import 'package:flutter_test/flutter_test.dart';
import 'package:timed_player/core/engine.dart';
import 'package:timed_player/core/model.dart';

ScheduleItem item(
  String id, {
  MediaKind kind = MediaKind.video,
  int at = 0,
  int from = 0,
  int? length,
  int? mediaLength,
  int volume = 100,
  int fadeIn = 0,
  int fadeOut = 0,
}) =>
    ScheduleItem(
      id: id,
      path: '/media/$id',
      kind: kind,
      offset: Duration(seconds: at),
      from: Duration(seconds: from),
      length: length == null ? null : Duration(seconds: length),
      mediaLength: mediaLength == null ? null : Duration(seconds: mediaLength),
      volume: volume,
      fadeIn: Duration(seconds: fadeIn),
      fadeOut: Duration(seconds: fadeOut),
    );

void main() {
  final t0 = DateTime(2026, 11, 2, 12);
  DateTime at(num seconds) =>
      t0.add(Duration(milliseconds: (seconds * 1000).round()));
  RunPlan plan(List<ScheduleItem> items) => RunPlan(Schedule(items: items), t0);

  test('plays each item from its file position for its length', () {
    final p = plan([item('a', at: 10, from: 60, length: 20)]);
    expect(p.stateAt(at(9)).visual, isNull);
    final cue = p.stateAt(at(15)).visual!;
    expect(cue.item.id, 'a');
    expect(cue.position, const Duration(seconds: 65));
    expect(p.stateAt(at(30)).visual, isNull);
    expect(p.stateAt(at(30)).finished, isTrue);
  });

  test('length defaults to the rest of the file', () {
    final p = plan([item('a', from: 30, mediaLength: 100)]);
    expect(p.stateAt(at(69)).visual, isNotNull);
    expect(p.stateAt(at(70)).visual, isNull);
  });

  test('a later screen item covers an earlier one, which then continues', () {
    final p = plan([
      item('bg', length: 600),
      item('ad', at: 100, length: 30),
    ]);
    expect(p.stateAt(at(50)).visual!.item.id, 'bg');
    expect(p.stateAt(at(110)).visual!.item.id, 'ad');
    final back = p.stateAt(at(140)).visual!;
    expect(back.item.id, 'bg');
    expect(back.position, const Duration(seconds: 140));
  });

  test('audio plays alongside video and other audio', () {
    final p = plan([
      item('v', length: 100),
      item('music', kind: MediaKind.audio, length: 100),
      item('voice', kind: MediaKind.audio, at: 20, length: 10),
    ]);
    final st = p.stateAt(at(25));
    expect(st.visual!.item.id, 'v');
    expect(st.audio.map((c) => c.item.id), unorderedEquals(['music', 'voice']));
  });

  test('joining late starts from where the item would be by now', () {
    final p = plan([item('a', at: 60, from: 5, length: 300)]);
    expect(p.stateAt(at(180)).visual!.position, const Duration(seconds: 125));
  });

  test('volume follows the fade envelope', () {
    final p = plan([item('a', length: 100, volume: 80, fadeIn: 10, fadeOut: 20)]);
    expect(p.stateAt(at(0)).visual!.volume, 0);
    expect(p.stateAt(at(5)).visual!.volume, closeTo(0.4, 1e-9));
    expect(p.stateAt(at(50)).visual!.volume, closeTo(0.8, 1e-9));
    expect(p.stateAt(at(90)).visual!.volume, closeTo(0.4, 1e-9));
  });

  test('an item of unknown length runs until the player reports its end', () {
    final p = plan([item('a')]);
    expect(p.stateAt(at(1000)).visual, isNotNull);
    expect(p.stateAt(at(1000)).finished, isFalse);
    p.endedAt[occurrenceKey(p.schedule.items.single)] = at(1000);
    expect(p.stateAt(at(1000)).visual, isNull);
    expect(p.stateAt(at(1000)).finished, isTrue);
  });

  test('pictures stay for the default time when no length is set', () {
    final p = plan([item('pic', kind: MediaKind.image)]);
    expect(p.stateAt(at(9)).visual, isNotNull);
    expect(p.stateAt(at(10)).visual, isNull);
  });

  test('output window spans the screen items, opening slightly early', () {
    final p = plan([
      item('music', kind: MediaKind.audio, length: 300),
      item('v1', at: 60, length: 10),
      item('v2', at: 120, length: 10),
    ]);
    expect(p.stateAt(at(57)).outputNeeded, isFalse);
    expect(p.stateAt(at(58)).outputNeeded, isTrue);
    expect(p.stateAt(at(90)).outputNeeded, isTrue);
    expect(p.stateAt(at(130)).outputNeeded, isFalse);
    expect(p.stateAt(at(130)).finished, isFalse);
  });

  test('reports the next item to start', () {
    final p = plan([item('a', at: 10, length: 5), item('b', at: 30, length: 5)]);
    expect(p.stateAt(at(0)).next!.item.id, 'a');
    expect(p.stateAt(at(12)).next!.item.id, 'b');
    expect(p.stateAt(at(31)).next, isNull);
  });

  test('an empty schedule is finished at once', () {
    expect(plan([]).stateAt(t0).finished, isTrue);
  });
}
