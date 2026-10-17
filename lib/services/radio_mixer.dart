import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_pcm.dart';

/// One stretch of the show timeline, for the player UI.
class Segment {
  Segment({
    required this.kind,
    required this.start,
    required this.end,
    required this.label,
    this.block,
  });

  /// `talk`, `pub`, `song`, `jingle` or `signal`.
  final String kind;
  final double start;
  final double end;
  final String label;

  /// Index of the talk block this segment voices, for `talk` segments.
  final int? block;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'start': start,
        'end': end,
        'label': label,
        'block': block,
      };

  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
        kind: j['kind'] as String,
        start: (j['start'] as num).toDouble(),
        end: (j['end'] as num).toDouble(),
        label: j['label'] as String,
        block: j['block'] as int?,
      );
}

/// Lays the show out like a radio morning: station theme, hosts talking over
/// a ducked music bed, songs, jingles between sections. Sections are rendered
/// one at a time and streamed to [WavWriter] to keep memory bounded.
class RadioMixer {
  RadioMixer(this._out, {Clip? theme}) : _theme = theme; // ignore: prefer_initializing_formals

  /// Loudness targets (RMS) applied by the caller through [Clip.levelTo].
  static const voiceLevel = 0.14;
  static const musicLevel = 0.15;

  /// The station theme plays louder than songs when it is on its own.
  static const _themeGain = 1.35;
  static const _bedGain = 0.2;
  static const _themeLoopFade = 1.0;

  final WavWriter _out;
  final Clip? _theme;
  final segments = <Segment>[];

  double get position => _out.seconds;

  /// Hosts talking over the theme bed. The opening lets the theme play loud
  /// first; the closing brings it back up after the last word.
  Future<void> talk(
    Clip voice, {
    required int block,
    required String label,
    String kind = 'talk',
    bool opening = false,
    bool closing = false,
  }) async {
    final theme = _theme;
    final lead = opening && theme != null ? 5.0 : 0.4;
    final tail = closing && theme != null ? 6.0 : 0.6;
    final voiceStart = _frames(lead);
    final voiceEnd = voiceStart + voice.frames;
    final total = voiceEnd + _frames(tail);
    final buf = Float32List(total * 2);

    if (theme != null) {
      final duckStart = voiceStart - _frames(0.6);
      final upStart = voiceEnd + _frames(0.3);
      for (var i = 0; i < total; i++) {
        double g;
        if (opening && i < duckStart) {
          g = _themeGain;
        } else if (opening && i < voiceStart) {
          g = _lerp(_themeGain, _bedGain, (i - duckStart) / (voiceStart - duckStart));
        } else if (!opening && i < voiceStart) {
          g = _bedGain * i / voiceStart;
        } else if (i < upStart) {
          g = _bedGain;
        } else if (closing) {
          final t = (i - upStart) / mixRate;
          // Swell back to full, hold, then fade out over the last 2 s.
          g = t < 0.8 ? _lerp(_bedGain, _themeGain, t / 0.8) : _themeGain;
          final remaining = (total - i) / mixRate;
          if (remaining < 2.0) g *= remaining / 2.0;
        } else {
          g = _bedGain * (1 - (i - upStart) / (total - upStart));
        }
        final t = i + (opening ? 0 : _frames(6));
        buf[i * 2] += _themeSample(theme, t, 0) * g;
        buf[i * 2 + 1] += _themeSample(theme, t, 1) * g;
      }
    }
    for (var i = 0; i < voice.data.length; i++) {
      buf[voiceStart * 2 + i] += voice.data[i];
    }
    await _emit(buf, kind: kind, label: label, block: block);
  }

  /// A song, cut to [maxSeconds] with a fade-out when it is longer.
  Future<void> song(Clip song, {required String label, required double maxSeconds}) async {
    final truncated = song.seconds > maxSeconds;
    final frames = truncated ? _frames(maxSeconds) : song.frames;
    final fadeIn = _frames(0.03);
    final fadeOut = _frames(truncated ? 6.0 : 1.0);
    final buf = Float32List(frames * 2);
    for (var i = 0; i < frames; i++) {
      var g = 1.0;
      if (i < fadeIn) g = i / fadeIn;
      if (i > frames - fadeOut) g *= (frames - i) / fadeOut;
      buf[i * 2] = song.data[i * 2] * g;
      buf[i * 2 + 1] = song.data[i * 2 + 1] * g;
    }
    await _emit(buf, kind: 'song', label: label);
  }

  /// A short sting taken from the start of the theme.
  Future<void> jingle() async {
    final theme = _theme;
    if (theme == null) return;
    final frames = math.min(_frames(3.5), theme.frames);
    final fadeOut = _frames(1.2);
    final buf = Float32List(frames * 2);
    for (var i = 0; i < frames; i++) {
      final g = _themeGain * (i > frames - fadeOut ? (frames - i) / fadeOut : 1.0);
      buf[i * 2] = theme.data[i * 2] * g;
      buf[i * 2 + 1] = theme.data[i * 2 + 1] * g;
    }
    await _emit(buf, kind: 'jingle', label: 'Jingle');
  }

  /// Pirate signal locking on: filtered static sweeping open, a tuning
  /// whistle gliding down, then a short dropout before the theme hits.
  Future<void> signal({double seconds = 1.6, int seed = 7}) async {
    final rng = math.Random(seed);
    final frames = _frames(seconds);
    final buf = Float32List(frames * 2);
    var low = 0.0;
    var phase = 0.0;
    for (var i = 0; i < frames; i++) {
      final t = i / frames;
      // Low-pass opening up as the signal locks.
      final alpha = 0.04 + 0.6 * t * t;
      low += alpha * ((rng.nextDouble() * 2 - 1) - low);
      final flutter = 0.6 + 0.4 * math.sin(2 * math.pi * 13 * i / mixRate);
      final dropout = (i ~/ (mixRate * 0.07)) % 5 == 3 ? 0.15 : 1.0;
      phase += 2 * math.pi * (2200 - 1700 * t) / mixRate;
      final whistle = 0.16 * math.sin(phase) * (1 - t);
      var v = (low * 1.3 * flutter * dropout + whistle) * math.min(1.0, i / _frames(0.08));
      if (t > 0.9) v *= (1 - t) / 0.1;
      buf[i * 2] = v;
      buf[i * 2 + 1] = v * 0.9;
    }
    await _emit(buf, kind: 'signal', label: 'Signal');
  }

  Future<void> _emit(Float32List buf,
      {required String kind, required String label, int? block}) async {
    final start = position;
    await _out.write(buf);
    segments.add(Segment(kind: kind, start: start, end: position, label: label, block: block));
  }

  /// Theme sample for bed frame [i] and channel [c], looping with a
  /// crossfade so long talk sections never hit a hard cut.
  double _themeSample(Clip theme, int i, int c) {
    final fade = _frames(_themeLoopFade);
    final period = theme.frames - fade;
    if (period <= fade) return theme.data[(i % theme.frames) * 2 + c];
    final k = i % period;
    final head = theme.data[k * 2 + c];
    if (i < period || k >= fade) return head;
    // First second of a repeat: blend in from the clip's own tail.
    final w = k / fade;
    return head * w + theme.data[(k + period) * 2 + c] * (1 - w);
  }

  static int _frames(double seconds) => (seconds * mixRate).round();
  static double _lerp(double a, double b, double t) => a + (b - a) * t.clamp(0.0, 1.0);
}
