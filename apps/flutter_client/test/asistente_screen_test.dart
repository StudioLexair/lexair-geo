import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lexair_geo/features/bootstrap/asistente_screen.dart';

Future<void> mensajes(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 600));
  }
}

void main() {
  testWidgets('permite elegir propósito y enviar la dirección del servidor', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DecisionAsistente? decision;
    await tester.pumpWidget(MaterialApp(home: AsistenteScreen(
      onDecision: (d) => decision = d,
      onFlag: () async {},
    )));
    await mensajes(tester);
    expect(find.text('Personas'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('Personas'));
    await mensajes(tester);
    await tester.tap(find.text('Solo cliente'));
    await mensajes(tester);
    await tester.enterText(find.byType(TextField), 'http://192.168.1.20:3000');
    await tester.tap(find.text('Listo'));
    await mensajes(tester);
    expect(decision, isA<DecisionRed>());
    expect((decision as DecisionRed).url, 'http://192.168.1.20:3000');
  });

  testWidgets('permite saltar el asistente', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DecisionAsistente? decision;
    await tester.pumpWidget(MaterialApp(home: AsistenteScreen(
      onDecision: (d) => decision = d,
      onFlag: () async {},
    )));
    await mensajes(tester);
    await tester.tap(find.byKey(const Key('saltar-asistente')));
    await tester.pump();
    expect(decision, isA<DecisionSaltar>());
  });
}
