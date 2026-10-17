// Runs only Grok's script step (no voices, no music) to check the prompt and
// the JSON it returns.
//
//   dart run tool/test_script.dart [--minutes 12] [--model x-ai/grok-4.7]
import 'dart:io';

import 'package:snooze_ai/services/openrouter.dart';
import 'package:snooze_ai/services/show_config.dart';
import 'package:snooze_ai/services/show_generator.dart';

import 'dot_env.dart';
import 'ffmpeg_decode.dart';

Future<void> main(List<String> args) async {
  final key = secret('OPENROUTER_API_KEY');
  if (key == null || key.isEmpty) {
    stderr.writeln('OPENROUTER_API_KEY introuvable.');
    exit(64);
  }
  var config = const ShowConfig();
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] == '--minutes') config = config.copyWith(showMinutes: int.parse(args[i + 1]));
    if (args[i] == '--model') config = config.copyWith(grokModel: args[i + 1]);
  }
  final client = OpenRouterClient(key);
  final watch = Stopwatch()..start();
  try {
    final json = await ShowGenerator(
      client: client,
      config: config,
      decode: ffmpegDecode,
      encode: ffmpegEncode,
      stationDir: Directory('out/station'),
      libraryDir: Directory('out/library'),
      debugDir: Directory('out/debug'),
    ).scriptOnly(DateTime.now());
    await Directory('out/debug').create(recursive: true);
    await File('out/debug/script.json').writeAsString(json);
    stdout.writeln('OK en ${watch.elapsed.inSeconds} s → out/debug/script.json');
  } finally {
    client.close();
  }
}
