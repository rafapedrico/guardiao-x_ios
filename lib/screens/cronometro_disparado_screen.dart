import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';

import '../services/alarme_service.dart';
import '../services/background_location_heartbeat_service.dart';
import '../services/database_helper.dart';
import '../services/emergency_alert_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/l10n_headless_service.dart';
import '../services/location_service.dart';
import '../services/rotina_alarme_service.dart';
import '../widgets/confirmacao_alerta_emergencia.dart';
import '../widgets/pin_dialog.dart';

/// Chave (SharedPreferences) sinalizando que o fluxo do Cronômetro
/// Regressivo (aba Segurança) foi TOTALMENTE resolvido (PIN correto OU
/// alerta de emergência já disparado) — mesmo papel de
/// `chaveAlarmeFluxoResolvido` em `rotina_alarme_service.dart`, e pelo
/// MESMO motivo: esta tela reaproveita a Activity nativa compartilhada
/// com o Alarme de Rotina (`RotinaCheckinAlarmActivity`, ver
/// `RotinaAlarmPlugin.kt`), então é possível existirem DUAS instâncias
/// rodando em paralelo (engine da MainActivity, se o app já estava
/// aberto, + engine desta Activity dedicada, lançada pelo alarme nativo)
/// se o app já estiver em primeiro plano no instante exato em que o
/// alarme dispara. Resolver o fluxo em UMA instância não para
/// automaticamente o som/diálogo da OUTRA sem este sinal em disco.
const String chaveCronometroFluxoResolvido = 'cronometro_fluxo_resolvido';

/// Tela dedicada exibida quando o Cronômetro Regressivo da aba Segurança
/// ZERA — reespecificação do usuário (2026-08-10, Parte 3; tolerância
/// ajustada de 180s para 60s em 2026-08-11): toca o som do alarme e abre
/// o teclado de PIN imediatamente, com até 60 segundos de tolerância
/// (`AlarmeService.duracaoJanelaFinalCronometro`) e 3 tentativas de PIN.
/// PIN correto (1ª ou 2ª tentativa) cancela tudo sem enviar nada; a 3ª
/// tentativa incorreta OU os 60s se esgotando disparam o alerta de
/// emergência com localização e mostram a confirmação de envio na tela.
///
/// ARQUITETURA: versão de FASE ÚNICA de [AlarmeDisparadoScreen] (Alarme
/// de Rotina) — mais simples, pois não há uma fase de "tolerância" prévia
/// e aberta (o próprio tempo escolhido pelo usuário no picker já cumpre
/// esse papel): assim que esta tela abre, o teclado de PIN de 60s já é
/// exibido diretamente, sem uma fase de "botão azul" anterior. Reaproveita
/// a MESMA infraestrutura nativa (Activity/Service/Receiver — ver
/// `RotinaAlarmPlugin.kt`, extra `tipoAlarme: 'cronometro'`), o mesmo
/// [PinDialogContent] (`pin_dialog.dart`) e os mesmos serviços de disparo
/// (`FirebaseSyncService`/`EmergencyAlertService`) já usados pelo Alarme
/// de Rotina e pelo próprio Cronômetro (tentativa manual de desarme,
/// ainda em `seguranca_tab.dart`, inalterada).
///
/// **Migração iOS (2026-09-12):** as 2 chamadas a `MethodChannel('.../rotina_alarme')`
/// aqui já eram protegidas por try/catch — no iOS só logam aviso e
/// seguem normalmente. O disparo do alerta em si passa por
/// `EmergencyAlertService`/`FirebaseSyncService`, já cobertos na Fase 2
/// (SMS desativado no iOS, canal de Push mantido).
class CronometroDisparadoScreen extends StatefulWidget {
  final bool veioDoForeground;
  const CronometroDisparadoScreen({super.key, this.veioDoForeground = false});

  @override
  State<CronometroDisparadoScreen> createState() =>
      _CronometroDisparadoScreenState();
}

class _CronometroDisparadoScreenState
    extends State<CronometroDisparadoScreen> {
  final AudioPlayer _player = AudioPlayer();

  static bool _instanciaGraficaAberta = false;
  bool _souDuplicada = false;

  /// Instante em que [_instanciaGraficaAberta] foi marcada `true` pela
  /// última vez — usado para detectar e SE AUTORRECUPERAR de uma flag
  /// travada (ver [_instanciaGraficaAberta]).
  static DateTime? _instanciaAbertaDesde;

  /// CORREÇÃO DE BUG REAL (2026-08-11): [_instanciaGraficaAberta] é um
  /// booleano ESTÁTICO (sobrevive entre disparos enquanto o mesmo engine
  /// nativo estiver vivo — ver `RotinaCheckinAlarmActivity`, reaberta via
  /// `onNewIntent`/`FLAG_ACTIVITY_SINGLE_TOP` sem recriar o engine). Se
  /// UMA instância anterior for encerrada de forma anormal (processo
  /// morto pelo Android, app forçado a fechar durante testes/instalação
  /// de uma nova build, etc.) SEM passar por [dispose] — que é o único
  /// lugar que zera a flag —, ela fica PRESA em `true` para sempre: todo
  /// alarme seguinte, mesmo em um ciclo completamente novo, cai
  /// imediatamente no ramo "tela duplicada" abaixo e se autodestrói SEM
  /// jamais tocar o som ou abrir o teclado de PIN — sintoma real
  /// reportado ("o teclado e o alarme ameaçam aparecer, mas são
  /// interrompidos imediatamente"). Nenhuma sessão real de PIN (60s) dura
  /// mais que [_tempoMaximoInstanciaTravada]; se a flag estiver marcada
  /// há mais tempo que isso, é certeza de que está travada por uma
  /// instância morta, não por uma duplicata legítima — trata como se
  /// nunca tivesse sido marcada e segue o fluxo normal.
  static const Duration _tempoMaximoInstanciaTravada = Duration(minutes: 5);

  bool _dialogoPinAberto = false;
  bool _alertaJaProcessado = false;
  bool _alertaDisparado = false;
  bool _fluxoEncerrado = false;

  Timer? _pollFluxoResolvidoTimer;

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
        debugPrint('🛡️ [SINTONIA] Detectada tentativa de tela duplicada do '
            'Cronômetro. Removendo da pilha imediatamente!');
        Navigator.of(context).pop();
      });
      return;
    }
    _instanciaGraficaAberta = true;
    _instanciaAbertaDesde = DateTime.now();

    // Mesma janela de "monitoramento ativo" já usada pelo alarme de
    // rotina — ver [LocationService.iniciarCicloDeAtualizacao].
    LocationService().iniciarCicloDeAtualizacao();

    _verificarFechamentoForcadoEEntaoIniciar();
  }

  /// Checa PRIMEIRO (ver documentação equivalente em
  /// `AlarmeDisparadoScreen`) se esta reabertura aconteceu por
  /// fechamento forçado (usuário arrastou o app para fora dos Recentes
  /// enquanto o cronômetro ainda tocava sem confirmação — mesmo
  /// mecanismo nativo compartilhado com o Alarme de Rotina). Se for o
  /// caso, dispara o alerta imediatamente; caso contrário, segue o fluxo
  /// normal (som + teclado de PIN).
  Future<void> _verificarFechamentoForcadoEEntaoIniciar() async {
    final bool fechamentoForcado = await RotinaAlarmeService
        .consumirFechamentoForcado(tipoAlarme: 'cronometro');
    if (!mounted || _fluxoEncerrado) return;

    if (fechamentoForcado) {
      debugPrint('🚨 [FECHAMENTO FORÇADO] App fechado enquanto o cronômetro '
          'ainda tocava sem confirmação — disparando alerta imediatamente.');
      String? motivo;
      try {
        final l10n = await L10nHeadlessService.obter();
        motivo = l10n.historicoCronometroFechamentoForcadoMotivo;
      } catch (e) {
        debugPrint('⚠️ Falha ao montar motivo de fechamento forçado: $e');
      }
      await _dispararAlerta(motivo: motivo);
      return;
    }

    _iniciarPollingDeFluxoResolvido();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tocarSomDoAlarme();
      _abrirTecladoPin();
    });
  }

  @override
  void dispose() {
    if (!_souDuplicada) {
      _instanciaGraficaAberta = false;
      _instanciaAbertaDesde = null;
      LocationService().pararCicloDeAtualizacao();
    }
    _pollFluxoResolvidoTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Carrega e toca o som de alarme customizado escolhido pelo usuário,
  /// em loop — mesmos fallbacks de preferências já usados em
  /// `AlarmeDisparadoScreen._tocarSomDoAlarme`.
  Future<void> _tocarSomDoAlarme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      String? soundPath = prefs.getString('tom_alarme_selecionado') ??
          prefs.getString('tom_alarme');

      if (soundPath == null || soundPath.isEmpty) {
        final int? somInt =
            prefs.getInt('som_selecionado') ?? prefs.getInt('tom_alarme_id');
        if (somInt != null) {
          soundPath = 'som_$somInt.mp3';
        }
      }

      if (soundPath == null || soundPath.isEmpty) {
        try {
          final config = await DatabaseHelper().getUserConfig();
          final int? somDb = config?['som_alarme_selecionado'] as int? ??
              config?['som_selecionado'] as int?;
          if (somDb != null) {
            soundPath = 'som_$somDb.mp3';
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao buscar som no SQLite (cronômetro): $e');
        }
      }

      soundPath ??= 'som_1.mp3';
      if (!soundPath.endsWith('.mp3')) {
        soundPath = '$soundPath.mp3';
      }

      try {
        await _player.stop();
      } catch (_) {}

      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('sounds/$soundPath'));
      debugPrint('🔊 Som do cronômetro iniciado com sucesso: $soundPath');
    } catch (e) {
      debugPrint('⚠️ Erro ao tocar áudio do cronômetro: $e');
    }
  }

  /// Monitora [chaveCronometroFluxoResolvido] a cada 1s enquanto a tela
  /// estiver montada — mesma técnica/motivo de
  /// `AlarmeDisparadoScreen._iniciarPollingDeSinalizacao`.
  void _iniciarPollingDeFluxoResolvido() {
    _pollFluxoResolvidoTimer =
        Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || _fluxoEncerrado) {
        timer.cancel();
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool(chaveCronometroFluxoResolvido) ?? false) {
        await _aoDetectarResolvidoEmOutraInstancia();
      }
    });
  }

  /// Outra instância desta tela já resolveu o fluxo — para o próprio som
  /// e fecha em silêncio, sem reprocessar nem mostrar sua própria
  /// confirmação.
  Future<void> _aoDetectarResolvidoEmOutraInstancia() async {
    if (_fluxoEncerrado) return;
    _fluxoEncerrado = true;
    _alertaJaProcessado = true;
    _pollFluxoResolvidoTimer?.cancel();

    try {
      const canalNativo =
          MethodChannel('com.example.security_check_app/rotina_alarme');
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
    _fecharTela();
  }

  /// Abre o teclado de PIN com o limite duro de 60 segundos e 3
  /// tentativas — ver `AlarmeService.duracaoJanelaFinalCronometro`.
  Future<void> _abrirTecladoPin() async {
    try {
      final config = await DatabaseHelper().getUserConfig();
      final pinReal = config?['pin_real'] as String? ?? '1234';
      if (!mounted) return;

      bool pinConfirmadoComSucesso = false;

      _dialogoPinAberto = true;
      await exibirDialogoPin(
        context: context,
        pinEsperado: pinReal,
        limiteErrosConsecutivos: 3,
        segundosLimiteDuro: AlarmeService.duracaoJanelaFinalCronometro.inSeconds,
        aoAtingirLimiteDeErros: _aoAtingirTerceiraSenhaErrada,
        aoExpirarTempoLimite: _aoEsgotarTempoLimite,
        aoConfirmarPinCorreto: () async {
          pinConfirmadoComSucesso = true;
          _dialogoPinAberto = false;
          _fluxoEncerrado = true;
          _pollFluxoResolvidoTimer?.cancel();
          try {
            await _player.stop();
          } catch (_) {}
          await _confirmarDesarme();
          if (!context.mounted) return;
          _fecharTela();
        },
      );
      _dialogoPinAberto = false;

      // Mesma regra de segurança do Alarme de Rotina: se o teclado fechar
      // (botão/gesto Voltar do sistema — este diálogo não tem "Cancelar")
      // sem PIN correto e sem o alerta já ter sido disparado nesse meio
      // tempo, o alarme NUNCA pode ficar silenciado — retoma o som.
      if (!pinConfirmadoComSucesso && !_fluxoEncerrado && mounted) {
        debugPrint('🔔 Teclado de PIN do cronômetro fechado sem confirmação '
            '— retomando o som.');
        unawaited(_tocarSomDoAlarme());
      }
    } catch (e) {
      debugPrint('⚠️ Erro no fluxo de PIN do cronômetro: $e');
      _dialogoPinAberto = false;
    }
  }

  /// PIN correto: cancela o alarme nativo, avisa a nuvem que o check-in
  /// está seguro e registra o desarme no histórico — mesmos passos/chaves
  /// i18n já usados por `SegurancaTab._aoConfirmarPinCorreto` (tentativa
  /// manual, antes do zero).
  Future<void> _confirmarDesarme() async {
    try {
      await AlarmeService().cancelarAlarme();
      BackgroundLocationHeartbeatService().confirmarCheckinSeguro();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(chaveCronometroFluxoResolvido, true);

      final l10n = await L10nHeadlessService.obter();
      await DatabaseHelper().inserirEventoHistorico(
        titulo: l10n.historicoCheckinDesarmadoTitulo,
        descricao: l10n.historicoCheckinDesarmadoDescricao,
        categoria: 'seguranca',
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao confirmar desarme do cronômetro: $e');
    }
  }

  Future<void> _aoAtingirTerceiraSenhaErrada() async {
    String? motivo;
    try {
      final l10n = await L10nHeadlessService.obter();
      motivo = l10n.historicoCronometroPinIncorretoMotivo;
    } catch (e) {
      debugPrint('⚠️ Falha ao montar motivo de PIN incorreto: $e');
    }
    await _dispararAlerta(motivo: motivo);
  }

  Future<void> _aoEsgotarTempoLimite() async {
    debugPrint('⏰ [TIMEOUT] 60s de tolerância esgotados sem desarme — iniciando disparo.');
    String? motivo;
    try {
      final l10n = await L10nHeadlessService.obter();
      motivo = l10n.historicoCronometroFalhaMotivo;
    } catch (e) {
      debugPrint('⚠️ [TIMEOUT] Falha ao montar motivo de tempo esgotado: $e');
    }
    await _dispararAlerta(motivo: motivo);
  }

  /// Dispara o alerta de emergência REAL (nuvem primeiro e aguardada,
  /// depois o fluxo local completo) e exibe a confirmação de envio FIXA
  /// na tela — mesma ordem/serviços já usados por
  /// `AlarmeDisparadoScreen._dispararAlertaDeFalhaDeDesarme` +
  /// `_finalizarComConfirmacao`.
  Future<void> _dispararAlerta({String? motivo}) async {
    if (_alertaJaProcessado) return;
    _alertaJaProcessado = true;

    // TRAVA ATÔMICA NATIVA (item 1, reespecificação do usuário,
    // 2026-08-15): `_alertaJaProcessado` acima só protege esta MESMA
    // instância/engine Dart — se existir uma SEGUNDA instância desta
    // tela rodando em paralelo em outro engine (app já aberto quando o
    // alarme nativo dispara — ver documentação completa da classe, no
    // topo do arquivo), ela tem seu PRÓPRIO `_alertaJaProcessado`, e
    // ambas conseguiam passar por esta guarda quase ao mesmo tempo,
    // disparando SMS/Firestore em DOBRO. `reivindicarDisparoUnicoCronometro`
    // usa uma trava nativa (HashSet num companion object Kotlin — real e
    // IMEDIATAMENTE compartilhada entre os dois engines, já que ambos
    // rodam no MESMO processo Android) para garantir exclusividade real:
    // só a PRIMEIRA chamada (de qualquer engine) recebe `true`.
    final bool souQuemDisparaDeVerdade =
        await AlarmeService().reivindicarDisparoUnicoCronometro();
    if (!souQuemDisparaDeVerdade) {
      // PERDI a corrida para a outra instância/engine — NÃO mexo em
      // `_fluxoEncerrado`/`_pollFluxoResolvidoTimer` aqui: o polling de
      // [_iniciarPollingDeFluxoResolvido] continua rodando normalmente e
      // vai detectar, em até ~1s, o `chaveCronometroFluxoResolvido` que a
      // instância VENCEDORA está prestes a gravar mais abaixo neste
      // mesmo método — é ELE quem para o som, fecha o teclado de PIN e
      // encerra esta tela (ver [_aoDetectarResolvidoEmOutraInstancia]).
      // Cancelar o polling aqui deixaria esta instância "perdedora" com o
      // som tocando e o teclado aberto para sempre.
      debugPrint('🚫 [DISPARO DUPLICADO EVITADO] Outra instância do '
          'Cronômetro já reivindicou este disparo — abortando silenciosamente '
          'e aguardando o polling de sincronização encerrar esta tela.');
      return;
    }

    _fluxoEncerrado = true;
    _pollFluxoResolvidoTimer?.cancel();

    // 1. Para o som — nativo + Dart.
    //
    // BUG REAL CONFIRMADO (2026-08-12): 'pararAlarme' (diferente de
    // 'silenciarSomSemFechar') NÃO só para o som — ele também chama
    // `fecharActivityAtiva()` no lado nativo (`RotinaAlarmPlugin.kt`),
    // que força `activity.finish()` na `RotinaCheckinAlarmActivity`
    // AGORA MESMO, destruindo esta tela/engine ANTES do SMS, do
    // histórico e da confirmação visual sequentes sequer rodarem. O
    // disparo em si (nuvem + SMS + histórico, mais abaixo) roda
    // normalmente mesmo assim — nenhum desses passos depende de
    // `context`/`mounted` — mas o `setState(() { _alertaDisparado =
    // true; })` no passo 4 é silenciosamente pulado (`if (mounted)`)
    // porque a Activity já não existe mais, e a confirmação de envio
    // nunca chega a aparecer na tela. Sintoma real reportado: "o som
    // parou certinho, mas faltou a janela avisando que a mensagem foi
    // enviada". 'silenciarSomSemFechar' é exatamente o método nativo já
    // existente para este cenário — usado pelo Alarme de Rotina para
    // silenciar o som SEM fechar a Activity enquanto o teclado de PIN
    // ainda está em uso (ver documentação em `RotinaAlarmPlugin.kt`) — e
    // aqui a tela de confirmação também precisa da Activity viva. Quem
    // efetivamente finaliza a Activity agora é [_fecharTela] (via
    // `SystemNavigator.pop`), só quando o usuário tocar em "Fechar"/
    // arrastar para cima, depois da confirmação já ter sido exibida.
    try {
      const canalNativo =
          MethodChannel('com.example.security_check_app/rotina_alarme');
      await canalNativo.invokeMethod('silenciarSomSemFechar');
    } catch (e) {
      debugPrint('⚠️ Falha ao parar som nativo ao disparar alerta: $e');
    }
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('⚠️ Falha ao parar player Dart ao disparar alerta: $e');
    }

    unawaited(RotinaAlarmeService.pararServicoForeground());
    unawaited(AlarmeService().cancelarAlarme());

    // CORREÇÃO DE BUG REAL (2026-08-15, duplo disparo): além de cancelar
    // o alarme NATIVO acima, é preciso avisar a nuvem — via
    // `alarmes_agendados/checkin_seguranca` — que o alerta já foi
    // disparado localmente, senão o documento continua PENDENTE e a
    // Cloud Function agendada (`monitorarAlarmesAgendados`), ao rodar
    // minutos depois e encontrar o prazo original já vencido, dispara um
    // SEGUNDO alerta duplicado (cenário real: 3ª senha errada dispara na
    // hora, e poucos segundos depois — quando os 60s originais se
    // esgotam — a function dispara de novo). Ver documentação completa em
    // [BackgroundLocationHeartbeatService.confirmarAlertaJaDisparado].
    BackgroundLocationHeartbeatService().confirmarAlertaJaDisparado();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(chaveCronometroFluxoResolvido, true);
    } catch (_) {}

    // 2. Fecha o teclado de PIN, se ainda estiver aberto.
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoPinAberto = false;
    }

    // 3. Dispara o alerta (nuvem primeiro e aguardada, depois o fluxo
    // local completo — SMS nativo + backend, já com o motivo/localização
    // e o registro automático no histórico, ver [EmergencyAlertService]).
    debugPrint('☁️ [TIMEOUT] Enviando Push/Firestore (FirebaseSyncService)...');
    try {
      final enviado = await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
      );
      debugPrint('☁️ [TIMEOUT] Push/Firestore -> enviado=$enviado');
    } catch (e) {
      debugPrint('⚠️ [TIMEOUT] Falha ao disparar alerta prioritário na nuvem: $e');
    }
    debugPrint('📡 [TIMEOUT] Disparando EmergencyAlertService (GPS + SMS + histórico local)...');
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto(
        motivo: motivo,
      );
      debugPrint('📡 [TIMEOUT] EmergencyAlertService concluído.');
    } catch (e) {
      debugPrint('⚠️ [TIMEOUT] Falha ao disparar alerta de emergência do cronômetro: $e');
    }

    // 4. Confirmação de envio — permanece fixa na tela (sem fechamento
    // automático) até o usuário deslizar para cima ou tocar em "Fechar".
    if (mounted) {
      setState(() {
        _alertaDisparado = true;
      });
    }
  }

  /// Único ponto de fechamento — reaproveita os dois caminhos já
  /// validados (tela ligada vs. tela desligada) de
  /// `AlarmeDisparadoScreen`.
  void _fecharTela() {
    if (!mounted) return;
    if (widget.veioDoForeground) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } else {
      SystemChannels.platform.invokeMethod('SystemNavigator.pop');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reespecificação do usuário (2026-08-14): a confirmação de alerta
    // enviado (3ª tentativa de PIN incorreta OU timeout dos 60s) usa
    // exatamente o mesmo componente visual — em VERMELHO, nunca verde —
    // compartilhado com `seguranca_tab.dart` (tentativa MANUAL de
    // desarme, antes do cronômetro zerar). Ver [ConfirmacaoAlertaEmergencia].
    if (_alertaDisparado) {
      return ConfirmacaoAlertaEmergencia(aoFechar: _fecharTela);
    }

    // Gesto de deslizar para cima é exclusivo da confirmação pós-alerta
    // acima — especificação do usuário: o gesto de "arrastar para
    // descartar" (seção 2 do pedido) é exclusivo do Alarme de Rotina, o
    // Cronômetro não o reproduz durante o teclado de PIN.
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Stack(
          children: [
            const Center(
              child: Icon(
                Icons.security_rounded,
                color: Color(0x40FF5252), // Colors.redAccent com opacity 0.25
                size: 140,
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Text(
                  AppLocalizations.of(context)!.cronometroAtivoDescricao,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
