import 'dart:io';
import 'dart:ui' show Size;

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Editor window and tray icon. Closing the window while a schedule is on
/// hides it to the tray, so playback continues.
class DesktopShell with WindowListener, TrayListener {
  DesktopShell({required this.isArmed});

  /// Whether a schedule is on (closing then hides instead of quitting).
  final bool Function() isArmed;

  /// Asks the user and prepares to quit; returns false to stay open.
  Future<bool> Function()? confirmExit;

  /// Called when the window is hidden to the tray.
  void Function()? onHidden;

  /// Tray menu "Остановить расписание".
  void Function()? onStop;

  bool _tray = false;

  bool get supported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> init() async {
    if (!supported) return;
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Timed Player',
        size: Size(1320, 860),
        minimumSize: Size(980, 640),
        center: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    try {
      await trayManager.setIcon(
          Platform.isWindows ? 'assets/tray.ico' : 'assets/tray.png');
      await trayManager.setToolTip('Timed Player');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Показать окно'),
        MenuItem(key: 'stop', label: 'Остановить расписание'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Выход'),
      ]));
      trayManager.addListener(this);
      _tray = true;
    } on Object {
      // Without a tray (e.g. a Linux desktop without one) the window just stays.
    }
  }

  Future<void> setTitle(String title) async {
    if (supported) await windowManager.setTitle(title);
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideToTray() async {
    if (_tray) {
      await windowManager.hide();
    } else {
      await windowManager.minimize();
    }
    onHidden?.call();
  }

  /// Asks via [confirmExit], then closes the app.
  Future<void> quit() async {
    final confirm = confirmExit;
    if (confirm != null && !await confirm()) return;
    await close();
  }

  /// Closes the app without asking.
  Future<void> close() async {
    _closing = true;
    if (_tray) await trayManager.destroy();
    await windowManager.setPreventClose(false);
    // A regular close: window_manager's destroy() quits the message loop
    // while the window is still alive, and the engine then crashes on exit.
    await windowManager.close();
  }

  bool _closing = false;

  @override
  void onWindowClose() {
    if (_closing) return;
    if (isArmed()) {
      hideToTray();
    } else {
      quit();
    }
  }

  @override
  void onTrayIconMouseDown() => show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        show();
      case 'stop':
        onStop?.call();
      case 'exit':
        show().then((_) => quit());
    }
  }
}
