import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import 'workspace_controller.dart';

/// Panel superior central con los modos de vista del mapa base (4 por
/// defecto). Los estilos vienen del paquete cartográfico instalado en el
/// servidor: nada fijo en el cliente. Con modo oscuro activo se resalta.
class MapModesPanel extends StatelessWidget {
  const MapModesPanel({super.key});

  static const _icons = {
    'standard': Icons.map_outlined,
    'dark': Icons.dark_mode_outlined,
    'high_contrast': Icons.contrast,
    'topographic': Icons.terrain_outlined,
    'satellite': Icons.satellite_alt_outlined,
  };

  static const _labels = {
    'standard': 'Estándar',
    'dark': 'Oscuro',
    'high_contrast': 'Al contraste',
    'topographic': 'Relieve',
    'satellite': 'Satélite',
  };

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final styles = ws.package?.styles ?? const [];
    if (styles.isEmpty) return const SizedBox.shrink();
    final shown = styles.take(4).toList();
    return Positioned(
      top: 12,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: Colors.white.withValues(alpha: 0.96),
          elevation: 2,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final s in shown)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _ModeButton(
                    key: Key('map-mode-${s.id}'),
                    selected: ws.styleId == s.id,
                    icon: _icons[s.kind] ?? Icons.map_outlined,
                    label: s.name.isNotEmpty ? s.name : (_labels[s.kind] ?? s.id),
                    onTap: () => ws.setStyle(s.id),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({super.key, required this.selected, required this.icon, required this.label, required this.onTap});
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? LexairColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: selected ? Colors.white : LexairColors.ink),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? Colors.white : LexairColors.ink)),
        ]),
      ),
    );
  }
}
