import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../map/workspace_controller.dart';
import 'geocoding_repository.dart';

/// Búsqueda de direcciones en el catálogo local (OSM + alias + datos
/// administrados). Si no hay coincidencias lo dice: nunca inventa puntos.
class AddressSearchPanel extends StatefulWidget {
  const AddressSearchPanel({super.key});

  @override
  State<AddressSearchPanel> createState() => _AddressSearchPanelState();
}

class _AddressSearchPanelState extends State<AddressSearchPanel> {
  final _q = TextEditingController();
  List<GeocodeResult>? _items;
  String? _error;
  bool _loading = false;
  Map<String, dynamic>? _reverse;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final text = _q.text.trim();
    if (text.length < 2) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await context.read<WorkspaceController>().geocoding.search(text);
      if (mounted) setState(() => _items = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _describeProvisional(WorkspaceController ws) async {
    final p = ws.provisional;
    if (p == null) return;
    try {
      final r = await ws.geocoding.reverse(p);
      if (mounted) setState(() => _reverse = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final items = _items;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        TextField(
          key: const Key('address-search'),
          controller: _q,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: 'Calle, número, localidad o lugar',
            prefixIcon: const Icon(Icons.signpost_outlined),
            isDense: true,
            suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilterChip(
            key: const Key('pick-mode'),
            avatar: const Icon(Icons.ads_click, size: 16),
            label: const Text('Elegir en mapa'),
            selected: ws.pickMode,
            onSelected: ws.setPickMode,
          ),
          const Spacer(),
          if (ws.provisional != null)
            TextButton(onPressed: () => ws.setProvisional(null), child: const Text('Quitar marcador')),
        ]),
        if (ws.provisional != null) _provisionalCard(ws),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
        if (items != null && items.isEmpty)
          const Padding(
            key: Key('address-not-found'),
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Dirección no encontrada en el catálogo local. Puede situarla manualmente '
                'con «Elegir en mapa»; quedará como pendiente de verificar.'),
          ),
        for (final r in items ?? const <GeocodeResult>[])
          Card(
            margin: const EdgeInsets.only(top: 6),
            child: ListTile(
              dense: true,
              title: Text(r.label),
              subtitle: Text([
                Labels.of(Labels.granularity, r.granularity),
                if (r.locality != null) r.locality!,
                if (r.municipality != null) r.municipality!,
                'confianza ${(r.confidence * 100).round()} %',
                if (r.isSynthetic) 'DATO SINTÉTICO',
                if (r.note != null) r.note!,
              ].join(' · ')),
              trailing: const Icon(Icons.my_location, size: 18),
              onTap: () {
                ws.setProvisional(r.point, source: r, center: true);
                setState(() => _reverse = null);
              },
            ),
          ),
        const SizedBox(height: 12),
        Text('Fuente: catálogo local derivado de © OpenStreetMap contributors (ODbL) y datos administrados.',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _provisionalCard(WorkspaceController ws) {
    final p = ws.provisional!;
    final rev = _reverse;
    String? name(Object? o) => o is Map<String, dynamic> ? (o['name'] ?? o['label']) as String? : null;
    return Card(
      color: const Color(0xFFFFF8E1),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Marcador provisional', style: TextStyle(fontWeight: FontWeight.w600)),
          Text('${Labels.coord(p.latitude)}, ${Labels.coord(p.longitude)}',
              style: const TextStyle(fontSize: 12, color: LexairColors.muted)),
          if (ws.provisionalSource != null) Text(ws.provisionalSource!.label, style: const TextStyle(fontSize: 12)),
          if (rev != null)
            Text([
              'Municipio: ${name(rev['municipality']) ?? 'desconocido'}',
              'Localidad: ${name(rev['locality']) ?? '—'}',
              'Dirección cercana: ${name(rev['nearestAddress']) ?? '—'}',
            ].join('\n'), style: const TextStyle(fontSize: 12)),
          Row(children: [
            TextButton(onPressed: () => _describeProvisional(ws), child: const Text('¿Qué hay aquí?')),
            TextButton(onPressed: () => ws.centerOn(p), child: const Text('Centrar')),
          ]),
          Text(ws.selected == null
              ? 'Seleccione una persona y use «Asignar ubicación» para guardarlo.'
              : 'Use «Cambiar ubicación» en la ficha de ${ws.selected!.code} para guardarlo.',
              style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}
