import 'package:latlong2/latlong.dart';

class PersonLocation {
  const PersonLocation({
    required this.precisionLevel,
    required this.validationStatus,
    required this.addressGranularity,
    required this.coordSource,
    required this.exact,
    this.lat,
    this.lon,
    this.addressText,
    this.municipalityId,
    this.municipality,
    this.locality,
    this.updatedAt,
  });

  final String precisionLevel;
  final String validationStatus;
  final String addressGranularity;
  final String coordSource;
  final bool exact;
  final double? lat;
  final double? lon;
  final String? addressText;
  final int? municipalityId;
  final String? municipality;
  final String? locality;
  final String? updatedAt;

  /// Solo existe si el usuario tiene permiso de ubicación exacta.
  LatLng? get point => lat != null && lon != null ? LatLng(lat!, lon!) : null;

  factory PersonLocation.fromJson(Map<String, dynamic> j) => PersonLocation(
    precisionLevel: j['precisionLevel'] as String,
    validationStatus: (j['validationStatus'] as String?) ?? 'pending',
    addressGranularity: (j['addressGranularity'] as String?) ?? 'unknown',
    coordSource: (j['coordSource'] as String?) ?? 'manual_coordinates',
    exact: j['exact'] == true,
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    addressText: j['addressText'] as String?,
    municipalityId: j['municipalityId'] as int?,
    municipality: j['municipality'] as String?,
    locality: j['locality'] as String?,
    updatedAt: j['updatedAt'] as String?,
  );
}

class Person {
  const Person({
    required this.id,
    required this.code,
    required this.givenNames,
    required this.familyNames,
    required this.groups,
    required this.isActive,
    required this.isSynthetic,
    required this.visibility,
    required this.consentStatus,
    required this.dataSource,
    this.phone,
    this.notes,
    this.cdr,
    this.defenseZone,
    this.location,
    this.distanceM,
  });

  final String id;
  final String code;
  final String givenNames;
  final String familyNames;
  final List<String> groups;
  final bool isActive;
  final bool isSynthetic;
  final String visibility;
  final String consentStatus;
  final String dataSource;
  final String? phone;
  final String? notes;
  final String? cdr;
  final String? defenseZone;
  final PersonLocation? location;
  final num? distanceM;

  String get fullName => '$givenNames $familyNames';

  factory Person.fromJson(Map<String, dynamic> j) => Person(
    id: j['id'] as String,
    code: j['code'] as String,
    givenNames: j['givenNames'] as String,
    familyNames: j['familyNames'] as String,
    groups: ((j['groups'] as List<dynamic>?) ?? const []).cast<String>(),
    isActive: j['isActive'] != false,
    isSynthetic: j['isSynthetic'] == true,
    visibility: (j['visibility'] as String?) ?? 'normal',
    consentStatus: (j['consentStatus'] as String?) ?? 'pending',
    dataSource: (j['dataSource'] as String?) ?? '',
    phone: j['phone'] as String?,
    notes: j['notes'] as String?,
    cdr: j['cdr'] as String?,
    defenseZone: j['defenseZone'] as String?,
    location: j['location'] == null
        ? null
        : PersonLocation.fromJson(j['location'] as Map<String, dynamic>),
    distanceM: j['distanceM'] as num?,
  );
}

class PageResult<T> {
  const PageResult({required this.items, required this.total, required this.page,
      required this.pageSize, this.totalIsCapped = false});
  final List<T> items;
  final int total;
  final int page;
  final int pageSize;
  final bool totalIsCapped;

  bool get hasMore => page * pageSize < total;

  static PageResult<T> fromJson<T>(Map<String, dynamic> j, T Function(Map<String, dynamic>) f) =>
      PageResult(
        items: ((j['items'] as List<dynamic>?) ?? const [])
            .map((e) => f(e as Map<String, dynamic>))
            .toList(),
        total: (j['total'] as num?)?.toInt() ?? 0,
        page: (j['page'] as num?)?.toInt() ?? 1,
        pageSize: (j['pageSize'] as num?)?.toInt() ?? 50,
        totalIsCapped: j['totalIsCapped'] == true,
      );
}
