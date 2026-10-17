import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Sample rate of the mixed show; everything is converted to 44.1 kHz stereo.
const mixRate = 44100;

/// Turns a compressed file into raw interleaved 16-bit LE PCM at [output].
/// MediaCodec on the phone, ffmpeg in `tool/`.
typedef PcmDecoder = Future<({int sampleRate, int channels})> Function(
    String input, String output);

/// Compresses the mixed WAV at [input] to AAC at [output] (`.m4a`).
/// MediaCodec on the phone, ffmpeg in `tool/`.
typedef AudioEncoder = Future<void> Function(String input, String output);

/// Interleaved stereo float samples at [mixRate].
class Clip {
  Clip(this.data);
  final Float32List data;

  factory Clip.silence(double seconds) => Clip(Float32List((seconds * mixRate).round() * 2));

  /// Clips back to back, in order.
  factory Clip.concat(List<Clip> clips) {
    if (clips.length == 1) return clips.single;
    final data = Float32List(clips.fold(0, (n, c) => n + c.data.length));
    var offset = 0;
    for (final c in clips) {
      data.setAll(offset, c.data);
      offset += c.data.length;
    }
    return Clip(data);
  }

  int get frames => data.length >> 1;
  double get seconds => frames / mixRate;

  double rms() {
    if (data.isEmpty) return 0;
    var sum = 0.0;
    for (final s in data) {
      sum += s * s;
    }
    return math.sqrt(sum / data.length);
  }

  double peak() {
    var p = 0.0;
    for (final s in data) {
      final a = s.abs();
      if (a > p) p = a;
    }
    return p;
  }

  /// Warm tanh saturation in place: 0 leaves the clip clean, 1 is heavy grit.
  /// Loudness is restored afterwards by [levelTo].
  Clip saturate(double amount) {
    if (amount <= 0) return this;
    final drive = 1 + amount * 6;
    final norm = 1 / _tanh(drive);
    for (var i = 0; i < data.length; i++) {
      data[i] = _tanh(data[i] * drive) * norm;
    }
    return this;
  }

  static double _tanh(double x) {
    if (x > 10) return 1;
    if (x < -10) return -1;
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }

  /// Scales in place towards an RMS level of [target], without letting the
  /// loudest sample exceed [maxPeak].
  Clip levelTo(double target, {double maxPeak = 0.89}) {
    final r = rms();
    if (r < 1e-5) return this;
    final g = math.min(target / r, maxPeak / peak());
    for (var i = 0; i < data.length; i++) {
      data[i] *= g;
    }
    return this;
  }
}

/// Loads [path] (WAV directly, anything else through [decode]) as a [Clip],
/// keeping at most [maxSeconds] of it.
Future<Clip> loadClip(String path, PcmDecoder decode, {double? maxSeconds}) async {
  final wav = await _readWavHeader(path);
  String pcmPath;
  int dataOffset, dataLength, rate, channels;
  if (wav != null) {
    pcmPath = path;
    (dataOffset, dataLength, rate, channels) = wav;
  } else {
    pcmPath = '$path.pcm';
    final info = await decode(path, pcmPath);
    dataOffset = 0;
    dataLength = await File(pcmPath).length();
    rate = info.sampleRate;
    channels = info.channels;
  }

  final bytesPerFrame = 2 * channels;
  var length = dataLength - dataLength % bytesPerFrame;
  if (maxSeconds != null) {
    length = math.min(length, (maxSeconds * rate).ceil() * bytesPerFrame);
  }
  final raf = await File(pcmPath).open();
  final bytes = Uint8List(length);
  try {
    await raf.setPosition(dataOffset);
    await raf.readInto(bytes);
  } finally {
    await raf.close();
  }
  if (wav == null) await File(pcmPath).delete();
  return Clip(_toStereoMixRate(Int16List.view(bytes.buffer), rate, channels));
}

/// Returns (data offset, data length, sample rate, channels) for 16-bit PCM
/// WAV files, or null when [path] is not one.
Future<(int, int, int, int)?> _readWavHeader(String path) async {
  final raf = await File(path).open();
  try {
    final head = await raf.read(4096);
    if (head.length < 12 ||
        String.fromCharCodes(head, 0, 4) != 'RIFF' ||
        String.fromCharCodes(head, 8, 12) != 'WAVE') {
      return null;
    }
    final bd = ByteData.sublistView(head);
    int? rate, channels;
    var offset = 12;
    while (offset + 8 <= head.length) {
      final id = String.fromCharCodes(head, offset, offset + 4);
      final size = bd.getUint32(offset + 4, Endian.little);
      if (id == 'fmt ') {
        channels = bd.getUint16(offset + 10, Endian.little);
        rate = bd.getUint32(offset + 12, Endian.little);
        if (bd.getUint16(offset + 22, Endian.little) != 16) return null;
      } else if (id == 'data' && rate != null) {
        final available = (await raf.length()) - offset - 8;
        return (offset + 8, math.min(size, available), rate, channels!);
      }
      offset += 8 + size + (size & 1);
    }
    return null;
  } finally {
    await raf.close();
  }
}

/// Linear-interpolation resampler and channel mapper.
Float32List _toStereoMixRate(Int16List pcm, int rate, int channels) {
  final srcFrames = pcm.length ~/ channels;
  final ratio = rate / mixRate;
  final outFrames = (srcFrames / ratio).floor();
  final out = Float32List(outFrames * 2);
  const scale = 1 / 32768;
  for (var i = 0; i < outFrames; i++) {
    final pos = i * ratio;
    final i0 = pos.floor();
    final i1 = math.min(i0 + 1, srcFrames - 1);
    final frac = pos - i0;
    for (var c = 0; c < 2; c++) {
      final ch = c < channels ? c : 0;
      final a = pcm[i0 * channels + ch];
      final b = pcm[i1 * channels + ch];
      out[i * 2 + c] = (a + (b - a) * frac) * scale;
    }
  }
  return out;
}

/// Streams 16-bit stereo [mixRate] audio to a WAV file, section by section.
class WavWriter {
  WavWriter._(this._file);

  final RandomAccessFile _file;
  int _dataBytes = 0;

  static Future<WavWriter> open(String path) async {
    final file = await File(path).open(mode: FileMode.write);
    await file.writeFrom(Uint8List(44)); // header patched in close()
    return WavWriter._(file);
  }

  double get seconds => _dataBytes / 4 / mixRate;

  Future<void> write(Float32List stereo) async {
    final out = Int16List(stereo.length);
    for (var i = 0; i < stereo.length; i++) {
      out[i] = (_softClip(stereo[i]) * 32767).round();
    }
    await _file.writeFrom(out.buffer.asUint8List());
    _dataBytes += out.lengthInBytes;
  }

  /// Copies the audio between [from] and [to] seconds of a WAV written by
  /// this class (canonical 44-byte header, same format) onto the end.
  Future<void> appendWavRange(String path, double from, [double? to]) async {
    final src = await File(path).open();
    try {
      final total = (await src.length()) - 44;
      final start = math.min((from * mixRate).round() * 4, total);
      final end = to == null ? total : math.min((to * mixRate).round() * 4, total);
      await src.setPosition(44 + start);
      var remaining = end - start;
      while (remaining > 0) {
        final chunk = await src.read(math.min(remaining, 1 << 20));
        if (chunk.isEmpty) break;
        await _file.writeFrom(chunk);
        _dataBytes += chunk.length;
        remaining -= chunk.length;
      }
    } finally {
      await src.close();
    }
  }

  Future<void> close() async {
    final h = ByteData(44);
    void ascii(int o, String s) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    h.setUint32(4, 36 + _dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 2, Endian.little);
    h.setUint32(24, mixRate, Endian.little);
    h.setUint32(28, mixRate * 4, Endian.little);
    h.setUint16(32, 4, Endian.little);
    h.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    h.setUint32(40, _dataBytes, Endian.little);
    await _file.setPosition(0);
    await _file.writeFrom(h.buffer.asUint8List());
    await _file.close();
  }

  /// Transparent below 0.9, then bends smoothly towards 1.0 instead of clipping.
  static double _softClip(double x) {
    final a = x.abs();
    if (a <= 0.9) return x;
    final bent = 0.9 + 0.1 * _tanh((a - 0.9) / 0.1);
    return x < 0 ? -bent : bent;
  }

  static double _tanh(double x) {
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }
}
