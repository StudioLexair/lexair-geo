import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../zones/zones_repository.dart';

/// Herramienta de dibujo activa.
enum DrawTool { none, circle, rectangle, polygon }

/// Estado del dibujo sobre el mapa. El usuario:
///  * círculo:     toque en el centro y arrastre (o segundo toque) fija el radio;
///  * rectángulo:  dos toques (esquinas opuestas);
///  * polígono:    toques sucesivos y cierre con «Terminar» (o doble toque).
///
/// El radio en metros se calcula con la fórmula haversine (los círculos se
/// guardan en el servidor como centro + radio y se materializan en PostGIS).
class DrawingController extends ChangeNotifier {
  DrawTool tool = DrawTool.none;
  LatLng? firstPoint;
  LatLng? centerPoint;
  LatLng? pendingPoint;
  final List<LatLng> ring = <LatLng>[];
  double? radiusM;

  int? get ringCount => tool == DrawTool.polygon ? ring.length : null;

  bool get isDrawing => tool != DrawTool.none;

  bool get canFinish => tool == DrawTool.polygon && ring.length >= 3;

  /// Comienza (o cancela si ya estaba activa) una herramienta.
  void start(DrawTool t) {
    if (tool == t) {
      cancel();
      return;
    }
    tool = t;
    _resetPoints();
    notifyListeners();
  }

  void _resetPoints() {
    firstPoint = null;
    centerPoint = null;
    pendingPoint = null;
    ring.clear();
    radiusM = null;
  }

  void cancel() {
    tool = DrawTool.none;
    _resetPoints();
    notifyListeners();
  }

  /// Toque del usuario en el mapa según la herramienta activa.
  /// Devuelve true si el dibujo terminó (para abrir el formulario de zona).
  bool onMapTap(LatLng p) {
    if (!isDrawing) return false;
    switch (tool) {
      case DrawTool.circle:
        if (centerPoint == null) {
          centerPoint = p;
          radiusM = 1;
        } else {
          radiusM = math.max(5.0, haversineM(centerPoint!, p));
          return true; // segundo toque fija el radio → terminar
        }
        break;
      case DrawTool.rectangle:
        if (firstPoint == null) {
          firstPoint = p;
        } else {
          firstPoint = null;
          return true; // dos esquinas fijadas → terminar
        }
        break;
      case DrawTool.polygon:
        ring.add(p);
        break;
      case DrawTool.none:
        break;
    }
    notifyListeners();
    return false;
  }

  /// Vista previa mientras el puntero se mueve (escritorio/web).
  void onMapHover(LatLng? p) {
    if (!isDrawing) return;
    if (tool == DrawTool.circle && centerPoint != null) {
      radiusM = math.max(1.0, haversineM(centerPoint!, p ?? centerPoint!));
    } else if (tool == DrawTool.rectangle && firstPoint != null) {
      pendingPoint = p;
    }
    notifyListeners();
  }

  void undoVertex() {
    if (tool == DrawTool.polygon && ring.isNotEmpty) {
      ring.removeLast();
      notifyListeners();
    }
  }

  /// Esquinas del rectángulo en curso (dos fijas + puntero).
  List<LatLng> rectanglePreview() {
    final a = firstPoint;
    final b = pendingPoint;
    if (a == null || b == null) return const [];
    return [LatLng(a.latitude, a.longitude), LatLng(a.latitude, b.longitude),
      LatLng(b.latitude, b.longitude), LatLng(b.latitude, a.longitude)];
  }

  /// Resultado final según la herramienta; null si el dibujo está incompleto.
  ZoneGeometrySpec? finishSpec() {
    switch (tool) {
      case DrawTool.circle:
        final c = centerPoint;
        final r = radiusM;
        if (c == null || r == null || r < 5) return null;
        return ZoneGeometrySpec.circle(center: c, radiusM: r.round());
      case DrawTool.rectangle:
        final verts = rectanglePreview();
        if (verts.length != 4) return null;
        return ZoneGeometrySpec.rectangle(corners: verts);
      case DrawTool.polygon:
        if (ring.length < 3) return null;
        return ZoneGeometrySpec.polygon(ring: List<LatLng>.unmodifiable(ring));
      case DrawTool.none:
        return null;
    }
  }

  @override
  void dispose() {
    ring.clear();
    super.dispose();
  }
}

/// Distancia haversine en metros (independiente de la proyección del mapa).
double haversineM(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(h.toDouble()));
}

double _rad(double deg) => deg * math.pi / 180.0;
