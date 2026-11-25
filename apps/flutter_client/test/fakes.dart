import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lexair_geo/core/net/api_client.dart';

/// Servidor API simulado en memoria SOLO para pruebas de widgets.
/// Las rutas y formas de respuesta replican el API real (/api/v1).
class FakeApi {
  final List<String> calls = [];
  final Map<String, http.Response Function(http.Request)> routes = {};

  void on(String methodPath, Object? body, {int status = 200}) =>
      routes[methodPath] = (_) => http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  ApiClient client() => ApiClient(
    baseUrl: 'https://geo.test/api/v1',
    client: MockClient((req) async {
      final key = '${req.method} ${req.url.path.replaceFirst('/api/v1', '')}';
      calls.add(key);
      final h = routes[key];
      return h != null ? h(req) : http.Response('{"error":"NOT_FOUND","message":"no ruta"}', 404);
    }),
  );
}

Map<String, dynamic> meJson({List<String> permissions = const ['persons.read'], bool mustChange = false,
    String role = 'operator'}) => {
  'id': '00000000-0000-4000-8000-000000000001',
  'username': 'operador1',
  'displayName': 'Operador Ficticio',
  'role': role,
  'permissions': permissions,
  'groups': [{'code': 'A', 'name': 'Grupo A', 'colorHex': '#1565C0'}],
  'mustChangePassword': mustChange,
};
