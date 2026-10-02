/**
 * Motor de retentativa progressiva do pipeline híbrido de alerta (ver
 * `alertaHibridoService.js`) — cobre o cenário em que o Push IMEDIATO não
 * chegou a ser confirmado como entregue (token expirado/inválido,
 * aparelho sem sinal, contato ainda sem conta no app no instante do
 * disparo): reenvia, por CONTATO individualmente, em intervalos
 * crescentes por até 48h — até o contato confirmar ENTREGUE ou o prazo
 * se esgotar (ver `relatorioFalhaService.js`, acionado a partir daqui).
 *
 * Modelo de dados (ver `alertaHibridoService.js` para o documento pai):
 *   entregas_alerta/{idEntrega}/destinatarios/{contatoId}
 *     - nome, telefone, uidDestino (string|null)
 *     - status: 'PENDENTE' | 'ENTREGUE' | 'FALHA_NAO_ENTREGUE'
 *     - tentativas (number), proximaTentativa (Timestamp),
 *       entregueEm (Timestamp|null)
 *
 * ACK (o que tira o contato da fila): o app do destinatário grava
 * `status: 'ENTREGUE'` diretamente neste sub-documento assim que o Push
 * chega no dispositivo (ver
 * `FirebaseSyncService.confirmarEntregaDestinatario`/`FcmService` no
 * app) — a regra do Firestore só permite essa escrita ao próprio
 * `uidDestino` (ver `firestore.rules`). A partir do instante em que o
 * status deixa de ser PENDENTE, o documento some da query abaixo e NUNCA
 * mais recebe reenvio para este alerta específico.
 *
 * RÉGUA DE BACKOFF (tempo decorrido desde `entregas_alerta.criadoEm`,
 * regra de negócio pedida explicitamente pelo usuário):
 *   0–20 min decorridos: reenvia a cada 1 min.
 *   21–40 min decorridos: reenvia a cada 2 min.
 *   41–120 min decorridos: reenvia a cada 5 min.
 *   121 min–48h decorridos: reenvia a cada 10 min.
 * Ao atingir 48h sem confirmação, o contato vira `FALHA_NAO_ENTREGUE` e
 * para de ser retentado.
 *
 * O `fcmToken` NUNCA é lido de um cache salvo no documento — é resolvido
 * de novo a cada tentativa via `resolverContasPorTelefone` (mesma função
 * usada no disparo imediato), garantindo que rotação de token e o status
 * de bloqueio do ciclo do Plano Free do DESTINATÁRIO estejam sempre
 * atualizados, mesmo numa janela de retentativa de até 48h.
 */

const {onSchedule} = require("firebase-functions/v2/scheduler");
const {getFirestore, Timestamp, FieldValue} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const logger = require("firebase-functions/logger");
const {resolverContasPorTelefone, TITULO_PUSH, tituloPushIos} = require("./alertaHibridoService");
const {montarApnsAlerta} = require("./apnsPayload");
const {dispararRelatorioFalhaEntrega} = require("./relatorioFalhaService");

const db = getFirestore();

const STATUS_PENDENTE = "PENDENTE";
const STATUS_FALHA = "FALHA_NAO_ENTREGUE";
const PRAZO_EXPIRACAO_MS = 48 * 60 * 60 * 1000; // 48h

/**
 * Calcula o intervalo (ms) até a PRÓXIMA tentativa, a partir de quanto
 * tempo já decorreu desde a criação do alerta — ver a régua de backoff
 * no cabeçalho deste arquivo.
 *
 * @param {number} decorridoMs
 * @return {number}
 */
function calcularProximoIntervaloMs(decorridoMs) {
  const decorridoMin = decorridoMs / 60000;
  if (decorridoMin <= 20) return 60 * 1000;
  if (decorridoMin <= 40) return 2 * 60 * 1000;
  if (decorridoMin <= 120) return 5 * 60 * 1000;
  return 10 * 60 * 1000;
}

/**
 * Envia o Push de retentativa a UM único token, best-effort (nunca
 * lança) — equivalente individual de `enviarFcmParaContatos`, usado aqui
 * porque cada destinatário desta fila pode estar num degrau de backoff
 * diferente dos demais contatos do MESMO alerta.
 *
 * @param {string} token
 * @param {string} corpo
 * @param {Object<string, string>} dados
 * @return {Promise<boolean>}
 */
async function enviarPushIndividual(token, corpo, dados) {
  try {
    await getMessaging().send({
      token,
      data: {...dados, titulo: TITULO_PUSH, corpo},
      android: {priority: "high"},
      // Mesmo bloco iOS do disparo imediato (`enviarFcmParaContatos`) —
      // mesmo collapse-id (idEntrega), então cada reenvio SUBSTITUI o
      // banner anterior em vez de empilhar um novo por minuto. O token
      // vem de `resolverContasPorTelefone`, que já aplica a TRAVA DE
      // RECEBIMENTO do Plano Free.
      apns: montarApnsAlerta({
        titulo: tituloPushIos(dados.nomeRemetente),
        corpo,
        collapseId: dados.idEntrega,
      }),
    });
    return true;
  } catch (e) {
    logger.error(
        `[monitorarRetentativasEntrega] Falha ao reenviar Push (token final ` +
        `...${token.slice(-8)}): ${(e && e.code) || (e && e.message) || e}`,
    );
    return false;
  }
}

/**
 * Roda a cada 1 minuto: busca (via collection group query, atravessando
 * TODOS os alertas ativos numa única consulta) todo sub-documento de
 * destinatário ainda PENDENTE cuja `proximaTentativa` já passou, e para
 * cada um decide entre reenviar o Push (com token sempre resolvido na
 * hora) ou, se o alerta já passou de 48h, marcar como
 * `FALHA_NAO_ENTREGUE` e acionar o relatório de retorno ao emissor.
 */
exports.monitorarRetentativasEntrega = onSchedule(
    {
      schedule: "every 1 minutes",
      timeZone: "America/Sao_Paulo",
    },
    async () => {
      const agoraMs = Date.now();

      const pendentes = await db.collectionGroup("destinatarios")
          .where("status", "==", STATUS_PENDENTE)
          .where("proximaTentativa", "<=", Timestamp.fromMillis(agoraMs))
          .get();

      if (pendentes.empty) return;

      logger.info(
          `[monitorarRetentativasEntrega] ${pendentes.size} destinatário(s) ` +
          "pendente(s) com retentativa vencida.",
      );

      // Cache de leitura do documento PAI por `idEntrega` — evita reler o
      // mesmo `entregas_alerta/{id}` uma vez por CONTATO quando vários
      // destinatários do MESMO alerta vencem no mesmo tick.
      const cacheEntregas = new Map();
      const entregasComFalhaNesteTick = new Set();

      for (const doc of pendentes.docs) {
        const entregaRef = doc.ref.parent.parent;
        if (!entregaRef) continue; // Nunca deve acontecer (subcoleção sem pai), defensivo.
        const idEntrega = entregaRef.id;

        let entrega = cacheEntregas.get(idEntrega);
        if (entrega === undefined) {
          const snap = await entregaRef.get();
          entrega = snap.exists ? snap.data() : null;
          cacheEntregas.set(idEntrega, entrega);
        }
        if (!entrega) {
          logger.warn(
              `[monitorarRetentativasEntrega] entregas_alerta/${idEntrega} não ` +
              `existe mais — destinatário órfão ${doc.id} ignorado.`,
          );
          continue;
        }

        const criadoEmMs = entrega.criadoEm ? entrega.criadoEm.toMillis() : agoraMs;
        const decorridoMs = agoraMs - criadoEmMs;

        try {
          if (decorridoMs >= PRAZO_EXPIRACAO_MS) {
            const marcouFalha = await db.runTransaction(async (tx) => {
              const snapAtual = await tx.get(doc.ref);
              if (!snapAtual.exists || snapAtual.data().status !== STATUS_PENDENTE) return false;
              tx.update(doc.ref, {status: STATUS_FALHA, falhaEm: Timestamp.now()});
              return true;
            });
            if (marcouFalha) entregasComFalhaNesteTick.add(idEntrega);
            continue;
          }

          const dados = doc.data();
          const [contatoResolvido] = await resolverContasPorTelefone([
            {nome: dados.nome, telefone: dados.telefone},
          ]);

          let enviouComSucesso = false;
          if (contatoResolvido && contatoResolvido.fcmToken) {
            enviouComSucesso = await enviarPushIndividual(
                contatoResolvido.fcmToken,
                entrega.mensagem || "",
                {
                  tipo: "alerta_emergencia",
                  idEntrega,
                  contatoId: doc.id,
                  origem: entrega.origem || "",
                  mensagem: entrega.mensagem || "",
                  nomeRemetente: entrega.nomeRemetente || "",
                  ...(entrega.fotoUrl ? {fotoUrl: entrega.fotoUrl} : {}),
                  ...(typeof entrega.latitude === "number" ?
                    {latitude: entrega.latitude.toString()} : {}),
                  ...(typeof entrega.longitude === "number" ?
                    {longitude: entrega.longitude.toString()} : {}),
                },
            );
          } else {
            logger.info(
                `[monitorarRetentativasEntrega] Contato "${dados.nome || dados.telefone}" ` +
                `de entregas_alerta/${idEntrega} ainda sem token resolvido — nova ` +
                "tentativa agendada.",
            );
          }

          const proximoIntervaloMs = calcularProximoIntervaloMs(decorridoMs);
          await db.runTransaction(async (tx) => {
            const snapAtual = await tx.get(doc.ref);
            // Reconfirma PENDENTE dentro da transação — evita sobrescrever
            // um ACK ('ENTREGUE') gravado pelo app do destinatário quase
            // no mesmo instante deste processamento.
            if (!snapAtual.exists || snapAtual.data().status !== STATUS_PENDENTE) return;
            tx.update(doc.ref, {
              tentativas: FieldValue.increment(1),
              proximaTentativa: Timestamp.fromMillis(agoraMs + proximoIntervaloMs),
              uidDestino: (contatoResolvido && contatoResolvido.uidDestino) || null,
              ultimaTentativaEm: Timestamp.now(),
              ultimaTentativaComSucesso: enviouComSucesso,
            });
          });
        } catch (e) {
          logger.error(
              `[monitorarRetentativasEntrega] Falha ao processar destinatário ` +
              `${doc.id} de entregas_alerta/${idEntrega}`, e,
          );
        }
      }

      for (const idEntrega of entregasComFalhaNesteTick) {
        try {
          await dispararRelatorioFalhaEntrega(db.collection("entregas_alerta").doc(idEntrega));
        } catch (e) {
          logger.error(
              `[monitorarRetentativasEntrega] Falha ao gerar relatório de 48h de ` +
              `entregas_alerta/${idEntrega}`, e,
          );
        }
      }
    },
);
