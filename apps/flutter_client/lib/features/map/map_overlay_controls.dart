import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import 'workspace_controller.dart';

/// Controles flotantes: zoom, selector de capas, filtro de grupos y lectura
/// de coordenadas. Todos actúan sobre el mapa o sobre la consulta real.
class MapOverlayControls extends StatelessWidget {
  const MapOverlayControls({super.key, required this.map, required this.cursor});
  final MapController map;
  final ValueListenable<LatLng?> cursor;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    return Stack(
      children: [
        Positioned(
          top: 12,
          right: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _LayerSelector(ws: ws),
              const SizedBox(height: 8),
              _box(Column(children: [
                IconButton(
                  key: const Key('zoom-in'),
                  tooltip: 'Acercar',
                  icon: const Icon(Icons.add),
                  onPressed: () => map.move(map.camera.center, map.camera.zoom + 1),
                ),
                const Divider(height: 1),
                IconButton(
                  key: const Key('zoom-out'),
                  tooltip: 'Alejar',
                  icon: const Icon(Icons.remove),
                  onPressed: () => map.move(map.camera.center, map.camera.zoom - 1),
                ),
              ])),
            ],
          ),
        ),
        if (ws.pickMode)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: _box(const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text('Haga clic en el mapa para colocar el marcador provisional'),
              ), color: const Color(0xFFFFF3E0)),
            ),
          ),
        Positioned(
          left: 12,
          bottom: 12,
          child: _box(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: ValueListenableBuilder<LatLng?>(
              valueListenable: cursor,
              builder: (context, c, _) => Text(
                [
                  if (c != null) '${Labels.coord(c.latitude)}, ${Labels.coord(c.longitude)}',
                  'zoom ${map.camera.zoom.toStringAsFixed(1)}',
                  if (ws.loadingFeatures) 'cargando…',
                  if (ws.mapError != null) '⚠ ${ws.mapError}',
                ].join('  ·  '),
                style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          )),
        ),
      ],
    );
  }

  static Widget _box(Widget child, {Color color = Colors.white}) => Material(
    color: color,
    elevation: 2,
    borderRadius: BorderRadius.circular(6),
    child: child,
  );
}

class _LayerSelector extends StatelessWidget {
  const _LayerSelector({required this.ws});
  final WorkspaceController ws;

  @override
  Widget build(BuildContext context) {
    final styles = ws.package?.styles ?? const [];
    return PopupMenuButton<String>(
      key: const Key('layer-selector'),
      tooltip: 'Capas del mapa',
      onSelected: (v) {
        if (v.startsWith('style:')) ws.setStyle(v.substring(6));
        if (v.startsWith('groups:')) ws.setGroupFilter(v.substring(7));
        if (v == 'toggle-persons') ws.toggleShowPersons(!ws.showPersons);
      },
      itemBuilder: (_) => [
        const PopupMenuItem(enabled: false, child: Text('Mapa base')),
        if (styles.isEmpty)
          const PopupMenuItem(enabled: false, child: Text('Sin estilos instalados')),
        for (final s in styles)
          CheckedPopupMenuItem(value: 'style:${s.id}', checked: ws.styleId == s.id, child: Text(s.name)),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'toggle-persons', checked: ws.showPersons, child: const Text('Capa de personas')),
        for (final g in const [('all', 'Todos los grupos permitidos'), ('A', 'Solo Grupo A'), ('B', 'Solo Grupo B')])
          CheckedPopupMenuItem(value: 'groups:${g.$1}', checked: ws.groupFilter == g.$1, child: Text(g.$2)),
      ],
      child: Material(
        color: Colors.white,
        elevation: 2,
        borderRadius: BorderRadius.circular(6),
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.layers_outlined, color: LexairColors.ink),
            SizedBox(width: 6),
            Text('Capas'),
          ]),
        ),
      ),
    );
  }
}
