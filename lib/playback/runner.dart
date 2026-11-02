import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/anchors.dart';
import '../core/engine.dart';
import '../core/model.dart';
import '../core/timefmt.dart';
import '../services/journal.dart';
import 'backend.dart';

enum RunnerStatus {
  /// Nothing is scheduled.
  stopped,

  /// Armed, waiting for the next start time.
  waiting,

  /// A run is under way.
  running,
}

const _idleKey = '__idle__';

/// Late by more than this, a start is logged as joined in progress.
const _lateNote = Duration(seconds: 1);

/// Completion flags are trusted only this long after a file was opened, so a
/// flag left over from the previous file is not taken for the new one.
const _settle = Duration(milliseconds: 300);

/// Drives a [PlaybackBackend] so that it plays what [RunPlan.stateAt] says,
/// checking the wall clock every [tickInterval].
class Runner extends ChangeNotifier {
  Runner({
    required this.backend,
    required this.journal,
    DateTime Function()? clock,
    bool Function(String path)? fileExists,
    this.tickInterval = const Duration(milliseconds: 40),
  })  : _now = clock ?? DateTime.now,
        _fileExists = fileExists ?? ((path) => File(path).existsSync()) {
    backend.onError = _onBackendError;
  }

  final PlaybackBackend backend;
  final Journal journal;
  final DateTime Function() _now;
  final bool Function(String path) _fileExists;

  /// Zero disables the timer; tests call [tick] themselves.
  final Duration tickInterval;

  Schedule? _schedule;
  bool _armed = false;
  bool _manual = false;
  RunPlan? _run;
  DateTime? _lastFinishedAnchor;
  DateTime? _nextAnchor;
  PlayState? _state;
  OutputConfig _output = const OutputConfig();
  bool _reopenOutput = false;
  String? _missingIdleWarned;

  String? _visualKey;
  double _visualVolume = 0;
  DateTime _visualOpenedAt = DateTime(0);
  DateTime _lastDriftCheck = DateTime(0);
  final Map<String, double> _audioVolumes = {};
  final Map<String, DateTime> _audioOpenedAt = {};
  final Map<String, String> _names = {};

  Timer? _timer;
  bool _busy = false;
  Future<void> _queue = Future.value();

  RunnerStatus get status => !_armed
      ? RunnerStatus.stopped
      : _run == null
          ? RunnerStatus.waiting
          : RunnerStatus.running;

  bool get isManual => _manual;
  Schedule? get schedule => _schedule;
  DateTime? get anchor => _run?.anchor;
  DateTime? get nextAnchor => _nextAnchor;
  PlayState? get state => _state;

  /// Time since the start of the current run.
  Duration? get position => _run == null ? null : _now().difference(_run!.anchor);

  OutputConfig get output => _output;
  set output(OutputConfig value) {
    if (value == _output) return;
    _output = value;
    if (backend.outputOpen) _reopenOutput = true;
    notifyListeners();
  }

  /// Starts [schedule] now as if it had already played for [from], or from the
  /// given [anchor] when resuming a run after a restart.
  Future<void> startManual(Schedule schedule,
      {Duration from = Duration.zero, DateTime? anchor}) {
    return _serial(() async {
      await _halt();
      _schedule = schedule;
      _manual = true;
      _armed = true;
      _run = RunPlan(schedule, anchor ?? _now().subtract(from));
      journal.add(anchor != null
          ? 'Продолжение «${schedule.name}» с ${formatDuration(position!)}'
          : from > Duration.zero
              ? 'Старт «${schedule.name}» с ${formatDuration(from)}'
              : 'Старт «${schedule.name}»');
      _startTimer();
      notifyListeners();
      await _step();
    });
  }

  /// Arms a clock-driven schedule so it starts by itself. Returns why it
  /// cannot be armed, or null.
  Future<String?> arm(Schedule schedule) async {
    if (schedule.start.mode == StartMode.manual) {
      return 'Это расписание запускается кнопкой «Старт»';
    }
    if (schedule.items.isEmpty) return 'В расписании нет элементов';
    final now = _now();
    if (activeAnchor(schedule.start, schedule.span, now) == null &&
        nextAnchorAfter(schedule.start, now) == null) {
      return schedule.start.mode == StartMode.once
          ? 'Время запуска уже прошло'
          : 'Не выбраны дни недели';
    }
    await _serial(() async {
      await _halt();
      _schedule = schedule;
      _manual = false;
      _armed = true;
      _lastFinishedAnchor = null;
      journal.add('Расписание «${schedule.name}» включено');
      _startTimer();
      notifyListeners();
      await _step();
    });
    return null;
  }

  Future<void> stop() => _serial(() async {
        if (!_armed) return;
        await _halt();
        journal.add('Остановлено');
        notifyListeners();
      });

  /// Applies an edited schedule to the armed one; changed items restart.
  void updateSchedule(Schedule schedule) {
    if (!_armed) return;
    _schedule = schedule;
    _run?.schedule = schedule;
    notifyListeners();
  }

  /// One pass of the clock check; called by the timer.
  Future<void> tick() {
    if (_busy || !_armed) return Future.value();
    _busy = true;
    return _serial(() async {
      try {
        if (_armed) await _step();
      } finally {
        _busy = false;
      }
    });
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object e, StackTrace s) {
      journal.add('⚠ Внутренняя ошибка: $e');
    });
    return result;
  }

  void _startTimer() {
    _timer?.cancel();
    if (tickInterval > Duration.zero) {
      _timer = Timer.periodic(tickInterval, (_) => tick());
    }
  }

  Future<void> _halt() async {
    _timer?.cancel();
    _timer = null;
    _armed = false;
    _run = null;
    _state = null;
    _nextAnchor = null;
    await _silence();
  }

  Future<void> _silence() async {
    await backend.stopAll();
    if (backend.outputOpen) await backend.closeOutput();
    _visualKey = null;
    _audioVolumes.clear();
    _audioOpenedAt.clear();
  }

  Future<void> _step() async {
    final schedule = _schedule!;
    final now = _now();
    if (_run == null) {
      final a = activeAnchor(schedule.start, schedule.span, now);
      if (a == null || a == _lastFinishedAnchor) {
        final next = nextAnchorAfter(schedule.start, now);
        if (next != _nextAnchor) {
          _nextAnchor = next;
          notifyListeners();
        }
        if (next == null) {
          await _halt();
          journal.add('Больше запусков нет — расписание выключено');
          notifyListeners();
        }
        return;
      }
      _run = RunPlan(schedule, a);
      _nextAnchor = null;
      final late = now.difference(a);
      journal.add('Начало «${schedule.name}», по плану ${formatClock(a)}'
          '${late > _lateNote ? ', подхвачено с ${formatDuration(late)}' : ''}');
      notifyListeners();
    }

    final run = _run!;
    if (_reopenOutput) {
      _reopenOutput = false;
      if (backend.outputOpen) {
        await backend.closeOutput();
        _visualKey = null;
      }
    }
    _collectCompletions(run, now);
    final st = run.stateAt(now);
    _state = st;
    await _apply(run, st, now);

    if (st.finished) {
      journal.add('Расписание «${schedule.name}» отыграно');
      _lastFinishedAnchor = run.anchor;
      _run = null;
      _state = null;
      await _silence();
      if (_manual || schedule.start.mode == StartMode.once) {
        await _halt();
      } else {
        _nextAnchor = nextAnchorAfter(schedule.start, now);
      }
      notifyListeners();
    }
  }

  void _collectCompletions(RunPlan run, DateTime now) {
    final v = _visualKey;
    if (v != null &&
        v != _idleKey &&
        now.difference(_visualOpenedAt) >= _settle &&
        backend.visualCompleted) {
      run.endedAt.putIfAbsent(v, () => now);
    }
    for (final k in _audioVolumes.keys) {
      final opened = _audioOpenedAt[k] ?? now;
      if (now.difference(opened) >= _settle && backend.audioCompleted(k)) {
        run.endedAt.putIfAbsent(k, () => now);
      }
    }
  }

  Future<void> _apply(RunPlan run, PlayState st, DateTime now) async {
    if (st.outputNeeded && !backend.outputOpen) {
      await backend.openOutput(_output);
      _visualKey = null;
      journal.add('Окно вывода открыто (монитор ${_output.screen + 1})');
    }

    if (backend.outputOpen) {
      final cue = st.visual;
      var idle = run.schedule.idleImage;
      if (idle != null && !_fileExists(idle)) {
        if (_missingIdleWarned != idle) {
          _missingIdleWarned = idle;
          journal.add('⚠ Заставка не найдена: $idle');
        }
        idle = null;
      }
      final want = cue?.key ?? (idle != null ? _idleKey : null);
      if (want != _visualKey) {
        _logStop(_visualKey);
        if (cue != null) {
          await _startVisual(run, cue, now);
        } else if (idle != null) {
          await backend.showPicture(idle);
          _visualKey = _idleKey;
        } else {
          await backend.clearVisual();
          _visualKey = null;
        }
      } else if (cue != null) {
        if ((cue.volume - _visualVolume).abs() >= 0.005) {
          await backend.setVisualVolume(cue.volume);
          _visualVolume = cue.volume;
        }
        await _checkDrift(cue, now);
      }

      if (!st.outputNeeded) {
        _logStop(_visualKey);
        await backend.closeOutput();
        _visualKey = null;
        journal.add('Окно вывода закрыто');
      }
    }

    final wanted = {for (final c in st.audio) c.key: c};
    for (final k in _audioVolumes.keys.toList()) {
      if (wanted.containsKey(k)) continue;
      await backend.stopAudio(k);
      _audioVolumes.remove(k);
      _audioOpenedAt.remove(k);
      _logStop(k);
    }
    for (final c in wanted.values) {
      final current = _audioVolumes[c.key];
      if (current == null) {
        _names[c.key] = c.item.displayName;
        if (!_fileExists(c.item.path)) {
          _fail(run, c.key, 'файл не найден: ${c.item.path}', now);
          continue;
        }
        await backend.startAudio(c.key, c.item, c.position, c.volume);
        _audioVolumes[c.key] = c.volume;
        _audioOpenedAt[c.key] = _now();
        journal.add(_startLine(c, now));
      } else if ((c.volume - current).abs() >= 0.005) {
        await backend.setAudioVolume(c.key, c.volume);
        _audioVolumes[c.key] = c.volume;
      }
    }
  }

  Future<void> _startVisual(RunPlan run, Cue cue, DateTime now) async {
    _names[cue.key] = cue.item.displayName;
    if (!_fileExists(cue.item.path)) {
      _fail(run, cue.key, 'файл не найден: ${cue.item.path}', now);
      await backend.clearVisual();
      _visualKey = null;
      return;
    }
    await backend.playVisual(cue.key, cue.item, cue.position, cue.volume);
    _visualKey = cue.key;
    _visualVolume = cue.volume;
    _visualOpenedAt = _now();
    _lastDriftCheck = _visualOpenedAt;
    journal.add(_startLine(cue, now));
  }

  /// Seeks a video back in line with the clock when it drifts noticeably
  /// (decoder stalls, a slow disk).
  Future<void> _checkDrift(Cue cue, DateTime now) async {
    if (cue.item.kind != MediaKind.video) return;
    if (now.difference(_visualOpenedAt) < const Duration(seconds: 3)) return;
    if (now.difference(_lastDriftCheck) < const Duration(seconds: 5)) return;
    _lastDriftCheck = now;
    final actual = backend.visualPosition;
    if (actual == null) return;
    final drift = cue.position - actual;
    if (drift.abs() > const Duration(milliseconds: 1500)) {
      await backend.seekVisual(cue.position);
      journal.add('↻ ${cue.item.displayName}: расхождение '
          '${drift.inMilliseconds} мс, позиция исправлена');
    }
  }

  String _startLine(Cue cue, DateTime now) {
    final late = now.difference(cue.occurrence.start);
    final b = StringBuffer('▶ ${cue.item.displayName}');
    if (cue.item.kind != MediaKind.image) {
      b.write(' с ${formatDuration(cue.position, millis: true)}, '
          'громкость ${cue.item.volume}%');
    }
    if (late > _lateNote) {
      b.write(' — подхвачено, опоздание ${formatDuration(late)}');
    } else {
      b.write(' (+${late.inMilliseconds} мс)');
    }
    return b.toString();
  }

  void _logStop(String? key) {
    if (key == null || key == _idleKey) return;
    journal.add('■ ${_names[key] ?? key}');
  }

  void _fail(RunPlan run, String key, String message, DateTime now) {
    journal.add('⚠ ${_names[key] ?? key}: $message');
    run.endedAt.putIfAbsent(key, () => now);
  }

  void _onBackendError(String key, String message) {
    final run = _run;
    if (run == null || key == _idleKey) return;
    _fail(run, key, message, _now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
