# Notas para a App Review — localização contínua (Monitoramento)

Texto para colar em **App Store Connect → versão → App Review Information →
Notes**, em inglês (a revisão é em inglês). Abaixo, a versão em português
para referência.

---

## English (paste into "Notes")

**What the feature is.** Guardian-X is a personal-safety app. In the
**Monitoring** tab, a user can share their location with trusted contacts
(family members) **only after explicitly approving each contact's request**
(or pre-authorizing that contact). The person being monitored always sees, at
the top of the Monitoring tab, *"Your location is being shared continuously
with: [names]"* and a switch to **pause** sharing at any time. Removing or
blocking a contact revokes access immediately.

**Why "Always" location is required.** Approved contacts open the map to see
where the person is right now (e.g., a teenager coming home at night, an
elderly parent). To keep that position current while Guardian-X is closed, the
app uses **region monitoring (150 m), significant-change and visits**, and,
only while the user is moving, short location bursts (max. 10 minutes each,
capped at ~2 hours per day; never in Low Power Mode or below 20% battery).
Without "Always", the position is only updated while the app is open, which
defeats the purpose of a safety feature. Background location is never used
for advertising, analytics or any purpose other than showing the position to
the contacts the user approved.

**Why Motion & Fitness is requested.** It is used only to detect when the user
starts/stops moving, so GPS is turned on only while moving (battery saving).
If denied, the feature keeps working with region monitoring + significant
change + visits.

**Consent flow.** Permissions are **never requested on first launch**. They are
requested only after the user has at least one approved contact and taps
*"Turn on continuous sharing"*, on a two-step explanatory screen:
1. explanation + "While Using" permission;
2. explanation of "Always" and Motion + an **explicit "I agree to share my
   location continuously with: [names]" checkbox** before the system prompts.

The user can pause sharing in the Monitoring tab, change permissions in
Settings, and check the status in *Settings → Permission Status →
Continuous tracking*.

**How to test (two demo accounts are provided below).**
1. On device A, sign in with **Account 1** (the monitored person).
2. On device B, sign in with **Account 2**; in the Monitoring tab add Account
   1's phone number and tap *Request location*.
3. On device A, approve the request; the Monitoring tab now shows the
   *Continuous sharing* card → tap *Turn on continuous sharing* and follow the
   two steps.
4. On device B, tap *View on map*: the app requests the current position and
   shows the time of the last update.
5. On device A, toggle the switch to pause; device B shows that the contact has
   no continuous updates.

A video showing the full flow is attached.

Demo accounts: Account 1 — `<e-mail>` / `<senha>` (phone `<+55…>`);
Account 2 — `<e-mail>` / `<senha>` (phone `<+55…>`). Both are Premium so the
feature is never paused by the free plan during the review.

---

## Português (referência)

**O que é.** Na aba **Monitoramento**, a pessoa compartilha a localização com
contatos de confiança **só depois de aprovar explicitamente cada pedido** (ou
pré-autorizar o contato). Quem é monitorado vê sempre, no topo da aba, *"Sua
localização está sendo compartilhada continuamente com: [nomes]"* e um botão
para **pausar** a qualquer momento. Remover ou bloquear o contato revoga o
acesso na hora.

**Por que "Sempre".** Quem foi aprovado abre o mapa para ver onde a pessoa
está agora. Para a posição continuar atualizada com o app fechado, o app usa
**cerca virtual (150 m), mudanças significativas e visits** e, só em
movimento, rajadas curtas de GPS (até 10 min cada, teto de ~2 h por dia;
nunca em Pouca Energia ou com bateria abaixo de 20%). Sem "Sempre", a posição
só muda com o app aberto. A localização em segundo plano não é usada para
publicidade, análise ou outra finalidade.

**Por que Movimento.** Só para saber quando a pessoa começa/para de se
mover e ligar o GPS apenas em movimento. Negado, tudo continua funcionando
com cerca + significativas + visits.

**Consentimento.** Nada é pedido no primeiro uso. As permissões só aparecem
quando já existe ao menos um contato aprovado e a pessoa toca em *Ativar
compartilhamento contínuo*, numa tela em duas etapas, com a caixa *"Concordo
em compartilhar minha localização continuamente com: [nomes]"* antes do
pedido do sistema.

## Checklist antes de enviar a versão

- [ ] Textos do `Info.plist` (Durante o uso, Sempre, Movimento) conferidos.
- [ ] Duas contas de demonstração criadas, pareadas e **Premium** (ver o
      roteiro do vídeo).
- [ ] Vídeo gravado e anexado (App Review Information → Attachment) ou link
      não listado nas notas.
- [ ] Regras/índices do Firestore publicados (sem eles o estado e o aviso de
      "localização parada" não funcionam).
- [ ] Política de privacidade (site) cita a localização contínua com
      contatos aprovados, a pausa e a retenção (só a última posição é
      guardada).
