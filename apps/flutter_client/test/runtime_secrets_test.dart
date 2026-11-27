import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lexair_geo/core/runtime/runtime_secrets.dart';

void main() {
  test('se genera un secreto aleatorio de 384 bits por arranque', () {
    final primero = generarSecretoSesion();
    final segundo = generarSecretoSesion();
    expect(primero, isNot(segundo));
    expect(base64Url.decode(primero), hasLength(48));
  });

  test('retira únicamente la contraseña de un JSON local', () async {
    final dir = await Directory.systemTemp.createTemp('vigia-test-');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/servidor-local.json');
    await f.writeAsString(jsonEncode({
      'usuarioAdmin': 'ficticio', 'claveAdmin': 'Temporal-ficticia-8192',
      'puertoBD': 5433, 'otraOpcion': true,
    }));
    await retirarClaveInicial(f);
    final result = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    expect(result, {'usuarioAdmin': 'ficticio', 'puertoBD': 5433, 'otraOpcion': true});
    await retirarClaveInicial(f);
  });

  test('no modifica un archivo que no es JSON válido', () async {
    final dir = await Directory.systemTemp.createTemp('vigia-test-');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/servidor-local.json');
    await f.writeAsString('{malformado');
    await expectLater(retirarClaveInicial(f), throwsFormatException);
    expect(await f.readAsString(), '{malformado');
  });
}
