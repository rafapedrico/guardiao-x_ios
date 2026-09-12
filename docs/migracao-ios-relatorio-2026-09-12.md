# Relatório Técnico — Migração/Adaptação do Guardião-X: Android → iOS

**Data:** 2026-09-12
**Branch analisada:** `feat/chat-suporte-ia` (commit `8ec1628`)
**Método:** leitura direta do código-fonte via `git show HEAD:<arquivo>` (ver nota sobre o diretório de trabalho no topo da conversa)

---

## 0.1 Rodada de mitigação pós-Fase 4 (2026-09-12) — impactos colaterais dos 4 itens sem equivalente

Antes da Fase 5, auditoria adicional em busca de efeitos colaterais das restrições da seção 5 sobre OUTRAS partes do app (onboarding, Configurações, cold start). Achados e correções, todas com `Platform.isIOS`/`Platform.isAndroid` — Android 100% inalterado:

1. **Bug de onboarding (crítico, corrigido):** `SmsPermissionService.verificarNoOnboarding`/`verificarAoAdicionarPrimeiroContato` mostravam, para TODO usuário iOS, um diálogo pedindo para "ativar o SMS de emergência" — contradizendo diretamente a decisão da Fase 2 (SMS desativado no iOS). Ambos agora retornam imediatamente no iOS.
2. **Cards mortos em Configurações (corrigido):** `DeviceAdminService.estaAtivo()` e `BatteryOptimizationService.estaIsento()` agora retornam `true` no iOS (conceitos inexistentes na plataforma — "já satisfeito" é o valor honesto), escondendo os cards de "Ativar Device Admin"/"Isenção de bateria" que, sem isso, ficariam visíveis para sempre com um botão que não faz nada.
3. **Gap de cold start (corrigido):** toque na notificação de check-in de rotina com o app 100% fechado não era tratado (`_capturarPayloadSolicitacaoPendente` só reconhecia payloads JSON, não o `idAlarme` cru do check-in) — mais grave no iOS, onde esse toque é o ÚNICO caminho de cold start para esse fluxo (sem `RotinaCheckinAlarmActivity` nativa). Agora captura e abre `AlarmeDisparadoScreen` direto, pulando a barreira de login (confirmação é 100% local/SQLite) — mesma política já usada para alerta recebido. Bônus: também corrige o mesmo gap que já existia (silenciosamente) no Android.
4. **🟡 Parcialmente resolvido — só a referência em português:** `faqResposta13` (`lib/l10n/app_pt.arb`) reescrita para deixar explícito que o gatilho físico de Volume+ é exclusivo do Android ("No iPhone, a Apple não permite que aplicativos escutem o botão de volume em segundo plano — por isso, nesse sistema, o botão específico da página Segurança é a forma de acionar o alerta"). **Os outros 10 idiomas (`app_ar/de/en/es/fr/hi/it/ja/ru/zh.arb`) continuam com o texto antigo/genérico, por decisão explícita do usuário** — a tradução de todos os idiomas fica para depois de todo o projeto estar concluído, usando o português como referência.

---

## 0. Achado prévio — não existe projeto iOS neste repositório

Não é um problema de configuração: **a pasta `ios/` nunca foi criada nem commitada** (`git ls-tree -r HEAD --name-only | grep '^ios/'` não retorna nada). O próprio `pubspec.yaml` confirma isso, no bloco do `flutter_launcher_icons`:

```yaml
flutter_launcher_icons:
  android: true
  ios: false
  ...
# este repositório não possui projeto iOS.
```

E `lib/firebase_options.dart` também documenta isso explicitamente:

```dart
// Cobre APENAS Android, único alvo mobile real do projeto no momento — ver
// ... iOS/Web no futuro, rode `flutterfire configure` de verdade para gerar as
```

**Passo zero da migração**, antes de qualquer item abaixo: `flutter create . --platforms=ios` para gerar o runner Xcode, registrar o app iOS no Firebase Console (mesmo projeto `guardiaox`, bundle id `com.rmfglobal.guardiaox` — o mesmo `applicationId` do Android, ver `android/app/build.gradle:51`), baixar o `GoogleService-Info.plist` real e rodar `flutterfire configure` para gerar a seção `ios` de `firebase_options.dart` (hoje só existe `android`, e `DefaultFirebaseOptions.currentPlatform` lança exceção em qualquer outra plataforma).

---

## 1. Dependências e Plugins (`pubspec.yaml`)

| Pacote | Suporte iOS | Ação necessária |
|---|---|---|
| `firebase_core`, `cloud_firestore`, `firebase_auth`, `firebase_messaging`, `cloud_functions`, `firebase_storage` | ✅ Nativo | Registrar app iOS no Firebase Console + `GoogleService-Info.plist` + chave APNs (Auth Key .p8) enviada ao Firebase para `firebase_messaging` funcionar |
| `firebase_app_check` `^0.2.1+22` | ✅, mas provider diferente | Android usa Play Integrity; iOS precisa `AppleProvider.deviceCheck` (ou App Attest) ativado explicitamente em `main.dart::_iniciarFirebaseEAuth` |
| `google_sign_in` `^7.2.0` | ✅ | Precisa do `REVERSED_CLIENT_ID` (do `GoogleService-Info.plist`) registrado como `CFBundleURLTypes` no `Info.plist` |
| `sign_in_with_apple` `^7.0.1` | ✅ Nativo do iOS | Habilitar capability "Sign In with Apple" no Xcode (no Android já é usado via web/REST) |
| `in_app_purchase` `^3.2.0` | ✅ | OK |
| `in_app_purchase_android` `^0.5.2` | ❌ **Android-only** | `premium_purchase_service.dart:7` importa `GooglePlayPurchaseParam` diretamente e em `premium_purchase_service.dart:151` faz `Platform.isAndroid ? GooglePlayPurchaseParam(...) : PurchaseParam(...)` — precisa adicionar `in_app_purchase_storekit` e montar o ramo iOS (`AppStorePurchaseParam`), além de cadastrar os produtos de assinatura no App Store Connect. **A validação de recibo no backend também precisa de um par iOS**: hoje `functions/premiumPurchaseService.js` só valida contra a Play Developer API — falta o equivalente via App Store Server API/`verifyReceipt` |
| `android_alarm_manager_plus` `^4.0.3` | ❌ **Sem implementação iOS** (plugin puramente Android) | Usado em `rotina_alarme_service.dart`, `notificacao_service.dart` e no comentário de `background_location_heartbeat_service.dart` para agendar o alarme "exato" que sobrevive ao app morto. **Não há substituto direto** — ver seção 5 |
| `flutter_local_notifications` `^19.5.0` | ✅, mas API bem diferente | `AndroidNotificationDetails(fullScreenIntent: ...)` (usado para acordar a tela com o app fechado) não tem equivalente no iOS — notificação local no iOS nunca abre uma tela custom por cima do bloqueio. Setup de permissão/categoria (`UNUserNotificationCenter`, `UNNotificationCategory` para a ação rápida "✅ Cheguei bem") precisa ser escrito do zero |
| `geolocator` `^10.1.0` | ✅, mas modelo de background diferente | `location_service.dart` roda um `Timer.periodic` de 2 min em memória Dart — no iOS isso é suspenso quando o app vai para segundo plano, a menos que se ative "Background Modes → Location updates" e ainda assim o SO pode restringir a frequência. Precisa `NSLocationAlwaysAndWhenInUseUsageDescription` + justificativa forte para a revisão da App Store (apps de localização contínua em segundo plano recebem escrutínio extra) |
| `camera` `0.10.5+9` | ✅ | Versão fixada por causa de um problema de Gradle Android — validar `pod install` no iOS antes de confiar (versão relativamente antiga) |
| `flutter_contacts` `^1.1.9+2` | ✅ | Precisa `NSContactsUsageDescription` |
| `permission_handler` `^11.3.1` | ✅, mas exige config extra | Cada grupo de permissão usado (câmera, contatos, localização, notificação) precisa ser habilitado via macro no `Podfile` (`permission_handler_apple`), além da chave correspondente no `Info.plist` |
| `audioplayers` `^6.1.0` | ✅, mas silenciado pelo modo Silencioso/Foco | Usado para o alarme sonoro em loop de `AlertaRecebidoAlarmService`/rotina — no Android o app força `STREAM_ALARM` no volume máximo; no iOS isso exige `AVAudioSession` categoria `.playback` +, para realmente furar o interruptor Silencioso/Modo Foco como o Android faz, o entitlement especial de **Critical Alerts** (concedido pela Apple mediante solicitação formal — não é automático) |
| `gal`, `share_plus`, `path_provider`, `url_launcher`, `phone_numbers_parser`, `dio`, `http`, `sqflite`, `encrypt`, `crypto`, `shared_preferences`, `font_awesome_flutter`, `cupertino_icons` | ✅ | Sem ação — multiplataforma nativo |
| `flutter_launcher_icons` | Config atual `ios: false` | Trocar para `true` e gerar ícone iOS (1024×1024) assim que `ios/` existir |

---

## 2. Permissões Nativas → `Info.plist`

Mapeamento do `AndroidManifest.xml` atual (`android/app/src/main/AndroidManifest.xml`) para o equivalente iOS:

| Permissão/Config Android | Equivalente iOS | Observação |
|---|---|---|
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` | `NSLocationWhenInUseUsageDescription` | — |
| `ACCESS_BACKGROUND_LOCATION` | `NSLocationAlwaysAndWhenInUseUsageDescription` + capability **Background Modes → Location updates** | Comentário no próprio manifest diz que sem essa declaração o Android nem oferece "permitir o tempo todo" — no iOS o equivalente é o par de chaves `NSLocationAlwaysAndWhenInUseUsageDescription` + `NSLocationWhenInUseUsageDescription` (as duas juntas são exigidas para o SO oferecer "Always") |
| `CAMERA` | `NSCameraUsageDescription` | Usado por `CameraCapturaScreen` (Captura e Dissuasão) |
| Gravação de vídeo com áudio (se aplicável) | `NSMicrophoneUsageDescription` | Verificar se `camera` grava áudio no fluxo de dissuasão |
| `READ_CONTACTS` / `WRITE_CONTACTS` | `NSContactsUsageDescription` | Aba Família (contatos de emergência) |
| `POST_NOTIFICATIONS` | Sem chave estática — pedido em runtime via `UNUserNotificationCenter.requestAuthorization` | Precisa também da capability **Push Notifications** no Xcode + subir a chave APNs (.p8) no Firebase Console para o `firebase_messaging` funcionar |
| `RECEIVE_BOOT_COMPLETED`, `SCHEDULE_EXACT_ALARM`, `USE_EXACT_ALARM`, `WAKE_LOCK`, `FOREGROUND_SERVICE*` | **Sem equivalente no iOS** | Sustentam o `android_alarm_manager_plus` e os Foreground Services nativos (`SosDispatchService`, `SolicitacaoMonitoramentoWakeService`, `AlertaRecebidoAlarmService`, `VolumeSosService`) — não existe API pública equivalente no iOS. Ver seção 5 |
| `MODIFY_AUDIO_SETTINGS` | `AVAudioSession` (categoria `.playback`) | Usado para forçar volume máximo do alarme — no iOS não é possível ignorar o interruptor físico Silencioso/Modo Foco sem o entitlement de Critical Alerts (`com.apple.developer.usernotifications.critical-alerts`, aprovação manual da Apple) |
| `DISABLE_KEYGUARD` | **Não existe no iOS** | Apple não permite nenhuma API para dispensar/desenhar sobre o Keyguard — ver seção 5 |
| `READ_PHONE_STATE` | **N/A** | Só existe para resolver o `SmsManager` do chip ativo em aparelhos dual-SIM (`SmsSender.kt`) — sem sentido no iOS, onde não existe `SmsManager` |
| `SEND_SMS` | **Não existe** — Apple não expõe nenhuma API pública para enviar SMS programaticamente, com ou sem permissão | Ver seção 3, é o ponto mais crítico da migração |
| `USE_FULL_SCREEN_INTENT` | Sem equivalente direto | Notificação local do iOS não consegue abrir uma tela custom por cima do bloqueio de tela |
| — (config adicional só do iOS) | `UIBackgroundModes`: `location`, `remote-notification`, possivelmente `audio` | Precisa ser adicionado do zero ao `Info.plist` |
| — (config adicional só do iOS) | `ITSAppUsesNonExemptEncryption = false` | Evita a pergunta de compliance de exportação em todo upload à App Store (o app usa `encrypt`/`crypto`, mas não para fins de exportação controlada) |

---

## 3. Lógica de SMS → fluxo exclusivo de Push no iOS

Esta é a mudança mais profunda do projeto, porque **SMS nativo não é só "um canal a mais" — é o canal de garantia usado exatamente quando o Push não está disponível.**

### 3.1 Onde o SMS nativo é enviado hoje

- **`android/app/src/main/kotlin/.../SmsSender.kt`** — classe Kotlin inteira em torno de `android.telephony.SmsManager` (resolução de chip ativo em dual-SIM, envio multipart, mapeamento de `RESULT_ERROR_*`). 100% API Android; não existe portabilidade, deve simplesmente não existir no alvo iOS.
- **`lib/services/emergency_alert_service.dart`** — canal `_canalSms = MethodChannel('.../sms')`, método privado que monta a mensagem e chama `enviarSms` nesse canal (bloco em torno da invocação `_canalSms.invokeMethod('enviarSms', {...})`). **Este é o ponto central de branch**: no iOS essa chamada deve ser simplesmente pulada (o canal nativo nem vai existir).
- **`lib/services/sms_permission_service.dart`** — serviço inteiro dedicado a pedir `SEND_SMS`/`READ_PHONE_STATE` em runtime, chamado por `lib/screens/home_screen.dart:80` (`verificarNoOnboarding`) e `lib/screens/tabs/configuracoes_tab.dart:449` (`verificarAoAdicionarPrimeiroContato`). No iOS deve virar no-op (ou a tela de onboarding correspondente deve ser removida/adaptada).
- **`lib/services/sos_disparo_service.dart`** — o comentário de topo da classe documenta explicitamente a arquitetura de **dois canais paralelos** do P1 (disparo imediato):
  1. **SMS nativo do aparelho** (`SmsManager`, sem custo, sem depender de conta/nuvem);
  2. **App-para-App via Push FCM**, através da Cloud Function `dispararAlertaHibrido`.

  E o trecho decisivo:
  > "O canal 2 só dispara quando há sessão do Firebase Auth disponível [...]. Nesse caso específico, o canal 1 (SMS) é o ÚNICO que dispara — decisão explícita do produto: a entrega de P1 NUNCA pode depender de autenticação na nuvem."

  Isso cobre o botão físico (Volume+ segurado 3s) acionado com o app **frio e a tela bloqueada, sem sessão ativa** (política "Opção A" de logout a cada cold start, ver `FirebaseAuthService`).

### 3.2 Por que isso não é uma simples troca de canal

- **Não existe fallback client-side no iOS.** Sem `SmsManager`, não há nenhuma forma de o app enviar uma mensagem sem depender de rede + backend.
- **O cenário que o SMS resolve (usuário sem sessão, app frio, tela bloqueada) também não existe estruturalmente no iOS**, porque a própria abertura do app por cima da tela de bloqueio (`LockscreenCameraActivity`, `RotinaCheckinAlarmActivity` — ver seção 5) não é possível no iOS. Ou seja, os dois pilares que sustentam "SMS como único canal garantido" (enviar sem rede, e rodar com a tela bloqueada sem desbloquear) simplesmente não têm base técnica no iOS.
- **Do lado do backend, isso já está resolvido corretamente para um cenário multiplataforma**: `functions/alertaHibridoService.js` documenta, como **regra de negócio permanente**, que a nuvem **nunca** deve enviar SMS/WhatsApp por gateway pago de terceiros (Twilio etc. foi removido deliberadamente em 2026-08-11) — o único canal de nuvem é Push FCM App-para-App gratuito. Isso significa que **não basta ligar um gateway de SMS no backend** para "resolver" o iOS sem violar essa regra de produto já estabelecida — é preciso decisão explícita do usuário/produto sobre se essa regra permanece ou é revista especificamente para iOS.

### 3.3 Recomendação de redesenho (decisão de produto necessária)

Para o iOS, o disparo do P1 sem sessão ativa precisa de uma nova estratégia — por exemplo, manter um token FCM válido cacheado localmente e associado ao usuário mesmo sem sessão Firebase Auth ativa (ex: reautenticação silenciosa/token de longa duração), para que o Push ainda possa ser disparado do backend mesmo no cenário "app frio". Isso é uma mudança de arquitetura de autenticação, não só de canal de envio — precisa ser alinhada com o usuário/dono do produto antes da implementação.

### 3.4 Outros pontos com "SMS" no nome que também precisam de revisão

- `EmergencyAlertService.enviarSmsComLinkDaFoto` / `enviarSmsResgateFoto` (P2, foto de dissuasão) — mesmo padrão dual-canal do P1, mesma dependência de `_canalSms`.
- `functions/relatorioFalhaService.js`, `functions/retencaoAlertasService.js`, `functions/entregaRetryEngine.js` — nomes sugerem acompanhamento de entrega; confirmar que tratam apenas do Push (não têm SMS embutido) antes de reaproveitar tal qual para iOS.

---

## 4. Arquivos Críticos para refatoração imediata

### Services (Dart) com dependência direta de API/canal nativo Android

| Arquivo | Motivo | Ação |
|---|---|---|
| `lib/services/emergency_alert_service.dart` | Canal `sms`, ponto central do disparo de SMS (seção 3) | Adicionar branch de plataforma; iOS pula o envio de SMS por completo |
| `lib/services/sms_permission_service.dart` | Só existe para pedir `SEND_SMS`/`READ_PHONE_STATE` | No-op/remover do fluxo de onboarding no iOS |
| `lib/services/device_admin_service.dart` | Canal `device_admin`, wrapper de `DevicePolicyManager.lockNow()` | **Sem equivalente iOS** — Apple não permite apps travarem a tela do usuário. Remover a funcionalidade e a tela de consentimento correspondente no iOS |
| `lib/services/volume_sos_service.dart` | Canal `volume_sos` + `volume_sos_events`, Foreground Service que escuta o botão físico de Volume+ em segundo plano | **Sem equivalente iOS** — iOS não permite interceptar botões de volume em segundo plano/app fechado. O próprio comentário do arquivo já reconhece isso ("plataforma não suporta (ex: iOS, onde este recurso não está implementado)"), então o guard try/catch já existe — mas a FUNCIONALIDADE (gatilho físico de SOS discreto) precisa de um substituto de produto para iOS (ex: gesto dentro do app, Botão de Ação do iPhone 15+, ou Atalho da Siri/App Intents) |
| `lib/services/rotina_alarme_service.dart` | Usa `android_alarm_manager_plus` + canal `rotina_alarme` para o alarme de rotina headless | Precisa reescrita completa do mecanismo de agendamento para iOS (ver seção 5) |
| `lib/services/notificacao_service.dart` | Usa `android_alarm_manager_plus`, canais `solicitacao_monitoramento`, `alerta_recebido_alarme`, `permissoes_nativas`, `fullScreenIntent` do `flutter_local_notifications` | Maior arquivo de integração nativa do projeto — precisa de um equivalente Swift para cada canal, ou remoção da funcionalidade correspondente |
| `lib/services/sos_dispatch_native_service.dart` | Canal `sos_dispatch`, mantém processo vivo via Foreground Service Android durante o envio do SOS | Sem Foreground Service no iOS; usar `BGProcessingTask`/`beginBackgroundTask` (garantia muito mais fraca — alguns segundos, não uma janela garantida) |
| `lib/services/background_location_heartbeat_service.dart` | `Timer.periodic` em memória Dart, para de rodar se o app for suspenso | No iOS precisa migrar para Significant-Location-Change API ou aceitar que o heartbeat só roda com o app em primeiro/segundo plano ativo (não morto) |
| `lib/services/location_service.dart` | Mesma limitação de `Timer.periodic` em segundo plano | Revisar estratégia de atualização periódica para o modelo de background do iOS |
| `lib/services/battery_optimization_service.dart` | Todo o fluxo de "pedir isenção de otimização de bateria" (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) | **Conceito não existe no iOS** — remover tela/fluxo equivalente |
| `lib/services/premium_purchase_service.dart` | Import direto de `in_app_purchase_android`/`GooglePlayPurchaseParam`, branch `Platform.isAndroid` já existe mas o ramo iOS não está implementado | Adicionar `in_app_purchase_storekit` + `AppStorePurchaseParam` |
| `lib/services/captura_dissuasao_service.dart` (indireto) | Depende de `DeviceAdminService.bloquearTelaAgora` como um dos fallbacks | Revisar fallback (hoje cai em `SystemNavigator.pop()` quando a permissão não foi concedida — esse já seria o único caminho no iOS) |

### Screens (Dart) com UI/fluxo Android-específico

| Arquivo | Motivo | Ação |
|---|---|---|
| `lib/screens/alarme_disparado_screen.dart` | 4 usos de `MethodChannel('.../rotina_alarme')`, tela pensada para abrir por cima do lockscreen | Redesenhar fluxo sem bypass de tela bloqueada |
| `lib/screens/cronometro_disparado_screen.dart` | 2 usos do mesmo canal nativo `rotina_alarme` | Idem |
| `lib/screens/camera_captura_screen.dart` | Canal `lockscreen` (`LockscreenPlugin`/`LockscreenCameraActivity`) — abre a câmera por cima do Keyguard | **Sem equivalente iOS** — o fluxo "P3/P4" (tela vermelha + bloqueio de tela ao deslizar) descrito em `sos_disparo_service.dart` precisa de redesenho completo para iOS |
| `lib/screens/permissoes_status_screen.dart` | Mostra cards de bateria/notificações/localização/câmera/tela cheia via `OnboardingService`, todos com lógica Android | Revisar cada card — bateria e tela cheia não fazem sentido no iOS |
| `lib/screens/excluir_conta_screen.dart` | Já tem `Platform.isIOS` (linha 50) apontando para URL de assinaturas da Apple — bom sinal, mas confirmar que cobre todo o fluxo de exclusão de conta/assinatura ativa exigido pelas guidelines da App Store (obrigatório desde 2022: apps com assinatura devem permitir cancelar/excluir conta dentro do app) |
| `lib/screens/onboarding_screen.dart` | Sequência de pedido de permissões (bateria, SMS, localização, câmera, tela cheia) — várias etapas Android-only | Redesenhar sequência para as permissões que realmente existem no iOS |

### Nativo Android (Kotlin) — inventário completo de canais que precisam de par Swift ou remoção

`android/app/src/main/kotlin/com/example/security_check_app/`: `SmsSender.kt`, `RotinaAlarmPlugin.kt`/`RotinaAlarmNativeReceiver.kt`/`RotinaAlarmWakeService.kt`, `LockscreenPlugin.kt`/`LockscreenCameraActivity.kt`, `DeviceAdminPlugin.kt`/`GuardiaoDeviceAdminReceiver.kt`, `SosDispatchPlugin.kt`/`SosDispatchService.kt`, `VolumeSosPlugin.kt`/`VolumeSosService.kt`/`VolumeSosBootReceiver.kt`/`VolumeSosBootWorker.kt`, `SolicitacaoMonitoramentoFcmReceiver.kt`/`SolicitacaoMonitoramentoWakeService.kt`, `AlertaRecebidoAlarmPlugin.kt`/`AlertaRecebidoAlarmService.kt`, `RotinaCheckinAlarmActivity.kt`, `MainActivity.kt`, `MainApplication.kt`.

**10 canais nativos distintos**, nenhum com implementação iOS hoje. Cada um precisa de uma decisão: (a) escrever o par em Swift com a API iOS equivalente (quando existe), ou (b) descontinuar a funcionalidade especificamente no iOS.

---

## 5. Funcionalidades sem equivalente direto no iOS — direcionamento de produto formal (atualizado 2026-09-12, pós-Fase 3)

Estas não são "ajustes de código" — são capacidades que a plataforma Apple **não permite por política/sandboxing**. As Fases 0-3 já resolveram SMS (seção 3) e o alarme exato do check-in de rotina (Fase 3, `RotinaAlarmeService` — ver histórico de mensagens da migração). Ficam **4 itens**, todos na mesma categoria "sem rota de código possível" — o trabalho desta rodada foi **auditar cada um, confirmar que o lado Dart já degrada com segurança no iOS, e registrar formalmente a decisão de produto**, não escrever mais código de plataforma.

| # | Item | Por que a Apple bloqueia | Status do código (auditado) | Decisão de produto formal para o iOS |
|---|---|---|---|---|
| 1 | **`rotina_alarme` (parte nativa restante)** — `RotinaCheckinAlarmActivity`, `RotinaAlarmWakeService`, WakeLock, abrir a Activity por cima do Keyguard já com o teclado de PIN | Apple não permite nenhum app desenhar uma tela própria por cima da tela de bloqueio sem desbloquear primeiro | ✅ Todas as chamadas a `MethodChannel('.../rotina_alarme')` em `AlarmeDisparadoScreen`/`CronometroDisparadoScreen`/`RotinaAlarmeService` já são try/catch — confirmadas seguras (Fase 3) | **Confirmado nesta migração:** no iOS, o usuário SEMPRE desbloqueia o aparelho normalmente primeiro; só depois vê a tela de confirmação do app (aberta pelo toque no lembrete local, ver Fase 3). Não há — nem haverá — "tela de PIN sobre o bloqueio" no iOS. |
| 2 | **`lockscreen` (`LockscreenCameraActivity`/`LockscreenPlugin`)** — abrir a câmera de dissuasão por cima do Keyguard sem desbloquear | Mesma restrição do item 1 | ✅ `CameraCapturaScreen._forcarShowWhenLocked` já é try/catch — confirmada segura | A Captura e Dissuasão no iOS só pode ser aberta com o aparelho já desbloqueado (fluxo normal do app). Sem alternativa possível — não é uma limitação de implementação, é uma restrição de sandboxing do SO. |
| 3 | **`device_admin` (`DevicePolicyManager.lockNow()`)** | Não existe API pública equivalente no iOS — nenhum app pode bloquear a tela do usuário sob demanda | ✅ `DeviceAdminService.bloquearTelaAgora()` já retorna `false` com segurança (nunca lança exceção) — confirmada segura | Recurso **não terá substituto** no iOS — ver ⚠️ abaixo, achado novo sobre o fallback (P4). |
| 4 | **`volume_sos` (gatilho físico de Volume+ por 3s, em segundo plano)** | iOS não expõe eventos de hardware de botão de volume para apps em segundo plano/fechados | ✅ `VolumeSosService.iniciarMonitoramento()` já é try/catch — o próprio comentário do arquivo já previa isso ("plataforma não suporta, ex: iOS") | O SOS discreto sem abrir o app **não existe no iOS**. Substituto sugerido para avaliação futura (fora do escopo desta migração): Botão de Ação do iPhone 15+/App Intents ou Atalho da Siri — ambos exigem o app já aberto pelo menos uma vez para configurar, e não são "background" no sentido do Android. Não implementado nesta fase. |

### ✅ Achado durante esta auditoria — resolvido (2026-09-12)

O fallback do **item 3** (P4 da sequência de SOS, gesto "deslizar para cima" em `CameraCapturaScreen._acionarSaidaDeSeguranca`) usava `SystemNavigator.pop()` quando o bloqueio nativo não está disponível — no Android isso fecha/minimiza o app; **no iOS é um no-op** (a Apple não permite encerramento programático), deixando a tela de evidência presa na tela.

**Decisão de produto:** no iOS, o gesto passa a voltar direto para a Home na aba Segurança (`HomeScreen(abaInicial: 0)`), removendo todas as rotas anteriores da pilha — a tela de evidência some da tela mesmo sem o app se encerrar de fato. Implementado em `CameraCapturaScreen._saidaDeSegurancaFallback` (novo método): `Platform.isAndroid` mantém `SystemNavigator.pop()` 100% inalterado; no iOS, `Navigator.popUntil` até a rota raiz (caminho normal, já que a Captura só é alcançável com o app já aberto no iOS) ou `pushAndRemoveUntil` como rede de segurança se não houver rota anterior.

---

## 6. Plano de ação (fases) — status em 2026-09-12

1. ✅ **Fase 0 — Infraestrutura:** `ios/` criado, app iOS registrado no Firebase "guardiaox" (aditivo, Android intocado), `firebase_options.dart`/`GoogleService-Info.plist` gerados.
2. ✅ **Fase 1 — Permissões e Info.plist:** chaves de localização/câmera/contatos/background modes adicionadas; `Runner.entitlements` criado (`aps-environment`).
3. ✅ **Fase 2 — SMS → Push exclusivo:** `EmergencyAlertService`/`SosDisparoService` com SMS desativado no iOS num ponto único (`_enviarSms`); base de Push/notificações locais (`DarwinInitializationSettings`, categorias, anexo de foto) implementada em `NotificacaoService`; `AlertasRecebidosService`/`AlertaRecebidoScreen` auditados (sem mudança necessária).
4. ✅ **Fase 3 — Alarme exato do check-in de rotina:** `android_alarm_manager_plus` substituído por lembretes locais recorrentes (`zonedSchedule`) no iOS; bug de crash real (chamadas sem try/catch) corrigido; Cloud Function `scheduledAlarmMonitor.js` (já implantada) formalizada como a garantia real de disparo no iOS.
5. ✅ **Direcionamento de produto dos 4 itens sem equivalente** (`rotina_alarme` nativo, `lockscreen`, `device_admin`, `volume_sos`) — ver seção 5 atualizada. **Pendência aberta:** decisão sobre o fallback do P4 (`SystemNavigator.pop()` no-op no iOS).
6. ✅ **Fase 5 — Compras (StoreKit) e validação de recibo no backend.** Ver seção 7 abaixo.
7. ⬜ **Fase 5 — Solicitar entitlement de Critical Alerts junto à Apple**, se o produto decidir manter o "Despertador de Emergência" com prioridade máxima no iOS (impacta o item 6 da seção anterior desta versão do relatório).
8. ⬜ **Fase 6 — Build real num Mac** (Xcode: `GoogleService-Info.plist`/`Runner.entitlements` como membros do target, capability Push Notifications, `pod install`, `Podfile` com macros do `permission_handler`) — nada disto pôde ser feito neste ambiente Windows.
9. ⬜ **Fase 7 — QA em dispositivo físico + TestFlight**, com atenção especial à revisão da App Store para permissões de localização contínua/background.

---

## 7. Fase 5 — Compras (StoreKit) e validação de recibo no backend (2026-09-12)

### O que foi implementado

- **`lib/services/premium_purchase_service.dart`:** o ramo iOS de `comprarPremium` (já existia parcialmente) agora gera um `appAccountToken` **UUID v5 determinístico** a partir do uid do Firebase (`Uuid().v5(namespace, uid)`) — achado importante: o StoreKit 2 exige um UUID de verdade nesse campo; o uid puro (string arbitrária) era **descartado silenciosamente** pela Apple, quebrando a checagem antifraude sem nenhum erro visível. `platform: 'ios'/'android'` agora vai junto na chamada a `validarCompraPremium`.
- **`functions/premiumPurchaseService.js`:** novo caminho de validação completo para iOS via **App Store Server API**, usando a biblioteca OFICIAL da Apple (`@apple/app-store-server-library`) — verifica a assinatura da transação (JWS), confere o `appAccountToken` (recalculando o MESMO UUID v5 a partir do uid autenticado) e consulta `getAllSubscriptionStatuses` para o status real e atual da assinatura (nunca confia no que veio do cliente). Fallback automático produção→sandbox (cobre TestFlight). Reverificação diária (`reverificarAssinaturasPremium`) estendida para cobrir também assinaturas iOS.
- **`functions/certs/AppleRootCA-G3.cer`:** certificado-raiz oficial da Apple (baixado de `apple.com/certificateauthority`, verificado), exigido para validar a assinatura das transações.
- **Verificação real feita:** a derivação UUID v5 (Dart `Uuid().v5(namespace, uid)` vs Node `uuidv5(uid, namespace)` — **ordem de parâmetros invertida entre as duas bibliotecas**, achado e corrigido nesta fase) foi testada de ponta a ponta com o mesmo uid de exemplo nos dois lados e produziu **exatamente o mesmo UUID** (`48834d60-bbb2-5ad5-9c1b-9ccf46c3b870`) — a única parte deste código que pude verificar de verdade sem depender de infraestrutura da Apple.

### ⚠️ Não testado contra a App Store de verdade

Diferente do restante desta migração, este código foi escrito seguindo a documentação oficial da Apple (`apple.github.io/app-store-server-library-node`) mas **nunca rodou contra uma compra Sandbox/TestFlight real** — não há Mac/Xcode/conta Apple Developer neste ambiente para isso. Testar de ponta a ponta no Sandbox da Apple antes de liberar a compra Premium para usuários iOS reais é fortemente recomendado.

### Pré-requisitos de infraestrutura (fora do alcance do código — precisam de conta Apple Developer)

1. App Store Connect → Users and Access → Integrations → In-App Purchase → gerar uma chave, anotar **Issuer ID** e **Key ID**, baixar o `.p8` (só baixa uma vez).
2. Configurar os 3 segredos da function: `firebase functions:secrets:set APPLE_ISSUER_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` (conteúdo completo do `.p8`).
3. Cadastrar o produto `assinatura_mensal` (mesmo id do Android) em App Store Connect → Monetização → Assinaturas.
4. Depois que o app existir em App Store Connect: preencher o Apple ID numérico do app em `_obterClienteEVerifierApple` (`functions/premiumPurchaseService.js`) — hoje `undefined`.

Sem os 3 segredos configurados, toda validação de compra iOS falha com erro "unavailable" (comportamento seguro — nunca concede Premium por engano; só nega até a infraestrutura estar pronta).

---

## 8. Correção final — revogação do token do Sign in with Apple (Guideline 4.8, 2026-09-12)

Achado durante a preparação do checklist final (`docs/checklist-final-mac-app-store-connect-2026-09-12.md`): a exclusão de conta apagava tudo no Firestore/Auth, mas nunca revogava o token do Sign in with Apple na própria Apple — exigência explícita da Guideline 4.8 para apps que oferecem esse login. Implementado nesta sessão:

- **`lib/services/social_auth_service.dart`:** `signInWithApple` agora registra o `authorizationCode` de cada login (fire-and-forget, nunca atrasa o login) via a nova callable `registrarAutorizacaoApple`.
- **`functions/appleSignInService.js` (novo):** troca esse código por um refresh_token junto à Apple (`/auth/token`) e o guarda em `usuarios/{uid}`; na exclusão de conta, revoga esse token (`/auth/revoke`) ANTES do documento ser apagado. Client secret JWT (ES256) gerado sob demanda via `jsonwebtoken`, seguindo a REST API oficial da Apple.
- **`functions/exclusaoContaService.js`:** chama a revogação, best-effort, antes de `excluirDadosFirestore`.
- **Verificação real feita:** a geração do JWT ES256 (header/claims `iss`/`iat`/`exp`/`aud`/`sub`) foi testada com uma chave EC descartável, confirmando que a biblioteca `jsonwebtoken` está sendo chamada corretamente. **Não testado contra a Apple de verdade** — mesma ressalva da Fase 5.
- **Pré-requisito de infraestrutura:** chave "Sign in with Apple" própria (Apple Developer → Keys) + 3 novos segredos (`APPLE_TEAM_ID`/`APPLE_SIWA_KEY_ID`/`APPLE_SIWA_PRIVATE_KEY`) — passo a passo completo no checklist final, Parte F.

Sem esses segredos configurados: login e exclusão de conta continuam funcionando normalmente (best-effort) — só a revogação em si fica pulada, sem nenhum erro visível ao usuário.

---

*Relatório gerado a partir do conteúdo de `HEAD` (commit `8ec1628`), já que os arquivos `lib/`, `functions/`, `cloud_functions/`, `windows/` e `docs/` estavam ausentes do diretório de trabalho local no momento da análise (ver aviso no início da conversa).*
