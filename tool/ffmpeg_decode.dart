import 'dart:io';

/// [PcmDecoder] for the PC tools: ffmpeg (on PATH) converts to 44.1 kHz stereo.
Future<({int sampleRate, int channels})> ffmpegDecode(String input, String output) async {
  await _ffmpeg([
    '-i', input, '-f', 's16le', '-acodec', 'pcm_s16le', '-ar', '44100', '-ac', '2', output, //
  ]);
  return (sampleRate: 44100, channels: 2);
}

/// [AudioEncoder] for the PC tools: AAC at 128 kb/s, like the phone.
Future<void> ffmpegEncode(String input, String output) =>
    _ffmpeg(['-i', input, '-c:a', 'aac', '-b:a', '128k', output]);

Future<void> _ffmpeg(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-y', '-loglevel', 'error', ...args]);
  if (r.exitCode != 0) throw ProcessException('ffmpeg', args, '${r.stderr}', r.exitCode);
}
