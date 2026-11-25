import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../core/theme/app_theme.dart';
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
