import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/timefmt.dart';

/// Playback log: a daily text file plus the recent lines for the editor.
class Journal extends ChangeNotifier {
  Journal({this.directory, DateTime Function()? clock})
      : _now = clock ?? DateTime.now;

  /// Folder for `ГГГГ-ММ-ДД.log` files; null keeps the log in memory only.
  final String? directory;
  final DateTime Function() _now;

  static const keep = 500;
  final List<String> lines = [];

  File? _fileFor(DateTime day) {
    final dir = directory;
    if (dir == null) return null;
    final name = '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    return File(p.join(dir, '$name.log'));
  }

  /// Shows today's earlier entries, e.g. after the app was restarted.
  void loadToday() {
    try {
      final file = _fileFor(_now());
      if (file == null || !file.existsSync()) return;
      final old = file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
      lines.insertAll(0, old.length > keep ? old.sublist(old.length - keep) : old);
      if (lines.length > keep) lines.removeRange(0, lines.length - keep);
      notifyListeners();
    } on FileSystemException {
      // An unreadable log only hides history.
    }
  }

  void add(String message) {
    final now = _now();
    final ms = now.millisecond.toString().padLeft(3, '0');
    final line = '${formatClock(now)}.$ms  $message';
    lines.add(line);
    if (lines.length > keep) lines.removeRange(0, lines.length - keep);
    final file = _fileFor(now);
    if (file != null) {
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('$line\n', mode: FileMode.append);
      } on FileSystemException {
        // The log must never stop playback.
      }
    }
    notifyListeners();
  }
}
