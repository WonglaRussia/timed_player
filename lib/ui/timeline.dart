import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/model.dart';
import '../core/timefmt.dart';

Color kindColor(MediaKind kind) => switch (kind) {
      MediaKind.video => const Color(0xFFE53935),
      MediaKind.image => const Color(0xFFFFA000),
      MediaKind.audio => const Color(0xFF00897B),
    };

const _rulerH = 28.0;
const _visualH = 46.0;
const _audioH = 30.0;
const _rowGap = 4.0;
const _gap = 6.0;
const _pad = 12.0;

/// Width given to items whose length is not known yet.
const _unknownLength = Duration(seconds: 10);

const _steps = [
  100, 200, 500, 1000, 2000, 5000, 10000, 15000, 30000, 60000, 120000, //
  300000, 600000, 900000, 1800000, 3600000, 7200000, 10800000, 21600000,
  43200000, 86400000,
];

class _Block {
  _Block(this.item, this.rect, this.offset, this.length, this.openEnded);

  final ScheduleItem item;
  final Rect rect;
  final Duration offset;
  final Duration length;
  final bool openEnded;
}

/// Block positions for one zoom level; shared by painting and hit-testing.
class _Layout {
  _Layout(List<ScheduleItem> items, this.pps,
      {String? dragId, Duration? dragOffset, Duration? dragLength}) {
    final placed = [
      for (final i in items)
        (
          item: i,
          offset: i.id == dragId && dragOffset != null ? dragOffset : i.offset,
          length: i.id == dragId && dragLength != null
              ? dragLength
              : i.playLength ?? _unknownLength,
          openEnded: i.playLength == null && !(i.id == dragId && dragLength != null),
        ),
    ]..sort((a, b) => a.offset.compareTo(b.offset));

    const visualTop = _rulerH + _gap;
    const audioTop = visualTop + _visualH + _gap;
    final rowEnds = <Duration>[];
    for (final e in placed) {
      final x = xOf(e.offset);
      final w = math.max(3.0, e.length.inMicroseconds / 1e6 * pps);
      Rect rect;
      if (e.item.kind.isVisual) {
        rect = Rect.fromLTWH(x, visualTop, w, _visualH);
      } else {
        var row = rowEnds.indexWhere((end) => end <= e.offset);
        if (row < 0) {
          row = rowEnds.length;
          rowEnds.add(Duration.zero);
        }
        rowEnds[row] = e.offset + e.length;
        rect = Rect.fromLTWH(x, audioTop + row * (_audioH + _rowGap), w, _audioH);
      }
      blocks.add(_Block(e.item, rect, e.offset, e.length, e.openEnded));
      final end = e.offset + e.length;
      if (end > span) span = end;
    }
    audioRows = math.max(1, rowEnds.length);
  }

  final double pps;
  final blocks = <_Block>[];
  Duration span = Duration.zero;
  late final int audioRows;

  static const visualTop = _rulerH + _gap;
  static const audioTop = visualTop + _visualH + _gap;

  double get height => audioTop + audioRows * (_audioH + _rowGap) + _gap;
  double xOf(Duration d) => _pad + d.inMicroseconds / 1e6 * pps;
  Duration timeAt(double x) =>
      Duration(microseconds: ((x - _pad) / pps * 1e6).round());

  _Block? hit(Offset pos) {
    // Topmost first: blocks are painted in order.
    for (final b in blocks.reversed) {
      if (b.rect.inflate(2).contains(pos)) return b;
    }
    return null;
  }
}

enum _DragKind { move, resize, cursor }

class _Drag {
  _Drag(this.kind, {this.id, this.grab = 0, this.offset = Duration.zero, this.length = Duration.zero});

  final _DragKind kind;
  final String? id;

  /// Distance from the block's left edge to the pointer.
  final double grab;
  Duration offset;
  Duration length;
}

/// Horizontal timeline in the spirit of the sketch: screen items (video and
/// pictures) in one lane, audio in lanes below. Blocks can be dragged to a new
/// start time or stretched by their right edge.
class Timeline extends StatefulWidget {
  const Timeline({
    super.key,
    required this.schedule,
    required this.selectedId,
    required this.cursor,
    required this.onSelect,
    required this.onMove,
    required this.onResize,
    required this.onCursor,
    required this.onOpen,
    this.playhead,
    this.clockAnchor,
  });

  final Schedule schedule;
  final String? selectedId;
  final Duration cursor;
  final Duration? playhead;

  /// When set, the ruler shows wall-clock times counted from it.
  final DateTime? clockAnchor;
  final ValueChanged<String?> onSelect;
  final void Function(String id, Duration offset) onMove;
  final void Function(String id, Duration length) onResize;
  final ValueChanged<Duration> onCursor;
  final ValueChanged<String> onOpen;

  @override
  State<Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<Timeline> {
  final _scroll = ScrollController();
  double? _pps;
  double _viewport = 800;
  _Drag? _drag;
  Offset _doubleTapAt = Offset.zero;

  static const _minPps = 0.005;
  static const _maxPps = 400.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double _fitPps() {
    final span = _Layout(widget.schedule.items, 1).span;
    final seconds = math.max(20.0, span.inMilliseconds / 1000 * 1.05);
    return ((_viewport - 2 * _pad) / seconds).clamp(_minPps, _maxPps);
  }

  void _fit() => setState(() {
        _pps = _fitPps();
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });

  void _zoom(double factor, double anchorX) {
    final old = _pps ?? _fitPps();
    final next = (old * factor).clamp(_minPps, _maxPps);
    final scrollOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    final contentX = scrollOffset + anchorX;
    setState(() => _pps = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = (contentX - _pad) * next / old + _pad - anchorX;
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final scroll = e as PointerScrollEvent;
      if (HardwareKeyboard.instance.isControlPressed) {
        _zoom(scroll.scrollDelta.dy < 0 ? 1.25 : 0.8, scroll.localPosition.dx);
      } else if (_scroll.hasClients) {
        final delta = scroll.scrollDelta.dy + scroll.scrollDelta.dx;
        _scroll.jumpTo((_scroll.offset + delta)
            .clamp(0.0, _scroll.position.maxScrollExtent));
      }
    });
  }

  _Layout _layout() => _Layout(
        widget.schedule.items,
        _pps!,
        dragId: _drag?.id,
        dragOffset: _drag?.kind == _DragKind.move ? _drag!.offset : null,
        dragLength: _drag?.kind == _DragKind.resize ? _drag!.length : null,
      );

  /// Rounds [t] to a grid that suits the zoom, or pulls it to a nearby block
  /// edge, the cursor or zero.
  Duration _snap(Duration t, _Layout layout, String id, Duration length) {
    const magnet = 8.0;
    Duration? best;
    var bestDistance = magnet;
    void consider(Duration candidate) {
      final d = (layout.xOf(candidate) - layout.xOf(t)).abs();
      if (d < bestDistance) {
        bestDistance = d;
        best = candidate;
      }
    }

    final edges = <Duration>[Duration.zero, widget.cursor];
    for (final b in layout.blocks) {
      if (b.item.id == id) continue;
      edges
        ..add(b.offset)
        ..add(b.offset + b.length);
    }
    for (final e in edges) {
      consider(e);
      if (length > Duration.zero) consider(e - length);
    }
    if (best != null) return best!.isNegative ? Duration.zero : best!;
    final step = _steps.firstWhere((s) => s * layout.pps / 1000 >= 6,
        orElse: () => _steps.last);
    final snapped =
        Duration(milliseconds: (t.inMilliseconds / step).round() * step);
    return snapped.isNegative ? Duration.zero : snapped;
  }

  void _dragStart(DragStartDetails d) {
    final layout = _layout();
    final pos = d.localPosition;
    final b = pos.dy > _rulerH ? layout.hit(pos) : null;
    if (b == null) {
      _drag = _Drag(_DragKind.cursor);
      widget.onCursor(_clamp(layout.timeAt(pos.dx)));
      return;
    }
    widget.onSelect(b.item.id);
    final resize = !b.openEnded && (pos.dx - b.rect.right).abs() <= 6;
    setState(() {
      _drag = _Drag(
        resize ? _DragKind.resize : _DragKind.move,
        id: b.item.id,
        grab: pos.dx - b.rect.left,
        offset: b.offset,
        length: b.length,
      );
    });
  }

  void _dragUpdate(DragUpdateDetails d) {
    final drag = _drag;
    if (drag == null) return;
    final layout = _layout();
    final x = d.localPosition.dx;
    switch (drag.kind) {
      case _DragKind.cursor:
        widget.onCursor(_clamp(layout.timeAt(x)));
      case _DragKind.move:
        final t = _clamp(layout.timeAt(x - drag.grab));
        setState(() => drag.offset = _snap(t, layout, drag.id!, drag.length));
      case _DragKind.resize:
        final end = _snap(_clamp(layout.timeAt(x)), layout, drag.id!, Duration.zero);
        final length = end - drag.offset;
        setState(() => drag.length =
            length < const Duration(milliseconds: 100) ? const Duration(milliseconds: 100) : length);
    }
  }

  void _dragEnd() {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = null);
    switch (drag.kind) {
      case _DragKind.cursor:
        break;
      case _DragKind.move:
        widget.onMove(drag.id!, drag.offset);
      case _DragKind.resize:
        widget.onResize(drag.id!, drag.length);
    }
  }

  Duration _clamp(Duration t) => t.isNegative ? Duration.zero : t;

  void _tap(TapUpDetails d) {
    final layout = _layout();
    final b = d.localPosition.dy > _rulerH ? layout.hit(d.localPosition) : null;
    if (b != null) {
      widget.onSelect(b.item.id);
    } else {
      widget.onSelect(null);
      widget.onCursor(_clamp(layout.timeAt(d.localPosition.dx)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      _viewport = math.max(200, constraints.maxWidth - 70);
      _pps ??= _fitPps();
      final layout = _layout();
      final span = math.max(layout.span.inMilliseconds,
          (widget.playhead ?? Duration.zero).inMilliseconds);
      final contentWidth = math.max(
          _viewport, _pad * 2 + (span / 1000 + 30) * layout.pps);
      final height = layout.height;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text('Шкала', style: theme.textTheme.titleSmall),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Перетащите блок, чтобы сдвинуть; правый край — длина. '
                    'Ctrl+колесо — масштаб. Щелчок по пустому месту ставит курсор.',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Уменьшить',
                  icon: const Icon(Icons.zoom_out),
                  onPressed: () => _zoom(0.66, _viewport / 2),
                ),
                IconButton(
                  tooltip: 'Увеличить',
                  icon: const Icon(Icons.zoom_in),
                  onPressed: () => _zoom(1.5, _viewport / 2),
                ),
                IconButton(
                  tooltip: 'Вписать всё',
                  icon: const Icon(Icons.fit_screen),
                  onPressed: _fit,
                ),
              ],
            ),
          ),
          SizedBox(
            height: height + 12,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 62,
                  height: height,
                  child: _LaneLabels(
                    audioRows: layout.audioRows,
                    clock: widget.clockAnchor != null,
                  ),
                ),
                Expanded(
                  child: Listener(
                    onPointerSignal: _onSignal,
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        scrollDirection: Axis.horizontal,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: _tap,
                          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
                          onDoubleTap: () {
                            final b = _layout().hit(_doubleTapAt);
                            if (b != null) widget.onOpen(b.item.id);
                          },
                          onHorizontalDragStart: _dragStart,
                          onHorizontalDragUpdate: _dragUpdate,
                          onHorizontalDragEnd: (_) => _dragEnd(),
                          onHorizontalDragCancel: _dragEnd,
                          child: CustomPaint(
                            size: Size(contentWidth, height),
                            painter: _Painter(
                              layout: layout,
                              scroll: _scroll,
                              viewport: _viewport,
                              selectedId: widget.selectedId,
                              cursor: widget.cursor,
                              playhead: widget.playhead,
                              clockAnchor: widget.clockAnchor,
                              drag: _drag,
                              colors: theme.colorScheme,
                              textStyle: theme.textTheme.bodySmall!,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _LaneLabels extends StatelessWidget {
  const _LaneLabels({required this.audioRows, required this.clock});

  final int audioRows;
  final bool clock;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    Widget label(String text, double top, double height) => Positioned(
          left: 8,
          top: top,
          height: height,
          child: Align(
              alignment: Alignment.centerLeft, child: Text(text, style: style)),
        );
    return Stack(children: [
      label(clock ? 'Часы' : 'T+', 0, _rulerH),
      label('Экран', _Layout.visualTop, _visualH),
      label('Звук', _Layout.audioTop, audioRows * (_audioH + _rowGap)),
    ]);
  }
}

class _Painter extends CustomPainter {
  _Painter({
    required this.layout,
    required this.scroll,
    required this.viewport,
    required this.selectedId,
    required this.cursor,
    required this.playhead,
    required this.clockAnchor,
    required this.drag,
    required this.colors,
    required this.textStyle,
  }) : super(repaint: scroll);

  final _Layout layout;
  final ScrollController scroll;
  final double viewport;
  final String? selectedId;
  final Duration cursor;
  final Duration? playhead;
  final DateTime? clockAnchor;
  final _Drag? drag;
  final ColorScheme colors;
  final TextStyle textStyle;

  void _text(Canvas canvas, String text, Offset at,
      {Color? color, double? maxWidth, FontWeight? weight}) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: textStyle.copyWith(color: color, fontWeight: weight)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    tp.paint(canvas, at);
  }

  String _label(Duration t, bool fine) {
    final anchor = clockAnchor;
    if (anchor != null) {
      final c = anchor.add(t);
      final ms = fine ? '.${(c.millisecond ~/ 100)}' : '';
      return '${formatClock(c)}$ms';
    }
    return formatDuration(t, millis: fine);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final left = scroll.hasClients ? scroll.offset : 0.0;
    final right = left + viewport + 80;
    final pps = layout.pps;

    final lane = Paint()..color = colors.surfaceContainerHighest.withValues(alpha: 0.5);
    canvas.drawRect(
        Rect.fromLTWH(left, _Layout.visualTop, right - left, _visualH), lane);
    canvas.drawRect(
        Rect.fromLTWH(left, _Layout.audioTop, right - left,
            layout.audioRows * (_audioH + _rowGap) - _rowGap),
        lane);

    // Ruler.
    final major = _steps.firstWhere((s) => s * pps / 1000 >= 90,
        orElse: () => _steps.last);
    final minor = _steps.firstWhere(
        (s) => s * pps / 1000 >= 12 && major % s == 0,
        orElse: () => major);
    final tick = Paint()
      ..color = colors.outline
      ..strokeWidth = 1;
    final grid = Paint()
      ..color = colors.outlineVariant.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final first = math.max(0, layout.timeAt(left).inMilliseconds ~/ minor * minor);
    final last = layout.timeAt(right).inMilliseconds;
    for (var ms = first; ms <= last; ms += minor) {
      final x = layout.xOf(Duration(milliseconds: ms));
      final isMajor = ms % major == 0;
      canvas.drawLine(Offset(x, isMajor ? 4 : _rulerH - 8), Offset(x, _rulerH), tick);
      if (isMajor) {
        canvas.drawLine(Offset(x, _rulerH), Offset(x, size.height), grid);
        _text(canvas, _label(Duration(milliseconds: ms), major < 1000),
            Offset(x + 3, 2),
            color: colors.onSurfaceVariant);
      }
    }
    canvas.drawLine(Offset(left, _rulerH), Offset(right, _rulerH), tick);

    // Blocks.
    for (final b in layout.blocks) {
      if (b.rect.right < left || b.rect.left > right) continue;
      final color = kindColor(b.item.kind);
      final rrect = RRect.fromRectAndRadius(b.rect, const Radius.circular(4));
      final fill = Paint();
      if (b.openEnded) {
        fill.shader = LinearGradient(colors: [color, color.withValues(alpha: 0.15)])
            .createShader(b.rect);
      } else {
        fill.color = color;
      }
      canvas.drawRRect(rrect, fill);

      // Fades as darker wedges.
      final shade = Paint()..color = Colors.black.withValues(alpha: 0.35);
      final fadeIn = b.item.fadeIn.inMicroseconds / 1e6 * pps;
      if (fadeIn > 1) {
        canvas.drawPath(
            Path()
              ..moveTo(b.rect.left, b.rect.top)
              ..lineTo(b.rect.left + math.min(fadeIn, b.rect.width), b.rect.top)
              ..lineTo(b.rect.left, b.rect.bottom)
              ..close(),
            shade);
      }
      final fadeOut = b.item.fadeOut.inMicroseconds / 1e6 * pps;
      if (fadeOut > 1 && !b.openEnded) {
        canvas.drawPath(
            Path()
              ..moveTo(b.rect.right, b.rect.top)
              ..lineTo(b.rect.right - math.min(fadeOut, b.rect.width), b.rect.top)
              ..lineTo(b.rect.right, b.rect.bottom)
              ..close(),
            shade);
      }

      final selected = b.item.id == selectedId;
      canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = selected ? 2.5 : 1
            ..color = selected ? Colors.white : Colors.black.withValues(alpha: 0.4));

      if (b.rect.width > 24) {
        final visibleLeft = math.max(b.rect.left, left) + 4;
        final maxWidth = b.rect.right - visibleLeft - 4;
        if (maxWidth > 12) {
          _text(canvas, b.item.displayName, Offset(visibleLeft, b.rect.top + 3),
              color: Colors.white, maxWidth: maxWidth, weight: FontWeight.w600);
          if (b.item.kind.isVisual) {
            _text(
                canvas,
                '${_label(b.offset, false)} · ${formatDuration(b.length)}'
                '${b.openEnded ? '…' : ''}',
                Offset(visibleLeft, b.rect.top + 22),
                color: Colors.white70,
                maxWidth: maxWidth);
          }
        }
      }
    }

    // While dragging, show the exact time next to the block.
    final d = drag;
    if (d != null && d.kind != _DragKind.cursor) {
      final shown = d.kind == _DragKind.move ? d.offset : d.offset + d.length;
      final x = layout.xOf(shown);
      _text(canvas, _label(shown, pps > 100), Offset(x + 4, _rulerH + 1),
          color: colors.primary, weight: FontWeight.bold);
    }

    final cursorX = layout.xOf(cursor);
    final cursorPaint = Paint()
      ..color = colors.primary
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(cursorX, 0), Offset(cursorX, size.height), cursorPaint);
    canvas.drawPath(
        Path()
          ..moveTo(cursorX - 6, 0)
          ..lineTo(cursorX + 6, 0)
          ..lineTo(cursorX, 9)
          ..close(),
        Paint()..color = colors.primary);

    final ph = playhead;
    if (ph != null && !ph.isNegative) {
      final x = layout.xOf(ph);
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = Colors.greenAccent
            ..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_Painter old) => true;
}
