import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:security_check_app/services/bloqueio_app_service.dart';
import 'package:security_check_app/widgets/camada_bloqueio_app.dart';

void main() {
  Widget app() => MaterialApp(
        theme: ThemeData(splashFactory: InkRipple.splashFactory),
        locale: const Locale('pt'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => CamadaBloqueioApp(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AlertDialog(content: Text('DIALOGO')),
                  ),
                  child: const Text('abrir dialogo'),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('ROTA')),
                    ),
                  ),
                  child: const Text('abrir rota'),
                ),
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const Text('FOLHA'),
                  ),
                  child: const Text('abrir folha'),
                ),
              ],
            ),
          ),
        ),
      );

  tearDown(() {
    BloqueioAppService().desbloquear();
  });

  // Regressão do build 107: o Navigator próprio da tela de bloqueio herdava
  // o HeroController do MaterialApp; ao desbloquear, ele era descartado e
  // deixava o HeroController sem navigator — todo push seguinte no
  // Navigator principal (Configurações, PIN do Histórico, folha de
  // contatos) quebrava em `HeroController.didChangeTop`.
  testWidgets('diálogo, rota e folha inferior abrem depois do desbloqueio',
      (tester) async {
    await tester.pumpWidget(app());
    BloqueioAppService().bloqueado.value = true;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    BloqueioAppService().desbloquear();
    await tester.pumpAndSettle();

    await tester.tap(find.text('abrir dialogo'));
    await tester.pumpAndSettle();
    expect(find.text('DIALOGO'), findsOneWidget);
    Navigator.of(tester.element(find.text('DIALOGO'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('abrir folha'));
    await tester.pumpAndSettle();
    expect(find.text('FOLHA'), findsOneWidget);
    Navigator.of(tester.element(find.text('FOLHA'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('abrir rota'));
    await tester.pumpAndSettle();
    expect(find.text('ROTA'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
