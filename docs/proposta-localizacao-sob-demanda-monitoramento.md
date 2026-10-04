# Proposta: posição atual do contato ao abrir o mapa (Monitoramento)

Data: 04/10/2026 · Status: **proposta — nada aplicado no servidor**
(qualquer deploy só com autorização, a partir de `C:\dev\guardiao-x_servidor`).

## Problema

`usuarios/{uidAlvo}/monitoramento/atual` só é regravado pelo aparelho do
contato quando ele aceita uma solicitação / liga o compartilhamento, ou
enquanto está com o cronômetro da Segurança ou um alarme de rotina ativo
(`LocationService`). Fora disso, "Ver no mapa" mostra uma posição que pode
ter horas. O build 110 já mostra no card e antes de abrir o mapa a idade da
posição, com aviso acima de 15 min — mas não traz uma posição nova.

## Proposta: pedido de localização por push de dados

1. **App de quem vê** (ao tocar em "Ver no mapa"): chama uma callable nova
   `pedirLocalizacaoAtual({uidAlvo})` e mostra "Pedindo a posição atual…"
   por até ~20 s, ouvindo `monitoramento/atual` em tempo real
   (`snapshots()`). Chegou posição com `atualizadoEm` mais novo → abre o
   mapa nela. Não chegou → oferece abrir a última conhecida, com o horário.
2. **Callable `pedirLocalizacaoAtual`** (servidor, função nova — não mexe nas
   existentes):
   - exige `permissoes_monitoramento/{uidAlvo}__{uidSolicitante}` com
     `status == 'aprovado'` e `bloqueado != true`;
   - limite de frequência por par (ex.: 1 pedido a cada 60 s) para não
     drenar a bateria do contato;
   - envia ao token FCM do alvo uma mensagem **só de dados**
     (`tipo: 'pedido_localizacao'`, `idPedido`), com
     `apns-push-type: background`, `apns-priority: 5` e
     `content-available: 1` no iOS; prioridade alta no Android.
3. **App do contato** (handler de background do FCM, que já existe em
   `fcm_service.dart`): ao receber `pedido_localizacao`, lê o GPS uma vez
   (precisão alta, limite ~10 s; sem fix, a última conhecida) e grava com
   `FirebaseSyncService.atualizarLocalizacaoAtual` (mesma regra do Firestore
   de hoje: só o dono grava o próprio documento — nada muda nas regras).

## Limitações do iOS (importante)

- Push silencioso (`content-available`) é **best-effort**: o iOS limita a
  frequência, atrasa ou descarta conforme bateria, Modo de Pouca Energia e
  uso do app; **não acorda o app se o usuário o encerrou** deslizando no
  seletor de apps. Não dá para garantir resposta.
- Ler o GPS a partir de um push em segundo plano exige a permissão de
  localização **"Sempre"**; com "Durante o uso", o app acordado em segundo
  plano não recebe a posição. O app já declara `UIBackgroundModes: location`
  e `NSLocationAlwaysAndWhenInUseUsageDescription`.
- Alternativa mais confiável no iOS (complementar, sem servidor): enquanto
  houver alguém com permissão "aprovado" para ver a posição, usar o
  **monitoramento de mudanças significativas** (`startMonitoringSignificantLocationChanges`)
  — o iOS acorda o app (mesmo encerrado) a cada ~500 m de deslocamento, e o
  app grava a posição. Custo baixo de bateria; exige "Sempre"; precisa de
  texto claro para o usuário e para a revisão da Apple.
- No Android, a mensagem de dados de alta prioridade acorda o app de forma
  confiável (salvo restrições agressivas de alguns fabricantes); como o app
  Android não muda nesta fase, o pedido só seria respondido por aparelhos
  iOS até o Android ganhar o mesmo handler.

## Recomendação

Fazer 1+2+3 (pedido por push de dados, com limite de frequência e fallback
para a última posição com horário) e, numa segunda etapa, o monitoramento de
mudanças significativas no iOS para quem tiver "Sempre" e compartilhamento
ativo. O servidor ganha só uma callable nova; nenhuma regra muda.
