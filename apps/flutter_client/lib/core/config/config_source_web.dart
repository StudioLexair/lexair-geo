import 'dart:convert';

import 'package:http/http.dart' as http;

/// Web: `config.json` junto a la aplicación (lo edita el administrador).
Future<Map<String, dynamic>?> readExternalConfig() async {
  try {
    final res = await http
        .get(Uri.base.resolve('config.json'))
        .timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) return null;
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// La aplicación web se sirve desde el propio servidor LEXAIR GEO.
String? platformDefaultServerUrl() => Uri.base.origin;
