import 'package:flutter_test/flutter_test.dart';
import 'package:timed_player/core/anchors.dart';
import 'package:timed_player/core/model.dart';

void main() {
  const hour = Duration(hours: 1);

  group('once', () {
    final rule = StartRule(mode: StartMode.once, at: DateTime(2026, 11, 2, 18));

    test('waits for the start, runs for the span, then expires', () {
      expect(activeAnchor(rule, hour, DateTime(2026, 11, 2, 17, 59)), isNull);
      expect(nextAnchorAfter(rule, DateTime(2026, 11, 2, 17, 59)),
          DateTime(2026, 11, 2, 18));
      expect(activeAnchor(rule, hour, DateTime(2026, 11, 2, 18)),
          DateTime(2026, 11, 2, 18));
      expect(activeAnchor(rule, hour, DateTime(2026, 11, 2, 18, 59, 59)),
          DateTime(2026, 11, 2, 18));
      expect(activeAnchor(rule, hour, DateTime(2026, 11, 2, 19)), isNull);
      expect(nextAnchorAfter(rule, DateTime(2026, 11, 2, 18)), isNull);
    });
  });

  group('weekly', () {
    // 2026-11-02 is a Monday.
    final weekdays = StartRule(
      mode: StartMode.weekly,
      timeOfDay: const Duration(hours: 9),
      weekdays: const {DateTime.monday, DateTime.wednesday},
    );

    test('next start skips days that are not chosen', () {
      expect(nextAnchorAfter(weekdays, DateTime(2026, 11, 2, 8)),
          DateTime(2026, 11, 2, 9));
      expect(nextAnchorAfter(weekdays, DateTime(2026, 11, 2, 9)),
          DateTime(2026, 11, 4, 9));
      expect(nextAnchorAfter(weekdays, DateTime(2026, 11, 5, 12)),
          DateTime(2026, 11, 9, 9));
    });

    test('a run in progress is found, including one started yesterday', () {
      expect(activeAnchor(weekdays, hour, DateTime(2026, 11, 2, 9, 30)),
          DateTime(2026, 11, 2, 9));
      expect(activeAnchor(weekdays, hour, DateTime(2026, 11, 2, 10, 30)), isNull);
      expect(activeAnchor(weekdays, hour, DateTime(2026, 11, 3, 9, 30)), isNull);

      const longSpan = Duration(hours: 30);
      expect(activeAnchor(weekdays, longSpan, DateTime(2026, 11, 3, 14)),
          DateTime(2026, 11, 2, 9));
      expect(activeAnchor(weekdays, longSpan, DateTime(2026, 11, 3, 15)), isNull);
    });

    test('no weekdays means no runs', () {
      final none = weekdays.copyWith(weekdays: {});
      expect(nextAnchorAfter(none, DateTime(2026, 11, 2)), isNull);
      expect(activeAnchor(none, hour, DateTime(2026, 11, 2, 9, 30)), isNull);
    });
  });

  test('manual schedules have no clock-driven runs', () {
    const rule = StartRule();
    expect(activeAnchor(rule, hour, DateTime(2026)), isNull);
    expect(nextAnchorAfter(rule, DateTime(2026)), isNull);
  });
}
