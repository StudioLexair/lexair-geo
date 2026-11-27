import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lexair_geo/core/app_services.dart';
import 'package:lexair_geo/core/config/app_config.dart';
import 'package:lexair_geo/core/config/config_store.dart';
import 'package:lexair_geo/core/net/api_client.dart';
import 'package:lexair_geo/core/state/connection_monitor.dart';
import 'package:lexair_geo/features/auth/auth_controller.dart';
import 'package:lexair_geo/features/auth/change_password_screen.dart';
import 'package:lexair_geo/features/auth/login_screen.dart';

import 'fakes.dart';

Widget harness(ApiClient api, AuthController auth, {Future<void> Function()? onConfigChanged}) {
  final services = AppServices(config: const AppConfig(serverUrl: 'https://geo.test'), api: api,
      configStore: ConfigStore(), onConfigChanged: onConfigChanged);
  return MultiProvider(
    providers: [
      Provider.value(value: services),
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider(create: (_) => ConnectionMonitor(api)),
    ],
    child: MaterialApp(
      home: Consumer<AuthController>(
        builder: (_, a, _) => a.status == AuthStatus.mustChangePassword
            ? const ChangePasswordScreen()
            : a.status == AuthStatus.signedIn
            ? const Scaffold(body: Text('DENTRO'))
            : const LoginScreen(),
      ),
    ),
  );
}

void main() {
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('guardar servidor aplica el cambio sin pedir reinicio', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    var aplicado = false;
    final api = FakeApi().client();
    await tester.pumpWidget(harness(api, AuthController(api, clientKind: 'windows'),
        onConfigChanged: () async { aplicado = true; }));
    await tester.tap(find.text('Servidor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('server-url-field')), 'http://192.168.1.22:3000');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(aplicado, isTrue);
    expect((await SharedPreferences.getInstance()).getString('lexair.serverUrlOverride'),
        'http://192.168.1.22:3000');
    expect(find.textContaining('Reinicie la aplicación'), findsNothing);
  });

  testWidgets('credenciales incorrectas muestran el mensaje del servidor', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeApi()
      ..on('POST /auth/login', {'error': 'UNAUTHORIZED', 'message': 'Usuario o contraseña incorrectos'}, status: 401);
    final api = fake.client();
    final auth = AuthController(api, clientKind: 'web');
    await tester.pumpWidget(harness(api, auth));
    await tester.enterText(find.byKey(const Key('login-username')), 'operador1');
    await tester.enterText(find.byKey(const Key('login-password')), 'mala');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Usuario o contraseña incorrectos'), findsOneWidget);
    expect(fake.calls, contains('POST /auth/login'));
  });

  testWidgets('contraseña temporal obliga a cambiarla antes de entrar', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeApi()
      ..on('POST /auth/login', {'token': 't0k3n'})
      ..on('GET /auth/me', meJson(mustChange: true));
    final api = fake.client();
    final auth = AuthController(api, clientKind: 'web');
    await tester.pumpWidget(harness(api, auth));
    await tester.enterText(find.byKey(const Key('login-username')), 'operador1');
    await tester.enterText(find.byKey(const Key('login-password')), 'Temporal-1234');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pumpAndSettle();
    expect(find.byType(ChangePasswordScreen), findsOneWidget);
    expect(auth.user!.displayName, 'Operador Ficticio');
  });

  testWidgets('el servidor inalcanzable se indica como desconectado', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = FakeApi(); // sin ruta /health => 404 => «desconectado»
    final api = fake.client();
    final auth = AuthController(api, clientKind: 'web');
    await tester.pumpWidget(harness(api, auth));
    final monitor = Provider.of<ConnectionMonitor>(tester.element(find.byType(LoginScreen)), listen: false);
    await monitor.check();
    await tester.pump();
    expect(find.text('Servidor desconectado'), findsOneWidget);
  });
  testWidgets('la pantalla de acceso no desborda en ventanas pequeñas (480x360)', (tester) async {
    tester.view.physicalSize = const Size(480, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeApi().client();
    await tester.pumpWidget(harness(api, AuthController(api, clientKind: 'web')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
  });
}
