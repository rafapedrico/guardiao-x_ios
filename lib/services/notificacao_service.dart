import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../app_navigator.dart'; // <--- O IMPORT CORRETO AQUI
import '../firebase_options.dart';
import '../screens/alarme_disparado_screen.dart';
import '../screens/alerta_recebido_screen.dart';
import '../screens/home_screen.dart';
import '../widgets/monitoramento_decisao_dialog.dart';
import 'database_helper.dart';
import 'cronometro_ios_service.dart';
import 'despertador_ios_service.dart';
import 'firebase_auth_service.dart';
import 'l10n_headless_service.dart';
import 'monitoramento_service.dart';
import 'rotina_alarme_service.dart';

/// Wrapper central do plugin `flutter_local_notifications`, responsável
/// por inicializar, exibir e cancelar as notificações locais de check-in
/// de rotina (Etapa 3), incluindo o tratamento da ação rápida
/// "✅ Cheguei bem" tanto em primeiro plano quanto em segundo
/// plano/headless (app fechado).
///
/// Mantido como uma classe de métodos estáticos (sem estado próprio),
/// já que precisa ser chamado tanto pelo main.dart normal quanto pelo
/// callback headless de [RotinaAlarmeService], que roda em um
/// FlutterEngine separado sem nenhum estado em memória compartilhado.
class NotificacaoService {
  NotificacaoService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// Id do canal Android usado exclusivamente para as notificações de
  /// check-in de rotina.
  static const String canalId = 'checkin_rotina';
  // Nomes/descrições de canal traduzidos via [AppLocalizations] — não
  // podem mais ser `const`, pois dependem do idioma ativo do usuário
  // (carregados uma vez em [inicializar] via [_carregarNomesCanaisLocalizados]).
  // Mantêm um valor padrão em português apenas como fallback antes da
  // primeira inicialização.
  static String canalNome = 'Check-in de Rotina';
  static String canalDescricao =
      'Lembretes de check-in de segurança dos alarmes de rotina cadastrados.';

  /// Canal Android dedicado ao Push App-para-App recebido via FCM (ver
  /// [FcmService]) — alerta de emergência de OUTRO usuário que cadastrou
  /// este aparelho como contato de emergência. Separado do canal de
  /// check-in de rotina para que o usuário possa configurar volume/som
  /// de forma independente para cada tipo de alerta.
  /// BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, via
  /// `dumpsys notification`): o Android trava as configurações de ÁUDIO
  /// de um canal (`audioAttributesUsage`, som) no momento em que ele é
  /// criado pela PRIMEIRA vez — o mecanismo de "deletar e recriar" usado
  /// para migrar canais já existentes (ver [inicializar]) se mostrou NÃO
  /// confiável na prática: mesmo depois de rodar, um aparelho de teste
  /// real continuou mostrando `usage=USAGE_NOTIFICATION` (som padrão do
  /// sistema) em vez de `USAGE_ALARM` no canal deste alerta —
  /// silenciosamente incapaz de furar o modo Silencioso/Não Perturbe, o
  /// PRÓPRIO objetivo do ajuste "Despertador de Emergência". Trocar o ID
  /// do canal é a forma robusta/padrão de resolver isso: um ID NOVO
  /// nunca existiu antes, então o Android o cria do zero, com as
  /// configurações corretas, sem depender de deletar+recriar
  /// funcionar de forma confiável em 100% dos aparelhos/versões do
  /// Android. Quem já tinha o app instalado ganha automaticamente o novo
  /// canal (com as configurações certas) na próxima vez que este método
  /// rodar — o canal antigo `alerta_emergencia_recebido` fica órfão,
  /// inofensivo, e pode ser removido manualmente pelo usuário em
  /// Configurações do Android se desejar (não reaparece).
  /// CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-16, Moto G7
  /// Play, via `dumpsys notification` ao vivo): incrementar SÓ a flag de
  /// migração (`_chaveCanaisMigrados`, delete+recreate do MESMO id) não
  /// foi suficiente para desativar `enableVibration` em instalações que
  /// já tinham este canal — `dumpsys notification` continuou mostrando
  /// `mVibrationEnabled=true` mesmo minutos depois da migração ter
  /// rodado (confirmado sem nenhuma exceção nos logs). Suspeita: uma
  /// corrida no lado nativo do Android entre `deleteNotificationChannel`
  /// (processado de forma assíncrona pelo `system_server`) e o
  /// `createNotificationChannel` seguinte, chamados em sequência rápida
  /// demais para o MESMO id. Em vez de depurar essa corrida a fundo,
  /// aplicada a MESMA solução definitiva já usada da `_v1` pra `_v2`
  /// (2026-08-15): um id de canal NOVO, que nunca existiu neste
  /// aparelho — sem migração alguma envolvida, `createNotificationChannel`
  /// aplica as configurações (agora com `enableVibration: false`) sem
  /// ambiguidade nenhuma.
  static const String canalAlertaRecebidoId = 'alerta_emergencia_recebido_v3';
  static String canalAlertaRecebidoNome = 'Alerta de Emergência Recebido';
  static String canalAlertaRecebidoDescricao =
      'Alertas de segurança de contatos que cadastraram este aparelho como emergência.';

  /// Canal Android dedicado às RESPOSTAS de push da aba Monitoramento
  /// (aprovada, recusada, bloqueada ou expirada — ver [FcmService] e
  /// `functions/monitoramentoService.js`). Notificações NORMAIS (sem tela
  /// cheia, sem som/vibração persistentes) — são só informativas, sobre uma
  /// solicitação que o PRÓPRIO usuário enviou. Deliberadamente SEPARADO de
  /// [canalSolicitacaoMonitoramentoId] abaixo, que é o único que precisa de
  /// urgência máxima (é o único que exige uma DECISÃO do usuário).
  static const String canalMonitoramentoId = 'monitoramento';
  static String canalMonitoramentoNome = 'Monitoramento de Localização';
  static String canalMonitoramentoDescricao =
      'Respostas a solicitações de compartilhamento de localização enviadas pela aba Monitoramento.';

  /// Canal Android dedicado à SOLICITAÇÃO de localização recebida (tipo
  /// `'solicitacao_monitoramento'`, ver [FcmService]) — o único evento da
  /// aba Monitoramento que exige uma decisão explícita do usuário
  /// (Aceitar/Recusar). Importância MÁXIMA + `fullScreenIntent` (mesmo
  /// padrão de [canalAlertaRecebidoId]/[exibirNotificacaoAlertaRecebido]):
  /// com o aparelho bloqueado, "acorda" a tela e abre por cima da
  /// lockscreen, estilo chamada recebida — em vez de só aparecer
  /// silenciosamente na bandeja como as respostas informativas acima.
  static const String canalSolicitacaoMonitoramentoId = 'solicitacao_monitoramento';
  static String canalSolicitacaoMonitoramentoNome =
      'Solicitação de Localização Recebida';
  static String canalSolicitacaoMonitoramentoDescricao =
      'Alerta prioritário quando um familiar solicita ver sua localização em tempo real — exige Aceitar ou Recusar.';

  /// Canal Android dedicado à confirmação de envio exibida DEPOIS do
  /// gesto de descarte (arrastar o botão azul/teclado de PIN para cima —
  /// ver `AlarmeDisparadoScreen._descartarPorArraste`): como a
  /// especificação exige que a tela/Activity do alarme feche IMEDIATAMENTE
  /// (controle 100% devolvido ao Android) assim que o gesto é detectado,
  /// não há mais nenhuma UI do app na tela para mostrar um diálogo
  /// in-app — a confirmação "mensagem enviada" precisa ser uma
  /// notificação do sistema. Importância baixa e sem som/vibração
  /// (o alarme já foi silenciado por este mesmo fluxo): é só uma
  /// confirmação informativa, não um novo alarme.
  static const String canalAlertaEnviadoId = 'alerta_enviado_confirmacao';
  static String canalAlertaEnviadoNome = 'Confirmação de Alerta Enviado';
  static String canalAlertaEnviadoDescricao =
      'Confirma que um alerta de emergência com localização foi enviado para os contatos cadastrados.';

  /// Carrega os nomes/descrições dos 4 canais Android no idioma
  /// atualmente selecionado pelo usuário (ver [L10nHeadlessService]),
  /// chamado uma única vez no início de [inicializar] — antes da criação
  /// efetiva dos canais logo abaixo.
  static Future<void> _carregarNomesCanaisLocalizados() async {
    try {
      final l10n = await L10nHeadlessService.obter();
      canalNome = l10n.notifCanalCheckinNome;
      canalDescricao = l10n.notifCanalCheckinDescricao;
      canalAlertaRecebidoNome = l10n.notifCanalAlertaRecebidoNome;
      canalAlertaRecebidoDescricao = l10n.notifCanalAlertaRecebidoDescricao;
      canalMonitoramentoNome = l10n.notifCanalMonitoramentoNome;
      canalMonitoramentoDescricao = l10n.notifCanalMonitoramentoDescricao;
      canalSolicitacaoMonitoramentoNome = l10n.notifCanalSolicitacaoMonitoramentoNome;
      canalSolicitacaoMonitoramentoDescricao =
          l10n.notifCanalSolicitacaoMonitoramentoDescricao;
      _labelAcaoAceitarMonitoramento = l10n.notifMonitAcaoAceitar;
      _labelAcaoRecusarMonitoramento = l10n.notifMonitAcaoRecusar;
      _labelAcaoPausarAlarme = l10n.notifPausarAlarmeAcao;
      _labelAcaoDesativarDespertador = l10n.despertadorDesativarAcao;
      _labelAcaoDesligarCronometro = l10n.cronometroAcaoDesligar;
      canalAlertaEnviadoNome = l10n.notifCanalAlertaEnviadoNome;
      canalAlertaEnviadoDescricao = l10n.notifCanalAlertaEnviadoDescricao;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao localizar nomes de canais: $e');
    }
  }

  /// Id da ação rápida "Cheguei bem" exibida na notificação.
  static const String acaoConfirmarId = 'confirmar_checkin_rotina';

  /// Ids das ações rápidas [Aceitar]/[Recusar] da notificação de
  /// solicitação de localização (ver [exibirNotificacaoMonitoramento] e
  /// [_processarRespostaPayloadJson]) — pedido explícito do usuário
  /// (2026-09-06): a decisão fica disponível direto na bandeja de
  /// notificações, sem precisar abrir o modal de confirmação.
  static const String acaoAceitarMonitoramentoId = 'aceitar_monitoramento';
  static const String acaoRecusarMonitoramentoId = 'recusar_monitoramento';
  static String _labelAcaoAceitarMonitoramento = 'Aceitar';
  static String _labelAcaoRecusarMonitoramento = 'Recusar';

  /// Label da ação "pausar_alarme" (ver [exibirNotificacaoAlarmeCompleto])
  /// — no Android é passado direto por [AndroidNotificationAction] a cada
  /// chamada de `show`; no iOS precisa estar pré-registrado como
  /// [DarwinNotificationCategory] em [inicializar] (categorias do iOS são
  /// fixas, definidas uma única vez, ao contrário das ações do Android),
  /// por isso carregado aqui como campo estático junto com os demais.
  static String _labelAcaoPausarAlarme = 'Pausar';

  /// Ação "Desativar despertador" das notificações do despertador do iOS
  /// (ver [agendarNotificacaoDespertador]): abre o app na tela do
  /// despertador, com o teclado do PIN.
  static String _labelAcaoDesativarDespertador = 'Desativar despertador';
  static const String categoriaIosDespertador = 'despertador';
  static const String categoriaIosCronometro = 'cronometro';
  static const String acaoDesligarCronometroId = 'desligar_cronometro';
  static String _labelAcaoDesligarCronometro = 'Desligar alerta de emergência';
  static const String acaoDesativarDespertadorId = 'desativar_despertador';

  /// Payload `despertador:<idAlarme>:<ciclo>` de uma notificação do
  /// despertador que abriu o app num cold start — consumido por `main.dart`
  /// via [consumirDespertadorPendente].
  static String? despertadorPendente;

  static String? consumirDespertadorPendente() {
    final payload = despertadorPendente;
    despertadorPendente = null;
    return payload;
  }

  /// Ids das categorias de notificação do iOS ([DarwinNotificationCategory])
  /// — equivalente ao "canal" do Android só no sentido de agrupar as
  /// ações disponíveis; sem efeito em som/vibração (isso o iOS resolve só
  /// pela [DarwinNotificationDetails.interruptionLevel] de cada notificação
  /// individual, ver cada `exibirNotificacao*` abaixo).
  static const String _categoriaIosAlarmeCompleto = 'alarme_completo';
  static const String _categoriaIosSolicitacaoMonitoramento =
      'solicitacao_monitoramento';

  static bool _inicializado = false;

  /// Chave em disco (sobrevive entre isolates, ao contrário de
  /// [_inicializado]) que marca se a migração ÚNICA de canais antigos
  /// (deletar + recriar) já rodou nesta instalação — ver [inicializar].
  /// Incrementada para `_v2` (2026-08-16): força a migração rodar de
  /// novo mesmo em instalações que já tinham passado pela `_v1`,
  /// necessário para o canal `alerta_emergencia_recebido_v2` (já
  /// existente nesses aparelhos, com vibração habilitada) ser recriado
  /// com a vibração desativada — ver [exibirNotificacaoAlertaRecebido].
  static const String _chaveCanaisMigrados =
      'notificacao_canais_migrados_v2';

  /// Payload de uma notificação de SOLICITAÇÃO ('solicitacao_monitoramento')
  /// recebida antes de existir uma sessão autenticada — capturado tanto no
  /// cold start (ver [inicializar]/[_capturarPayloadSolicitacaoPendente])
  /// quanto por um toque com o app já rodando mas ainda sem login (ver
  /// [_processarRespostaPayloadJson]). NUNCA usado para pular a barreira de
  /// login: é só guardado aqui até a [LoginScreen] concluir um login com
  /// sucesso e consumi-lo via [consumirPayloadSolicitacaoPendente], abrindo
  /// o modal de decisão direto em vez da Home normal.
  static Map<String, dynamic>? payloadSolicitacaoPendente;

  /// Payload de um alerta de emergência RECEBIDO de outro usuário (tipo
  /// `'alerta_recebido'`, ver [exibirNotificacaoAlertaRecebido]) capturado
  /// num COLD START via toque nesta notificação (app 100% fechado) —
  /// mesma mecânica de [payloadSolicitacaoPendente], mas com um
  /// tratamento DIFERENTE e deliberado: reespecificação do usuário
  /// (2026-08-14) exige que o usuário NUNCA precise logar para ver a
  /// mensagem/localização de um alerta recebido. Por isso este payload é
  /// consumido em `main.dart` (ver `_inicializarNotificacoesEAbrirAlertaPendente`)
  /// para pular a barreira de login e abrir [AlertaRecebidoScreen] direto
  /// — ao contrário de [payloadSolicitacaoPendente], que é sempre
  /// guardado até um login de verdade acontecer.
  static Map<String, dynamic>? payloadAlertaRecebidoPendente;

  /// Id do alarme de rotina (`idAlarme`, ver [exibirNotificacaoCheckin]/
  /// [agendarLembretesCheckinRotinaIOS]) cuja notificação de check-in foi
  /// tocada num COLD START (app 100% fechado) — capturado em
  /// [inicializar] via `getNotificationAppLaunchDetails()`.
  ///
  /// ACHADO NA AUDITORIA PÓS-FASE 4 (2026-09-12): sem isto, o toque a
  /// frio nessa notificação nunca era tratado — nem no Android nem no
  /// iOS — porque [_capturarPayloadSolicitacaoPendente] só reconhecia
  /// payloads JSON (`{...}`), e o payload do check-in é só o
  /// `idAlarme` cru (ou `alarme_<idAlarme>`, ver [_processarResposta]).
  /// No Android isso raramente importava (o caminho PRINCIPAL desse
  /// cold start é a `RotinaCheckinAlarmActivity` NATIVA, aberta
  /// diretamente pelo `RotinaAlarmWakeService`, sem passar por aqui) —
  /// mas no iOS, sem Activity nativa nenhuma, o toque nesta notificação
  /// é o ÚNICO caminho para o cold start, então o gap ficava muito mais
  /// exposto. Mesma política de [payloadAlertaRecebidoPendente]: pula a
  /// barreira de login (o PIN de confirmação é 100% local/SQLite, sem
  /// depender de sessão) — consumido em `main.dart`.
  static int? idAlarmeCheckinPendente;

  static void _capturarPayloadSolicitacaoPendente(String? payload, {String? actionId}) {
    if (payload == null) return;

    if (payload.startsWith(DespertadorIosService.prefixoPayload) ||
        payload.startsWith(CronometroIosService.prefixoPayload)) {
      despertadorPendente = payload;
      return;
    }

    if (!payload.startsWith('{')) {
      // Payload numérico (check-in) ou 'alarme_<id>' (janela final/alarme
      // completo) — mesmo parsing já usado por [_processarResposta].
      final idAlarme = int.tryParse(
          payload.startsWith('alarme_') ? payload.replaceFirst('alarme_', '') : payload);
      if (idAlarme != null) {
        idAlarmeCheckinPendente = idAlarme;
      }
      return;
    }

    try {
      final dados = jsonDecode(payload) as Map<String, dynamic>;
      if (dados['tipo'] == 'monitoramento_push' &&
          dados['subTipo'] == 'solicitacao_monitoramento') {
        // Cold start via toque numa das ações rápidas [Aceitar]/[Recusar]
        // (ver [acaoAceitarMonitoramentoId]/[acaoRecusarMonitoramentoId])
        // com o app 100% fechado: preserva qual ação foi tocada, para a
        // LoginScreen aplicar a MESMA decisão depois do login, em vez de
        // reabrir o modal por cima de uma escolha que o usuário já tinha
        // feito.
        payloadSolicitacaoPendente = {
          ...dados,
          if (actionId == acaoAceitarMonitoramentoId ||
              actionId == acaoRecusarMonitoramentoId)
            'acaoDireta': actionId,
        };
      } else if (dados['tipo'] == 'alerta_recebido') {
        payloadAlertaRecebidoPendente = dados;
      }
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao decodificar payload de lançamento: $e');
    }
  }

  /// Lê e limpa o [idAlarmeCheckinPendente] — chamado por `main.dart`
  /// junto com [consumirPayloadAlertaRecebidoPendente]. Devolve `null`
  /// no fluxo normal (cold start sem essa notificação envolvida).
  static int? consumirIdAlarmeCheckinPendente() {
    final id = idAlarmeCheckinPendente;
    idAlarmeCheckinPendente = null;
    return id;
  }

  /// Lê e limpa o payload pendente — chamado pela `LoginScreen` logo após
  /// um login bem-sucedido. Devolve `null` se não havia nenhuma solicitação
  /// pendente (fluxo normal, sem notificação envolvida).
  static Map<String, dynamic>? consumirPayloadSolicitacaoPendente() {
    final dados = payloadSolicitacaoPendente;
    payloadSolicitacaoPendente = null;
    return dados;
  }

  /// Lê e limpa o payload de alerta recebido pendente — chamado por
  /// `main.dart` logo após [inicializar] resolver, ANTES de qualquer
  /// LoginScreen aparecer (ver [payloadAlertaRecebidoPendente]). Devolve
  /// `null` no fluxo normal (cold start sem nenhuma notificação
  /// envolvida).
  static Map<String, dynamic>? consumirPayloadAlertaRecebidoPendente() {
    final dados = payloadAlertaRecebidoPendente;
    payloadAlertaRecebidoPendente = null;
    return dados;
  }

  /// Canal nativo dedicado ao fluxo de "acordar a tela" para solicitações
  /// de monitoramento (ver `SolicitacaoMonitoramentoWakeService`/
  /// `SolicitacaoMonitoramentoFcmReceiver`, no lado Kotlin, e
  /// `MainActivity.configureFlutterEngine`/`onNewIntent`, que registram
  /// este canal). `'obterPayloadPendente'` é chamado UMA VEZ por
  /// [inicializar] (mesmo padrão de `getNotificationAppLaunchDetails`)
  /// para resgatar os extras de um COLD START; `'solicitacaoRecebida'` é
  /// invocado NATIVO->DART quando o Intent chega com o engine já rodando
  /// (app em primeiro/segundo plano, via `onNewIntent`).
  ///
  /// **iOS:** sem handler nativo registrado — `invokeMapMethod` (chamado
  /// em [inicializar]) lança, já capturado e só logado como aviso;
  /// `setMethodCallHandler` (Dart escutando o nativo) simplesmente nunca
  /// é acionado, também sem risco. Nenhuma perda funcional real: este
  /// canal é só um ATALHO Android para "acordar a tela mais rápido" — o
  /// caminho PRINCIPAL e 100% cross-platform (`FirebaseMessaging.onMessage`/
  /// `onBackgroundMessage` em `FcmService._tratarPushMonitoramento`) já
  /// entrega a mesma solicitação de monitoramento no iOS normalmente.
  static const MethodChannel _canalSolicitacaoNativa =
      MethodChannel('com.example.security_check_app/solicitacao_monitoramento');

  /// Modo "Despertador de Emergência" (reespecificação do usuário,
  /// 2026-08-15) — ver `AlertaRecebidoAlarmService.kt`/
  /// `AlertaRecebidoAlarmPlugin.kt` para a implementação nativa completa
  /// (alarme sonoro em loop, volume máximo do STREAM_ALARM, desarme via
  /// notificação/toque/arraste). Usado por [exibirNotificacaoAlertaRecebido]
  /// (iniciar) e por `AlertaRecebidoScreen` (parar, ao abrir a tela ou
  /// tocar no link do mapa).
  ///
  /// **iOS:** sem handler nativo — [iniciarAlarmeCritico]/
  /// [pararAlarmeCritico] já capturam a falha e só logam aviso (nunca
  /// travam `AlertaRecebidoScreen`/a notificação de tela cheia). O único
  /// efeito real da ausência: o som toca uma única vez (via
  /// `DarwinNotificationDetails.interruptionLevel`, ver
  /// [exibirNotificacaoAlertaRecebido]) em vez do loop contínuo em volume
  /// máximo do Android — depende do entitlement de Critical Alerts
  /// (pendente, seção 5/6 do relatório de migração) para ter um
  /// equivalente real, não de reimplementar este canal em Swift.
  static const MethodChannel _canalAlertaRecebidoAlarme =
      MethodChannel('com.example.security_check_app/alerta_recebido_alarme');

  /// Canal dedicado a consultas nativas 100% silenciosas sem equivalente
  /// no `flutter_local_notifications`/`permission_handler` — ver
  /// [podeUsarTelaCheia] e `MainActivity.kt`.
  ///
  /// **iOS:** sem handler nativo — [podeUsarTelaCheia] já captura a
  /// falha e retorna `true` por padrão (permissivo), mesmo valor que já
  /// devolve em qualquer Android < 14. Não faz sentido registrar um
  /// equivalente Swift: `USE_FULL_SCREEN_INTENT` é um conceito
  /// exclusivamente Android (ver seção 3 do relatório de migração —
  /// nenhuma notificação local pode abrir uma tela por cima do bloqueio
  /// no iOS) — o card correspondente em `OnboardingScreen`/
  /// `PermissoesStatusScreen` precisa ser revisto na fase de adaptação
  /// de telas, não aqui.
  static const MethodChannel _canalPermissoesNativas =
      MethodChannel('com.example.security_check_app/permissoes_nativas');

  /// Inicia o alarme sonoro contínuo em volume máximo — chamado junto com
  /// a notificação de tela cheia em [exibirNotificacaoAlertaRecebido].
  /// Protegido: uma falha aqui (ex: `MissingPluginException` no engine
  /// headless do `firebase_messaging` com o app 100% fechado — ver
  /// documentação completa em `AlertaRecebidoAlarmService.kt`) NUNCA deve
  /// impedir a notificação de tela cheia (que já funciona nesse cenário)
  /// de aparecer.
  static Future<void> iniciarAlarmeCritico() async {
    try {
      await _canalAlertaRecebidoAlarme.invokeMethod('iniciarAlarme');
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao iniciar o Despertador de Emergência: $e');
    }
  }

  /// Para o alarme sonoro contínuo — chamado sempre que o usuário toma
  /// qualquer ação sobre o alerta recebido (abre a tela, toca no link do
  /// mapa etc., ver `AlertaRecebidoScreen`). Idempotente e seguro chamar
  /// mesmo se nenhum alarme estiver tocando.
  static Future<void> pararAlarmeCritico() async {
    try {
      await _canalAlertaRecebidoAlarme.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao parar o Despertador de Emergência: $e');
    }
  }

  /// Ids de permissão com o modal de decisão atualmente aberto — evita
  /// empilhar dois diálogos para a MESMA solicitação quando mais de um
  /// caminho (Intent nativo aqui, FCM em primeiro plano em [FcmService],
  /// toque na notificação) processa o mesmo evento quase ao mesmo tempo.
  static final Set<String> _idsComDialogoAbertoViaNativo = {};

  /// Ponto único de decisão para um payload de solicitação recebido pelo
  /// caminho nativo (`SolicitacaoMonitoramentoWakeService`): se já houver
  /// sessão autenticada e um `BuildContext` disponível, abre o modal de
  /// decisão DIRETO por cima da tela atual; caso contrário — cold start
  /// ainda na barreira de login — só guarda em [payloadSolicitacaoPendente]
  /// para a `LoginScreen` consumir depois. NUNCA pula a autenticação.
  static Future<void> _tratarPayloadSolicitacaoNativo(
    Map<String, dynamic> dados,
  ) async {
    final idPermissao = dados['idPermissao'] as String?;
    final uidSolicitante = dados['uidSolicitante'] as String?;
    if (idPermissao == null || uidSolicitante == null) return;

    // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06): TERCEIRA
    // via independente para a MESMA solicitação (além do listener da
    // `MonitoramentoTab` e do handler de FCM em primeiro plano) — ver
    // documentação completa em
    // [MonitoramentoService.marcarResolvidoDireto]/[foiResolvidoDireto].
    // Sem esta checagem, tocar [Aceitar]/[Recusar] direto na notificação
    // (que acorda a tela/traz o app à frente) corria contra este caminho
    // nativo (`SolicitacaoMonitoramentoWakeService`), que abria o MESMO
    // modal de decisão de novo por cima da escolha já feita. Uma pequena
    // espera ANTES da checagem dá tempo de sobra para a marcação (em
    // disco, cruza isolates) vencer essa corrida.
    await Future.delayed(const Duration(milliseconds: 600));
    if (await MonitoramentoService.foiResolvidoDireto(idPermissao)) return;

    final autenticado =
        Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;
    final context = appNavigatorKey.currentContext;

    if (autenticado && context != null) {
      if (_idsComDialogoAbertoViaNativo.contains(idPermissao)) return;
      _idsComDialogoAbertoViaNativo.add(idPermissao);
      try {
        await exibirDialogoDecisaoMonitoramento(
          context: context,
          idPermissao: idPermissao,
          uidSolicitante: uidSolicitante,
          nomeSolicitante: (dados['nomeSolicitante'] as String?) ?? '',
          telefoneSolicitante: (dados['telefoneSolicitante'] as String?) ?? '',
        );
      } finally {
        _idsComDialogoAbertoViaNativo.remove(idPermissao);
      }
      return;
    }

    payloadSolicitacaoPendente = {
      'tipo': 'monitoramento_push',
      'subTipo': 'solicitacao_monitoramento',
      'idPermissao': idPermissao,
      'uidSolicitante': uidSolicitante,
      'nomeSolicitante': (dados['nomeSolicitante'] as String?) ?? '',
      'telefoneSolicitante': (dados['telefoneSolicitante'] as String?) ?? '',
    };
  }

  static Future<dynamic> _aoReceberChamadaNativa(MethodCall call) async {
    if (call.method != 'solicitacaoRecebida') return null;
    try {
      final dados = Map<String, dynamic>.from(call.arguments as Map);
      await _tratarPayloadSolicitacaoNativo(dados);
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao processar solicitação nativa recebida: $e');
    }
    return null;
  }

  /// Deve ser chamado uma única vez, bem no início do app (main.dart),
  /// ANTES de runApp(). Também é chamado defensivamente pelo callback
  /// headless do [RotinaAlarmeService], já que o FlutterEngine headless
  /// não compartilha nenhuma inicialização feita pelo processo principal.
  static Future<void> inicializar() async {
    if (_inicializado) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    // Carrega os labels localizados ANTES de montar as categorias do iOS
    // abaixo — diferente do Android (ação anexada a cada `show()`
    // individual, sempre com o idioma atual), o iOS exige que as
    // categorias/ações sejam registradas UMA vez aqui, em `initialize()`.
    await _carregarNomesCanaisLocalizados();

    final darwinSettings = DarwinInitializationSettings(
      // `false` nos três: a permissão de notificação já é pedida pelo
      // FcmService (`FirebaseMessaging.instance.requestPermission()`,
      // MESMA API nativa do iOS por baixo — ver `main.dart`, chamado bem
      // antes deste `inicializar()`). Pedir de novo aqui não mostraria um
      // segundo diálogo (o iOS só perguntar uma vez por app), mas manter
      // um único ponto de responsabilidade evita qualquer corrida de
      // ordem entre os dois plugins no cold start.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: [
        DarwinNotificationCategory(
          categoriaIosCronometro,
          actions: [
            DarwinNotificationAction.plain(
              acaoDesligarCronometroId,
              _labelAcaoDesligarCronometro,
              options: {DarwinNotificationActionOption.foreground},
            ),
          ],
        ),
        DarwinNotificationCategory(
          categoriaIosDespertador,
          actions: [
            DarwinNotificationAction.plain(
              acaoDesativarDespertadorId,
              _labelAcaoDesativarDespertador,
              options: {DarwinNotificationActionOption.foreground},
            ),
          ],
        ),
        DarwinNotificationCategory(
          _categoriaIosAlarmeCompleto,
          actions: [
            // Sem `.foreground` nas opções — equivalente a
            // `showsUserInterface: false` do Android: a ação roda sem
            // trazer o app para frente (mesmo padrão do lado Android).
            DarwinNotificationAction.plain(
              'pausar_alarme',
              _labelAcaoPausarAlarme,
            ),
          ],
        ),
        DarwinNotificationCategory(
          _categoriaIosSolicitacaoMonitoramento,
          actions: [
            // `foreground: true` (via a opção abaixo) — equivalente ao
            // `showsUserInterface: true` do Android: a barreira de login
            // (ver política de segurança em `main.dart`) precisa continuar
            // valendo mesmo decidindo direto pela notificação, então
            // qualquer uma das duas ações sempre abre o app.
            DarwinNotificationAction.plain(
              acaoAceitarMonitoramentoId,
              _labelAcaoAceitarMonitoramento,
              options: {DarwinNotificationActionOption.foreground},
            ),
            DarwinNotificationAction.plain(
              acaoRecusarMonitoramentoId,
              _labelAcaoRecusarMonitoramento,
              options: {
                DarwinNotificationActionOption.foreground,
                DarwinNotificationActionOption.destructive,
              },
            ),
          ],
        ),
      ],
    );

    final initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _aoReceberRespostaEmPrimeiroPlano,
      onDidReceiveBackgroundNotificationResponse: _aoReceberRespostaEmSegundoPlano,
    );

    // Cold start via toque numa notificação (app estava totalmente
    // fechado): `onDidReceiveNotificationResponse` acima só dispara para
    // toques que acontecem DEPOIS do app já estar rodando — a notificação
    // que efetivamente abriu o processo agora precisa ser resgatada aqui,
    // explicitamente, ANTES de qualquer tela ser construída. Sem isto, o
    // payload se perdia silenciosamente sempre que o app era relançado do
    // zero por uma notificação (é exatamente esse o cold start em que a
    // barreira de login — ver política de segurança em `main.dart` — SEMPRE
    // aparece primeiro; o payload capturado aqui é só guardado para a
    // LoginScreen consumir DEPOIS de um login bem-sucedido, nunca usado
    // para pular a autenticação).
    try {
      final detalhesLancamento = await _plugin.getNotificationAppLaunchDetails();
      final respostaDeLancamento = detalhesLancamento?.notificationResponse;
      if (detalhesLancamento?.didNotificationLaunchApp == true &&
          respostaDeLancamento != null) {
        _capturarPayloadSolicitacaoPendente(
          respostaDeLancamento.payload,
          actionId: respostaDeLancamento.actionId,
        );
      }
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao ler notificação de lançamento: $e');
    }

    // Mesma ideia acima, mas para o caminho 100% nativo (ver
    // SolicitacaoMonitoramentoWakeService): resgata os extras deixados no
    // Intent que abriu o app num cold start disparado por esse Service, e
    // passa a escutar chamadas futuras (app já rodando, via onNewIntent).
    _canalSolicitacaoNativa.setMethodCallHandler(_aoReceberChamadaNativa);
    try {
      final payloadPendente = await _canalSolicitacaoNativa
          .invokeMapMethod<String, dynamic>('obterPayloadPendente');
      if (payloadPendente != null) {
        await _tratarPayloadSolicitacaoNativo(payloadPendente);
      }
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao ler payload nativo pendente: $e');
    }

    // Carrega os nomes/descrições dos canais no idioma ativo do usuário
    // ANTES de criá-los de fato (ver [_carregarNomesCanaisLocalizados]).
    await _carregarNomesCanaisLocalizados();

    final canal = AndroidNotificationChannel(
      canalId,
      canalNome,
      description: canalDescricao,
      importance: Importance.max,
      // CORREÇÃO (bug real observado em teste — "toque duplo"): sem
      // `playSound: false`, este canal tocava o som PADRÃO de
      // notificação do Android (~1 minuto, sem controle de volume pelo
      // app) em PARALELO ao alarme sonoro customizado do próprio
      // Guardião-X (player nativo/Dart, ver AlarmeDisparadoScreen), toda
      // vez que o alarme de rotina disparava. O áudio do alerta passa a
      // ficar 100% sob controle do player do app.
      playSound: false,
    );
    final canalAlertaRecebido = AndroidNotificationChannel(
      canalAlertaRecebidoId,
      canalAlertaRecebidoNome,
      description: canalAlertaRecebidoDescricao,
      importance: Importance.max,
      // Modo "Despertador de Emergência" (2026-08-15): roteia o som
      // desta notificação pelo canal STREAM_ALARM do Android (em vez do
      // STREAM_NOTIFICATION padrão) — o mesmo canal usado por
      // despertadores do sistema, que NÃO é silenciado pelo modo
      // Silencioso/Vibrar do aparelho. Efeito mesmo no pior caso (app
      // 100% fechado, ver `AlertaRecebidoAlarmService.kt`), onde o loop
      // sonoro contínuo em volume máximo daquele serviço não chega a
      // iniciar — este ajuste garante que ao menos o som PADRÃO desta
      // notificação já fure o silencioso.
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-16, Moto
      // G7 Play — reespecificação do usuário): vibração desativada por
      // completo neste canal — ver documentação completa (motor de
      // vibração ficando preso em loop infinito, som permanece
      // funcionando normalmente) em [exibirNotificacaoAlertaRecebido].
      // Esta é a configuração que REALMENTE vale: o Android trava as
      // opções de vibração/som de um canal no momento em que ele é
      // criado pela PRIMEIRA vez, então é aqui — não no
      // `enableVibration: false` da notificação individual — que a
      // mudança precisa acontecer para valer também em instalações já
      // existentes (ver a migração `_chaveCanaisMigrados` em
      // [inicializar], incrementada para forçar a recriação deste canal).
      enableVibration: false,
    );
    final canalMonitoramento = AndroidNotificationChannel(
      canalMonitoramentoId,
      canalMonitoramentoNome,
      description: canalMonitoramentoDescricao,
      importance: Importance.high,
    );
    final canalSolicitacaoMonitoramento = AndroidNotificationChannel(
      canalSolicitacaoMonitoramentoId,
      canalSolicitacaoMonitoramentoNome,
      description: canalSolicitacaoMonitoramentoDescricao,
      importance: Importance.max,
      // CORREÇÃO (pedido explícito do usuário, 2026-09-06): som e vibração
      // deixados EXPLÍCITOS na criação do canal — mesmo já sendo o padrão
      // da própria lib, o Android trava essas configurações no momento em
      // que o canal é criado pela PRIMEIRA vez (ver a mesma lição já
      // documentada em [canalAlertaRecebidoId] logo abaixo), então deixar
      // implícito arrisca depender de um default que pode mudar. `sound:
      // null` (omitido) = toque PADRÃO do sistema Android, garantido de
      // tocar mesmo em segundo plano (nunca depende de um arquivo de som
      // customizado embutido no app). `vibrationPattern` também omitido de
      // propósito — usa o padrão de vibração do próprio sistema, mais
      // previsível entre fabricantes do que um padrão custom.
      playSound: true,
      enableVibration: true,
    );
    final canalAlertaEnviado = AndroidNotificationChannel(
      canalAlertaEnviadoId,
      canalAlertaEnviadoNome,
      description: canalAlertaEnviadoDescricao,
      importance: Importance.low,
      playSound: false,
    );
    final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // CORREÇÃO DE BUG REAL (2026-08-15, diagnosticado ao vivo via
    // logcat): o migration de canais abaixo (deletar + recriar,
    // necessário SÓ UMA VEZ por instalação para aplicar `playSound:
    // false`/`audioAttributesUsage: alarm` a canais já existentes de
    // versões antigas — ver comentários originais preservados logo
    // abaixo) rodava TODA VEZ que [inicializar] era chamado, inclusive
    // em CADA isolate headless novo do `firebase_messaging`
    // (`_inicializado` é um `bool` estático — não sobrevive entre
    // isolates, cada mensagem em segundo plano criava um isolate 100%
    // novo). Cada mensagem recebida disparava, então, 2 chamadas nativas
    // extras de `deleteNotificationChannel` — round-trips desnecessários
    // (o canal já teria sido migrado da PRIMEIRA vez) que competiam pela
    // janela de execução CURTA que o Android concede a um
    // `BroadcastReceiver`/isolate headless antes de matá-lo. Sintoma real
    // observado: o isolate reiniciava do zero a cada mensagem (mesma
    // sequência completa de logs repetindo), e a notificação de alerta
    // NUNCA chegava a ser exibida (`dumpsys notification` confirmou
    // ausência). Uma flag persistida em disco (sobrevive entre isolates,
    // ao contrário do `bool` estático) garante que a migração rode
    // literalmente UMA vez por instalação, nunca de novo — deixando
    // [inicializar] rápido o bastante para caber na janela do isolate
    // headless.
    final prefsMigracao = await SharedPreferences.getInstance();
    final bool canaisJaMigrados =
        prefsMigracao.getBool(_chaveCanaisMigrados) ?? false;

    if (!canaisJaMigrados) {
      // O Android trava as configurações de um canal (incluindo som) no
      // momento em que ele é criado pela PRIMEIRA vez — chamar
      // `createNotificationChannel` de novo com `playSound: false` NÃO
      // atualiza um canal 'checkin_rotina' já existente em instalações
      // anteriores ao ajuste acima. Remover e recriar aqui garante que a
      // correção do "toque duplo" também se aplique a quem já tinha o app
      // instalado, não só a instalações novas. Idempotente e seguro: apagar
      // um canal inexistente (instalação nova) é um no-op.
      try {
        await implementacaoAndroid?.deleteNotificationChannel(canalId);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao remover canal antigo de check-in: $e');
      }
      // Mesmo motivo acima: quem já tinha o app instalado ANTES do ajuste
      // "Despertador de Emergência" (2026-08-15, `audioAttributesUsage:
      // AudioAttributesUsage.alarm`) ficaria preso no canal antigo
      // (STREAM_NOTIFICATION) para sempre sem isto.
      try {
        await implementacaoAndroid?.deleteNotificationChannel(canalAlertaRecebidoId);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao remover canal antigo de alerta recebido: $e');
      }
      try {
        await prefsMigracao.setBool(_chaveCanaisMigrados, true);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao persistir flag de migração de canais: $e');
      }
    }

    // `createNotificationChannel` é barato/seguro chamar sempre, mesmo
    // com o canal já existente (o Android trata como no-op) — os
    // próprios canais em si são um recurso PERSISTIDO pelo sistema
    // operacional (sobrevivem a reinícios do app), diferente da migração
    // acima.
    await implementacaoAndroid?.createNotificationChannel(canal);
    await implementacaoAndroid?.createNotificationChannel(canalAlertaRecebido);
    await implementacaoAndroid?.createNotificationChannel(canalMonitoramento);
    await implementacaoAndroid?.createNotificationChannel(canalSolicitacaoMonitoramento);
    await implementacaoAndroid?.createNotificationChannel(canalAlertaEnviado);

    // A partir do Android 14/15+, `USE_FULL_SCREEN_INTENT` deixou de ser
    // concedida automaticamente para apps sem função de chamada/alarme — sem
    // esta solicitação explícita, o `fullScreenIntent: true` das notificações
    // acima é silenciosamente rebaixado para um heads-up normal, que NÃO
    // acorda a tela com o aparelho bloqueado (é exatamente esse sintoma que
    // motivou este ajuste). Em versões do Android onde a permissão não se
    // aplica (< 14), a chamada é um no-op seguro do lado nativo.
    try {
      await implementacaoAndroid?.requestFullScreenIntentPermission();
    } catch (e) {
      debugPrint(
          '⚠️ [NotificacaoService] Falha ao solicitar permissão de full-screen intent: $e');
    }

    // Migração iOS (2026-09-12): banco de fusos horários exigido por
    // `zonedSchedule` (ver [agendarLembretesCheckinRotinaIOS]) — carregado
    // aqui, uma única vez, junto com o resto da inicialização. Barato e
    // seguro chamar mesmo no Android, que nunca usa `zonedSchedule`.
    try {
      tzdata.initializeTimeZones();
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao inicializar timezone: $e');
    }

    _inicializado = true;
  }

  /// `true` se o app já pode agendar alarmes EXATOS (`AlarmManager.
  /// canScheduleExactAlarms()`) — checagem 100% silenciosa, nunca navega
  /// para Configurações (ao contrário de [solicitarAlarmesExatos]). Usado
  /// por [OnboardingService] para mostrar o status do item "Notificações
  /// e alarmes" sem disparar nenhuma navegação indesejada só de exibir a
  /// tela. Sempre `true` em versões do Android onde a permissão nem existe
  /// (< 12) — nunca lança exceção (permissivo em caso de erro/plataforma
  /// não suportada).
  static Future<bool> podeAgendarAlarmesExatos() async {
    try {
      final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await implementacaoAndroid?.canScheduleExactNotifications() ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao checar permissão de alarmes exatos: $e');
      return true;
    }
  }

  /// Solicita a permissão de alarmes exatos — abre a tela nativa de
  /// Configurações se ainda não concedida (Android 12+); no-op imediato
  /// (retorna `true`) em versões mais antigas ou se já concedida. Usado
  /// pelo botão "Conceder" do item "Notificações e alarmes" em
  /// [OnboardingService]/`OnboardingScreen`.
  static Future<bool> solicitarAlarmesExatos() async {
    try {
      final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await implementacaoAndroid?.requestExactAlarmsPermission() ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao solicitar permissão de alarmes exatos: $e');
      return true;
    }
  }

  /// Solicita a permissão de notificação em tela cheia (`USE_FULL_SCREEN_INTENT`,
  /// só existe a partir do Android 14) — abre a tela nativa de
  /// Configurações se ainda não concedida; no-op imediato (retorna `true`)
  /// em versões mais antigas ou se já concedida.
  static Future<bool> solicitarPermissaoTelaCheia() async {
    try {
      final implementacaoAndroid = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await implementacaoAndroid?.requestFullScreenIntentPermission() ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao solicitar permissão de tela cheia: $e');
      return true;
    }
  }

  /// Checagem NATIVA e 100% silenciosa (sem qualquer navegação/prompt) de
  /// `USE_FULL_SCREEN_INTENT` — CORREÇÃO DE BUG REAL (relatado em teste
  /// físico, 2026-08-16): antes desta checagem, `OnboardingScreen`/
  /// `PermissoesStatusScreen` só sabiam o status desta permissão logo após
  /// o usuário tocar em "Conceder" (valor nunca persistido nem
  /// reconsultado) — ao reabrir a tela ou reiniciar o app, o item sempre
  /// voltava a aparecer como "Pendente", mesmo já concedido de fato.
  ///
  /// O `flutter_local_notifications` só expõe um método que PEDE a
  /// permissão (e pode navegar para Configurações), nunca um getter isolado
  /// só de leitura — por isso esta consulta vai direto ao canal nativo
  /// (`MainActivity.kt`), que chama `NotificationManager.canUseFullScreenIntent()`
  /// (API 34+). Em versões anteriores ao Android 14, ou em qualquer falha
  /// do canal, retorna `true`: a restrição nem existe nessas versões, e uma
  /// falha técnica na checagem nunca deve fazer o item aparecer como
  /// pendente indevidamente.
  static Future<bool> podeUsarTelaCheia() async {
    try {
      final resultado =
          await _canalPermissoesNativas.invokeMethod<bool>('podeUsarTelaCheia');
      return resultado ?? true;
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao checar permissão de tela cheia: $e');
      return true;
    }
  }

  /// Exibe a notificação de check-in de rotina para o [idAlarme]
  /// informado, com a ação rápida "✅ Cheguei bem". O [idAlarme] é
  /// codificado no próprio id da notificação Android para que o handler
  /// da ação consiga identificar exatamente qual alarme confirmar.
  static Future<void> exibirNotificacaoCheckin({
    required int idAlarme,
    required String etiqueta,
  }) async {
    await inicializar();

    final androidDetails = AndroidNotificationDetails(
      canalId,
      canalNome,
      channelDescription: canalDescricao,
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
      fullScreenIntent: true,
      vibrationPattern: Int64List.fromList([0, 500, 250, 500]),
      // Áudio 100% sob controle do player do próprio app (ver o mesmo
      // ajuste, com a explicação completa, no canal 'checkin_rotina' em
      // [inicializar]) — nunca o som padrão de notificação do sistema.
      playSound: false,
    );

    // iOS: sem `fullScreenIntent`/`ongoing` (não existem nessa plataforma
    // — a Apple não permite notificação local abrir uma tela por cima do
    // bloqueio, ver seção 5 de `docs/migracao-ios-relatorio-2026-09-12.md`).
    // `.active` é o nível de interrupção "normal" (banner + som padrão,
    // sem furar o Silencioso) — mesmo padrão sem som customizado do lado
    // Android (`playSound: false` acima só desliga o som PADRÃO do
    // sistema; o alarme sonoro do app já é outro player, independente
    // disto nas duas plataformas).
    const darwinDetails = DarwinNotificationDetails(
      presentSound: false,
      interruptionLevel: InterruptionLevel.active,
    );

    final details = NotificationDetails(android: androidDetails, iOS: darwinDetails);
    final l10n = await L10nHeadlessService.obter();

    await _plugin.show(
      idAlarme,
      l10n.familiaEtiquetaPadrao,
      l10n.notifCheckinCorpo,
      details,
      payload: idAlarme.toString(),
    );
  }

  /// Exibe uma notificação de alarme completo com som e vibração persistentes,
  /// usando uma intenção de tela cheia para aparecer sobre a tela de bloqueio.
  static Future<void> exibirNotificacaoAlarmeCompleto({
    required int idAlarme,
    required String etiqueta,
  }) async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();

    final androidDetails = AndroidNotificationDetails(
      canalId,
      canalNome,
      channelDescription: canalDescricao,
      importance: Importance.max,
      priority: Priority.high,
      ongoing: true,
      fullScreenIntent: true,
      autoCancel: false,
      playSound: true,
      vibrationPattern: Int64List.fromList([0, 1000, 500, 1000, 500, 1000]),
      actions: [
        AndroidNotificationAction(
          'pausar_alarme',
          l10n.notifPausarAlarmeAcao,
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );

    // iOS: `.timeSensitive` é o nível máximo de interrupção disponível
    // SEM o entitlement especial de Critical Alerts (que a Apple concede
    // manualmente mediante justificativa — ver seção 5/6 do relatório de
    // migração) — furar o modo Silencioso/Foco por completo, como o
    // Android faz aqui via `AudioAttributesUsage.alarm`, só é possível
    // com esse entitlement. `categoryIdentifier` liga esta notificação à
    // categoria com a ação "pausar_alarme" registrada em [inicializar].
    const darwinDetails = DarwinNotificationDetails(
      categoryIdentifier: _categoriaIosAlarmeCompleto,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    final details = NotificationDetails(android: androidDetails, iOS: darwinDetails);

    await _plugin.show(
      idAlarme + 10000, // ID diferente para não conflitar com a notificação normal
      etiqueta.isNotEmpty ? etiqueta : l10n.notifAlarmeSegurancaTitulo,
      l10n.notifAlarmeSegurancaCorpo,
      details,
      payload: 'alarme_${idAlarme.toString()}',
    );
  }

  /// Exibe, com tela cheia mesmo sobre a lockscreen (mesmo mecanismo de
  /// [exibirNotificacaoAlarmeCompleto]: `fullScreenIntent` + `Importance.max`
  /// + vibração/som persistentes), o alerta de emergência de OUTRO
  /// usuário recebido via Push FCM (ver [FcmService]) — canal próprio
  /// [canalAlertaRecebidoId], distinto do alarme de rotina do PRÓPRIO
  /// usuário.
  ///
  /// [idEntrega] identifica o documento `entregas_alerta/{idEntrega}` no
  /// Firestore (ver `functions/alertaHibridoService.js`) — usado para
  /// codificar um id de notificação Android estável e para levar o
  /// payload completo (remetente/mensagem/localização) até
  /// [AlertaRecebidoScreen] quando o usuário tocar a notificação.
  static Future<void> exibirNotificacaoAlertaRecebido({
    required String idEntrega,
    required String mensagem,
    String? nomeRemetente,
    double? latitude,
    double? longitude,
    String? fotoUrl,
  }) async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();
    final String tituloAlerta = nomeRemetente != null && nomeRemetente.isNotEmpty
        ? l10n.notifAlertaDeNome(nomeRemetente)
        : l10n.notifAlertaSegurancaGenerico;

    // P2 da sequência unificada de SOS (ver SosDisparoService no
    // remetente): quando o alerta inclui uma foto, baixa os bytes ANTES
    // de montar a notificação e usa BigPictureStyle para exibi-la
    // embutida — best-effort: uma falha no download (sem rede, link
    // expirado, timeout) NUNCA deve impedir a notificação de
    // texto/localização de aparecer, só cai para o estilo padrão.
    Uint8List? fotoBytes;
    if (fotoUrl != null && fotoUrl.isNotEmpty) {
      try {
        final resposta = await http.get(Uri.parse(fotoUrl)).timeout(const Duration(seconds: 15));
        if (resposta.statusCode == 200) {
          fotoBytes = resposta.bodyBytes;
        }
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao baixar foto do SOS para exibição: $e');
      }
    }

    final androidDetails = AndroidNotificationDetails(
      canalAlertaRecebidoId,
      canalAlertaRecebidoNome,
      channelDescription: canalAlertaRecebidoDescricao,
      importance: Importance.max,
      priority: Priority.high,
      // Modo "Despertador de Emergência" (item 4, reespecificação do
      // usuário, 2026-08-15): precisa continuar DESCARTÁVEL por arraste
      // — `ongoing: true` (valor anterior) bloqueia completamente o
      // gesto de swipe, o que impediria o usuário de silenciar o alarme
      // dessa forma. `autoCancel` continua `false` de propósito: um
      // toque simples abre o app SEM remover a notificação sozinho — é
      // [cancelarNotificacaoAlertaRecebido] (chamado explicitamente ao
      // abrir `AlertaRecebidoScreen`) quem a remove de fato, o que por
      // sua vez para o som insistente (ver `additionalFlags` abaixo).
      ongoing: false,
      fullScreenIntent: true,
      autoCancel: false,
      playSound: true,
      // Ver comentário completo no canal (acima, em [inicializar]) —
      // roteia o som desta notificação pelo STREAM_ALARM.
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // MODO "DESPERTADOR DE EMERGÊNCIA" (items 3/4, reespecificação do
      // usuário, 2026-08-15) — `Notification.FLAG_INSISTENT` (valor 4),
      // aplicado via `additionalFlags` (recurso nativo padrão do
      // Android, não um hack): repete o SOM em loop contínuo até a
      // notificação ser CANCELADA (arrastada para descartar, ou removida
      // programaticamente — ver [cancelarNotificacaoAlertaRecebido]).
      // ÚNICO mecanismo de loop que funciona de forma 100% confiável
      // mesmo com o app TOTALMENTE fechado: roda inteiramente dentro da
      // MESMA chamada `flutter_local_notifications` que já posta esta
      // notificação com sucesso no isolate headless do
      // `firebase_messaging` (diferente do plugin nativo customizado
      // `AlertaRecebidoAlarmService`/`AlertaRecebidoAlarmPlugin`, que só
      // funciona quando o app já tem um engine "de verdade" rodando —
      // ver documentação completa em `AlertaRecebidoAlarmService.kt`).
      additionalFlags: Int32List.fromList(<int>[4]),
      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-16, Moto
      // G7 Play — reespecificação do usuário): a vibração REMOVIDA por
      // completo — `FLAG_INSISTENT` (acima) mantém o motor de vibração
      // repetindo pra sempre em loop junto com o som, e nesse aparelho
      // esse loop ficava PRESO mesmo depois da notificação já ter sido
      // cancelada (só desligar o aparelho parava) — um bug de
      // fabricante/SO fora do nosso controle de código, mas que só afeta
      // a vibração; o som (roteado por STREAM_ALARM, ver
      // `audioAttributesUsage` acima) continua funcionando e sendo
      // corretamente interrompido pelos mesmos mecanismos já existentes
      // (toque na notificação, abrir o app, ou o teto de 5 minutos — ver
      // [_tempoMaximoAlarmeRecebido]). `enableVibration: false` aqui é
      // redundante com o mesmo ajuste já feito no CANAL (ver
      // [inicializar]) — o Android decide pelo canal, mas deixar
      // explícito também aqui documenta a intenção sem depender de
      // ninguém ler o outro lugar.
      enableVibration: false,
      styleInformation: fotoBytes != null
          ? BigPictureStyleInformation(
              ByteArrayAndroidBitmap(fotoBytes),
              contentTitle: tituloAlerta,
              summaryText: mensagem,
            )
          : null,
    );

    // iOS — canal PRINCIPAL do fluxo de emergência no iOS (decisão de
    // produto 2026-09-12: sem SMS, 100% Push com foto e localização em
    // tempo real, ver nota de migração em `emergency_alert_service.dart`).
    // `.timeSensitive` é o nível máximo de interrupção sem o entitlement
    // de Critical Alerts (não solicitado ainda — ver seção 5/6 do
    // relatório de migração); com ele, bastaria trocar para `.critical`
    // aqui para furar o Silencioso/Foco como o Android faz via
    // `audioAttributesUsage: alarm`/`FLAG_INSISTENT` acima — o iOS não
    // repete o som em loop (`FLAG_INSISTENT` não tem equivalente), toca
    // uma vez só, então o "Despertador de Emergência" contínuo também
    // depende dessa mesma decisão de produto pendente.
    //
    // A foto (já baixada em [fotoBytes] acima, best-effort) é anexada via
    // [DarwinNotificationAttachment] — diferente do Android
    // (`ByteArrayAndroidBitmap` aceita os bytes direto), o iOS exige um
    // arquivo em disco; escrito no diretório temporário do app, nunca
    // bloqueia a notificação em caso de falha (mesmo padrão best-effort
    // do download acima).
    DarwinNotificationAttachment? anexoFotoIos;
    if (fotoBytes != null) {
      try {
        final tempDir = await getTemporaryDirectory();
        final arquivoTemp = File(
            '${tempDir.path}/alerta_recebido_${idEntrega.hashCode.abs()}.jpg');
        await arquivoTemp.writeAsBytes(fotoBytes, flush: true);
        anexoFotoIos = DarwinNotificationAttachment(arquivoTemp.path);
      } catch (e) {
        debugPrint('⚠️ [NotificacaoService] Falha ao preparar anexo de foto (iOS): $e');
      }
    }

    final darwinDetails = DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.timeSensitive,
      attachments: anexoFotoIos != null ? [anexoFotoIos] : null,
    );

    final details = NotificationDetails(android: androidDetails, iOS: darwinDetails);

    final payload = jsonEncode({
      'tipo': 'alerta_recebido',
      'idEntrega': idEntrega,
      'mensagem': mensagem,
      // Item pendente (2026-08-14, reespecificação do usuário): "todas as
      // mensagens" devem mostrar o horário e data EXATA — capturado aqui,
      // no momento real da entrega no dispositivo (mesmo instante em que
      // AlertasRecebidosService.registrarAlertaRecebido grava `recebido_em`
      // no SQLite local), e propagado pelo payload até AlertaRecebidoScreen
      // (ver `recebidoEm` abaixo e em [_processarRespostaPayloadJson]).
      'recebidoEm': DateTime.now().toIso8601String(),
      if (nomeRemetente != null) 'nomeRemetente': nomeRemetente,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (fotoUrl != null && fotoUrl.isNotEmpty) 'fotoUrl': fotoUrl,
    });

    // Modo "Despertador de Emergência" (item 3 do pedido): inicia o
    // alarme sonoro contínuo em volume máximo EM PARALELO à notificação
    // de tela cheia abaixo — ver [iniciarAlarmeCritico].
    unawaited(iniciarAlarmeCritico());

    await _plugin.show(
      _idNotificacaoAlertaRecebido(idEntrega),
      tituloAlerta,
      mensagem,
      details,
      payload: payload,
    );

    // TETO DE SEGURANÇA (2026-08-15, mesmo pedido do usuário que motivou
    // a correção do "não consegui fazer parar de vibrar"; ajustado de 3
    // para 5 minutos no mesmo dia, após confirmar em teste físico que o
    // teto nativo/este agendado já disparavam corretamente): agenda um
    // alarme nativo de UMA VEZ, em [_tempoMaximoAlarmeRecebido] (5
    // minutos — MESMO valor já usado por
    // `AlertaRecebidoAlarmService._TEMPO_MAXIMO_TOCANDO`, do lado
    // nativo), que cancela esta notificação sozinho se o usuário nunca
    // interagir com ela.
    //
    // POR QUE NÃO REAPROVEITAR O TIMEOUT NATIVO JÁ EXISTENTE: aquele
    // timeout vive DENTRO de `AlertaRecebidoAlarmService` — mas esse
    // Service só chega a INICIAR quando `iniciarAlarmeCritico()` (acima)
    // funciona, e ele já é protegido por try/catch justamente porque
    // FALHA (`MissingPluginException`) sempre que esta função roda no
    // isolate HEADLESS do FCM (app fechado) — exatamente o cenário onde
    // uma rede de segurança é mais necessária. `AndroidAlarmManager`
    // (usado abaixo) é um plugin FEDERADO de verdade (registrado em
    // QUALQUER engine automaticamente, mesmo padrão já usado com sucesso
    // em outros callbacks headless deste app, ver
    // `RotinaAlarmeService`/`RetryUploadService`), então funciona de
    // forma confiável não importa o estado do app.
    //
    // iOS: `android_alarm_manager_plus` não tem NENHUMA implementação
    // nessa plataforma — a chamada abaixo lança (`MissingPluginException`
    // ou equivalente), já capturada pelo try/catch existente e só
    // logada como aviso; nunca propaga nem derruba o restante do método.
    // Sem este teto de segurança no iOS, a notificação permanece até o
    // usuário interagir com ela manualmente (sem o loop sonoro contínuo
    // do Android para justificar um timeout automático de qualquer
    // forma, ver `interruptionLevel`/`DarwinNotificationAttachment`
    // acima — o iOS toca o som uma única vez).
    try {
      await AndroidAlarmManager.oneShot(
        _tempoMaximoAlarmeRecebido,
        _idAlarmeSegurancaAlertaRecebido(idEntrega),
        _callbackTimeoutSegurancaAlertaRecebido,
        exact: true,
        wakeup: true,
        allowWhileIdle: true, // bypassa Doze — o dispositivo receptor pode estar com a tela apagada/bloqueada pelos 5 minutos inteiros.
        rescheduleOnReboot: false,
        params: {'idEntrega': idEntrega},
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao agendar o teto de segurança '
          'do alerta recebido — a notificação só será cancelada por interação '
          'manual do usuário: $e');
    }
  }

  /// Mesmo teto (5 minutos — reespecificado pelo usuário, 2026-08-15;
  /// era 3 minutos) já usado pelo timeout nativo de
  /// `AlertaRecebidoAlarmService._TEMPO_MAXIMO_TOCANDO` — ver
  /// documentação completa em [exibirNotificacaoAlertaRecebido] sobre por
  /// que este, implementado separadamente via `AndroidAlarmManager`, é
  /// necessário mesmo já existindo aquele.
  static const Duration _tempoMaximoAlarmeRecebido = Duration(minutes: 5);

  /// Id estável derivado do [idEntrega] — evita colidir com os ids de
  /// notificação de check-in de rotina (idAlarme/idAlarme+10000).
  /// Compartilhado entre [exibirNotificacaoAlertaRecebido] (posta) e
  /// [cancelarNotificacaoAlertaRecebido] (remove) para nunca divergir.
  static int _idNotificacaoAlertaRecebido(String idEntrega) =>
      30000 + (idEntrega.hashCode.abs() % 60000);

  /// Id do alarme nativo do teto de segurança (ver
  /// [_tempoMaximoAlarmeRecebido]) — faixa DELIBERADAMENTE separada de
  /// [_idNotificacaoAlertaRecebido] (namespace diferente do
  /// `AndroidAlarmManager`, mas por clareza/depuração nunca reaproveita o
  /// mesmo número) e dos demais ids de alarme nativo já usados neste app
  /// (`RotinaAlarmeService`, `RetryUploadService`, `AlarmeService`).
  static int _idAlarmeSegurancaAlertaRecebido(String idEntrega) =>
      90000 + (idEntrega.hashCode.abs() % 60000);

  /// Remove a notificação do alerta recebido — item 4 do pedido
  /// ("Despertador de Emergência"): cancelar a notificação
  /// programaticamente é o que efetivamente para o som insistente em
  /// loop (`Notification.FLAG_INSISTENT`, ver
  /// [exibirNotificacaoAlertaRecebido]), já que este só continua
  /// tocando "até a notificação ser cancelada". Chamado por
  /// `AlertaRecebidoScreen` assim que o usuário abre a tela (qualquer
  /// caminho: toque na notificação, no card do Histórico, etc.) ou toca
  /// no link do mapa. Seguro chamar mesmo sem nenhuma notificação ativa
  /// com este [idEntrega] (no-op).
  static Future<void> cancelarNotificacaoAlertaRecebido(String idEntrega) async {
    try {
      await _plugin.cancel(_idNotificacaoAlertaRecebido(idEntrega));
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao cancelar notificação de alerta recebido: $e');
    }
    // Cancela também o teto de segurança agendado (ver
    // [exibirNotificacaoAlertaRecebido]) — a notificação já foi resolvida
    // por interação do usuário, então o alarme de 5 minutos não precisa
    // mais disparar. Puramente cosmético/limpeza: mesmo se este cancel
    // falhar ou o alarme já tiver disparado, [_callbackTimeoutSegurancaAlertaRecebido]
    // chamar [cancelarNotificacaoAlertaRecebido] de novo é inofensivo
    // (idempotente).
    try {
      await AndroidAlarmManager.cancel(_idAlarmeSegurancaAlertaRecebido(idEntrega));
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao cancelar o teto de segurança do alerta recebido: $e');
    }
  }

  /// Id fixo: uma nova revogação substitui o aviso anterior em vez de
  /// empilhar.
  static const int idNotificacaoSessaoEncerrada = 990001;

  /// Só iOS — a conta foi aberta em outro aparelho e a sessão deste foi
  /// encerrada (ver `SessaoRevogadaService`). Tocar abre o app, que mostra
  /// a tela explicando e o botão para entrar de novo (o payload não é
  /// tratado em [_processarResposta]: a própria abertura já resolve).
  static Future<void> exibirNotificacaoSessaoEncerrada() async {
    try {
      await inicializar();
      final l10n = await L10nHeadlessService.obter();
      await _plugin.show(
        idNotificacaoSessaoEncerrada,
        l10n.sessaoEncerradaTitulo,
        l10n.sessaoEncerradaMensagem,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(interruptionLevel: InterruptionLevel.timeSensitive),
        ),
        payload: 'sessao_encerrada',
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao exibir aviso de sessão encerrada: $e');
    }
  }

  /// Exibe a notificação para os eventos de push da aba Monitoramento —
  /// solicitação de localização recebida, aprovada, recusada, bloqueada ou
  /// expirada (ver [FcmService._tratarPushMonitoramento] e
  /// `functions/monitoramentoService.js`/`monitoramentoExpiracaoMonitor.js`).
  ///
  /// SÓ o tipo `'solicitacao_monitoramento'` — o único que exige uma decisão
  /// do usuário — usa [canalSolicitacaoMonitoramentoId] com
  /// `fullScreenIntent` (mesmo padrão de
  /// [exibirNotificacaoAlertaRecebido]): com o aparelho bloqueado, "acorda"
  /// a tela e abre por cima da lockscreen, estilo chamada recebida. As
  /// respostas informativas (aprovado/negado/bloqueado/expirado) continuam
  /// em [canalMonitoramentoId], uma notificação normal — a aba Monitoramento
  /// nunca deve se comportar como alarme/sirene fora do caso que realmente
  /// precisa de uma resposta.
  ///
  /// Ao tocar na notificação, a barreira de login (ver política de
  /// segurança em `main.dart`) continua obrigatória; o modal de decisão só
  /// abre DEPOIS de autenticado (ver [_processarRespostaPayloadJson] e
  /// `LoginScreen._navegarParaFluxoPrincipal`).
  static Future<void> exibirNotificacaoMonitoramento({
    required String tipo,
    required String idPermissao,
    String? nomeContraparte,
    String? uidSolicitante,
    String? telefoneSolicitante,
  }) async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();

    final nome = (nomeContraparte != null && nomeContraparte.trim().isNotEmpty)
        ? nomeContraparte.trim()
        : l10n.notifMonitContatoGenerico;

    final String titulo;
    final String corpo;
    switch (tipo) {
      case 'solicitacao_monitoramento':
        titulo = l10n.notifMonitSolicitacaoTitulo;
        corpo = l10n.notifMonitSolicitacaoCorpo(nome);
        break;
      case 'monitoramento_aprovado':
        titulo = l10n.notifMonitAprovadoTitulo;
        corpo = l10n.notifMonitAprovadoCorpo(nome);
        break;
      case 'monitoramento_negado':
        titulo = l10n.notifMonitNegadoTitulo;
        corpo = l10n.notifMonitNegadoCorpo(nome);
        break;
      case 'monitoramento_bloqueado':
        titulo = l10n.notifMonitBloqueadoTitulo;
        corpo = l10n.notifMonitBloqueadoCorpo(nome);
        break;
      case 'monitoramento_expirado':
        titulo = l10n.notifMonitExpiradoTitulo;
        corpo = l10n.notifMonitExpiradoCorpo(nome);
        break;
      default:
        // Tipo de push de monitoramento ainda não mapeado — ignora em vez
        // de exibir uma notificação vazia/confusa.
        return;
    }

    final bool ehSolicitacao = tipo == 'solicitacao_monitoramento';

    final androidDetails = ehSolicitacao
        ? AndroidNotificationDetails(
            canalSolicitacaoMonitoramentoId,
            canalSolicitacaoMonitoramentoNome,
            channelDescription: canalSolicitacaoMonitoramentoDescricao,
            importance: Importance.max,
            priority: Priority.high,
            fullScreenIntent: true,
            autoCancel: true,
            playSound: true,
            visibility: NotificationVisibility.public,
            vibrationPattern: Int64List.fromList([0, 800, 400, 800]),
            // Ações rápidas [Aceitar]/[Recusar] direto na notificação
            // (pedido explícito do usuário, 2026-09-06) — mesmo padrão já
            // usado pela ação "Cheguei bem" do check-in de rotina
            // ([acaoConfirmarId] acima), mas aqui com `showsUserInterface:
            // true`: ao contrário do check-in (100% local/SQLite), a
            // decisão aqui grava no Firestore e exige sessão autenticada
            // (ver [MonitoramentoService.responderSolicitacao]) — a
            // barreira de login do app (ver política de segurança em
            // `main.dart`) precisa continuar valendo mesmo para quem
            // decide direto pela notificação, então o toque em qualquer
            // uma das duas ações ainda abre o app (rápido, sem exibir o
            // modal de confirmação de novo — ver
            // [_processarRespostaPayloadJson]), nunca decide 100%
            // headless. O toque no CORPO da notificação (sem `actionId`)
            // continua abrindo o modal completo normalmente, para quem
            // preferir revisar antes de decidir.
            actions: [
              AndroidNotificationAction(
                acaoRecusarMonitoramentoId,
                _labelAcaoRecusarMonitoramento,
                showsUserInterface: true,
                cancelNotification: true,
              ),
              AndroidNotificationAction(
                acaoAceitarMonitoramentoId,
                _labelAcaoAceitarMonitoramento,
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ],
          )
        : AndroidNotificationDetails(
            canalMonitoramentoId,
            canalMonitoramentoNome,
            channelDescription: canalMonitoramentoDescricao,
            importance: Importance.high,
            priority: Priority.high,
            autoCancel: true,
          );

    // iOS: só a SOLICITAÇÃO (que exige decisão) ganha `.timeSensitive` +
    // a categoria com as ações [Aceitar]/[Recusar] registradas em
    // [inicializar]; as respostas informativas usam `.active` normal,
    // sem categoria (sem ações, mesmo padrão do canal Android acima).
    final darwinDetails = ehSolicitacao
        ? const DarwinNotificationDetails(
            categoryIdentifier: _categoriaIosSolicitacaoMonitoramento,
            interruptionLevel: InterruptionLevel.timeSensitive,
          )
        : const DarwinNotificationDetails(
            interruptionLevel: InterruptionLevel.active,
          );

    final details = NotificationDetails(android: androidDetails, iOS: darwinDetails);
    final payload = jsonEncode({
      'tipo': 'monitoramento_push',
      'subTipo': tipo,
      'idPermissao': idPermissao,
      // Só preenchidos para 'solicitacao_monitoramento' (ver
      // FcmService._tratarPushMonitoramento) — usados pelo deep link em
      // [_processarRespostaPayloadJson] para abrir o modal de decisão
      // direto, sem precisar de uma nova consulta ao Firestore.
      if (uidSolicitante != null) 'uidSolicitante': uidSolicitante,
      if (tipo == 'solicitacao_monitoramento') 'nomeSolicitante': nomeContraparte ?? '',
      if (telefoneSolicitante != null) 'telefoneSolicitante': telefoneSolicitante,
    });

    await _plugin.show(
      // Faixa de id dedicada — evita colidir com check-in (idAlarme),
      // alarme completo (idAlarme+10000) e alerta recebido (30000+...).
      90000 + (idPermissao.hashCode.abs() % 9000),
      titulo,
      corpo,
      details,
      payload: payload,
    );
  }

  /// Exibe a notificação de confirmação "alerta enviado" — usada
  /// especificamente pelo gesto de descarte do Alarme de Rotina (arrastar
  /// o botão azul/teclado de PIN para cima, ver
  /// `AlarmeDisparadoScreen._descartarPorArraste`), o único caso em que o
  /// app precisa devolver a tela 100% ao Android ANTES de conseguir
  /// mostrar qualquer confirmação — por isso vira uma notificação do
  /// sistema, em vez do diálogo/tela cheia in-app usado nos demais
  /// disparos (3ª tentativa de PIN incorreta, tempo esgotado etc., que já
  /// mostram a própria tela verde de confirmação sem precisar disto).
  static Future<void> exibirNotificacaoAlertaEnviado() async {
    await inicializar();
    final l10n = await L10nHeadlessService.obter();

    final androidDetails = AndroidNotificationDetails(
      canalAlertaEnviadoId,
      canalAlertaEnviadoNome,
      channelDescription: canalAlertaEnviadoDescricao,
      importance: Importance.low,
      priority: Priority.low,
      autoCancel: true,
      playSound: false,
    );

    // iOS: `.passive` — só aparece na Central de Notificações, sem
    // banner/som, equivalente à `Importance.low` sem som do Android.
    const darwinDetails = DarwinNotificationDetails(
      presentSound: false,
      interruptionLevel: InterruptionLevel.passive,
    );

    final details = NotificationDetails(android: androidDetails, iOS: darwinDetails);

    await _plugin.show(
      // Id fixo e estável: não há necessidade de múltiplas notificações
      // deste tipo simultâneas — uma nova sempre substitui a anterior.
      70000,
      l10n.notifDescarteAlertaEnviadoTitulo,
      l10n.notifDescarteAlertaEnviadoCorpo,
      details,
    );
  }

  /// Cancela (remove) a notificação de check-in de rotina exibida para
  /// o [idAlarme] informado. Chamado tanto quando o usuário confirma o
  /// Notificação do despertador do iOS (sem AlarmKit): sensível ao tempo,
  /// com o som escolhido ([som], .caf em Library/Sounds), a ação
  /// "Desativar despertador" e gatilho no fuso local. Em primeiro plano não
  /// mostra banner nem toca (a própria tela do despertador já toca o som).
  static Future<void> agendarNotificacaoDespertador({
    required int id,
    required DateTime quando,
    required String titulo,
    required String corpo,
    required String payload,
    String? som,
    String categoria = categoriaIosDespertador,
  }) async {
    if (!Platform.isIOS || !quando.isAfter(DateTime.now())) return;
    await inicializar();
    await _plugin.zonedSchedule(
      id,
      titulo,
      corpo,
      tz.TZDateTime.from(quando, tz.local),
      NotificationDetails(
        iOS: DarwinNotificationDetails(
          sound: som,
          presentSound: false,
          presentBanner: false,
          presentList: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
          categoryIdentifier: categoria,
          threadIdentifier: categoria,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: payload,
    );
  }

  /// Notificações agendadas e ainda não entregues (iOS: limite de 64).
  static Future<List<PendingNotificationRequest>> notificacoesPendentes() async {
    await inicializar();
    try {
      return await _plugin.pendingNotificationRequests();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> cancelarNotificacao(int id) async {
    await inicializar();
    await _plugin.cancel(id);
  }

  /// Aviso imediato, com banner (ex.: "Despertador desativado (pausado)").
  static Future<void> exibirAvisoDespertador({
    required int id,
    required String titulo,
    required String corpo,
  }) async {
    await inicializar();
    await _plugin.show(
      id,
      titulo,
      corpo,
      NotificationDetails(
        android: AndroidNotificationDetails(canalId, canalNome),
        iOS: const DarwinNotificationDetails(interruptionLevel: InterruptionLevel.active),
      ),
    );
  }

  /// Aviso informativo agendado localmente (sem servidor) — usado pelos
  /// avisos do botão SOS no Plano Free (ver `SosPlanoAvisoService`).
  /// [quando] no passado não agenda nada.
  static Future<void> agendarAvisoLocal({
    required int id,
    required String titulo,
    required String corpo,
    required DateTime quando,
    String? payload,
  }) async {
    if (!quando.isAfter(DateTime.now())) return;
    await inicializar();
    await _plugin.zonedSchedule(
      id,
      titulo,
      corpo,
      tz.TZDateTime.from(quando.toUtc(), tz.UTC),
      NotificationDetails(
        android: AndroidNotificationDetails(canalId, canalNome),
        iOS: const DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  /// Exibe agora um aviso informativo (mesmo formato de [agendarAvisoLocal]).
  static Future<void> exibirAvisoLocal({
    required int id,
    required String titulo,
    required String corpo,
    String? payload,
  }) async {
    await inicializar();
    await _plugin.show(
      id,
      titulo,
      corpo,
      NotificationDetails(
        android: AndroidNotificationDetails(canalId, canalNome),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: payload,
    );
  }

  static Future<void> cancelarAvisoLocal(int id) async {
    await inicializar();
    await _plugin.cancel(id);
  }

  /// check-in quanto quando o disparo de emergência já ocorreu (a
  /// notificação de pedido de confirmação não faz mais sentido).
  static Future<void> cancelarNotificacaoCheckin(int idAlarme) async {
    await inicializar();
    await _plugin.cancel(idAlarme);
    // Migração iOS: limpa também os lembretes agendados via
    // [agendarLembretesCheckinRotinaIOS] — no-op completo no Android.
    // Reaproveitando este único método existente, TODO call site já
    // existente em `RotinaAlarmeService` (cancelarAlarme/pausarAlarme/
    // pausarAlarmePorHoje/confirmarCheckinRotina, todos já chamam
    // [cancelarNotificacaoCheckin]) ganha a limpeza no iOS de graça, sem
    // precisar de nenhuma chamada nova nesses lugares.
    await cancelarLembretesCheckinRotinaIOS(idAlarme);
  }

  static int _idCheckinUnicoIOS(int idAlarme) => 300000 + idAlarme;
  static int _idJanelaFinalUnicoIOS(int idAlarme) => 400000 + idAlarme;
  static int _idCheckinRecorrenteIOS(int idAlarme, int dia) =>
      100000 + idAlarme * 10 + dia;
  static int _idJanelaFinalRecorrenteIOS(int idAlarme, int dia) =>
      200000 + idAlarme * 10 + dia;

  /// Próxima ocorrência (podendo ser hoje, se o horário ainda não tiver
  /// passado) do [diaSemana] informado (1=segunda...7=domingo, mesmo
  /// padrão de `DateTime.weekday`) às [hora]:[minuto] — mesmo algoritmo
  /// de `RotinaAlarmeService._calcularProximoDisparo`, só que para um
  /// único dia por vez (aqui cada dia da semana selecionado ganha seu
  /// próprio lembrete RECORRENTE, ver [agendarLembretesCheckinRotinaIOS]).
  static DateTime _proximaOcorrenciaSemanalIOS(
      int diaSemana, int hora, int minuto) {
    final agora = DateTime.now();
    for (int offset = 0; offset < 8; offset++) {
      final candidatoData = agora.add(Duration(days: offset));
      if (candidatoData.weekday != diaSemana) continue;
      final candidato = DateTime(
          candidatoData.year, candidatoData.month, candidatoData.day, hora, minuto);
      if (candidato.isAfter(agora)) return candidato;
    }
    // Defensivo — 8 dias sempre cobre uma semana inteira, nunca deveria
    // chegar aqui de verdade.
    return DateTime(agora.year, agora.month, agora.day, hora, minuto)
        .add(const Duration(days: 7));
  }

  /// MIGRAÇÃO iOS (decisão de produto, 2026-09-12): substitui, SÓ no iOS,
  /// o papel do `android_alarm_manager_plus` (sem implementação nessa
  /// plataforma) para o alarme de rotina — ver
  /// `RotinaAlarmeService.agendarAlarme`. No Android, é um no-op
  /// completo (`Platform.isIOS` logo no início) — o fluxo Android
  /// continua 100% no `android_alarm_manager_plus`, sem nenhuma alteração
  /// de comportamento.
  ///
  /// Agenda dois LEMBRETES locais por dia da semana selecionado
  /// ([diasSemanaCsv], mesmo formato CSV do SQLite): o check-in no
  /// horário exato e um aviso de "última chance" ao expirar a
  /// tolerância. Usa `matchDateTimeComponents: DateTimeComponents.
  /// dayOfWeekAndTime` — uma notificação RECORRENTE semanal nativa do
  /// iOS, que nunca precisa de nenhum código Dart rodando em segundo
  /// plano para se re-agendar (ao contrário do Android, que rechama
  /// [RotinaAlarmeService.agendarAlarme] a cada disparo do callback
  /// headless) — o próprio SO repete a notificação todo dia da semana
  /// escolhido, indefinidamente, até este alarme ser cancelado/editado.
  ///
  /// IMPORTANTE — o que este método NÃO faz: não dispara o alerta de
  /// emergência sozinho se o usuário nunca interagir. Isso é papel
  /// exclusivo da Cloud Function já implantada
  /// `functions/scheduledAlarmMonitor.js` (alimentada por
  /// [BackgroundLocationHeartbeatService], 100% Dart/Firestore, sem
  /// nenhuma dependência deste método) — a garantia real de entrega no
  /// iOS vem de lá, nunca de uma notificação local, que o SO pode até
  /// suprimir/atrasar em cenários extremos (Modo Foco, armazenamento
  /// cheio, etc.).
  ///
  /// Sem dia da semana válido em [diasSemanaCsv] (mesmo fallback de
  /// `RotinaAlarmeService._calcularProximoDisparo`): agenda um único
  /// lembrete não-recorrente para hoje, SE [hora]:[minuto] ainda não
  /// tiver passado — nunca lança exceção, apenas não agenda nada nesse
  /// caso (mesmo comportamento do Android).
  static Future<void> agendarLembretesCheckinRotinaIOS({
    required int idAlarme,
    required String etiqueta,
    required int hora,
    required int minuto,
    required String diasSemanaCsv,
    required int minutosTolerancia,
  }) async {
    if (!Platform.isIOS) return;
    await inicializar();
    await cancelarLembretesCheckinRotinaIOS(idAlarme);

    final l10n = await L10nHeadlessService.obter();
    final String tituloCheckin = etiqueta.isNotEmpty ? etiqueta : l10n.familiaEtiquetaPadrao;
    final String corpoCheckin = l10n.notifCheckinCorpo;
    final String tituloJanelaFinal = l10n.notifAlarmeSegurancaTitulo;
    final String corpoJanelaFinal = l10n.notifAlarmeSegurancaCorpo;

    const darwinCheckin = DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    // Sem `categoryIdentifier`/ação "pausar_alarme" aqui de propósito:
    // esta é uma notificação NOVA, sem contrapartida direta no Android
    // (lá, a janela final é 100% via a Activity nativa sobre o
    // lockscreen, nunca uma notificação `flutter_local_notifications`) —
    // um toque simplesmente abre o app na tela de confirmação, sem a
    // ambiguidade de "pausar o alarme inteiro" numa notificação que
    // representa a ÚLTIMA CHANCE.
    const darwinJanelaFinal = DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    final Set<int> diasSemana = diasSemanaCsv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((d) => d >= 1 && d <= 7)
        .toSet();

    if (diasSemana.isNotEmpty) {
      for (final dia in diasSemana) {
        final proximaOcorrencia = _proximaOcorrenciaSemanalIOS(dia, hora, minuto);
        final janelaFinalMomento =
            proximaOcorrencia.add(Duration(minutes: minutosTolerancia));
        try {
          await _plugin.zonedSchedule(
            _idCheckinRecorrenteIOS(idAlarme, dia),
            tituloCheckin,
            corpoCheckin,
            tz.TZDateTime.from(proximaOcorrencia.toUtc(), tz.UTC),
            const NotificationDetails(iOS: darwinCheckin),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: idAlarme.toString(),
          );
          await _plugin.zonedSchedule(
            _idJanelaFinalRecorrenteIOS(idAlarme, dia),
            tituloJanelaFinal,
            corpoJanelaFinal,
            tz.TZDateTime.from(janelaFinalMomento.toUtc(), tz.UTC),
            const NotificationDetails(iOS: darwinJanelaFinal),
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: 'alarme_$idAlarme',
          );
        } catch (e) {
          debugPrint('⚠️ [NotificacaoService] Falha ao agendar lembrete iOS '
              '(dia $dia) do alarme #$idAlarme: $e');
        }
      }
      return;
    }

    // Fallback sem dia da semana válido — mesmo comportamento do
    // Android: só agenda se o horário de hoje ainda não tiver passado.
    final agora = DateTime.now();
    final candidato = DateTime(agora.year, agora.month, agora.day, hora, minuto);
    if (candidato.isBefore(agora)) return;
    final janelaFinalCandidato = candidato.add(Duration(minutes: minutosTolerancia));
    try {
      await _plugin.zonedSchedule(
        _idCheckinUnicoIOS(idAlarme),
        tituloCheckin,
        corpoCheckin,
        tz.TZDateTime.from(candidato.toUtc(), tz.UTC),
        const NotificationDetails(iOS: darwinCheckin),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: idAlarme.toString(),
      );
      await _plugin.zonedSchedule(
        _idJanelaFinalUnicoIOS(idAlarme),
        tituloJanelaFinal,
        corpoJanelaFinal,
        tz.TZDateTime.from(janelaFinalCandidato.toUtc(), tz.UTC),
        const NotificationDetails(iOS: darwinJanelaFinal),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: 'alarme_$idAlarme',
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao agendar lembrete único '
          'iOS do alarme #$idAlarme: $e');
    }
  }

  /// Cancela TODOS os ids possíveis (recorrentes de 1-7 + os de
  /// fallback único) agendados por [agendarLembretesCheckinRotinaIOS]
  /// para [idAlarme] — sempre seguro/idempotente cancelar um id que
  /// nunca existiu (no-op), então não precisa saber de antemão qual
  /// variante (recorrente ou única) foi usada. No-op completo no
  /// Android.
  static Future<void> cancelarLembretesCheckinRotinaIOS(int idAlarme) async {
    if (!Platform.isIOS) return;
    try {
      await _plugin.cancel(_idCheckinUnicoIOS(idAlarme));
      await _plugin.cancel(_idJanelaFinalUnicoIOS(idAlarme));
      for (int dia = 1; dia <= 7; dia++) {
        await _plugin.cancel(_idCheckinRecorrenteIOS(idAlarme, dia));
        await _plugin.cancel(_idJanelaFinalRecorrenteIOS(idAlarme, dia));
      }
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao cancelar lembretes iOS '
          'do alarme #$idAlarme: $e');
    }
  }

  /// Handler chamado quando o usuário interage com a notificação
  /// (toque no corpo ou na ação "Cheguei bem") com o app em primeiro
  /// plano ou no processo principal já ativo.
  static void _aoReceberRespostaEmPrimeiroPlano(
      NotificationResponse resposta) {
    _processarResposta(resposta);
  }

  /// Handler chamado pelo Android em um isolate headless separado
  /// quando o usuário interage com a notificação (ex: toca "Cheguei
  /// bem") com o app COMPLETAMENTE fechado. Precisa ser uma função
  /// top-level ou estática anotada com `@pragma('vm:entry-point')`.
  @pragma('vm:entry-point')
  static void _aoReceberRespostaEmSegundoPlano(
      NotificationResponse resposta) {
    _processarResposta(resposta);
  }

  /// Lógica compartilhada entre os dois handlers (primeiro e segundo
  /// plano): se a ação tocada foi "Cheguei bem", confirma o check-in de
  /// rotina correspondente via [RotinaAlarmeService], cancelando o
  /// alarme de tolerância agendado e registrando o evento no histórico.
  static void _processarResposta(NotificationResponse resposta) {
    final payload = resposta.payload ?? '';

    // Payload JSON — alerta de emergência de OUTRO usuário (ver
    // exibirNotificacaoAlertaRecebido) ou push da aba Monitoramento (ver
    // exibirNotificacaoMonitoramento), distintos do alarme de rotina do
    // próprio usuário tratado no restante deste método.
    if (payload.startsWith('{')) {
      _processarRespostaPayloadJson(payload, actionId: resposta.actionId);
      return;
    }

    // Despertador do iOS: toque na notificação ou em "Desativar
    // despertador" abre a tela do despertador com o idAlarme e a ocorrência.
    if (payload.startsWith(DespertadorIosService.prefixoPayload) ||
        payload.startsWith(CronometroIosService.prefixoPayload)) {
      unawaited(DespertadorIosService().abrirPorPayload(payload, tecladoDireto: true));
      return;
    }
    if (Platform.isIOS) {
      // Lembretes antigos (antes do despertador por ocorrência): abre a
      // ocorrência em andamento desse alarme, se houver.
      final idLegado = int.tryParse(payload.replaceFirst('alarme_', ''));
      if (idLegado != null) {
        unawaited(DespertadorIosService().abrirOcorrenciaEmAndamento(idLegado, tecladoDireto: true));
      }
      return;
    }

    final idAlarme = int.tryParse(payload.startsWith('alarme_')
        ? payload.replaceFirst('alarme_', '')
        : payload);

    if (idAlarme == null) return;

    if (resposta.actionId == acaoConfirmarId) {
      // 1. Gravação síncrona de prioridade máxima no disco para cessar o loop do reprodutor em background
      SharedPreferences.getInstance().then((prefs) async {
        await prefs.setBool('stop_current_alarm', true);
        await prefs.remove('alarme_disparando_no_momento');
        debugPrint('⏹️ [NotificacaoService] Flags de cancelamento persistidas no disco.');
      }).catchError((e) {
        debugPrint('⚠️ Erro ao persistir cancelamento no SharedPreferences: $e');
      });

      // 2. Tenta fazer a limpeza silenciosa das rotinas locais
      RotinaAlarmeService.pausarAlarme(idAlarme).then((_) async {
        // 3. Atualiza e remove o destaque da notificação
        final l10n = await L10nHeadlessService.obter();
        _plugin.show(
          idAlarme,
          l10n.familiaEtiquetaPadrao,
          l10n.notifCheckinCanceladoCorpo,
          NotificationDetails(
            android: AndroidNotificationDetails(
              canalId,
              canalNome,
              importance: Importance.low,
              priority: Priority.low,
              ongoing: false,
              autoCancel: true,
            ),
            iOS: const DarwinNotificationDetails(
              presentSound: false,
              interruptionLevel: InterruptionLevel.passive,
            ),
          ),
        );
      }).catchError((e) {
        debugPrint('⚠️ Falha ao registrar pausa no service: $e');
      });
      
    } else if (resposta.actionId == 'pausar_alarme') {
      RotinaAlarmeService.pausarAlarme(idAlarme).catchError((e) {
        debugPrint('⚠️ Falha ao pausar alarme: $e');
      });
    } else if (resposta.actionId == null) {
      appNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (context) => AlarmeDisparadoScreen(idAlarme: idAlarme)),
      );
    }
  }

  /// Decodifica um payload JSON de notificação e roteia para a tela
  /// correta conforme o campo `tipo`:
  /// - `'monitoramento_push'` (ver [exibirNotificacaoMonitoramento]): abre
  ///   a HomeScreen diretamente na aba Monitoramento (índice 2) — ou, se
  ///   [actionId] for uma das ações rápidas [Aceitar]/[Recusar] (ver
  ///   [acaoAceitarMonitoramentoId]/[acaoRecusarMonitoramentoId]),
  ///   resolve a solicitação DIRETO, sem exibir o modal de confirmação de
  ///   novo (o usuário já decidiu ao tocar a ação específica).
  /// - qualquer outro valor (compatibilidade com payloads antigos, ver
  ///   [exibirNotificacaoAlertaRecebido]): alerta de emergência de
  ///   terceiro, navega para [AlertaRecebidoScreen].
  ///
  /// Protegido contra payload malformado — nunca deixa a interação com a
  /// notificação derrubar o app.
  static Future<void> _processarRespostaPayloadJson(String payload, {String? actionId}) async {
    try {
      final dados = jsonDecode(payload) as Map<String, dynamic>;

      if (dados['tipo'] == 'monitoramento_push') {
        final subTipo = dados['subTipo'] as String?;
        final idPermissao = dados['idPermissao'] as String?;
        final uidSolicitante = dados['uidSolicitante'] as String?;
        final ehSolicitacao = subTipo == 'solicitacao_monitoramento' &&
            idPermissao != null &&
            uidSolicitante != null;

        // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06): o
        // toque numa notificação (incluindo as ações rápidas
        // [Aceitar]/[Recusar]) pode ser entregue por
        // `onDidReceiveBackgroundNotificationResponse` — um ISOLATE Dart
        // totalmente NOVO e separado do engine principal do app (mesma
        // limitação já documentada em `firebaseMessagingBackgroundHandler`,
        // em `fcm_service.dart`), onde `Firebase.apps` sempre começa
        // VAZIO. Antes desta correção, isso fazia `autenticado` abaixo dar
        // sempre `false` nesse cenário — mesmo com uma sessão válida
        // persistida em disco — e a ação [Aceitar]/[Recusar] nunca
        // chegava a chamar [MonitoramentoService.responderSolicitacao] de
        // verdade: só caía no fallback de "sem sessão agora" (guardar o
        // payload para a LoginScreen), que nem se aplica aqui (não há
        // barreira de login real neste cenário — a sessão existe, só não
        // nesta isolate específica). Resultado observado: o modal de
        // decisão "fantasma" de [MonitoramentoTab]/do caminho nativo
        // sempre vencia, porque a resolução direta nunca tinha, de fato,
        // acontecido. `Firebase.initializeApp()` aqui restaura a sessão já
        // persistida (não é um novo login) — mesmo padrão já usado com
        // sucesso em `firebaseMessagingBackgroundHandler`.
        if (Firebase.apps.isEmpty) {
          try {
            await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
          } catch (e) {
            debugPrint('⚠️ [NotificacaoService] Falha ao inicializar Firebase nesta isolate: $e');
          }
        }

        // Redirecionamento direto (deep link): só para uma SOLICITAÇÃO
        // recebida (não uma resposta a uma solicitação já enviada) e só
        // quando o usuário já está autenticado NESTA sessão do app — fora
        // disso (sem login em NENHUM lugar, cenário genuinamente sem
        // sessão) cai no fallback abaixo, que apenas abre a aba
        // Monitoramento normalmente.
        final autenticado =
            Firebase.apps.isNotEmpty && FirebaseAuthService().uidAtual != null;

        // Ação rápida [Aceitar]/[Recusar] tocada direto na notificação
        // (pedido explícito do usuário, 2026-09-06) — resolve na hora,
        // sem reabrir o modal, sempre que já houver sessão. A barreira de
        // login continua obrigatória: sem sessão agora, cai no mesmo
        // fallback de payload pendente abaixo, carregando a ação
        // escolhida para a LoginScreen aplicar depois do login.
        if (ehSolicitacao &&
            autenticado &&
            (actionId == acaoAceitarMonitoramentoId ||
                actionId == acaoRecusarMonitoramentoId)) {
          // Marca (em disco — ver documentação completa em
          // [MonitoramentoService.marcarResolvidoDireto]) ANTES de
          // escrever no Firestore, e AGUARDADA: esta função pode estar
          // rodando numa isolate headless que o SO pode encerrar assim
          // que ela retornar — sem `await` aqui, tanto a marca quanto a
          // escrita abaixo arriscam nunca completar de verdade.
          await MonitoramentoService.marcarResolvidoDireto(idPermissao);
          await MonitoramentoService().responderSolicitacao(
            permissaoId: idPermissao,
            aprovar: actionId == acaoAceitarMonitoramentoId,
            uidSolicitante: uidSolicitante,
            nomeSolicitante: (dados['nomeSolicitante'] as String?) ?? '',
            telefoneSolicitante: (dados['telefoneSolicitante'] as String?) ?? '',
          );
          return;
        }

        if (ehSolicitacao && autenticado) {
          final context = appNavigatorKey.currentContext;
          if (context != null) {
            exibirDialogoDecisaoMonitoramento(
              context: context,
              idPermissao: idPermissao,
              uidSolicitante: uidSolicitante,
              nomeSolicitante: (dados['nomeSolicitante'] as String?) ?? '',
              telefoneSolicitante: (dados['telefoneSolicitante'] as String?) ?? '',
            );
            return;
          }
        }

        if (ehSolicitacao && !autenticado) {
          // Sem sessão ativa agora (barreira de login obrigatória à
          // frente, ver política de segurança em `main.dart`) — NUNCA
          // pula o login. Só guarda o payload (+ qual ação rápida foi
          // tocada, se alguma — ver `acaoDireta` abaixo) para a
          // LoginScreen aplicar a MESMA decisão assim que o login
          // terminar com sucesso, em vez de deixar a solicitação se
          // perder ou reabrir o modal por cima de uma decisão que o
          // usuário já tinha tomado ao tocar a ação da notificação.
          payloadSolicitacaoPendente = {
            ...dados,
            if (actionId == acaoAceitarMonitoramentoId ||
                actionId == acaoRecusarMonitoramentoId)
              'acaoDireta': actionId,
          };
          return;
        }

        appNavigatorKey.currentState?.push(
          MaterialPageRoute(
            builder: (context) => const HomeScreen(abaInicial: 2),
          ),
        );
        return;
      }

      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, Moto
      // G7 Play — "vibrou e não consegui fazer parar"): antes, parar o
      // alarme sonoro/vibração insistente (`FLAG_INSISTENT`) só acontecia
      // DENTRO de [AlertaRecebidoScreen] (`initState`) — ou seja,
      // dependia inteiramente do `push()` abaixo ter sucesso. Mas esta
      // função também roda no isolate HEADLESS de
      // `onDidReceiveBackgroundNotificationResponse` (toque na
      // notificação com o app TOTALMENTE fechado) — nesse isolate NUNCA
      // existe `runApp()`/Navigator, então `appNavigatorKey.currentState`
      // é sempre `null` e `?.push(...)` é um NO-OP silencioso: a tela
      // nunca abria, [cancelarNotificacaoAlertaRecebido] nunca era
      // chamado, e a notificação (com sua vibração/som em loop,
      // `Notification.FLAG_INSISTENT`) ficava tocando/vibrando PARA
      // SEMPRE, sem nenhuma forma de parar a não ser matar o app pelo
      // sistema. Agora, parar o alarme e cancelar a notificação
      // acontecem AQUI, incondicionalmente, ANTES da tentativa de
      // navegação — [cancelarNotificacaoAlertaRecebido] usa só
      // `flutter_local_notifications` (plugin federado, registrado
      // automaticamente em QUALQUER engine, inclusive headless — ao
      // contrário do MethodChannel customizado usado por
      // [pararAlarmeCritico], protegido por seu próprio try/catch), então
      // funciona de forma confiável não importa o estado do app. A
      // navegação para [AlertaRecebidoScreen] continua best-effort logo
      // abaixo — quando não há Navigator vivo (app fechado), o usuário só
      // vê os detalhes ao reabrir o app manualmente (já persistidos
      // localmente por `AlertasRecebidosService`), mas o alarme já para
      // na hora do toque, não importa o estado do app.
      final idEntregaAlerta = dados['idEntrega'] as String?;
      unawaited(pararAlarmeCritico());
      if (idEntregaAlerta != null) {
        unawaited(cancelarNotificacaoAlertaRecebido(idEntregaAlerta));
      }

      appNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (context) => AlertaRecebidoScreen(
            mensagem: (dados['mensagem'] as String?) ?? '',
            nomeRemetente: dados['nomeRemetente'] as String?,
            latitude: (dados['latitude'] as num?)?.toDouble(),
            longitude: (dados['longitude'] as num?)?.toDouble(),
            fotoUrl: dados['fotoUrl'] as String?,
            idEntrega: idEntregaAlerta,
            recebidoEm: dados['recebidoEm'] as String?,
          ),
        ),
      );
    } catch (e) {
      debugPrint('⚠️ [NotificacaoService] Falha ao processar payload JSON da notificação: $e');
    }
  }

  /// Registra, de forma resiliente (nunca lança exceção), um evento no
  /// histórico administrativo (categoria 'sistema'), usado pelos fluxos
  /// de check-in de rotina confirmados/perdidos.
  static Future<void> registrarEventoSistema({
    required String titulo,
    required String descricao,
  }) async {
    try {
      await DatabaseHelper().inserirEventoHistorico(
        titulo: titulo,
        descricao: descricao,
        categoria: 'sistema',
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao registrar evento de sistema no histórico: $e');
    }
  }
}

/// Callback headless do teto de segurança agendado por
/// [NotificacaoService.exibirNotificacaoAlertaRecebido] — roda num
/// isolate/engine SEPARADO do processo principal (mesmo mecanismo já
/// usado por `RotinaAlarmeService`/`RetryUploadService`), por isso é uma
/// função TOP-LEVEL (fora de qualquer classe) anotada com
/// `@pragma('vm:entry-point')`, obrigatória para o `AndroidAlarmManager`
/// conseguir encontrá-la mesmo depois do tree-shaking do Dart AOT em
/// builds de release.
///
/// Se os 5 minutos se esgotarem sem o usuário ter interagido com a
/// notificação (que já teria cancelado este mesmo alarme, ver
/// [NotificacaoService.cancelarNotificacaoAlertaRecebido]), para o
/// alarme sonoro nativo (best-effort — pode já nem estar tocando, ver
/// documentação completa em [NotificacaoService.exibirNotificacaoAlertaRecebido]
/// sobre por que este teto existe SEPARADO daquele) e cancela a
/// notificação (o que efetivamente encerra o som/vibração insistentes do
/// `flutter_local_notifications`, o caminho que SEMPRE funciona
/// independente do estado do app).
@pragma('vm:entry-point')
void _callbackTimeoutSegurancaAlertaRecebido(int id, Map<String, dynamic> params) async {
  final idEntrega = params['idEntrega'] as String?;
  if (idEntrega == null) return;

  debugPrint('⏰ [HEADLESS] Teto de segurança (5min) do alerta recebido '
      '#$idEntrega atingido sem confirmação — parando o alarme.');

  await NotificacaoService.pararAlarmeCritico();
  await NotificacaoService.cancelarNotificacaoAlertaRecebido(idEntrega);
}