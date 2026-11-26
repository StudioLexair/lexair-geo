import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_services.dart';
import '../../core/config/terminologia.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../map/workspace_controller.dart';
import '../persons/person.dart';
import '../persons/photo_cache.dart';
import 'search_repository.dart';

/// Búsqueda global (Ctrl+K): una caja, todo lo que existe en el sistema.
/// Sugerencias en vivo con foto, agrupadas por tipo; direcciones y zonas
/// vuelan al mapa; guarda un historial y permite fijar búsquedas frecuentes.
Future<void> showGlobalSearch(BuildContext context) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Búsqueda global',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, a1, a2) => const Center(child: GlobalSearchOverlay()),
    transitionBuilder: (_, anim, a2, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(anim), child: child),
    ),
  );
}

/// Una fila de resultados: persona, dirección o zona.
sealed class Hit {
  Widget leading(BuildContext context);
  String get titulo;
  String get subtitulo;
  IconData get icono;
}

class PersonHit extends Hit {
  PersonHit(this.person);
  final Person person;

  @override
  Widget leading(BuildContext context) => FutureBuilder<Uint8List?>(
    future: PhotoCache.I.get(person.id),
    builder: (_, snap) {
      final bytes = snap.data;
      if (bytes != null && bytes.isNotEmpty) {
        return CircleAvatar(radius: 16, backgroundImage: MemoryImage(bytes));
      }
      return CircleAvatar(
        radius: 16,
        backgroundColor: Labels.groupColor(person.groups),
        child: Text(person.groups.join(), style: const TextStyle(color: Colors.white, fontSize: 12)),
      );
    },
  );

  @override
  String get titulo => person.fullName;
  @override
  String get subtitulo => [
    person.code,
    person.location?.municipality ?? (person.location == null ? 'Sin ubicación' : null),
    person.phone,
    if (!person.isActive) 'inactiva',
  ].whereType<String>().join(' · ');
  @override
  IconData get icono => Icons.person_outline;
}

class AddressEntry extends Hit {
  AddressEntry(this.address);
  final AddressHit address;

  @override
  Widget leading(BuildContext context) => CircleAvatar(
    radius: 16,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Icon(
      switch (address.fuente) { 'vivienda' => Icons.home_outlined, 'antiguo' => Icons.history_edu, _ => Icons.add_road_outlined },
      size: 18,
      color: LexairColors.accent,
    ),
  );

  @override
  String get titulo => address.label;
  @override
  String get subtitulo => [
    address.municipality,
    address.fuenteEtiqueta,
  ].whereType<String>().join(' · ');
  @override
  IconData get icono => Icons.place_outlined;
}

class ZoneEntry extends Hit {
  ZoneEntry(this.zone);
  final ZoneHit zone;

  @override
  Widget leading(BuildContext context) => CircleAvatar(
    radius: 16,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Icon(Icons.shield_outlined, size: 18, color: LexairColors.accent),
  );

  @override
  String get titulo => zone.name;
  @override
  String get subtitulo => 'Zona del mapa';
  @override
  IconData get icono => Icons.shield_outlined;
}

class GlobalSearchOverlay extends StatefulWidget {
  const GlobalSearchOverlay({super.key});

  @override
  State<GlobalSearchOverlay> createState() => _GlobalSearchOverlayState();
}

class _GlobalSearchOverlayState extends State<GlobalSearchOverlay> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  late final SearchRepository _repo;
  Timer? _debounce;
  GlobalSearch? _result;
  String? _error;
  bool _loading = false;
  bool _vivo = false;
  int _cursor = -1;
  final List<Hit> _hits = [];
  List<String> _historial = [];
  List<String> _fijados = [];
  final Set<String> _filtros = <String>{};

  static const _kHistorial = 'lexair.busq.historial';
  static const _kFijados = 'lexair.busq.fijados';

  @override
  void initState() {
    super.initState();
    _repo = SearchRepository(context.read<AppServices>().api);
    _cargarGuardadas();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _cargarGuardadas() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _historial = p.getStringList(_kHistorial) ?? const [];
        _fijados = p.getStringList(_kFijados) ?? const [];
      });
    }
  }

  Future<void> _guardar(String q) async {
    final p = await SharedPreferences.getInstance();
    _historial = [q, ..._historial.where((x) => x != q)].take(12).toList();
    await p.setStringList(_kHistorial, _historial);
  }

  Future<void> _alternarFijado(String q) async {
    final p = await SharedPreferences.getInstance();
    setState(() => _fijados.contains(q) ? _fijados.remove(q) : _fijados.add(q));
    if (_fijados.length > 8) _fijados.removeRange(8, _fijados.length);
    await p.setStringList(_kFijados, _fijados.toList());
  }

  void _alEscribir(String _) {
    _debounce?.cancel();
    if (_ctrl.text.trim().length < 2) {
      setState(() {
        _result = null;
        _error = null;
        _hits.clear();
        _cursor = -1;
        _vivo = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), _buscar);
  }

  Future<void> _buscar() async {
    final q = _ctrl.text.trim();
    if (q.length < 2) return;
    setState(() => _loading = true);
    try {
      final r = await _repo.run(q, filtros: _filtros.toList());
      if (!mounted) return;
      setState(() {
        _result = r;
        _error = null;
        _vivo = true;
        _hits
          ..clear()
          ..addAll(r.persons.map(PersonHit.new))
          ..addAll(r.addresses.map(AddressEntry.new))
          ..addAll(r.zones.map(ZoneEntry.new));
        _cursor = _hits.isEmpty ? -1 : 0;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _usarTexto(String texto) {
    _ctrl.text = texto;
    _cursor = -1;
    _buscar();
    _focus.requestFocus();
  }

  Future<void> _activar(Hit hit) async {
    final q = _ctrl.text.trim();
    if (q.isNotEmpty) await _guardar(q);
    if (!mounted) return;
    final ws = context.read<WorkspaceController>();
    Navigator.of(context).pop();
    switch (hit) {
      case PersonHit(:final person):
        unawaited(ws.select(person));
      case AddressEntry(:final address):
        ws.centerOn(LatLng(address.lat, address.lon), 17);
      case ZoneEntry(:final zone):
        ws.centerOn(LatLng(zone.lat, zone.lon), 14);
    }
  }

  KeyEventResult _teclas(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (_hits.isEmpty) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _cursor = (_cursor + 1) % _hits.length);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _cursor = (_cursor - 1 + _hits.length) % _hits.length);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_cursor >= 0 && _cursor < _hits.length) unawaited(_activar(_hits[_cursor]));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      constraints: BoxConstraints(
        maxWidth: 620,
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Focus(
        onKeyEvent: _teclas,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ctrl,
              focusNode: _focus,
              onChanged: _alEscribir,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Buscar personas, direcciones, teléfonos…  (Ctrl+K)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _ctrl.clear();
                          _alEscribir('');
                        },
                      ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 18),
              ),
            ),
            const Divider(height: 1),
            if (_filtros.isNotEmpty || _vivo) _chipsFiltros(),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(14), child: Text(_error!, style: const TextStyle(color: Colors.red))),
            Flexible(child: _cuerpo(theme)),
            if (_vivo && _result != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: Text(
                  '${_result!.persons.length + _result!.addresses.length + _result!.zones.length} resultado(s) · ${_result!.tookMs} ms',
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chipsFiltros() {
    final pase = T.paseSingular;
    final chips = {
      'con_permiso': Text('En $pase'.toLowerCase()),
      'sin_ubicacion': const Text('Sin ubicación'),
      'con_telefono': const Text('Con teléfono'),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        children: [
          for (final e in chips.entries)
            FilterChip(
              label: e.value,
              selected: _filtros.contains(e.key),
              visualDensity: VisualDensity.compact,
              onSelected: (v) {
                setState(() => v ? _filtros.add(e.key) : _filtros.remove(e.key));
                if (_ctrl.text.trim().length >= 2) _buscar();
              },
            ),
        ],
      ),
    );
  }

  Widget _cuerpo(ThemeData theme) {
    final q = _ctrl.text.trim();
    if (q.length < 2) return _guardadas(theme);
    if (_loading && _result == null) return const Center(child: Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 2)));
    final r = _result;
    final sugerencia = r?.sugerencia;
    Widget? banner() {
      if (sugerencia == null || sugerencia.toLowerCase() == q.toLowerCase()) return null;
      return Material(
        color: LexairColors.accent.withValues(alpha: 0.12),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.auto_fix_high, size: 20, color: LexairColors.accent),
          title: Text('¿Quisiste decir «$sugerencia»?'),
          onTap: () => _usarTexto(sugerencia),
        ),
      );
    }
    if (r == null || r.vacia) {
      final b = banner();
      return Column(children: [
        ?b,
        Expanded(
          child: Center(
            child: Text(_error == null ? 'Sin resultados' : '', style: theme.textTheme.bodySmall),
          ),
        ),
      ]);
    }
    final filas = <Widget>[ if (banner() != null) banner()! ];
    var i = 0;
    void grupo(String titulo, Iterable<Hit> items) {
      if (items.isEmpty) return;
      filas.add(Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
        child: Text(titulo.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: Colors.white54, letterSpacing: 1.2)),
      ));
      for (final hit in items) {
        final sel = i == _cursor;
        filas.add(Material(
          color: sel ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
          child: MouseRegion(
            onEnter: (_) { if (mounted) setState(() => _cursor = i); },
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: hit.leading(context),
              title: Text(hit.titulo, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(hit.subtitulo, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Icon(hit.icono, size: 16, color: sel ? LexairColors.accent : Colors.white30),
              onTap: () => unawaited(_activar(hit)),
            ),
          ),
        ));
        i++;
      }
    }
    grupo('Personas', r.persons.map((p) => PersonHit(p)));
    grupo('Direcciones', r.addresses.map(AddressEntry.new));
    grupo('Zonas', r.zones.map(ZoneEntry.new));
    return ListView(shrinkWrap: true, children: filas);
  }

  Widget _guardadas(ThemeData theme) {
    final secciones = <(String, IconData, List<String>)>[
      ('Fijados', Icons.push_pin_outlined, _fijados),
      ('Búsquedas recientes', Icons.history, _historial.where((q) => !_fijados.contains(q)).toList()),
    ];
    final filas = <Widget>[];
    for (final (titulo, icono, lista) in secciones) {
      if (lista.isEmpty) continue;
      filas.add(Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
        child: Text(titulo.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: Colors.white54, letterSpacing: 1.2)),
      ));
      for (final q in lista) {
        filas.add(ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(icono, size: 18, color: Colors.white54),
          title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: titulo == 'Fijados'
              ? IconButton(icon: const Icon(Icons.push_pin, size: 16), tooltip: 'Quitar',
                  onPressed: () => unawaited(_alternarFijado(q)))
              : IconButton(icon: const Icon(Icons.push_pin_outlined, size: 16), tooltip: 'Fijar',
                  onPressed: () => unawaited(_alternarFijado(q))),
          onTap: () => _usarTexto(q),
        ));
      }
    }
    if (filas.isEmpty) {
      filas.add(Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text('Escribe para buscar en todo el sistema.\n«puedes pegar» un teléfono o una dirección con número.',
              textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        ),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: filas);
  }
}
