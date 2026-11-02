import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../core/model.dart';
import 'backend.dart';

/// Desktop playback on libmpv. The screen layer is a separate mpv window
/// (fullscreen on the chosen monitor, black when idle); every audio item gets
/// its own player without video.
class MpvBackend implements PlaybackBackend {
  static const _windowTitle = 'Timed Player — вывод';

  /// Keys inside the output window. Esc leaves fullscreen so a single-monitor
  /// computer can reach the editor; closing the window is ignored because the
  /// schedule owns it.
  static const _bindings = 'ESC set fullscreen no\n'
      'f cycle fullscreen\n'
      'CLOSE_WIN ignore\n'
      'q ignore\n';

  Player? _visual;
  String? _visualKey;
  final List<StreamSubscription<Object>> _visualSubs = [];
  final Map<String, Player> _audio = {};
  final Map<String, List<StreamSubscription<Object>>> _audioSubs = {};
  String? _lastLog;

  @override
  void Function(String key, String message)? onError;

  /// Errors reported by mpv itself (window, decoder, audio device).
  void Function(String message)? onLog;

  StreamSubscription<Object> _logs(Player player) =>
      player.stream.log.listen((log) {
        // media_kit sets options this libmpv build lacks (osc); harmless.
        if (log.prefix == 'media_kit' && log.text.contains('property not found')) {
          return;
        }
        final line = '${log.prefix}: ${log.text.trim()}';
        if (line == _lastLog) return;
        _lastLog = line;
        onLog?.call(line);
      });

  @override
  bool get outputOpen => _visual != null;

  NativePlayer _mpv(Player p) => p.platform as NativePlayer;

  @override
  Future<void> openOutput(OutputConfig config) async {
    if (_visual != null) return;
    final player = Player(
      configuration: const PlayerConfiguration(vo: 'gpu', title: _windowTitle),
    );
    _visual = player;
    final mpv = _mpv(player);
    final properties = {
      // media_kit turns video off until a VideoController attaches; here mpv
      // draws into its own window instead.
      'vid': 'auto',
      'hwdec': 'auto-safe',
      // Local files need no disk cache, and libmpv has no folder for one.
      'cache-on-disk': 'no',
      'screen': '${config.screen}',
      'fs-screen': '${config.screen}',
      'fullscreen': config.fullscreen ? 'yes' : 'no',
      'ontop': config.onTop ? 'yes' : 'no',
      'cursor-autohide': 'always',
      'image-display-duration': 'inf',
      'input-vo-keyboard': 'yes',
      'force-window': 'yes',
    };
    for (final e in properties.entries) {
      await mpv.setProperty(e.key, e.value);
    }
    await mpv.command(['define-section', 'timed_player', _bindings, 'force']);
    await mpv.command(['enable-section', 'timed_player']);
    _visualSubs
      ..add(player.stream.error.listen((message) {
        final key = _visualKey;
        if (key != null) onError?.call(key, message);
      }))
      ..add(_logs(player));
  }

  @override
  Future<void> closeOutput() async {
    final player = _visual;
    if (player == null) return;
    _visual = null;
    _visualKey = null;
    for (final s in _visualSubs) {
      await s.cancel();
    }
    _visualSubs.clear();
    await player.dispose();
  }

  Media _media(ScheduleItem item, Duration position) => Media(
        item.path,
        start: item.kind == MediaKind.image || position <= Duration.zero
            ? null
            : position,
      );

  @override
  Future<void> playVisual(
      String key, ScheduleItem item, Duration position, double volume) async {
    final player = _visual;
    if (player == null) return;
    _visualKey = key;
    await player.setVolume(volume * 100);
    await player.open(_media(item, position), play: true);
  }

  @override
  Future<void> showPicture(String path) async {
    final player = _visual;
    if (player == null) return;
    _visualKey = null;
    await player.setVolume(0);
    await player.open(Media(path), play: true);
  }

  @override
  Future<void> clearVisual() async {
    _visualKey = null;
    await _visual?.stop();
  }

  @override
  Future<void> setVisualVolume(double volume) async =>
      _visual?.setVolume(volume * 100);

  @override
  Future<void> seekVisual(Duration position) async => _visual?.seek(position);

  @override
  Duration? get visualPosition => _visual?.state.position;

  @override
  bool get visualCompleted => _visual?.state.completed ?? false;

  @override
  Future<void> startAudio(
      String key, ScheduleItem item, Duration position, double volume) async {
    await stopAudio(key);
    final player = Player(
      configuration: PlayerConfiguration(title: 'Timed Player — ${item.displayName}'),
    );
    _audio[key] = player;
    _audioSubs[key] = [
      player.stream.error.listen((message) => onError?.call(key, message)),
      _logs(player),
    ];
    await _mpv(player).setProperty('cache-on-disk', 'no');
    await player.setVolume(volume * 100);
    await player.open(_media(item, position), play: true);
  }

  @override
  Future<void> setAudioVolume(String key, double volume) async =>
      _audio[key]?.setVolume(volume * 100);

  @override
  Future<void> stopAudio(String key) async {
    for (final s in _audioSubs.remove(key) ?? const <StreamSubscription<Object>>[]) {
      await s.cancel();
    }
    await _audio.remove(key)?.dispose();
  }

  @override
  bool audioCompleted(String key) => _audio[key]?.state.completed ?? false;

  @override
  Future<void> stopAll() async {
    for (final key in _audio.keys.toList()) {
      await stopAudio(key);
    }
    await clearVisual();
  }
}
