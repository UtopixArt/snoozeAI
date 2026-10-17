# audio_codec

Local plugin used by snoozeAI, built on Android `MediaExtractor` / `MediaCodec` / `MediaMuxer`:

- `decodeToPcm`: any format Android reads (MP3, AAC...) to raw 16-bit LE PCM, so the show can be mixed in Dart.
- `encodeWavToAac`: the mixed 16-bit WAV to an AAC `.m4a`, ~10x smaller.

Registered as a plugin so it also works in the background engine that prepares the show.
