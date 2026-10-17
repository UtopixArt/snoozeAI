// Generates a Radio CHROME show on the PC, to try prompts, voices and music
// without the phone.
//
//   dart run tool/generate_show.dart [--minutes 12] [--song-seconds 120]
//       [--name Alex] [--style "..."] [--tokyo]
//
// Keys come from the environment or `.env` (OPENROUTER_API_KEY, and
// APIMART_API_KEY for Suno). ffmpeg must be on PATH. The station theme and the
// song library persist in `out/station` and `out/library` like on the phone.
import 'dart:io';

import 'package:snooze_ai/services/apimart_suno.dart';
import 'package:snooze_ai/services/openrouter.dart';
import 'package:snooze_ai/services/show_config.dart';
import 'package:snooze_ai/services/show_generator.dart';

import 'dot_env.dart';
import 'ffmpeg_decode.dart';

Future<void> main(List<String> args) async {
  final key = secret('OPENROUTER_API_KEY');
  if (key == null || key.isEmpty) {
    stderr.writeln('OPENROUTER_API_KEY introuvable (variable d\'environnement ou .env).');
    exit(64);
  }
  final sunoKey = secret('APIMART_API_KEY');

  var config = const ShowConfig();
  var wakeAt = DateTime.now();
  for (var i = 0; i < args.length; i++) {
    final value = i + 1 < args.length ? args[i + 1] : '';
    switch (args[i]) {
      case '--minutes':
        config = config.copyWith(showMinutes: int.parse(value));
      case '--song-seconds':
        config = config.copyWith(songSeconds: int.parse(value));
      case '--name':
        config = config.copyWith(listenerName: value);
      case '--style':
        config = config.copyWith(musicStyle: value);
      case '--tokyo':
        // Pretend the phone is on Japan time to hear the travel episode.
        final utc = DateTime.now().toUtc().add(const Duration(hours: 9));
        wakeAt = _FixedOffset(utc, const Duration(hours: 9));
    }
  }

  final client = OpenRouterClient(key);
  final suno = sunoKey == null || sunoKey.isEmpty ? null : ApimartSuno(sunoKey);
  if (suno == null) stdout.writeln('Pas de APIMART_API_KEY : musique depuis la bibliothèque / Lyria.');
  final watch = Stopwatch()..start();
  try {
    final show = await ShowGenerator(
      client: client,
      config: config,
      decode: ffmpegDecode,
      encode: ffmpegEncode,
      stationDir: Directory('out/station'),
      libraryDir: Directory('out/library'),
      suno: suno,
      debugDir: Directory('out/debug'),
    ).generate(
      rootDir: Directory('out'),
      wakeAt: wakeAt,
      onProgress: (s) => stdout.writeln('[${watch.elapsed.inSeconds}s] $s'),
    );
    stdout.writeln('\n${show.title} — ${show.onAirCity} — ${(show.durationSeconds / 60).toStringAsFixed(1)} min'
        ' — Suno ${show.sunoCostUsd.toStringAsFixed(2)} \$');
    for (final s in show.segments) {
      stdout.writeln('  ${_mmss(s.start)}  ${s.kind.padRight(6)} ${s.label}');
    }
    stdout.writeln('Fichier : ${show.audioPath}');
    for (final c in show.snoozes) {
      stdout.writeln('Snooze : ${show.dirPath}/${c.file} (reprise à ${_mmss(c.resumeAt)})');
    }
    for (final e in show.errors) {
      stderr.writeln('ERREUR $e');
    }
    if (show.errors.isNotEmpty) exitCode = 1;
  } finally {
    client.close();
    suno?.close();
  }
}

String _mmss(double s) =>
    '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).floor().toString().padLeft(2, '0')}';

/// A local time in another zone than the PC's, for `--tokyo`.
class _FixedOffset extends DateTime {
  _FixedOffset(DateTime utc, this._offset)
      : super(utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second);
  final Duration _offset;

  @override
  Duration get timeZoneOffset => _offset;
}
