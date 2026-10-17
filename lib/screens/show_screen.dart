import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../scheduler.dart';
import '../services/radio_mixer.dart';
import '../services/show_generator.dart';
import '../widgets/audio_output_chip.dart';

/// Plays the mixed show like a radio: rundown with the current segment
/// highlighted, and the transcript of what the hosts are saying.
class ShowScreen extends StatefulWidget {
  const ShowScreen({super.key, this.autoplay = false, this.startAt});

  final bool autoplay;

  /// Where to resume, when taking over from the ringing alarm.
  final Duration? startAt;

  @override
  State<ShowScreen> createState() => _ShowScreenState();
}

class _ShowScreenState extends State<ShowScreen> {
  final _player = AudioPlayer();
  Show? _show;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      final show = await Show.latest(await Scheduler.showsRoot());
      if (show != null) {
        await _player.setAudioSource(AudioSource.file(show.audioPath),
            initialPosition: widget.startAt);
        if (widget.autoplay) unawaited(_player.play());
      }
      setState(() {
        _show = show;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  /// Sends the show through Android's share sheet, under a readable name.
  Future<void> _share(Show show) async {
    final safeTitle = show.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final copy = File('${(await getTemporaryDirectory()).path}/Radio CHROME - $safeTitle.m4a');
    await File(show.audioPath).copy(copy.path);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(copy.path, mimeType: 'audio/mp4')],
      text: 'Radio CHROME, en direct de ${show.onAirCity} : « ${show.title} » 📻⚡',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final show = _show;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio CHROME'),
        actions: [
          if (show != null)
            IconButton(
              tooltip: "Partager l'émission",
              icon: const Icon(Icons.share),
              onPressed: () => _share(show),
            ),
          const AudioOutputChip(),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : show == null
              ? Center(child: Text(_error ?? 'Aucune émission générée pour l\'instant.'))
              : StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (context, snap) => _ShowBody(
                    show: show,
                    player: _player,
                    position: (snap.data ?? Duration.zero).inMilliseconds / 1000,
                  ),
                ),
    );
  }
}

class _ShowBody extends StatelessWidget {
  const _ShowBody({required this.show, required this.player, required this.position});

  final Show show;
  final AudioPlayer player;
  final double position;

  Segment? get _current {
    for (final s in show.segments) {
      if (position >= s.start && position < s.end) return s;
    }
    return null;
  }

  /// Talk block on air, or the last one heard during songs and jingles.
  int? get _block {
    int? block;
    for (final s in show.segments) {
      if (s.start > position) break;
      if (s.block != null && s.block! >= 0) block = s.block;
    }
    return block;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _current;
    final block = _block;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(show.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${show.onAirCity} · ${_isToday(show.wakeAt) ? 'ce matin' : frenchDate(show.wakeAt)}'
          ' · ${(show.durationSeconds / 60).round()} min',
          style: theme.textTheme.bodySmall,
        ),
        for (final e in show.errors)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(e, style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
          ),
        const SizedBox(height: 16),
        _Transport(player: player, position: position, duration: show.durationSeconds),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              for (final s in show.segments)
                if (s.kind == 'talk' || s.kind == 'pub' || s.kind == 'song')
                  ListTile(
                    dense: true,
                    selected: identical(s, current),
                    leading: Icon(switch (s.kind) {
                      'song' => Icons.music_note,
                      'pub' => Icons.campaign_outlined,
                      _ => Icons.mic_none,
                    }),
                    title: Text(s.label.isEmpty ? (s.kind == 'song' ? 'Morceau' : 'Antenne') : s.label),
                    trailing: Text(_mmss(s.start)),
                    onTap: () => player.seek(Duration(milliseconds: (s.start * 1000).round())),
                  ),
            ],
          ),
        ),
        if (block != null && block < show.blocks.length) ...[
          const SizedBox(height: 16),
          Text(show.blocks[block].topic, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final line in show.blocks[block].lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Text.rich(TextSpan(children: [
                TextSpan(
                  text: '${line.host}  ',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: switch (line.speaker) {
                      'A' => theme.colorScheme.primary,
                      'B' => theme.colorScheme.tertiary,
                      _ => theme.colorScheme.outline,
                    },
                  ),
                ),
                TextSpan(text: line.text),
              ])),
            ),
        ],
        if (show.citations.isNotEmpty) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Sources (${show.citations.length})'),
            children: [
              for (final c in show.citations)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link, size: 18),
                  title: Text(Uri.tryParse(c.url)?.host ?? c.url),
                  subtitle: Text(c.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ],
      ],
    );
  }

  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.player, required this.position, required this.duration});

  final AudioPlayer player;
  final double position;
  final double duration;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
        child: Row(
          children: [
            StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, snap) {
                final state = snap.data;
                final done = state?.processingState == ProcessingState.completed;
                final playing = (state?.playing ?? false) && !done;
                return IconButton.filled(
                  iconSize: 36,
                  icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                  onPressed: () async {
                    if (playing) return player.pause();
                    if (done) await player.seek(Duration.zero);
                    await player.play();
                  },
                );
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: duration <= 0 ? 0 : (position / duration).clamp(0.0, 1.0),
                  ),
                  const SizedBox(height: 6),
                  Text('${_mmss(position)} / ${_mmss(duration)}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _mmss(double s) =>
    '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).floor().toString().padLeft(2, '0')}';
