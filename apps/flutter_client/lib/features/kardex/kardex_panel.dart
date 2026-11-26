import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../auth/auth_controller.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart' show Labels;
import '../map/map_markers.dart' show fmtDateIso;
import '../map/workspace_controller.dart';
import '../persons/location_dialog.dart';
import '../persons/person.dart';
import '../persons/photo_cache.dart';
import '../../core/config/terminologia.dart';
import '../passes/pass.dart';

/// Kardex junto al mapa: todas las personas cargadas, con foto (o iniciales)
/// y nombre. Cada ficha se puede tocar (modal con todos los datos), arrastrar
/// sobre el mapa para marcar la residencia exacta, o «marcar en el mapa».
/// El panel se minimiza a un botón lateral.
class KardexPanel extends StatefulWidget {
  const KardexPanel({super.key});

  @override
  State<KardexPanel> createState() => _KardexPanelState();
}

class _KardexPanelState extends State<KardexPanel> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Person> _rows = const [];
  String? _error;
  bool _loading = false;
  String? _nextPage;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _reload();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300 && _nextPage != null && !_loading) _loadMore();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _reload());
  }

  Future<void> _reload() async {
    final ws = context.read<WorkspaceController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await ws.persons.search(
        q: _q.text.trim().isEmpty ? null : _q.text.trim(),
        pageSize: 100,
      );
      if (!mounted) return;
      setState(() {
        _rows = page.items;
        _nextPage = page.page < _lastPage(page) ? '${page.page + 1}' : null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.userMessage;
        _loading = false;
      });
    }
  }

  int _lastPage(PageResult<Person> page) =>
      page.totalIsCapped ? page.page + 1 : (page.total / page.pageSize).ceil().clamp(page.page, 9999);

  Future<void> _loadMore() async {
    final ws = context.read<WorkspaceController>();
    final next = int.tryParse(_nextPage ?? '');
    if (next == null || _loading) return;
    setState(() => _loading = true);
    try {
      final page = await ws.persons.search(
        q: _q.text.trim().isEmpty ? null : _q.text.trim(),
        page: next,
        pageSize: 100,
      );
      if (!mounted) return;
      setState(() {
        _rows = [..._rows, ...page.items];
        _nextPage = page.page < _lastPage(page) ? '${page.page + 1}' : null;
        _loading = false;
      });
    } on ApiException {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    if (!ws.kardexOpen) {
      return Positioned(
        top: 130,
        right: 12,
        child: Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(8),
          color: LexairColors.sidebar,
          child: Tooltip(
            message: 'Abrir ${T.kardexTitulo.toLowerCase()}',
            child: InkWell(
              key: const Key('kardex-open'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => ws.setKardexOpen(true),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.menu_book_outlined, color: Colors.white, size: 22),
                  const SizedBox(height: 4),
                  RotatedBox(quarterTurns: 1,
                      child: Text(T.kardexTituloCorto,
                          style: const TextStyle(color: Colors.white, fontSize: 11, letterSpacing: 1))),
                ]),
              ),
            ),
          ),
        ),
      );
    }
    // Con el panel de zona abierto no estorba: se minimiza solo.
    if (ws.selectedZone != null) return const SizedBox.shrink();
    return Positioned(
      top: 64,
      right: 12,
      bottom: 12,
      width: 300,
      child: Card(
        key: const Key('kardex-panel'),
        elevation: 4,
        margin: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: LexairColors.sidebar,
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              const Icon(Icons.menu_book_outlined, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text(T.kardexTitulo,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
              IconButton(
                key: const Key('kardex-close'),
                tooltip: 'Minimizar',
                icon: const Icon(Icons.keyboard_double_arrow_right, size: 18, color: Colors.white),
                onPressed: () => ws.setKardexOpen(false),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: TextField(
              controller: _q,
              onChanged: _onChanged,
              onSubmitted: (_) => _reload(),
              decoration: const InputDecoration(
                hintText: 'Buscar por nombre, código o teléfono',
                prefixIcon: Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_error!,
                style: const TextStyle(fontSize: 12, color: LexairColors.danger))),
          Expanded(child: _rows.isEmpty && !_loading
            ? const Center(child: Text('Sin personas cargadas.',
                style: TextStyle(fontSize: 13, color: LexairColors.muted)))
            : ListView.builder(
                key: const Key('kardex-list'),
                controller: _scroll,
                padding: const EdgeInsets.all(8),
                itemCount: _rows.length + (_loading ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i >= _rows.length) {
                    return const Center(child: Padding(padding: EdgeInsets.all(12),
                        child: SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))));
                  }
                  final p = _rows[i];
                  return KardexPersonTile(person: p, onUpdated: _reload);
                },
              )),
        ]),
      ),
    );
  }
}

/// Ficha del kardex: foto/iniciales a la izquierda, nombre al lado; se toca
/// para el modal completo y se arrastra al mapa para marcar la residencia.
class KardexPersonTile extends StatelessWidget {
  const KardexPersonTile({super.key, required this.person, this.onUpdated});
  final Person person;
  final VoidCallback? onUpdated;

  @override
  Widget build(BuildContext context) {
    final ws = context.read<WorkspaceController>();
    final located = person.location?.point != null;
    return Draggable<Person>(
      data: person,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        color: LexairColors.primary,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            kardexAvatar(person, 22),
            const SizedBox(width: 8),
            Text(person.fullName, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
      ),
      onDragUpdate: (details) {
        // La vista convierte la posición global en coordenadas geográficas.
        ws.updateKardexDrag(details.globalPosition);
      },
      onDragStarted: () => ws.setKardexDragging(true),
      onDragEnd: (_) => ws.setKardexDragging(false),
      childWhenDragging: Opacity(opacity: 0.4, child: _tile(context, located)),
      child: GestureDetector(
        key: Key('kardex-tile-${person.code}'),
        onTap: () async {
          final updated = await showKardexPersonModal(context, person: person, onUpdated: onUpdated);
          if (updated != null) ws.replaceSelected(updated);
        },
        child: _tile(context, located),
      ),
    );
  }

  Widget _tile(BuildContext context, bool located) {
    final ws = context.read<WorkspaceController>();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: located ? LexairColors.primary.withValues(alpha: 0.06) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: LexairColors.border),
      ),
      child: Row(children: [
        kardexAvatar(person, 18),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(person.fullName, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          Text(person.code,
              style: const TextStyle(fontSize: 11, color: LexairColors.muted, fontFeatures: [])),
        ])),
        Tooltip(
          message: located ? 'Marcado en el mapa' : 'Sin ubicación precisa: arrastre al mapa o «Marcar»',
          child: Icon(located ? Icons.location_on : Icons.location_off,
              size: 16, color: located ? LexairColors.ok : LexairColors.warn),
        ),
        IconButton(
          tooltip: 'Abrir ficha',
          icon: const Icon(Icons.chevron_right, size: 18),
          onPressed: () async {
            final updated = await showKardexPersonModal(context, person: person);
            if (updated != null) ws.replaceSelected(updated);
          },
        ),
      ]),
    );
  }
}

/// Avatar del kardex: foto si el servidor la proporciona, iniciales si no.
Widget kardexAvatar(Person p, double radius) {
  final initials = p.fullName.isEmpty ? '?' : p.fullName.trim().split(RegExp(r'\s+'))
      .take(2).map((s) => s[0].toUpperCase()).join();
  return CircleAvatar(
    radius: radius,
    backgroundColor: LexairColors.sidebar,
    child: FutureBuilder<Uint8List?>(
      future: PhotoCache.I.get(p.id),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes != null && bytes.isNotEmpty) {
          return ClipOval(
            child: Image.memory(bytes,
                width: radius * 2, height: radius * 2, fit: BoxFit.cover,
                gaplessPlayback: true),
          );
        }
        return Text(initials, style: TextStyle(color: Colors.white, fontSize: radius * 0.62));
      },
    ),
  );
}

/// Modal con TODOS los datos cargados de la persona (ficha, ubicación,
/// interno, pases) y acciones de marcado preciso en el mapa.
Future<Person?> showKardexPersonModal(BuildContext context, {required Person person, void Function()? onUpdated}) =>
    showDialog<Person>(context: context, builder: (_) => _KardexPersonModal(person: person, onUpdated: onUpdated));

class _KardexPersonModal extends StatefulWidget {
  const _KardexPersonModal({required this.person, this.onUpdated});
  final Person person;
  final void Function()? onUpdated;

  @override
  State<_KardexPersonModal> createState() => _KardexPersonModalState();
}

class _KardexPersonModalState extends State<_KardexPersonModal> {
  late Person _person = widget.person;
  bool _loadingPasses = true;
  Inmate? _inmate;
  List<Pass> _passes = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPasses();
  }

  Future<void> _loadPasses() async {
    final ws = context.read<WorkspaceController>();
    try {
      final j = await ws.passesRepo.ofPerson(widget.person.id);
      if (!mounted) return;
      setState(() {
        _inmate = j['inmate'] == null ? null : Inmate.fromJson(j['inmate'] as Map<String, dynamic>);
        _passes = ((j['passes'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>().map(Pass.fromJson).toList();
        _loadingPasses = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isForbidden ? 'Sin permiso para consultar ${T.sujetoPlural.toLowerCase()} y ${T.pasePlural.toLowerCase()}.' : e.userMessage;
        _loadingPasses = false;
      });
    }
  }

  Future<void> _cambiarFoto() async {
    final f = await FilePicker.pickFile(type: FileType.image);
    if (f == null || !mounted) return;
    final ws = context.read<WorkspaceController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await f.readAsBytes();
      if (bytes.length > 3 * 1024 * 1024) {
        messenger.showSnackBar(const SnackBar(content: Text('La imagen supera 3 MB')));
        return;
      }
      final ruta = (f.path ?? '').toLowerCase();
      final mime = ruta.endsWith('.png') ? 'image/png'
          : ruta.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
      await ws.persons.uploadPhoto(_person.id, bytes, mime);
      if (!mounted) return;
      setState(() {});
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  Future<void> _quitarFoto() async {
    final ws = context.read<WorkspaceController>();
    try {
      await ws.persons.removePhoto(_person.id);
      if (!mounted) return;
      setState(() {});
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  /// Edita teléfono, CDR, zona y notas (PATCH /persons/:id).
  Future<void> _editarFicha() async {
    final phone = TextEditingController(text: _person.phone ?? '');
    final cdr = TextEditingController(text: _person.cdr ?? '');
    final zona = TextEditingController(text: _person.defenseZone ?? '');
    final notas = TextEditingController(text: _person.notes ?? '');
    final updated = await showDialog<Person>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar ficha'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: phone,
                decoration: const InputDecoration(labelText: 'Teléfono')),
            const SizedBox(height: 10),
            TextField(controller: cdr,
                decoration: const InputDecoration(labelText: 'CDR')),
            const SizedBox(height: 10),
            TextField(controller: zona,
                decoration: const InputDecoration(labelText: 'Zona de defensa')),
            const SizedBox(height: 10),
            TextField(controller: notas, maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notas')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () async {
              final ws = ctx.read<WorkspaceController>();
              String? limpiar(String v) => v.trim().isEmpty ? null : v.trim();
              try {
                final r = await ws.persons.update(_person.id, {
                  'phone': limpiar(phone.text),
                  'cdr': limpiar(cdr.text),
                  'defenseZone': limpiar(zona.text),
                  'notes': limpiar(notas.text),
                });
                if (ctx.mounted) Navigator.of(ctx).pop(r);
              } on ApiException catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.userMessage)));
                }
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (updated != null && mounted) {
      setState(() => _person = updated);
      widget.onUpdated?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _person;
    final loc = p.location;
    final ws = context.read<WorkspaceController>();
    final user = context.read<AuthController>().user;
    final canWriteLocation = user?.can('locations.write') ?? false;
    final canWritePersons = user?.can('persons.write') ?? false;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      title: Row(children: [
        kardexAvatar(p, 22),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p.fullName, style: const TextStyle(fontSize: 16)),
          Text('Código ${p.code} · ${p.isActive ? 'activo' : 'inactivo'}',
              style: const TextStyle(fontSize: 12, color: LexairColors.muted)),
        ])),
        if (canWritePersons)
          PopupMenuButton<String>(
            tooltip: 'Foto',
            icon: const Icon(Icons.photo_camera_outlined, size: 20),
            onSelected: (v) {
              if (v == 'cambiar') _cambiarFoto();
              if (v == 'quitar') _quitarFoto();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'cambiar', child: Text('Cambiar foto…')),
              if (PhotoCache.I.hasPhoto(p.id))
                const PopupMenuItem(value: 'quitar', child: Text('Quitar foto')),
            ],
          ),
      ]),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _section('Identificación', [
            _row('Código', p.code),
            _row('Teléfono', p.phone ?? '—'),
            if (p.cdr != null && p.cdr!.isNotEmpty) _row('CDR', p.cdr!),
            if (p.defenseZone != null && p.defenseZone!.isNotEmpty) _row('Zona de defensa', p.defenseZone!),
            _row('Origen del dato', p.dataSource),
            _row('Grupos', p.groups.join(', ')),
            _row('Visibilidad', p.visibility),
            if (p.notes != null && p.notes!.isNotEmpty) _row('Notas', p.notes!),
          ]),
          _section('Ubicación', [
            _row('Dirección', loc?.addressText ?? 'sin dirección'),
            _row('Municipio', loc?.municipality ?? '—'),
            _row('Precisión', loc?.precisionLevel ?? '—'),
            _row('Validación', loc?.validationStatus ?? '—'),
            if (loc?.point != null)
              _row('Coordenadas', '${Labels.coord(loc!.point!.latitude)}, ${Labels.coord(loc.point!.longitude)}'),
          ]),
          _loadingPasses
            ? const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())
            : _error != null
              ? Text(_error!, style: const TextStyle(fontSize: 12, color: LexairColors.danger))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_inmate != null)
                    _section('Interno', [
                      if (_inmate!.internCode != null) _row('Código de ${T.sujetoSingular.toLowerCase()}', _inmate!.internCode!),
                  if (widget.person.cdr != null) _row('CDR', widget.person.cdr!),
                  if (widget.person.defenseZone != null) _row('Zona de defensa', widget.person.defenseZone!),
                      _row('Centro', _inmate!.facility ?? '—'),
                      _row('Estado', _inmate!.status ?? '—'),
                      if (_inmate!.riskLevel != null) _row('Riesgo', _inmate!.riskLevel!),
                      if (_inmate!.notes != null && _inmate!.notes!.isNotEmpty) _row('Notas', _inmate!.notes!),
                    ]),
                  _section('Pases (${_passes.length})', [
                    for (final pass in _passes.take(10))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(children: [
                          Icon(Icons.circle, size: 10,
                              color: pass.isActive ? LexairColors.ok : LexairColors.muted),
                          const SizedBox(width: 6),
                          Expanded(child: Text(
                            '${pass.passTypeName ?? 'Pase'} · ${pass.state} · ${fmtDateIso(pass.startsAt)} → ${fmtDateIso(pass.endsAt)}',
                            style: const TextStyle(fontSize: 12))),
                        ]),
                      ),
                    if (_passes.isEmpty) Text('Sin ${T.pasePlural.toLowerCase()} registrados.',
                        style: const TextStyle(fontSize: 12, color: LexairColors.muted)),
                  ]),
                ]),
          const SizedBox(height: 8),
        ])),
      ),
      actions: [
        if (canWriteLocation) ...[
          TextButton.icon(
            key: const Key('kardex-mark-on-map'),
            icon: const Icon(Icons.my_location, size: 16),
            label: const Text('Marcar en el mapa'),
            onPressed: () {
              ws.startPickFor(_person);
              Navigator.of(context).pop();
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
            label: const Text('Coordenadas…'),
            onPressed: () async {
              final navigator = Navigator.of(context);
              final person = await showLocationDialog(context, _person, ws);
              if (person != null && navigator.mounted) navigator.pop(person);
            },
          ),
        ],
        if (canWritePersons)
          TextButton.icon(
            key: const Key('kardex-edit-person'),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Editar ficha'),
            onPressed: _editarFicha,
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cerrar')),
      ],
    );
  }

  static Widget _section(String title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: LexairColors.primary)),
      const SizedBox(height: 2),
      ...rows,
    ]),
  );

  static Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 130, child: Text(k, style: const TextStyle(fontSize: 12, color: LexairColors.muted))),
      Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
    ]),
  );
}
