import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../core/state/connection_monitor.dart';
import '../../core/theme/app_theme.dart';
import '../admin/admin_screen.dart';
import '../auth/auth_controller.dart';
import '../map/workspace_controller.dart';
import 'connection_badge.dart';
import 'workspace_screen.dart';

/// Estructura principal tras iniciar sesión: barra lateral, cabecera con
/// estado de conexión y usuario, y el área de contenido.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    unawaited(context.read<WorkspaceController>().loadStyles());
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final monitor = context.watch<ConnectionMonitor>();
    final user = auth.user!;
    final showAdmin = user.isAdminArea;
    final index = showAdmin ? _index : 0;
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          backgroundColor: LexairColors.sidebar,
          selectedIndex: index,
          onDestinationSelected: (i) => setState(() => _index = i),
          labelType: NavigationRailLabelType.all,
          unselectedIconTheme: const IconThemeData(color: Colors.white70),
          selectedIconTheme: const IconThemeData(color: Colors.white),
          unselectedLabelTextStyle: const TextStyle(color: Colors.white70, fontSize: 12),
          selectedLabelTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
          indicatorColor: LexairColors.sidebarActive,
          leading: const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Icon(Icons.travel_explore, color: LexairColors.accent, size: 32),
          ),
          destinations: [
            const NavigationRailDestination(icon: Icon(Icons.map_outlined), label: Text('Mapa')),
            if (showAdmin)
              const NavigationRailDestination(icon: Icon(Icons.admin_panel_settings_outlined), label: Text('Admin')),
          ],
        ),
        Expanded(
          child: Column(children: [
            Container(
              height: 48,
              color: LexairColors.sidebar,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Text('LEXAIR GEO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
                const SizedBox(width: 16),
                if (monitor.mapIsSynthetic)
                  const Tooltip(
                    message: 'El servidor usa un paquete cartográfico sintético de pruebas',
                    child: Chip(label: Text('MAPA SINTÉTICO'), visualDensity: VisualDensity.compact,
                        backgroundColor: Color(0xFFFFE0B2)),
                  ),
                const Spacer(),
                const ConnectionBadge(),
                const SizedBox(width: 16),
                PopupMenuButton<String>(
                  key: const Key('user-menu'),
                  tooltip: 'Cuenta',
                  onSelected: (v) {
                    if (v == 'logout') unawaited(auth.logout());
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(enabled: false, child: Text('${user.displayName}\n${user.roleLabel}')),
                    const PopupMenuItem(enabled: false, child: Text('Versión ${AppConfig.appVersion}')),
                    const PopupMenuDivider(),
                    const PopupMenuItem(value: 'logout', child: Text('Cerrar sesión')),
                  ],
                  child: Row(children: [
                    const Icon(Icons.account_circle, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(user.displayName, style: const TextStyle(color: Colors.white)),
                  ]),
                ),
              ]),
            ),
            Expanded(child: IndexedStack(index: index, children: [
              const WorkspaceScreen(),
              if (showAdmin) const AdminScreen(),
            ])),
          ]),
        ),
      ]),
    );
  }
}
