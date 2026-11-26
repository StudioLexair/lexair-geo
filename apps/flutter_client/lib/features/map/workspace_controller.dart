import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../core/net/api_exception.dart';
import '../geocoding/geocoding_repository.dart';
import '../passes/pass.dart';
import '../passes/passes_repository.dart';
import '../personnel/personnel.dart';
import '../personnel/personnel_repository.dart';
import '../persons/person.dart';
import '../persons/persons_repository.dart';
import '../zones/zone.dart';
import '../zones/zones_repository.dart';
import 'map_repository.dart';
import 'map_drawing.dart';

enum ToolTab { persons, addresses, zones }

/// Estado del espacio de trabajo GIS: estilo de mapa, capas (personas, zonas
/// dibujadas, pases activos, personal), persona/zona seleccionada,
/// proximidad, marcador provisional y herramienta de dibujo activa.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required this.maps,
    required this.persons,
    required this.geocoding,
    required ZonesRepository zones,
    required PersonnelRepository personnel,
    required PassesRepository passes,
  })  : zonesRepo = zones,
        personnelRepo = personnel,
        passesRepo = passes;

  final MapRepository maps;
  final PersonsRepository persons;
  final GeocodingRepository geocoding;
  final ZonesRepository zonesRepo;
  final PersonnelRepository personnelRepo;
  final PassesRepository passesRepo;

  MapPackageInfo? package;
  String? styleId;
  String? mapError;

  List<MapFeature> features = const [];
  bool loadingFeatures = false;
  String groupFilter = 'all';
  bool showPersons = true;
  Timer? _debounce;
  ({double w, double s, double e, double n, double z})? _lastView;

  // --- Capas de operación de pases -----------------------------------------
  List<Zone> zones = const [];
  bool showZones = true;
  bool loadingZones = false;

  List<PassMarker> passMarkers = const [];
  MarkerStyle passMarkerStyle = const MarkerStyle();
  bool showPasses = true;
  bool passesHidden = false; // sin permiso de ubicación exacta
  int hiddenPassCount = 0;

  List<Personnel> personnelMarkers = const [];
  bool showPersonnel = false;

  Zone? selectedZone;
  List<ZonePerson> zonePersons = const [];
  List<ZonePersonnelItem> zonePersonnel = const [];
  List<Pass> zonePasses = const [];
  bool loadingZoneDetail = false;

  ToolTab tab = ToolTab.persons;
  Person? selected;
  NearbyResult? nearby;
  bool loadingNearby = false;
  String? nearbyError;

  /// Marcador provisional (búsqueda de dirección o selección en mapa).
  LatLng? provisional;
  GeocodeResult? provisionalSource;
  bool pickMode = false;

  /// Herramienta de dibujo de zonas (círculo, rectángulo, polígono).
  final drawing = DrawingController();

  /// Geometría terminada esperando «asignar área» (la vista abre el diálogo
  /// y la consume con [consumePendingZoneSpec] al cerrarlo).
  ZoneGeometrySpec? pendingZoneSpec;
  ZoneGeometrySpec? consumePendingZoneSpec() {
    final s = pendingZoneSpec;
    pendingZoneSpec = null;
    return s;
  }

  /// Solicitudes de centrado para el MapController (consumidas por la vista).
  final StreamController<(LatLng, double?)> _center = StreamController.broadcast();
  Stream<(LatLng, double?)> get centerRequests => _center.stream;

  Future<void> loadStyles() async {
    try {
      package = await maps.styles();
      styleId = package!.styles.isNotEmpty ? package!.styles.first.id : null;
      mapError = package!.installed ? null : 'No hay paquete cartográfico instalado en el servidor';
    } on ApiException catch (e) {
      mapError = e.message;
    }
    notifyListeners();
    await refreshZones();
  }

  void setStyle(String id) {
    styleId = id;
    notifyListeners();
  }

  void setTab(ToolTab t) {
    tab = t;
    notifyListeners();
    if (t == ToolTab.zones) refreshZones();
  }

  void centerOn(LatLng p, [double? zoom]) => _center.add((p, zoom));

  String? get _groupsParam => groupFilter == 'all' ? null : groupFilter;

  void setGroupFilter(String value) {
    groupFilter = value;
    notifyListeners();
    _refetch();
  }

  void toggleShowPersons(bool v) {
    showPersons = v;
    notifyListeners();
    if (v) _refetch();
  }

  void toggleShowZones(bool v) {
    showZones = v;
    if (v) refreshZones();
    notifyListeners();
  }

  void toggleShowPasses(bool v) {
    showPasses = v;
    notifyListeners();
    if (v) _refetch();
  }

  void toggleShowPersonnel(bool v) {
    showPersonnel = v;
    notifyListeners();
    if (v) _refetch();
  }

  String? get _bboxParam {
    final v = _lastView;
    if (v == null) return null;
    return [v.w, v.s, v.e, v.n].map((x) => x.toStringAsFixed(5)).join(',');
  }

  /// Llamado al mover el mapa; agrupa peticiones (debounce 350 ms).
  void onViewChanged(double w, double s, double e, double n, double zoom) {
    _lastView = (w: w, s: s, e: e, n: n, z: zoom);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _refetchAll);
  }

  /// Refresco inmediato de las capas visibles (filtros y toggles).
  void _refetch() {
    unawaited(_refetchAll());
  }

  Future<void> _refetchAll() async {
    await Future.wait([_refetchFeatures(), _refetchZones(), _refetchPasses(), _refetchPersonnel()]);
    notifyListeners();
  }

  Future<void> _refetchFeatures() async {
    final v = _lastView;
    if (v == null || !showPersons) return;
    loadingFeatures = true;
    notifyListeners();
    try {
      features = await maps.points(west: v.w, south: v.s, east: v.e, north: v.n, zoom: v.z,
          groups: _groupsParam);
      mapError = null;
    } on ApiException catch (e) {
      features = const [];
      if (!e.isForbidden) mapError = e.message;
    }
    loadingFeatures = false;
    notifyListeners();
  }

  /// Zonas visibles en el bbox actual (recarga manual en cambios de datos).
  Future<void> refreshZones() async {
    if (!showZones) return;
    loadingZones = true;
    notifyListeners();
    try {
      zones = await zonesRepo.list(bbox: _bboxParam);
    } on ApiException catch (e) {
      if (!e.isForbidden) mapError = e.message;
    }
    loadingZones = false;
    notifyListeners();
  }

  Future<void> _refetchZones() async {
    if (!showZones || _lastView == null) return;
    try {
      zones = await zonesRepo.list(bbox: _bboxParam);
    } on ApiException catch (_) {
      // Silencioso: el error de personas ya se muestra.
    }
    notifyListeners();
  }

  /// Marcadores de internos con pase activo en el bbox actual.
  Future<void> _refetchPasses() async {
    final v = _lastView;
    if (v == null || !showPasses) return;
    try {
      final res = await passesRepo.map(west: v.w, south: v.s, east: v.e, north: v.n);
      if (res == null) {
        passesHidden = true;
        passMarkers = const [];
      } else {
        passesHidden = false;
        passMarkers = res.markers;
        passMarkerStyle = res.style;
      }
    } on ApiException catch (e) {
      if (e.isForbidden) {
        passesHidden = true;
        passMarkers = const [];
      }
    }
    notifyListeners();
  }

  /// Personal de la fuerza del bbox actual (capa opcional).
  Future<void> _refetchPersonnel() async {
    final v = _lastView;
    if (v == null || !showPersonnel) return;
    try {
      final j = await personnelRepo.list(bbox: _bboxParam, pageSize: 200);
      personnelMarkers = ((j['items'] as List<dynamic>?) ?? const [])
          .cast<Map<String, dynamic>>().map(Personnel.fromJson).toList();
    } on ApiException catch (_) {
      personnelMarkers = const [];
    }
    notifyListeners();
  }

  Future<void> select(Person p, {bool center = true}) async {
    selected = p;
    nearby = null;
    nearbyError = null;
    notifyListeners();
    final point = p.location?.point;
    if (center && point != null) centerOn(point, 16);
  }

  Future<void> selectById(String id) async {
    try {
      await select(await persons.get(id));
    } on ApiException catch (e) {
      nearbyError = e.message;
      notifyListeners();
    }
  }

  void replaceSelected(Person p) {
    selected = p;
    notifyListeners();
    unawaited(_refetchFeatures());
    unawaited(_refetchPasses());
  }

  void clearSelection() {
    selected = null;
    nearby = null;
    notifyListeners();
  }

  Future<void> searchNearby(int radius, {int page = 1}) async {
    final p = selected;
    if (p == null) return;
    loadingNearby = true;
    nearbyError = null;
    notifyListeners();
    try {
      nearby = await persons.nearby(p.id, radius, groups: _groupsParam, page: page);
      final point = p.location?.point;
      if (point != null) centerOn(point, _zoomForRadius(radius));
    } on ApiException catch (e) {
      nearbyError = e.userMessage;
    }
    loadingNearby = false;
    notifyListeners();
  }

  static double _zoomForRadius(int r) =>
      r <= 100 ? 17.5 : r <= 250 ? 16.5 : r <= 500 ? 15.5 : r <= 1000 ? 14.5 : r <= 2000 ? 13.5 : 12;

  void setProvisional(LatLng? p, {GeocodeResult? source, bool center = false}) {
    provisional = p;
    provisionalSource = source;
    if (center && p != null) centerOn(p, const {'dwelling', 'poi'}.contains(source?.granularity) ? 18 : 16);
    notifyListeners();
  }

  void setPickMode(bool v) {
    pickMode = v;
    notifyListeners();
  }

  // --- Dibujo de zonas ------------------------------------------------------
  void startDrawing(DrawTool t) {
    selectedZone = null;
    drawing.start(t);
    notifyListeners();
  }

  void cancelDrawing() {
    drawing.cancel();
    notifyListeners();
  }

  void undoVertex() {
    drawing.undoVertex();
    notifyListeners();
  }

  /// Toque sobre el mapa: primero dibujo, luego selección de zona/persona.
  Future<void> onMapTap(LatLng p) async {
    if (drawing.isDrawing) {
      final finished = drawing.onMapTap(p);
      notifyListeners();
      if (finished) await onZoneDrawn();
      return;
    }
    if (pickMode) {
      setProvisional(p);
      return;
    }
    await selectZoneAt(p);
  }

  /// Vista previa del dibujo al mover el puntero (web/escritorio).
  void onMapHover(LatLng? p) {
    drawing.onMapHover(p);
    notifyListeners();
  }

  /// El dibujo terminó: deja la geometría lista para el diálogo de zona.
  Future<void> onZoneDrawn() async {
    pendingZoneSpec = drawing.finishSpec();
    if (pendingZoneSpec == null) drawing.cancel();
    notifyListeners();
  }

  /// Selección de zona por punto tocado: pregunta al servidor qué zonas hay.
  Future<void> selectZoneAt(LatLng p) async {
    try {
      final found = await zonesRepo.containing(p);
      if (found.isEmpty) {
        selectedZone = null;
        zonePersons = const [];
        zonePersonnel = const [];
        zonePasses = const [];
        notifyListeners();
        return;
      }
      await selectZone(found.first, center: false);
    } on ApiException catch (e) {
      if (!e.isForbidden) mapError = e.message;
      notifyListeners();
    }
  }

  Future<void> selectZone(Zone z, {bool center = true}) async {
    selectedZone = z;
    zonePersons = const [];
    zonePersonnel = const [];
    zonePasses = const [];
    loadingZoneDetail = true;
    notifyListeners();
    if (center) {
      final c = z.isCircle ? z.center : _centroid(z.vertices);
      if (c != null) centerOn(c, 14);
    }
    try {
      final personsPage = await zonesRepo.persons(z.id);
      zonePersons = ((personsPage['items'] as List<dynamic>?) ?? const [])
          .cast<Map<String, dynamic>>().map(ZonePerson.fromJson).toList();
      final personnelPage = await zonesRepo.personnel(z.id);
      zonePersonnel = ((personnelPage['items'] as List<dynamic>?) ?? const [])
          .cast<Map<String, dynamic>>().map(ZonePersonnelItem.fromJson).toList();
      final passesPage = await zonesRepo.passes(z.id);
      zonePasses = ((passesPage['items'] as List<dynamic>?) ?? const [])
          .cast<Map<String, dynamic>>().map(Pass.fromJson).toList();
    } on ApiException catch (e) {
      if (!e.isForbidden) mapError = e.message;
    }
    loadingZoneDetail = false;
    notifyListeners();
  }

  void clearZoneSelection() {
    selectedZone = null;
    zonePersons = const [];
    zonePersonnel = const [];
    zonePasses = const [];
    notifyListeners();
  }

  /// Recarga una zona tras editarla o asignar personas.
  Future<void> reloadZone(String id) async {
    await refreshZones();
    final z = zones.where((x) => x.id == id).firstOrNull ?? selectedZone;
    if (z != null) await selectZone(z, center: false);
  }

  static LatLng? _centroid(List<LatLng> verts) {
    if (verts.isEmpty) return null;
    var lat = 0.0;
    var lon = 0.0;
    for (final v in verts) {
      lat += v.latitude;
      lon += v.longitude;
    }
    return LatLng(lat / verts.length, lon / verts.length);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_center.close());
    drawing.dispose();
    super.dispose();
  }
}
