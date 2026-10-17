import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';

import 'scheduler.dart';
import 'screens/home_screen.dart';
import 'screens/ring_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Alarm.init();
  await AndroidAlarmManager.initialize();
  await Scheduler.installFallbackRing();
  runApp(const SnoozeApp());
}

class SnoozeApp extends StatefulWidget {
  const SnoozeApp({super.key});

  @override
  State<SnoozeApp> createState() => _SnoozeAppState();
}

class _SnoozeAppState extends State<SnoozeApp> {
  final _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<AlarmSet>? _ringing;
  bool _ringScreenOpen = false;

  @override
  void initState() {
    super.initState();
    // The full-screen intent launches the app while the alarm rings.
    // Alarm.ringing replays its current value on listen, before the navigator
    // exists, so the push waits for a frame.
    _ringing = Alarm.ringing.listen((set) {
      if (set.alarms.isEmpty) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = _navigator.currentState;
        if (navigator == null || _ringScreenOpen) return;
        _ringScreenOpen = true;
        navigator
            .push(MaterialPageRoute<void>(
              builder: (_) => RingScreen(alarm: set.alarms.first),
            ))
            .whenComplete(() => _ringScreenOpen = false);
      });
      WidgetsBinding.instance.scheduleFrame();
    });
    Scheduler.rearm();
  }

  @override
  void dispose() {
    _ringing?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Radio CHROME: neon magenta and cyan on near-black.
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF2BD6),
      brightness: Brightness.dark,
    ).copyWith(
      primary: const Color(0xFFFF4FD8),
      tertiary: const Color(0xFF3DF5FF),
      surface: const Color(0xFF0B0714),
    );
    return MaterialApp(
      title: 'Radio CHROME',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}
