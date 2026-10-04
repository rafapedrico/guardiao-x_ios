import 'dart:async';

import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../screens/camera_captura_screen.dart';
import '../screens/sos_sem_login_screen.dart';
import '../widgets/plano_bloqueado_dialog.dart';
import 'bloqueio_app_service.dart';
import 'captura_dissuasao_service.dart';
import 'plano_ciclo_service.dart';
import 'sos_disparo_service.dart';

/// Texto da tela preta do Widget SOS (ver [TelaSosWidget]).
enum EtapaTelaSosWidget {
  enviandoLocalizacao,
  localizacaoEnviada,
  falhaTentandoNovamente,
  cameraIndisponivel,
}

/// Fluxo do toque no Widget SOS do iOS (`guardiaox://sos`, ver
/// [SosDeepLinkService]) — app fechado, em segundo plano (com ou sem
/// bloqueio pendente), em primeiro plano em qualquer tela, ou logo após
/// desbloquear o iPhone.
///
/// Do primeiro quadro após o toque até a câmera abrir, a ÚNICA coisa
/// visível é a [TelaSosWidget] (preta, texto vermelho), desenhada em
/// `MaterialApp.builder` POR CIMA de tudo — Navigator, diálogos e a
/// camada de bloqueio ([CamadaBloqueioApp]). Nunca splash, login,
/// bloqueio ou Home.
///
/// Em paralelo, a partir de uma única leitura da janela do Plano Free:
///   - P1: Push com a última posição conhecida, com progresso na tela
///     ("Enviando…" → "Localização enviada…", ou "Falha… Tentando
///     novamente…" enquanto o Firestore insiste) — ver
///     [SosDisparoService.executarP1DoWidget];
///   - P2: a câmera ([CameraCapturaScreen]). Quando o preview aparece, a
///     tela preta sai. Se a câmera não abrir em [_limiteCamera], o texto
///     vira "Câmera indisponível…" e a captura segue para a tela vermelha.
class SosWidgetFluxoService {
  SosWidgetFluxoService._internal();
  static final SosWidgetFluxoService _instance = SosWidgetFluxoService._internal();
  factory SosWidgetFluxoService() => _instance;

  static const String origem = 'sos_widget_ios';
  static const Duration _limiteCamera = Duration(seconds: 10);
  static const Duration _exibicaoCameraIndisponivel = Duration(seconds: 3);

  /// `null` = tela preta fora da tela.
  final ValueNotifier<EtapaTelaSosWidget?> etapa = ValueNotifier<EtapaTelaSosWidget?>(null);

  VoidCallback? _encerrarLiberacao;
  bool _envioConfirmado = false;
  bool _soReenviando = false;
  Timer? _timerSaida;

  /// Começa o fluxo. Síncrono até a tela preta estar pedida: chamado antes
  /// do `runApp` no cold start (o primeiro quadro já sai preto) e direto do
  /// evento nativo no warm start. Um toque com a tela preta já na tela é
  /// ignorado (o SOS já está em andamento).
  void iniciar({required Future<void> Function() garantirFirebaseEAuth}) {
    if (etapa.value != null) {
      debugPrint('🆘 [SosWidgetFluxo] Toque ignorado — SOS do widget já em andamento.');
      return;
    }
    debugPrint('🆘 [SosWidgetFluxo] Toque no Widget SOS — tela preta e envio imediato.');
    _timerSaida?.cancel();
    _envioConfirmado = false;
    _soReenviando = false;
    // O SOS nunca espera desbloqueio: esconde a camada de bloqueio (e o
    // Face ID automático dela) enquanto o fluxo estiver na tela.
    _encerrarLiberacao = BloqueioAppService().liberarParaEmergencia();
    FocusManager.instance.primaryFocus?.unfocus();
    etapa.value = EtapaTelaSosWidget.enviandoLocalizacao;
    unawaited(_executar(garantirFirebaseEAuth));
  }

  Future<void> _executar(Future<void> Function() garantirFirebaseEAuth) async {
    try {
      await garantirFirebaseEAuth();
    } catch (e) {
      debugPrint('⚠️ [SosWidgetFluxo] Firebase/Auth indisponível: $e');
    }

    if (!BloqueioAppService.sessaoValida()) {
      // Ninguém nunca entrou neste aparelho: não há como enviar alerta.
      debugPrint('🆘 [SosWidgetFluxo] Sem sessão — explicando como ativar o botão.');
      _encerrarTela();
      (await _aguardarNavigator())?.push(
        MaterialPageRoute<void>(builder: (_) => const SosSemLoginScreen()),
      );
      return;
    }

    // Uma única leitura da janela do Plano Free para o envio e a câmera.
    final planoLiberado = PlanoCicloService().podeUsarRecursosAvancados();
    unawaited(_enviarLocalizacao(planoLiberado));
    unawaited(_abrirCamera(planoLiberado));
  }

  Future<void> _enviarLocalizacao(Future<bool> planoLiberado) async {
    if (!await planoLiberado) return;
    try {
      await SosDisparoService().executarP1DoWidget(
        origem: origem,
        aoConfirmar: _aoConfirmarEnvio,
        aoFalhar: _aoFalharEnvio,
      );
    } catch (e) {
      debugPrint('⚠️ [SosWidgetFluxo] Falha no envio da localização: $e');
      _aoFalharEnvio();
    }
  }

  void _aoConfirmarEnvio() {
    _envioConfirmado = true;
    final atual = etapa.value;
    if (atual == EtapaTelaSosWidget.enviandoLocalizacao ||
        atual == EtapaTelaSosWidget.falhaTentandoNovamente) {
      etapa.value = EtapaTelaSosWidget.localizacaoEnviada;
    }
    if (_soReenviando && etapa.value != null) {
      _timerSaida?.cancel();
      _timerSaida = Timer(const Duration(milliseconds: 1500), _encerrarTela);
    }
  }

  void _aoFalharEnvio() {
    if (_envioConfirmado) return;
    if (etapa.value == EtapaTelaSosWidget.enviandoLocalizacao) {
      etapa.value = EtapaTelaSosWidget.falhaTentandoNovamente;
    }
  }

  Future<void> _abrirCamera(Future<bool> planoLiberado) async {
    if (!await planoLiberado) {
      // Fora dos 10 dias ativos do Plano Free: nada é enviado. A tela preta
      // sai para o aviso do plano aparecer; o bloqueio só volta depois.
      debugPrint('🔒 [SosWidgetFluxo] Plano Free fora da janela ativa — SOS não enviado.');
      final encerrarLiberacao = _encerrarLiberacao;
      _encerrarLiberacao = null;
      _encerrarTela();
      final contexto = appNavigatorKey.currentContext;
      if (contexto != null && contexto.mounted) {
        await garantirRecursoLiberadoOuExibirUpsell(contexto);
      }
      encerrarLiberacao?.call();
      return;
    }

    if (CameraCapturaScreen.instanciasAbertas > 0) {
      // Já há uma câmera/tela vermelha de SOS aberta: só reenvia a
      // localização e devolve a tela que já estava aberta.
      debugPrint('🆘 [SosWidgetFluxo] Câmera do SOS já aberta — só reenviando a localização.');
      _soReenviando = true;
      if (_envioConfirmado) {
        _aoConfirmarEnvio();
      } else {
        _timerSaida = Timer(_limiteCamera, _encerrarTela);
      }
      return;
    }

    // Rede de segurança: se nem a tela de captura conseguir avisar, a tela
    // preta não fica para sempre.
    _timerSaida = Timer(_limiteCamera + const Duration(seconds: 2), () => _aoResolverCamera(false));
    final abriuTela = await CapturaDissuasaoService().abrirCapturaSePermitido(
      origemUnificada: origem,
      planoJaVerificado: true,
      limiteAbertura: _limiteCamera,
      aoResolverAbertura: _aoResolverCamera,
    );
    if (!abriuTela) _aoResolverCamera(false);
  }

  void _aoResolverCamera(bool abriu) {
    if (etapa.value == null || etapa.value == EtapaTelaSosWidget.cameraIndisponivel) return;
    _timerSaida?.cancel();
    if (abriu) {
      debugPrint('📷 [SosWidgetFluxo] Câmera aberta — saindo da tela preta.');
      _encerrarTela();
      return;
    }
    debugPrint('📷 [SosWidgetFluxo] Câmera indisponível — seguindo para a tela vermelha.');
    etapa.value = EtapaTelaSosWidget.cameraIndisponivel;
    _timerSaida = Timer(_exibicaoCameraIndisponivel, _encerrarTela);
  }

  /// Tira a tela preta. A câmera/tela vermelha tem a própria liberação do
  /// bloqueio ([LiberaBloqueioEnquantoAberta]).
  void _encerrarTela() {
    _timerSaida?.cancel();
    _timerSaida = null;
    etapa.value = null;
    _encerrarLiberacao?.call();
    _encerrarLiberacao = null;
  }

  Future<NavigatorState?> _aguardarNavigator() async {
    for (var tentativa = 0; tentativa < 20; tentativa++) {
      final navigator = appNavigatorKey.currentState;
      if (navigator != null) return navigator;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return null;
  }
}
