/**
 * Cloud Functions do projeto Firebase "guardiaox" — camada de resiliência
 * na nuvem do Guardião X (security_check_app).
 *
 * FLUXO IMPLEMENTADO (documento criado em `usuarios/{usuarioId}/alertas`):
 * 1. O app Flutter escreve, de forma minimalista e o mais rápido possível,
 *    um documento em `usuarios/{usuarioId}/alertas/{alertaId}` assim que
 *    detecta um evento de emergência — ver `FirebaseSyncService` no app:
 *    - `tentativa_desarme_incorreto`: 2 PINs incorretos consecutivos.
 *    - `sos_fisico`: botão físico (Volume+) ou botão de SOS manual da aba
 *      Segurança (ver `SosDisparoService`), com `latitude`/`longitude`
 *      capturadas NA HORA do disparo (P1 da sequência unificada).
 *    - `sos_fisico_foto`: foto capturada em seguida (P2), com `fotoUrl`
 *      apontando para o arquivo já enviado ao Firebase Storage.
 * 2. Esta função é acionada automaticamente por esse `onDocumentCreated`.
 * 3. Ela resolve a localização a usar na mensagem: prioriza
 *    `alerta.latitude`/`alerta.longitude` (mais precisas, capturadas no
 *    exato instante do disparo) e só cai para a ÚLTIMA localização
 *    conhecida gravada no documento do usuário
 *    (`FirebaseSyncService.atualizarLocalizacaoAtual`) quando o alerta não
 *    as informa (caso do PIN incorreto, que não captura GPS na hora).
 * 4. Monta a mensagem de alerta (texto varia por `tipo`) com o link do
 *    Google Maps.
 * 5. Aciona o pipeline de entrega (ver `alertaHibridoService.js`): Push
 *    FCM gratuito para os contatos que têm o app instalado.
 */

const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const logger = require("firebase-functions/logger");

// IMPORTANTE: initializeApp() precisa rodar ANTES de qualquer módulo que
// chame getFirestore()/getMessaging() em seu próprio escopo top-level
// (ver alertaHibridoService.js, scheduledAlarmMonitor.js) — por isso
// esses `require`s só acontecem DEPOIS da linha abaixo, nunca antes.
initializeApp();
const db = getFirestore();

const {dispararAlertaHibrido} = require("./alertaHibridoService");

const TIPO_TENTATIVA_DESARME_INCORRETO = "tentativa_desarme_incorreto";
const TIPO_SOS_FISICO = "sos_fisico";
const TIPO_SOS_FISICO_FOTO = "sos_fisico_foto";
const TIPOS_ALERTA_TRATADOS = new Set([
  TIPO_TENTATIVA_DESARME_INCORRETO,
  TIPO_SOS_FISICO,
  TIPO_SOS_FISICO_FOTO,
]);

/**
 * @param {number} latitude
 * @param {number} longitude
 * @return {string}
 */
function montarLinkGoogleMaps(latitude, longitude) {
  return `https://maps.google.com/?q=${latitude},${longitude}`;
}

/**
 * @param {number|undefined} latitude
 * @param {number|undefined} longitude
 * @return {string}
 */
function montarTextoLocalizacao(latitude, longitude) {
  if (typeof latitude === "number" && typeof longitude === "number") {
    return `Latitude: ${latitude}, Longitude: ${longitude} ` +
        `(${montarLinkGoogleMaps(latitude, longitude)})`;
  }
  return "Localização indisponível (nenhuma posição registrada na nuvem " +
      "para este usuário).";
}

exports.aoReceberAlertaTentativaDesarme = onDocumentCreated(
    {
      document: "usuarios/{usuarioId}/alertas/{alertaId}",
    },
    async (event) => {
      const snap = event.data;
      if (!snap) {
        logger.warn("Evento sem dados (snap ausente) — ignorado.");
        return;
      }

      const alerta = snap.data();
      const {usuarioId} = event.params;

      if (!TIPOS_ALERTA_TRATADOS.has(alerta.tipo)) {
        logger.info(
            `Alerta tipo "${alerta.tipo}" ainda não tratado por esta ` +
            "função — ignorado.",
        );
        return;
      }

      const usuarioRef = db.collection("usuarios").doc(usuarioId);
      const usuarioSnap = await usuarioRef.get();
      const usuario = usuarioSnap.exists ? usuarioSnap.data() : {};

      // Prioriza as coordenadas do PRÓPRIO documento de alerta — gravadas
      // NA HORA do disparo pelo `SosDisparoService` (P1 da sequência
      // unificada do botão físico/SOS manual) — antes de cair para a
      // última localização conhecida do usuário (fluxo de PIN incorreto,
      // que não captura GPS na hora do disparo).
      const latitude = typeof alerta.latitude === "number" ?
          alerta.latitude : (usuario && usuario.latitude);
      const longitude = typeof alerta.longitude === "number" ?
          alerta.longitude : (usuario && usuario.longitude);
      const localizacaoTexto = montarTextoLocalizacao(latitude, longitude);
      const contatos = (usuario && usuario.contatosEmergencia) || [];

      let mensagem;
      if (alerta.tipo === TIPO_TENTATIVA_DESARME_INCORRETO) {
        // `motivo` descreve exatamente o que aconteceu (ver
        // FirebaseSyncService.dispararAlertaTentativaDesarmeIncorreto no
        // app) — cai no texto histórico apenas se o documento não o
        // informar (compatibilidade com alertas antigos/de teste).
        const motivo = alerta.motivo ||
            "O PIN foi digitado incorretamente 2 vezes seguidas ao tentar " +
            "desarmar antecipadamente o sistema de segurança.";
        mensagem =
            "⚠️ ALERTA DE SEGURANÇA (via nuvem): TENTATIVA DE DESARME COM " +
            "SENHA INCORRETA!\n" +
            `${motivo}\n` +
            `Localização: ${localizacaoTexto}`;
      } else if (alerta.tipo === TIPO_SOS_FISICO) {
        // P1 da sequência unificada (ver SosDisparoService no app) —
        // botão físico de Volume+ ou botão de SOS manual da aba
        // Segurança, com sessão autenticada disponível.
        mensagem =
            "🚨 SOS DE EMERGÊNCIA!\n" +
            `Localização: ${localizacaoTexto}`;
      } else {
        // TIPO_SOS_FISICO_FOTO — P2 da sequência unificada: foto já
        // enviada ao Firebase Storage, `fotoUrl` é um link (com token de
        // acesso) para visualização direta, sem exigir login no app.
        const fotoUrl = alerta.fotoUrl || "";
        mensagem =
            "📷 EVIDÊNCIA FOTOGRÁFICA registrada durante o SOS!\n" +
            `Foto: ${fotoUrl}\n` +
            `Localização: ${localizacaoTexto}`;
      }

      if (contatos.length === 0) {
        logger.warn(
            `Usuário ${usuarioId} não possui contatos de emergência ` +
            "sincronizados no Firestore — nenhum alerta será disparado.",
        );
      } else {
        await dispararAlertaHibrido({
          usuarioId,
          contatos,
          mensagem,
          // `alerta.origem`, quando informado (ver SosDisparoService no
          // app), é mais específico que `alerta.tipo` para fins de
          // log/telemetria (ex: distingue botão físico de SOS manual,
          // mesmo os dois usando `tipo: "sos_fisico"`).
          origem: alerta.origem || alerta.tipo,
          fotoUrl: alerta.tipo === TIPO_SOS_FISICO_FOTO ? alerta.fotoUrl : undefined,
          // Coordenadas ESTRUTURADAS (além de já estarem embutidas como
          // texto em `mensagem`) — o app do guardião usa isso para
          // habilitar o botão "Ver no Mapa" sem precisar fazer parsing
          // de texto livre (ver NotificacaoService/AlertaRecebidoScreen).
          latitude: typeof latitude === "number" ? latitude : undefined,
          longitude: typeof longitude === "number" ? longitude : undefined,
        });
      }

      await snap.ref.update({
        processado: true,
        processadoEm: new Date().toISOString(),
        localizacaoUsadaNoAlerta: localizacaoTexto,
        totalContatosNotificados: contatos.length,
      });
    },
);

// Monitoramento agendado (heartbeat & cloud alert) — ver
// scheduledAlarmMonitor.js para o fluxo completo e o modelo de dados da
// coleção `alarmes_agendados`. Reaproveita o mesmo `initializeApp()`
// já chamado acima nesta mesma inicialização do processo.
exports.monitorarAlarmesAgendados =
  require("./scheduledAlarmMonitor").monitorarAlarmesAgendados;

// Motor de retentativa progressiva do alerta híbrido (ver
// entregaRetryEngine.js): reenvia o Push por CONTATO individual a cada
// 1/2/5/10 min (conforme o tempo decorrido) por até 48h, até confirmação
// de entrega (ACK) ou expiração — que aciona relatorioFalhaService.js.
exports.monitorarRetentativasEntrega =
  require("./entregaRetryEngine").monitorarRetentativasEntrega;

// Aba Monitoramento (ver monitoramentoService.js): permissão bilateral e
// explícita de compartilhamento de localização GPS em tempo real,
// totalmente independente do pipeline de alerta de emergência acima.
// - Callable acionada pelo botão "Solicitar Localização" no app.
const monitoramentoService = require("./monitoramentoService");
exports.solicitarMonitoramento = monitoramentoService.solicitarMonitoramento;
// - Trigger que notifica o solicitante quando o alvo aprova/nega/bloqueia.
exports.aoAtualizarPermissaoMonitoramento =
  monitoramentoService.aoAtualizarPermissaoMonitoramento;
// - Callable acionada pelo Switch de pré-autorização em cada card da
// lista "Localização de familiares" (concede/bloqueia diretamente, sem
// esperar uma solicitação prévia do contato).
exports.definirPermissaoCompartilhamento =
  monitoramentoService.definirPermissaoCompartilhamento;
// - Callable acionada pelo slider de bloquear/desbloquear de cada card
// (ou pelo botão rápido "Bloquear" no modal de decisão) — impede que o
// contato envie NOVAS solicitações, eixo independente do status de
// compartilhamento acima.
exports.definirBloqueioSolicitante =
  monitoramentoService.definirBloqueioSolicitante;
// - Job agendado (regra das 24h) que expira solicitações pendentes sem
// resposta (ver monitoramentoExpiracaoMonitor.js).
exports.monitorarExpiracaoMonitoramento =
  require("./monitoramentoExpiracaoMonitor").monitorarExpiracaoMonitoramento;

// Configurações > Minha Conta > Excluir Conta e Dados (ver
// exclusaoContaService.js): apaga Firestore + o registro no Firebase
// Authentication do usuário autenticado, com Admin SDK (única forma de
// contornar tanto `firestore.rules` — que nega `delete` ao cliente de
// propósito — quanto a exigência de reautenticação recente do SDK
// cliente do Auth). Histórico de alertas/fotos NÃO é apagado aqui — ver
// retenção de 30 dias logo abaixo.
exports.excluirContaCompleta =
  require("./exclusaoContaService").excluirContaCompleta;

// Job agendado (retenção de 30 dias, pedido explícito do usuário,
// 2026-09-04): purga definitivamente o histórico de alertas/localizações/
// fotografias das contas excluídas há mais de 30 dias — ver
// retencaoAlertasService.js.
exports.purgarHistoricoRetidoAposExclusao =
  require("./retencaoAlertasService").purgarHistoricoRetidoAposExclusao;

// Unicidade estrita de telefone SEM SMS OTP (decisão de arquitetura
// 2026-08-23 — remoção do Firebase Phone Auth para zerar custo de SMS,
// mantendo o motor de segurança via checagem server-side em vez de prova
// de posse; ver telefonePerfilService.js).
exports.atualizarTelefonePerfil =
  require("./telefonePerfilService").atualizarTelefonePerfil;

// Revogação de sessões em outros aparelhos após login num aparelho novo
// (perda/troca de celular, pedido do usuário 2026-09-06) — baseada
// exclusivamente no UID autenticado do chamador, nunca em número de
// telefone (ver sessaoDispositivoService.js).
exports.revogarSessoesEmOutrosDispositivos =
  require("./sessaoDispositivoService").revogarSessoesEmOutrosDispositivos;

// Ciclo recorrente de 30 dias do Plano Free (10 dias ativos + 20 dias
// bloqueados, ver planoCicloService.js) — Admin SDK é a ÚNICA forma de
// gravar `isPremium`/`cycleStartDate`/`blockedAt` em `usuarios/{uid}`
// (ver `firestore.rules`, que bloqueia essa escrita vinda do cliente).
const planoCicloService = require("./planoCicloService");
// - Callable chamada pelo app uma vez por sessão (ver
// PlanoCicloService.iniciar): inicializa o ciclo no primeiro login e
// renova automaticamente ao completar 30 dias.
exports.sincronizarCicloPlano = planoCicloService.sincronizarCicloPlano;
// - Callable do botão "Cancelar Plano Premium" (self-downgrade apenas).
exports.cancelarPremiumDoProprioUsuario =
  planoCicloService.cancelarPremiumDoProprioUsuario;

// Chat de Suporte Interno com IA (decisão de arquitetura 2026-08-24,
// substitui a Central de Atendimento via WhatsApp) — ver
// suporteChatService.js e suporteConhecimentoBase.js.
const suporteChatService = require("./suporteChatService");
// - Trigger: responde automaticamente toda pergunta do usuário via
// Claude (Sonnet 5), com prompt caching na base de conhecimento e
// handoff pra atendente humano quando necessário.
exports.aoReceberMensagemSuporte = suporteChatService.aoReceberMensagemSuporte;
// - Callable do botão "Falar com atendente" (escalonamento manual,
// determinístico).
exports.solicitarAtendenteHumano = suporteChatService.solicitarAtendenteHumano;
// - Callables do Painel de Atendimento (Admin, módulo Tickets/M2) —
// exigem a custom claim `role` em ["atendente", "supervisor", "admin"].
exports.responderComoAtendente = suporteChatService.responderComoAtendente;
exports.encerrarTicketSuporte = suporteChatService.encerrarTicketSuporte;
// - Resumo seguro (nome/email/telefone) de quem abriu o ticket, sem
// expor o documento completo de `usuarios/{uid}` (ver
// suporteChatService.js).
exports.obterResumoUsuarioSuporte = suporteChatService.obterResumoUsuarioSuporte;

// Monitoramento de Alertas do Painel de Admin (M3) — ver
// alertaMonitoramentoService.js. Exige role "supervisor"/"admin".
const alertaMonitoramentoService = require("./alertaMonitoramentoService");
exports.listarAlertasMonitoramento =
  alertaMonitoramentoService.listarAlertasMonitoramento;
exports.encerrarAlertaMonitoramento =
  alertaMonitoramentoService.encerrarAlertaMonitoramento;

// Gestão de Planos do Painel de Admin (M3) — ver planoAdminService.js.
// Exige role "admin". Nunca concede Premium (só visualiza/revoga).
const planoAdminService = require("./planoAdminService");
exports.obterParametrosPlanos = planoAdminService.obterParametrosPlanos;
exports.buscarUsuarioPlano = planoAdminService.buscarUsuarioPlano;
exports.revogarPremiumAdmin = planoAdminService.revogarPremiumAdmin;

// Validação real de compra do Plano Premium via Google Play Billing —
// ver premiumPurchaseService.js. Esta é a ÚNICA forma automática (não
// manual) de conceder `isPremium: true`.
const premiumPurchaseService = require("./premiumPurchaseService");
// - Callable chamada pelo purchaseStream do app assim que uma compra é
// entregue (ver PremiumPurchaseService.comprarPremium no Flutter).
exports.validarCompraPremium = premiumPurchaseService.validarCompraPremium;
// - Job diário: revoga automaticamente o Premium de quem cancelou/deixou
// expirar a assinatura real (rede de segurança sem RTDN, ver
// documentação no topo do arquivo).
exports.reverificarAssinaturasPremium =
  premiumPurchaseService.reverificarAssinaturasPremium;
// - Reconciliação MANUAL (admin) de uma compra que falhou por problema de
// infraestrutura (não de fraude) — roda a MESMA verificação real contra a
// Play Store de `validarCompraPremium`, nunca um atalho sem ela. Exige
// role "admin".
exports.reconciliarCompraPremiumAdmin =
  premiumPurchaseService.reconciliarCompraPremiumAdmin;

// Revogação de token do Sign in with Apple na exclusão de conta —
// Guideline 4.8 da App Store, achado no checklist final da migração iOS
// (2026-09-12) — ver appleSignInService.js.
const appleSignInService = require("./appleSignInService");
// - Callable chamada logo após CADA login bem-sucedido via Apple (ver
// SocialAuthService.signInWithApple no Flutter) — troca o
// authorizationCode por um refresh_token e o guarda para uso futuro.
exports.registrarAutorizacaoApple = appleSignInService.registrarAutorizacaoApple;

// Encurtador de link próprio para o SMS da foto do SOS — ver
// fotoSosLinkService.js (correção do bug real de SMS multi-parte não
// entregue, confirmado em teste físico em 2026-09-06).
const fotoSosLinkService = require("./fotoSosLinkService");
// - Callable chamada pelo app (SosDisparoService) logo após o upload da
// foto ao Storage, antes de montar o SMS.
exports.criarLinkCurtoFoto = fotoSosLinkService.criarLinkCurtoFoto;
// - Rota pública (via rewrite "/f/**" do Hosting, ver firebase.json) que
// resolve o link curto e redireciona para a foto real no Storage.
exports.abrirFotoSos = fotoSosLinkService.abrirFotoSos;
