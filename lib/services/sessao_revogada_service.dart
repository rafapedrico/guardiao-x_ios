import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_navigator.dart';
import '../screens/sessao_encerrada_screen.dart';
import 'bloqueio_app_service.dart';
import 'notificacao_service.dart';

/// Só iOS. Regra do produto: "uma conta, um aparelho ativo" entre TODAS
/// as plataformas — o push de alerta vai só para o aparelho do último
/// login (fcmToken mais recente), então o servidor derruba a sessão dos
/// outros aparelhos a cada login (`revogarSessoesEmOutrosDispositivos` em
/// guardiao-x_servidor). O app Android não muda nada; quem precisa avisar
/// é este iPhone, que deixa de estar protegido sem perceber.
///
/// Detecção (o SDK do Firebase desloga sozinho quando a renovação do
/// token é recusada, e o [authStateChanges] passa de usuário para `null`
/// sem o usuário ter tocado em "Sair"):
/// - ao voltar ao primeiro plano: renovação forçada do token;
/// - a qualquer momento: erro de token revogado (via [authStateChanges]);
/// - ao abrir Status de Permissões ([verificarAgora]).
///
/// Ao detectar: grava a marca em disco (o Widget SOS e o próximo cold
/// start sabem explicar o motivo), dispara a notificação local e abre a
/// [SessaoEncerradaScreen].
class SessaoRevogadaService with WidgetsBindingObserver {
  SessaoRevogadaService._internal();
  static final SessaoRevogadaService _instance = SessaoRevogadaService._internal();
  factory SessaoRevogadaService() => _instance;

  static const String _chaveRevogada = 'sessao_revogada_outro_aparelho';

  /// Códigos do Firebase Auth que significam "esta sessão não vale mais".
  static const Set<String> _codigosSessaoInvalida = {
    'user-token-expired',
    'invalid-user-token',
    'user-disabled',
    'user-not-found',
  };

  bool _iniciado = false;
  bool _saidaVoluntaria = false;
  bool _tratando = false;
  String? _uidAnterior;
  StreamSubscription<User?>? _assinatura;

  /// Chamar logo depois do `Firebase.initializeApp()` — ANTES da primeira
  /// renovação de token do cold start, para enxergar a transição
  /// "sessão restaurada → deslogado pelo SDK".
  void iniciar() {
    if (!Platform.isIOS || _iniciado || Firebase.apps.isEmpty) return;
    _iniciado = true;
    WidgetsBinding.instance.addObserver(this);
    _assinatura = FirebaseAuth.instance.authStateChanges().listen((usuario) {
      final uid = usuario?.uid;
      if (_uidAnterior != null && uid == null && !_saidaVoluntaria) {
        unawaited(_aoDetectarRevogacao());
      }
      // Sessão válida de novo (login novo ou sessão restaurada no cold
      // start): a proteção está neste iPhone — limpa a marca.
      if (uid != null) unawaited(aoEntrar());
      _uidAnterior = uid;
    });
  }

  /// "Sair" do próprio usuário (ou exclusão da conta): não é revogação.
  void marcarSaidaVoluntaria() {
    _saidaVoluntaria = true;
  }

  /// A saída voluntária não aconteceu (ex: a exclusão da conta falhou).
  void desmarcarSaidaVoluntaria() {
    _saidaVoluntaria = false;
  }

  /// Login novo concluído: a proteção voltou para este iPhone.
  Future<void> aoEntrar() async {
    _saidaVoluntaria = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_chaveRevogada);
    } catch (_) {}
  }

  /// `true` se a última sessão deste aparelho foi encerrada por um login
  /// em outro aparelho (e ainda não houve login novo aqui).
  static Future<bool> foiRevogada() async {
    if (!Platform.isIOS) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_chaveRevogada) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Confere AGORA com o servidor (renovação forçada do token). Devolve
  /// `true` se a sessão deste aparelho foi encerrada. Sem rede, devolve
  /// `false` (não dá para afirmar nada) e tenta de novo na próxima vez.
  Future<bool> verificarAgora() async {
    if (!Platform.isIOS || Firebase.apps.isEmpty) return false;
    final usuario = FirebaseAuth.instance.currentUser;
    if (usuario == null) return foiRevogada();
    try {
      await usuario.getIdToken(true);
      return false;
    } on FirebaseAuthException catch (e) {
      if (_codigosSessaoInvalida.contains(e.code)) {
        await _aoDetectarRevogacao();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(verificarAgora());
  }

  Future<void> _aoDetectarRevogacao() async {
    if (_tratando) return;
    _tratando = true;
    try {
      debugPrint('🔒 [SessaoRevogadaService] Sessão encerrada por login em outro aparelho.');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_chaveRevogada, true);
      } catch (_) {}
      // Sem sessão não há o que desbloquear — o aviso aparece direto.
      BloqueioAppService().aoEncerrarSessao();
      await NotificacaoService.exibirNotificacaoSessaoEncerrada();
      exibirTela();
    } finally {
      _tratando = false;
    }
  }

  /// Abre a [SessaoEncerradaScreen] (uma única vez por cima de tudo). Se
  /// uma emergência estiver na tela (câmera do SOS, alerta recebido),
  /// empilha por cima sem destruí-la; senão, substitui a pilha.
  void exibirTela() {
    if (SessaoEncerradaScreen.aberta) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navegador = appNavigatorKey.currentState;
      if (navegador == null || SessaoEncerradaScreen.aberta) return;
      final rota = MaterialPageRoute<void>(builder: (_) => const SessaoEncerradaScreen());
      if (BloqueioAppService().emergenciasAbertas.value > 0) {
        navegador.push(rota);
      } else {
        navegador.pushAndRemoveUntil(rota, (route) => false);
      }
    });
  }

  /// Só para testes/cleanup.
  void encerrar() {
    _assinatura?.cancel();
    if (_iniciado) WidgetsBinding.instance.removeObserver(this);
    _iniciado = false;
  }
}
