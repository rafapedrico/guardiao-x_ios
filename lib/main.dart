import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_navigator.dart';
import 'firebase_options.dart';
import 'screens/alarme_disparado_screen.dart';
import 'screens/alerta_recebido_screen.dart';
import 'screens/cronometro_disparado_screen.dart';
import 'screens/completar_perfil_screen.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/alarme_service.dart';
import 'services/background_location_heartbeat_service.dart';
import 'services/bloqueio_app_service.dart';
import 'services/captura_dissuasao_service.dart';
import 'services/contatos_emergencia_service.dart';
import 'services/database_helper.dart';
import 'services/diagnostico_service.dart';
import 'services/emergency_alert_service.dart';
import 'services/encryption_service.dart';
import 'services/fcm_service.dart';
import 'services/firebase_auth_service.dart';
import 'services/firebase_sync_service.dart';
import 'services/font_scale_service.dart';
import 'services/locale_service.dart';
import 'services/notificacao_service.dart';
import 'services/onboarding_service.dart';
import 'services/plano_ciclo_service.dart';
import 'services/premium_purchase_service.dart';
import 'services/relatorio_falha_entrega_service.dart';
import 'services/retry_upload_service.dart';
import 'services/rotina_alarme_service.dart';
import 'services/sessao_revogada_service.dart';
import 'services/sos_deep_link_service.dart';
import 'services/sos_disparo_service.dart';
import 'services/sos_plano_aviso_service.dart';
import 'services/sos_widget_fluxo_service.dart';
import 'services/volume_sos_service.dart';
import 'services/wallpaper_service.dart';
import 'widgets/camada_bloqueio_app.dart';
import 'widgets/pin_dialog.dart';
import 'widgets/plano_bloqueado_dialog.dart';
import 'widgets/tela_sos_widget.dart';

const String _rotaInicialSosFisico = '/sos_fisico_lockscreen';
const String _rotaInicialRotinaAlarme = '/rotina_alarme_confirmacao';
const String _rotaInicialCronometroAlarme = '/cronometro_alarme_confirmacao';

// ================================================================
// ARQUITETURA DE COLD START — LAZY LOADING ESTRITO EM 3 ETAPAS
// (reescrita completa a pedido explícito do usuário: a versão anterior,
// mesmo já adiando os serviços nativos pesados para depois do runApp(),
// ainda tinha WallpaperService/FontScaleService/LocaleService + 2
// leituras de disco `await`adas ANTES do runApp() — medido ~7s de cold
// start em debug. Meta: ZERO `await` antes do runApp()).
//
// ETAPA 1 (main, abaixo): só ensureInitialized() + checagens 100%
// SÍNCRONAS de rota (sem I/O, não são `await` — decidem qual widget é
// o primeiro frame) + runApp() imediato. ÚNICA exceção (iOS, build 110):
// uma consulta nativa de poucos milissegundos — "o app foi aberto pelo
// Widget SOS?" — aguardada ANTES do runApp() para o primeiro quadro já
// ser a tela preta do SOS, nunca a splash/login/bloqueio.
//
// ETAPA 2 (_garantirFirebaseEAuth): disparada (sem `await`) logo após o
// runApp() — SÓ Firebase core + FirebaseAuth (com a sessão persistida
// restaurada) e o token FCM. Nada de heartbeat aqui. Futuro único,
// compartilhado por todos os pontos de entrada — ver a função.
//
// ETAPA 3 (iniciarServicosPosLoginOuDashboard, chamada por
// HomeScreen.initState — ver home_screen.dart): TODOS os serviços
// nativos pesados (Alarme, Notificação, VolumeSos, RetryUpload,
// PlanoLimite, BackgroundLocationHeartbeat, FCM, AlarmManager) só sobem
// depois que o usuário efetivamente loga e chega no dashboard — nunca
// antes, nem em paralelo com o cold start.
//
// SESSÃO E BLOQUEIO (2026-10-03, substitui a antiga "Opção A"): a
// sessão do Firebase Auth fica SEMPRE persistida — logout só quando o
// usuário toca em "Sair". O que protege o app é o bloqueio local
// ([BloqueioAppService]/[CamadaBloqueioApp]: Face ID/Touch ID/biometria,
// código do aparelho ou PIN do Guardião-X), exigido no cold start e ao
// voltar do segundo plano. Antes, a Opção A deslogava a cada cold start
// e o Widget SOS do iOS caía na LoginScreen sem sessão para enviar o
// alerta (build 105: 4 de 5 toques). Emergências (Widget SOS, botão
// físico, alerta recebido, alarmes) pulam o bloqueio enquanto estão na
// tela. Como a sessão agora sobrevive ao cold start, a HomeScreen (e com
// ela o VolumeSosService e os alarmes de rotina da ETAPA 3) sobe já no
// cold start normal, por baixo da camada de bloqueio.
// ================================================================

/// Guarda para [iniciarServicosPosLoginOuDashboard] disparar UMA ÚNICA
/// vez por sessão do engine, mesmo que HomeScreen seja desmontada/
/// remontada (troca de aba, deep-link, etc.).
bool _servicosPosLoginJaIniciados = false;

/// Futuro ÚNICO de [_garantirFirebaseEAuth] — compartilhado pela splash,
/// pelo Widget SOS e pelos cold starts de emergência, para nunca
/// inicializar duas vezes nem correr uma contra a outra.
Future<void>? _futuroFirebaseEAuth;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Primeiro de tudo: registra erros/avisos para a tela Diagnóstico (ver
  // [DiagnosticoService]) — o usuário testa via TestFlight, sem console.
  DiagnosticoService().instalar();

  // CORREÇÃO DE BUG REAL (2026-09-04 — pedido explícito do usuário: "o
  // despertador de rotina acende a tela e dá um estalo, mas o som só
  // toca depois que o usuário desliza o dedo/toca na notificação"):
  // TODOS os `AudioPlayer` deste app (ver [AlarmeSonoroService]/
  // `AlarmeDisparadoScreen`/`CronometroDisparadoScreen`) tocavam sem
  // NENHUM `AudioContext` configurado — o `audioplayers` então usa o
  // padrão da plataforma (Android: `USAGE_MEDIA`, foco de áudio comum).
  // Um stream de mídia comum, tocado por uma Activity aberta via
  // `Intent` em segundo plano/por cima do Keyguard (sem estar
  // genuinamente "resumida e em foco" ainda), pode ser silenciosamente
  // adiado/negado pelo Android até o usuário interagir com a tela —
  // EXATAMENTE o sintoma relatado (tela acende, mas o som só começa após
  // o toque). Isso NUNCA acontece com apps de despertador de verdade
  // porque eles tocam o som como `USAGE_ALARM` — um uso que o Android
  // trata como prioritário (ignora o Modo Não Perturbe, ganha foco de
  // áudio mesmo sem a janela estar interativa, toca no volume de alarme
  // em vez do de mídia). `AudioPlayer.global.setAudioContext(...)`
  // configura esse contexto UMA vez, aqui em `main()` — o ÚNICO ponto de
  // entrada Dart compartilhado por TODOS os engines/Activities deste app
  // (normal, `RotinaCheckinAlarmActivity` do despertador/cronômetro,
  // `LockscreenCameraActivity` do SOS físico) — afetando toda instância
  // de `AudioPlayer` criada DEPOIS disto neste isolate, sem precisar
  // repetir a configuração em cada tela. Fire-and-forget (sem `await`):
  // é uma chamada de MethodChannel simples, nunca deve atrasar o
  // primeiro frame.
  unawaited(AudioPlayer.global.setAudioContext(AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gain,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  )));

  // ETAPA 1 — checagens 100% SÍNCRONAS (leitura de memória já resolvida
  // pelo binding, sem I/O nenhum): NÃO são `await`, custam
  // microssegundos, e são essenciais para decidir o primeiro frame.
  // Removê-las faria a LoginScreen (com campos de texto) desenhar por
  // cima da lockscreen no SOS físico — bug de segurança já corrigido
  // antes — ou atrasaria a AlarmeDisparadoScreen.
  final bool coldStartViaSosFisico =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialSosFisico;

  final bool coldStartViaRotinaAlarme =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialRotinaAlarme;

  final bool coldStartViaCronometroAlarme =
      WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
          _rotaInicialCronometroAlarme;

  // Síncrono, idempotente, sem I/O — ver encryption_service.dart (só
  // deriva a chave em memória; os demais serviços chamam de novo
  // sozinhos caso ainda não tenha rodado).
  EncryptionService().initialize();

  // Observa o ciclo de vida do app para o bloqueio local (volta do
  // segundo plano depois de alguns minutos) — ver [BloqueioAppService].
  BloqueioAppService().iniciar();

  // REQUISITO OFICIAL DO FLUTTER/FLUTTERFIRE (reespecificação do
  // usuário, 2026-08-15): `FirebaseMessaging.onBackgroundMessage(...)`
  // deve ser registrado o MAIS CEDO possível dentro de `main()`, SEM
  // depender de estado de login/navegação — é essa chamada que grava,
  // no lado nativo, QUAL função Dart o Android deve invocar quando uma
  // mensagem chegar com o app fechado. Fire-and-forget (sem `await`):
  // `Firebase.initializeApp()` sozinho pode levar 4s+ (ver comentário
  // completo em [_garantirFirebaseEAuth]), e não faz sentido atrasar o
  // primeiro frame (`runApp()`, logo abaixo) por causa disso. Chamar
  // `Firebase.initializeApp()` de novo aqui (além da chamada existente
  // em [_garantirFirebaseEAuth]) é seguro e barato — o SDK é idempotente,
  // a segunda chamada só devolve a instância já inicializada sem
  // repetir nenhum I/O.
  unawaited(_registrarHandlerFcmDeBackgroundImediatamente());

  // REESPECIFICAÇÃO DO USUÁRIO (2026-08-14): tocar na notificação de um
  // "alerta recebido" (mensagem de outro usuário que cadastrou este
  // aparelho como contato de emergência) NUNCA deve exigir login — o
  // usuário precisa ver a mensagem/localização direto. Mesma lógica de
  // "o mais cedo possível, sem depender de login/navegação" do handler
  // de FCM acima: `NotificacaoService.inicializar()` não depende de
  // Firebase, só precisa rodar cedo o bastante para resgatar (via
  // `getNotificationAppLaunchDetails()`) o payload de um COLD START via
  // toque nesta notificação, ANTES de qualquer LoginScreen chegar a
  // aparecer. Fire-and-forget — ver [_inicializarNotificacoesEAbrirAlertaPendente].
  unawaited(_inicializarNotificacoesEAbrirAlertaPendente());

  // SUBSTITUTO iOS DO GATILHO FÍSICO DE SOS (Volume+ em segundo plano,
  // sem equivalente possível na Apple — ver
  // docs/migracao-ios-relatorio-2026-09-12.md, seção 5, item 4): o Widget
  // SOS (`ios/SOSWidget/`) abre o app via `guardiaox://sos`, capturado no
  // SceneDelegate nativo (ver [SosDeepLinkService]).
  //
  // Cold start pelo widget: perguntado ANTES do runApp() (única espera
  // antes do primeiro quadro, poucos ms) para a tela inicial já ser a tela
  // preta do SOS — nunca splash, login, bloqueio ou Home. O fluxo começa
  // aqui mesmo: a tela preta já está pedida quando o runApp() desenha.
  final bool coldStartViaWidgetSos =
      await SosDeepLinkService().consumirAberturaInicial();
  if (coldStartViaWidgetSos) {
    debugPrint('🆘 [main] Cold start via Widget SOS (iOS).');
    SosWidgetFluxoService().iniciar(garantirFirebaseEAuth: _garantirFirebaseEAuth);
    unawaited(_garantirFirebaseEAuth()
        .then((_) => BloqueioAppService().bloquearSeHouverSessao()));
  }

  // Toques com o app já rodando (primeiro/segundo plano, com ou sem
  // bloqueio pendente). Ouvido só DEPOIS da consulta acima: começar a
  // ouvir entrega ao Dart os toques guardados no buffer nativo, e o da
  // abertura a frio já foi consumido — nunca duplica nem perde. Assinatura
  // única, fora de [iniciarServicosPosLoginOuDashboard]: o SOS funciona
  // antes de qualquer login.
  SosDeepLinkService().aoTocarNoWidget.listen((_) {
    debugPrint('🆘 [main] SOS via Widget (iOS) — app já em execução.');
    SosWidgetFluxoService().iniciar(garantirFirebaseEAuth: _garantirFirebaseEAuth);
  });

  // Dispara (chama, SEM `await`) a inicialização de Firebase+Auth — isso
  // já executa o corpo síncrono da função até o primeiro `await`
  // interno, mas retorna a Future imediatamente sem bloquear main().
  //
  // MEDIDO no dispositivo físico (2026-08-06): `Firebase.initializeApp()`
  // sozinho pode levar 4s+ (I/O real do SDK nativo). Descoberta chave:
  // mesmo SEM nenhum `await` esperando por ele, esse trabalho nativo
  // compete pela MESMA UI thread usada pelos frames da splash animada —
  // rodar em paralelo com a animação a deixava visivelmente mais lenta
  // mesmo sem nenhum código Dart "esperando". Por isso, no cold start
  // NORMAL (nenhuma das duas flags abaixo), o disparo do Firebase é
  // ADIADO para depois da animação da splash terminar (ver
  // [_SplashGateState._aguardarProntidao]) — a splash roda inteira sem
  // nenhum trabalho pesado competindo, e o Firebase só liga junto com a
  // LoginScreen, aproveitando o tempo que o usuário leva pra digitar
  // e-mail/senha.
  //
  // Já os fluxos de SOS físico e rotina de alarme (abaixo) NÃO têm
  // nenhuma animação para proteger — disparam o Firebase imediatamente,
  // como antes.
  Future<void>? futuroFirebaseEAuthImediato;
  if (coldStartViaSosFisico ||
      coldStartViaRotinaAlarme ||
      coldStartViaCronometroAlarme) {
    // Os TRÊS cold starts de emergência (SOS físico, Alarme de Rotina,
    // Cronômetro Regressivo) não têm animação para proteger — Firebase
    // imediato. Rotina/Cronômetro deixam o app bloqueado por baixo (as
    // telas de alarme liberam o bloqueio enquanto estão abertas); o SOS
    // físico a frio roda numa Activity própria sobre a tela de bloqueio
    // do Android, que só fecha ao final — nada a bloquear lá.
    futuroFirebaseEAuthImediato = _garantirFirebaseEAuth();
    if (!coldStartViaSosFisico) {
      unawaited(futuroFirebaseEAuthImediato
          .then((_) => BloqueioAppService().bloquearSeHouverSessao()));
    }
  }

  // ETAPA 1, fim: primeiro frame disparado imediatamente — ZERO
  // `await` entre ensureInitialized() e este runApp().
  runApp(SecurityCheckApp(
    abertoViaAlarmeRotina: coldStartViaRotinaAlarme,
    abertoViaCronometroAlarme: coldStartViaCronometroAlarme,
    abertoViaSosFisico: coldStartViaSosFisico,
    abertoViaWidgetSos: coldStartViaWidgetSos,
  ));

  // A partir daqui, tudo roda EM PARALELO com o primeiro frame já na
  // tela — nada abaixo bloqueia ou atrasa o runApp() acima.

  if (coldStartViaSosFisico) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint(
          '🚨 [main] SOS Físico via Lockscreen: aguardando Firebase+Auth antes de disparar P1->P2.');
      // Só aguarda AQUI (depois do primeiro frame, tela preta já
      // visível) — nunca antes do runApp(). O disparo em si precisa do
      // Firebase pronto para usar Push/link real da foto (ver política
      // de sessão em [_garantirFirebaseEAuth]).
      futuroFirebaseEAuthImediato!.then((_) {
        _dispararSequenciaUnificadaDeSos(origem: 'sos_fisico').then((abriuCamera) {
          // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (Motorola
          // Razr, 2026-09-04 — logcat mostrou os dois limites mensais do
          // Plano Gratuito no teto exatamente neste instante): quando a
          // câmera NÃO abre por qualquer motivo (limite mensal atingido,
          // permissão negada, `NavigatorState` indisponível), esta engine
          // isolada da [LockscreenCameraActivity] não tinha absolutamente
          // NADA além de [_TelaPretaAguardandoSos] — um `Scaffold` preto
          // vazio, sem spinner, sem texto, sem botão de voltar funcional
          // — e ficava assim PARA SEMPRE, obrigando o usuário a forçar o
          // fechamento do app bem no meio de uma emergência real. P1 (SMS
          // + nuvem) já foi disparado em paralelo por
          // [_dispararSequenciaUnificadaDeSos] independentemente deste
          // resultado — não há mais nada útil a fazer nesta Activity
          // isolada quando a câmera não abre, então a fecha
          // automaticamente (`SystemNavigator.pop()`, mesmo mecanismo já
          // usado por [CameraCapturaScreen._acionarSaidaDeSeguranca])
          // devolvendo o aparelho à tela de bloqueio normal em vez de
          // deixar um buraco preto sem saída.
          if (!abriuCamera) {
            debugPrint(
                '🚨 [main] SOS Físico: câmera não abriu — fechando a tela preta (P1 já disparado em paralelo).');
            SystemNavigator.pop();
          }
        });
      });
    });
  }

  // CORREÇÃO DE BUG REAL (2026-08-11): `coldStartViaRotinaAlarme`/
  // `coldStartViaCronometroAlarme` JÁ fazem `_telaInicial()` (usada pelo
  // `onGenerateRoute` do MaterialApp, ver [build] abaixo, para o
  // `defaultRouteName` especial do cold start) devolver
  // `AlarmeDisparadoScreen()`/`CronometroDisparadoScreen()` diretamente
  // como a PRÓPRIA tela inicial — ver [_telaInicial]. Havia AQUI, antes,
  // um `navigateToAlarmeDisparado()`/`navigateToCronometroDisparado()`
  // redundante que EMPILHAVA uma SEGUNDA instância da mesma tela por
  // cima da primeira (mesmo Navigator/engine, sem precisar de nenhuma
  // corrida entre dois engines): a segunda instância se autodetectava
  // como duplicata e se autorremovia (`Navigator.pop()`), mas como o
  // `pop()` remove sempre o TOPO da pilha — não necessariamente "a si
  // mesma" — na prática acabava fechando também o diálogo de PIN que a
  // PRIMEIRA instância tinha acabado de abrir por cima dela, no
  // instante exato em que ele deveria abrir. Sintoma real reportado: "o
  // som/teclado ameaçam aparecer, mas são interrompidos imediatamente,
  // sem chance de digitar a senha". Removido — `_telaInicial()` sozinha
  // já é suficiente e correta para o cold start.

  // Wallpaper/fonte/idioma persistidos: puramente visuais (o
  // MaterialApp já nasce com os valores padrão dos ValueNotifiers e
  // reconstrói reativamente assim que estes carregarem) — nunca
  // precisam bloquear o primeiro frame. Fire-and-forget.
  unawaited(_inicializarPreferenciasVisuais());
}

/// Wallpaper, escala de fonte e idioma persistidos — só afetam
/// aparência (ver comentário em [main]), nunca bloqueiam o cold start.
Future<void> _inicializarPreferenciasVisuais() async {
  await WallpaperService.inicializar();
  await FontScaleService.inicializar();
  await LocaleService.inicializar();
}

/// Registra `FirebaseMessaging.onBackgroundMessage` o mais cedo possível
/// (ver chamada em [main], logo no início da função, incondicional) —
/// ÚNICA responsabilidade desta função, deliberadamente separada de
/// [_garantirFirebaseEAuth] (que também chama `Firebase.initializeApp()`,
/// entre várias outras coisas, mas só é disparada incondicionalmente
/// para os 3 cold starts de emergência — no cold start NORMAL, fica
/// atrás da animação da splash, ver [_SplashGateState._aguardarProntidao]).
/// [FirebaseMessaging.onBackgroundMessage] em si é uma chamada síncrona e
/// barata (só grava o callback handle nativo) — só depende de
/// `Firebase.initializeApp()` já ter completado, por isso aguardado aqui
/// antes. Protegida por try/catch: nunca lança exceção, nem impede o
/// resto do cold start.
Future<void> _registrarHandlerFcmDeBackgroundImediatamente() async {
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    debugPrint('📲 [main] Handler de background do FCM registrado (imediato, cold start).');
  } catch (e) {
    debugPrint('⚠️ [main] Falha ao registrar handler de background do FCM imediatamente: $e');
  }
}

/// REESPECIFICAÇÃO DO USUÁRIO (2026-08-14): "quando eu tocar na
/// notificação, em vez de aparecer a tela de login, preciso que apareça
/// a tela bonita [...] com a localização — o usuário não precisa logar
/// no app para ver a mensagem e localização".
///
/// Chamada sem `await` logo no início de [main] (junto com
/// [_registrarHandlerFcmDeBackgroundImediatamente]), incondicionalmente
/// — inclusive nos 3 cold starts de emergência (SOS físico/Rotina/
/// Cronômetro), onde é sempre um no-op silencioso (esses fluxos nunca
/// nascem de um toque nesta notificação, então nunca há payload
/// pendente).
///
/// [NotificacaoService.inicializar] não depende de Firebase/sessão — só
/// dela já ter rodado é que [NotificacaoService.consumirPayloadAlertaRecebidoPendente]
/// tem algo pra devolver (a leitura de `getNotificationAppLaunchDetails()`
/// que resgata o payload de um COLD START acontece DENTRO de
/// [NotificacaoService.inicializar]). Se houver um payload pendente,
/// substitui TODA a pilha de navegação (`pushAndRemoveUntil`, mesmo
/// padrão do fallback de `AlertaRecebidoScreen._fecharTela`) por
/// [AlertaRecebidoScreen] — a LoginScreen/splash nunca chega a ficar
/// visível por mais que um frame, mesmo que já estivesse prestes a
/// aparecer.
///
/// `addPostFrameCallback` garante que `appNavigatorKey.currentState` já
/// existe (o primeiro frame do [runApp] em [main] já rodou) antes de
/// tentar navegar — protegido por try/catch, nunca lança exceção nem
/// atrasa o resto do cold start.
Future<void> _inicializarNotificacoesEAbrirAlertaPendente() async {
  try {
    await NotificacaoService.inicializar();
  } catch (e) {
    debugPrint('⚠️ [main] Falha ao inicializar NotificacaoService no cold start: $e');
    return;
  }

  final dados = NotificacaoService.consumirPayloadAlertaRecebidoPendente();
  if (dados == null) return;

  debugPrint('📬 [main] Cold start via toque em alerta recebido — abrindo direto, sem login.');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      appNavigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => AlertaRecebidoScreen(
            mensagem: (dados['mensagem'] as String?) ?? '',
            nomeRemetente: dados['nomeRemetente'] as String?,
            latitude: (dados['latitude'] as num?)?.toDouble(),
            longitude: (dados['longitude'] as num?)?.toDouble(),
            fotoUrl: dados['fotoUrl'] as String?,
            idEntrega: dados['idEntrega'] as String?,
            recebidoEm: dados['recebidoEm'] as String?,
          ),
        ),
        (route) => false,
      );
    } catch (e) {
      debugPrint('⚠️ [main] Falha ao abrir AlertaRecebidoScreen no cold start: $e');
    }
  });

  // ACHADO NA AUDITORIA PÓS-FASE 4 (2026-09-12): cold start via toque na
  // notificação de check-in de rotina (ver
  // [NotificacaoService.idAlarmeCheckinPendente]) — sem tratamento
  // explícito, esse toque não abria nada de especial (o app abria na
  // LoginScreen normal, sem levar o usuário até a confirmação). Mesma
  // política do bloco acima: pula a barreira de login — a confirmação
  // "Cheguei bem" é 100% local/SQLite, sem depender de sessão (ver
  // `RotinaAlarmeService.confirmarCheckinRotina`). Mais relevante no
  // iOS, onde este toque é o ÚNICO caminho para o cold start desse
  // fluxo (sem a `RotinaCheckinAlarmActivity` nativa do Android).
  final idAlarmeCheckinPendente = NotificacaoService.consumirIdAlarmeCheckinPendente();
  if (idAlarmeCheckinPendente != null) {
    debugPrint('📬 [main] Cold start via toque em check-in de rotina '
        '#$idAlarmeCheckinPendente — abrindo direto, sem login.');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        appNavigatorKey.currentState?.pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AlarmeDisparadoScreen()),
          (route) => false,
        );
      } catch (e) {
        debugPrint('⚠️ [main] Falha ao abrir AlarmeDisparadoScreen no cold start: $e');
      }
    });
  }
}

/// ETAPA 2: o MÍNIMO de Firebase — `Firebase.initializeApp()`, App Check,
/// a sessão persistida restaurada e o token FCM. Nada de heartbeat aqui
/// (ver ETAPA 3, [iniciarServicosPosLoginOuDashboard]). Memoizada: todos os
/// pontos de entrada (splash, Widget SOS, cold starts de emergência)
/// compartilham a MESMA execução.
///
/// `Firebase.initializeApp()` sozinho pode levar 4s+ (MEDIDO no
/// dispositivo físico, 2026-08-06) — por isso, no cold start normal, ele
/// só é disparado DEPOIS da animação da splash (ver
/// [_SplashGateState._aguardarProntidao]), que então aguarda este futuro
/// para saber se existe sessão (Home bloqueada) ou não (LoginScreen).
///
/// Protegida por try/catch e NUNCA lança exceção: se o Firebase falhar
/// ao inicializar (sem rede, projeto mal configurado, etc.), o app
/// continua funcional para login local/SMS, que não dependem dele.
Future<void> _garantirFirebaseEAuth() =>
    _futuroFirebaseEAuth ??= _inicializarFirebaseEAuth();

Future<void> _inicializarFirebaseEAuth() async {
  // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, via
  // logcat no Moto G7 Play): esta função roda em CADA execução de
  // main() — inclusive no cold-start dedicado do botão físico de SOS
  // (`coldStartViaSosFisico`, ver acima), que abre `LockscreenCameraActivity`
  // com sua PRÓPRIA `FlutterEngine`/isolate, SEPARADA da engine principal
  // (`MainActivity`) que pode continuar viva/"quente" no MESMO processo
  // Android (ver `VolumeSosEventBridge`). O `FirebaseApp` nativo é um
  // singleton POR PROCESSO — se a engine principal já tiver inicializado
  // o Firebase segundos antes, chamar `Firebase.initializeApp()` de novo
  // nesta engine NOVA, sem checar antes, derruba com
  // `IllegalStateException: FirebaseApp name [DEFAULT] already exists!`
  // — visto ao vivo no logcat em disparos consecutivos do botão físico.
  // Resultado real: `Firebase.apps` ficava vazio NESTA engine, e todo o
  // disparo (localização E foto) caía silenciosamente no fallback SEM
  // sessão (SMS de resgate genérico, sem link real nem Push) — sintoma
  // relatado pelo usuário como "a foto tirada nem sempre é enviada".
  // `if (Firebase.apps.isEmpty)` é o MESMO guard já usado com sucesso
  // pelos outros pontos de entrada headless deste app (ver
  // `fcm_service.dart`/`rotina_alarme_service.dart`) — o SDK detecta o
  // app nativo já registrado por OUTRA engine e reaproveita, em vez de
  // tentar recriá-lo.
  if (Firebase.apps.isEmpty) {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      debugPrint('☁️ [Firebase] Inicializado com sucesso.');
    } catch (e) {
      debugPrint('⚠️ [Firebase] Falha ao inicializar (app segue 100% funcional '
          'apenas com os recursos locais): $e');
    }
  } else {
    debugPrint('☁️ [Firebase] Já inicializado (outra engine no mesmo processo) — reaproveitando.');
  }

  // Só iOS: detecta a sessão encerrada por login em outro aparelho. Tem
  // que começar a ouvir ANTES da primeira renovação de token abaixo, para
  // enxergar "sessão restaurada → deslogada pelo SDK" já no cold start.
  SessaoRevogadaService().iniciar();

  // CORREÇÃO (bug real diagnosticado em teste, 2026-08-10 — login
  // travando indefinidamente, sem erro nenhum, tanto e-mail/senha quanto
  // social): sem NENHUM provedor de App Check ativado, o interceptor de
  // rede que o próprio SDK (firebase_auth/firebase_core) injeta em toda
  // chamada ficava tentando obter um token de um provedor inexistente e
  // nunca completava a chamada — nem sucesso, nem exceção, só um
  // `Future` pendurado para sempre (confirmado via logcat: o log do
  // próprio SDK "Error getting App Check token; using placeholder token
  // instead" aparecia, mas a chamada JAMAIS retornava depois disso).
  // `AndroidProvider.debug` gera um token de depuração local válido só
  // para este aparelho/instalação — em builds de release, usa
  // `playIntegrity` (o provedor real de produção, exige o app assinado e
  // publicado/testado via Play Integrity API). Nunca lança exceção: se a
  // ativação falhar por qualquer motivo, o app segue exatamente como
  // antes (não piora nada).
  try {
    await FirebaseAppCheck.instance.activate(
      androidProvider:
          kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
    );
    debugPrint('☁️ [Firebase] App Check ativado com sucesso '
        '(${kDebugMode ? "debug" : "playIntegrity"}).');
  } catch (e) {
    debugPrint('⚠️ [Firebase] Falha ao ativar App Check: $e');
  }

  // BUG REAL CONFIRMADO (2026-08-15 — "app receptor deslogado não recebe
  // alerta"): o `fcmToken` salvo em `usuarios/{uid}.fcmToken` (é POR ELE
  // que a Cloud Function resolve, na hora de um alerta, o telefone de um
  // contato de emergência — ver `resolverContasPorTelefone` em
  // `functions/alertaHibridoService.js`, já independente de status de
  // login) só era sincronizado dentro de [FcmService.inicializar], antes
  // chamado exclusivamente APÓS um login manual bem-sucedido
  // (`login_screen.dart`) ou já no dashboard
  // ([iniciarServicosPosLoginOuDashboard], abaixo). Resultado: se o token
  // do aparelho rotacionar (reinstalação, limpeza de dados do app,
  // renovação periódica do próprio FCM) enquanto o usuário não chega à
  // Home, o token gravado no Firestore fica
  // PERMANENTEMENTE desatualizado até o próximo login manual — nenhum
  // Push chega a esse aparelho nesse meio tempo, mesmo com o Guardião-X
  // instalado e o número certo cadastrado como contato de emergência.
  //
  // Registra o handler de background do FCM + pede a permissão de
  // notificação AQUI, incondicionalmente (independente de login) — este
  // registro em si (`FirebaseMessaging.onBackgroundMessage`) já não tem
  // NENHUMA dependência de sessão (ver [FcmService.registrarInfraestrutura]);
  // só não estava sendo chamado tão cedo porque seu único call site
  // (`iniciarServicosPosLoginOuDashboard`) só roda depois do usuário
  // alcançar o dashboard. Chamar de novo lá é seguro/idempotente
  // (guardado por `_infraestruturaRegistrada`).
  try {
    await FcmService().registrarInfraestrutura();
  } catch (e) {
    debugPrint('⚠️ [main] Falha ao registrar infraestrutura de FCM no cold start: $e');
  }

  // CORREÇÃO (bug real confirmado, 2026-08-15 — "app receptor deslogado
  // não recebe alerta"): sincroniza o TOKEN aqui, usando a sessão que o
  // SDK restaura do disco em [Firebase.initializeApp] — em TODO cold
  // start (não só em logins reais), para manter o token sempre fresco.
  // `aguardarUidPronto`: a restauração da sessão é assíncrona; quem
  // aguarda este futuro (splash, Widget SOS) precisa saber de verdade se
  // há sessão. Sem sessão (nunca entrou neste aparelho, ou tocou em
  // "Sair") é um no-op silencioso.
  try {
    if (await FirebaseAuthService().aguardarUidPronto() != null) {
      // Ver documentação completa em [FirebaseAuthService.garantirTokenPronto]
      // — sem isto, a escrita abaixo falhava com
      // `[cloud_firestore/permission-denied]` mesmo com um `uid` válido
      // (corrida real confirmada via logcat: o ID token da sessão
      // recém-restaurada ainda não estava pronto no instante exato desta
      // chamada).
      await FirebaseAuthService().garantirTokenPronto();
      await FcmService().inicializar();
      debugPrint('📲 [main] Token FCM sincronizado a partir da sessão restaurada (cold start).');

      // PARIDADE COM O LOGIN (ver `_finalizarLoginComSucesso` em
      // login_screen.dart): desde o fim da Opção A o app abre direto com a
      // sessão persistida, sem passar por lá — então os mesmos passos
      // pós-login rodam aqui. Fora de propósito: a revogação de sessões
      // em outros aparelhos, que é exclusiva de um login NOVO (repeti-la a
      // cada abertura derrubaria o outro aparelho sem ninguém ter entrado).
      unawaited(ContatosEmergenciaService.sincronizarAgora());
      final usuario = FirebaseAuthService().usuarioAtual;
      if (usuario != null &&
          usuario.providerData.every((p) => p.providerId != 'password')) {
        unawaited(FirebaseSyncService().sincronizarPerfilSocial(
          nome: usuario.displayName,
          email: usuario.email,
        ));
      }
    }
  } catch (e) {
    debugPrint('⚠️ [main] Falha ao sincronizar token FCM no cold start: $e');
  }


}

/// ETAPA 3 (pedido explícito do usuário): TODOS os serviços nativos
/// pesados — Alarme de rotina, canais de notificação, Foreground
/// Service do botão físico, fila de retry offline, FCM, heartbeat de
/// localização e limites do plano — só sobem DEPOIS que o usuário
/// chega no dashboard (chamada em
/// `HomeScreen.initState()`, ver home_screen.dart), nunca antes/em
/// paralelo com o cold start. Guardada por [_servicosPosLoginJaIniciados]
/// para nunca rodar duas vezes na mesma sessão do engine.
///
/// Com a sessão persistida (fim da Opção A, ver cabeçalho do arquivo), a
/// HomeScreen sobe já no cold start normal, por baixo do bloqueio local —
/// então o botão físico de SOS e os alarmes de rotina voltam a ficar
/// ativos sem depender de um novo login.
Future<void> iniciarServicosPosLoginOuDashboard() async {
  if (_servicosPosLoginJaIniciados) return;
  _servicosPosLoginJaIniciados = true;

  debugPrint('🚀 [main] Login/Dashboard alcançado — iniciando serviços nativos em segundo plano.');

  // Registra o handler de background do FCM e pede a permissão de
  // notificação — token sync (que precisa de `uid`) continua separado,
  // em `FcmService().inicializar()`, chamado direto por login_screen.dart.
  FcmService().registrarInfraestrutura();

  // Heartbeat de localização (a cada 5 min, só quando faltar ≤2h para
  // algum alarme de rotina ativo).
  BackgroundLocationHeartbeatService().iniciar();

  await DatabaseHelper().resetarSessaoAuditoria();
  await AlarmeService.inicializar();
  await NotificacaoService.inicializar();
  await VolumeSosService().iniciarMonitoramento();

  // Ciclo recorrente de 30 dias do Plano Free (10 dias ativos + 20 dias
  // bloqueados, ver PlanoCicloService) — dispara a sincronização/renovação
  // server-side uma vez por sessão. Não `await`ado de propósito: nunca
  // deve atrasar o boot dos demais serviços, mesma filosofia de
  // RetryUploadService().iniciar() logo abaixo; os pontos de bloqueio
  // sempre fazem sua PRÓPRIA leitura fresca do Firestore quando
  // necessário, nunca dependem deste disparo já ter terminado.
  PlanoCicloService().iniciar();

  // Avisos locais de que o botão SOS para nos dias bloqueados do Plano
  // Free (véspera e início do bloqueio) — ver SosPlanoAvisoService.
  SosPlanoAvisoService().iniciar();

  // REGRA DE NEGÓCIO (Alarme de Rotina, pedido explícito do usuário,
  // 2026-09-04): fora dos 10 dias ativos do mês (e sem Premium), nenhum
  // alarme de rotina deve continuar agendado — ver documentação completa
  // em [RotinaAlarmeService.desativarAlarmesSePlanoBloqueado]. Checagem
  // própria e independente da sincronização acima (não depende dela ter
  // terminado), fire-and-forget pelo mesmo motivo: nunca atrasar o boot.
  unawaited(RotinaAlarmeService.desativarAlarmesSePlanoBloqueado());

  // Fluxo real de compra do Plano Premium (Google Play Billing, ver
  // PremiumPurchaseService) — assina o purchaseStream do plugin
  // `in_app_purchase` UMA única vez por sessão do engine. Precisa
  // acontecer aqui (boot), nunca só quando a tela de planos abre: o
  // resultado de uma compra pode chegar minutos depois (ex: usuário
  // trocou de forma de pagamento no meio do fluxo) e o app precisa estar
  // ouvindo o stream o tempo todo, não só enquanto aquela tela existir.
  PremiumPurchaseService().iniciar();

  // Resiliência offline do P2 do SOS (ver RetryUploadService): reagenda
  // o alarme periódico de retry (precisa do AndroidAlarmManager já
  // inicializado por AlarmeService.inicializar() acima) e tenta drenar a
  // fila imediatamente — cobre o caso comum de o app ser reaberto depois
  // que a conectividade voltou.
  RetryUploadService().iniciar();

  // Varredura de fallback do relatório de falha de 48h (ver
  // RelatorioFalhaEntregaService) — cobre o caso do nudge silencioso do
  // Push nunca ter chegado (app encerrado pelo SO antes da entrega, sem
  // Google Play Services, etc.). Não `await`ado de propósito, mesma
  // filosofia dos demais disparos "fire-and-forget" deste bloco — nunca
  // deve atrasar o boot dos demais serviços, e é 100% silenciosa (nunca
  // exibe notificação/UI, só grava eventos no cofre local).
  RelatorioFalhaEntregaService().sincronizarPendentes();

  VolumeSosService().aoDispararSos.listen((_) {
    _dispararFluxoCompletoDeSos(origem: 'sos_fisico');
  });

  const EventChannel('com.example.security_check_app/rotina_alarme_events')
      .receiveBroadcastStream()
      .listen((_) {
    _exibirPinDeRotinaAoAbrirPorAlarme();
  }, onError: (e) {
    debugPrint('⚠️ [main] Erro no EventChannel de alarme de rotina: $e');
  });

}

/// Dispara P1 (localização imediata, deduplicada entre engines — ver
/// [SosDisparoService]) e P2 (abre a câmera) EM PARALELO — P1 continua
/// enviando o SMS/nuvem de localização assim que possível, mas NUNCA
/// bloqueia a abertura da câmera, que é a etapa perceptível pelo
/// usuário (câmera física ~3s: obturador livre quase instantaneamente).
/// Antes, P2 só começava depois de P1 concluir (SMS + geolocalização),
/// somando vários segundos de espera com a tela preta antes do
/// obturador aparecer. Compartilhado pelos DOIS pontos de entrada do
/// botão físico (cold-start via lockscreen acima e o EventChannel de
/// [_dispararFluxoCompletoDeSos] abaixo).
///
/// REGRA OFICIAL DO PLANO FREE (reespecificação do usuário, 2026-09-04):
/// dentro dos 10 dias ativos do mês (ou Premium), TODOS os recursos são
/// liberados sem nenhum teto numérico adicional; fora deles, NENHUMA
/// mensagem é enviada — o usuário precisa esperar os 20 dias restantes ou
/// assinar o Premium. O aviso correspondente (ver
/// [garantirRecursoLiberadoOuExibirUpsell] em `plano_bloqueado_dialog.dart`)
/// agora aparece TAMBÉM no gatilho FÍSICO — antes só existia no botão
/// manual da aba Segurança (headless/tela bloqueada era sempre
/// silencioso, ver `CapturaDissuasaoService`). RESSALVA DE SEGURANÇA
/// registrada ao usuário nesta mudança: como o gatilho físico pode
/// disparar com o aparelho bloqueado/escondido (o próprio motivo do
/// [_TelaPretaAguardandoSos] existir), exibir um diálogo aqui expõe,
/// pela primeira vez, que este é um app de pânico disfarçado para
/// qualquer um olhando a tela naquele instante — aceito deliberadamente
/// a pedido do usuário, mas documentado aqui para nunca ser reintroduzido
/// "sem querer" achando que é óbvio. `appNavigatorKey` aqui é sempre o do
/// PRÓPRIO engine desta chamada (isolado do engine principal quando
/// disparado a frio via `LockscreenCameraActivity` — `main()`/`runApp`
/// rodam de novo nesse cold start, ver cabeçalho do arquivo), nunca
/// aponta para a tela errada.
///
/// Retorna `true` só quando a câmera foi de fato aberta (ver
/// [CapturaDissuasaoService.abrirCapturaSePermitido]) — usado pelo
/// cold-start via lockscreen para decidir se [_TelaPretaAguardandoSos]
/// precisa de um fallback de saída (ver documentação completa em [main]).
Future<bool> _dispararSequenciaUnificadaDeSos({required String origem}) async {
  final BuildContext? contexto = appNavigatorKey.currentContext;

  // Única trava do Plano Free (janela de 10 dias ativos/Premium) —
  // checada ANTES de disparar P1, mesmo padrão do precheck já usado pelo
  // botão manual (ver `SegurancaTab._confirmarEDispararSosManual`). Se
  // bloqueado, nem P1 nem P2 disparam.
  if (contexto != null && contexto.mounted) {
    if (!await garantirRecursoLiberadoOuExibirUpsell(contexto)) return false;
  }

  // Fire-and-forget: P1 (SMS + nuvem) roda em paralelo, nunca atrasa P2.
  unawaited(SosDisparoService().executarP1LocalizacaoImediata(origem: origem));

  // CapturaDissuasaoService encapsula o retry-loop de NavigatorState e uma
  // SEGUNDA checagem (idempotente) da mesma janela de 10 dias ativos —
  // reusado aqui (em vez de `navigateToCameraCaptura` direto) para
  // preservar essa regra também no caminho sem `BuildContext` disponível
  // (raríssimo).
  return CapturaDissuasaoService().abrirCapturaSePermitido(origemUnificada: origem);
}

/// Redireciona a navegação para a AlarmeDisparadoScreen
void navigateToAlarmeDisparado() {
  try {
    final state = appNavigatorKey.currentState;
    if (state != null) {
      state.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/alarme_disparado'),
          builder: (context) => const AlarmeDisparadoScreen(),
        ),
      );
    }
  } catch (e) {
    debugPrint('⚠️ Falha ao navegar para AlarmeDisparadoScreen: $e');
  }
}

/// Redireciona a navegação para a CronometroDisparadoScreen — mesmo
/// padrão de [navigateToAlarmeDisparado].
void navigateToCronometroDisparado() {
  try {
    final state = appNavigatorKey.currentState;
    if (state != null) {
      state.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/cronometro_disparado'),
          builder: (context) => const CronometroDisparadoScreen(),
        ),
      );
    }
  } catch (e) {
    debugPrint('⚠️ Falha ao navegar para CronometroDisparadoScreen: $e');
  }
}

Future<void> _exibirPinDeRotinaAoAbrirPorAlarme() async {
  try {
    debugPrint(
        '📱 [main] Redirecionando cold-start de rotina para AlarmeDisparadoScreen.');
    navigateToAlarmeDisparado();
  } catch (e) {
    debugPrint('⚠️ Falha ao redirecionar tela no cold-start de rotina: $e');
  }
}

void _dispararFluxoCompletoDeSos({required String origem}) {
  debugPrint('🆘 [main] Disparando fluxo completo de SOS — origem: $origem');
  // O SOS nunca espera desbloqueio (ver BloqueioAppService).
  final encerrarLiberacao = BloqueioAppService().liberarParaEmergencia();
  _dispararSequenciaUnificadaDeSos(origem: origem).catchError((e) {
    debugPrint('⚠️ [main] Falha ao processar SOS ($origem): $e');
    return false;
  }).whenComplete(encerrarLiberacao);
}

class SecurityCheckApp extends StatefulWidget {
  final bool abertoViaAlarmeRotina;
  final bool abertoViaCronometroAlarme;
  final bool abertoViaSosFisico;

  /// Aberto a frio pelo Widget SOS do iOS: a tela preta do SOS
  /// ([CamadaTelaSosWidget]) já cobre tudo, e a rota de baixo é a
  /// [_SplashGate] sem animação (Home bloqueada ou login, decidida em
  /// silêncio para quando o SOS sair da tela).
  final bool abertoViaWidgetSos;

  const SecurityCheckApp({
    super.key,
    this.abertoViaAlarmeRotina = false,
    this.abertoViaCronometroAlarme = false,
    this.abertoViaSosFisico = false,
    this.abertoViaWidgetSos = false,
  });

  @override
  State<SecurityCheckApp> createState() => _SecurityCheckAppState();
}

class _SecurityCheckAppState extends State<SecurityCheckApp> {
  late ValueNotifier<bool> _alarmeAtivoNotifier;
  StreamSubscription<PremiumCompraEvento>? _assinaturaComprasPremium;

  @override
  void initState() {
    super.initState();
    _alarmeAtivoNotifier = ValueNotifier<bool>(widget.abertoViaAlarmeRotina);

    // Feedback global do resultado da compra do Plano Premium (ver
    // PremiumPurchaseService) — precisa viver aqui, no widget raiz do
    // app, e não numa tela específica: o purchaseStream é assíncrono e o
    // resultado pode chegar bem depois de quem iniciou a compra ter
    // saído da tela (ou até trocado de aba).
    _assinaturaComprasPremium =
        PremiumPurchaseService().eventos.listen(_aoReceberEventoDeCompraPremium);
    // Adiado (pedido explícito do usuário, 2026-08-06): este monitor só
    // importa para detectar um alarme de rotina disparando enquanto o
    // app JÁ está em uso (empurra a AlarmeDisparadoScreen por cima da
    // tela atual) — não é necessário durante o cold start/splash/login.
    // Rodar `SharedPreferences.reload()` (I/O de disco) a cada 1s desde
    // o primeiro frame competia com o boot do engine bem na janela mais
    // sensível. Atraso curto e fixo (em vez de acoplar à splash) porque
    // este widget não tem visibilidade de quando ela termina.
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _monitorarMudancasNoDisco();
    });
  }

  bool _travaProcessandoAbertura = false;

  void _monitorarMudancasNoDisco() {
    Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final bool ativoNoDisco =
          prefs.getBool('alarme_disparando_no_momento') ?? false;

      if (!ativoNoDisco) {
        _travaProcessandoAbertura = false;
      }

      if (ativoNoDisco) {
        final state = appNavigatorKey.currentState;
        if (state != null) {
          bool jaEstaNaTela = false;

          state.popUntil((route) {
            final String? nomeRota = route.settings.name;
            if (nomeRota == '/alarme_disparado' ||
                route.toString().contains('AlarmeDisparadoScreen')) {
              jaEstaNaTela = true;
            }
            return true;
          });

          if (!jaEstaNaTela && !_travaProcessandoAbertura) {
            _travaProcessandoAbertura = true;

            state.push(
              MaterialPageRoute(
                settings: const RouteSettings(name: '/alarme_disparado'),
                builder: (context) =>
                    const AlarmeDisparadoScreen(veioDoForeground: true),
              ),
            );
            debugPrint(
                '🚀 [SUCESSO] Tela do botão azul forçada com segurança total anti-duplicação!');
          }
        }
      }

      if (_alarmeAtivoNotifier.value !=
          (widget.abertoViaAlarmeRotina || ativoNoDisco)) {
        _alarmeAtivoNotifier.value =
            widget.abertoViaAlarmeRotina || ativoNoDisco;
      }
    });
  }

  @override
  void dispose() {
    _alarmeAtivoNotifier.dispose();
    _assinaturaComprasPremium?.cancel();
    super.dispose();
  }

  /// Feedback global (independente de qual tela iniciou a compra — ver
  /// documentação de [PremiumPurchaseService]) para os desfechos
  /// relevantes da compra do Plano Premium via `SnackBar`, usando o
  /// [appNavigatorKey] em vez de um `context` de tela específica.
  /// `pendente`/`cancelada` não mostram nada: o pagamento ainda está em
  /// andamento, ou o usuário simplesmente desistiu — nenhum dos dois é
  /// um erro que mereça aviso.
  void _aoReceberEventoDeCompraPremium(PremiumCompraEvento evento) {
    final BuildContext? context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;

    switch (evento) {
      case PremiumCompraEvento.concedida:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.premiumCompraConcedidaMensagem),
            backgroundColor: Colors.green.shade700,
          ),
        );
        break;
      case PremiumCompraEvento.semDireito:
      case PremiumCompraEvento.erro:
      case PremiumCompraEvento.erroValidacao:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.premiumCompraFalhaMensagem),
            backgroundColor: Colors.red.shade700,
          ),
        );
        break;
      case PremiumCompraEvento.pendente:
      case PremiumCompraEvento.cancelada:
        break;
    }
  }

  /// Escolhe a tela raiz do MaterialApp. No cold start via SOS Físico
  /// (botão de volume com o aparelho bloqueado) NUNCA construímos a
  /// LoginScreen: ela tem campos de texto e, mesmo sem autofocus, não deve
  /// chegar a existir sobre a lockscreen. Uma tela preta neutra ocupa esse
  /// instante até a CameraCapturaScreen ser empurrada por cima.
  ///
  /// No cold start NORMAL vem a [_SplashGate] (mesmo fundo escuro da
  /// splash nativa do Android, ver `launch_background.xml`) rodando a
  /// splash cinematográfica; ao terminar, ela mostra a Home (com sessão
  /// persistida — coberta pelo bloqueio local, ver [BloqueioAppService])
  /// ou a LoginScreen (sem sessão).
  Widget _telaInicial() {
    if (widget.abertoViaAlarmeRotina) return const AlarmeDisparadoScreen();
    if (widget.abertoViaCronometroAlarme) {
      return const CronometroDisparadoScreen();
    }
    if (widget.abertoViaSosFisico) return const _TelaPretaAguardandoSos();
    if (widget.abertoViaWidgetSos) return const _SplashGate(semAnimacao: true);
    return const _SplashGate();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: LocaleService.localeNotifier,
      builder: (context, locale, __) {
        return ValueListenableBuilder<double>(
          valueListenable: FontScaleService.fontScaleNotifier,
          builder: (context, fatorFonte, _) {
            return MaterialApp(
              navigatorKey: appNavigatorKey,
              title: 'Security Check App',
              debugShowCheckedModeBanner: false,
              locale: locale,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(fatorFonte),
                  ),
                  // Bloqueio local POR CIMA do Navigator (ver
                  // BloqueioAppService): nenhuma navegação escapa dele. A
                  // tela preta do Widget SOS fica por cima de TUDO,
                  // inclusive do bloqueio (ver SosWidgetFluxoService).
                  child: CamadaTelaSosWidget(
                    child: CamadaBloqueioApp(child: child!),
                  ),
                );
              },
              // CORREÇÃO DE BUG REAL (2026-08-11) — CAUSA RAIZ VERDADEIRA:
              // com `initialRoute` ausente, o `Navigator` resolve a rota
              // inicial a partir de `defaultRouteName` (a rota especial
              // de cold start, ex: "/cronometro_alarme_confirmacao")
              // através do algoritmo PADRÃO
              // `Navigator.defaultGenerateInitialRoutes`: para QUALQUER
              // nome de rota que comece com "/", esse algoritmo gera uma
              // PILHA de rotas — uma para "/" e OUTRA para o nome
              // completo —, chamando `onGenerateRoute` UMA VEZ PARA CADA
              // uma. Como o `onGenerateRoute` abaixo ignorava
              // completamente `settings.name` (sempre devolvia
              // `_telaInicial()`, não importa qual fosse a rota), as DUAS
              // chamadas geravam a MESMA tela — `AlarmeDisparadoScreen`/
              // `CronometroDisparadoScreen` — DUAS VEZES empilhadas. A
              // segunda instância se autodetectava como duplicata (ver
              // `_instanciaGraficaAberta` em `alarme_disparado_screen.dart`/
              // `cronometro_disparado_screen.dart`) e se autorremovia via
              // `Navigator.pop()` — que, por remover sempre o TOPO da
              // pilha (não necessariamente "a si mesma"), acabava
              // fechando também o diálogo de PIN que a PRIMEIRA instância
              // tinha acabado de abrir por cima dela, no instante exato
              // em que ele deveria abrir. Sintoma real reportado: "o
              // som/teclado ameaçam aparecer, mas são interrompidos
              // imediatamente" — confirmado no log (mesma thread/engine,
              // "tela duplicada" seguido, sequencialmente, de uma segunda
              // tentativa bem-sucedida). `onGenerateInitialRoutes` abaixo
              // SUBSTITUI por completo esse algoritmo padrão de
              // segmentação, garantindo EXATAMENTE uma única rota inicial
              // — nunca uma pilha — não importa quantos "/" o nome da
              // rota especial de cold start contenha.
              onGenerateInitialRoutes: (initialRouteName) {
                return [
                  MaterialPageRoute(
                    builder: (_) => _telaInicial(),
                    settings: RouteSettings(name: initialRouteName),
                  ),
                ];
              },
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (_) => _telaInicial(),
                  settings: settings,
                );
              },
            );
          },
        );
      },
    );
  }
}

class TelaInicialComPossivelDialogoPin extends StatefulWidget {
  const TelaInicialComPossivelDialogoPin({
    super.key,
    required this.aguardandoConfirmacaoPin,
  });

  final bool aguardandoConfirmacaoPin;

  @override
  State<TelaInicialComPossivelDialogoPin> createState() =>
      _TelaInicialComPossivelDialogoPinState();
}

class _TelaInicialComPossivelDialogoPinState
    extends State<TelaInicialComPossivelDialogoPin> {
  @override
  void initState() {
    super.initState();
    if (widget.aguardandoConfirmacaoPin) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _exibirDialogoDePinPendente();
      });
    }
  }

  Future<void> _exibirDialogoDePinPendente() async {
    if (!mounted) return;
    try {
      final config = await DatabaseHelper().getUserConfig();
      final pinReal = config?['pin_real'] as String?;
      if (!mounted) return;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinReal,
        segundosTolerancia: null,
        aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
        aoAtingirLimiteDeErros: _aoErrarPinDuasVezes,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao exibir diálogo de PIN pendente: $e');
    }
  }

  Future<void> _aoConfirmarPinCorreto() async {
    try {
      await DatabaseHelper().limparAguardandoConfirmacaoPin();
    } catch (e) {
      debugPrint('⚠️ Falha ao limpar flag de confirmação de PIN: $e');
    }
  }

  Future<void> _aoErrarPinDuasVezes() async {
    // ORDEM CRÍTICA: alerta para a nuvem primeiro e aguardado, antes de
    // qualquer outro processamento — ver mesma lógica em
    // SegurancaTab._dispararSosDeCoacao.
    try {
      await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto();
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta prioritário na nuvem: $e');
    }
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto();
    } catch (e) {
      debugPrint(
          '⚠️ Falha ao disparar alerta de tentativa de desarme incorreta: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const HomeScreen();
  }
}

/// Placeholder neutro (sem nenhum campo de texto/foco) exibido só durante o
/// instante do cold start via SOS Físico, antes da CameraCapturaScreen ser
/// empurrada por cima em [navigateToCameraCaptura].
class _TelaPretaAguardandoSos extends StatelessWidget {
  const _TelaPretaAguardandoSos();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: Colors.black);
  }
}

/// Cor de fundo preta pura compartilhada pela splash nativa do Android
/// (ver `android/app/.../drawable/launch_background.xml` e
/// `values/colors.xml`, `@color/launch_background`) e pela
/// [_ConteudoSplashAnimada] — garante zero "flash" de cor entre o
/// toque no ícone e o primeiro frame do Flutter.
const Color _corSplashDeMarca = Colors.black;

/// Crossfade final da splash para a LoginScreen — dispara assim que a
/// animação da [_ConteudoSplashAnimada] termina de verdade (ver
/// [_SplashGateState._aguardarProntidao]), sem nenhum orçamento fixo
/// adicional somado por cima.
const Duration _duracaoCrossfadeParaLogin = Duration(milliseconds: 300);

/// Chave do SharedPreferences que guarda o ÍNDICE (0-5) da PRÓXIMA
/// frase de marca a exibir na splash — persiste entre aberturas do app
/// para que as 6 frases apareçam em loop sequencial (1→2→…→6→1…), uma
/// por abertura, em vez de repetir/sortear (ver [_SplashGateState]).
const String _prefsChaveIndiceFraseSplash = 'splash_frase_indice_proxima';

/// As 6 frases de marca (uma por abertura, em loop) exibidas na splash
/// cinematográfica — ver `lib/l10n/app_*.arb` (`splashFrase1..6`).
/// Cada frase é dividida em linhas por "\n"; a linha cujo conteúdo
/// (normalizado) é exatamente "GUARDIÃO X" fica FIXA na tela durante a
/// animação de saída, as demais deslizam para cima e desaparecem — ver
/// [_ConteudoSplashAnimada._ehLinhaDaMarca].
List<String> _frasesSplash(AppLocalizations l10n) => <String>[
      l10n.splashFrase1,
      l10n.splashFrase2,
      l10n.splashFrase3,
      l10n.splashFrase4,
      l10n.splashFrase5,
      l10n.splashFrase6,
    ];

/// Rota inicial do app no cold start NORMAL. Mostra a splash
/// cinematográfica de marca ([_ConteudoSplashAnimada]) sobre o MESMO fundo
/// preto da splash nativa e, ao terminar a animação, troca (DENTRO desta
/// mesma rota — nunca com `pushReplacement`, que substituiria a câmera do
/// SOS se o Widget já tivesse empurrado uma por cima) para:
/// - a Home, se houver sessão persistida — coberta pelo bloqueio local
///   (ver [BloqueioAppService]);
/// - a [LoginScreen], se não houver.
///
/// O Firebase só é disparado depois da animação (ele compete pela UI
/// thread e deixava a splash mais lenta) e é aguardado aqui para decidir
/// entre as duas telas.
class _SplashGate extends StatefulWidget {
  const _SplashGate({this.semAnimacao = false});

  /// Cold start pelo Widget SOS: a tela preta do SOS cobre tudo, então
  /// nada de animação (nem consumo da frase da vez) — só a decisão
  /// Home/login, sobre fundo preto.
  final bool semAnimacao;

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

enum _DestinoSplash { splash, login, home, onboarding, completarPerfil }

class _SplashGateState extends State<_SplashGate> {
  _DestinoSplash _destino = _DestinoSplash.splash;

  /// Sinalizado por [_ConteudoSplashAnimada] (via `onConcluida`) assim
  /// que a sequência real de animação (digitação + pausa + saída — ver
  /// [_ConteudoSplashAnimadaState]) termina. É o ÚNICO gatilho de
  /// [_aguardarProntidao] — substitui o antigo orçamento fixo de tempo,
  /// que somava um delay artificial por cima da animação de verdade.
  final Completer<void> _animacaoConcluidaCompleter = Completer<void>();

  /// Índice (0-5) da frase a exibir nesta abertura — só fica não-nulo
  /// depois da leitura (rápida, mas assíncrona) do SharedPreferences,
  /// para nunca trocar a frase NO MEIO da animação de digitação (ver
  /// [_carregarIndiceFrase]).
  int? _indiceFrase;

  @override
  void initState() {
    super.initState();
    if (widget.semAnimacao) {
      _aoAnimacaoConcluir();
    } else {
      _carregarIndiceFrase();
    }
    _aguardarProntidao();
  }

  Future<void> _carregarIndiceFrase() async {
    int indiceSorteado = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      indiceSorteado = (prefs.getInt(_prefsChaveIndiceFraseSplash) ?? 0) % 6;
      // Fire-and-forget: já grava o índice da PRÓXIMA abertura — não
      // precisa ser aguardado, e não deve atrasar a splash atual.
      unawaited(
        prefs.setInt(_prefsChaveIndiceFraseSplash, (indiceSorteado + 1) % 6),
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao ler índice da frase de splash: $e');
    }
    if (mounted) setState(() => _indiceFrase = indiceSorteado);
  }

  void _aoAnimacaoConcluir() {
    if (!_animacaoConcluidaCompleter.isCompleted) {
      _animacaoConcluidaCompleter.complete();
    }
  }

  Future<void> _aguardarProntidao() async {
    // Transição dispara assim que a animação de verdade terminar — ver
    // [_animacaoConcluidaCompleter] — sem nenhum orçamento fixo de tempo
    // adicional por cima: nenhuma alteração na digitação/pausa/saída.
    await _animacaoConcluidaCompleter.future;

    // SÓ AGORA (animação já terminou) dispara o Firebase — ver comentário
    // completo em [main]: rodá-lo EM PARALELO com a animação a deixava
    // visivelmente mais lenta (compete pela mesma UI thread nativa).
    // Aguardado (com teto) para saber se existe sessão persistida.
    try {
      await _garantirFirebaseEAuth().timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('⚠️ [SplashGate] Firebase demorou/falhou ao inicializar: $e');
    }

    // Conta por e-mail/senha que nunca confirmou o e-mail não entra direto
    // — a LoginScreen mantém a barreira de `emailVerified`.
    _DestinoSplash destino = _DestinoSplash.login;
    if (BloqueioAppService.sessaoValida()) {
      BloqueioAppService().bloquearSeHouverSessao();
      // Mesma ordem do login social ([_finalizarLoginComSucesso] em
      // login_screen.dart): telefone primeiro, depois Assistente/Home —
      // cobre quem fechou o app no meio de "Completar perfil".
      if (await _precisaCompletarPerfil()) {
        destino = _DestinoSplash.completarPerfil;
      } else {
        destino = await OnboardingService().jaConcluido()
            ? _DestinoSplash.home
            : _DestinoSplash.onboarding;
      }
    }
    if (!mounted) return;
    setState(() => _destino = destino);
    if (destino == _DestinoSplash.login &&
        !widget.semAnimacao &&
        await SessaoRevogadaService.foiRevogada()) {
      // Só iOS: a última sessão foi encerrada por login em outro aparelho
      // — explica isso em vez de mostrar só o formulário de login.
      SessaoRevogadaService().exibirTela();
    }
    if (destino == _DestinoSplash.home) {
      // Solicitação de localização que abriu o app: o modal abre por cima
      // da Home (fica atrás do bloqueio até o desbloqueio).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        abrirSolicitacaoPendenteAposAutenticacao();
      });
    }
  }

  /// Conta só social (sem senha) que nunca gravou telefone. Na dúvida
  /// (sem rede), segue para a Home — o perfil é cobrado na próxima
  /// abertura, nunca às custas do acesso ao SOS.
  Future<bool> _precisaCompletarPerfil() async {
    final usuario = FirebaseAuthService().usuarioAtual;
    if (usuario == null ||
        usuario.providerData.any((p) => p.providerId == 'password')) {
      return false;
    }
    try {
      final config = await DatabaseHelper().getUserConfig();
      final telefoneLocal = config?['telefone'] as String?;
      if (telefoneLocal != null && telefoneLocal.trim().isNotEmpty) return false;
    } catch (_) {}
    return await FirebaseSyncService().possuiTelefoneNoPerfil() == false;
  }

  Widget _telaDoDestino() {
    switch (_destino) {
      case _DestinoSplash.completarPerfil:
        return const CompletarPerfilScreen(aoConcluir: decidirProximaTelaAposAutenticacao);
      case _DestinoSplash.home:
        return const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false);
      case _DestinoSplash.onboarding:
        return const OnboardingScreen(aoConcluir: navegarParaFluxoPrincipal);
      case _DestinoSplash.login:
      case _DestinoSplash.splash:
        return const LoginScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _duracaoCrossfadeParaLogin,
      child: _destino != _DestinoSplash.splash
          ? KeyedSubtree(key: ValueKey(_destino), child: _telaDoDestino())
          : (_indiceFrase == null
              // Placeholder preto (idêntico ao fundo da splash nativa
              // E da splash animada) só pelos poucos milissegundos da
              // leitura assíncrona do índice da frase — invisível na
              // prática, sem nenhum "flash" de cor.
              ? const ColoredBox(
                  key: ValueKey('splash_preta_aguardando_indice'),
                  color: _corSplashDeMarca,
                )
              : _ConteudoSplashAnimada(
                  key: ValueKey('splash_de_marca_$_indiceFrase'),
                  indiceFrase: _indiceFrase!,
                  onConcluida: _aoAnimacaoConcluir,
                )),
    );
  }
}

/// Splash cinematográfica de marca: a frase do índice sorteado (ver
/// [_frasesSplash]) é digitada letra por letra, linha por linha
/// ("efeito máquina de escrever"); ao terminar, uma breve pausa e então
/// a animação de saída — a linha "GUARDIÃO X" fica FIXA na tela e as
/// demais deslizam para cima enquanto desaparecem (fade out). Fundo
/// preto puro, texto em negrito verde neon com efeito de brilho/glow.
class _ConteudoSplashAnimada extends StatefulWidget {
  const _ConteudoSplashAnimada({
    super.key,
    required this.indiceFrase,
    this.onConcluida,
  });

  final int indiceFrase;

  /// Chamado UMA VEZ, assim que a sequência (digitação + pausa + saída)
  /// termina de verdade — ver [_ConteudoSplashAnimadaState._iniciarSequenciaDeAnimacao].
  /// Não altera em nada o ritmo/duração da animação em si, só notifica
  /// quem está esperando (ver [_SplashGateState]).
  final VoidCallback? onConcluida;

  @override
  State<_ConteudoSplashAnimada> createState() =>
      _ConteudoSplashAnimadaState();
}

class _ConteudoSplashAnimadaState extends State<_ConteudoSplashAnimada>
    with TickerProviderStateMixin {
  static const Color _verdeNeon = Color(0xFF39FF14);

  // Timings da animação em si — INTOCADOS a pedido explícito do usuário
  // (2026-08-06): a velocidade de digitação e o restante do efeito devem
  // continuar exatamente como estão. A splash agora transiciona para a
  // LoginScreen assim que esta sequência termina de verdade (ver
  // [_SplashGateState._aguardarProntidao]), sem nenhum orçamento fixo
  // adicional somado por cima — soma ≈ 3.2s (2.1s digitando + 0.3s de
  // pausa com "GUARDIÃO X" sozinha na tela + 0.8s de saída).
  static const Duration _duracaoDigitacao = Duration(milliseconds: 2100);
  static const Duration _duracaoPausaPosDigitacao =
      Duration(milliseconds: 300);
  static const Duration _duracaoSaida = Duration(milliseconds: 800);

  late final AnimationController _digitacaoController;
  late final AnimationController _saidaController;
  late final Animation<double> _curvaSaida;

  List<String> _linhas = const <String>[];
  int _totalCaracteres = 0;

  @override
  void initState() {
    super.initState();
    _digitacaoController = AnimationController(
      vsync: this,
      duration: _duracaoDigitacao,
    );
    _saidaController = AnimationController(
      vsync: this,
      duration: _duracaoSaida,
    );
    _curvaSaida = CurvedAnimation(
      parent: _saidaController,
      curve: Curves.easeInCubic,
    );
    _iniciarSequenciaDeAnimacao();
  }

  Future<void> _iniciarSequenciaDeAnimacao() async {
    await _digitacaoController.forward();
    if (!mounted) return;
    await Future<void>.delayed(_duracaoPausaPosDigitacao);
    if (!mounted) return;
    await _saidaController.forward();
    // Sequência de verdade terminou — libera a troca para a LoginScreen
    // (ver [_SplashGateState]) imediatamente, sem esperas extras.
    widget.onConcluida?.call();
  }

  @override
  void dispose() {
    _digitacaoController.dispose();
    _saidaController.dispose();
    super.dispose();
  }

  /// A linha que corresponde à marca (ver [AppLocalizations.marcaGuardiaoX])
  /// fica fixa na tela durante a saída — as demais linhas da frase é que
  /// sobem/desaparecem (ver classe doc). Comparação resiliente a espaço
  /// vs. hífen (as frases da splash escrevem "GUARDIAN X", o resto do
  /// app usa "Guardian-X") e a maiúsculas/minúsculas — nunca mais um
  /// literal fixo em português, já que a marca agora é traduzida por
  /// idioma (ver `lib/l10n/app_*.arb`, chave `marcaGuardiaoX`). Custo
  /// igual ao da comparação anterior (duas normalizações de string por
  /// linha, por frame) — não introduz nenhum trabalho a mais no boot.
  bool _ehLinhaDaMarca(String linha, String marcaLocalizada) {
    String normalizar(String texto) =>
        texto.trim().toUpperCase().replaceAll(RegExp(r'[-\s]+'), ' ');
    return normalizar(linha) == normalizar(marcaLocalizada);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final frases = _frasesSplash(l10n);
    final frase = frases[widget.indiceFrase % frases.length];
    _linhas = frase.split('\n');
    _totalCaracteres =
        _linhas.fold<int>(0, (soma, linha) => soma + linha.length);

    return Scaffold(
      backgroundColor: _corSplashDeMarca,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: SizedBox(
              width: double.infinity,
              child: AnimatedBuilder(
                animation: Listenable.merge(
                  <Listenable>[_digitacaoController, _saidaController],
                ),
                builder: (context, _) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _construirLinhas(context),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _construirLinhas(BuildContext context) {
    final double valorDigitacao = _digitacaoController.value;
    final int caracteresVisiveis =
        (_totalCaracteres * valorDigitacao).round();
    final String marcaLocalizada = AppLocalizations.of(context)!.marcaGuardiaoX;

    // Tamanho-base responsivo: proporcional à largura da tela, com
    // limites para não "apertar" em telas pequenas nem sobrar espaço
    // excessivo em telas grandes/tablets — o FittedBox abaixo ainda
    // encolhe por linha se, mesmo assim, algum texto não couber.
    final double larguraTela = MediaQuery.of(context).size.width;
    final double fonteMarca = (larguraTela * 0.135).clamp(30.0, 52.0);
    final double fonteDemais = fonteMarca * 0.6;

    int acumulado = 0;
    final widgets = <Widget>[];
    for (final linha in _linhas) {
      final int inicioLinha = acumulado;
      acumulado += linha.length;
      final int visivelNaLinha =
          (caracteresVisiveis - inicioLinha).clamp(0, linha.length);
      final String textoParcial = linha.substring(0, visivelNaLinha);
      final bool aindaDigitandoEstaLinha =
          visivelNaLinha > 0 && visivelNaLinha < linha.length;

      final bool fixa = _ehLinhaDaMarca(linha, marcaLocalizada);
      final double progressoSaida = fixa ? 0.0 : _curvaSaida.value;
      final double fonteLinha = fixa ? fonteMarca : fonteDemais;
      final String textoExibido =
          textoParcial + (aindaDigitandoEstaLinha ? '▏' : '');

      // FittedBox com um filho de largura intrínseca ZERO (Text('')) faz o
      // Flutter estourar 'width > 0.0': is not true dentro de
      // BoxFit.scaleDown (assert só ativo em modo debug — por isso passou
      // despercebido testando só builds release) — acontece exatamente no
      // instante em que uma linha ainda não começou a "digitar" (nenhum
      // caractere nem cursor visível ainda). Nesse caso, reserva a MESMA
      // altura da linha com um SizedBox simples (sem FittedBox) em vez de
      // tentar ajustar-a-caber um texto vazio — evita tanto o crash quanto
      // um "pulo" de layout no instante em que a 1ª letra aparece.
      final Widget conteudoLinha = textoExibido.isEmpty
          ? SizedBox(height: fonteLinha * 1.15)
          : FittedBox(
              fit: BoxFit.scaleDown,
              child: _TextoNeon(
                texto: textoExibido,
                fontSize: fonteLinha,
                cor: _verdeNeon,
              ),
            );

      widgets.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: fixa ? 10 : 6),
          child: Opacity(
            opacity: (1.0 - progressoSaida).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -36 * progressoSaida),
              child: conteudoLinha,
            ),
          ),
        ),
      );
    }
    return widgets;
  }
}

/// Texto em negrito, verde sólido e nítido (sem sombra/glow) — usado nas
/// linhas da [_ConteudoSplashAnimada].
class _TextoNeon extends StatelessWidget {
  const _TextoNeon({
    required this.texto,
    required this.fontSize,
    required this.cor,
  });

  final String texto;
  final double fontSize;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    return Text(
      texto,
      textAlign: TextAlign.center,
      maxLines: 1,
      softWrap: false,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.4,
        height: 1.15,
        color: cor,
      ),
    );
  }
}