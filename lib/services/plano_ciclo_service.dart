import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_auth_service.dart';

/// Snapshot computado do ciclo recorrente de 30 dias do Plano Free —
/// espelho em Dart da MESMA regra calculada no servidor (ver
/// `functions/planoCicloService.js::calcularDiaAtual`), a partir dos
/// campos `isPremium`/`cycleStartDate` lidos de `usuarios/{uid}`.
///
/// Regra: contando o próprio dia de início como dia 1 —
/// - `isPremium == true`: sempre [ativo].
/// - Dias 1 a 10 do ciclo: [ativo] (recursos completos).
/// - Dias 11 a 30: bloqueado (só navegação básica).
/// - Acima de 30 dias (ciclo vencido, ainda não sincronizado com o
///   servidor): tratado como [ativo] por padrão — mesma blindagem
///   permissiva do restante do app (nunca bloquear por uma renovação
///   simplesmente atrasada; a Cloud Function corrige o valor real na
///   próxima sincronização, ver [PlanoCicloService.iniciar]).
@immutable
class PlanoCicloStatus {
  const PlanoCicloStatus({
    required this.isPremium,
    required this.cycleStartDate,
    required this.diaAtualCiclo,
    required this.ativo,
  });

  final bool isPremium;
  final DateTime cycleStartDate;

  /// Dia atual do ciclo, 1-based (o dia de início já é o dia 1). Pode
  /// ultrapassar 30 momentaneamente, se o app ainda não teve a chance de
  /// sincronizar a renovação automática com o servidor.
  final int diaAtualCiclo;

  /// `true` quando o usuário tem acesso total (Premium, ou dentro dos 10
  /// dias ativos do ciclo gratuito atual).
  final bool ativo;

  static const int _duracaoCicloDias = 30;
  static const int _duracaoAtivoDias = 10;

  /// Data em que o ciclo atual se autorrenova (novos 10 dias ativos).
  DateTime get dataRenovacao =>
      cycleStartDate.add(const Duration(days: _duracaoCicloDias));

  /// Dias de proteção completa restantes neste ciclo (0 se já bloqueado
  /// ou se for Premium — Premium não tem contagem, é sempre ilimitado).
  int get diasRestantesAtivos {
    if (isPremium || !ativo) return 0;
    // Ciclo vencido (dia > 30) ainda não renovado pelo servidor: na
    // próxima sincronização ele reinicia HOJE (dia 1, ver
    // `sincronizarCicloDoUsuario`), então o card mostra os 10 dias do
    // ciclo novo — antes mostrava "restam 0 dias" com o plano ativo.
    if (diaAtualCiclo > _duracaoCicloDias) return _duracaoAtivoDias;
    final restantes = _duracaoAtivoDias - diaAtualCiclo + 1;
    return restantes.clamp(0, _duracaoAtivoDias);
  }

  /// Dias até a próxima renovação automática (liberação dos próximos 10
  /// dias) — usado no texto do modal de bloqueio e no indicador da tela
  /// inicial. Conta dias de CALENDÁRIO até a data exibida ao lado
  /// ([dataRenovacao]) — antes arredondava horas para cima, e o texto
  /// dizia "faltam 10 dias, em 11/10" num dia 02/10 (9 dias de calendário).
  int get diasParaRenovacao {
    final agora = DateTime.now();
    final hoje = DateTime.utc(agora.year, agora.month, agora.day);
    final renovacao = dataRenovacao.toLocal();
    final diaRenovacao = DateTime.utc(renovacao.year, renovacao.month, renovacao.day);
    return diaRenovacao.difference(hoje).inDays.clamp(0, _duracaoCicloDias);
  }

  /// 🧪 BANDEIRA DE TESTE TEMPORÁRIA (2026-09-04, pedido explícito do
  /// usuário) — força o app a se comportar como se o ciclo do Plano Free
  /// já tivesse passado dos 10 dias ativos, SEM alterar `cycleStartDate`
  /// de verdade no Firestore nem a data do sistema do aparelho. Único
  /// propósito: validar de ponta a ponta a desativação automática dos
  /// alarmes de rotina e o aviso no botão "Salvar Alarme" ao expirar o
  /// ciclo, sem esperar até a renovação real. `isPremium` continua
  /// respeitado normalmente (uma conta Premium de verdade não é afetada).
  ///
  /// ⚠️ OBRIGATÓRIO: voltar para `false` assim que o teste for confirmado
  /// — NUNCA subir para produção com isto em `true`.
  ///
  /// REVERTIDO PARA PRODUÇÃO (2026-09-04): segunda rodada de teste
  /// confirmada com sucesso (aba Monitoramento em vermelho + bloqueio do
  /// Cronômetro Regressivo) — voltando a `false`.
  static const bool debugForcarPlanoFreeBloqueado = false;

  /// Constrói o status a partir dos dados brutos de `usuarios/{uid}`.
  /// Blindado contra documento ausente/campo nunca gravado: nesse caso,
  /// assume um ciclo começando AGORA (dia 1, ativo) — nunca bloqueia por
  /// falta de dado, já que a Cloud Function inicializa o campo de verdade
  /// na primeira sincronização (ver [PlanoCicloService.iniciar]).
  factory PlanoCicloStatus.fromDoc(Map<String, dynamic>? dados) {
    final bool isPremium = dados?['isPremium'] as bool? ?? false;
    final Timestamp? timestamp = dados?['cycleStartDate'] as Timestamp?;
    final DateTime inicio = timestamp?.toDate() ?? DateTime.now();
    final int diaAtual =
        DateTime.now().difference(inicio).inDays.clamp(0, 1 << 30) + 1;
    final bool dentroDaJanelaAtiva = !debugForcarPlanoFreeBloqueado &&
        (diaAtual <= _duracaoAtivoDias ||
            diaAtual > _duracaoCicloDias); // ciclo vencido -> permissivo
    return PlanoCicloStatus(
      isPremium: isPremium,
      cycleStartDate: inicio,
      diaAtualCiclo: diaAtual,
      ativo: isPremium || dentroDaJanelaAtiva,
    );
  }
}

/// Serviço central da regra de monetização/limitação do Plano Free —
/// ciclo recorrente de 30 dias (10 ativos + 20 bloqueados), com a
/// proteção de servidor pedida explicitamente: os campos que definem o
/// ciclo (`isPremium`/`cycleStartDate`) vivem em `usuarios/{uid}` no
/// Firestore (nunca em SharedPreferences/SQLite locais), e SÓ a Cloud
/// Function `sincronizarCicloPlano` (Admin SDK) pode escrevê-los — ver
/// `firestore.rules` e `functions/planoCicloService.js`. Isso garante que
/// desinstalar/reinstalar o app, ou adulterar o armazenamento local, não
/// reinicia nem burla o ciclo: ao logar de novo com o mesmo número, o
/// status já vem direto do servidor.
///
/// LIMITE HONESTO deste modelo (documentado aqui para nunca ser
/// esquecido): o BLOQUEIO em si (impedir o envio do SMS/Push, recusar
/// compartilhar localização, abrir a câmera) é aplicado no CLIENTE,
/// checando estes campos. Um cliente adulterado/recompilado
/// sem essas checagens poderia, em tese, ignorá-las. O que ESTE serviço
/// resolve de verdade é: (1) o ciclo não pode ser resetado reinstalando o
/// app ou limpando dados locais, e (2) `isPremium`/`cycleStartDate` não
/// podem ser forjados por uma escrita direta ao Firestore a partir do
/// app, mesmo por um cliente adulterado — só a Cloud Function concede
/// esses valores.
class PlanoCicloService {
  PlanoCicloService._internal();
  static final PlanoCicloService _instance = PlanoCicloService._internal();
  factory PlanoCicloService() => _instance;

  static const String _colecaoUsuarios = 'usuarios';
  static const Duration _timeout = Duration(seconds: 8);

  bool _sincronizadoNestaSessao = false;

  String? get _uid => FirebaseAuthService().uidAtual;

  /// `true` só com Firebase inicializado E sessão ativa. Sem sessão
  /// (ninguém logado no aparelho), o SMS de emergência já é
  /// o ÚNICO canal disponível por outros motivos (sem nuvem, sem como
  /// resolver o `uid`) — não há ciclo de servidor para consultar aqui, e
  /// [podeUsarRecursosAvancados] trata esse caso como liberado por
  /// padrão (ver documentação do método).
  bool get _firebaseDisponivel => Firebase.apps.isNotEmpty && _uid != null;

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection(_colecaoUsuarios).doc(_uid);

  /// Deve ser chamada uma única vez por sessão do engine, junto dos
  /// demais serviços pesados (ver
  /// `main.dart::iniciarServicosPosLoginOuDashboard`). Dispara (sem
  /// aguardar — nunca deve atrasar o boot) a callable
  /// `sincronizarCicloPlano`, que inicializa o ciclo no primeiro login de
  /// sempre desta conta e renova automaticamente ao completar 30 dias.
  /// Sem conexão no momento, o app simplesmente segue com o último
  /// `cycleStartDate` já gravado no Firestore (lido sob demanda por
  /// [obterStatusAtualizado]) — a próxima sessão com internet tenta de
  /// novo.
  void iniciar() {
    if (_sincronizadoNestaSessao) {
      debugPrint('☁️ [PlanoCicloService] iniciar() ignorado — já sincronizado nesta sessão.');
      return;
    }
    _sincronizadoNestaSessao = true;
    unawaited(_aguardarSessaoESincronizar());
  }

  /// CORREÇÃO (2026-08-18, confirmado em teste físico — Moto G7 Play):
  /// `iniciar()` era chamado com [_uid] SÍNCRONO ainda `null` logo após um
  /// login fresco (mesma classe de corrida já documentada e resolvida em
  /// [FirebaseAuthService.aguardarUidPronto] para outros fluxos) — o
  /// resultado era um retorno 100% silencioso (nenhum print de sucesso
  /// nem de falha) e a Cloud Function `sincronizarCicloPlano` NUNCA
  /// chegava a ser sequer invocada durante toda a sessão (confirmado:
  /// zero logs no servidor). Agora aguarda ativamente a sessão ficar
  /// pronta (com teto de tempo) antes de desistir.
  Future<void> _aguardarSessaoESincronizar() async {
    if (Firebase.apps.isEmpty) {
      debugPrint('☁️ [PlanoCicloService] Firebase indisponível — sincronização do ciclo adiada.');
      return;
    }
    final String? uid = await FirebaseAuthService().aguardarUidPronto();
    if (uid == null) {
      debugPrint('☁️ [PlanoCicloService] Sem sessão mesmo após aguardar — sincronização do ciclo adiada.');
      return;
    }
    debugPrint('☁️ [PlanoCicloService] Disparando sincronização do ciclo do plano (uid=$uid)...');
    await _sincronizarNoServidor();
  }

  Future<void> _sincronizarNoServidor() async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('sincronizarCicloPlano')
          .call()
          .timeout(_timeout);
      debugPrint('☁️ [PlanoCicloService] Ciclo do Plano Free sincronizado/renovado no servidor.');
    } catch (e) {
      debugPrint('⚠️ [PlanoCicloService] Falha ao sincronizar ciclo no servidor '
          '(app segue com o último valor conhecido): $e');
    }
  }

  /// Leitura em tempo real, para a UI reativa (indicador da tela inicial,
  /// ver `InicioDashboard`) — `null` sem sessão/Firebase indisponível.
  Stream<PlanoCicloStatus?> statusStream() {
    if (!_firebaseDisponivel) return Stream<PlanoCicloStatus?>.value(null);
    return _doc
        .snapshots()
        .map((snap) => PlanoCicloStatus.fromDoc(snap.data()))
        .handleError((e) {
      debugPrint('⚠️ [PlanoCicloService] Falha no listener do ciclo do plano: $e');
    });
  }

  /// Leitura pontual e SEMPRE FRESCA (nunca cacheada) do status atual —
  /// usada tanto pelos pontos de bloqueio (via [podeUsarRecursosAvancados])
  /// quanto pelo modal de upsell (data de renovação exibida ao usuário).
  /// Deliberadamente uma consulta nova a cada chamada, em vez de um
  /// listener em memória: os pontos de bloqueio também rodam no isolate
  /// HEADLESS do `android_alarm_manager_plus` (alarme nativo disparando
  /// com o app fechado, ver `EmergencyAlertService`), que não compartilha
  /// memória com o engine principal — só uma leitura de rede própria é
  /// confiável nos dois contextos. `null` sem sessão ou em caso de falha.
  Future<PlanoCicloStatus?> obterStatusAtualizado() async {
    if (!_firebaseDisponivel) return null;
    try {
      final snap = await _doc.get().timeout(_timeout);
      return PlanoCicloStatus.fromDoc(snap.data());
    } catch (e) {
      debugPrint('⚠️ [PlanoCicloService] Falha ao ler o ciclo do plano: $e');
      return null;
    }
  }

  /// PONTO ÚNICO DE DECISÃO — ÚNICA trava do Plano Free no app
  /// (reespecificação do usuário, 2026-09-04: sem nenhum teto numérico
  /// adicional) — usado por todos os bloqueios de mensagens/alertas (SMS
  /// + Push, ver [EmergencyAlertService]/[FirebaseSyncService]), de
  /// localização em tempo real (ver [MonitoramentoService]) e de captura
  /// de foto (ver `CapturaDissuasaoService`).
  ///
  /// Retorna `true` (libera o recurso) quando: Premium ativo, dentro dos
  /// 10 dias ativos do ciclo gratuito, OU — de propósito — sempre que o
  /// status não pôde ser determinado agora (sem sessão/Firebase
  /// indisponível, falha de rede, timeout). Esta última blindagem é
  /// deliberada: uma falha/atraso técnico no controle de MONETIZAÇÃO
  /// nunca deve, por si só, silenciar um recurso de SEGURANÇA (SOS,
  /// alerta de pânico).
  Future<bool> podeUsarRecursosAvancados() async {
    final status = await obterStatusAtualizado();
    return status?.ativo ?? true;
  }
}
