/// Versión web/plataformas sin soporte del servidor integrado.
class LocalRuntimePlan {
  const LocalRuntimePlan();
  final int puertoApi = 3000;
  final int puertoBd = 5433;
  String get serverUrl => 'http://127.0.0.1:$puertoApi';
}

Future<LocalRuntimePlan?> detectServidorIntegrado() async => null;

Future<LocalRuntimePlan?> ensureServidorIntegrado(
    {void Function(String)? onLog, void Function(String paso, String estado)? onPaso,
    String? usuarioInicial, String? claveInicial}) async =>
    null;

Future<void> guardarConfigLocal({
  int? puertoApi,
  int? puertoBd,
  String? usuarioAdmin,
  String? claveAdmin,
}) async {}
