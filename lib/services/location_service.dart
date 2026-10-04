import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'firebase_sync_service.dart';
import 'l10n_headless_service.dart';

/// Serviço centralizado de geolocalização proativa.
///
/// Estratégia adotada (definida junto com o time de segurança):
///
/// 1. Permissão ao iniciar: assim que a tela de Segurança é aberta, o app
///    verifica e solicita a permissão de localização do Android
///    ('While in Use'), garantindo que o GPS esteja liberado antes mesmo
///    de o usuário precisar ativar o cronômetro.
///
/// 2. Captura proativa (warm-up): no exato instante em que o cronômetro de
///    check-in é iniciado, uma localização de alta precisão é buscada
///    IMEDIATAMENTE em segundo plano e guardada em memória como a
///    "Localização Atualizada".
///
/// 3. Loop de atualização: enquanto o cronômetro estiver ativo, a cada
///    2 minutos uma nova localização é obtida e SUBSTITUI a anterior em
///    memória — mantendo sempre apenas o registro mais recente do
///    aparelho, sem acumular histórico.
///
/// 4. Envio do alerta: no momento do disparo de emergência, o SMS usa
///    imediatamente essa última localização salva em memória por este
///    fluxo proativo, sem depender de uma nova consulta (lenta) ao GPS
///    no momento crítico.
///
/// 5. Camada extra de resiliência (Firebase): em PARALELO ao loop acima
///    (independente dele), um segundo Timer dispara a cada 1 minuto
///    enquanto o monitoramento estiver ativo, enviando a última posição
///    ao Firestore via [FirebaseSyncService.atualizarLocalizacaoAtual]
///    (sempre sobrescrevendo o mesmo documento, nunca acumulando
///    histórico). Isso garante que, mesmo que o aparelho seja
///    destruído/desligado/perca sinal, a nuvem já tenha uma posição com
///    no máximo ~1 minuto de atraso. Funciona apenas enquanto o app
///    estiver vivo (primeiro ou segundo plano) — não sobrevive ao
///    processo do app sendo encerrado pelo Android.
class LocationService {
  LocationService._internal();
  static final LocationService _instance = LocationService._internal();
  factory LocationService() => _instance;

  /// Intervalo entre atualizações automáticas de localização enquanto o
  /// cronômetro de check-in estiver ativo.
  static const Duration intervaloAtualizacao = Duration(minutes: 2);

  /// Intervalo entre os envios periódicos de localização ao Firebase
  /// (camada de resiliência na nuvem), independente do loop acima.
  static const Duration intervaloAtualizacaoFirebase = Duration(minutes: 1);

  /// Última posição capturada em memória (a "Localização Atualizada").
  /// É sempre sobrescrita: nunca mantemos histórico, apenas o registro
  /// mais recente do aparelho.
  Position? _ultimaPosicao;

  Timer? _timerAtualizacao;
  Timer? _timerFirebase;

  // Contagem de referências: permite que MAIS DE UM consumidor (ex: o
  // cronômetro da aba Segurança E, simultaneamente, um alarme de rotina
  // disparado na aba Família) "peçam" o ciclo de atualização ao mesmo
  // tempo, sem que um cancele o ciclo do outro por engano. Os Timers só
  // são criados de fato na PRIMEIRA chamada de
  // [iniciarCicloDeAtualizacao] (contador 0 -> 1) e só são cancelados na
  // ÚLTIMA chamada correspondente de [pararCicloDeAtualizacao] (contador
  // 1 -> 0) — cada consumidor deve manter seu próprio par
  // iniciar/parar 1:1.
  int _referenciasAtivas = 0;

  Position? get ultimaPosicao => _ultimaPosicao;

  /// Verifica e solicita a permissão de localização ('While in Use') junto
  /// ao sistema operacional Android. Deve ser chamado assim que a tela de
  /// Segurança for aberta (ou na inicialização do app), garantindo que o
  /// GPS esteja liberado antes do usuário precisar ativar o cronômetro.
  ///
  /// Retorna `true` se a permissão foi concedida (When in Use ou Always),
  /// `false` caso contrário.
  Future<bool> garantirPermissaoDeLocalizacao() async {
    try {
      final bool servicoAtivo = await Geolocator.isLocationServiceEnabled();
      if (!servicoAtivo) {
        debugPrint('📍 Serviço de localização (GPS) está desativado no aparelho.');
        return false;
      }

      LocationPermission permissao = await Geolocator.checkPermission();

      if (permissao == LocationPermission.denied) {
        permissao = await Geolocator.requestPermission();
      }

      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        debugPrint('📍 Permissão de localização negada pelo usuário.');
        return false;
      }

      // permissao concedida: whileInUse ou always.
      return true;
    } catch (e) {
      debugPrint('⚠️ Falha ao solicitar permissão de localização: $e');
      return false;
    }
  }

  /// Busca a localização atual com alta precisão e guarda em memória,
  /// substituindo qualquer registro anterior (regra de descarte).
  ///
  /// Usado tanto no "warm-up" (ao iniciar o cronômetro) quanto em cada
  /// ciclo do loop de atualização periódica.
  Future<Position?> capturarLocalizacaoAtual() async {
    try {
      final bool temPermissao = await garantirPermissaoDeLocalizacao();
      if (!temPermissao) return _ultimaPosicao;

      final posicao = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );

      // Regra de descarte: sempre substitui a posição anterior pela mais
      // recente, mantendo em memória apenas o último registro do aparelho.
      _ultimaPosicao = posicao;
      debugPrint(
          '📍 Localização atualizada em memória: ${posicao.latitude}, ${posicao.longitude}');
      return _ultimaPosicao;
    } catch (e) {
      debugPrint('⚠️ Falha ao capturar localização atual: $e');
      // Mantém a última posição válida conhecida em memória (se existir),
      // para que o fluxo de emergência ainda tenha uma coordenada útil.
      return _ultimaPosicao;
    }
  }

  /// Inicia o ciclo de vida do GPS atrelado ao monitoramento ativo
  /// (cronômetro de check-in da Segurança OU alarme de rotina disparado
  /// na Família):
  ///
  /// 1. Faz o "warm-up": busca a localização atual imediatamente.
  /// 2. Agenda um Timer.periodic para repetir a captura a cada 2 minutos
  ///    enquanto o monitoramento permanecer ativo.
  /// 3. Agenda um segundo Timer.periodic independente, a cada 1 minuto,
  ///    enviando a localização ao Firebase (ver [_atualizarLocalizacaoNoFirebase]).
  ///
  /// Cada chamada DEVE ter uma chamada correspondente de
  /// [pararCicloDeAtualizacao] quando aquele monitoramento específico
  /// terminar — a contagem de referências ([_referenciasAtivas]) garante
  /// que os Timers só parem quando TODOS os consumidores tiverem
  /// encerrado, permitindo que a Segurança e a Família monitorem ao
  /// mesmo tempo sem um cancelar o ciclo do outro.
  Future<void> iniciarCicloDeAtualizacao() async {
    _referenciasAtivas++;
    if (_referenciasAtivas > 1) {
      // Já existe outro consumidor mantendo o ciclo ativo: apenas
      // contabiliza mais um interessado, sem recriar os Timers.
      return;
    }

    // Passo 2 (Warm-up): busca IMEDIATA da localização precisa, em
    // segundo plano, no exato momento em que o monitoramento é iniciado.
    await capturarLocalizacaoAtual();

    // Passo 3: loop de atualização a cada 2 minutos enquanto o
    // monitoramento permanecer ativo.
    _timerAtualizacao = Timer.periodic(intervaloAtualizacao, (timer) async {
      await capturarLocalizacaoAtual();
    });

    // Passo 5 (Firebase): warm-up + loop independente de 1 em 1 minuto,
    // enviando a última localização à nuvem enquanto o monitoramento
    // estiver ativo. Roda em paralelo ao loop de 2 minutos acima, sem
    // interferir nele.
    await _atualizarLocalizacaoNoFirebase();
    _timerFirebase = Timer.periodic(intervaloAtualizacaoFirebase, (timer) async {
      await _atualizarLocalizacaoNoFirebase();
    });
  }

  /// Interrompe o ciclo de atualização periódica de localização. Deve ser
  /// chamado sempre que o monitoramento ativo daquele consumidor
  /// específico for parado/desarmado (com sucesso ou por disparo de
  /// emergência) — ver a contagem de referências em [_referenciasAtivas]:
  /// os Timers só são efetivamente cancelados quando o último consumidor
  /// ativo chamar este método.
  void pararCicloDeAtualizacao() {
    if (_referenciasAtivas == 0) return;
    _referenciasAtivas--;
    if (_referenciasAtivas > 0) return;

    _timerAtualizacao?.cancel();
    _timerAtualizacao = null;
    _timerFirebase?.cancel();
    _timerFirebase = null;
  }

  /// Captura a posição atual (reaproveitando [capturarLocalizacaoAtual],
  /// já com seu próprio fallback para a última posição em memória) e
  /// envia ao Firestore via [FirebaseSyncService]. Não faz nada se nenhuma
  /// posição estiver disponível (GPS desligado e sem posição anterior em
  /// memória) — o próximo tick de 1 minuto tenta novamente.
  Future<void> _atualizarLocalizacaoNoFirebase() async {
    final posicao = await capturarLocalizacaoAtual();
    if (posicao == null) return;
    await FirebaseSyncService().atualizarLocalizacaoAtual(
      latitude: posicao.latitude,
      longitude: posicao.longitude,
      precisao: posicao.accuracy,
      origem: 'cronometro',
    );
  }

  /// Limpa a última localização guardada em memória. Opcionalmente pode
  /// ser chamado após o envio do alerta de emergência, para não reutilizar
  /// coordenadas antigas em um próximo ciclo de check-in.
  void limparLocalizacao() {
    _ultimaPosicao = null;
  }

  /// Formata a última posição conhecida em memória em texto legível
  /// (latitude/longitude + link clássico do Google Maps) para ser
  /// inserido no corpo do SMS de emergência.
  ///
  /// Caso não exista nenhuma posição em memória (fluxo proativo nunca
  /// rodou ou falhou completamente), tenta como último recurso obter a
  /// última localização conhecida do aparelho (cache do sistema) antes de
  /// desistir.
  Future<String> obterLocalizacaoFormatadaParaAlerta() async {
    Position? posicao = _ultimaPosicao;

    if (posicao == null) {
      try {
        posicao = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }

    if (posicao == null) {
      final l10n = await L10nHeadlessService.obter();
      return l10n.smsLocalizacaoIndisponivelFalha;
    }

    return _formatarPosicao(posicao);
  }

  String _formatarPosicao(Position posicao) {
    return 'Latitude: ${posicao.latitude}, Longitude: ${posicao.longitude} '
        '(https://maps.google.com/?q=${posicao.latitude},${posicao.longitude})';
  }
}
