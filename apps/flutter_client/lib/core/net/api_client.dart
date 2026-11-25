import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

typedef Json = Map<String, dynamic>;

/// Cliente REST de `/api/v1`. Todas las peticiones pasan por aquí: el
/// cliente nunca accede a PostgreSQL directamente.
class ApiClient {
  ApiClient({required this.baseUrl, required http.Client client}) : _client = client; // ignore: prefer_initializing_formals

  final String baseUrl;
  final http.Client _client;

  /// Token de sesión, solo en memoria (nunca se persiste en disco).
  String? token;
  void Function()? onUnauthorized;

  static const _timeout = Duration(seconds: 20);


  Map<String, String> get authHeaders => {
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Uri uri(String path, [Map<String, Object?>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && '$v'.isNotEmpty) q[k] = '$v';
    });
    return Uri.parse('$baseUrl$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  Future<Json> getJson(String path, [Map<String, Object?>? query]) =>
      _send('GET', uri(path, query));
  Future<Json> postJson(String path, [Object? body, Map<String, Object?>? query]) =>
      _send('POST', uri(path, query), body: body);
  Future<Json> putJson(String path, Object? body) => _send('PUT', uri(path), body: body);
  Future<Json> patchJson(String path, Object? body) => _send('PATCH', uri(path), body: body);
  Future<Json> deleteJson(String path) => _send('DELETE', uri(path));

  /// Envío de texto (CSV) con su propio Content-Type.
  Future<Json> postText(String path, String text, String contentType, Map<String, Object?> query) =>
      _send('POST', uri(path, query), rawBody: text, contentType: contentType);

  /// Descarga binaria/texto (exportaciones CSV).
  Future<String> getText(String path, [Map<String, Object?>? query]) async {
    final res = await _raw('GET', uri(path, query));
    _throwIfError(res);
    return utf8.decode(res.bodyBytes);
  }

  Future<Json> _send(
    String method,
    Uri url, {
    Object? body,
    String? rawBody,
    String contentType = 'application/json',
  }) async {
    final res = await _raw(
      method,
      url,
      body: rawBody ?? (body == null ? null : jsonEncode(body)),
      contentType: contentType,
    );
    _throwIfError(res);
    if (res.bodyBytes.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    return decoded is Json ? decoded : <String, dynamic>{'items': decoded};
  }

  Future<http.Response> _raw(
    String method,
    Uri url, {
    String? body,
    String contentType = 'application/json',
  }) async {
    final req = http.Request(method, url)
      ..headers.addAll(authHeaders)
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      req.headers['Content-Type'] = '$contentType; charset=utf-8';
      req.body = body;
    }
    try {
      final streamed = await _client.send(req).timeout(_timeout);
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on TimeoutException {
      throw const ApiException.offline('Tiempo de espera agotado');
    } on http.ClientException catch (e) {
      throw ApiException.offline(e.message);
    } on ApiException {
      rethrow;
    } catch (e) {
      // SocketException / HandshakeException en Windows, errores XHR en web.
      throw ApiException.offline(e.toString());
    }
  }

  void _throwIfError(http.Response res) {
    if (res.statusCode < 400) return;
    var code = 'HTTP_${res.statusCode}';
    var message = 'Error del servidor (${res.statusCode})';
    Object? details;
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is Json) {
        code = (body['error'] as String?) ?? code;
        message = (body['message'] as String?) ?? message;
        details = body['details'];
      }
    } catch (_) {
      // Cuerpo no JSON (p. ej. página de error de Nginx).
    }
    if (res.statusCode == 401) onUnauthorized?.call();
    throw ApiException(
      statusCode: res.statusCode,
      code: code,
      message: message,
      details: details,
    );
  }

  void close() => _client.close();
}
