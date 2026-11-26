import 'package:flutter/material.dart';

/// Iconos disponibles para marcadores y categorías. Los nombres se guardan en
/// la configuración del servidor (`passes.marker_icon`, `personnel.marker_icon`
/// y `geo.zone_categories.icon`): nada queda fijado en el cliente.
const Map<String, IconData> lexairIcons = {
  'local_police': Icons.local_police,
  'shield': Icons.shield,
  'shield_moon': Icons.shield_moon,
  'flag': Icons.flag,
  'warning': Icons.warning_amber_rounded,
  'place': Icons.place,
  'directions_walk': Icons.directions_walk,
  'person_pin': Icons.person_pin,
  'visibility': Icons.visibility,
  'control_camera': Icons.control_camera,
  'edit_note': Icons.edit_note,
  'home': Icons.home,
  'gavel': Icons.gavel,
  'anchor': Icons.anchor,
  'fence': Icons.fence,
  'my_location': Icons.my_location,
  'push_pin': Icons.push_pin,
  'star': Icons.star,
  'label': Icons.label,
  'info': Icons.info,
};

IconData iconFromName(String? name, {IconData fallback = Icons.place}) =>
    lexairIcons[name] ?? fallback;
