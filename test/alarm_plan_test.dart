import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:snooze_ai/app_store.dart';

void main() {
  // 2026-10-16 is a Friday.
  final friday10am = DateTime(2026, 10, 16, 10);

  AlarmPlan only(Map<int, DaySetting> days) => AlarmPlan(
        enabled: true,
        week: [for (var d = 1; d <= 7; d++) days[d] ?? const DaySetting()],
      );

  test('skips today once the ring time has passed', () {
    final plan = only({5: const DaySetting(on: true, hour: 7, minute: 30)});
    expect(plan.upcoming(friday10am), [DateTime(2026, 10, 23, 7, 30)]);
  });

  test('includes today when the ring time is still ahead', () {
    final plan = only({5: const DaySetting(on: true, hour: 11)});
    expect(plan.upcoming(friday10am), [DateTime(2026, 10, 16, 11)]);
  });

  test('each day rings at its own time, soonest first', () {
    final plan = only({
      1: const DaySetting(on: true, hour: 6, minute: 45),
      6: const DaySetting(on: true, hour: 10),
      7: const DaySetting(on: true, hour: 9, minute: 30),
    });
    expect(plan.upcoming(friday10am), [
      DateTime(2026, 10, 17, 10),
      DateTime(2026, 10, 18, 9, 30),
      DateTime(2026, 10, 19, 6, 45),
    ]);
  });

  test('a day switched off keeps its time but does not ring', () {
    final plan = only({6: const DaySetting(hour: 10)});
    expect(plan.upcoming(friday10am), isEmpty);
    expect(plan.day(6).hour, 10);
  });

  test('older plans with one shared time migrate to per-day settings', () {
    final plan = AlarmPlan.fromJson({
      'enabled': true,
      'hour': 7,
      'minute': 15,
      'weekdays': [1, 2, 3, 4, 5, 6, 7],
      'leadMinutes': 30,
    });
    for (var d = 1; d <= 7; d++) {
      expect(plan.day(d).on, isTrue);
      expect((plan.day(d).hour, plan.day(d).minute), (7, 15));
    }
  });

  test('round-trips through JSON', () {
    final plan = only({2: const DaySetting(on: true, hour: 6), 6: const DaySetting(hour: 11, minute: 5)})
        .copyWith(leadMinutes: 45);
    final copy = AlarmPlan.fromJson(jsonDecode(jsonEncode(plan)) as Map<String, dynamic>);
    expect(jsonEncode(copy), jsonEncode(plan));
  });
}
