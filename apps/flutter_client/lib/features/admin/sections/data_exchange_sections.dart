import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/net/api_exception.dart';
import '../admin_repository.dart';
import '../admin_widgets.dart';

/// 6. Importación CSV: primero validación (dry-run) y luego importación.
class ImportSection extends StatefulWidget {
  const ImportSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  State<ImportSection> createState() => _ImportSectionState();
}

class _ImportSectionState extends State<ImportSection> {
  String? _filename;
  String? _csv;
  String? _xml;
  String _group = 'A';
  Json? _result;
  Json? _xmlResult;
  String? _error;
  bool _busy = false;

  Future<void> _pick() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['csv']);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (bytes.length > 20 * 1024 * 1024) {
      setState(() => _error = 'El fichero supera 20 MB');
      return;
    }
    setState(() {
      _filename = f.name;
      _csv = utf8.decode(bytes, allowMalformed: false);
      _result = null;
      _error = null;
    });
  }

  /// Libro de reclusos en pase (Excel XML exportado por el registro).
  Future<void> _pickXml() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['xml']);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (bytes.length > 30 * 1024 * 1024) {
      setState(() => _error = 'El fichero supera 30 MB');
      return;
    }
    setState(() {
      _filename = f.name;
      _xml = utf8.decode(bytes, allowMalformed: true);
      _xmlResult = null;
      _error = null;
    });
  }

  Future<void> _sendXml(bool dryRun) async {
    setState(() => _busy = true);
    try {
      final r = await widget.repo.importReclusosXml(_xml!, group: _group, dryRun: dryRun, filename: _filename!);
      setState(() => _xmlResult = r);
    } on ApiException catch (e) {
      setState(() => _error = e.userMessage);
    } on FormatException {
      setState(() => _error = 'El fichero no está en UTF-8');
    }
    setState(() => _busy = false);
  }

  Future<void> _send(bool dryRun) async {
    setState(() => _busy = true);
    try {
      final r = await widget.repo.importCsv(_csv!, group: _group, dryRun: dryRun, filename: _filename!);
      setState(() => _result = r);
    } on ApiException catch (e) {
      setState(() => _error = e.userMessage);
    } on FormatException {
      setState(() => _error = 'El fichero no está en UTF-8');
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final errors = r == null ? const <Json>[] : itemsOf(r, 'errors');
    final x = _xmlResult;
    final xErrors = x == null ? const <Json>[] : itemsOf(x, 'errors');
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text('Importar reclusos en pase (Excel XML)', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Libro exportado por el registro penitenciario (hojas Hoja1 y '
          'BBDD_CON_DIRECCION). Reconoce NIDENTIDAD, nombres, apellidos, fecha de ingreso, '
          'unidad, provincia, municipio, consejo popular, CDR y dirección. Crea la ficha de '
          'interno de cada persona y deja su ubicación por municipio; luego se precisa '
          'arrastrando la ficha del kardex al mapa.'),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(
          key: const Key('pick-reclusos-xml'),
          onPressed: _pickXml,
          icon: const Icon(Icons.table_view),
          label: const Text('Elegir libro XML'),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(_xml != null ? (_filename ?? '') : 'Ningún libro seleccionado')),
        DropdownButton<String>(
          value: _group,
          items: const [
            DropdownMenuItem(value: 'A', child: Text('Grupo A')),
            DropdownMenuItem(value: 'B', child: Text('Grupo B')),
          ],
          onChanged: (v) => setState(() => _group = v ?? 'A'),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton(
          key: const Key('validate-reclusos-xml'),
          onPressed: _xml == null || _busy ? null : () => _sendXml(true),
          child: const Text('1. Validar'),
        ),
        const SizedBox(width: 12),
        FilledButton(
          key: const Key('import-reclusos-xml'),
          onPressed: x == null || x['dryRun'] != true || (x['okRows'] as num) == 0 || _busy
              ? null : () => _sendXml(false),
          child: const Text('2. Importar reclusos'),
        ),
      ]),
      if (x != null) ...[
        const SizedBox(height: 12),
        Text('${x['dryRun'] == true ? 'Validación' : 'Importación'}: ${x['status']} · '
            'hoja usada: ${x['sheet']} · ${x['totalRows']} filas · ${x['okRows']} válidas · '
            '${x['inmates']} internos · ${x['located']} ubicadas por municipio · ${x['errorRows']} con avisos'),
        for (final e in xErrors.take(50))
          Text('Fila ${e['row']}: ${e['message'] ?? e['reason']}', style: const TextStyle(fontSize: 12)),
      ],
      const Divider(height: 40),
      Text('Importar personas (CSV)', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('Columnas obligatorias: code, given_names, family_names, data_source. Opcionales: phone, '
          'notes, cdr, defense_zone, lat, lon, address_text, municipality, precision_level, '
          'consent_status. Codificación UTF-8; máximo 50 000 filas. Las ubicaciones importadas '
          'nunca quedan como «exacta verificada».'),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton.icon(onPressed: _pick, icon: const Icon(Icons.attach_file), label: const Text('Elegir CSV')),
        const SizedBox(width: 12),
        Expanded(child: Text(_filename ?? 'Ningún fichero seleccionado')),
        DropdownButton<String>(
          value: _group,
          items: const [
            DropdownMenuItem(value: 'A', child: Text('Grupo A')),
            DropdownMenuItem(value: 'B', child: Text('Grupo B')),
          ],
          onChanged: (v) => setState(() => _group = v ?? 'A'),
        ),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        OutlinedButton(onPressed: _csv == null || _busy ? null : () => _send(true), child: const Text('1. Validar')),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: r == null || r['dryRun'] != true || (r['okRows'] as num) == 0 || _busy ? null : () => _send(false),
          child: const Text('2. Importar filas válidas'),
        ),
      ]),
      if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
          child: Text(_error!, style: const TextStyle(color: Colors.red))),
      if (r != null) ...[
        const SizedBox(height: 16),
        Text('${r['dryRun'] == true ? 'Validación' : 'Importación'}: ${r['status']} · '
            '${r['totalRows']} filas · ${r['okRows']} válidas · ${r['errorRows']} con errores'),
        for (final e in errors.take(100))
          Text('Línea ${e['line']}${e['code'] == null ? '' : ' (${e['code']})'}: '
              '${((e['errors'] as List<dynamic>?) ?? const []).join('; ')}', style: const TextStyle(fontSize: 12)),
      ],
    ]);
  }
}

/// 7. Historial de importaciones.
class ImportHistorySection extends StatelessWidget {
  const ImportHistorySection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
    title: 'Historial de importaciones',
    load: repo.imports,
    builder: (context, items, _) => items.isEmpty
        ? const Center(child: Text('Sin importaciones'))
        : ListView(children: [
            for (final j in items)
              ListTile(
                dense: true,
                leading: Icon(j['dryRun'] == true ? Icons.rule : Icons.upload_file),
                title: Text('${j['filename']} → Grupo ${j['targetGroup']} · ${j['status']}'),
                subtitle: Text('${fmtDate(j['createdAt'])} · ${j['createdBy'] ?? ''} · '
                    '${j['okRows']}/${j['totalRows']} válidas · ${j['errorRows']} errores'
                    '${j['dryRun'] == true ? ' · solo validación' : ''}'),
              ),
          ]),
  );
}

/// 8. Exportación CSV autorizada (auditada en el servidor, máx. 50 000 filas).
class ExportSection extends StatefulWidget {
  const ExportSection({super.key, required this.repo});
  final AdminRepository repo;

  @override
  State<ExportSection> createState() => _ExportSectionState();
}

class _ExportSectionState extends State<ExportSection> {
  String _groups = 'A,B';
  bool _inactive = false;
  String? _msg;

  Future<void> _export() async {
    setState(() => _msg = 'Generando…');
    try {
      final csv = await widget.repo.exportCsv({'groups': _groups, 'includeInactive': '$_inactive'});
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final uri = await FilePicker.saveFile(
        fileName: 'lexair_personas_$stamp.csv',
        bytes: Uint8List.fromList(utf8.encode(csv)),
        mimeType: 'text/csv',
      );
      setState(() => _msg = uri == null ? 'Exportación cancelada' : 'Exportación guardada');
    } on ApiException catch (e) {
      setState(() => _msg = e.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(20), children: [
    Text('Exportar personas (CSV)', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 8),
    const Text('Solo se exportan los grupos y campos que su rol permite ver. Cada exportación queda '
        'registrada en la auditoría. Trate el fichero como información sensible.'),
    Row(children: [
      DropdownButton<String>(
        value: _groups,
        items: const [
          DropdownMenuItem(value: 'A,B', child: Text('Grupos A y B')),
          DropdownMenuItem(value: 'A', child: Text('Grupo A')),
          DropdownMenuItem(value: 'B', child: Text('Grupo B')),
        ],
        onChanged: (v) => setState(() => _groups = v ?? 'A,B'),
      ),
      const SizedBox(width: 16),
      Checkbox(value: _inactive, onChanged: (v) => setState(() => _inactive = v ?? false)),
      const Text('Incluir inactivas'),
    ]),
    const SizedBox(height: 12),
    Align(alignment: Alignment.centerLeft,
        child: FilledButton.icon(onPressed: _export, icon: const Icon(Icons.download), label: const Text('Exportar'))),
    if (_msg != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_msg!)),
  ]);
}
