import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/net/api_client.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../persons/person.dart';
import '../persons/persons_repository.dart';
import '../map/workspace_controller.dart';
import 'zone.dart';
import 'zones_repository.dart';

/// Flujo tras terminar un dibujo: nombra la zona, elige categoría, color,
/// etiqueta y estilo; guarda; y opcionalmente asigna presos (manualmente o
/// recalculando por geometría). Todo lo que pide el servidor es configurable.
Future<void> showZoneAssignDialog(BuildContext context, {required ZoneGeometrySpec spec}) async {
  final ws = context.read<WorkspaceController>();
  final api = context.read<AppServices>().api;
  final zonesRepo = ZonesRepository(api);
  final canWrite = context.read<AuthController>().user?.can('zones.write') ?? false;
  if (!canWrite) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Su rol no permite crear zonas (permiso zones.write)')));
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _ZoneAssignDialog(ws: ws, spec: spec, zonesRepo: zonesRepo),
  );
}

class _ZoneAssignDialog extends StatefulWidget {
  const _ZoneAssignDialog({required this.ws, required this.spec, required this.zonesRepo});
  final WorkspaceController ws;
  final ZoneGeometrySpec spec;
  final ZonesRepository zonesRepo;

  @override
  State<_ZoneAssignDialog> createState() => _ZoneAssignDialogState();
}

class _ZoneAssignDialogState extends State<_ZoneAssignDialog> {
  final _name = TextEditingController();
  final _label = TextEditingController();
  final _description = TextEditingController();
  List<ZoneCategory> _categories = const [];
  int? _categoryId;
  String _color = '#0F6C81';
  final List<String> _palette = const ['#1565C0', '#C62828', '#2E7D32', '#EF8F00', '#6A1B9A'];
  bool _showLabel = true;
  bool _saving = false;
  String? _error;
  Zone? _created;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final cats = await widget.zonesRepo.categories();
      // La paleta configurable vive en la administración (zones.palette).
      if (!mounted) return;
      setState(() {
        _categories = cats;
        _categoryId = cats.isNotEmpty ? cats.first.id : null;
        if (cats.isNotEmpty) _color = cats.first.colorHex;
      });
    } on ApiException {
      // Sin categorías configuradas sigue siendo posible crear la zona.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _label.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'El nombre es obligatorio');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final zone = await widget.zonesRepo.create({
        'name': _name.text.trim(),
        'description': _description.text.trim().isEmpty ? null : _description.text.trim(),
        'geometry': widget.spec.toJson(),
        'labelText': _label.text.trim().isEmpty ? null : _label.text.trim(),
        'showLabel': _showLabel,
        'categoryId': _categoryId,
        'colorHex': _color,
        'isActive': true,
      });
      widget.ws.pendingZoneSpec = null;
      if (!mounted) return;
      setState(() {
        _created = zone;
        _saving = false;
      });
      await widget.ws.refreshZones();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Zona «${zone.name}» creada')));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = _created;
    return AlertDialog(
      title: Text(z == null ? 'Asignar área dibujada' : 'Área «${z.name}»'),
      content: SizedBox(
        width: 460,
        child: z == null ? _form() : _afterCreate(z),
      ),
      actions: z == null
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Descartar dibujo'),
              ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Guardando…' : 'Guardar zona'),
              ),
            ]
          : [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Listo'))],
    );
  }

  Widget _form() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Nombre del área *'),
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _label,
      decoration: const InputDecoration(labelText: 'Texto sobre el mapa (opcional)'),
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _description,
      maxLines: 2,
      decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
    ),
    const SizedBox(height: 8),
    DropdownButtonFormField<int>(
      initialValue: _categoryId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Categoría'),
      items: [
        for (final c in _categories) DropdownMenuItem(value: c.id, child: Text(c.name)),
      ],
      onChanged: (v) => setState(() {
        _categoryId = v;
        final c = _categories.where((x) => x.id == v).firstOrNull;
        if (c != null) _color = c.colorHex;
      }),
    ),
    const SizedBox(height: 8),
    Row(children: [
      const Text('Color:'),
      const SizedBox(width: 8),
      for (final hex in _palette)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: InkWell(
            onTap: () => setState(() => _color = hex),
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _colorFromHex(hex) ?? LexairColors.primary,
                shape: BoxShape.circle,
                border: Border.all(
                  color: _color == hex ? LexairColors.ink : Colors.white,
                  width: _color == hex ? 2.5 : 1,
                ),
              ),
            ),
          ),
        ),
      const Spacer(),
      Switch(
        value: _showLabel,
        onChanged: (v) => setState(() => _showLabel = v),
      ),
      const Text('Etiqueta visible'),
    ]),
    if (_error != null)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(_error!, style: const TextStyle(color: LexairColors.danger)),
      ),
  ]);

  /// Tras crear: asignar presos manualmente o recalculando por geometría.
  Widget _afterCreate(Zone zone) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('Zona creada (${zone.areaKm2 != null ? '${zone.areaKm2!.toStringAsFixed(1)} km²' : '—'})'),
    const SizedBox(height: 10),
    Row(children: [
      Expanded(child: OutlinedButton.icon(
        icon: const Icon(Icons.format_line_spacing, size: 18),
        label: const Text('Recalcular por geometría'),
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            final r = await widget.zonesRepo.recompute(zone.id);
            messenger.showSnackBar(SnackBar(
              content: Text('Asignadas por vivir dentro: ${r.added} · obsoletas quitadas: ${r.removedStale}')));
          } on ApiException catch (e) {
            messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
          }
          if (context.mounted) await widget.ws.reloadZone(zone.id);
        },
      )),
    ]),
    const SizedBox(height: 8),
    const Text('También puede añadir o quitar presos manualmente desde el panel de la zona.',
        style: TextStyle(fontSize: 12, color: LexairColors.muted)),
  ]);

  static Color? _colorFromHex(String hex) {
    if (hex.length == 7 && hex.startsWith('#')) {
      final v = int.tryParse(hex.substring(1), radix: 16);
      if (v != null) return Color(0xFF000000 | v);
    }
    return null;
  }
}

/// Diálogo para buscar y asignar presos a una zona (uso desde el panel).
Future<void> showZonePersonsAssignDialog(BuildContext context, {required Zone zone}) async {
  final api = context.read<AppServices>().api;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _AssignPersonsDialog(api: api, zone: zone),
  );
}

class _AssignPersonsDialog extends StatefulWidget {
  const _AssignPersonsDialog({required this.api, required this.zone});
  final ApiClient api;
  final Zone zone;

  @override
  State<_AssignPersonsDialog> createState() => _AssignPersonsDialogState();
}

class _AssignPersonsDialogState extends State<_AssignPersonsDialog> {
  final _q = TextEditingController();
  final _selected = <String, Person>{};
  List<Person> _results = const [];
  bool _loading = false;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _loading = true);
    final repo = PersonsRepository(widget.api);
    try {
      final page = await repo.search(q: _q.text.trim().isEmpty ? null : _q.text.trim(), pageSize: 20);
      if (!mounted) return;
      setState(() {
        _results = page.items;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  Future<void> _assign() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final repo = ZonesRepository(widget.api);
    try {
      final r = await repo.assignPersons(widget.zone.id, add: _selected.keys.toList());
      messenger.showSnackBar(SnackBar(content: Text('Asignadas ${r.added} persona(s) a «${widget.zone.name}»')));
      navigator.pop();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Añadir presos a «${widget.zone.name}»'),
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(children: [
          Row(children: [
            Expanded(child: TextField(
              controller: _q,
              decoration: const InputDecoration(labelText: 'Buscar por nombre, código o dirección'),
              onSubmitted: (_) => _search(),
            )),
            const SizedBox(width: 8),
            IconButton(icon: const Icon(Icons.search), onPressed: _search),
          ]),
          const SizedBox(height: 8),
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: [
                for (final p in _results)
                  CheckboxListTile(
                    dense: true,
                    value: _selected.containsKey(p.id),
                    title: Text(p.fullName),
                    subtitle: Text('${p.code}${p.location?.addressText != null ? ' · ${p.location!.addressText}' : ''}'),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected[p.id] = p;
                      } else {
                        _selected.remove(p.id);
                      }
                    }),
                  ),
                if (_results.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Busque personas para añadirlas a la zona.'),
                  ),
              ])),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _selected.isEmpty ? null : _assign,
          child: Text('Añadir ${_selected.length}'),
        ),
      ],
    );
  }
}
