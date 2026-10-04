import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:security_check_app/screens/consentimento_rastreamento_screen.dart';
import 'package:security_check_app/services/rastreamento_continuo_service.dart';

void main() {
  test('estado do nativo é lido com valores padrão seguros', () {
    final completo = EstadoRastreamento.doMapa(const {
      'permissao': 'sempre',
      'precisaoExata': true,
      'movimento': 'permitido',
      'atualizacaoSegundoPlano': true,
      'modoPoucaEnergia': false,
      'rastreamentoAtivo': true,
      'motivoInativo': null,
      'atividade': 'a_pe',
    });
    expect(completo.sempre, isTrue);
    expect(completo.rastreamentoAtivo, isTrue);
    expect(completo.atividade, 'a_pe');

    final vazio = EstadoRastreamento.doMapa(const {});
    expect(vazio.sempre, isFalse);
    expect(vazio.rastreamentoAtivo, isFalse);
    expect(vazio.movimento, 'nao_determinado');
  });

  testWidgets('consentimento começa pela etapa "Durante o uso"', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('pt'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ConsentimentoRastreamentoScreen(),
    ));
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('Permitir localização'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
  });
}
