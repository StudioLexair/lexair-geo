import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_services.dart';
import 'core/state/connection_monitor.dart';
import 'core/theme/app_theme.dart';
import 'features/admin/admin_repository.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/change_password_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/geocoding/geocoding_repository.dart';
import 'features/map/map_repository.dart';
import 'features/map/workspace_controller.dart';
import 'features/passes/passes_repository.dart';
import 'features/personnel/personnel_repository.dart';
import 'features/persons/persons_repository.dart';
import 'features/zones/zones_repository.dart';
import 'features/shell/app_shell.dart';

/// Raíz de la aplicación: inyecta servicios y decide la pantalla según el
/// estado de la sesión. El estado del espacio de trabajo se crea por sesión
/// y se destruye al cerrarla (no quedan datos en memoria tras el logout).
class LexairApp extends StatelessWidget {
  const LexairApp({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider(
          create: (_) => AuthController(services.api, clientKind: kIsWeb ? 'web' : 'windows'),
        ),
        ChangeNotifierProvider(
          create: (_) => ConnectionMonitor(services.api,
              interval: Duration(seconds: services.config.healthPollSeconds))..start(),
        ),
        Provider(create: (_) => AdminRepository(services.api)),
      ],
      child: MaterialApp(
        title: 'LEXAIR GEO',
        debugShowCheckedModeBanner: false,
        theme: buildLexairTheme(),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final api = context.read<AppServices>().api;
    return switch (auth.status) {
      AuthStatus.signedOut || AuthStatus.signingIn => const LoginScreen(),
      AuthStatus.mustChangePassword => const ChangePasswordScreen(),
      AuthStatus.signedIn => ChangeNotifierProvider(
        key: ValueKey(auth.user?.id),
        create: (_) => WorkspaceController(
          maps: MapRepository(api),
          persons: PersonsRepository(api),
          geocoding: GeocodingRepository(api),
          zones: ZonesRepository(api),
          personnel: PersonnelRepository(api),
          passes: PassesRepository(api),
        ),
        child: const AppShell(),
      ),
    };
  }
}
