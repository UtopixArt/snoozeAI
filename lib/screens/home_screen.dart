import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_store.dart';
import '../scheduler.dart';
import '../services/show_generator.dart';
import '../widgets/audio_output_chip.dart';
import 'settings_screen.dart';
import 'show_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _dayNames = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];

  AlarmPlan _plan = const AlarmPlan();
  Show? _show;
  GenerationStatus? _status;
  bool _hasKey = true;
  bool _batteryOk = true;
  String? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions().then((_) => _refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Also catches a time-zone change after a flight.
      Scheduler.rearm();
      _refresh();
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.notification.request();
    if (await Permission.scheduleExactAlarm.isDenied) {
      await Permission.scheduleExactAlarm.request();
    }
  }

  Future<void> _refresh() async {
    final plan = await AppStore.loadPlan();
    final show = await Show.latest(await Scheduler.showsRoot());
    final status = await AppStore.loadStatus();
    final key = await AppStore.loadApiKey();
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!mounted) return;
    setState(() {
      _plan = plan;
      _show = show;
      _status = status;
      _hasKey = key != null && key.isNotEmpty;
      _batteryOk = battery;
    });
  }

  Future<void> _updatePlan(AlarmPlan plan) async {
    setState(() => _plan = plan);
    await AppStore.savePlan(plan);
    await Scheduler.rearm();
  }

  Future<void> _pickTime(int weekday) async {
    final day = _plan.day(weekday);
    final picked = await showTimePicker(
      context: context,
      helpText: _dayNames[weekday - 1].toUpperCase(),
      initialTime: TimeOfDay(hour: day.hour, minute: day.minute),
    );
    if (picked != null) {
      // Picking a time means the user wants that day on.
      await _updatePlan(_plan
          .withDay(weekday, day.copyWith(hour: picked.hour, minute: picked.minute, on: true))
          .copyWith(enabled: true));
    }
  }

  Future<void> _generateNow() async {
    setState(() => _progress = 'Démarrage…');
    try {
      await Scheduler.generateForNextAlarm(
        onProgress: (step) => mounted ? setState(() => _progress = step) : null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Échec : $e')));
      }
    } finally {
      if (mounted) setState(() => _progress = null);
      await _refresh();
    }
  }

  Future<void> _testRing() async {
    await Scheduler.testRing();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Sonnerie de test dans 10 secondes (tu peux verrouiller l\'écran).'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final next = _plan.enabled ? _plan.upcoming(DateTime.now()) : <DateTime>[];
    final show = _show;
    final status = _status;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            ClipOval(child: Image(image: AssetImage('assets/icon/logo_square.png'), width: 34, height: 34)),
            SizedBox(width: 10),
            Flexible(child: Text('Radio CHROME', overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          const AudioOutputChip(),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
              await Scheduler.rearm();
              await _refresh();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_hasKey)
              _Banner(
                icon: Icons.key_outlined,
                text: 'Ajoute ta clé OpenRouter dans les réglages.',
                action: 'Réglages',
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()))
                    .then((_) => _refresh()),
              ),
            if (!_batteryOk)
              _Banner(
                icon: Icons.battery_alert_outlined,
                text: 'Autorise snoozeAI à ignorer l\'optimisation de batterie, '
                    'sinon l\'émission risque de ne pas être générée la nuit.',
                action: 'Autoriser',
                onTap: () => Permission.ignoreBatteryOptimizations.request().then((_) => _refresh()),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Réveil', style: theme.textTheme.titleLarge)),
                        Switch(
                          value: _plan.enabled,
                          onChanged: (v) => _updatePlan(_plan.copyWith(enabled: v)),
                        ),
                      ],
                    ),
                    Text(
                      next.isEmpty
                          ? 'Aucun réveil programmé'
                          : 'Prochain : ${frenchDate(next.first)} à ${hhmm(next.first)}\n'
                              'Émission préparée ${_plan.leadMinutes} min avant',
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 8),
                    for (var d = 1; d <= 7; d++)
                      _DayRow(
                        name: _dayNames[d - 1],
                        setting: _plan.day(d),
                        dimmed: !_plan.enabled,
                        onPickTime: () => _pickTime(d),
                        onToggle: (on) => _updatePlan(_plan.withDay(d, _plan.day(d).copyWith(on: on))),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.radio_outlined),
                title: Text(show?.title ?? 'Pas encore d\'émission'),
                subtitle: Text(_statusLine(show, status)),
                trailing: show == null ? null : const Icon(Icons.chevron_right),
                onTap: show == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const ShowScreen())),
              ),
            ),
            const SizedBox(height: 16),
            if (_progress != null) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(_progress!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              onPressed: _progress != null || !_hasKey ? null : _generateNow,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('Préparer l\'émission maintenant'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _testRing,
              icon: const Icon(Icons.alarm),
              label: const Text('Tester la sonnerie (10 s)'),
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLine(Show? show, GenerationStatus? status) {
    final parts = <String>[
      if (show != null)
        '${show.onAirCity} · ${frenchDate(show.createdAt)} à ${hhmm(show.createdAt)}'
            '${show.sunoCostUsd > 0 ? ' · Suno ${show.sunoCostUsd.toStringAsFixed(2)} \$' : ''}',
      if (status != null && !status.ok)
        'Dernier essai (${hhmm(status.at)}) : ${status.message.split('\n').first}',
    ];
    return parts.isEmpty ? 'Appuie sur « Préparer » pour tester' : parts.join('\n');
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.name,
    required this.setting,
    required this.dimmed,
    required this.onPickTime,
    required this.onToggle,
  });

  final String name;
  final DaySetting setting;

  /// The master switch is off: days keep their settings but look inactive.
  final bool dimmed;
  final VoidCallback onPickTime;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = setting.on && !dimmed;
    final time = '${setting.hour.toString().padLeft(2, '0')}:${setting.minute.toString().padLeft(2, '0')}';
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(name, style: TextStyle(color: active ? null : theme.disabledColor)),
        ),
        TextButton(
          onPressed: onPickTime,
          child: Text(
            time,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: active ? theme.colorScheme.onSurface : theme.disabledColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const Spacer(),
        Switch(value: setting.on, onChanged: onToggle),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(icon, color: scheme.onErrorContainer),
        title: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
        trailing: TextButton(onPressed: onTap, child: Text(action)),
      ),
    );
  }
}
