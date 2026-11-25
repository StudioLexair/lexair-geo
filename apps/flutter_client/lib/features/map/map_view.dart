import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/net/http_client_factory.dart';
import '../../core/theme/app_theme.dart';
import 'map_markers.dart';
import 'map_overlay_controls.dart';
import 'workspace_controller.dart';

/// Mapa principal. Los mosaicos se piden SIEMPRE al servidor de la LAN
/// (`/tiles/{estilo}/{z}/{x}/{y}.png`); no hay ninguna URL externa.
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

  static const _villaClara = LatLng(22.4067, -79.9653); // Santa Clara (referencia)

  @override
  void initState() {
    super.initState();
    final services = context.read<AppServices>();
    // Los mosaicos solo contienen datos OSM (sin datos personales).
    _tiles = NetworkTileProvider(
      httpClient: createHttpClient(caCertificatePath: services.config.caCertificatePath),
      silenceExceptions: true,
    );
    _sub = context.read<WorkspaceController>().centerRequests.listen((r) {
      _map.move(r.$1, r.$2 ?? _map.camera.zoom);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _tiles.dispose();
    _cursor.dispose();
    super.dispose();
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
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: pkg?.center ?? _villaClara,
            initialZoom: 11,
            minZoom: (pkg?.minZoom ?? 6).toDouble().clamp(3, 10),
            maxZoom: 19,
            backgroundColor: dark ? const Color(0xFF1D2026) : const Color(0xFFE8E6E1),
            onMapReady: () => _emitView(_map.camera),
            onPositionChanged: (camera, _) => _emitView(camera),
            onTap: (_, p) => ws.onMapTap(p),
            onPointerHover: (event, p) => _cursor.value = p,
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
            if (ws.showPersons) MarkerLayer(markers: buildFeatureMarkers(context, ws, _map)),
            MarkerLayer(markers: buildSelectionMarkers(ws)),
            SimpleAttributionWidget(
              source: Text(pkg?.attribution ?? '© OpenStreetMap contributors',
                  style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
        MapOverlayControls(map: _map, cursor: _cursor),
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
