import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app/controller.dart';
import 'playback/mpv_backend.dart';
import 'playback/probe.dart';
import 'playback/runner.dart';
import 'services/desktop_shell.dart';
import 'services/journal.dart';
import 'services/settings.dart';
import 'ui/editor_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final options = LaunchOptions.parse(args);
  final support = await getApplicationSupportDirectory();
  final journal = Journal(directory: p.join(support.path, 'journal'))..loadToday();
  final settings = await AppSettings.load(p.join(support.path, 'settings.json'));
  final backend = MpvBackend()..onLog = (message) => journal.add('mpv: $message');
  final runner = Runner(backend: backend, journal: journal)
    ..output = settings.output;
  final controller = AppController(
    runner: runner,
    journal: journal,
    settings: settings,
    probe: probeLength,
  );
  final shell = DesktopShell(isArmed: () => runner.status != RunnerStatus.stopped);
  await shell.init();

  if (options.exitWhenDone) {
    // For scripted runs: quit once the schedule has played.
    var started = false;
    runner.addListener(() {
      if (runner.status != RunnerStatus.stopped) {
        started = true;
      } else if (started) {
        started = false;
        Future<void>.delayed(const Duration(milliseconds: 300), shell.close);
      }
    });
  }

  runApp(TimedPlayerApp(controller: controller, shell: shell));
  await controller.startup(options);
  if (options.exitWhenDone && runner.status == RunnerStatus.stopped) exit(1);
}

class TimedPlayerApp extends StatelessWidget {
  const TimedPlayerApp({super.key, required this.controller, required this.shell});

  final AppController controller;
  final DesktopShell shell;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Timed Player',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFE53935),
            brightness: Brightness.dark,
          ),
        ),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: EditorPage(controller: controller, shell: shell),
      );
}
