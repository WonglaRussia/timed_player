/// Decides what should be playing at a given moment of a schedule run.
///
/// The rules are a function of the wall clock only, so a run joined late (the
/// app started after the planned time) plays exactly what it would have played
/// had it been running all along:
/// * the screen layer shows the item that started most recently and is still
///   on; when it ends, an earlier item that is still on continues from the
///   position it would have reached;
/// * audio items play alongside, any number at once;
/// * volume follows the fade-in/fade-out envelope.
library;

import 'model.dart';

/// Window opens this long before the first screen item, so it is ready in time.
const outputLead = Duration(seconds: 2);

/// One item placed on the wall clock of a run.
class Occurrence {
  const Occurrence(this.item, this.key, this.start, this.end);

  final ScheduleItem item;

  /// Identifies what is playing; changes when an edit needs a restart.
  final String key;
  final DateTime start;

  /// Null while the item plays to the end of a file of unknown length.
  final DateTime? end;

  bool isOnAt(DateTime t) =>
      !t.isBefore(start) && (end == null || t.isBefore(end!));
}

/// An item that should be playing now, with its file position and volume.
class Cue {
  const Cue(this.occurrence, this.position, this.volume);

  final Occurrence occurrence;

  /// Position in the file.
  final Duration position;

  /// 0.0–1.0, fades applied.
  final double volume;

  ScheduleItem get item => occurrence.item;
  String get key => occurrence.key;
}

class PlayState {
  const PlayState({
    required this.visual,
    required this.audio,
    required this.outputNeeded,
    required this.finished,
    required this.next,
  });

  final Cue? visual;
  final List<Cue> audio;

  /// The output window should be open (from just before the first screen item
  /// to the end of the last one).
  final bool outputNeeded;

  /// Every item of the run has ended.
  final bool finished;

  /// The next item to start, if any.
  final Occurrence? next;
}

String occurrenceKey(ScheduleItem i) =>
    '${i.id}|${i.kind.name}|${i.offset.inMilliseconds}|'
    '${i.from.inMilliseconds}|${i.path}';

class RunPlan {
  RunPlan(this.schedule, this.anchor);

  /// Replaced in place when the schedule is edited during a run.
  Schedule schedule;
  final DateTime anchor;

  /// Items that stopped before their planned end (file ended, failed to open),
  /// by occurrence key.
  final Map<String, DateTime> endedAt = {};

  Occurrence occurrenceOf(ScheduleItem item) {
    final key = occurrenceKey(item);
    final start = anchor.add(item.offset);
    final length = item.playLength;
    var end = length == null ? null : start.add(length);
    final early = endedAt[key];
    if (early != null && (end == null || early.isBefore(end))) {
      end = early.isBefore(start) ? start : early;
    }
    return Occurrence(item, key, start, end);
  }

  List<Occurrence> get occurrences =>
      [for (final i in schedule.items) occurrenceOf(i)];

  PlayState stateAt(DateTime now) {
    final all = occurrences;
    Occurrence? visual;
    final audio = <Cue>[];
    Occurrence? next;
    var finished = true;
    DateTime? firstVisual;
    DateTime? lastVisualEnd;
    var visualOpenEnded = false;

    for (final o in all) {
      if (o.end == null || now.isBefore(o.end!)) finished = false;
      if (o.start.isAfter(now) && (next == null || o.start.isBefore(next.start))) {
        next = o;
      }
      if (o.item.kind.isVisual) {
        if (firstVisual == null || o.start.isBefore(firstVisual)) {
          firstVisual = o.start;
        }
        if (o.end == null) {
          visualOpenEnded = true;
        } else if (lastVisualEnd == null || o.end!.isAfter(lastVisualEnd)) {
          lastVisualEnd = o.end;
        }
      }
      if (!o.isOnAt(now)) continue;
      if (o.item.kind.isVisual) {
        // Later start wins; on a tie the item further down the list wins.
        if (visual == null || !o.start.isBefore(visual.start)) visual = o;
      } else {
        audio.add(_cue(o, now));
      }
    }

    final outputNeeded = firstVisual != null &&
        !now.isBefore(firstVisual.subtract(outputLead)) &&
        (visualOpenEnded || now.isBefore(lastVisualEnd!));

    return PlayState(
      visual: visual == null ? null : _cue(visual, now),
      audio: audio,
      outputNeeded: outputNeeded,
      finished: finished,
      next: next,
    );
  }

  Cue _cue(Occurrence o, DateTime now) {
    final elapsed = now.difference(o.start);
    return Cue(o, o.item.from + elapsed, envelope(o, now));
  }
}

/// Item volume (0.0–1.0) with fade-in from its start and fade-out to its end.
double envelope(Occurrence o, DateTime now) {
  var v = o.item.volume / 100.0;
  final fadeIn = o.item.fadeIn.inMilliseconds;
  if (fadeIn > 0) {
    final t = now.difference(o.start).inMilliseconds;
    if (t < fadeIn) v *= (t / fadeIn).clamp(0.0, 1.0);
  }
  final fadeOut = o.item.fadeOut.inMilliseconds;
  if (fadeOut > 0 && o.end != null) {
    final rest = o.end!.difference(now).inMilliseconds;
    if (rest < fadeOut) v *= (rest / fadeOut).clamp(0.0, 1.0);
  }
  return v;
}
