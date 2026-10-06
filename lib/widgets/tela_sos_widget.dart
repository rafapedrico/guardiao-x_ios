import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/sos_plano_aviso_service.dart';
import '../services/sos_widget_fluxo_service.dart';

/// Tela preta do SOS (Widget SOS e botão SOS do app): a única coisa visível
/// do toque até a câmera abrir (ver [SosWidgetFluxoService]). Fica em `MaterialApp.builder`
/// por cima do Navigator e da [CamadaBloqueioApp]; some sozinha quando
/// [SosWidgetFluxoService.etapa] volta a `null`.
class CamadaTelaSosWidget extends StatelessWidget {
  const CamadaTelaSosWidget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EtapaTelaSosWidget?>(
      valueListenable: SosWidgetFluxoService().etapa,
      child: child,
      builder: (context, etapa, conteudo) {
        return Stack(
          children: [
            ExcludeSemantics(excluding: etapa != null, child: conteudo!),
            if (etapa != null) Positioned.fill(child: TelaSosWidget(etapa: etapa)),
          ],
        );
      },
    );
  }
}

class TelaSosWidget extends StatelessWidget {
  const TelaSosWidget({super.key, required this.etapa});

  final EtapaTelaSosWidget etapa;

  String _texto(AppLocalizations? l10n) {
    switch (etapa) {
      case EtapaTelaSosWidget.enviandoLocalizacao:
        return l10n?.sosWidgetEnviandoLocalizacao ?? 'Alerta acionado. Enviando sua localização…';
      case EtapaTelaSosWidget.localizacaoEnviada:
        return l10n?.sosLocalizacaoEnviadaSucesso ?? 'Localização enviada com sucesso';
      case EtapaTelaSosWidget.semConexao:
        return l10n?.sosSemConexao ??
            'Sem conexão. Seu alerta será enviado automaticamente assim que houver sinal';
      case EtapaTelaSosWidget.abrindoCamera:
        return l10n?.sosAbrindoCamera ?? 'Abrindo a câmera';
      case EtapaTelaSosWidget.cameraIndisponivel:
        return l10n?.sosWidgetCameraIndisponivel ??
            'Câmera indisponível — alerta já enviado aos seus contatos';
      case EtapaTelaSosWidget.cameraIndisponivelSemConexao:
        return l10n?.sosCameraIndisponivelSemConexao ??
            'Câmera indisponível — seu alerta será enviado aos seus contatos assim que houver sinal';
      case EtapaTelaSosWidget.desativadoPlanoFree:
        final fim = SosWidgetFluxoService().fimBloqueioPlano;
        final data = fim == null ? '—' : formatarDiaMes(fim);
        return l10n?.sosPlanoWidgetDesativado(data) ??
            'Botão SOS desativado no Plano Free até $data';
    }
  }

  static const Color _vermelho = Color(0xFFFF1744);

  List<Widget> _botoesPlano(AppLocalizations? l10n) => [
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: SosWidgetFluxoService().assinarPremium,
            style: FilledButton.styleFrom(
              backgroundColor: _vermelho,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            child: Text(l10n?.sosPlanoBotaoAssinar ?? 'Assinar Premium'),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: SosWidgetFluxoService().fecharAvisoPlano,
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
          child: Text(l10n?.agoraNao ?? 'Agora não'),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    // Material próprio: absorve os toques e não depende de nenhuma rota.
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _texto(AppLocalizations.of(context)),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: _vermelho,
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                ),
                if (etapa == EtapaTelaSosWidget.desativadoPlanoFree)
                  ..._botoesPlano(AppLocalizations.of(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
