import 'dart:convert';

import 'package:flutter/material.dart';

import '../admin_repository.dart';
import '../admin_widgets.dart';

/// Sección 18: conectores Oracle 11g. Configuración de conexión (host, puerto,
/// servicio o SID), mappings tabla→objetivo y ejecución (real o simulación).
/// La contraseña se envía una sola vez y el servidor la guarda cifrada.
class OracleSection extends StatelessWidget {
  const OracleSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Oracle 11g (extracción de datos)',
    load: repo.oracleConnectors,
    actions: (reload) => [
      FilledButton.icon(
        key: const Key('oracle-new'),
        icon: const Icon(Icons.add_link, size: 18),
        label: const Text('Nuevo conector'),
        onPressed: () async {
          if (await _showConnectorDialog(context, repo)) reload();
        },
      ),
    ],
    builder: (context, items, reload) => Column(children: [
      Expanded(child: items.isEmpty
        ? const Center(child: Text(
            'No hay conectores. Cree uno, configure sus mappings (tabla Oracle → '
            'personas, internos, personal o pases) y ej «Probar conexión».',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey)))
        : ListView(padding: const EdgeInsets.all(12), children: [
            for (final c in items)
              Card(child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${c['name']} · ${c['username']}@${c['host']}:${c['port']}/${c['serviceName']}')),
                    if (c['enabled'] != true) const Chip(label: Text('Deshabilitado'), visualDensity: VisualDensity.compact),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'Modo: ${c['thickMode'] == true ? 'THICK (Oracle 11g, Instant Client)' : 'thin (12.1+)'} · '
                    'Última corrida: ${fmtDate(c['lastRunAt'])} ${c['lastStatus'] != null ? '(${c['lastStatus']})' : ''} · '
                    'Mappings: ${(c['mappings'] as List<dynamic>?)?.length ?? 0}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.cable, size: 16),
                      label: const Text('Probar conexión'),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final r = await repo.testOracleConnector('${c['id']}');
                          messenger.showSnackBar(SnackBar(content: Text(
                            'Conexión OK (${r['elapsedMs']} ms)${r['banner'] != null ? '\n${r['banner']}' : ''}')));
                        } catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text('Falló: $e')));
                        }
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.sim_card_download_outlined, size: 16),
                      label: const Text('Simular'),
                      onPressed: () async {
                        await _run(context, repo, '${c['id']}', dryRun: true, reload: reload);
                      },
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.sync, size: 16),
                      label: const Text('Sincronizar ahora'),
                      onPressed: () async {
                        await _run(context, repo, '${c['id']}', dryRun: false, reload: reload);
                      },
                    ),
                    IconButton(
                      tooltip: 'Editar',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () async {
                        if (await _showConnectorDialog(context, repo, existing: c)) reload();
                      },
                    ),
                    IconButton(
                      tooltip: 'Historial de corridas',
                      icon: const Icon(Icons.history, size: 18),
                      onPressed: () => _showRuns(context, repo, '${c['id']}'),
                    ),
                    IconButton(
                      tooltip: 'Eliminar',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Eliminar conector'),
                            content: Text('¿Eliminar «${c['name']}»? Se borrará también su historial.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
                              FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Eliminar')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          try {
                            await repo.deleteOracleConnector('${c['id']}');
                            messenger.showSnackBar(const SnackBar(content: Text('Conector eliminado')));
                            reload();
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
                          }
                        }
                      },
                    ),
                  ]),
                ]),
              )),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Oracle 11g requiere modo THICK con Oracle Instant Client instalado en el servidor '
                '(variable ORACLE_INSTANT_CLIENT). La contraseña se guarda cifrada con la clave del '
                'servidor y nunca se vuelve a mostrar.',
                style: TextStyle(fontSize: 12, color: Colors.grey[700])),
            ),
          ])),
    ]),
  );

  Future<void> _run(BuildContext context, AdminRepository repo, String id,
      {required bool dryRun, required VoidCallback reload}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await repo.runOracleConnector(id, dryRun: dryRun);
      messenger.showSnackBar(SnackBar(content: Text(
        '${dryRun ? 'Simulación' : 'Sincronización'} (${r['status']}): '
        'personas ${r['persons']}, internos ${r['inmates']}, '
        'personal ${r['personnel']}, pases ${r['passes']}'
        '${r['error'] != null ? '\n${r['error']}' : ''}')));
      reload();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _showRuns(BuildContext context, AdminRepository repo, String id) async {
    final navigator = Navigator.of(context);
    final runs = await repo.oracleRuns(connectorId: id);
    if (!navigator.context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Historial de sincronizaciones'),
        content: SizedBox(
          width: 560,
          height: 380,
          child: runs.isEmpty
              ? const Center(child: Text('Sin corridas registradas.'))
              : ListView(children: [
                  for (final r in runs)
                    ListTile(
                      dense: true,
                      leading: Icon(_statusIcon('${r['status']}')),
                      title: Text('${fmtDate(r['startedAt'])} · ${r['status']}${r['dryRun'] == true ? ' (simulación)' : ''}'),
                      subtitle: Text(
                        'personas ${r['persons'] ?? 0}, internos ${r['inmates'] ?? 0}, '
                        'personal ${r['personnel'] ?? 0}, pases ${r['passes'] ?? 0} · '
                        'leídas ${r['rowsRead'] ?? 0}, saltadas ${r['rowsSkipped'] ?? 0}'
                        '${r['errorText'] != null ? '\n${r['errorText']}' : ''}'),
                    ),
                ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cerrar'))],
      ),
    );
  }

  static IconData _statusIcon(String status) => switch (status) {
    'ok' => Icons.check_circle,
    'partial' => Icons.warning_amber,
    'error' => Icons.error_outline,
    _ => Icons.hourglass_empty,
  };
}

/// Alta/edición de un conector, incluida la edición JSON de los mappings.
Future<bool> _showConnectorDialog(BuildContext context, AdminRepository repo, {Json? existing}) async {
  final name = TextEditingController(text: existing?['name'] as String? ?? '');
  final host = TextEditingController(text: existing?['host'] as String? ?? '');
  final port = TextEditingController(text: '${existing?['port'] ?? 1521}');
  final serviceName = TextEditingController(text: existing?['serviceName'] as String? ?? '');
  final username = TextEditingController(text: existing?['username'] as String? ?? '');
  final password = TextEditingController();
  var serviceKind = (existing?['serviceKind'] as String?) ?? 'service';
  var thickMode = existing?['thickMode'] == true;
  var enabled = existing?['enabled'] != false;
  final mappingsCtl = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(existing?['mappings'] ?? _sampleMappings()));
  String? error;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(existing == null ? 'Nuevo conector Oracle' : 'Editar conector'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre *')),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: host, decoration: const InputDecoration(labelText: 'Host/IP *'))),
              const SizedBox(width: 8),
              SizedBox(width: 90, child: TextField(controller: port, decoration: const InputDecoration(labelText: 'Puerto'))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              SizedBox(width: 120, child: DropdownButtonFormField<String>(
                initialValue: serviceKind,
                decoration: const InputDecoration(labelText: 'Servicio por'),
                items: const [
                  DropdownMenuItem(value: 'service', child: Text('SERVICE_NAME')),
                  DropdownMenuItem(value: 'sid', child: Text('SID')),
                ],
                onChanged: (v) => setState(() => serviceKind = v ?? 'service'),
              )),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: serviceName, decoration: const InputDecoration(labelText: 'SERVICE_NAME o SID *'))),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: username, decoration: const InputDecoration(labelText: 'Usuario Oracle *'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                controller: password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: existing == null ? 'Contraseña *' : 'Contraseña (dejar vacío para conservar)'),
              )),
            ]),
            CheckboxListTile(
              dense: true,
              value: thickMode,
              title: const Text('Modo THICK (obligatorio para Oracle 11g, con Instant Client)'),
              onChanged: (v) => setState(() => thickMode = v == true),
            ),
            CheckboxListTile(
              dense: true,
              value: enabled,
              title: const Text('Habilitado'),
              onChanged: (v) => setState(() => enabled = v == true),
            ),
            TextField(
              controller: mappingsCtl,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'NotoSansMono', fontSize: 11),
              decoration: const InputDecoration(
                labelText: 'Mappings (JSON): tabla Oracle → objetivo',
                helperText: 'type: persons | inmates | personnel | passes'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
          ])),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              List<dynamic> mappings;
              try {
                mappings = jsonDecode(mappingsCtl.text) as List<dynamic>;
              } on FormatException {
                setState(() => error = 'Mappings: JSON no válido');
                return;
              }
              final messenger = ScaffoldMessenger.of(ctx);
              final navigator = Navigator.of(ctx);
              final body = <String, dynamic>{
                'host': host.text.trim(),
                'port': int.tryParse(port.text.trim()) ?? 1521,
                'serviceKind': serviceKind,
                'serviceName': serviceName.text.trim(),
                'username': username.text.trim(),
                'thickMode': thickMode,
                'enabled': enabled,
                'mappings': mappings,
              };
              try {
                if (existing == null) {
                  await repo.createOracleConnector({...body, 'name': name.text.trim(), 'password': password.text});
                } else {
                  final patch = <String, dynamic>{...body};
                  if (name.text.trim().isNotEmpty && name.text.trim() != existing['name']) patch['name'] = name.text.trim();
                  if (password.text.isNotEmpty) patch['password'] = password.text;
                  await repo.updateOracleConnector('${existing['id']}', patch);
                }
                messenger.showSnackBar(const SnackBar(content: Text('Conector guardado')));
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

/// Plantilla inicial de mappings (editable).
List<Map<String, dynamic>> _sampleMappings() => [
  {
    'type': 'persons',
    'sourceTable': 'ESQUEMA.VISTA_PRESOS',
    'keyColumn': 'EXPEDIENTE',
    'columns': {
      'givenNames': 'NOMBRE',
      'familyNames': 'APELLIDOS',
      'phone': 'TELEFONO',
    },
    'latColumn': 'LATITUD',
    'lonColumn': 'LONGITUD',
    'codePrefix': 'OR-',
    'groups': ['A'],
  },
];
