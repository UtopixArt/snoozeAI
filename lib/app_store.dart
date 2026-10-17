import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/show_config.dart';

/// One day of the week: whether the alarm rings, and when.
class DaySetting {
  const DaySetting({this.on = false, this.hour = 7, this.minute = 0});
  final bool on;
  final int hour;
  final int minute;

  Map<String, dynamic> toJson() => {'on': on, 'hour': hour, 'minute': minute};
  factory DaySetting.fromJson(Map<String, dynamic> j) => DaySetting(
        on: j['on'] as bool? ?? false,
        hour: j['hour'] as int? ?? 7,
        minute: j['minute'] as int? ?? 0,
      );

  DaySetting copyWith({bool? on, int? hour, int? minute}) =>
      DaySetting(on: on ?? this.on, hour: hour ?? this.hour, minute: minute ?? this.minute);
}

/// When the alarm rings: a time per day of the week, each switchable.
/// [week] is indexed by [DateTime.weekday] - 1 (0 = lundi).
class AlarmPlan {
  const AlarmPlan({
    this.enabled = false,
    this.week = _defaultWeek,
    this.leadMinutes = 30,
  });

  static const _defaultWeek = [
    DaySetting(on: true), DaySetting(on: true), DaySetting(on: true), DaySetting(on: true),
    DaySetting(on: true), DaySetting(hour: 9), DaySetting(hour: 9),
  ];

  /// Master switch.
  final bool enabled;
  final List<DaySetting> week;

  /// How long before the ring the show is generated.
  final int leadMinutes;

  DaySetting day(int weekday) => week[weekday - 1];

  /// Next ring time strictly after [from] for each active weekday, soonest first.
  List<DateTime> upcoming(DateTime from) {
    final result = <DateTime>[];
    for (var offset = 0; offset <= 7; offset++) {
      final date = DateTime(from.year, from.month, from.day + offset);
      final setting = day(date.weekday);
      if (!setting.on) continue;
      final ring = DateTime(date.year, date.month, date.day, setting.hour, setting.minute);
      if (ring.isAfter(from) && !result.any((d) => d.weekday == ring.weekday)) result.add(ring);
    }
    return result..sort();
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'week': week,
        'leadMinutes': leadMinutes,
      };

  factory AlarmPlan.fromJson(Map<String, dynamic> j) {
    final week = j['week'] as List?;
    return AlarmPlan(
      enabled: j['enabled'] as bool? ?? false,
      week: week != null && week.length == 7
          ? [for (final d in week) DaySetting.fromJson(d as Map<String, dynamic>)]
          // Older plans: one time shared by a set of weekdays.
          : [
              for (var d = 1; d <= 7; d++)
                DaySetting(
                  on: ((j['weekdays'] as List?) ?? const [1, 2, 3, 4, 5]).contains(d),
                  hour: j['hour'] as int? ?? 7,
                  minute: j['minute'] as int? ?? 0,
                ),
            ],
      leadMinutes: j['leadMinutes'] as int? ?? 30,
    );
  }

  AlarmPlan copyWith({bool? enabled, List<DaySetting>? week, int? leadMinutes}) => AlarmPlan(
        enabled: enabled ?? this.enabled,
        week: week ?? this.week,
        leadMinutes: leadMinutes ?? this.leadMinutes,
      );

  /// This plan with [weekday] replaced by [setting].
  AlarmPlan withDay(int weekday, DaySetting setting) =>
      copyWith(week: [for (var d = 1; d <= 7; d++) d == weekday ? setting : day(d)]);
}

/// Outcome of the last show generation, shown on the home screen.
class GenerationStatus {
  GenerationStatus({required this.at, required this.ok, this.message = ''});
  final DateTime at;
  final bool ok;
  final String message;

  Map<String, dynamic> toJson() =>
      {'at': at.toIso8601String(), 'ok': ok, 'message': message};
  factory GenerationStatus.fromJson(Map<String, dynamic> j) => GenerationStatus(
        at: DateTime.parse(j['at'] as String),
        ok: j['ok'] as bool,
        message: j['message'] as String? ?? '',
      );
}

/// Persistence shared by the UI and the background generation isolate.
class AppStore {
  static const _planKey = 'alarm_plan';
  static const _configKey = 'show_config';
  static const _statusKey = 'generation_status';
  static const _apiKeyKey = 'openrouter_api_key';
  static const _sunoKeyKey = 'apimart_api_key';
  static const _snoozeCountKey = 'snooze_count';

  static const _secure = FlutterSecureStorage();

  static Future<AlarmPlan> loadPlan() async {
    final raw = (await _prefs()).getString(_planKey);
    return raw == null ? const AlarmPlan() : AlarmPlan.fromJson(jsonDecode(raw));
  }

  static Future<void> savePlan(AlarmPlan plan) async =>
      (await _prefs()).setString(_planKey, jsonEncode(plan));

  static Future<ShowConfig> loadConfig() async {
    final raw = (await _prefs()).getString(_configKey);
    return raw == null ? const ShowConfig() : ShowConfig.fromJson(jsonDecode(raw));
  }

  static Future<void> saveConfig(ShowConfig config) async =>
      (await _prefs()).setString(_configKey, jsonEncode(config));

  static Future<GenerationStatus?> loadStatus() async {
    final raw = (await _prefs()).getString(_statusKey);
    return raw == null ? null : GenerationStatus.fromJson(jsonDecode(raw));
  }

  static Future<void> saveStatus(GenerationStatus status) async =>
      (await _prefs()).setString(_statusKey, jsonEncode(status));

  /// Keys baked in at build time with `--dart-define-from-file=.env`, so a
  /// personal build works without typing them on the phone.
  static const _buildTimeApiKey = String.fromEnvironment('OPENROUTER_API_KEY');
  static const _buildTimeSunoKey = String.fromEnvironment('APIMART_API_KEY');

  static Future<String?> loadApiKey() => _loadSecret(_apiKeyKey, _buildTimeApiKey);
  static Future<void> saveApiKey(String key) => _saveSecret(_apiKeyKey, key);

  /// APIMart key for Suno; without it songs come from the library or Lyria.
  static Future<String?> loadSunoKey() => _loadSecret(_sunoKeyKey, _buildTimeSunoKey);
  static Future<void> saveSunoKey(String key) => _saveSecret(_sunoKeyKey, key);

  static Future<String?> _loadSecret(String name, String buildTime) async {
    final stored = await _secure.read(key: name);
    if (stored != null && stored.isNotEmpty) return stored;
    return buildTime.isEmpty ? null : buildTime;
  }

  static Future<void> _saveSecret(String name, String value) =>
      value.isEmpty ? _secure.delete(key: name) : _secure.write(key: name, value: value);

  /// Snoozes since the alarm first rang this morning.
  static Future<int> loadSnoozeCount() async => (await _prefs()).getInt(_snoozeCountKey) ?? 0;
  static Future<void> saveSnoozeCount(int count) async =>
      (await _prefs()).setInt(_snoozeCountKey, count);

  /// The background isolate and the UI each keep their own cache, so always
  /// reload to see what the other side wrote.
  static Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }
}
