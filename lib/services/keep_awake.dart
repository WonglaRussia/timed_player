import 'dart:ffi';
import 'dart:io';

import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the computer and the screen from sleeping while a schedule is on.
class KeepAwake {
  static int Function(int)? _setThreadExecutionState;
  static bool _on = false;

  static const _esContinuous = 0x80000000;
  static const _esSystemRequired = 0x00000001;
  static const _esDisplayRequired = 0x00000002;

  static Future<void> set(bool on) async {
    if (on == _on) return;
    _on = on;
    try {
      if (Platform.isWindows) {
        // wakelock_plus keeps only the display on; an unattended schedule
        // also needs the system itself awake.
        final f = _setThreadExecutionState ??= DynamicLibrary.open('kernel32.dll')
            .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
                'SetThreadExecutionState');
        f(on
            ? _esContinuous | _esSystemRequired | _esDisplayRequired
            : _esContinuous);
      } else if (on) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } on Object {
      _on = !on;
    }
  }
}
