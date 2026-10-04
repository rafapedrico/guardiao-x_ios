import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'location_service.dart';
import 'plano_ciclo_service.dart';

/// Resultado de [MonitoramentoService.pedirLocalizacaoAtual].
enum ResultadoPedidoPosicao { posicaoNova, semResposta, semPermissao, limiteExcedido }

/// Serviço central da aba Monitoramento: gerencia a lista LOCAL de
/// contatos (SQLite, tabela `monitoramento_contatos`, TOTALMENTE
/// independente dos contatos de emergência do alarme/pânico) e a
/// permissão bilateral de compartilhamento de localização GPS em tempo
/// real com cada um deles, persistida na nuvem em
/// `permissoes_monitoramento/{uidAlvo}__{uidSolicitante}` (ver
/// `firestore.rules` e `functions/monitoramentoService.js`).
///
/// Cada contato pode ter até DUAS relações de permissão independentes,
/// cada uma com seu próprio ciclo de vida:
/// - Bloco A ("ver localização dele"): documento onde EU sou
///   `uidSolicitante` — ver [solicitarLocalizacao].
/// - Compartilhamento ("compartilhar minha localização com ele"):
///   documento onde EU sou `uidAlvo` — pode ser concedido/bloqueado
///   REATIVAMENTE (ele me solicita, eu respondo — ver
///   [responderSolicitacao]) ou PROATIVAMENTE, direto no switch de cada
///   contato, mesmo sem ele nunca ter solicitado — ver
///   [definirPermissaoCompartilhamento].
///
/// As colunas `status_ver_localizacao`/`status_compartilhamento` da
/// tabela local são apenas um CACHE para exibição imediata/offline — a
/// fonte de verdade é sempre o documento no Firestore, e a UI (Etapa 2)
/// deve preferir os streams em tempo real ([statusPermissaoStream],
/// [pedidosRecebidosPendentesStream]) sempre que houver conexão.
class MonitoramentoService {
  MonitoramentoService._internal();
  static final MonitoramentoService _instance =
      MonitoramentoService._internal();
  factory MonitoramentoService() => _instance;

  static const String colecaoPermissoes = 'permissoes_monitoramento';

  static const String statusPendente = 'pendente';
  static const String statusAprovado = 'aprovado';
  static const String statusNegado = 'negado';
  static const String statusBloqueado = 'bloqueado';
  static const String statusExpirado = 'expirado';

  /// Valores padrão do cache local antes de qualquer solicitação existir.
  static const String statusVerNaoSolicitado = 'nao_solicitado';
  static const String statusCompartilharInexistente = 'inexistente';

  /// Retornado por [solicitarLocalizacao]/[definirPermissaoCompartilhamento]
  /// quando a ação foi recusada por causa do BLOQUEIO BIDIRECIONAL de
  /// localização em tempo real do ciclo do Plano Free (ver
  /// PlanoCicloService) — fora dos 10 dias ativos do mês, sem Premium, o
  /// usuário não pode nem VER a localização de terceiros nem PASSAR A
  /// COMPARTILHAR a própria (revogar/bloquear um compartilhamento já
  /// concedido continua sempre permitido, por ser uma ação
  /// segurança-positiva).
  static const String statusBloqueadoPlanoFree = 'bloqueado_plano_free';

  /// Incrementado a cada alteração relevante na lista local de contatos
  /// ou em seus status em cache — mesmo padrão de
  /// [ContatosEmergenciaService.versaoContatos], consumido pela
  /// MonitoramentoTab via [ValueListenableBuilder]/`addListener`.
  static final ValueNotifier<int> versaoMonitoramento = ValueNotifier<int>(0);

  static void _notificarAlteracao() => versaoMonitoramento.value++;

  /// Janela de validade de uma marca em [marcarResolvidoDireto] — curta o
  /// bastante para nunca bloquear um ciclo GENUÍNO futuro da MESMA
  /// solicitação (o mesmo par de contas pode gerar o mesmo `permissaoId`
  /// de novo em outro dia), generosa o bastante para cobrir a corrida
  /// real observada em teste físico entre esta marca e os demais
  /// listeners que competem para abrir o modal de decisão.
  static const int _janelaResolvidoDiretoMs = 8000;

  /// Registro COMPARTILHADO (em disco, via `SharedPreferences` — NÃO em
  /// memória) de um `idPermissao` já resolvido direto pelas ações rápidas
  /// [Aceitar]/[Recusar] da notificação (ver
  /// `NotificacaoService._processarRespostaPayloadJson` e
  /// `LoginScreen._abrirModalDecisaoAposLogin`).
  ///
  /// CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06, DUAS
  /// causas raiz distintas, ambas confirmadas com teste físico real):
  ///
  /// 1) Tocar numa dessas ações abre o app (mesmo padrão de qualquer
  ///    notificação com `showsUserInterface: true`) — e o app reabrindo
  ///    (ou o próprio caminho nativo `SolicitacaoMonitoramentoWakeService`,
  ///    ou o listener independente [pedidosRecebidosPendentesStream] de
  ///    `MonitoramentoTab`) também detecta a MESMA solicitação (ainda
  ///    "pendente" no instante em que competem, porque a escrita de
  ///    [responderSolicitacao] é assíncrona e ainda não terminou) e abre
  ///    o modal de decisão de novo — por cima da decisão que o usuário JÁ
  ///    tinha tomado ao tocar o botão da notificação.
  ///
  /// 2) MAIS IMPORTANTE — o toque na ação da notificação pode ser
  ///    entregue via `onDidReceiveBackgroundNotificationResponse`, um
  ///    ISOLATE Dart TOTALMENTE SEPARADO do engine principal do app
  ///    (mesma limitação já documentada para
  ///    `firebaseMessagingBackgroundHandler` em `fcm_service.dart`).
  ///    Isolates Dart NUNCA compartilham memória de campos `static` entre
  ///    si — um `Set` em memória (a versão original desta correção) só
  ///    protegia listeners rodando NO MESMO isolate; o caminho nativo
  ///    (sempre no engine PRINCIPAL) nunca via a marca feita por essa
  ///    outra isolate, perdendo a corrida sempre. `SharedPreferences`
  ///    persiste em disco, lido/escrito por QUALQUER isolate/engine do
  ///    mesmo processo — o mesmo padrão já comprovado neste projeto para
  ///    exatamente este tipo de coordenação entre engines/isolates
  ///    separados (ver `SosDisparoService._reivindicarDisparoUnico`).
  static Future<void> marcarResolvidoDireto(String idPermissao) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'monitoramento_resolvido_direto_$idPermissao',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Falha ao marcar resolução direta ($idPermissao): $e');
    }
  }

  /// `true` se [idPermissao] foi marcado por [marcarResolvidoDireto] há
  /// menos de [_janelaResolvidoDiretoMs] — usado pelos demais listeners
  /// (`MonitoramentoTab`, caminho nativo) para pular a exibição do modal
  /// de decisão quando a resolução já está em andamento/concluída por
  /// outro caminho.
  static Future<bool> foiResolvidoDireto(String idPermissao) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final marcadoEm = prefs.getInt('monitoramento_resolvido_direto_$idPermissao');
      if (marcadoEm == null) return false;
      return DateTime.now().millisecondsSinceEpoch - marcadoEm < _janelaResolvidoDiretoMs;
    } catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Falha ao checar resolução direta ($idPermissao): $e');
      return false;
    }
  }

  String? get _meuUid => FirebaseAuthService().uidAtual;

  bool get _firebaseDisponivel => Firebase.apps.isNotEmpty && _meuUid != null;

  // ==========================================================
  // CONTATOS LOCAIS (SQLite) — gerenciamento independente
  // ==========================================================

  Future<List<Map<String, dynamic>>> listarContatos() async {
    await _garantirCacheDaContaAtual();
    return DatabaseHelper().listarContatosMonitoramento();
  }

  static const String _chaveContaDonaDoCache = 'monitoramento_cache_uid_dono';

  /// CORREÇÃO (feedback do build 109 — "Ver localização mostra a MINHA
  /// posição, e não a do contato"): a tabela local de contatos guarda o uid
  /// resolvido de cada contato e o status "aprovado" em cache, mas NÃO é
  /// apagada ao sair da conta. Entrando com OUTRA conta no mesmo aparelho,
  /// as linhas da conta anterior continuavam valendo — e se o contato
  /// cadastrado era justamente a conta que agora está logada, o card usava
  /// o MEU uid como alvo: o documento de permissão `eu__eu` não existe, o
  /// card caía no "aprovado" do cache e lia `usuarios/{meuUid}/monitoramento/atual`
  /// (o dono sempre pode ler o próprio) → a minha própria posição no mapa.
  ///
  /// Agora o cache tem dono: se a conta mudou, tudo o que foi resolvido na
  /// nuvem é descartado (nome/telefone ficam; o uid é resolvido de novo na
  /// próxima solicitação). Sem dono registrado (instalações anteriores a
  /// esta correção), só as linhas que apontam para a própria conta.
  Future<void> _garantirCacheDaContaAtual() async {
    final meuUid = _meuUid;
    if (meuUid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final dono = prefs.getString(_chaveContaDonaDoCache);
      if (dono == meuUid) {
        await DatabaseHelper().limparResolucaoContatosMonitoramento(somenteUid: meuUid);
        return;
      }
      final apagadas = await DatabaseHelper()
          .limparResolucaoContatosMonitoramento(somenteUid: dono == null ? meuUid : null);
      await prefs.setString(_chaveContaDonaDoCache, meuUid);
      if (apagadas > 0) {
        debugPrint('🧹 [MonitoramentoService] Cache de $apagadas contato(s) de monitoramento '
            'era de outra conta — descartado.');
        _notificarAlteracao();
      }
    } catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Falha ao conferir o dono do cache local: $e');
    }
  }

  /// Adiciona um novo contato à lista local. [telefone] é normalizado
  /// para E.164 (mesmo critério de `CadastroScreen`/`smsGateway.js`) antes
  /// de ser salvo, garantindo que corresponda ao que a Cloud Function vai
  /// procurar em `usuarios.telefone`.
  Future<int> adicionarContato({
    required String nome,
    required String telefone,
  }) async {
    final id = await DatabaseHelper().inserirContatoMonitoramento(
      nome: nome,
      telefone: _normalizarTelefoneE164(telefone),
    );
    _notificarAlteracao();
    return id;
  }

  Future<void> editarNomeContato(int id, String novoNome) async {
    await DatabaseHelper().atualizarNomeContatoMonitoramento(id, novoNome);
    _notificarAlteracao();
  }

  /// Remove o contato da lista local E revoga IMEDIATAMENTE, no Firestore,
  /// qualquer permissão de compartilhamento que eu tenha concedido a ele
  /// (reaproveita [definirPermissaoCompartilhamento] com `permitir: false`
  /// — mesmo caminho do switch de compartilhamento).
  ///
  /// CORREÇÃO DE FALHA CRÍTICA DE PRIVACIDADE (pedido do usuário,
  /// 2026-08-16): antes, este método só apagava a linha local do SQLite —
  /// o documento em `permissoes_monitoramento` continuava com `status:
  /// 'aprovado'` no Firestore, então o contato removido CONTINUAVA
  /// conseguindo ver minha localização em tempo real (o `StreamBuilder` do
  /// APARELHO DELE escuta esse documento diretamente, nunca minha lista
  /// local). Agora a revogação é chamada SEMPRE, incondicionalmente, ANTES
  /// de apagar a linha local (que fornece o telefone usado para resolver
  /// o documento certo) — nunca dependendo do cache local
  /// `status_compartilhamento`, que pode estar desatualizado.
  ///
  /// Depois de revogado, o status volta a um estado não aprovado — só
  /// uma NOVA solicitação (ver [solicitarLocalizacao]), com uma NOVA
  /// aprovação explícita minha, pode restabelecer o compartilhamento.
  ///
  /// Best-effort quanto à revogação: a remoção LOCAL sempre acontece
  /// (nunca deixa um contato "preso" na lista por falta de rede), mas
  /// retorna `false` quando a revogação em si falhou de verdade (erro de
  /// rede/servidor — não confundir com "não havia nada para revogar"),
  /// para que a UI ([MonitoramentoTab._excluirContato]) alerte o usuário
  /// a tentar de novo em vez de presumir silenciosamente que está seguro.
  Future<bool> removerContato(int id) async {
    final contato = await DatabaseHelper().buscarContatoMonitoramentoPorId(id);

    bool revogacaoOk = true;
    if (contato != null) {
      final resultado = await definirPermissaoCompartilhamento(
        idContatoLocal: id,
        permitir: false,
      );
      // 'numero_nao_encontrado'/'proprio_numero' não são falhas de
      // revogação — significam que nunca poderia ter existido uma
      // permissão de verdade para esse contato. Só 'erro' (rede/servidor)
      // é reportado como falha real ao chamador.
      revogacaoOk = resultado != 'erro';
    }

    await DatabaseHelper().deletarContatoMonitoramento(id);
    _notificarAlteracao();
    return revogacaoOk;
  }

  // ==========================================================
  // BLOCO A — "Ver localização dele" (eu = uidSolicitante)
  // ==========================================================

  /// Solicita a localização do contato local [idContatoLocal], via Cloud
  /// Function callable `solicitarMonitoramento`. Resolve o `uid` pelo
  /// telefone SERVER-SIDE (o cliente nunca consulta `usuarios` por
  /// telefone diretamente, ver `firestore.rules`).
  ///
  /// Retorna:
  /// - `'enviada'`: solicitação criada/reenviada, aguardando aprovação.
  /// - `'ja_aprovado'`: já havia permissão aprovada — nada a fazer.
  /// - `'numero_nao_encontrado'`: telefone não corresponde a nenhuma conta.
  /// - `'proprio_numero'`: o telefone informado é o do próprio usuário.
  /// - `'bloqueado_pelo_alvo'`: o contato me bloqueou (ver
  ///   [definirBloqueioPorTelefone]) — a Cloud Function nem chega a criar
  ///   um ciclo pendente nem a enviar Push.
  /// - `'erro'`: falha de rede/servidor.
  Future<String> solicitarLocalizacao(int idContatoLocal) async {
    if (!_firebaseDisponivel) return 'erro';
    if (!await PlanoCicloService().podeUsarRecursosAvancados()) {
      return statusBloqueadoPlanoFree;
    }

    final contato =
        await DatabaseHelper().buscarContatoMonitoramentoPorId(idContatoLocal);
    if (contato == null) return 'erro';

    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('solicitarMonitoramento')
          .call<Map<String, dynamic>>({
        'telefoneAlvo': contato['telefone'],
      });

      final dados = resultado.data;
      final uidAlvo = dados['uidAlvo'] as String?;
      final status = dados['status'] as String?;

      if (uidAlvo != null) {
        await DatabaseHelper()
            .atualizarUidContatoMonitoramento(idContatoLocal, uidAlvo);
      }
      if (status != null) {
        await DatabaseHelper()
            .atualizarStatusVerLocalizacao(idContatoLocal, status);
      }
      _notificarAlteracao();

      return status == statusAprovado ? 'ja_aprovado' : 'enviada';
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') return 'numero_nao_encontrado';
      if (e.code == 'invalid-argument') return 'proprio_numero';
      if (e.code == 'permission-denied') return 'bloqueado_pelo_alvo';
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao solicitar localização: ${e.code} ${e.message}');
      return 'erro';
    } catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Falha ao solicitar localização: $e');
      return 'erro';
    }
  }

  // ==========================================================
  // BLOCO B — "Compartilhar minha localização" (eu = uidAlvo)
  // ==========================================================

  /// Stream em tempo real das solicitações PENDENTES recebidas por mim —
  /// usada para exibir "Fulano está solicitando a sua localização.
  /// Permitir ou Bloquear?" (ver requisito de fluxo de consentimento).
  Stream<QuerySnapshot<Map<String, dynamic>>>
      pedidosRecebidosPendentesStream() {
    if (!_firebaseDisponivel) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection(colecaoPermissoes)
        .where('uidAlvo', isEqualTo: _meuUid)
        .where('status', isEqualTo: statusPendente)
        .snapshots();
  }

  /// Responde a uma solicitação recebida, aprovando ou negando. Só o alvo
  /// (dono da própria localização) pode escrever este status — ver
  /// `firestore.rules`. Garante que o solicitante também exista na minha
  /// lista local (o switch de pré-autorização só é exibido para contatos
  /// já resolvidos localmente), criando a linha automaticamente se
  /// ausente.
  Future<void> responderSolicitacao({
    required String permissaoId,
    required bool aprovar,
    required String uidSolicitante,
    required String nomeSolicitante,
    required String telefoneSolicitante,
  }) async {
    if (!_firebaseDisponivel) return;
    // Defesa em profundidade: a UI (ver `monitoramento_decisao_dialog.dart`)
    // já checa isso ANTES de chegar aqui e exibe o modal de upsell — este
    // segundo bloqueio cobre qualquer outro chamador futuro.
    if (aprovar && !await PlanoCicloService().podeUsarRecursosAvancados()) {
      aprovar = false;
    }
    final novoStatus = aprovar ? statusAprovado : statusNegado;

    try {
      await FirebaseFirestore.instance
          .collection(colecaoPermissoes)
          .doc(permissaoId)
          .update({
        'status': novoStatus,
        'atualizadoEm': FieldValue.serverTimestamp(),
        'respondidoEm': FieldValue.serverTimestamp(),
      });

      // Solução A: ao aprovar, não esperamos o próximo tick do heartbeat de
      // localização (que só roda enquanto o cronômetro de Segurança ou um
      // alarme de rotina estiverem ativos, ver [LocationService]) — capturamos
      // e enviamos a posição atual imediatamente, para que quem acabou de
      // ganhar acesso já encontre uma coordenada válida em
      // `usuarios/{meuUid}/monitoramento/atual` assim que abrir o mapa.
      // Fire-and-forget: o GPS pode levar alguns segundos e não deve atrasar
      // a resposta da solicitação nem quebrar o fluxo se falhar.
      if (aprovar) {
        unawaited(_enviarLocalizacaoImediataAoAceitar());
      }

      final contatoLocal = await DatabaseHelper()
          .buscarContatoMonitoramentoPorUid(uidSolicitante);

      int idContatoLocal;
      if (contatoLocal == null) {
        idContatoLocal = await DatabaseHelper().inserirContatoMonitoramento(
          nome: nomeSolicitante,
          telefone: telefoneSolicitante,
        );
        await DatabaseHelper()
            .atualizarUidContatoMonitoramento(idContatoLocal, uidSolicitante);
      } else {
        idContatoLocal = contatoLocal['id'] as int;
      }
      await DatabaseHelper()
          .atualizarStatusCompartilhamento(idContatoLocal, novoStatus);
      _notificarAlteracao();
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao responder solicitação $permissaoId: $e');
    }
  }

  /// Captura a posição atual do aparelho e a envia ao Firestore
  /// (`usuarios/{meuUid}/monitoramento/atual`), reaproveitando o mesmo
  /// [LocationService] e [FirebaseSyncService] usados pelo heartbeat
  /// periódico da Segurança/Família — ver [responderSolicitacao]. Falhas
  /// (GPS desligado, permissão negada, sem posição em memória) são apenas
  /// logadas: o próximo heartbeat periódico (se algum monitoramento externo
  /// estiver ativo) ou uma nova solicitação tentam novamente depois.
  Future<void> _enviarLocalizacaoImediataAoAceitar() async {
    try {
      final posicao = await LocationService().capturarLocalizacaoAtual();
      if (posicao == null) return;
      await FirebaseSyncService().atualizarLocalizacaoAtual(
        latitude: posicao.latitude,
        longitude: posicao.longitude,
        precisao: posicao.accuracy,
        origem: 'aceite',
      );
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao enviar localização imediata após aceite: $e');
    }
  }

  /// Define diretamente — sem esperar uma solicitação prévia do contato —
  /// se o contato local [idContatoLocal] pode receber a MINHA localização.
  /// Usada pelo Switch de pré-autorização exibido em CADA card da lista
  /// "Localização real", via Cloud Function callable
  /// `definirPermissaoCompartilhamento`, que resolve o uid do contato pelo
  /// telefone server-side e cria/atualiza o documento em
  /// `permissoes_monitoramento` diretamente como `aprovado`/`bloqueado`
  /// (pula o ciclo `pendente`, pois quem decide aqui é o dono da própria
  /// localização).
  ///
  /// Retorna:
  /// - `'sucesso'`: permissão definida.
  /// - `'numero_nao_encontrado'`: telefone não corresponde a nenhuma conta.
  /// - `'proprio_numero'`: o telefone informado é o do próprio usuário.
  /// - `'erro'`: falha de rede/servidor.
  Future<String> definirPermissaoCompartilhamento({
    required int idContatoLocal,
    required bool permitir,
  }) async {
    if (!_firebaseDisponivel) return 'erro';
    // Bloqueia apenas o caminho POSITIVO (passar a compartilhar) — negar/
    // revogar (`permitir: false`) é sempre permitido, inclusive quando
    // chamado internamente em cascata por [definirBloqueioPorTelefone] e
    // [removerContato], que nunca devem ser impedidos de revogar acesso.
    if (permitir && !await PlanoCicloService().podeUsarRecursosAvancados()) {
      return statusBloqueadoPlanoFree;
    }

    final contato =
        await DatabaseHelper().buscarContatoMonitoramentoPorId(idContatoLocal);
    if (contato == null) return 'erro';

    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('definirPermissaoCompartilhamento')
          .call<Map<String, dynamic>>({
        'telefoneContato': contato['telefone'],
        'permitir': permitir,
      });

      final dados = resultado.data;
      final uidContato = dados['uidContato'] as String?;
      final status = dados['status'] as String?;

      if (uidContato != null) {
        await DatabaseHelper()
            .atualizarUidContatoMonitoramento(idContatoLocal, uidContato);
      }
      if (status != null) {
        await DatabaseHelper()
            .atualizarStatusCompartilhamento(idContatoLocal, status);
      }
      _notificarAlteracao();

      // Solução A também se aplica aqui: este é o OUTRO caminho (além de
      // [responderSolicitacao]) pelo qual eu (dono da localização) concedo
      // acesso a alguém — via switch de pré-autorização, sem que o contato
      // precise ter solicitado antes. Mesmo gatilho de captura+envio
      // imediato de GPS, para não deixar quem acabou de ganhar acesso pelo
      // switch preso em "aguardando primeira localização" à toa.
      if (status == statusAprovado) {
        unawaited(_enviarLocalizacaoImediataAoAceitar());
      }

      return 'sucesso';
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') return 'numero_nao_encontrado';
      if (e.code == 'invalid-argument') return 'proprio_numero';
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir permissão de compartilhamento: ${e.code} ${e.message}');
      return 'erro';
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir permissão de compartilhamento: $e');
      return 'erro';
    }
  }

  // ==========================================================
  // BLOQUEIO DE SOLICITANTES — eixo independente do `status` acima
  // ==========================================================

  /// Bloqueia/desbloqueia — via telefone direto, sem exigir um contato já
  /// resolvido na lista local — que um solicitante específico envie NOVAS
  /// solicitações de localização para mim. Usada por
  /// [definirBloqueioSolicitante] abaixo (fluxo do slider dedicado de cada
  /// card da lista, ver `monitoramento_tab.dart`).
  ///
  /// [idContatoLocal], quando informado, cacheia localmente o `uid`
  /// resolvido pela Cloud Function — INDISPENSÁVEL para a reatividade do
  /// slider: sem ele, um contato cujo uid nunca foi resolvido antes fica
  /// sem `permissaoId` no lado Dart, e o card não consegue montar o
  /// `StreamBuilder` que escuta o campo `bloqueado` em tempo real.
  ///
  /// Persistido como campo booleano DEDICADO (`bloqueado`) no documento de
  /// permissão — eixo antes INDEPENDENTE do `status` de compartilhamento.
  ///
  /// REGRA DE CONSISTÊNCIA DE PRIVACIDADE (pedido do usuário, 2026-08-16):
  /// ao BLOQUEAR (nunca ao desbloquear), agora também força
  /// [definirPermissaoCompartilhamento] com `permitir: false` para o mesmo
  /// contato, se houver um [idContatoLocal] resolvido — não fazia sentido
  /// impedir novas solicitações e, ao mesmo tempo, continuar compartilhando
  /// ATIVAMENTE a localização já aprovada antes. Desbloquear continua
  /// **não** reativando o compartilhamento sozinho — isso ainda exige uma
  /// ação explícita separada do usuário no switch de compartilhamento.
  ///
  /// Retorna:
  /// - `'sucesso'`: bloqueio/desbloqueio definido.
  /// - `'numero_nao_encontrado'`: telefone não corresponde a nenhuma conta.
  /// - `'proprio_numero'`: o telefone informado é o do próprio usuário.
  /// - `'erro'`: falha de rede/servidor.
  Future<String> definirBloqueioPorTelefone({
    required String telefone,
    required bool bloquear,
    int? idContatoLocal,
  }) async {
    if (!_firebaseDisponivel) return 'erro';

    // TRAVA DO CICLO DO PLANO FREE (pedido explícito do usuário,
    // 2026-09-04 — ver PlanoCicloService): mesmo padrão de
    // [definirPermissaoCompartilhamento] — só a direção que LIBERA um
    // recurso (aqui, permitir que o contato volte a enviar solicitações)
    // é gated; BLOQUEAR nunca é, já que restringir é sempre uma ação
    // positiva de segurança, nunca um recurso premium.
    if (!bloquear && !await PlanoCicloService().podeUsarRecursosAvancados()) {
      return statusBloqueadoPlanoFree;
    }

    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('definirBloqueioSolicitante')
          .call<Map<String, dynamic>>({
        'telefoneContato': telefone,
        'bloquear': bloquear,
      });

      // CRÍTICO para a reatividade do slider: sem cachear o uid resolvido
      // aqui, um contato que NUNCA teve o uid resolvido antes (nunca usou
      // "Solicitar Localização" nem o switch de compartilhamento) continua
      // com `uid_contato` nulo no SQLite local mesmo depois do bloqueio —
      // e é esse uid que `MonitoramentoTab._construirCardVerLocalizacao`
      // usa para montar o `permissaoId` e abrir o StreamBuilder que reflete
      // o campo `bloqueado` em tempo real. Sem ele, o card nunca escuta o
      // documento certo: a escrita no Firestore funciona, mas a UI local
      // parece "não reagir" (volta a mostrar Liberado no próximo rebuild).
      if (idContatoLocal != null) {
        final uidContato = resultado.data['uidContato'] as String?;
        if (uidContato != null) {
          await DatabaseHelper()
              .atualizarUidContatoMonitoramento(idContatoLocal, uidContato);
        }
      }

      // REGRA DE CONSISTÊNCIA DE PRIVACIDADE (ver documentação completa
      // acima): bloquear novas solicitações também revoga o
      // compartilhamento ATIVO já concedido a este contato — nunca ao
      // desbloquear. Reaproveita [definirPermissaoCompartilhamento]
      // inteiro (não só a chamada à Cloud Function) para que o cache local
      // (`status_compartilhamento`) e a notificação de UI fiquem
      // consistentes nos dois eixos. Best-effort: uma falha aqui não deve
      // impedir o bloqueio em si (já concluído com sucesso acima) de ser
      // reportado como êxito — o usuário pode reabrir o switch de
      // compartilhamento manualmente se este segundo passo falhar.
      if (bloquear && idContatoLocal != null) {
        try {
          await definirPermissaoCompartilhamento(
            idContatoLocal: idContatoLocal,
            permitir: false,
          );
        } catch (e) {
          debugPrint(
              '⚠️ [MonitoramentoService] Falha ao revogar compartilhamento em cascata após bloqueio: $e');
        }
      }

      _notificarAlteracao();
      return 'sucesso';
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'not-found') return 'numero_nao_encontrado';
      if (e.code == 'invalid-argument') return 'proprio_numero';
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir bloqueio de solicitante: ${e.code} ${e.message}');
      return 'erro';
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao definir bloqueio de solicitante: $e');
      return 'erro';
    }
  }

  /// Mesma operação de [definirBloqueioPorTelefone], mas a partir do
  /// contato local [idContatoLocal] — usada pelo slider deslizante de cada
  /// card da lista "Localização real" (ver `monitoramento_tab.dart`).
  Future<String> definirBloqueioSolicitante({
    required int idContatoLocal,
    required bool bloquear,
  }) async {
    final contato =
        await DatabaseHelper().buscarContatoMonitoramentoPorId(idContatoLocal);
    if (contato == null) return 'erro';

    return definirBloqueioPorTelefone(
      telefone: contato['telefone'] as String,
      bloquear: bloquear,
      idContatoLocal: idContatoLocal,
    );
  }

  // ==========================================================
  // IDS DETERMINÍSTICOS E LISTENERS EM TEMPO REAL
  // ==========================================================

  String _montarIdPermissao(String uidAlvo, String uidSolicitante) =>
      '${uidAlvo}__$uidSolicitante';

  /// Doc id do Bloco A: "eu (`_meuUid`) vejo a localização de [uidAlvo]".
  String? idPermissaoParaVer(String uidAlvo) {
    final meuUid = _meuUid;
    if (meuUid == null) return null;
    return _montarIdPermissao(uidAlvo, meuUid);
  }

  /// Doc id do Bloco B: "[uidSolicitante] vê a localização de mim
  /// (`_meuUid`)".
  String? idPermissaoParaCompartilhar(String uidSolicitante) {
    final meuUid = _meuUid;
    if (meuUid == null) return null;
    return _montarIdPermissao(meuUid, uidSolicitante);
  }

  /// Listener genérico de um documento de permissão pelo seu id — usado
  /// pela UI (Etapa 2) para refletir o status de cada bloco de cada
  /// contato em tempo real, sem precisar de refresh manual.
  Stream<DocumentSnapshot<Map<String, dynamic>>> statusPermissaoStream(
    String permissaoId,
  ) {
    if (!_firebaseDisponivel) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection(colecaoPermissoes)
        .doc(permissaoId)
        .snapshots();
  }

  /// Busca (leitura única, sem stream) a última posição conhecida de
  /// [uidAlvo] em `usuarios/{uidAlvo}/monitoramento/atual` — só retorna
  /// dados se o Bloco A estiver `aprovado` (ver `firestore.rules`); caso
  /// contrário, a própria leitura é negada pelo Firestore e este método
  /// devolve `null` silenciosamente. Usada pelo botão "Ver no mapa".
  Future<Map<String, dynamic>?> buscarUltimaLocalizacao(String uidAlvo) async {
    if (!_firebaseDisponivel) return null;
    // Nunca a própria posição como se fosse a de um contato (ver
    // [_garantirCacheDaContaAtual]).
    if (uidAlvo == _meuUid) {
      debugPrint('⚠️ [MonitoramentoService] Contato aponta para a própria conta — ignorado.');
      return null;
    }
    // BLOQUEIO BIDIRECIONAL de localização do ciclo do Plano Free (ver
    // PlanoCicloService) — lado "visualizar": além de [_abrirMapa] já
    // checar isso antes de abrir o mapa (exibindo o modal de upsell),
    // este `null` aqui também suprime a data de "atualizado há X min" e o
    // botão "Ver no mapa" exibidos no próprio card (ver
    // `_construirLinhaAprovado` em `monitoramento_tab.dart`), sem nunca
    // expor a coordenada em si.
    if (!await PlanoCicloService().podeUsarRecursosAvancados()) return null;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uidAlvo)
          .collection('monitoramento')
          .doc('atual')
          .get()
          .timeout(const Duration(seconds: 8));
      return snap.data();
    } catch (e) {
      debugPrint(
          '⚠️ [MonitoramentoService] Falha ao buscar última localização de $uidAlvo: $e');
      return null;
    }
  }

  /// Pede ao aparelho de [uidAlvo] a posição ATUAL (callable
  /// `pedirLocalizacaoAtual`, que manda um push silencioso) e espera por uma
  /// posição gravada depois do pedido — tudo dentro de [limite] (callable +
  /// espera), mesmo que a callable nunca responda.
  ///
  /// - [ResultadoPedidoPosicao.posicaoNova]: chegou posição nova.
  /// - [ResultadoPedidoPosicao.semPermissao]: `permission-denied` — o contato
  ///   não está compartilhando a localização comigo; não adianta esperar.
  /// - [ResultadoPedidoPosicao.limiteExcedido]: `resource-exhausted` (limite
  ///   de 1 pedido/min) — ver [liberaNovoPedidoEm].
  /// - [ResultadoPedidoPosicao.semResposta]: qualquer outro caso (sem
  ///   resposta, alvo sem rastreamento, function indisponível) — o mapa
  ///   abre com a última posição e o horário.
  Future<ResultadoPedidoPosicao> pedirLocalizacaoAtual(
    String uidAlvo, {
    Duration limite = const Duration(seconds: 30),
  }) async {
    if (!_firebaseDisponivel || uidAlvo == _meuUid) {
      return ResultadoPedidoPosicao.semResposta;
    }
    // Ainda dentro do limite que o servidor acabou de recusar: nem chama.
    if (liberaNovoPedidoEm(uidAlvo) != null) return ResultadoPedidoPosicao.limiteExcedido;
    final pedidoEm = DateTime.now();
    final prazo = pedidoEm.add(limite);
    Duration restante() {
      final r = prazo.difference(DateTime.now());
      return r.isNegative ? Duration.zero : r;
    }

    try {
      final limiteCallable = restante() < const Duration(seconds: 10)
          ? restante()
          : const Duration(seconds: 10);
      await FirebaseFunctions.instance
          .httpsCallable('pedirLocalizacaoAtual')
          .call<Map<String, dynamic>>({'uidAlvo': uidAlvo})
          .timeout(limiteCallable);
      _ultimoPedidoPosicaoEm[_chavePar(uidAlvo)] = pedidoEm;
    } on FirebaseFunctionsException catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Pedido de posição atual recusado: ${e.code} ${e.message}');
      switch (e.code) {
        case 'permission-denied':
          return ResultadoPedidoPosicao.semPermissao;
        case 'resource-exhausted':
          _liberaPedidoPosicaoEm[_chavePar(uidAlvo)] = _calcularLiberacao(uidAlvo);
          return ResultadoPedidoPosicao.limiteExcedido;
        default:
          return ResultadoPedidoPosicao.semResposta;
      }
    } catch (e) {
      debugPrint('⚠️ [MonitoramentoService] Pedido de posição atual não enviado: $e');
      return ResultadoPedidoPosicao.semResposta;
    }
    try {
      await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(uidAlvo)
          .collection('monitoramento')
          .doc('atual')
          .snapshots()
          .firstWhere((snap) {
            final momento = snap.data()?['atualizadoEm'];
            return momento is Timestamp &&
                momento.toDate().isAfter(pedidoEm.subtract(const Duration(seconds: 2)));
          })
          .timeout(restante());
      return ResultadoPedidoPosicao.posicaoNova;
    } on FirebaseException catch (e) {
      return e.code == 'permission-denied'
          ? ResultadoPedidoPosicao.semPermissao
          : ResultadoPedidoPosicao.semResposta;
    } catch (_) {
      return ResultadoPedidoPosicao.semResposta;
    }
  }

  /// Limite do servidor para `pedirLocalizacaoAtual`: 1 pedido/min por PAR
  /// solicitante→alvo (`controle/pedido_{alvo}__{solicitante}`), contado a
  /// partir do último pedido ACEITO — os recusados não reiniciam o prazo. O
  /// servidor não informa os segundos restantes, então a contagem é local.
  static const Duration _intervaloPedidoPosicao = Duration(minutes: 1);
  final Map<String, DateTime> _ultimoPedidoPosicaoEm = {};
  final Map<String, DateTime> _liberaPedidoPosicaoEm = {};

  String _chavePar(String uidAlvo) => '${uidAlvo}__$_meuUid';

  /// Quando um novo [pedirLocalizacaoAtual] para [uidAlvo] deve ser aceito
  /// depois de um `resource-exhausted` (`null` = liberado).
  DateTime? liberaNovoPedidoEm(String uidAlvo) {
    final ate = _liberaPedidoPosicaoEm[_chavePar(uidAlvo)];
    if (ate == null || !DateTime.now().isBefore(ate)) return null;
    return ate;
  }

  /// 60 s depois do último pedido aceito deste par que este app conhece; sem
  /// ele (o pedido aceito veio de outra sessão da mesma conta), 60 s a
  /// partir de agora — nunca libera antes do servidor.
  DateTime _calcularLiberacao(String uidAlvo) {
    final agora = DateTime.now();
    final ultimo = _ultimoPedidoPosicaoEm[_chavePar(uidAlvo)];
    final pelaUltima = ultimo?.add(_intervaloPedidoPosicao);
    if (pelaUltima != null && pelaUltima.isAfter(agora)) return pelaUltima;
    return agora.add(_intervaloPedidoPosicao);
  }

  /// Estado do rastreamento contínuo de [uidAlvo]
  /// (`usuarios/{uidAlvo}/monitoramento/estado`, gravado pelo aparelho dele):
  /// permissão, se está ativo e, nos dias bloqueados do Plano Free,
  /// `bloqueadoAte`. Vazio se não houver/sem permissão de leitura.
  Stream<Map<String, dynamic>?> estadoAlvoStream(String uidAlvo) {
    if (!_firebaseDisponivel || uidAlvo == _meuUid) return Stream.value(null);
    return FirebaseFirestore.instance
        .collection('usuarios')
        .doc(uidAlvo)
        .collection('monitoramento')
        .doc('estado')
        .snapshots()
        .map((snap) => snap.data())
        .handleError((Object e) {
      debugPrint('⚠️ [MonitoramentoService] Estado do rastreamento de $uidAlvo indisponível: $e');
    });
  }

  /// Mesma normalização de `CadastroScreen._normalizarTelefoneE164` e de
  /// `normalizarTelefoneE164` em `functions/smsGateway.js`: números sem
  /// "+" recebem o prefixo do Brasil ("+55").
  String _normalizarTelefoneE164(String telefone) {
    final limpo = telefone.replaceAll(RegExp(r'[^\d+]'), '');
    if (limpo.startsWith('+')) return limpo;
    return '+55$limpo';
  }
}
