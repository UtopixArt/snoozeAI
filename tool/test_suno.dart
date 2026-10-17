// One real Suno generation through APIMart, to check price, track count and
// waiting time before wiring it into the show.
//
//   dart run tool/test_suno.dart ["prompt"]
//
// Reads APIMART_API_KEY from the environment or `.env`. Output in `out/suno/`.
import 'dart:io';

import 'package:snooze_ai/services/apimart_suno.dart';

import 'dot_env.dart';

Future<void> main(List<String> args) async {
  final key = secret('APIMART_API_KEY');
  if (key == null || key.isEmpty) {
    stderr.writeln('APIMART_API_KEY introuvable (variable d\'environnement ou .env).');
    exit(64);
  }
  final prompt = args.isNotEmpty
      ? args.first
      : 'Chanson pop française entraînante pour se réveiller le matin, voix féminine solaire, '
          'refrain accrocheur sur le fait de sortir du lit et de croquer la journée, 118 BPM';

  await Directory('out/suno').create(recursive: true);
  final suno = ApimartSuno(key);
  final watch = Stopwatch()..start();
  try {
    final result = await suno.generate(
      prompt: prompt,
      pathPrefix: 'out/suno/test_${DateTime.now().millisecondsSinceEpoch}',
    );
    stdout.writeln('Terminé en ${watch.elapsed.inSeconds} s — tâche ${result.taskId}');
    stdout.writeln('Coût annoncé : ${result.costUsd == null ? 'non renvoyé' : '${result.costUsd} \$'}');
    for (final t in result.tracks) {
      stdout.writeln('  « ${t.title} » — ${t.seconds.toStringAsFixed(0)} s → ${t.path}');
    }
  } finally {
    suno.close();
  }
}
