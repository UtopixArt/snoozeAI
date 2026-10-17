package com.snoozeai.audio_codec;

import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Audio file conversions for the show mixer, on a worker thread:
 * decode anything to raw 16-bit PCM, and encode the mixed WAV to AAC.
 * Registered as a plugin (not in MainActivity) so it also exists in the
 * background engine that generates the show before the alarm.
 */
public class AudioCodecPlugin implements FlutterPlugin, MethodCallHandler {
  private static final long TIMEOUT_US = 10_000;

  private MethodChannel channel;
  private ExecutorService executor;
  private final Handler mainThread = new Handler(Looper.getMainLooper());

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    channel = new MethodChannel(binding.getBinaryMessenger(), "snoozeai/audio_codec");
    channel.setMethodCallHandler(this);
    executor = Executors.newSingleThreadExecutor();
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    executor.shutdown();
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    final String input = call.argument("input");
    final String output = call.argument("output");
    switch (call.method) {
      case "decodeToPcm":
        run(result, () -> decode(input, output));
        break;
      case "encodeWavToAac":
        final Integer bitrate = call.argument("bitrate");
        run(result, () -> {
          encode(input, output, bitrate == null ? 128_000 : bitrate);
          return null;
        });
        break;
      default:
        result.notImplemented();
    }
  }

  private void run(Result result, Callable<Object> job) {
    executor.execute(() -> {
      try {
        Object value = job.call();
        mainThread.post(() -> result.success(value));
      } catch (Exception e) {
        mainThread.post(() -> result.error("CODEC_FAILED", e.toString(), null));
      }
    });
  }

  private static Map<String, Object> decode(String input, String output) throws IOException {
    MediaExtractor extractor = new MediaExtractor();
    MediaCodec codec = null;
    try (OutputStream out = new BufferedOutputStream(new FileOutputStream(output), 1 << 16)) {
      extractor.setDataSource(input);
      MediaFormat format = null;
      for (int i = 0; i < extractor.getTrackCount(); i++) {
        MediaFormat f = extractor.getTrackFormat(i);
        String mime = f.getString(MediaFormat.KEY_MIME);
        if (mime != null && mime.startsWith("audio/")) {
          extractor.selectTrack(i);
          format = f;
          break;
        }
      }
      if (format == null) throw new IOException("No audio track in " + input);

      int sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
      int channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
      codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME));
      codec.configure(format, null, null, 0);
      codec.start();

      MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      byte[] chunk = new byte[0];
      boolean inputDone = false;
      boolean outputDone = false;
      // Same non-blocking pump as encode(): only wait when nothing moved.
      while (!outputDone) {
        boolean progressed = false;
        while (!inputDone) {
          int in = codec.dequeueInputBuffer(0);
          if (in < 0) break;
          ByteBuffer buffer = codec.getInputBuffer(in);
          int size = extractor.readSampleData(buffer, 0);
          if (size < 0) {
            codec.queueInputBuffer(in, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            inputDone = true;
          } else {
            codec.queueInputBuffer(in, 0, size, extractor.getSampleTime(), 0);
            extractor.advance();
          }
          progressed = true;
        }

        long wait = progressed ? 0 : TIMEOUT_US;
        while (true) {
          int outIndex = codec.dequeueOutputBuffer(info, wait);
          wait = 0;
          if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) break;
          if (outIndex >= 0) {
            ByteBuffer buffer = codec.getOutputBuffer(outIndex);
            if (buffer != null && info.size > 0) {
              if (chunk.length < info.size) chunk = new byte[info.size];
              buffer.position(info.offset);
              buffer.get(chunk, 0, info.size);
              out.write(chunk, 0, info.size);
            }
            codec.releaseOutputBuffer(outIndex, false);
            if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
              outputDone = true;
              break;
            }
          } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            MediaFormat outFormat = codec.getOutputFormat();
            sampleRate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE);
            channels = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
            if (outFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)
                && outFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) != AudioFormat.ENCODING_PCM_16BIT) {
              throw new IOException("Unsupported PCM encoding from decoder");
            }
          }
        }
      }

      Map<String, Object> result = new HashMap<>();
      result.put("sampleRate", sampleRate);
      result.put("channels", channels);
      return result;
    } finally {
      release(codec);
      extractor.release();
    }
  }

  /** Encodes a canonical 44-byte-header 16-bit PCM WAV (as written by the mixer) to AAC-LC in MP4. */
  private static void encode(String input, String output, int bitrate) throws IOException {
    MediaCodec codec = null;
    MediaMuxer muxer = null;
    try (InputStream in = new BufferedInputStream(new FileInputStream(input), 1 << 16)) {
      byte[] header = new byte[44];
      new DataInputStream(in).readFully(header);
      ByteBuffer h = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN);
      int channels = h.getShort(22);
      int sampleRate = h.getInt(24);
      int bytesPerFrame = 2 * channels;

      MediaFormat format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channels);
      format.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
      format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
      format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1 << 16);
      codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
      codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
      codec.start();
      muxer = new MediaMuxer(output, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

      MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      byte[] chunk = new byte[1 << 16];
      long framesRead = 0;
      int track = -1;
      boolean inputDone = false;
      boolean outputDone = false;
      // Never sleep while the codec has work: fill every free input buffer and
      // drain every ready output without waiting, and only block briefly when
      // neither side moved (waiting 10 ms per chunk made a show take minutes).
      while (!outputDone) {
        boolean progressed = false;
        while (!inputDone) {
          int inIndex = codec.dequeueInputBuffer(0);
          if (inIndex < 0) break;
          ByteBuffer buffer = codec.getInputBuffer(inIndex);
          int want = Math.min(buffer.capacity(), chunk.length);
          want -= want % bytesPerFrame;
          int read = readFully(in, chunk, want);
          long pts = framesRead * 1_000_000L / sampleRate;
          if (read <= 0) {
            codec.queueInputBuffer(inIndex, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
            inputDone = true;
          } else {
            buffer.clear();
            buffer.put(chunk, 0, read);
            codec.queueInputBuffer(inIndex, 0, read, pts, 0);
            framesRead += read / bytesPerFrame;
          }
          progressed = true;
        }

        long wait = progressed ? 0 : TIMEOUT_US;
        while (true) {
          int outIndex = codec.dequeueOutputBuffer(info, wait);
          wait = 0;
          if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) break;
          if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            track = muxer.addTrack(codec.getOutputFormat());
            muxer.start();
          } else if (outIndex >= 0) {
            ByteBuffer buffer = codec.getOutputBuffer(outIndex);
            boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
            if (buffer != null && info.size > 0 && !config && track >= 0) {
              buffer.position(info.offset);
              buffer.limit(info.offset + info.size);
              muxer.writeSampleData(track, buffer, info);
            }
            codec.releaseOutputBuffer(outIndex, false);
            if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
              outputDone = true;
              break;
            }
          }
        }
      }
      muxer.stop();
    } finally {
      release(codec);
      if (muxer != null) muxer.release();
    }
  }

  private static int readFully(InputStream in, byte[] buffer, int length) throws IOException {
    int total = 0;
    while (total < length) {
      int n = in.read(buffer, total, length - total);
      if (n < 0) break;
      total += n;
    }
    return total;
  }

  private static void release(MediaCodec codec) {
    if (codec == null) return;
    try {
      codec.stop();
    } catch (IllegalStateException ignored) {
    }
    codec.release();
  }
}
