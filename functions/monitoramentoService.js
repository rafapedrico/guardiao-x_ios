/**
 * Backend da aba Monitoramento: permissão bilateral e explícita de
 * compartilhamento de localização GPS em tempo real entre usuários do
 * Guardião X, TOTALMENTE independente do pipeline de alerta de emergência
 * (`alertaHibridoService.js`) — aqui não há disparo de SMS/sirene, apenas
 * consentimento e leitura de posição.
 *
 * Modelo de dados (coleção `permissoes_monitoramento/{permissaoId}`, ver
 * `MonitoramentoService` no app Flutter):
 *   permissaoId: string, determinístico = `${uidAlvo}__${uidSolicitante}`
 *   uidAlvo: string (uid de quem COMPARTILHA a localização)
 *   uidSolicitante: string (uid de quem VÊ a localização)
 *   telefoneAlvo, telefoneSolicitante: string (E.164)
 *   nomeAlvo, nomeSolicitante: string (denormalizado)
 *   status: "pendente" | "aprovado" | "negado" | "bloqueado" | "expirado"
 *   criadoEm, atualizadoEm, respondidoEm: Timestamp
 *   expiraEm: Timestamp (só relevante em "pendente" — ver
 *     `monitoramentoExpiracaoMonitor.js`, regra das 24h)
 *
 * Cada PAR de usuários pode ter até DOIS documentos independentes — um
 * para cada direção de "quem vê a localização de quem" — cada um com seu
 * próprio ciclo de vida. O cliente NUNCA cria este documento diretamente
 * (ver `firestore.rules`): só esta Cloud Function callable cria/reabre uma
 * solicitação; o cliente só pode ATUALIZAR o status, e só quando for o
 * `uidAlvo` do documento (aprovar/negar/bloquear/desbloquear).
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentUpdated} = require("firebase-functions/v2/firestore");
const {getFirestore, Timestamp} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");
const {montarApnsAlerta} = require("./apnsPayload");
const logger = require("firebase-functions/logger");
const {normalizarTelefoneE164} = require("./telefoneUtils");
const {JANELA_EXPIRACAO_MONITORAMENTO_MS} = require("./constantes");

const db = getFirestore();

const COLECAO_PERMISSOES = "permissoes_monitoramento";
const STATUS_PENDENTE = "pendente";
const STATUS_APROVADO = "aprovado";
const STATUS_NEGADO = "negado";
const STATUS_BLOQUEADO = "bloqueado";
const STATUS_EXPIRADO = "expirado";

// Sentinela interna (NÃO é um valor do campo `status`) usada só para o
// retorno da transação em exports.solicitarMonitoramento identificar o
// caso "solicitante bloqueado" (campo booleano `bloqueado`, ver
// exports.definirBloqueioSolicitante) e abortar com HttpsError antes de
// disparar o Push — nunca é escrita no Firestore.
const STATUS_BLOQUEADO_SOLICITACAO = "__bloqueado_solicitacao__";

/**
 * @param {string} uidAlvo
 * @param {string} uidSolicitante
 * @return {string}
 */
function montarIdPermissao(uidAlvo, uidSolicitante) {
  return `${uidAlvo}__${uidSolicitante}`;
}

/**
 * Título/corpo do banner do iOS para os pushes da aba Monitoramento — no
 * Android o app monta esse texto localmente (ver
 * `NotificacaoService.exibirNotificacaoMonitoramento`, chaves
 * `notifMonit*`), mas no iOS quem exibe é o sistema, direto do payload.
 * O servidor não conhece o idioma do destinatário, então usa o português
 * (mesmo critério de `TITULO_PUSH` em `alertaHibridoService.js`).
 *
 * @param {string} tipo
 * @param {Object<string, string>} dados
 * @return {{titulo: string, corpo: string}}
 */
function textoPushMonitoramentoIos(tipo, dados) {
  const nomeSolicitante = (dados && dados.nomeSolicitante) || "Um contato";
  const nomeAlvo = (dados && dados.nomeAlvo) || "Um contato";
  switch (tipo) {
    case "solicitacao_monitoramento":
      return {
        titulo: "📍 Solicitação de localização",
        corpo: `${nomeSolicitante} está solicitando a sua localização.`,
      };
    case "monitoramento_aprovado":
      return {
        titulo: "📍 Localização liberada",
        corpo: `${nomeAlvo} permitiu que você veja a localização dele(a).`,
      };
    case "monitoramento_negado":
      return {
        titulo: "📍 Solicitação recusada",
        corpo: `${nomeAlvo} recusou a sua solicitação de localização.`,
      };
    case "monitoramento_bloqueado":
      return {
        titulo: "📍 Compartilhamento bloqueado",
        corpo: `${nomeAlvo} bloqueou o compartilhamento da localização com você.`,
      };
    case "monitoramento_expirado":
      return {
        titulo: "📍 Solicitação expirada",
        corpo: `Sua solicitação de localização para ${nomeAlvo} expirou sem resposta.`,
      };
    default:
      return {titulo: "📍 Guardião-X", corpo: ""};
  }
}

/**
 * Envia um Push data-only (mesmo padrão de `enviarFcmParaContatos` em
 * `alertaHibridoService.js`) para um único usuário, buscando seu
 * `fcmToken` em `usuarios/{uidDestino}`. Best-effort: nunca lança
 * exceção — a ausência de token/falha de envio não deve interromper o
 * fluxo de permissão, que já está persistido no Firestore.
 *
 * @param {string} uidDestino
 * @param {string} tipo
 * @param {Object<string, string>} dadosExtras
 */
async function enviarFcmMonitoramento(uidDestino, tipo, dadosExtras) {
  try {
    const snap = await db.collection("usuarios").doc(uidDestino).get();
    const fcmToken = snap.exists && snap.data().fcmToken;
    if (!fcmToken) {
      logger.info(
          `[enviarFcmMonitoramento] Usuário ${uidDestino} sem fcmToken — ` +
          `Push "${tipo}" não enviado.`,
      );
      return;
    }

    const textoIos = textoPushMonitoramentoIos(tipo, dadosExtras);
    await getMessaging().send({
      token: fcmToken,
      data: {tipo, ...dadosExtras},
      android: {priority: "high"},
      // iOS: sem este bloco o push data-only não aparece com o app
      // fechado/em segundo plano (ver `apnsPayload.js`). Notificação
      // normal (sem time-sensitive) — não é alerta de emergência.
      apns: montarApnsAlerta({
        titulo: textoIos.titulo,
        corpo: textoIos.corpo,
        collapseId: dadosExtras && dadosExtras.idPermissao,
        timeSensitive: false,
      }),
    });
    logger.info(`[enviarFcmMonitoramento] Push "${tipo}" enviado para ${uidDestino}.`);
  } catch (e) {
    logger.error(
        `[enviarFcmMonitoramento] Falha ao enviar Push "${tipo}" para ${uidDestino}`, e,
    );
  }
}

/**
 * Callable `onCall` chamada pelo app (ver
 * `lib/services/monitoramento_service.dart`, `solicitarLocalizacao`) ao
 * tocar em "Solicitar Localização" para um contato da aba Monitoramento.
 * Resolve o uid pelo telefone SERVER-SIDE (o cliente nunca consulta
 * `usuarios` por telefone diretamente — ver `firestore.rules`).
 *
 * data: {telefoneAlvo: string}
 * return: {sucesso: true, uidAlvo: string, status: string, permissaoId: string}
 */
exports.solicitarMonitoramento = onCall(async (request) => {
  const uidSolicitante = request.auth && request.auth.uid;
  if (!uidSolicitante) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }

  const {telefoneAlvo} = request.data || {};
  const telefoneNormalizado = normalizarTelefoneE164(telefoneAlvo);
  if (!telefoneNormalizado) {
    throw new HttpsError("invalid-argument", "Telefone inválido.");
  }

  const solicitanteSnap = await db.collection("usuarios").doc(uidSolicitante).get();
  const solicitante = solicitanteSnap.exists ? solicitanteSnap.data() : {};

  const alvoQuery = await db.collection("usuarios")
      .where("telefone", "==", telefoneNormalizado)
      .limit(1)
      .get();
  if (alvoQuery.empty) {
    throw new HttpsError(
        "not-found", "Este número ainda não possui conta no Guardião X.",
    );
  }

  const alvoDoc = alvoQuery.docs[0];
  const uidAlvo = alvoDoc.id;
  const alvo = alvoDoc.data();

  if (uidAlvo === uidSolicitante) {
    throw new HttpsError(
        "invalid-argument", "Não é possível solicitar a própria localização.",
    );
  }

  const permissaoId = montarIdPermissao(uidAlvo, uidSolicitante);
  const permissaoRef = db.collection(COLECAO_PERMISSOES).doc(permissaoId);

  const statusResultante = await db.runTransaction(async (tx) => {
    const snapAtual = await tx.get(permissaoRef);
    const dadosAtuais = snapAtual.exists ? snapAtual.data() : null;

    // Bloqueado (ver exports.definirBloqueioSolicitante): o ALVO marcou
    // este solicitante como bloqueado explicitamente — nem cria/reabre um
    // ciclo pendente, nem dispara Push. Eixo independente de `status`
    // (mesmo um vínculo já `aprovado` anteriormente pode ter sido
    // bloqueado depois).
    if (dadosAtuais && dadosAtuais.bloqueado === true) {
      return STATUS_BLOQUEADO_SOLICITACAO;
    }

    // Já aprovado: nada a fazer, devolve o status atual sem reabrir o
    // ciclo nem reenviar Push.
    if (dadosAtuais && dadosAtuais.status === STATUS_APROVADO) {
      return STATUS_APROVADO;
    }

    // Já pendente: evita resetar o prazo de 24h a cada toque repetido no
    // botão — apenas devolve o status atual.
    if (dadosAtuais && dadosAtuais.status === STATUS_PENDENTE) {
      return STATUS_PENDENTE;
    }

    // Sem documento, ou existente com negado/bloqueado/expirado: cria ou
    // REABRE uma nova solicitação pendente com prazo renovado de 24h.
    const agora = Timestamp.now();
    tx.set(permissaoRef, {
      uidAlvo,
      uidSolicitante,
      telefoneAlvo: telefoneNormalizado,
      telefoneSolicitante: solicitante.telefone || "",
      nomeAlvo: alvo.nome || "",
      nomeSolicitante: solicitante.nome || "",
      status: STATUS_PENDENTE,
      criadoEm: dadosAtuais ? dadosAtuais.criadoEm || agora : agora,
      atualizadoEm: agora,
      respondidoEm: null,
      expiraEm: Timestamp.fromMillis(
          Date.now() + JANELA_EXPIRACAO_MONITORAMENTO_MS,
      ),
    }, {merge: true});
    return STATUS_PENDENTE;
  });

  if (statusResultante === STATUS_BLOQUEADO_SOLICITACAO) {
    logger.warn(
        `[solicitarMonitoramento] BLOQUEADO: ${uidSolicitante} tentou solicitar ` +
        `a localização de ${uidAlvo}, que o bloqueou explicitamente — Push não enviado.`,
    );
    throw new HttpsError(
        "permission-denied", "Este contato não está disponível no momento.",
    );
  }

  if (statusResultante === STATUS_PENDENTE) {
    await enviarFcmMonitoramento(uidAlvo, "solicitacao_monitoramento", {
      idPermissao: permissaoId,
      uidSolicitante,
      nomeSolicitante: solicitante.nome || "",
      telefoneSolicitante: solicitante.telefone || "",
    });
  }

  logger.info(
      `[solicitarMonitoramento] ${uidSolicitante} -> ${uidAlvo}: status resultante ${statusResultante}.`,
  );

  return {
    sucesso: true,
    uidAlvo,
    status: statusResultante,
    permissaoId,
  };
});

/**
 * Trigger `onDocumentUpdated`: sempre que o `status` de uma permissão
 * mudar por resposta do alvo (aprovado/negado/bloqueado, escrito
 * diretamente pelo cliente — ver `firestore.rules`), notifica o
 * SOLICITANTE via Push. A transição para "expirado" é tratada à parte
 * pela função agendada (`monitoramentoExpiracaoMonitor.js`), que já
 * dispara seu próprio Push — por isso é ignorada aqui.
 */
exports.aoAtualizarPermissaoMonitoramento = onDocumentUpdated(
    `${COLECAO_PERMISSOES}/{permissaoId}`,
    async (event) => {
      const antes = event.data.before.data();
      const depois = event.data.after.data();

      if (!antes || !depois) return;
      if (antes.status === depois.status) return;
      if (depois.status === STATUS_EXPIRADO) return;

      // Auditoria: toda vez que o ALVO nega ou bloqueia o compartilhamento
      // da própria localização com um solicitante específico, registra no
      // log — é o ponto server-side onde essa decisão de negação
      // individual fica rastreável (a leitura em si, quando negada pela
      // regra do Firestore em `usuarios/{uid}/monitoramento/atual`,
      // acontece inteiramente dentro do motor de regras, sem passar por
      // nenhuma Cloud Function, logo não pode ser logada aqui).
      if (depois.status === STATUS_NEGADO || depois.status === STATUS_BLOQUEADO) {
        logger.warn(
            `[permissaoMonitoramento] NEGADA: ${depois.uidAlvo} ` +
            `(${depois.telefoneAlvo || "sem telefone"}) definiu status ` +
            `"${depois.status}" para ${depois.uidSolicitante} ` +
            `(${depois.telefoneSolicitante || "sem telefone"}) — ` +
            `permissaoId=${event.params.permissaoId}. Solicitações futuras ` +
            "deste número para ver a localização serão negadas pela regra " +
            "de leitura em usuarios/{uid}/monitoramento/atual.",
        );
      }

      const tiposPorStatus = {
        [STATUS_APROVADO]: "monitoramento_aprovado",
        [STATUS_NEGADO]: "monitoramento_negado",
        [STATUS_BLOQUEADO]: "monitoramento_bloqueado",
      };
      const tipo = tiposPorStatus[depois.status];
      if (!tipo) return;

      await enviarFcmMonitoramento(depois.uidSolicitante, tipo, {
        idPermissao: event.params.permissaoId,
        uidAlvo: depois.uidAlvo,
        nomeAlvo: depois.nomeAlvo || "",
      });
    },
);

/**
 * Callable `onCall` chamada pelo app (ver
 * `lib/services/monitoramento_service.dart`,
 * `definirPermissaoCompartilhamento`) ao alternar o Switch de
 * pré-autorização exibido em CADA card da lista "Localização de
 * familiares" — permite ao dono da localização CONCEDER ou BLOQUEAR
 * preventivamente o acesso de um contato específico, mesmo que ele nunca
 * tenha solicitado antes (pula o ciclo `pendente` -> aprovar/negar, pois
 * quem está decidindo aqui é o próprio dono, não quem solicita).
 *
 * Resolve o uid do contato pelo telefone SERVER-SIDE, no mesmo padrão de
 * `solicitarMonitoramento` — o cliente nunca consulta `usuarios` por
 * telefone diretamente (ver `firestore.rules`).
 *
 * data: {telefoneContato: string, permitir: boolean}
 * return: {sucesso: true, uidContato: string, status: string, permissaoId: string}
 */
exports.definirPermissaoCompartilhamento = onCall(async (request) => {
  const uidAlvo = request.auth && request.auth.uid;
  if (!uidAlvo) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }

  const {telefoneContato, permitir} = request.data || {};
  const telefoneNormalizado = normalizarTelefoneE164(telefoneContato);
  if (!telefoneNormalizado) {
    throw new HttpsError("invalid-argument", "Telefone inválido.");
  }
  if (typeof permitir !== "boolean") {
    throw new HttpsError("invalid-argument", "Parâmetro 'permitir' inválido.");
  }

  const alvoSnap = await db.collection("usuarios").doc(uidAlvo).get();
  const alvo = alvoSnap.exists ? alvoSnap.data() : {};

  const contatoQuery = await db.collection("usuarios")
      .where("telefone", "==", telefoneNormalizado)
      .limit(1)
      .get();
  if (contatoQuery.empty) {
    throw new HttpsError(
        "not-found", "Este número ainda não possui conta no Guardião X.",
    );
  }

  const contatoDoc = contatoQuery.docs[0];
  const uidSolicitante = contatoDoc.id;
  const contato = contatoDoc.data();

  if (uidSolicitante === uidAlvo) {
    throw new HttpsError(
        "invalid-argument",
        "Não é possível definir permissão para o próprio número.",
    );
  }

  const novoStatus = permitir ? STATUS_APROVADO : STATUS_BLOQUEADO;
  const permissaoId = montarIdPermissao(uidAlvo, uidSolicitante);
  const permissaoRef = db.collection(COLECAO_PERMISSOES).doc(permissaoId);

  await db.runTransaction(async (tx) => {
    const snapAtual = await tx.get(permissaoRef);
    const dadosAtuais = snapAtual.exists ? snapAtual.data() : null;
    const agora = Timestamp.now();

    tx.set(permissaoRef, {
      uidAlvo,
      uidSolicitante,
      telefoneAlvo: alvo.telefone || telefoneNormalizado,
      telefoneSolicitante: contato.telefone || telefoneNormalizado,
      nomeAlvo: alvo.nome || "",
      nomeSolicitante: contato.nome || "",
      status: novoStatus,
      criadoEm: dadosAtuais ? dadosAtuais.criadoEm || agora : agora,
      atualizadoEm: agora,
      respondidoEm: agora,
      expiraEm: null,
    }, {merge: true});
  });

  // Auditoria da pré-autorização direta — mesmo critério de log do
  // trigger `aoAtualizarPermissaoMonitoramento` acima, mas aqui cobre
  // também o caso de PRIMEIRA definição (documento inexistente antes),
  // que não passa por aquele trigger de `onDocumentUpdated`.
  if (novoStatus === STATUS_BLOQUEADO) {
    logger.warn(
        `[definirPermissaoCompartilhamento] NEGADA (pré-autorização): ` +
        `${uidAlvo} bloqueou preventivamente ${uidSolicitante} ` +
        `(${telefoneNormalizado}) — permissaoId=${permissaoId}.`,
    );
  } else {
    logger.info(
        `[definirPermissaoCompartilhamento] ${uidAlvo} concedeu ` +
        `pré-autorização a ${uidSolicitante} (${telefoneNormalizado}) — ` +
        `permissaoId=${permissaoId}.`,
    );
  }

  return {
    sucesso: true,
    uidContato: uidSolicitante,
    status: novoStatus,
    permissaoId,
  };
});

/**
 * Callable `onCall` chamada pelo app (ver
 * `lib/services/monitoramento_service.dart`, `definirBloqueioSolicitante`)
 * para bloquear/desbloquear que um contato específico envie NOVAS
 * solicitações de localização para mim — pelo slider deslizante de cada
 * card na aba Monitoramento, ou pelo botão rápido "Bloquear" no modal de
 * decisão de uma solicitação recebida.
 *
 * Persistido como campo booleano DEDICADO (`bloqueado`) no mesmo documento
 * de permissão do Bloco B (`uidAlvo` = eu, `uidSolicitante` = o contato) —
 * eixo INDEPENDENTE do `status` de compartilhamento (`STATUS_*`): bloquear
 * não revoga, por si só, um compartilhamento `aprovado` já ativo; só
 * impede que uma NOVA solicitação pendente seja aberta/notificada (ver
 * `exports.solicitarMonitoramento`, que verifica este campo antes de
 * disparar o Push).
 *
 * Resolve o uid do contato pelo telefone SERVER-SIDE, no mesmo padrão de
 * `definirPermissaoCompartilhamento` — o cliente nunca consulta `usuarios`
 * por telefone diretamente.
 *
 * data: {telefoneContato: string, bloquear: boolean}
 * return: {sucesso: true, uidContato: string, bloqueado: boolean, permissaoId: string}
 */
exports.definirBloqueioSolicitante = onCall(async (request) => {
  const uidAlvo = request.auth && request.auth.uid;
  if (!uidAlvo) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }

  const {telefoneContato, bloquear} = request.data || {};
  const telefoneNormalizado = normalizarTelefoneE164(telefoneContato);
  if (!telefoneNormalizado) {
    throw new HttpsError("invalid-argument", "Telefone inválido.");
  }
  if (typeof bloquear !== "boolean") {
    throw new HttpsError("invalid-argument", "Parâmetro 'bloquear' inválido.");
  }

  const alvoSnap = await db.collection("usuarios").doc(uidAlvo).get();
  const alvo = alvoSnap.exists ? alvoSnap.data() : {};

  const contatoQuery = await db.collection("usuarios")
      .where("telefone", "==", telefoneNormalizado)
      .limit(1)
      .get();
  if (contatoQuery.empty) {
    throw new HttpsError(
        "not-found", "Este número ainda não possui conta no Guardião X.",
    );
  }

  const contatoDoc = contatoQuery.docs[0];
  const uidSolicitante = contatoDoc.id;
  const contato = contatoDoc.data();

  if (uidSolicitante === uidAlvo) {
    throw new HttpsError(
        "invalid-argument",
        "Não é possível bloquear o próprio número.",
    );
  }

  const permissaoId = montarIdPermissao(uidAlvo, uidSolicitante);
  const permissaoRef = db.collection(COLECAO_PERMISSOES).doc(permissaoId);

  await db.runTransaction(async (tx) => {
    const snapAtual = await tx.get(permissaoRef);
    const dadosAtuais = snapAtual.exists ? snapAtual.data() : null;
    const agora = Timestamp.now();

    tx.set(permissaoRef, {
      uidAlvo,
      uidSolicitante,
      telefoneAlvo: alvo.telefone || telefoneNormalizado,
      telefoneSolicitante: contato.telefone || telefoneNormalizado,
      nomeAlvo: alvo.nome || "",
      nomeSolicitante: contato.nome || "",
      // Preservado se já existir — bloquear é um eixo independente de
      // status (ver docstring acima); só define um padrão razoável
      // ("negado") para o caso de o documento ainda não existir.
      status: dadosAtuais ? dadosAtuais.status : STATUS_NEGADO,
      bloqueado: bloquear,
      criadoEm: dadosAtuais ? dadosAtuais.criadoEm || agora : agora,
      atualizadoEm: agora,
    }, {merge: true});
  });

  logger.info(
      `[definirBloqueioSolicitante] ${uidAlvo} ${bloquear ? "bloqueou" : "desbloqueou"} ` +
      `solicitações de ${uidSolicitante} (${telefoneNormalizado}) — permissaoId=${permissaoId}.`,
  );

  return {
    sucesso: true,
    uidContato: uidSolicitante,
    bloqueado: bloquear,
    permissaoId,
  };
});

module.exports.COLECAO_PERMISSOES = COLECAO_PERMISSOES;
module.exports.STATUS_PENDENTE = STATUS_PENDENTE;
module.exports.STATUS_APROVADO = STATUS_APROVADO;
module.exports.STATUS_NEGADO = STATUS_NEGADO;
module.exports.STATUS_BLOQUEADO = STATUS_BLOQUEADO;
module.exports.STATUS_EXPIRADO = STATUS_EXPIRADO;
module.exports.enviarFcmMonitoramento = enviarFcmMonitoramento;
