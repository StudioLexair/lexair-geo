import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lexair_geo/features/bootstrap/initial_account_screen.dart';

void main() {
  testWidgets('solicita usuario y contraseña, una pregunta por vez', (tester) async {
    String? usuario, clave;
    await tester.pumpWidget(MaterialApp(home: InitialAccountScreen(onComplete: (u, p) {
      usuario = u; clave = p;
    })));
    expect(find.text('¿Qué nombre tendrá la primera cuenta?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'operador-ficticio');
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    final passField = tester.widget<TextField>(find.byType(TextField));
    expect(passField.obscureText, isTrue);
    await tester.enterText(find.byType(TextField), 'corta');
    await tester.tap(find.text('Continuar'));
    await tester.pump();
    expect(find.text('Mínimo 12 caracteres'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Ficticia-4739!');
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'No-coincide-4739!');
    await tester.tap(find.text('Crear cuenta'));
    await tester.pump();
    expect(find.text('Las contraseñas no coinciden.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Ficticia-4739!');
    await tester.tap(find.text('Crear cuenta'));
    await tester.pump();
    expect(usuario, 'operador-ficticio');
    expect(clave, 'Ficticia-4739!');
  });
}
