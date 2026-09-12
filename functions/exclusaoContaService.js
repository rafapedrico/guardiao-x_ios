/**
 * Exclusão definitiva de conta (Configurações > Minha Conta > Excluir
 * Conta e Dados no app) — requisito de conformidade da Google Play Store
 * e da Apple App Store para apps que oferecem cadastro de conta.
 *
 * Roda inteiramente com o Admin SDK, por dois motivos:
 * 1. `firestore.rules` nega `delete` ao cliente de propósito em TODAS as
 *    coleções (usuarios, alarmes_agendados, permissoes_monitoramento —
 *    ver comentários lá) — o cliente jamais conseguiria apagar esses
 *    documentos sozinho, mesmo sendo o dono.
 * 2. Apagar o registro do Firebase Authentication a partir do cliente
 *    (`user.delete()`) exige reautenticação recente
 *    (`requires-recent-login`) — inviável de tratar de forma uniforme
 *    aqui, já que o login pode ter sido por e-mail/senha OU por um
 *    provider social (Google/Facebook/Apple), cada um com seu próprio
 *    fluxo de reautenticação. `admin.auth().deleteUser()` ignora essa
 *    exigência por completo.
 *
 * A confirmação de identidade de quem está pedindo a exclusão continua
 * sendo feita no PRÓPRIO APARELHO, pelo PIN de segurança já usado em
 * todas as demais ações sensíveis do Guardião X (ver `ExcluirContaScreen`
 * / `pin_dialog.dart`) — esta função só executa depois que o PIN correto
 * já foi confirmado localmente e o app chama esta callable autenticado
 * como o próprio usuário (`request.auth.uid`).
 *
 * MIGRAÇÃO iOS — Guideline 4.8 da App Store (achado no checklist final,
 * 2026-09-12): quem tiver logado via Sign in with Apple também tem o
 * token da Apple revogado aqui (ver [revogarAppleTokenSeExistir] em
 * `appleSignInService.js`), ANTES de [excluirDadosFirestore] apagar
 * `usuarios/{uid}` — é de lá que o refresh_token gravado no login é
 * lido. Best-effort/no-op para quem nunca logou via Apple.
 */

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const {getFirestore} = require("firebase-admin/firestore");
const {getAuth} = require("firebase-admin/auth");
const {getStorage} = require("firebase-admin/storage");
const logger = require("firebase-functions/logger");
const {revogarAppleTokenSeExistir, APPLE_SIWA_SECRETS} = require("./appleSignInService");

const db = getFirestore();

/**
 * Apaga todos os documentos do Firestore associados a [uid]:
 * - `usuarios/{uid}` (documento principal) e sua subcoleção
 *   `monitoramento/atual`.
 * - `alarmes_agendados/*` cujo campo `usuarioId` seja [uid].
 * - `permissoes_monitoramento/*` em que [uid] seja `uidAlvo` OU
 *   `uidSolicitante` (compartilhamento bilateral de localização).
 *
 * NÃO apaga `usuarios/{uid}/alertas/*` (histórico de alertas, localizações
 * e fotografias) nem as fotos do SOS em `sos_fotos/{uid}/` no Storage —
 * RETENÇÃO DELIBERADA DE 30 DIAS (reespecificação do usuário, 2026-09-04,
 * ver `website/exclusao-dados.html`/`privacidade.html` e
 * `excluirContaItemHistorico` no app): por motivos de segurança, esse
 * histórico serve de prova em caso de incidentes e só é apagado de
 * verdade pela function agendada [purgarHistoricoRetidoAposExclusao] em
 * `retencaoAlertasService.js`, 30 dias depois de [registrarRevogacao] ter
 * gravado `excluidoEm`. Ficam órfãos (mas inertes: sem o uid no Auth,
 * ninguém jamais volta a autenticar como esse usuário para lê-los —
 * `firestore.rules` restringe `alertas` ao próprio dono) até lá.
 *
 * NÃO tenta limpar `entregas_alerta/*\/confirmacoes/{uid}` — coleção
 * interna e opaca do pipeline de Push (sem índice viável por uid a partir
 * daqui) que não contém, por si só, nenhum dado pessoal identificável
 * além da própria referência de uid, já órfã depois deste processo.
 *
 * Também libera `telefones_reservados/{telefone}` (ver
 * `telefonePerfilService.js` — unicidade estrita sem OTP, decisão de
 * arquitetura 2026-08-23) SE o usuário tiver um telefone gravado — sem
 * isso, o número ficaria permanentemente preso e ninguém mais (nem o
 * próprio dono, numa conta nova) conseguiria cadastrá-lo de novo. Lição
 * do bug da "conta fantasma" do Auth (mesmo dia): a liberação acontece
 * no MESMO Promise.all que apaga `usuarios/{uid}`, nunca numa etapa
 * separada que possa ficar pra trás se algo falhar no meio do caminho.
 *
 * @param {string} uid
 */
async function excluirDadosFirestore(uid) {
  const operacoes = [];

  // BUG REAL CORRIGIDO (auditoria de exclusão de conta, 2026-09-04): esta
  // subcoleção (ver `relatorioFalhaService.js`) normalmente se autolimpa —
  // o próprio app apaga cada documento assim que o processa (ver
  // `RelatorioFalhaEntregaService._ingerirRelatorio` no Flutter) — mas um
  // relatório gerado e ainda não processado no momento da exclusão (app
  // fechado, nudge perdido) ficava permanentemente órfão: sem o `uid` no
  // Auth, ninguém jamais volta a autenticar como esse usuário para apagá-lo,
  // e `firestore.rules` restringe `relatoriosFalha` ao próprio dono — os
  // nomes/telefones de terceiros ali dentro (`contatosFalha`) ficariam
  // presos para sempre.
  const relatoriosFalhaSnap = await db
      .collection("usuarios").doc(uid).collection("relatoriosFalha").get();
  for (const doc of relatoriosFalhaSnap.docs) operacoes.push(doc.ref.delete());

  operacoes.push(
      db.collection("usuarios").doc(uid)
          .collection("monitoramento").doc("atual")
          .delete().catch(() => {}),
  );

  const usuarioSnap = await db.collection("usuarios").doc(uid).get();
  const telefone = usuarioSnap.exists ? usuarioSnap.data().telefone : null;
  if (telefone) {
    const refReserva = db.collection("telefones_reservados").doc(telefone);
    const reservaSnap = await refReserva.get();
    // Defensivo: só apaga se a reserva for realmente deste uid.
    if (reservaSnap.exists && reservaSnap.data().uid === uid) {
      operacoes.push(refReserva.delete());
    }
  }

  operacoes.push(db.collection("usuarios").doc(uid).delete());

  const alarmesSnap = await db.collection("alarmes_agendados")
      .where("usuarioId", "==", uid).get();
  for (const doc of alarmesSnap.docs) operacoes.push(doc.ref.delete());

  const [comoAlvo, comoSolicitante] = await Promise.all([
    db.collection("permissoes_monitoramento")
        .where("uidAlvo", "==", uid).get(),
    db.collection("permissoes_monitoramento")
        .where("uidSolicitante", "==", uid).get(),
  ]);
  for (const doc of comoAlvo.docs) operacoes.push(doc.ref.delete());
  for (const doc of comoSolicitante.docs) operacoes.push(doc.ref.delete());

  await Promise.all(operacoes);
}

/**
 * DECISÃO DE ARQUITETURA DELIBERADA (auditoria de exclusão de conta,
 * 2026-09-04) — `suporte_tickets/{ticketId}` (+ subcoleção `mensagens`) e
 * `suporte_limites/{uid}` (ver `suporteChatService.js`) NÃO são apagados
 * por [excluirDadosFirestore], PROPOSITALMENTE: um agressor que force a
 * vítima a excluir a conta (ou que exclua a própria conta após ser
 * denunciado) não deve conseguir apagar junto o histórico de conversas com
 * o Suporte/IA — que pode conter relatos, pedidos de ajuda ou evidências
 * relevantes para uma investigação/auditoria posterior. O documento fica
 * apenas orfão de uma conta que não existe mais (o campo `uid` deixa de
 * corresponder a qualquer usuário do Auth), nunca acessível a mais
 * ninguém por `firestore.rules` além do Painel de Admin
 * (`temRolePainel`). NÃO remover esta retenção sem entender o motivo
 * acima — se um pedido de exclusão granular desses dados surgir no
 * futuro, resolver via solicitação manual ao DPO (ver
 * `exclusao-dados.html`), nunca pelo fluxo automático desta função.
 */

/**
 * Apaga todas as fotos do SOS enviadas por [uid] (`sos_fotos/{uid}/*` no
 * Storage — ver `storage.rules`).
 *
 * NÃO é mais chamada por [excluirContaCompleta] diretamente — ver
 * RETENÇÃO DELIBERADA DE 30 DIAS documentada em [excluirDadosFirestore].
 * Chamada só pela function agendada [purgarHistoricoRetidoAposExclusao]
 * em `retencaoAlertasService.js`, ao final do prazo de retenção. Mantida
 * exportada e sem nenhuma outra mudança de comportamento.
 * @param {string} uid
 */
async function excluirArquivosStorage(uid) {
  const bucket = getStorage().bucket();
  await bucket.deleteFiles({prefix: `sos_fotos/${uid}/`});
}

/**
 * Apaga definitivamente `usuarios/{uid}/alertas/*` (histórico de alertas,
 * localizações e fotografias enviadas) — chamada EXCLUSIVAMENTE pela
 * function agendada [purgarHistoricoRetidoAposExclusao] em
 * `retencaoAlertasService.js`, ao final do prazo de retenção de 30 dias
 * (ver RETENÇÃO DELIBERADA documentada em [excluirDadosFirestore]).
 * Extraída como função própria (em vez de inline lá) justamente porque
 * NÃO roda mais no momento da exclusão da conta em si.
 * @param {string} uid
 */
async function excluirHistoricoAlertas(uid) {
  const alertasSnap = await db
      .collection("usuarios").doc(uid).collection("alertas").get();
  await Promise.all(alertasSnap.docs.map((doc) => doc.ref.delete()));
}

/**
 * Registra um marcador PERMANENTE de revogação em `contas_excluidas/{uid}`
 * — sobrevive à exclusão do documento `usuarios/{uid}` (apagado logo
 * depois, ver [excluirDadosFirestore]) e existe justamente para não
 * depender só da memória do processo.
 *
 * IMPORTANTE — por que isto NÃO chama nenhum gateway de pagamento: o
 * Guardião X não processa cobranças diretamente e NUNCA integrou nenhum
 * gateway (Stripe ou similar) — as assinaturas do Plano Premium são
 * feitas 100% pela Google Play Billing / Apple StoreKit, sem nenhuma
 * Cloud Function neste projeto recebendo webhooks/RTDN dessas lojas (ver
 * `PremiumPriceService`/Termos de Uso, Seção 7: "a RMF Global não recebe
 * nem processa pagamentos diretamente"). Isso significa que a RMF Global
 * NUNCA teve, em nenhum momento, um meio de cobrar o usuário por conta
 * própria — não existe "assinatura" para revogar do lado do servidor
 * porque o servidor nunca teve controle sobre ela. A renovação automática
 * de uma assinatura ativa é decidida inteiramente pela conta
 * Google/Apple do próprio usuário, por isso a tela de exclusão orienta
 * explicitamente o cancelamento na loja (ver
 * `excluirContaAvisoAssinatura` nos arquivos de tradução).
 *
 * Este documento existe para o cenário em que uma futura integração
 * server-side com a Google Play Developer API (Real-time Developer
 * Notifications) for implementada: bastaria consultar esta coleção antes
 * de processar uma notificação de renovação, para reconhecer contas já
 * excluídas e tratar cobranças pós-exclusão como reembolso automático.
 *
 * TAMBÉM é o âncora da RETENÇÃO DE 30 DIAS do histórico de alertas (ver
 * [excluirDadosFirestore]): `excluidoEmMs` (epoch, mais fácil de comparar
 * numa query do que o ISO string de `excluidoEm`, mantido por
 * compatibilidade) + `retencaoProcessada: false` são o que a function
 * agendada [purgarHistoricoRetidoAposExclusao] em
 * `retencaoAlertasService.js` usa para achar, todo dia, quais contas já
 * passaram do prazo de 30 dias e ainda não tiveram o histórico
 * definitivamente apagado.
 *
 * @param {string} uid
 */
async function registrarRevogacao(uid) {
  const agora = new Date();
  await db.collection("contas_excluidas").doc(uid).set({
    excluidoEm: agora.toISOString(),
    excluidoEmMs: agora.getTime(),
    motivo: "exclusao_de_conta_pelo_usuario",
    retencaoProcessada: false,
  });
}

/**
 * Callable `onCall` acionada pelo app (ver `ExclusaoContaService` no
 * Flutter) depois da confirmação do PIN de segurança na
 * `ExcluirContaScreen`. Ordem deliberada: registro de revogação ->
 * Firestore -> Auth por último — se algo falhar antes de chegar no Auth,
 * o usuário ainda consegue logar de novo e tentar a exclusão outra vez;
 * apagar o Auth primeiro removeria essa chance de nova tentativa.
 *
 * Storage (`sos_fotos/{uid}/`) DELIBERADAMENTE não é apagado aqui mais —
 * ver RETENÇÃO DE 30 DIAS documentada em [excluirDadosFirestore]/
 * [excluirArquivosStorage]: quem apaga de verdade, ao final do prazo, é a
 * function agendada em `retencaoAlertasService.js`.
 */
// Reexportadas para reuso por `retencaoAlertasService.js` (purga definitiva
// do histórico retido, 30 dias depois) — mesma lógica de limpeza, sem
// duplicar código.
exports.excluirDadosFirestore = excluirDadosFirestore;
exports.excluirArquivosStorage = excluirArquivosStorage;
exports.excluirHistoricoAlertas = excluirHistoricoAlertas;

exports.excluirContaCompleta = onCall({secrets: APPLE_SIWA_SECRETS}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "É necessário estar autenticado.");
  }
  const uid = request.auth.uid;

  try {
    await registrarRevogacao(uid);
  } catch (e) {
    // Best-effort: a ausência deste marcador nunca deve impedir a
    // exclusão real da conta em si, que é o que o usuário pediu. Note que
    // isto também significa que o histórico de alertas deste uid pode
    // ficar retido além dos 30 dias normais, até alguém notar/corrigir —
    // preferível a apagar peças de evidência sem o marcador de segurança.
    logger.error(`[excluirContaCompleta] Falha ao registrar revogação de ${uid}:`, e);
  }

  // Guideline 4.8 da App Store — ver documentação completa no topo do
  // arquivo. ANTES de excluirDadosFirestore: é de usuarios/{uid} que o
  // refresh_token da Apple é lido. Já é best-effort internamente
  // ([revogarAppleTokenSeExistir] nunca lança), então nada de try/catch
  // extra aqui.
  await revogarAppleTokenSeExistir(uid);

  try {
    await excluirDadosFirestore(uid);
  } catch (e) {
    logger.error(`[excluirContaCompleta] Falha ao excluir Firestore de ${uid}:`, e);
    throw new HttpsError("internal", "Falha ao excluir os dados salvos na nuvem.");
  }

  try {
    await getAuth().deleteUser(uid);
  } catch (e) {
    logger.error(`[excluirContaCompleta] Falha ao excluir usuário do Auth ${uid}:`, e);
    throw new HttpsError("internal", "Falha ao excluir o cadastro de autenticação.");
  }

  logger.info(`[excluirContaCompleta] Conta ${uid} excluída com sucesso — histórico de alertas/fotos retido por 30 dias.`);
  return {sucesso: true};
});
