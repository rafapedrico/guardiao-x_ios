import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'firebase_auth_service.dart';

/// Bloqueio LOCAL do app (Face ID/Touch ID/biometria, com o código do
/// aparelho e o PIN do Guardião-X como alternativas — ver
/// `CamadaBloqueioApp`). Substituiu a antiga "Opção A" (logout forçado do
/// Firebase Auth a cada cold start), que fazia o Widget SOS do iOS abrir a
/// LoginScreen em vez de disparar o SOS (feedback do build 105: 4 de 5
/// toques): sem sessão, nenhum alerta pode ser enviado.
///
/// Agora a sessão do Firebase fica SEMPRE persistida (logout só no "Sair"),
/// e quem protege o conteúdo do app é este bloqueio:
/// - Cold start normal com sessão: o app abre bloqueado.
/// - Volta do segundo plano depois de [tempoEmSegundoPlanoParaBloquear]:
///   bloqueia de novo.
/// - Emergências PULAM o bloqueio enquanto estão na tela (SOS do Widget e
///   do botão físico, câmera/tela vermelha, alerta recebido, alarme de
///   rotina/cronômetro) via [liberarParaEmergencia]/
///   [LiberaBloqueioEnquantoAberta]. Quando a emergência sai da tela,
///   qualquer navegação para o resto do app cai de volta no bloqueio.
///
/// O bloqueio é uma camada POR CIMA do Navigator (ver `CamadaBloqueioApp`
/// em `MaterialApp.builder`), não uma rota — por isso nenhuma navegação
/// (pop até a raiz, troca de pilha, deep link) consegue "escapar" dele.
class BloqueioAppService with WidgetsBindingObserver {
  BloqueioAppService._internal();
  static final BloqueioAppService _instance = BloqueioAppService._internal();
  factory BloqueioAppService() => _instance;

  /// Tempo em segundo plano a partir do qual o app volta bloqueado.
  static const Duration tempoEmSegundoPlanoParaBloquear = Duration(minutes: 2);

  /// `true` = o conteúdo do app exige desbloqueio.
  final ValueNotifier<bool> bloqueado = ValueNotifier<bool>(false);

  /// Quantas emergências estão na tela agora (> 0 esconde a camada).
  final ValueNotifier<int> emergenciasAbertas = ValueNotifier<int>(0);

  bool _observando = false;
  DateTime? _foiParaSegundoPlanoEm;

  /// `true` quando a camada de bloqueio deve estar visível.
  bool get camadaVisivel => bloqueado.value && emergenciasAbertas.value == 0;

  /// Começa a observar o ciclo de vida do app. Idempotente.
  void iniciar() {
    if (_observando) return;
    _observando = true;
    WidgetsBinding.instance.addObserver(this);
  }

  /// Bloqueia se houver uma sessão restaurada — chamado depois que o
  /// Firebase Auth termina de restaurar a sessão no cold start.
  void bloquearSeHouverSessao() {
    if (sessaoValida()) _bloquear();
  }

  /// Sessão que de fato dá acesso ao app: conta por e-mail/senha só vale
  /// com o e-mail confirmado (a tela de verificação de e-mail não deve
  /// ficar atrás do bloqueio). Também usada pela splash em `main.dart`.
  static bool sessaoValida() {
    // Firebase pode não ter inicializado (sem rede no 1º uso, falha do
    // SDK): sem ele não há sessão — nunca lança.
    if (Firebase.apps.isEmpty) return false;
    try {
      final usuario = FirebaseAuthService().usuarioAtual;
      if (usuario == null) return false;
      return usuario.emailVerified ||
          usuario.providerData.every((p) => p.providerId != 'password');
    } catch (_) {
      return false;
    }
  }

  /// Desbloqueio confirmado (biometria, código do aparelho, PIN) ou login
  /// novo de verdade.
  void desbloquear() {
    bloqueado.value = false;
  }

  /// Sessão encerrada ("Sair"): não há mais nada a proteger.
  void aoEncerrarSessao() {
    bloqueado.value = false;
  }

  /// Esconde a camada enquanto uma emergência está em andamento. Devolve a
  /// função que encerra a liberação (idempotente — pode ser chamada mais
  /// de uma vez sem descontar duas vezes).
  VoidCallback liberarParaEmergencia() {
    emergenciasAbertas.value++;
    var encerrada = false;
    return () {
      if (encerrada) return;
      encerrada = true;
      emergenciasAbertas.value--;
    };
  }

  void _bloquear() {
    // Fecha o teclado de qualquer campo que estivesse em foco por baixo.
    FocusManager.instance.primaryFocus?.unfocus();
    bloqueado.value = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // Só `paused`/`hidden` contam como "saiu do app". `inactive` NÃO:
      // o próprio prompt do Face ID/código do aparelho e o seletor de
      // contatos deixam o app inativo por instantes — contar isso
      // criaria um ciclo de bloqueio.
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _foiParaSegundoPlanoEm ??= DateTime.now();
        break;
      case AppLifecycleState.resumed:
        final saiuEm = _foiParaSegundoPlanoEm;
        _foiParaSegundoPlanoEm = null;
        if (saiuEm != null &&
            DateTime.now().difference(saiuEm) >= tempoEmSegundoPlanoParaBloquear) {
          bloquearSeHouverSessao();
        }
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }
}

/// Telas de emergência que precisam funcionar SEM desbloqueio (câmera/tela
/// vermelha do SOS, alerta recebido, alarme de rotina, cronômetro): a
/// camada de bloqueio fica escondida enquanto a tela existir.
mixin LiberaBloqueioEnquantoAberta<T extends StatefulWidget> on State<T> {
  VoidCallback? _encerrarLiberacao;

  @override
  void initState() {
    super.initState();
    _encerrarLiberacao = BloqueioAppService().liberarParaEmergencia();
  }

  @override
  void dispose() {
    _encerrarLiberacao?.call();
    super.dispose();
  }
}
