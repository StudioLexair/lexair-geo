import '../../core/net/api_client.dart';
import 'person.dart';

class NearbyResult {
  const NearbyResult({required this.origin, required this.radiusM, required this.page,
      required this.distancesRounded});
  final Person origin;
  final int radiusM;
  final PageResult<Person> page;
  final bool distancesRounded;
}

class RadiusOptions {
  const RadiusOptions({required this.presets, required this.customAllowed, required this.maxCustom});
  final List<int> presets;
  final bool customAllowed;
  final int maxCustom;
}

class PersonsRepository {
  PersonsRepository(this._api);
  final ApiClient _api;

  Future<PageResult<Person>> search({
    String? q,
    String? groups,
    int? municipalityId,
    String status = 'active',
    String? validation,
    String? onPass,
    int page = 1,
    int pageSize = 50,
  }) async {
    final j = await _api.getJson('/persons', {
      'q': q, 'groups': groups, 'municipalityId': municipalityId, 'status': status,
      'validation': validation, 'onPass': onPass, 'page': page, 'pageSize': pageSize,
    });
    return PageResult.fromJson(j, Person.fromJson);
  }

  Future<Person> get(String id) async => Person.fromJson(await _api.getJson('/persons/$id'));

  Future<Person> create(Map<String, dynamic> body) async =>
      Person.fromJson(await _api.postJson('/persons', body));

  Future<Person> update(String id, Map<String, dynamic> body) async =>
      Person.fromJson(await _api.patchJson('/persons/$id', body));

  Future<Person> setActive(String id, bool active) async => Person.fromJson(
      await _api.postJson('/persons/$id/${active ? 'reactivate' : 'deactivate'}'));

  Future<Person> setGroups(String id, List<String> groups) async =>
      Person.fromJson(await _api.putJson('/persons/$id/groups', {'groups': groups}));

  Future<Person> setLocation(String id, Map<String, dynamic> body) async =>
      Person.fromJson(await _api.putJson('/persons/$id/location', body));

  Future<Person> verifyLocation(String id, {String status = 'validated',
      String precision = 'exact_verified'}) async =>
      Person.fromJson(await _api.postJson('/persons/$id/location/verify',
          {'status': status, 'precisionLevel': precision}));

  Future<RadiusOptions> radii() async {
    final j = await _api.getJson('/proximity/radii');
    return RadiusOptions(
      presets: ((j['presets'] as List<dynamic>?) ?? const []).map((e) => (e as num).toInt()).toList(),
      customAllowed: j['customAllowed'] == true,
      maxCustom: (j['maxCustom'] as num?)?.toInt() ?? 0,
    );
  }

  Future<NearbyResult> nearby(String id, int radius, {String? groups, int page = 1,
      int pageSize = 50}) async {
    final j = await _api.getJson('/persons/$id/nearby',
        {'radius': radius, 'groups': groups, 'page': page, 'pageSize': pageSize});
    return NearbyResult(
      origin: Person.fromJson(j['origin'] as Map<String, dynamic>),
      radiusM: (j['radiusM'] as num).toInt(),
      page: PageResult.fromJson(j, Person.fromJson),
      distancesRounded: j['distancesRounded'] == true,
    );
  }
}
