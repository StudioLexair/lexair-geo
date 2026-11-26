import '../../core/net/api_client.dart';
import 'pass.dart';

class PassesRepository {
  PassesRepository(this._api);
  final ApiClient _api;

  Future<Json> list({String state = 'active', String? personId, String? zoneId, String? q,
      int page = 1, int pageSize = 100}) async =>
    _api.getJson('/passes', {
      'state': state, 'personId': personId, 'zoneId': zoneId, 'q': q, 'page': page, 'pageSize': pageSize,
    });

  Future<Pass> create(Map<String, dynamic> body) async =>
      Pass.fromJson(await _api.postJson('/passes', body));

  Future<void> update(String id, Map<String, dynamic> body) async =>
      _api.patchJson('/passes/$id', body);

  Future<void> markReturned(String id) async => _api.postJson('/passes/$id/return', {});

  Future<void> cancel(String id) async => _api.postJson('/passes/$id/cancel', {});

  Future<List<PassType>> types() async {
    final j = await _api.getJson('/passes/types');
    return ((j['items'] as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>().map(PassType.fromJson).toList();
  }

  Future<void> createType(Map<String, dynamic> body) => _api.postJson('/passes/types', body);
  Future<void> updateType(int id, Map<String, dynamic> body) =>
      _api.patchJson('/passes/types/$id', body);

  /// Opciones configurables (estados y riesgos de interno).
  Future<Json> options() async => _api.getJson('/passes/options');

  /// Ficha de interno + pases de una persona (`GET /persons/:id/passes`).
  Future<Json> ofPerson(String personId) async => _api.getJson('/persons/$personId/passes');

  Future<Inmate> registerInmate(String personId, Map<String, dynamic> body) async =>
      Inmate.fromJson(await _api.postJson('/persons/$personId/inmate', body));

  /// Marcadores de pases activos para el bbox actual. Devuelve null si el
  /// usuario no tiene permiso de ubicación exacta (el servidor oculta puntos).
  Future<({List<PassMarker> markers, MarkerStyle style})?> map(
      {required double west, required double south, required double east, required double north}) async {
    final j = await _api.getJson('/passes/map', {
      'bbox': [west, south, east, north].map((v) => v.toStringAsFixed(5)).join(','),
    });
    if (j['mode'] != 'points') return null;
    final markers = ((j['items'] as List<dynamic>?) ?? const []).cast<Map<String, dynamic>>().map((e) {
      final lat = (e['lat'] as num).toDouble();
      final lon = (e['lon'] as num).toDouble();
      return PassMarker(pass: Pass.fromJson(e), lat: lat, lon: lon);
    }).toList();
    final style = j['marker'] == null
        ? const MarkerStyle()
        : MarkerStyle.fromJson(j['marker'] as Map<String, dynamic>);
    return (markers: markers, style: style);
  }
}
