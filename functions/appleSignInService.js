/**
 * Revogação de token do "Sign in with Apple" na exclusão de conta —
 * requisito da App Store Review Guideline 4.8 ("apps que oferecem Sign
 * in with Apple devem usar a REST API da Apple para revogar o token do
 * usuário ao excluir a conta") — achado documentado no checklist final
 * da migração iOS (`docs/checklist-final-mac-app-store-connect-2026-09-12.md`),
 * implementado nesta sessão (2026-09-12).
 *
 * Dois passos, em momentos diferentes:
 * 1. [registrarAutorizacaoApple] — callable chamada pelo app logo após
 *    CADA login bem-sucedido via Apple (ver
 *    `SocialAuthService.signInWithApple` no Flutter, fire-and-forget):
 *    troca o `authorizationCode` (de uso único, válido por poucos
 *    minutos) por um refresh_token de VERDADE junto à Apple, e grava
 *    esse refresh_token em `usuarios/{uid}` — é ele, não o
 *    authorizationCode (já expirado a essa altura), que a Apple aceita
 *    revogar meses depois.
 * 2. [revogarAppleTokenSeExistir] — função (não-callable) chamada por
 *    `exclusaoContaService.js` ANTES de apagar o documento
 *    `usuarios/{uid}` (é de lá que o refresh_token vem): revoga de fato
 *    o token na Apple.
 *
 * Best-effort nos DOIS passos: uma falha aqui nunca bloqueia o login
 * (passo 1) nem a exclusão de conta (passo 2) — só significa que, nesse
 * caso específico, o token da Apple continua tecnicamente válido do
 * lado da Apple até expirar/ser revogado manualmente pelo usuário em
 * appleid.apple.com. Não é um risco de segurança do PRÓPRIO Guardião X:
 * a conta no Firebase (e todos os dados) já foram excluídos de qualquer
 * forma; o token revogado é só a credencial que a Apple usaria para
 * autorizar um FUTURO login com este app — sem conta no Firebase para
 * autenticar, esse token não abre porta nenhuma sozinho.
 *
 * PRÉ-REQUISITO DE INFRAESTRUTURA (fora do alcance do código — precisa
 * de conta Apple Developer, ver
 * `docs/checklist-final-mac-app-store-connect-2026-09-12.md`):
 * 1. Apple Developer → Certificates, Identifiers & Profiles → Keys →
 *    "+" → marcar "Sign in with Apple" (chave DIFERENTE da de APNs e da
 *    de In-App Purchase, embora todas usem o mesmo Team) → baixar o
 *    `.p8`, anotar o Key ID.
 * 2. `firebase functions:secrets:set APPLE_SIWA_KEY_ID` /
 *    `APPLE_SIWA_PRIVATE_KEY` (conteúdo do `.p8`) / `APPLE_TEAM_ID` (o
 *    Team ID de 10 caracteres, visível em Apple Developer → Membership
 *    — NÃO é o mesmo valor do "Issuer ID" usado pela App Store Server
 *    API na Fase 5, são identificadores diferentes).
 *
 * NÃO TESTADO CONTRA A APPLE DE VERDADE — mesma ressalva da Fase 5 (App
 * Store Server API, ver `premiumPurchaseService.js`): escrito seguindo
 * a documentação REST oficial da Apple
 * (https://developer.apple.com/documentation/sign_in_with_apple/generate_and_validate_tokens),
 * nunca executado contra um login Apple real (sem Mac/Xcode/conta
 * Developer neste ambiente).
 */

const {onCall} = require("firebase-functions/v2/https");
const {defineSecret} = require("firebase-functions/params");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const jwt = require("jsonwebtoken");
const logger = require("firebase-functions/logger");

const db = getFirestore();

const appleTeamId = defineSecret("APPLE_TEAM_ID");
const appleSiwaKeyId = defineSecret("APPLE_SIWA_KEY_ID");
const appleSiwaPrivateKey = defineSecret("APPLE_SIWA_PRIVATE_KEY");
const APPLE_SIWA_SECRETS = [appleTeamId, appleSiwaKeyId, appleSiwaPrivateKey];

// Mesmo bundle id do app iOS (ver Fase 0 da migração, `ios/Runner.xcodeproj`)
// — client_id correto quando o authorizationCode veio do fluxo NATIVO
// (iOS/macOS, sem nenhum Services ID envolvido). Usado só como fallback
// aqui (ver [revogarAppleTokenSeExistir]) — o client_id de verdade é
// sempre o gravado em `appleClientId` junto com o token, ver
// [registrarAutorizacaoApple].
const APPLE_BUNDLE_ID = "com.rmfglobal.guardiaox";

/**
 * Gera o `client_secret` (JWT ES256) exigido em TODA chamada à REST API
 * do Sign in with Apple — validade curta (1h), gerado sob demanda a
 * cada chamada, nunca reaproveitado entre elas (diferente do client
 * secret de longa duração que alguns tutoriais geram uma vez só — aqui
 * é sempre fresco, mais simples e sem necessidade de cache/renovação).
 * @param {string} clientId bundle id (fluxo nativo) ou Services ID
 *   (fluxo web/Android) — PRECISA ser o MESMO client_id usado na hora
 *   do login original (ver `sub` do payload — a Apple recusa a chamada
 *   se não bater).
 * @return {string}
 */
function _gerarClientSecretApple(clientId) {
  const agora = Math.floor(Date.now() / 1000);
  return jwt.sign(
      {
        iss: appleTeamId.value(),
        iat: agora,
        exp: agora + 3600,
        aud: "https://appleid.apple.com",
        sub: clientId,
      },
      appleSiwaPrivateKey.value(),
      {
        algorithm: "ES256",
        keyid: appleSiwaKeyId.value(),
      },
  );
}

/**
 * Troca o `authorizationCode` (de uso único, poucos minutos de validade)
 * por um refresh_token de verdade — POST
 * https://appleid.apple.com/auth/token, `grant_type=authorization_code`.
 * @param {string} authorizationCode
 * @param {string} clientId
 * @return {Promise<string>} o refresh_token.
 */
async function _trocarCodigoPorRefreshToken(authorizationCode, clientId) {
  const corpo = new URLSearchParams({
    client_id: clientId,
    client_secret: _gerarClientSecretApple(clientId),
    code: authorizationCode,
    grant_type: "authorization_code",
  });

  const resposta = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: {"Content-Type": "application/x-www-form-urlencoded"},
    body: corpo,
  });

  const dados = await resposta.json();
  if (!resposta.ok || !dados.refresh_token) {
    throw new Error(
        `Apple /auth/token retornou ${resposta.status}: ${JSON.stringify(dados)}`,
    );
  }
  return dados.refresh_token;
}

/**
 * Callable chamada pelo app logo após CADA login bem-sucedido via Apple
 * (ver `SocialAuthService.signInWithApple` no Flutter) — fire-and-forget
 * do lado do app, nunca atrasa nem bloqueia o login em si (o Firebase
 * Auth já concluiu ANTES desta chamada). Guarda o refresh_token
 * resultante em `usuarios/{uid}`, para uso futuro por
 * [revogarAppleTokenSeExistir] na exclusão de conta.
 */
exports.registrarAutorizacaoApple = onCall({secrets: APPLE_SIWA_SECRETS}, async (request) => {
  if (!request.auth) return {sucesso: false};
  const uid = request.auth.uid;
  const {authorizationCode, clientId} = request.data || {};

  if (!authorizationCode || typeof authorizationCode !== "string" ||
      !clientId || typeof clientId !== "string") {
    logger.warn(`[AppleSignIn] Chamada de ${uid} sem authorizationCode/clientId válidos.`);
    return {sucesso: false};
  }

  try {
    const refreshToken = await _trocarCodigoPorRefreshToken(authorizationCode, clientId);
    await db.collection("usuarios").doc(uid).set({
      appleRefreshToken: refreshToken,
      appleClientId: clientId,
      appleRefreshTokenAtualizadoEm: FieldValue.serverTimestamp(),
    }, {merge: true});
    logger.info(`[AppleSignIn] refresh_token da Apple registrado para ${uid}.`);
    return {sucesso: true};
  } catch (e) {
    logger.error(
        `[AppleSignIn] Falha ao trocar authorizationCode por refresh_token (uid=${uid}) — ` +
        "best-effort, login do usuário não foi afetado.", e,
    );
    return {sucesso: false};
  }
});

/**
 * Revoga o refresh_token da Apple do usuário [uid], se algum estiver
 * registrado (ver [registrarAutorizacaoApple]) — POST
 * https://appleid.apple.com/auth/revoke. Chamada por
 * `exclusaoContaService.js::excluirContaCompleta` ANTES de apagar
 * `usuarios/{uid}` (é de lá que o refresh_token é lido). No-op
 * silencioso se o usuário nunca logou via Apple (nenhum
 * `appleRefreshToken` gravado). Best-effort: NUNCA lança exceção, nunca
 * bloqueia o resto da exclusão de conta.
 * @param {string} uid
 */
async function revogarAppleTokenSeExistir(uid) {
  try {
    const snap = await db.collection("usuarios").doc(uid).get();
    const dados = snap.exists ? snap.data() : null;
    const refreshToken = dados && dados.appleRefreshToken;
    if (!refreshToken) return;
    const clientId = dados.appleClientId || APPLE_BUNDLE_ID;

    const corpo = new URLSearchParams({
      client_id: clientId,
      client_secret: _gerarClientSecretApple(clientId),
      token: refreshToken,
      token_type_hint: "refresh_token",
    });

    const resposta = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      headers: {"Content-Type": "application/x-www-form-urlencoded"},
      body: corpo,
    });

    if (!resposta.ok) {
      const texto = await resposta.text();
      throw new Error(`Apple /auth/revoke retornou ${resposta.status}: ${texto}`);
    }

    logger.info(`[AppleSignIn] Token da Apple revogado com sucesso para ${uid} (exclusão de conta).`);
  } catch (e) {
    logger.error(
        `[AppleSignIn] Falha ao revogar token da Apple na exclusão de conta (uid=${uid}) — ` +
        "best-effort, não impede a exclusão do resto da conta.", e,
    );
  }
}

exports.revogarAppleTokenSeExistir = revogarAppleTokenSeExistir;
exports.APPLE_SIWA_SECRETS = APPLE_SIWA_SECRETS;
