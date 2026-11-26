import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/net/api_exception.dart';
import '../../core/theme/app_theme.dart';
import '../../core/util/labels.dart';
import '../auth/auth_controller.dart';
import '../map/workspace_controller.dart';
import '../passes/passes_section.dart';
import '../personnel/nearby_personnel_section.dart';
import 'location_dialog.dart';
import 'person.dart';
import 'person_form_dialog.dart';
import 'proximity_section.dart';

/// Ficha de la persona seleccionada: datos, ubicación con su procedencia y
/// precisión, acciones permitidas y consulta de proximidad.
class PersonDetailPanel extends StatelessWidget {
  const PersonDetailPanel({super.key});

  Future<void> _act(BuildContext context, Future<Person> Function() f, String ok) async {
    final ws = context.read<WorkspaceController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      ws.replaceSelected(await f());
      messenger.showSnackBar(SnackBar(content: Text(ok)));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final user = context.watch<AuthController>().user;
    final p = ws.selected!;
    final loc = p.location;
    final can = user?.can ?? (_) => false;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(children: [
          IconButton(
            key: const Key('detail-back'),
            tooltip: 'Volver a resultados',
            icon: const Icon(Icons.arrow_back),
            onPressed: ws.clearSelection,
          ),
          Expanded(child: Text(p.fullName, style: Theme.of(context).textTheme.titleMedium)),
        ]),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final g in p.groups)
            Chip(
              label: Text('Grupo $g', style: const TextStyle(color: Colors.white, fontSize: 12)),
              backgroundColor: g == 'A' ? LexairColors.groupA : LexairColors.groupB,
              visualDensity: VisualDensity.compact,
            ),
          if (!p.isActive) const Chip(label: Text('Inactiva'), visualDensity: VisualDensity.compact),
          if (p.visibility == 'restricted')
            const Chip(label: Text('Restringida'), visualDensity: VisualDensity.compact),
          if (p.isSynthetic)
            const Chip(label: Text('Dato sintético'), visualDensity: VisualDensity.compact),
        ]),
        const SizedBox(height: 8),
        _row('Código', p.code),
        if (p.phone != null) _row('Teléfono', p.phone!),
        _row('Consentimiento', Labels.of(Labels.consent, p.consentStatus)),
        _row('Fuente del dato', p.dataSource),
        if (p.notes != null && p.notes!.isNotEmpty) _row('Notas', p.notes!),
        const Divider(height: 24),
        Text('Ubicación fija', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (loc == null)
          const Text('Sin ubicación registrada.')
        else ...[
          Row(children: [
            Icon(Icons.circle, size: 10, color: Labels.precisionColor(loc.precisionLevel)),
            const SizedBox(width: 6),
            Text(Labels.of(Labels.precision, loc.precisionLevel)),
          ]),
          _row('Validación', Labels.of(Labels.validation, loc.validationStatus)),
          _row('Origen', Labels.of(Labels.coordSource, loc.coordSource)),
          _row('Granularidad', Labels.of(Labels.granularity, loc.addressGranularity)),
          if (loc.municipality != null) _row('Municipio', loc.municipality!),
          if (loc.locality != null) _row('Localidad', loc.locality!),
          if (loc.addressText != null) _row('Dirección', loc.addressText!),
          if (loc.point != null)
            _row('Coordenadas', '${Labels.coord(loc.lat!)}, ${Labels.coord(loc.lon!)}')
          else
            _row('Coordenadas', 'Ocultas (sin permiso de ubicación exacta)'),
        ],
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (can('persons.write'))
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Editar'),
              onPressed: () async {
                final r = await showPersonFormDialog(context, p);
                if (r != null) ws.replaceSelected(r);
              },
            ),
          if (can('locations.write'))
            OutlinedButton.icon(
              key: const Key('set-location'),
              icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
              label: Text(loc == null ? 'Asignar ubicación' : 'Cambiar ubicación'),
              onPressed: () async {
                final r = await showLocationDialog(context, p, ws);
                if (r != null) ws.replaceSelected(r);
              },
            ),
          if (can('locations.verify') && loc != null && loc.validationStatus != 'validated')
            OutlinedButton.icon(
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: const Text('Verificar'),
              onPressed: () => _act(context, () => ws.persons.verifyLocation(p.id), 'Ubicación verificada'),
            ),
          if (can('persons.write'))
            TextButton(
              onPressed: () => _act(context, () => ws.persons.setActive(p.id, !p.isActive),
                  p.isActive ? 'Persona desactivada' : 'Persona reactivada'),
              child: Text(p.isActive ? 'Desactivar' : 'Reactivar'),
            ),
        ]),
        if (can('passes.read')) ...[
          const Divider(height: 24),
          PassesSection(person: p),
        ],
        if (can('personnel.read') && loc != null) ...[
          const Divider(height: 24),
          NearbyPersonnelSection(person: p),
        ],
        if (can('proximity.query') && loc != null) ...[
          const Divider(height: 24),
          const ProximitySection(),
        ],
      ],
    );
  }

  static Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 110, child: Text(k, style: const TextStyle(color: LexairColors.muted, fontSize: 13))),
      Expanded(child: SelectableText(v, style: const TextStyle(fontSize: 13))),
    ]),
  );
}
