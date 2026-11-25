import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createHttpClient({String? caCertificatePath}) {
  final context = SecurityContext(withTrustedRoots: true);
  if (caCertificatePath != null && File(caCertificatePath).existsSync()) {
    // CA privada de la red interna (infrastructure/nginx/make_internal_ca.sh).
    context.setTrustedCertificates(caCertificatePath);
  }
  final client = HttpClient(context: context)
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 20)
    ..findProxy = (_) => 'DIRECT'; // LAN: nunca a través de proxies externos
  return IOClient(client);
}
