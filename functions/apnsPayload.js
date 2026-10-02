/**
 * Blocos `apns` (iOS) compartilhados por TODOS os pontos de envio de Push
 * das Cloud Functions.
 *
 * Por que existe (bug real, primeiro teste no iPhone, build 104): todo
 * Push deste projeto é DATA-ONLY (só `data` + `android.priority`) — no
 * Android isso é o desejado (o app monta a própria notificação de tela
 * cheia, ver `enviarFcmParaContatos`), mas no iOS uma mensagem data-only
 * sem bloco `apns` vira um push silencioso de baixa prioridade que o
 * sistema NÃO exibe com o app fechado/em segundo plano (e frequentemente
 * nem entrega). O bloco `apns` é ignorado pelo Android, então o
 * comportamento lá continua idêntico.
 *
 * A TRAVA DE RECEBIMENTO do Plano Free (ver `resolverContasPorTelefone`)
 * continua valendo sem nenhuma mudança: o bloco `apns` só é anexado a uma
 * Message que já tem token — destinatário bloqueado não tem token
 * resolvido, logo nenhuma Message (nem Android, nem iOS) é montada.
 */

/** `apns-collapse-id` aceita no máximo 64 bytes. */
const LIMITE_COLLAPSE_ID = 64;

/**
 * Push VISÍVEL no iOS (banner + som), com `content-available` para o app
 * também acordar em segundo plano e gravar a confirmação de entrega.
 *
 * [collapseId] (opcional): Pushes com o mesmo id SUBSTITUEM o anterior na
 * Central de Notificações em vez de empilhar — usado pelo motor de
 * retentativa (`entregaRetryEngine.js`), que reenvia o MESMO alerta a
 * cada 1 min até o ACK.
 *
 * @param {{titulo: string, corpo: string, collapseId?: string, timeSensitive?: boolean}} params
 * @return {Object}
 */
function montarApnsAlerta({titulo, corpo, collapseId, timeSensitive = true}) {
  const headers = {
    "apns-priority": "10",
    "apns-push-type": "alert",
  };
  if (collapseId) {
    headers["apns-collapse-id"] = String(collapseId).slice(0, LIMITE_COLLAPSE_ID);
  }

  const aps = {
    "alert": {title: titulo || "", body: corpo || ""},
    "sound": "default",
    "content-available": 1,
  };
  if (timeSensitive) aps["interruption-level"] = "time-sensitive";

  return {headers, payload: {aps}};
}

/**
 * Push SILENCIOSO (background) no iOS — só acorda o app para processar o
 * `data`, sem exibir nada. Usado no nudge do relatório de falha de 48h
 * (`relatorioFalhaService.js`), que é silencioso por definição também no
 * Android. A Apple exige `apns-priority: 5` para `apns-push-type:
 * background`.
 *
 * @return {Object}
 */
function montarApnsSilencioso() {
  return {
    headers: {
      "apns-priority": "5",
      "apns-push-type": "background",
    },
    payload: {aps: {"content-available": 1}},
  };
}

module.exports = {montarApnsAlerta, montarApnsSilencioso};
