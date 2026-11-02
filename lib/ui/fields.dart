import 'package:flutter/material.dart';

import '../core/timefmt.dart';

/// Text field for a time value (`ЧЧ:ММ:СС`, `ММ:СС` or seconds). Reports every
/// valid value as it is typed and marks invalid input.
class DurationField extends StatefulWidget {
  const DurationField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
    this.helper,
    this.emptyHint,
    this.width = 150,
    this.validate,
    this.onValid,
  });

  final Duration? value;

  /// Reports whether the text currently typed is valid.
  final ValueChanged<bool>? onValid;

  /// Null only when [emptyHint] is set and the field is cleared.
  final ValueChanged<Duration?> onChanged;
  final String? label;
  final String? helper;

  /// Allows an empty field, shown with this hint.
  final String? emptyHint;
  final double width;

  /// Extra check; returns an error text or null.
  final String? Function(Duration value)? validate;

  @override
  State<DurationField> createState() => _DurationFieldState();
}

class _DurationFieldState extends State<DurationField> {
  late final _controller = TextEditingController(text: _format(widget.value));
  final _focus = FocusNode();
  String? _error;

  String _format(Duration? d) => d == null ? '' : formatDuration(d, millis: true);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _error == null) {
        _controller.text = _format(widget.value);
      }
    });
  }

  @override
  void didUpdateWidget(DurationField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) {
      _controller.text = _format(widget.value);
      _error = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changed(String text) {
    if (text.trim().isEmpty && widget.emptyHint != null) {
      setState(() => _error = null);
      widget.onValid?.call(true);
      widget.onChanged(null);
      return;
    }
    final d = parseDuration(text);
    final error = d == null ? 'Формат ЧЧ:ММ:СС' : widget.validate?.call(d);
    setState(() => _error = error);
    widget.onValid?.call(error == null);
    if (error == null) widget.onChanged(d);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.width,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          onChanged: _changed,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.emptyHint ?? '00:00:00',
            helperText: _error == null ? widget.helper : null,
            errorText: _error,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}
