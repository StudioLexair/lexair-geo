import 'package:latlong2/latlong.dart';

/// Categoría configurable de zona (color, icono) gestionada en Administración.
class ZoneCategory {
  const ZoneCategory({
    required this.id,
    required this.name,
    required this.colorHex,
    required this.icon,
    this.description = '',
    this.isActive = true,
    this.zoneCount = 0,
  });

  final int id;
  final String name;
  final String colorHex;
  final String icon;
  final String description;
  final bool isActive;
  final int zoneCount;

  factory ZoneCategory.fromJson(Map<String, dynamic> j) => ZoneCategory(
    id: (j['id'] as num).toInt(),
    name: j['name'] as String,
    description: (j['description'] as String?) ?? '',
    colorHex: (j['colorHex'] as String?) ?? '#0F6C81',
    icon: (j['icon'] as String?) ?? 'label',
    isActive: j['isActive'] != false,
    zoneCount: (j['zoneCount'] as num?)?.toInt() ?? 0,
  );
}

/// Área dibujada sobre el mapa: círculo (centro + radio), rectángulo
/// (esquinas) o polígono (vértices). El servidor la materializa como POLYGON
/// en PostGIS para consultas de contenido.
class Zone {
  const Zone({
    required this.id,
    required this.name,
    required this.kind,
    required this.vertices,
    required this.showLabel,
    required this.fillOpacity,
    required this.strokeWidth,
    required this.isActive,
    required this.isSynthetic,
    required this.membersCount,
    required this.manualCount,
    required this.passesInside,
    required this.personnelCount,
    required this.createdAt,
    required this.updatedAt,
    this.description,
    this.center,
    this.radiusM,
    this.label,
    this.category,
    required this.colorHex,
    this.areaKm2,
  });

  final String id;
  final String name;
  final String? description;
  final String kind; // circle | rectangle | polygon
  final List<LatLng> vertices;
  final LatLng? center;
  final int? radiusM;
  final String? label;
  final bool showLabel;
  final ZoneCategory? category;
  final String colorHex;
  final double fillOpacity;
  final double strokeWidth;
  final bool isActive;
  final bool isSynthetic;
  final double? areaKm2;
  final int membersCount;
  final int manualCount;
  final int passesInside;
  final int personnelCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Zone.fromJson(Map<String, dynamic> j) => Zone(
    id: j['id'] as String,
    name: j['name'] as String,
    description: j['description'] as String?,
    kind: (j['kind'] as String?) ?? 'polygon',
    vertices: ((j['vertices'] as List<dynamic>?) ?? const [])
        .map((v) => LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble()))
        .toList(),
    center: j['center'] == null
        ? null
        : LatLng(((j['center'] as Map<String, dynamic>)['lat'] as num).toDouble(),
            ((j['center'] as Map<String, dynamic>)['lon'] as num).toDouble()),
    radiusM: (j['radiusM'] as num?)?.toInt(),
    label: j['label'] as String?,
    showLabel: j['showLabel'] != false,
    category: j['category'] == null
        ? null
        : ZoneCategory.fromJson(j['category'] as Map<String, dynamic>),
    colorHex: (j['colorHex'] as String?) ?? '#0F6C81',
    fillOpacity: (j['fillOpacity'] as num?)?.toDouble() ?? 0.15,
    strokeWidth: (j['strokeWidth'] as num?)?.toDouble() ?? 2,
    isActive: j['isActive'] != false,
    isSynthetic: j['isSynthetic'] == true,
    areaKm2: (j['areaKm2'] as num?)?.toDouble(),
    membersCount: (j['membersCount'] as num?)?.toInt() ?? 0,
    manualCount: (j['manualCount'] as num?)?.toInt() ?? 0,
    passesInside: (j['passesInside'] as num?)?.toInt() ?? 0,
    personnelCount: (j['personnelCount'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
    updatedAt: DateTime.tryParse((j['updatedAt'] as String?) ?? '') ?? DateTime.now(),
  );

  bool get isCircle => kind == 'circle';
}

/// Resumen de persona dentro de una zona (respuesta de `/zones/:id/persons`).
class ZonePerson {
  const ZonePerson({
    required this.id,
    required this.code,
    required this.name,
    required this.groups,
    required this.onPass,
    required this.viaGeometry,
    required this.viaManual,
    this.phone,
    this.lat,
    this.lon,
    this.addressText,
    this.internCode,
    this.riskLevel,
  });

  final String id;
  final String code;
  final String name;
  final String? phone;
  final double? lat;
  final double? lon;
  final String? addressText;
  final String? internCode;
  final String? riskLevel;
  final List<String> groups;
  final bool onPass;
  final bool viaGeometry;
  final bool viaManual;

  factory ZonePerson.fromJson(Map<String, dynamic> j) => ZonePerson(
    id: j['id'] as String,
    code: j['code'] as String,
    name: j['name'] as String,
    phone: j['phone'] as String?,
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    addressText: j['address_text'] as String?,
    internCode: j['internCode'] as String?,
    riskLevel: j['riskLevel'] as String?,
    groups: ((j['groups'] as List<dynamic>?) ?? const []).cast<String>(),
    onPass: j['onPass'] == true,
    viaGeometry: j['viaGeometry'] == true,
    viaManual: j['viaManual'] == true,
  );
}

/// Personal mostrado por una zona o cerca de un punto/presos.
class ZonePersonnelItem {
  const ZonePersonnelItem({
    required this.id,
    required this.name,
    required this.assigned,
    required this.insideZone,
    this.code,
    this.rank,
    this.unit,
    this.phone,
    this.phoneAlt,
    this.addressText,
    this.roleNote,
    this.lat,
    this.lon,
    this.distanceM,
  });

  final String id;
  final String name;
  final String? code;
  final String? rank;
  final String? unit;
  final String? phone;
  final String? phoneAlt;
  final String? addressText;
  final String? roleNote;
  final bool assigned;
  final bool insideZone;
  final double? lat;
  final double? lon;
  final num? distanceM;

  factory ZonePersonnelItem.fromJson(Map<String, dynamic> j) => ZonePersonnelItem(
    id: j['id'] as String,
    name: (j['name'] ?? j['full_name'] ?? '') as String,
    code: j['code'] as String?,
    rank: j['rank'] as String?,
    unit: j['unit'] as String?,
    phone: j['phone'] as String?,
    phoneAlt: j['phone_alt'] as String?,
    addressText: j['address_text'] as String?,
    roleNote: j['role_note'] as String?,
    assigned: j['assigned'] == true,
    insideZone: j['insideZone'] == true,
    lat: (j['lat'] as num?)?.toDouble(),
    lon: (j['lon'] as num?)?.toDouble(),
    distanceM: j['distanceM'] as num?,
  );
}
