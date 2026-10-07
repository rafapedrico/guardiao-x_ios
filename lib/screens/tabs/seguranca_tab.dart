import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/location_service.dart';
import '../../services/emergency_alert_service.dart';
import '../../services/alarme_service.dart';
import '../../services/background_location_heartbeat_service.dart';
import '../../services/captura_dissuasao_service.dart';
import '../../services/historico_alertas_service.dart';
import '../../services/sos_disparo_service.dart';
import '../../services/sos_widget_fluxo_service.dart';
import '../cronometro_disparado_screen.dart' show chaveCronometroFluxoResolvido;
import '../../widgets/confirmacao_alerta_emergencia.dart';
import '../../widgets/pin_dialog.dart';
import '../../widgets/plano_bloqueado_dialog.dart';




class SegurancaTab extends StatefulWidget {
  const SegurancaTab({super.key});

  @override
  State<SegurancaTab> createState() => _SegurancaTabState();
}

class _SegurancaTabState extends State<SegurancaTab> {
  final DatabaseHelper _db = DatabaseHelper();
  final AlarmeService _alarmeService = AlarmeService();

  // Controlador para o campo de Anotações/Dica de Contexto
  final TextEditingController _contextoController = TextEditingController();

  // Estilos de texto reutilizados na tela, centralizados para evitar
  // duplicação e facilitar futuras alterações de tema.
  static const TextStyle _estiloTituloSecao = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: Colors.black87,
  );
  static const TextStyle _estiloLabelPicker = TextStyle(
    color: Colors.grey,
    fontWeight: FontWeight.w500,
  );

  // Variáveis do Banco de Dados
  String? _pinRealConfirmado;

  // Variáveis de controle do Timer Padrão
  int _horaSelecionada = 0;
  int _minutoSelecionada = 5;

  // Variáveis de controle do Timer Ativo
  Timer? _timer;
  bool _isTimerAtivo = false;
  int _segundosRestantes = 0;

  // ==========================================================
  // CONTROLE DO DIÁLOGO DE PIN DE DESARME
  // ==========================================================
  // Regra de negócio reespecificada em 2026-08-09: o toque no botão
  // laranja NÃO interrompe mais o cronômetro principal — ele continua
  // rodando normalmente em segundo plano por trás do diálogo de PIN
  // (ver [_abrirDialogoDesarme]). Esta flag apenas evita que o mesmo
  // diálogo seja aberto duas vezes simultaneamente (o modal já bloqueia
  // toques na tela por baixo dele, mas esta guarda extra cobre qualquer
  // chamada programática repetida).
  bool _dialogoPinAberto = false;

  // Serviço singleton responsável pelo ciclo de vida proativo do GPS:
  // solicitação de permissão, warm-up ao iniciar o cronômetro e loop de
  // atualização a cada 2 minutos enquanto o check-in estiver ativo.
  final LocationService _locationService = LocationService();


  @override
  void initState() {
    super.initState();
    _carregarConfiguracoesSeguranca();

    // CORREÇÃO DE BUG REAL (2026-08-23, relatado pelo usuário): a Tela de
    // Início ocupa o MESMO slot, dentro de `HomeScreen`, da IndexedStack
    // que hospeda esta aba — navegar até "Início" (inclusive via
    // Configurações -> ícone de casa) troca `IndexedStack(...)` por
    // `InicioDashboard()` no mesmo lugar da árvore de widgets, o que
    // DESTRÓI e recria o State desta tela ao voltar (`initState` roda de
    // novo do zero). Sem isto, `_isTimerAtivo`/`_segundosRestantes` e o
    // `Timer.periodic` visual eram perdidos — a aba voltava mostrando
    // "Fazer Check-in" como se nenhum cronômetro estivesse ativo, mesmo
    // com o alarme NATIVO (`AlarmeService.agendarAlarmeEmergencia`,
    // Doze-proof) e o dead man's switch na nuvem
    // (`BackgroundLocationHeartbeatService`) continuando 100% ativos por
    // baixo — nenhum dos dois depende do State desta tela. Ver
    // [_restaurarCronometroAtivoSePersistido].
    _restaurarCronometroAtivoSePersistido();

    // Regra de negócio 1 (Permissão ao Iniciar): assim que a tela de
    // Segurança é aberta, o app já verifica/solicita a permissão de
    // localização do Android, garantindo que o GPS esteja liberado antes
    // mesmo de o usuário ativar o cronômetro de check-in.
    _locationService.garantirPermissaoDeLocalizacao();
  }

  @override
  void dispose() {
    _contextoController.dispose();
    _cancelarTodosOsTimers();
    // Interrompe o loop de atualização de localização (se ainda ativo) ao
    // destruir a tela, evitando Timers órfãos em segundo plano.
    _locationService.pararCicloDeAtualizacao();
    super.dispose();
  }

  // ==========================================================
  // GERENCIADOR CENTRALIZADO DO CICLO DE VIDA DOS TIMERS
  // ==========================================================
  // Ponto ÚNICO de cancelamento de TODOS os Timers desta tela (cronômetro
  // principal). Chamado sistematicamente ANTES de
  // qualquer novo Timer ser criado (iniciar cronômetro, dispose), e
  // também diretamente pelo dispose(). Isso elimina de raiz qualquer
  // possibilidade de dois Timers do mesmo tipo coexistirem
  // simultaneamente.
  void _cancelarTodosOsTimers() {
    _timer?.cancel();
    _timer = null;
  }

  /// Cancela exclusivamente o cronômetro principal de check-in,
  /// garantindo que nenhuma referência antiga fique rodando "invisível"
  /// antes de um novo ser agendado.
  void _cancelarTimerPrincipal() {
    _timer?.cancel();
    _timer = null;
  }


  Future<void> _carregarConfiguracoesSeguranca() async {
    try {
      final config = await _db.getUserConfig();
      if (config != null && mounted) {
        setState(() {
          _pinRealConfirmado = config['pin_real'] as String?;
        });
        // Verifica se o prazo de segurança de 2h já expirou, e caso
        // afirmativo, efetiva a troca de senha pendente automaticamente.
        await _processarSenhaPendenteSeExpirada();
      }
    } catch (_) {}
  }

  /// Verifica se existe uma senha pendente e se o prazo de segurança de
  /// 2 horas desde a solicitação já se passou. Se sim, promove a senha
  /// pendente para senha principal (pin_real) e limpa os campos temporários.
  /// Caso contrário, mantém a senha antiga como válida para autenticação.
  ///
  /// A verificação/efetivação em si é centralizada no DatabaseHelper
  /// (`processarSenhaPendenteSeExpirada`), garantindo que o mesmo
  /// comportamento ocorra independentemente de qual tela do app o usuário
  /// abrir primeiro (Segurança, Configurações ou cold start em main.dart).
  Future<void> _processarSenhaPendenteSeExpirada() async {
    final efetivado = await _db.processarSenhaPendenteSeExpirada();
    if (efetivado && mounted) {
      final config = await _db.getUserConfig();
      if (config != null) {
        setState(() {
          _pinRealConfirmado = config['pin_real'] as String?;
        });
      }
    }
    // Se ainda não passaram 2h, nada é feito: a senha antiga
    // (_pinRealConfirmado) continua sendo a única válida para autenticação.
  }

  /// Ação disparada ao tocar no botão circular de check-in.
  ///
  /// Regra de segurança crítica (reespecificada em 2026-08-09): uma vez
  /// que o timer esteja ativo (botão laranja, "Toque: desarmar"), o
  /// toque NUNCA cancela o cronômetro diretamente — em vez disso, abre
  /// IMEDIATAMENTE o teclado numérico de PIN (ver [_abrirDialogoDesarme]).
  /// O cronômetro principal CONTINUA rodando normalmente em segundo
  /// plano por trás do diálogo: só o PIN correto o cancela, ou o próprio
  /// tempo se esgotando dispara o alerta. O ALARME NATIVO agendado via
  /// AlarmeService só é cancelado quando o PIN correto for digitado com
  /// sucesso — abrir o diálogo, por si só, NUNCA cancela o alarme nativo.
  void _alternarTimer() {
    if (_isTimerAtivo) {
      _abrirDialogoDesarme();
    } else {
      _iniciarTimer();
    }
  }

  /// Abre o diálogo de PIN para tentativa de desarme (toque no botão
  /// laranja). Exige o PIN correto ou 3 tentativas erradas consecutivas
  /// para se resolver (ver [_aoConfirmarPinCorreto]/
  /// [_aoAtingirTerceiraSenhaErrada]) — NÃO interrompe o cronômetro
  /// principal, que continua contando em segundo plano por trás do
  /// diálogo. Protegido por [_dialogoPinAberto] contra abertura em
  /// duplicidade.
  void _abrirDialogoDesarme() {
    if (_dialogoPinAberto || !mounted) return;
    _dialogoPinAberto = true;
    exibirDialogoPin(
      context: context,
      pinEsperado: _pinRealConfirmado,
      aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
      // Regra de negócio: exatamente 3 tentativas de PIN erradas
      // encerram o cronômetro imediatamente e disparam o alerta
      // completo — ver [_aoAtingirTerceiraSenhaErrada]. Nas 2 primeiras
      // tentativas erradas o diálogo apenas mostra o erro e permanece
      // aberto para uma nova tentativa, sem disparar nada.
      limiteErrosConsecutivos: 3,
      aoAtingirLimiteDeErros: _aoAtingirTerceiraSenhaErrada,
    ).then((_) {
      _dialogoPinAberto = false;
    });
  }

  /// Fecha o diálogo de PIN se estiver aberto — usado quando o próprio
  /// cronômetro (não o usuário) precisa encerrar o ciclo: o tempo se
  /// esgotou naturalmente, ou a 3ª tentativa de PIN errada disparou o
  /// alerta. Devolve a interface ao estado normal (regra de negócio:
  /// "libere a interface do aplicativo para uso normal").
  void _fecharDialogoPinSeAberto() {
    if (_dialogoPinAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    _dialogoPinAberto = false;
  }


  /// Restaura a EXIBIÇÃO do cronômetro de check-in, se algum ciclo ainda
  /// estiver em andamento, ao (re)montar esta tela — ver a correção de
  /// bug real documentada em [initState]. Lê o timestamp de expiração
  /// persistido em disco (`DatabaseHelper.salvarContextoTimerAtivo`,
  /// gravado no INÍCIO do cronômetro, ANTES do alarme nativo ser
  /// agendado) e, se ele ainda estiver no futuro, recalcula
  /// `_segundosRestantes` a partir do tempo REAL restante e retoma a
  /// contagem visual normalmente — sem reagendar o alarme nativo nem
  /// re-registrar o heartbeat na nuvem, já que nenhum dos dois foi
  /// perdido (são independentes do State desta tela).
  Future<void> _restaurarCronometroAtivoSePersistido() async {
    try {
      final config = await _db.getUserConfig();
      if (config == null) return;

      final timestampStr = config['timestamp_expiracao_alarme'] as String?;
      final epochMs = timestampStr != null ? int.tryParse(timestampStr) : null;
      if (epochMs == null) return;

      final restante =
          DateTime.fromMillisecondsSinceEpoch(epochMs).difference(DateTime.now());
      // Prazo já vencido — ou o alerta real já está em andamento na tela
      // dedicada [CronometroDisparadoScreen], ou o ciclo genuinamente
      // expirou enquanto esta tela estava desmontada. De qualquer forma,
      // não há contagem visual para retomar aqui; mantém o estado ocioso
      // normal.
      if (restante.inSeconds <= 0) return;

      if (!mounted) return;

      _cancelarTimerPrincipal();
      _disparoJaExecutadoNesteCiclo = false;
      setState(() {
        _segundosRestantes = restante.inSeconds;
        _isTimerAtivo = true;
        _contextoController.text = (config['contexto_timer_ativo'] as String?) ?? '';
      });

      // Retoma o loop de localização em segundo plano (interrompido pelo
      // dispose() do State anterior, ver [dispose]) e a contagem visual.
      _locationService.iniciarCicloDeAtualizacao();
      _iniciarTimerVisual();

      debugPrint(
          '⏱️ [SegurancaTab] Cronômetro ativo restaurado ao reabrir a aba '
          '— ${restante.inSeconds}s restantes.');
    } catch (e) {
      debugPrint('⚠️ [SegurancaTab] Falha ao restaurar cronômetro ativo: $e');
    }
  }

  Future<void> _iniciarTimer() async {
    // REGRA DE NEGÓCIO (Cronômetro Regressivo, pedido explícito do
    // usuário, 2026-09-04 — mesma trava já aplicada ao Alarme de Rotina e
    // ao SOS): dentro dos 10 dias ativos do mês (ou Premium), o recurso
    // funciona normalmente; fora dessa janela, o botão verde não deve
    // sequer iniciar a contagem — exibe o aviso de upsell e interrompe
    // aqui, ANTES de qualquer `setState`/agendamento. Mesma trava única
    // do ciclo do Plano Free (ver PlanoCicloService), nunca um teto
    // numérico separado.
    if (!await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;

    _carregarConfiguracoesSeguranca();
    int totalSegundos = (_horaSelecionada * 3600) + (_minutoSelecionada * 60);

    if (totalSegundos <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.segurancaSelecioneTempo)),
      );
      return;
    }

    // Cancela sistematicamente QUALQUER Timer principal que ainda possa
    // estar rodando de um ciclo anterior, antes de iniciar um novo —
    // elimina a possibilidade de dois cronômetros concorrentes
    // coexistirem.
    _cancelarTimerPrincipal();

    // Novo ciclo de check-in: reseta a flag de disparo único, garantindo
    // que o próximo esgotamento de tolerância possa disparar novamente
    // (uma única vez por ciclo).
    _disparoJaExecutadoNesteCiclo = false;

    setState(() {
      _segundosRestantes = totalSegundos;
      _isTimerAtivo = true;
    });



    // Registra no histórico ('seguranca') a ativação do cronômetro de
    // check-in, tornando a ação 100% transparente e auditável.
    if (mounted) {
      // Evento do cronômetro na área protegida do Histórico, com a posição.
      final l10n = AppLocalizations.of(context)!;
      final duracao = l10n.historicoCronometroAtivadoDescricao(
        _horaSelecionada.toString().padLeft(2, '0'),
        _minutoSelecionada.toString().padLeft(2, '0'),
      );
      final texto = _contextoController.text.trim();
      unawaited(HistoricoAlertasService().registrarEvento(
        tipo: TipoAlertaHistorico.cronometroAtivado,
        contexto: texto.isEmpty ? duracao : '$duracao\n$texto',
        posicao: _locationService.ultimaPosicao,
      ));
    }

    // Regra de negócio 2 e 3 (Captura Proativa + Loop de Atualização):
    // no exato momento em que o cronômetro é iniciado, dispara IMEDIATAMENTE
    // a busca de localização de alta precisão em segundo plano (warm-up) e
    // agenda a atualização automática a cada 2 minutos enquanto o
    // cronômetro permanecer ativo. A chamada não é aguardada (fire-and-
    // -forget) para não travar a UI do botão de check-in.
    _locationService.iniciarCicloDeAtualizacao();

    // Agenda o alarme NATIVO (android_alarm_manager_plus), que garante o
    // disparo de emergência mesmo que o app seja fechado ou fique em
    // segundo plano. Regra de negócio reespecificada em 2026-08-09: sem
    // tolerância extra — dispara exatamente no fim do tempo escolhido
    // pelo usuário, replicando o mesmo instante do cronômetro em memória.
    _alarmeService.agendarAlarmeEmergencia(
      duracaoAteDisparo: Duration(seconds: totalSegundos),
      contexto: _contextoController.text.trim(),
    );

    // Regra de negócio 4 (Rastreamento em segundo plano): registra este
    // ciclo como um dead man's switch na nuvem, reaproveitando a mesma
    // infraestrutura já validada para o alarme de rotina — dentro da
    // janela de 120 minutos antes do fim, a localização passa a ser
    // capturada e sobrescrita na nuvem a cada 1 minuto; se o aparelho
    // ficar offline/desligado antes do fim, a Cloud Function agendada
    // (`scheduledAlarmMonitor.js`) dispara o alerta usando a ÚLTIMA
    // localização válida registrada, com seu horário exato.
    BackgroundLocationHeartbeatService().registrarCheckinAtivo(
      dataHoraDisparo: DateTime.now().add(Duration(seconds: totalSegundos)),
      contexto: _contextoController.text.trim(),
    );

    _iniciarTimerVisual();
  }

  /// Cria o `Timer.periodic` que só decrementa `_segundosRestantes` e
  /// atualiza a UI a cada segundo — extraído de [_iniciarTimer] para ser
  /// reaproveitado também por [_restaurarCronometroAtivoSePersistido]
  /// (retomada da contagem visual ao reabrir esta aba com um cronômetro
  /// já em andamento), sem duplicar a lógica do tick.
  void _iniciarTimerVisual() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // Guarda defensiva extra: se por qualquer motivo esta referência de
      // Timer não for mais a atual (ex: foi substituída por um cancel +
      // novo Timer entre um tick e outro), interrompe imediatamente esta
      // instância "fantasma" em vez de continuar decrementando o estado.
      if (!identical(timer, _timer)) {
        timer.cancel();
        return;
      }

      if (_segundosRestantes > 0) {
        setState(() {
          _segundosRestantes--;
        });
      } else {
        // Reespecificação do usuário (2026-08-10, Parte 3): o tempo
        // chegou ao fim — a partir daqui, quem conduz o fluxo real é a
        // tela dedicada [CronometroDisparadoScreen], aberta pelo alarme
        // NATIVO agendado em [AlarmeService.agendarAlarmeEmergencia] para
        // este MESMO instante (som + teclado de PIN com 60 segundos de
        // tolerância, 3 tentativas). Este Timer visual só encerra a
        // contagem local — NUNCA MAIS dispara o alerta diretamente (antes
        // disparava aqui, sem nenhuma chance de PIN).
        _finalizarTimerLocalAoZerar();
      }
    });
  }

  /// Encerra apenas o Timer visual e o loop LOCAL de localização desta
  /// tela (par do `iniciarCicloDeAtualizacao()` feito em [_iniciarTimer])
  /// quando o cronômetro chega a zero — a partir daqui,
  /// [CronometroDisparadoScreen] assume seu PRÓPRIO par
  /// iniciar/parar de rastreamento pela duração da janela de 60s.
  /// Propositalmente NÃO chama [_pararTimer]/[BackgroundLocationHeartbeatService.cancelarCheckinAtivo]:
  /// o heartbeat de nuvem (dead man's switch) e o alarme nativo continuam
  /// intactos até o fluxo ser realmente resolvido (PIN correto ou alerta
  /// disparado), dentro da nova tela.
  void _finalizarTimerLocalAoZerar() {
    _cancelarTimerPrincipal();
    _fecharDialogoPinSeAberto();
    _locationService.pararCicloDeAtualizacao();
    if (mounted) {
      setState(() {
        _isTimerAtivo = false;
        _segundosRestantes = 0;
      });
    }
  }

  void _pararTimer() {
    _cancelarTimerPrincipal();

    // CORREÇÃO DE BUG REAL (2026-08-11): [_executarDisparoDeEmergencia]
    // (3ª tentativa de PIN errada NUMA TENTATIVA MANUAL de desarme, ANTES
    // do cronômetro zerar) chama [_pararTimer] mas nunca cancelava o
    // alarme NATIVO agendado em [AlarmeService.agendarAlarmeEmergencia]
    // — o cronômetro "ressuscitava" sozinho no horário original, minutos
    // depois, tocando som e reabrindo o teclado de PIN de novo para um
    // ciclo que já tinha sido resolvido (com o alerta real já enviado).
    // Cancelar aqui é seguro mesmo no caminho de PIN correto
    // ([_aoConfirmarPinCorreto], que já cancela antes de chegar aqui —
    // chamada duplicada é inofensiva) e não enfraquece a regra de
    // segurança original de [AlarmeService.cancelarAlarme] ("só cancela
    // com o PIN correto"): nos dois casos que chegam aqui, o ciclo já
    // está definitivamente resolvido — ou por PIN correto, ou porque o
    // alerta de emergência JÁ foi disparado de verdade — nunca por um
    // simples toque/abertura de tela sem prova de identidade.
    unawaited(_alarmeService.cancelarAlarme());

    // O cronômetro foi parado/desarmado (por qualquer motivo): interrompe
    // o loop de atualização de localização a cada 2 minutos, já que ele
    // só deve rodar enquanto o check-in estiver ativo.
    _locationService.pararCicloDeAtualizacao();
    // Encerra o acompanhamento do dead man's switch na nuvem para este
    // ciclo (ver [BackgroundLocationHeartbeatService.cancelarCheckinAtivo]) —
    // não altera o status já gravado, apenas para de atualizá-lo.
    BackgroundLocationHeartbeatService().cancelarCheckinAtivo();
    // CORREÇÃO DE BUG REAL (2026-08-23): limpa o timestamp de expiração
    // persistido — sem isto, [_restaurarCronometroAtivoSePersistido]
    // poderia "ressuscitar" este ciclo já encerrado como se ainda
    // estivesse ativo, na próxima vez que esta tela for recriada. Ver
    // [DatabaseHelper.limparContextoTimerAtivo].
    unawaited(_db.limparContextoTimerAtivo());

    if (!mounted) return;
    setState(() {
      _isTimerAtivo = false;
      _segundosRestantes = 0;
    });

    // NOTA: o fechamento do diálogo de PIN (Navigator.pop) é tratado
    // explicitamente em cada ponto de chamada específico (dentro do
    // próprio PinDialogContent ao confirmar o PIN, e em
    // [_fecharDialogoPinSeAberto] quando o disparo de emergência
    // acontece) — NUNCA aqui, pois _pararTimer() também é chamado por
    // esses fluxos, onde um pop indevido poderia fechar a rota errada ou
    // falhar silenciosamente.
  }

  /// Chamado pelo [PinDialogContent] quando o PIN correto é digitado
  /// (1ª ou 2ª tentativa). Regra de negócio: cancela o cronômetro
  /// IMEDIATAMENTE e NENHUMA mensagem de alerta é enviada. Cancela o
  /// alarme NATIVO (só agora, com o PIN confirmado), interrompe os
  /// timers/heartbeat locais e registra o desarme no histórico. Envolvido
  /// em try/catch para NUNCA travar o diálogo/UI mesmo em caso de falha.
  Future<void> _aoConfirmarPinCorreto() async {
    try {
      await _alarmeService.cancelarAlarme();
      await _db.limparAguardandoConfirmacaoPin();
      // Avisa a nuvem imediatamente que o check-in foi desarmado com
      // sucesso (ver [BackgroundLocationHeartbeatService.confirmarCheckinSeguro]),
      // antes que o dead man's switch agendado tenha qualquer chance de
      // considerar o prazo vencido.
      BackgroundLocationHeartbeatService().confirmarCheckinSeguro();

      final posicao = _locationService.ultimaPosicao;
      _pararTimer();
      unawaited(HistoricoAlertasService().registrarEvento(
        tipo: TipoAlertaHistorico.cronometroDesarmado,
        posicao: posicao,
      ));
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.segurancaCheckinDesarmado), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('⚠️ Falha ao confirmar PIN/desarmar check-in: $e');
    }
  }

  // Flag simples para garantir que, mesmo diante de eventuais chamadas
  // concorrentes (ex.: o cronômetro chegando a zero E a 3ª tentativa de
  // PIN errada quase ao mesmo tempo), o disparo de emergência ocorra NO
  // MÁXIMO uma única vez por ciclo — nunca em loop, nunca duplicado.
  bool _disparoJaExecutadoNesteCiclo = false;

  /// Ponto ÚNICO de disparo de emergência deste cronômetro — usado tanto
  /// quando o tempo se esgota sem desarme (regra de negócio 3) quanto
  /// quando o PIN é digitado errado pela 3ª vez consecutiva (regra de
  /// negócio 2). Garante (via [_disparoJaExecutadoNesteCiclo]) que o
  /// disparo ocorra apenas UMA vez por ciclo, fecha o diálogo de PIN se
  /// estiver aberto (libera a interface para uso normal) e delega para
  /// [_executarDisparoDeEmergencia] o disparo em si + o aviso na tela.
  Future<void> _dispararUmaVezSeNecessario() async {
    if (_disparoJaExecutadoNesteCiclo) return;
    _disparoJaExecutadoNesteCiclo = true;
    // Idempotente mesmo se o cronômetro já tiver sido cancelado pelo
    // chamador (ex: o próprio Timer.periodic ao chegar a zero) — cobre
    // também o caminho da 3ª tentativa de PIN errada, onde o cronômetro
    // ainda pode estar rodando neste exato instante.
    _cancelarTimerPrincipal();
    _fecharDialogoPinSeAberto();

    // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-08-15, via
    // logcat): mesmo com `cancelarAlarme()` chamado imediatamente (ver
    // comentário abaixo), o alarme NATIVO ainda conseguia disparar
    // depois — `AlarmManager.cancel()` não é garantidamente instantâneo
    // para um alarme já muito próximo/prestes a entregar (limitação real
    // do Android, não deste app) — abrindo [CronometroDisparadoScreen] do
    // ZERO, sem NENHUMA pista de que este ciclo já tinha sido resolvido
    // aqui: nem a trava nativa (só usada por aquela tela) nem
    // [chaveCronometroFluxoResolvido] (só gravada por ela também) eram
    // tocadas neste caminho de desarme MANUAL. Resultado observado ao
    // vivo: um 3º disparo (`[TIMEOUT]`) completo — SMS+Firestore de novo
    // para os mesmos contatos — quando os 60s de tolerância daquela tela
    // se esgotaram sozinhos, minutos depois do desarme manual já
    // resolvido aqui. Reivindicar a MESMA trava nativa E gravar a MESMA
    // flag em disco que [CronometroDisparadoScreen] usa fecha as duas
    // pontas: se a tela abrir mesmo assim, sua própria chamada a
    // `reivindicarDisparoUnicoCronometro()` já encontra a trava tomada
    // (aborta ANTES de qualquer SMS/rede) e, ainda que o polling dela
    // leve até ~1s para reagir, a flag em disco garante que ela se
    // autoencerre em seguida, sem depender só do cancelamento do alarme.
    try {
      await AlarmeService().reivindicarDisparoUnicoCronometro();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(chaveCronometroFluxoResolvido, true);
    } catch (e) {
      debugPrint('⚠️ Falha ao reivindicar trava/gravar flag de fluxo resolvido: $e');
    }

    // CORREÇÃO DE BUG REAL (2026-08-14, disparo duplicado): o alarme
    // NATIVO (AlarmManager, agendado por
    // [AlarmeService.agendarAlarmeEmergencia] para o instante em que o
    // cronômetro original chegaria a zero) e o heartbeat de nuvem
    // (dead man's switch) precisam ser cancelados AQUI, IMEDIATAMENTE —
    // ANTES de [_executarDisparoDeEmergencia], que aguarda rede (GPS, SMS,
    // Firestore, podendo levar vários segundos). Antes, esse cancelamento
    // só acontecia no FINAL de [_executarDisparoDeEmergencia] (via
    // [_pararTimer]), depois de toda aquela espera: se o horário original
    // do cronômetro chegasse ENQUANTO essa espera ainda rodava, o alarme
    // nativo (ainda agendado) disparava por conta própria, abrindo
    // [CronometroDisparadoScreen] com som + teclado de PIN para um ciclo
    // que já tinha sido resolvido (disparo duplicado real reportado pelo
    // usuário). `cancelarAlarme()`/`cancelarCheckinAtivo()` chamados de
    // novo mais tarde (dentro de [_pararTimer]) são inofensivos —
    // idempotentes por natureza.
    unawaited(_alarmeService.cancelarAlarme());
    _locationService.pararCicloDeAtualizacao();

    // CORREÇÃO DE BUG REAL (2026-08-15): antes, chamava só
    // `cancelarCheckinAtivo()` — que só PARA o heartbeat LOCAL de
    // atualizar o documento, sem nunca marcar `alarmes_agendados` como
    // resolvido na nuvem. Como esta 3ª tentativa errada acontece durante
    // um desarme MANUAL (ANTES do cronômetro principal chegar a zero), o
    // `prazoFinalEpochMs` já gravado no Firestore ainda podia estar
    // MINUTOS no futuro (tempo restante do cronômetro + 60s de
    // tolerância) — o documento ficava PENDENTE por até alguns minutos
    // mesmo com o alerta já enviado agora mesmo, e a Cloud Function
    // agendada (`monitorarAlarmesAgendados`, a cada 2 min) disparava um
    // SEGUNDO alerta duplicado quando esse prazo antigo vencia (sintoma
    // real relatado: 2 a 6 minutos depois). `confirmarAlertaJaDisparado`
    // grava ALERTA_DISPARADO no Firestore (tirando o documento da
    // consulta da function) E chama `cancelarCheckinAtivo()`
    // internamente — mesmo remédio já usado em
    // `CronometroDisparadoScreen._dispararAlerta` para o disparo
    // acontecendo DEPOIS do cronômetro zerar.
    BackgroundLocationHeartbeatService().confirmarAlertaJaDisparado();

    await _executarDisparoDeEmergencia();
  }

  /// Executa o disparo de emergência COMPLETO — SMS nativo, push/Firestore
  /// para o app receptor (ver [EmergencyAlertService.dispararAlertaTentativaDesarmeIncorreto])
  /// e registro no histórico local — e exibe IMEDIATAMENTE a confirmação
  /// de envio em tela cheia, sem esperar a confirmação de rede do
  /// SMS/nuvem, que roda em paralelo.
  ///
  /// Reespecificação do usuário (2026-08-14): unificado com o MESMO
  /// pipeline e o MESMO componente visual ([ConfirmacaoAlertaEmergencia])
  /// já usados pela 3ª tentativa de PIN errada e pelo timeout de 60s
  /// DENTRO da janela final de tolerância (ver
  /// `cronometro_disparado_screen.dart`) — antes, este método (disparo por
  /// 3ª tentativa de PIN errada durante uma tentativa MANUAL de desarme,
  /// ANTES do cronômetro zerar) usava o alerta genérico
  /// ([EmergencyAlertService.dispararAlertaDeEmergencia]) e um simples
  /// `AlertDialog` de aviso, divergindo do fluxo da janela final.
  ///
  /// Protegido por try/catch para que qualquer falha (GPS, SMS, banco)
  /// jamais trave a interface do usuário ou dispare novamente em loop.
  ///
  /// Regra de negócio 7 (restrições obrigatórias): a CÂMERA nunca é
  /// acionada em nenhum ponto deste fluxo. NOTA (reespecificação do
  /// usuário, 2026-08-10): a restrição original também proibia qualquer
  /// som de alarme — isso foi revertido DE PROPÓSITO, mas só para o novo
  /// fluxo "ao zerar" (ver [CronometroDisparadoScreen], que toca o alarme
  /// e abre o teclado de PIN por até 60s). Este método específico
  /// continua sem tocar nenhum som — regra histórica preservada aqui, não
  /// pedida para mudar.
  Future<void> _executarDisparoDeEmergencia() async {
    final l10n = AppLocalizations.of(context)!;
    _abrirConfirmacaoAlertaEnviado();
    try {
      // Nuvem primeiro (id fixo, status real no Histórico), depois o SMS
      // (só Android) — ver HistoricoAlertasService.dispararAlertaCronometro.
      await HistoricoAlertasService().dispararAlertaCronometro(
        tipo: TipoAlertaHistorico.tentativaDesarmeIncorreto,
        motivo: l10n.historicoCronometroPinIncorretoMotivo,
        contexto: _contextoController.text.trim(),
        posicao: _locationService.ultimaPosicao,
      );
    } catch (e) {
      debugPrint('⚠️ Falha ao executar disparo de emergência: $e');
    }
    _pararTimer();
  }

  /// Abre, em tela cheia, o MESMO componente de confirmação usado por
  /// `cronometro_disparado_screen.dart` (ver [ConfirmacaoAlertaEmergencia])
  /// — ícone e texto em vermelho, nunca aguardando a confirmação de rede
  /// do SMS/nuvem para aparecer. Chamado uma única vez por ciclo, de
  /// dentro de [_executarDisparoDeEmergencia].
  void _abrirConfirmacaoAlertaEnviado() {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConfirmacaoAlertaEmergencia(
          aoFechar: () {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
  }

  // ==========================================================
  // 3ª TENTATIVA DE PIN ERRADA (gatilho de emergência)
  // ==========================================================

  /// Callback passado ao [PinDialogContent] (ver [_abrirDialogoDesarme]),
  /// acionado automaticamente quando o usuário digita o PIN INCORRETO 3
  /// VEZES CONSECUTIVAS durante uma tentativa de desarme. Regra de
  /// negócio: o cronômetro é encerrado IMEDIATAMENTE, o diálogo de PIN é
  /// fechado, o alerta na tela é exibido e o alerta de emergência
  /// completo (Push App-para-App e SMS) é disparado.
  ///
  /// ORDEM CRÍTICA: o alerta prioritário para a nuvem (Firebase) é
  /// disparado e AGUARDADO PRIMEIRO, antes de qualquer outro
  /// processamento local — garantindo que, mesmo que o aparelho seja
  /// destruído/desligado nos segundos seguintes, a nuvem já tenha
  /// recebido o alerta. Só depois disso o disparo completo local é
  /// executado (ver [_dispararUmaVezSeNecessario]).
  ///
  /// Protegido por try/catch em cada etapa para nunca propagar exceção de
  /// volta ao diálogo de PIN.
  Future<void> _aoAtingirTerceiraSenhaErrada() async {
    debugPrint('🚨 [PIN INCORRETO 3x] 3 PINs incorretos consecutivos detectados. '
        'Encerrando o cronômetro e disparando o alerta completo.');

    // CORREÇÃO DE BUG REAL (2026-08-15): esta chamada não informava
    // [motivo], então a notificação Push recebida pelo contato de
    // emergência caía no texto GENÉRICO de `functions/index.js`
    // ("...incorretamente 2 vezes seguidas...") — um texto histórico de
    // antes da unificação para 3 tentativas (ver
    // `PinDialogContent.limiteErrosConsecutivos: 3` acima, em
    // [_abrirDialogoDesarme]), e DIFERENTE do SMS local, que já usa o
    // texto certo ("3 vezes", `l10n.historicoCronometroPinIncorretoMotivo`,
    // ver [_executarDisparoDeEmergencia]). Passar o mesmo motivo aqui
    // também deixa Push e SMS consistentes entre si para o mesmo evento.
    // O envio à nuvem (primeiro, aguardado) e ao Histórico acontece em
    // [_executarDisparoDeEmergencia], uma única vez por ciclo.

    // Reaproveita o mesmo guard de disparo único por ciclo
    // ([_disparoJaExecutadoNesteCiclo]), que também fecha o diálogo de
    // PIN e cancela o cronômetro principal.
    await _dispararUmaVezSeNecessario();
  }

  // ==========================================================
  // BOTÃO DE SOS/PÂNICO MANUAL
  // ==========================================================


  /// Botão SOS da aba Segurança: o envio começa no toque, sem confirmação,
  /// pelo MESMO pipeline do Widget SOS ([SosWidgetFluxoService]) — tela
  /// preta com a localização exata enviada aos contatos, os avisos
  /// "Localização enviada com sucesso"/"Abrindo a câmera", a câmera, a foto
  /// e a tela vermelha. Sem sessão, o fluxo abre a SosSemLoginScreen. A
  /// proteção contra toque duplo fica no fluxo (tela preta já na tela,
  /// deduplicação do disparo e câmera já aberta).
  ///
  /// ÚNICA trava do Plano Free (reespecificação do usuário, 2026-09-04):
  /// fora dos 10 dias ativos, o aviso de sempre aparece e nada é enviado.
  Future<void> _confirmarEDispararSosManual() async {
    if (Platform.isIOS) {
      // A tela preta sobe no toque; a janela do Plano Free é lida em
      // seguida e, se bloqueada, a tela preta sai e o aviso de sempre abre.
      SosWidgetFluxoService().iniciar(
        origemAlerta: SosWidgetFluxoService.origemBotaoApp,
        aoPlanoBloqueado: () async {
          if (mounted) await garantirRecursoLiberadoOuExibirUpsell(context);
        },
      );
      return;
    }
    if (!await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;
    try {
      unawaited(SosDisparoService().executarP1LocalizacaoImediata(origem: 'sos_manual'));
      await CapturaDissuasaoService().abrirCapturaSePermitido(origemUnificada: 'sos_manual');
    } catch (e) {
      debugPrint('⚠️ Falha ao disparar SOS manual: $e');
    }
  }

  String _formatarTempo(int totalSegundos) {
    int horas = totalSegundos ~/ 3600;
    int minutos = (totalSegundos % 3600) ~/ 60;
    int segundos = totalSegundos % 60;
    return "${horas.toString().padLeft(2, '0')}:${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    // Correção do erro de design original: a tela de bloqueio de PIN por
    // inatividade que substituía toda a rota foi removida. A UI normal
    // (com o cronômetro em contagem regressiva) é SEMPRE exibida — o
    // diálogo de PIN, quando necessário, é aberto por cima dela via
    // [exibirDialogoPin] (ver [_abrirDialogoDesarme]), nunca bloqueando a
    // navegação para as demais abas (Família, Histórico) nem a
    // HomeScreen.
    return _buildTelaPrincipal();
  }


  /// Tela de funcionamento normal com plano de fundo dinâmico, sincronizado
  /// em tempo real com a escolha feita em Configurações.
  Widget _buildTelaPrincipal() {
    return Scaffold(
      backgroundColor: Colors.transparent, // Permite que o fundo do Container apareça
      body: ValueListenableBuilder<String>(
        valueListenable: WallpaperService.wallpaperNotifier,
        builder: (context, fundoAtivo, _) {
          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage(fundoAtivo),
                fit: BoxFit.cover,
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildCampoContexto(),
                  const SizedBox(height: 24),
                  Text(
                    AppLocalizations.of(context)!.segurancaTituloSecaoTempo,
                    textAlign: TextAlign.center,
                    softWrap: true,
                    overflow: TextOverflow.clip,
                    style: _estiloTituloSecao,
                  ),
                  const SizedBox(height: 16),
                  _buildSeletoresDeTempo(),
                  const SizedBox(height: 32),
                  _buildBotaoCheckIn(),
                  const SizedBox(height: 24),
                  _buildBotaoSos(),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Card com o campo de texto para anotações/dica de contexto.
  Widget _buildCampoContexto() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: Row(
          children: [
            const Icon(Icons.lightbulb_outline, color: Colors.blue, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _contextoController,
                enabled: !_isTimerAtivo,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context)!.segurancaDicaContextoLabel,
                  hintText: AppLocalizations.of(context)!.segurancaDicaContextoHint,
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Seletores (pickers estilo iOS) de horas e minutos para definir a
  /// duração do timer de check-in.
  Widget _buildSeletoresDeTempo() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Column(
          children: [
            SizedBox(
              height: 130,
              width: 70,
              child: CupertinoPicker(
                itemExtent: 38,
                scrollController: FixedExtentScrollController(initialItem: _horaSelecionada),
                onSelectedItemChanged: (index) => setState(() => _horaSelecionada = index),
                children: List.generate(24, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
              ),
            ),
            Text(
              AppLocalizations.of(context)!.horasLabel,
              softWrap: true,
              overflow: TextOverflow.clip,
              style: _estiloLabelPicker,
            ),
          ],
        ),
        const SizedBox(width: 40),
        Column(
          children: [
            SizedBox(
              height: 130,
              width: 70,
              child: CupertinoPicker(
                itemExtent: 38,
                scrollController: FixedExtentScrollController(initialItem: _minutoSelecionada),
                onSelectedItemChanged: (index) => setState(() => _minutoSelecionada = index),
                children: List.generate(60, (index) => Center(child: Text(index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
              ),
            ),
            Text(
              AppLocalizations.of(context)!.minutosLabel,
              softWrap: true,
              overflow: TextOverflow.clip,
              style: _estiloLabelPicker,
            ),
          ],
        ),
      ],
    );
  }

  /// Botão circular central que inicia/desarma o timer de check-in.
  Widget _buildBotaoCheckIn() {
    return GestureDetector(
      onTap: _alternarTimer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isTimerAtivo ? const Color(0xFFE67E22) : const Color(0xFF4C7040),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_isTimerAtivo ? Icons.timer : Icons.check_circle_outline, color: Colors.white, size: 36),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  _isTimerAtivo ? _formatarTempo(_segundosRestantes) : AppLocalizations.of(context)!.segurancaFazerCheckin,
                  textAlign: TextAlign.center,
                  softWrap: true,
                  overflow: TextOverflow.clip,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: _isTimerAtivo ? 20 : 16, letterSpacing: _isTimerAtivo ? 1.2 : 0),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _isTimerAtivo ? AppLocalizations.of(context)!.segurancaToqueDesarmar : AppLocalizations.of(context)!.segurancaToqueIniciar,
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Botão de SOS/Pânico manual: dispara o alerta de emergência
  /// imediatamente (após confirmação simples via diálogo), reutilizando
  /// o mesmo [EmergencyAlertService.dispararAlertaDeEmergencia] usado
  /// pelo fluxo automático do cronômetro. Complementa (não substitui) o
  /// gatilho físico via botão de Volume+ segurado por 3s, que dispara
  /// sem diálogo (ver VolumeSosService/main.dart).
  Widget _buildBotaoSos() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _confirmarEDispararSosManual,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.red,
          side: const BorderSide(color: Colors.red, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        icon: const Icon(Icons.sos),
        label: Text(
          AppLocalizations.of(context)!.segurancaBotaoPanico,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

}
