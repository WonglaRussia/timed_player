import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// Reads the length of a media file by opening it in a silent player.
/// Returns null when the file cannot be read within [timeout].
Future<Duration?> probeLength(String path,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final player = Player(
    configuration: const PlayerConfiguration(muted: true, title: 'probe'),
  );
  final result = Completer<Duration?>();
  final subs = [
    player.stream.duration.listen((d) {
      if (d > Duration.zero && !result.isCompleted) result.complete(d);
    }),
    player.stream.error.listen((_) {
      if (!result.isCompleted) result.complete(null);
    }),
  ];
  try {
    await (player.platform as NativePlayer).setProperty('cache-on-disk', 'no');
    await player.open(Media(path), play: false);
    return await result.future.timeout(timeout, onTimeout: () => null);
  } finally {
    for (final s in subs) {
      await s.cancel();
    }
    await player.dispose();
  }
}
