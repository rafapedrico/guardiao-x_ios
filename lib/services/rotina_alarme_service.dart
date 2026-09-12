import 'dart:async';
import 'dart:io' show Platform;
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import '../models/alarme_rotina.dart';
import 'alarme_agendado_cloud_service.dart';
import 'background_location_heartbeat_service.dart';
import 'database_helper.dart';
import 'emergency_alert_service.dart';
import 'firebase_sync_service.dart';
import 'l10n_headless_service.dart';
import 'notificacao_service.dart';
import 'plano_ciclo_service.dart';

// Canal unificado para comunicação nativa
const MethodChannel _canalRotinaAlarme =
    MethodChannel('com.example.security_check_app/rotina_alarme');

/// Chave (SharedPreferences) que sinaliza ao lado Dart em primeiro plano
/// ([AlarmeDisparadoScreen]) que o alarme de rotina ENTROU na "janela
/// final" de 60 segundos (tolerância já expirada, segunda e última chance
/// antes do alerta de emergência ser disparado de verdade). Como o
/// callback headless do `android_alarm_manager_plus` roda em um isolate
/// completamente separado do isolate da UI em primeiro plano, esta é a
/// mesma técnica de "sinalização via disco" já usada por
/// `alarme_disparando_no_momento`/`stop_current_alarm`.
const String chaveAlarmeFaseFinal = 'alarme_fase_final';

/// Chave (SharedPreferences) com o instante EXATO (epoch em
/// milissegundos) em que o alarme REAL de emergência da janela final vai
/// disparar (ver [_callbackJanelaFinalExpirada]). Gravado junto com
/// [chaveAlarmeFaseFinal] para que [AlarmeDisparadoScreen] calcule o
/// tempo restante correto no cronômetro visual do diálogo de PIN, mesmo
/// que o polling (a cada 1s) só detecte a fase final um pouco depois do
/// instante exato em que ela começou no isolate headless.
const String chaveAlarmeFaseFinalDeadlineEpochMs =
    'alarme_fase_final_deadline_epoch_ms';

/// Chave (SharedPreferences) sinalizando que o alerta de emergência REAL
/// da janela final já foi disparado (nuvem + SMS/local já tentados) —
/// gravada pelo callback headless [_callbackJanelaFinalExpirada] DEPOIS
/// de concluir o disparo. [AlarmeDisparadoScreen] usa isso como um
/// fallback (o caminho PRIMÁRIO é o próprio diálogo de PIN em primeiro
/// plano detectando a falha diretamente) para garantir que a tela pare o
/// som, feche o teclado e mostre a confirmação mesmo se, por algum
/// motivo, o diálogo em primeiro plano não tiver dado conta sozinho.
const String chaveAlarmeEmergenciaDisparada = 'alarme_emergencia_disparada';

/// Chave (SharedPreferences) sinalizando que o fluxo do alarme de rotina
/// foi TOTALMENTE resolvido (PIN correto confirmado OU alerta de
/// emergência já disparado) — sinal para QUALQUER instância de
/// [AlarmeDisparadoScreen] parar seu próprio som e se fechar.
///
/// MOTIVO DE EXISTIR: como [RotinaCheckinAlarmActivity] é lançada via
/// [android.content.Intent] puro (sem `FlutterEngineCache`, apesar do
/// que um comentário antigo do código nativo afirmava), ela cria um
/// engine Flutter/isolate Dart TOTALMENTE INDEPENDENTE do engine da
/// `MainActivity` — cada um com sua PRÓPRIA cópia de todo o estado Dart
/// (inclusive o AudioPlayer do som e a trava estática
/// `_instanciaGraficaAberta`, que só protege contra duplicidade DENTRO
/// do mesmo isolate). Na prática, isso significa que podem existir DUAS
/// instâncias de [AlarmeDisparadoScreen] rodando em paralelo — uma
/// dentro da MainActivity (empurrada pelo polling de
/// `alarme_disparando_no_momento`) e outra dentro da
/// RotinaCheckinAlarmActivity (lançada pelo caminho nativo de
/// RotinaAlarmWakeService) — e resolver o fluxo em UMA delas (ex:
/// confirmar o PIN) não interrompe automaticamente o som/timers da
/// OUTRA, já que cada uma tem seu próprio AudioPlayer/Timer em memória.
///
/// Como o SharedPreferences É compartilhado entre isolates (é o mesmo
/// arquivo nativo no disco), esta flag funciona como um sinal confiável
/// entre eles: assim que qualquer instância resolve o fluxo, ela grava
/// esta flag; TODAS as instâncias (via seu próprio polling de 1s) a
/// detectam e se encerram — mesmo a(s) que não foram a que resolveu.
///
/// Diferente de `stop_current_alarm`/`alarme_disparando_no_momento`
/// (que já são alterados no simples TOQUE do botão "Interromper
/// Alarme", antes mesmo do PIN ser confirmado), esta flag SÓ vira
/// `true` na resolução DEFINITIVA — nunca antes.
const String chaveAlarmeFluxoResolvido = 'alarme_fluxo_resolvido';

/// Chave (SharedPreferences) sinalizando que o app foi fechado à força
/// (gesto de "jogar para cima"/force close nos Recentes) ENQUANTO o
/// alarme de rotina ainda tocava sem confirmação — especificação do
/// usuário (2026-08-07, item 4): esse gesto deve disparar o alerta de
/// emergência IMEDIATAMENTE, em vez de simplesmente reabrir a tela e
/// continuar tocando como antes.
///
/// Gravada pelo lado NATIVO (`RotinaAlarmWakeService.onTaskRemoved`, ver
/// `RotinaAlarmFluxoState.marcarFechamentoForcado`) num arquivo de
/// SharedPreferences 100% nativo — NÃO o `FlutterSharedPreferences` que
/// esta chave Dart normalmente usaria, já que não há nenhum engine
/// Flutter vivo no exato momento do `onTaskRemoved` para escrever nele.
/// [AlarmeDisparadoScreen] consome o sinal assim que seu próprio engine
/// (re)inicia, via o método nativo `consumirFechamentoForcado` (que já
/// limpa a flag nativa ao ler, evitando reprocessar no próximo ciclo).
const String chaveAlarmeFechamentoForcado = 'alarme_fechamento_forcado';

class RotinaAlarmeService {
  RotinaAlarmeService._internal();
  static final RotinaAlarmeService _instance = RotinaAlarmeService._internal();
  factory RotinaAlarmeService() => _instance;

  static const int _offsetIdCheckin = 20000;
  static const int _offsetIdTolerancia = 30000;
  static const int _offsetIdJanelaFinal = 40000;

  /// Duração da janela final (última chance) após a tolerância expirar —
  /// especificação do usuário (2026-08-07): tempo TOTAL de toque =
  /// tolerância cadastrada + 60 segundos adicionais. O alarme toca
  /// novamente, exibe o teclado de PIN diretamente (sem exigir novo
  /// toque no botão) com este limite estrito, e QUALQUER falha (3ª
  /// tentativa de PIN incorreta ou tempo esgotado) dispara o alerta de
  /// emergência imediatamente. Este MESMO valor também é usado para
  /// calcular `prazoFinalDisparo` (ver [BackgroundLocationHeartbeatService]/
  /// `AlarmeAgendadoModel`), o prazo que a Cloud Function agendada
  /// (`functions/scheduledAlarmMonitor.js`) usa como rede de segurança
  /// caso o aparelho fique sem bateria/internet — mudar aqui já ajusta
  /// os dois lados automaticamente, sem precisar mexer na function.
  static const Duration duracaoJanelaFinal = Duration(seconds: 60);

  static int _idCheckin(int idAlarme) => _offsetIdCheckin + idAlarme;
  static int _idTolerancia(int idAlarme) => _offsetIdTolerancia + idAlarme;
  static int _idJanelaFinal(int idAlarme) => _offsetIdJanelaFinal + idAlarme;

  static Future<void> agendarAlarme(Map<String, dynamic> alarmeMap) async {
    final id = alarmeMap['id'] as int?;
    if (id == null) return;

    final hora = alarmeMap['hora'] as int? ?? 0;
    final minuto = alarmeMap['minuto'] as int? ?? 0;
    final diasSemanaCsv = alarmeMap['dias_semana'] as String? ?? '';

    // MIGRAÇÃO iOS (decisão de produto, 2026-09-12): agenda os lembretes
    // locais via NotificacaoService/zonedSchedule — no-op completo no
    // Android ([NotificacaoService.agendarLembretesCheckinRotinaIOS] já
    // guarda `Platform.isIOS` internamente), então o restante deste
    // método (100% `android_alarm_manager_plus`) continua intacto e sem
    // nenhuma mudança de comportamento. Fire-and-forget: nunca atrasa o
    // agendamento nativo abaixo. A garantia real de disparo no iOS é da
    // Cloud Function `scheduledAlarmMonitor.js`, não deste agendamento —
    // ver documentação completa no método chamado.
    unawaited(() async {
      final l10n = await L10nHeadlessService.obter();
      final etiqueta = AlarmeRotina.fromMap(alarmeMap).etiquetaExibida(l10n);
      final minutosTolerancia = alarmeMap['minutos_tolerancia'] as int? ?? 10;
      await NotificacaoService.agendarLembretesCheckinRotinaIOS(
        idAlarme: id,
        etiqueta: etiqueta,
        hora: hora,
        minuto: minuto,
        diasSemanaCsv: diasSemanaCsv,
        minutosTolerancia: minutosTolerancia,
      );
    }());

    final proximoDisparo = _calcularProximoDisparo(hora, minuto, diasSemanaCsv);
    if (proximoDisparo == null) {
      final agora = DateTime.now();
      final candidato = DateTime(agora.year, agora.month, agora.day, hora, minuto);
      if (candidato.isBefore(agora)) return;
      await _agendarNativo(id, candidato);
      // Ver documentação completa em
      // [BackgroundLocationHeartbeatService.registrarAlarmeRotinaImediatamente]
      // — grava o dead man's switch na nuvem NA HORA do agendamento,
      // nunca só quando faltar ≤48h para o disparo. Fire-and-forget:
      // nunca atrasa/bloqueia o agendamento nativo já concluído acima.
      unawaited(BackgroundLocationHeartbeatService()
          .registrarAlarmeRotinaImediatamente(alarmeMap));
      return;
    }

    await _agendarNativo(id, proximoDisparo);
    unawaited(BackgroundLocationHeartbeatService()
        .registrarAlarmeRotinaImediatamente(alarmeMap));
  }

  static Future<void> _agendarNativo(int idAlarme, DateTime dataHoraDisparo) async {
    // MIGRAÇÃO iOS: `android_alarm_manager_plus` não tem NENHUMA
    // implementação nessa plataforma — chamar seus métodos sem essa
    // guarda arriscaria lançar uma exceção não tratada (diferente da
    // maioria dos outros canais deste app, que já eram protegidos por
    // try/catch). O bloco inteiro fica restrito ao Android; o lembrete
    // local equivalente do iOS já foi agendado em [agendarAlarme]
    // (chamador desta função), via
    // [NotificacaoService.agendarLembretesCheckinRotinaIOS].
    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(_idCheckin(idAlarme));

      await AndroidAlarmManager.oneShotAt(
        dataHoraDisparo,
        _idCheckin(idAlarme),
        _callbackCheckinRotina,
        exact: true,
        wakeup: true,
        // CORREÇÃO (Doze/deep sleep): sem isto, o Android pode ADIAR o
        // disparo deste alarme por minutos/horas quando o aparelho está em
        // repouso profundo, mesmo sendo "exact" — `allowWhileIdle` (que o
        // pacote traduz para `setExactAndAllowWhileIdle` nativo) é o que
        // realmente garante o disparo no segundo programado independente
        // do estado de energia do aparelho.
        allowWhileIdle: true,
        rescheduleOnReboot: true,
        params: {'idAlarme': idAlarme},
      );

      // Agenda também o alarme NATIVO paralelo (100% independente do
      // Flutter/Dart, ver [RotinaAlarmNativeReceiver]) para o MESMO
      // horário — é ele quem garante, de forma robusta a Doze, que o
      // aparelho acorde e a tela do alarme abra mesmo se o isolate
      // headless do android_alarm_manager_plus for suspenso/encerrado
      // antes de conseguir agir.
      await agendarAlarmeNativo(idAlarme, dataHoraDisparo);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('stop_current_alarm');

    debugPrint(
        '⏰ Alarme de rotina #$idAlarme agendado para ${dataHoraDisparo.toIso8601String()}');
  }

  /// Agenda o alarme NATIVO paralelo (ver `RotinaAlarmPlugin.kt` /
  /// [RotinaAlarmNativeReceiver]) para o MESMO horário do alarme Dart
  /// acima, usando `setExactAndAllowWhileIdle` diretamente no
  /// `AlarmManager` do Android — um caminho que não depende de NENHUM
  /// engine Flutter estar vivo para disparar. Nunca lança exceção; se a
  /// chamada nativa falhar por qualquer motivo, o alarme Dart "normal"
  /// ainda tenta funcionar por conta própria.
  static Future<void> agendarAlarmeNativo(int idAlarme, DateTime dataHoraDisparo) async {
    try {
      await _canalRotinaAlarme.invokeMethod('agendarAlarmeNativo', {
        'idAlarme': idAlarme,
        'epochMillis': dataHoraDisparo.millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao agendar alarme nativo paralelo #$idAlarme: $e');
    }
  }

  /// Cancela o alarme NATIVO paralelo agendado por [agendarAlarmeNativo].
  /// Nunca lança exceção.
  static Future<void> cancelarAlarmeNativo(int idAlarme) async {
    try {
      await _canalRotinaAlarme.invokeMethod('cancelarAlarmeNativo', {
        'idAlarme': idAlarme,
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao cancelar alarme nativo paralelo #$idAlarme: $e');
    }
  }

  /// Libera o WakeLock e encerra o `RotinaAlarmWakeService` (ver
  /// `RotinaAlarmWakeService.kt`) — DEVE ser chamado a partir do isolate
  /// em PRIMEIRO PLANO assim que o fluxo do alarme de rotina for
  /// resolvido (PIN confirmado ou alerta de emergência já disparado),
  /// para não manter a CPU do aparelho acordada além do necessário.
  /// Seguro mesmo se o serviço não estiver rodando; nunca lança exceção.
  static Future<void> pararServicoForeground() async {
    try {
      await _canalRotinaAlarme.invokeMethod('pararServicoForeground');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar serviço em primeiro plano do alarme: $e');
    }
  }

  /// Calcula o próximo horário de disparo previsto para [alarmeMap] (o
  /// MESMO algoritmo usado internamente por [agendarAlarme]), SEM agendar
  /// nada — usado por `BackgroundLocationHeartbeatService` para decidir
  /// se um alarme está dentro da janela de heartbeat (≤ 2h do disparo),
  /// sem duplicar/arriscar divergir da lógica de agendamento real.
  static DateTime? proximoDisparoPrevisto(Map<String, dynamic> alarmeMap) {
    final hora = alarmeMap['hora'] as int? ?? 0;
    final minuto = alarmeMap['minuto'] as int? ?? 0;
    final diasSemanaCsv = alarmeMap['dias_semana'] as String? ?? '';

    final proximo = _calcularProximoDisparo(hora, minuto, diasSemanaCsv);
    if (proximo != null) return proximo;

    final agora = DateTime.now();
    final candidato = DateTime(agora.year, agora.month, agora.day, hora, minuto);
    return candidato.isBefore(agora) ? null : candidato;
  }

  static DateTime? _calcularProximoDisparo(int hora, int minuto, String diasSemanaCsv) {
    final dias = diasSemanaCsv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
    if (dias.isEmpty) return null;

    final agora = DateTime.now();
    for (int offset = 0; offset < 8; offset++) {
      final candidatoData = agora.add(Duration(days: offset));
      final diaSemanaCandidato = candidatoData.weekday;
      if (!dias.contains(diaSemanaCandidato)) continue;

      final candidato = DateTime(
        candidatoData.year,
        candidatoData.month,
        candidatoData.day,
        hora,
        minuto,
      );
      if (candidato.isAfter(agora)) return candidato;
    }
    return null;
  }

  /// REGRA DE NEGÓCIO (Alarme de Rotina, pedido explícito do usuário,
  /// 2026-09-04): dentro dos 10 dias ativos do mês (ou Premium), os
  /// alarmes de rotina funcionam de forma totalmente ilimitada. Fora
  /// dessa janela (20 dias bloqueados do Plano Free), NENHUM alarme de
  /// rotina deve continuar agendado — chamado uma vez por sessão (ver
  /// `main.dart::iniciarServicosPosLoginOuDashboard`, logo após
  /// [PlanoCicloService.iniciar]) para desativar automaticamente todo
  /// alarme que porventura ainda esteja ativo quando o ciclo vira de
  /// "ativo" para "bloqueado" — sem exigir que o usuário abra a aba
  /// Família e desative um por um manualmente.
  ///
  /// Mesmo par cancelamento nativo + `ativo = 0` no SQLite já usado pelo
  /// switch manual da aba Família (ver `FamiliaTabState._alternarAtivo`),
  /// para a lista já refletir o estado real na próxima vez que a aba for
  /// aberta. `status == null` (falha ao consultar — sem sessão, sem rede)
  /// NUNCA desativa nada, mesma blindagem permissiva já usada em todo o
  /// resto do app: uma falha técnica no controle de monetização não deve
  /// desligar, por conta própria, um recurso de segurança já configurado
  /// pelo usuário.
  static Future<void> desativarAlarmesSePlanoBloqueado() async {
    try {
      final status = await PlanoCicloService().obterStatusAtualizado();
      if (status == null || status.ativo) return;

      final db = DatabaseHelper();
      final alarmes = await db.listarAlarmes();
      final ativos = alarmes.where((mapa) => (mapa['ativo'] as int?) == 1);

      for (final mapa in ativos) {
        final id = mapa['id'] as int;
        await cancelarAlarme(id);
        await db.alternarAtivoAlarme(id, false);
        debugPrint(
            '🔒 [RotinaAlarmeService] Alarme #$id desativado automaticamente — '
            'Plano Free fora da janela de 10 dias ativos do mês.');
      }
    } catch (e) {
      debugPrint('⚠️ [RotinaAlarmeService] Falha ao desativar alarmes por plano bloqueado: $e');
    }
  }

  static Future<void> cancelarAlarme(int idAlarme) async {
    // NOVO (sincronização imediata, 2026-08-23): avisa a nuvem ANTES de
    // qualquer outra coisa — fecha a janela de corrida com a Cloud
    // Function agendada (`monitorarAlarmesAgendados`, a cada 2min), que
    // senão poderia encontrar o documento ainda PENDENTE e disparar um
    // alerta falso para um alarme que o usuário acabou de cancelar. Ver
    // [AlarmeAgendadoCloudService.marcarCancelado].
    unawaited(AlarmeAgendadoCloudService().marcarCancelado(idAlarme.toString()));

    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(_idCheckin(idAlarme));
      await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
      await AndroidAlarmManager.cancel(_idJanelaFinal(idAlarme));
      await cancelarAlarmeNativo(idAlarme);
    }
    // No iOS, [cancelarNotificacaoCheckin] já cancela os lembretes
    // locais equivalentes (ver [NotificacaoService.cancelarLembretesCheckinRotinaIOS]).
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    await _limparFlagsDeFaseFinal();
    debugPrint('⏰ Alarme de rotina #$idAlarme cancelado.');
  }

  /// CORREÇÃO (bug real observado em teste): "pausar só por hoje"
  /// (gesto de deslizar na aba Família, ver
  /// `familia_tab.dart#_pausarAlarmePorHoje`) só gravava uma coluna no
  /// SQLite (`alarme_pausado`) — nunca cancelava o disparo já agendado
  /// no `AndroidAlarmManager`/alarme nativo paralelo, que continuava
  /// tocando normalmente no horário. Este método cancela de fato TUDO
  /// que estava agendado para hoje (mesmos 3 alarmes + o nativo
  /// paralelo, igual [cancelarAlarme]/[pausarAlarme]) e reagenda
  /// diretamente a partir de AMANHÃ, pulando o disparo de hoje por
  /// completo — em vez de depender de uma checagem em tempo de disparo
  /// (que exigiria o alarme acordar a tela/som antes de decidir abortar).
  static Future<void> pausarAlarmePorHoje(
    int idAlarme,
    Map<String, dynamic> alarmeMap,
  ) async {
    // NOVO (sincronização imediata, 2026-08-23): mesmo motivo de
    // [cancelarAlarme] — o disparo de HOJE está sendo pulado, então a
    // nuvem precisa saber ANTES da Cloud Function agendada rodar de
    // novo. `sinalizarNovoCiclo` garante que, quando o heartbeat
    // registrar o PRÓXIMO disparo (amanhã ou depois), o documento nasça
    // PENDENTE de novo em vez de herdar este CANCELADO de hoje — ver
    // [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
    unawaited(AlarmeAgendadoCloudService().marcarCancelado(idAlarme.toString()));
    AlarmeAgendadoCloudService().sinalizarNovoCiclo(idAlarme.toString());

    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(_idCheckin(idAlarme));
      await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
      await AndroidAlarmManager.cancel(_idJanelaFinal(idAlarme));
      await cancelarAlarmeNativo(idAlarme);
    }
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    await _limparFlagsDeFaseFinal();

    final hora = alarmeMap['hora'] as int? ?? 0;
    final minuto = alarmeMap['minuto'] as int? ?? 0;
    final diasSemanaCsv = alarmeMap['dias_semana'] as String? ?? '';

    final proximoDisparo =
        _calcularProximoDisparoAPartirDeAmanha(hora, minuto, diasSemanaCsv);
    if (proximoDisparo != null) {
      await _agendarNativo(idAlarme, proximoDisparo);
    }

    // MIGRAÇÃO iOS — LIMITAÇÃO CONHECIDA: diferente do Android (que
    // cancela e reagenda um disparo ÚNICO pro próximo dia válido, via
    // [_agendarNativo] acima), os lembretes locais do iOS são
    // notificações RECORRENTES semanais (ver
    // [NotificacaoService.agendarLembretesCheckinRotinaIOS]) — o iOS não
    // tem como "pular só uma ocorrência" de uma série recorrente.
    // Rearmar a série aqui é necessário (senão o cancelamento acima
    // apagaria os lembretes de TODAS as próximas semanas, não só o de
    // hoje) — mas isso significa que o lembrete LOCAL de hoje pode
    // continuar disparando no iOS mesmo com "pausar só por hoje"
    // acionado. Sem risco de alerta falso: quem decide se o alerta de
    // emergência real dispara é exclusivamente o status CANCELADO já
    // gravado no Firestore acima
    // (`AlarmeAgendadoCloudService.marcarCancelado`/
    // `scheduledAlarmMonitor.js`), nunca a notificação local em si — só
    // uma imperfeição cosmética (um lembrete a mais, sem consequência
    // real).
    unawaited(() async {
      final l10n = await L10nHeadlessService.obter();
      final etiqueta = AlarmeRotina.fromMap(alarmeMap).etiquetaExibida(l10n);
      final minutosToleranciaIOS = alarmeMap['minutos_tolerancia'] as int? ?? 10;
      await NotificacaoService.agendarLembretesCheckinRotinaIOS(
        idAlarme: idAlarme,
        etiqueta: etiqueta,
        hora: hora,
        minuto: minuto,
        diasSemanaCsv: diasSemanaCsv,
        minutosTolerancia: minutosToleranciaIOS,
      );
    }());

    debugPrint(
        '⏸️ Alarme de rotina #$idAlarme pausado só por hoje — próximo disparo real: $proximoDisparo.');
  }

  /// Mesmo algoritmo de [_calcularProximoDisparo], mas o offset de busca
  /// começa em 1 (amanhã) em vez de 0 (hoje) — usado exclusivamente por
  /// [pausarAlarmePorHoje] para garantir que o disparo de HOJE seja
  /// pulado mesmo que o horário do alarme ainda não tenha passado.
  static DateTime? _calcularProximoDisparoAPartirDeAmanha(
    int hora,
    int minuto,
    String diasSemanaCsv,
  ) {
    final dias = diasSemanaCsv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
    if (dias.isEmpty) return null;

    final agora = DateTime.now();
    for (int offset = 1; offset <= 8; offset++) {
      final candidatoData = agora.add(Duration(days: offset));
      if (!dias.contains(candidatoData.weekday)) continue;

      return DateTime(
        candidatoData.year,
        candidatoData.month,
        candidatoData.day,
        hora,
        minuto,
      );
    }
    return null;
  }

  static Future<void> pausarAlarme(int idAlarme) async {
    // NOVO (sincronização imediata, 2026-08-23): ver
    // [AlarmeAgendadoCloudService.marcarPausado] e o mesmo raciocínio de
    // [cancelarAlarme].
    unawaited(AlarmeAgendadoCloudService().marcarPausado(idAlarme.toString()));

    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(_idCheckin(idAlarme));
      await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
      await AndroidAlarmManager.cancel(_idJanelaFinal(idAlarme));
      await cancelarAlarmeNativo(idAlarme);
    }
    // No iOS, cancela por completo a série recorrente (ver
    // [NotificacaoService.cancelarLembretesCheckinRotinaIOS]) — diferente
    // de [pausarAlarmePorHoje], esta é uma pausa TOTAL, sem reagendar
    // nada: o usuário precisa reativar o alarme manualmente (aba
    // Família), que chama [agendarAlarme] de novo do zero.
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    await _limparFlagsDeFaseFinal();

    try {
      await DatabaseHelper().definirAlarmePausado(idAlarme, true);
    } catch (e) {
      debugPrint('⚠️ Falha ao marcar alarme #$idAlarme como pausado: $e');
    }

    try {
      // Chama apenas o método que o Kotlin realmente implementa
      await _canalRotinaAlarme.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo do alarme #$idAlarme: $e');
    }

    debugPrint('⏸️ Alarme de rotina #$idAlarme pausado pelo usuário.');
  }

  /// Limpa as flags em disco usadas para sinalizar (entre o isolate
  /// headless e a UI em primeiro plano) que o alarme está tocando e/ou na
  /// janela final de 60 segundos. Chamado sempre que o alarme é
  /// cancelado/pausado/confirmado, para nunca deixar
  /// [AlarmeDisparadoScreen] "preso" numa fase antiga.
  static Future<void> _limparFlagsDeFaseFinal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(chaveAlarmeFaseFinal);
      await prefs.remove(chaveAlarmeFaseFinalDeadlineEpochMs);
      await prefs.remove(chaveAlarmeEmergenciaDisparada);
    } catch (e) {
      debugPrint('⚠️ Falha ao limpar flag de fase final: $e');
    }
  }

  /// Cancela SOMENTE o alarme nativo da janela final (`_idJanelaFinal`),
  /// sem tocar no check-in nem na tolerância. Usado por
  /// [AlarmeDisparadoScreen] quando o PRÓPRIO diálogo de PIN em primeiro
  /// plano já detectou a falha (PIN incorreto ou tempo esgotado) e já
  /// disparou o alerta real por conta própria — evita que o alarme
  /// nativo, agendado para o MESMO instante-limite, dispare de novo
  /// alguns segundos/minutos depois e envie um alerta duplicado.
  static Future<void> cancelarJanelaFinal(int idAlarme) async {
    try {
      await AndroidAlarmManager.cancel(_idJanelaFinal(idAlarme));
    } catch (e) {
      debugPrint('⚠️ Falha ao cancelar janela final do alarme #$idAlarme: $e');
    }
  }

  /// Checagem PRÉ-DISPARO (2026-08-23): garante que o Firebase esteja
  /// inicializado neste isolate (necessário sempre que esta função roda
  /// dentro de um callback HEADLESS do `android_alarm_manager_plus` — ver
  /// mesmo padrão em [_callbackJanelaFinalExpirada]) e consulta se a
  /// nuvem já assumiu o desfecho do ciclo ATUAL do alarme [idAlarme] (ver
  /// [AlarmeAgendadoCloudService.statusJaResolvidoNaNuvem]) — chamada no
  /// início dos três callbacks headless do alarme local (check-in,
  /// tolerância expirada e janela final expirada), ANTES de tocar sirene,
  /// abrir a tela ou enviar SMS/Push. `true` significa que o disparo
  /// local ATUAL deve ser abortado (a nuvem já confirmou seguro, já
  /// disparou o alerta sozinha, ou o usuário cancelou/pausou o alarme por
  /// outro caminho) — ver os pontos de chamada para o que cada callback
  /// faz nesse caso. Nunca lança exceção; `false` em caso de qualquer
  /// falha (comportamento local segue exatamente como antes desta
  /// correção).
  static Future<bool> _alarmeJaResolvidoNaNuvem(int idAlarme) async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
            .timeout(const Duration(seconds: 8));
      }
    } catch (e) {
      debugPrint(
          '⚠️ [RotinaAlarmeService] Falha ao inicializar Firebase para checagem pré-disparo: $e');
      return false;
    }

    return AlarmeAgendadoCloudService().statusJaResolvidoNaNuvem(idAlarme.toString());
  }

  static Future<void> desligarAlarme() async {
    try {
      await _canalRotinaAlarme.invokeMethod('pararAlarme');
      debugPrint('🔇 Alarme desligado pelo usuário');
    } catch (e) {
      debugPrint('⚠️ Falha ao desligar o alarme: $e');
    }
  }

  static Future<void> despausarAlarme(int idAlarme) async {
    try {
      await DatabaseHelper().definirAlarmePausado(idAlarme, false);
    } catch (e) {
      debugPrint('⚠️ Falha ao desmarcar alarme #$idAlarme como pausado: $e');
    }

    // NOVO (sincronização imediata, 2026-08-23): sinaliza que o PRÓXIMO
    // registro deste alarme pelo heartbeat (`BackgroundLocationHeartbeatService`,
    // a cada 1min quando dentro da janela de 48h) deve reiniciar o
    // documento como um ciclo PENDENTE totalmente novo, com o timestamp
    // recém-calculado — em vez de herdar o PAUSADO gravado por
    // [AlarmeAgendadoCloudService.marcarPausado]. Mesmo padrão já usado
    // por [confirmarCheckinRotina]/[_callbackJanelaFinalExpirada] ao
    // concluir um ciclo. Ver [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
    AlarmeAgendadoCloudService().sinalizarNovoCiclo(idAlarme.toString());

    try {
      final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
      final ativo = (dados?['ativo'] as int?) == 1;
      if (dados != null && ativo) {
        await agendarAlarme(dados);
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao reagendar alarme #$idAlarme após despausar: $e');
    }

    debugPrint('▶️ Alarme de rotina #$idAlarme reativado pelo usuário.');
  }

  /// Consome (lê E limpa, atomicamente, do lado nativo) a flag de
  /// "fechamento forçado" gravada por `RotinaAlarmWakeService.onTaskRemoved`
  /// — ver documentação completa em [chaveAlarmeFechamentoForcado]. `true`
  /// significa que esta abertura da tela do alarme aconteceu porque o
  /// usuário arrastou o app para fora dos Recentes enquanto ele ainda
  /// tocava sem confirmação; `false` (inclusive em caso de erro) é o
  /// caminho normal (disparo/reabertura por qualquer outro motivo).
  /// [tipoAlarme] opcional: quando informado (ex: `'cronometro'`, ver
  /// `CronometroDisparadoScreen`), só consome a flag se o tipo do alarme
  /// atualmente em andamento no lado nativo bater — ver documentação
  /// completa em `RotinaAlarmFluxoState.consumirFechamentoForcado` (Kotlin).
  /// `null` (padrão, usado pelo Alarme de Rotina) preserva o
  /// comportamento histórico: consome incondicionalmente.
  static Future<bool> consumirFechamentoForcado({String? tipoAlarme}) async {
    try {
      final resultado = await _canalRotinaAlarme.invokeMethod<bool>(
        'consumirFechamentoForcado',
        {'tipoAlarme': tipoAlarme},
      );
      return resultado ?? false;
    } catch (e) {
      debugPrint('⚠️ Falha ao consultar fechamento forçado: $e');
      return false;
    }
  }

  static Future<void> iniciarTelaAlarmeNativa(int idAlarme) async {
    try {
      await _canalRotinaAlarme.invokeMethod('iniciarTelaAlarme', {
        'idAlarme': idAlarme,
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao iniciar tela nativa do alarme de rotina #$idAlarme: $e');
    }
  }

  /// Reinicia o som NATIVO (Kotlin/MediaPlayer) em loop, SOMENTE se já
  /// houver uma `RotinaCheckinAlarmActivity` viva e registrada no
  /// momento da chamada — usado como reforço, na transição para a
  /// JANELA FINAL de 60 segundos, quando a tolerância expira sem
  /// confirmação (ver [AlarmeDisparadoScreen._entrarNaFaseFinal]).
  ///
  /// Propositalmente NÃO lança nenhuma Activity/tela nova: se o app
  /// estiver em primeiro plano rodando dentro da `MainActivity` comum
  /// (cenário mais frequente), não há nenhuma `RotinaCheckinAlarmActivity`
  /// para reiniciar e esta chamada é um no-op — nesse caso o som já é
  /// garantido pelo AudioPlayer Dart do próprio
  /// [AlarmeDisparadoScreen._tocarSomDoAlarme], que roda no mesmo engine
  /// em primeiro plano que fez esta chamada.
  ///
  /// IMPORTANTE: DEVE ser chamado a partir do isolate EM PRIMEIRO PLANO —
  /// NUNCA a partir de um callback headless do `android_alarm_manager_plus`.
  /// O MethodChannel usado aqui só é registrado dentro de
  /// `MainActivity.configureFlutterEngine` (ver `MainApplication.kt`), e
  /// o engine headless criado pelo pacote NÃO possui esse (nem nenhum
  /// outro) plugin local registrado — chamado de lá, sempre lançaria
  /// `MissingPluginException` em silêncio (foi exatamente essa tentativa,
  /// removida daqui, que resultava no som não voltando a tocar). Nunca
  /// lança exceção.
  static Future<void> reiniciarSomNativoSeAtivo() async {
    try {
      await _canalRotinaAlarme.invokeMethod('reiniciarSomSeAtivo');
    } catch (e) {
      debugPrint('⚠️ Falha ao tentar reiniciar som nativo (best-effort): $e');
    }
  }

  /// CORREÇÃO (bug real observado em teste): ao expirar a tolerância, a
  /// tela permanecia apagada mesmo com o som Dart tocando corretamente —
  /// `setTurnScreenOn`/`setShowWhenLocked` só têm efeito pleno quando a
  /// Activity é CRIADA ou RETOMADA, e nada trazia a
  /// `RotinaCheckinAlarmActivity` de volta ao primeiro plano nesse
  /// momento. Este método (chamado por
  /// [AlarmeDisparadoScreen._entrarNaFaseFinal]) faz nativamente, numa
  /// única chamada: acende a tela fisicamente (WakeLock), garante que a
  /// Activity exista/volte ao topo, e reinicia o som nativo se ela já
  /// existia. DEVE ser chamado a partir do isolate em PRIMEIRO PLANO
  /// (mesma restrição de [reiniciarSomNativoSeAtivo]). Nunca lança
  /// exceção.
  static Future<void> acordarParaFaseFinal(int idAlarme) async {
    try {
      await _canalRotinaAlarme.invokeMethod('acordarParaFaseFinal', {
        'idAlarme': idAlarme,
      });
    } catch (e) {
      debugPrint('⚠️ Falha ao acordar tela para a janela final: $e');
    }
  }

 static Future<void> confirmarCheckinRotina(int idAlarme) async {
    // NOVO (heartbeat/alerta na nuvem): melhor esforço, nunca bloqueia
    // nem lança exceção — avisa a coleção `alarmes_agendados` que o
    // usuário está seguro, independente do fluxo local abaixo (100%
    // intacto) continuar exatamente como antes. Ver
    // [AlarmeAgendadoCloudService.marcarConfirmadoSeguro].
    unawaited(AlarmeAgendadoCloudService().marcarConfirmadoSeguro(idAlarme.toString()));
    // Ciclo definitivamente concluído (êxito) — a PRÓXIMA ocorrência deste
    // mesmo id, reagendada logo abaixo, deve nascer PENDENTE de novo. Ver
    // [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
    AlarmeAgendadoCloudService().sinalizarNovoCiclo(idAlarme.toString());

    // 1. Limpa os timers pendentes locais de SMS e notificação — inclui
    // a janela final de 60 segundos, caso o PIN correto tenha sido
    // confirmado dentro dela.
    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(_idTolerancia(idAlarme));
      await AndroidAlarmManager.cancel(_idJanelaFinal(idAlarme));
      await cancelarAlarmeNativo(idAlarme);
    }
    // No iOS, cancela a série recorrente inteira — sem problema: o
    // `agendarAlarme(dados)` no fim deste método (se `ativo`) já a
    // rearma para as próximas ocorrências, exatamente como
    // [pausarAlarmePorHoje] faz explicitamente.
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    await _limparFlagsDeFaseFinal();
    // Libera o WakeLock (ver RotinaAlarmWakeService) assim que o PIN
    // correto é confirmado — chamado a partir do isolate em primeiro
    // plano (esta função só é acionada pelo diálogo de PIN), portanto
    // confiável.
    await pararServicoForeground();

    // Encerra explicitamente qualquer sinalização de "alarme ainda
    // tocando" em disco — necessário porque, na janela final, o teclado
    // de PIN é aberto automaticamente (sem o toque no botão que
    // normalmente já limpava essas flags, ver AlarmeDisparadoScreen).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      // Sinaliza a QUALQUER outra instância de AlarmeDisparadoScreen
      // (possivelmente rodando num engine/isolate totalmente separado,
      // ver documentação de [chaveAlarmeFluxoResolvido]) que o fluxo já
      // foi resolvido — mesmo que não tenha sido ELA quem resolveu, deve
      // parar seu próprio som e se fechar.
      await prefs.setBool(chaveAlarmeFluxoResolvido, true);
    } catch (e) {
      debugPrint('⚠️ Falha ao limpar flags de alarme tocando: $e');
    }

    Map<String, dynamic>? dados;
    try {
      // --- CORREÇÃO: Usamos o canal correto _canalRotinaAlarme ---
      await _canalRotinaAlarme.invokeMethod('pararAlarme');
      // -----------------------------------------------------------
      dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    } catch (e) {
      debugPrint('⚠️ Erro ao parar som nativo no check-in: $e');
    }

    final l10n = await L10nHeadlessService.obter();
    final etiqueta = dados != null
        ? AlarmeRotina.fromMap(dados).etiquetaExibida(l10n)
        : l10n.familiaEtiquetaPadrao;

    await NotificacaoService.registrarEventoSistema(
      titulo: l10n.historicoCheckinRotinaConfirmadoTitulo,
      descricao: l10n.historicoCheckinRotinaConfirmadoDescricao(etiqueta),
    );

    // Reagenda automaticamente a rotina do alarme para o próximo dia/período
    try {
      final ativo = (dados?['ativo'] as int?) == 1;
      if (dados != null && ativo) {
        await agendarAlarme(dados);
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao reagendar alarme de rotina #$idAlarme: $e');
    }
  }
}

@pragma('vm:entry-point')
void _callbackCheckinRotina(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint('🔔 [HEADLESS] Alarme de check-in de rotina #$idAlarme disparado!');

  // NOVO (checagem pré-disparo, 2026-08-23): cobre o cenário TESTADO
  // FISICAMENTE pelo usuário — aparelho desligado no horário do alarme,
  // a nuvem dispara o alerta híbrido sozinha via
  // `functions/scheduledAlarmMonitor.js`, e só DEPOIS o aparelho é
  // religado. `rescheduleOnReboot: true` reagenda este mesmo alarme (já
  // vencido) para disparar IMEDIATAMENTE ao religar — sem esta checagem,
  // isso tocaria a sirene e reenviaria SMS/Push duplicados para um ciclo
  // que a nuvem já concluiu sozinha. Ver [_alarmeJaResolvidoNaNuvem].
  if (await RotinaAlarmeService._alarmeJaResolvidoNaNuvem(idAlarme)) {
    debugPrint(
        '☁️ [HEADLESS] Alarme #$idAlarme já resolvido na nuvem — disparo '
        'local abortado, apenas atualizando o estado local e reagendando '
        'a próxima ocorrência.');
    try {
      final dadosResolvido = await DatabaseHelper().buscarAlarmePorId(idAlarme);
      final ativoResolvido = (dadosResolvido?['ativo'] as int?) == 1;
      if (dadosResolvido != null && ativoResolvido) {
        await RotinaAlarmeService.agendarAlarme(dadosResolvido);
      }
    } catch (e) {
      debugPrint(
          '⚠️ [HEADLESS] Falha ao reagendar alarme #$idAlarme já resolvido na nuvem: $e');
    }
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  
  // 1. Grava no disco que o alarme está disparando para o main.dart saber
  await prefs.setBool('alarme_disparando_no_momento', true);
  await prefs.setBool('stop_current_alarm', false);
  // Novo ciclo de alarme começando agora: reseta o sinal de "fluxo
  // resolvido" do ciclo anterior (ver documentação de
  // [chaveAlarmeFluxoResolvido]).
  await prefs.remove(chaveAlarmeFluxoResolvido);

  // CORREÇÃO (bug real observado em teste — "mensagem enviada"
  // aparecendo na hora, antes até da tolerância começar): se o CICLO
  // ANTERIOR deste mesmo alarme tiver terminado com o alerta de
  // emergência REAL disparado (PIN nunca confirmado — o único caminho
  // que NÃO passa por [confirmarCheckinRotina]/[cancelarAlarme]/
  // [pausarAlarme], os únicos lugares que limpam essas flags),
  // [chaveAlarmeEmergenciaDisparada]/[chaveAlarmeFaseFinal] ficavam
  // gravadas no disco PARA SEMPRE. Como [AlarmeDisparadoScreen] lê essas
  // flags assim que a tela abre (ver [_verificarSinalizacaoNoDisco]), o
  // PRÓXIMO disparo deste alarme herdava o estado do ciclo anterior e
  // pulava direto para a confirmação verde. Um novo ciclo começando
  // agora nunca deve carregar sinalização de um ciclo já encerrado.
  await prefs.remove(chaveAlarmeFaseFinal);
  await prefs.remove(chaveAlarmeFaseFinalDeadlineEpochMs);
  await prefs.remove(chaveAlarmeEmergenciaDisparada);

  // 2. Abre a interface nativa / traz o app para o primeiro plano IMEDIATAMENTE
  try {
    await RotinaAlarmeService.iniciarTelaAlarmeNativa(idAlarme);
  } catch (e) {
    debugPrint('⚠️ Falha ao chamar tela nativa: $e');
  }

  // 3. Monitora a flag no SharedPreferences para interrupção instantânea
  // durante a janela inicial (aguardando o toque em "Interromper
  // Alarme"). CORREÇÃO (bug real observado em teste): este Timer NUNCA
  // se cancelava sozinho além de detectar 'stop_current_alarm' — como o
  // isolate headless permanece vivo (o WakeLock do RotinaAlarmWakeService
  // impede o Doze de suspendê-lo), ele continuava rodando por MINUTOS,
  // e ao detectar 'stop_current_alarm=true' durante a transição para a
  // JANELA FINAL (que também usa essa mesma flag momentaneamente ao
  // abrir o teclado, ver AlarmeDisparadoScreen._abrirTecladoPin),
  // removia 'alarme_disparando_no_momento' no momento ERRADO —
  // interferindo numa fase que não lhe dizia mais respeito. Agora ele
  // também se cancela assim que detectar que o alarme avançou para a
  // fase final ou para o disparo real, já que a partir daí quem manda
  // nessas flags é o próprio fluxo da janela final.
  int tentativasMonitoramentoInicial = 0;
  Timer.periodic(const Duration(milliseconds: 200), (timer) async {
    tentativasMonitoramentoInicial++;
    // Teto de segurança (20 minutos): nunca deixa este monitoramento
    // rodando indefinidamente caso, por qualquer motivo, nenhuma das
    // condições de parada abaixo seja atingida.
    if (tentativasMonitoramentoInicial > 6000) {
      timer.cancel();
      return;
    }

    final prefsRelo = await SharedPreferences.getInstance();
    await prefsRelo.reload();

    if ((prefsRelo.getBool(chaveAlarmeFaseFinal) ?? false) ||
        (prefsRelo.getBool(chaveAlarmeEmergenciaDisparada) ?? false)) {
      debugPrint('🔇 [HEADLESS] Monitoramento inicial encerrado — o alarme '
          'avançou para a janela final.');
      timer.cancel();
      return;
    }

    if (prefsRelo.getBool('stop_current_alarm') == true) {
      try {
        timer.cancel(); // Finaliza o monitoramento de segurança
        await prefsRelo.remove('stop_current_alarm');
        await prefsRelo.remove('alarme_disparando_no_momento');
        debugPrint('🔇 [HEADLESS] Alarme finalizado com sucesso.');
      } catch (e) {
        debugPrint('⚠️ [HEADLESS] Falha ao processar parada: $e');
        timer.cancel();
      }
    }
  });

  Map<String, dynamic>? dados;
  // ⬇️ Daqui para baixo no seu arquivo (busca no banco e timers de tolerância),
  // tudo CONTINUA 100% INTACTO sem mudar nenhuma linha!
  try {
    dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao buscar dados do alarme #$idAlarme: $e');
  }

  if (dados == null) return;

  final ativo = (dados['ativo'] as int?) == 1;
  if (!ativo) return;

  final key = 'pausado_hoje_$idAlarme';
  if (prefs.getBool(key) == true) {
    debugPrint('⏸️ [HEADLESS] Alarme de rotina #$idAlarme pausado por hoje via swipe — disparo ignorado.');
    await prefs.remove(key);
    try {
      await RotinaAlarmeService.agendarAlarme(dados);
    } catch (e) {
      debugPrint('⚠️ [HEADLESS] Falha ao reagendar alarme pausado por hoje: $e');
    }
    return;
  }

  // Resolve a chave neutra padrão (ou uma tradução legada já gravada no
  // banco — ver AlarmeRotina.etiquetaExibida) para o texto traduzido no
  // idioma ATUAL do app, nunca um texto fixo/de outro idioma.
  final etiqueta = AlarmeRotina.fromMap(dados).etiquetaExibida(await L10nHeadlessService.obter());
  final minutosTolerancia = dados['minutos_tolerancia'] as int? ?? 10;

  try {
    await DatabaseHelper().marcarUltimoDisparo(
      idAlarme,
      DateTime.now().millisecondsSinceEpoch,
    );
  } catch (_) {}

  try {
    await NotificacaoService.exibirNotificacaoCheckin(
      idAlarme: idAlarme,
      etiqueta: etiqueta,
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao exibir notificação de check-in: $e');
  }

  try {
    await AndroidAlarmManager.oneShot(
      Duration(minutes: minutosTolerancia),
      RotinaAlarmeService._idTolerancia(idAlarme),
      _callbackToleranciaExpirada,
      exact: true,
      wakeup: true,
      allowWhileIdle: true, // bypassa Doze — ver comentário em _agendarNativo
      rescheduleOnReboot: false,
      params: {'idAlarme': idAlarme},
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao agendar tolerância do alarme #$idAlarme: $e');
  }

  try {
    await RotinaAlarmeService.agendarAlarme(dados);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao reagendar próxima ocorrência: $e');
  }
}

/// Disparado quando o TEMPO DE TOLERÂNCIA (definido na programação do
/// alarme) expira sem que o PIN correto tenha sido confirmado — seja
/// porque o usuário nunca tocou em "Interromper Alarme", seja porque
/// tocou mas errou o PIN (sem chegar a 2 erros consecutivos, o que já
/// dispararia o alerta imediatamente por conta própria).
///
/// NÃO dispara mais o alerta de emergência diretamente: em vez disso,
/// concede uma ÚLTIMA CHANCE de 60 segundos — o alarme toca novamente, a
/// tela volta ao primeiro plano já com o teclado de PIN aberto
/// (diretamente, sem exigir novo toque no botão) e QUALQUER falha nesse
/// prazo (PIN incorreto ou tempo esgotado) aciona
/// [_callbackJanelaFinalExpirada]/o alerta real. Isso é sinalizado ao
/// lado Dart em primeiro plano via a flag em disco
/// [chaveAlarmeFaseFinal] (ver [AlarmeDisparadoScreen]).
@pragma('vm:entry-point')
void _callbackToleranciaExpirada(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint(
      '🔔 [HEADLESS] Tolerância do check-in de rotina #$idAlarme expirada — '
      'concedendo janela final de 60 segundos antes do alerta de emergência.');

  // NOVO (checagem pré-disparo, 2026-08-23): mesmo raciocínio de
  // [_callbackCheckinRotina] — se a nuvem já resolveu este ciclo (alerta
  // já disparado pela Cloud Function, confirmado seguro ou
  // cancelado/pausado pelo usuário por outro caminho), não há motivo
  // para reacender a tela/som para mais uma última chance. Ver
  // [_alarmeJaResolvidoNaNuvem].
  if (await RotinaAlarmeService._alarmeJaResolvidoNaNuvem(idAlarme)) {
    debugPrint(
        '☁️ [HEADLESS] Alarme #$idAlarme já resolvido na nuvem — janela '
        'final abortada.');
    try {
      await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    } catch (_) {}
    return;
  }

  try {
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
  } catch (_) {}

  try {
    final l10n = await L10nHeadlessService.obter();
    await NotificacaoService.registrarEventoSistema(
      titulo: l10n.historicoCheckinRotinaUltimaChanceTitulo,
      descricao: l10n.historicoCheckinRotinaUltimaChanceDescricao,
    );
  } catch (_) {}

  // Sinaliza (via disco) que entramos na janela final, e re-arma as
  // flags de "alarme tocando" — mesmo que o usuário já tenha tocado no
  // botão "Interromper Alarme" durante a tolerância (o que já as tinha
  // limpado), o app precisa saber que o alarme está tocando DE NOVO.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(chaveAlarmeFaseFinal, true);
    await prefs.setInt(
      chaveAlarmeFaseFinalDeadlineEpochMs,
      DateTime.now().add(RotinaAlarmeService.duracaoJanelaFinal).millisecondsSinceEpoch,
    );
    await prefs.setBool('alarme_disparando_no_momento', true);
    await prefs.setBool('stop_current_alarm', false);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao sinalizar fase final em disco: $e');
  }

  // NÃO chama [RotinaAlarmeService.tocarAlarmeNovamente] AQUI: este
  // callback roda no isolate HEADLESS do android_alarm_manager_plus, que
  // não tem nenhum plugin/MethodChannel local registrado (ver
  // `MainApplication.kt`) — a chamada sempre falharia em silêncio
  // (MissingPluginException), e foi exatamente essa tentativa que
  // resultava no som NÃO voltando a tocar. Em vez disso, a flag
  // [chaveAlarmeFaseFinal] gravada acima é monitorada por
  // [AlarmeDisparadoScreen] (que SEMPRE roda num engine em primeiro
  // plano, com os plugins devidamente registrados) — é ELE quem
  // efetivamente re-toca o som nativo e o som Dart assim que detecta a
  // fase final, com no máximo ~1s de atraso.

  // Agenda o disparo REAL de emergência para daqui a 60 segundos, caso o
  // PIN correto não seja confirmado antes disso — ver
  // [RotinaAlarmeService.confirmarCheckinRotina], que cancela este alarme
  // também.
  try {
    await AndroidAlarmManager.oneShot(
      RotinaAlarmeService.duracaoJanelaFinal,
      RotinaAlarmeService._idJanelaFinal(idAlarme),
      _callbackJanelaFinalExpirada,
      exact: true,
      wakeup: true,
      allowWhileIdle: true, // bypassa Doze — ver comentário em _agendarNativo
      rescheduleOnReboot: false,
      params: {'idAlarme': idAlarme},
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao agendar janela final do alarme #$idAlarme: $e');
  }
}

/// Disparado quando a JANELA FINAL de 60 segundos (ver
/// [_callbackToleranciaExpirada]) expira sem que o PIN correto tenha sido
/// confirmado. Este é o disparo REAL e definitivo do alerta de
/// emergência — não há mais nenhuma chance depois deste ponto.
///
/// Também é o destino do erro de PIN (mesmo que uma única vez) dentro
/// desta janela — mas esse caminho é acionado diretamente pelo
/// `aoAtingirLimiteDeErros` do diálogo de PIN em
/// [AlarmeDisparadoScreen] (com `limiteErrosConsecutivos: 1`), não por
/// este callback headless, já que o app está necessariamente aberto e em
/// primeiro plano para o usuário estar digitando o PIN.
@pragma('vm:entry-point')
void _callbackJanelaFinalExpirada(int idAlarmeParam, Map<String, dynamic> params) async {
  final idAlarme = params['idAlarme'] as int? ?? idAlarmeParam;

  debugPrint(
      '🚨 [HEADLESS] Janela final (2 min) do alarme de rotina #$idAlarme '
      'expirada sem confirmação — disparando alerta de emergência AGORA.');

  // NOVO (checagem pré-disparo/regra de confirmação única, 2026-08-23):
  // este é o instante em que o alerta REAL seria disparado localmente —
  // se a nuvem já assumiu o desfecho deste ciclo (a Cloud Function
  // agendada disparou o alerta híbrido sozinha numa corrida vencida pelo
  // lado da nuvem, o PIN foi confirmado por outro caminho, ou o usuário
  // cancelou/pausou o alarme), ABORTA o disparo local e apenas
  // sincroniza o estado — evita SMS/Push duplicados. Ver
  // [_alarmeJaResolvidoNaNuvem].
  if (await RotinaAlarmeService._alarmeJaResolvidoNaNuvem(idAlarme)) {
    debugPrint(
        '☁️ [HEADLESS] Alarme #$idAlarme já resolvido na nuvem — disparo '
        'local do alerta de emergência abortado (evita duplicidade de '
        'SMS/Push).');
    try {
      await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(chaveAlarmeFaseFinal);
      await prefs.remove(chaveAlarmeFaseFinalDeadlineEpochMs);
      await prefs.setBool(chaveAlarmeEmergenciaDisparada, true);
      await prefs.setBool(chaveAlarmeFluxoResolvido, true);
    } catch (_) {}
    // Ciclo já concluído por outro caminho — a PRÓXIMA ocorrência deste
    // mesmo id deve nascer PENDENTE de novo (ver
    // [AlarmeAgendadoCloudService.sinalizarNovoCiclo]). Necessário aqui
    // porque, quando é a PRÓPRIA Cloud Function agendada quem resolve o
    // ciclo (aparelho desligado), nenhum caminho local chega a sinalizar
    // isso sozinho.
    AlarmeAgendadoCloudService().sinalizarNovoCiclo(idAlarme.toString());
    return;
  }

  try {
    await NotificacaoService.cancelarNotificacaoCheckin(idAlarme);
  } catch (_) {}

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(chaveAlarmeFaseFinal);
    await prefs.remove(chaveAlarmeFaseFinalDeadlineEpochMs);
  } catch (_) {}

  final l10n = await L10nHeadlessService.obter();
  String etiqueta = l10n.familiaEtiquetaPadrao;
  String? eventoId;
  try {
    final dados = await DatabaseHelper().buscarAlarmePorId(idAlarme);
    if (dados != null) {
      etiqueta = AlarmeRotina.fromMap(dados).etiquetaExibida(l10n);
      // TRAVA CONTRA MENSAGENS DUPLICADAS: MESMO eventoId calculado em
      // [AlarmeDisparadoScreen._dispararAlertaDeFalhaDeDesarme] (mesmo
      // idAlarme + mesmo `ultimo_disparo_epoch`, gravado uma única vez
      // por disparo em [_callbackCheckinRotina]) — garante que, mesmo
      // que este callback headless E o diálogo de PIN em primeiro plano
      // detectem a falha quase ao mesmo tempo, só o primeiro a chegar no
      // Firestore/trava local realmente envia a mensagem.
      final ultimoDisparoEpoch = dados['ultimo_disparo_epoch'] as int?;
      if (ultimoDisparoEpoch != null) {
        eventoId = 'rotina_${idAlarme}_$ultimoDisparoEpoch';
      }
    }
  } catch (_) {}

  final motivo = l10n.historicoCheckinRotinaFalhaMotivo(etiqueta);

  try {
    await NotificacaoService.registrarEventoSistema(
      titulo: l10n.historicoAlertaEmergenciaRotinaTitulo,
      descricao: motivo,
    );
  } catch (_) {}

  // CRÍTICO: este callback roda num isolate HEADLESS separado do
  // isolate principal — `main()` (e o `Firebase.initializeApp()` que ele
  // chama) NUNCA roda aqui. Sem isto, `Firebase.apps` fica vazio neste
  // isolate e o disparo para a nuvem abaixo seria silenciosamente
  // ignorado (nenhum log, nenhum erro) por
  // [FirebaseSyncService._firebaseDisponivel]. `cloud_firestore` É um
  // plugin padrão do pubspec (diferente do MethodChannel local do
  // alarme/SMS) e por isso seu lado NATIVO já vem registrado
  // automaticamente neste engine — só falta esta inicialização do lado
  // Dart.
  try {
    if (Firebase.apps.isEmpty) {
      // Timeout explícito (bug real observado em teste): sem conexão
      // real com a internet, esta chamada pode ficar pendurada por
      // tempo indefinido, travando TODO o disparo do alerta (inclusive
      // o SMS nativo abaixo, que nem depende de internet).
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)
          .timeout(const Duration(seconds: 8));
    }
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao inicializar Firebase neste isolate: $e');
  }

  // CORREÇÃO DE BUG REAL (2026-08-15, mesma classe do duplo disparo do
  // Cronômetro — ver `CronometroDisparadoScreen._dispararAlerta` /
  // `AlarmeDisparadoScreen._dispararAlertaDeFalhaDeDesarme`): este
  // callback É o próprio prazo final expirando (a janela final nativa),
  // então não há um alarme local irmão para cancelar — mas o documento
  // `alarmes_agendados/{idAlarme}` na nuvem continua PENDENTE até aqui, e
  // a Cloud Function agendada (`monitorarAlarmesAgendados`) roda de
  // qualquer forma a cada 2 minutos. Sem marcar ALERTA_DISPARADO agora,
  // ela encontraria o mesmo documento vencido pouco depois e disparia um
  // SEGUNDO alerta duplicado. Ver
  // [AlarmeAgendadoCloudService.marcarAlertaDisparado].
  unawaited(AlarmeAgendadoCloudService().marcarAlertaDisparado(idAlarme.toString()));
  // Ciclo definitivamente concluído (falha) — a PRÓXIMA ocorrência deste
  // mesmo id (já reagendada no disparo original, ver
  // `_callbackCheckinRotina`) deve nascer PENDENTE de novo. Ver
  // [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
  AlarmeAgendadoCloudService().sinalizarNovoCiclo(idAlarme.toString());

  // MESMA ordem crítica usada no resto do app: nuvem primeiro (rápida,
  // minimalista), depois o fluxo local completo (SMS nativo + backend).
  try {
    await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(
      motivo: motivo,
      eventoId: eventoId,
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao disparar alerta prioritário na nuvem (rotina): $e');
  }
  try {
    await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto(
      motivo: motivo,
      eventoId: eventoId,
    );
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha durante o disparo de emergência de rotina: $e');
  }

  // CORREÇÃO (pedido do usuário, 2026-08-11): este callback é o único
  // caminho de disparo que pode rodar SEM nenhuma tela do app visível
  // (isolate headless do `android_alarm_manager_plus` — diferente de
  // [AlarmeDisparadoScreen._dispararAlertaDeFalhaDeDesarme]/
  // [_descartarPorArraste], que sempre têm a Activity nativa aberta ou
  // mostram a notificação do sistema). Sem esta chamada, o usuário só
  // ficava sabendo que o alerta foi enviado se reabrisse o app depois —
  // agora a mesma notificação do sistema usada no gesto de arraste (ver
  // [NotificacaoService.exibirNotificacaoAlertaEnviado]) confirma o
  // envio imediatamente, mesmo com o app 100% fechado.
  try {
    await NotificacaoService.exibirNotificacaoAlertaEnviado();
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao exibir notificação de confirmação: $e');
  }

  try {
    await DatabaseHelper().marcarAguardandoConfirmacaoPin();
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao marcar aguardando_confirmacao_pin: $e');
  }

  // Sinaliza (via disco) que o disparo REAL já foi concluído — usado por
  // [AlarmeDisparadoScreen] como fallback (o caminho primário é o próprio
  // diálogo de PIN em primeiro plano detectando a falha diretamente e
  // reagindo na hora) para garantir que a tela pare o som, feche o
  // teclado e mostre a confirmação mesmo se ela não tiver capturado o
  // evento sozinha.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(chaveAlarmeEmergenciaDisparada, true);
  } catch (e) {
    debugPrint('⚠️ [HEADLESS] Falha ao sinalizar emergência disparada: $e');
  }
}