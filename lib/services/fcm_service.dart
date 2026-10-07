import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../firebase_options.dart';
import '../screens/alerta_recebido_screen.dart';
import '../widgets/monitoramento_decisao_dialog.dart';
import 'alertas_recebidos_service.dart';
import 'aviso_entrega_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'notificacao_service.dart';
import 'relatorio_falha_entrega_service.dart';

/// Handler de SEGUNDO PLANO/TERMINADO do FCM — chamado pelo Android num
/// ISOLATE/ENGINE TOTALMENTE SEPARADO, sem NENHUM estado compartilhado
/// com o processo principal do app.
///
/// REESPECIFICAÇÃO DO USUÁRIO (2026-08-15, requisitos oficiais do
/// Flutter/FlutterFire): antes, este handler era um método ESTÁTICO
/// dentro da classe [FcmService] — funciona na prática na maioria dos
/// casos, mas diverge do padrão oficial documentado pela própria
/// FlutterFire (`FirebaseMessaging.onBackgroundMessage`), que exige uma
/// função TOP-LEVEL (fora de qualquer classe), não um método de classe
/// "que precise de inicialização". Diagnosticado ao vivo via logcat
/// (2026-08-15): o broadcast nativo do FCM chegava
/// (`FLTFireMsgReceiver: broadcast received for message`), mas a engine
/// Flutter de background nunca era instanciada
/// (`FLTFireBGExecutor: Creating background FlutterEngine instance`
/// nunca aparecia nos logs) — o Android ficava reagendando via
/// `AlarmManager: setExactAndAllowWhileIdle [name: FcmRetry...]`
/// repetidamente, sem nunca completar. Descoberto em paralelo que o
/// "Battery Care"/"Smart Background" PRÓPRIO da Motorola também
/// restringia o app (`BatteryCare: [SmartBackgroundController] skip
/// foreground package`, fora do controle deste código — precisa de
/// ajuste manual nas configurações do aparelho), mas mover este handler
/// para o formato 100% conforme à documentação oficial é a correção de
/// código correta e a que efetivamente está ao alcance do app, eliminando
/// de vez a divergência como possível causa/agravante.
///
/// `@pragma('vm:entry-point')` é OBRIGATÓRIO: sem ele, o compilador
/// Dart AOT (release) pode fazer tree-shaking desta função por não
/// enxergar nenhuma chamada estática a ela no código (só é referenciada
/// via callback handle nativo) — resultando exatamente no sintoma
/// observado (nada acontece em segundo plano, sem nenhuma exceção
/// visível). `WidgetsFlutterBinding.ensureInitialized()` também é
/// exigido pela documentação oficial antes de usar qualquer plugin
/// (`flutter_local_notifications`, `http`, `Firebase`) neste isolate
/// novo/isolado — sem binding próprio, sem estado compartilhado com o
/// processo principal.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage mensagem) async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('📩 [FCM Recebido - Background] ${mensagem.data}');
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
    // Requisito 4 (renderização nativa a partir do isolate de
    // background): [FcmService._tratarDadosDoAlerta] já despacha para
    // [NotificacaoService.exibirNotificacaoAlertaRecebido], que monta o
    // canal de alta prioridade (`Importance.max`) com `fullScreenIntent:
    // true` e `audioAttributesUsage: AudioAttributesUsage.alarm` (som
    // roteado pelo STREAM_ALARM) via `flutter_local_notifications` —
    // funciona sem alterações a partir deste isolate, já que o plugin
    // (diferente de plugins locais customizados deste app, ver
    // `SmsSender.kt`) é registrado automaticamente em QUALQUER engine
    // Flutter, inclusive este headless.
    // iOS: com o bloco `apns` (ver `functions/apnsPayload.js`) quem
    // EXIBE o banner é o próprio sistema — aqui só falta o ACK/registro
    // local; exibir também a notificação local duplicaria o aviso.
    await FcmService()._tratarDadosDoAlerta(
      mensagem.data,
      exibirNotificacaoLocal: !_sistemaJaExibiu(mensagem),
    );
  } catch (e) {
    debugPrint('⚠️ [FcmService] Falha ao processar mensagem em segundo plano: $e');
  }
}

/// `true` quando o próprio iOS já exibiu este Push como banner (mensagem
/// com bloco `apns.payload.aps.alert`, ver `functions/apnsPayload.js`).
/// No Android as mensagens continuam data-only, então é sempre `false`.
bool _sistemaJaExibiu(RemoteMessage mensagem) =>
    Platform.isIOS && mensagem.notification != null;

/// Serviço central do lado "guardião" da arquitetura híbrida de alertas:
/// mantém o `fcmToken` do aparelho sincronizado com
/// `usuarios/{uid}.fcmToken` (é por ele que a Cloud Function resolve para
/// onde mandar o Push App-para-App gratuito, ver
/// `functions/alertaHibridoService.js`) e trata as mensagens recebidas em
/// primeiro plano, segundo plano e com o app totalmente fechado.
///
/// As mensagens do pipeline de alerta são DATA-ONLY (sem o campo
/// `notification`, ver `enviarFcmParaContatos` no backend) — de
/// propósito, para que este serviço tenha controle total sobre COMO a
/// notificação é exibida (tela cheia sobre a lockscreen, mesmo padrão de
/// `NotificacaoService.exibirNotificacaoAlarmeCompleto`) em vez de deixar
/// o Android exibir automaticamente uma notificação padrão do sistema.
///
/// CONFIRMAÇÃO DE ENTREGA: grava em `entregas_alerta/{id}/confirmacoes`
/// que o Push foi ENTREGUE NO DISPOSITIVO — não quando o usuário abre o
/// app ou lê a notificação. Este serviço grava essa confirmação assim
/// que `onMessage`/`onBackgroundMessage` executa (ver
/// [_tratarDadosDoAlerta]), o que acontece automaticamente na entrega da
/// mensagem pelo SO, mesmo com a tela bloqueada e o app fechado — nunca
/// depende de interação do usuário.
class FcmService {
  FcmService._internal();
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;

  static const String _tipoAlertaEmergencia = 'alerta_emergencia';

  /// Nudge silencioso do relatório de falha de 48h (ver
  /// `functions/relatorioFalhaService.js`/[RelatorioFalhaEntregaService])
  /// — NUNCA exibe notificação, apenas grava um evento local no cofre de
  /// Auditoria de Eventos Sensíveis.
  static const String _tipoRelatorioFalhaEntrega = 'relatorio_falha_entrega';

  /// Tipos de push da aba Monitoramento (ver `functions/monitoramentoService.js`
  /// e `functions/monitoramentoExpiracaoMonitor.js`) — notificações NORMAIS
  /// (sem tela cheia, sem confirmação de entrega/transbordo), distintas do
  /// pipeline de alerta de emergência acima.
  static const Set<String> _tiposPushMonitoramento = {
    'solicitacao_monitoramento',
    'monitoramento_aprovado',
    'monitoramento_negado',
    'monitoramento_bloqueado',
    'monitoramento_expirado',
  };

  bool _infraestruturaRegistrada = false;
  bool _listenerDeRenovacaoRegistrado = false;

  /// Registra o handler de background do FCM, solicita a permissão de
  /// notificação (`POST_NOTIFICATIONS`) e liga o listener de primeiro
  /// plano — nada disto depende de um usuário autenticado, então deve
  /// rodar uma única vez por processo, o mais cedo possível (ver
  /// `main.dart`, logo após `Firebase.initializeApp()`).
  ///
  /// CORREÇÃO: antes, todo este registro só acontecia dentro de
  /// [inicializar], chamado exclusivamente em `login_screen.dart` após um
  /// login manual bem-sucedido — na época (antiga política "Opção A",
  /// logout a cada cold start) o app ficava sem sessão logo no início, e
  /// um aparelho recém-instalado (ou que
  /// ainda não completou o primeiro login nesta execução) ficava sem o
  /// handler de background e sem a permissão de notificação armados —
  /// alertas chegando nessa janela eram perdidos silenciosamente. Separar
  /// este registro (sem dependência de login) da sincronização do token
  /// (que precisa de `uid`, ver [inicializar]) resolve isso: agora a
  /// entrega/exibição da notificação funciona independente de estar
  /// logado no momento em que o Push chega.
  Future<void> registrarInfraestrutura() async {
    if (_infraestruturaRegistrada) return;
    if (Firebase.apps.isEmpty) return;

    try {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      await FirebaseMessaging.instance.requestPermission();
      FirebaseMessaging.onMessage.listen(_processarMensagem);
      if (Platform.isIOS) {
        // iOS: o banner do Push é exibido pelo SISTEMA (bloco `apns`), então
        // o toque nele chega por aqui — não pelo
        // `flutter_local_notifications` (que só trata as notificações
        // locais que ele mesmo criou). No Android o toque continua indo
        // pela notificação local montada pelo app.
        FirebaseMessaging.onMessageOpenedApp.listen(_aoTocarPushIos);
        unawaited(_tratarPushQueAbriuOAppIos());
      }
      _infraestruturaRegistrada = true;
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao registrar infraestrutura de FCM: $e');
    }
  }

  /// Sincroniza o `fcmToken` atual do aparelho com `usuarios/{uid}.fcmToken`
  /// — deve ser chamado a cada login bem-sucedido (não só uma vez por
  /// processo: "Sair da conta" em Configurações permite logar de novo com
  /// outra conta sem cold start, ver `configuracoes_tab.dart`), já que
  /// precisa do `uid` da sessão ativa para saber em qual documento gravar.
  /// Garante primeiro que [registrarInfraestrutura] já rodou.
  Future<void> inicializar() async {
    await registrarInfraestrutura();
    if (Firebase.apps.isEmpty) return;

    try {
      final messaging = FirebaseMessaging.instance;

      // Registrado ANTES da espera pelo APNs abaixo: se o token APNs
      // chegar só mais tarde, o token FCM gerado nesse momento chega por
      // aqui e ainda é gravado no Firestore.
      if (!_listenerDeRenovacaoRegistrado) {
        messaging.onTokenRefresh.listen((novoToken) {
          debugPrint('📲 [FcmService] Token FCM renovado pelo SO (...${novoToken.substring(novoToken.length - 12)}) — sincronizando.');
          FirebaseSyncService().atualizarFcmToken(novoToken);
        });
        _listenerDeRenovacaoRegistrado = true;
      }

      // iOS: o token FCM só existe depois que o APNs entrega o token do
      // aparelho — chamar `getToken()` antes disso lança
      // `apns-token-not-set` e NENHUM token é gravado no Firestore (achado
      // no 1º teste no iPhone: `fcmTokenAtualizadoEm` da conta parado na
      // data do último login pelo Android). Espera até ~15s pelo APNs.
      if (Platform.isIOS) {
        String? apnsToken;
        for (var i = 0; i < 30 && apnsToken == null; i++) {
          try {
            apnsToken = await messaging.getAPNSToken();
          } catch (_) {}
          if (apnsToken == null) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
        if (apnsToken == null) {
          debugPrint('⚠️ [FcmService] Token APNs indisponível após aguardar — token FCM não sincronizado nesta sessão.');
          return;
        }
      }

      // CORREÇÃO (bug real confirmado em teste físico, 2026-08-14 — Razr
      // com `fcmToken` gravado no Firestore, mas TODO envio a ele falhava
      // no `[FCM Enviado] 0 enviado(s), 1 falha(s) de 1 token(s)` da Cloud
      // Function): `getToken()` sozinho devolve o token já em CACHE local
      // sempre que existir um — um `pm clear`/reinstalação some com esse
      // cache, mas qualquer outra causa de invalidação do lado do servidor
      // FCM (ex: o token expirar/ser revogado sem o SDK perceber) deixa o
      // cache local "vivo" apontando pra um registro morto, e `getToken()`
      // nunca vai buscar um substituto sozinho. `deleteToken()` força o
      // SDK a esquecer esse cache e negociar um registro NOVO de verdade
      // no próximo `getToken()` — a única forma confiável de garantir que
      // o valor gravado no Firestore é sempre um registro vivo, não uma
      // cópia local potencialmente morta.
      try {
        await messaging.deleteToken();
      } catch (e) {
        debugPrint('⚠️ [FcmService] Falha ao invalidar token em cache (seguindo mesmo assim): $e');
      }

      final token = await messaging.getToken();
      if (token != null) {
        debugPrint('📲 [FcmService] Novo token FCM obtido (...${token.substring(token.length - 12)}) — sincronizando com o Firestore.');
        await FirebaseSyncService().atualizarFcmToken(token);
        debugPrint('📲 [FcmService] Token FCM inicial sincronizado.');
      } else {
        // ANTES: esse caso não gerava NENHUM log — uma falha silenciosa
        // real (getToken() devolvendo null, ex: sem Google Play Services
        // disponível/atualizado) ficava indistinguível de "tudo certo".
        debugPrint('⚠️ [FcmService] getToken() devolveu null — nenhum token para sincronizar com o Firestore.');
      }
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao sincronizar token FCM: $e');
    }
  }

  /// Handler de PRIMEIRO PLANO (app aberto e em uso).
  Future<void> _processarMensagem(RemoteMessage mensagem) async {
    debugPrint('📩 [FCM Recebido - Foreground] ${mensagem.data}');
    // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06): este
    // handler (`FirebaseMessaging.onMessage`) dispara sempre que o
    // ENGINE principal do app está anexado e vivo — o que inclui o app
    // rodando em segundo plano (usuário trocou para outro app/Home,
    // processo não foi morto), não só quando ele está de fato VISÍVEL na
    // tela. Antes, `emPrimeiroPlano` era sempre `true` aqui, então uma
    // solicitação de monitoramento chegando nesse cenário comum (app
    // aberto minutos atrás, agora em segundo plano) abria o modal de
    // decisão MESMO ASSIM — só que invisível atrás da Home/outro app,
    // sem nenhuma notificação na bandeja para avisar o usuário, e o
    // modal só aparecia se/quando ele reabrisse o app manualmente por
    // conta própria. `WidgetsBinding.instance.lifecycleState` distingue
    // os dois casos: só `AppLifecycleState.resumed` significa
    // "realmente na tela agora" — qualquer outro estado (paused,
    // inactive, hidden, detached) cai no [_tratarPushMonitoramento] como
    // segundo plano de verdade, que exibe a notificação com os botões
    // [Aceitar]/[Recusar] em vez de um diálogo que ninguém vê.
    final bool realmenteVisivel =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    await _tratarDadosDoAlerta(mensagem.data, emPrimeiroPlano: realmenteVisivel);

    // iOS com o app aberto: além da notificação local, abre direto a tela
    // do alerta recebido (no Android a notificação de tela cheia já cumpre
    // esse papel).
    if (Platform.isIOS &&
        realmenteVisivel &&
        mensagem.data['tipo'] == _tipoAlertaEmergencia) {
      _abrirTelaAlertaRecebido(mensagem.data);
    }
  }

  /// iOS, cold start: o app estava FECHADO e foi aberto pelo toque no
  /// banner do Push. Nesse caso o handler de background pode nem ter
  /// rodado (o iOS não acorda um app encerrado pelo usuário para
  /// `content-available`), então o ACK/registro local é feito aqui.
  Future<void> _tratarPushQueAbriuOAppIos() async {
    try {
      final mensagem = await FirebaseMessaging.instance.getInitialMessage();
      if (mensagem == null) return;
      await _tratarToqueIos(mensagem, appEstavaFechado: true);
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao tratar Push que abriu o app (iOS): $e');
    }
  }

  /// iOS, app em segundo plano: toque no banner do Push.
  Future<void> _aoTocarPushIos(RemoteMessage mensagem) async {
    try {
      await _tratarToqueIos(mensagem, appEstavaFechado: false);
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao tratar toque no Push (iOS): $e');
    }
  }

  Future<void> _tratarToqueIos(
    RemoteMessage mensagem, {
    required bool appEstavaFechado,
  }) async {
    final data = mensagem.data;
    final tipo = data['tipo'] as String?;
    debugPrint('👆 [FcmService] Toque no Push (iOS, tipo=$tipo, app fechado=$appEstavaFechado)');

    if (tipo == _tipoAlertaEmergencia) {
      // Idempotente: ACK e registro local ignoram repetição (ver
      // `inserirAlertaTerceiroRecebido`, `ConflictAlgorithm.ignore`).
      await _tratarAlertaEmergencia(data, exibirNotificacaoLocal: false);
      _abrirTelaAlertaRecebido(data, substituirPilha: appEstavaFechado);
      return;
    }

    if (tipo == 'solicitacao_monitoramento') {
      final idPermissao = data['idPermissao'] as String?;
      final uidSolicitante = data['uidSolicitante'] as String?;
      if (idPermissao == null || uidSolicitante == null) return;
      final nome = (data['nomeSolicitante'] as String?) ?? '';
      final telefone = (data['telefoneSolicitante'] as String?) ?? '';
      final abriu = !appEstavaFechado &&
          await _tentarAbrirDecisaoDireto(
            idPermissao: idPermissao,
            uidSolicitante: uidSolicitante,
            nomeSolicitante: nome,
            telefoneSolicitante: telefone,
          );
      if (!abriu) {
        // Sem sessão/contexto agora (cold start na barreira de login):
        // mesma mecânica do toque na notificação local — a LoginScreen
        // consome depois do login.
        NotificacaoService.payloadSolicitacaoPendente = {
          'tipo': 'monitoramento_push',
          'subTipo': 'solicitacao_monitoramento',
          'idPermissao': idPermissao,
          'uidSolicitante': uidSolicitante,
          'nomeSolicitante': nome,
          'telefoneSolicitante': telefone,
        };
      }
    }
  }

  /// Ids de alerta cuja [AlertaRecebidoScreen] já foi aberta por este
  /// serviço nesta execução — evita empilhar a mesma tela duas vezes
  /// (ex: Push em primeiro plano seguido do toque no banner).
  static final Set<String> _idsAlertaJaAbertos = {};

  /// Abre [AlertaRecebidoScreen] a partir do `data` do Push (mesmos campos
  /// do payload da notificação local, ver
  /// `NotificacaoService.exibirNotificacaoAlertaRecebido`). Com
  /// [substituirPilha] (cold start), troca a pilha inteira — mesmo padrão
  /// de `_inicializarNotificacoesEAbrirAlertaPendente` em `main.dart`: o
  /// alerta recebido nunca exige login.
  void _abrirTelaAlertaRecebido(
    Map<String, dynamic> data, {
    bool substituirPilha = false,
  }) {
    final idEntrega = data['idEntrega'] as String?;
    if (idEntrega != null && !_idsAlertaJaAbertos.add(idEntrega)) return;

    final rota = MaterialPageRoute(
      builder: (_) => AlertaRecebidoScreen(
        mensagem: (data['mensagem'] as String?) ?? '',
        nomeRemetente: data['nomeRemetente'] as String?,
        latitude: double.tryParse((data['latitude'] as String?) ?? ''),
        longitude: double.tryParse((data['longitude'] as String?) ?? ''),
        fotoUrl: data['fotoUrl'] as String?,
        idEntrega: idEntrega,
        recebidoEm: DateTime.now().toIso8601String(),
      ),
    );

    // O Navigator pode ainda não existir num cold start — tenta de novo
    // por alguns instantes antes de desistir (o alerta já ficou
    // registrado no Histórico de qualquer forma).
    var tentativas = 0;
    void tentar() {
      final navegador = appNavigatorKey.currentState;
      if (navegador == null) {
        if (++tentativas > 20) return;
        Future.delayed(const Duration(milliseconds: 250), tentar);
        return;
      }
      try {
        if (substituirPilha) {
          navegador.pushAndRemoveUntil(rota, (route) => false);
        } else {
          navegador.push(rota);
        }
      } catch (e) {
        debugPrint('⚠️ [FcmService] Falha ao abrir AlertaRecebidoScreen: $e');
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tentar());
  }

  /// Lógica compartilhada entre primeiro e segundo plano: despacha o
  /// tratamento conforme o campo `tipo` da mensagem data-only recebida —
  /// alerta de emergência de terceiro ([_tratarAlertaEmergencia]) ou push
  /// da aba Monitoramento ([_tratarPushMonitoramento]). Qualquer outro
  /// `tipo` (ou ausente) é ignorado silenciosamente.
  ///
  /// [emPrimeiroPlano] só é `true` quando chamado por [_processarMensagem]
  /// (app aberto e em uso, ver `FirebaseMessaging.onMessage`) — usado por
  /// [_tratarPushMonitoramento] para decidir entre abrir o modal de decisão
  /// direto ou apenas exibir a notificação normal.
  ///
  /// [exibirNotificacaoLocal] é `false` só no iOS em segundo plano, quando o
  /// próprio sistema já exibiu o banner do Push (ver [_sistemaJaExibiu]).
  Future<void> _tratarDadosDoAlerta(
    Map<String, dynamic> data, {
    bool emPrimeiroPlano = false,
    bool exibirNotificacaoLocal = true,
  }) async {
    final tipo = data['tipo'] as String?;

    if (tipo == _tipoAlertaEmergencia) {
      await _tratarAlertaEmergencia(data, exibirNotificacaoLocal: exibirNotificacaoLocal);
      return;
    }

    if (tipo != null && AvisoEntregaService.tipos.contains(tipo)) {
      // Aviso ao REMETENTE sobre a entrega do alerta a um contato:
      // notificação visível com o título/corpo do servidor + status por
      // contato no detalhe do alerta no Histórico.
      await AvisoEntregaService.processar(data, exibirNotificacao: exibirNotificacaoLocal);
      return;
    }

    if (tipo == _tipoRelatorioFalhaEntrega) {
      // Propositalmente sem nenhuma notificação/UI — ver documentação de
      // [RelatorioFalhaEntregaService.processarRelatorioSilencioso].
      try {
        await RelatorioFalhaEntregaService().processarRelatorioSilencioso(data);
      } catch (e) {
        debugPrint('⚠️ [FcmService] Falha ao processar relatório de falha de entrega: $e');
      }
      return;
    }

    if (tipo != null && _tiposPushMonitoramento.contains(tipo)) {
      if (!exibirNotificacaoLocal) return; // iOS: banner já exibido pelo sistema.
      await _tratarPushMonitoramento(data, tipo, emPrimeiroPlano: emPrimeiroPlano);
      return;
    }
  }

  /// Se for um alerta de emergência de terceiro, confirma a ENTREGA NO
  /// DISPOSITIVO e só então tenta exibir a notificação de tela cheia.
  ///
  /// ORDEM CRÍTICA E DE PROPÓSITO: este método só é chamado quando o SO
  /// já entregou a mensagem FCM a este aparelho (é exatamente isso que
  /// dispara `onMessage`/`onBackgroundMessage`, mesmo com a tela
  /// bloqueada e o app fechado) — ou seja, a mera execução deste método
  /// JÁ É a prova de entrega no dispositivo, independente de qualquer
  /// interação do usuário (abrir o app, tocar na notificação, etc.).
  /// Por isso a confirmação ([FirebaseSyncService.confirmarEntregaAlerta])
  /// é gravada PRIMEIRO, em seu próprio try/catch — uma falha ao MOSTRAR
  /// a notificação de tela cheia (ex: canal ainda não criado, permissão
  /// negada) NUNCA deve impedir o registro da entrega já confirmada pelo
  /// FCM.
  Future<void> _tratarAlertaEmergencia(
    Map<String, dynamic> data, {
    bool exibirNotificacaoLocal = true,
  }) async {
    final idEntrega = data['idEntrega'] as String?;
    final mensagem = (data['mensagem'] as String?) ?? '';
    final nomeRemetente = data['nomeRemetente'] as String?;
    final fotoUrl = data['fotoUrl'] as String?;
    // Presente só quando este Push veio do disparo imediato/motor de
    // retentativa (ver `alertaHibridoService.js`/`entregaRetryEngine.js`)
    // — identifica QUAL sub-documento de `destinatarios` corresponde a
    // este aparelho, para o ACK abaixo parar futuras retentativas.
    final contatoId = data['contatoId'] as String?;
    // Valores do FCM `data` chegam sempre como String — ver
    // functions/alertaHibridoService.js, que serializa com `.toString()`.
    final latitude = double.tryParse((data['latitude'] as String?) ?? '');
    final longitude = double.tryParse((data['longitude'] as String?) ?? '');
    if (idEntrega == null) return;

    try {
      await FirebaseSyncService().confirmarEntregaAlerta(idEntrega);
      debugPrint('✅ [Confirmação de Entrega Enviada] entregas_alerta/$idEntrega');
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao confirmar entrega no dispositivo: $e');
    }

    try {
      await FirebaseSyncService().confirmarEntregaDestinatario(idEntrega, contatoId);
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao confirmar ENTREGUE do destinatário (motor de retentativa): $e');
    }

    // Persiste localmente (indicador de "não visualizado" no HomeScreen +
    // item clicável na aba Histórico, ver AlertasRecebidosService) —
    // best-effort, nunca bloqueia os passos acima/abaixo.
    unawaited(AlertasRecebidosService.registrarAlertaRecebido(
      idEntrega: idEntrega,
      nomeRemetente: nomeRemetente,
      mensagem: mensagem,
      latitude: latitude,
      longitude: longitude,
      fotoUrl: fotoUrl,
    ));

    if (!exibirNotificacaoLocal) return;

    try {
      await NotificacaoService.exibirNotificacaoAlertaRecebido(
        idEntrega: idEntrega,
        mensagem: mensagem,
        nomeRemetente: nomeRemetente,
        fotoUrl: fotoUrl,
        latitude: latitude,
        longitude: longitude,
      );
    } catch (e) {
      debugPrint('⚠️ [FcmService] Falha ao exibir notificação de alerta recebido: $e');
    }
  }

  /// Exibe a notificação NORMAL (sem tela cheia, sem som/vibração
  /// persistentes — ver [NotificacaoService.exibirNotificacaoMonitoramento])
  /// para um push da aba Monitoramento, funcionando com o app em
  /// primeiro plano, segundo plano ou totalmente fechado. Diferente de
  /// [_tratarAlertaEmergencia], não há nenhuma confirmação de
  /// entrega/transbordo a registrar aqui — a expiração de 24h da
  /// solicitação (ver `monitoramentoExpiracaoMonitor.js`) é decidida
  /// inteiramente no servidor a partir do Firestore, não da entrega deste
  /// Push.
  ///
  /// [tipo] é `'solicitacao_monitoramento'` (nome vem de `nomeSolicitante`,
  /// quem está pedindo a localização) ou uma resposta a uma solicitação
  /// já enviada — `'monitoramento_aprovado'`, `'monitoramento_negado'`,
  /// `'monitoramento_bloqueado'` ou `'monitoramento_expirado'` (nome vem
  /// de `nomeAlvo`, quem respondeu/deixou expirar).
  Future<void> _tratarPushMonitoramento(
    Map<String, dynamic> data,
    String tipo, {
    required bool emPrimeiroPlano,
  }) async {
    final idPermissao = data['idPermissao'] as String?;
    if (idPermissao == null) return;

    final nomeContraparte = tipo == 'solicitacao_monitoramento'
        ? data['nomeSolicitante'] as String?
        : data['nomeAlvo'] as String?;

    // Só relevante para 'solicitacao_monitoramento': permite que o toque na
    // notificação abra DIRETO no modal de decisão (ver
    // `NotificacaoService.exibirNotificacaoMonitoramento`/deep link),
    // sem precisar de uma nova consulta ao Firestore para descobrir quem
    // está solicitando.
    final uidSolicitante = tipo == 'solicitacao_monitoramento'
        ? data['uidSolicitante'] as String?
        : null;
    final telefoneSolicitante = tipo == 'solicitacao_monitoramento'
        ? data['telefoneSolicitante'] as String?
        : null;

    // Com o app já ABERTO em primeiro plano, uma SOLICITAÇÃO recebida (não
    // uma resposta a uma solicitação já enviada) NÃO deve passar por um
    // banner/notificação discreta — abre o modal de decisão DIRETO no
    // centro da tela, sem exigir que o usuário toque em nada primeiro. Se
    // não houver um `BuildContext` válido no momento (ex: app em transição
    // de tela), cai no fallback abaixo e mostra a notificação normalmente.
    if (emPrimeiroPlano &&
        tipo == 'solicitacao_monitoramento' &&
        uidSolicitante != null) {
      final abriuDireto = await _tentarAbrirDecisaoDireto(
        idPermissao: idPermissao,
        uidSolicitante: uidSolicitante,
        nomeSolicitante: nomeContraparte ?? '',
        telefoneSolicitante: telefoneSolicitante ?? '',
      );
      if (abriuDireto) return;
    }

    try {
      await NotificacaoService.exibirNotificacaoMonitoramento(
        tipo: tipo,
        idPermissao: idPermissao,
        nomeContraparte: nomeContraparte,
        uidSolicitante: uidSolicitante,
        telefoneSolicitante: telefoneSolicitante,
      );
    } catch (e) {
      debugPrint(
          '⚠️ [FcmService] Falha ao exibir notificação de monitoramento ($tipo): $e');
    }
  }

  /// Ids de permissão com o modal de decisão ([exibirDialogoDecisaoMonitoramento])
  /// atualmente aberto — evita empilhar dois diálogos para a MESMA
  /// solicitação caso o FCM reentregue a mesma mensagem (retry do SO)
  /// enquanto o primeiro ainda está na tela.
  static final Set<String> _idsComDialogoAberto = {};

  /// Tenta abrir o modal de decisão direto sobre a tela atual (sem navegar
  /// para nenhuma aba/tela intermediária). Só funciona com o app
  /// efetivamente rodando em primeiro plano E o usuário já autenticado
  /// nesta sessão — fora disso (sem `BuildContext` disponível, ou sessão
  /// sem login) retorna `false` para o chamador cair no fallback de
  /// notificação normal.
  Future<bool> _tentarAbrirDecisaoDireto({
    required String idPermissao,
    required String uidSolicitante,
    required String nomeSolicitante,
    required String telefoneSolicitante,
  }) async {
    if (Firebase.apps.isEmpty || FirebaseAuthService().uidAtual == null) {
      return false;
    }
    final context = appNavigatorKey.currentContext;
    if (context == null) return false;

    if (_idsComDialogoAberto.contains(idPermissao)) {
      // Já em exibição (reentrega do FCM) — não empilha um segundo modal,
      // mas ainda assim reporta como "tratado" para não cair no fallback.
      return true;
    }

    _idsComDialogoAberto.add(idPermissao);
    try {
      await exibirDialogoDecisaoMonitoramento(
        context: context,
        idPermissao: idPermissao,
        uidSolicitante: uidSolicitante,
        nomeSolicitante: nomeSolicitante,
        telefoneSolicitante: telefoneSolicitante,
      );
    } finally {
      _idsComDialogoAberto.remove(idPermissao);
    }
    return true;
  }
}
