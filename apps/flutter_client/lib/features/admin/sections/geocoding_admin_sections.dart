import 'package:flutter/material.dart';

import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 9. Municipios cargados (límites OSM admin_level=6 de Villa Clara).
class MunicipalitiesSection extends StatelessWidget {
  const MunicipalitiesSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Municipios',
    load: repo.municipalities,
    builder: (context, items, _) => items.isEmpty
        ? const Center(child: Text('No hay municipios cargados. Importe el catálogo con scripts/maps.'))
        : ListView(children: [
            for (final m in items)
              ListTile(
                dense: true,
                title: Text('${m['name']}${m['isSynthetic'] == true ? '  (SINTÉTICO)' : ''}'),
                subtitle: Text('${m['province'] ?? ''} · ${m['localities']} localidades · '
                    '${m['osmId'] == null ? 'sin id OSM' : 'OSM r${m['osmId']}'} · ${m['source']}'),
              ),
          ]),
  );
}

/// 10. Alias de calles (nombres populares → nombre oficial).
class AliasesSection extends StatelessWidget {
  const AliasesSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Alias de calles',
    load: repo.aliases,
    actions: (reload) => [
      FilledButton.icon(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Nuevo alias'),
        onPressed: () async {
          final v = await _form(context, 'Nuevo alias', const ['Alias (nombre popular)', 'Nombre oficial de la calle']);
          if (v != null && context.mounted &&
              await runAction(context, () => repo.addAlias({'alias': v[0], 'streetName': v[1]}), 'Alias creado')) {
            reload();
          }
        },
      ),
    ],
    builder: (context, items, reload) => ListView(children: [
      if (items.isEmpty) const ListTile(title: Text('Sin alias')),
      for (final a in items)
        ListTile(
          dense: true,
          title: Text('${a['alias']} → ${a['streetName']}'),
          trailing: IconButton(
            tooltip: 'Eliminar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await runAction(context, () => repo.deleteAlias(a['id'] as int), 'Alias eliminado')) reload();
            },
          ),
        ),
    ]),
  );
}

/// 11. Direcciones administradas localmente (completan el catálogo OSM).
class LocalAddressesSection extends StatelessWidget {
  const LocalAddressesSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Direcciones administradas',
    load: repo.localAddresses,
    actions: (reload) => [
      FilledButton.icon(
        icon: const Icon(Icons.add_location_alt_outlined, size: 18),
        label: const Text('Nueva dirección'),
        onPressed: () async {
          final v = await _form(context, 'Nueva dirección verificada',
              const ['Calle', 'Número (vacío = tramo de calle)', 'Latitud', 'Longitud']);
          if (v == null || !context.mounted) return;
          final lat = double.tryParse(v[2].replaceAll(',', '.'));
          final lon = double.tryParse(v[3].replaceAll(',', '.'));
          if (lat == null || lon == null) return;
          if (await runAction(context, () => repo.addAddress({
            'streetName': v[0], 'houseNumber': v[1].isEmpty ? null : v[1], 'lat': lat, 'lon': lon,
          }), 'Dirección creada')) {
            reload();
          }
        },
      ),
    ],
    builder: (context, items, reload) => ListView(children: [
      const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Solo registre direcciones comprobadas sobre el terreno. Las coordenadas se validan '
            'contra el área permitida.'),
      ),
      if (items.isEmpty) const ListTile(title: Text('Sin direcciones locales')),
      for (final a in items)
        ListTile(
          dense: true,
          title: Text('${a['streetName']}${a['houseNumber'] == null ? '' : ' #${a['houseNumber']}'}'),
          subtitle: Text('${a['granularity']} · ${a['municipality'] ?? 'sin municipio'} · '
              '${(a['lat'] as num).toStringAsFixed(6)}, ${(a['lon'] as num).toStringAsFixed(6)}'),
          trailing: IconButton(
            tooltip: 'Eliminar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await runAction(context, () => repo.deleteAddress(a['id'] as int), 'Dirección eliminada')) {
                reload();
              }
            },
          ),
        ),
    ]),
  );
}

Future<List<String>?> _form(BuildContext context, String title, List<String> labels) async {
  final ctls = [for (final _ in labels) TextEditingController()];
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < labels.length; i++)
            TextField(controller: ctls[i], decoration: InputDecoration(labelText: labels[i])),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Guardar')),
      ],
    ),
  );
  final values = [for (final c in ctls) c.text.trim()];
  for (final c in ctls) {
    c.dispose();
  }
  return ok == true && values.first.isNotEmpty ? values : null;
}
