import 'package:flutter/material.dart';

import '../../../core/util/labels.dart';
import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 1. Resumen: recuentos reales de la base de datos.
class DashboardSection extends StatelessWidget {
  const DashboardSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<Json>(
    title: 'Resumen',
    load: repo.dashboard,
    builder: (context, d, _) {
      Widget card(String label, Object? v, [IconData icon = Icons.analytics_outlined]) => SizedBox(
        width: 210,
        child: Card(
          child: ListTile(
            leading: Icon(icon),
            title: Text('${v ?? 0}', style: Theme.of(context).textTheme.headlineSmall),
            subtitle: Text(label),
          ),
        ),
      );
      final byGroup = (d['by_group'] as Map<String, dynamic>?) ?? const {};
      final byPrecision = (d['by_precision'] as Map<String, dynamic>?) ?? const {};
      return ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          card('Personas activas', d['persons_active'], Icons.people_outline),
          card('Personas totales', d['persons_total'], Icons.groups_outlined),
          for (final e in byGroup.entries) card('Miembros Grupo ${e.key}', e.value, Icons.label_outline),
          card('Ubicaciones', d['locations_total'], Icons.place_outlined),
          card('Usuarios activos', d['users_active'], Icons.badge_outlined),
          card('Municipios', d['municipalities'], Icons.map_outlined),
          card('Direcciones/tramos', d['addresses'], Icons.signpost_outlined),
          card('Puntos de interés', d['pois'], Icons.place),
          card('Importaciones (7 días)', d['imports_7d'], Icons.upload_file),
        ]),
        if ((d['persons_synthetic'] as num? ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('Atención: ${d['persons_synthetic']} registros son SINTÉTICOS (datos de prueba).',
                style: const TextStyle(color: Colors.orange)),
          ),
        const SizedBox(height: 16),
        Text('Ubicaciones por precisión', style: Theme.of(context).textTheme.titleMedium),
        for (final e in byPrecision.entries)
          ListTile(dense: true, leading: Icon(Icons.circle, size: 12, color: Labels.precisionColor(e.key)),
              title: Text(Labels.of(Labels.precision, e.key)), trailing: Text('${e.value}')),
      ]);
    },
  );
}

/// 2. Estado del servidor: API, PostgreSQL/PostGIS y servicio de mosaicos.
class ServerStatusSection extends StatelessWidget {
  const ServerStatusSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<Json>(
    title: 'Estado del servidor',
    load: repo.status,
    builder: (context, s, _) => ListView(padding: const EdgeInsets.all(16), children: [
      KeyValueTable(data: {
        'api': s['api'],
        'database': s['database'],
        'tiles': s['tiles'],
      }, labels: const {
        'api': 'API', 'database': 'Base de datos', 'tiles': 'Servicio de mosaicos',
        'uptimeS': 'Tiempo activo (s)', 'latencyMs': 'Latencia (ms)', 'size_bytes': 'Tamaño (bytes)',
      }),
    ]),
  );
}

/// 12. Cartografía instalada (manifiesto del paquete MBTiles).
class CartographySection extends StatelessWidget {
  const CartographySection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<Json>(
    title: 'Cartografía',
    load: repo.status,
    builder: (context, s, _) {
      final c = (s['cartography'] as Map<String, dynamic>?) ?? const {};
      return ListView(padding: const EdgeInsets.all(16), children: [
        if (c['isSynthetic'] == true)
          const Card(color: Color(0xFFFFF3E0), child: ListTile(
            leading: Icon(Icons.warning_amber),
            title: Text('Paquete SINTÉTICO de pruebas: no es cartografía real de Villa Clara.'),
          )),
        if (c['installed'] != true)
          const Text('No hay paquete cartográfico instalado. Consulte docs/MAP_DATA.md.'),
        KeyValueTable(data: c, labels: const {
          'installed': 'Instalado', 'name': 'Nombre', 'version': 'Versión', 'generatedAt': 'Generado',
          'sourceTimestamp': 'Fecha de los datos OSM', 'isSynthetic': 'Sintético', 'styles': 'Estilos',
          'missingFeatures': 'Capas no disponibles',
        }),
        const SizedBox(height: 16),
        const Text('Los paquetes se generan fuera del servidor de producción (scripts/maps) y se '
            'instalan con scripts/maps/install_map_package.sh.'),
      ]);
    },
  );
}

/// 16. Copias de seguridad: listado real del directorio de backups.
class BackupsSection extends StatelessWidget {
  const BackupsSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<Json>(
    title: 'Copias de seguridad',
    load: repo.status,
    builder: (context, s, _) {
      final b = (s['backups'] as Map<String, dynamic>?) ?? const {};
      final items = itemsOf(b);
      return ListView(padding: const EdgeInsets.all(16), children: [
        Text('Directorio: ${b['dir'] ?? '—'}'),
        const SizedBox(height: 8),
        const Text('Las copias se crean con scripts/backup_lexair_geo.sh (cron diario) y se restauran '
            'con scripts/restore_lexair_geo.sh, que exige confirmación explícita. Por seguridad la '
            'restauración no se puede lanzar desde la aplicación.'),
        const SizedBox(height: 12),
        if (items.isEmpty) const Text('No se encontraron copias.'),
        for (final i in items)
          ListTile(
            dense: true,
            leading: const Icon(Icons.archive_outlined),
            title: Text('${i['file']}'),
            subtitle: Text('${fmtDate(i['modifiedAt'])} · ${((i['sizeBytes'] as num) / 1048576).toStringAsFixed(1)} MB'),
          ),
      ]);
    },
  );
}

/// 5. Grupos A y B con sus miembros activos.
class GroupsSection extends StatelessWidget {
  const GroupsSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Grupos',
    load: repo.groups,
    builder: (context, items, _) => ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Cada persona existe una sola vez; los grupos son pertenencias. Una persona puede '
          'pertenecer a A, a B o a ambos.'),
      for (final g in items)
        ListTile(
          leading: CircleAvatar(backgroundColor: Labels.groupColor([g['code'] as String]),
              child: Text('${g['code']}', style: const TextStyle(color: Colors.white))),
          title: Text('${g['name']}'),
          trailing: Text('${g['activeMembers']} activos'),
        ),
    ]),
  );
}

/// 17. Licencias y atribución (ODbL) y versión.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(20), children: [
    Text('Acerca de LEXAIR GEO', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 12),
    const Text('Studio Lexair. Plataforma GIS interna para Villa Clara, sin servicios en la nube.'),
    const SizedBox(height: 16),
    const Text('Datos cartográficos', style: TextStyle(fontWeight: FontWeight.w600)),
    const Text('© OpenStreetMap contributors. Los datos están disponibles bajo la Open Database '
        'License (ODbL) 1.0. Extracto de Geofabrik (Cuba). Las bases derivadas de OSM que se '
        'distribuyan deben ofrecerse bajo ODbL.'),
    const SizedBox(height: 16),
    OutlinedButton(
      onPressed: () => showLicensePage(context: context, applicationName: 'LEXAIR GEO'),
      child: const Text('Licencias de componentes de software'),
    ),
  ]);
}
