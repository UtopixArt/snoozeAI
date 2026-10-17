import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'station.dart';

class LibrarySong {
  LibrarySong({
    required this.id,
    required this.file,
    required this.title,
    required this.preset,
    required this.addedAt,
    this.lastPlayed,
    this.plays = 0,
  });

  final String id;

  /// File name inside the library folder.
  final String file;
  final String title;
  final String preset;
  final DateTime addedAt;
  DateTime? lastPlayed;
  int plays;

  int get energy => presetById(preset).energy;

  Map<String, dynamic> toJson() => {
        'id': id,
        'file': file,
        'title': title,
        'preset': preset,
        'addedAt': addedAt.toIso8601String(),
        'lastPlayed': lastPlayed?.toIso8601String(),
        'plays': plays,
      };

  factory LibrarySong.fromJson(Map<String, dynamic> j) => LibrarySong(
        id: j['id'] as String,
        file: j['file'] as String,
        title: j['title'] as String,
        preset: j['preset'] as String,
        addedAt: DateTime.parse(j['addedAt'] as String),
        lastPlayed: j['lastPlayed'] == null ? null : DateTime.parse(j['lastPlayed'] as String),
        plays: j['plays'] as int? ?? 0,
      );
}

/// The station's playlist: every generated song is kept and rotated, so only
/// one or two new songs have to be paid for each morning.
class MusicLibrary {
  MusicLibrary._(this.dir, this.songs, this.recentPresets);

  final Directory dir;
  final List<LibrarySong> songs;

  /// Presets of the latest new generations, most recent first.
  final List<String> recentPresets;

  static const maxSongs = 60;

  File get _index => File('${dir.path}/library.json');

  String pathOf(LibrarySong s) => '${dir.path}/${s.file}';

  static Future<MusicLibrary> open(Directory dir) async {
    await dir.create(recursive: true);
    final index = File('${dir.path}/library.json');
    final library = await index.exists()
        ? () async {
            final j = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
            return MusicLibrary._(
              dir,
              [for (final s in j['songs'] as List) LibrarySong.fromJson(s as Map<String, dynamic>)],
              (j['recentPresets'] as List? ?? const []).cast<String>(),
            );
          }()
        : Future.value(MusicLibrary._(dir, [], []));
    return (await library).._adoptOrphans();
  }

  /// Songs whose index entry was lost (a run that died before saving) are
  /// paid for, so they rejoin the rotation as untitled pirate tracks.
  void _adoptOrphans() {
    final known = {for (final s in songs) s.file};
    var n = songs.where((s) => s.title.startsWith('Piste pirate')).length;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      if (!name.endsWith('.mp3') || known.contains(name)) continue;
      songs.add(LibrarySong(
        id: name.substring(0, name.length - 4),
        file: name,
        title: 'Piste pirate ${++n}',
        preset: 'techno',
        addedAt: f.statSync().modified,
      ));
    }
  }

  Future<void> save() async {
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ')
        .convert({'songs': songs, 'recentPresets': recentPresets}));
    await tmp.rename(_index.path);
  }

  /// Presets for today's new generations: ones not heard lately, and the
  /// hardest preset when the library has nothing to end the show on.
  List<MusicPreset> choosePresets(int count, {math.Random? random}) {
    final rng = random ?? math.Random();
    final chosen = <MusicPreset>[];
    if (!songs.any((s) => s.energy >= 5)) chosen.add(musicPresets.last);
    final fresh = musicPresets
        .where((p) => !recentPresets.take(3).contains(p.id) && !chosen.contains(p))
        .toList()
      ..shuffle(rng);
    final rest = musicPresets.where((p) => !chosen.contains(p) && !fresh.contains(p)).toList()
      ..shuffle(rng);
    for (final p in [...fresh, ...rest]) {
      if (chosen.length >= count) break;
      chosen.add(p);
    }
    return chosen.take(count).toList();
  }

  /// How many Suno generations (2 songs each) today's show needs.
  int generationsNeeded(int songCount) {
    final playable = _rotation(DateTime.now()).length;
    if (playable >= songCount) return 1;
    return ((songCount - playable) / 2).ceil().clamp(1, 3);
  }

  /// Library songs for [count] slots, least recently played first.
  List<LibrarySong> pick(int count, {Set<String> exclude = const {}}) {
    final pool = _rotation(DateTime.now()).where((s) => !exclude.contains(s.id)).toList();
    return pool.take(count).toList();
  }

  /// Songs not played in the last 3 days, oldest play first.
  List<LibrarySong> _rotation(DateTime now) {
    final cutoff = now.subtract(const Duration(days: 3));
    final pool = songs.where((s) => s.lastPlayed == null || s.lastPlayed!.isBefore(cutoff)).toList()
      ..sort((a, b) => (a.lastPlayed ?? DateTime(2000)).compareTo(b.lastPlayed ?? DateTime(2000)));
    return pool;
  }

  /// Moves a freshly generated file into the library.
  Future<LibrarySong> add(String path, {required String title, required String preset}) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}_${songs.length}';
    final file = '$id.mp3';
    await File(path).copy('${dir.path}/$file');
    final song = LibrarySong(
      id: id,
      file: file,
      title: title.isEmpty ? 'Sans titre' : title,
      preset: preset,
      addedAt: DateTime.now(),
    );
    songs.add(song);
    return song;
  }

  void notePresetGenerated(String preset) {
    recentPresets
      ..remove(preset)
      ..insert(0, preset);
    if (recentPresets.length > 10) recentPresets.removeRange(10, recentPresets.length);
  }

  void markPlayed(Iterable<LibrarySong> played, DateTime at) {
    for (final s in played) {
      s.lastPlayed = at;
      s.plays++;
    }
  }

  /// Drops the most played songs once the library is full (~4 MB per song).
  Future<void> prune() async {
    if (songs.length <= maxSongs) return;
    final byWear = [...songs]..sort((a, b) => b.plays.compareTo(a.plays));
    for (final s in byWear.take(songs.length - maxSongs)) {
      songs.remove(s);
      final f = File(pathOf(s));
      if (await f.exists()) await f.delete();
    }
  }
}
