import 'dart:convert';
import 'dart:io';

/// Windows: config.json junto al ejecutable o en %PROGRAMDATA%\LexairGeo.
Future<Map<String, dynamic>?> readExternalConfig() async {
  final candidates = <String>[
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}config.json',
    if (Platform.environment['PROGRAMDATA'] != null)
      '${Platform.environment['PROGRAMDATA']}\\LexairGeo\\config.json',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    }
  }
  return null;
}

String? platformDefaultServerUrl() => null;
