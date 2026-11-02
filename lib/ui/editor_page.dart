import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../core/engine.dart';
import '../core/model.dart';
import '../core/timefmt.dart';
import '../playback/runner.dart';
import '../services/desktop_shell.dart';
import 'item_dialog.dart';
import 'output_dialog.dart';
import 'schedule_bar.dart';
import 'timeline.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.controller, required this.shell});

  final AppController controller;
  final DesktopShell shell;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  Timer? _ticker;
  String _title = '';

  AppController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    widget.shell
      ..confirmExit = _confirmExit
      ..onStop = c.stop
      ..onHidden = () =>
          c.journal.add('Окно скрыто в трей — расписание продолжает работать');
    // Status line and playhead move with the clock.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (c.runner.status != RunnerStatus.stopped && mounted) setState(() {});
    });
    _changed();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final title = 'Timed Player — ${c.title}';
    if (title != _title) {
      _title = title;
      widget.shell.setTitle(title);
    }
    if (mounted) setState(() {});
  }

  void _error(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: Theme.of(context).colorScheme.error,
    ));
  }

  Future<bool> _ask(String title, String text, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  // ---- files ----------------------------------------------------------------

  Future<bool> _saveIfNeeded() async {
    if (!c.dirty) return true;
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Несохранённые изменения'),
        content: Text('Сохранить изменения в «${c.schedule.name}»?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('Не сохранять')),
          FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Сохранить')),
        ],
      ),
    );
    if (answer == 'save') return _save();
    return answer == 'discard';
  }

  Future<bool> _save() async {
    final path = c.filePath;
    if (path == null) return _saveAs();
    try {
      await c.saveTo(path);
      return true;
    } on Object catch (e) {
      _error('Не удалось сохранить: $e');
      return false;
    }
  }

  Future<bool> _saveAs() async {
    final safe = c.schedule.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final name = '${safe.isEmpty ? 'расписание' : safe}.$scheduleExtension';
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Сохранить расписание',
        fileName: name,
        bytes: c.encode(name),
      );
      if (uri == null) return false;
      // Written again so media next to the file are stored by relative path.
      await c.saveTo(uri.toFilePath());
      return true;
    } on Object catch (e) {
      _error('Не удалось сохранить: $e');
      return false;
    }
  }

  Future<void> _open() async {
    if (!await _saveIfNeeded()) return;
    final file = await FilePicker.pickFile(
      dialogTitle: 'Открыть расписание',
      type: FileType.custom,
      allowedExtensions: [scheduleExtension, 'json'],
    );
    final path = file?.path;
    if (path == null) return;
    try {
      await c.openFile(path);
    } on Object catch (e) {
      _error('Не удалось открыть: $e');
    }
  }

  Future<void> _new() async {
    if (await _saveIfNeeded()) c.newSchedule();
  }

  Future<bool> _confirmExit() async {
    if (c.runner.status != RunnerStatus.stopped &&
        !await _ask('Расписание включено',
            'После выхода по расписанию ничего проигрываться не будет. Выйти?',
            'Выйти')) {
      return false;
    }
    if (!await _saveIfNeeded()) return false;
    await c.stop();
    return true;
  }

  // ---- items ----------------------------------------------------------------

  Future<void> _addFiles() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Добавить видео, аудио или картинки',
      type: FileType.custom,
      allowedExtensions: mediaExtensions,
    );
    await c.addFiles(files.map((f) => f.path).whereType<String>().toList());
  }

  Future<void> _edit(String id) async {
    final item = c.schedule.items.where((i) => i.id == id).firstOrNull;
    if (item == null) return;
    c.select(id);
    final changed = await showItemDialog(
      context,
      item: item,
      probe: c.probe,
      clockAnchor: c.clockTimes ? c.clockAnchor : null,
    );
    if (changed != null) c.upsertItem(changed);
  }

  void _deleteSelected() {
    final id = c.selectedId;
    if (id != null) c.removeItem(id);
  }

  // ---- running --------------------------------------------------------------

  Future<void> _arm() async {
    final error = await c.arm();
    if (error != null) _error(error);
  }

  Future<void> _output() async {
    final config = await showOutputDialog(context, c.settings.output);
    if (config == null) return;
    c.settings
      ..output = config
      ..save();
    c.runner.output = config;
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? 'в ${formatClock(t)}' : '${formatDate(t)} в ${formatClock(t)}';
  }

  String _status() {
    final r = c.runner;
    final now = DateTime.now();
    switch (r.status) {
      case RunnerStatus.stopped:
        return 'Остановлено';
      case RunnerStatus.waiting:
        final next = r.nextAnchor;
        return next == null
            ? 'Ожидание'
            : 'Ждёт старта ${_when(next)} — через ${formatDuration(next.difference(now))}';
      case RunnerStatus.running:
        final b = StringBuffer(
            'Идёт «${r.schedule?.name ?? ''}»: ${formatDuration(r.position ?? Duration.zero)}');
        final next = r.state?.next;
        if (next != null) {
          b.write(' · далее «${next.item.displayName}» через '
              '${formatDuration(next.start.difference(now))}');
        }
        return b.toString();
    }
  }

  Set<String> _playingKeys() {
    final st = c.runner.state;
    if (!c.linked || st == null) return const {};
    return {
      if (st.visual != null) st.visual!.key,
      for (final a in st.audio) a.key,
    };
  }

  // ---- layout ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = c.runner.status;
    final clockAnchor = c.clockTimes ? c.clockAnchor : null;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _new,
        const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: theme.colorScheme.surfaceContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(children: [
                    IconButton(
                        tooltip: 'Новое (Ctrl+N)',
                        onPressed: _new,
                        icon: const Icon(Icons.note_add_outlined)),
                    IconButton(
                        tooltip: 'Открыть (Ctrl+O)',
                        onPressed: _open,
                        icon: const Icon(Icons.folder_open_outlined)),
                    IconButton(
                        tooltip: 'Сохранить (Ctrl+S)',
                        onPressed: _save,
                        icon: const Icon(Icons.save_outlined)),
                    IconButton(
                        tooltip: 'Сохранить как…',
                        onPressed: _saveAs,
                        icon: const Icon(Icons.save_as_outlined)),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: c.busy ? null : _addFiles,
                      icon: c.busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.add),
                      label: const Text('Добавить файлы'),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _status(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: status == RunnerStatus.running
                              ? Colors.greenAccent
                              : status == RunnerStatus.waiting
                                  ? theme.colorScheme.tertiary
                                  : theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: c.schedule.items.isEmpty ? null : c.start,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(c.cursor > Duration.zero
                          ? 'Старт с ${formatDuration(c.cursor)}'
                          : 'Старт'),
                    ),
                    const SizedBox(width: 8),
                    if (c.schedule.start.mode != StartMode.manual) ...[
                      FilledButton.tonalIcon(
                        onPressed: _arm,
                        icon: const Icon(Icons.alarm_on),
                        label: const Text('Включить по времени'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    OutlinedButton.icon(
                      onPressed: status == RunnerStatus.stopped ? null : c.stop,
                      icon: const Icon(Icons.stop),
                      label: const Text('Стоп'),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                        tooltip: 'Вывод видео: монитор, режим окна',
                        onPressed: _output,
                        icon: const Icon(Icons.monitor)),
                    IconButton(
                        tooltip: 'Свернуть в трей',
                        onPressed: widget.shell.hideToTray,
                        icon: const Icon(Icons.minimize)),
                  ]),
                ),
              ),
              ScheduleBar(controller: c),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Timeline(
                  schedule: c.schedule,
                  selectedId: c.selectedId,
                  cursor: c.cursor,
                  playhead: c.linked ? c.runner.position : null,
                  clockAnchor: clockAnchor,
                  onSelect: c.select,
                  onMove: c.moveItem,
                  onResize: c.resizeItem,
                  onCursor: c.setCursor,
                  onOpen: _edit,
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _ItemTable(
                  controller: c,
                  playing: _playingKeys(),
                  clockAnchor: clockAnchor,
                  onEdit: _edit,
                  onAdd: _addFiles,
                ),
              ),
              const Divider(height: 1),
              SizedBox(height: 170, child: _JournalPanel(controller: c)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemTable extends StatelessWidget {
  const _ItemTable({
    required this.controller,
    required this.playing,
    required this.clockAnchor,
    required this.onEdit,
    required this.onAdd,
  });

  final AppController controller;
  final Set<String> playing;
  final DateTime? clockAnchor;
  final ValueChanged<String> onEdit;
  final VoidCallback onAdd;

  static const _widths = [36.0, 104.0, null, 104.0, 100.0, 108.0, 100.0, 64.0, 110.0, 88.0];

  String _time(Duration offset) {
    final a = clockAnchor;
    if (a == null) return formatDuration(offset, millis: true);
    final base = Duration(hours: a.hour, minutes: a.minute, seconds: a.second);
    return formatTimeOfDay(base + offset);
  }

  String _seconds(Duration d) {
    if (d == Duration.zero) return '—';
    final s = d.inMilliseconds / 1000;
    return '${s == s.roundToDouble() ? s.round() : s.toStringAsFixed(1)} с';
  }

  Widget _row(List<Widget> cells) => Row(children: [
        for (var i = 0; i < cells.length; i++)
          if (_widths[i] == null)
            Expanded(child: cells[i])
          else
            SizedBox(width: _widths[i], child: cells[i]),
      ]);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = controller.schedule.items;
    if (items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.movie_filter_outlined, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          const Text('Расписание пустое'),
          const SizedBox(height: 4),
          Text('Добавьте видео, аудио или картинки — они встанут друг за другом, '
              'потом время каждого можно поменять.',
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton.icon(
              onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Добавить файлы')),
        ]),
      );
    }
    final header = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Text h(String s) => Text(s, style: header);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: _row([
            h('№'),
            h('Тип'),
            h('Название'),
            h(clockAnchor == null ? 'Старт' : 'Старт (часы)'),
            h('С позиции'),
            h('Длительность'),
            h('Конец'),
            h('Громк.'),
            h('Нараст./затух.'),
            const SizedBox(),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final selected = item.id == controller.selectedId;
              final isPlaying = playing.contains(occurrenceKey(item));
              final length = item.playLength;
              final missing = !File(item.path).existsSync();
              return Material(
                color: selected
                    ? theme.colorScheme.secondaryContainer
                    : Colors.transparent,
                child: InkWell(
                  onTap: () => controller.select(item.id),
                  onDoubleTap: () => onEdit(item.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: _row([
                      isPlaying
                          ? const Icon(Icons.play_arrow, color: Colors.greenAccent, size: 18)
                          : Text('${index + 1}'),
                      Row(children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                              color: kindColor(item.kind),
                              borderRadius: BorderRadius.circular(2)),
                        ),
                        const SizedBox(width: 6),
                        Text(item.kind.label),
                      ]),
                      Tooltip(
                        message: missing ? 'Файл не найден: ${item.path}' : item.path,
                        child: Row(children: [
                          if (missing)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.warning_amber,
                                  size: 16, color: theme.colorScheme.error),
                            ),
                          Expanded(
                            child: Text(item.displayName, overflow: TextOverflow.ellipsis),
                          ),
                        ]),
                      ),
                      Text(_time(item.offset)),
                      Text(item.kind == MediaKind.image ? '—' : formatDuration(item.from, millis: true)),
                      Text(length == null
                          ? 'до конца'
                          : '${formatDuration(length, millis: true)}${item.length == null ? '*' : ''}'),
                      Text(length == null ? '?' : _time(item.offset + length)),
                      Text(item.kind == MediaKind.image ? '—' : '${item.volume}%'),
                      Text('${_seconds(item.fadeIn)} / ${_seconds(item.fadeOut)}'),
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        IconButton(
                          tooltip: 'Изменить',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          onPressed: () => onEdit(item.id),
                        ),
                        IconButton(
                          tooltip: 'Удалить (Delete)',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () => controller.removeItem(item.id),
                        ),
                      ]),
                    ]),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Text(
            '* длительность — до конца файла. Двойной щелчок по строке или блоку — '
            'изменить элемент.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _JournalPanel extends StatelessWidget {
  const _JournalPanel({required this.controller});

  final AppController controller;

  void _openFolder() {
    final dir = controller.journal.directory;
    if (dir == null) return;
    Directory(dir).createSync(recursive: true);
    if (Platform.isWindows) {
      Process.run('explorer', [dir]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [dir]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: controller.journal,
      builder: (context, _) {
        final lines = controller.journal.lines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
              child: Row(children: [
                Text('Журнал', style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  tooltip: 'Открыть папку журнала',
                  icon: const Icon(Icons.folder_outlined, size: 20),
                  onPressed: _openFolder,
                ),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final line = lines[lines.length - 1 - i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: SelectableText(
                      line,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Consolas',
                        color: line.contains('⚠') ? theme.colorScheme.error : null,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
