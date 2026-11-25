import 'config_source_stub.dart'
    if (dart.library.io) 'config_source_io.dart'
    if (dart.library.js_interop) 'config_source_web.dart'
    as impl;

/// Lee la configuración externa propia de la plataforma (o null).
Future<Map<String, dynamic>?> readExternalConfig() => impl.readExternalConfig();

/// URL por defecto de la plataforma (en web: el mismo origen).
String? platformDefaultServerUrl() => impl.platformDefaultServerUrl();
