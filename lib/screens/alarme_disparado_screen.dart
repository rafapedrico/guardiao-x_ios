import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/alarme_rotina.dart';
import '../services/alarme_agendado_cloud_service.dart';
import '../services/rotina_alarme_service.dart';
import '../services/database_helper.dart';
import '../services/emergency_alert_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/l10n_headless_service.dart';
import '../services/location_service.dart';
import '../services/notificacao_service.dart';
import '../services/bloqueio_app_service.dart';
import '../widgets/pin_dialog.dart';
import 'package:audioplayers/audioplayers.dart';

/// **Migração iOS (2026-09-12):** as 4 chamadas a `MethodChannel('.../rotina_alarme')`
/// nesta tela já eram protegidas por try/catch antes desta migração — no
/// iOS, só logam um aviso e seguem normalmente (o som do alarme, tocado
/// via `audioplayers`/Dart puro, continua funcionando independente
/// disso). A garantia real do disparo do alerta de emergência no iOS
/// (se o usuário nunca chegar a ver esta tela) é da Cloud Function
/// `functions/scheduledAlarmMonitor.js`, não desta tela — ver
/// `RotinaAlarmeService`/`docs/migracao-ios-relatorio-2026-09-12.md`.
class AlarmeDisparadoScreen extends StatefulWidget {
  // --- ADICIONADO: Parâmetro para saber se o app já estava aberto ---
  final bool veioDoForeground;
  const AlarmeDisparadoScreen({super.key, this.veioDoForeground = false});
  // ------------------------------------------------------------------

  @override
  State<AlarmeDisparadoScreen> createState() => _AlarmeDisparadoScreenState();
}

// Emergência: funciona sem desbloquear o app (ver BloqueioAppService).
class _AlarmeDisparadoScreenState extends State<AlarmeDisparadoScreen>
    with LiberaBloqueioEnquantoAberta<AlarmeDisparadoScreen> {
  final AudioPlayer _player = AudioPlayer();

  static bool _instanciaGraficaAberta = false;
  bool _souDuplicada = false;

  /// Instante em que [_instanciaGraficaAberta] foi marcada `true` pela
  /// última vez — ver documentação completa em
  /// [_tempoMaximoInstanciaTravada]/mesmo mecanismo de autorrecuperação
  /// já aplicado em `CronometroDisparadoScreen`.
  static DateTime? _instanciaAbertaDesde;

  /// CORREÇÃO DE BUG REAL (2026-08-11): mesmo bug/correção do Cronômetro
  /// (ver `cronometro_disparado_screen.dart`) — [_instanciaGraficaAberta]
  /// é estático e só é zerado em [dispose]; se uma instância anterior
  /// morrer sem passar por lá (processo morto, reinstalação durante
  /// testes, etc.), fica travada em `true` para sempre e todo alarme de
  /// rotina seguinte se autodestrói imediatamente, sem tocar o som nem
  /// abrir o teclado. Nenhum ciclo real do Alarme de Rotina (tolerância +
  /// janela final de 60s) dura mais que isto — passado esse tempo, trata
  /// a flag como travada por uma instância morta, não uma duplicata
  /// legítima.
  static const Duration _tempoMaximoInstanciaTravada = Duration(minutes: 10);

  // ==========================================================
  // FASE FINAL (última chance, 60 segundos, após a tolerância expirar)
  // ==========================================================
  // Sinalizada em disco (SharedPreferences) pelo callback headless
  // [_callbackToleranciaExpirada] em rotina_alarme_service.dart, que roda
  // num isolate separado do desta UI — por isso a necessidade de checar
  // uma vez ao abrir E também de continuar monitorando via polling
  // enquanto esta tela permanecer montada (o alarme pode "tocar
  // novamente" com o usuário já olhando para a tela do primeiro diálogo).
  bool _faseFinal = false;
  Timer? _pollFaseFinalTimer;

  // Controla se HÁ, neste exato momento, um diálogo de PIN aberto por
  // cima desta tela — usado para fechá-lo antes de abrir o diálogo
  // estrito da fase final, caso o usuário ainda estivesse com o diálogo
  // "normal" (2 erros) aberto quando a tolerância expirou.
  bool _dialogoPinAberto = false;

  // Instante exato (epoch em ms) em que o alarme REAL de emergência da
  // janela final vai disparar (gravado pelo callback headless em
  // [chaveAlarmeFaseFinalDeadlineEpochMs]) — usado para que o cronômetro
  // visual do diálogo comece já refletindo o tempo realmente restante,
  // em vez de sempre recomeçar do zero quando o polling detecta a fase
  // final com um pequeno atraso.
  int? _deadlineEpochMs;

  // ==========================================================
  // CONFIRMAÇÃO FINAL (alerta de emergência já disparado de verdade)
  // ==========================================================
  // Protege contra disparo/processamento duplicado: tanto o próprio
  // diálogo de PIN em primeiro plano (erro/tempo esgotado, caminho
  // PRIMÁRIO) quanto o polling da flag [chaveAlarmeEmergenciaDisparada]
  // gravada pelo callback headless (caminho de FALLBACK) podem tentar
  // finalizar a tela — apenas o primeiro a chegar deve executar a
  // sequência.
  bool _alertaJaProcessado = false;

  // Controla a UI de confirmação exibida após o alerta real ter sido
  // disparado (ver [_finalizarComConfirmacao]).
  bool _alertaDisparado = false;

  // ==========================================================
  // SINCRONIA ENTRE MÚLTIPLOS ENGINES (bug real observado em teste)
  // ==========================================================
  // RotinaCheckinAlarmActivity é lançada via Intent puro — cria um
  // engine Flutter/isolate Dart TOTALMENTE SEPARADO do da MainActivity
  // (apesar de um comentário antigo do código nativo afirmar o
  // contrário). Isso significa que podem existir DUAS instâncias desta
  // tela rodando em paralelo, cada uma com seu PRÓPRIO AudioPlayer e
  // Timers — resolver o fluxo em UMA (ex: confirmar o PIN) não para
  // automaticamente o som da OUTRA. [_fluxoEncerrado] é setado assim que
  // ESTA instância souber, por qualquer meio (resolveu ela mesma OU
  // detectou [chaveAlarmeFluxoResolvido] gravado por outra instância),
  // que o ciclo terminou — usado para nunca processar/fechar duas vezes.
  bool _fluxoEncerrado = false;

  int? _idAlarmeAtual;

  @override
  void initState() {
    super.initState();

    final DateTime? desde = _instanciaAbertaDesde;
    final bool travadaHaMuitoTempo = _instanciaGraficaAberta &&
        desde != null &&
        DateTime.now().difference(desde) > _tempoMaximoInstanciaTravada;
    if (travadaHaMuitoTempo) {
      debugPrint('🛡️ [SINTONIA] Flag de instância única travada há mais de '
          '${_tempoMaximoInstanciaTravada.inMinutes}min (instância anterior '
          'morreu sem dispose) — tratando como nova instância legítima.');
      _instanciaGraficaAberta = false;
    }

    if (_instanciaGraficaAberta) {
      _souDuplicada = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('🛡️ [SINTONIA] Detetada tentativa de tela azul duplicada. Removendo da pilha imediatamente!');
        Navigator.of(context).pop();
      });
      return;
    }

    _instanciaGraficaAberta = true;
    _instanciaAbertaDesde = DateTime.now();

    // Camada extra de resiliência (Firebase): enquanto esta tela estiver
    // aberta (alarme de rotina disparado, aguardando confirmação de PIN),
    // envia a localização à nuvem a cada 1 minuto — mesma janela de
    // "monitoramento ativo" já usada pelo cronômetro da aba Segurança.
    // Interrompido em dispose() assim que o alarme for desarmado/fechado.
    LocationService().iniciarCicloDeAtualizacao();

    // PRIORIDADE MÁXIMA (item 4 — fechamento forçado): checa ANTES de
    // qualquer outra coisa (som, polling normal) se esta reabertura da
    // tela aconteceu porque o usuário arrastou o app para fora dos
    // Recentes enquanto o alarme ainda tocava (ver
    // `RotinaAlarmWakeService.onTaskRemoved`/[RotinaAlarmeService.
    // consumirFechamentoForcado]). Se for o caso, dispara o alerta
    // imediatamente em vez de seguir o fluxo normal — por isso este
    // `await` bloqueia o resto do initState (é uma checagem local,
    // rapidíssima, e queremos decidir isso antes de tocar qualquer som).
    _verificarFechamentoForcadoEEntaoIniciar();
  }

  /// Ver comentário em [initState]. Se NÃO foi fechamento forçado, segue
  /// o fluxo normal exatamente como antes (polling de sinalização +
  /// tocar o som customizado).
  Future<void> _verificarFechamentoForcadoEEntaoIniciar() async {
    final bool fechamentoForcado = await RotinaAlarmeService.consumirFechamentoForcado();
    if (!mounted || _fluxoEncerrado) return;

    if (fechamentoForcado) {
      debugPrint('🚨 [FECHAMENTO FORÇADO] App foi fechado enquanto o alarme '
          'de rotina ainda tocava sem confirmação — disparando alerta '
          'imediatamente, sem retomar o toque normal.');
      _idAlarmeAtual ??= await _resolverIdAlarmeMaisRecente();
      String? motivo;
      try {
        final l10n = await L10nHeadlessService.obter();
        Map<String, dynamic>? dados;
        if (_idAlarmeAtual != null) {
          dados = await DatabaseHelper().buscarAlarmePorId(_idAlarmeAtual!);
        }
        final etiqueta = dados != null
            ? AlarmeRotina.fromMap(dados).etiquetaExibida(l10n)
            : l10n.familiaEtiquetaPadrao;
        motivo = l10n.historicoCheckinRotinaFechamentoForcadoMotivo(etiqueta);
      } catch (e) {
        debugPrint('⚠️ Falha ao montar motivo de fechamento forçado: $e');
      }
      await _dispararAlertaDeFalhaDeDesarme(
        motivo: motivo,
        mostrarConfirmacaoEFechar: true,
      );
      return;
    }

    // Verifica imediatamente se este disparo já nasceu na fase final (ou
    // com o alerta real já disparado — ex: a tela foi recriada após ter
    // sido fechada) e continua monitorando a cada 1s enquanto a tela
    // estiver montada — ver [_iniciarPollingDeSinalizacao].
    _verificarSinalizacaoNoDisco();
    _iniciarPollingDeSinalizacao();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('📱 [INTERFACE] Botão azul montado! Carregando som customizado.');
      _tocarSomDoAlarme();
    });
  }

  @override
  void dispose() {
    if (!_souDuplicada) {
      _instanciaGraficaAberta = false;
      _instanciaAbertaDesde = null;
      // Encerra o ciclo de localização iniciado em initState() — mantém o
      // par iniciar/parar 1:1 exigido pela contagem de referências do
      // LocationService (ver [LocationService.pararCicloDeAtualizacao]).
      LocationService().pararCicloDeAtualizacao();
    }
    _pollFaseFinalTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Carrega e toca o som de alarme customizado escolhido pelo usuário,
  /// em loop. Extraído para ser reaproveitado tanto no primeiro toque
  /// (initState) quanto ao ENTRAR NA FASE FINAL ([_entrarNaFaseFinal]) —
  /// esse segundo ponto de chamada é o que garante que "o despertador
  /// toca novamente" de verdade quando a tolerância expira, já que o som
  /// NATIVO (Kotlin) não pode ser reiniciado de forma confiável a partir
  /// do callback headless (ver comentário detalhado em
  /// `RotinaAlarmeService.tocarAlarmeNovamente`) — este player Dart, por
  /// rodar sempre no engine em primeiro plano desta tela, é a fonte de
  /// som garantida.
  Future<void> _tocarSomDoAlarme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Força a leitura atualizada do disco
      if (prefs.getBool('stop_current_alarm') == true) return;

      // 1. Tenta buscar das SharedPreferences (String)
      String? soundPath = prefs.getString('tom_alarme_selecionado') ??
                          prefs.getString('tom_alarme');

      // 2. Tenta buscar das SharedPreferences (Int)
      if (soundPath == null || soundPath.isEmpty) {
        final int? somInt = prefs.getInt('som_selecionado') ?? prefs.getInt('tom_alarme_id');
        if (somInt != null) {
          soundPath = 'som_$somInt.mp3';
        }
      }

      // 3. 🟢 FALLBACK DE SEGURANÇA: Consulta direta na tabela user_config
      if (soundPath == null || soundPath.isEmpty) {
        try {
          final dbHelper = DatabaseHelper();
          final config = await dbHelper.getUserConfig();
          final int? somDb = config?['som_alarme_selecionado'] as int? ??
                             config?['som_selecionado'] as int?;
          if (somDb != null) {
            soundPath = 'som_$somDb.mp3';
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao buscar som no SQLite: $e');
        }
      }

      // 4. Se nada for encontrado em nenhum lugar, assume som_1.mp3 como padrão
      soundPath ??= 'som_1.mp3';

      if (!soundPath.endsWith('.mp3')) {
        soundPath = '$soundPath.mp3';
      }

      try {
        await _player.stop();
      } catch (_) {}

      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('sounds/$soundPath'));
      debugPrint('🔊 Som customizado iniciado com sucesso na interface: $soundPath');
    } catch (e) {
      debugPrint('⚠️ Erro ao tocar áudio na interface: $e');
    }
  }

  /// Leitura única (ao montar a tela) das flags de fase final/alerta já
  /// disparado.
  Future<void> _verificarSinalizacaoNoDisco() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    if ((prefs.getBool(chaveAlarmeEmergenciaDisparada) ?? false) && !_alertaJaProcessado) {
      await _aoDetectarEmergenciaDisparadaNoDisco();
      return;
    }

    final bool faseFinal = prefs.getBool(chaveAlarmeFaseFinal) ?? false;
    if (faseFinal && mounted && !_faseFinal) {
      _deadlineEpochMs = prefs.getInt(chaveAlarmeFaseFinalDeadlineEpochMs);
      await _entrarNaFaseFinal();
    }
  }

  /// Monitora as flags de fase final / alerta disparado a cada 1 segundo
  /// enquanto a tela estiver montada — necessário porque os callbacks
  /// headless que gravam essas flags rodam num isolate separado do desta
  /// UI (mesma técnica de "sinalização via disco" já usada em
  /// `main.dart`/`alarme_disparando_no_momento`), e esta tela pode já
  /// estar aberta (com o diálogo "normal" de PIN) no momento exato em
  /// que a tolerância/janela final expira.
  void _iniciarPollingDeSinalizacao() {
    _pollFaseFinalTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _fluxoEncerrado) {
        timer.cancel();
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // PRIORIDADE MÁXIMA: o fluxo já foi resolvido por OUTRA instância
      // desta mesma tela (engine/isolate separado, ver documentação de
      // [chaveAlarmeFluxoResolvido]) — para tudo aqui e fecha em
      // silêncio, sem reprocessar nem mostrar a própria confirmação.
      if (prefs.getBool(chaveAlarmeFluxoResolvido) ?? false) {
        await _aoDetectarResolvidoEmOutraInstancia();
        return;
      }

      if (!_alertaJaProcessado && (prefs.getBool(chaveAlarmeEmergenciaDisparada) ?? false)) {
        await _aoDetectarEmergenciaDisparadaNoDisco();
        return;
      }

      if (!_faseFinal && (prefs.getBool(chaveAlarmeFaseFinal) ?? false)) {
        _deadlineEpochMs = prefs.getInt(chaveAlarmeFaseFinalDeadlineEpochMs);
        await _entrarNaFaseFinal();
      }
    });
  }

  /// Fallback: reage à flag [chaveAlarmeEmergenciaDisparada] gravada pelo
  /// callback headless [_callbackJanelaFinalExpirada] — usado apenas
  /// quando o próprio diálogo de PIN em primeiro plano (caminho
  /// primário, ver [_dispararAlertaDeFalhaDeDesarme]) não tiver
  /// processado a falha sozinho. NÃO reenvia o alerta (o headless já o
  /// fez) — só executa a parte de UI (parar som, fechar diálogo, mostrar
  /// confirmação).
  Future<void> _aoDetectarEmergenciaDisparadaNoDisco() async {
    if (_alertaJaProcessado) return;
    _alertaJaProcessado = true;
    await _finalizarComConfirmacao();
  }

  /// Reage à flag [chaveAlarmeFluxoResolvido]: OUTRA instância desta
  /// tela (rodando num engine/isolate separado — ver documentação
  /// completa da flag) já resolveu o fluxo (PIN correto OU alerta
  /// disparado). Esta instância apenas para seu PRÓPRIO som (nativo +
  /// Dart) e se fecha SILENCIOSAMENTE — não reenvia nada nem mostra sua
  /// própria tela de confirmação, já que a outra instância já cuidou
  /// disso.
  Future<void> _aoDetectarResolvidoEmOutraInstancia() async {
    if (_fluxoEncerrado) return;
    _fluxoEncerrado = true;
    _alertaJaProcessado = true;
    _pollFaseFinalTimer?.cancel();

    debugPrint('🛑 [SINCRONIA MULTI-ENGINE] Fluxo já resolvido em outra '
        'instância da tela do alarme — encerrando esta em silêncio.');

    try {
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      await canalNativo.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo (resolvido alhures): $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('⚠️ Falha ao parar player Dart (resolvido alhures): $e');
    }

    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }

    if (!mounted) return;
    if (widget.veioDoForeground) {
      _fecharCaminhoTelaLigada(context);
    } else {
      await _fecharCaminhoTelaDesligada(context);
    }
  }

  /// Transição para a janela final: o alarme "tocou novamente" — reforça
  /// o som (Dart, garantido + nativo, melhor esforço), fecha o diálogo
  /// de PIN "normal" se ainda estiver aberto (não faz sentido mantê-lo,
  /// com o limite de 2 erros, por baixo do novo) e abre diretamente o
  /// diálogo estrito de 60 segundos, sem exigir novo toque em "Interromper
  /// Alarme".
  Future<void> _entrarNaFaseFinal() async {
    if (_faseFinal) return;
    _faseFinal = true;
    if (mounted) setState(() {});

    // Garante que o usuário OUÇA o alarme de novo: o AudioPlayer Dart é
    // a fonte CONFIÁVEL (roda neste mesmo engine em primeiro plano).
    unawaited(_tocarSomDoAlarme());

    // CORREÇÃO (bug real observado em teste): reiniciar apenas o som não
    // bastava — com o aparelho bloqueado há alguns minutos, a TELA
    // continuava apagada (ninguém via o teclado de PIN). Resolve o
    // idAlarme PRIMEIRO e usa o método nativo combinado, que acende a
    // tela fisicamente, traz a Activity de volta ao primeiro plano e
    // reforça o som nativo — tudo em uma única chamada confiável (roda
    // no engine em primeiro plano desta tela).
    _idAlarmeAtual ??= await _resolverIdAlarmeMaisRecente();
    if (_idAlarmeAtual != null) {
      unawaited(RotinaAlarmeService.acordarParaFaseFinal(_idAlarmeAtual!));
    }

    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
      // Pequena espera para o pop concluir antes de empilhar o próximo
      // diálogo por cima da mesma rota.
      await Future.delayed(const Duration(milliseconds: 150));
    }

    if (!mounted) return;
    await _abrirTecladoPin();
  }

  // --- CAMINHO 1: EXCLUSIVO PARA TELA LIGADA (Limpa toda e qualquer tela azul duplicada) ---
  void _fecharCaminhoTelaLigada(BuildContext context) {
    // Garante que o diálogo do PIN feche primeiro (se ainda houver um
    // aberto — a confirmação final não abre nenhum diálogo).
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }

    // Varre a pilha limpando qualquer rota residual de alarme que tenha ficado sobreposta
    Navigator.of(context).popUntil((route) {
      return route.isFirst || route.settings.name != '/alarme_disparado';
    });

    debugPrint('🔓 [CAMINHO TELA LIGADA] Telas de alarme limpas com sucesso. App continua aberto!');
  }

  // --- CAMINHO 2: EXCLUSIVO PARA TELA DESLIGADA (Encerra o processo nativo) ---
  Future<void> _fecharCaminhoTelaDesligada(BuildContext context) async {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    await SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    debugPrint('🔓 [CAMINHO TELA DESLIGADA] Encerrando o processo nativo e voltando para o Android.');
  }

  /// Resolve o id do alarme de rotina mais recentemente disparado
  /// (`ultimo_disparo_epoch` mais alto), usado tanto pelo toque no botão
  /// "Interromper Alarme" quanto pela transição automática para a fase
  /// final.
  Future<int?> _resolverIdAlarmeMaisRecente() async {
    final alarmes = await DatabaseHelper().listarAlarmes();
    Map<String, dynamic>? maisRecente;

    for (final alarme in alarmes) {
      final epoch = alarme['ultimo_disparo_epoch'] as int?;
      if (epoch == null) continue;
      final epochAtual = maisRecente?['ultimo_disparo_epoch'] as int?;
      if (epochAtual == null || epoch > epochAtual) {
        maisRecente = alarme;
      }
    }

    return maisRecente?['id'] as int?;
  }

  /// Ponto ÚNICO de abertura do teclado de PIN — usado tanto pelo toque
  /// no botão "Interromper Alarme" (fase inicial: limite de 2 erros
  /// consecutivos, sem prazo duro) quanto pela transição automática para
  /// a janela final (limite de 1 erro + 60 segundos de prazo duro, ver
  /// [_entrarNaFaseFinal]). Consolida a resolução do alarme mais recente,
  /// a busca do PIN esperado e o fluxo de confirmação/erro/expiração.
  Future<void> _abrirTecladoPin() async {
    try {
      // Interrompe apenas o SOM nativo ao tocar no botão — NUNCA chama
      // [RotinaAlarmeService.pausarAlarme] aqui, pois ela cancelaria os
      // alarmes nativos de tolerância/janela final ANTES do PIN ser
      // confirmado. Regra 3 exige que a tolerância continue contando
      // enquanto o PIN correto não for digitado, mesmo que o botão já
      // tenha sido tocado — só [RotinaAlarmeService.confirmarCheckinRotina]
      // (PIN correto) pode cancelá-los de verdade.
      //
      // NÃO para o [_player] aqui (diferente da versão anterior): na
      // fase final ele PRECISA continuar tocando enquanto o teclado é
      // exibido — só é interrompido de fato ao confirmar o PIN correto
      // ou ao disparar o alerta real (ver [_finalizarComConfirmacao]).
      //
      // CORREÇÃO (bug real observado em teste — tela bloqueada): usava
      // "pararAlarme" aqui, que no lado Kotlin (RotinaAlarmPlugin)
      // também chama fecharActivityAtiva() — fechando a
      // RotinaCheckinAlarmActivity (e o engine Flutter dentro dela)
      // ANTES do teclado de PIN sequer aparecer, com o aparelho
      // bloqueado. "silenciarSomSemFechar" faz SÓ a parte de áudio, sem
      // encerrar a Activity.
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      try {
        await canalNativo.invokeMethod('silenciarSomSemFechar');
      } catch (e) {
        debugPrint('⚠️ Falha ao parar som nativo do alarme: $e');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      await prefs.reload();

      // CORREÇÃO DE SEGURANÇA: mesmo que [idAlarme] não possa ser
      // resolvido (caso raro — ex: alarme já reagendado/removido entre o
      // disparo e o toque no botão), o app NUNCA deve fechar a tela sem
      // exigir o PIN correto primeiro. Antes, esse caso caía num
      // caminho que fechava direto, sem diálogo — um desvio de
      // autenticação. Agora [idAlarme] segue nulo até o diálogo (só é
      // usado dentro de [aoConfirmarPinCorreto] para decidir se chama
      // [RotinaAlarmeService.confirmarCheckinRotina]).
      final idAlarme = _idAlarmeAtual ?? await _resolverIdAlarmeMaisRecente();
      _idAlarmeAtual = idAlarme;

      final config = await DatabaseHelper().getUserConfig();
      final pinReal = config?['pin_real'] as String? ?? '1234';

      if (!mounted) return;

      // Capturado no momento da abertura: se a fase final mudar enquanto
      // este diálogo específico já está aberto, ela só afeta o PRÓXIMO
      // diálogo (aberto por [_entrarNaFaseFinal] após fechar este).
      final bool ehFaseFinal = _faseFinal;

      // Calcula o tempo REALMENTE restante até o alarme nativo de
      // emergência da janela final disparar (ver [_deadlineEpochMs]), em
      // vez de sempre começar do zero — garante que o cronômetro visual
      // reflita com precisão o prazo real, mesmo com o pequeno atraso do
      // polling que detectou a fase final.
      int segundosLimiteDuro = RotinaAlarmeService.duracaoJanelaFinal.inSeconds;
      if (ehFaseFinal && _deadlineEpochMs != null) {
        final restanteMs = _deadlineEpochMs! - DateTime.now().millisecondsSinceEpoch;
        segundosLimiteDuro = (restanteMs / 1000).ceil().clamp(
              0,
              RotinaAlarmeService.duracaoJanelaFinal.inSeconds,
            );
      }

      // Etiqueta do alarme para as mensagens de motivo abaixo (l10n) —
      // mesmo texto usado pelo callback headless equivalente
      // ([_callbackJanelaFinalExpirada] em rotina_alarme_service.dart).
      final l10nDialogo = AppLocalizations.of(context)!;
      String etiquetaAlarme = l10nDialogo.familiaEtiquetaPadrao;
      try {
        if (idAlarme != null) {
          final dadosAlarme = await DatabaseHelper().buscarAlarmePorId(idAlarme);
          if (dadosAlarme != null) {
            etiquetaAlarme = AlarmeRotina.fromMap(dadosAlarme).etiquetaExibida(l10nDialogo);
          }
        }
      } catch (_) {}
      if (!mounted) return;

      bool pinConfirmadoComSucesso = false;

      _dialogoPinAberto = true;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinReal,
        segundosTolerancia: null,
        // UNIFICADO (especificação do usuário, 2026-08-07, item 3): 3
        // tentativas de PIN incorreto SEMPRE disparam o alerta de
        // imediato — sem disfarce, sem diferença entre fase inicial e
        // fase final (tolerância vs. os 60s adicionais). As 2 primeiras
        // tentativas erradas só mostram "PIN incorreto" e mantêm o
        // alarme tocando normalmente; a 3ª desliga o alarme e dispara o
        // alerta na hora.
        limiteErrosConsecutivos: 3,
        segundosLimiteDuro: ehFaseFinal ? segundosLimiteDuro : null,
        aoAtingirLimiteDeErros: () => _dispararAlertaDeFalhaDeDesarme(
          motivo: l10nDialogo.historicoCheckinRotinaPinIncorretoMotivo(etiquetaAlarme),
          mostrarConfirmacaoEFechar: true,
        ),
        aoExpirarTempoLimite: ehFaseFinal
            ? () => _dispararAlertaDeFalhaDeDesarme(
                  motivo: l10nDialogo.historicoCheckinRotinaFalhaMotivo(etiquetaAlarme),
                  mostrarConfirmacaoEFechar: true,
                )
            : null,
        aoDescartarPorArraste: _descartarPorArraste,
        aoConfirmarPinCorreto: () async {
          pinConfirmadoComSucesso = true;
          _dialogoPinAberto = false;
          _fluxoEncerrado = true;
          _pollFaseFinalTimer?.cancel();
          try {
            await _player.stop();
          } catch (_) {}
          if (idAlarme != null) {
            // Grava chaveAlarmeFluxoResolvido (ver RotinaAlarmeService)
            // para que qualquer OUTRA instância desta tela, rodando num
            // engine separado (ver documentação da flag), pare seu
            // próprio som e se feche também. Também é aqui (PIN já
            // validado) que o status na nuvem vira CONFIRMADO_SEGURA —
            // ver [AlarmeAgendadoCloudService.marcarConfirmadoSeguro].
            await RotinaAlarmeService.confirmarCheckinRotina(idAlarme);
          } else {
            // idAlarme não pôde ser resolvido (caso raro) — mesmo assim
            // o PIN já foi validado acima antes de chegar aqui; apenas
            // libera o WakeLock/serviço em primeiro plano com segurança.
            unawaited(RotinaAlarmeService.pararServicoForeground());
          }

          if (!context.mounted) return;

          // --- SEPARAÇÃO DE CAMINHOS BASEADA NA INTERFACE ATIVA ---
          final ModalRoute<dynamic>? rotaAtual = ModalRoute.of(context);
          final bool interfaceGraficaAtiva = rotaAtual?.isActive ?? false;

          if (widget.veioDoForeground && interfaceGraficaAtiva) {
            _fecharCaminhoTelaLigada(context);
          } else {
            await _fecharCaminhoTelaDesligada(context);
          }
        },
      );
      _dialogoPinAberto = false;

      // REQUISITO DE SEGURANÇA: se o teclado fechou (ex: botão/gesto
      // Voltar do sistema, já que este diálogo não tem botão "Cancelar")
      // SEM o PIN correto E sem o alerta de emergência já ter sido
      // disparado nesse meio-tempo (_fluxoEncerrado), o alarme NUNCA pode
      // ficar silenciado — precisa voltar a tocar normalmente até a
      // tolerância/janela final esgotar de verdade.
      if (!pinConfirmadoComSucesso && !_fluxoEncerrado && mounted) {
        debugPrint(
            '🔔 Teclado de PIN fechado sem confirmação — retomando o som do alarme.');
        try {
          await prefs.setBool('stop_current_alarm', false);
          await prefs.setBool('alarme_disparando_no_momento', true);
        } catch (_) {}
        unawaited(_tocarSomDoAlarme());
        unawaited(RotinaAlarmeService.reiniciarSomNativoSeAtivo());
      }
    } catch (e) {
      debugPrint('⚠️ Erro no fluxo de silenciamento e PIN: $e');
      _dialogoPinAberto = false;
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  /// Dispara o alerta de emergência REAL por falha de desarme na JANELA
  /// FINAL (nuvem primeiro e aguardada, depois o fluxo local completo) —
  /// acionado tanto pelo limite de erros de PIN quanto pela expiração do
  /// prazo duro. Este é o caminho PRIMÁRIO (o polling da flag em disco,
  /// ver [_aoDetectarEmergenciaDisparadaNoDisco], é só um fallback).
  ///
  /// [motivo] nulo mantém o texto padrão histórico ("PIN incorreto 2
  /// vezes seguidas"), usado na fase INICIAL (regra 2) — nesse caso,
  /// [mostrarConfirmacaoEFechar] permanece `false`, preservando o
  /// disfarce de segurança (nada muda visualmente na tela). Na fase
  /// FINAL, [mostrarConfirmacaoEFechar] é sempre `true`: não há mais
  /// motivo para disfarçar — o usuário deve ver claramente que o alerta
  /// foi enviado.
  Future<void> _dispararAlertaDeFalhaDeDesarme({
    String? motivo,
    bool mostrarConfirmacaoEFechar = false,
  }) async {
    // TRAVA CONTRA MENSAGENS DUPLICADAS: só a JANELA FINAL corre risco de
    // disparo duplo (este diálogo de PIN em primeiro plano E o callback
    // headless [_callbackJanelaFinalExpirada] podem detectar a MESMA
    // falha quase simultaneamente) — por isso o eventoId (mesmo id em
    // ambos os caminhos, ver documentação em
    // [FirebaseSyncService.dispararAlertaTentativaDesarmeIncorreto]) só é
    // calculado aqui. A fase inicial (2 erros, disfarçada) não tem
    // contraparte headless — comportamento histórico inalterado.
    String? eventoId;
    if (mostrarConfirmacaoEFechar && _idAlarmeAtual != null) {
      try {
        final dados = await DatabaseHelper().buscarAlarmePorId(_idAlarmeAtual!);
        final ultimoDisparoEpoch = dados?['ultimo_disparo_epoch'] as int?;
        if (ultimoDisparoEpoch != null) {
          eventoId = 'rotina_${_idAlarmeAtual}_$ultimoDisparoEpoch';
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao calcular eventoId de deduplicação: $e');
      }
    }

    if (mostrarConfirmacaoEFechar) {
      if (_alertaJaProcessado) return;
      _alertaJaProcessado = true;

      // Este caminho (primeiro plano) já está tratando a falha — cancela
      // o alarme nativo da janela final para que ele não dispare de novo
      // (duplicando o alerta) alguns instantes depois.
      if (_idAlarmeAtual != null) {
        unawaited(RotinaAlarmeService.cancelarJanelaFinal(_idAlarmeAtual!));

        // CORREÇÃO DE BUG REAL (2026-08-15, mesma classe do duplo disparo
        // do Cronômetro — ver `CronometroDisparadoScreen._dispararAlerta`):
        // cancelar o alarme NATIVO acima não é suficiente. É preciso
        // também avisar a nuvem que o alerta já foi disparado pelo
        // aparelho, senão o documento `alarmes_agendados/{idAlarme}`
        // continua PENDENTE, e a Cloud Function agendada
        // (`monitorarAlarmesAgendados`), ao rodar minutos depois e
        // encontrar o prazo original (`prazoFinalEpochMs`) já vencido
        // nesse mesmo documento ainda PENDENTE, dispara um SEGUNDO alerta
        // duplicado — mesmo cenário real relatado no Cronômetro (3ª senha
        // errada dispara na hora, e a janela final nativa/a Cloud Function
        // disparam de novo pouco depois). Ver
        // [AlarmeAgendadoCloudService.marcarAlertaDisparado].
        unawaited(AlarmeAgendadoCloudService()
            .marcarAlertaDisparado(_idAlarmeAtual!.toString()));
        // Ciclo definitivamente concluído (falha) — a PRÓXIMA ocorrência
        // deste mesmo id deve nascer PENDENTE de novo. Ver
        // [AlarmeAgendadoCloudService.sinalizarNovoCiclo] (débito técnico
        // corrigido em 2026-08-15).
        AlarmeAgendadoCloudService().sinalizarNovoCiclo(_idAlarmeAtual!.toString());
      }
    }

    try {
      await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
        eventoId: eventoId,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta prioritário na nuvem: $e');
    }
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
        eventoId: eventoId,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta de tentativa de '
          'desarme incorreta: $e');
    }

    if (mostrarConfirmacaoEFechar) {
      await _finalizarComConfirmacao();
    }
  }

  /// Aciona quando o usuário arrasta/joga o botão azul OU o teclado de
  /// PIN para cima (gesto de DESCARTE, distinto do gesto de sistema
  /// "tirar o app dos Recentes" já tratado por `onTaskRemoved` —
  /// especificação do usuário). Ligado tanto ao [GestureDetector] da fase
  /// "alarme ativo" no [build] quanto ao parâmetro
  /// `aoDescartarPorArraste` passado a [exibirDialogoPin] em
  /// [_abrirTecladoPin] (fase inicial e fase final).
  ///
  /// DIFERENTE de [_dispararAlertaDeFalhaDeDesarme] (PIN incorreto/tempo
  /// esgotado): naqueles casos a tela mostra uma confirmação FIXA até o
  /// usuário fechá-la. Aqui a exigência é o oposto — o controle da
  /// tela/sistema precisa voltar 100% ao Android IMEDIATAMENTE (o botão e
  /// o teclado somem, sem tentar redesenhar nada por cima do bloqueio) —
  /// por isso a ORDEM das etapas é: 1) para o som, 2) fecha a
  /// Activity/devolve o controle ao Android, e SÓ DEPOIS 3) dispara o
  /// alerta com localização e 4) confirma o envio via uma NOTIFICAÇÃO do
  /// sistema (ver [NotificacaoService.exibirNotificacaoAlertaEnviado]) —
  /// não há mais nenhuma UI do app na tela para mostrar um diálogo
  /// in-app neste ponto.
  Future<void> _descartarPorArraste() async {
    if (_alertaJaProcessado) return;
    _alertaJaProcessado = true;
    _fluxoEncerrado = true;
    _pollFaseFinalTimer?.cancel();

    // 1. Para o som imediatamente — nativo + Dart.
    try {
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      await canalNativo.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo ao descartar por arraste: $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('⚠️ Falha ao parar player Dart ao descartar por arraste: $e');
    }

    unawaited(RotinaAlarmeService.pararServicoForeground());

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      // Sinaliza a QUALQUER outra instância desta tela (engine/isolate
      // separado, ver documentação de [chaveAlarmeFluxoResolvido]) que o
      // fluxo já foi resolvido aqui.
      await prefs.setBool(chaveAlarmeFluxoResolvido, true);
    } catch (_) {}

    // 2. Devolve o controle 100% ao Android — a tela (botão/teclado) some
    // AGORA, antes até do alerta ser efetivamente disparado.
    if (mounted) {
      if (widget.veioDoForeground) {
        _fecharCaminhoTelaLigada(context);
      } else {
        await _fecharCaminhoTelaDesligada(context);
      }
    }

    // 3. Dispara o alerta com localização (mesmo par de chamadas usado em
    // [_dispararAlertaDeFalhaDeDesarme]) — cancela a janela final nativa
    // primeiro, para que ela não dispare de novo (duplicando o alerta)
    // alguns instantes depois.
    if (_idAlarmeAtual != null) {
      unawaited(RotinaAlarmeService.cancelarJanelaFinal(_idAlarmeAtual!));
      // Ver documentação completa em [_dispararAlertaDeFalhaDeDesarme] —
      // mesma correção contra o duplo disparo via Cloud Function agendada.
      unawaited(AlarmeAgendadoCloudService()
          .marcarAlertaDisparado(_idAlarmeAtual!.toString()));
      // Ciclo definitivamente concluído (falha/descarte) — a PRÓXIMA
      // ocorrência deste mesmo id deve nascer PENDENTE de novo. Ver
      // [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
      AlarmeAgendadoCloudService().sinalizarNovoCiclo(_idAlarmeAtual!.toString());
    }

    String? motivo;
    String? eventoId;
    try {
      final l10n = await L10nHeadlessService.obter();
      _idAlarmeAtual ??= await _resolverIdAlarmeMaisRecente();
      Map<String, dynamic>? dados;
      if (_idAlarmeAtual != null) {
        dados = await DatabaseHelper().buscarAlarmePorId(_idAlarmeAtual!);
      }
      final etiqueta = dados != null
          ? AlarmeRotina.fromMap(dados).etiquetaExibida(l10n)
          : l10n.familiaEtiquetaPadrao;
      motivo = l10n.historicoCheckinRotinaDescartadoPorArrasteMotivo(etiqueta);
      final ultimoDisparoEpoch = dados?['ultimo_disparo_epoch'] as int?;
      if (_idAlarmeAtual != null && ultimoDisparoEpoch != null) {
        eventoId = 'rotina_${_idAlarmeAtual}_$ultimoDisparoEpoch';
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao montar motivo de descarte por arraste: $e');
    }

    try {
      await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
        eventoId: eventoId,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta prioritário na nuvem (descarte): $e');
    }
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
        eventoId: eventoId,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar alerta de descarte por arraste: $e');
    }

    // 4. Confirmação de envio — via notificação do sistema, já que a
    // tela do app não existe mais neste ponto (ver documentação do
    // método).
    try {
      await NotificacaoService.exibirNotificacaoAlertaEnviado();
    } catch (e) {
      debugPrint('⚠️ Falha ao exibir notificação de confirmação de descarte: $e');
    }
  }

  /// Executa a sequência final da JANELA FINAL depois que o alerta real
  /// já foi disparado (ou sinalizado como disparado pelo callback
  /// headless, ver [_aoDetectarEmergenciaDisparadaNoDisco]):
  /// 1. Para o alarme sonoro (nativo + Dart).
  /// 2. Fecha o teclado de PIN, se ainda estiver aberto.
  /// 3. Exibe a mensagem de confirmação de envio, FIXA na tela — só é
  ///    fechada quando o usuário desliza para cima ou toca em "Fechar"
  ///    (ver [_fecharTelaConfirmacao]), nunca automaticamente.
  ///
  /// Idempotente: protegida pela MESMA flag [_alertaJaProcessado] usada
  /// em [_dispararAlertaDeFalhaDeDesarme], para nunca executar esta
  /// sequência mais de uma vez.
  Future<void> _finalizarComConfirmacao() async {
    _fluxoEncerrado = true;
    _pollFaseFinalTimer?.cancel();

    // 1. Para o som — nativo (reliable a partir daqui, pois estamos no
    // engine em primeiro plano) e Dart.
    try {
      const canalNativo = MethodChannel('com.example.security_check_app/rotina_alarme');
      await canalNativo.invokeMethod('pararAlarme');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo ao finalizar: $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('⚠️ Falha ao parar player Dart ao finalizar: $e');
    }

    // Libera o WakeLock nativo (ver RotinaAlarmWakeService) — não há mais
    // motivo para manter a CPU acordada além deste ponto.
    unawaited(RotinaAlarmeService.pararServicoForeground());

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stop_current_alarm', true);
      await prefs.remove('alarme_disparando_no_momento');
      // Sinaliza a QUALQUER outra instância desta tela (engine/isolate
      // separado, ver documentação de [chaveAlarmeFluxoResolvido]) que o
      // fluxo já foi resolvido aqui — ela deve parar seu próprio som e
      // se fechar em silêncio.
      await prefs.setBool(chaveAlarmeFluxoResolvido, true);
    } catch (_) {}

    // 2. Fecha o teclado de PIN, se ainda estiver aberto.
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }

    // 3. Exibe a confirmação — permanece fixa na tela (sem fechamento
    // automático) até o usuário deslizar para cima ou tocar em "Fechar"
    // (ver [_fecharTelaConfirmacao] e o gesto configurado em [build]).
    if (mounted) {
      setState(() {
        _alertaDisparado = true;
        _faseFinal = true;
      });
    }
  }

  /// Único ponto de fechamento da tela de confirmação verde — acionado
  /// pelo gesto de deslizar para cima ou pelo botão "Fechar" (nunca
  /// automaticamente, ver [_finalizarComConfirmacao]). Reaproveita os
  /// mesmos dois caminhos de encerramento já validados (tela ligada vs.
  /// tela desligada) para garantir que, no caso de tela desligada, o
  /// aparelho retorne imediatamente ao bloqueio nativo do Android.
  Future<void> _fecharTelaConfirmacao() async {
    if (!mounted) return;
    if (widget.veioDoForeground) {
      _fecharCaminhoTelaLigada(context);
    } else {
      await _fecharCaminhoTelaDesligada(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget tela = Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Icon(
                _alertaDisparado
                    ? Icons.check_circle_rounded
                    : (_faseFinal ? Icons.warning_amber_rounded : Icons.security_rounded),
                color: _alertaDisparado
                    ? Colors.greenAccent.withOpacity(0.35)
                    : (_faseFinal ? Colors.redAccent.withOpacity(0.25) : Colors.white10),
                size: 140,
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _alertaDisparado
                          ? AppLocalizations.of(context)!.alarmeRotinaAlertaEnviadoDescricao
                          : (_faseFinal
                              ? AppLocalizations.of(context)!.alarmeRotinaFaseFinalDescricao
                              : AppLocalizations.of(context)!.alarmeRotinaAtivoDescricao),
                      style: TextStyle(
                        color: _alertaDisparado
                            ? Colors.greenAccent
                            : (_faseFinal ? Colors.redAccent : Colors.white70),
                        fontSize: 16,
                        fontWeight:
                            (_faseFinal || _alertaDisparado) ? FontWeight.bold : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    // Botão "Interromper Alarme": só na fase inicial. Na
                    // fase final o teclado já é aberto automaticamente, e
                    // após a confirmação não há mais nenhuma ação
                    // pendente do usuário.
                    if (!_faseFinal && !_alertaDisparado)
                      SizedBox(
                        width: double.infinity,
                        height: 64,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue.shade700,
                            foregroundColor: Colors.white,
                            elevation: 6,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(32),
                            ),
                          ),
                          onPressed: _abrirTecladoPin,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.alarm_off, size: 26),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  AppLocalizations.of(context)!.desligarAlarmeBotao,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Tela de confirmação (pós-alerta): permanece fixa —
                    // só sai por gesto explícito do usuário (swipe up,
                    // capturado em todo o corpo da tela abaixo, ou este
                    // botão "Fechar").
                    if (_alertaDisparado) ...[
                      const Icon(
                        Icons.keyboard_arrow_up_rounded,
                        color: Colors.white38,
                        size: 32,
                      ),
                      Text(
                        AppLocalizations.of(context)!.fecharConfirmacaoDica,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.greenAccent,
                            side: const BorderSide(color: Colors.greenAccent),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                          ),
                          onPressed: _fecharTelaConfirmacao,
                          child: Text(
                            AppLocalizations.of(context)!.fecharConfirmacaoBotao,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Gesto de deslizar para cima:
    // - Na tela de confirmação (pós-alerta): fecha a tela normalmente
    //   (comportamento antigo, inalterado).
    // - Na fase "alarme ativo" (botão azul, ANTES de abrir o teclado de
    //   PIN): aciona o gesto de DESCARTE (ver [_descartarPorArraste]) —
    //   especificação do usuário: arrastar o botão para cima sem digitar
    //   o PIN é tratado como uma falha de confirmação, igual à 3ª
    //   tentativa errada.
    // - Durante a fase final/teclado de PIN aberto: o gesto é capturado
    //   DENTRO do próprio diálogo (ver `pin_dialog.dart`,
    //   `aoDescartarPorArraste`), não aqui.
    if (_alertaDisparado) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragEnd: (details) {
          if (details.velocity.pixelsPerSecond.dy < -250) {
            _fecharTelaConfirmacao();
          }
        },
        child: tela,
      );
    }

    if (!_faseFinal) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragEnd: (details) {
          if (details.velocity.pixelsPerSecond.dy < -250) {
            _descartarPorArraste();
          }
        },
        child: tela,
      );
    }

    return tela;
  }
}
