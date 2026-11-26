import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../core/util/icon_map.dart';
import '../../core/util/labels.dart';
import '../persons/person.dart';
import 'workspace_controller.dart';

/// Marcadores de personas: agrupaciones (calculadas en el servidor con
/// PostGIS) a zoom bajo y puntos individuales a zoom alto.
List<Marker> buildFeatureMarkers(BuildContext context, WorkspaceController ws, MapController map) {
  return ws.features.map((f) {
    if (f.isCluster) {
      final size = f.count < 10 ? 30.0 : f.count < 100 ? 36.0 : f.count < 1000 ? 44.0 : 52.0;
      final color = f.hasA && f.hasB
          ? LexairColors.groupAB
          : f.hasB
          ? LexairColors.groupB
          : LexairColors.groupA;
      return Marker(
        point: f.point,
        width: size,
        height: size,
        child: GestureDetector(
          onTap: () => ws.centerOn(f.point, map.camera.zoom + 2),
          child: Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.85),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
            ),
            alignment: Alignment.center,
            child: Text(
              f.count >= 1000 ? '${(f.count / 1000).toStringAsFixed(1)}k' : '${f.count}',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }
    final selected = ws.selected?.id == f.personId;
    return Marker(
      point: f.point,
      width: 26,
      height: 26,
      child: Tooltip(
        message: '${f.name ?? ''} · ${f.code ?? ''}\n${Labels.of(Labels.precision, f.precisionLevel)}',
        child: GestureDetector(
          onTap: () => ws.selectById(f.personId!),
          child: Icon(
            Icons.location_on,
            size: selected ? 30 : 24,
            color: Labels.groupColor(f.groups),
            shadows: const [Shadow(blurRadius: 2, color: Colors.black38)],
          ),
        ),
      ),
    );
  }).toList();
}

/// Persona seleccionada, resultados de proximidad y marcador provisional.
List<Marker> buildSelectionMarkers(WorkspaceController ws) {
  final out = <Marker>[];
  for (final p in ws.nearby?.page.items ?? const <Person>[]) {
    final pt = p.location?.point;
    if (pt == null) continue;
    out.add(Marker(
      point: pt,
      width: 22,
      height: 22,
      child: GestureDetector(
        onTap: () => ws.select(p, center: false),
        child: Container(
          decoration: BoxDecoration(
            color: Labels.groupColor(p.groups),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    ));
  }
  final sel = ws.selected?.location?.point;
  if (sel != null) {
    out.add(Marker(
      point: sel,
      width: 40,
      height: 40,
      alignment: Alignment.topCenter,
      child: const Icon(Icons.person_pin_circle, size: 40, color: LexairColors.accent,
          shadows: [Shadow(blurRadius: 3, color: Colors.black45)]),
    ));
  }
  final prov = ws.provisional;
  if (prov != null) {
    out.add(Marker(
      point: prov,
      width: 36,
      height: 36,
      alignment: Alignment.topCenter,
      child: const Tooltip(
        message: 'Marcador provisional (no guardado). Active «Elegir en mapa» para moverlo.',
        child: Icon(Icons.add_location_alt, size: 36, color: Color(0xFF6D4C41)),
      ),
    ));
  }
  return out;
}


/// Marcadores de internos CON PASE ACTIVO. El icono, color y tamaño vienen de
/// la configuración del servidor (`passes.marker_icon`): nada fijado en el
/// cliente. Al tocarlo se abre la ficha de la persona.
List<Marker> buildPassMarkers(BuildContext context, WorkspaceController ws) {
  final style = ws.passMarkerStyle;
  final icon = iconFromName(style.icon, fallback: Icons.local_police);
  final color = _hexToColor(style.colorHex) ?? LexairColors.groupB;
  return [
    for (final m in ws.passMarkers)
      Marker(
        point: LatLng(m.lat, m.lon),
        width: style.size + 6,
        height: style.size + 6,
        alignment: Alignment.topCenter,
        child: Tooltip(
          message: '${m.pass.personName ?? ''}\n'
              'Pase: ${m.pass.passTypeName ?? ''}\n'
              'Hasta: ${fmtDateIso(m.pass.endsAt)}\n'
              'Interno: ${m.pass.internCode ?? '—'}',
          child: GestureDetector(
            onTap: () => ws.selectById(m.pass.personId),
            child: Stack(clipBehavior: Clip.none, children: [
              Icon(icon, size: style.size.toDouble(), color: color,
                  shadows: const [Shadow(blurRadius: 3, color: Colors.black45)]),
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: LexairColors.ok,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
  ];
}

/// Marcadores de personal de la fuerza (capa opcional del mapa).
List<Marker> buildPersonnelMarkers(BuildContext context, WorkspaceController ws) {
  return [
    for (final p in ws.personnelMarkers)
      if (p.hasPoint)
        Marker(
          point: LatLng(p.lat!, p.lon!),
          width: 26,
          height: 26,
          child: Tooltip(
            message: '${p.rank != null ? '${p.rank} ' : ''}${p.fullName}\n'
                '${p.unit ?? ''}\n${p.phone ?? 'sin teléfono'}',
            child: GestureDetector(
              onTap: () => showPersonnelSheet(context, p),
              child: Icon(iconFromName('shield', fallback: Icons.shield),
                  size: 24, color: LexairColors.primary,
                  shadows: const [Shadow(blurRadius: 2, color: Colors.black38)]),
            ),
          ),
        ),
  ];
}

/// Ficha rápida del personal al tocar su marcador (teléfonos y unidad).
Future<void> showPersonnelSheet(BuildContext context, dynamic p) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p.rank != null ? '${p.rank} ' : ''}${p.fullName}',
              style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (p.code != null) Text('Código: ${p.code}'),
          if (p.unit != null) Text('Unidad: ${p.unit}'),
          if (p.phone != null) SelectableText('Teléfono: ${p.phone}'),
          if (p.phoneAlt != null) SelectableText('Altéfono: ${p.phoneAlt}'),
          if (p.addressText != null) Text('Residencia: ${p.addressText}'),
          if (p.roleNote != null) Text('Función: ${p.roleNote}'),
        ]),
      ),
    ),
  );
}

Color? _hexToColor(String hex) {
  if (hex.length == 7 && hex.startsWith('#')) {
    final v = int.tryParse(hex.substring(1), radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return null;
}

String fmtDateIso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
