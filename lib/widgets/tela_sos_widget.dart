import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/sos_widget_fluxo_service.dart';

/// Tela preta do Widget SOS: a única coisa visível do toque no widget até a
/// câmera abrir (ver [SosWidgetFluxoService]). Fica em `MaterialApp.builder`
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
        return l10n?.sosWidgetEnviandoLocalizacao ?? 'Enviando localização…';
      case EtapaTelaSosWidget.localizacaoEnviada:
        return l10n?.sosWidgetLocalizacaoEnviada ??
            'Localização enviada, aguardando liberação da câmera';
      case EtapaTelaSosWidget.falhaTentandoNovamente:
        return l10n?.sosWidgetFalhaEnvio ??
            'Falha ao enviar a localização. Tentando novamente…';
      case EtapaTelaSosWidget.cameraIndisponivel:
        return l10n?.sosWidgetCameraIndisponivel ??
            'Câmera indisponível — alerta já enviado aos seus contatos';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Material próprio: absorve os toques e não depende de nenhuma rota.
    return Material(
      color: Colors.black,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _texto(AppLocalizations.of(context)),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFFF1744),
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
