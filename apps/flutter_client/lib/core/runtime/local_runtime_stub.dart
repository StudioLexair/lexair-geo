/// Versión web/plataformas sin soporte del servidor integrado.
class LocalRuntimePlan {
  const LocalRuntimePlan();
  String get serverUrl => 'http://127.0.0.1:3000';
}

Future<LocalRuntimePlan?> detectServidorIntegrado() async => null;

Future<LocalRuntimePlan?> ensureServidorIntegrado({void Function(String)? onLog}) async => null;
