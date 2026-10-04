import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:security_check_app/services/sos_widget_fluxo_service.dart';
import 'package:security_check_app/widgets/tela_sos_widget.dart';

void main() {
  final etapa = SosWidgetFluxoService().etapa;

  tearDown(() => etapa.value = null);

  Widget app() => MaterialApp(
        locale: const Locale('pt'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => CamadaTelaSosWidget(child: child!),
        home: const Scaffold(body: Text('conteudo do app')),
      );

  testWidgets('tela preta cobre o app e acompanha cada etapa do SOS do widget',
      (tester) async {
    await tester.pumpWidget(app());
    expect(find.byType(TelaSosWidget), findsNothing);

    etapa.value = EtapaTelaSosWidget.enviandoLocalizacao;
    await tester.pump();
    expect(find.text('Enviando localização…'), findsOneWidget);

    etapa.value = EtapaTelaSosWidget.falhaTentandoNovamente;
    await tester.pump();
    expect(find.text('Falha ao enviar a localização. Tentando novamente…'), findsOneWidget);

    etapa.value = EtapaTelaSosWidget.localizacaoEnviada;
    await tester.pump();
    expect(find.text('Localização enviada, aguardando liberação da câmera'), findsOneWidget);

    etapa.value = EtapaTelaSosWidget.cameraIndisponivel;
    await tester.pump();
    expect(find.text('Câmera indisponível — alerta já enviado aos seus contatos'), findsOneWidget);

    // Toques não chegam ao app por baixo da tela preta.
    final material = tester.widget<Material>(
      find.descendant(of: find.byType(TelaSosWidget), matching: find.byType(Material)).first,
    );
    expect(material.color, Colors.black);

    etapa.value = null;
    await tester.pump();
    expect(find.byType(TelaSosWidget), findsNothing);
    expect(find.text('conteudo do app'), findsOneWidget);
  });
}
