import 'dart:async';

import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/pin_hash.dart';

/// Limite de tentativas de PIN de uma área (ex.: a área protegida do
/// Histórico, ver AreaProtegidaHistoricoService): o diálogo consulta se a
/// área está bloqueada, avisa cada erro e cada acerto. Sem controle (o
/// padrão), as tentativas são ilimitadas como sempre — o cronômetro e o
/// despertador dependem disso para disparar o alerta no 3º erro.
abstract class ControleTentativasPin {
  /// Fim do bloqueio em vigor, ou `null`.
  Future<DateTime?> bloqueadoAte();

  /// Registra um erro; devolve o fim do bloqueio se este erro bloqueou.
  Future<DateTime?> registrarErro();

  Future<void> registrarAcerto();
}

/// Diálogo leve (AlertDialog) para confirmação de PIN, exibido POR CIMA
/// da tela atual (sem substituir toda a árvore/rota como a antiga
/// TelaBloqueioPin fazia). Isso elimina os conflitos de ciclo de vida
/// relatados: a navegação (bottom navigation, HomeScreen, FamiliaTab
/// etc.) continua livre e funcionando normalmente por trás do diálogo.
///
/// Uso típico:
/// ```dart
/// await exibirDialogoPin(
///   context: context,
///   pinEsperado: _pinRealConfirmado,
///   aoConfirmarPinCorreto: _aoConfirmarPinCorreto,
/// );
/// ```
///
/// REGRAS DE NEGÓCIO DE SEGURANÇA/DISFARCE (UX) mantidas:
/// - PIN incorreto: exibe apenas "PIN incorreto. Tente novamente.".
/// - PIN correto: aciona [aoConfirmarPinCorreto] e fecha o diálogo
///   silenciosamente.
/// - O diálogo é [barrierDismissible]: false, ou seja, não pode ser
///   fechado tocando fora dele — apenas digitando o PIN correto — mas,
///   diferente da tela cheia antiga, ele NUNCA bloqueia a UI/navegação
///   por trás em caso de erro de ciclo de vida (o app permanece
///   plenamente responsivo).
///
/// PIN DE COAÇÃO (gatilho discreto de emergência): [aoAtingirLimiteDeErros]
/// é um callback OPCIONAL, disparado internamente sempre que o usuário
/// digitar o PIN incorreto [limiteErrosConsecutivos] VEZES CONSECUTIVAS
/// (padrão: 2 — o contador é resetado automaticamente após acionar o
/// callback, e também sempre que o PIN correto for digitado). Chamadores
/// que precisem de um disparo já na PRIMEIRA tentativa errada (ex: a
/// janela final de 60 segundos do alarme de rotina da Família, onde não há
/// mais margem para uma segunda chance) podem passar
/// `limiteErrosConsecutivos: 1`. A interface NUNCA reflete esse gatilho —
/// a mensagem de erro exibida é sempre a mesma ("PIN incorreto. Tente
/// novamente."), independentemente de qual erro consecutivo for,
/// mantendo o disfarce de segurança 100% intacto diante de um possível
/// agressor observando a tela. Toda a lógica real de disparo (chamar o
/// EmergencyAlertService, obter localização, etc.) fica a cargo de quem
/// fornece o callback (ver [SegurancaTab._dispararSosDeCoacao]) — este
/// widget é propositalmente "burro" e não conhece nada sobre
/// GPS/serviços de emergência.
///
/// LIMITE DURO DE TEMPO (opcional): quando [segundosLimiteDuro] é
/// informado, o próprio diálogo passa a exibir uma contagem regressiva
/// AO VIVO (reaproveitando o mesmo texto/estilo âmbar de
/// [segundosTolerancia], porém atualizado a cada segundo via um Timer
/// interno) e, ao chegar a zero SEM que o PIN correto tenha sido
/// digitado, aciona [aoExpirarTempoLimite] uma única vez. O diálogo NUNCA
/// se fecha sozinho por causa disso — continua aberto e funcional,
/// aceitando o PIN correto mesmo depois do tempo esgotado — apenas o
/// callback de expiração é dado como responsável por qualquer ação real
/// (ex: disparar um alerta de emergência). Por ser um limite de
/// SEGURANÇA, o botão/gesto Voltar do sistema Android também fica
/// bloqueado enquanto ele estiver ativo (diferente do comportamento
/// padrão sem [segundosLimiteDuro], onde Voltar fecha o diálogo
/// normalmente — ver `familia_tab.dart`): sem isso, Voltar cancelava o
/// [Timer] interno da contagem (`dispose()`) sem nunca acionar
/// [aoExpirarTempoLimite], deixando o alarme tocando indefinidamente sem
/// jamais disparar o alerta.
Future<void> exibirDialogoPin({
  required BuildContext context,
  required String? pinEsperado,
  required Future<void> Function() aoConfirmarPinCorreto,
  int? segundosTolerancia,
  Future<void> Function()? aoAtingirLimiteDeErros,
  int limiteErrosConsecutivos = 2,
  int? segundosLimiteDuro,
  Future<void> Function()? aoExpirarTempoLimite,
  bool mostrarBotaoCancelar = false,
  VoidCallback? aoCancelar,
  Future<void> Function()? aoDescartarPorArraste,
  String? mensagemSucesso,
  ControleTentativasPin? controleTentativas,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return PinDialogContent(
        pinEsperado: pinEsperado,
        aoConfirmarPinCorreto: aoConfirmarPinCorreto,
        segundosTolerancia: segundosTolerancia,
        aoAtingirLimiteDeErros: aoAtingirLimiteDeErros,
        limiteErrosConsecutivos: limiteErrosConsecutivos,
        segundosLimiteDuro: segundosLimiteDuro,
        aoExpirarTempoLimite: aoExpirarTempoLimite,
        mostrarBotaoCancelar: mostrarBotaoCancelar,
        aoCancelar: aoCancelar,
        aoDescartarPorArraste: aoDescartarPorArraste,
        mensagemSucesso: mensagemSucesso,
        controleTentativas: controleTentativas,
      );
    },
  );
}

class PinDialogContent extends StatefulWidget {
  const PinDialogContent({
    super.key,
    required this.pinEsperado,
    required this.aoConfirmarPinCorreto,
    this.segundosTolerancia,
    this.aoAtingirLimiteDeErros,
    this.limiteErrosConsecutivos = 2,
    this.segundosLimiteDuro,
    this.aoExpirarTempoLimite,
    this.mostrarBotaoCancelar = false,
    this.aoCancelar,
    this.aoDescartarPorArraste,
    this.mensagemSucesso,
    this.controleTentativas,
  });

  /// Valor guardado em `user_config.pin_real`: hash com sal (ver [PinHash])
  /// ou, em instalações ainda não migradas, o PIN em texto puro.
  final String? pinEsperado;

  /// Limite de tentativas da área (ver [ControleTentativasPin]).
  final ControleTentativasPin? controleTentativas;
  final Future<void> Function() aoConfirmarPinCorreto;
  final int? segundosTolerancia;

  /// Callback silencioso, opcional, acionado ao atingir
  /// [limiteErrosConsecutivos] erros consecutivos de PIN. Ver
  /// documentação completa em [exibirDialogoPin].
  final Future<void> Function()? aoAtingirLimiteDeErros;

  /// Quantidade de erros consecutivos necessária para acionar
  /// [aoAtingirLimiteDeErros]. Padrão 2 (mantém o comportamento histórico
  /// de "PIN de coação"); passe 1 para disparos que não podem tolerar
  /// nenhuma tentativa errada (ex: última chance antes de um alerta já
  /// estar prestes a soar de qualquer forma).
  final int limiteErrosConsecutivos;

  /// Duração (em segundos) de um limite DURO de tempo, opcional. Quando
  /// informado, o diálogo exibe uma contagem regressiva ao vivo e aciona
  /// [aoExpirarTempoLimite] uma única vez ao chegar a zero sem o PIN
  /// correto ter sido digitado. Ver documentação completa em
  /// [exibirDialogoPin].
  final int? segundosLimiteDuro;

  /// Callback acionado uma única vez quando [segundosLimiteDuro] chega a
  /// zero sem confirmação. O diálogo permanece aberto normalmente depois
  /// disso.
  final Future<void> Function()? aoExpirarTempoLimite;

  /// Quando `true`, exibe um botão de texto "Cancelar" abaixo do teclado
  /// numérico, permitindo fechar o diálogo sem digitar o PIN. Usado em
  /// fluxos onde a confirmação por PIN é opcional (ex: pausar um alarme
  /// de rotina), diferente do bloqueio de segurança padrão da
  /// SegurancaTab, que nunca deve poder ser cancelado sem o PIN correto.
  final bool mostrarBotaoCancelar;

  /// Callback disparado ao tocar no botão "Cancelar" (visível apenas
  /// quando [mostrarBotaoCancelar] é `true`). O próprio diálogo já se
  /// encarrega de fechar (`Navigator.pop`) antes de chamar este
  /// callback.
  final VoidCallback? aoCancelar;

  /// Callback OPCIONAL, acionado quando o usuário arrasta/joga o próprio
  /// diálogo (teclado de PIN) para cima com velocidade suficiente (mesmo
  /// limiar usado na tela de confirmação do Alarme de Rotina — ver
  /// `alarme_disparado_screen.dart`) — gesto de DESCARTE, distinto do
  /// gesto de sistema "tirar o app dos Recentes". Especificação do
  /// usuário: só o Alarme de Rotina usa isto (`null` em todos os demais
  /// chamadores, inclusive o Cronômetro da Segurança), então por padrão
  /// (`null`) este widget não ganha NENHUM gesto novo — comportamento
  /// 100% preservado para quem não passar este parâmetro. Quando
  /// informado, o próprio diálogo se fecha (`Navigator.pop`) e cancela o
  /// timer do limite duro ANTES de chamar o callback — toda a lógica real
  /// (parar som, devolver a tela ao Android, disparar o alerta) fica a
  /// cargo de quem fornece o callback, igual ao padrão já usado em
  /// [aoAtingirLimiteDeErros]/[aoExpirarTempoLimite].
  final Future<void> Function()? aoDescartarPorArraste;

  /// Mensagem de sucesso exibida no lugar do texto padrão
  /// ([AppLocalizations.pinAlarmeDesligado]) quando o PIN correto é
  /// digitado. OPCIONAL — quando omitido (`null`), mantém o texto padrão
  /// "Alarme desligado" usado historicamente em todos os fluxos de
  /// desarme de alarme/cronômetro. Chamadores cuja ação por trás do PIN
  /// não é desarmar um alarme (ex: [ExcluirContaScreen], que reaproveita
  /// este mesmo teclado para confirmar a exclusão de conta) devem
  /// informar um texto específico ao contexto — sem isso, o usuário via
  /// "Alarme desligado" ao excluir a conta, um feedback incorreto.
  final String? mensagemSucesso;

  @override
  State<PinDialogContent> createState() => _PinDialogContentState();
}


class _PinDialogContentState extends State<PinDialogContent> {
  String _pinDigitado = '';
  String? _mensagemErro;
  bool _verificando = false;

  // Contador de erros consecutivos de PIN, usado exclusivamente para o
  // gatilho silencioso do "PIN de coação"
  // (ver [widget.aoAtingirLimiteDeErros]/[widget.limiteErrosConsecutivos]).
  // É resetado para 0 tanto ao acionar o callback (evitando disparos
  // repetidos a cada N erros subsequentes) quanto ao digitar o PIN
  // correto. NUNCA influencia a mensagem de erro exibida na tela.
  int _errosConsecutivos = 0;

  // Limite duro de tempo (opcional, ver [widget.segundosLimiteDuro]):
  // contagem regressiva ao vivo, atualizada a cada segundo, e flag para
  // garantir que [widget.aoExpirarTempoLimite] só seja acionado UMA vez.
  int? _segundosRestantesLimiteDuro;
  Timer? _timerLimiteDuro;
  bool _limiteDuroJaAcionado = false;

  // Bloqueio por tentativas (ver [widget.controleTentativas]).
  DateTime? _bloqueadoAte;
  Timer? _timerBloqueio;

  bool get _bloqueado => _bloqueadoAte != null && _bloqueadoAte!.isAfter(DateTime.now());

  void _aplicarBloqueio(DateTime? fim) {
    _timerBloqueio?.cancel();
    if (!mounted) return;
    setState(() {
      _bloqueadoAte = fim;
      _pinDigitado = '';
    });
    if (fim == null) return;
    _timerBloqueio = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!_bloqueado) {
        timer.cancel();
        setState(() {
          _bloqueadoAte = null;
          _mensagemErro = null;
        });
        return;
      }
      setState(() {});
    });
  }

  String _textoBloqueio() {
    final restante = _bloqueadoAte!.difference(DateTime.now());
    final minutos = restante.inMinutes;
    final segundos = (restante.inSeconds % 60).toString().padLeft(2, '0');
    return AppLocalizations.of(context)!.pinAreaBloqueada('$minutos:$segundos');
  }

  @override
  void initState() {
    super.initState();
    final controle = widget.controleTentativas;
    if (controle != null) {
      controle.bloqueadoAte().then(_aplicarBloqueio);
    }
    if (widget.segundosLimiteDuro != null) {
      _segundosRestantesLimiteDuro = widget.segundosLimiteDuro;
      _timerLimiteDuro = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final restante = (_segundosRestantesLimiteDuro ?? 1) - 1;
        setState(() {
          _segundosRestantesLimiteDuro = restante;
        });
        if (restante <= 0) {
          timer.cancel();
          _acionarLimiteDuroExpirado();
        }
      });
    }
  }

  @override
  void dispose() {
    _timerLimiteDuro?.cancel();
    _timerBloqueio?.cancel();
    super.dispose();
  }

  /// Aciona [widget.aoExpirarTempoLimite] uma única vez (protegido por
  /// [_limiteDuroJaAcionado] contra chamadas repetidas) quando o limite
  /// duro de tempo chega a zero sem que o PIN correto tenha sido
  /// digitado. O diálogo permanece aberto/funcional normalmente depois
  /// disso — mantém o mesmo princípio de nunca se auto-fechar diante de
  /// uma falha, usado em todo o restante do app.
  Future<void> _acionarLimiteDuroExpirado() async {
    if (_limiteDuroJaAcionado) return;
    _limiteDuroJaAcionado = true;
    if (widget.aoExpirarTempoLimite != null) {
      try {
        await widget.aoExpirarTempoLimite!.call();
      } catch (_) {}
    }
  }

  /// Aciona [widget.aoDescartarPorArraste] (se informado) — ver
  /// documentação completa no parâmetro. Fecha o diálogo e cancela o
  /// timer do limite duro ANTES de chamar o callback, mesmo padrão de
  /// [_acionarLimiteDuroExpirado]/`_verificarPin`. Protegido contra
  /// disparo duplo (ex: o usuário conseguir arrastar de novo antes do
  /// `pop` concluir).
  bool _descarteJaAcionado = false;
  void _descartarPorArraste() {
    if (widget.aoDescartarPorArraste == null || _descarteJaAcionado) return;
    _descarteJaAcionado = true;
    _timerLimiteDuro?.cancel();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    unawaited(widget.aoDescartarPorArraste!.call());
  }

  void _pressionarTecla(String caractere) {
    if (_pinDigitado.length >= 4 || _verificando || _bloqueado) return;
    setState(() {
      _pinDigitado += caractere;
      _mensagemErro = null;
    });

    if (_pinDigitado.length == 4) {
      _verificarPin();
    }
  }

  void _apagarTecla() {
    if (_pinDigitado.isEmpty || _verificando) return;
    setState(() {
      _pinDigitado = _pinDigitado.substring(0, _pinDigitado.length - 1);
      _mensagemErro = null;
    });
  }

  Future<void> _verificarPin() async {
    final pinCorreto = PinHash.verificar(_pinDigitado, widget.pinEsperado);

    if (pinCorreto) {
      _errosConsecutivos = 0;
      _timerLimiteDuro?.cancel();
      await widget.controleTentativas?.registrarAcerto();
      if (!mounted) return;
      setState(() {
        _verificando = true;
        // Altera a mensagem no próprio teclado: usa o texto específico do
        // chamador quando informado, senão cai no padrão "Alarme desligado".
        _mensagemErro = widget.mensagemSucesso ??
            AppLocalizations.of(context)!.pinAlarmeDesligado;
      });

      // Aguarda 1 segundo para o usuário ler o feedback de sucesso antes de sair
      await Future.delayed(const Duration(seconds: 1));

      try {
        await widget.aoConfirmarPinCorreto();
      } catch (_) {}
      
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      return;
    }

    // --- NOVA LÓGICA: Mantém o teclado travado e exibe o aviso em minúsculas ---
    _errosConsecutivos++;

    if (_errosConsecutivos >= widget.limiteErrosConsecutivos &&
        widget.aoAtingirLimiteDeErros != null) {
      _errosConsecutivos = 0;
      try {
        widget.aoAtingirLimiteDeErros!.call();
      } catch (_) {}
    }

    if (mounted) {
      setState(() {
        _mensagemErro = AppLocalizations.of(context)!.pinSenhaIncorreta; // Mensagem atualizada
        _pinDigitado = ''; // Reseta os indicadores de círculos para nova tentativa
      });
    }

    final controle = widget.controleTentativas;
    if (controle != null) {
      final fim = await controle.registrarErro();
      if (fim != null) _aplicarBloqueio(fim);
    }
  }

  @override
  Widget build(BuildContext context) {
    // O valor AO VIVO do limite duro (quando presente) tem prioridade
    // sobre o valor estático de [widget.segundosTolerancia] — não faz
    // sentido os dois coexistirem no mesmo diálogo, e os chamadores atuais
    // só informam um ou outro.
    final int? segundosParaExibir =
        _segundosRestantesLimiteDuro ?? widget.segundosTolerancia;
    final bool exibirContagem = segundosParaExibir != null;

    // CORREÇÃO DE BUG REAL (2026-08-12): o teclado numérico usava um
    // `SizedBox` de tamanho FIXO (260x260), mas o `GridView` de 4 linhas
    // dentro dele (3 colunas, `childAspectRatio: 1.3`) precisa, para uma
    // LARGURA de 260, de ~278 de altura — 18px A MAIS do que a caixa
    // reservava. Resultado: a última linha (dígito "0" + apagar) ficava
    // cortada/sobreposta ao texto de erro vermelho logo acima, em
    // QUALQUER aparelho (não era uma questão de tela pequena — o cálculo
    // já estava incorreto para o valor fixo escolhido). Corrigido
    // calculando a altura do teclado A PARTIR da largura real (nunca o
    // contrário) — sempre exatamente do tamanho que o GridView realmente
    // ocupa, sem sobra nem corte. A LARGURA, por sua vez, agora é
    // responsiva ao tamanho da tela (`MediaQuery`) em vez de um valor
    // fixo, para telas pequenas (compactas) ou grandes (tablets) do
    // Guardião X sempre caberem confortavelmente.
    final Size tamanhoTela = MediaQuery.sizeOf(context);
    const int colunasTeclado = 3;
    const int linhasTeclado = 4;
    const double espacamentoTeclado = 12;
    const double aspectRatioTeclado = 1.3;
    // 75% da largura da tela, nunca menor que 220 (aparelhos bem
    // compactos) nem maior que 300 (tablets — evita um teclado
    // desproporcionalmente gigante).
    final double larguraTeclado =
        (tamanhoTela.width * 0.75).clamp(220.0, 300.0);
    final double larguraCelula = (larguraTeclado -
            espacamentoTeclado * (colunasTeclado - 1)) /
        colunasTeclado;
    final double alturaCelula = larguraCelula / aspectRatioTeclado;
    final double alturaTeclado = alturaCelula * linhasTeclado +
        espacamentoTeclado * (linhasTeclado - 1);

    final Widget dialogo = Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        // Teto de altura total do diálogo (85% da tela): em telas muito
        // baixas (aparelhos pequenos, modo split-screen, fonte do
        // sistema aumentada) o conteúdo agora ROLA em vez de estourar/
        // cortar — ver `SingleChildScrollView` logo abaixo.
        constraints: BoxConstraints(maxHeight: tamanhoTela.height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            const Icon(Icons.lock_outline, color: Colors.white70, size: 40),
            const SizedBox(height: 10),
            Text(
              AppLocalizations.of(context)!.pinConfirmeSeuPin,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                exibirContagem
                    ? AppLocalizations.of(context)!.pinDigiteParaDesarmar
                    : AppLocalizations.of(context)!.pinDigiteParaContinuar,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            if (exibirContagem) ...[
              const SizedBox(height: 6),
              Text(
                AppLocalizations.of(context)!
                    .pinTempoTolerancia(segundosParaExibir.clamp(0, 1 << 30)),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
            const SizedBox(height: 16),
            _buildIndicadoresPIN(),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 18),
              child: (_bloqueado || _mensagemErro != null)
                  ? Text(
                      _bloqueado ? _textoBloqueio() : _mensagemErro!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 8),
            _buildTecladoPIN(largura: larguraTeclado, altura: alturaTeclado),
            if (widget.mostrarBotaoCancelar) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _verificando
                    ? null
                    : () {
                        if (Navigator.of(context).canPop()) {
                          Navigator.of(context).pop();
                        }
                        widget.aoCancelar?.call();
                      },
                child: Text(
                  AppLocalizations.of(context)!.cancelar,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );

    // Gesto de descarte (arrastar para cima) — só anexado quando o
    // chamador informa [widget.aoDescartarPorArraste] (opt-in, ver
    // documentação do parâmetro); nos demais casos o diálogo continua
    // exatamente como antes, sem nenhum GestureDetector extra. Mesmo
    // limiar de velocidade já validado na tela de confirmação do Alarme
    // de Rotina (`alarme_disparado_screen.dart`).
    final Widget resultado = widget.aoDescartarPorArraste == null
        ? dialogo
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (details) {
              if (details.velocity.pixelsPerSecond.dy < -250) {
                _descartarPorArraste();
              }
            },
            child: dialogo,
          );

    // CORREÇÃO (bug real reportado 2026-08-11): quando há um limite DURO
    // de tempo ([widget.segundosLimiteDuro] != null — Cronômetro
    // Regressivo e fase final do Alarme de Rotina), o botão/gesto de
    // VOLTAR do sistema Android conseguia fechar este diálogo mesmo com
    // `barrierDismissible: false` (que só bloqueia toque FORA do
    // diálogo, nunca o botão/gesto Voltar). Como o `dispose()` deste
    // State cancela [_timerLimiteDuro] junto, isso apagava silenciosamente
    // a contagem regressiva de segurança: o app só reagia tocando o som
    // de novo (ver `CronometroDisparadoScreen._abrirTecladoPin`), sem
    // jamais dispatar o alerta de emergência, persistir o histórico ou
    // exibir a confirmação de envio — o cronômetro de 60s simplesmente
    // travava tocando som para sempre. Bloquear o Voltar do sistema
    // exclusivamente quando existe esse limite duro fecha a brecha sem
    // afetar os demais chamadores (ex: `FamiliaTab`/`SegurancaTab`, que
    // não usam [segundosLimiteDuro] e continuam permitindo Voltar como
    // cancelamento, documentado em `familia_tab.dart`), nem os fechamentos
    // programáticos já existentes (PIN correto, alerta já disparado,
    // gesto de arraste) — todos usam `Navigator.pop()` diretamente, que
    // [PopScope] com `canPop: false` NUNCA intercepta.
    if (widget.segundosLimiteDuro == null) return resultado;

    return PopScope(
      canPop: false,
      child: resultado,
    );
  }


  Widget _buildIndicadoresPIN() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        bool preenchido = index < _pinDigitado.length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: preenchido ? Colors.redAccent : Colors.white24,
            border: Border.all(color: Colors.white54),
          ),
        );
      }),
    );
  }

  /// [largura]/[altura] agora vêm sempre calculados por [build] a partir
  /// do tamanho real da tela (ver comentário lá) — nunca mais um valor
  /// fixo — garantindo que a última linha do teclado (dígito "0" +
  /// apagar) nunca seja cortada, em nenhum aparelho/modelo de tela onde
  /// o Guardião X esteja instalado.
  Widget _buildTecladoPIN({required double largura, required double altura}) {
    return SizedBox(
      width: largura,
      height: altura,
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.3,
        ),
        itemCount: 12,
        itemBuilder: (context, index) {
          if (index == 9) return const SizedBox.shrink();
          if (index == 11) {
            return IconButton(
              icon: const Icon(Icons.backspace_outlined,
                  color: Colors.white70, size: 24),
              onPressed: _verificando ? null : _apagarTecla,
            );
          }
          String numero = index == 10 ? '0' : (index + 1).toString();
          return ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.08),
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              elevation: 0,
            ),
            onPressed: _verificando ? null : () => _pressionarTecla(numero),
            child: Text(numero,
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold)),
          );
        },
      ),
    );
  }
}
