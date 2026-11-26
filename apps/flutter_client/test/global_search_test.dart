import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:lexair_geo/core/app_services.dart';
import 'package:lexair_geo/core/config/app_config.dart';
import 'package:lexair_geo/core/config/config_store.dart';
import 'package:lexair_geo/core/net/api_client.dart';
import 'package:lexair_geo/features/geocoding/geocoding_repository.dart';
import 'package:lexair_geo/features/map/map_repository.dart';
import 'package:lexair_geo/features/map/workspace_controller.dart';
import 'package:lexair_geo/features/personnel/personnel_repository.dart';
import 'package:lexair_geo/features/passes/passes_repository.dart';
import 'package:lexair_geo/features/persons/persons_repository.dart';
import 'package:lexair_geo/features/search/global_search_overlay.dart';
import 'package:lexair_geo/features/search/search_repository.dart';
import 'package:lexair_geo/features/zones/zones_repository.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

Map<String, dynamic> personaJson(String id, String nombre, String apellidos, String codigo,
    {String? telefono, bool grupoB = false}) => {
  'id': id, 'code': codigo, 'givenNames': nombre, 'familyNames': apellidos,
  'phone': telefono, 'notes': null, 'cdr': null, 'defenseZone': null,
  'isActive': true, 'isSynthetic': true, 'visibility': 'normal',
  'consentStatus': 'not_required', 'dataSource': 'pruebas',
  'groups': grupoB ? ['B'] : ['A'],
  'location': null,
};

Map<String, dynamic> busquedaJson(Map<String, Object?> overrides) => {
  'q': 'marta abreu', 'detectado': 'texto', 'sugerencia': null,
  'persons': [personaJson('id-1', 'Marta', 'Abreu', 'VC-100002')],
  'addresses': [
    {'label': 'Calle Sintética del Sol 45', 'municipality': 'Municipio Buscador',
     'lat': 22.40, 'lon': -79.95, 'fuente': 'vivienda'},
    {'label': 'Calle Sintética del Sol', 'municipality': 'Municipio Buscador',
     'lat': 22.4001, 'lon': -79.9501, 'fuente': 'antiguo'},
  ],
  'zones': [
    {'id': 'z-1', 'name': 'Zona Sintética Buscador', 'lat': 22.41, 'lon': -79.96},
  ],
  'tookMs': 12,
  ...overrides,
};

WorkspaceController controllerWith(ApiClient api) => WorkspaceController(
  maps: MapRepository(api), persons: PersonsRepository(api), geocoding: GeocodingRepository(api),
  zones: ZonesRepository(api), personnel: PersonnelRepository(api), passes: PassesRepository(api));

Future<void> bombearOverlay(WidgetTester tester, AppServices services, WorkspaceController ws) async {
  await tester.pumpWidget(MultiProvider(providers: [
    Provider<AppServices>.value(value: services),
    ChangeNotifierProvider<WorkspaceController>.value(value: ws),
  ], child: const MaterialApp(home: Scaffold(body: Center(child: GlobalSearchOverlay())))));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uri() manda el filtro repetido como el servidor lo espera', () {
    final api = ApiClient(baseUrl: 'https://geo.test/api/v1', client: MockClient((_) async => http.Response('{}', 200)));
    final u = api.uri('/search', {'q': 'marta abreu', 'limit': 10, 'filtro': ['con_permiso', 'con_telefono']});
    expect(u.queryParametersAll['filtro'], ['con_permiso', 'con_telefono']);
    expect(u.queryParameters['q'], 'marta abreu');
    final sin = api.uri('/search', {'q': 'x', 'filtro': const <String>[]});
    expect(sin.queryParameters.containsKey('filtro'), isFalse);
  });

  test('SearchRepository parsea los tres grupos y el tipo detectado', () async {
    final fake = FakeApi()..on('GET /search', busquedaJson({'detectado': 'telefono'}));
    final r = await SearchRepository(fake.client()).run('marta abreu');
    expect(fake.calls, contains('GET /search'));
    expect(r.persons.single.fullName, 'Marta Abreu');
    expect(r.addresses.first.fuenteEtiqueta, 'número');
    expect(r.addresses.last.fuenteEtiqueta, 'nombre antiguo');
    expect(r.zones.single.name, 'Zona Sintética Buscador');
    expect(r.detectado, 'telefono');
    expect(r.vacia, isFalse);
  });

  test('GlobalSearch vacío conserva la sugerencia del servidor', () {
    final r = GlobalSearch.fromJson(busquedaJson({'persons': [], 'addresses': [], 'zones': [],
        'sugerencia': 'Marta Abreu'}));
    expect(r.vacia, isTrue);
    expect(r.sugerencia, 'Marta Abreu');
  });

  testWidgets('busca en vivo, agrupa por tipo y abre la persona con Enter', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeApi()..on('GET /search', busquedaJson({}));
    final api = fake.client();
    final services = AppServices(
      config: const AppConfig(serverUrl: 'https://geo.test'), api: api, configStore: ConfigStore());
    final ws = controllerWith(api);

    await bombearOverlay(tester, services, ws);

    await tester.enterText(find.byType(TextField), 'marta abreu');
    await tester.pump(const Duration(milliseconds: 300)); // pasa el antirrebote
    await tester.pumpAndSettle();

    expect(find.text('PERSONAS'), findsOneWidget);
    expect(find.text('DIRECCIONES'), findsOneWidget);
    expect(find.text('ZONAS'), findsOneWidget);
    expect(find.text('Marta Abreu'), findsOneWidget);
    expect(find.text('Calle Sintética del Sol 45'), findsOneWidget);
    expect(find.text('Zona Sintética Buscador'), findsOneWidget);

    // Teclado: baja a la primera dirección, vuelve a la persona y abre.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(ws.selected?.fullName, 'Marta Abreu');
    expect(find.byType(GlobalSearchOverlay), findsNothing);
  });

  testWidgets('con tipeo erróneo sugiere «¿quisiste decir…?» y lo usa', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeApi()
      ..on('GET /search', busquedaJson({'q': 'marta abrei', 'sugerencia': 'Marta Abreu',
          'persons': [], 'addresses': [], 'zones': []}));
    final api = fake.client();
    final services = AppServices(
      config: const AppConfig(serverUrl: 'https://geo.test'), api: api, configStore: ConfigStore());
    final ws = controllerWith(api);

    await bombearOverlay(tester, services, ws);
    await tester.enterText(find.byType(TextField), 'marta abrei');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.textContaining('¿Quisiste decir'), findsOneWidget);
    await tester.tap(find.textContaining('¿Quisiste decir'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Marta Abreu'), findsOneWidget); // buscó con la escritura corregida
  });

  testWidgets('la dirección vuela al mapa y queda en el historial', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = FakeApi()..on('GET /search', busquedaJson({'persons': [], 'zones': []}));
    final api = fake.client();
    final services = AppServices(
      config: const AppConfig(serverUrl: 'https://geo.test'), api: api, configStore: ConfigStore());
    final ws = controllerWith(api);

    await bombearOverlay(tester, services, ws);
    await tester.enterText(find.byType(TextField), 'calle del sol 45');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // Escuchar ANTES de activar: el stream es broadcast (sin oyente, se pierde).
    final vuelo = ws.centerRequests.first;
    await tester.tap(find.text('Calle Sintética del Sol 45'));
    final (punto, zoom) = await vuelo;
    await tester.pumpAndSettle();

    expect(find.byType(GlobalSearchOverlay), findsNothing);
    expect(punto, const LatLng(22.40, -79.95));
    expect(zoom, 17);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('lexair.busq.historial'), contains('calle del sol 45'));
  });
}
