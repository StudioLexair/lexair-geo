import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../map/workspace_controller.dart';
import '../persons/person.dart';
import '../../core/config/terminologia.dart';
import 'pass.dart';

/// Diálogo de «Conceder pase» (fechas, tipo, zona autorizada, notas) y de
/// «Registrar como interno» (código de interno, centro, estado, riesgo).
/// Los estados y tipos provienen de catálogos configurables del servidor.
Future<bool> showPassFormDialog(BuildContext context, {required Person person}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => _PassFormDialog(person: person),
  );
  return r == true;
}

Future<bool> showInmateFormDialog(BuildContext context, {required Person person}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => _InmateFormDialog(person: person),
  );
  return r == true;
}

class _PassFormDialog extends StatefulWidget {
  const _PassFormDialog({required this.person});
  final Person person;

  @override
  State<_PassFormDialog> createState() => _PassFormDialogState();
}

class _PassFormDialogState extends State<_PassFormDialog> {
  final _facility = TextEditingController();
  final _address = TextEditingController();
  final _notes = TextEditingController();
  DateTime _start = DateTime.now();
  DateTime _end = DateTime.now().add(const Duration(days: 7));
  List<PassType> _types = const [];
  int? _typeId;
  List<Map<String, dynamic>> _zoneOptions = const [];
  String? _zoneId;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WorkspaceController>();
    try {
      final types = await ws.passesRepo.types();
      final zones = await ws.zonesRepo.list();
      if (!mounted) return;
      setState(() {
        _types = types;
        _typeId = types.isNotEmpty ? types.first.id : null;
        _zoneOptions = zones
            .map((z) => {'id': z.id, 'name': z.name, 'kind': z.kind})
            .toList();
      });
    } on ApiException {
      // Sin catálogo cargado el pase se crea sin tipo.
    }
  }

  @override
  void dispose() {
    _facility.dispose();
    _address.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (!mounted) return;
    final dt = time == null ? picked : DateTime(picked.year, picked.month, picked.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _start = dt;
        if (_end.isBefore(_start)) _end = _start.add(const Duration(days: 1));
      } else {
        _end = dt;
      }
    });
  }

  Future<void> _save() async {
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'La fecha de fin debe ser posterior al inicio');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final ws = context.read<WorkspaceController>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ws.passesRepo.create({
        'personId': widget.person.id,
        'passTypeId': _typeId,
        'facility': _facility.text.trim().isEmpty ? null : _facility.text.trim(),
        'startsAt': _start.toUtc().toIso8601String(),
        'endsAt': _end.toUtc().toIso8601String(),
        'authorizedZoneId': _zoneId,
        'authorizedAddress': _address.text.trim().isEmpty ? null : _address.text.trim(),
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      });
      messenger.showSnackBar(SnackBar(content: Text('${T.paseSingular} concedido')));
      navigator.pop(true);
    } on ApiException catch (e) {
      setState(() {
        _saving = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Conceder ${T.paseSingular.toLowerCase()} · ${widget.person.fullName}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<int>(
            initialValue: _typeId,
            isExpanded: true,
            decoration: InputDecoration(labelText: 'Tipo de ${T.paseSingular.toLowerCase()}'),
            items: [for (final t in _types) DropdownMenuItem(value: t.id, child: Text(t.name))],
            onChanged: (v) => setState(() {
              _typeId = v;
              final t = _types.where((x) => x.id == v).firstOrNull;
              if (t != null && _end.isBefore(DateTime.now())) {
                _end = _start.add(Duration(days: t.defaultDays));
              }
            }),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: InkWell(
              onTap: () => _pickDate(isStart: true),
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Desde'),
                child: Text(Labels.dateTime(_start)),
              ),
            )),
            const SizedBox(width: 8),
            Expanded(child: InkWell(
              onTap: () => _pickDate(isStart: false),
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Hasta'),
                child: Text(Labels.dateTime(_end)),
              ),
            )),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _zoneId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Zona autorizada (opcional)'),
            items: [
              const DropdownMenuItem(value: null, child: Text('— sin zona —')),
              for (final z in _zoneOptions)
                DropdownMenuItem(value: z['id'] as String, child: Text('${z['name']}')),
            ],
            onChanged: (v) => setState(() => _zoneId = v),
          ),
          const SizedBox(height: 8),
          TextField(controller: _address, decoration: const InputDecoration(labelText: 'Dirección autorizada (opcional)')),
          const SizedBox(height: 8),
          TextField(controller: _facility, decoration: const InputDecoration(labelText: 'Centro penitenciario (opcional)')),
          const SizedBox(height: 8),
          TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notas (opcional)')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: LexairColors.danger)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Guardando…' : 'Conceder')),
      ],
    );
  }
}

class _InmateFormDialog extends StatefulWidget {
  const _InmateFormDialog({required this.person});
  final Person person;

  @override
  State<_InmateFormDialog> createState() => _InmateFormDialogState();
}

class _InmateFormDialogState extends State<_InmateFormDialog> {
  final _internCode = TextEditingController();
  final _facility = TextEditingController();
  final _notes = TextEditingController();
  String? _status;
  String? _risk;
  List<String> _statuses = const [];
  List<String> _risks = const [];
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Estados y niveles de riesgo configurables en el servidor
    // (claves inmate.statuses e inmate.risk_levels de la administración).
    final ws = context.read<WorkspaceController>();
    try {
      final opts = await ws.passesRepo.options();
      if (!mounted) return;
      setState(() {
        _statuses = ((opts['statuses'] as List<dynamic>?) ?? const []).cast<String>();
        _risks = ((opts['riskLevels'] as List<dynamic>?) ?? const []).cast<String>();
        _status = _statuses.isNotEmpty ? _statuses.first : null;
        _risk = _risks.isNotEmpty ? _risks.first : null;
      });
    } on ApiException {
      _statuses = const ['Internado', 'En pase', 'Excarcelado', 'Libertad condicional'];
      _risks = const ['Bajo', 'Medio', 'Alto', 'Máximo'];
      if (!mounted) return;
      setState(() {
        _status = _statuses.first;
        _risk = _risks.first;
      });
    }
  }

  @override
  void dispose() {
    _internCode.dispose();
    _facility.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ws = context.read<WorkspaceController>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ws.passesRepo.registerInmate(widget.person.id, {
        'internCode': _internCode.text.trim().isEmpty ? null : _internCode.text.trim().toUpperCase(),
        'facility': _facility.text.trim().isEmpty ? null : _facility.text.trim(),
        'status': _status,
        'riskLevel': _risk,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      });
      messenger.showSnackBar(SnackBar(content: Text('Registrada como ${T.sujetoSingular.toLowerCase()}')));
      navigator.pop(true);
    } on ApiException catch (e) {
      setState(() {
        _saving = false;
        _error = e.userMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Registrar como ${T.sujetoSingular.toLowerCase()} · ${widget.person.fullName}'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _internCode,
            decoration: const InputDecoration(labelText: 'Código (opcional)'),
          ),
          const SizedBox(height: 8),
          TextField(controller: _facility, decoration: const InputDecoration(labelText: 'Centro penitenciario')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _status,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Estado'),
            items: [for (final s in _statuses) DropdownMenuItem(value: s, child: Text(s))],
            onChanged: (v) => setState(() => _status = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _risk,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Nivel de riesgo'),
            items: [for (final r in _risks) DropdownMenuItem(value: r, child: Text(r))],
            onChanged: (v) => setState(() => _risk = v),
          ),
          const SizedBox(height: 8),
          TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notas (opcional)')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: LexairColors.danger)),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Guardando…' : 'Registrar')),
      ],
    );
  }
}

