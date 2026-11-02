import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/anchors.dart';
import '../core/model.dart';
import '../playback/runner.dart';
import '../services/journal.dart';
import '../services/keep_awake.dart';
import '../services/settings.dart';

/// Extension of schedule files (JSON inside).
const scheduleExtension = 'tplay';

/// Command-line options: `[--open файл] [--start | --arm] [--exit-when-done]`.
class LaunchOptions {
  const LaunchOptions(
      {this.open, this.start = false, this.arm = false, this.exitWhenDone = false});

  final String? open;
  final bool start;
  final bool arm;
  final bool exitWhenDone;

  static LaunchOptions parse(List<String> args) {
    String? open;
    var start = false, arm = false, exitWhenDone = false;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--open' when i + 1 < args.length:
          open = args[++i];
        case '--start':
          start = true;
        case '--arm':
          arm = true;
        case '--exit-when-done':
          exitWhenDone = true;
        default:
          if (!args[i].startsWith('--')) open = args[i];
      }
    }
    return LaunchOptions(
        open: open, start: start, arm: arm, exitWhenDone: exitWhenDone);
  }
}

/// Editor state: the open schedule, selection, file handling, and the link
/// between the editor and the [Runner].
class AppController extends ChangeNotifier {
  AppController({
    required this.runner,
    required this.journal,
    required this.settings,
    required this.probe,
  }) {
    runner.addListener(_onRunner);
  }

  final Runner runner;
  final Journal journal;
  final AppSettings settings;

  /// Reads a media file's length.
  final Future<Duration?> Function(String path) probe;

  Schedule _schedule = const Schedule();
  String? _filePath;
  bool _dirty = false;
  bool _linked = false;
  bool _busy = false;
  String? selectedId;
  Duration cursor = Duration.zero;

  Schedule get schedule => _schedule;
  String? get filePath => _filePath;
  bool get dirty => _dirty;
  bool get busy => _busy;

  /// The runner plays the schedule open in the editor, so edits apply live.
  bool get linked => _linked && runner.status != RunnerStatus.stopped;

  bool get clockTimes => settings.clockTimes;
  set clockTimes(bool value) {
    settings.clockTimes = value;
    settings.save();
    notifyListeners();
  }

  String get title =>
      '${_filePath == null ? _schedule.name : p.basename(_filePath!)}'
      '${_dirty ? ' •' : ''}';

  /// Run start that clock times are counted from: the running run, else the
  /// next planned start of a clock-driven schedule.
  DateTime? get clockAnchor {
    if (linked && runner.anchor != null) return runner.anchor;
    return displayAnchor(_schedule.start, _schedule.span, DateTime.now());
  }

  ScheduleItem? get selected {
    for (final i in _schedule.items) {
      if (i.id == selectedId) return i;
    }
    return null;
  }

  // ---- editing --------------------------------------------------------------

  void edit(Schedule s) {
    final items = [...s.items];
    // Stable, so items that start together keep their order (the later one in
    // the list is the one shown).
    mergeSort(items, compare: (a, b) => a.offset.compareTo(b.offset));
    _schedule = s.copyWith(items: items);
    _dirty = true;
    if (linked) runner.updateSchedule(_schedule);
    notifyListeners();
  }

  void select(String? id) {
    selectedId = id;
    notifyListeners();
  }

  void setCursor(Duration d) {
    cursor = d.isNegative ? Duration.zero : d;
    notifyListeners();
  }

  void upsertItem(ScheduleItem item) {
    final items = [..._schedule.items];
    final i = items.indexWhere((e) => e.id == item.id);
    if (i >= 0) {
      items[i] = item;
    } else {
      items.add(item);
    }
    selectedId = item.id;
    edit(_schedule.copyWith(items: items));
  }

  void removeItem(String id) {
    if (selectedId == id) selectedId = null;
    edit(_schedule.copyWith(
        items: _schedule.items.where((e) => e.id != id).toList()));
  }

  void moveItem(String id, Duration offset) {
    final item = _find(id);
    if (item == null) return;
    upsertItem(item.copyWith(offset: offset.isNegative ? Duration.zero : offset));
  }

  void resizeItem(String id, Duration length) {
    final item = _find(id);
    if (item == null) return;
    const min = Duration(milliseconds: 100);
    upsertItem(item.copyWith(length: length < min ? min : length));
  }

  ScheduleItem? _find(String id) {
    for (final i in _schedule.items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// End of the last item on the layer of [kind]; unknown lengths count as
  /// ten seconds so new items do not land on top of them.
  Duration layerEnd(MediaKind kind) {
    var end = Duration.zero;
    for (final i in _schedule.items) {
      if (i.kind.isVisual != kind.isVisual) continue;
      final e = i.endOffset ?? i.offset + const Duration(seconds: 10);
      if (e > end) end = e;
    }
    return end;
  }

  /// Adds files one after another at the end of their layer.
  Future<void> addFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    _busy = true;
    notifyListeners();
    try {
      var visualEnd = layerEnd(MediaKind.video);
      var audioEnd = layerEnd(MediaKind.audio);
      final added = <ScheduleItem>[];
      for (final path in paths) {
        final kind = kindForPath(path);
        final length = kind == MediaKind.image ? null : await probe(path);
        final item = ScheduleItem(
          id: newId(),
          path: path,
          kind: kind,
          offset: kind.isVisual ? visualEnd : audioEnd,
          mediaLength: length,
        );
        final end = item.endOffset ?? item.offset + const Duration(seconds: 10);
        if (kind.isVisual) {
          visualEnd = end;
        } else {
          audioEnd = end;
        }
        added.add(item);
      }
      selectedId = added.last.id;
      edit(_schedule.copyWith(items: [..._schedule.items, ...added]));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ---- files ----------------------------------------------------------------

  void newSchedule() {
    _schedule = const Schedule();
    _filePath = null;
    _dirty = false;
    _linked = false;
    selectedId = null;
    cursor = Duration.zero;
    notifyListeners();
  }

  Future<void> openFile(String path) async {
    final json = jsonDecode(await File(path).readAsString());
    if (json is! Map) throw const FormatException('Файл повреждён');
    _schedule = Schedule.fromJson(json.cast<String, Object?>(), p.dirname(path));
    _filePath = path;
    _dirty = false;
    _linked = false;
    selectedId = null;
    cursor = Duration.zero;
    settings.lastFile = path;
    settings.save();
    notifyListeners();
  }

  /// JSON of the schedule as stored next to [path].
  Uint8List encode(String path) => Uint8List.fromList(utf8.encode(
      const JsonEncoder.withIndent('  ').convert(_schedule.toJson(p.dirname(path)))));

  Future<void> saveTo(String path) async {
    await File(path).writeAsBytes(encode(path), flush: true);
    _filePath = path;
    _dirty = false;
    settings.lastFile = path;
    settings.save();
    _onRunner();
  }

  // ---- running --------------------------------------------------------------

  /// Starts the schedule now, from the cursor position.
  Future<void> start() async {
    _linked = true;
    await runner.startManual(_schedule, from: cursor);
  }

  /// Arms a clock-driven schedule. Returns why it cannot start, or null.
  Future<String?> arm() async {
    final error = await runner.arm(_schedule);
    if (error == null) {
      _linked = true;
      _onRunner();
    }
    return error;
  }

  Future<void> stop() => runner.stop();

  void _onRunner() {
    final running = runner.status != RunnerStatus.stopped;
    KeepAwake.set(running);
    final s = runner.schedule;
    settings.active = !running || s == null
        ? null
        : ActiveRun(
            schedule: s,
            manual: runner.isManual,
            anchor: runner.isManual ? runner.anchor : null,
            file: _linked ? _filePath : null,
          );
    settings.save();
    notifyListeners();
  }

  /// Opens the last file and resumes a run interrupted by a restart, or
  /// follows the command line.
  Future<void> startup(LaunchOptions options) async {
    final active = settings.active;
    final file = options.open ?? settings.lastFile;
    if (file != null && File(file).existsSync()) {
      try {
        await openFile(file);
      } on Object catch (e) {
        journal.add('⚠ Не удалось открыть $file: $e');
      }
    }
    if (options.start) {
      await start();
    } else if (options.arm) {
      final error = await arm();
      if (error != null) journal.add('⚠ $error');
    } else if (active != null) {
      journal.add('Восстановление «${active.schedule.name}» после перезапуска');
      _linked = active.file != null && active.file == _filePath;
      if (active.manual && active.anchor != null) {
        await runner.startManual(active.schedule, anchor: active.anchor);
      } else if (!active.manual) {
        final error = await runner.arm(active.schedule);
        if (error != null) journal.add('⚠ $error');
      }
    }
  }

  @override
  void dispose() {
    runner.removeListener(_onRunner);
    super.dispose();
  }
}
