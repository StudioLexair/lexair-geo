import 'dart:convert';

import 'package:flutter/material.dart';

import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 13/14. Configuración del sistema. El servidor valida cada clave; aquí
/// solo se edita el valor JSON. [prefixes] filtra las claves mostradas.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.repo, required this.title, this.prefixes, this.exclude});
  final AdminRepository repo;
  final String title;
  final List<String>? prefixes;
  final List<String>? exclude;

  bool _visible(String key) =>
      (prefixes == null || prefixes!.any(key.startsWith)) && !(exclude ?? const []).any(key.startsWith);

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: title,
    load: repo.settings,
    builder: (context, items, reload) => ListView(padding: const EdgeInsets.all(12), children: [
      for (final s in items.where((s) => _visible(s['key'] as String)))
        Card(
          child: ListTile(
            title: Text('${s['key']}'),
            subtitle: Text('${s['description'] ?? ''}\nValor: ${jsonEncode(s['value'])}\n'
                'Actualizado: ${fmtDate(s['updatedAt'])}'),
            isThreeLine: true,
            trailing: IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                if (await _edit(context, s)) reload();
              },
            ),
          ),
        ),
    ]),
  );

  Future<bool> _edit(BuildContext context, Json s) async {
    final ctl = TextEditingController(text: const JsonEncoder.withIndent('  ').convert(s['value']));
    String? error;
    final value = await showDialog<Object?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('${s['key']}'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: ctl,
              maxLines: 8,
              style: const TextStyle(fontFamily: 'NotoSansMono'),
              decoration: InputDecoration(labelText: 'Valor (JSON)', errorText: error),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.of(ctx).pop(<Object?>[jsonDecode(ctl.text)]);
                } on FormatException {
                  setState(() => error = 'JSON no válido');
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (value is! List || !context.mounted) return false;
    return runAction(context, () => repo.putSetting(s['key'] as String, value.first), 'Configuración guardada');
  }
}
