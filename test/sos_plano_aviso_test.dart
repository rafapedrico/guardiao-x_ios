import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:security_check_app/services/plano_ciclo_service.dart';
import 'package:security_check_app/services/sos_plano_aviso_service.dart';
import 'package:security_check_app/services/sos_widget_fluxo_service.dart';
import 'package:security_check_app/widgets/tela_sos_widget.dart';

PlanoCicloStatus _status({required int diasDesdeInicio, bool premium = false}) {
  final dia = diasDesdeInicio + 1;
  return PlanoCicloStatus(
    isPremium: premium,
    cycleStartDate: DateTime.now().subtract(Duration(days: diasDesdeInicio, hours: 1)),
    diaAtualCiclo: dia,
    ativo: premium || dia <= 10 || dia > 30,
  );
}

void main() {
  test('período bloqueado vai do dia 11 até a renovação do ciclo', () {
    final status = _status(diasDesdeInicio: 2);
    final bloqueio = BloqueioSosPlano.doCiclo(status)!;
    expect(bloqueio.inicio, status.cycleStartDate.add(const Duration(days: 10)).toLocal());
    expect(bloqueio.fim, status.dataRenovacao.toLocal());
    // Dentro dos 10 dias ativos: nada em vigor.
    expect(BloqueioSosPlano.vigente(status), isNull);
  });

  test('em vigor só nos dias bloqueados e nunca no Premium', () {
    expect(BloqueioSosPlano.vigente(_status(diasDesdeInicio: 12)), isNotNull);
    expect(BloqueioSosPlano.vigente(_status(diasDesdeInicio: 12, premium: true)), isNull);
    expect(BloqueioSosPlano.doCiclo(_status(diasDesdeInicio: 2, premium: true)), isNull);
    expect(BloqueioSosPlano.vigente(null), isNull);
  });

  test('data no formato DD/MM', () {
    expect(formatarDiaMes(DateTime(2026, 11, 3)), '03/11');
  });

  testWidgets('toque no widget nos dias bloqueados mostra o aviso e o Premium', (tester) async {
    final fluxo = SosWidgetFluxoService();
    fluxo.fimBloqueioPlano = DateTime(2026, 11, 3);
    fluxo.etapa.value = EtapaTelaSosWidget.desativadoPlanoFree;
    addTearDown(() => fluxo.etapa.value = null);

    await tester.pumpWidget(MaterialApp(
      locale: const Locale('pt'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => CamadaTelaSosWidget(child: child!),
      home: const Scaffold(body: Text('app')),
    ));

    expect(find.text('Botão SOS desativado no Plano Free até 03/11'), findsOneWidget);
    expect(find.text('Assinar Premium'), findsOneWidget);

    await tester.tap(find.text('Agora não'));
    await tester.pump();
    expect(find.byType(TelaSosWidget), findsNothing);
  });
}
