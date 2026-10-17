import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Suno song generation through the APIMart reseller (not an official Suno
/// API). Asynchronous: submit, poll the task, then download the tracks.
class ApimartSuno {
  ApimartSuno(this.apiKey, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static const _base = 'https://api.apimart.ai/v1/music';

  final String apiKey;
  final http.Client _http;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      };

  /// Generates songs from [prompt] (style, mood, theme of the lyrics) and
  /// downloads every returned track as `<pathPrefix>_<n>.<ext>`.
  Future<SunoResult> generate({
    required String prompt,
    required String pathPrefix,
    String version = 'v6',
    bool instrumental = false,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    final submit = await _http
        .post(Uri.parse('$_base/generations'),
            headers: _headers,
            body: jsonEncode({
              'model': 'suno',
              'version': version,
              'custom': false,
              'instrumental': instrumental,
              'prompt': prompt.length > 3000 ? prompt.substring(0, 3000) : prompt,
              'audio_format': 'mp3',
            }))
        .timeout(const Duration(minutes: 1));
    final submitted = _decode(submit);
    final taskId = ((submitted['data'] as List).first as Map)['task_id'] as String;

    // A paid task is never resubmitted; only its status is polled.
    final deadline = DateTime.now().add(timeout);
    await Future<void>.delayed(const Duration(seconds: 3));
    while (true) {
      final res = await _http
          .get(Uri.parse('$_base/tasks/$taskId'), headers: _headers)
          .timeout(const Duration(seconds: 30));
      final data = _decode(res)['data'] as Map<String, dynamic>;
      switch (data['status']) {
        case 'completed':
          return _download(data, taskId, pathPrefix);
        case 'failed':
          throw ApimartException('Génération Suno échouée : ${data['error'] ?? data}');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw ApimartException('Suno trop long (tâche $taskId)');
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<SunoResult> _download(Map<String, dynamic> data, String taskId, String pathPrefix) async {
    final music = ((data['result'] as Map?)?['music'] as List?) ?? const [];
    final tracks = <SunoTrack>[];
    for (final m in music.cast<Map<String, dynamic>>()) {
      final url = m['audio_url'] as String?;
      if (url == null || url.isEmpty) continue;
      final res = await _http.get(Uri.parse(url)).timeout(const Duration(minutes: 2));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) continue;
      final path = '${pathPrefix}_${tracks.length}.mp3';
      await File(path).writeAsBytes(res.bodyBytes, flush: true);
      tracks.add(SunoTrack(
        path: path,
        title: (m['title'] as String?)?.trim() ?? '',
        seconds: (m['duration'] as num?)?.toDouble() ?? 0,
      ));
    }
    if (tracks.isEmpty) throw ApimartException('Aucun morceau téléchargeable (tâche $taskId)');
    return SunoResult(
      tracks: tracks,
      costUsd: (data['cost'] as num?)?.toDouble(),
      taskId: taskId,
    );
  }

  void close() => _http.close();

  static Map<String, dynamic> _decode(http.Response res) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on FormatException {
      json = null;
    }
    if (res.statusCode != 200 || json == null || (json['code'] != null && json['code'] != 200)) {
      final err = json?['error'] ?? json?['message'] ?? res.body;
      throw ApimartException('APIMart ${res.statusCode} : ${err is Map ? err['message'] ?? err : err}');
    }
    return json;
  }
}

class SunoTrack {
  SunoTrack({required this.path, required this.title, required this.seconds});
  final String path;
  final String title;
  final double seconds;
}

class SunoResult {
  SunoResult({required this.tracks, required this.costUsd, required this.taskId});
  final List<SunoTrack> tracks;

  /// Cost reported by APIMart for the task, when it reports one.
  final double? costUsd;
  final String taskId;
}

class ApimartException implements Exception {
  ApimartException(this.message);
  final String message;

  @override
  String toString() => message;
}
