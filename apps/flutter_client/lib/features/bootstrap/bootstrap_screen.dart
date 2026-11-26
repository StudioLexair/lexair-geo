import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/config/config_store.dart';
import '../../core/net/api_client.dart';
import '../../core/net/http_client_factory.dart';
import '../../core/runtime/local_runtime.dart';
import '../../core/theme/app_theme.dart';
import '../../app.dart';
import '../../core/app_services.dart';

/// Pantalla de arranque del «todo en uno»: levanta el servidor integrado
/// (PostgreSQL + API) antes de mostrar la pantalla de acceso. Solo aparece
/// cuando el paquete Windows incluye la carpeta `servidor/`.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key, required this.onDone});

  /// Recibe la configuración final y construye la aplicación normal.
  final void Function(AppConfig config, ConfigStore store) onDone;

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  final List<String> _log = [];
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _arrancar();
  }

  Future<void> _arrancar() async {
    setState(() {
      _busy = true;
      _error = null;
      _log.clear();
    });
    try {
      final plan = await ensureServidorIntegrado(onLog: (m) {
        setState(() => _log.add(m));
      });
      final store = ConfigStore();
      var config = await store.load();
      if (plan != null &&
          (config.serverUrl == 'https://geo.internal' ||
              config.serverUrl == plan.serverUrl)) {
        await store.saveOverride(plan.serverUrl);
        config = await store.load();
      }
      if (!mounted) return;
      widget.onDone(config, store);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
        _log.add('ERROR: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
        backgroundColor: LexairColors.sidebar,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Image.asset('assets/branding/vigia_logo.png',
                        width: 56, height: 56),
                    const SizedBox(width: 14),
                    const Text('VIGÍA',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2)),
                  ]),
                  const SizedBox(height: 10),
                  Text(_error == null && _busy
                      ? 'Iniciando el servidor integrado…'
                      : _error == null
                          ? 'Servidor integrado listo.'
                          : 'No se pudo iniciar el servidor integrado',
                      style: const TextStyle(color: Colors.white70, fontSize: 15)),
                  const SizedBox(height: 20),
                  if (_busy) const LinearProgressIndicator(
                      color: LexairColors.accent,
                      backgroundColor: LexairColors.sidebarActive),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    height: 180,
                    child: ListView(
                      reverse: true,
                      children: [
                        for (final l in _log.reversed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(l,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12.5)),
                          ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    Row(children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _arrancar,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                final store = ConfigStore();
                                final config = await store.load();
                                widget.onDone(config, store);
                              },
                        child: const Text('Continuar sin servidor integrado',
                            style: TextStyle(color: Colors.white70)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Raíz que decide entre la pantalla de arranque integrado y la app normal.
class VigiaRoot extends StatefulWidget {
  const VigiaRoot({
    super.key,
    required this.initialConfig,
    required this.store,
    required this.plan,
  });

  final AppConfig initialConfig;
  final ConfigStore store;
  final LocalRuntimePlan? plan;

  @override
  State<VigiaRoot> createState() => _VigiaRootState();
}

class _VigiaRootState extends State<VigiaRoot> {
  late AppConfig _config;
  late AppServices _services;
  bool _bootstrap = false;

  @override
  void initState() {
    super.initState();
    _config = widget.initialConfig;
    _services = _buildServices();
    // Arranque integrado solo si el servidor configurado es el de fábrica
    // o el propio puerto local (nunca pisa un servidor interno ya elegido).
    _bootstrap = widget.plan != null &&
        (_config.serverUrl == 'https://geo.internal' ||
            _config.serverUrl == widget.plan!.serverUrl) &&
        !_apiYaResponde();
  }

  bool _apiYaResponde() => false; // se comprueba en el propio arranque.

  AppServices _buildServices() => AppServices(
        config: _config,
        api: ApiClient(
          baseUrl: _config.apiBase,
          client: createHttpClient(caCertificatePath: _config.caCertificatePath),
        ),
        configStore: widget.store,
      );

  void _onDone(AppConfig config, ConfigStore store) {
    setState(() {
      _config = config;
      _services = AppServices(
        config: config,
        api: ApiClient(
          baseUrl: config.apiBase,
          client: createHttpClient(caCertificatePath: config.caCertificatePath),
        ),
        configStore: store,
      );
      _bootstrap = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bootstrap) {
      return BootstrapScreen(onDone: _onDone);
    }
    return LexairApp(services: _services);
  }
}
