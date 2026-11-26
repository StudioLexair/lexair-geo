import 'dart:io';
import 'dart:ui' show Size;

import 'package:window_manager/window_manager.dart';

Future<void> inicializarVentana() async {
  if (!Platform.isWindows) return;
  await windowManager.ensureInitialized();
  const WindowOptions opts = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1024, 640),
    title: 'VIGÍA · Lexair Geo',
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
