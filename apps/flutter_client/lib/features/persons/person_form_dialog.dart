import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/labels.dart';
import '../auth/auth_controller.dart';
import '../map/workspace_controller.dart';
import 'person.dart';

/// Alta o edición de una persona. Los grupos se gestionan como
/// pertenencias (una persona puede estar en A, B o ambos sin duplicarse).
Future<Person?> showPersonFormDialog(BuildContext context, Person? existing) =>
    showDialog<Person>(context: context, builder: (_) => _PersonFormDialog(existing: existing));

class _PersonFormDialog extends StatefulWidget {
  const _PersonFormDialog({this.existing});
  final Person? existing;

  @override
  State<_PersonFormDialog> createState() => _PersonFormDialogState();
}

class _PersonFormDialogState extends State<_PersonFormDialog> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(text: widget.existing?.code);
  late final _given = TextEditingController(text: widget.existing?.givenNames);
  late final _family = TextEditingController(text: widget.existing?.familyNames);
  late final _phone = TextEditingController(text: widget.existing?.phone);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late final _source = TextEditingController(text: widget.existing?.dataSource ?? 'registro_manual');
  late Set<String> _groups = {...?widget.existing?.groups};
  late String _consent = widget.existing?.consentStatus ?? 'pending';
  late String _visibility = widget.existing?.visibility ?? 'normal';
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    for (final c in [_code, _given, _family, _phone, _notes, _source]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (_groups.isEmpty) {
      setState(() => _error = 'Seleccione al menos un grupo');
      return;
    }
    final repo = context.read<WorkspaceController>().persons;
    final canGroups = context.read<AuthController>().user?.can('groups.manage') ?? false;
    final body = <String, dynamic>{
      'givenNames': _given.text.trim(),
      'familyNames': _family.text.trim(),
      'phone': _opt(_phone),
      'notes': _opt(_notes),
      'consentStatus': _consent,
      'visibility': _visibility,
      'dataSource': _source.text.trim(),
    };
    setState(() => _busy = true);
    try {
      Person p;
      if (_isNew) {
        p = await repo.create({...body, 'code': _code.text.trim().toUpperCase(), 'groups': _groups.toList()});
      } else {
        p = await repo.update(widget.existing!.id, body);
        final changed = _groups.length != p.groups.length || !_groups.containsAll(p.groups);
        if (changed && canGroups) p = await repo.setGroups(p.id, _groups.toList()..sort());
      }
      if (mounted) Navigator.of(context).pop(p);
    } on ApiException catch (e) {
      setState(() {
        _busy = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.read<AuthController>().user;
    final canGroups = _isNew || (user?.can('groups.manage') ?? false);
    return AlertDialog(
      title: Text(_isNew ? 'Nueva persona' : 'Editar ${widget.existing!.code}'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_isNew)
                TextFormField(
                  key: const Key('pf-code'),
                  controller: _code,
                  decoration: const InputDecoration(labelText: 'Código *'),
                  validator: (v) => RegExp(r'^[A-Z0-9][A-Z0-9-]{2,31}$').hasMatch((v ?? '').trim().toUpperCase())
                      ? null
                      : '3–32 caracteres: A-Z, 0-9 o guion',
                ),
              TextFormField(key: const Key('pf-given'), controller: _given,
                  decoration: const InputDecoration(labelText: 'Nombre(s) *'), validator: _req),
              TextFormField(key: const Key('pf-family'), controller: _family,
                  decoration: const InputDecoration(labelText: 'Apellidos *'), validator: _req),
              TextFormField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Teléfono'),
                validator: (v) => (v ?? '').trim().isEmpty || RegExp(r'^[0-9 +()-]{5,25}$').hasMatch(v!.trim())
                    ? null
                    : 'Formato no válido',
              ),
              TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notas')),
              TextFormField(controller: _source, decoration: const InputDecoration(labelText: 'Fuente del dato *'),
                  validator: (v) => (v ?? '').trim().length < 2 ? 'Obligatoria' : null),
              const SizedBox(height: 12),
              Row(children: [
                const Text('Grupos: '),
                for (final g in const ['A', 'B'])
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: FilterChip(
                      key: Key('pf-group-$g'),
                      label: Text('Grupo $g'),
                      selected: _groups.contains(g),
                      onSelected: canGroups
                          ? (s) => setState(() => _groups = s ? ({..._groups, g}) : ({..._groups}..remove(g)))
                          : null,
                    ),
                  ),
              ]),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _consent,
                    decoration: const InputDecoration(labelText: 'Consentimiento'),
                    items: [for (final e in Labels.consent.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                    onChanged: (v) => _consent = v ?? _consent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _visibility,
                    decoration: const InputDecoration(labelText: 'Visibilidad'),
                    items: const [
                      DropdownMenuItem(value: 'normal', child: Text('Normal')),
                      DropdownMenuItem(value: 'restricted', child: Text('Restringida')),
                    ],
                    onChanged: (v) => _visibility = v ?? _visibility,
                  ),
                ),
              ]),
              if (_error != null)
                Padding(padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, style: const TextStyle(color: Colors.red))),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(key: const Key('pf-save'), onPressed: _busy ? null : _save, child: const Text('Guardar')),
      ],
    );
  }

  static String? _req(String? v) => (v ?? '').trim().isEmpty ? 'Obligatorio' : null;
}
