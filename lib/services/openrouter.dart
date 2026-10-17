import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thin OpenRouter client. Pure Dart (no Flutter imports) so it can run in a
/// background isolate on the phone and from `tool/` scripts on a PC.
class OpenRouterClient {
  OpenRouterClient(this.apiKey, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static const _base = 'https://openrouter.ai/api/v1';

  final String apiKey;
  final http.Client _http;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://github.com/snoozeai',
        'X-Title': 'snoozeAI',
      };

  /// Chat completion; returns the assistant text and any web citations.
  Future<ChatResult> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    Map<String, dynamic>? responseFormat,
    List<Map<String, dynamic>>? plugins,
    Map<String, dynamic>? extra,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'response_format': ?responseFormat,
      'plugins': ?plugins,
      ...?extra,
    };
    final res = await _http
        .post(Uri.parse('$_base/chat/completions'),
            headers: _headers, body: jsonEncode(body))
        .timeout(timeout);
    final json = _decodeOrThrow(res);
    final message = (json['choices'] as List).first['message'] as Map;
    final annotations = (message['annotations'] as List?) ?? const [];
    final citations = <Citation>[
      for (final a in annotations)
        if (a is Map && a['type'] == 'url_citation')
          Citation(
            url: a['url_citation']['url'] as String? ?? '',
            title: a['url_citation']['title'] as String? ?? '',
          ),
    ];
    return ChatResult(_contentText(message['content']), citations);
  }

  /// Text to speech through `/audio/speech`. [input] is either a plain string
  /// or a list of `{text, voice}` turns (multi-speaker, Gemini TTS).
  /// Raw PCM responses come back wrapped in a WAV container.
  Future<SpeechAudio> speech({
    required String model,
    required Object input,
    String? voice,
    String? instructions,
    String format = 'mp3',
    Duration timeout = const Duration(minutes: 4),
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'input': input,
      'voice': ?voice,
      'instructions': ?instructions,
      'response_format': format,
    };
    final res = await _http
        .post(Uri.parse('$_base/audio/speech'),
            headers: _headers, body: jsonEncode(body))
        .timeout(timeout);
    if (res.statusCode != 200) _throwApiError(res.statusCode, res.body);
    if (res.bodyBytes.isEmpty) {
      throw OpenRouterException(res.statusCode, 'Réponse audio vide');
    }
    // e.g. "audio/pcm;rate=24000;channels=1"
    final type = res.headers['content-type'] ?? '';
    if (!type.startsWith('audio/pcm')) return SpeechAudio(res.bodyBytes, 'mp3');
    int param(String name, int fallback) =>
        int.tryParse(RegExp('$name=(\\d+)').firstMatch(type)?.group(1) ?? '') ?? fallback;
    return SpeechAudio(
      pcm16ToWav(res.bodyBytes, sampleRate: param('rate', 24000), channels: param('channels', 1)),
      'wav',
    );
  }

  /// Music generation (Lyria) through chat completions with audio output.
  /// The audio arrives as base64 chunks in an SSE stream.
  Future<Uint8List> music({
    required String model,
    required String prompt,
    String format = 'mp3',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final req = http.Request('POST', Uri.parse('$_base/chat/completions'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        'modalities': ['text', 'audio'],
        'audio': {'format': format},
        'stream': true,
      });
    final res = await _http.send(req).timeout(timeout);
    if (res.statusCode != 200) {
      _throwApiError(res.statusCode, await res.stream.bytesToString());
    }

    final audio = StringBuffer();
    String? streamError;
    await for (final line in res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(timeout)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final chunk = jsonDecode(data) as Map<String, dynamic>;
      if (chunk['error'] != null) {
        streamError = jsonEncode(chunk['error']);
        continue;
      }
      for (final choice in (chunk['choices'] as List?) ?? const []) {
        final part = (choice['delta'] ?? choice['message']) as Map?;
        final b64 = (part?['audio'] as Map?)?['data'];
        if (b64 is String) audio.write(b64);
      }
    }
    if (audio.isEmpty) {
      throw OpenRouterException(
          200, streamError ?? 'Aucune donnée audio renvoyée par $model');
    }
    return base64Decode(audio.toString());
  }

  void close() => _http.close();

  static String _contentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .map((p) => p['text'])
          .whereType<String>()
          .join();
    }
    return '';
  }

  static Map<String, dynamic> _decodeOrThrow(http.Response res) {
    if (res.statusCode != 200) _throwApiError(res.statusCode, res.body);
    // Long requests may be padded with keep-alive lines (": OPENROUTER
    // PROCESSING") before the JSON body.
    final body = utf8
        .decode(res.bodyBytes, allowMalformed: true)
        .split('\n')
        .where((l) => !l.startsWith(':'))
        .join('\n')
        .trim();
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException catch (e) {
      final head = body.length > 160 ? '${body.substring(0, 160)}…' : body;
      throw OpenRouterException(res.statusCode, 'Réponse illisible (${e.message}) : $head');
    }
    if (json['error'] != null) {
      throw OpenRouterException(res.statusCode, jsonEncode(json['error']));
    }
    return json;
  }

  static Never _throwApiError(int status, String body) {
    var message = body;
    try {
      final err = (jsonDecode(body) as Map)['error'];
      if (err is Map && err['message'] != null) message = '${err['message']}';
    } catch (_) {}
    throw OpenRouterException(status, message);
  }
}

class SpeechAudio {
  SpeechAudio(this.bytes, this.extension);
  final Uint8List bytes;

  /// File extension matching [bytes]: `mp3` or `wav`.
  final String extension;
}

/// Prepends a 44-byte RIFF header to little-endian 16-bit PCM samples.
Uint8List pcm16ToWav(Uint8List pcm, {required int sampleRate, required int channels}) {
  const bytesPerSample = 2;
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // fmt chunk size
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * channels * bytesPerSample, Endian.little);
  header.setUint16(32, channels * bytesPerSample, Endian.little);
  header.setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}

class ChatResult {
  ChatResult(this.text, this.citations);
  final String text;
  final List<Citation> citations;
}

class Citation {
  Citation({required this.url, required this.title});
  final String url;
  final String title;

  Map<String, dynamic> toJson() => {'url': url, 'title': title};
  factory Citation.fromJson(Map<String, dynamic> j) =>
      Citation(url: j['url'] as String, title: j['title'] as String);
}

class OpenRouterException implements Exception {
  OpenRouterException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  @override
  String toString() => 'OpenRouter $statusCode: $message';
}
