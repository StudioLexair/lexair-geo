import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Etiquetas en español para los valores codificados del API.
class Labels {
  static const precision = {
    'exact_verified': 'Exacta verificada',
    'high': 'Alta precisión',
    'approximate': 'Aproximada',
    'general_area': 'Zona general',
    'unverified': 'Pendiente de verificar',
  };
  static const validation = {
    'pending': 'Pendiente',
    'validated': 'Validada',
    'rejected': 'Rechazada',
  };
  static const coordSource = {
    'manual_coordinates': 'Coordenada manual',
    'map_pick': 'Selección en mapa',
    'geocoded_address': 'Dirección geocodificada',
    'gps_once': 'GPS puntual autorizado',
    'admin_correction': 'Corrección administrativa',
    'synthetic': 'Sintética (pruebas)',
  };
  static const granularity = {
    'dwelling': 'Vivienda',
    'street': 'Calle (no vivienda)',
    'locality': 'Localidad',
    'municipality': 'Municipio',
    'poi': 'Punto de interés',
    'unknown': 'Desconocida',
  };
  static const consent = {
    'granted': 'Otorgado',
    'not_required': 'No requerido',
    'pending': 'Pendiente',
    'revoked': 'Revocado',
  };

  static String of(Map<String, String> map, String? key) =>
      key == null ? '—' : (map[key] ?? key);

  static Color precisionColor(String? p) => switch (p) {
    'exact_verified' => LexairColors.ok,
    'high' => const Color(0xFF558B2F),
    'approximate' => LexairColors.warn,
    'general_area' => const Color(0xFF8D6E63),
    _ => LexairColors.muted,
  };

  static Color groupColor(List<String> groups) {
    if (groups.contains('A') && groups.contains('B')) return LexairColors.groupAB;
    if (groups.contains('B')) return LexairColors.groupB;
    return LexairColors.groupA;
  }

  static String distance(num meters) =>
      meters >= 1000 ? '${(meters / 1000).toStringAsFixed(2)} km' : '${meters.round()} m';

  static String coord(double v) => v.toStringAsFixed(6);

  /// Fecha y hora local legible (formularios y listas de pases).
  static String dateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String date(DateTime d) => d.toString().substring(0, 10);
}
