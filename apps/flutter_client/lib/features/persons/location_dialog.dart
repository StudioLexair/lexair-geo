import 'package:flutter/material.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/labels.dart';
import '../map/workspace_controller.dart';
import 'person.dart';

/// Asigna la ubicación fija desde el marcador provisional (dirección
/// geocodificada o clic en el mapa) o desde coordenadas tecleadas. La
/// precisión «exacta verificada» solo se obtiene con la acción Verificar.
Future<Person?> showLocationDialog(BuildContext context, Person p, WorkspaceController ws) =>
    showDialog<Person>(context: context, builder: (_) => _LocationDialog(person: p, ws: ws));

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({required this.person, required this.ws});
  final Person person;
  final WorkspaceController ws;

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  static const _apiGranularities = ['dwelling', 'poi', 'street', 'locality', 'municipality', 'unknown'];
  late final _src = widget.ws.provisionalSource;
  late final _lat = TextEditingController(text: widget.ws.provisional?.latitude.toStringAsFixed(6) ?? '');
  late final _lon = TextEditingController(text: widget.ws.provisional?.longitude.toStringAsFixed(6) ?? '');
  late final _address = TextEditingController(text: _src?.label ?? widget.person.location?.addressText ?? '');
  late String _precision = _src?.suggestedPrecision ?? 'unverified';
  late String _granularity =
      _apiGranularities.contains(_src?.granularity) ? _src!.granularity : 'unknown';
  String? _error;

  String get _coordSource => _src != null
      ? 'geocoded_address'
      : widget.ws.provisional != null
      ? 'map_pick'
      : 'manual_coordinates';

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_lon.text.trim().replaceAll(',', '.'));
    if (lat == null || lon == null || lat < 19.5 || lat > 23.6 || lon < -85.2 || lon > -74.0) {
      setState(() => _error = 'Coordenadas fuera de Cuba o no válidas');
      return;
    }
    try {
      final r = await widget.ws.persons.setLocation(widget.person.id, {
        'lat': lat,
        'lon': lon,
        'coordSource': _coordSource,
        'precisionLevel': _precision,
        'addressGranularity': _granularity,
        'addressText': _address.text.trim().isEmpty ? null : _address.text.trim(),
        'municipalityId': _src?.municipalityId,
        'localityId': _src?.localityId,
        'geocodeConfidence': _src?.confidence,
      });
      widget.ws.setProvisional(null);
      if (mounted) Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      setState(() => _error = e.userMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final precisions = Labels.precision.entries.where((e) => e.key != 'exact_verified');
    return AlertDialog(
      title: Text('Ubicación de ${widget.person.code}'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            widget.ws.provisional == null
                ? 'Sin marcador provisional: busque una dirección o use «Elegir en mapa», o teclee coordenadas.'
                : 'Origen: ${Labels.of(Labels.coordSource, _coordSource)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_src?.note != null) Text(_src!.note!, style: const TextStyle(color: Colors.orange, fontSize: 12)),
          Row(children: [
            Expanded(child: TextField(key: const Key('loc-lat'), controller: _lat,
                decoration: const InputDecoration(labelText: 'Latitud'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(key: const Key('loc-lon'), controller: _lon,
                decoration: const InputDecoration(labelText: 'Longitud'))),
          ]),
          TextField(controller: _address, decoration: const InputDecoration(labelText: 'Dirección (texto)')),
          DropdownButtonFormField<String>(
            initialValue: _precision,
            decoration: const InputDecoration(labelText: 'Nivel de precisión'),
            items: [for (final e in precisions) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _precision = v ?? _precision),
          ),
          DropdownButtonFormField<String>(
            initialValue: _granularity,
            decoration: const InputDecoration(labelText: 'Granularidad'),
            items: [
              for (final g in _apiGranularities)
                DropdownMenuItem(value: g, child: Text(Labels.of(Labels.granularity, g))),
            ],
            onChanged: (v) => setState(() => _granularity = v ?? _granularity),
          ),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        FilledButton(key: const Key('loc-save'), onPressed: _save, child: const Text('Guardar ubicación')),
      ],
    );
  }
}
