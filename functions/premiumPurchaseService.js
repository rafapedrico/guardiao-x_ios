/**
 * Validação real de compra do Plano Premium — Google Play Billing
 * (Android) e Apple App Store (iOS, adicionado na Fase 5 da migração
 * iOS, 2026-09-12) — fecha a lacuna documentada em `planoCicloService.js`/
 * `lib/services/premium_price_service.dart` (não existia, neste projeto,
 * nenhuma verificação de recibo de compra; `isPremium` só podia ser
 * concedido manualmente pelo Console do Firebase).
 *
 * Fluxo completo (Android, inalterado desde a versão original):
 * 1. App compra a assinatura via Play Billing (`InAppPurchase.buyNonConsumable`,
 *    ver `lib/services/premium_purchase_service.dart`).
 * 2. O `purchaseStream` do app recebe o `PurchaseDetails` com o
 *    `purchaseToken` e chama [validarCompraPremium] aqui.
 * 3. Esta função consulta a Play Developer API (Android Publisher,
 *    endpoint `purchases.subscriptionsv2`) para confirmar que o token é
 *    genuíno e que a assinatura está de fato ativa — NUNCA confia em
 *    nada que o cliente diga sobre o estado da compra.
 * 4. Só então grava `isPremium: true` em `usuarios/{uid}` (Admin SDK —
 *    única forma permitida, ver `firestore.rules`).
 *
 * Fluxo completo (iOS, Fase 5): o mesmo desenho, com a App Store Server
 * API (`@apple/app-store-server-library`, biblioteca OFICIAL da Apple)
 * no lugar da Play Developer API — ver [_verificarTransacaoApple]/
 * [_validarEGravarPremiumApple] abaixo. `platform: 'ios'` no payload da
 * chamada decide qual das duas rotas é usada; nenhuma linha do fluxo
 * Android precisou mudar.
 *
 * PRÉ-REQUISITO DE INFRAESTRUTURA — ANDROID (fora do alcance do código —
 * precisa ser feito manualmente no Google Cloud/Play Console antes de
 * funcionar em produção):
 * 1. Ativar a "Google Play Android Developer API" (androidpublisher.
 *    googleapis.com) no projeto GCP do Firebase (mesmo projeto do
 *    `guardiaox`, número 555863351772).
 * 2. Play Console > Configurar > Acesso à API > vincular esse projeto
 *    GCP (se ainda não estiver vinculado).
 * 3. Na mesma tela, conceder acesso à conta de serviço que esta function
 *    (Cloud Functions Gen 2) efetivamente usa por padrão —
 *    `555863351772-compute@developer.gserviceaccount.com` (conta padrão
 *    do Compute Engine; NÃO é a `<project-id>@appspot.gserviceaccount.com`
 *    do Gen 1) — com a permissão "Ver dados financeiros" + "Gerenciar
 *    pedidos e assinaturas" (Financial data / Orders & subscriptions).
 * Sem isso, toda chamada a [validarCompraPremium] (Android) falha com 403
 * `accessNotConfigured` (a API do Google recusa a consulta por permissão)
 * — confirmado nos logs de produção em 2026-09-02/03.
 *
 * PRÉ-REQUISITO DE INFRAESTRUTURA — iOS (Fase 5, NADA disto pôde ser
 * feito neste ambiente Windows — exige uma conta Apple Developer paga e
 * acesso ao App Store Connect, nenhum dos dois disponível aqui):
 * 1. App Store Connect > Users and Access > Integrations > In-App
 *    Purchase — gerar uma chave (uma única vez), anotando o **Key ID** e
 *    o **Issuer ID** exibidos, e baixar o arquivo `.p8` (só pode ser
 *    baixado UMA vez).
 * 2. Configurar os 3 segredos desta function (nunca commitar os valores
 *    reais no código — `defineSecret` abaixo só declara os NOMES):
 *      firebase functions:secrets:set APPLE_ISSUER_ID
 *      firebase functions:secrets:set APPLE_KEY_ID
 *      firebase functions:secrets:set APPLE_PRIVATE_KEY   # conteúdo completo do .p8, incluindo as linhas BEGIN/END PRIVATE KEY
 * 3. Cadastrar o produto de assinatura `assinatura_mensal` (MESMO id do
 *    Android) em App Store Connect > Monetização > Assinaturas, dentro
 *    de um Grupo de Assinaturas — preço, período de teste etc.
 * 4. `APPLE_APP_APPLE_ID` (o Apple ID numérico do app, visível em App
 *    Store Connect > App Information) — preenchido com 6817916652. O
 *    `SignedDataVerifier` EXIGE esse valor no ambiente PRODUCTION (no
 *    SANDBOX ele é ignorado).
 * Sem os 3 segredos configurados, toda chamada iOS de
 * [validarCompraPremium] falha com "unavailable" (erro de credencial ao
 * montar o `AppStoreServerAPIClient`).
 *
 * NÃO TESTADO CONTRA A APPLE DE VERDADE: diferente do lado Android (já
 * validado em produção), este código foi escrito seguindo a documentação
 * oficial da Apple/`@apple/app-store-server-library`
 * (https://apple.github.io/app-store-server-library-node/) mas nunca
 * rodou contra uma compra Sandbox/TestFlight real — este ambiente não
 * tem Mac/Xcode/conta Apple Developer para isso (ver
 * `docs/migracao-ios-relatorio-2026-09-12.md`). Testar de ponta a ponta
 * no Sandbox da Apple ANTES de liberar a compra Premium para usuários
 * iOS reais é fortemente recomendado.
 *
 * LIMITE HONESTO (documentado para nunca ser esquecido, válido para as
 * duas plataformas): cobre a CONCESSÃO inicial e a reverificação
 * periódica (ver [reverificarAssinaturasPremium] abaixo), mas não usa
 * notificações em tempo real (RTDN/Pub-Sub no Android; App Store Server
 * Notifications V2 no iOS) — uma renovação com falha de pagamento ou um
 * cancelamento só é refletido em `isPremium` na próxima execução da
 * reverificação diária, nunca instantaneamente.
 */

const fs = require("fs");
const path = require("path");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {defineSecret} = require("firebase-functions/params");
const {getFirestore, FieldValue} = require("firebase-admin/firestore");
const {GoogleAuth} = require("google-auth-library");
const {v5: uuidv5} = require("uuid");
const {
  AppStoreServerAPIClient,
  SignedDataVerifier,
  Environment,
} = require("@apple/app-store-server-library");
const logger = require("firebase-functions/logger");

const db = getFirestore();

// Mesmo pacote Android usado em `android/app/build.gradle`
// (`applicationId`) e nos links da Play Store espalhados pelo app/site.
const ANDROID_PACKAGE_NAME = "com.rmfglobal.guardiaox";

// Mesmo bundle id iOS configurado em `ios/Runner.xcodeproj` (Fase 0 da
// migração) — igual ao pacote Android de propósito (ver
// `lib/firebase_options.dart`).
const APPLE_BUNDLE_ID = "com.rmfglobal.guardiaox";
// Apple ID numérico do app em App Store Connect (App Information).
const APPLE_APP_APPLE_ID = 6817916652;

// Id do produto de assinatura mensal — precisa ser EXATAMENTE este id
// tanto no Play Console (Monetise > Products > Subscriptions) quanto em
// App Store Connect (Monetização > Assinaturas), e é o mesmo usado em
// `lib/services/premium_price_service.dart`/`premium_purchase_service.dart`.
const PRODUTO_PREMIUM_ID = "assinatura_mensal";

// Segredos da App Store Server API — NUNCA valores reais aqui, só os
// nomes (ver instruções de infraestrutura no topo do arquivo).
const appleIssuerId = defineSecret("APPLE_ISSUER_ID");
const appleKeyId = defineSecret("APPLE_KEY_ID");
const applePrivateKey = defineSecret("APPLE_PRIVATE_KEY");
const APPLE_SECRETS = [appleIssuerId, appleKeyId, applePrivateKey];

// Namespace fixo (UUID v4 gerado uma única vez para este projeto) usado
// para derivar um `appAccountToken` DETERMINÍSTICO a partir do uid do
// Firebase — StoreKit 2 exige um UUID de verdade nesse campo (uma
// string arbitrária como o uid é SILENCIOSAMENTE descartada pela Apple,
// ao contrário do `obfuscatedAccountId` do Android, que aceita
// qualquer string). Ver a MESMA constante, com o MESMO valor, em
// `lib/services/premium_purchase_service.dart`.
//
// NUNCA ALTERAR este valor depois que a primeira compra real no iOS
// acontecer — mudar quebraria a checagem antifraude de todo uid que já
// comprou (o token esperado recalculado não bateria mais com o token
// gravado na compra original pela Apple).
const NAMESPACE_APP_ACCOUNT_TOKEN = "0ab5674b-b258-4492-9068-4e0fdf0c98ef";

// Estados da Play Developer API (`subscriptionState`) em que o usuário
// AINDA tem direito ao Premium. `SUBSCRIPTION_STATE_CANCELED` é tratado
// à parte abaixo (tem direito só até `expiryTime`, mesmo com auto-renew
// desligado). Todos os demais (ON_HOLD, PAUSED, EXPIRED, PENDING) NÃO
// dão direito.
const ESTADOS_COM_DIREITO_A_PREMIUM = new Set([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
]);

// Estados da App Store Server API (`Status`, ver
// https://apple.github.io/app-store-server-library-node/enums/Status.html)
// em que o usuário AINDA tem direito ao Premium — mesmo espírito do
// conjunto Android acima: ACTIVE (1) e BILLING_GRACE_PERIOD (4) contam;
// EXPIRED (2), BILLING_RETRY (3) e REVOKED (5) não.
const ESTADOS_APPLE_COM_DIREITO_A_PREMIUM = new Set([1, 4]);

/**
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @return {boolean}
 */
function _ehAdmin(request) {
  return !!request.auth && request.auth.token.role === "admin";
}

let _clienteAndroidPublisherPromise = null;

/**
 * Cliente HTTP autenticado (via Application Default Credentials — a
 * própria identidade da Cloud Function) com escopo da Play Developer
 * API. Reaproveitado entre invocações (mesma instância da function),
 * nunca recriado a cada chamada.
 */
function _obterClienteAndroidPublisher() {
  if (!_clienteAndroidPublisherPromise) {
    const auth = new GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/androidpublisher"],
    });
    _clienteAndroidPublisherPromise = auth.getClient();
  }
  return _clienteAndroidPublisherPromise;
}

/**
 * Consulta o estado REAL e atual de uma assinatura na Play Store a
 * partir do `purchaseToken` — nunca do que o app envia sobre si mesmo.
 * @param {string} purchaseToken
 * @return {Promise<object>} corpo de `SubscriptionPurchaseV2`.
 */
async function _consultarAssinaturaNaPlayStore(purchaseToken) {
  const client = await _obterClienteAndroidPublisher();
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${ANDROID_PACKAGE_NAME}/purchases/subscriptionsv2/tokens/` +
    `${encodeURIComponent(purchaseToken)}`;
  const resposta = await client.request({url});
  return resposta.data;
}

/**
 * Decide, a partir da resposta da Play Store, se a assinatura dá direito
 * ao Premium AGORA e até quando.
 * @param {object} assinatura resposta de [_consultarAssinaturaNaPlayStore].
 * @param {string} productIdEsperado
 * @return {{temDireito: boolean, expiryTimeMs: (number|null), motivo: (string|undefined)}}
 */
function _calcularDireitoPremio(assinatura, productIdEsperado) {
  const estado = assinatura.subscriptionState;
  const itemLinha = (assinatura.lineItems || [])
      .find((item) => item.productId === productIdEsperado);

  if (!itemLinha) {
    return {temDireito: false, expiryTimeMs: null, motivo: "produto_nao_encontrado"};
  }

  const expiryTimeMs = Date.parse(itemLinha.expiryTime);
  const expiryValido = !Number.isNaN(expiryTimeMs);

  if (ESTADOS_COM_DIREITO_A_PREMIUM.has(estado)) {
    return {temDireito: true, expiryTimeMs: expiryValido ? expiryTimeMs : null};
  }

  // Cancelada (auto-renovação desligada) mas ainda dentro do período já
  // pago — mantém acesso até a data de expiração, igual qualquer
  // assinatura cancelada em qualquer loja.
  if (estado === "SUBSCRIPTION_STATE_CANCELED" && expiryValido && expiryTimeMs > Date.now()) {
    return {temDireito: true, expiryTimeMs};
  }

  return {temDireito: false, expiryTimeMs: expiryValido ? expiryTimeMs : null, motivo: estado};
}

// ================================================================
// iOS — App Store Server API (Fase 5 da migração, 2026-09-12)
// ================================================================

/**
 * Lê os certificados-raiz da Apple, baixados de
 * https://www.apple.com/certificateauthority/AppleRootCA-G3.cer e
 * versionados junto com esta function (`functions/certs/`) — exigidos
 * pelo `SignedDataVerifier` para confirmar que uma transação foi
 * assinada de verdade pela Apple, nunca forjada.
 * @return {Buffer[]}
 */
function _carregarRaizesConfiancaApple() {
  const caminho = path.join(__dirname, "certs", "AppleRootCA-G3.cer");
  return [fs.readFileSync(caminho)];
}

const _clientesAppleCache = {};

/**
 * Monta (e reaproveita entre invocações, uma instância por ambiente) o
 * par cliente/verificador da App Store Server API para o [environment]
 * informado (`Environment.PRODUCTION` ou `Environment.SANDBOX`) — ver
 * `@apple/app-store-server-library`, biblioteca OFICIAL da Apple.
 * @param {Environment} environment
 * @return {{client: AppStoreServerAPIClient, verifier: SignedDataVerifier}}
 */
function _obterClienteEVerifierApple(environment) {
  if (_clientesAppleCache[environment]) return _clientesAppleCache[environment];

  const client = new AppStoreServerAPIClient(
      applePrivateKey.value(),
      appleKeyId.value(),
      appleIssuerId.value(),
      APPLE_BUNDLE_ID,
      environment,
  );
  const verifier = new SignedDataVerifier(
      _carregarRaizesConfiancaApple(),
      true, // enableOnlineChecks
      environment,
      APPLE_BUNDLE_ID,
      // appAppleId (Apple ID numérico do app) — ver instruções de
      // infraestrutura no topo do arquivo, item 4.
      APPLE_APP_APPLE_ID,
  );

  _clientesAppleCache[environment] = {client, verifier};
  return _clientesAppleCache[environment];
}

/**
 * Verifica a assinatura de [transactionJws] (a JWS que o app envia —
 * `compra.verificationData.serverVerificationData` no
 * `PurchaseDetails` do `in_app_purchase_storekit`, ver
 * `premium_purchase_service.dart`) e devolve o payload já decodificado.
 * Tenta PRODUCTION primeiro; cai para SANDBOX automaticamente se a
 * verificação falhar nesse ambiente (mesmo padrão documentado pela
 * própria Apple para o antigo endpoint verifyReceipt, código 21007) —
 * cobre compras de desenvolvimento/TestFlight sem precisar saber de
 * antemão qual ambiente a transação veio.
 * @param {string} transactionJws
 * @return {Promise<{payload: object, environment: Environment}>}
 */
async function _verificarTransacaoApple(transactionJws) {
  let ultimoErro;
  for (const environment of [Environment.PRODUCTION, Environment.SANDBOX]) {
    const {verifier} = _obterClienteEVerifierApple(environment);
    try {
      const payload = await verifier.verifyAndDecodeTransaction(transactionJws);
      return {payload, environment};
    } catch (e) {
      ultimoErro = e;
    }
  }
  throw ultimoErro;
}

/**
 * Consulta o estado ATUAL (não o do momento da compra) da assinatura via
 * `getAllSubscriptionStatuses` — nunca confia no `expiresDate`/status
 * embutido na JWS que o cliente enviou (pode estar desatualizado desde
 * então). Mesmo par produção/sandbox de [_verificarTransacaoApple], mas
 * usado sozinho pela reverificação diária (ver
 * [reverificarAssinaturasPremium]), que não tem nenhuma JWS nova do
 * cliente para verificar — só o `originalTransactionId` já salvo.
 * @param {string} anyTransactionId qualquer id de transação da mesma
 *   linhagem de assinatura (a própria Apple resolve o grupo a partir dele).
 * @param {Environment} [environmentPreferido] tenta este primeiro, se
 *   informado (evita a tentativa desnecessária no outro ambiente quando
 *   já se sabe de qual a transação original veio).
 * @return {Promise<{statusResponse: object, environment: Environment}>}
 */
async function _obterStatusAssinaturaApple(anyTransactionId, environmentPreferido) {
  const ordem = environmentPreferido === Environment.SANDBOX ?
    [Environment.SANDBOX, Environment.PRODUCTION] :
    [Environment.PRODUCTION, Environment.SANDBOX];

  let ultimoErro;
  for (const environment of ordem) {
    const {client} = _obterClienteEVerifierApple(environment);
    try {
      const statusResponse = await client.getAllSubscriptionStatuses(anyTransactionId);
      return {statusResponse, environment};
    } catch (e) {
      ultimoErro = e;
    }
  }
  throw ultimoErro;
}

/**
 * Localiza, dentro da resposta de `getAllSubscriptionStatuses`, o item
 * de [originalTransactionId] informado e decide se ele dá direito ao
 * Premium agora.
 * @param {object} statusResponse resposta de [_obterStatusAssinaturaApple].
 * @param {string} originalTransactionId
 * @return {{temDireito: boolean, status: (number|null)}}
 */
function _calcularDireitoPremioApple(statusResponse, originalTransactionId) {
  const grupos = statusResponse.data || [];
  for (const grupo of grupos) {
    const itens = grupo.lastTransactions || [];
    const item = itens.find((it) => it.originalTransactionId === originalTransactionId);
    if (item) {
      return {
        temDireito: ESTADOS_APPLE_COM_DIREITO_A_PREMIUM.has(item.status),
        status: item.status,
      };
    }
  }
  return {temDireito: false, status: null};
}

/**
 * Núcleo da validação iOS — mesma filosofia e mesmo formato de retorno
 * de [_validarEGravarPremium] (Android), só que via App Store Server
 * API. Ver documentação completa daquela função para o desenho geral
 * (chamada tanto pela rota self-service quanto pela de reconciliação
 * manual do admin).
 * @param {{uid: string, transactionJws: string, productId: string, origem: string}} params
 * @return {Promise<{isPremium: boolean, subscriptionState: string, expiryTimeMs: (number|null|undefined)}>}
 */
async function _validarEGravarPremiumApple({uid, transactionJws, productId, origem}) {
  let payload;
  let environment;
  try {
    ({payload, environment} = await _verificarTransacaoApple(transactionJws));
  } catch (e) {
    logger.error(
        `[PremiumPurchase][Apple] (${origem}) Falha ao verificar a transação na App Store Server API (uid=${uid}) — ` +
        "verifique se os segredos APPLE_ISSUER_ID/APPLE_KEY_ID/APPLE_PRIVATE_KEY estão configurados.",
        e,
    );
    throw new HttpsError(
        "unavailable",
        origem === "admin" ?
          `Falha ao verificar a transação na App Store Server API: ${e.message || e}` :
          "Não foi possível validar a compra na App Store agora. Tente novamente em instantes.",
    );
  }

  // ANTI-FRAUDE (ver documentação completa de NAMESPACE_APP_ACCOUNT_TOKEN
  // acima e do lado Dart em `premium_purchase_service.dart`): o
  // appAccountToken sozinho prova que ALGUÉM comprou a assinatura, mas
  // só a comparação com o UUID v5 determinístico do uid prova que foi
  // ESTE usuário.
  const appAccountTokenEsperado = uuidv5(uid, NAMESPACE_APP_ACCOUNT_TOKEN);
  if (payload.appAccountToken !== appAccountTokenEsperado) {
    logger.warn(
        `[PremiumPurchase][Apple] (${origem}) Recusada: appAccountToken da transação ` +
        `("${payload.appAccountToken}") não bate com o esperado para uid="${uid}".`,
    );
    throw new HttpsError("permission-denied", "Esta compra não pertence a este usuário.");
  }

  if (payload.productId !== productId) {
    throw new HttpsError(
        "invalid-argument",
        `productId da transação (${payload.productId}) não corresponde ao esperado (${productId}).`,
    );
  }

  if (!payload.originalTransactionId) {
    throw new HttpsError("invalid-argument", "Transação da Apple sem originalTransactionId.");
  }

  let statusResponse;
  try {
    ({statusResponse} = await _obterStatusAssinaturaApple(payload.transactionId, environment));
  } catch (e) {
    logger.error(
        `[PremiumPurchase][Apple] (${origem}) Falha ao consultar getAllSubscriptionStatuses (uid=${uid}).`,
        e,
    );
    throw new HttpsError(
        "unavailable",
        "Não foi possível confirmar o status atual da assinatura na App Store agora. Tente novamente em instantes.",
    );
  }

  const {temDireito, status} =
    _calcularDireitoPremioApple(statusResponse, payload.originalTransactionId);

  if (!temDireito) {
    logger.info(
        `[PremiumPurchase][Apple] (${origem}) Compra de ${uid} validada, mas sem direito a Premium agora ` +
        `(status=${status}).`,
    );
    return {isPremium: false, subscriptionState: `apple_status_${status}`};
  }

  const camposGravados = {
    isPremium: true,
    premiumProductId: productId,
    premiumPlataforma: "ios",
    premiumOriginalTransactionId: payload.originalTransactionId,
    premiumAppleEnvironment: environment,
    premiumSubscriptionState: `apple_status_${status}`,
    premiumExpiryTimeMs: payload.expiresDate || null,
    premiumValidadoEm: FieldValue.serverTimestamp(),
  };
  if (origem === "admin") {
    camposGravados.premiumReconciliadoManualmenteEm = FieldValue.serverTimestamp();
  }

  await db.collection("usuarios").doc(uid).set(camposGravados, {merge: true});

  logger.info(
      `[PremiumPurchase][Apple] (${origem}) Premium concedido a ${uid} (status=${status}, ` +
      `expira em ${payload.expiresDate ? new Date(payload.expiresDate).toISOString() : "?"}).`,
  );

  return {
    isPremium: true,
    subscriptionState: `apple_status_${status}`,
    expiryTimeMs: payload.expiresDate || null,
  };
}

// ================================================================
// Android — Play Developer API (arquitetura original, inalterada)
// ================================================================

/**
 * Núcleo compartilhado entre [validarCompraPremium] (self-service, chamada
 * pelo próprio app) e [reconciliarCompraPremiumAdmin] (suporte manual, ver
 * documentação daquela function) — consulta a Play Store, aplica a MESMA
 * checagem antifraude (o token precisa pertencer ao `uid` informado) e só
 * então grava `isPremium`. Essa checagem NUNCA é pulada, nem para o admin:
 * o objetivo da rota administrativa é REPETIR esta verificação real quando
 * ela falhou por um problema de infraestrutura (ex: API do Google ainda
 * propagando após ser habilitada), nunca abrir um atalho sem ela — mantém
 * a mesma garantia antifraude documentada abaixo.
 * @param {{uid: string, purchaseToken: string, productId: string, origem: string}} params
 *   `origem` é só para os logs/mensagens de erro distinguirem quem chamou
 *   (`"self"` = o próprio usuário via app, `"admin"` = reconciliação manual).
 * @return {Promise<{isPremium: boolean, subscriptionState: string, expiryTimeMs: (number|null|undefined)}>}
 */
async function _validarEGravarPremium({uid, purchaseToken, productId, origem}) {
  let assinatura;
  try {
    assinatura = await _consultarAssinaturaNaPlayStore(purchaseToken);
  } catch (e) {
    logger.error(
        `[PremiumPurchase] (${origem}) Falha ao consultar a Play Developer API (uid=${uid}) — ` +
        "verifique se a API está ativada e a conta de serviço tem acesso no Play Console.",
        e,
    );
    throw new HttpsError(
        "unavailable",
        origem === "admin" ?
          // Rota admin: quem chama já está debugando o próprio problema de
          // infraestrutura, então o erro real (ex: "ainda propagando") é
          // mais útil do que a mensagem genérica abaixo.
          `Falha ao consultar a Play Developer API: ${e.message || e}` :
          "Não foi possível validar a compra na Play Store agora. Tente novamente em instantes.",
    );
  }

  // ANTI-FRAUDE: o purchaseToken sozinho prova que ALGUÉM comprou a
  // assinatura, mas não prova que foi ESTE usuário chamando agora — sem
  // esta checagem, um único purchaseToken válido (reaproveitado,
  // vazado ou compartilhado entre contas) poderia ser reenviado por N
  // uids Firebase diferentes, concedendo Premium de graça pra todos
  // eles. O app envia `accountId: uid` como `obfuscatedAccountId` no
  // momento da compra (ver [PurchaseParam] em
  // `premium_purchase_service.dart`) — a Play Store ecoa esse mesmo
  // valor aqui em `externalAccountIdentifiers`, e só seguimos adiante se
  // bater exatamente com o `uid` informado (o autenticado, na rota
  // self-service; o informado pelo admin, na rota de reconciliação).
  const idExternoDaCompra = assinatura.externalAccountIdentifiers &&
    assinatura.externalAccountIdentifiers.obfuscatedExternalAccountId;
  if (idExternoDaCompra !== uid) {
    logger.warn(
        `[PremiumPurchase] (${origem}) Recusada: obfuscatedAccountId da compra ("${idExternoDaCompra}") ` +
        `não bate com o uid esperado ("${uid}").`,
    );
    throw new HttpsError("permission-denied", "Esta compra não pertence a este usuário.");
  }

  const {temDireito, expiryTimeMs, motivo} = _calcularDireitoPremio(assinatura, productId);

  if (!temDireito) {
    logger.info(
        `[PremiumPurchase] (${origem}) Compra de ${uid} validada, mas sem direito a Premium agora ` +
        `(estado=${motivo || assinatura.subscriptionState}).`,
    );
    return {isPremium: false, subscriptionState: assinatura.subscriptionState};
  }

  const camposGravados = {
    isPremium: true,
    premiumProductId: productId,
    premiumPlataforma: "android",
    premiumPurchaseToken: purchaseToken,
    premiumSubscriptionState: assinatura.subscriptionState,
    premiumExpiryTimeMs: expiryTimeMs,
    premiumValidadoEm: FieldValue.serverTimestamp(),
  };
  // Marcador só informativo (auditoria) — não muda em nada o direito ao
  // Premium, que já foi verificado igual acima; só registra que desta vez
  // a concessão passou pela rota manual, não pelo purchaseStream do app.
  if (origem === "admin") {
    camposGravados.premiumReconciliadoManualmenteEm = FieldValue.serverTimestamp();
  }

  await db.collection("usuarios").doc(uid).set(camposGravados, {merge: true});

  logger.info(
      `[PremiumPurchase] (${origem}) Premium concedido a ${uid} (estado=${assinatura.subscriptionState}, ` +
      `expira em ${expiryTimeMs ? new Date(expiryTimeMs).toISOString() : "?"}).`,
  );

  return {
    isPremium: true,
    subscriptionState: assinatura.subscriptionState,
    expiryTimeMs,
  };
}

/**
 * Callable chamada pelo app assim que o `purchaseStream` entrega uma
 * compra em estado `purchased`/`restored` (ver
 * `PremiumPurchaseService._aoReceberAtualizacoesDeCompra` no Flutter).
 * `platform` ('android' | 'ios', enviado pelo app — ver
 * `premium_purchase_service.dart`) decide qual das duas lojas é
 * consultada; `purchaseToken` é o `purchaseToken` da Play Store no
 * Android e a JWS da transação (`serverVerificationData`) no iOS. Só
 * concede `isPremium` depois de validar de verdade na loja
 * correspondente.
 */
exports.validarCompraPremium = onCall({secrets: APPLE_SECRETS}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Requer autenticação.");
  }
  const uid = request.auth.uid;
  const {purchaseToken, productId, platform} = request.data || {};

  if (!purchaseToken || typeof purchaseToken !== "string") {
    throw new HttpsError("invalid-argument", "purchaseToken é obrigatório.");
  }
  if (productId !== PRODUTO_PREMIUM_ID) {
    throw new HttpsError(
        "invalid-argument",
        `productId inválido — esperado "${PRODUTO_PREMIUM_ID}".`,
    );
  }

  if (platform === "ios") {
    return _validarEGravarPremiumApple({uid, transactionJws: purchaseToken, productId, origem: "self"});
  }
  return _validarEGravarPremium({uid, purchaseToken, productId, origem: "self"});
});

/**
 * Reconciliação MANUAL de uma compra Premium — rota de suporte/admin para
 * os casos em que [validarCompraPremium] falhou por um problema de
 * INFRAESTRUTURA (não de fraude/direito): o exemplo real que motivou esta
 * function foi a Play Developer API ainda propagando logo após ser
 * habilitada no Cloud Console (ver comentário no topo do arquivo), que fez
 * o app receber "Não foi possível confirmar sua assinatura agora" mesmo
 * com a compra genuína e já paga do lado da Play Store. `platform`
 * opcional (default `"android"`, compatível com chamadas antigas do
 * painel admin) segue a MESMA rota Apple/Google de [validarCompraPremium]
 * quando informado `"ios"`.
 *
 * NÃO é uma forma de conceder Premium sem verificação — roda exatamente a
 * mesma consulta real à loja e a mesma checagem antifraude de
 * [validarCompraPremium] (ver [_validarEGravarPremium]/
 * [_validarEGravarPremiumApple]), só que acionada por um admin informando
 * `uid` + `purchaseToken` em vez de pelo próprio app. Mantém a DECISÃO
 * DELIBERADA de `planoAdminService.js` (aquele módulo nunca concede
 * Premium sem verificação) — esta function não é parte dele,
 * propositalmente: aqui SEMPRE há uma verificação real contra a loja
 * antes de qualquer gravação.
 *
 * O `purchaseToken` não fica salvo em lugar nenhum quando a validação
 * falha (só é gravado em `usuarios/{uid}` em caso de sucesso) — quem for
 * reconciliar precisa obter o token/JWS de outra forma (ex: logs do
 * dispositivo do próprio usuário, ou pedir para o usuário reabrir o app,
 * que já reenvia o mesmo token automaticamente via `restorePurchases()` a
 * cada boot — ver `PremiumPurchaseService.iniciar()` no Flutter).
 */
exports.reconciliarCompraPremiumAdmin = onCall({secrets: APPLE_SECRETS}, async (request) => {
  if (!_ehAdmin(request)) {
    throw new HttpsError("permission-denied", "Apenas admin.");
  }

  const {uid, purchaseToken, productId, platform} = request.data || {};
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("invalid-argument", "uid é obrigatório.");
  }
  if (!purchaseToken || typeof purchaseToken !== "string") {
    throw new HttpsError("invalid-argument", "purchaseToken é obrigatório.");
  }
  const productIdFinal = typeof productId === "string" && productId ?
    productId : PRODUTO_PREMIUM_ID;

  const usuarioSnap = await db.collection("usuarios").doc(uid).get();
  if (!usuarioSnap.exists) {
    throw new HttpsError("not-found", "Usuário não encontrado.");
  }

  const resultado = platform === "ios" ?
    await _validarEGravarPremiumApple({
      uid, transactionJws: purchaseToken, productId: productIdFinal, origem: "admin",
    }) :
    await _validarEGravarPremium({
      uid, purchaseToken, productId: productIdFinal, origem: "admin",
    });

  logger.info(
      `[PremiumPurchase] (admin) Reconciliação manual (${platform === "ios" ? "iOS" : "Android"}) ` +
      `disparada por ${request.auth.uid} para uid=${uid} — resultado: isPremium=${resultado.isPremium}.`,
  );

  return resultado;
});

/**
 * Rede de segurança contra o LIMITE HONESTO documentado no topo do
 * arquivo (sem notificações em tempo real): reverifica, uma vez por dia,
 * todo usuário atualmente `isPremium: true` com um `premiumPurchaseToken`
 * (Android) ou `premiumOriginalTransactionId` (iOS) registrado — ou seja,
 * concedido por [validarCompraPremium]/[reconciliarCompraPremiumAdmin].
 * Premium concedido manualmente pelo Console do Firebase (sem nenhum dos
 * dois campos) é ignorado aqui, de propósito, para nunca revogar uma
 * concessão manual. Uma assinatura que expirou, foi cancelada (após o fim
 * do período pago) ou entrou em pagamento recusado sem grace period tem
 * `isPremium` revertido para `false` automaticamente, em qualquer das
 * duas plataformas.
 */
exports.reverificarAssinaturasPremium = onSchedule(
    {
      schedule: "every 24 hours",
      timeZone: "America/Sao_Paulo",
      secrets: APPLE_SECRETS,
    },
    async () => {
      const premiumAtual = await db.collection("usuarios")
          .where("isPremium", "==", true)
          .get();

      if (premiumAtual.empty) {
        logger.info("[PremiumPurchase] Nenhum usuário Premium para reverificar.");
        return;
      }

      let revogados = 0;
      let mantidos = 0;
      let ignorados = 0;

      for (const doc of premiumAtual.docs) {
        const dados = doc.data();
        const tokenAndroid = dados.premiumPurchaseToken;
        const originalTransactionIdApple = dados.premiumOriginalTransactionId;

        if (tokenAndroid) {
          const productId = dados.premiumProductId || PRODUTO_PREMIUM_ID;
          try {
            const assinatura = await _consultarAssinaturaNaPlayStore(tokenAndroid);
            const {temDireito, expiryTimeMs} = _calcularDireitoPremio(assinatura, productId);

            if (!temDireito) {
              await doc.ref.set({
                isPremium: false,
                premiumSubscriptionState: assinatura.subscriptionState,
                premiumRevogadoEm: FieldValue.serverTimestamp(),
              }, {merge: true});
              logger.info(
                  `[PremiumPurchase] Premium (Android) revogado de ${doc.id} na reverificação ` +
                  `diária (estado=${assinatura.subscriptionState}).`,
              );
              revogados++;
            } else {
              await doc.ref.set({
                premiumSubscriptionState: assinatura.subscriptionState,
                premiumExpiryTimeMs: expiryTimeMs,
              }, {merge: true});
              mantidos++;
            }
          } catch (e) {
            // Falha de rede/API não deve derrubar o Premium de ninguém —
            // mesma filosofia permissiva do resto do app: uma falha
            // técnica na reverificação nunca, por si só, tira o acesso de
            // quem pagou. Só loga e tenta de novo amanhã.
            logger.error(
                `[PremiumPurchase] Falha ao reverificar a assinatura (Android) de ${doc.id} — mantido como estava.`,
                e,
            );
          }
          continue;
        }

        if (originalTransactionIdApple) {
          try {
            const environmentPreferido = dados.premiumAppleEnvironment === "Sandbox" ?
              Environment.SANDBOX : Environment.PRODUCTION;
            const {statusResponse} = await _obterStatusAssinaturaApple(
                originalTransactionIdApple, environmentPreferido,
            );
            const {temDireito, status} =
              _calcularDireitoPremioApple(statusResponse, originalTransactionIdApple);

            if (!temDireito) {
              await doc.ref.set({
                isPremium: false,
                premiumSubscriptionState: `apple_status_${status}`,
                premiumRevogadoEm: FieldValue.serverTimestamp(),
              }, {merge: true});
              logger.info(
                  `[PremiumPurchase] Premium (iOS) revogado de ${doc.id} na reverificação ` +
                  `diária (status=${status}).`,
              );
              revogados++;
            } else {
              await doc.ref.set({
                premiumSubscriptionState: `apple_status_${status}`,
              }, {merge: true});
              mantidos++;
            }
          } catch (e) {
            logger.error(
                `[PremiumPurchase] Falha ao reverificar a assinatura (iOS) de ${doc.id} — mantido como estava.`,
                e,
            );
          }
          continue;
        }

        // Premium sem token/originalTransactionId registrado = concedido
        // manualmente pelo Console do Firebase (ver planoAdminService.js)
        // — este job só reverifica compras reais feitas via loja.
        ignorados++;
      }

      logger.info(
          `[PremiumPurchase] Reverificação diária concluída: ${mantidos} mantido(s), ` +
          `${revogados} revogado(s), ${ignorados} ignorado(s) (Premium manual/sem token).`,
      );
    },
);
