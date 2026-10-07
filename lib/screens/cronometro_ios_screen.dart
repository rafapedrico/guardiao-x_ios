import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/bloqueio_app_service.dart';
import '../services/cronometro_ios_service.dart';
import '../services/database_helper.dart';
import '../widgets/pin_dialog.dart';

/// Fim do Cronômetro Regressivo no iOS (ver [CronometroIosService]): o som
/// escolhido em loop (mesmo no silencioso) até o PIN correto ou o fim da
/// tolerância de 60 s, com o teclado do PIN (direto quando a tela foi aberta
/// por "Desligar alerta de emergência").
///   - PIN correto: "Senha correta. O alerta de emergência não foi enviado."
///     e volta ao app;
///   - 3 PINs errados: o teclado fecha na hora, o alerta sai e uma
///     notificação confirma;
///   - fim da tolerância: o app envia `cronometro_expirado`.
class CronometroIosScreen extends StatefulWidget {
  const CronometroIosScreen({super.key, required this.fimEpochMs, this.tecladoDireto = false});

  final int fimEpochMs;
  final bool tecladoDireto;

  /// Uma tela por vez.
  static bool aberta = false;

  @override
  State<CronometroIosScreen> createState() => _CronometroIosScreenState();
}

class _CronometroIosScreenState extends State<CronometroIosScreen>
    with LiberaBloqueioEnquantoAberta<CronometroIosScreen> {
  final AudioPlayer _player = AudioPlayer();
  Timer? _timerRelogio;
  bool _dialogoAberto = false;
  bool _encerrado = false;
  String? _mensagemFinal;

  DateTime get _prazo =>
      DateTime.fromMillisecondsSinceEpoch(widget.fimEpochMs).add(CronometroIosService.tolerancia);

  @override
  void initState() {
    super.initState();
    CronometroIosScreen.aberta = true;
    CronometroIosService().ciclosEncerrados.addListener(_aoEncerrarCiclo);
    _timerRelogio = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_encerrado && DateTime.now().isAfter(_prazo)) {
        unawaited(_aoEsgotar());
      }
      setState(() {});
    });
    unawaited(_tocarSom());
    if (widget.tecladoDireto) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _abrirTecladoPin());
    }
  }

  @override
  void dispose() {
    CronometroIosScreen.aberta = false;
    CronometroIosService().ciclosEncerrados.removeListener(_aoEncerrarCiclo);
    _timerRelogio?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// O ciclo terminou por outro caminho (ex.: alerta enviado pelo timer do
  /// serviço): para o som e mostra o resultado.
  void _aoEncerrarCiclo() {
    if (_encerrado) return;
    _encerrado = true;
    unawaited(_pararSom());
    if (_dialogoAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoAberto = false;
    }
    if (mounted) setState(() => _mensagemFinal = AppLocalizations.of(context)!.notifCronometroExpiradoCorpo);
  }

  Future<void> _tocarSom() async {
    try {
      final config = await DatabaseHelper().getUserConfig();
      final numero = config?['som_alarme_selecionado'] as int? ?? 1;
      await _player.setAudioContext(AudioContext(
        iOS: AudioContextIOS(category: AVAudioSessionCategory.playback, options: const {}),
      ));
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(1.0);
      await _player.play(AssetSource('sounds/som_$numero.mp3'));
    } catch (e) {
      debugPrint('⚠️ [CronometroIos] Falha ao tocar o som: $e');
    }
  }

  Future<void> _pararSom() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  Future<void> _abrirTecladoPin() async {
    if (_dialogoAberto || _encerrado || !mounted) return;
    final config = await DatabaseHelper().getUserConfig();
    final pin = config?['pin_real'] as String?;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    _dialogoAberto = true;
    await exibirDialogoPin(
      context: context,
      pinEsperado: pin,
      limiteErrosConsecutivos: 3,
      mostrarBotaoCancelar: true,
      mensagemSucesso: l10n.notifPinCorretoCronometroCorpo,
      aoConfirmarPinCorreto: () async {
        if (_encerrado) return;
        _encerrado = true;
        await _pararSom();
        await CronometroIosService().confirmarPinCorreto(widget.fimEpochMs);
        WidgetsBinding.instance.addPostFrameCallback((_) => _sair());
      },
      aoAtingirLimiteDeErros: () async {
        // O teclado fecha na hora; o alerta segue.
        if (_dialogoAberto && mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        _dialogoAberto = false;
        if (_encerrado) return;
        _encerrado = true;
        await _pararSom();
        if (mounted) setState(() => _mensagemFinal = l10n.notif3PinsCronometroCorpo);
        await CronometroIosService().enviarAlertaPinIncorreto(widget.fimEpochMs);
      },
    );
    _dialogoAberto = false;
  }

  Future<void> _aoEsgotar() async {
    if (_encerrado) return;
    _encerrado = true;
    if (_dialogoAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoAberto = false;
    }
    await _pararSom();
    if (mounted) setState(() => _mensagemFinal = AppLocalizations.of(context)!.notifCronometroExpiradoCorpo);
    await CronometroIosService().enviarAlertaTempoEsgotado(widget.fimEpochMs);
  }

  void _sair() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  String _restante() {
    final r = _prazo.difference(DateTime.now());
    if (r.isNegative) return '00:00';
    return '${r.inMinutes.toString().padLeft(2, '0')}:${(r.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final terminou = _mensagemFinal != null;
    return PopScope(
      canPop: terminou,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Icon(
                  terminou ? Icons.check_circle_rounded : Icons.security_rounded,
                  color: terminou ? Colors.greenAccent : Colors.redAccent,
                  size: 110,
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.cronometroNotificacaoTituloAlerta,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  _mensagemFinal ?? l10n.cronometroTelaInstrucao(_restante()),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: terminou ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: terminou
                      ? OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.greenAccent,
                            side: const BorderSide(color: Colors.greenAccent),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                          ),
                          onPressed: _sair,
                          child: Text(l10n.fecharConfirmacaoBotao,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                        )
                      : ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                          ),
                          onPressed: _encerrado ? null : _abrirTecladoPin,
                          icon: const Icon(Icons.lock_open, size: 26),
                          label: Text(l10n.cronometroAcaoDesligar,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
