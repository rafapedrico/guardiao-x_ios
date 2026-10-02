/**
 * Pipeline de disparo de alerta via Push FCM — módulo compartilhado pelas
 * duas origens de alerta já existentes (`aoReceberAlertaTentativaDesarme`
 * em `index.js` e `monitorarAlarmesAgendados` em
 * `scheduledAlarmMonitor.js`).
 *
 * REMOÇÃO DO WHATSAPP (2026-08-11): este módulo enviava também WhatsApp
 * de contingência via Twilio (transbordo 60s após o Push, ou imediato com
 * a chave global "Enviar também via WhatsApp"), debitando a Carteira de
 * Créditos do usuário a cada envio — removido por completo a pedido do
 * usuário, junto com `smsGateway.js`, `transbordoWhatsappMonitor.js`,
 * `walletService.js` e `comprasService.js`. O único canal de nuvem
 * restante é o Push FCM App-para-App, gratuito, para contatos de
 * emergência que também têm o Guardião X instalado.
 *
 * 1. Resolve, por telefone, quais dos contatos de emergência têm conta
 *    no app (Push FCM gratuito, App-para-App).
 * 2. Envia o Push (alta prioridade) a quem foi encontrado.
 * 3. Registra `entregas_alerta/{idEntrega}` — mantido como bookkeeping de
 *    entrega (ver `FirebaseSyncService.confirmarEntregaAlerta`/
 *    `FcmService` no app), mesmo sem nenhum job de transbordo consumindo
 *    mais essa confirmação.
 *
 * REGRA DE NEGÓCIO PERMANENTE (custo de infraestrutura, reafirmada
 * explicitamente pelo usuário): este módulo é o ÚNICO caminho de disparo
 * de alerta a partir da NUVEM (chamado tanto pelo trigger reativo em
 * `index.js` quanto pelo monitoramento agendado em
 * `scheduledAlarmMonitor.js`) e NUNCA deve enviar SMS por gateway/API
 * paga de terceiros — apenas Push FCM App-para-App, sem custo. O SMS
 * nativo (via `SmsManager` do próprio aparelho, sem custo para o
 * servidor) só existe no lado do CLIENTE Flutter (ver
 * `EmergencyAlertService`), quando o aparelho do usuário está ligado, com
 * sinal e crédito/plano ativo. Qualquer novo canal de nuvem que envolva
 * custo de SMS/WhatsApp de terceiros violaria essa regra — não
 * reintroduzir sem alinhamento explícito.
 *
 * MOTOR DE RETENTATIVA PROGRESSIVA (2026-08-22, ver `entregaRetryEngine.js`):
 * além do disparo imediato feito por [dispararAlertaHibrido] abaixo, cada
 * contato de emergência ganha um sub-documento de acompanhamento em
 * `entregas_alerta/{idEntrega}/destinatarios/{contatoId}` (criado por
 * [criarDestinatariosDeAcompanhamento]), consumido pelo cron de 1 minuto
 * em `entregaRetryEngine.js` para reenviar o Push (com o `fcmToken`
 * SEMPRE resolvido de novo na hora, nunca em cache) em intervalos
 * crescentes por até 48h, até o contato confirmar ENTREGUE ou o prazo
 * esgotar (ver `relatorioFalhaService.js`).
 */

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164} = require("./telefoneUtils");
const {calcularDiaAtual, DURACAO_ATIVO_DIAS} = require("./planoCicloService");
const {montarApnsAlerta} = require("./apnsPayload");

const db = getFirestore();

const COLECAO_ENTREGAS = "entregas_alerta";
const SUBCOLECAO_DESTINATARIOS = "destinatarios";
const TITULO_PUSH = "🚨 Alerta de segurança";
const STATUS_DESTINATARIO_PENDENTE = "PENDENTE";
const PRIMEIRO_INTERVALO_RETENTATIVA_MS = 60 * 1000; // 1 min (0–20 min decorridos)

/**
 * Título do banner do iOS (bloco `apns`): o Android monta o próprio
 * título no app a partir de `nomeRemetente` (ver
 * `NotificacaoService.exibirNotificacaoAlertaRecebido`), mas no iOS quem
 * exibe é o sistema, direto do payload — então o servidor já manda o
 * título final.
 *
 * @param {string} nomeRemetente
 * @return {string}
 */
function tituloPushIos(nomeRemetente) {
  return nomeRemetente ? `🚨 Alerta de ${nomeRemetente}` : TITULO_PUSH;
}

/**
 * Para cada contato `{nome, telefone}`, normaliza o telefone e busca em
 * `usuarios` por uma conta com esse mesmo telefone — é assim que o app
 * resolve, EM TEMPO DE ALERTA, quais dos contatos de emergência possuem
 * o Guardião X instalado (sem depender de o usuário "vincular guardiões"
 * manualmente).
 *
 * @param {Array<{nome?: string, telefone?: string}>} contatos
 * @return {Promise<Array<{nome: string, telefone: string, uidDestino: string|null, fcmToken: string|null}>>}
 */
async function resolverContasPorTelefone(contatos) {
  return Promise.all(
      (contatos || []).map(async (contato) => {
        const telefoneNormalizado = normalizarTelefoneE164(contato.telefone);
        const base = {
          nome: contato.nome || "",
          telefone: telefoneNormalizado || contato.telefone || "",
          uidDestino: null,
          fcmToken: null,
        };

        if (!telefoneNormalizado) return base;

        try {
          // CORREÇÃO (bug real confirmado em teste físico, 2026-08-14 —
          // "messaging/registration-token-not-registered" mesmo com o
          // token atual sincronizado no Firestore): quando o MESMO
          // telefone está cadastrado em mais de uma conta (contas de
          // teste antigas nunca apagadas, por exemplo), `.limit(1)` sem
          // ordenação pegava a PRIMEIRA que o Firestore devolvesse — uma
          // ordem arbitrária, não necessariamente a conta ativa de
          // verdade.
          //
          // TENTATIVA 1 (revertida): `orderBy(fcmTokenAtualizadoEm, desc)`
          // direto na query — funcionalmente correta, MAS o Firestore
          // EXCLUI dos resultados qualquer documento que não tenha o
          // campo ordenado (confirmado em teste físico: uma conta cujo
          // token ainda não tinha sido sincronizado sob este código novo
          // simplesmente sumia da lista, mesmo sendo a única conta ativa
          // de verdade — pior que o bug original).
          //
          // Escolhe em MEMÓRIA em vez de na query: busca todas as contas
          // com esse telefone (query simples, equality-only, sem
          // depender de nenhum índice composto) e escolhe a com
          // `fcmTokenAtualizadoEm` mais recente — contas sem esse campo
          // nunca são excluídas, só ficam por último na prioridade.
          const snap = await db.collection("usuarios")
              .where("telefone", "==", telefoneNormalizado)
              .get();
          if (snap.empty) return base;

          let melhorDoc = snap.docs[0];
          for (const doc of snap.docs) {
            const atual = doc.data().fcmTokenAtualizadoEm;
            const melhor = melhorDoc.data().fcmTokenAtualizadoEm;
            if (atual && (!melhor || atual.toMillis() > melhor.toMillis())) {
              melhorDoc = doc;
            }
          }
          const dados = melhorDoc.data();

          // TRAVA DE RECEBIMENTO (eixo "não recebe alertas em tempo real
          // App-para-App" do Plano Free, ver `planoCicloService.js`):
          // avaliada aqui, no lado do DESTINATÁRIO (não do remetente),
          // porque só o servidor sabe o status de ciclo/isPremium da
          // conta que RECEBERIA o Push — o remetente nunca tem acesso ao
          // documento `usuarios/{uidDestino}` de outra pessoa. Reaproveita
          // os MESMOS `dados` já lidos acima (nenhuma leitura extra ao
          // Firestore). Um destinatário bloqueado simplesmente não entra
          // na lista de tokens de `enviarFcmParaContatos` — segue
          // recebendo alertas normalmente assim que seu próprio ciclo
          // reabrir (Premium ou os 10 dias do próximo mês).
          const isPremiumDestino = dados.isPremium === true;
          let destinoBloqueado = false;
          if (!isPremiumDestino) {
            const cycleStartDate = dados.cycleStartDate;
            if (cycleStartDate) {
              const diaAtual = calcularDiaAtual(cycleStartDate.toMillis(), Date.now());
              destinoBloqueado = diaAtual > DURACAO_ATIVO_DIAS && diaAtual <= 30;
              // diaAtual > 30 (ciclo vencido, ainda não sincronizado pelo
              // app do destinatário) é tratado como ATIVO por padrão —
              // mesma filosofia permissiva do restante do app: nunca
              // suprimir um alerta de emergência por uma renovação de
              // ciclo simplesmente atrasada.
            }
          }

          return {
            ...base,
            uidDestino: melhorDoc.id,
            fcmToken: destinoBloqueado ? null : (dados.fcmToken || null),
          };
        } catch (e) {
          logger.error(
              `[resolverContasPorTelefone] Falha ao resolver conta para ${telefoneNormalizado}`, e,
          );
          return base;
        }
      }),
  );
}

/**
 * Envia o Push App-para-App só para quem tem `fcmToken` resolvido, como
 * mensagem DATA-ONLY no Android (sem o campo `notification`; o bloco
 * `apns` só vale para o iOS, ver `apnsPayload.js`) — de propósito: com
 * `notification` presente, o Android exibiria automaticamente uma
 * notificação padrão do sistema em segundo plano/terminado, duplicando a
 * notificação de tela cheia customizada que o próprio app monta (ver
 * `NotificacaoService.exibirNotificacaoAlertaRecebido` no Flutter). Alta
 * prioridade (`android.priority: 'high'`) garante entrega imediata mesmo
 * com o aparelho em Doze/economia de bateria. Best-effort: nunca lança
 * exceção — um token inválido/expirado não deve interromper o restante
 * do fluxo do alerta.
 *
 * Cada contato leva o SEU PRÓPRIO `contatoId` (id do sub-documento em
 * `entregas_alerta/{idEntrega}/destinatarios/`, ver
 * `criarDestinatariosDeAcompanhamento`) embutido em `data` — é assim que
 * o ACK do app receptor (ver
 * `FirebaseSyncService.confirmarEntregaDestinatario`) sabe qual
 * sub-documento marcar como ENTREGUE, inclusive já no disparo IMEDIATO
 * (não só nas retentativas de `entregaRetryEngine.js`). Por precisar de
 * um `data` DIFERENTE por token, usa `sendEach` (um Message por
 * destinatário) em vez de `sendEachForMulticast` (que só aceita um único
 * `data` compartilhado por todos os tokens).
 *
 * @param {Array<{fcmToken: string|null, contatoId: string, nome: string, telefone: string, uidDestino: string|null}>} contatosResolvidos
 * @param {string} titulo
 * @param {string} corpo
 * @param {Object<string, string>} dadosExtras
 */
async function enviarFcmParaContatos(contatosResolvidos, titulo, corpo, dadosExtras) {
  const comToken = (contatosResolvidos || []).filter((c) => c.fcmToken);

  if (comToken.length === 0) {
    logger.info(
        "[FCM Enviado] Nenhum contato com conta no app/token válido — nenhum Push enviado.",
    );
    return;
  }

  try {
    const resposta = await getMessaging().sendEach(comToken.map((c) => ({
      token: c.fcmToken,
      data: {...dadosExtras, titulo, corpo, contatoId: c.contatoId},
      android: {priority: "high"},
      // iOS: sem este bloco o push data-only não aparece com o app
      // fechado/em segundo plano (ver `apnsPayload.js`). Ignorado no
      // Android. O collapse-id por alerta+contato faz as retentativas
      // (`entregaRetryEngine.js`) substituírem este banner em vez de
      // empilhar um novo por minuto.
      apns: montarApnsAlerta({
        titulo: tituloPushIos(dadosExtras && dadosExtras.nomeRemetente),
        corpo,
        collapseId: dadosExtras && dadosExtras.idEntrega,
      }),
    })));
    logger.info(
        `[FCM Enviado] ${resposta.successCount} enviado(s), ` +
        `${resposta.failureCount} falha(s) de ${comToken.length} token(s).`,
    );

    // CORREÇÃO (bug real, 2026-08-14 — Razr recebendo
    // "0 enviado(s), 1 falha(s) de 1 token(s)" em TODO disparo, sem
    // nenhuma pista do motivo): nem `sendEachForMulticast` nem `sendEach`
    // lançam exceção por falha individual de token (é por isso que o
    // `catch` abaixo nunca via nada) — cada resultado fica em
    // `resposta.responses`, na MESMA ordem/tamanho de `comToken`. Loga o
    // `error.code`/`error.message` de cada falha (nunca o token cru, só
    // nome+telefone do contato, suficiente pra identificar QUEM sem
    // expor o segredo) — é a única forma de distinguir, por exemplo, um
    // token morto (`messaging/registration-token-not-registered`) de um
    // projeto Firebase incompatível (`messaging/mismatched-credential`)
    // ou qualquer outra causa.
    resposta.responses.forEach((r, i) => {
      if (r.success) return;
      const contato = comToken[i];
      logger.error(
          `[FCM Enviado] Falha no token de "${contato.nome || contato.telefone}" ` +
          `(uidDestino=${contato.uidDestino}): ${r.error && r.error.code} — ${r.error && r.error.message}`,
      );
    });
  } catch (e) {
    logger.error("[FCM Enviado] Falha ao enviar Push em lote", e);
  }
}

/**
 * Orquestra o disparo do alerta de emergência: resolve contas, envia o
 * Push gratuito e registra `entregas_alerta/{idEntrega}`. Retorna o id do
 * documento criado (ou `null` se não havia contatos de emergência para
 * notificar).
 *
 * @param {{usuarioId: string, contatos: Array<Object>, mensagem: string, origem: string, fotoUrl?: string, latitude?: number, longitude?: number}} params
 * @return {Promise<string|null>}
 */
async function dispararAlertaHibrido({usuarioId, contatos, mensagem, origem, fotoUrl, latitude, longitude}) {
  if (!contatos || contatos.length === 0) {
    logger.warn(
        `[dispararAlertaHibrido] Usuário ${usuarioId} não possui contatos de ` +
        "emergência — nenhum alerta será disparado.",
    );
    return null;
  }

  const contatosResolvidos = await resolverContasPorTelefone(contatos);
  const entregaRef = db.collection(COLECAO_ENTREGAS).doc();
  const idEntrega = entregaRef.id;

  let nomeRemetente = "";
  try {
    const remetenteSnap = await db.collection("usuarios").doc(usuarioId).get();
    nomeRemetente = (remetenteSnap.exists && remetenteSnap.data().nome) || "";
  } catch (e) {
    logger.error(`[dispararAlertaHibrido] Falha ao buscar nome do remetente ${usuarioId}`, e);
  }

  const agora = Timestamp.now();

  await entregaRef.set({
    usuarioId,
    origem,
    mensagem,
    nomeRemetente,
    ...(fotoUrl ? {fotoUrl} : {}),
    ...(typeof latitude === "number" ? {latitude} : {}),
    ...(typeof longitude === "number" ? {longitude} : {}),
    criadoEm: agora,
    // Consumido por `entregaRetryEngine.js` para decidir quando o alerta
    // deixa de aceitar novas retentativas (48h) — e por
    // `relatorioFalhaService.js` para travar o envio do relatório de
    // falha a UMA ÚNICA VEZ por alerta.
    relatorioFalhaEnviado: false,
    contatos: contatosResolvidos.map((c) => ({
      nome: c.nome,
      telefone: c.telefone,
      uidDestino: c.uidDestino,
    })),
  });

  // Cria os sub-documentos de acompanhamento ANTES de enviar o Push
  // imediato abaixo (não depois) — de propósito: cada mensagem enviada
  // precisa levar o `contatoId` JÁ definido em `data`, para que o ACK do
  // próprio disparo imediato (o caminho mais comum, quando o
  // destinatário já está com o app aberto/em segundo plano) já pare a
  // fila de retentativa — em vez de só a PRÓXIMA tentativa (1 min
  // depois, via `entregaRetryEngine.js`) carregar um `contatoId` válido.
  const contatosComId = await criarDestinatariosDeAcompanhamento(entregaRef, contatosResolvidos, agora);

  await enviarFcmParaContatos(contatosComId, TITULO_PUSH, mensagem, {
    tipo: "alerta_emergencia",
    idEntrega,
    origem,
    mensagem,
    nomeRemetente,
    // Presente somente para alertas do tipo `sos_fisico_foto` — o app
    // do guardião usa este link (Firebase Storage, com token de
    // acesso embutido) para baixar e exibir a foto na notificação
    // (ver NotificacaoService.exibirNotificacaoAlertaRecebido).
    ...(fotoUrl ? {fotoUrl} : {}),
    // Coordenadas ESTRUTURADAS (habilita o botão "Ver no Mapa" no app
    // do guardião sem depender de parsing de texto livre) — os valores
    // de `data` do FCM só aceitam string, por isso o `.toString()`; o
    // Flutter faz o parse de volta para double (ver FcmService).
    ...(typeof latitude === "number" ? {latitude: latitude.toString()} : {}),
    ...(typeof longitude === "number" ? {longitude: longitude.toString()} : {}),
  });

  logger.info(
      `[dispararAlertaHibrido] entregas_alerta/${idEntrega} criado para o usuário ` +
      `${usuarioId} (origem: ${origem}) — ${contatosResolvidos.length} contato(s).`,
  );

  return idEntrega;
}

/**
 * Cria, em `entregas_alerta/{idEntrega}/destinatarios/{contatoId}`, um
 * sub-documento de acompanhamento POR CONTATO — inclusive para quem
 * ainda não tem `fcmToken` resolvido (sem conta no app agora, mas que
 * pode instalar/logar dentro da janela de 48h: o motor de retentativa
 * tenta resolver de novo a cada tentativa, ver `entregaRetryEngine.js`).
 * Todos começam com a MESMA `proximaTentativa` (agora + 1 min — primeiro
 * degrau da régua de backoff).
 *
 * Retorna os MESMOS `contatosResolvidos`, cada um com o `contatoId` do
 * seu sub-documento anexado — usado pelo chamador para que o Push
 * imediato já saia com o `contatoId` certo em `data` (ver
 * `dispararAlertaHibrido`).
 *
 * @param {FirebaseFirestore.DocumentReference} entregaRef
 * @param {Array<{nome: string, telefone: string, uidDestino: string|null, fcmToken: string|null}>} contatosResolvidos
 * @param {FirebaseFirestore.Timestamp} criadoEm
 * @return {Promise<Array<{nome: string, telefone: string, uidDestino: string|null, fcmToken: string|null, contatoId: string}>>}
 */
async function criarDestinatariosDeAcompanhamento(entregaRef, contatosResolvidos, criadoEm) {
  if (!contatosResolvidos || contatosResolvidos.length === 0) return [];

  const lote = db.batch();
  const proximaTentativa = Timestamp.fromMillis(
      criadoEm.toMillis() + PRIMEIRO_INTERVALO_RETENTATIVA_MS,
  );

  const contatosComId = contatosResolvidos.map((contato) => ({
    ...contato,
    contatoId: entregaRef.collection(SUBCOLECAO_DESTINATARIOS).doc().id,
  }));

  for (const contato of contatosComId) {
    const destinatarioRef = entregaRef.collection(SUBCOLECAO_DESTINATARIOS).doc(contato.contatoId);
    lote.set(destinatarioRef, {
      nome: contato.nome || "",
      telefone: contato.telefone || "",
      uidDestino: contato.uidDestino || null,
      status: STATUS_DESTINATARIO_PENDENTE,
      // Conta a tentativa já feita pelo disparo imediato logo em seguida
      // somente quando há um token para enviar — contatos sem conta
      // resolvida ainda ficam com 0 até o motor de retentativa achar um
      // token.
      tentativas: contato.fcmToken ? 1 : 0,
      proximaTentativa,
      entregueEm: null,
    });
  }

  await lote.commit();
  return contatosComId;
}

module.exports = {
  resolverContasPorTelefone,
  enviarFcmParaContatos,
  dispararAlertaHibrido,
  COLECAO_ENTREGAS,
  SUBCOLECAO_DESTINATARIOS,
  TITULO_PUSH,
  tituloPushIos,
};
