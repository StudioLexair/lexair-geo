import '../../core/net/api_client.dart';
import '../persons/person.dart';

/// Búsqueda global unificada (/search): el servidor detecta qué es lo escrito
/// y devuelve personas, direcciones (con nombres antiguos de calles) y zonas
/// agrupadas, más una sugerencia de escritura correcta cuando hay tipeo.
class SearchRepository {
  SearchRepository(this._api);
  final ApiClient _api;

  Future<GlobalSearch> run(
    String q, {
    int limit = 10,
    List<String> filtros = const <String>[],
    String? municipio,
  }) async {
    final j = await _api.getJson('/search', {
      'q': q,
      'limit': limit,
      if (filtros.isNotEmpty) 'filtro': filtros,
      if (municipio != null && municipio.isNotEmpty) 'municipio': municipio,
    });
    return GlobalSearch.fromJson(j);
  }
}

class GlobalSearch {
  const GlobalSearch({
    required this.query,
    required this.detectado,
    required this.sugerencia,
    required this.persons,
    required this.addresses,
    required this.zones,
    required this.tookMs,
  });

  final String query;
  /// identidad · telefono · direccion · texto
  final String detectado;
  final String? sugerencia;
  final List<Person> persons;
  final List<AddressHit> addresses;
  final List<ZoneHit> zones;
  final int tookMs;
  bool get vacia => persons.isEmpty && addresses.isEmpty && zones.isEmpty;

  factory GlobalSearch.fromJson(Map<String, dynamic> j) => GlobalSearch(
    query: j['q'] as String? ?? '',
    detectado: j['detectado'] as String? ?? 'texto',
    sugerencia: j['sugerencia'] as String?,
    persons: ((j['persons'] as List?) ?? const [])
        .map((e) => Person.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    addresses: ((j['addresses'] as List?) ?? const [])
        .map((e) => AddressHit.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    zones: ((j['zones'] as List?) ?? const [])
        .map((e) => ZoneHit.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    tookMs: (j['tookMs'] as num?)?.toInt() ?? 0,
  );
}

/// Dirección hallada: calle, vivienda con número o nombre antiguo de calle.
class AddressHit {
  const AddressHit({
    required this.label,
    required this.municipality,
    required this.lat,
    required this.lon,
    required this.fuente,
  });

  final String label;
  final String? municipality;
  final double lat;
  final double lon;
  /// calle · vivienda · antiguo
  final String fuente;

  String get fuenteEtiqueta => switch (fuente) {
    'vivienda' => 'número',
    'antiguo' => 'nombre antiguo',
    _ => 'calle',
  };

  factory AddressHit.fromJson(Map<String, dynamic> j) => AddressHit(
    label: j['label'] as String? ?? '',
    municipality: j['municipality'] as String?,
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    fuente: j['fuente'] as String? ?? 'calle',
  );
}

/// Zona dibujada en el mapa (solo para quien tiene permiso de verlas).
class ZoneHit {
  const ZoneHit({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
  });

  final String id;
  final String name;
  final double lat;
  final double lon;

  factory ZoneHit.fromJson(Map<String, dynamic> j) => ZoneHit(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
  );
}
