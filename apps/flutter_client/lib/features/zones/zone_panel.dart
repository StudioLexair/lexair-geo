import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../auth/auth_controller.dart';
import '../map/map_markers.dart' show fmtDateIso;
import '../map/map_view.dart';
import '../map/workspace_controller.dart';
import 'zone_assign_dialog.dart';
import '../../core/config/terminologia.dart';

/// Panel superpuesto a la derecha del mapa con el detalle de la zona
/// seleccionada: presos dentro (por residencia o asignación manual), personal
/// de la fuerza y pases que se cumplen en el área.
class ZonePanelOverlay extends StatelessWidget {
  const ZonePanelOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final z = ws.selectedZone;
    if (z == null) return const SizedBox.shrink();
    final user = context.watch<AuthController>().user;
    final canWrite = user?.can('zones.write') ?? false;
    final canAssign = user?.can('zones.assign') ?? false;
    final color = zoneColor(z);
    return Positioned(
      top: 12,
      right: 12,
      bottom: 12,
      width: 360,
      child: Card(
        elevation: 4,
        margin: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            color: color.withValues(alpha: 0.12),
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(z.name, style: Theme.of(context).textTheme.titleMedium),
                Text('Círculo/área · ${z.areaKm2?.toStringAsFixed(1) ?? '—'} km²'
                    '${z.category != null ? ' · ${z.category!.name}' : ''}',
                    style: const TextStyle(fontSize: 12, color: LexairColors.muted)),
              ])),
              IconButton(
                key: const Key('zone-close'),
                tooltip: 'Cerrar',
                icon: const Icon(Icons.close),
                onPressed: ws.clearZoneSelection,
              ),
            ]),
          ),
          if (ws.loadingZoneDetail)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [
              if (z.description != null && z.description!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(z.description!, style: const TextStyle(fontSize: 13)),
                ),
              if (z.label != null && z.label!.isNotEmpty)
                _row('Etiqueta', z.label!),
              _row('${T.sujetoPlural} dentro', '${z.membersCount} (manuales: ${z.manualCount})'),
              _row('${T.pasePlural} activos en el área', '${z.passesInside}'),
              _row('Personal asignado', '${z.personnelCount}'),
              const Divider(height: 20),
              _sectionTitle(context, '${T.sujetoPlural} en esta zona (${ws.zonePersons.length})'),
              for (final p in ws.zonePersons)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    p.onPass ? Icons.local_police : Icons.person_outline,
                    size: 20,
                    color: p.onPass ? LexairColors.groupB : LexairColors.muted,
                  ),
                  title: Text(p.name, style: const TextStyle(fontSize: 13)),
                  subtitle: Text([
                    p.code,
                    if (p.internCode != null) '${T.sujetoSingular} ${p.internCode}',
                    if (p.riskLevel != null) 'Riesgo ${p.riskLevel}',
                    if (p.phone != null) p.phone!,
                    if (p.viaGeometry && p.viaManual) 'vive dentro + asignado',
                    if (p.viaGeometry && !p.viaManual) 'vive dentro',
                    if (!p.viaGeometry && p.viaManual) 'asignado manualmente',
                  ].join(' · '), style: const TextStyle(fontSize: 12)),
                  onTap: () => ws.selectById(p.id),
                ),
              if (ws.zonePersons.isEmpty)
                const Text('Ningún preso dentro de esta zona.',
                    style: TextStyle(fontSize: 13, color: LexairColors.muted)),
              if (canAssign) ...[
                const SizedBox(height: 8),
                Row(children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.person_add_alt_1, size: 16),
                    label: const Text('Añadir presos'),
                    onPressed: () async {
                      await showZonePersonsAssignDialog(context, zone: z);
                      if (context.mounted) await ws.reloadZone(z.id);
                    },
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.format_line_spacing, size: 16),
                    label: const Text('Recalcular'),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        final r = await ws.zonesRepo.recompute(z.id);
                        messenger.showSnackBar(SnackBar(content: Text(
                          'Añadidas ${r.added}, quitadas ${r.removedStale} (por geometría)')));
                      } on ApiException catch (e) {
                        messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
                      }
                      if (context.mounted) await ws.reloadZone(z.id);
                    },
                  ),
                ]),
              ],
              const Divider(height: 20),
              _sectionTitle(context, 'Personal de la fuerza (asignado y cercano)'),
              for (final pe in ws.zonePersonnel)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.shield, size: 20, color: LexairColors.primary),
                  title: Text('${pe.rank != null ? '${pe.rank} ' : ''}${pe.name}',
                      style: const TextStyle(fontSize: 13)),
                  subtitle: Text([
                    if (pe.unit != null) pe.unit!,
                    if (pe.phone != null) pe.phone!,
                    if (pe.phoneAlt != null) 'Alt. ${pe.phoneAlt}',
                    if (pe.distanceM != null) Labels.distance(pe.distanceM!),
                    if (pe.assigned) 'asignado',
                    if (pe.insideZone && !pe.assigned) 'vive dentro',
                  ].join(' · '), style: const TextStyle(fontSize: 12)),
                ),
              if (ws.zonePersonnel.isEmpty)
                const Text('Sin personal asignado ni residente en el área.',
                    style: TextStyle(fontSize: 13, color: LexairColors.muted)),
              const Divider(height: 20),
              _sectionTitle(context, '${T.pasePlural} que se cumplen aquí'),
              for (final p in ws.zonePasses)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.circle, size: 12,
                      color: p.state == 'active' ? LexairColors.ok : LexairColors.muted),
                  title: Text(p.personName ?? '', style: const TextStyle(fontSize: 13)),
                  subtitle: Text([
                    _stateLabel(p.state),
                    if (p.authorizedHere == true) 'autorizado aquí',
                    'hasta ${fmtDateIso(p.endsAt)}',
                  ].join(' · '), style: const TextStyle(fontSize: 12)),
                  onTap: () => ws.selectById(p.personId),
                ),
              if (ws.zonePasses.isEmpty)
                Text('Sin ${T.pasePlural.toLowerCase()} en esta zona.',
                    style: const TextStyle(fontSize: 13, color: LexairColors.muted)),
              const Divider(height: 20),
              if (canWrite)
                Row(children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Eliminar zona'),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final ws2 = context.read<WorkspaceController>();
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Eliminar zona'),
                          content: Text('¿Eliminar «${z.name}»? Las personas asignadas no se borran.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
                            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Eliminar')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        try {
                          await ws2.zonesRepo.delete(z.id);
                          ws2.clearZoneSelection();
                          await ws2.refreshZones();
                          messenger.showSnackBar(const SnackBar(content: Text('Zona eliminada')));
                        } on ApiException catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
                        }
                      }
                    },
                  ),
                ]),
            ])),
        ]),
      ),
    );
  }

  static String _stateLabel(String state) => switch (state) {
    'active' => 'ACTIVO',
    'scheduled' => 'programado',
    'expired' => 'vencido',
    'returned' => 'devuelto',
    'cancelled' => 'cancelado',
    _ => state,
  };

  static Widget _sectionTitle(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(t, style: Theme.of(context).textTheme.titleSmall),
  );

  static Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      SizedBox(width: 170, child: Text(k, style: const TextStyle(color: LexairColors.muted, fontSize: 13))),
      Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
    ]),
  );
}
