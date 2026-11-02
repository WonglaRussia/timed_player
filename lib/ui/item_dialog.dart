import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/model.dart';
import '../core/timefmt.dart';
import 'fields.dart';

/// Edits one schedule item. Returns the changed item, or null on cancel.
Future<ScheduleItem?> showItemDialog(
  BuildContext context, {
  required ScheduleItem item,
  required Future<Duration?> Function(String path) probe,
  DateTime? clockAnchor,
}) =>
    showDialog<ScheduleItem>(
      context: context,
      builder: (_) =>
          _ItemDialog(item: item, probe: probe, clockAnchor: clockAnchor),
    );

class _ItemDialog extends StatefulWidget {
  const _ItemDialog(
      {required this.item, required this.probe, required this.clockAnchor});

  final ScheduleItem item;
  final Future<Duration?> Function(String path) probe;
  final DateTime? clockAnchor;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  late ScheduleItem _item = widget.item;
  late final _title = TextEditingController(text: widget.item.title ?? '');
  final _invalid = <String>{};
  bool _probing = false;

  Duration? get _anchorTime {
    final a = widget.clockAnchor;
    if (a == null) return null;
    return Duration(
        hours: a.hour,
        minutes: a.minute,
        seconds: a.second,
        milliseconds: a.millisecond);
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _valid(String field, bool ok) =>
      setState(() => ok ? _invalid.remove(field) : _invalid.add(field));

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Файл для элемента',
      type: FileType.custom,
      allowedExtensions: mediaExtensions,
    );
    final path = file?.path;
    if (path == null) return;
    final kind = kindForPath(path);
    setState(() {
      _item = _item.copyWith(path: path, kind: kind, mediaLength: null);
      _probing = kind != MediaKind.image;
    });
    if (kind == MediaKind.image) return;
    final length = await widget.probe(path);
    if (!mounted) return;
    setState(() {
      _item = _item.copyWith(mediaLength: length);
      _probing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anchorTime = _anchorTime;
    final media = _item.mediaLength;
    final isImage = _item.kind == MediaKind.image;

    return AlertDialog(
      title: const Text('Элемент расписания'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(_item.path,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Другой файл…'),
                ),
              ]),
              const SizedBox(height: 4),
              Text(
                _probing
                    ? 'Определяю длину файла…'
                    : isImage
                        ? 'Картинка'
                        : media == null
                            ? 'Длина файла неизвестна'
                            : 'Длина файла: ${formatDuration(media, millis: true)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              SegmentedButton<MediaKind>(
                segments: [
                  for (final k in MediaKind.values)
                    ButtonSegment(value: k, label: Text(k.label)),
                ],
                selected: {_item.kind},
                onSelectionChanged: (s) =>
                    setState(() => _item = _item.copyWith(kind: s.single)),
              ),
              if (_item.kind == MediaKind.audio && kindForPath(_item.path) == MediaKind.video)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Из видеофайла будет звучать только звук.',
                      style: theme.textTheme.bodySmall),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Название (необязательно)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(spacing: 12, runSpacing: 12, children: [
                if (anchorTime != null)
                  DurationField(
                    label: 'Старт по часам',
                    value: anchorTime + _item.offset,
                    helper: 'от начала ${formatDuration(_item.offset, millis: true)}',
                    width: 170,
                    validate: (v) =>
                        v < anchorTime ? 'Раньше начала расписания' : null,
                    onValid: (ok) => _valid('start', ok),
                    onChanged: (v) => setState(
                        () => _item = _item.copyWith(offset: v! - anchorTime)),
                  )
                else
                  DurationField(
                    label: 'Старт от начала',
                    value: _item.offset,
                    width: 170,
                    onValid: (ok) => _valid('start', ok),
                    onChanged: (v) =>
                        setState(() => _item = _item.copyWith(offset: v)),
                  ),
                if (!isImage)
                  DurationField(
                    label: 'С позиции в файле',
                    value: _item.from,
                    width: 170,
                    validate: (v) => media != null && v >= media
                        ? 'Дальше конца файла'
                        : null,
                    onValid: (ok) => _valid('from', ok),
                    onChanged: (v) =>
                        setState(() => _item = _item.copyWith(from: v)),
                  ),
                DurationField(
                  label: 'Длительность',
                  value: _item.length,
                  emptyHint: isImage
                      ? formatDuration(defaultImageLength)
                      : 'до конца файла',
                  helper: _item.playLength == null
                      ? 'до конца файла'
                      : 'конец в ${formatDuration(_item.offset + _item.playLength!)}'
                          ' от начала',
                  width: 170,
                  validate: (v) => v <= Duration.zero ? 'Больше нуля' : null,
                  onValid: (ok) => _valid('length', ok),
                  onChanged: (v) =>
                      setState(() => _item = _item.copyWith(length: v)),
                ),
              ]),
              if (!isImage) ...[
                const SizedBox(height: 16),
                Row(children: [
                  const SizedBox(width: 90, child: Text('Громкость')),
                  Expanded(
                    child: Slider(
                      value: _item.volume.toDouble(),
                      max: 100,
                      divisions: 100,
                      label: '${_item.volume}%',
                      onChanged: (v) => setState(
                          () => _item = _item.copyWith(volume: v.round())),
                    ),
                  ),
                  SizedBox(width: 48, child: Text('${_item.volume}%')),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  DurationField(
                    label: 'Нарастание',
                    value: _item.fadeIn,
                    width: 170,
                    onValid: (ok) => _valid('fadeIn', ok),
                    onChanged: (v) =>
                        setState(() => _item = _item.copyWith(fadeIn: v)),
                  ),
                  DurationField(
                    label: 'Затухание',
                    value: _item.fadeOut,
                    width: 170,
                    helper: _item.playLength == null
                        ? 'нужна известная длина'
                        : null,
                    onValid: (ok) => _valid('fadeOut', ok),
                    onChanged: (v) =>
                        setState(() => _item = _item.copyWith(fadeOut: v)),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _invalid.isNotEmpty || _probing
              ? null
              : () {
                  final title = _title.text.trim();
                  Navigator.pop(
                      context, _item.copyWith(title: title.isEmpty ? null : title));
                },
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
