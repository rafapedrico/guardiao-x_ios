import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import '../app_navigator.dart';
import '../models/alarme_rotina.dart';
import '../screens/despertador_ios_screen.dart';
import 'ciclo_despertador.dart';
import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'l10n_headless_service.dart';
import 'notificacao_service.dart';

/// Despertador de check-in no iOS (alarmes de rotina da aba Família): faz o
/// alarme TOCAR de verdade no horário.
///   - iOS 26+ com o AlarmKit autorizado: um alarme do sistema por ocorrência
///     (som escolhido em Configurações, toca mesmo no silencioso). O botão
///     "Desativar despertador" abre a [DespertadorIosScreen] com o teclado do
///     PIN. Parar o som pelo sistema não cancela o alerta — só o PIN.
///   - Sem AlarmKit: notificações sensíveis ao tempo com o mesmo som, a ação
///     "Desativar despertador" e repetições a cada 30 s durante a tolerância,
///     canceladas no PIN correto. O iOS guarda no máximo 64 notificações
///     pendentes: entram só as ocorrências que couberem (somando as demais
///     notificações do app, como as do cronômetro), e a última vaga vira um
///     aviso para abrir o app antes da primeira ocorrência que ficou de fora
///     — nunca um despertador descartado em silêncio. O agendamento é refeito
///     ao abrir o app, ao voltar do segundo plano e a cada mudança.
///   - Com o app aberto no horário, a tela do despertador abre sozinha.
///   - Janelas de localização (2 h antes até o fim da tolerância) vão para o
///     rastreamento nativo gravar a posição no documento do despertador.
/// O alerta no fim da tolerância é enviado pela própria tela; o servidor
/// fica como reserva (prazo = horário + tolerância).
class DespertadorIosService with WidgetsBindingObserver {
  DespertadorIosService._internal();
  static final DespertadorIosService _instance = DespertadorIosService._internal();
  factory DespertadorIosService() => _instance;

  static const String prefixoPayload = 'despertador:';
  static const MethodChannel _canal = MethodChannel('guardiaox/despertador');

  static const int _limiteNotificacoesIos = 64;
  static const Duration _intervaloRepeticao = Duration(seconds: 30);
  static const int _maxRepeticoes = 99;
  static const int _maxAlarmesSistema = 40;
  static const Duration _horizonte = Duration(days: 8);
  static const int _idAvisoReagendar = 1999999990;

  bool _iniciado = false;
  bool _emPrimeiroPlano = true;
  Timer? _timerProximaOcorrencia;
  Future<void>? _reagendamentoEmCurso;
  bool _reagendarDeNovo = false;

  static String payloadDe(int idAlarme, int ciclo) => '$prefixoPayload$idAlarme:$ciclo';

  /// UUID estável de uma ocorrência (id do alarme no AlarmKit).
  static String uuidDe(int idAlarme, int ciclo) {
    final h = md5.convert(utf8.encode('guardiaox-despertador-$idAlarme-$ciclo')).toString();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-'
        'a${h.substring(17, 20)}-${h.substring(20, 32)}';
  }

  /// Id da notificação [repeticao] (0 = o toque no horário) de uma
  /// ocorrência — sempre o mesmo para a mesma ocorrência.
  static int _idNotificacao(int idAlarme, DateTime horario, int repeticao) {
    final dia = DateTime.utc(horario.year, horario.month, horario.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
    return 1000000000 + (idAlarme % 500) * 2000000 + (dia % 10000) * 100 + repeticao;
  }

  Future<void> iniciar() async {
    if (!Platform.isIOS || _iniciado) return;
    _iniciado = true;
    WidgetsBinding.instance.addObserver(this);
    _canal.setMethodCallHandler((chamada) async {
      if (chamada.method == 'aberturaPorAlarme') await _verificarAberturaPendente();
    });
    await _configurarFusoLocal();
    await reagendar();
    await _verificarAberturaPendente();
    await _abrirSeEmAndamento();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _emPrimeiroPlano = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) return;
    unawaited(() async {
      await reagendar();
      await _verificarAberturaPendente();
      await _abrirSeEmAndamento();
    }());
  }

  Future<void> _configurarFusoLocal() async {
    try {
      final nome = await _canal.invokeMethod<String>('fusoHorario');
      if (nome != null) tz.setLocalLocation(tz.getLocation(nome));
    } catch (e) {
      debugPrint('⚠️ [Despertador] Fuso local indisponível (usando ${tz.local.name}): $e');
    }
  }

  /// Som escolhido em Configurações, já convertido para .caf.
  Future<String?> _somEscolhido() async {
    try {
      final config = await DatabaseHelper().getUserConfig();
      final numero = config?['som_alarme_selecionado'] as int? ?? 1;
      return await _canal.invokeMethod<String>('prepararSom', {'asset': 'assets/sounds/som_$numero.mp3'});
    } catch (e) {
      debugPrint('⚠️ [Despertador] Som escolhido indisponível — som padrão: $e');
      return null;
    }
  }

  /// Refaz todo o agendamento a partir do SQLite. Chamadas concorrentes se
  /// juntam numa só (mais uma rodada no fim, se algo mudou no meio).
  Future<void> reagendar() {
    if (!Platform.isIOS) return Future.value();
    if (_reagendamentoEmCurso != null) {
      _reagendarDeNovo = true;
      return _reagendamentoEmCurso!;
    }
    final rodada = () async {
      do {
        _reagendarDeNovo = false;
        try {
          await _reagendarAgora();
        } catch (e) {
          debugPrint('⚠️ [Despertador] Falha ao reagendar: $e');
        }
      } while (_reagendarDeNovo);
    }();
    _reagendamentoEmCurso = rodada.whenComplete(() => _reagendamentoEmCurso = null);
    return _reagendamentoEmCurso!;
  }

  Future<void> _reagendarAgora() async {
    await NotificacaoService.inicializar();
    final alarmes = await DatabaseHelper().listarAlarmes();
    for (final alarme in alarmes) {
      final id = alarme['id'] as int?;
      if (id != null) await NotificacaoService.cancelarLembretesCheckinRotinaIOS(id);
    }

    final ocorrencias = <OcorrenciaDespertador>[
      for (final alarme in alarmes) ...CicloDespertador.proximas(alarme, horizonte: _horizonte),
    ]..sort((a, b) => a.horario.compareTo(b.horario));

    await _definirJanelasLocalizacao(alarmes);

    final l10n = await L10nHeadlessService.obter();
    final som = await _somEscolhido();
    String tituloDe(OcorrenciaDespertador o) => AlarmeRotina.fromMap(o.alarme).etiquetaExibida(l10n);

    var usouAlarmKit = false;
    try {
      var disponivel = await _canal.invokeMethod<bool>('alarmKitDisponivel') ?? false;
      if (disponivel && ocorrencias.isNotEmpty) {
        disponivel = await _canal.invokeMethod<bool>('pedirAutorizacaoAlarmKit') ?? false;
      }
      if (disponivel) {
        final agendados = await _canal.invokeMethod<int>('agendarAlarmes', {
          'alarmes': [
            for (final o in ocorrencias.take(_maxAlarmesSistema))
              {
                'uuid': uuidDe(o.idAlarme, o.ciclo),
                'epochMs': o.ciclo,
                'titulo': tituloDe(o),
                'som': som,
                'idAlarme': o.idAlarme,
                'ciclo': o.ciclo,
              },
          ],
          'textoParar': l10n.despertadorPararSomAcao,
          'textoAbrir': l10n.despertadorDesativarAcao,
        });
        usouAlarmKit = (agendados ?? -1) >= 0;
      }
    } catch (e) {
      debugPrint('⚠️ [Despertador] AlarmKit indisponível — usando notificações: $e');
    }

    await _agendarNotificacoes(usouAlarmKit ? const [] : ocorrencias, som, tituloDe, l10n.despertadorNotifCorpo);
    _armarTimerPrimeiroPlano(ocorrencias);
    debugPrint('⏰ [Despertador] ${ocorrencias.length} ocorrência(s) nos próximos ${_horizonte.inDays} dias '
        '— ${usouAlarmKit ? "AlarmKit" : "notificações"}.');
  }

  Future<void> _agendarNotificacoes(
    List<OcorrenciaDespertador> ocorrencias,
    String? som,
    String Function(OcorrenciaDespertador) tituloDe,
    String corpo,
  ) async {
    final pendentes = await NotificacaoService.notificacoesPendentes();
    for (final p in pendentes) {
      if ((p.payload ?? '').startsWith(prefixoPayload) || p.id == _idAvisoReagendar) {
        await NotificacaoService.cancelarNotificacao(p.id);
      }
    }
    if (ocorrencias.isEmpty) return;

    final outras = pendentes
        .where((p) => !(p.payload ?? '').startsWith(prefixoPayload) && p.id != _idAvisoReagendar)
        .length;
    // Uma vaga fica reservada para o aviso de reagendamento.
    var vagas = _limiteNotificacoesIos - outras - 1;
    final agora = DateTime.now();

    for (var i = 0; i < ocorrencias.length; i++) {
      final o = ocorrencias[i];
      final repeticoes = (o.minutosTolerancia * 60 ~/ _intervaloRepeticao.inSeconds).clamp(0, _maxRepeticoes);
      var custo = 1 + repeticoes;
      if (custo > vagas) {
        if (i == 0 && vagas > 0) {
          custo = vagas; // Ao menos o toque e parte das repetições da primeira.
        } else {
          final quando = o.horario.subtract(const Duration(hours: 1));
          final l10n = await L10nHeadlessService.obter();
          await NotificacaoService.agendarNotificacaoDespertador(
            id: _idAvisoReagendar,
            quando: quando.isAfter(agora) ? quando : agora.add(const Duration(minutes: 1)),
            titulo: l10n.despertadorAvisoReagendarTitulo,
            corpo: l10n.despertadorAvisoReagendarCorpo(tituloDe(o), _hora(o.horario)),
            payload: 'reagendar_despertador',
          );
          debugPrint('⚠️ [Despertador] Limite de notificações: ${ocorrencias.length - i} '
              'ocorrência(s) ficam para o próximo reagendamento (aviso agendado).');
          return;
        }
      }
      final payload = payloadDe(o.idAlarme, o.ciclo);
      for (var r = 0; r < custo; r++) {
        await NotificacaoService.agendarNotificacaoDespertador(
          id: _idNotificacao(o.idAlarme, o.horario, r),
          quando: o.horario.add(_intervaloRepeticao * r),
          titulo: tituloDe(o),
          corpo: corpo,
          payload: payload,
          som: som,
        );
      }
      vagas -= custo;
    }
  }

  static String _hora(DateTime h) =>
      '${h.hour.toString().padLeft(2, '0')}:${h.minute.toString().padLeft(2, '0')}';

  Future<void> _definirJanelasLocalizacao(List<Map<String, dynamic>> alarmes) async {
    final uid = FirebaseAuthService().uidAtual;
    final janelas = <Map<String, dynamic>>[];
    if (uid != null) {
      for (final alarme in alarmes) {
        final o = await CicloDespertador.alvo(alarme);
        if (o == null) continue;
        janelas.add({
          'doc': '${uid}_${o.idAlarme}',
          'inicioMs': o.horario.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
          'fimMs': o.fimTolerancia.millisecondsSinceEpoch,
        });
      }
    }
    try {
      await _canal.invokeMethod<void>('definirJanelasLocalizacao', {'janelas': janelas});
    } catch (_) {}
  }

  /// Com o app aberto no horário, a tela do despertador abre sozinha.
  void _armarTimerPrimeiroPlano(List<OcorrenciaDespertador> ocorrencias) {
    _timerProximaOcorrencia?.cancel();
    if (ocorrencias.isEmpty) return;
    final proxima = ocorrencias.first;
    final espera = proxima.horario.difference(DateTime.now());
    if (espera > const Duration(days: 1)) return;
    _timerProximaOcorrencia = Timer(espera.isNegative ? Duration.zero : espera, () async {
      final dados = await DatabaseHelper().buscarAlarmePorId(proxima.idAlarme);
      if (dados != null && (dados['ativo'] as int?) == 1 && !CicloDespertador.pausadoHoje(dados)) {
        await abrirTela(proxima.idAlarme, proxima.ciclo);
      }
      await reagendar();
    });
  }

  /// Ocorrência terminada (PIN correto ou alerta enviado): cancela o que
  /// faltava dela e reagenda.
  Future<void> resolverOcorrencia(int idAlarme, int ciclo) async {
    if (!Platform.isIOS) return;
    await CicloDespertador.marcarResolvido(idAlarme, ciclo);
    final payload = payloadDe(idAlarme, ciclo);
    for (final p in await NotificacaoService.notificacoesPendentes()) {
      if (p.payload == payload) await NotificacaoService.cancelarNotificacao(p.id);
    }
    await pararAlarmeDoSistema(idAlarme, ciclo);
    await reagendar();
  }

  /// Para o toque do AlarmKit desta ocorrência (a tela do app assume o som).
  Future<void> pararAlarmeDoSistema(int idAlarme, int ciclo) async {
    try {
      await _canal.invokeMethod<void>('pararAlarme', {'uuid': uuidDe(idAlarme, ciclo)});
    } catch (_) {}
  }

  Future<void> _verificarAberturaPendente() async {
    try {
      final pendente = await _canal.invokeMapMethod<String, dynamic>('consumirAbertura');
      final id = (pendente?['idAlarme'] as num?)?.toInt();
      final ciclo = (pendente?['ciclo'] as num?)?.toInt();
      if (id != null && ciclo != null) await abrirTela(id, ciclo, tecladoDireto: true);
    } catch (_) {}
    final payload = NotificacaoService.consumirDespertadorPendente();
    if (payload != null) await abrirPorPayload(payload, tecladoDireto: true);
  }

  /// App aberto durante a tolerância de uma ocorrência não resolvida.
  Future<void> _abrirSeEmAndamento() async {
    if (!_emPrimeiroPlano || DespertadorIosScreen.aberta) return;
    for (final alarme in await DatabaseHelper().listarAlarmes()) {
      final o = await CicloDespertador.emAndamento(alarme);
      if (o != null) {
        await abrirTela(o.idAlarme, o.ciclo);
        return;
      }
    }
  }

  Future<void> abrirPorPayload(String payload, {bool tecladoDireto = false}) async {
    final partes = payload.substring(prefixoPayload.length).split(':');
    if (partes.length != 2) return;
    final id = int.tryParse(partes[0]);
    final ciclo = int.tryParse(partes[1]);
    if (id == null || ciclo == null) return;
    await abrirTela(id, ciclo, tecladoDireto: tecladoDireto);
  }

  Future<void> abrirOcorrenciaEmAndamento(int idAlarme, {bool tecladoDireto = false}) async {
    final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    if (dados == null) return;
    final o = await CicloDespertador.emAndamento(dados);
    if (o != null) await abrirTela(o.idAlarme, o.ciclo, tecladoDireto: tecladoDireto);
  }

  /// Abre a tela do despertador da ocorrência (uma por vez). Ocorrência já
  /// resolvida neste aparelho não abre de novo.
  Future<void> abrirTela(int idAlarme, int ciclo, {bool tecladoDireto = false}) async {
    if (DespertadorIosScreen.aberta) return;
    if (await CicloDespertador.cicloResolvido(idAlarme) == ciclo) return;
    NavigatorState? navigator;
    for (var i = 0; i < 20 && navigator == null; i++) {
      navigator = appNavigatorKey.currentState;
      if (navigator == null) await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (navigator == null || DespertadorIosScreen.aberta) return;
    DespertadorIosScreen.aberta = true;
    await navigator.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/despertador'),
      builder: (_) => DespertadorIosScreen(idAlarme: idAlarme, ciclo: ciclo, tecladoDireto: tecladoDireto),
    ));
  }
}
