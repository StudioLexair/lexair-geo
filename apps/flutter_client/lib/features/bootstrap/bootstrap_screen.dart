import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/config/config_store.dart';
import '../../core/config/terminologia.dart';
import '../../core/net/api_client.dart';
import '../../core/net/http_client_factory.dart';
import '../../core/runtime/local_runtime.dart';
import '../../core/theme/app_theme.dart';
import '../../app.dart';
import '../../core/app_services.dart';
import 'asistente_screen.dart';

/// Pantalla de arranque del «todo en uno»: levanta el servidor integrado
/// (base de datos + API) antes de mostrar la pantalla de acceso. Solo aparece
/// cuando el paquete Windows incluye la carpeta `servidor/`.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key, required this.onDone});

  /// Recibe la configuración final y construye la aplicación normal.
  final void Function(AppConfig config, ConfigStore store) onDone;

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _PasoDef {
  const _PasoDef(this.key, this.label);
  final String key;
  final String label;
}

const List<_PasoDef> _pasos = [
  _PasoDef('bd', 'Base de datos local'),
  _PasoDef('esquema', 'Esquema y migraciones'),
  _PasoDef('catalogo', 'Datos del territorio'),
  _PasoDef('cuenta', 'Cuenta de acceso'),
  _PasoDef('api', 'Servidor local'),
];

class _BootstrapScreenState extends State<BootstrapScreen> {
  final Map<String, String> _estado = {};
  final List<String> _log = [];
  final List<int> _puertos = [];
  String? _error;
  bool _busy = true;
  int _segundos = 0;

  @override
  void initState() {
    super.initState();
    _arrancar();
    Stream.periodic(const Duration(seconds: 1)).listen((_) {
      if (mounted && _busy) setState(() => _segundos++);
    });
  }

  bool _esLocal(String url) =>
      url == 'https://geo.internal' ||
      url.startsWith('http://127.0.0.1') ||
      url.startsWith('http://localhost');

  Future<void> _arrancar() async {
    setState(() {
      _busy = true;
      _error = null;
      _estado.clear();
      _log.clear();
      _segundos = 0;
    });
    try {
      final plan = await ensureServidorIntegrado(
        onLog: (m) {
          if (!mounted) return;
          setState(() => _log.add(m));
        },
        onPaso: (k, e) {
          if (!mounted) return;
          setState(() => _estado[k] = e);
        },
      );
      final store = ConfigStore();
      var config = await store.load();
      if (plan != null && _esLocal(config.serverUrl)) {
        await store.saveOverride(plan.serverUrl);
        config = await store.load();
        if (mounted) setState(() => _puertos.add(plan.puertoApi));
      }
      if (!mounted) return;
      widget.onDone(config, store);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.toString();
        _log.add('ERROR: $e');
      });
    }
  }

  Widget _icono(String estado) {
    switch (estado) {
      case 'listo':
      case 'omitido':
        return const Icon(Icons.check_circle, color: LexairColors.ok, size: 20);
      case 'error':
        return Icon(Icons.error, color: Theme.of(context).colorScheme.error, size: 20);
      case 'iniciando':
        return const SizedBox(
            width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: LexairColors.accent));
      default:
        return const Icon(Icons.radio_button_unchecked, color: Colors.white24, size: 20);
    }
  }

  String _textoEstado(String estado) {
    switch (estado) {
      case 'listo':
        return 'listo';
      case 'omitido':
        return 'ya estaba';
      case 'error':
        return 'con problemas';
      case 'iniciando':
        return 'iniciando…';
      default:
        return 'pendiente';
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
            constraints: const BoxConstraints(maxWidth: 540),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Image.asset('assets/branding/vigia_logo.png', width: 56, height: 56),
                    const SizedBox(width: 14),
                    Text(T.orgNombre,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2)),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    _error == null && _busy
                        ? 'Preparando el sistema… ($_segundos s)'
                        : _error == null
                            ? 'Sistema listo.'
                            : 'No se pudo iniciar el sistema local',
                    style: const TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                  const SizedBox(height: 18),
                  for (final p in _pasos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(children: [
                        _icono(_estado[p.key] ?? ''),
                        const SizedBox(width: 12),
                        Text(p.label,
                            style: TextStyle(
                                color: (_estado[p.key] ?? '') == 'error'
                                    ? Theme.of(context).colorScheme.error
                                    : Colors.white,
                                fontSize: 14.5)),
                        const Spacer(),
                        Text(_textoEstado(_estado[p.key] ?? ''),
                            style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
                      ]),
                    ),
                  const SizedBox(height: 16),
                  if (_busy)
                    const LinearProgressIndicator(
                        color: LexairColors.accent, backgroundColor: LexairColors.sidebarActive),
                  if (_puertos.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Puerto del servidor: ${_puertos.first}',
                        style: const TextStyle(color: Colors.white38, fontSize: 12.5)),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    height: _error != null ? 160 : 120,
                    child: ListView(
                      reverse: true,
                      children: [
                        for (final l in _log.reversed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(l,
                                style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
                        child: const Text('Continuar sin servidor local',
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

/// Raíz: decide entre el asistente de primera configuración, la pantalla de
/// arranque del servidor integrado y la aplicación normal.
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
  bool _asistente = false;

  bool _esLocalOFabrica(String url) =>
      url == 'https://geo.internal' ||
      url.startsWith('http://127.0.0.1') ||
      url.startsWith('http://localhost');

  @override
  void initState() {
    super.initState();
    _config = widget.initialConfig;
    _services = _buildServices();
    if (widget.plan != null && _esLocalOFabrica(_config.serverUrl)) {
      // Primera configuración: si el asistente no se ha completado aún, es lo
      // primero que se ve; después arranca el servidor integrado.
      _asistente = true;
      _cargarBandera();
    }
  }

  Future<void> _cargarBandera() async {
    final hecha = await widget.store.getFlag('asistenteCompletado');
    if (!mounted) return;
    setState(() {
      _asistente = !hecha;
      _bootstrap = hecha;
    });
  }

  AppServices _buildServices() => AppServices(
        config: _config,
        api: ApiClient(
          baseUrl: _config.apiBase,
          client: createHttpClient(caCertificatePath: _config.caCertificatePath),
        ),
        configStore: widget.store,
        onConfigChanged: _aplicarConfiguracion,
      );

  void _actualizarServicios(AppConfig config) {
    final anterior = _services;
    setState(() {
      _config = config;
      _services = _buildServices();
    });
    // Desmontar primero los consumidores del cliente anterior.
    WidgetsBinding.instance.addPostFrameCallback((_) => anterior.api.close());
  }

  Future<void> _aplicarConfiguracion() async {
    final config = await widget.store.load();
    if (!mounted) return;
    _actualizarServicios(config);
    if (widget.plan != null && _esLocalOFabrica(config.serverUrl)) {
      setState(() => _bootstrap = true);
    }
  }

  void _onDone(AppConfig config, ConfigStore store) {
    _actualizarServicios(config);
    setState(() {
      _bootstrap = false;
      _asistente = false;
    });
  }

  Future<void> _onDecision(DecisionAsistente d) async {
    final store = widget.store;
    await store.setFlag('asistenteCompletado', true);
    if (d is DecisionLocal) {
      setState(() {
        _asistente = false;
        _bootstrap = true;
      });
    } else if (d is DecisionRed) {
      await store.saveOverride(d.url);
      final config = await store.load();
      if (!mounted) return;
      _actualizarServicios(config);
      setState(() => _asistente = false);
    } else {
      setState(() => _asistente = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget contenido;
    if (_asistente) {
      contenido = AsistenteScreen(onDecision: _onDecision, onFlag: () async {});
    } else if (_bootstrap) {
      contenido = BootstrapScreen(onDone: _onDone);
    } else {
      contenido = LexairApp(key: ObjectKey(_services), services: _services);
    }
    // Las pantallas anteriores al acceso necesitan su propio MaterialApp:
    // aporta Overlay, Navigator, tema y soporte correcto para campos de texto.
    if (_asistente || _bootstrap) {
      return MaterialApp(
        title: 'VIGÍA · Lexair Geo',
        debugShowCheckedModeBanner: false,
        theme: buildLexairTheme(),
        home: contenido,
      );
    }
    return contenido;
  }
}
