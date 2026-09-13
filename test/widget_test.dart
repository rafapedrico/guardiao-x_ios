// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:security_check_app/main.dart';

void main() {
  setUp(() {
    // _SplashGate lê o índice da próxima frase de marca via
    // SharedPreferences (ver lib/main.dart) — sem isso o plugin lançaria
    // MissingPluginException no ambiente de teste.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App inicializa sem lançar exceções (cold start normal)',
      (WidgetTester tester) async {
    // Desde a refatoração de cold start (commit 5e2933e), o app nunca
    // pula direto para o dashboard "Segurança": a rota inicial normal é
    // sempre a splash cinematográfica (_SplashGate), que faz crossfade
    // para a LoginScreen sozinha, sem esperar o Firebase. Chegar até o
    // dashboard exigiria login real (Firebase Auth mockado), fora do
    // escopo deste smoke test.
    await tester.pumpWidget(const SecurityCheckApp());
    await tester.pump();

    expect(tester.takeException(), isNull);

    // _SecurityCheckAppState.initState() agenda, sem possibilidade de
    // cancelamento externo, um Future.delayed(3s) que dispara um
    // Timer.periodic(1s) (monitor de alarme em disco — ver
    // lib/main.dart). O binding de teste falha o teste se restar
    // QUALQUER Timer pendente quando o corpo do teste termina, mesmo
    // que ainda não esteja "devido" — então precisamos avançar o
    // relógio (virtual, via pump com duração) além dos dois disparos
    // E então desmontar a árvore, para que o próprio Timer.periodic se
    // cancele sozinho (ele só se cancela quando `!mounted`, checado no
    // callback seguinte) antes do teste encerrar.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
  });
}
