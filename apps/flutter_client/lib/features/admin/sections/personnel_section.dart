import 'package:flutter/material.dart';

import '../admin_repository.dart';
import '../admin_widgets.dart';

/// Sección de personal de la fuerza: alta/edición/baja con grado, unidad,
/// teléfonos y dirección de residencia. La ubicación precisa se fija desde el
/// mapa o desde Oracle; aquí solo se gestiona el registro.
class PersonnelSection extends StatelessWidget {
  const PersonnelSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Personal de la fuerza',
    load: () async => itemsOf(await repo.api.getJson('/personnel', {'pageSize': 500})),
    actions: (reload) => [
      FilledButton.icon(
        key: const Key('personnel-new'),
        icon: const Icon(Icons.shield_outlined, size: 18),
        label: const Text('Nuevo miembro'),
        onPressed: () async {
          if (await _showPersonnelDialog(context, repo)) reload();
        },
      ),
    ],
    builder: (context, items, reload) {
      return Column(children: [
        Expanded(child: items.isEmpty
          ? const Center(child: Text(
              'Sin personal registrado. Añada militares y colaboradores con su '
              'grado, unidad, teléfono y dirección para las consultas de cercanía.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
          : ListView(padding: const EdgeInsets.all(12), children: [
              for (final pe in items)
                Card(child: ListTile(
                  leading: const Icon(Icons.shield, color: Color(0xFF0F6C81)),
                  title: Text('${pe['rank'] != null ? '${pe['rank']} ' : ''}${pe['fullName']}'),
                  subtitle: Text([
                    'Código: ${pe['code'] ?? '—'}',
                    if (pe['unit'] != null) '${pe['unit']}',
                    if (pe['phone'] != null) '☎ ${pe['phone']}',
                    if (pe['phoneAlt'] != null) 'alt. ${pe['phoneAlt']}',
                    if (pe['addressText'] != null) '${pe['addressText']}',
                  ].join('\n'), style: const TextStyle(fontSize: 12)),
                  isThreeLine: true,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Editar',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () async {
                        if (await _showPersonnelDialog(context, repo, existing: pe)) reload();
                      },
                    ),
                    IconButton(
                      tooltip: 'Desactivar/activar',
                      icon: Icon(
                        pe['isActive'] == false ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        size: 18),
                      onPressed: () async {
                        await runAction(context,
                          () => repo.api.patchJson('/personnel/${pe['id']}', {'isActive': pe['isActive'] == false}),
                          'Personal actualizado');
                        reload();
                      },
                    ),
                  ]),
                )),
            ])),
      ]);
    },
  );
}

Future<bool> _showPersonnelDialog(BuildContext context, AdminRepository repo, {Json? existing}) async {
  final code = TextEditingController(text: '${existing?['code'] ?? ''}');
  final fullName = TextEditingController(text: '${existing?['fullName'] ?? ''}');
  final rank = TextEditingController(text: '${existing?['rank'] ?? ''}');
  final unit = TextEditingController(text: '${existing?['unit'] ?? ''}');
  final phone = TextEditingController(text: '${existing?['phone'] ?? ''}');
  final phoneAlt = TextEditingController(text: '${existing?['phoneAlt'] ?? ''}');
  final address = TextEditingController(text: '${existing?['addressText'] ?? ''}');
  final roleNote = TextEditingController(text: '${existing?['roleNote'] ?? ''}');
  String? error;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(existing == null ? 'Nuevo miembro del personal' : 'Editar personal'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (existing == null)
              TextField(controller: code, decoration: const InputDecoration(
                labelText: 'Código (opcional)', helperText: 'p. ej. PM-023; se genera uno si se deja vacío')),
            TextField(controller: fullName, decoration: const InputDecoration(labelText: 'Nombre completo *')),
            TextField(controller: rank, decoration: const InputDecoration(labelText: 'Grado/rango')),
            TextField(controller: unit, decoration: const InputDecoration(labelText: 'Unidad')),
            TextField(controller: phone, decoration: const InputDecoration(labelText: 'Teléfono')),
            TextField(controller: phoneAlt, decoration: const InputDecoration(labelText: 'Teléfono alternativo')),
            TextField(controller: address, maxLines: 2,
                decoration: const InputDecoration(labelText: 'Dirección de residencia',
                    helperText: 'Se geolocaliza y sirve para las consultas de cercanía')),
            TextField(controller: roleNote, decoration: const InputDecoration(labelText: 'Función (opcional)')),
            if (error != null)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
          ])),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(ctx);
              final navigator = Navigator.of(ctx);
              try {
                final body = <String, dynamic>{
                  if (code.text.trim().isNotEmpty) 'code': code.text.trim().toUpperCase(),
                  'fullName': fullName.text.trim(),
                  'rank': rank.text.trim().isEmpty ? null : rank.text.trim(),
                  'unit': unit.text.trim().isEmpty ? null : unit.text.trim(),
                  'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
                  'phoneAlt': phoneAlt.text.trim().isEmpty ? null : phoneAlt.text.trim(),
                  'addressText': address.text.trim().isEmpty ? null : address.text.trim(),
                  'roleNote': roleNote.text.trim().isEmpty ? null : roleNote.text.trim(),
                };
                if (existing == null) {
                  await repo.api.postJson('/personnel', body);
                } else {
                  await repo.api.patchJson('/personnel/${existing['id']}', body);
                }
                messenger.showSnackBar(const SnackBar(content: Text('Personal guardado')));
                navigator.pop(true);
              } catch (e) {
                setState(() => error = '$e');
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    ),
  );
  return result == true;
}
