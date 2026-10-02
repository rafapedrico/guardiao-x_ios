/**
 * Relatório de retorno ao emissor quando um alerta de emergência expira
 * (48h) sem confirmação de entrega de um ou mais contatos — acionado por
 * `entregaRetryEngine.js` assim que o último contato pendente de um
 * alerta vira `FALHA_NAO_ENTREGUE`.
 *
 * REGRA DE NEGÓCIO DE SEGURANÇA/DISFARCE (pedida explicitamente pelo
 * usuário, 2026-08-22): este relatório NUNCA é exibido como notificação
 * visível na tela do emissor — é gravado silenciosamente em
 * `usuarios/{usuarioId}/relatoriosFalha/{idEntrega}` e o próprio app do
 * emissor o processa em segundo plano (Push data-only, sem o campo
 * `notification`, mesmo padrão do pipeline de alerta em
 * `alertaHibridoService.js`) para virar um evento LOCAL da categoria
 * 'critico' — só visível dentro do cofre de Auditoria de Eventos
 * Sensíveis já existente no app (trava de carência de 2h, ver
 * `DatabaseHelper.getStatusAuditoria`/`HistoricoTab`), nunca numa
 * notificação de tela de bloqueio. Ver `RelatorioFalhaEntregaService` no
 * app Flutter, que consome tanto o nudge quanto (em caso de falha na
 * entrega do nudge) uma varredura de fallback por sessão.
 */

const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {montarApnsSilencioso} = require("./apnsPayload");
const logger = require("firebase-functions/logger");

const db = getFirestore();

const SUBCOLECAO_DESTINATARIOS = "destinatarios";
const STATUS_FALHA = "FALHA_NAO_ENTREGUE";
const TIPO_RELATORIO_FALHA = "relatorio_falha_entrega";

/**
 * @param {FirebaseFirestore.DocumentReference} entregaRef
 */
async function dispararRelatorioFalhaEntrega(entregaRef) {
  const entregaSnap = await entregaRef.get();
  if (!entregaSnap.exists) return;
  const entrega = entregaSnap.data();

  // Checagem rápida ANTES da transação — evita o custo da query de
  // destinatários abaixo no caminho comum (relatório já enviado por um
  // tick anterior, ver a trava transacional mais abaixo).
  if (entrega.relatorioFalhaEnviado === true) return;

  const falhasSnap = await entregaRef.collection(SUBCOLECAO_DESTINATARIOS)
      .where("status", "==", STATUS_FALHA)
      .get();
  if (falhasSnap.empty) return;

  // Trava transacional: garante que o relatório é gerado UMA ÚNICA VEZ
  // por alerta, mesmo que este helper seja chamado mais de uma vez para
  // o mesmo `idEntrega` (ex: destinatários do mesmo alerta expirando em
  // ticks diferentes do cron de 1 min de `entregaRetryEngine.js`).
  const podeEnviar = await db.runTransaction(async (tx) => {
    const snapAtual = await tx.get(entregaRef);
    if (!snapAtual.exists || snapAtual.data().relatorioFalhaEnviado === true) return false;
    tx.update(entregaRef, {
      relatorioFalhaEnviado: true,
      relatorioFalhaEnviadoEm: Timestamp.now(),
    });
    return true;
  });
  if (!podeEnviar) return;

  const contatosFalha = falhasSnap.docs.map((d) => ({
    nome: d.data().nome || "",
    telefone: d.data().telefone || "",
  }));

  const usuarioId = entrega.usuarioId;
  if (!usuarioId) {
    logger.warn(
        `[relatorioFalhaService] entregas_alerta/${entregaRef.id} sem ` +
        "usuarioId — relatório não pôde ser associado a nenhum emissor.",
    );
    return;
  }

  const relatorioRef = db.collection("usuarios").doc(usuarioId)
      .collection("relatoriosFalha").doc(entregaRef.id);
  await relatorioRef.set({
    idEntrega: entregaRef.id,
    origem: entrega.origem || "",
    criadoEm: entrega.criadoEm || Timestamp.now(),
    geradoEm: Timestamp.now(),
    contatosFalha,
  });

  logger.info(
      `[relatorioFalhaService] Relatório de falha gravado em ` +
      `usuarios/${usuarioId}/relatoriosFalha/${entregaRef.id} ` +
      `(${contatosFalha.length} contato(s) sem confirmação em 48h).`,
  );

  // Nudge SILENCIOSO (data-only, sem `notification`) para o app do
  // próprio emissor processar o relatório em segundo plano e gravá-lo no
  // histórico local. Best-effort: se o token não existir/estiver morto,
  // o relatório continua disponível no Firestore e será recuperado na
  // próxima sincronização de sessão (ver
  // `RelatorioFalhaEntregaService.sincronizarPendentes` no app) — nunca
  // se perde, só atrasa até o app ser reaberto.
  try {
    const usuarioSnap = await db.collection("usuarios").doc(usuarioId).get();
    const fcmToken = usuarioSnap.exists ? usuarioSnap.data().fcmToken : null;
    if (fcmToken) {
      await getMessaging().send({
        token: fcmToken,
        data: {
          tipo: TIPO_RELATORIO_FALHA,
          idEntrega: entregaRef.id,
        },
        android: {priority: "high"},
        // iOS: push de BACKGROUND (silencioso também lá — mesmo papel do
        // data-only no Android), ver `apnsPayload.js`.
        apns: montarApnsSilencioso(),
      });
    }
  } catch (e) {
    logger.error(
        `[relatorioFalhaService] Falha ao enviar nudge silencioso ao emissor ${usuarioId}`, e,
    );
  }
}

module.exports = {dispararRelatorioFalhaEntrega, TIPO_RELATORIO_FALHA};
