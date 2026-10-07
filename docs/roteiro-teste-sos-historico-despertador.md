# Roteiro de teste — SOS, Histórico e Despertador (iOS)

Ramo `feat/sos-historico`. Use um iPhone com o app do TestFlight, uma conta
com pelo menos um contato de emergência (com o app instalado, para receber o
Push) e um PIN definido em Configurações.

## 1. SOS com internet

1. Aba Segurança → toque no botão SOS (não deve aparecer "Confirmar SOS?").
2. Esperado na tela preta: "Alerta acionado. Enviando sua localização…" →
   "Localização enviada com sucesso" (~2 s, nunca mais de 3 s) → "Abrindo a
   câmera" → câmera.
3. Tire a foto. A tela vermelha deve dizer "…COM A FOTO E LOCALIZAÇÃO…".
4. No aparelho do contato: Push da localização e, depois, Push da foto.
5. Histórico → "Alertas enviados" → digite o PIN → uma única entrada "SOS
   acionado pelo botão do app", status "Enviado aos contatos", com foto.
   Toque nela: data/hora, status, miniatura da foto, "Ver no mapa" abre o
   Apple Maps com a precisão em metros.
6. Repita pelo Widget SOS: mesma sequência de telas (a tela preta fica até a
   câmera abrir, com os mesmos avisos) e entrada "SOS acionado pelo widget".
7. Toque duplo rápido no botão SOS: um único alerta, uma única câmera.

## 2. SOS em modo avião

1. Ligue o modo avião e toque em SOS.
2. Esperado: "Alerta acionado…" por ~8 s → "Sem conexão. Seu alerta será
   enviado automaticamente assim que houver sinal" (2 s) → "Abrindo a câmera".
3. Tire a foto. Tela vermelha: "ATENÇÃO, SEU ALERTA SERÁ ENVIADO AOS
   FAMILIARES ASSIM QUE HOUVER CONEXÃO."
4. Histórico: entrada com status "Pendente — será enviado assim que houver
   conexão" e a foto local visível na miniatura.
5. Desligue o modo avião com o app aberto: o contato recebe a localização; a
   entrada passa a "Enviado aos contatos"; a foto sai pela fila de retry
   (pode levar até a próxima abertura do app) e entra na MESMA entrada.

## 3. SOS sem permissão de câmera

1. Ajustes → Guardião-X → Câmera: desligada. Toque em SOS.
2. Esperado: localização enviada; "Câmera indisponível — alerta já enviado aos
   seus contatos"; tela vermelha "…COM SUA LOCALIZAÇÃO…" (sem foto).
3. Histórico: entrada "Enviado aos contatos", sem foto.
4. Sem sessão (app recém-instalado, sem login): o toque abre a tela "Ative o
   Botão SOS".

## 4. Histórico após reinstalar o app

1. Faça 1–2 SOS (seção 1). Apague o app e instale de novo pelo TestFlight.
2. Entre na mesma conta. Histórico → "Alertas enviados" → PIN.
3. Esperado: os SOS voltam (status "Enviado", com localização e o link da foto
   — a cópia local não volta, a miniatura carrega pelo link).
4. Alertas disparados pelo servidor com o app fechado (cronômetro/despertador)
   só aparecem depois que o servidor passar a gravar
   `usuarios/{uid}/historico_alertas` e a regra de leitura for publicada.

## 5. PIN errado 3 vezes (área protegida)

1. Histórico → "Alertas enviados" → digite um PIN errado 3 vezes.
2. Esperado: "Muitas tentativas incorretas. Tente novamente em 5:00" com
   contagem; o teclado não aceita dígitos.
3. Fechar e reabrir o app não zera o bloqueio. Depois do tempo, 3 novos erros
   bloqueiam por 10 minutos. O PIN certo zera tudo.
4. Liberação: com a área aberta, vá para outra aba e volte → pede o PIN.
   Deixe o app em segundo plano por mais de 2 minutos → pede o PIN.
5. Apagar uma entrada (arrastar) ou "Limpar Histórico" pede o PIN de novo.
6. O PIN de antes da atualização continua valendo (migração para hash).

## 6. Cronômetro

1. Ative o cronômetro → entrada "Cronômetro ativado" (área protegida, com
   localização). Desarme com o PIN certo → "Cronômetro desarmado com o PIN
   correto".
2. PIN errado 3 vezes no desarme → alerta aos contatos + entrada "Alerta: PIN
   incorreto 3 vezes no cronômetro" com status real.

## 7. Despertador (aba Família)

Sem contato de emergência: o "+" fica cinza e leva a Configurações.

### iOS 26 ou mais novo (AlarmKit)
1. Crie um despertador para daqui a 3 min, tolerância 2 min. Autorize os
   alarmes quando o iOS pedir.
2. Com o app fechado e o iPhone no silencioso: no horário, o alarme do
   sistema toca com o som escolhido em Configurações.
3. "Parar" só para o som — sem PIN, ao fim da tolerância o servidor alerta.
4. Repita e toque em "Desativar despertador": o app abre na tela do
   despertador com o teclado. PIN certo → notificação "Despertador
   desativado (pausado)", volta ao app. Firestore:
   `alarmes_agendados/{uid}_{id}` com `CONFIRMADO_SEGURA` e o `cicloEpochMs`
   da ocorrência; nenhum alerta chega ao contato.

### iOS anterior
1. Mesmo cenário: no horário chega a notificação com o som escolhido e se
   repete a cada ~30 s até o fim da tolerância; "Desativar despertador" abre
   a tela com o teclado; PIN certo cancela as repetições.

### Comum
1. App aberto no horário: a tela do despertador abre sozinha e toca em loop.
2. 3 PINs errados: o teclado fecha na hora, o alerta sai, notificação "Um
   alerta de emergência foi enviado aos seus contatos cadastrados."; doc com
   `ALERTA_DISPARADO` e `eventoId`; o servidor NÃO manda um segundo alerta.
3. Sem PIN até o fim da tolerância com o app aberto: o app envia o alerta na
   hora (sem janela extra).
4. Pausar (botão ou arrastar) pede o PIN; doc `PAUSADO` com `pausadoAte` =
   00:00 de amanhã; hoje não toca; "Retorna" mostra a próxima ocorrência real.
   Reativar pede o PIN. 3 erros ao pausar/apagar → alerta "Tentativa de
   apagar/pausar o despertador com senha incorreta" + notificação.
5. Até 2 h antes do horário com o app aberto, `ultimaLocalizacao` do doc é
   atualizada a cada ~60 s até o fim da tolerância; fora da janela, não.
6. Histórico protegido: confirmação, alertas por PIN errado e por tempo
   esgotado, com status e localização.

## 8. Alinhamento com o Android (conferir no Firestore)

1. SOS: `usuarios/{uid}/alertas/{alertaId}` com `tipo: sos_fisico`,
   `alertaId` e `contextoPersonalizado`; foto em `{alertaId}_foto`.
2. Com GPS impreciso no toque, a posição precisa chega em
   `alertas/{alertaId}/atualizacoes_localizacao/{auto}`; o alerta original
   não muda. (Precisa da regra de criação nessa subcoleção no servidor.)
3. Cronômetro: `cronometro_expirado` (tempo) ou `tentativa_desarme_incorreto`
   (3 PINs), com o texto do cronômetro em `contextoPersonalizado`.
4. Despertador: `despertador_expirado` por tempo ou por 3 PINs (o `motivo`
   diz qual), com o texto do despertador; tentativa de apagar/pausar com PIN
   errado: `tentativa_desarme_incorreto`.
5. `alarmes_agendados/{uid}_{id}` sempre com `cicloEpochMs` e `pausadoAte`
   (nulo sem pausa). Pausar por hoje: o doc passa para a próxima ocorrência,
   PENDENTE, com `pausadoAte` = 00h00 de amanhã.
6. Trocar o som em Configurações grava `usuarios/{uid}.somAlerta = "som_N"`.
7. Termos e Privacidade: seção 8, retenção de 30 dias.

## 9. Alinhamento final (localização, foto, avisos de entrega)

1. Cronômetro ou despertador ativo: a posição aparece só em
   `usuarios/{uid}/monitoramento/atual` — nada novo em `usuarios/{uid}`
   (latitude/longitude) nem em `alarmes_agendados/...ultimaLocalizacao`.
   Parado, uma gravação a cada ~5 min; andando, a cada 30 m ou mais.
2. Rastreamento contínuo: mesmos intervalos de antes, também só em
   `monitoramento/atual`.
3. Foto do SOS no Storage: lado maior ≤ 1600 px, JPEG, em pé (sem girar);
   a miniatura do Histórico e a foto da fila de reenvio são a reduzida.
4. Depois de um SOS, os avisos do servidor ("{nome} ainda não recebeu…",
   "{nome} recebeu seu alerta.", "Não foi possível entregar…") chegam como
   notificação; no detalhe do alerta, "Entrega aos contatos" mostra cada
   contato com Entregue / Tentando / Não entregue e o texto do aviso.

## 10. Fim do cronômetro no iOS, sons .caf e proteção do banco

1. Sem PIN cadastrado, o cronômetro não começa ("Cadastre um PIN").
2. Cronômetro de 1 min; bloqueie o iPhone. No fim: notificação "Cronômetro
   de segurança" com o som escolhido em Configurações, repetida a cada ~15 s
   durante os 60 s de tolerância, com a ação "Desligar alerta de emergência"
   → abre o app direto no teclado do PIN.
3. App aberto no fim: a tela abre sozinha e o som toca em loop até o PIN ou
   o fim dos 60 s.
4. PIN correto: notificação "Senha correta. O alerta de emergência não foi
   enviado.", doc `alarmes_agendados/{uid}_checkin_seguranca` em
   CONFIRMADO_SEGURA, nenhum alerta ao contato, Histórico "Cronômetro
   desarmado".
5. 3 PINs errados: o teclado fecha, alerta `tentativa_desarme_incorreto` e
   notificação "Houve 3 tentativas…".
6. Sem PIN até o fim (app em segundo plano): o próprio app envia
   `cronometro_expirado` (id `cronometro_{fim}`) e mostra a notificação; doc
   em ALERTA_DISPARADO; o servidor não manda um segundo.
7. Durante a tolerância, tentar iniciar outro cronômetro mostra "O
   cronômetro anterior ainda está na tolerância…".
8. Do início até o fim da tolerância, com o app em segundo plano, a posição
   em `monitoramento/atual` é atualizada (indicador azul de localização),
   no máximo 1x/min e só com 30 m de deslocamento ou a cada 5 min parado.
9. Sons: no despertador (AlarmKit e notificações) e no cronômetro, o som é o
   `som_N.caf` escolhido; um Push de alerta recebido toca o `som_N.caf` do
   destinatário (enviado pelo servidor). O som 10 ("Sirene") é o mesmo
   sirene do Android (16 s) — nenhum som é mudo.
10. Com o iPhone bloqueado, um alerta recebido e um aviso de entrega entram
    no Histórico (banco com proteção até o primeiro desbloqueio).
