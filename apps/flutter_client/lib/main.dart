import 'package:flutter/material.dart';

import 'core/config/config_store.dart';
import 'core/config/terminologia.dart';
import 'core/runtime/local_runtime.dart';
import 'features/bootstrap/bootstrap_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Terminología editable desde terminologia.json (valores por defecto si no existe).
  await Terminologia.I.load();
  final store = ConfigStore();
  final config = await store.load();
  // «Todo en uno»: si el paquete incluye un servidor integrado y el usuario
  // aún no apunta a un servidor interno propio, se muestra la pantalla de
  // arranque que levanta la base de datos y el API antes del acceso.
  final plan = await detectServidorIntegrado();
  runApp(VigiaRoot(initialConfig: config, store: store, plan: plan));
}
