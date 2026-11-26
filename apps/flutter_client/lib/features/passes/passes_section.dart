import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../map/map_markers.dart' show fmtDateIso;
import '../map/workspace_controller.dart';
import '../persons/person.dart';
import 'pass.dart';
import 'pass_form_dialog.dart';

/// Sección de internos y pases dentro de la ficha de una persona:
/// ficha de interno, lista de pases con su estado y acciones permitidas.
class PassesSection extends StatefulWidget {
  const PassesSection({super.key, required this.person});
  final Person person;

  @override
  State<PassesSection> createState() => _PassesSectionState();
}

class _PassesSectionState extends State<PassesSection> {
  bool _loading = true;
  Inmate? _inmate;
  List<Pass> _passes = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ws = context.read<WorkspaceController>();
    setState(() => _loading = true);
    try {
      final j = await ws.passesRepo.ofPerson(widget.person.id);
      if (!mounted) return;
      setState(() {
        _inmate = j['inmate'] == null ? null : Inmate.fromJson(j['inmate'] as Map<String, dynamic>);
        _passes = ((j['passes'] as List<dynamic>?) ?? const [])
            .cast<Map<String, dynamic>>().map(Pass.fromJson).toList();
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.isForbidden ? 'Sin permiso para consultar pases.' : e.userMessage;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().user;
    final canWrite = user?.can('passes.write') ?? false;
    final ws = context.read<WorkspaceController>();
    final messenger = ScaffoldMessenger.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Internos y pases', style: Theme.of(context).textTheme.titleSmall)),
        if (canWrite && _inmate == null)
          TextButton.icon(
            icon: const Icon(Icons.badge_outlined, size: 16),
            label: const Text('Registrar como interno'),
            onPressed: () async {
              final created = await showInmateFormDialog(context, person: widget.person);
              if (created) unawaited(_load());
            },
          ),
        IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh, size: 18), onPressed: _load),
      ]),
      const SizedBox(height: 6),
      if (_loading)
        const Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())
      else if (_error != null)
        Text(_error!, style: const TextStyle(fontSize: 13, color: LexairColors.danger))
      else ...[
        if (_inmate != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              Chip(
                label: Text('Interno ${_inmate!.internCode ?? '—'}',
                    style: const TextStyle(fontSize: 12)),
                backgroundColor: LexairColors.sidebar.withValues(alpha: 0.08),
                visualDensity: VisualDensity.compact,
              ),
              if (_inmate!.facility != null)
                Chip(label: Text(_inmate!.facility!, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact),
              if (_inmate!.status != null)
                Chip(label: Text(_inmate!.status!, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact),
              if (_inmate!.riskLevel != null)
                Chip(label: Text('Riesgo: ${_inmate!.riskLevel!}', style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact),
            ]),
          ),
        for (final p in _passes)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_stateIcon(p.state),
                size: 20, color: p.isActive ? LexairColors.ok : LexairColors.muted),
            title: Text([
              if (p.passTypeName != null) p.passTypeName!,
              p.state,
            ].join(' · '), style: const TextStyle(fontSize: 13)),
            subtitle: Text([
              'desde ${fmtDateIso(p.startsAt)}',
              'hasta ${fmtDateIso(p.endsAt)}',
              if (p.authorizedZoneName != null) 'zona: ${p.authorizedZoneName}',
              if (p.facility != null) p.facility!,
            ].join('\n'), style: const TextStyle(fontSize: 12)),
            isThreeLine: true,
            trailing: canWrite && (p.state == 'active' || p.state == 'scheduled')
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Registrar regreso',
                      icon: const Icon(Icons.login, size: 18),
                      onPressed: () async {
                        try {
                          await ws.passesRepo.markReturned(p.id);
                          messenger.showSnackBar(const SnackBar(content: Text('Pase cerrado (regreso registrado)')));
                          unawaited(_load());
                        } on ApiException catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Cancelar pase',
                      icon: const Icon(Icons.event_busy, size: 18),
                      onPressed: () async {
                        try {
                          await ws.passesRepo.cancel(p.id);
                          messenger.showSnackBar(const SnackBar(content: Text('Pase cancelado')));
                          unawaited(_load());
                        } on ApiException catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
                        }
                      },
                    ),
                  ])
                : null,
          ),
        if (_passes.isEmpty && _inmate != null)
          const Text('Sin pases registrados.', style: TextStyle(fontSize: 13, color: LexairColors.muted)),
        if (canWrite && _inmate != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.assignment_turned_in_outlined, size: 18),
              label: const Text('Conceder pase'),
              onPressed: () async {
                final created = await showPassFormDialog(context, person: widget.person);
                if (created) unawaited(_load());
              },
            ),
          ),
      ],
    ]);
  }

  static IconData _stateIcon(String state) => switch (state) {
    'active' => Icons.directions_walk,
    'scheduled' => Icons.schedule,
    'expired' => Icons.event_available,
    'returned' => Icons.login,
    'cancelled' => Icons.event_busy,
    _ => Icons.help_outline,
  };
}
