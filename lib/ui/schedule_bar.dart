import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../core/model.dart';
import '../core/timefmt.dart';
import 'fields.dart';

/// Schedule name, how it starts, the idle picture and the time display mode.
class ScheduleBar extends StatefulWidget {
  const ScheduleBar({super.key, required this.controller});

  final AppController controller;

  @override
  State<ScheduleBar> createState() => _ScheduleBarState();
}

class _ScheduleBarState extends State<ScheduleBar> {
  late final _name = TextEditingController(text: widget.controller.schedule.name);

  AppController get c => widget.controller;
  StartRule get rule => c.schedule.start;

  @override
  void didUpdateWidget(ScheduleBar old) {
    super.didUpdateWidget(old);
    if (_name.text != c.schedule.name) _name.text = c.schedule.name;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _setRule(StartRule r) => c.edit(c.schedule.copyWith(start: r));

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final at = rule.at ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: at.isBefore(now) ? now : at,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null) return;
    _setRule(rule.copyWith(
        at: DateTime(date.year, date.month, date.day, at.hour, at.minute, at.second)));
  }

  Future<void> _pickIdle() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Заставка между роликами',
      type: FileType.custom,
      allowedExtensions: imageExtensions,
    );
    final path = file?.path;
    if (path != null) c.edit(c.schedule.copyWith(idleImage: path));
  }

  Duration _timeOf(DateTime t) =>
      Duration(hours: t.hour, minutes: t.minute, seconds: t.second);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idle = c.schedule.idleImage;
    final at = rule.at ?? DateTime.now().add(const Duration(minutes: 10));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 240,
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Название расписания',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => c.edit(c.schedule.copyWith(name: v)),
            ),
          ),
          SegmentedButton<StartMode>(
            segments: const [
              ButtonSegment(
                  value: StartMode.manual,
                  icon: Icon(Icons.play_circle_outline),
                  label: Text('Кнопкой')),
              ButtonSegment(
                  value: StartMode.once,
                  icon: Icon(Icons.event),
                  label: Text('Один раз')),
              ButtonSegment(
                  value: StartMode.weekly,
                  icon: Icon(Icons.repeat),
                  label: Text('По дням')),
            ],
            selected: {rule.mode},
            onSelectionChanged: (s) {
              final mode = s.single;
              _setRule(rule.copyWith(
                mode: mode,
                at: mode == StartMode.once && rule.at == null ? at : rule.at,
              ));
            },
          ),
          if (rule.mode == StartMode.once) ...[
            OutlinedButton.icon(
              onPressed: _pickDate,
              icon: const Icon(Icons.calendar_month),
              label: Text(formatDate(at)),
            ),
            DurationField(
              label: 'Время',
              value: _timeOf(at),
              width: 130,
              validate: (v) => v >= const Duration(days: 1) ? 'До 23:59:59' : null,
              onChanged: (v) => _setRule(rule.copyWith(
                  at: DateTime(at.year, at.month, at.day).add(v!))),
            ),
          ],
          if (rule.mode == StartMode.weekly) ...[
            DurationField(
              label: 'Время',
              value: rule.timeOfDay,
              width: 130,
              validate: (v) => v >= const Duration(days: 1) ? 'До 23:59:59' : null,
              onChanged: (v) => _setRule(rule.copyWith(timeOfDay: v)),
            ),
            Wrap(spacing: 4, children: [
              for (var d = 1; d <= 7; d++)
                FilterChip(
                  label: Text(weekdayShort[d - 1]),
                  selected: rule.weekdays.contains(d),
                  showCheckmark: false,
                  onSelected: (on) => _setRule(rule.copyWith(
                      weekdays: on
                          ? ({...rule.weekdays, d})
                          : ({...rule.weekdays}..remove(d)))),
                ),
            ]),
          ],
          Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton.icon(
              onPressed: _pickIdle,
              icon: const Icon(Icons.wallpaper),
              label: Text(idle == null ? 'Заставка: чёрный' : 'Заставка: ${p.basename(idle)}'),
            ),
            if (idle != null)
              IconButton(
                tooltip: 'Убрать заставку',
                icon: const Icon(Icons.close),
                onPressed: () => c.edit(c.schedule.copyWith(idleImage: null)),
              ),
          ]),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Время:', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 6),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('от начала')),
                ButtonSegment(value: true, label: Text('по часам')),
              ],
              selected: {c.clockTimes && c.clockAnchor != null},
              onSelectionChanged: c.clockAnchor == null
                  ? null
                  : (s) => c.clockTimes = s.single,
            ),
          ]),
        ],
      ),
    );
  }
}
