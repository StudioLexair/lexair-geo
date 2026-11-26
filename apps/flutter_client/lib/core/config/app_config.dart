/// Configuración del cliente. Se puede cambiar sin recompilar:
/// - Web: `config.json` servido junto a la aplicación (o mismo origen).
/// - Windows: `config.json` junto al ejecutable o en %PROGRAMDATA%\LexairGeo.
/// - Ambos: ajuste manual guardado localmente desde la pantalla de acceso.
class AppConfig {
  const AppConfig({
    required this.serverUrl,
    this.caCertificatePath,
    this.healthPollSeconds = 15,
    this.source = 'default',
  });

  final String serverUrl;
  final String? caCertificatePath;
  final int healthPollSeconds;

  /// Procedencia del valor efectivo (para diagnóstico en «Estado»).
  final String source;

  static const String appVersion = '0.4.0';

  String get apiBase => '${_trimSlash(serverUrl)}/api/v1';
  String get tilesBase => '${_trimSlash(serverUrl)}/tiles';

  AppConfig copyWith({String? serverUrl, String? source}) => AppConfig(
    serverUrl: serverUrl ?? this.serverUrl,
    caCertificatePath: caCertificatePath,
    healthPollSeconds: healthPollSeconds,
    source: source ?? this.source,
  );

  factory AppConfig.fromJson(Map<String, dynamic> json, {String source = 'file'}) {
    final url = json['serverUrl'];
    if (url is! String || !isValidServerUrl(url)) {
      throw const FormatException('serverUrl no válido en config.json');
    }
    final poll = json['healthPollSeconds'];
    final ca = json['caCertificatePath'];
    return AppConfig(
      serverUrl: _trimSlash(url),
      caCertificatePath: ca is String && ca.isNotEmpty ? ca : null,
      healthPollSeconds: poll is int && poll >= 5 && poll <= 300 ? poll : 15,
      source: source,
    );
  }

  static bool isValidServerUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.query.isEmpty;
  }

  static String _trimSlash(String s) {
    var out = s.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
