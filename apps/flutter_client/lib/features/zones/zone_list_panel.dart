import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../map/map_view.dart';
import '../map/workspace_controller.dart';

/// Pestaña «Zonas» del panel izquierdo: lista de zonas visibles con recuentos
/// y acceso directo al dibujo. La edición se hace tocando el área en el mapa.
class ZoneListPanel extends StatelessWidget {
  const ZoneListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final zones = ws.zones;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Text('Zonas dibujadas (${zones.length})',
              style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          if (ws.loadingZones)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          IconButton(
            tooltip: 'Recargar',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => ws.refreshZones(),
          ),
        ]),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          'Use las herramientas de la parte superior del mapa para dibujar un '
          'círculo, un cuadrado o un polígono; al terminar podrá asignarle '
          'nombre, etiqueta, presos y personal.',
          style: TextStyle(fontSize: 12, color: LexairColors.muted),
        ),
      ),
      const Divider(height: 1),
      Expanded(child: ListView(children: [
        for (final z in zones)
          ListTile(
            dense: true,
            leading: Icon(Icons.shape_line_outlined, size: 20, color: zoneColor(z)),
            title: Text(z.name, style: const TextStyle(fontSize: 13)),
            subtitle: Text([
              z.category?.name ?? 'sin categoría',
              '${z.membersCount} presos',
              if (z.passesInside > 0) '${z.passesInside} pases activos',
              if (z.areaKm2 != null) '${z.areaKm2!.toStringAsFixed(1)} km²',
            ].join(' · '), style: const TextStyle(fontSize: 12)),
            onTap: () => ws.selectZone(z),
          ),
        if (zones.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No hay zonas dibujadas en esta vista del mapa.',
                style: TextStyle(fontSize: 13, color: LexairColors.muted)),
          ),
      ])),
    ]);
  }
}
