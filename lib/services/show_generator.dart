import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'apimart_suno.dart';
import 'audio_pcm.dart';
import 'music_library.dart';
import 'openrouter.dart';
import 'radio_mixer.dart';
import 'show_config.dart';
import 'station.dart';

/// Builds one Radio CHROME morning show:
///  1. plans the playlist (new Suno songs + station library, rising energy),
///  2. Grok writes the rundown while Suno composes,
///  3. Gemini TTS records every line in the right host's voice,
///  4. everything is mixed into `show.m4a`, plus the snooze-roast versions.
class ShowGenerator {
  ShowGenerator({
    required this.client,
    required this.config,
    required this.decode,
    required this.encode,
    required this.stationDir,
    required this.libraryDir,
    this.suno,
    this.debugDir,
  });

  final OpenRouterClient client;
  final ShowConfig config;
  final PcmDecoder decode;
  final AudioEncoder encode;

  /// Long-lived station assets (the theme).
  final Directory stationDir;
  final Directory libraryDir;

  /// Null when there is no APIMart key: songs come from the library, then Lyria.
  final ApimartSuno? suno;

  /// Where diagnostics such as unreadable Grok answers are written, if set.
  final Directory? debugDir;

  static const snoozeVariants = 2;

  /// Radio kept after a snooze roast; the cut loops if the listener still sleeps.
  static const _snoozeTailSeconds = 360.0;
  static const _ttsConcurrency = 6;
  static const _lineGap = 0.15;
  static final _songMarker = RegExp(r'\{MORCEAU_(\d+)\}');

  /// Production words Grok sometimes leaks next to the title marker.
  static final _markerLeak = RegExp(r'\btitres? exacts?\s*[,:]?\s*', caseSensitive: false);

  Future<Show> generate({
    required Directory rootDir,
    required DateTime wakeAt,
    void Function(String step)? onProgress,
  }) async {
    final dir = Directory('${rootDir.path}/show-${DateTime.now().millisecondsSinceEpoch}');
    await dir.create(recursive: true);
    final place = config.placeAt(wakeAt.timeZoneOffset);
    final library = await MusicLibrary.open(libraryDir);
    final errors = <String>[];
    Future<T?> guard<T>(String what, Future<T> job) =>
        job.then<T?>((v) => v).catchError((Object e) {
          errors.add('$what : $e');
          return null;
        });

    // 1. Playlist plan: new songs fill the first slots, the library the rest.
    final generations = suno == null ? 0 : library.generationsNeeded(config.songCount);
    final presets = library.choosePresets(generations);
    final slots = <_Slot>[
      for (var g = 0; g < presets.length; g++)
        for (var k = 0; k < 2; k++) _Slot(presets[g], generation: g),
    ].take(config.songCount).toList();
    for (final song in library.pick(config.songCount - slots.length)) {
      slots.add(_Slot(presetById(song.preset), song: song));
    }
    while (slots.length < config.songCount) {
      // No Suno and a thin library: Lyria fills in, cycling through presets.
      slots.add(_Slot(musicPresets[slots.length % musicPresets.length]));
    }
    slots.sort((a, b) => a.preset.energy.compareTo(b.preset.energy));

    // 2. Grok writes while Suno composes and the theme is checked.
    onProgress?.call('Grok écrit l\'émission, Suno compose ${generations * 2} morceaux…');
    final themeJob = guard('Générique', _ensureTheme());
    final sunoJobs = [
      for (var g = 0; g < presets.length; g++)
        guard('Suno ${presets[g].label}', suno!.generate(
          prompt: [presets[g].prompt, if (config.musicStyle.trim().isNotEmpty) config.musicStyle]
              .join('. '),
          pathPrefix: '${dir.path}/suno_$g',
        )),
    ];
    // Paid songs go into the library as soon as they exist, even when the
    // rest of the show fails, so a retry does not pay for them again.
    var sunoCost = 0.0;
    Future<void> shelveSongs() async {
      final sunoResults = await Future.wait(sunoJobs);
      for (var g = 0; g < presets.length; g++) {
        final result = sunoResults[g];
        if (result == null) continue;
        sunoCost += result.costUsd ?? 0;
        library.notePresetGenerated(presets[g].id);
        final waiting = slots.where((s) => s.generation == g && s.song == null).toList();
        for (var t = 0; t < result.tracks.length; t++) {
          final track = result.tracks[t];
          final added = await library.add(track.path, title: track.title, preset: presets[g].id);
          if (t < waiting.length) waiting[t].song = added;
        }
      }
      await library.save();
    }

    final _Script script;
    try {
      script = await _writeScript(wakeAt, place, slots);
    } catch (_) {
      await shelveSongs();
      rethrow;
    }
    onProgress?.call('Rangement des morceaux…');
    await shelveSongs();
    final used = {for (final s in slots) if (s.song != null) s.song!.id};
    for (final slot in slots.where((s) => s.song == null)) {
      final spare = library.pick(1, exclude: used);
      if (spare.isNotEmpty) {
        slot.song = spare.first;
        used.add(spare.first.id);
      }
    }
    await Future.wait([
      for (var i = 0; i < slots.length; i++)
        if (slots[i].song == null)
          guard('Morceau de secours ${slots[i].preset.label}',
                  _lyria(ShowConfig.fallbackSongModel, slots[i].preset.prompt, '${dir.path}/lyria_$i.mp3'))
              .then((path) => slots[i].fallbackPath = path),
    ]);

    // 3. Every line in its host's voice.
    onProgress?.call('VOLT et NYX enregistrent…');
    String withTitles(String text) => text.replaceAll(_markerLeak, '').replaceAllMapped(_songMarker, (m) {
          final i = int.parse(m[1]!) - 1;
          return i >= 0 && i < slots.length && slots[i].playable ? slots[i].title : 'un son qui tabasse';
        });
    final allLines = [
      for (final b in script.blocks) ...b.lines,
      for (final roast in script.snoozeRoasts) ...roast,
    ];
    final linePaths = await _recordLines(allLines, withTitles, dir, errors);

    // 4. Mix.
    onProgress?.call('Mixage de l\'émission…');
    final themePath = await themeJob;
    final theme = themePath == null
        ? null
        : (await loadClip(themePath, decode)).levelTo(RadioMixer.musicLevel);
    Future<Clip?> voiceOf(List<Line> lines) async {
      final clips = <Clip>[];
      for (final l in lines) {
        final path = linePaths[l];
        if (path == null) continue;
        final persona = personaFor(l.speaker);
        if (clips.isNotEmpty) clips.add(Clip.silence(_lineGap));
        clips.add((await loadClip(path, decode))
            .saturate(persona.grit)
            .levelTo(RadioMixer.voiceLevel * (persona == pubVoice ? 0.9 : 1)));
      }
      return clips.isEmpty ? null : Clip.concat(clips);
    }

    final mainWav = '${dir.path}/show.wav';
    final writer = await WavWriter.open(mainWav);
    final RadioMixer mixer;
    double? firstSongAt;
    final played = <LibrarySong>[];
    try {
      mixer = RadioMixer(writer, theme: theme);
      await mixer.signal();
      final talkBlocks = [
        for (var i = 0; i < script.blocks.length; i++)
          if (script.blocks[i].kind == 'talk') i,
      ];
      var nextSlot = 0;
      for (var i = 0; i < script.blocks.length; i++) {
        final block = script.blocks[i];
        final voice = await voiceOf(block.lines);
        if (voice != null) {
          await mixer.talk(
            voice,
            block: i,
            label: block.topic,
            kind: block.kind,
            opening: i == 0,
            closing: i == script.blocks.length - 1,
          );
        }
        if (block.kind != 'talk' || i == talkBlocks.last) continue;
        while (nextSlot < slots.length && !slots[nextSlot].playable) {
          nextSlot++;
        }
        if (nextSlot >= slots.length) continue;
        final slot = slots[nextSlot++];
        final path = slot.song != null ? library.pathOf(slot.song!) : slot.fallbackPath!;
        final song = await loadClip(path, decode, maxSeconds: config.songSeconds + 1.0);
        firstSongAt ??= mixer.position;
        await mixer.song(song.levelTo(RadioMixer.musicLevel, maxPeak: 0.95),
            label: slot.title, maxSeconds: config.songSeconds.toDouble());
        if (slot.song != null) played.add(slot.song!);
        await mixer.jingle();
      }
    } finally {
      await writer.close();
    }
    if (mixer.segments.length <= 1) {
      throw StateError('Rien à diffuser :\n${errors.join('\n')}');
    }

    // Snooze versions: a roast from the hosts, then the show from its first song.
    final snoozes = <SnoozeCut>[];
    for (var k = 0; k < script.snoozeRoasts.length && k < snoozeVariants; k++) {
      final roast = await voiceOf(script.snoozeRoasts[k]);
      if (roast == null) continue;
      final wav = '${dir.path}/snooze_${k + 1}.wav';
      final w = await WavWriter.open(wav);
      double intro;
      try {
        final m = RadioMixer(w, theme: theme);
        await m.signal(seconds: 1.0, seed: 11 + k);
        await m.talk(roast, block: -1, label: 'Rapport de snooze', opening: true);
        intro = m.position;
        final from = firstSongAt ?? 0;
        await w.appendWavRange(mainWav, from, from + _snoozeTailSeconds);
      } finally {
        await w.close();
      }
      snoozes.add(SnoozeCut(
        file: 'snooze_${k + 1}.m4a',
        introSeconds: intro,
        resumeAt: firstSongAt ?? 0,
        seconds: w.seconds,
      ));
    }

    onProgress?.call('Compression…');
    await encode(mainWav, '${dir.path}/show.m4a');
    for (var k = 0; k < snoozes.length; k++) {
      await encode('${dir.path}/snooze_${k + 1}.wav', '${dir.path}/${snoozes[k].file}');
    }
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is File && !name.endsWith('.m4a')) await f.delete();
    }

    library.markPlayed(played, wakeAt);
    await library.prune();
    await library.save();

    final show = Show(
      dirPath: dir.path,
      createdAt: DateTime.now(),
      wakeAt: wakeAt,
      onAirCity: place.onAir,
      title: script.title,
      blocks: script.blocks,
      songs: [for (final s in slots) if (s.playable) Song(title: s.title, preset: s.preset.id)],
      segments: mixer.segments,
      durationSeconds: mixer.position,
      citations: script.citations,
      audioFile: 'show.m4a',
      snoozes: snoozes,
      sunoCostUsd: sunoCost,
      errors: errors,
    );
    await File('${dir.path}/show.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(show));
    onProgress?.call(errors.isEmpty ? 'Émission prête' : 'Émission prête (partielle)');
    return show;
  }

  /// Grok's script alone for [wakeAt], with a placeholder playlist, as JSON.
  /// Used by `tool/test_script.dart` to check the prompt without paying for audio.
  Future<String> scriptOnly(DateTime wakeAt) async {
    final slots = [for (var i = 0; i < config.songCount; i++) _Slot(musicPresets[i % musicPresets.length])];
    final script = await _writeScript(wakeAt, config.placeAt(wakeAt.timeZoneOffset), slots);
    return const JsonEncoder.withIndent('  ').convert({
      'title': script.title,
      'blocks': script.blocks,
      'snooze': script.snoozeRoasts,
      'citations': script.citations,
    });
  }

  Future<_Script> _writeScript(DateTime wakeAt, Place place, List<_Slot> slots) async {
    final talkBlocks = slots.length + 1;
    final pubs = config.showMinutes > 15 ? 2 : 1;
    // The hosts speak ~155 words a minute; Grok overshoots loose targets, so
    // each block gets a hard ceiling.
    final words = (config.talkSeconds / 60 * 150).round() - pubs * 60;
    final openingWords = (words * 0.3).round();
    final closingWords = (words * 0.22).round();
    final middleWords =
        talkBlocks > 2 ? ((words - openingWords - closingWords) / (talkBlocks - 2)).round() : 0;
    final name = config.listenerName.trim();
    final listener = name.isEmpty
        ? "l'auditeur (tu ne connais pas son prénom : tutoie-le, ne l'appelle jamais « l'auditeur » à l'antenne)"
        : name;
    final playlist = [
      for (var i = 0; i < slots.length; i++)
        '- Morceau ${i + 1} : ${slots[i].preset.label}'
            '${slots[i].song != null ? ' (titre : « ${slots[i].song!.title} »)' : ''}. '
            'Son titre est remplacé automatiquement : à l\'antenne, écris {MORCEAU_${i + 1}} à la place '
            'du titre, comme si c\'était le titre lui-même (« on écoute {MORCEAU_${i + 1}} »).',
    ].join('\n');
    final travel = place.onAir != config.onAirCity
        ? '\nL\'auditeur est en voyage : on est à ${place.onAir} (${place.city}), loin de ${config.onAirCity}, sa ville. Exploite-le !'
        : '';

    final system = '''
Tu es le producteur de $stationName, une radio pirate cyberpunk qui émet sur ${place.onAir}.
${place.onAir} est le nom cyberpunk de la vraie ville de ${place.city}. ${place.flavor}$travel

Les voix de l'antenne :
- ${volt.name} (speaker "A") : ${volt.character}
- ${nyx.name} (speaker "B") : ${nyx.character}
- ${pubVoice.name} (speaker "P") : ${pubVoice.character} Uniquement dans les blocs "pub".
Le contraste VOLT qui hurle / NYX qui apaise fait le show. Répliques courtes qui fusent, vannes, complicité.
Running gag : $listener est un champion du snooze.

Univers : un futur cyberpunk où les grosses entreprises sont « les corpos », la ville est un « Sprawl », les infos
sont « piratées des serveurs corpo ». Mais les FAITS restent vrais et exacts : météo, chiffres, dates, noms,
événements viennent de la recherche web et ne sont jamais inventés. Seul l'emballage est cyberpunk.

Conducteur de ce matin : exactement $talkBlocks blocs "talk", plus $pubs bloc(s) "pub".
Après chacun des ${slots.length} premiers blocs "talk", un morceau passe, dans cet ordre :
$playlist

LONGUEUR : contrainte stricte, la radio a une grille horaire. Compte tes mots et reste dans chaque fourchette :
ni plus (on déborde sur les morceaux), ni moins (un bloc trop court sonne vide). Environ $words mots au total.
- 1er bloc "talk" (entre ${_low(openingWords)} et $openingWords mots) : ouverture explosive, VOLT hurle « BONJOUR ${place.onAir} !!! »,
  $stationName, l'heure, puis NYX enchaîne en douceur. Météo du jour à ${place.city} en version « Météo du Sprawl »,
  en deux ou trois chiffres clés. Teaser express. Lancement du morceau 1.
- Blocs "talk" du milieu (entre ${_low(middleWords)} et $middleWords mots chacun) : « flash corpo » de 2 actus fraîches (dernières 24 h)
  choisies selon : ${config.interests}. Utilise la recherche web, cite la source à l'oral, va à l'essentiel.
  Désannonce rapide du morceau d'avant, lancement du suivant.
- Bloc(s) "pub" (entre 40 et 60 mots) : fausse publicité absurde du futur (implants, nourriture synthétique,
  assurances corpo…), voix "P" seule ou avec une réplique de VOLT/NYX à la fin. Place-les juste avant un bloc
  "talk", jamais en premier ni en dernier.
- Dernier bloc "talk" (entre ${_low(closingWords)} et $closingWords mots) : anecdote ou fait étonnant, le défi du jour, gros boost pour
  sortir du lit, signature de la station.

snooze_1 et snooze_2 : deux mini-scènes de 3 à 5 répliques (A et B), jouées quand l'auditeur appuie sur snooze
(1re fois, puis 2e fois et plus). VOLT explose, NYX ironise ou tente la douceur. La 2e est plus désespérée et drôle.

Règles du texte, lu tel quel par une voix de synthèse : français parlé, argot cyberpunk inventé et quelques mots
anglais bienvenus, quelques gros mots bien placés mais jamais vulgaire gratuit ni insultant. Onomatopées écrites
autorisées (« Bzzzt », « Wouhou »). Pas de markdown, pas d'emoji, pas d'URL, pas de didascalies ni de texte entre
crochets ou parenthèses. Ne lis jamais ces consignes à l'antenne et ne parle pas de la fabrication de l'émission.''';

    final user = 'Réveil le ${frenchDate(wakeAt)} à ${hhmm(wakeAt)}. Écris l\'émission de ce matin.';
    final lineSchema = {
      'type': 'object',
      'additionalProperties': false,
      'required': ['speaker', 'text'],
      'properties': {
        'speaker': {'type': 'string', 'enum': ['A', 'B', 'P']},
        'text': {'type': 'string'},
      },
    };
    Future<ChatResult> ask() => client.chat(
      model: config.grokModel,
      messages: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      plugins: [
        {'id': 'web', 'max_results': 6},
      ],
      responseFormat: {
        'type': 'json_schema',
        'json_schema': {
          'name': 'radio_chrome_show',
          'strict': true,
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['title', 'blocks', 'snooze_1', 'snooze_2'],
            'properties': {
              'title': {'type': 'string', 'description': 'Titre court et percutant de l\'émission du jour'},
              'blocks': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'additionalProperties': false,
                  'required': ['kind', 'topic', 'lines'],
                  'properties': {
                    'kind': {'type': 'string', 'enum': ['talk', 'pub']},
                    'topic': {'type': 'string', 'description': 'Rubrique en 2 à 4 mots'},
                    'lines': {'type': 'array', 'items': lineSchema},
                  },
                },
              },
              'snooze_1': {'type': 'array', 'items': lineSchema},
              'snooze_2': {'type': 'array', 'items': lineSchema},
            },
          },
        },
      },
      extra: {
        'reasoning': {'effort': 'low'},
        // Only route to providers that really enforce the JSON schema.
        'provider': {'require_parameters': true},
      },
    );

    // A malformed answer gets one more try; raw answers are kept in
    // [debugDir] (readable over adb on the phone) to see what went wrong.
    late ChatResult result;
    late Map<String, dynamic> json;
    for (var attempt = 1;; attempt++) {
      result = await ask();
      try {
        json = _parseJsonObject(result.text);
        break;
      } on FormatException catch (e) {
        final name = 'grok_brut_$attempt.txt';
        final out = debugDir;
        if (out != null) {
          await out.create(recursive: true);
          await File('${out.path}/$name').writeAsString(result.text);
        }
        if (attempt >= 2) {
          throw FormatException('Script de Grok illisible deux fois (${e.message})'
              '${out != null ? ', réponse brute dans $name' : ''}');
        }
      }
    }
    List<Line> lines(Object? raw) => [
          for (final t in (raw as List?) ?? const [])
            if ('${t['text']}'.trim().isNotEmpty)
              Line(speaker: const {'A', 'B', 'P'}.contains(t['speaker']) ? t['speaker'] as String : 'A',
                  text: '${t['text']}'.trim()),
        ];
    final blocks = [
      for (final b in json['blocks'] as List)
        if (lines(b['lines']).isNotEmpty)
          Block(kind: b['kind'] == 'pub' ? 'pub' : 'talk', topic: '${b['topic']}', lines: lines(b['lines'])),
    ];
    if (!blocks.any((b) => b.kind == 'talk')) {
      throw const FormatException('Conducteur vide renvoyé par Grok');
    }
    return _Script(
      title: '${json['title']}',
      blocks: blocks,
      snoozeRoasts: [lines(json['snooze_1']), lines(json['snooze_2'])],
      citations: result.citations,
    );
  }

  /// Lower end of a word range whose upper end is [max].
  static int _low(int max) => (max * 0.8).round();

  /// One TTS call per line, so each host keeps their own voice and delivery.
  Future<Map<Line, String>> _recordLines(
      List<Line> lines, String Function(String) prepare, Directory dir, List<String> errors) async {
    final paths = <Line, String>{};
    var next = 0;
    var failures = 0;
    Future<void> worker() async {
      while (next < lines.length) {
        final index = next++;
        final line = lines[index];
        final persona = personaFor(line.speaker);
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final audio = await client.speech(
              model: config.ttsModel,
              format: config.ttsModel.startsWith('google/') ? 'pcm' : 'mp3',
              input: prepare(line.text),
              voice: persona.voice,
              instructions: persona.delivery,
            );
            final path = '${dir.path}/line_$index.${audio.extension}';
            await File(path).writeAsBytes(audio.bytes, flush: true);
            paths[line] = path;
            break;
          } catch (e) {
            if (attempt == 1) {
              failures++;
              if (failures <= 3) errors.add('Voix ${persona.name} : $e');
            } else {
              await Future<void>.delayed(const Duration(seconds: 2));
            }
          }
        }
      }
    }

    await Future.wait([for (var i = 0; i < _ttsConcurrency; i++) worker()]);
    if (failures > 3) errors.add('… et ${failures - 3} autres répliques perdues');
    return paths;
  }

  Future<String> _ensureTheme() async {
    final file = File('${stationDir.path}/theme.mp3');
    if (await file.exists()) return file.path;
    await stationDir.create(recursive: true);
    return _lyria(ShowConfig.themeModel, stationThemePrompt, file.path);
  }

  Future<String> _lyria(String model, String prompt, String path) async {
    final bytes = await client.music(model: model, prompt: prompt);
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  /// Grok sometimes answers with several JSON objects back to back (an empty
  /// draft, then the real script), or wraps one in prose or code fences.
  /// Every top-level object is parsed and the one with the most lines wins.
  static Map<String, dynamic> _parseJsonObject(String text) {
    Map<String, dynamic>? best;
    var bestLines = -1;
    for (final candidate in topLevelJsonObjects(text)) {
      final Object? decoded;
      try {
        decoded = jsonDecode(candidate);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, dynamic>) continue;
      final lines = ((decoded['blocks'] as List?) ?? const [])
          .fold<int>(0, (n, b) => n + ((b is Map ? b['lines'] as List? : null)?.length ?? 0));
      if (lines > bestLines) {
        best = decoded;
        bestLines = lines;
      }
    }
    if (best == null) throw FormatException('Réponse de Grok illisible', text);
    return best;
  }
}

/// The balanced `{…}` spans at the top level of [text], ignoring braces
/// inside JSON strings.
Iterable<String> topLevelJsonObjects(String text) sync* {
  var depth = 0;
  var start = -1;
  var inString = false;
  var escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"' && depth > 0) {
      inString = true;
    } else if (c == '{') {
      if (depth == 0) start = i;
      depth++;
    } else if (c == '}' && depth > 0) {
      depth--;
      if (depth == 0) yield text.substring(start, i + 1);
    }
  }
}

/// One song position in the show.
class _Slot {
  _Slot(this.preset, {this.song, this.generation});
  final MusicPreset preset;

  /// Index of the Suno generation expected to fill this slot.
  final int? generation;
  LibrarySong? song;

  /// Lyria song when neither Suno nor the library could fill the slot.
  String? fallbackPath;

  bool get playable => song != null || fallbackPath != null;
  String get title => song?.title ?? 'Chrome ${preset.label}';
}

class _Script {
  _Script({
    required this.title,
    required this.blocks,
    required this.snoozeRoasts,
    required this.citations,
  });
  final String title;
  final List<Block> blocks;
  final List<List<Line>> snoozeRoasts;
  final List<Citation> citations;
}

class Line {
  Line({required this.speaker, required this.text});

  /// `A` (VOLT), `B` (NYX) or `P` (fake commercials).
  final String speaker;
  final String text;

  String get host => personaFor(speaker).name;

  Map<String, dynamic> toJson() => {'speaker': speaker, 'text': text};
  factory Line.fromJson(Map<String, dynamic> j) =>
      Line(speaker: j['speaker'] as String, text: j['text'] as String);
}

/// A stretch of the hosts talking (`talk`) or a fake commercial (`pub`).
class Block {
  Block({required this.kind, required this.topic, required this.lines});
  final String kind;
  final String topic;
  final List<Line> lines;

  Map<String, dynamic> toJson() => {'kind': kind, 'topic': topic, 'lines': lines};
  factory Block.fromJson(Map<String, dynamic> j) => Block(
        kind: j['kind'] as String? ?? 'talk',
        topic: j['topic'] as String,
        lines: [for (final l in j['lines'] as List) Line.fromJson(l as Map<String, dynamic>)],
      );
}

class Song {
  Song({required this.title, required this.preset});
  final String title;
  final String preset;

  Map<String, dynamic> toJson() => {'title': title, 'preset': preset};
  factory Song.fromJson(Map<String, dynamic> j) =>
      Song(title: j['title'] as String, preset: j['preset'] as String);
}

/// The show as replayed after a snooze: a roast, then the show resumed at its first song.
class SnoozeCut {
  SnoozeCut({
    required this.file,
    required this.introSeconds,
    required this.resumeAt,
    required this.seconds,
  });
  final String file;

  /// Total length of the cut (it loops while the alarm rings).
  final double seconds;

  /// Length of the roast before the show resumes.
  final double introSeconds;

  /// Position in the main show where this cut joins it.
  final double resumeAt;

  /// Position in the main show matching [seconds] into this cut.
  double mainPosition(double seconds) =>
      seconds <= introSeconds ? resumeAt : resumeAt + seconds - introSeconds;

  Map<String, dynamic> toJson() =>
      {'file': file, 'introSeconds': introSeconds, 'resumeAt': resumeAt, 'seconds': seconds};
  factory SnoozeCut.fromJson(Map<String, dynamic> j) => SnoozeCut(
        file: j['file'] as String,
        introSeconds: (j['introSeconds'] as num).toDouble(),
        resumeAt: (j['resumeAt'] as num).toDouble(),
        seconds: (j['seconds'] as num?)?.toDouble() ?? 0,
      );
}

/// Manifest of a generated show (`show.json` in its folder).
class Show {
  Show({
    required this.dirPath,
    required this.createdAt,
    required this.wakeAt,
    required this.onAirCity,
    required this.title,
    required this.blocks,
    required this.songs,
    required this.segments,
    required this.durationSeconds,
    required this.citations,
    required this.audioFile,
    required this.snoozes,
    required this.sunoCostUsd,
    required this.errors,
  });

  final String dirPath;
  final DateTime createdAt;
  final DateTime wakeAt;
  final String onAirCity;
  final String title;
  final List<Block> blocks;
  final List<Song> songs;
  final List<Segment> segments;
  final double durationSeconds;
  final List<Citation> citations;
  final String audioFile;
  final List<SnoozeCut> snoozes;
  final double sunoCostUsd;
  final List<String> errors;

  String get audioPath => '$dirPath/$audioFile';

  /// Cut to play for the [count]-th snooze (1-based); the last one repeats.
  SnoozeCut? snoozeCut(int count) =>
      snoozes.isEmpty ? null : snoozes[math.min(count, snoozes.length) - 1];

  Map<String, dynamic> toJson() => {
        'createdAt': createdAt.toIso8601String(),
        'wakeAt': wakeAt.toIso8601String(),
        'onAirCity': onAirCity,
        'title': title,
        'blocks': blocks,
        'songs': songs,
        'segments': segments,
        'durationSeconds': durationSeconds,
        'citations': citations,
        'audioFile': audioFile,
        'snoozes': snoozes,
        'sunoCostUsd': sunoCostUsd,
        'errors': errors,
      };

  /// Null when the folder has no manifest or one from an older app version.
  static Future<Show?> load(Directory dir) async {
    final file = File('${dir.path}/show.json');
    if (!await file.exists()) return null;
    try {
      final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return Show(
        dirPath: dir.path,
        createdAt: DateTime.parse(j['createdAt'] as String),
        wakeAt: DateTime.parse(j['wakeAt'] as String),
        onAirCity: j['onAirCity'] as String,
        title: j['title'] as String,
        blocks: [for (final b in j['blocks'] as List) Block.fromJson(b as Map<String, dynamic>)],
        songs: [for (final s in j['songs'] as List) Song.fromJson(s as Map<String, dynamic>)],
        segments: [
          for (final s in j['segments'] as List) Segment.fromJson(s as Map<String, dynamic>)
        ],
        durationSeconds: (j['durationSeconds'] as num).toDouble(),
        citations: [
          for (final c in j['citations'] as List) Citation.fromJson(c as Map<String, dynamic>)
        ],
        audioFile: j['audioFile'] as String,
        snoozes: [
          for (final s in j['snoozes'] as List) SnoozeCut.fromJson(s as Map<String, dynamic>)
        ],
        sunoCostUsd: (j['sunoCostUsd'] as num?)?.toDouble() ?? 0,
        errors: (j['errors'] as List).cast<String>(),
      );
    } on Object {
      return null;
    }
  }

  /// Most recent complete show under [rootDir], if any.
  static Future<Show?> latest(Directory rootDir) async {
    for (final d in await _showDirs(rootDir)) {
      final show = await Show.load(d);
      if (show != null) return show;
    }
    return null;
  }

  /// Keeps the [keep] newest show folders and deletes the rest.
  static Future<void> prune(Directory rootDir, {int keep = 3}) async {
    for (final d in (await _showDirs(rootDir)).skip(keep)) {
      await d.delete(recursive: true);
    }
  }

  static Future<List<Directory>> _showDirs(Directory rootDir) async {
    if (!await rootDir.exists()) return [];
    final dirs = await rootDir
        .list()
        .where((e) => e is Directory && e.path.contains('show-'))
        .cast<Directory>()
        .toList();
    return dirs..sort((a, b) => b.path.compareTo(a.path));
  }
}

const _weekdays = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
const _months = [
  'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
  'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
];

String frenchDate(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${d.year}';

String hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}h${d.minute.toString().padLeft(2, '0')}';
