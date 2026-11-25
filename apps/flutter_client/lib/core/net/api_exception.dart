/// Error uniforme para toda la aplicación. `isOffline` distingue un
/// servidor inaccesible de un error de negocio: la interfaz nunca debe
/// mostrar una operación como completada si el servidor no respondió.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
  });

  const ApiException.offline([String? detail])
    : statusCode = 0,
      code = 'OFFLINE',
      message = 'No hay conexión con el servidor LEXAIR GEO',
      details = detail;

  final int statusCode;
  final String code;
  final String message;
  final Object? details;

  bool get isOffline => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;

  /// Mensaje para el usuario, con detalles de validación si existen.
  String get userMessage {
    final d = details;
    if (d is List && d.isNotEmpty) {
      final parts = d
          .whereType<Map<String, dynamic>>()
          .map((e) => '${e['path']}: ${e['message']}')
          .take(4);
      return '$message (${parts.join('; ')})';
    }
    return message;
  }

  @override
  String toString() => 'ApiException($statusCode, $code, $message)';
}
