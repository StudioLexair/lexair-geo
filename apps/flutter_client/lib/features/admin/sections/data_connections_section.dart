import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_services.dart';
import '../../../core/config/app_config.dart';
import '../../../core/net/api_exception.dart';
import '../../../core/config/config_store.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/auth_controller.dart';
import '../admin_repository.dart';
import '../admin_widgets.dart';

/// Conexiones de datos del sistema:
///  * PostGIS (destino): mapa, zonas, pases y consultas. La conexión se
///    define en el servidor (DATABASE_URL); aquí se comprueba y se muestra.
///  * Oracle 11g (origen): carga de reclusos, internos, personal y pases.
///    Los conectores con sus mappings se gestionan en la sección Oracle 11g.
///  * Modo local de pruebas: la aplicación apunta al equipo local hasta que
///    se decida el servidor definitivo (ajuste guardado en el cliente).
class DataConnectionsSection extends StatelessWidget {
  const DataConnectionsSection({super.key, required this.repo});

  final AdminRepository repo;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return ListView(padding: const EdgeInsets.all(16), children: [
      _PostgisCard(repo: repo),
      const SizedBox(height: 16),
      const _OracleCard(),
      const SizedBox(height: 16),
      _LocalModeCard(store: services.configStore, current: services.config),
      const SizedBox(height: 16),
      Text('Nota: las contraseñas de base de datos nunca se guardan en el cliente. '
          'PostGIS se configura en el servidor (DATABASE_URL) y Oracle con su clave '
          'cifrada en la sección Oracle 11g.',
          style: TextStyle(fontSize: 12, color: Colors.grey[700])),
    ]);
  }
}

class _PostgisCard extends StatelessWidget {
  const _PostgisCard({required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.storage_outlined, color: LexairColors.primary),
            const SizedBox(width: 8),
            const Expanded(child: Text('PostGIS (destino de datos y mapas)',
                style: TextStyle(fontWeight: FontWeight.w600))),
            TextButton.icon(
              icon: const Icon(Icons.wifi_find, size: 16),
              label: const Text('Probar'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  final s = await repo.status();
                  final db = s['database'] as Map<String, dynamic>?;
                  final ok = db?['ok'] == true;
                  messenger.showSnackBar(SnackBar(content: Text(
                    ok ? 'Conexión PostGIS OK${db?['latencyMs'] != null ? ' (${db!['latencyMs']} ms)' : ''}'
                       : 'PostGIS responde, pero la base de datos no está operativa')));
                } catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('Falló la prueba: $e')));
                }
              },
            ),
          ]),
          const SizedBox(height: 8),
          FutureBuilder<Json>(
            future: repo.status(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator());
              }
              final s = snap.data ?? const {};
              final db = (s['database'] ?? const {}) as Map<String, dynamic>;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _kv('Servidor', db['ok'] == true ? 'conectado' : 'sin conexión'),
                _kv('Base', '${db['database'] ?? '—'} · ${db['version'] ?? ''}'),
                _kv('Extensión PostGIS', '${db['postgis'] ?? '—'}'),
                _kv('Clúster de mapa', s['clusters'] != null ? 'listo' : 'pendiente'),
                _kv('Mosaicos', '${s['tiles'] ?? '—'}'),
              ]);
            },
          ),
          const SizedBox(height: 4),
          Text('La URL de conexión (DATABASE_URL) se define en el servidor: '
              'services/api/.env o variables de servicio.',
              style: TextStyle(fontSize: 12, color: Colors.grey[700])),
        ]),
      ),
    );
  }
}

class _OracleCard extends StatelessWidget {
  const _OracleCard();

  @override
  Widget build(BuildContext context) {
    final repo = AdminRepository(context.read<AppServices>().api);
    return Card(
      // No const: el repo depende del contexto.
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.table_view_outlined, color: LexairColors.primary),
            const SizedBox(width: 8),
            const Expanded(child: Text('Oracle 11g (base de origen externa)',
                style: TextStyle(fontWeight: FontWeight.w600))),
            TextButton.icon(
              key: const Key('config-oracle'),
              onPressed: () => _showConfigDialog(context, repo, null, null),
              icon: const Icon(Icons.settings, size: 18),
              label: const Text('Configurar'),
            ),
          ]),
          const SizedBox(height: 8),
          FutureBuilder<List<Json>>(
            future: repo.oracleConnectors(),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator());
              }
              final items = snap.data ?? const <Json>[];
              if (items.isEmpty) {
                return const Text('Sin conectores configurados. Crée uno en la sección «Oracle 11g».',
                    style: TextStyle(fontSize: 13, color: LexairColors.muted));
              }
              return Column(children: [
                for (final c in items)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(c['enabled'] == true ? Icons.link : Icons.link_off,
                        size: 18, color: c['enabled'] == true ? LexairColors.ok : LexairColors.muted),
                    title: Text('${c['name']} · ${c['username']}@${c['host']}:${c['port']}/${c['serviceName']}',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text('Última corrida: ${fmtDate(c['lastRunAt'])} ${c['lastStatus'] ?? ''}',
                        style: const TextStyle(fontSize: 12)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: 'Configurar base de datos',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: () => _showConfigDialog(context, repo, c, '${c['id']}'),
                      ),
                      IconButton(
                        tooltip: 'Probar conexión',
                        icon: const Icon(Icons.wifi_find, size: 18),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            final r = await repo.testOracleConnector('${c['id']}');
                            messenger.showSnackBar(SnackBar(content: Text('Conexión OK (${r['elapsedMs']} ms)')));
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(content: Text('Falló: $e')));
                          }
                        },
                      ),
                    ]),
                  ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

/// Diálogo «Configurar base de datos» con campos directos:
/// servidor, puerto, servicio, usuario y contraseña + prueba de conexión.
Future<void> _showConfigDialog(BuildContext context, AdminRepository repo, Json? connector, String? id) {
  return showDialog<void>(
    context: context,
    builder: (_) => _OracleConfigDialog(repo: repo, connector: connector, connectorId: id),
  );
}

class _OracleConfigDialog extends StatefulWidget {
  const _OracleConfigDialog({required this.repo, this.connector, this.connectorId});
  final AdminRepository repo;
  final Json? connector;
  final String? connectorId;

  @override
  State<_OracleConfigDialog> createState() => _OracleConfigDialogState();
}

class _OracleConfigDialogState extends State<_OracleConfigDialog> {
  late final TextEditingController _host = TextEditingController(text: widget.connector?['host']?.toString() ?? '');
  late final TextEditingController _port = TextEditingController(text: widget.connector?['port']?.toString() ?? '1521');
  late final TextEditingController _service = TextEditingController(text: widget.connector?['serviceName']?.toString() ?? '');
  late final TextEditingController _user = TextEditingController(text: widget.connector?['username']?.toString() ?? '');
  final TextEditingController _pass = TextEditingController();
  bool _sid = false;
  bool _busy = false;
  String? _estado;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _service.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Json _body({bool withPassword = true}) => {
        'host': _host.text.trim(),
        'port': int.tryParse(_port.text.trim()) ?? 1521,
        'serviceName': _service.text.trim(),
        'serviceKind': _sid ? 'sid' : 'service',
        'username': _user.text.trim(),
        if (withPassword && _pass.text.isNotEmpty) 'password': _pass.text,
      };

  Future<void> _probar() async {
    setState(() {
      _busy = true;
      _estado = 'Probando conexión…';
    });
    try {
      final r = await widget.repo.testOracleConnection(_body());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _estado = 'Conexión correcta (${r['elapsedMs']} ms)'
            '${r['banner'] != null ? ' · ${r['banner']}' : ''}';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _estado = 'Falló: ${e.userMessage}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _estado = 'Falló: $e';
      });
    }
  }

  Future<void> _aplicar() async {
    setState(() => _busy = true);
    try {
      final nuevo = _body(withPassword: false);
      if (_pass.text.isNotEmpty) nuevo['password'] = _pass.text;
      if (widget.connectorId == null) {
        await widget.repo.createOracleConnector({
          ...nuevo,
          'name': _service.text.trim().isEmpty ? 'principal' : _service.text.trim(),
          'enabled': true,
          'mappings': const [],
        });
      } else {
        await widget.repo.updateOracleConnector(widget.connectorId!, nuevo);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _estado = 'No se pudo guardar: ${e.userMessage}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _estado = 'No se pudo guardar: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Configurar base de datos'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: _host,
              decoration: const InputDecoration(labelText: 'Servidor o dirección')),
          const SizedBox(height: 8),
          TextField(controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Puerto')),
          const SizedBox(height: 8),
          TextField(controller: _service,
              decoration: const InputDecoration(labelText: 'Servicio Oracle')),
          const SizedBox(height: 8),
          TextField(controller: _user,
              decoration: const InputDecoration(labelText: 'Usuario de la base')),
          const SizedBox(height: 8),
          TextField(controller: _pass,
              obscureText: true,
              decoration: InputDecoration(
                labelText: widget.connectorId == null ? 'Contraseña de la base' : 'Contraseña (vacío: sin cambios)'),
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            value: _sid,
            onChanged: (v) => setState(() => _sid = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Conectar por SID en vez de servicio'),
          ),
          if (_estado != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_estado!,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: _estado!.startsWith('Conexión correcta')
                          ? LexairColors.ok
                          : Theme.of(context).colorScheme.error)),
            ),
        ]),
      ),
      actions: [
        TextButton.icon(
          onPressed: _busy ? null : _probar,
          icon: const Icon(Icons.wifi_find, size: 18),
          label: const Text('Probar conexión'),
        ),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(onPressed: _busy ? null : _aplicar, child: const Text('Aplicar')),
      ],
    );
  }
}

class _LocalModeCard extends StatelessWidget {
  const _LocalModeCard({required this.store, required this.current});
  final ConfigStore store;
  final AppConfig current;

  @override
  Widget build(BuildContext context) {
    final isLocal = current.serverUrl.contains('localhost') || current.serverUrl.contains('127.0.0.1');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.computer_outlined, color: isLocal ? LexairColors.warn : LexairColors.primary),
            const SizedBox(width: 8),
            const Expanded(child: Text('Modo local de pruebas',
                style: TextStyle(fontWeight: FontWeight.w600))),
            Switch(
              key: const Key('local-mode-switch'),
              value: isLocal,
              onChanged: (v) async {
                final services = context.read<AppServices>();
                final auth = context.read<AuthController>();
                final confirmar = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                  title: const Text('Cambiar conexión'),
                  content: const Text('Se cerrará la sesión actual y se aplicará la nueva conexión.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continuar')),
                  ],
                ));
                if (confirmar != true || !context.mounted) return;
                await store.saveOverride(v ? 'http://localhost:3000' : null);
                await auth.logout();
                await services.onConfigChanged?.call();
              },
            ),
          ]),
          Text('Servidor actual: ${current.serverUrl} (${current.source})',
              style: const TextStyle(fontSize: 12, color: LexairColors.muted)),
          const SizedBox(height: 4),
          const Text('Para pruebas en el equipo: API local con la base PostGIS del propio '
              'equipo hasta configurar el servidor y las bases definitivas.',
              style: TextStyle(fontSize: 12, color: LexairColors.muted)),
        ]),
      ),
    );
  }
}

Widget _kv(String k, String v) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 2),
  child: Row(children: [
    SizedBox(width: 170, child: Text(k, style: const TextStyle(color: LexairColors.muted, fontSize: 13))),
    Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
  ]),
);

