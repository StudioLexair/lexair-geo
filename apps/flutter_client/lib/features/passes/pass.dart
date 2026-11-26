/// Estado calculado por el servidor a partir de las fechas y las marcas de
/// cierre (no hay cron): scheduled/active/expired/returned/cancelled.
class Pass {
  const Pass({
    required this.id,
    required this.personId,
    required this.state,
    required this.startsAt,
    required this.endsAt,
    required this.createdAt,
    this.passTypeId,
    this.passTypeName,
    this.passTypeColor,
    this.facility,
    this.returnedAt,
    this.cancelledAt,
    this.authorizedZoneId,
    this.authorizedZoneName,
    this.authorizedAddress,
    this.notes,
    this.dataSource,
    this.code,
    this.personName,
    this.phone,
    this.internCode,
    this.riskLevel,
    this.lat,
    this.lon,
    this.addressText,
    this.validationStatus,
    this.authorizedHere,
  });

  final String id;
  final String personId;
  final int? passTypeId;
  final String? passTypeName;
  final String? passTypeColor;
  final String? facility;
  final DateTime startsAt;
  final DateTime endsAt;
  final DateTime? returnedAt;
  final DateTime? cancelledAt;
  final String? authorizedZoneId;
  final String? authorizedZoneName;
  final String? authorizedAddress;
  final String? notes;
  final String? dataSource;
  final String state;
  // Datos de la persona (presentes en las respuestas de listado y mapa).
  final String? code;
  final String? personName;
  final String? phone;
  final String? internCode;
  final String? riskLevel;
  final double? lat;
  final double? lon;
  final String? addressText;
  final String? validationStatus;
  final bool? authorizedHere;
  final DateTime createdAt;

  bool get isActive => state == 'active';

  factory Pass.fromJson(Map<String, dynamic> j) => Pass(
    id: j['id'] as String,
    personId: (j['personId'] ?? j['person_id']) as String,
    passTypeId: (j['passTypeId'] as num?)?.toInt(),
    passTypeName: (j['passTypeName'] ?? j['passType']) as String?,
    passTypeColor: (j['passTypeColor'] ?? j['passTypeColorHex']) as String?,
    facility: j['facility'] as String?,
    startsAt: DateTime.tryParse((j['startsAt'] as String?) ?? '') ?? DateTime.now(),
    endsAt: DateTime.tryParse((j['endsAt'] as String?) ?? '') ?? DateTime.now(),
    returnedAt: j['returnedAt'] == null ? null : DateTime.tryParse(j['returnedAt'] as String),
    cancelledAt: j['cancelledAt'] == null ? null : DateTime.tryParse(j['cancelledAt'] as String),
    authorizedZoneId: (j['authorizedZoneId'] ?? j['authorized_zone_id']) as String?,
    authorizedZoneName: (j['authorizedZoneName'] ?? j['authorized_zone_name']) as String?,
    authorizedAddress: (j['authorizedAddress'] ?? j['authorized_address']) as String?,
    notes: j['notes'] as String?,
    dataSource: (j['dataSource'] ?? j['data_source']) as String?,
    state: (j['state'] as String?) ?? 'scheduled',
    code: j['code'] as String?,
    personName: (j['personName'] ?? j['name']) as String?,
    phone: j['phone'] as String?,
    internCode: (j['internCode'] ?? j['intern_code']) as String?,
    riskLevel: (j['riskLevel'] ?? j['risk_level']) as String?,
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    addressText: j['address_text'] as String?,
    validationStatus: j['validationStatus'] as String?,
    authorizedHere: j['authorizedHere'] as bool?,
    createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
  );
}

/// Tipo de pase del catálogo configurable.
class PassType {
  const PassType({
    required this.id,
    required this.code,
    required this.name,
    required this.defaultDays,
    required this.colorHex,
    required this.isActive,
    required this.passCount,
    this.description = '',
  });

  final int id;
  final String code;
  final String name;
  final String description;
  final int defaultDays;
  final String colorHex;
  final bool isActive;
  final int passCount;

  factory PassType.fromJson(Map<String, dynamic> j) => PassType(
    id: (j['id'] as num).toInt(),
    code: j['code'] as String,
    name: j['name'] as String,
    description: (j['description'] as String?) ?? '',
    defaultDays: (j['defaultDays'] as num?)?.toInt() ?? 7,
    colorHex: (j['colorHex'] as String?) ?? '#1565C0',
    isActive: j['isActive'] != false,
    passCount: (j['passCount'] as num?)?.toInt() ?? 0,
  );
}

/// Ficha de interno ligada a una persona del directorio.
class Inmate {
  const Inmate({
    required this.personId,
    required this.isActive,
    this.internCode,
    this.facility,
    this.status,
    this.riskLevel,
    this.cellRef,
    this.notes,
    this.dataSource,
  });

  final String personId;
  final String? internCode;
  final String? facility;
  final String? status;
  final String? riskLevel;
  final String? cellRef;
  final String? notes;
  final String? dataSource;
  final bool isActive;

  factory Inmate.fromJson(Map<String, dynamic> j) => Inmate(
    personId: (j['personId'] ?? j['person_id']) as String,
    internCode: (j['internCode'] ?? j['intern_code']) as String?,
    facility: j['facility'] as String?,
    status: j['status'] as String?,
    riskLevel: (j['riskLevel'] ?? j['risk_level']) as String?,
    cellRef: (j['cellRef'] ?? j['cell_ref']) as String?,
    notes: j['notes'] as String?,
    dataSource: (j['dataSource'] ?? j['data_source']) as String?,
    isActive: j['isActive'] != false,
  );
}

/// Marcador del mapa (`/passes/map`): pase activo con ubicación del interno.
class PassMarker {
  const PassMarker({required this.pass, required this.lat, required this.lon});
  final Pass pass;
  final double lat;
  final double lon;
}

/// Configuración del marcador (icono, color, tamaño) editable en Administración.
class MarkerStyle {
  const MarkerStyle({this.icon = 'local_police', this.colorHex = '#C62828', this.size = 30});
  final String icon;
  final String colorHex;
  final int size;

  factory MarkerStyle.fromJson(Map<String, dynamic> j) => MarkerStyle(
    icon: (j['icon'] as String?) ?? 'local_police',
    colorHex: (j['colorHex'] as String?) ?? '#C62828',
    size: (j['size'] as num?)?.toInt() ?? 30,
  );
}
