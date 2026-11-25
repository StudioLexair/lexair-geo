import 'package:http/http.dart' as http;

import 'http_client_stub.dart'
    if (dart.library.io) 'http_client_io.dart'
    if (dart.library.js_interop) 'http_client_web.dart'
    as impl;

/// Cliente HTTP de la plataforma. En Windows admite una CA privada (PEM)
/// para el HTTPS interno; en web el navegador gestiona los certificados.
http.Client createHttpClient({String? caCertificatePath}) =>
    impl.createHttpClient(caCertificatePath: caCertificatePath);
