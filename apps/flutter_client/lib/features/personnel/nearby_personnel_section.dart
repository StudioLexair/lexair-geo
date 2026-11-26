import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../map/workspace_controller.dart';
import '../persons/person.dart';

/// «¿Quién de la fuerza vive cerca de este preso?» — lista ordenada por
/// distancia con grado, unidad y teléfonos. El radio es configurable en el
/// servidor (personnel.near_radius_m).
class NearbyPersonnelSection extends StatefulWidget {
  const NearbyPersonnelSection({super.key, required this.person});
  final Person person;

  @override
  State<NearbyPersonnelSection> createState() => _NearbyPersonnelSectionState();
}

class _NearbyPersonnelSectionState extends State<NearbyPersonnelSection> {
  bool _loading = true;
  List<_NearbyRow> _rows = const [];
  int _radius = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WorkspaceController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final j = await ws.personnelRepo.nearPerson(widget.person.id);
      if (!mounted) return;
      setState(() {
        _rows = ((j['items'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(_NearbyRow.fromJson)
            .toList();
        _radius = (j['radiusM'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isForbidden ? 'Sin permiso para consultar el personal cercano.' : e.userMessage;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(
          'Personal de la fuerza cerca${_radius > 0 ? ' (residencia a $_radius m o menos)' : ''}',
          style: Theme.of(context).textTheme.titleSmall)),
        IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
      ]),
      const SizedBox(height: 6),
      if (_loading)
        const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
      else if (_error != null)
        Text(_error!, style: const TextStyle(fontSize: 13, color: LexairColors.danger))
      else if (_rows.isEmpty)
        const Text('No hay personal con residencia cerca de esta ubicación.',
            style: TextStyle(fontSize: 13, color: LexairColors.muted))
      else
        for (final r in _rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.shield, size: 20, color: LexairColors.primary),
            title: Text('${r.rank != null ? '${r.rank} ' : ''}${r.fullName}',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text([
              if (r.unit != null) r.unit!,
              if (r.phone != null) r.phone!,
              if (r.phoneAlt != null) 'Alt. ${r.phoneAlt}',
              if (r.distanceM != null) Labels.distance(r.distanceM!),
            ].join(' · '), style: const TextStyle(fontSize: 12)),
          ),
    ]);
  }
}

class _NearbyRow {
  const _NearbyRow({required this.fullName, this.rank, this.unit, this.phone, this.phoneAlt, this.distanceM});
  final String fullName;
  final String? rank;
  final String? unit;
  final String? phone;
  final String? phoneAlt;
  final num? distanceM;

  factory _NearbyRow.fromJson(Map<String, dynamic> j) => _NearbyRow(
    fullName: (j['fullName'] ?? j['full_name'] ?? '') as String,
    rank: j['rank'] as String?,
    unit: j['unit'] as String?,
    phone: j['phone'] as String?,
    phoneAlt: (j['phoneAlt'] ?? j['phone_alt']) as String?,
    distanceM: j['distanceM'] as num?,
  );
}
