import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:alarm/alarm.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:audio_codec/audio_codec.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app_store.dart';
import 'services/apimart_suno.dart';
import 'services/openrouter.dart';
import 'services/show_generator.dart';

/// Arms the alarms and the pre-wake generation jobs.
///
/// Every alarm plays a fixed file under `ring/`: `current` for the show,
/// `snooze_1`/`snooze_2` for the versions opening with a roast. Generation
/// overwrites them, so nothing has to be re-armed from the background, and if
/// generation never runs the alarm still plays the previous show or the
/// bundled fallback ring. The files have no extension because they hold
/// either AAC or MP3; Android's players detect the format from the content.
class Scheduler {
  /// Alarm ids 1..7 are the weekday alarms, [snoozeAlarmId] snoozes and tests.
  static const snoozeAlarmId = 50;
  static const _generationJobBase = 100;
  static const _retryJobId = 150;
  static const snoozeDuration = Duration(minutes: 9);

  static Future<String> _docs() async => (await getApplicationDocumentsDirectory()).path;

  static Future<Directory?> _debugDir() async {
    final external = await getExternalStorageDirectory();
    return external == null ? null : Directory('${external.path}/debug');
  }

  static Future<Directory> showsRoot() async => Directory('${await _docs()}/shows');

  static Future<File> _ringFile([String name = 'current']) async => File('${await _docs()}/ring/$name');

  static Future<File> _fallbackFile() async => File('${await _docs()}/ring/fallback.mp3');

  /// Copies the bundled ring out of the assets so both isolates can use it.
  static Future<void> installFallbackRing() async {
    final fallback = await _fallbackFile();
    if (!await fallback.exists()) {
      await fallback.parent.create(recursive: true);
      final data = await rootBundle.load('assets/audio/fallback_ring.mp3');
      await fallback.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    final ring = await _ringFile();
    if (!await ring.exists()) await fallback.copy(ring.path);
  }

  static Future<void> _installRing(Show show) async {
    Future<void> install(String source, String name) async {
      final ring = await _ringFile(name);
      final tmp = File('${ring.path}.tmp');
      await File(source).copy(tmp.path);
      await tmp.rename(ring.path);
    }

    await install(show.audioPath, 'current');
    for (var k = 1; k <= ShowGenerator.snoozeVariants; k++) {
      final cut = show.snoozeCut(k);
      if (cut != null) {
        await install('${show.dirPath}/${cut.file}', 'snooze_$k');
      } else {
        final stale = await _ringFile('snooze_$k');
        if (await stale.exists()) await stale.delete();
      }
    }
  }

  /// Re-arms everything from the saved plan, in the phone's current time
  /// zone (so it also fixes alarms after a trip). Leaves a ringing alarm alone.
  static Future<void> rearm() async {
    final plan = await AppStore.loadPlan();
    final now = DateTime.now();
    final upcoming = {for (final d in plan.enabled ? plan.upcoming(now) : <DateTime>[]) d.weekday: d};

    for (var weekday = 1; weekday <= 7; weekday++) {
      await AndroidAlarmManager.cancel(_generationJobBase + weekday);
      final ringAt = upcoming[weekday];
      if (ringAt == null) {
        if (!await Alarm.isRinging(weekday)) await Alarm.stop(weekday);
        continue;
      }
      if (await Alarm.isRinging(weekday)) continue;

      await Alarm.set(alarmSettings: await _alarmSettings(weekday, ringAt));
      final generateAt = ringAt.subtract(Duration(minutes: plan.leadMinutes));
      if (generateAt.isAfter(now)) {
        await AndroidAlarmManager.oneShotAt(
          generateAt,
          _generationJobBase + weekday,
          generationJob,
          exact: true,
          wakeup: true,
          allowWhileIdle: true,
          rescheduleOnReboot: true,
        );
      }
    }
  }

  /// Silences [ringing] and brings the radio back in [snoozeDuration], opening
  /// with the hosts roasting the listener (harsher from the second snooze).
  static Future<void> snooze(AlarmSettings ringing) async {
    final count = await AppStore.loadSnoozeCount() + 1;
    await AppStore.saveSnoozeCount(count);
    await Alarm.stop(ringing.id);
    final cut = await _ringFile('snooze_${math.min(count, ShowGenerator.snoozeVariants)}');
    await Alarm.set(
      alarmSettings: await _alarmSettings(
        snoozeAlarmId,
        DateTime.now().add(snoozeDuration),
        audio: await cut.exists() ? cut : null,
        payload: 'snooze:$count',
      ),
    );
  }

  /// The listener is up: the next snooze starts counting from zero again.
  static Future<void> resetSnoozes() => AppStore.saveSnoozeCount(0);

  /// Which snooze an alarm replays (0 for a normal ring), from its payload.
  static int snoozeNumber(AlarmSettings alarm) {
    final payload = alarm.payload ?? '';
    return payload.startsWith('snooze:') ? int.tryParse(payload.substring(7)) ?? 0 : 0;
  }

  /// Rings once in [delay], to check sound, volume and Bluetooth routing.
  static Future<void> testRing({Duration delay = const Duration(seconds: 10)}) async =>
      Alarm.set(
        alarmSettings: await _alarmSettings(snoozeAlarmId, DateTime.now().add(delay)),
      );

  static Future<AlarmSettings> _alarmSettings(
    int id,
    DateTime at, {
    File? audio,
    String? payload,
  }) async =>
      AlarmSettings(
        id: id,
        dateTime: at,
        assetAudioPath: (audio ?? await _ringFile()).path,
        payload: payload,
        // The show replays until the user gets up.
        loopAudio: true,
        vibrate: false,
        // Bluetooth speaker or headphones when connected, phone speaker otherwise.
        preferConnectedAudioDevice: true,
        androidFullScreenIntent: true,
        warningNotificationOnKill: true,
        // No snooze in the notification: snoozing goes through the ring screen,
        // which picks the roast version and counts snoozes.
        volumeSettings: VolumeSettings.fade(
          volume: 0.9,
          fadeDuration: const Duration(seconds: 6),
        ),
        notificationSettings: const NotificationSettings(
          title: 'Radio CHROME',
          body: 'En direct. Debout !',
          stopButton: 'Couper la radio',
        ),
      );

  /// Generates the show for the next ring and installs it as the ring.
  /// Runs in the UI isolate ("Préparer maintenant") or the background job.
  static Future<Show> generateForNextAlarm({void Function(String)? onProgress}) async {
    final apiKey = await AppStore.loadApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('Clé OpenRouter manquante (Réglages)');
    }
    final sunoKey = await AppStore.loadSunoKey();
    final plan = await AppStore.loadPlan();
    final next = plan.upcoming(DateTime.now());
    final wakeAt = next.isNotEmpty ? next.first : DateTime.now();

    final client = OpenRouterClient(apiKey);
    final suno = sunoKey == null || sunoKey.isEmpty ? null : ApimartSuno(sunoKey);
    try {
      final root = await showsRoot();
      final docs = await _docs();
      final show = await ShowGenerator(
        client: client,
        config: await AppStore.loadConfig(),
        decode: AudioCodec.decodeToPcm,
        encode: AudioCodec.encodeWavToAac,
        stationDir: Directory('$docs/station'),
        libraryDir: Directory('$docs/library'),
        suno: suno,
        // Android/data/<app>/files/debug: readable over adb, unlike app documents.
        debugDir: await _debugDir(),
      ).generate(rootDir: root, wakeAt: wakeAt, onProgress: onProgress);
      await _installRing(show);
      await resetSnoozes();
      await Show.prune(root);
      await AppStore.saveStatus(GenerationStatus(
        at: DateTime.now(),
        ok: show.errors.isEmpty,
        message: show.errors.join('\n'),
      ));
      return show;
    } catch (e) {
      await AppStore.saveStatus(GenerationStatus(at: DateTime.now(), ok: false, message: '$e'));
      rethrow;
    } finally {
      client.close();
      suno?.close();
    }
  }
}

/// Entry point of the background generation job (android_alarm_manager_plus).
/// On failure it retries every 5 minutes while there is time before the ring.
@pragma('vm:entry-point')
Future<void> generationJob() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    await Scheduler.generateForNextAlarm();
  } catch (_) {
    final next = (await AppStore.loadPlan()).upcoming(DateTime.now());
    final retryAt = DateTime.now().add(const Duration(minutes: 5));
    if (next.isNotEmpty && retryAt.isBefore(next.first.subtract(const Duration(minutes: 2)))) {
      await AndroidAlarmManager.oneShotAt(
        retryAt,
        Scheduler._retryJobId,
        generationJob,
        exact: true,
        wakeup: true,
        allowWhileIdle: true,
      );
    }
  }
}
