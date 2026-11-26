import 'local_runtime_stub.dart'
    if (dart.library.io) 'local_runtime_io.dart' as impl;
import 'local_runtime_stub.dart'
    if (dart.library.io) 'local_runtime_io.dart' show LocalRuntimePlan;
export 'local_runtime_stub.dart'
    if (dart.library.io) 'local_runtime_io.dart' show LocalRuntimePlan;

/// Servidor integrado («todo en uno»): la aplicación Windows trae dentro del
/// paquete un servidor completo (PostgreSQL+PostGIS, Node.js y la API) y lo
/// levanta al arrancar. En web y en paquetes sin `servidor/` devuelve null.

/// Detecta si existe un servidor integrado empaquetado junto al ejecutable
/// (carpeta `servidor/` con pg, node y api). Solo Windows; rápido (sistema
/// de ficheros). Devuelve null en web, en otras plataformas o si falta.
Future<LocalRuntimePlan?> detectServidorIntegrado() => impl.detectServidorIntegrado();

/// Levanta el servidor integrado completo (base de datos → extensiones →
/// migraciones → catálogo → cuenta → API) y devuelve la URL local.
/// Es idempotente: si ya responde, no toca nada. [onPaso] notifica
/// ('bd'|'esquema'|'catalogo'|'cuenta'|'api', estado).
Future<LocalRuntimePlan?> ensureServidorIntegrado({
  void Function(String)? onLog,
  void Function(String paso, String estado)? onPaso,
}) =>
    impl.ensureServidorIntegrado(onLog: onLog, onPaso: onPaso);

/// Guarda la configuración local del modo integrado (puertos y cuenta
/// inicial). Solo escritorio con carpeta de usuario disponible.
Future<void> guardarConfigLocal({
  int? puertoApi,
  int? puertoBd,
  String? usuarioAdmin,
  String? claveAdmin,
}) =>
    impl.guardarConfigLocal(
        puertoApi: puertoApi,
        puertoBd: puertoBd,
        usuarioAdmin: usuarioAdmin,
        claveAdmin: claveAdmin);
