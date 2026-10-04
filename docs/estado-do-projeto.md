# Estado do projeto Guardião-X

Atualizado em 03/10/2026.

## Organização

São **3 pastas** e **um único projeto Firebase** (`guardiaox`: mesmo Firestore,
Storage, Cloud Functions e Auth para os dois apps).

| Pasta | O que é | Regra |
|---|---|---|
| `C:\dev\guardiao-x_IOS` (GitHub `rafapedrico/guardiao-x_ios`) | App **iOS** | Este repositório. |
| `C:\dev\guardiao-x` | App **Android** publicado + site meuguardiaox.com.br | **Somente leitura.** O app Android não muda (evita nova revisão na Play Store). O site é publicado de lá (`--only hosting:publico`). |
| `C:\dev\guardiao-x_servidor` (GitHub `rafapedrico/guardiao-x_servidor`, privado) | **Servidor**: Cloud Functions, regras do Firestore/Storage, índices e painel admin | **Todo deploy de servidor sai só daqui, e só com autorização do Rafael.** |

Os `firebase.json` das pastas dos apps não têm mais functions, Firestore nem
Storage: um `firebase deploy` feito lá não consegue alterar o servidor.

## O que foi feito na sessão de 02–03/10/2026

- **TestFlight automático:** builds 104 a 107 enviados pelo GitHub Actions
  (assinatura 100% na nuvem com a chave da App Store Connect).
- **Widget SOS ("Botão de Pânico")** na tela de início e na tela bloqueada:
  target do Xcode criado por script (`ios/scripts/adicionar_target_sos_widget.rb`),
  imagem oficial, 11 idiomas, status real em Status de Permissões, passo a
  passo e FAQ.
- **Bloqueio local no lugar da "Opção A":** a sessão fica salva (logout só em
  "Sair"); o app pede Face ID/Touch ID, código do aparelho ou PIN ao abrir e
  depois de 2 min em segundo plano. Emergências (Widget SOS, câmera/tela
  vermelha, alerta recebido, alarmes) passam por cima do bloqueio — por isso o
  Widget agora sempre dispara o SOS.
- **Conta aberta em outro aparelho (só iOS):** o app detecta, avisa com
  notificação e tela, e o Widget explica por que o SOS está desativado.
- **Push no iPhone (APNs):** todos os envios do servidor levam o bloco `apns`
  (ignorado pelo Android); o app espera o token APNs antes de gravar o token
  de push e abre a tela do alerta ao tocar na notificação.
- **Secrets da Apple** criados no Firebase (ver abaixo) — destravou o deploy
  das functions.
- **Correção da revogação de sessão:** `revogarSessoesEmOutrosDispositivos`
  deslogava também o aparelho que acabava de entrar; agora corta no instante
  do login de quem chama.
- **Outros:** abas que cabem em qualquer fonte, fonte 1.0/1.15/1.3, textos do
  iOS sem SMS, aviso quando a assinatura não pode abrir, "Adicionar contato"
  rolável, remoção do "Servidor offline" e do servidor de desenvolvimento,
  `pubspec.lock` e `ios/Podfile.lock` versionados.
- **Servidor separado** em `C:\dev\guardiao-x_servidor`, com **Node 22** e
  testes no emulador — **publicado em 03/10 às 02:20** (primeiro deploy a
  partir do repositório do servidor).

### Deploys de servidor feitos

| Quando (horário de Brasília) | O quê |
|---|---|
| 02/10 23:44 | Todas as 30 functions (bloco `apns`, `appAppleId`, primeira publicação de `revogarSessoesEmOutrosDispositivos` e `registrarAutorizacaoApple`) |
| 03/10 00:12 | Só `revogarSessoesEmOutrosDispositivos` (correção) |
| 03/10 02:20 | Todas as 30 functions em **Node 22**, a partir de `guardiao-x_servidor` (com autorização) — mesmo código, só o runtime mudou |

Regras do Firestore (06/09) e do Storage (01/08) não foram republicadas.

## Decisões tomadas

- **Plano Free:** 10 dias liberados e 20 bloqueados por ciclo de 30 dias. A
  **trava de recebimento** continua: conta Free bloqueada não recebe push de
  alerta.
- **"Uma conta, um aparelho ativo"**, entre todas as plataformas: cada login
  desconecta a mesma conta nos outros aparelhos (o push só vai para o
  aparelho do último login).
- **O app Android não muda.** O servidor atende os dois apps sem exigir nada
  dele.

## Pendências (em ordem)

1. ~~Deploy do Node 22~~ — **feito em 03/10 às 02:20**, 30/30 functions em Node 22.
2. **Índice que falta no Firestore (problema antigo, desde pelo menos 20/09):**
   a function `monitorarExpiracaoMonitoramento` falha a cada 15 min porque
   não existe o índice `permissoes_monitoramento (status, expiraEm)` — as
   solicitações de localização sem resposta nunca expiram sozinhas. Correção:
   incluir o índice no `firestore.indexes.json` do servidor e publicar só os
   índices, **com autorização**.
3. **Teste de push nos dois sentidos** — Android → iPhone e iPhone → Android,
   com o app aberto, em segundo plano e fechado. Conta do Rafael no iPhone e
   conta da Michele no Android. Não usar a mesma conta nos dois aparelhos (um
   login desconecta o outro).
4. **Contas duplicadas no login com a Apple** quando a pessoa usa "Ocultar meu
   e-mail" (o Firebase trata o e-mail oculto como outra pessoa).
5. **Remetentes de e-mail na Apple:** cadastrar em Apple Developer → Sign in
   with Apple for Email Communication os domínios/endereços que enviam e-mail
   (ex.: os e-mails do Firebase Auth), se for necessário falar com quem usa o
   e-mail oculto.
6. **Assinatura Premium na App Store Connect:** aceitar o acordo de apps
   pagos e criar o produto `assinatura_mensal`.
7. **Revogar o `isPremium` de teste** das duas contas depois dos testes
   (painel admin → Planos → Revogar Premium).
8. **Commit do `firebase.json` na pasta do Android** ainda só local (sem push).
9. **Posição atual no Monitoramento (04/10):** hoje a posição do contato só é
   atualizada no aceite, com cronômetro ou com alarme ativos. Proposta (sem
   nada aplicado no servidor) em
   `docs/proposta-localizacao-sob-demanda-monitoramento.md`.

## Como gerar um build do TestFlight

- GitHub → Actions → **iOS TestFlight** → *Run workflow* (branch `main`), ou
  `gh workflow run "iOS TestFlight" --ref main`.
- Também roda num push de tag `v*` (ex.: `git tag v1.0.1 && git push origin v1.0.1`).
- O build number é automático (número da execução + 100). O build aparece no
  TestFlight depois do processamento da Apple.
- Todo push na `main` roda o **iOS Build Validation** (análise, testes e
  compilação sem assinatura), que também publica o `ios/Podfile.lock` como
  artifact.

## Onde ficam os segredos (só os nomes — nunca os valores)

- **GitHub → Settings → Secrets and variables → Actions** (repositório iOS):
  `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
  `APP_STORE_CONNECT_API_KEY`.
- **Firebase / Google Secret Manager** (projeto `guardiaox`, usados pelas
  functions): `APPLE_TEAM_ID`, `APPLE_SIWA_KEY_ID`, `APPLE_SIWA_PRIVATE_KEY`
  (Sign in with Apple), `APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`
  (validação de compra na App Store), `OPENROUTER_API_KEY` (chat de suporte).
- Nenhum desses valores fica em nenhum repositório. Para o emulador local do
  servidor usa-se `functions/.secret.local` com valores falsos (ignorado pelo
  git).
