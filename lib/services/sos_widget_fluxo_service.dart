import 'dart:async';

import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../screens/camera_captura_screen.dart';
import '../screens/sos_sem_login_screen.dart';
import '../widgets/premium_compra_aviso.dart';
import 'bloqueio_app_service.dart';
import 'captura_dissuasao_service.dart';
import 'historico_alertas_service.dart';
import 'plano_ciclo_service.dart';
import 'sos_disparo_service.dart';
import 'sos_plano_aviso_service.dart';

/// Texto da tela preta do SOS (ver [TelaSosWidget]).
enum EtapaTelaSosWidget {
  /// "Alerta acionado. Enviando sua localização…"
  enviandoLocalizacao,

  /// "Localização enviada com sucesso" — 2 s, depois [abrindoCamera].
  localizacaoEnviada,

  /// Sem confirmação em 8 s: "Sem conexão. Seu alerta será enviado
  /// automaticamente assim que houver sinal" — 2 s, depois [abrindoCamera].
  semConexao,

  /// "Abrindo a câmera" até o preview aparecer.
  abrindoCamera,

  /// A câmera não abriu em 10 s (alerta já confirmado pelo servidor).
  cameraIndisponivel,

  /// A câmera não abriu em 10 s e o alerta ainda está na fila.
  cameraIndisponivelSemConexao,

  /// Dias bloqueados do Plano Free: "Botão SOS desativado no Plano Free
  /// até DD/MM" com "Assinar Premium" — nada é enviado.
  desativadoPlanoFree,
}

/// Fluxo do SOS do iOS — o MESMO para o Widget SOS (`guardiaox://sos`, ver
/// [SosDeepLinkService]) e para o botão SOS da aba Segurança.
///
/// Do toque até a câmera abrir, a ÚNICA coisa visível é a [TelaSosWidget]
/// (preta, texto vermelho), desenhada em `MaterialApp.builder` POR CIMA de
/// tudo — Navigator, diálogos e a camada de bloqueio ([CamadaBloqueioApp]).
///
/// Sequência:
///   1. toque → envio imediato, sem confirmação, da localização exata
///      ([SosDisparoService.executarP1Sos], alerta com id fixo e
///      confirmação do servidor) — "Alerta acionado. Enviando sua
///      localização…";
///   2. confirmado → "Localização enviada com sucesso" por 2 s; sem
///      confirmação em 8 s → "Sem conexão…" por 2 s (o envio continua
///      tentando sozinho);
///   3. "Abrindo a câmera" até o preview aparecer (teto de 10 s; sem câmera,
///      "Câmera indisponível…" e a captura segue para a tela vermelha).
/// A câmera só abre depois desses avisos.
class SosWidgetFluxoService {
  SosWidgetFluxoService._internal();
  static final SosWidgetFluxoService _instance = SosWidgetFluxoService._internal();
  factory SosWidgetFluxoService() => _instance;

  /// `origem` do alerta no Firestore para o Widget SOS.
  static const String origem = 'sos_widget_ios';

  /// `origem` do alerta no Firestore para o botão SOS da aba Segurança.
  static const String origemBotaoApp = 'sos_manual';

  static const Duration _limiteConfirmacao = Duration(seconds: 8);
  static const Duration _exibicaoAviso = Duration(seconds: 2);
  static const Duration _limiteCamera = Duration(seconds: 10);
  static const Duration _exibicaoCameraIndisponivel = Duration(seconds: 3);

  /// `null` = tela preta fora da tela.
  final ValueNotifier<EtapaTelaSosWidget?> etapa = ValueNotifier<EtapaTelaSosWidget?>(null);

  /// Fim do bloqueio do Plano Free exibido em
  /// [EtapaTelaSosWidget.desativadoPlanoFree].
  DateTime? fimBloqueioPlano;

  VoidCallback? _encerrarLiberacao;
  Completer<bool>? _confirmacao;
  bool _envioConfirmado = false;
  Timer? _timerSaida;

  /// Começa o fluxo. Síncrono até a tela preta estar pedida: chamado antes
  /// do `runApp` no cold start (o primeiro quadro já sai preto), direto do
  /// evento nativo no warm start e no toque do botão SOS do app. Um toque
  /// com a tela preta já na tela é ignorado (o SOS já está em andamento).
  ///
  /// [origemAlerta]: [origem] (widget) ou [origemBotaoApp].
  /// [aoPlanoBloqueado]: nos dias bloqueados do Plano Free, em vez da tela
  /// preta de "Botão SOS desativado", fecha a tela preta e chama este aviso
  /// (o botão do app mantém o aviso de sempre).
  void iniciar({
    Future<void> Function()? garantirFirebaseEAuth,
    String origemAlerta = origem,
    Future<void> Function()? aoPlanoBloqueado,
  }) {
    if (etapa.value != null) {
      debugPrint('🆘 [SosFluxo] Toque ignorado — SOS já em andamento.');
      return;
    }
    debugPrint('🆘 [SosFluxo] SOS ($origemAlerta) — tela preta e envio imediato.');
    _timerSaida?.cancel();
    _envioConfirmado = false;
    _confirmacao = Completer<bool>();
    // O SOS nunca espera desbloqueio: esconde a camada de bloqueio (e o
    // Face ID automático dela) enquanto o fluxo estiver na tela.
    _encerrarLiberacao = BloqueioAppService().liberarParaEmergencia();
    FocusManager.instance.primaryFocus?.unfocus();
    etapa.value = EtapaTelaSosWidget.enviandoLocalizacao;
    unawaited(_executar(garantirFirebaseEAuth, origemAlerta, aoPlanoBloqueado));
  }

  Future<void> _executar(
    Future<void> Function()? garantirFirebaseEAuth,
    String origemAlerta,
    Future<void> Function()? aoPlanoBloqueado,
  ) async {
    try {
      await garantirFirebaseEAuth?.call();
    } catch (e) {
      debugPrint('⚠️ [SosFluxo] Firebase/Auth indisponível: $e');
    }

    if (!BloqueioAppService.sessaoValida()) {
      // Ninguém nunca entrou neste aparelho: não há como enviar alerta.
      debugPrint('🆘 [SosFluxo] Sem sessão — explicando como ativar o botão.');
      _encerrarTela();
      (await _aguardarNavigator())?.push(
        MaterialPageRoute<void>(builder: (_) => const SosSemLoginScreen()),
      );
      return;
    }

    // Sem status (sem rede/falha), libera — nunca silenciar um SOS por
    // falha técnica (mesma regra de [PlanoCicloService.podeUsarRecursosAvancados]).
    final status = await PlanoCicloService().obterStatusAtualizado();
    if (!(status?.ativo ?? true)) {
      debugPrint('🔒 [SosFluxo] Plano Free nos dias bloqueados — SOS não enviado.');
      if (aoPlanoBloqueado != null) {
        _encerrarTela();
        await aoPlanoBloqueado();
        return;
      }
      fimBloqueioPlano = BloqueioSosPlano.vigente(status)?.fim;
      etapa.value = EtapaTelaSosWidget.desativadoPlanoFree;
      return;
    }

    if (!await SosDisparoService().reivindicarDisparo()) {
      // Outro disparo de SOS começou há poucos segundos e já está enviando.
      debugPrint('🔁 [SosFluxo] SOS já em andamento por outro disparo.');
      _encerrarTela();
      return;
    }

    final alertaId = HistoricoAlertasService().novoAlertaId();
    unawaited(SosDisparoService()
        .executarP1Sos(
          alertaId: alertaId,
          origem: origemAlerta,
          tipoHistorico: origemAlerta == origemBotaoApp
              ? TipoAlertaHistorico.sosManual
              : TipoAlertaHistorico.sosWidget,
          aoConfirmar: _aoConfirmarEnvio,
          aoFalhar: () {},
        )
        .catchError((Object e) {
      debugPrint('⚠️ [SosFluxo] Falha no envio da localização: $e');
    }));

    final confirmado = await _confirmacao!.future
        .timeout(_limiteConfirmacao, onTimeout: () => false);
    if (etapa.value == null) return;
    etapa.value = confirmado ? EtapaTelaSosWidget.localizacaoEnviada : EtapaTelaSosWidget.semConexao;
    await Future<void>.delayed(_exibicaoAviso);
    if (etapa.value == null) return;

    if (CameraCapturaScreen.instanciasAbertas > 0) {
      // Já há uma câmera/tela vermelha de SOS aberta: o alerta novo já foi
      // enviado; devolve a tela que já estava aberta.
      debugPrint('🆘 [SosFluxo] Câmera do SOS já aberta — só reenviou a localização.');
      _encerrarTela();
      return;
    }

    etapa.value = EtapaTelaSosWidget.abrindoCamera;
    // Rede de segurança: se nem a tela de captura conseguir avisar, a tela
    // preta não fica para sempre.
    _timerSaida = Timer(_limiteCamera + const Duration(seconds: 2), () => _aoResolverCamera(false));
    final abriuTela = await CapturaDissuasaoService().abrirCapturaSePermitido(
      origemUnificada: origemAlerta,
      alertaId: alertaId,
      planoJaVerificado: true,
      limiteAbertura: _limiteCamera,
      aoResolverAbertura: _aoResolverCamera,
    );
    if (!abriuTela) _aoResolverCamera(false);
  }

  void _aoConfirmarEnvio() {
    _envioConfirmado = true;
    final confirmacao = _confirmacao;
    if (confirmacao != null && !confirmacao.isCompleted) confirmacao.complete(true);
  }

  void _aoResolverCamera(bool abriu) {
    final atual = etapa.value;
    if (atual == null ||
        atual == EtapaTelaSosWidget.cameraIndisponivel ||
        atual == EtapaTelaSosWidget.cameraIndisponivelSemConexao) {
      return;
    }
    _timerSaida?.cancel();
    if (abriu) {
      debugPrint('📷 [SosFluxo] Câmera aberta — saindo da tela preta.');
      _encerrarTela();
      return;
    }
    debugPrint('📷 [SosFluxo] Câmera indisponível — seguindo para a tela vermelha.');
    etapa.value = _envioConfirmado
        ? EtapaTelaSosWidget.cameraIndisponivel
        : EtapaTelaSosWidget.cameraIndisponivelSemConexao;
    _timerSaida = Timer(_exibicaoCameraIndisponivel, _encerrarTela);
  }

  /// "Assinar Premium" na tela do botão desativado.
  Future<void> assinarPremium() async {
    _encerrarTela();
    final navigator = await _aguardarNavigator();
    final contexto = navigator?.context;
    if (contexto != null && contexto.mounted) {
      await iniciarCompraPremiumComAviso(contexto);
    }
  }

  /// "Agora não" na tela do botão desativado.
  void fecharAvisoPlano() => _encerrarTela();

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
