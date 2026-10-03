package com.example.security_check_app

import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Nome do canal dedicado ao fluxo de "acordar a tela" para solicitações de
 * monitoramento recebidas via FCM — ver [SolicitacaoMonitoramentoWakeService]/
 * [SolicitacaoMonitoramentoFcmReceiver] no lado nativo e `NotificacaoService`
 * no lado Dart. */
private const val CANAL_SOLICITACAO_MONITORAMENTO =
    "com.example.security_check_app/solicitacao_monitoramento"

/** Canal dedicado a consultas NATIVAS e 100% silenciosas de permissões que
 * não têm equivalente síncrono/sem-navegação nos plugins Flutter em uso
 * (ver [podeUsarTelaCheiaNativo] — `NotificacaoService.podeUsarTelaCheia`
 * no lado Dart). */
private const val CANAL_PERMISSOES_NATIVAS =
    "com.example.security_check_app/permissoes_nativas"

// FlutterFragmentActivity (não FlutterActivity): exigido pelo local_auth
// (bloqueio local do app com biometria, ver BloqueioAppService no Dart).
open class MainActivity: FlutterFragmentActivity() {

    private var canalSolicitacaoMonitoramento: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Mantém o registro dos plugins essenciais
        flutterEngine.plugins.add(SmsSender())
        flutterEngine.plugins.add(VolumeSosPlugin())
        flutterEngine.plugins.add(LockscreenPlugin())
        flutterEngine.plugins.add(RotinaAlarmPlugin())
        flutterEngine.plugins.add(DeviceAdminPlugin())
        flutterEngine.plugins.add(SosDispatchPlugin())
        flutterEngine.plugins.add(AlertaRecebidoAlarmPlugin())

        // ATENÇÃO — NÃO registre aqui um MethodChannel manual no canal
        // "com.example.security_check_app/rotina_alarme": esse canal já
        // é de propriedade do [RotinaAlarmPlugin] (registrado logo acima).
        // Um `MethodChannel(...).setMethodCallHandler{...}` manual no
        // MESMO nome de canal, se chamado DEPOIS de
        // `flutterEngine.plugins.add(RotinaAlarmPlugin())`, SOBRESCREVE
        // silenciosamente o handler do plugin — foi exatamente esse bug
        // (código legado, já removido) que fazia com que
        // "pararAlarme"/"pausarAlarme"/"reiniciarSomSeAtivo" nunca
        // chegassem à implementação real (RotinaAlarmSomBridge.pararSom(),
        // fecharActivityAtiva(), etc.) sempre que o app rodava dentro
        // desta Activity ou de RotinaCheckinAlarmActivity (que a estende).

        // "obterPayloadPendente": chamado UMA VEZ pelo Dart logo no
        // startup (mesmo padrão de getNotificationAppLaunchDetails) para
        // resgatar os extras de um COLD START via
        // SolicitacaoMonitoramentoWakeService. "solicitacaoRecebida" é
        // invocado NATIVO->DART em [onNewIntent], quando o Intent chega
        // com o engine já rodando (app em primeiro/segundo plano).
        val canal = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CANAL_SOLICITACAO_MONITORAMENTO)
        canal.setMethodCallHandler { call, result ->
            if (call.method == "obterPayloadPendente") {
                result.success(extrairPayloadSolicitacao(intent, limpar = true))
            } else {
                result.notImplemented()
            }
        }
        canalSolicitacaoMonitoramento = canal

        // BUG REAL CORRIGIDO (relatado pelo usuário em teste físico,
        // 2026-08-16): a tela "Status de Permissões" mostrava "Alertas em
        // tela cheia" como Concedida logo após tocar em "Conceder", mas
        // voltava a "Pendente" ao reabrir a tela ou reiniciar o app — o
        // Dart nunca tinha como reconsultar o status real dessa permissão
        // (`flutter_local_notifications` só expõe `request...()`, que
        // pede/navega, nunca uma checagem silenciosa isolada). Este canal
        // consulta a API nativa do Android diretamente
        // (`NotificationManager.canUseFullScreenIntent()`, só existe a
        // partir da API 34/Android 14), sem qualquer navegação/prompt.
        val canalPermissoes =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CANAL_PERMISSOES_NATIVAS)
        canalPermissoes.setMethodCallHandler { call, result ->
            if (call.method == "podeUsarTelaCheia") {
                result.success(podeUsarTelaCheiaNativo())
            } else {
                result.notImplemented()
            }
        }
    }

    /** Checagem 100% silenciosa (sem navegar para Configurações nem
     * exibir nenhum prompt) de `USE_FULL_SCREEN_INTENT`. Em versões
     * anteriores ao Android 14 essa restrição nem existe — a permissão é
     * implicitamente concedida a qualquer app, então sempre retorna
     * `true` nesse caso (mesmo fallback permissivo já usado no restante
     * do app para versões antigas do Android). */
    private fun podeUsarTelaCheiaNativo(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val manager = getSystemService(NotificationManager::class.java) ?: return true
        return manager.canUseFullScreenIntent()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tratarIntentDeAlertaRecebido(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = extrairPayloadSolicitacao(intent, limpar = true)
        if (payload != null) {
            canalSolicitacaoMonitoramento?.invokeMethod("solicitacaoRecebida", payload)
        }
        tratarIntentDeAlertaRecebido(intent)
    }

    /** Modo "Despertador de Emergência" (item 4 do pedido): se este
     * Intent veio do toque no corpo da notificação de controle do alarme
     * sonoro (ver [AlertaRecebidoAlarmService.EXTRA_PARAR_AO_ABRIR]),
     * silencia o alarme IMEDIATAMENTE — nativo, sem depender do lado
     * Dart (o engine pode ainda estar subindo, num cold start). */
    private fun tratarIntentDeAlertaRecebido(intent: Intent?) {
        if (intent?.getBooleanExtra(AlertaRecebidoAlarmService.EXTRA_PARAR_AO_ABRIR, false) == true) {
            AlertaRecebidoAlarmPlugin.pararAlarme(applicationContext)
        }
    }

    /** Lê (e opcionalmente limpa, para não reprocessar a mesma solicitação
     * numa navegação/rotação subsequente) os extras deixados pelo
     * [SolicitacaoMonitoramentoWakeService] no Intent que abriu/reabriu
     * esta Activity. Retorna `null` se não houver nenhuma solicitação
     * pendente nesse Intent. */
    private fun extrairPayloadSolicitacao(intent: Intent?, limpar: Boolean): Map<String, String>? {
        val idPermissao = intent?.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_ID_PERMISSAO)
            ?: return null
        val payload = mapOf(
            "idPermissao" to idPermissao,
            "uidSolicitante" to (intent.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_UID_SOLICITANTE) ?: ""),
            "nomeSolicitante" to (intent.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_NOME_SOLICITANTE) ?: ""),
            "telefoneSolicitante" to (intent.getStringExtra(SolicitacaoMonitoramentoWakeService.EXTRA_TELEFONE_SOLICITANTE) ?: ""),
        )
        if (limpar) {
            intent?.removeExtra(SolicitacaoMonitoramentoWakeService.EXTRA_ID_PERMISSAO)
        }
        return payload
    }
}