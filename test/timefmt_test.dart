import 'package:flutter_test/flutter_test.dart';
import 'package:timed_player/core/timefmt.dart';

void main() {
  test('formats durations', () {
    expect(formatDuration(Duration.zero), '00:00:00');
    expect(formatDuration(const Duration(hours: 26, minutes: 3, seconds: 9)),
        '26:03:09');
    expect(formatDuration(const Duration(seconds: 5, milliseconds: 250), millis: true),
        '00:00:05.25');
    expect(formatDuration(const Duration(seconds: 5, milliseconds: 250)),
        '00:00:05');
    expect(formatDuration(const Duration(seconds: -90)), '-00:01:30');
  });

  test('parses durations', () {
    expect(parseDuration('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
    expect(parseDuration('02:03'), const Duration(minutes: 2, seconds: 3));
    expect(parseDuration('75'), const Duration(seconds: 75));
    expect(parseDuration('1,5'), const Duration(milliseconds: 1500));
    expect(parseDuration(' 0:00:01.25 '), const Duration(milliseconds: 1250));
    expect(parseDuration('30:00:00'), const Duration(hours: 30));
  });

  test('rejects malformed durations', () {
    for (final bad in ['', 'abc', '1:2:3:4', '1:60', '1:60:00', '-5', '1::2', '1.5:00']) {
      expect(parseDuration(bad), isNull, reason: bad);
    }
  });

  test('formats time of day past midnight', () {
    expect(formatTimeOfDay(const Duration(hours: 9)), '09:00:00');
    expect(formatTimeOfDay(const Duration(hours: 25, minutes: 30)), '+1д 01:30:00');
  });
}
