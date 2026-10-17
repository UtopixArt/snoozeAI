import 'package:flutter/services.dart';

/// Android MediaCodec conversions used by the show mixer. Works in
/// background isolates too.
class AudioCodec {
  static const _channel = MethodChannel('snoozeai/audio_codec');

  /// Writes interleaved 16-bit LE PCM samples of [input] (MP3, AAC…) to
  /// [output] and returns the sample rate and channel count of that PCM.
  static Future<({int sampleRate, int channels})> decodeToPcm(
      String input, String output) async {
    final info = await _channel.invokeMapMethod<String, Object>(
      'decodeToPcm',
      {'input': input, 'output': output},
    );
    return (
      sampleRate: info!['sampleRate']! as int,
      channels: info['channels']! as int,
    );
  }

  /// Encodes a 16-bit PCM WAV with a canonical 44-byte header to AAC (.m4a).
  static Future<void> encodeWavToAac(String input, String output, {int bitrate = 128000}) =>
      _channel.invokeMethod<void>(
        'encodeWavToAac',
        {'input': input, 'output': output, 'bitrate': bitrate},
      );
}
