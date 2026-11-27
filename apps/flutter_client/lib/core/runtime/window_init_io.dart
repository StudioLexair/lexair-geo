import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Rect, Size;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

Future<void> inicializarVentana() async {
  if (!Platform.isWindows) return;
  await windowManager.ensureInitialized();

  // Restaurar geometría cuando la ventana nativa esté lista.
  Rect? guardada;
  try {
    final prefs = await SharedPreferences.getInstance();
    final crudo = prefs.getString('lexair.ventana');
    if (crudo != null) {
      final g = (jsonDecode(crudo) as List<dynamic>).cast<num>();
      if (g.length == 4 && g[2] >= 900 && g[3] >= 500) {
        guardada = Rect.fromLTWH(
            g[0].toDouble(), g[1].toDouble(), g[2].toDouble(), g[3].toDouble());
      }
    }
  } catch (_) {
    // Sin preferencias válidas: se usa la geometría por defecto.
  }

  const opciones = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(1024, 640),
    title: 'VIGÍA · Lexair Geo',
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(opciones, () async {
    if (guardada != null) {
      try {
        await windowManager.setBounds(guardada,
            size: Size(guardada.width, guardada.height));
      } catch (_) {}
    }
    await VentanaGuardada.registrar();
    await windowManager.show();
    await windowManager.focus();
  });
}

/// Guarda el tamaño/posición al cerrar la ventana.
class VentanaGuardada with WindowListener {
  VentanaGuardada._();
  static final VentanaGuardada _i = VentanaGuardada._();

  static Future<void> registrar() async {
    await windowManager.setPreventClose(true);
    windowManager.addListener(_i);
  }

  @override
  void onWindowClose() async {
    try {
      final b = await windowManager.getBounds();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lexair.ventana',
          jsonEncode([b.left, b.top, b.width, b.height]));
    } catch (_) {}
    await windowManager.destroy();
  }
}
