import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../../core/net/api_exception.dart';
import '../geocoding/geocoding_repository.dart';
import '../persons/person.dart';
import '../persons/persons_repository.dart';
import 'map_repository.dart';

enum ToolTab { persons, addresses }

/// Estado del espacio de trabajo GIS: estilo de mapa, capa de personas de
/// la vista actual, persona seleccionada, proximidad y marcador provisional.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({required this.maps, required this.persons, required this.geocoding});

  final MapRepository maps;
  final PersonsRepository persons;
  final GeocodingRepository geocoding;

  MapPackageInfo? package;
  String? styleId;
  String? mapError;

  List<MapFeature> features = const [];
  bool loadingFeatures = false;
  String groupFilter = 'all';
  bool showPersons = true;
  Timer? _debounce;
  ({double w, double s, double e, double n, double z})? _lastView;

  ToolTab tab = ToolTab.persons;
  Person? selected;
  NearbyResult? nearby;
  bool loadingNearby = false;
  String? nearbyError;

  /// Marcador provisional (búsqueda de dirección o selección en mapa).
  LatLng? provisional;
  GeocodeResult? provisionalSource;
  bool pickMode = false;

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
  }

  void setStyle(String id) {
    styleId = id;
    notifyListeners();
  }

  void setTab(ToolTab t) {
    tab = t;
    notifyListeners();
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

  /// Llamado al mover el mapa; agrupa peticiones (debounce 350 ms).
  void onViewChanged(double w, double s, double e, double n, double zoom) {
    _lastView = (w: w, s: s, e: e, n: n, z: zoom);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _refetch);
  }

  Future<void> _refetch() async {
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
    unawaited(_refetch());
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

  void onMapTap(LatLng p) {
    if (pickMode) setProvisional(p);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_center.close());
    super.dispose();
  }
}
