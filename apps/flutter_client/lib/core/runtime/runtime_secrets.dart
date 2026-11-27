import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Un secreto nuevo por proceso de API: las sesiones viven solo en memoria
/// del cliente, por lo que pueden invalidarse al reiniciar el servidor.
String generarSecretoSesion() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(48, (_) => random.nextInt(256)));
}

/// Retira la clave inicial tras crear la cuenta, preservando todas las demás
/// opciones. No sustituye archivos ilegibles o JSON inválido por uno vacío.
Future<void> retirarClaveInicial(File archivo) async {
  if (!await archivo.exists()) return;
  final decoded = jsonDecode(await archivo.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Configuración local inválida');
  }
  if (!decoded.containsKey('claveAdmin')) return;
  decoded.remove('claveAdmin');
  await archivo.writeAsString(const JsonEncoder.withIndent('  ').convert(decoded), flush: true);
}
