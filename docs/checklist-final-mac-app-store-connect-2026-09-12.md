# Checklist Final — Mac / App Store Connect / Encerramento da Migração iOS

**Data:** 2026-09-12
**Complementa:** `docs/migracao-ios-relatorio-2026-09-12.md` (relatório técnico completo — leia-o primeiro se ainda não leu)
**Para quem é este documento:** tudo aqui é trabalho que **precisa de um Mac com Xcode e/ou acesso ao App Store Connect/Apple Developer** — nada disto pôde ser feito neste ambiente Windows. Siga na ordem; cada parte indica claramente se é "uma vez só" ou "toda vez que compilar".

Todo o código-fonte referenciado já está pronto em `dev/guardiao-x_ios` (nada precisa ser escrito do zero — só configurado/executado).

---

## 0. Antes de começar — reúna estes acessos

| # | O que | Onde conseguir | Anote aqui |
|---|---|---|---|
| 1 | Conta Apple Developer Program ativa (paga, US$99/ano) | [developer.apple.com/account](https://developer.apple.com/account) | Team ID: `_______` |
| 2 | Acesso a App Store Connect com papel **Admin** ou **App Manager** | [appstoreconnect.apple.com](https://appstoreconnect.apple.com) | — |
| 3 | Um Mac com Xcode instalado (versão recente, compatível com Flutter atual) | — | — |
| 4 | O repositório `guardiao-x_ios` clonado no Mac, na branch correta | `git clone https://github.com/rafapedrico/guardiao-x_ios.git` | — |

Sem o item 1 (conta paga), nada abaixo funciona — nem build num device físico, nem TestFlight, nem submissão.

---

## Parte A — Primeiro build no Mac (uma vez, e depois a cada `flutter pub get`)

- [ ] **A1.** No Mac, dentro de `guardiao-x_ios/`: `flutter pub get` (baixa as dependências, incluindo as novas `timezone` e `uuid` adicionadas nesta migração).
- [ ] **A2.** `cd ios && pod install` — gera o `ios/Podfile.lock` e `ios/Pods/` pela primeira vez (o `Podfile` em si só é criado automaticamente pelo Flutter na primeira vez que você abre/builda o projeto iOS — se `ios/Podfile` ainda não existir quando chegar aqui, rode `flutter build ios --no-codesign` uma vez antes, só para o Flutter gerá-lo).
- [ ] **A3.** Edite `ios/Podfile` e adicione o bloco abaixo (habilita só as permissões que o app realmente usa no iOS — câmera, localização, contatos; todas as outras ficam desabilitadas de propósito, mesmo espírito de superfície mínima já usado no resto do projeto):

  ```ruby
  post_install do |installer|
    installer.pods_project.targets.each do |target|
      flutter_additional_ios_build_settings(target)
      target.build_configurations.each do |config|
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']
        config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] += [
          'PERMISSION_CAMERA=1',
          'PERMISSION_LOCATION=1',
          'PERMISSION_CONTACTS=1',
          'PERMISSION_NOTIFICATIONS=1',
          # Todas as demais permissões do permission_handler, desativadas
          # de propósito (o app não usa nenhuma delas no iOS):
          'PERMISSION_EVENTS=0',
          'PERMISSION_EVENTS_FULL_ACCESS=0',
          'PERMISSION_REMINDERS=0',
          'PERMISSION_MICROPHONE=0',
          'PERMISSION_SPEECH_RECOGNIZER=0',
          'PERMISSION_PHOTOS=0',
          'PERMISSION_MEDIA_LIBRARY=0',
          'PERMISSION_SENSORS=0',
          'PERMISSION_BLUETOOTH=0',
          'PERMISSION_APP_TRACKING_TRANSPARENCY=0',
          'PERMISSION_ASSISTANT=0',
          # Deixe em 0 até (e SE) o entitlement de Critical Alerts for
          # aprovado pela Apple (ver Parte D) — sem o entitlement
          # aprovado, habilitar este macro sem o direito real de usá-lo
          # pode causar rejeição na revisão da App Store.
          'PERMISSION_CRITICAL_ALERTS=0',
        ]
      end
    end
  end
  ```

  Rode `pod install` de novo depois de editar.
- [ ] **A4.** Abra **`ios/Runner.xcworkspace`** no Xcode — **nunca** o `.xcodeproj` diretamente (o workspace inclui os Pods).
- [ ] **A5.** Selecione o projeto "Runner" → target "Runner" → aba **Signing & Capabilities**:
  - Marque seu **Team** (a conta Apple Developer do item 0.1).
  - Confirme o **Bundle Identifier**: precisa ser exatamente `com.rmfglobal.guardiaox` (já configurado no `project.pbxproj` pela migração — só confira que o Xcode não alterou nada).
- [ ] **A6.** Arraste estes dois arquivos (já existem em `ios/Runner/`, gerados nesta migração) para dentro do grupo "Runner" no navegador do Xcode, marcando **"Copy items if needed"** e **"Add to targets: Runner"**:
  - `GoogleService-Info.plist`
  - `Runner.entitlements`
- [ ] **A7.** Ainda em Signing & Capabilities, clique em **"+ Capability"** e adicione:
  - **Push Notifications** (isso liga de vez o `Runner.entitlements` ao build — sem este passo, o arquivo existe no disco mas não é usado).
  - **Sign in with Apple** (o app já usa o pacote `sign_in_with_apple`, mas a capability precisa ser habilitada aqui também).
  - **Background Modes** → marque **Location updates**, **Remote notifications** e **Audio, AirPlay, and Picture in Picture** (já declarados em `Info.plist`, mas confirme que aparecem marcados aqui também).
- [ ] **A8.** `flutter_launcher_icons`: no `pubspec.yaml`, mude `ios: false` para `ios: true` (bloco `flutter_launcher_icons:`, perto do fim do arquivo) e rode `dart run flutter_launcher_icons` — gera o ícone do app pro iOS a partir do mesmo `assets/images/app_icon.png` já usado no Android.
- [ ] **A9.** Rode `flutter run` (com um device/simulador iOS selecionado) e confirme que o app abre sem crashar até a tela de Login.

---

## Parte B — Firebase / Push (APNs)

- [ ] **B1.** [Apple Developer Portal](https://developer.apple.com/account/resources/authkeys/list) → Certificates, Identifiers & Profiles → **Keys** → "+" → marque **Apple Push Notifications service (APNs)** → Continue → Register.
- [ ] **B2.** Baixe o arquivo `.p8` gerado **imediatamente** (só é possível baixar uma vez) e anote o **Key ID** exibido na tela.
- [ ] **B3.** No [Firebase Console](https://console.firebase.google.com/project/guardiaox/settings/cloudmessaging) → Configurações do projeto → **Cloud Messaging** → seção "Configuração de apps Apple" (deve mostrar o app iOS `com.rmfglobal.guardiaox` já registrado, ver Fase 0 desta migração) → **Fazer upload** da chave APNs: envie o `.p8`, o **Key ID** (passo anterior) e o **Team ID** (item 0.1).
- [ ] **B4.** Teste: com o app rodando num device físico real (Push não funciona em simulador), peça pra outro usuário disparar um alerta que te tenha como contato de emergência — confirme que a notificação chega com foto/localização (fluxo implementado na Fase 2 desta migração).

---

## Parte C — Compras (StoreKit / App Store Connect) — Fase 5 desta migração

### C.1 — Criar o app em App Store Connect (se ainda não existir)

- [ ] App Store Connect → Apps → "+" → New App → Bundle ID `com.rmfglobal.guardiaox`, nome, idioma principal.
- [ ] Confirme o acordo "Paid Applications Agreement" assinado em **Business** (obrigatório para vender qualquer assinatura, mesmo num app gratuito com IAP).

### C.2 — Cadastrar o produto de assinatura

- [ ] App Store Connect → seu app → **Monetização → Assinaturas** → criar um **Grupo de Assinaturas** (ex: "Guardião-X Premium").
- [ ] Dentro do grupo, criar a assinatura com o **Product ID exatamente `assinatura_mensal`** — precisa bater EXATAMENTE com `PRODUTO_PREMIUM_ID` em `functions/premiumPurchaseService.js` e `PremiumPurchaseService.idProdutoPremium` no Flutter. Preencha preço, duração (mensal), nome/descrição localizados, e envie a "Review Screenshot" exigida pela Apple para o produto (print de qualquer tela do app mostrando a oferta).

### C.3 — Gerar a chave da App Store Server API (usada pela validação no backend)

- [ ] App Store Connect → **Users and Access → Integrations → In-App Purchase** → gerar uma chave.
- [ ] Anote o **Issuer ID** (fica visível no topo da página) e o **Key ID** da chave gerada.
- [ ] Baixe o `.p8` **imediatamente** (só é possível baixar uma vez).

### C.4 — Configurar os segredos da Cloud Function

No Mac (ou qualquer máquina com `firebase-tools` logado no projeto `guardiaox`), dentro de `guardiao-x_ios/functions/`:

```bash
firebase functions:secrets:set APPLE_ISSUER_ID
# cole o Issuer ID do passo C.3 quando pedido

firebase functions:secrets:set APPLE_KEY_ID
# cole o Key ID do passo C.3

firebase functions:secrets:set APPLE_PRIVATE_KEY
# cole o CONTEÚDO COMPLETO do arquivo .p8 baixado (abra num editor de texto e
# copie tudo, incluindo as linhas -----BEGIN PRIVATE KEY----- / -----END PRIVATE KEY-----)
```

- [ ] Depois que o app existir de verdade em App Store Connect (passo C.1), pegue o **Apple ID numérico do app** (App Store Connect → seu app → App Information → "Apple ID") e preencha no lugar do `undefined` em `functions/premiumPurchaseService.js`, função `_obterClienteEVerifierApple` (parâmetro `appAppleId` do `SignedDataVerifier`) — opcional mas recomendado, reforça a validação.
- [ ] Deploy: `firebase deploy --only functions:validarCompraPremium,functions:reconciliarCompraPremiumAdmin,functions:reverificarAssinaturasPremium`.

### C.5 — Testar no Sandbox da Apple **antes de liberar para usuários reais**

- [ ] App Store Connect → Users and Access → **Sandbox → Testers** → criar uma conta de teste (e-mail que não precisa ser real, mas precisa ser único e nunca usado num Apple ID de verdade).
- [ ] No device de teste: Ajustes → App Store → role até "Conta Sandbox" → entre com a conta de teste (iOS 17+; em versões antigas, o login sandbox acontece direto na hora da compra).
- [ ] No app, dispare uma compra Premium de verdade (ambiente sandbox não cobra nada) e acompanhe os logs da function: `firebase functions:log --only validarCompraPremium`.
- [ ] Confirme em `usuarios/{uid}` no Firestore que `isPremium` virou `true` e `premiumPlataforma: "ios"` foi gravado.
- [ ] **Este teste é o único jeito de saber se a implementação da Fase 5 (nunca testada contra a Apple de verdade neste ambiente) está correta.** Se falhar, os logs da function (`firebase functions:log`) mostram exatamente onde (verificação de assinatura, antifraude, ou consulta de status).

---

## Parte D — Critical Alerts (opcional — só se o produto decidir manter o "Despertador de Emergência" com prioridade máxima no iOS)

- [ ] Preencha o formulário oficial: [developer.apple.com/contact/request/notifications-critical-alerts-entitlement](https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/) — explique o caso de uso (app de segurança pessoal, alerta de emergência recebido de contatos de confiança precisa furar o modo Silencioso/Foco). Aprovação não é automática nem imediata (pode levar dias/semanas).
- [ ] Se aprovado: em `ios/Runner/Runner.entitlements`, adicionar a chave `com.apple.developer.usernotifications.critical-alerts` = `true`; no `Podfile` (Parte A3), trocar `PERMISSION_CRITICAL_ALERTS=0` para `=1`; em `lib/services/notificacao_service.dart`, trocar `InterruptionLevel.timeSensitive` para `InterruptionLevel.critical` nas notificações de alarme/alerta recebido (pontos já identificados e comentados no código da Fase 2/3 desta migração).
- [ ] Se **não** for solicitado agora: nenhuma ação — o app já funciona corretamente com `.timeSensitive` (furou o Silencioso normal, não o "Não perturbe"/Foco).

---

## Parte E — Checklist de QA funcional (device físico, antes do TestFlight)

Teste cada item — todos foram implementados/adaptados nesta migração, nenhum foi testado num iPhone real ainda:

- [ ] Login e-mail/senha, Google, Apple.
- [ ] Cadastro de contato de emergência.
- [ ] Botão manual de SOS (aba Segurança) → confirma que dispara Push (não SMS) para os contatos.
- [ ] Fluxo completo de câmera de dissuasão (P2) → foto anexada ao Push recebido pelo contato.
- [ ] Gesto "deslizar para cima" na tela de dissuasão (P4) → confirma que volta para a Home/aba Segurança (ajuste desta migração — `SystemNavigator.pop()` não existe no iOS).
- [ ] Alarme de rotina: cadastrar um alarme para ~2 minutos no futuro, fechar o app completamente (matar do multitarefas), aguardar a notificação local chegar, tocar nela → confirma que abre direto na tela de confirmação, sem precisar logar de novo (ajuste desta migração).
- [ ] Ação "Pausar" na notificação de alarme completo (se aplicável ao seu teste).
- [ ] Recebimento de um Push de alerta de emergência de outro usuário (com foto) — abre `AlertaRecebidoScreen`, foto/localização aparecem.
- [ ] Aba Monitoramento: solicitar/aceitar/recusar localização em tempo real.
- [ ] Configurações → confirme que **não aparecem** mais os cards de "Device Admin"/"Isenção de bateria" (ajuste desta migração).
- [ ] Onboarding de um usuário novo → confirme que **não aparece** nenhum diálogo pedindo permissão de SMS (ajuste desta migração).
- [ ] Compra do Plano Premium (ver Parte C.5, ambiente Sandbox).
- [ ] Exclusão de conta (`excluir_conta_screen.dart`) — ver pendência na Parte F abaixo antes de liberar publicamente.

---

## Parte F — Antes de submeter para revisão da App Store

- [x] **✅ Revogação do token do Sign in with Apple na exclusão de conta (Guideline 4.8) — implementada em 2026-09-12.** `SocialAuthService.signInWithApple` (Flutter) registra o `authorizationCode` de cada login via a nova callable `registrarAutorizacaoApple`; `functions/appleSignInService.js` (novo arquivo) troca esse código por um refresh_token e o guarda em `usuarios/{uid}`; `exclusaoContaService.js` revoga esse token na Apple (`revogarAppleTokenSeExistir`) ANTES de apagar o documento. **Falta só a parte manual, abaixo:**
  - [ ] Apple Developer → Certificates, Identifiers & Profiles → **Keys** → "+" → marcar **"Sign in with Apple"** (chave DIFERENTE da de APNs — Parte B — e da de In-App Purchase — Parte C.3) → baixar o `.p8`, anotar o **Key ID**.
  - [ ] Anotar o **Team ID** (Apple Developer → Membership — 10 caracteres, NÃO é o "Issuer ID" da Parte C.3, são identificadores diferentes).
  - [ ] Configurar os 3 segredos (mesmo terminal/Mac das Partes C.4):
    ```bash
    firebase functions:secrets:set APPLE_TEAM_ID
    firebase functions:secrets:set APPLE_SIWA_KEY_ID
    firebase functions:secrets:set APPLE_SIWA_PRIVATE_KEY
    # cole o conteúdo completo do .p8 desta chave (BEGIN/END PRIVATE KEY incluídos)
    ```
  - [ ] Deploy: `firebase deploy --only functions:registrarAutorizacaoApple,functions:excluirContaCompleta`.
  - [ ] Testar: logar com Apple, excluir a conta, e conferir nos logs (`firebase functions:log --only excluirContaCompleta`) a linha `[AppleSignIn] Token da Apple revogado com sucesso`. **Também não testado contra a Apple de verdade neste ambiente** — mesma ressalva da Fase 5 (compras).
  - [ ] Sem os 3 segredos configurados: o app funciona normalmente (login e exclusão de conta continuam funcionando, best-effort) — só a revogação em si fica pulada, sem nenhum erro visível ao usuário.
- [ ] **App Privacy** (App Store Connect → seu app → App Privacy): declarar TODOS os dados coletados — localização (usada e não vinculada/vinculada ao usuário — este app vincula, já que rastreia quem é o usuário), contatos, fotos, identificadores.
- [ ] **Classificação etária** (Age Rating) preenchida.
- [ ] **Notas para o revisor:** como o app exige login obrigatório a cada cold start ("Opção A", ver `FirebaseAuthService`), inclua uma conta de demonstração (e-mail/senha) nas notas de revisão — sem isso, o revisor da Apple não consegue nem abrir o app além da tela de Login.
- [ ] **Justificativa de localização em segundo plano:** a Apple pede, na maioria dos casos, uma explicação por escrito (e às vezes um vídeo) do uso legítimo de `NSLocationAlwaysAndWhenInUseUsageDescription` — prepare um texto curto explicando o cronômetro de check-in de segurança.
- [ ] **Screenshots** nos tamanhos obrigatórios (6.9", 6.5" no mínimo — verificar os tamanhos exigidos no momento da submissão, a Apple às vezes muda).
- [ ] **`faqResposta13`** (texto sobre o botão de Volume+): só a versão em português foi corrigida nesta migração (ver relatório principal, seção "Rodada de mitigação"). Os outros 10 idiomas continuam com o texto antigo — combinado explicitamente que a tradução completa fica para o fim do projeto; não esquecer antes do lançamento público em mercados não-lusófonos.

---

## Resumo — todas as credenciais que você vai precisar reunir

| Credencial | Onde é usada | Gerada em |
|---|---|---|
| Apple Team ID | Xcode Signing | developer.apple.com/account |
| Chave APNs (.p8) + Key ID | Firebase Console (Cloud Messaging) | Apple Developer → Keys |
| Chave da App Store Server API (.p8) + Issuer ID + Key ID | Segredos da Cloud Function (`APPLE_ISSUER_ID`/`APPLE_KEY_ID`/`APPLE_PRIVATE_KEY`) | App Store Connect → Integrations → In-App Purchase |
| Apple ID numérico do app | `functions/premiumPurchaseService.js` (`appAppleId`) | App Store Connect → App Information (só existe depois de criar o app) |
| Conta Sandbox Tester | Teste de compra (Parte C.5) | App Store Connect → Sandbox → Testers |
| Chave "Sign in with Apple" (.p8) + Key ID + Team ID | Segredos da Cloud Function (`APPLE_TEAM_ID`/`APPLE_SIWA_KEY_ID`/`APPLE_SIWA_PRIVATE_KEY`) | Apple Developer → Keys (Parte F) — revogação de token na exclusão de conta |

---

## O que fica fora deste checklist (por decisão de produto, não por falta de tempo)

- **`volume_sos`** (gatilho físico de Volume+ em segundo plano): sem substituto no iOS. Botão de Ação (iPhone 15+)/App Intents ficou anotado como possibilidade futura, não implementado.
- **`device_admin`**/**`lockscreen`**: sem substituto possível — Apple não permite em nenhuma circunstância.
- Tradução completa do FAQ (`faqResposta13`) para os 10 idiomas restantes.

---

*Isolamento mantido durante toda a preparação deste checklist: nenhum comando rodou fora de `dev/guardiao-x_ios`; nenhum arquivo em `dev/guardiao-x` ou `dev/guardiao-x - Copia` foi tocado.*
