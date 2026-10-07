import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../models/alarme_agendado_model.dart';
import 'firebase_auth_service.dart';

/// Mesmo teto de timeout já usado por [FirebaseSyncService] — sem isto,
/// uma chamada ao Firestore sem conectividade real (Wi-Fi só com rede
/// local, por exemplo) poderia ficar pendurada indefinidamente.
const Duration _timeoutFirestore = Duration(seconds: 8);

/// Camada de acesso ao Firestore para o modelo [AlarmeAgendadoModel] —
/// coleção `alarmes_agendados`, escrita paralela e independente da
/// coleção `usuarios` já usada por `FirebaseSyncService`. Mesma postura
/// defensiva do resto do app: nunca lança exceção para quem a invoca,
/// sempre com timeout explícito, e um no-op silencioso se o Firebase não
/// tiver inicializado (ver [_firebaseDisponivel]) — o alarme local
/// (som, tela, tolerância, janela final, SMS nativo) continua 100%
/// funcional mesmo que toda esta classe falhe.
class AlarmeAgendadoCloudService {
  AlarmeAgendadoCloudService._internal();
  static final AlarmeAgendadoCloudService _instance =
      AlarmeAgendadoCloudService._internal();
  factory AlarmeAgendadoCloudService() => _instance;

  static const String _colecao = 'alarmes_agendados';

  bool get _firebaseDisponivel =>
      Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;

  /// Ids de alarme de ROTINA (mesma string usada como chave do documento,
  /// ver [_documento]) cujo PRÓXIMO registro em
  /// `BackgroundLocationHeartbeatService._executarCiclo` deve usar
  /// [reiniciarCicloComoPendente] em vez de [registrarAlarmeAgendado] — ver
  /// [sinalizarNovoCiclo]/[consumirSinalizacaoDeNovoCiclo].
  final Set<String> _idsRotinaComNovoCicloPendente = {};

  /// Sinaliza que o ciclo do alarme de ROTINA [idAlarme] acabou de ser
  /// CONCLUÍDO de forma definitiva (PIN correto, alerta de emergência
  /// disparado — inclusive pelo callback headless —, ou o alarme foi
  /// reativado/reagendado manualmente pelo usuário na aba Família) e que a
  /// PRÓXIMA vez que este mesmo id for registrado pelo heartbeat deve
  /// nascer como um ciclo PENDENTE totalmente novo no Firestore.
  ///
  /// CORREÇÃO DE DÉBITO TÉCNICO (2026-08-15): diferente do Cronômetro (id
  /// fixo `checkin_seguranca`, que já reiniciava o ciclo via
  /// `BackgroundLocationHeartbeatService.registrarCheckinAtivo`), os
  /// alarmes de Rotina reaproveitam o MESMO `idAlarme` (autoincrement do
  /// SQLite) em toda repetição semanal/diária — mas
  /// [registrarAlarmeAgendado] deliberadamente PRESERVA o `status` já
  /// gravado a cada heartbeat. Sem esta sinalização, depois do PRIMEIRO
  /// ciclo de um alarme recorrente (êxito ou falha), o documento ficava
  /// PARA SEMPRE fora de PENDENTE, e a Cloud Function agendada
  /// (`monitorarAlarmesAgendados`) parava de proteger TODAS as ocorrências
  /// seguintes desse mesmo alarme.
  ///
  /// IMPORTANTE — NUNCA chamar isto no instante em que o alarme apenas
  /// DISPARA (`RotinaAlarmeService`, callback `_callbackCheckinRotina`): o
  /// reagendamento nativo da PRÓXIMA ocorrência já acontece nesse momento,
  /// mas o ciclo ATUAL ainda está em aberto (teclado de PIN prestes a
  /// abrir) — reiniciar o documento nesse instante apagaria o
  /// monitoramento do ciclo em andamento sempre que a repetição for
  /// diária/frequente o bastante para a PRÓXIMA ocorrência já cair dentro
  /// da janela de 48h de heartbeat. Só chamar quando o ciclo ATUAL já
  /// estiver definitivamente resolvido (ou antes dele sequer começar, ex:
  /// reativação manual de um alarme pausado/editado).
  void sinalizarNovoCiclo(String idAlarme) {
    _idsRotinaComNovoCicloPendente.add(idAlarme);
  }

  /// Consome (lê E remove) a sinalização de [sinalizarNovoCiclo] para
  /// [idAlarme] — chamado por
  /// `BackgroundLocationHeartbeatService._executarCiclo` a cada ciclo, para
  /// decidir entre [registrarAlarmeAgendado] (preserva status) e
  /// [reiniciarCicloComoPendente] (sempre PENDENTE) para este candidato.
  bool consumirSinalizacaoDeNovoCiclo(String idAlarme) {
    return _idsRotinaComNovoCicloPendente.remove(idAlarme);
  }

  /// Id do documento namespaced por usuário (`{uid}_{idAlarme}`) — evita
  /// colisão entre o mesmo `idAlarme` local (autoincrement do SQLite) de
  /// dois usuários diferentes, e casa com a regra de segurança do
  /// Firestore que restringe leitura/escrita ao dono (`usuarioId`
  /// gravado no próprio documento, ver `firestore.rules`).
  DocumentReference<Map<String, dynamic>> _documento(String idAlarme) {
    final uid = FirebaseAuthService().uidAtual;
    return FirebaseFirestore.instance
        .collection(_colecao)
        .doc('${uid}_$idAlarme');
  }

  /// Cria/atualiza (via merge, nunca acumula) o documento do alarme
  /// agendado — chamado a cada ciclo do
  /// `BackgroundLocationHeartbeatService` enquanto o alarme estiver
  /// dentro da janela de heartbeat (≤ 2h do disparo previsto),
  /// substituindo sempre `dataHoraDisparo`, `ultimaLocalizacao` e
  /// `contatosEmergencia` pelos valores mais recentes. Preserva o
  /// `status` já gravado na nuvem (nunca sobrescreve de volta para
  /// PENDENTE um alarme já confirmado/alertado) a menos que o documento
  /// ainda não exista.
  Future<void> registrarAlarmeAgendado(AlarmeAgendadoModel modelo) async {
    if (!_firebaseDisponivel) return;
    try {
      final doc = _documento(modelo.idAlarme);
      final dadosParaGravar = modelo.toFirestore();

      final snapshotAtual = await doc.get().timeout(_timeoutFirestore);
      if (snapshotAtual.exists) {
        // Não pisa no status já confirmado/alertado por um heartbeat
        // subsequente — apenas o PIN correto (CONFIRMADO_SEGURA) ou a
        // Cloud Function (ALERTA_DISPARADO) podem mudar o status depois
        // do registro inicial.
        dadosParaGravar.remove('status');
      }

      await doc.set(dadosParaGravar, SetOptions(merge: true)).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao registrar alarme agendado #${modelo.idAlarme}: $e');
    }
  }

  /// Reinicia o documento do alarme como um NOVO ciclo PENDENTE —
  /// necessário para ids FIXOS e reaproveitados entre ciclos (ex: o
  /// cronômetro de check-in da aba Segurança, ver
  /// `BackgroundLocationHeartbeatService.idAlarmeCheckinSeguranca`), cujo
  /// documento de um ciclo ANTERIOR já finalizado (CONFIRMADO_SEGURA ou
  /// ALERTA_DISPARADO) senão ficaria "preso" nesse status para sempre.
  /// Diferente de [registrarAlarmeAgendado] (que deliberadamente
  /// PRESERVA o status já gravado — correto para heartbeats dentro do
  /// MESMO ciclo), este método sobrescreve o documento inteiro, sempre
  /// que um novo ciclo de monitoramento está começando.
  Future<void> reiniciarCicloComoPendente(AlarmeAgendadoModel modelo) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(modelo.idAlarme)
          .set(modelo.toFirestore())
          .timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [AlarmeAgendadoCloudService] Ciclo #${modelo.idAlarme} reiniciado como PENDENTE.');
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao reiniciar ciclo #${modelo.idAlarme}: $e');
    }
  }

  /// Marca o alarme como CONFIRMADO_SEGURA — chamado assim que o PIN
  /// correto é digitado (ver
  /// `RotinaAlarmeService.confirmarCheckinRotina`), avisando a nuvem que
  /// o usuário está a salvo antes mesmo de a Cloud Function agendada
  /// rodar novamente e checar o prazo.
  /// Ciclo do despertador de check-in ([modelo] traz a ocorrência ALVO —
  /// ver `CicloDespertador.alvo` — em `cicloEpochMs`):
  ///   - mesma ocorrência do documento: só atualiza posição, contatos e
  ///     textos — nunca o status;
  ///   - documento PENDENTE de outra ocorrência: se o prazo ainda não passou,
  ///     a ocorrência atual continua sendo acompanhada (só a posição é
  ///     atualizada); com o prazo vencido, é o servidor quem resolve — nada
  ///     muda aqui. Exceção: horário do alarme editado (outro hora:minuto),
  ///     que troca a ocorrência na hora;
  ///   - CONFIRMADO_SEGURA/ALERTA_DISPARADO (ocorrência anterior resolvida):
  ///     arma a nova como PENDENTE;
  ///   - PAUSADO: continua pausado até `pausadoAte`; depois, arma;
  ///   - CANCELADO (alarme desligado e religado) ou sem documento: arma.
  /// [forcarNovoCiclo]: arma a nova ocorrência em qualquer caso.
  Future<void> sincronizarCicloDespertador(
    AlarmeAgendadoModel modelo, {
    bool forcarNovoCiclo = false,
  }) async {
    if (!_firebaseDisponivel) return;
    final ciclo = modelo.cicloEpochMs;
    if (ciclo == null) return registrarAlarmeAgendado(modelo);
    try {
      final doc = _documento(modelo.idAlarme);
      final snapshot = await doc.get().timeout(_timeoutFirestore);
      final dados = snapshot.data();
      if (!snapshot.exists || dados == null || forcarNovoCiclo) {
        await doc.set(modelo.toFirestore()).timeout(_timeoutFirestore);
        return;
      }

      final dataDoc = (dados['dataHoraDisparo'] as Timestamp?)?.toDate();
      final cicloDoc = (dados['cicloEpochMs'] as num?)?.toInt() ?? dataDoc?.millisecondsSinceEpoch;
      final status = AlarmeAgendadoStatus.fromFirestore(dados['status'] as String?);
      final atualizaveis = <String, dynamic>{
        if (modelo.ultimaLocalizacao != null) 'ultimaLocalizacao': modelo.ultimaLocalizacao!.toMap(),
        'contatosEmergencia': modelo.contatosEmergencia,
        'etiqueta': modelo.etiqueta,
        'contextoPersonalizado': modelo.contextoPersonalizado,
      };

      Future<void> soAtualizar() =>
          doc.set(atualizaveis, SetOptions(merge: true)).timeout(_timeoutFirestore);
      Future<void> armar() => doc.set(modelo.toFirestore()).timeout(_timeoutFirestore);

      if (cicloDoc == ciclo) return soAtualizar();

      switch (status) {
        case AlarmeAgendadoStatus.pendente:
          final horarioEditado = dataDoc != null &&
              (dataDoc.hour != modelo.dataHoraDisparo.hour ||
                  dataDoc.minute != modelo.dataHoraDisparo.minute);
          if (horarioEditado) return armar();
          final prazoDoc = (dados['prazoFinalEpochMs'] as num?)?.toInt() ?? 0;
          if (prazoDoc > DateTime.now().millisecondsSinceEpoch) return soAtualizar();
          return;
        case AlarmeAgendadoStatus.pausado:
          final ate = (dados['pausadoAte'] as Timestamp?)?.toDate();
          if (ate != null && DateTime.now().isBefore(ate)) return;
          return armar();
        case AlarmeAgendadoStatus.confirmadoSeguro:
        case AlarmeAgendadoStatus.alertaDisparado:
        case AlarmeAgendadoStatus.cancelado:
          return armar();
      }
    } catch (e) {
      debugPrint('⚠️ [AlarmeAgendadoCloudService] Falha ao sincronizar o ciclo do despertador '
          '#${modelo.idAlarme}: $e');
    }
  }

  /// Status da ocorrência [ciclo] na nuvem; `null` se o documento já
  /// acompanha outra ocorrência (ou não pôde ser lido).
  Future<AlarmeAgendadoStatus?> statusDaOcorrencia(String idAlarme, int ciclo) async {
    if (!_firebaseDisponivel) return null;
    try {
      final snapshot = await _documento(idAlarme).get().timeout(_timeoutFirestore);
      final dados = snapshot.data();
      if (dados == null) return null;
      final cicloDoc = (dados['cicloEpochMs'] as num?)?.toInt() ??
          (dados['dataHoraDisparo'] as Timestamp?)?.toDate().millisecondsSinceEpoch;
      if (cicloDoc != ciclo) return null;
      return AlarmeAgendadoStatus.fromFirestore(dados['status'] as String?);
    } catch (_) {
      return null;
    }
  }

  /// [cicloEpochMs]: a ocorrência confirmada (despertador de check-in).
  Future<void> marcarConfirmadoSeguro(String idAlarme, {int? cicloEpochMs}) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.confirmadoSeguro.valorFirestore,
          'confirmadoEm': FieldValue.serverTimestamp(),
          if (cicloEpochMs != null) 'cicloEpochMs': cicloEpochMs,
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como seguro: $e');
    }
  }

  /// Marca o alarme como ALERTA_DISPARADO — chamado assim que o alerta de
  /// emergência já foi disparado PELO PRÓPRIO APARELHO (3ª tentativa de
  /// PIN incorreta OU os 60s de tolerância se esgotando localmente, ver
  /// `BackgroundLocationHeartbeatService.confirmarAlertaJaDisparado`).
  ///
  /// CORREÇÃO DE BUG REAL (2026-08-15, duplo disparo do Cronômetro): sem
  /// esta chamada, o documento `alarmes_agendados/{idAlarme}` permanecia
  /// PENDENTE mesmo depois do disparo local — a única forma de sair de
  /// PENDENTE antes desta correção era [marcarConfirmadoSeguro] (PIN
  /// certo). Isso significa que, quando as 3 tentativas de PIN erradas
  /// aconteciam ANTES do prazo (`prazoFinalEpochMs`) se esgotar, o alerta
  /// já tinha sido enviado pelo aparelho, mas o documento continuava
  /// PENDENTE — e assim que o prazo original vencia (poucos segundos
  /// depois), a Cloud Function agendada (`monitorarAlarmesAgendados`, que
  /// só olha para `status == PENDENTE`) encontrava esse mesmo documento
  /// "vencido sem confirmação" e disparava um SEGUNDO alerta duplicado.
  /// Gravar ALERTA_DISPARADO aqui, no mesmo instante do disparo local,
  /// tira o documento da consulta da function e resolve o duplo envio —
  /// mesmo espírito de [marcarConfirmadoSeguro], só que para o outro
  /// desfecho possível do ciclo.
  /// [eventoId]: id do alerta já enviado pelo app para esta ocorrência —
  /// o servidor não manda um segundo alerta.
  Future<void> marcarAlertaDisparado(String idAlarme, {int? cicloEpochMs, String? eventoId}) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.alertaDisparado.valorFirestore,
          'alertaDisparadoEm': FieldValue.serverTimestamp(),
          if (cicloEpochMs != null) 'cicloEpochMs': cicloEpochMs,
          if (eventoId != null) 'eventoId': eventoId,
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como alerta disparado: $e');
    }
  }

  /// Marca o alarme como CANCELADO — chamado IMEDIATAMENTE por
  /// `RotinaAlarmeService.cancelarAlarme`/`pausarAlarmePorHoje` assim que
  /// o usuário cancela um alarme/rotina pela interface (ou pula só o
  /// disparo de hoje), ANTES de qualquer outra coisa acontecer.
  ///
  /// CORREÇÃO (2026-08-23, sincronização imediata): sem isto, cancelar
  /// pelo app só afetava o `AlarmManager` local — o documento na nuvem
  /// continuava PENDENTE até o próximo ciclo do heartbeat (até 1 minuto
  /// depois), e a Cloud Function agendada (`monitorarAlarmesAgendados`,
  /// que roda a cada 2 minutos) podia disparar um alerta FALSO nesse
  /// intervalo para um alarme que o usuário já tinha cancelado. Gravar
  /// aqui, na hora do próprio gesto de cancelar, fecha essa janela de
  /// corrida.
  Future<void> marcarCancelado(String idAlarme) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.cancelado.valorFirestore,
          'canceladoEm': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [AlarmeAgendadoCloudService] Alarme #$idAlarme marcado como CANCELADO.');
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como cancelado: $e');
    }
  }

  /// Marca o alarme como PAUSADO — chamado IMEDIATAMENTE por
  /// `RotinaAlarmeService.pausarAlarme` assim que o usuário pausa um
  /// alarme/rotina pela interface, mesmo motivo/urgência de
  /// [marcarCancelado] (fechar a janela de corrida com a Cloud Function
  /// agendada). Revertido para PENDENTE (com timestamp novo) somente
  /// quando o usuário reativa o alarme — ver
  /// [sinalizarNovoCiclo]/`RotinaAlarmeService.despausarAlarme`.
  /// [pausadoAte]: fim da pausa (00:00 do dia seguinte, "pausado por
  /// hoje"); depois dele a próxima ocorrência volta a ser armada.
  Future<void> marcarPausado(String idAlarme, {DateTime? pausadoAte}) async {
    if (!_firebaseDisponivel) return;
    try {
      await _documento(idAlarme).set(
        {
          'status': AlarmeAgendadoStatus.pausado.valorFirestore,
          'pausadoEm': FieldValue.serverTimestamp(),
          if (pausadoAte != null) 'pausadoAte': Timestamp.fromDate(pausadoAte),
        },
        SetOptions(merge: true),
      ).timeout(_timeoutFirestore);
      debugPrint(
          '☁️ [AlarmeAgendadoCloudService] Alarme #$idAlarme marcado como PAUSADO.');
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao marcar alarme #$idAlarme como pausado: $e');
    }
  }

  /// Consulta o status ATUAL do alarme [idAlarme] na nuvem — checagem
  /// PRÉ-DISPARO usada por `RotinaAlarmeService` nos três callbacks
  /// headless do alarme local (check-in, tolerância expirada e janela
  /// final expirada) ANTES de tocar sirene ou enviar SMS/Push. Retorna
  /// `true` somente se a nuvem já assumiu o desfecho deste ciclo — ver
  /// [AlarmeAgendadoStatus.jaResolvidoNaNuvem]; `false` (nunca lança
  /// exceção) tanto se o documento ainda não existe quanto se ainda está
  /// PENDENTE, casos em que o fluxo local segue normalmente, como já
  /// validado.
  ///
  /// CORREÇÃO (2026-08-23, alarme duplicado ao religar o aparelho):
  /// cobre exatamente o cenário testado fisicamente pelo usuário — o
  /// aparelho fica desligado durante o horário do alarme, a nuvem dispara
  /// o alerta híbrido sozinha (Push FCM) via `scheduledAlarmMonitor.js`,
  /// e só DEPOIS o aparelho é religado. O `android_alarm_manager_plus`
  /// reagenda (`rescheduleOnReboot: true`) o alarme de check-in para o
  /// mesmo instante — já no passado — e o dispara imediatamente ao
  /// religar, o que sem esta checagem tocaria a sirene e reenviaria
  /// SMS/Push duplicados para um ciclo que a nuvem já concluiu.
  ///
  /// Diferente do resto desta classe (que usa [_firebaseDisponivel], uma
  /// leitura SÍNCRONA de `uidAtual`), aguarda
  /// [FirebaseAuthService.aguardarUidPronto] antes de consultar: esta
  /// checagem tipicamente acontece nos primeiríssimos instantes de um
  /// isolate headless recém-criado (reboot do aparelho), exatamente o
  /// cenário em que `uidAtual` síncrono pode retornar `null` mesmo
  /// havendo uma sessão salva em disco ainda sendo restaurada (mesma
  /// corrida documentada em [FirebaseAuthService.aguardarUidPronto]).
  Future<bool> statusJaResolvidoNaNuvem(String idAlarme) async {
    if (Firebase.apps.isEmpty) return false;
    try {
      final uid = await FirebaseAuthService().aguardarUidPronto();
      if (uid == null) return false;

      final snapshot = await FirebaseFirestore.instance
          .collection(_colecao)
          .doc('${uid}_$idAlarme')
          .get()
          .timeout(_timeoutFirestore);
      if (!snapshot.exists) return false;

      final status = AlarmeAgendadoStatus.fromFirestore(
        snapshot.data()?['status'] as String?,
      );
      return status.jaResolvidoNaNuvem;
    } catch (e) {
      debugPrint(
          '⚠️ [AlarmeAgendadoCloudService] Falha ao consultar status prévio do alarme #$idAlarme: $e');
      return false;
    }
  }
}
