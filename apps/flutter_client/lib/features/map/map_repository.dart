import 'package:latlong2/latlong.dart';

import '../../core/net/api_client.dart';

class MapStyle {
  const MapStyle({required this.id, required this.name, required this.kind});
  final String id;
  final String name;
  final String kind;
}

class MapPackageInfo {
  const MapPackageInfo({required this.installed, required this.styles, required this.attribution,
      this.version, this.isSynthetic = false, this.minZoom = 6, this.maxZoom = 18, this.center});
  final bool installed;
  final List<MapStyle> styles;
  final String attribution;
  final String? version;
  final bool isSynthetic;
  final int minZoom;
  final int maxZoom;
  final LatLng? center;
}

/// Punto o agrupación devuelto por `/maps/points`.
class MapFeature {
  const MapFeature({required this.point, required this.count, this.personId, this.code,
      this.name, this.groups = const [], this.precisionLevel, this.hasA = false, this.hasB = false});
  final LatLng point;
  final int count;
  final String? personId;
  final String? code;
  final String? name;
  final List<String> groups;
  final String? precisionLevel;
  final bool hasA;
  final bool hasB;

  bool get isCluster => personId == null;
}

class MapRepository {
  MapRepository(this._api);
  final ApiClient _api;

  Future<MapPackageInfo> styles() async {
    final j = await _api.getJson('/maps/styles');
    final center = j['center'] as List<dynamic>?;
    return MapPackageInfo(
      installed: j['installed'] == true,
      styles: ((j['styles'] as List<dynamic>?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((s) => MapStyle(id: s['id'] as String, name: s['name'] as String, kind: s['kind'] as String))
          .toList(),
      attribution: (j['attribution'] as String?) ?? '© OpenStreetMap contributors',
      version: j['version'] as String?,
      isSynthetic: j['isSynthetic'] == true,
      minZoom: (j['minzoom'] as num?)?.toInt() ?? 6,
      maxZoom: (j['maxzoom'] as num?)?.toInt() ?? 18,
      center: center == null
          ? null
          : LatLng((center[1] as num).toDouble(), (center[0] as num).toDouble()),
    );
  }

  Future<List<MapFeature>> points({required double west, required double south,
      required double east, required double north, required double zoom, String? groups}) async {
    final j = await _api.getJson('/maps/points', {
      'bbox': [west, south, east, north].map((v) => v.toStringAsFixed(5)).join(','),
      'zoom': zoom.toStringAsFixed(1),
      'groups': groups,
    });
    final mode = j['mode'];
    return ((j['items'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>().map((e) {
      final p = LatLng((e['lat'] as num).toDouble(), (e['lon'] as num).toDouble());
      if (mode == 'points') {
        return MapFeature(point: p, count: 1, personId: e['id'] as String, code: e['code'] as String?,
            name: e['name'] as String?, groups: ((e['groups'] as List<dynamic>?) ?? const []).cast<String>(),
            precisionLevel: e['precisionLevel'] as String?);
      }
      return MapFeature(point: p, count: (e['count'] as num).toInt(),
          hasA: e['hasA'] == true, hasB: e['hasB'] == true);
    }).toList();
  }
}
