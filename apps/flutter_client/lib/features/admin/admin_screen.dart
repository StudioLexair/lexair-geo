import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../auth/user_profile.dart';
import '../../core/config/terminologia.dart';
import 'admin_repository.dart';
import 'sections/audit_section.dart';
import 'sections/catalog_sections.dart';
import 'sections/data_connections_section.dart';
import 'sections/data_exchange_sections.dart';
import 'sections/geocoding_admin_sections.dart';
import 'sections/oracle_section.dart';
import 'sections/personnel_section.dart';
import 'sections/overview_sections.dart';
import 'sections/roles_section.dart';
import 'sections/settings_section.dart';
import 'sections/users_section.dart';

class AdminSectionDef {
  const AdminSectionDef(this.id, this.label, this.icon, this.permission, this.build);
  final String id;
  final String label;
  final IconData icon;
  /// null = visible para cualquier usuario con acceso al área de administración.
  final String? permission;
  final Widget Function(AdminRepository repo) build;
}

/// Las 23 secciones del panel. Cada una se muestra solo si el rol tiene
/// el permiso correspondiente (el servidor lo vuelve a comprobar).
final List<AdminSectionDef> adminSections = [
  AdminSectionDef('dashboard', 'Resumen', Icons.dashboard_outlined, 'system.status', (r) => DashboardSection(repo: r)),
  AdminSectionDef('status', 'Estado del servidor', Icons.dns_outlined, 'system.status', (r) => ServerStatusSection(repo: r)),
  AdminSectionDef('users', 'Usuarios', Icons.badge_outlined, 'users.manage', (r) => UsersSection(repo: r)),
  AdminSectionDef('roles', 'Roles y permisos', Icons.admin_panel_settings_outlined, 'users.manage', (r) => RolesSection(repo: r)),
  AdminSectionDef('groups', 'Grupos', Icons.label_outline, 'persons.read', (r) => GroupsSection(repo: r)),
  AdminSectionDef('import', 'Importar CSV', Icons.upload_file, 'imports.run', (r) => ImportSection(repo: r)),
  AdminSectionDef('imports', 'Historial de importaciones', Icons.history, 'imports.run', (r) => ImportHistorySection(repo: r)),
  AdminSectionDef('export', 'Exportaciones', Icons.download_outlined, 'exports.run', (r) => ExportSection(repo: r)),
  AdminSectionDef('municipalities', 'Municipios', Icons.map_outlined, 'geocoding.manage', (r) => MunicipalitiesSection(repo: r)),
  AdminSectionDef('aliases', 'Alias de calles', Icons.alt_route, 'geocoding.manage', (r) => AliasesSection(repo: r)),
  AdminSectionDef('addresses', 'Direcciones administradas', Icons.signpost_outlined, 'geocoding.manage', (r) => LocalAddressesSection(repo: r)),
  AdminSectionDef('cartography', 'Cartografía', Icons.layers_outlined, 'system.status', (r) => CartographySection(repo: r)),
  AdminSectionDef('proximity', 'Proximidad y mapa', Icons.radar, 'settings.manage',
      (r) => SettingsSection(repo: r, title: 'Proximidad y mapa', prefixes: const ['proximity.', 'map.'])),
  AdminSectionDef('settings', 'Configuración general', Icons.settings_outlined, 'settings.manage',
      (r) => SettingsSection(repo: r, title: 'Configuración general', exclude: const ['proximity.', 'map.'])),
  AdminSectionDef('zonecategories', 'Categorías de zona', Icons.category_outlined, 'zones.write', (r) => ZoneCategoriesSection(repo: r)),
  AdminSectionDef('passtypes', 'Tipos de ${T.paseSingular.toLowerCase()}', Icons.sticky_note_2_outlined, 'passes.write', (r) => PassTypesSection(repo: r)),
  AdminSectionDef('connections', 'Conexiones de datos', Icons.lan_outlined, 'system.status', (r) => DataConnectionsSection(repo: r)),
  AdminSectionDef('opsettings', '${T.pasePlural}, zonas y personal', Icons.tune_outlined, 'settings.manage',
      (r) => SettingsSection(repo: r, title: '${T.pasePlural}, zonas y personal',
          prefixes: const ['passes.', 'zones.', 'personnel.', 'inmate.'])),
  AdminSectionDef('personnel', 'Personal de la fuerza', Icons.shield_outlined, 'personnel.write', (r) => PersonnelSection(repo: r)),
  AdminSectionDef('oracle', 'Oracle 11g', Icons.storage_outlined, 'settings.manage', (r) => OracleSection(repo: r)),
  AdminSectionDef('audit', 'Auditoría', Icons.fact_check_outlined, 'audit.read', (r) => AuditSection(repo: r)),
  AdminSectionDef('backups', 'Copias de seguridad', Icons.backup_outlined, 'system.status', (r) => BackupsSection(repo: r)),
  AdminSectionDef('about', 'Licencias y acerca de', Icons.info_outline, null, (_) => const AboutSection()),
];

List<AdminSectionDef> visibleSections(UserProfile? u) =>
    adminSections.where((s) => s.permission == null || (u?.can(s.permission!) ?? false)).toList();

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  String? _current;

  @override
  Widget build(BuildContext context) {
    final sections = visibleSections(context.watch<AuthController>().user);
    final repo = context.read<AdminRepository>();
    final current = sections.firstWhere((s) => s.id == _current, orElse: () => sections.first);
    return Row(children: [
      Container(
        width: 250,
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: LexairColors.border))),
        child: ListView(children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('ADMINISTRACIÓN', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: LexairColors.muted)),
          ),
          for (final s in sections)
            ListTile(
              key: Key('admin-${s.id}'),
              dense: true,
              selected: s.id == current.id,
              leading: Icon(s.icon, size: 20),
              title: Text(s.label),
              onTap: () => setState(() => _current = s.id),
            ),
        ]),
      ),
      Expanded(child: KeyedSubtree(key: ValueKey(current.id), child: current.build(repo))),
    ]);
  }
}
