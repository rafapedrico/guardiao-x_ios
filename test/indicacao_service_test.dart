import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:security_check_app/services/indicacao_service.dart';
import 'package:security_check_app/widgets/codigo_indicacao.dart';

void main() {
  group('IndicacaoService.normalizar', () {
    test('aceita minúsculas, espaços e hífen', () {
      expect(IndicacaoService.normalizar('abc234'), 'ABC234');
      expect(IndicacaoService.normalizar(' ab-c 234 '), 'ABC234');
    });

    test('recusa fora do formato (tamanho e alfabeto sem O/0, I/1, L)', () {
      expect(IndicacaoService.normalizar(null), isNull);
      expect(IndicacaoService.normalizar(''), isNull);
      expect(IndicacaoService.normalizar('ABC23'), isNull);
      expect(IndicacaoService.normalizar('ABC2345'), isNull);
      expect(IndicacaoService.normalizar('ABCDE0'), isNull);
      expect(IndicacaoService.normalizar('ABCDE1'), isNull);
      expect(IndicacaoService.normalizar('ABCDEO'), isNull);
      expect(IndicacaoService.normalizar('ABCDEI'), isNull);
      expect(IndicacaoService.normalizar('ABCDEL'), isNull);
    });
  });

  test('motivos do contrato de registrarIndicacao', () {
    expect(IndicacaoService.resultadoDoMotivo('ok'), ResultadoIndicacao.ok);
    expect(IndicacaoService.resultadoDoMotivo('codigo_invalido'), ResultadoIndicacao.codigoInvalido);
    expect(IndicacaoService.resultadoDoMotivo('autoindicacao'), ResultadoIndicacao.autoindicacao);
    expect(IndicacaoService.resultadoDoMotivo('ja_vinculado'), ResultadoIndicacao.jaVinculado);
    expect(IndicacaoService.resultadoDoMotivo('ja_premium'), ResultadoIndicacao.jaPremium);
    expect(IndicacaoService.resultadoDoMotivo('outro'), ResultadoIndicacao.erro);
    expect(IndicacaoService.resultadoDoMotivo(null), ResultadoIndicacao.erro);
  });

  testWidgets('cada resultado tem texto próprio, sem valor em dinheiro', (tester) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('pt'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        l10n = AppLocalizations.of(context)!;
        return const SizedBox.shrink();
      }),
    ));

    final textos = ResultadoIndicacao.values.map((r) => textoResultadoIndicacao(l10n, r)).toList();
    expect(textos.toSet().length, ResultadoIndicacao.values.length);
    for (final texto in textos) {
      expect(texto, isNot(contains(r'R$')));
      expect(texto, isNot(contains('50')));
    }
  });
}
