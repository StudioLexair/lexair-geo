import 'package:latlong2/latlong.dart';

import '../../core/net/api_client.dart';

class GeocodeResult {
  const GeocodeResult({required this.kind, required this.label, required this.point,
      required this.granularity, required this.suggestedPrecision, required this.confidence,
      required this.source, required this.isSynthetic, this.municipalityId, this.municipality,
      this.localityId, this.locality, this.note});

  final String kind;
  final String label;
  final LatLng point;
  final String granularity;
  final String suggestedPrecision;
  final double confidence;
  final String source;
  final bool isSynthetic;
  final int? municipalityId;
  final String? municipality;
  final int? localityId;
  final String? locality;
  final String? note;

  factory GeocodeResult.fromJson(Map<String, dynamic> j) => GeocodeResult(
    kind: j['kind'] as String,
    label: j['label'] as String,
    point: LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
    granularity: j['granularity'] as String,
    suggestedPrecision: j['suggestedPrecision'] as String,
    confidence: (j['confidence'] as num).toDouble(),
    source: (j['source'] as String?) ?? '',
    isSynthetic: j['isSynthetic'] == true,
    municipalityId: j['municipalityId'] as int?,
    municipality: j['municipality'] as String?,
    localityId: j['localityId'] as int?,
    locality: j['locality'] as String?,
    note: j['note'] as String?,
  );
}

class Municipality {
  const Municipality({required this.id, required this.name, this.isSynthetic = false});
  final int id;
  final String name;
  final bool isSynthetic;
}

class GeocodingRepository {
  GeocodingRepository(this._api);
  final ApiClient _api;

  Future<List<GeocodeResult>> search(String q, {int? municipalityId}) async {
    final j = await _api.getJson('/geocoding/search', {'q': q, 'municipalityId': municipalityId});
    return ((j['items'] as List<dynamic>?) ?? const [])
        .map((e) => GeocodeResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> reverse(LatLng p) =>
      _api.getJson('/geocoding/reverse', {'lat': p.latitude, 'lon': p.longitude});

  Future<List<Municipality>> municipalities() async {
    final j = await _api.getJson('/geocoding/municipalities');
    return ((j['items'] as List<dynamic>?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((m) => Municipality(id: m['id'] as int, name: m['name'] as String,
            isSynthetic: m['isSynthetic'] == true))
        .toList();
  }
}
