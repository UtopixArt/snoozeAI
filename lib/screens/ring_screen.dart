import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/utils/alarm_set.dart';
import 'package:flutter/material.dart';

import '../scheduler.dart';
import '../services/show_generator.dart';
import 'show_screen.dart';

/// Shown over the lock screen while the alarm music plays.
class RingScreen extends StatefulWidget {
  const RingScreen({super.key, required this.alarm});

  final AlarmSettings alarm;

  @override
  State<RingScreen> createState() => _RingScreenState();
}

class _RingScreenState extends State<RingScreen> {
  Show? _show;
  StreamSubscription<AlarmSet>? _ringing;
  late final Timer _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    Scheduler.showsRoot().then(Show.latest).then((s) {
      if (mounted) setState(() => _show = s);
    });
    _clock = Timer.periodic(const Duration(seconds: 15), (_) {
      setState(() => _now = DateTime.now());
    });
    // Stopped or snoozed from the notification: leave this screen.
    _ringing = Alarm.ringing.listen((set) {
      if (!set.containsId(widget.alarm.id) && mounted) {
        Navigator.of(context).maybePop();
      }
    });
  }

  @override
  void dispose() {
    _ringing?.cancel();
    _clock.cancel();
    super.dispose();
  }

  /// Hands the show over from the alarm to the in-app player at the same
  /// spot, so the radio keeps going while the user gets up.
  Future<void> _wakeUp() async {
    await _ringing?.cancel();
    final show = _show;
    Duration? startAt;
    if (show != null && show.durationSeconds > 0) {
      final elapsed = DateTime.now().difference(widget.alarm.dateTime).inMilliseconds / 1000;
      final cut = show.snoozeCut(Scheduler.snoozeNumber(widget.alarm));
      final double position;
      if (Scheduler.snoozeNumber(widget.alarm) > 0 && cut != null) {
        final cutLength = cut.seconds > 0 ? cut.seconds : cut.introSeconds + show.durationSeconds - cut.resumeAt;
        position = cut.mainPosition(elapsed <= 0 ? 0 : elapsed % cutLength);
      } else {
        position = elapsed <= 0 ? 0 : elapsed % show.durationSeconds;
      }
      startAt = Duration(milliseconds: (position * 1000).round());
    }
    await Alarm.stop(widget.alarm.id);
    await Scheduler.resetSnoozes();
    unawaited(Scheduler.rearm());
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => ShowScreen(autoplay: show != null, startAt: startAt),
    ));
  }

  Future<void> _turnOff() async {
    await _ringing?.cancel();
    await Alarm.stop(widget.alarm.id);
    await Scheduler.resetSnoozes();
    unawaited(Scheduler.rearm());
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _snooze() async {
    await _ringing?.cancel();
    await Scheduler.snooze(widget.alarm);
    unawaited(Scheduler.rearm());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final show = _show;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF07020F), Color(0xFF3B0A5C), Color(0xFFFF2BD6)],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Spacer(),
                  ClipOval(
                    child: Image.asset('assets/icon/logo_square.png', width: 180, height: 180),
                  ),
                  const SizedBox(height: 24),
                  Text(hhmm(_now).replaceFirst('h', ':'),
                      style: theme.textTheme.displayLarge
                          ?.copyWith(fontWeight: FontWeight.w300, color: Colors.white)),
                  const SizedBox(height: 8),
                  Text(frenchDate(_now),
                      style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)),
                  const SizedBox(height: 32),
                  if (show != null) ...[
                    Text('EN DIRECT SUR RADIO CHROME · ${show.onAirCity}',
                        style: theme.textTheme.labelLarge?.copyWith(color: Colors.white70)),
                    const SizedBox(height: 6),
                    Text(show.title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white)),
                  ],
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: FilledButton.icon(
                      onPressed: _wakeUp,
                      icon: const Icon(Icons.wb_sunny_outlined),
                      label: const Text('Je me lève, la radio continue',
                          style: TextStyle(fontSize: 18)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: _snooze,
                      icon: const Icon(Icons.snooze),
                      label: Text('Snooze ${Scheduler.snoozeDuration.inMinutes} min'),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.white70),
                    onPressed: _turnOff,
                    child: const Text('Couper la radio'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
