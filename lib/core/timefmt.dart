/// Formatting and parsing of time values shown in the editor.
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// Formats [d] as `ЧЧ:ММ:СС`, adding `.ммм` when [millis] is set and the
/// value has a fractional second.
String formatDuration(Duration d, {bool millis = false}) {
  final negative = d.isNegative;
  var ms = d.inMilliseconds.abs();
  final h = ms ~/ 3600000;
  ms %= 3600000;
  final m = ms ~/ 60000;
  ms %= 60000;
  final s = ms ~/ 1000;
  ms %= 1000;
  final b = StringBuffer(negative ? '-' : '')
    ..write('${_two(h)}:${_two(m)}:${_two(s)}');
  if (millis && ms != 0) {
    var frac = ms.toString().padLeft(3, '0');
    while (frac.endsWith('0')) {
      frac = frac.substring(0, frac.length - 1);
    }
    b.write('.$frac');
  }
  return b.toString();
}

/// Parses `Ч:ММ:СС`, `ММ:СС` or plain seconds, each optionally with a
/// fraction (`1:02:03.5`, `90,25`). Returns null for anything else.
Duration? parseDuration(String text) {
  final t = text.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  final parts = t.split(':');
  if (parts.length > 3) return null;
  var totalMs = 0;
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i].trim();
    final last = i == parts.length - 1;
    if (part.isEmpty) return null;
    if (last) {
      if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(part)) return null;
      final v = double.parse(part);
      if (parts.length > 1 && v >= 60) return null;
      totalMs = totalMs * 60 + (v * 1000).round();
    } else {
      if (!RegExp(r'^\d+$').hasMatch(part)) return null;
      final v = int.parse(part);
      if (i > 0 && v >= 60) return null;
      totalMs = totalMs * 60 + v * 1000;
    }
  }
  return Duration(milliseconds: totalMs);
}

/// Formats a wall-clock moment as `ЧЧ:ММ:СС`.
String formatClock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

/// Formats a date as `ДД.ММ.ГГГГ`.
String formatDate(DateTime t) => '${_two(t.day)}.${_two(t.month)}.${t.year}';

/// Formats a time of day stored as an offset from midnight, wrapping past
/// 24 hours as `+1д ЧЧ:ММ:СС`.
String formatTimeOfDay(Duration sinceMidnight) {
  final days = sinceMidnight.inDays;
  final rest = sinceMidnight - Duration(days: days);
  final clock = formatDuration(rest);
  return days > 0 ? '+$daysд $clock' : clock;
}

const weekdayShort = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
