import 'dart:convert';
import 'dart:io';

import '../core/model.dart';
import '../playback/backend.dart';

/// The schedule the runner was playing, kept so it can be resumed after the
/// app is restarted unexpectedly (crash, power loss, reboot).
class ActiveRun {
  const ActiveRun({
    required this.schedule,
    required this.manual,
    this.anchor,
    this.file,
  });

  /// Snapshot with absolute paths, independent of any schedule file.
  final Schedule schedule;
  final bool manual;

  /// Start of a manual run.
  final DateTime? anchor;

  /// Schedule file the run was started from, if it was saved.
  final String? file;

  Map<String, Object?> toJson() => {
        'schedule': schedule.toJson(null),
        'manual': manual,
        if (anchor != null) 'anchor': anchor!.toIso8601String(),
        if (file != null) 'file': file,
      };

  static ActiveRun? fromJson(Object? j) {
    if (j is! Map) return null;
    final map = j.cast<String, Object?>();
    try {
      return ActiveRun(
        schedule: Schedule.fromJson(
            (map['schedule'] as Map).cast<String, Object?>(), null),
        manual: map['manual'] == true,
        anchor: map['anchor'] == null
            ? null
            : DateTime.tryParse(map['anchor'] as String),
        file: map['file'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

class AppSettings {
  AppSettings(this.file);

  final String file;
  String? lastFile;
  OutputConfig output = const OutputConfig();
  bool clockTimes = false;
  ActiveRun? active;

  static Future<AppSettings> load(String file) async {
    final s = AppSettings(file);
    try {
      final j = jsonDecode(await File(file).readAsString());
      if (j is Map) {
        final map = j.cast<String, Object?>();
        s.lastFile = map['lastFile'] as String?;
        if (map['output'] is Map) {
          s.output = OutputConfig.fromJson(
              (map['output'] as Map).cast<String, Object?>());
        }
        s.clockTimes = map['clockTimes'] == true;
        s.active = ActiveRun.fromJson(map['active']);
      }
    } on Object {
      // Missing or damaged settings fall back to defaults.
    }
    return s;
  }

  void save() {
    final data = {
      'lastFile': lastFile,
      'output': output.toJson(),
      'clockTimes': clockTimes,
      if (active != null) 'active': active!.toJson(),
    };
    try {
      final f = File(file);
      f.parent.createSync(recursive: true);
      // Write then rename, so a power cut never leaves half a file.
      final tmp = File('$file.tmp')
        ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
      tmp.renameSync(file);
    } on FileSystemException {
      // Settings are a convenience; playback goes on without them.
    }
  }
}
