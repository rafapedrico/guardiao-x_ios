/**
 * Revogação de sessões em outros aparelhos — pedido explícito do usuário
 * (2026-09-06): quando alguém perde o celular (ou troca de aparelho) e
 * loga de novo na MESMA conta em um aparelho novo, a sessão que ainda
 * estiver aberta no aparelho antigo deve parar de funcionar por segurança.
 *
 * DELIBERADAMENTE não tem nada a ver com número de telefone/duplicidade —
 * a única credencial que importa aqui é o próprio UID autenticado de quem
 * está chamando (`request.auth.uid`), o mesmo UID que o Firebase Auth já
 * resolve automaticamente para a MESMA conta Google/e-mail em qualquer
 * aparelho. Um número de telefone NUNCA é usado como prova de identidade
 * neste fluxo — ver decisão registrada em `telefonePerfilService.js`
 * (auditoria 2026-09-06: "transferência automática via duplicidade de
 * número" foi recusada por risco de sequestro de conta).
 *
 * Como funciona: grava em `validSince` da conta o instante do LOGIN de
 * quem está chamando (`request.auth.token.auth_time`, em segundos) —
 * qualquer sessão autenticada ANTES disso (os outros aparelhos) para de
 * funcionar na próxima renovação do ID token (até ~1h de tolerância,
 * tempo de vida padrão de um ID token do Firebase). A sessão do aparelho
 * que acabou de logar foi criada exatamente em `auth_time`, então
 * continua válida. Só afeta o PRÓPRIO uid do chamador — nunca é possível
 * revogar a sessão de outra pessoa por aqui.
 *
 * BUG REAL CORRIGIDO (2026-10-03, 1º deploy desta função): a versão
 * anterior usava `getAuth().revokeRefreshTokens(uid)`, que corta em
 * "agora" — DEPOIS do login do aparelho atual — e derrubava também a
 * sessão de quem acabou de entrar. A renovação forçada do token feita
 * pelo app em seguida (`getIdToken(true)`) não salvava nada: ela usa o
 * MESMO refresh token, já revogado. Resultado: todo login era deslogado
 * segundos depois (visto no iPhone: `atualizarTelefonePerfil` chegando
 * com `auth: MISSING` logo após o login com a Apple). O Admin SDK não
 * permite escolher o instante do corte, por isso a chamada direta ao
 * Identity Toolkit (`accounts:update`, o mesmo endpoint que o
 * `revokeRefreshTokens` usa por baixo).
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {GoogleAuth} = require("google-auth-library");
const logger = require("firebase-functions/logger");

const googleAuth = new GoogleAuth({
  scopes: [
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/identitytoolkit",
  ],
});

/**
 * Define `validSince` (segundos UTC) da conta [uid] no Identity Toolkit.
 * @param {string} uid
 * @param {number} validSinceSegundos
 */
async function definirValidSince(uid, validSinceSegundos) {
  const projectId = process.env.GCLOUD_PROJECT || await googleAuth.getProjectId();
  const cliente = await googleAuth.getClient();
  await cliente.request({
    url: `https://identitytoolkit.googleapis.com/v1/projects/${projectId}/accounts:update`,
    method: "POST",
    data: {localId: uid, validSince: String(validSinceSegundos)},
  });
}

exports.revogarSessoesEmOutrosDispositivos = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }
  const uid = request.auth.uid;
  const authTime = Number(request.auth.token && request.auth.token.auth_time);

  // Sem `auth_time` válido não há como cortar SÓ os outros aparelhos —
  // melhor não revogar nada do que derrubar a sessão atual.
  if (!Number.isFinite(authTime) || authTime <= 0) {
    logger.warn(`[SessaoDispositivo] auth_time ausente para ${uid} — nenhuma sessão revogada.`);
    return {sucesso: false};
  }

  try {
    await definirValidSince(uid, Math.floor(authTime));
    logger.info(
        `[SessaoDispositivo] Sessões anteriores a ${new Date(authTime * 1000).toISOString()} ` +
        `revogadas para ${uid} (aparelho atual preservado).`,
    );
    return {sucesso: true};
  } catch (e) {
    // Best-effort: uma falha aqui nunca deve impedir o login em si no
    // aparelho atual (já concluído antes desta chamada) — só significa
    // que uma sessão antiga eventualmente órfã continua válida por mais
    // tempo. Log para acompanhamento, sem propagar erro pro app.
    logger.error(`[SessaoDispositivo] Falha ao revogar sessões de ${uid}:`, e);
    return {sucesso: false};
  }
});
