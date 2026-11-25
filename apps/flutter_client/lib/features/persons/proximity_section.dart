import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/labels.dart';
import '../map/workspace_controller.dart';
import 'persons_repository.dart';

/// Radios configurables por el administrador (100 m … 5 km) y radio
/// personalizado si el rol lo permite. La consulta real es ST_DWithin.
class ProximitySection extends StatefulWidget {
  const ProximitySection({super.key});

  @override
  State<ProximitySection> createState() => _ProximitySectionState();
}

class _ProximitySectionState extends State<ProximitySection> {
  RadiusOptions? _opts;
  int? _radius;
  final _custom = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final o = await context.read<WorkspaceController>().persons.radii();
      if (mounted) setState(() => _opts = o);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    }
  }

  void _search(WorkspaceController ws, int r) {
    setState(() => _radius = r);
    unawaited(ws.searchNearby(r));
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final o = _opts;
    final res = ws.nearby;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Personas cercanas', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (o == null && _error == null) const LinearProgressIndicator(minHeight: 2),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
        if (o != null)
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final r in o.presets)
              ChoiceChip(
                key: Key('radius-$r'),
                label: Text(Labels.distance(r)),
                selected: _radius == r,
                onSelected: (_) => _search(ws, r),
              ),
          ]),
        if (o != null && o.customAllowed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _custom,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(isDense: true, labelText: 'Radio personalizado (m, máx. ${o.maxCustom})'),
                ),
              ),
              IconButton(
                tooltip: 'Buscar',
                icon: const Icon(Icons.search),
                onPressed: () {
                  final v = int.tryParse(_custom.text.trim());
                  if (v == null || v <= 0 || v > o.maxCustom) {
                    setState(() => _error = 'Radio entre 1 y ${o.maxCustom} m');
                    return;
                  }
                  _error = null;
                  _search(ws, v);
                },
              ),
            ]),
          ),
        if (ws.loadingNearby) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator(minHeight: 2)),
        if (ws.nearbyError != null) Text(ws.nearbyError!, style: const TextStyle(color: Colors.red)),
        if (res != null) ...[
          const SizedBox(height: 8),
          Text(
            '${res.page.total}${res.page.totalIsCapped ? '+' : ''} persona(s) en ${Labels.distance(res.radiusM)}'
            '${res.distancesRounded ? ' · distancias redondeadas' : ''}',
            key: const Key('nearby-count'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final p in res.page.items)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.circle, size: 12, color: Labels.groupColor(p.groups)),
              title: Text(p.fullName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${p.code} · ${p.groups.join('+')}'),
              trailing: Text(p.distanceM == null ? '' : Labels.distance(p.distanceM!)),
              onTap: () => ws.select(p),
            ),
          if (res.page.page > 1 || res.page.hasMore)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: res.page.page > 1 ? () => ws.searchNearby(res.radiusM, page: res.page.page - 1) : null,
              ),
              Text('Página ${res.page.page}'),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: res.page.hasMore ? () => ws.searchNearby(res.radiusM, page: res.page.page + 1) : null,
              ),
            ]),
        ],
      ],
    );
  }
}
