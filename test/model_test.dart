import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:timed_player/core/model.dart';

void main() {
  final base = p.join(p.current, 'shows');

  test('round-trips through JSON, storing media inside the folder relatively', () {
    final inside = p.join(base, 'clips', 'intro.mp4');
    final outside = p.join(p.current, 'elsewhere', 'music.mp3');
    final s = Schedule(
      name: 'Утро',
      start: StartRule(
        mode: StartMode.weekly,
        timeOfDay: const Duration(hours: 9),
        weekdays: const {1, 3, 5},
      ),
      idleImage: p.join(base, 'logo.png'),
      items: [
        ScheduleItem(
          id: 'x',
          path: inside,
          kind: MediaKind.video,
          offset: const Duration(minutes: 5),
          from: const Duration(seconds: 30),
          length: const Duration(seconds: 90),
          volume: 70,
          fadeIn: const Duration(seconds: 2),
          title: 'Заставка',
        ),
        ScheduleItem(id: 'y', path: outside, kind: MediaKind.audio),
      ],
    );

    final json = jsonEncode(s.toJson(base));
    final stored = jsonDecode(json) as Map<String, Object?>;
    final items = stored['items'] as List;
    expect((items[0] as Map)['path'], 'clips/intro.mp4');
    expect((items[1] as Map)['path'], outside);

    final back = Schedule.fromJson(stored, base);
    expect(back.name, 'Утро');
    expect(back.start.mode, StartMode.weekly);
    expect(back.start.weekdays, {1, 3, 5});
    expect(back.idleImage, p.join(base, 'logo.png'));
    expect(back.items[0].path, inside);
    expect(back.items[0].offset, const Duration(minutes: 5));
    expect(back.items[0].length, const Duration(seconds: 90));
    expect(back.items[0].volume, 70);
    expect(back.items[0].title, 'Заставка');
    expect(back.items[1].length, isNull);
    expect(back.items[1].kind, MediaKind.audio);
  });

  test('rejects files of another format', () {
    expect(() => Schedule.fromJson({'format': 'other/1'}, null),
        throwsFormatException);
  });

  test('guesses kind by extension', () {
    expect(kindForPath('a.MP3'), MediaKind.audio);
    expect(kindForPath('a.jpeg'), MediaKind.image);
    expect(kindForPath('a.mkv'), MediaKind.video);
    expect(kindForPath('a.unknown'), MediaKind.video);
  });

  test('span covers the last end', () {
    final s = Schedule(items: [
      const ScheduleItem(
          id: 'a', path: 'a', kind: MediaKind.video, length: Duration(seconds: 10)),
      const ScheduleItem(
          id: 'b',
          path: 'b',
          kind: MediaKind.audio,
          offset: Duration(seconds: 5),
          mediaLength: Duration(seconds: 20),
          from: Duration(seconds: 4)),
    ]);
    expect(s.span, const Duration(seconds: 21));
  });
}
