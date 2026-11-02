/// When a schedule run starts ("anchor") for the clock-driven start modes.
library;

import 'model.dart';

DateTime _onDay(DateTime base, int dayDelta, Duration timeOfDay) {
  final ms = timeOfDay.inMilliseconds;
  // Calendar fields rather than adding a Duration keep the wall-clock time
  // right across daylight-saving changes.
  return DateTime(
    base.year,
    base.month,
    base.day + dayDelta,
    ms ~/ 3600000,
    ms % 3600000 ~/ 60000,
    ms % 60000 ~/ 1000,
    ms % 1000,
  );
}

/// Start of the run that is under way at [now] (started, not yet past [span]),
/// or null. Manual schedules have no clock-driven runs.
DateTime? activeAnchor(StartRule rule, Duration span, DateTime now) {
  switch (rule.mode) {
    case StartMode.manual:
      return null;
    case StartMode.once:
      final at = rule.at;
      if (at == null) return null;
      return !now.isBefore(at) && now.isBefore(at.add(span)) ? at : null;
    case StartMode.weekly:
      if (rule.weekdays.isEmpty) return null;
      for (var d = 0; d <= span.inDays + 1; d++) {
        final a = _onDay(now, -d, rule.timeOfDay);
        if (a.isAfter(now) || !rule.weekdays.contains(a.weekday)) continue;
        // Runs share one length, so an older run ends before this one does.
        return now.isBefore(a.add(span)) ? a : null;
      }
      return null;
  }
}

/// First run start strictly after [t], or null when there is none.
DateTime? nextAnchorAfter(StartRule rule, DateTime t) {
  switch (rule.mode) {
    case StartMode.manual:
      return null;
    case StartMode.once:
      final at = rule.at;
      return at != null && at.isAfter(t) ? at : null;
    case StartMode.weekly:
      if (rule.weekdays.isEmpty) return null;
      for (var d = 0; d <= 7; d++) {
        final a = _onDay(t, d, rule.timeOfDay);
        if (a.isAfter(t) && rule.weekdays.contains(a.weekday)) return a;
      }
      return null;
  }
}

/// The run start used to show clock times in the editor: the active or next
/// run, or for a single start its set moment even when it has passed.
DateTime? displayAnchor(StartRule rule, Duration span, DateTime now) =>
    activeAnchor(rule, span, now) ??
    nextAnchorAfter(rule, now) ??
    (rule.mode == StartMode.once ? rule.at : null);
