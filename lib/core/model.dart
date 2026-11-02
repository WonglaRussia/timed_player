/// Schedule data model and its JSON file format.
library;

import 'dart:math';

import 'package:path/path.dart' as p;

enum MediaKind {
  video,
  audio,
  image;

  /// Video and pictures share the single screen layer; audio plays alongside.
  bool get isVisual => this != MediaKind.audio;

  String get label => switch (this) {
        MediaKind.video => 'Видео',
        MediaKind.audio => 'Аудио',
        MediaKind.image => 'Картинка',
      };
}

const _videoExt = {
  'mp4', 'm4v', 'mkv', 'avi', 'mov', 'wmv', 'webm', 'mpg', 'mpeg', 'ts', //
  'm2ts', 'mts', 'flv', '3gp', 'ogv', 'vob',
};
const _audioExt = {
  'mp3', 'wav', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'wma', 'aif', //
  'aiff', 'ape', 'mka', 'ac3',
};
const _imageExt = {'jpg', 'jpeg', 'png', 'bmp', 'gif', 'webp', 'tif', 'tiff'};

/// Every extension the file picker offers.
final mediaExtensions = [..._videoExt, ..._audioExt, ..._imageExt];
final imageExtensions = [..._imageExt];

/// Guesses the kind from the file extension; unknown files are tried as video.
MediaKind kindForPath(String path) {
  final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
  if (_audioExt.contains(ext)) return MediaKind.audio;
  if (_imageExt.contains(ext)) return MediaKind.image;
  return MediaKind.video;
}

/// How long a picture stays on screen when no length is set.
const defaultImageLength = Duration(seconds: 10);

final _random = Random();

String newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    _random.nextInt(1 << 30).toRadixString(36);

const _keep = Object();

class ScheduleItem {
  const ScheduleItem({
    required this.id,
    required this.path,
    required this.kind,
    this.offset = Duration.zero,
    this.from = Duration.zero,
    this.length,
    this.mediaLength,
    this.volume = 100,
    this.fadeIn = Duration.zero,
    this.fadeOut = Duration.zero,
    this.title,
  });

  final String id;

  /// Absolute path of the media file.
  final String path;
  final MediaKind kind;

  /// When the item starts, counted from the start of the schedule.
  final Duration offset;

  /// Position in the file to play from.
  final Duration from;

  /// How long to play; null plays to the end of the file.
  final Duration? length;

  /// Length of the file itself when known; null for pictures.
  final Duration? mediaLength;

  /// 0–100 %.
  final int volume;
  final Duration fadeIn;
  final Duration fadeOut;
  final String? title;

  /// How long the item stays on; null when it plays to the end of a file whose
  /// length is unknown.
  Duration? get playLength {
    if (length != null) return length;
    if (kind == MediaKind.image) return defaultImageLength;
    final m = mediaLength;
    if (m == null) return null;
    final rest = m - from;
    return rest.isNegative ? Duration.zero : rest;
  }

  Duration? get endOffset {
    final l = playLength;
    return l == null ? null : offset + l;
  }

  String get displayName =>
      (title != null && title!.trim().isNotEmpty) ? title!.trim() : p.basename(path);

  ScheduleItem copyWith({
    String? id,
    String? path,
    MediaKind? kind,
    Duration? offset,
    Duration? from,
    Object? length = _keep,
    Object? mediaLength = _keep,
    int? volume,
    Duration? fadeIn,
    Duration? fadeOut,
    Object? title = _keep,
  }) =>
      ScheduleItem(
        id: id ?? this.id,
        path: path ?? this.path,
        kind: kind ?? this.kind,
        offset: offset ?? this.offset,
        from: from ?? this.from,
        length: identical(length, _keep) ? this.length : length as Duration?,
        mediaLength: identical(mediaLength, _keep)
            ? this.mediaLength
            : mediaLength as Duration?,
        volume: volume ?? this.volume,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
        title: identical(title, _keep) ? this.title : title as String?,
      );

  Map<String, Object?> toJson(String? baseDir) => {
        'id': id,
        'path': _storePath(path, baseDir),
        'kind': kind.name,
        'offsetMs': offset.inMilliseconds,
        'fromMs': from.inMilliseconds,
        'lengthMs': length?.inMilliseconds,
        'mediaLengthMs': mediaLength?.inMilliseconds,
        'volume': volume,
        'fadeInMs': fadeIn.inMilliseconds,
        'fadeOutMs': fadeOut.inMilliseconds,
        if (title != null) 'title': title,
      };

  factory ScheduleItem.fromJson(Map<String, Object?> j, String? baseDir) {
    final path = _loadPath(j['path'] as String, baseDir);
    return ScheduleItem(
      id: (j['id'] as String?) ?? newId(),
      path: path,
      kind: MediaKind.values.asNameMap()[j['kind']] ?? kindForPath(path),
      offset: _ms(j['offsetMs']) ?? Duration.zero,
      from: _ms(j['fromMs']) ?? Duration.zero,
      length: _ms(j['lengthMs']),
      mediaLength: _ms(j['mediaLengthMs']),
      volume: ((j['volume'] as num?) ?? 100).round().clamp(0, 100),
      fadeIn: _ms(j['fadeInMs']) ?? Duration.zero,
      fadeOut: _ms(j['fadeOutMs']) ?? Duration.zero,
      title: j['title'] as String?,
    );
  }
}

enum StartMode {
  /// Starts when the Start button is pressed.
  manual,

  /// Starts once at a set date and time.
  once,

  /// Starts at a set time of day on the chosen weekdays.
  weekly,
}

class StartRule {
  const StartRule({
    this.mode = StartMode.manual,
    this.at,
    this.timeOfDay = Duration.zero,
    this.weekdays = const {1, 2, 3, 4, 5, 6, 7},
  });

  final StartMode mode;

  /// Moment of the single start ([StartMode.once]).
  final DateTime? at;

  /// Start time counted from midnight ([StartMode.weekly]).
  final Duration timeOfDay;

  /// [DateTime.monday]..[DateTime.sunday] ([StartMode.weekly]).
  final Set<int> weekdays;

  StartRule copyWith({
    StartMode? mode,
    Object? at = _keep,
    Duration? timeOfDay,
    Set<int>? weekdays,
  }) =>
      StartRule(
        mode: mode ?? this.mode,
        at: identical(at, _keep) ? this.at : at as DateTime?,
        timeOfDay: timeOfDay ?? this.timeOfDay,
        weekdays: weekdays ?? this.weekdays,
      );

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        if (at != null) 'at': at!.toIso8601String(),
        'timeOfDayMs': timeOfDay.inMilliseconds,
        'weekdays': (weekdays.toList()..sort()),
      };

  factory StartRule.fromJson(Map<String, Object?> j) => StartRule(
        mode: StartMode.values.asNameMap()[j['mode']] ?? StartMode.manual,
        at: j['at'] == null ? null : DateTime.tryParse(j['at'] as String),
        timeOfDay: _ms(j['timeOfDayMs']) ?? Duration.zero,
        weekdays: ((j['weekdays'] as List?) ?? const [1, 2, 3, 4, 5, 6, 7])
            .map((e) => (e as num).toInt())
            .where((d) => d >= 1 && d <= 7)
            .toSet(),
      );
}

class Schedule {
  const Schedule({
    this.name = 'Новое расписание',
    this.start = const StartRule(),
    this.idleImage,
    this.items = const [],
  });

  final String name;
  final StartRule start;

  /// Picture shown between visual items instead of black.
  final String? idleImage;
  final List<ScheduleItem> items;

  /// Time from the schedule start to the end of its last item. Items of
  /// unknown length count up to their start only.
  Duration get span {
    var end = Duration.zero;
    for (final i in items) {
      final e = i.endOffset ?? i.offset;
      if (e > end) end = e;
    }
    return end;
  }

  Schedule copyWith({
    String? name,
    StartRule? start,
    Object? idleImage = _keep,
    List<ScheduleItem>? items,
  }) =>
      Schedule(
        name: name ?? this.name,
        start: start ?? this.start,
        idleImage:
            identical(idleImage, _keep) ? this.idleImage : idleImage as String?,
        items: items ?? this.items,
      );

  static const format = 'timed_player/1';

  /// [baseDir] is the folder of the schedule file: media inside it are stored
  /// by relative path so the folder can be moved to another computer.
  Map<String, Object?> toJson(String? baseDir) => {
        'format': format,
        'name': name,
        'start': start.toJson(),
        if (idleImage != null) 'idleImage': _storePath(idleImage!, baseDir),
        'items': [for (final i in items) i.toJson(baseDir)],
      };

  factory Schedule.fromJson(Map<String, Object?> j, String? baseDir) {
    final fmt = j['format'];
    if (fmt is String && !fmt.startsWith('timed_player/')) {
      throw FormatException('Это не файл расписания: $fmt');
    }
    return Schedule(
      name: (j['name'] as String?) ?? 'Расписание',
      start: j['start'] is Map
          ? StartRule.fromJson((j['start'] as Map).cast<String, Object?>())
          : const StartRule(),
      idleImage: j['idleImage'] == null
          ? null
          : _loadPath(j['idleImage'] as String, baseDir),
      items: [
        for (final e in (j['items'] as List? ?? const []))
          ScheduleItem.fromJson((e as Map).cast<String, Object?>(), baseDir),
      ],
    );
  }
}

Duration? _ms(Object? v) =>
    v == null ? null : Duration(milliseconds: (v as num).round());

String _storePath(String path, String? baseDir) {
  if (baseDir != null && p.isWithin(baseDir, path)) {
    return p.split(p.relative(path, from: baseDir)).join('/');
  }
  return path;
}

String _loadPath(String stored, String? baseDir) {
  if (baseDir == null) return stored;
  final isAbsolute = p.isAbsolute(stored) || p.windows.isAbsolute(stored);
  return isAbsolute ? stored : p.normalize(p.join(baseDir, stored));
}
