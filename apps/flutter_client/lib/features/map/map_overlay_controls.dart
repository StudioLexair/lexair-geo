import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../auth/auth_controller.dart';
import 'map_drawing.dart';
import 'workspace_controller.dart';
import '../../core/config/terminologia.dart';

/// Controles flotantes: herramientas de dibujo de zonas, zoom, selector de
/// capas (personas, zonas, pases, personal), filtro de grupos y lectura de
/// coordenadas. Todo actúa sobre consultas reales del servidor.
class MapOverlayControls extends StatelessWidget {
  const MapOverlayControls({super.key, required this.map, required this.cursor});
  final MapController map;
  final ValueListenable<LatLng?> cursor;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final canDraw = context.watch<AuthController>().user?.can('zones.write') ?? false;
    return Stack(children: [
      if (canDraw)
        Positioned(
          top: 12,
          left: 12,
          child: DrawToolbar(tool: ws.drawing.tool),
        ),
      Positioned(
        top: canDraw ? 66 : 12,
        right: 12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _LayerSelector(ws: ws),
            const SizedBox(height: 8),
            overlayBox(Column(children: [
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
      if (ws.drawing.isDrawing)
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(child: _DrawingBanner(tool: ws.drawing.tool)),
        )
      else if (ws.pickMode)
        Positioned(
          top: 12,
          left: 0,
          right: 0,
          child: Center(
            child: overlayBox(const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text('Haga clic en el mapa para colocar el marcador provisional'),
            ), color: const Color(0xFFFFF3E0)),
          ),
        ),
      Positioned(
        left: 12,
        bottom: 12,
        child: overlayBox(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: ValueListenableBuilder<LatLng?>(
            valueListenable: cursor,
            builder: (context, c, _) => Text(
              [
                if (c != null) '${Labels.coord(c.latitude)}, ${Labels.coord(c.longitude)}',
                if (ws.drawing.isDrawing && ws.drawing.tool == DrawTool.circle && (ws.drawing.radiusM ?? 0) > 1)
                  'radio ${Labels.distance(ws.drawing.radiusM!)}',
                'zoom ${map.camera.zoom.toStringAsFixed(1)}',
                if (ws.loadingFeatures) 'cargando…',
                if (ws.mapError != null) '⚠ ${ws.mapError}',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        )),
      ),
    ]);
  }
}

/// Panel flotante genérico (elevación y esquinas).
Widget overlayBox(Widget child, {Color color = Colors.white}) => Material(
  color: color,
  elevation: 2,
  borderRadius: BorderRadius.circular(6),
  child: child,
);


/// Barra de herramientas de dibujo: círculo, rectángulo, polígono, deshacer
/// vértice, terminar (polígono) y cancelar. Tras dibujar se abre «Asignar área».
class DrawToolbar extends StatelessWidget {
  const DrawToolbar({super.key, required this.tool});
  final DrawTool tool;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final drawing = ws.drawing;
    return overlayBox(Row(mainAxisSize: MainAxisSize.min, children: [
      _tool(context, 'draw-circle', Icons.radio_button_unchecked, 'Dibujar círculo (toque el centro y luego el borde)',
        DrawTool.circle, tool),
      _divider(),
      _tool(context, 'draw-rectangle', Icons.crop_square, 'Dibujar cuadrado/rectángulo (dos esquinas)',
        DrawTool.rectangle, tool),
      _divider(),
      _tool(context, 'draw-polygon', Icons.format_shapes, 'Dibujar polígono (toque los vértices y cierre)',
        DrawTool.polygon, tool),
      if (drawing.isDrawing) ...[
        _divider(),
        if (drawing.tool == DrawTool.polygon)
          _action(context, 'draw-undo', Icons.undo, 'Deshacer último vértice', ws.undoVertex),
        _action(context, 'draw-cancel', Icons.close, 'Cancelar dibujo', () => ws.cancelDrawing()),
      ],
    ]));
  }

  Widget _tool(BuildContext context, String key, IconData icon, String tooltip, DrawTool t, DrawTool current) {
    final ws = context.read<WorkspaceController>();
    final active = current == t;
    return IconButton(
      key: Key(key),
      tooltip: tooltip,
      icon: Icon(icon, size: 22, color: active ? LexairColors.accent : LexairColors.ink),
      onPressed: () => ws.startDrawing(t),
    );
  }

  Widget _action(BuildContext context, String key, IconData icon, String tooltip, VoidCallback f) =>
      IconButton(key: Key(key), tooltip: tooltip, icon: Icon(icon, size: 20), onPressed: f);

  static Widget _divider() => const SizedBox(height: 26, child: VerticalDivider(width: 1));
}

class _DrawingBanner extends StatelessWidget {
  const _DrawingBanner({required this.tool});
  final DrawTool tool;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final msg = switch (tool) {
      DrawTool.circle => 'Círculo: toque el centro y arrastre o toque otra vez para fijar el radio',
      DrawTool.rectangle => ws.drawing.firstPoint == null
          ? 'Rectángulo: toque la primera esquina'
          : 'Rectángulo: toque la esquina opuesta',
      DrawTool.polygon => 'Polígono: toque los vértices${ws.drawing.canFinish ? ' · cierre desde el botón ✓' : ''}',
      DrawTool.none => '',
    };
    final hasFinish = ws.drawing.canFinish;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      overlayBox(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(msg, style: const TextStyle(fontSize: 13)),
      ), color: const Color(0xFFFFF3E0)),
      const SizedBox(width: 8),
      if (hasFinish)
        overlayBox(IconButton(
          key: const Key('draw-finish'),
          tooltip: 'Terminar polígono y asignar área',
          icon: const Icon(Icons.check, color: LexairColors.ok),
          onPressed: () => ws.onZoneDrawn(),
        )),
    ]);
  }
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
        if (v == 'toggle-zones') ws.toggleShowZones(!ws.showZones);
        if (v == 'toggle-passes') ws.toggleShowPasses(!ws.showPasses);
        if (v == 'toggle-personnel') ws.toggleShowPersonnel(!ws.showPersonnel);
      },
      itemBuilder: (_) => [
        const PopupMenuItem(enabled: false, child: Text('Mapa base')),
        if (styles.isEmpty)
          const PopupMenuItem(enabled: false, child: Text('Sin estilos instalados')),
        for (final s in styles)
          CheckedPopupMenuItem(value: 'style:${s.id}', checked: ws.styleId == s.id, child: Text(s.name)),
        const PopupMenuDivider(),
        const PopupMenuItem(enabled: false, child: Text('Capas de operación')),
        CheckedPopupMenuItem(value: 'toggle-persons', checked: ws.showPersons, child: const Text('Personas')),
        CheckedPopupMenuItem(value: 'toggle-zones', checked: ws.showZones, child: const Text('Zonas dibujadas')),
        CheckedPopupMenuItem(value: 'toggle-passes', checked: ws.showPasses && !ws.passesHidden,
            child: Text(ws.passesHidden
                ? '${T.pasePlural} activos (oculto: sin permiso de ubicación)'
                : '${T.pasePlural} activos')),
        CheckedPopupMenuItem(value: 'toggle-personnel', checked: ws.showPersonnel, child: const Text('Personal de la fuerza')),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'groups:all', checked: ws.groupFilter == 'all',
            child: const Text('Todos los grupos permitidos')),
        CheckedPopupMenuItem(value: 'groups:A', checked: ws.groupFilter == 'A', child: const Text('Solo Grupo A')),
        CheckedPopupMenuItem(value: 'groups:B', checked: ws.groupFilter == 'B', child: const Text('Solo Grupo B')),
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
