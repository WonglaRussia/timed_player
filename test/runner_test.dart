import 'package:flutter_test/flutter_test.dart';
import 'package:timed_player/core/model.dart';
import 'package:timed_player/playback/backend.dart';
import 'package:timed_player/playback/runner.dart';
import 'package:timed_player/services/journal.dart';

/// Records what the runner asks for instead of playing anything.
class FakeBackend implements PlaybackBackend {
  final calls = <String>[];
  bool _open = false;
  String? visualPath;
  final audio = <String, String>{};

  @override
  bool visualCompleted = false;
  @override
  Duration? visualPosition;
  final completedAudio = <String>{};

  @override
  void Function(String key, String message)? onError;

  String _name(String path) => path.split('/').last;

  @override
  bool get outputOpen => _open;

  @override
  Future<void> openOutput(OutputConfig config) async {
    _open = true;
    calls.add('open');
  }

  @override
  Future<void> closeOutput() async {
    _open = false;
    visualPath = null;
    calls.add('close');
  }

  @override
  Future<void> playVisual(
      String key, ScheduleItem item, Duration position, double volume) async {
    visualPath = item.path;
    visualCompleted = false;
    calls.add('play ${_name(item.path)} @${position.inSeconds}');
  }

  @override
  Future<void> showPicture(String path) async {
    visualPath = path;
    calls.add('picture ${_name(path)}');
  }

  @override
  Future<void> clearVisual() async {
    visualPath = null;
    calls.add('black');
  }

  @override
  Future<void> setVisualVolume(double volume) async {}

  @override
  Future<void> seekVisual(Duration position) async {
    calls.add('seek @${position.inSeconds}');
  }

  @override
  Future<void> startAudio(
      String key, ScheduleItem item, Duration position, double volume) async {
    audio[key] = item.path;
    calls.add('audio ${_name(item.path)} @${position.inSeconds}');
  }

  @override
  Future<void> setAudioVolume(String key, double volume) async {}

  @override
  Future<void> stopAudio(String key) async {
    calls.add('stop audio ${_name(audio.remove(key)!)}');
  }

  @override
  bool audioCompleted(String key) => completedAudio.contains(audio[key]);

  @override
  Future<void> stopAll() async {
    audio.clear();
    visualPath = null;
  }
}

void main() {
  late DateTime now;
  late FakeBackend backend;
  late Journal journal;
  late Runner runner;
  late Set<String> missing;

  setUp(() {
    now = DateTime(2026, 11, 2, 12);
    backend = FakeBackend();
    journal = Journal(clock: () => now);
    missing = {};
    runner = Runner(
      backend: backend,
      journal: journal,
      clock: () => now,
      fileExists: (path) => !missing.contains(path),
      tickInterval: Duration.zero,
    );
  });

  Future<void> advance(int seconds) async {
    now = now.add(Duration(seconds: seconds));
    await runner.tick();
  }

  ScheduleItem item(String name, int at,
          {int? length, MediaKind kind = MediaKind.video, int from = 0}) =>
      ScheduleItem(
        id: name,
        path: '/m/$name',
        kind: kind,
        offset: Duration(seconds: at),
        from: Duration(seconds: from),
        length: length == null ? null : Duration(seconds: length),
      );

  test('manual run plays items at their times and stops at the end', () async {
    final s = Schedule(items: [
      item('a.mp4', 5, length: 10, from: 60),
      item('b.mp4', 20, length: 5),
      item('m.mp3', 0, length: 30, kind: MediaKind.audio),
    ]);
    await runner.startManual(s);
    expect(runner.status, RunnerStatus.running);
    expect(backend.calls, ['audio m.mp3 @0']);

    await advance(3); // 2 s before a.mp4 the output window opens
    expect(backend.calls.last, 'open');
    await advance(2);
    expect(backend.calls.last, 'play a.mp4 @60');
    await advance(10);
    expect(backend.calls.last, 'black');
    await advance(5);
    expect(backend.calls.last, 'play b.mp4 @0');
    await advance(5);
    expect(backend.calls.last, 'close');
    await advance(10);
    expect(backend.calls.last, 'stop audio m.mp3');
    expect(runner.status, RunnerStatus.stopped);
    expect(journal.lines.last, contains('Расписание «Новое расписание» отыграно'));
  });

  test('starting from a position joins items already under way', () async {
    final s = Schedule(items: [item('a.mp4', 0, length: 100)]);
    await runner.startManual(s, from: const Duration(seconds: 40));
    expect(backend.calls, ['open', 'play a.mp4 @40']);
    expect(runner.position, const Duration(seconds: 40));
  });

  test('an item of unknown length ends when the player says so', () async {
    final a = item('a.mp4', 0); // length unknown
    final b = item('b.mp4', 0, length: 300);
    // Same start: the item further down the list is the one on screen.
    await runner.startManual(Schedule(items: [b, a]));
    expect(backend.calls.last, 'play a.mp4 @0');
    await advance(30);
    backend.visualCompleted = true;
    await advance(1);
    expect(backend.calls.last, 'play b.mp4 @31');
  });

  test('a missing file is logged and skipped', () async {
    missing.add('/m/a.mp4');
    final s = Schedule(items: [item('a.mp4', 0, length: 10)]);
    await runner.startManual(s);
    expect(journal.lines.any((l) => l.contains('файл не найден')), isTrue);
    await advance(1);
    expect(backend.calls.where((c) => c.startsWith('play')), isEmpty);
  });

  test('weekly schedule waits for its time, then runs', () async {
    final s = Schedule(
      start: const StartRule(
          mode: StartMode.weekly, timeOfDay: Duration(hours: 12, seconds: 10)),
      items: [item('a.mp4', 0, length: 5)],
    );
    expect(await runner.arm(s), isNull);
    expect(runner.status, RunnerStatus.waiting);
    expect(runner.nextAnchor, DateTime(2026, 11, 2, 12, 0, 10));
    await advance(10);
    expect(runner.status, RunnerStatus.running);
    expect(backend.calls.last, 'play a.mp4 @0');
    await advance(5);
    expect(runner.status, RunnerStatus.waiting);
    expect(runner.nextAnchor, DateTime(2026, 11, 3, 12, 0, 10));
  });

  test('armed after the planned time, the run is joined in progress', () async {
    final s = Schedule(
      start: StartRule(mode: StartMode.once, at: DateTime(2026, 11, 2, 11, 59)),
      items: [item('a.mp4', 0, length: 300)],
    );
    expect(await runner.arm(s), isNull);
    expect(backend.calls.last, 'play a.mp4 @60');
    expect(journal.lines.any((l) => l.contains('подхвачено')), isTrue);
  });

  test('a single start in the past cannot be armed', () async {
    final s = Schedule(
      start: StartRule(mode: StartMode.once, at: DateTime(2026, 11, 2, 10)),
      items: [item('a.mp4', 0, length: 5)],
    );
    expect(await runner.arm(s), 'Время запуска уже прошло');
    expect(runner.status, RunnerStatus.stopped);
  });

  test('idle picture fills the gaps between screen items', () async {
    final s = Schedule(
      idleImage: '/m/logo.png',
      items: [item('a.mp4', 0, length: 5), item('b.mp4', 10, length: 5)],
    );
    await runner.startManual(s);
    await advance(6);
    expect(backend.calls.last, 'picture logo.png');
    await advance(4);
    expect(backend.calls.last, 'play b.mp4 @0');
  });

  test('stop silences everything', () async {
    await runner.startManual(Schedule(items: [item('a.mp4', 0, length: 50)]));
    await runner.stop();
    expect(backend.outputOpen, isFalse);
    expect(runner.status, RunnerStatus.stopped);
  });
}
