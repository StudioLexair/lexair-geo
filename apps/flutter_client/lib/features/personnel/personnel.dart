/// Ficha del personal de la fuerza (militares y colaboradores):
/// grado, unidad, teléfonos y residencia para consultas de proximidad.
class Personnel {
  const Personnel({
    required this.id,
    required this.fullName,
    required this.isActive,
    required this.isSynthetic,
    required this.dataSource,
    required this.createdAt,
    required this.updatedAt,
    this.code,
    this.rank,
    this.unit,
    this.phone,
    this.phoneAlt,
    this.addressText,
    this.municipalityId,
    this.municipality,
    this.zoneId,
    this.zoneName,
    this.roleNote,
    this.lat,
    this.lon,
    this.exactLocation = true,
    this.distanceM,
  });

  final String id;
  final String? code;
  final String fullName;
  final String? rank;
  final String? unit;
  final String? phone;
  final String? phoneAlt;
  final String? addressText;
  final int? municipalityId;
  final String? municipality;
  final String? zoneId;
  final String? zoneName;
  final String? roleNote;
  final bool isActive;
  final bool isSynthetic;
  final String dataSource;
  final double? lat;
  final double? lon;
  final bool exactLocation;
  final num? distanceM;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasPoint => lat != null && lon != null;

  factory Personnel.fromJson(Map<String, dynamic> j) => Personnel(
    id: j['id'] as String,
    code: j['code'] as String?,
    fullName: (j['fullName'] ?? j['full_name'] ?? '') as String,
    rank: j['rank'] as String?,
    unit: j['unit'] as String?,
    phone: j['phone'] as String?,
    phoneAlt: (j['phoneAlt'] ?? j['phone_alt']) as String?,
    addressText: (j['addressText'] ?? j['address_text']) as String?,
    municipalityId: (j['municipalityId'] ?? j['municipality_id']) as int?,
    municipality: j['municipality'] as String?,
    zoneId: (j['zone'] == null ? null : (j['zone'] as Map<String, dynamic>)['id']) as String?,
    zoneName: (j['zone'] == null ? null : (j['zone'] as Map<String, dynamic>)['name']) as String?,
    roleNote: (j['roleNote'] ?? j['role_note']) as String?,
    isActive: j['isActive'] != false,
    isSynthetic: j['isSynthetic'] == true,
    dataSource: (j['dataSource'] as String?) ?? 'manual',
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    exactLocation: (j['location'] as Map<String, dynamic>?)?['exact'] != false,
    distanceM: j['distanceM'] as num?,
    createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse((j['updatedAt'] as String?) ?? '') ?? DateTime.now(),
  );
}
