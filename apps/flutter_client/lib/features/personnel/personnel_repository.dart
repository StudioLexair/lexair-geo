import '../../core/net/api_client.dart';
import 'personnel.dart';

class PersonnelRepository {
  PersonnelRepository(this._api);
  final ApiClient _api;

  Future<Json> list({String? q, String? zoneId, String? bbox, String status = 'active',
      int page = 1, int pageSize = 100}) async =>
    _api.getJson('/personnel', {
      'q': q, 'zoneId': zoneId, 'bbox': bbox, 'status': status, 'page': page, 'pageSize': pageSize,
    });

  Future<Personnel> get(String id) async => Personnel.fromJson(await _api.getJson('/personnel/$id'));

  Future<Personnel> create(Map<String, dynamic> body) async =>
      Personnel.fromJson(await _api.postJson('/personnel', body));

  Future<Personnel> update(String id, Map<String, dynamic> body) async =>
      Personnel.fromJson(await _api.patchJson('/personnel/$id', body));

  Future<void> delete(String id) async => _api.deleteJson('/personnel/$id');

  Future<Personnel> setLocation(String id, Map<String, dynamic> body) async =>
      Personnel.fromJson(await _api.putJson('/personnel/$id/location', body));

  /// Personal que vive cerca de un punto (por ejemplo, la ubicación de un preso).
  Future<Json> near({required double lat, required double lon, int? radius}) async =>
      _api.getJson('/personnel/near', {'lat': lat, 'lon': lon, 'radius': radius});

  /// Personal que vive cerca de una persona registrada (preso en pase).
  Future<Json> nearPerson(String personId, {int? radius}) async =>
      _api.getJson('/persons/$personId/nearby-personnel', {'radius': radius});
}
