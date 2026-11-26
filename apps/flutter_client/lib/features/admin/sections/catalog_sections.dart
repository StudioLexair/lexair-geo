import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../admin_repository.dart';
import '../../../core/config/terminologia.dart';
import '../admin_widgets.dart';

/// Diálogo genérico de alta/edición para catálogos pequeños.
Future<bool> showCatalogDialog(
  BuildContext context, {
  required String title,
  required List<Widget> fields,
  required Future<void> Function() onSave,
}) async {
  String? error;
  var saving = false;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [...fields, if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: LexairColors.danger)))])),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: saving ? null : () async {
              setState(() { saving = true; error = null; });
              final navigator = Navigator.of(ctx);
              try {
                await onSave();
                navigator.pop(true);
              } catch (e) {
                setState(() { saving = false; error = '$e'; });
              }
            },
            child: Text(saving ? 'Guardando…' : 'Guardar'),
          ),
        ],
      ),
    ),
  );
  return result == true;
}

/// Categorías de zona: nombre, color y descripción. Se usan al dibujar áreas
/// en el mapa y al filtrar; todo configurable desde aquí.
class ZoneCategoriesSection extends StatelessWidget {
  const ZoneCategoriesSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Categorías de zona',
    load: repo.zoneCategories,
    actions: (reload) => [
      FilledButton.icon(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Nueva categoría'),
        onPressed: () async {
          final name = TextEditingController();
          final desc = TextEditingController();
          String color = '#0F6C81';
          final ok = await showCatalogDialog(
            context,
            title: 'Nueva categoría de zona',
            fields: [
              TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Nombre *')),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Descripción')),
              StatefulBuilder(builder: (ctx, setState) => Row(children: [
                const Text('Color:'),
                const SizedBox(width: 8),
                for (final hex in const ['#0F6C81', '#1565C0', '#C62828', '#2E7D32', '#EF8F00', '#6A1B9A', '#37474F'])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      onTap: () => setState(() => color = hex),
                      child: Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(
                          color: Color(int.parse('FF${hex.substring(1)}', radix: 16)),
                          shape: BoxShape.circle,
                          border: Border.all(color: color == hex ? Colors.black : Colors.white, width: color == hex ? 2.5 : 1),
                        ),
                      ),
                    ),
                  ),
              ])),
            ],
            onSave: () async {
              if (name.text.trim().isEmpty) throw 'El nombre es obligatorio';
              await repo.createZoneCategory({
                'name': name.text.trim(),
                'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
                'colorHex': color,
              });
            },
          );
          if (ok) reload();
        },
      ),
    ],
    builder: (context, items, reload) => ListView(padding: const EdgeInsets.all(12), children: [
      if (items.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Sin categorías. Cree la primera.'))),
      for (final c in items)
        ListTile(
          leading: Container(width: 18, height: 18, decoration: BoxDecoration(
            color: Color(int.parse('FF${('${c['colorHex'] ?? '#0F6C81'}').substring(1)}', radix: 16)),
            shape: BoxShape.circle)),
          title: Text('${c['name']}'),
          subtitle: Text('${c['description'] ?? ''}\nCódigo: ${c['code']}', style: const TextStyle(fontSize: 12)),
          isThreeLine: true,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () async {
                final name = TextEditingController(text: '${c['name']}');
                final desc = TextEditingController(text: '${c['description'] ?? ''}');
                final color = '${c['colorHex'] ?? '#0F6C81'}';
                final ok = await showCatalogDialog(
                  context,
                  title: 'Editar categoría',
                  fields: [
                    TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre *')),
                    TextField(controller: desc, decoration: const InputDecoration(labelText: 'Descripción')),
                    Text('Color actual: $color', style: const TextStyle(fontSize: 12)),
                  ],
                  onSave: () => repo.updateZoneCategory(c['id'] as int, {
                    'name': name.text.trim(),
                    'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
                    'colorHex': color,
                  }),
                );
                if (ok) reload();
              },
            ),
          ]),
        ),
      const SizedBox(height: 12),
      Text('Las categorías y sus colores aparecen al asignar un área dibujada en el mapa.',
          style: TextStyle(fontSize: 12, color: Colors.grey[700])),
    ]),
  );
}

/// Tipos de pase: código, nombre, duración por defecto y si se puede revalidar.
/// Los pases creados desde la ficha del interno usan este catálogo.
class PassTypesSection extends StatelessWidget {
  const PassTypesSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Tipos de pase',
    load: repo.passTypes,
    actions: (reload) => [
      FilledButton.icon(
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Nuevo tipo'),
        onPressed: () async {
          final code = TextEditingController();
          final name = TextEditingController();
          final days = TextEditingController(text: '7');
          var revalidatable = false;
          final ok = await showCatalogDialog(
            context,
            title: 'Nuevo tipo de pase',
            fields: [
              TextField(controller: code, autofocus: true,
                  decoration: const InputDecoration(labelText: 'Código *', helperText: 'minúsculas_con_guiones, p. ej. pase_medico')),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre *')),
              TextField(controller: days, decoration: const InputDecoration(labelText: 'Días por defecto')),
              StatefulBuilder(builder: (ctx, setState) => CheckboxListTile(
                value: revalidatable,
                title: const Text('Permitir revalidación'),
                onChanged: (v) => setState(() => revalidatable = v == true),
              )),
            ],
            onSave: () async {
              if (code.text.trim().isEmpty || name.text.trim().isEmpty) {
                throw 'Código y nombre son obligatorios';
              }
              await repo.createPassType({
                'code': code.text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_'),
                'name': name.text.trim(),
                'defaultDays': int.tryParse(days.text.trim()) ?? 7,
                'revalidatable': revalidatable,
              });
            },
          );
          if (ok) reload();
        },
      ),
    ],
    builder: (context, items, reload) => ListView(padding: const EdgeInsets.all(12), children: [
      if (items.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Sin tipos de pase.'))),
      for (final t in items)
        ListTile(
          leading: const Icon(Icons.sticky_note_2_outlined),
          title: Text('${t['name']}'),
          subtitle: Text('Código: ${t['code']} · duración por defecto: ${t['defaultDays']} día(s)'
              '${t['revalidatable'] == true ? ' · revalidable' : ''}', style: const TextStyle(fontSize: 12)),
          trailing: IconButton(
            tooltip: 'Editar',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () async {
              final name = TextEditingController(text: '${t['name']}');
              final days = TextEditingController(text: '${t['defaultDays'] ?? 7}');
              var revalidatable = t['revalidatable'] == true;
              final ok = await showCatalogDialog(
                context,
                title: 'Editar tipo de pase',
                fields: [
                  Text('Código: ${t['code']}', style: const TextStyle(fontSize: 12)),
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre *')),
                  TextField(controller: days, decoration: const InputDecoration(labelText: 'Días por defecto')),
                  StatefulBuilder(builder: (ctx, setState) => CheckboxListTile(
                    value: revalidatable,
                    title: const Text('Permitir revalidación'),
                    onChanged: (v) => setState(() => revalidatable = v == true),
                  )),
                ],
                onSave: () => repo.updatePassType(t['id'] as int, {
                  'name': name.text.trim(),
                  'defaultDays': int.tryParse(days.text.trim()) ?? 7,
                  'revalidatable': revalidatable,
                }),
              );
              if (ok) reload();
            },
          ),
        ),
      const SizedBox(height: 12),
      Text('El marcador de ${T.sujetoPlural.toLowerCase()} con ${T.paseSingular.toLowerCase()} activo se configura en '
          '«${T.pasePlural}, zonas y personal» (icono, color y tamaño).',
          style: TextStyle(fontSize: 12, color: Colors.grey[700])),
    ]),
  );
}
