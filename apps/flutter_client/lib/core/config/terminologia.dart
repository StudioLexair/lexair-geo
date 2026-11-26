import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Terminología configurable de la aplicación.
///
/// Los nombres que ve el usuario (entidades, secciones, títulos) se cargan de
/// un fichero JSON fácil de editar (`terminologia.json`, junto a config.json o
/// en %PROGRAMDATA%\LexairGeo). Si el fichero no existe se usan los valores
/// por defecto de abajo, neutrales. Así cada instalación puede llamar a las
/// entidades como prefiera sin tocar el programa.
class Terminologia {
  Terminologia._();
  static final Terminologia I = Terminologia._();

  /// Valores por defecto (neutrales). Un fichero externo puede sobreescribirlos.
  static const Map<String, String> defaults = {
    'sujetoSingular': 'Ficha',
    'sujetoPlural': 'Fichas',
    'paseSingular': 'Permiso',
    'pasePlural': 'Permisos',
    'kardexTitulo': 'Registros',
    'kardexTituloCorto': 'REGISTROS',
    'importTitulo': 'Importar fichas (Excel XML)',
    'unidadLabel': 'Unidad',
    'orgNombre': 'VIGÍA',
  };

  Map<String, String> _v = Map.of(defaults);

  String operator [](String key) => _v[key] ?? defaults[key] ?? key;

  String get sujetoSingular => this['sujetoSingular'];
  String get sujetoPlural => this['sujetoPlural'];
  String get paseSingular => this['paseSingular'];
  String get pasePlural => this['pasePlural'];
  String get kardexTitulo => this['kardexTitulo'];
  String get kardexTituloCorto => this['kardexTituloCorto'];
  String get importTitulo => this['importTitulo'];
  String get unidadLabel => this['unidadLabel'];
  String get orgNombre => this['orgNombre'];


  /// Aplica valores personalizados (usado por load y por pruebas).
  @visibleForTesting
  void apply(Map<String, String> overrides) {
    _v = Map.of(defaults)..addAll(overrides);
  }

  /// Rutas candidatas del fichero externo (misma política que config.json).
  static List<String> _rutas() {
    if (kIsWeb) return const [];
    final rutas = <String>[];
    try {
      rutas.add(
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}terminologia.json');
      final pd = Platform.environment['PROGRAMDATA'];
      if (pd != null) rutas.add('$pd\\LexairGeo\\terminologia.json');
    } catch (_) {}
    return rutas;
  }

  /// Carga el fichero externo si existe y fusiona sobre los valores por
  /// defecto. Nunca falla: ante cualquier error conserva los valores previos.
  Future<void> load() async {
    if (kIsWeb) return;
    for (final ruta in _rutas()) {
      try {
        final f = File(ruta);
        if (!f.existsSync()) continue;
        final dec = jsonDecode(f.readAsStringSync());
        if (dec is Map<String, dynamic>) {
          apply(dec.map((k, v) => MapEntry(k, v?.toString() ?? '')));
          return;
        }
      } catch (_) {
        // Configuración inválida: seguimos con lo anterior.
      }
    }
    return;
  }
}

/// Acceso corto: T.sujetoPlural etc.
Terminologia get T => Terminologia.I;
