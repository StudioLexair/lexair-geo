import '../../core/net/api_client.dart';

export '../../core/net/api_client.dart' show Json;

List<Json> itemsOf(Json j, [String key = 'items']) =>
    ((j[key] as List<dynamic>?) ?? const []).cast<Json>();

/// Acceso a los endpoints de administración. Cada método corresponde a
/// una ruta real del API; no hay datos locales simulados.
class AdminRepository {
  AdminRepository(this.api);
  final ApiClient api;

  Future<Json> dashboard() => api.getJson('/admin/dashboard');
  Future<Json> status() => api.getJson('/admin/status');

  Future<List<Json>> users() async => itemsOf(await api.getJson('/users'));
  Future<Json> createUser(Json body) => api.postJson('/users', body);
  Future<Json> updateUser(String id, Json body) => api.patchJson('/users/$id', body);
  Future<Json> resetPassword(String id) => api.postJson('/users/$id/reset-password');

  Future<Json> roles() => api.getJson('/admin/roles');
  Future<Json> setRolePermissions(String code, List<String> perms) =>
      api.putJson('/admin/roles/$code/permissions', {'permissions': perms});

  Future<List<Json>> groups() async => itemsOf(await api.getJson('/groups'));

  Future<List<Json>> settings() async => itemsOf(await api.getJson('/admin/settings'));
  Future<Json> putSetting(String key, Object? value) => api.putJson('/admin/settings/$key', {'value': value});

  Future<Json> audit(Map<String, Object?> q) => api.getJson('/audit', q);

  Future<List<Json>> imports() async => itemsOf(await api.getJson('/imports'));
  Future<Json> importDetail(String id) => api.getJson('/imports/$id');
  Future<Json> importCsv(String csv, {required String group, required bool dryRun, required String filename}) =>
      api.postText('/imports/persons', csv, 'text/csv; charset=utf-8',
          {'group': group, 'dryRun': '$dryRun', 'filename': filename});

  Future<String> exportCsv(Map<String, Object?> q) => api.getText('/exports/persons.csv', q);

  Future<List<Json>> municipalities() async => itemsOf(await api.getJson('/geocoding/municipalities'));
  Future<List<Json>> aliases() async => itemsOf(await api.getJson('/geocoding/aliases'));
  Future<Json> addAlias(Json body) => api.postJson('/geocoding/aliases', body);
  Future<Json> deleteAlias(int id) => api.deleteJson('/geocoding/aliases/$id');
  Future<List<Json>> localAddresses() async => itemsOf(await api.getJson('/geocoding/addresses'));
  Future<Json> addAddress(Json body) => api.postJson('/geocoding/addresses', body);
  Future<Json> deleteAddress(int id) => api.deleteJson('/geocoding/addresses/$id');

  Future<Json> mapStyles() => api.getJson('/maps/styles');

  // --- Operación de pases: zonas, personal, internos ------------------------
  Future<List<Json>> zoneCategories() async => itemsOf(await api.getJson('/zones/categories'));
  Future<Json> createZoneCategory(Json body) => api.postJson('/zones/categories', body);
  Future<Json> updateZoneCategory(int id, Json body) => api.patchJson('/zones/categories/$id', body);

  Future<List<Json>> passTypes() async => itemsOf(await api.getJson('/passes/types'));
  Future<Json> createPassType(Json body) => api.postJson('/passes/types', body);
  Future<Json> updatePassType(int id, Json body) => api.patchJson('/passes/types/$id', body);

  // --- Conectores Oracle 11g -----------------------------------------------
  Future<List<Json>> oracleConnectors() async => itemsOf(await api.getJson('/oracle/connectors'));
  Future<Json> createOracleConnector(Json body) => api.postJson('/oracle/connectors', body);
  Future<Json> updateOracleConnector(String id, Json body) => api.patchJson('/oracle/connectors/$id', body);
  Future<void> deleteOracleConnector(String id) => api.deleteJson('/oracle/connectors/$id');
  Future<Json> testOracleConnector(String id) => api.postJson('/oracle/connectors/$id/test', {});
  Future<Json> runOracleConnector(String id, {bool dryRun = false}) =>
      api.postJson('/oracle/connectors/$id/run', {'dryRun': dryRun});
  Future<List<Json>> oracleRuns({String? connectorId}) async =>
      itemsOf(await api.getJson('/oracle/runs', {'connectorId': connectorId, 'limit': 100}));
}
