import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/net/http_client_factory.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../kardex/kardex_panel.dart';
import '../persons/location_dialog.dart';
import '../persons/person.dart';
import '../zones/zone.dart';
import '../zones/zone_assign_dialog.dart';
import '../zones/zone_panel.dart';
import 'map_drawing.dart';
import 'map_markers.dart';
import 'map_modes_panel.dart';
import 'map_overlay_controls.dart';
import 'workspace_controller.dart';

/// Mapa principal. Los mosaicos se piden SIEMPRE al servidor de la LAN
/// (`/tiles/{estilo}/{z}/{x}/{y}.png`); no hay ninguna URL externa.
/// Encima se dibujan las zonas guardadas (polígonos/círculos/etiquetas), los
/// pases activos, el personal y la vista previa del dibujo en curso.
class MapView extends StatefulWidget {
  const MapView({super.key});

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  final _map = MapController();
  StreamSubscription<(LatLng, double?)>? _sub;
  late final NetworkTileProvider _tiles;
  final _cursor = ValueNotifier<LatLng?>(null);

  bool _hadPendingZone = false;

  static const _villaClara = LatLng(22.4067, -79.9653); // Santa Clara (referencia)

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    final ws = context.read<WorkspaceController>();
    // Los mosaicos solo contienen datos OSM (sin datos personales).
    _tiles = NetworkTileProvider(
      httpClient: createHttpClient(caCertificatePath: services.config.caCertificatePath),
      silenceExceptions: true,
    );
    _sub = ws.centerRequests.listen((r) {
      _map.move(r.$1, r.$2 ?? _map.camera.zoom);
    });
    // Cuando un dibujo termina se abre el diálogo «Asignar área».
    ws.addListener(_onWorkspaceChanged);
  }

  /// Toque en el mapa con «Marcar en el mapa» pendiente del kardex:
  /// abre el diálogo de ubicación con la coordenada tocada (precisa).
  Future<void> _onMapTap(LatLng p) async {
    final ws = context.read<WorkspaceController>();
    await ws.onMapTap(p);
    final person = ws.pickForPerson;
    if (person != null && ws.provisional != null && mounted) {
      final updated = await showLocationDialog(context, person, ws);
      if (updated != null) ws.replaceSelected(updated);
      ws.clearPickFor();
    }
  }

  void _onWorkspaceChanged() {
    final ws = context.read<WorkspaceController>();
    final has = ws.pendingZoneSpec != null;
    if (has && !_hadPendingZone && mounted) {
      _hadPendingZone = true;
      unawaited(_openZoneAssignDialog());
    } else if (!has) {
      _hadPendingZone = false;
    }
  }

  /// «Asignar área»: nombre, categoría, estilo, etiqueta y asignación de presos.
  Future<void> _openZoneAssignDialog() async {
    final ws = context.read<WorkspaceController>();
    final spec = ws.consumePendingZoneSpec();
    if (spec == null || !mounted) return;
    await showZoneAssignDialog(context, spec: spec);
    if (mounted) ws.cancelDrawing();
  }

  @override
  void dispose() {
    try {
      context.read<WorkspaceController>().removeListener(_onWorkspaceChanged);
    } catch (_) {
      // El árbol ya se desmontó: no hay nada que desconectar.
    }
    unawaited(_sub?.cancel());
    _tiles.dispose();
    _cursor.dispose();
    super.dispose();
  }

  /// Convierte una posición GLOBAL (puntero de arrastre) en coordenadas
  /// geográficas del mapa actual.
  LatLng? _pointToLatLng(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return _map.camera.screenOffsetToLatLng(box.globalToLocal(global));
  }

  /// Suelta del kardex al mapa: coordenada precisa donde caiga la ficha.
  Future<void> _dropPersonOnMap(DragTargetDetails<Person> details) async {
    final ws = context.read<WorkspaceController>();
    final person = details.data;
    final latlng = _pointToLatLng(details.offset);
    ws.setKardexDragging(false);
    if (latlng == null || !mounted) return;
    ws.setProvisional(latlng);
    final updated = await showLocationDialog(context, person, ws);
    if (updated != null) {
      ws.replaceSelected(updated);
      await ws.select(updated, center: false);
    }
    ws.setProvisional(null);
  }

  void _emitView(MapCamera camera) {
    final b = camera.visibleBounds;
    context.read<WorkspaceController>().onViewChanged(b.west, b.south, b.east, b.north, camera.zoom);
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final services = context.read<AppServices>();
    final pkg = ws.package;
    final style = ws.styleId;
    final dark = pkg?.styles.where((s) => s.id == style).firstOrNull?.kind == 'dark';
    final drawingTool = ws.drawing.tool;
    return Stack(
      children: [
        DragTarget<Person>(
          key: const Key('kardex-drop-map'),
          onWillAcceptWithDetails: (_) => ws.kardexDragging,
          onMove: (details) => ws.updateKardexPreview(_pointToLatLng(details.offset)),
          onLeave: (_) => ws.updateKardexPreview(null),
          onAcceptWithDetails: (details) => unawaited(_dropPersonOnMap(details)),
          builder: (context, candidate, _) => FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: pkg?.center ?? _villaClara,
            initialZoom: 11,
            minZoom: (pkg?.minZoom ?? 6).toDouble().clamp(3, 10),
            maxZoom: 19,
            backgroundColor: dark ? const Color(0xFF1D2026) : const Color(0xFFE8E6E1),
            onMapReady: () => _emitView(_map.camera),
            onPositionChanged: (camera, _) => _emitView(camera),
            onTap: (_, p) => unawaited(_onMapTap(p)),
            onPointerHover: (event, p) {
              _cursor.value = p;
              ws.onMapHover(p);
            },
          ),
          children: [
            if (style != null)
              TileLayer(
                key: ValueKey(style),
                urlTemplate: '${services.config.tilesBase}/$style/{z}/{x}/{y}.png',
                tileProvider: _tiles,
                maxNativeZoom: pkg?.maxZoom ?? 18,
                userAgentPackageName: 'cu.studiolexair.lexair_geo',
              ),
            if (ws.showZones) ...buildZoneLayers(ws.zones),
            if (ws.nearby != null && ws.selected?.location?.point != null)
              CircleLayer(circles: [
                CircleMarker(
                  point: ws.selected!.location!.point!,
                  radius: ws.nearby!.radiusM.toDouble(),
                  useRadiusInMeter: true,
                  color: LexairColors.primary.withValues(alpha: 0.08),
                  borderColor: LexairColors.primary,
                  borderStrokeWidth: 1.5,
                ),
              ]),
            if (drawingTool != DrawTool.none) buildDrawingPreview(ws.drawing),
            if (ws.showPersons) MarkerLayer(markers: buildFeatureMarkers(context, ws, _map)),
            if (ws.showPasses && !ws.passesHidden)
              MarkerLayer(markers: buildPassMarkers(context, ws)),
            if (ws.showPersonnel)
              MarkerLayer(markers: buildPersonnelMarkers(context, ws)),
            MarkerLayer(markers: buildSelectionMarkers(ws)),
            if (ws.kardexDropPreview != null)
              MarkerLayer(markers: [
                Marker(
                  point: ws.kardexDropPreview!,
                  width: 44,
                  height: 44,
                  child: const Icon(Icons.location_on, size: 40, color: LexairColors.accent),
                ),
              ]),
            SimpleAttributionWidget(
              source: Text(pkg?.attribution ?? '© OpenStreetMap contributors',
                  style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
        ),
        MapOverlayControls(map: _map, cursor: _cursor),
        const MapModesPanel(),
        const ZonePanelOverlay(),
        if (context.watch<AuthController>().user?.can('persons.read') ?? false)
          const KardexPanel(),
        // Un paquete de prueba nunca debe pasar por cartografía real de Villa Clara.
        if (pkg?.isSynthetic ?? false)
          const Positioned(
            left: 12,
            bottom: 28,
            child: Chip(
              avatar: Icon(Icons.warning_amber, size: 18),
              label: Text('MAPA SINTÉTICO DE PRUEBA · no es cartografía real'),
            ),
          ),
      ],
    );
  }
}

/// Capas de zonas: relleno con borde y etiquetas de texto ancladas.
List<Widget> buildZoneLayers(List<Zone> zones) {
  return [
    PolygonLayer(polygons: [
      for (final z in zones)
        Polygon(
          points: zoneOutline(z),
          color: zoneColor(z).withValues(alpha: z.fillOpacity),
          borderColor: zoneColor(z),
          borderStrokeWidth: z.strokeWidth,
        ),
    ]),
    MarkerLayer(
      markers: [
        for (final z in zones)
          if (z.showLabel && (z.label?.isNotEmpty ?? false))
            Marker(
              point: zoneAnchor(z),
              width: 220,
              height: 40,
              alignment: Alignment.center,
              child: Align(
                alignment: Alignment.center,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: zoneColor(z), width: 1),
                  ),
                  child: Text(
                    z.label!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: zoneColor(z), fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
      ],
    ),
  ];
}

/// Color de la zona: propio, de la categoría o el corporativo.
Color zoneColor(Zone z) {
  final hex = z.colorHex;
  if (hex.length == 7 && hex.startsWith('#')) {
    final v = int.tryParse(hex.substring(1), radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return LexairColors.primary;
}

/// Punto de anclaje de la etiqueta: centro del círculo o primer vértice.
LatLng zoneAnchor(Zone z) {
  if (z.isCircle && z.center != null) return z.center!;
  if (z.vertices.isNotEmpty) return z.vertices.first;
  return const LatLng(0, 0);
}

/// Vértices para representar la zona. El círculo se aproxima localmente con 36
/// segmentos (en el servidor el polígono guardado en PostGIS es exacto).
List<LatLng> zoneOutline(Zone z) {
  if (z.isCircle) {
    final c = z.center ?? zoneAnchor(z);
    const segments = 36;
    const metersPerDegLat = 110574.0;
    final metersPerDegLon = 111320.0 * math.cos(c.latitude * math.pi / 180.0);
    final dLat = (z.radiusM ?? 0) / metersPerDegLat;
    final dLon = (z.radiusM ?? 0) / metersPerDegLon;
    return List.generate(segments, (i) {
      final a = i * 2 * math.pi / segments;
      return LatLng(
        c.latitude + dLat * math.cos(a),
        c.longitude + dLon * math.sin(a),
      );
    });
  }
  if (z.kind == 'rectangle' && z.vertices.length == 4) {
    final lats = z.vertices.map((v) => v.latitude).toList()..sort();
    final lons = z.vertices.map((v) => v.longitude).toList()..sort();
    return [
      LatLng(lats.first, lons.first), LatLng(lats.first, lons.last),
      LatLng(lats.last, lons.last), LatLng(lats.last, lons.first),
    ];
  }
  return z.vertices;
}

/// Vista previa del dibujo en curso: círculo, rectángulo o polígono.
Widget buildDrawingPreview(DrawingController d) {
  const previewColor = LexairColors.accent;
  return Stack(children: [
    if (d.tool == DrawTool.circle && d.centerPoint != null && (d.radiusM ?? 0) > 1)
      CircleLayer(circles: [
        CircleMarker(
          point: d.centerPoint!,
          radius: d.radiusM!.toDouble(),
          useRadiusInMeter: true,
          color: previewColor.withValues(alpha: 0.12),
          borderColor: previewColor,
          borderStrokeWidth: 2,
        ),
      ]),
    if (d.tool == DrawTool.rectangle && d.rectanglePreview().length == 4)
      PolygonLayer(polygons: [
        Polygon(
          points: d.rectanglePreview(),
          color: previewColor.withValues(alpha: 0.12),
          borderColor: previewColor,
          borderStrokeWidth: 2,
        ),
      ]),
    if (d.tool == DrawTool.polygon && d.ring.length >= 3)
      PolygonLayer(polygons: [
        Polygon(
          points: d.ring,
          color: previewColor.withValues(alpha: 0.12),
          borderColor: previewColor,
          borderStrokeWidth: 2,
        ),
      ]),
    MarkerLayer(markers: [
      if (d.tool == DrawTool.circle && d.centerPoint != null)
        Marker(
          point: d.centerPoint!,
          width: 30,
          height: 30,
          child: const Icon(Icons.adjust, size: 28, color: previewColor),
        ),
      if (d.tool == DrawTool.polygon)
        for (final v in d.ring)
          Marker(
            point: v,
            width: 14,
            height: 14,
            child: Container(
              decoration: BoxDecoration(
                color: previewColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
            ),
          ),
      if (d.tool == DrawTool.rectangle && d.firstPoint != null)
        Marker(
          point: d.firstPoint!,
          width: 16,
          height: 16,
          child: Container(
            decoration: BoxDecoration(
              color: previewColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
    ]),
  ]);
}
