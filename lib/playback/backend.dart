import '../core/model.dart';

/// Where and how the screen layer is shown.
class OutputConfig {
  const OutputConfig({this.screen = 0, this.fullscreen = true, this.onTop = false});

  /// Monitor index, in the system's monitor order.
  final int screen;
  final bool fullscreen;
  final bool onTop;

  OutputConfig copyWith({int? screen, bool? fullscreen, bool? onTop}) =>
      OutputConfig(
        screen: screen ?? this.screen,
        fullscreen: fullscreen ?? this.fullscreen,
        onTop: onTop ?? this.onTop,
      );

  Map<String, Object?> toJson() =>
      {'screen': screen, 'fullscreen': fullscreen, 'onTop': onTop};

  factory OutputConfig.fromJson(Map<String, Object?> j) => OutputConfig(
        screen: (j['screen'] as num?)?.toInt() ?? 0,
        fullscreen: (j['fullscreen'] as bool?) ?? true,
        onTop: (j['onTop'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is OutputConfig &&
      other.screen == screen &&
      other.fullscreen == fullscreen &&
      other.onTop == onTop;

  @override
  int get hashCode => Object.hash(screen, fullscreen, onTop);
}

/// Media playback as the runner needs it: one screen layer in an output window
/// and any number of audio players. Volumes are 0.0–1.0.
abstract class PlaybackBackend {
  bool get outputOpen;

  /// Opens the output window, black until something is shown.
  Future<void> openOutput(OutputConfig config);
  Future<void> closeOutput();

  /// Plays [item] on the screen layer from [position] (pictures ignore it).
  Future<void> playVisual(
      String key, ScheduleItem item, Duration position, double volume);

  /// Shows a picture between items.
  Future<void> showPicture(String path);

  /// Leaves the output window black.
  Future<void> clearVisual();
  Future<void> setVisualVolume(double volume);
  Future<void> seekVisual(Duration position);

  /// Current file position of the screen layer, if known.
  Duration? get visualPosition;

  /// The file on the screen layer has played to its end.
  bool get visualCompleted;

  Future<void> startAudio(
      String key, ScheduleItem item, Duration position, double volume);
  Future<void> setAudioVolume(String key, double volume);
  Future<void> stopAudio(String key);
  bool audioCompleted(String key);

  /// Stops all playback; the output window stays as it is.
  Future<void> stopAll();

  /// Called when the item identified by `key` cannot be played.
  void Function(String key, String message)? onError;
}
