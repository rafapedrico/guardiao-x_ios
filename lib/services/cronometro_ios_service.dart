import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_navigator.dart';
import '../screens/cronometro_ios_screen.dart';
import 'background_location_heartbeat_service.dart';
import 'database_helper.dart';
import 'despertador_ios_service.dart';
import 'historico_alertas_service.dart';
import 'l10n_headless_service.dart';
import 'notificacao_service.dart';

/// Fim do Cronômetro Regressivo (aba Segurança) no iOS — mesmas regras do
/// Android:
///   - no fim do tempo, notificações sensíveis ao tempo com o som escolhido
///     (`som_N.caf`) e a ação "Desligar alerta de emergência", que abre o
///     PIN direto ([CronometroIosScreen]); com o app aberto, a tela abre
///     sozinha e toca o som em loop até o PIN ou o fim da tolerância (60 s);
///   - do início até o fim da tolerância, sessão de localização em segundo
///     plano (no máximo 1x/min, regra de 30 m / 5 min, só em
///     `monitoramento/atual`) — que também mantém o app vivo;
///   - fim da tolerância sem PIN: o próprio app envia `cronometro_expirado`
///     (o servidor é a reserva, prazo = fim + 60 s);
///   - um novo cronômetro não começa durante a tolerância do anterior.
/// O ciclo é identificado pelo fim (epoch ms, `timestamp_expiracao_alarme`
/// no SQLite e `cicloEpochMs` em `alarmes_agendados/{uid}_checkin_seguranca`).
class CronometroIosService with WidgetsBindingObserver {
  CronometroIosService._internal();
  static final CronometroIosService _instance = CronometroIosService._internal();
  factory CronometroIosService() => _instance;

  static const String prefixoPayload = 'cronometro:';
  static const Duration tolerancia = Duration(seconds: 60);
  static const Duration _intervaloRepeticao = Duration(seconds: 15);
  static const String _chaveResolvido = 'cronometro_ios_ciclo_resolvido';
  static const String _consumidorLocalizacao = 'cronometro';
  static const MethodChannel _canal = MethodChannel('guardiaox/despertador');

  /// Muda quando um ciclo termina (PIN correto ou alerta) — a aba Segurança
  /// volta ao estado inicial.
  final ValueNotifier<int> ciclosEncerrados = ValueNotifier<int>(0);

  Timer? _timerFim;
  Timer? _timerPrazo;
  bool _iniciado = false;
  bool _enviandoAlerta = false;

  static int _idNotificacao(int fim, int repeticao) => 1990000000 + ((fim ~/ 1000) % 99999) * 10 + repeticao;

  Future<void> iniciar() async {
    if (!Platform.isIOS || _iniciado) return;
    _iniciado = true;
    WidgetsBinding.instance.addObserver(this);
    await _retomar();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_retomar());
  }

  Future<int?> fimDoCicloAtual() async {
    try {
      final config = await DatabaseHelper().getUserConfig();
      return int.tryParse((config?['timestamp_expiracao_alarme'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<bool> _resolvido(int fim) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getInt(_chaveResolvido) == fim;
  }

  Future<void> _marcarResolvido(int fim) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_chaveResolvido, fim);
  }

  /// `true` enquanto o ciclo anterior não terminou: o tempo zerou, a
  /// tolerância corre e nada o resolveu. Um novo cronômetro não pode
  /// começar (reiniciar o ciclo na nuvem cancelaria o alerta sem PIN).
  Future<bool> cicloEmAndamentoNaTolerancia() async {
    if (!Platform.isIOS) return false;
    final fim = await fimDoCicloAtual();
    if (fim == null) return false;
    final agora = DateTime.now().millisecondsSinceEpoch;
    if (agora < fim || agora > fim + tolerancia.inMilliseconds) return false;
    return !await _resolvido(fim);
  }

  /// Novo ciclo (chamado por `AlarmeService.agendarAlarmeEmergencia`).
  Future<void> armar(DateTime fim) async {
    if (!Platform.isIOS) return;
    await _cancelarNotificacoes();
    final l10n = await L10nHeadlessService.obter();
    final som = await DespertadorIosService.somEscolhido();
    final fimMs = fim.millisecondsSinceEpoch;
    final repeticoes = tolerancia.inSeconds ~/ _intervaloRepeticao.inSeconds;
    for (var r = 0; r < repeticoes; r++) {
      await NotificacaoService.agendarNotificacaoDespertador(
        id: _idNotificacao(fimMs, r),
        quando: fim.add(_intervaloRepeticao * r),
        titulo: l10n.cronometroNotificacaoTituloAlerta,
        corpo: l10n.cronometroNotificacaoCorpo,
        payload: '$prefixoPayload$fimMs',
        som: som,
        categoria: NotificacaoService.categoriaIosCronometro,
      );
    }
    await _sessaoLocalizacao(ate: fim.add(tolerancia));
    _armarTimers(fimMs);
    // O orçamento de 64 notificações do despertador conta estas.
    unawaited(DespertadorIosService().reagendar());
  }

  /// Ciclo encerrado antes do fim (PIN correto no desarme, alerta por 3 PINs
  /// durante a contagem) ou cancelado: nada mais toca nem é enviado.
  Future<void> cancelar() async {
    if (!Platform.isIOS) return;
    final fim = await fimDoCicloAtual();
    if (fim != null) await _marcarResolvido(fim);
    await _encerrarLocal();
  }

  Future<void> _encerrarLocal() async {
    _timerFim?.cancel();
    _timerPrazo?.cancel();
    await _cancelarNotificacoes();
    await _sessaoLocalizacao(ate: null);
    unawaited(DespertadorIosService().reagendar());
    ciclosEncerrados.value++;
  }

  Future<void> _cancelarNotificacoes() async {
    for (final p in await NotificacaoService.notificacoesPendentes()) {
      if ((p.payload ?? '').startsWith(prefixoPayload)) await NotificacaoService.cancelarNotificacao(p.id);
    }
  }

  Future<void> _sessaoLocalizacao({DateTime? ate}) async {
    try {
      if (ate == null) {
        await _canal.invokeMethod<void>('pararSessaoLocalizacao', {'consumidor': _consumidorLocalizacao});
      } else {
        await _canal.invokeMethod<void>('iniciarSessaoLocalizacao', {
          'consumidor': _consumidorLocalizacao,
          'ateMs': ate.millisecondsSinceEpoch,
        });
      }
    } catch (e) {
      debugPrint('⚠️ [CronometroIos] Sessão de localização indisponível: $e');
    }
  }

  void _armarTimers(int fimMs) {
    _timerFim?.cancel();
    _timerPrazo?.cancel();
    final agora = DateTime.now().millisecondsSinceEpoch;
    final ateFim = Duration(milliseconds: (fimMs - agora).clamp(0, 1 << 40));
    final atePrazo = Duration(milliseconds: (fimMs + tolerancia.inMilliseconds - agora).clamp(0, 1 << 40));
    _timerFim = Timer(ateFim, () => unawaited(abrirTela(fimMs)));
    _timerPrazo = Timer(atePrazo, () => unawaited(enviarAlertaTempoEsgotado(fimMs)));
  }

  /// Abertura do app / volta do segundo plano.
  Future<void> _retomar() async {
    final fim = await fimDoCicloAtual();
    if (fim == null || await _resolvido(fim)) return;
    final agora = DateTime.now().millisecondsSinceEpoch;
    if (agora < fim) {
      _armarTimers(fim);
      return;
    }
    if (agora <= fim + tolerancia.inMilliseconds) {
      _armarTimers(fim);
      await abrirTela(fim);
      return;
    }
    // O app não estava vivo no fim da tolerância: o servidor (reserva) é
    // quem alerta por este ciclo — o app não manda um segundo alerta.
    await _marcarResolvido(fim);
    await _encerrarLocal();
  }

  Future<void> abrirPorPayload(String payload, {bool tecladoDireto = false}) async {
    final fim = int.tryParse(payload.substring(prefixoPayload.length));
    if (fim != null) await abrirTela(fim, tecladoDireto: tecladoDireto);
  }

  /// Tela do fim do cronômetro (uma por vez), só dentro da tolerância de um
  /// ciclo não resolvido.
  Future<void> abrirTela(int fim, {bool tecladoDireto = false}) async {
    if (CronometroIosScreen.aberta || await _resolvido(fim)) return;
    final agora = DateTime.now().millisecondsSinceEpoch;
    if (agora > fim + tolerancia.inMilliseconds) return;
    NavigatorState? navigator;
    for (var i = 0; i < 20 && navigator == null; i++) {
      navigator = appNavigatorKey.currentState;
      if (navigator == null) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (navigator == null || CronometroIosScreen.aberta) return;
    CronometroIosScreen.aberta = true;
    await navigator.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/cronometro'),
      builder: (_) => CronometroIosScreen(fimEpochMs: fim, tecladoDireto: tecladoDireto),
    ));
  }

  /// PIN correto na tela do fim: nenhum alerta.
  Future<void> confirmarPinCorreto(int fim) async {
    await _marcarResolvido(fim);
    BackgroundLocationHeartbeatService().confirmarCheckinSeguro();
    await HistoricoAlertasService().registrarEvento(tipo: TipoAlertaHistorico.cronometroDesarmado);
    try {
      await DatabaseHelper().limparContextoTimerAtivo();
    } catch (_) {}
    final l10n = await L10nHeadlessService.obter();
    await NotificacaoService.exibirAvisoDespertador(
      id: 1999999994,
      titulo: l10n.cronometroNotificacaoTituloAlerta,
      corpo: l10n.notifPinCorretoCronometroCorpo,
    );
    await _encerrarLocal();
  }

  /// 3 PINs errados na tela do fim: `tentativa_desarme_incorreto`.
  Future<void> enviarAlertaPinIncorreto(int fim) async {
    final l10n = await L10nHeadlessService.obter();
    await _enviarAlerta(
      fim,
      tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
      motivo: l10n.historicoCronometroPinIncorretoMotivo,
      aviso: l10n.notif3PinsCronometroCorpo,
    );
  }

  /// Fim da tolerância sem PIN: `cronometro_expirado`, enviado pelo app.
  Future<void> enviarAlertaTempoEsgotado(int fim) async {
    final l10n = await L10nHeadlessService.obter();
    await _enviarAlerta(
      fim,
      tipo: TipoAlertaHistorico.cronometroExpirado,
      motivo: l10n.historicoCronometroFalhaMotivo,
      aviso: l10n.notifCronometroExpiradoCorpo,
    );
  }

  Future<void> _enviarAlerta(
    int fim, {
    required String tipo,
    required String motivo,
    required String aviso,
  }) async {
    if (_enviandoAlerta || await _resolvido(fim)) return;
    _enviandoAlerta = true;
    try {
      // Ciclo resolvido localmente e na nuvem (ALERTA_DISPARADO) antes do
      // envio: o servidor não manda um segundo alerta por este ciclo.
      await _marcarResolvido(fim);
      BackgroundLocationHeartbeatService().confirmarAlertaJaDisparado();
      await HistoricoAlertasService().dispararAlertaCronometro(
        tipo: tipo,
        motivo: motivo,
        eventoId: 'cronometro_$fim',
      );
      try {
        await DatabaseHelper().limparContextoTimerAtivo();
      } catch (_) {}
      final l10n = await L10nHeadlessService.obter();
      await NotificacaoService.exibirAvisoDespertador(
        id: 1999999995,
        titulo: l10n.cronometroNotificacaoTituloAlerta,
        corpo: aviso,
      );
      await _encerrarLocal();
    } finally {
      _enviandoAlerta = false;
    }
  }
}
