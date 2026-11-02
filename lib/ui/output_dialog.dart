import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';

import '../playback/backend.dart';

/// Chooses the monitor and window mode for video output.
Future<OutputConfig?> showOutputDialog(
    BuildContext context, OutputConfig current) async {
  var displays = <String>[];
  try {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final primary = await ScreenRetriever.instance.getPrimaryDisplay();
      displays = [
        for (final d in await ScreenRetriever.instance.getAllDisplays())
          _describe(d, d.id == primary.id),
      ];
    }
  } on Object {
    // The list is a convenience; the number alone still works.
  }
  if (!context.mounted) return null;
  return showDialog<OutputConfig>(
    context: context,
    builder: (_) => _OutputDialog(current: current, displays: displays),
  );
}

String _describe(Display d, bool primary) {
  final name = d.name;
  return '${d.size.width.round()}×${d.size.height.round()}'
      '${name == null || name.isEmpty ? '' : ' — $name'}'
      '${primary ? ' (основной)' : ''}';
}

class _OutputDialog extends StatefulWidget {
  const _OutputDialog({required this.current, required this.displays});

  final OutputConfig current;
  final List<String> displays;

  @override
  State<_OutputDialog> createState() => _OutputDialogState();
}

class _OutputDialogState extends State<_OutputDialog> {
  late OutputConfig _config = widget.current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.displays.isEmpty ? 1 : widget.displays.length;
    return AlertDialog(
      title: const Text('Вывод видео'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Монитор', style: theme.textTheme.titleSmall),
            RadioGroup<int>(
              groupValue: _config.screen.clamp(0, count - 1),
              onChanged: (v) => setState(() => _config = _config.copyWith(screen: v)),
              child: Column(children: [
                for (var i = 0; i < count; i++)
                  RadioListTile<int>(
                    value: i,
                    dense: true,
                    title: Text('Монитор ${i + 1}'),
                    subtitle:
                        widget.displays.isEmpty ? null : Text(widget.displays[i]),
                  ),
              ]),
            ),
            const Divider(),
            SwitchListTile(
              dense: true,
              title: const Text('На весь экран'),
              value: _config.fullscreen,
              onChanged: (v) => setState(() => _config = _config.copyWith(fullscreen: v)),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Поверх всех окон'),
              subtitle: const Text('Удобно, когда монитор отдан только под вывод'),
              value: _config.onTop,
              onChanged: (v) => setState(() => _config = _config.copyWith(onTop: v)),
            ),
            const SizedBox(height: 8),
            Text(
              'В окне вывода: Esc — выйти из полноэкранного режима, F — вернуть его. '
              'Окно открывается за 2 секунды до первого ролика или картинки и '
              'закрывается после последнего; между ними экран чёрный или с заставкой.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _config),
            child: const Text('Применить')),
      ],
    );
  }
}
