import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'config_source.dart';

/// Resuelve la configuración efectiva por prioridad:
/// ajuste manual local > config.json externo > origen web > valor empaquetado.
class ConfigStore {
  static const _overrideKey = 'lexair.serverUrlOverride';

  Future<AppConfig> load() async {
    final bundled = AppConfig.fromJson(
      jsonDecode(await rootBundle.loadString('assets/config/default_config.json'))
          as Map<String, dynamic>,
      source: 'empaquetado',
    );
    var config = bundled;
    final webOrigin = platformDefaultServerUrl();
    if (webOrigin != null && AppConfig.isValidServerUrl(webOrigin)) {
      config = config.copyWith(serverUrl: webOrigin, source: 'mismo origen');
    }
    try {
      final external = await readExternalConfig();
      if (external != null) {
        config = AppConfig.fromJson({...external}, source: 'config.json');
      }
    } on FormatException {
      // config.json inválido: se mantiene el valor anterior.
    }
    final prefs = await SharedPreferences.getInstance();
    final manual = prefs.getString(_overrideKey);
    if (manual != null && AppConfig.isValidServerUrl(manual)) {
      config = config.copyWith(serverUrl: manual, source: 'ajuste local');
    }
    return config;
  }

  Future<void> saveOverride(String? url) async {
    final prefs = await SharedPreferences.getInstance();
    if (url == null || url.trim().isEmpty) {
      await prefs.remove(_overrideKey);
    } else {
      await prefs.setString(_overrideKey, url.trim());
    }
  }

  /// Bandera persistente (por usuario) para estados como «asistente completado».
  Future<bool> getFlag(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('lexair.$key') ?? false;
  }

  Future<void> setFlag(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lexair.$key', value);
  }

  /// Texto persistente genérico (respuestas del asistente, etc.).
  Future<String?> getText(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('lexair.$key');
  }

  Future<void> setText(String key, String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.trim().isEmpty) {
      await prefs.remove('lexair.$key');
    } else {
      await prefs.setString('lexair.$key', value.trim());
    }
  }
}
