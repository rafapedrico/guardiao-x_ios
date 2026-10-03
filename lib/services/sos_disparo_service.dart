import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show XFile;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emergency_alert_service.dart';
import 'firebase_auth_service.dart';
import 'firebase_sync_service.dart';
import 'retry_upload_service.dart';
import 'sos_dispatch_native_service.dart';

/// Serviço ÚNICO e UNIFICADO de disparo do SOS — reúne, num só lugar, a
/// sequência estritamente sequencial exigida para o botão físico
/// (Volume+ segurado por 3s, tanto com o app frio/bloqueado quanto já
/// rodando) E o botão de SOS manual da aba Segurança:
///
///   P1 (PRIORIDADE MÁXIMA) — captura localização + timestamp e despacha
///       IMEDIATAMENTE, em PARALELO, por DOIS canais oficiais e
///       independentes:
///         1. SMS nativo direto do aparelho (`SmsManager`, sem custo,
///            nunca depende de conta/nuvem) — ver
///            [EmergencyAlertService.dispararSosComDuplaLocalizacao].
///         2. App-para-App (Push FCM), via `dispararAlertaHibrido` no
///            backend.
///       O canal 2 só dispara quando há sessão do Firebase Auth
///       disponível (desde 2026-10-03 a sessão fica persistida — ver
///       `FirebaseAuthService` —, então isso só falta se ninguém nunca
///       entrou no aparelho). Nesse caso, o canal 1 (SMS) é o ÚNICO que
///       dispara — decisão
///       explícita do produto: a entrega de P1 NUNCA pode depender de
///       autenticação na nuvem.
///   P2 — abre a câmera (UI, ver `CapturaDissuasaoService`) e, assim que
///       a foto for tirada, [dispararFotoCapturada] despacha os MESMOS
///       dois canais em paralelo: SMS com o link da foto + localização
///       ([EmergencyAlertService.enviarSmsComLinkDaFoto]) e Push com o
///       link da foto já enviada ao Firebase Storage. Sem sessão (ou se
///       o upload ao Storage falhar por qualquer motivo), o canal 2 fica
///       indisponível e o SMS de fallback
///       ([EmergencyAlertService.enviarSmsResgateFoto], sem link real)
///       é usado no lugar.
///   P3/P4 — tela vermelha travada + bloqueio nativo de tela ao deslizar
///       para cima — implementados em `CameraCapturaScreen`, fora deste
///       serviço (são puramente locais, sem dependência de rede/nuvem).
///
/// **MIGRAÇÃO iOS (decisão de produto, 2026-09-12):** a descrição acima
/// (SMS + Push em paralelo) continua valendo INTEGRALMENTE para o
/// Android. No iOS, o canal 1 (SMS) NUNCA dispara — a Apple não
/// oferece nenhuma API pública de envio de SMS — e essa remoção é
/// tratada num ponto único, dentro de
/// [EmergencyAlertService._enviarSms] (ver a nota de migração no topo
/// daquele arquivo), então nenhuma chamada deste serviço a
/// [EmergencyAlertService] precisou mudar de assinatura. Na prática,
/// no iOS:
///   - P1: só o canal 2 (Push, via [_dispararLocalizacaoViaNuvem])
///     realmente envia algo. Sem sessão do Firebase Auth ativa, P1 não
///     envia NADA no iOS — aceito conscientemente pelo produto, já que
///     o cenário "botão físico com o app frio/tela bloqueada" que
///     justificava o SMS como canal de garantia no Android também não
///     existe no iOS por outro motivo: a Apple não permite escutar o
///     botão de volume em segundo plano nem abrir o app por cima da
///     tela de bloqueio (sem equivalente de
///     `VolumeSosService`/`LockscreenCameraActivity`).
///   - P2: idem — só o canal 2 (Push com o link real da foto) envia
///     algo; o fallback [_dispararFotoViaSmsFallback] (chamado só
///     quando NÃO há sessão) também não envia nada no iOS.
/// Nenhuma lógica de deduplicação/Foreground Service abaixo precisou
/// mudar — ambas continuam idênticas nas duas plataformas.
///
/// DEDUPLICAÇÃO ENTRE OS DOIS ENGINES NATIVOS DO BOTÃO FÍSICO: um único
/// aperto físico de Volume+ pode disparar SIMULTANEAMENTE dois
/// `FlutterEngine`/`main()` diferentes no lado nativo Android (ver
/// `VolumeSosService.kt` — o Foreground Service sempre chama
/// `VolumeSosEventBridge.notificarSosDisparado()` E
/// `forcarAberturaLockscreenCameraActivity()` juntos, e esta última
/// SEMPRE cria uma `LockscreenCameraActivity`/engine nova,
/// independentemente de o engine principal já estar rodando). Como são
/// dois isolates/engines Dart totalmente separados, uma flag em memória
/// não os vê um ao outro — por isso [_reivindicarDisparoUnico] usa
/// `SharedPreferences` (arquivo em disco compartilhado por todo o
/// processo do app) como trava: só o primeiro engine a "reivindicar" a
/// janela de alguns segundos realmente despacha o alerta; o outro
/// detecta a reivindicação já feita e não despacha de novo — eliminando
/// o bug real observado de SMS/Push duplicados conforme o caminho de
/// disparo.
class SosDisparoService {
  SosDisparoService._internal();
  static final SosDisparoService _instance = SosDisparoService._internal();
  factory SosDisparoService() => _instance;

  static const String _chaveUltimoDisparoEpochMs = 'sos_unificado_ultimo_disparo_epoch_ms';

  /// Janela de deduplicação: generosa o suficiente para cobrir a corrida
  /// entre os dois engines nativos do gatilho físico (tipicamente
  /// resolvida em bem menos de 1s), sem risco de bloquear um SEGUNDO
  /// disparo genuíno (ex: usuário aciona de novo, deliberadamente,
  /// poucos segundos depois) — mais curta que o cooldown de 10s já
  /// aplicado no lado nativo do botão de volume.
  static const int _janelaDedupMs = 4000;

  final EmergencyAlertService _emergencyAlertService = EmergencyAlertService();

  /// Executa a sequência unificada completa a partir de P1: captura e
  /// despacha a localização (deduplicado entre engines) e, em seguida —
  /// só depois de P1 estar de fato concluído/persistido — devolve o
  /// controle para o chamador abrir a câmera (P2), respeitando a ordem
  /// estrita P1 -> P2 exigida pelo produto.
  ///
  /// [origem] identifica o gatilho para fins de log/telemetria apenas —
  /// não afeta a lógica de disparo. Use `'sos_fisico'` para os dois
  /// pontos de entrada do botão físico (cold-start via lockscreen e
  /// EventChannel do `VolumeSosService`) e `'sos_manual'` para o botão
  /// da aba Segurança.
  Future<void> executarP1LocalizacaoImediata({required String origem}) async {
    // REESPECIFICAÇÃO DO USUÁRIO (2026-09-04): o antigo teto separado de 5
    // alertas/mês (PlanoLimiteService, removido) contradizia a regra
    // oficial do Plano Free — "dentro dos 10 dias ativos, todos os
    // recursos são liberados, sem nenhum teto numérico adicional". O
    // chamador (ver `main.dart::_dispararSequenciaUnificadaDeSos` /
    // `SegurancaTab._confirmarEDispararSosManual`) já checa a janela de
    // 10 dias ativos ANTES de chegar aqui; o canal SMS/Push em si também
    // se protege de forma independente (ver
    // `EmergencyAlertService._enviarSms`/`FirebaseSyncService`).
    final bool reivindicado = await _reivindicarDisparoUnico();
    if (!reivindicado) {
      debugPrint(
          '🔁 [SosDisparoService] Disparo duplicado detectado (outro engine já iniciou a sequência há poucos segundos) — P1 ($origem) não reenviado.');
      return;
    }

    // CORREÇÃO DE REGRESSÃO (bug real, 2026-08-07): a versão anterior
    // fazia `await FirebaseAuthService().aguardarUidPronto()` AQUI, ANTES
    // de entrar no Foreground Service abaixo — ou seja, ANTES do SMS
    // (canal 1, que nunca deveria depender de sessão) sequer começar a
    // ser montado. Como [aguardarUidPronto] pode levar até 5s no pior
    // caso, isso deixava o processo até 5s SEM a proteção do Foreground
    // Service nativo — tempo mais que suficiente para o Android matar o
    // processo (tela bloqueada, Doze) antes de QUALQUER coisa ser
    // enviada, "quebrando" o botão físico por completo. Agora: entra no
    // Foreground Service e dispara o SMS IMEDIATAMENTE, e só resolve o
    // uid (com espera, se necessário) DENTRO de [_dispararLocalizacaoViaNuvem],
    // em paralelo ao SMS via `Future.wait` — nunca bloqueando/atrasando
    // o canal 1.
    //
    // JANELA CRÍTICA: do início do envio até aqui embaixo, um Foreground
    // Service nativo (ver SosDispatchNativeService) mantém o PROCESSO do
    // app vivo — sem isso, o SMS/upload em voo seria perdido caso o
    // Android decidisse matar o processo no meio do envio (memória
    // baixa, Doze agressivo, app forçado a fechar logo após o toque no
    // botão de pânico). Nunca depende da Activity/engine continuar em
    // primeiro plano.
    await SosDispatchNativeService().executarComServicoAtivo(() async {
      // Canal 1 (SEMPRE, independente de sessão, disparado NA HORA — sem
      // nenhum `await` antes dele nesta função): SMS nativo, direto do
      // aparelho — ver EmergencyAlertService.dispararSosComDuplaLocalizacao.
      // Roda numa child Future totalmente independente da nuvem: uma
      // falha/demora na chamada de rede abaixo NUNCA atrasa ou cancela o
      // SMS, que não depende de internet nenhuma (rádio GSM puro).
      final smsFuture = _emergencyAlertService.dispararSosComDuplaLocalizacao();

      // Canal 2 (App-para-App): roda em PARALELO ao SMS
      // acima — a eventual espera pela sessão (ver
      // FirebaseAuthService.aguardarUidPronto) acontece só aqui dentro,
      // nunca atrasando o canal 1.
      final nuvemFuture = _dispararLocalizacaoViaNuvem(origem: origem);

      await Future.wait([smsFuture, nuvemFuture]);
    });
  }

  Future<void> _dispararLocalizacaoViaNuvem({required String origem}) async {
    final String? uid = await FirebaseAuthService().aguardarUidPronto();
    if (uid == null) {
      debugPrint(
          '📵 [SosDisparoService] Sem sessão autenticada — P1 só via SMS (canal oficial único).');
      return;
    }
    debugPrint('☁️ [SosDisparoService] Sessão autenticada — P1 também via Push.');
    final Position? posicao = await _obterPosicaoRapida();
    await FirebaseSyncService().dispararAlertaSosFisico(
      latitude: posicao?.latitude,
      longitude: posicao?.longitude,
      origem: origem,
    );
  }

  /// Executa o P2 da sequência: [foto] já foi capturada pela UI
  /// ([CameraCapturaScreen]) — envia ao Firebase Storage (se houver
  /// sessão autenticada) e, com o link em mãos, despacha os DOIS canais
  /// oficiais em paralelo: SMS com o link real da foto + localização e
  /// Push. Sem sessão OU se o upload falhar por qualquer motivo (sem
  /// rede, Storage indisponível, etc.), o canal 2 fica indisponível e o
  /// SMS usa a mensagem de fallback (sem link real) — a entrega de P2
  /// nunca pode depender de um único canal funcionando.
  Future<void> dispararFotoCapturada(XFile foto, {required String origem}) async {
    String? fotoUrl;

    // Mesma janela crítica do P1 (ver executarP1LocalizacaoImediata):
    // Foreground Service nativo ativo durante todo o upload/SMS, para
    // que uma morte do processo no meio do envio não perca o trabalho.
    //
    // CORREÇÃO DE REGRESSÃO (mesmo bug do P1, 2026-08-07): [aguardarUidPronto]
    // (ver documentação completa em [executarP1LocalizacaoImediata]) DEVE
    // ser chamado DENTRO deste bloco protegido pelo Foreground Service,
    // nunca antes — chamá-lo antes deixava o processo até 5s sem essa
    // proteção, arriscando ser morto pelo Android (tela bloqueada, Doze)
    // antes até do SMS de fallback (que nem depende de sessão) ser
    // enviado.
    await SosDispatchNativeService().executarComServicoAtivo(() async {
      final String? uid = await FirebaseAuthService().aguardarUidPronto();
      if (uid != null) {
        try {
          fotoUrl = await _uploadFotoParaStorage(foto, uid);
          debugPrint('☁️ [SosDisparoService] Foto do SOS ($origem) enviada ao Storage: $fotoUrl');
        } catch (e) {
          // RESILIÊNCIA OFFLINE: a falha de rede (sem Wi-Fi/4G, Storage
          // indisponível, etc.) NUNCA interrompe o fluxo — é capturada
          // aqui, o SMS abaixo segue via GSM normalmente (independente
          // de internet) e o payload do upload é salvo localmente para
          // ser reenviado automaticamente assim que a conectividade for
          // reestabelecida (ver RetryUploadService).
          debugPrint('⚠️ [SosDisparoService] Falha ao enviar foto ao Storage — SMS usará o fallback sem link. '
              'Payload salvo para retry automático: $e');
          try {
            await RetryUploadService().enfileirar(fotoOriginal: foto, origem: origem);
          } catch (e2) {
            debugPrint('⚠️ [SosDisparoService] Falha ao enfileirar retry do upload: $e2');
          }
        }
      } else {
        // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15):
        // antes, este ramo ("sem sessão AGORA") só mandava o SMS de
        // resgate genérico (sem link real da foto) e não enfileirava
        // NADA para retry — diferente do ramo acima (upload falhou COM
        // sessão), que já enfileira. Resultado real observado: quando
        // `aguardarUidPronto()` retornava `null` momentaneamente (ex:
        // corrida de inicialização do Firebase entre duas engines no
        // mesmo processo — ver `main.dart::_iniciarFirebaseEAuth` — ou
        // qualquer instabilidade de sessão passageira), a foto real
        // NUNCA mais era enviada, mesmo depois da sessão/conectividade
        // se restabelecerem segundos depois — só o SMS genérico "SOS-..."
        // sem link nenhum ficava registrado. Enfileirar aqui também
        // garante que [RetryUploadService] (cold start seguinte + alarme
        // periódico de 15 min) tente de novo automaticamente assim que
        // houver sessão, completando o upload real + o link da foto na
        // segunda mensagem, sem exigir nenhuma ação do usuário.
        debugPrint('📵 [SosDisparoService] Sem sessão autenticada — P2 ($origem) só via SMS '
            '(canal oficial único) agora; enfileirando para retry automático.');
        try {
          await RetryUploadService().enfileirar(fotoOriginal: foto, origem: origem);
        } catch (e2) {
          debugPrint('⚠️ [SosDisparoService] Falha ao enfileirar retry do upload (sem sessão): $e2');
        }
      }

      // Canal 1 (SEMPRE): SMS — com o link real da foto quando
      // disponível, ou a mensagem de fallback (sem link) caso
      // contrário. Child Future totalmente independente da nuvem
      // abaixo — nunca espera/depende dela.
      //
      // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06): ver
      // documentação completa em [_linkCurtoParaSms] — o SMS usa um link
      // CURTO (encurtado nas próximas linhas), nunca a URL completa do
      // Storage, para caber numa única parte de SMS e nunca precisar de
      // concatenação multi-parte (causa raiz confirmada da foto não
      // chegar aos contatos). O canal de nuvem (Push) abaixo continua
      // usando a URL completa normalmente — não tem limite de caracteres.
      final String? linkFotoParaSms =
          fotoUrl != null ? await _linkCurtoParaSms(fotoUrl!) : null;
      final smsFuture = linkFotoParaSms != null
          ? _emergencyAlertService.enviarSmsComLinkDaFoto(linkFotoParaSms)
          : _dispararFotoViaSmsFallback();

      // Canal 2 (App-para-App): só quando o upload deu certo.
      final nuvemFuture = fotoUrl != null
          ? FirebaseSyncService().dispararAlertaSosFoto(fotoUrl: fotoUrl!, origem: origem)
          : Future.value(false);

      await Future.wait([smsFuture, nuvemFuture]);
    });
  }

  /// Reenvia uma foto de SOS que ficou pendente na fila de retry local
  /// (ver [RetryUploadService]) — mesma lógica de upload+despacho de
  /// [dispararFotoCapturada], mas a partir de um arquivo já copiado para
  /// um caminho permanente em disco (o arquivo temporário original da
  /// captura pode já ter sido reciclado pelo SO). Retorna `true` só
  /// quando o upload E o despacho (SMS com link + nuvem) forem
  /// concluídos com sucesso — [RetryUploadService] só remove o item da
  /// fila local nesse caso; qualquer outra falha mantém o item na fila
  /// para a próxima tentativa periódica.
  Future<bool> tentarReenviarFotoEnfileirada({
    required String fotoPathLocal,
    required String origem,
  }) async {
    final String? uid = FirebaseAuthService().uidAtual;
    if (uid == null) {
      debugPrint('📵 [SosDisparoService] Retry de upload adiado — sem sessão autenticada no momento.');
      return false;
    }

    String fotoUrl;
    try {
      fotoUrl = await _uploadFotoParaStorage(XFile(fotoPathLocal), uid);
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Retry de upload falhou de novo (mantido na fila): $e');
      return false;
    }

    try {
      final String linkFotoParaSms = await _linkCurtoParaSms(fotoUrl);
      await Future.wait([
        _emergencyAlertService.enviarSmsComLinkDaFoto(linkFotoParaSms),
        FirebaseSyncService().dispararAlertaSosFoto(fotoUrl: fotoUrl, origem: origem),
      ]);
      debugPrint('✅ [SosDisparoService] Retry de upload ($origem) concluído com sucesso: $fotoUrl');
      return true;
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Retry de upload — Storage ok mas despacho falhou (mantido na fila): $e');
      return false;
    }
  }

  /// Encurta a URL completa do Firebase Storage ([fotoUrlLongo], com
  /// ~200+ caracteres, token incluso) para um link curto próprio
  /// (`https://www.meuguardiaox.com.br/f/<código>`, ~40 caracteres) via
  /// a Cloud Function callable `criarLinkCurtoFoto` (ver
  /// `functions/fotoSosLinkService.js`) — usado EXCLUSIVAMENTE para o
  /// texto que sai pelo SMS, nunca para o canal de Push/nuvem (que não
  /// tem limite de caracteres e continua recebendo a URL completa).
  ///
  /// CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06, 2
  /// rodadas em aparelho real — Moto G7 Play): o SMS da foto com a URL
  /// completa do Storage precisava de 2-3 partes concatenadas; o rádio
  /// confirmava `RESULT_OK` para TODAS as partes (ver `adb logcat -s
  /// SmsSender`), mas a mensagem simplesmente não chegava aos contatos —
  /// sintoma de colisão do número de referência de concatenação entre
  /// dois SMS multi-parte enviados ao mesmo número em sequência rápida
  /// (o SMS de localização, P1, sai segundos antes). Reduzir de 3 para 2
  /// partes NÃO resolveu (2ª rodada de teste, ainda sem entrega) — só um
  /// SMS de UMA ÚNICA parte (sem cabeçalho de concatenação nenhum)
  /// elimina o problema pela raiz, e a URL crua do Storage nunca cabe
  /// nesse limite.
  ///
  /// NUNCA bloqueia o envio do SMS: qualquer falha ao encurtar (function
  /// fora do ar, sem rede no momento desta chamada específica, etc.) cai
  /// de volta na URL completa original — o mesmo comportamento (com o
  /// mesmo risco de concatenação) que já existia antes desta correção,
  /// nunca a ausência total do SMS.
  Future<String> _linkCurtoParaSms(String fotoUrlLongo) async {
    try {
      final resultado = await FirebaseFunctions.instance
          .httpsCallable('criarLinkCurtoFoto')
          .call<Map<String, dynamic>>({'fotoUrl': fotoUrlLongo});
      final String? shortId = resultado.data['shortId'] as String?;
      if (shortId != null && shortId.isNotEmpty) {
        final String linkCurto = 'https://www.meuguardiaox.com.br/f/$shortId';
        debugPrint('🔗 [SosDisparoService] Link da foto encurtado para o SMS: $linkCurto');
        return linkCurto;
      }
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Falha ao encurtar o link da foto — '
          'SMS usará a URL completa do Storage (risco de multi-parte): $e');
    }
    return fotoUrlLongo;
  }

  Future<String> _uploadFotoParaStorage(XFile foto, String uid) async {
    final nomeArquivo = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = FirebaseStorage.instance.ref('sos_fotos/$uid/$nomeArquivo');
    await ref.putFile(
      File(foto.path),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return ref.getDownloadURL();
  }

  Future<void> _dispararFotoViaSmsFallback() async {
    try {
      await _emergencyAlertService.enviarSmsResgateFoto(
        login: 'familia_resgate',
        senha: 'SOS-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      );
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Falha no fallback de SMS da foto: $e');
    }
  }

  /// Localização "rápida": tenta a última posição em cache (instantânea,
  /// sem acionar o GPS); se não houver nenhuma em cache, faz uma única
  /// tentativa de leitura em tempo real com timeout curto — nunca deixa
  /// P1 esperando o GPS por muito tempo, priorizando velocidade sobre
  /// precisão milimétrica (a mensagem já avisa que é a última localização
  /// conhecida quando aplicável).
  Future<Position?> _obterPosicaoRapida() async {
    try {
      final cache = await Geolocator.getLastKnownPosition();
      if (cache != null) return cache;
    } catch (_) {}

    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );
    } catch (e) {
      debugPrint('⚠️ [SosDisparoService] Falha ao obter localização para P1: $e');
      return null;
    }
  }

  /// Reivindica, via `SharedPreferences`, o direito exclusivo de disparar
  /// P1 nesta janela de tempo — ver documentação da classe. Retorna
  /// `true` se este engine é o primeiro a chegar (deve prosseguir com o
  /// disparo) ou `false` se outro engine já reivindicou há menos de
  /// [_janelaDedupMs].
  Future<bool> _reivindicarDisparoUnico() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final agora = DateTime.now().millisecondsSinceEpoch;
      final ultimo = prefs.getInt(_chaveUltimoDisparoEpochMs) ?? 0;
      if (agora - ultimo < _janelaDedupMs) {
        return false;
      }
      await prefs.setInt(_chaveUltimoDisparoEpochMs, agora);
      return true;
    } catch (e) {
      // Falha ao acessar SharedPreferences (raríssimo) — na dúvida,
      // prefere disparar (nunca bloquear um SOS real por causa de uma
      // trava de deduplicação que não pôde ser verificada).
      debugPrint('⚠️ [SosDisparoService] Falha ao verificar deduplicação, disparando mesmo assim: $e');
      return true;
    }
  }
}
