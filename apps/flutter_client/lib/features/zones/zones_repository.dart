import 'package:latlong2/latlong.dart';

import '../../core/net/api_client.dart';
import 'zone.dart';

/// Especificación de geometría dibujada en el cliente, tal como la espera
/// `POST /zones` (el servidor la convierte a POLYGON de PostGIS).
class ZoneGeometrySpec {
  const ZoneGeometrySpec.circle({required this.center, required this.radiusM})
    : kind = 'circle', corners = null, ring = null;
  const ZoneGeometrySpec.rectangle({required this.corners})
    : kind = 'rectangle', center = null, radiusM = null, ring = null;
  const ZoneGeometrySpec.polygon({required this.ring})
    : kind = 'polygon', center = null, radiusM = null, corners = null;

  final String kind;
  final LatLng? center;
  final int? radiusM;
  final List<LatLng>? corners;
  final List<LatLng>? ring;

  Map<String, dynamic> toJson() {
    List<Map<String, dynamic>> verts(List<LatLng> list) =>
      list.map((p) => {'lat': p.latitude, 'lon': p.longitude}).toList();
    switch (kind) {
      case 'circle':
        return {'kind': 'circle', 'lat': center!.latitude, 'lon': center!.longitude, 'radiusM': radiusM};
      case 'rectangle':
        return {
          'kind': 'rectangle',
          'north': corners!.reduce((a, b) => a.latitude > b.latitude ? a : b).latitude,
          'south': corners!.reduce((a, b) => a.latitude < b.latitude ? a : b).latitude,
          'east': corners!.reduce((a, b) => a.longitude > b.longitude ? a : b).longitude,
          'west': corners!.reduce((a, b) => a.longitude < b.longitude ? a : b).longitude,
        };
      default:
        return {'kind': 'polygon', 'vertices': verts(ring!)};
    }
  }
}

class ZonesRepository {
  ZonesRepository(this._api);
  final ApiClient _api;

  List<Zone> _zones(Json j) => ((j['items'] as List<dynamic>?) ?? const [])
      .cast<Map<String, dynamic>>().map(Zone.fromJson).toList();

  Future<List<Zone>> list({String? bbox, bool includeInactive = false, int? categoryId}) async {
    final j = await _api.getJson('/zones', {
      'bbox': bbox,
      if (includeInactive) 'includeInactive': 'true',
      'categoryId': categoryId,
    });
    return _zones(j);
  }

  Future<Zone> create(Map<String, dynamic> body) async => Zone.fromJson(await _api.postJson('/zones', body));

  Future<Zone> update(String id, Map<String, dynamic> body) async =>
      Zone.fromJson(await _api.patchJson('/zones/$id', body));

  Future<void> delete(String id) async => _api.deleteJson('/zones/$id');

  /// ¿Qué zonas hay bajo un punto tocado en el mapa?
  Future<List<Zone>> containing(LatLng p) async {
    final j = await _api.getJson('/zones/containing',
        {'lat': p.latitude.toStringAsFixed(6), 'lon': p.longitude.toStringAsFixed(6)});
    return _zones(j);
  }

  Future<Json> persons(String zoneId, {int page = 1, int pageSize = 50}) async =>
      _api.getJson('/zones/$zoneId/persons', {'page': page, 'pageSize': pageSize});

  Future<({int added, int removed})> assignPersons(String zoneId,
      {List<String> add = const [], List<String> remove = const []}) async {
    final j = await _api.putJson('/zones/$zoneId/persons', {'add': add, 'remove': remove});
    return (added: (j['added'] as num?)?.toInt() ?? 0, removed: (j['removed'] as num?)?.toInt() ?? 0);
  }

  Future<({int removedStale, int added})> recompute(String zoneId) async {
    final j = await _api.postJson('/zones/$zoneId/recompute');
    return (
      removedStale: (j['removedStale'] as num?)?.toInt() ?? 0,
      added: (j['added'] as num?)?.toInt() ?? 0,
    );
  }

  Future<Json> personnel(String zoneId) async => _api.getJson('/zones/$zoneId/personnel');

  Future<Json> passes(String zoneId) async => _api.getJson('/zones/$zoneId/passes');

  Future<List<ZoneCategory>> categories() async {
    final j = await _api.getJson('/zones/categories');
    return ((j['items'] as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>().map(ZoneCategory.fromJson).toList();
  }

  Future<void> createCategory(Map<String, dynamic> body) => _api.postJson('/zones/categories', body);
  Future<void> updateCategory(int id, Map<String, dynamic> body) =>
      _api.patchJson('/zones/categories/$id', body);
}
