import 'package:flutter/material.dart';

/// Identidad visual LEXAIR GEO: GIS de escritorio sobrio, azul petróleo
/// con acento cobre discreto (Studio Lexair). Tipografía del sistema para
/// no depender de fuentes descargadas.
class LexairColors {
  static const ink = Color(0xFF14232E);
  static const panel = Color(0xFFF7F8FA);
  static const sidebar = Color(0xFF102A38);
  static const sidebarActive = Color(0xFF1E4A5F);
  static const primary = Color(0xFF0F6C81);
  static const accent = Color(0xFFC07A3A);
  static const border = Color(0xFFDDE2E7);
  static const groupA = Color(0xFF1565C0);
  static const groupB = Color(0xFFC62828);
  static const groupAB = Color(0xFF6A1B9A);
  static const ok = Color(0xFF2E7D32);
  static const warn = Color(0xFFEF8F00);
  static const danger = Color(0xFFC62828);
  static const muted = Color(0xFF5F6B76);
}

ThemeData buildLexairTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: LexairColors.primary,
    primary: LexairColors.primary,
    secondary: LexairColors.accent,
    surface: Colors.white,
  );
  return ThemeData(
    useMaterial3: true,
    // Fuente empaquetada: idéntica en Windows y Web y sin descargas externas.
    fontFamily: 'NotoSans',
    colorScheme: scheme,
    scaffoldBackgroundColor: LexairColors.panel,
    visualDensity: VisualDensity.compact,
    dividerTheme: const DividerThemeData(color: LexairColors.border, space: 1),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: LexairColors.border),
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
    ),
    textTheme: const TextTheme(
      titleMedium: TextStyle(fontWeight: FontWeight.w600, color: LexairColors.ink),
      bodySmall: TextStyle(color: LexairColors.muted),
    ),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
  );
}
