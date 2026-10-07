import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../models/alarme_agendado_model.dart';
import '../models/alarme_rotina.dart';
import '../services/alarme_agendado_cloud_service.dart';
import '../services/bloqueio_app_service.dart';
import '../services/ciclo_despertador.dart';
import '../services/database_helper.dart';
import '../services/despertador_ios_service.dart';
import '../services/historico_alertas_service.dart';
import '../services/l10n_headless_service.dart';
import '../services/location_service.dart';
import '../services/notificacao_service.dart';
import '../services/rotina_alarme_service.dart';
import '../widgets/pin_dialog.dart';

/// Tela do despertador de check-in no iOS (ver [DespertadorIosService]):
///   - toca o som escolhido em Configurações em loop (mesmo no silencioso)
///     até o PIN correto ou o fim da tolerância;
///   - "Desligar despertador" abre o teclado do PIN (direto, quando a tela
///     foi aberta pelo botão do alarme/notificação);
///   - PIN correto: confirma a ocorrência na nuvem (CONFIRMADO_SEGURA, nenhum
///     alerta), registra no Histórico, avisa "Despertador desativado
///     (pausado)" e volta ao app;
///   - 3 PINs errados: o teclado fecha na hora, o alerta sai aos contatos e
///     uma notificação confirma o envio;
///   - fim da tolerância sem PIN: o próprio app envia o alerta (sem janela
///     extra); o servidor é só a reserva.
class DespertadorIosScreen extends StatefulWidget {
  const DespertadorIosScreen({
    super.key,
    required this.idAlarme,
    required this.ciclo,
    this.tecladoDireto = false,
  });

  final int idAlarme;
  final int ciclo;
  final bool tecladoDireto;

  /// Uma tela de despertador por vez.
  static bool aberta = false;

  @override
  State<DespertadorIosScreen> createState() => _DespertadorIosScreenState();
}

class _DespertadorIosScreenState extends State<DespertadorIosScreen>
    with LiberaBloqueioEnquantoAberta<DespertadorIosScreen> {
  final AudioPlayer _player = AudioPlayer();
  Map<String, dynamic>? _alarme;
  OcorrenciaDespertador? _ocorrencia;
  Timer? _timerTolerancia;
  Timer? _timerRelogio;
  bool _dialogoAberto = false;
  bool _encerrado = false;
  bool _alertaEnviado = false;

  @override
  void initState() {
    super.initState();
    DespertadorIosScreen.aberta = true;
    LocationService().iniciarCicloDeAtualizacao();
    unawaited(_iniciar());
  }

  @override
  void dispose() {
    DespertadorIosScreen.aberta = false;
    _timerTolerancia?.cancel();
    _timerRelogio?.cancel();
    LocationService().pararCicloDeAtualizacao();
    _player.dispose();
    super.dispose();
  }

  Future<void> _iniciar() async {
    final dados = await DatabaseHelper().buscarAlarmePorId(widget.idAlarme);
    if (!mounted) return;
    if (dados == null) {
      _sair();
      return;
    }
    final ocorrencia = CicloDespertador.ocorrenciaDoCiclo(dados, widget.ciclo);
    setState(() {
      _alarme = dados;
      _ocorrencia = ocorrencia;
    });
    // Ocorrência que tocou (o AlarmeDisparadoScreen e o eventoId usam).
    unawaited(DatabaseHelper().marcarUltimoDisparo(widget.idAlarme, widget.ciclo));
    unawaited(DespertadorIosService().pararAlarmeDoSistema(widget.idAlarme, widget.ciclo));

    final restante = ocorrencia.fimTolerancia.difference(DateTime.now());
    if (restante <= Duration.zero) {
      await _aoEsgotarTolerancia();
      return;
    }
    _timerTolerancia = Timer(restante, _aoEsgotarTolerancia);
    _timerRelogio = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(_tocarSom());
    if (widget.tecladoDireto) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _abrirTecladoPin());
    }
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
      debugPrint('⚠️ [DespertadorIos] Falha ao tocar o som: $e');
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
      mensagemSucesso: l10n.despertadorDesativadoTitulo,
      aoConfirmarPinCorreto: _aoConfirmarPin,
      aoAtingirLimiteDeErros: () async {
        // O teclado fecha na hora; o alerta segue em segundo plano.
        if (_dialogoAberto && mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        _dialogoAberto = false;
        await _enviarAlerta(TipoAlertaHistorico.despertadorPinIncorreto);
      },
    );
    _dialogoAberto = false;
  }

  Future<void> _aoConfirmarPin() async {
    if (_encerrado) return;
    _encerrado = true;
    _timerTolerancia?.cancel();
    await _pararSom();
    try {
      await RotinaAlarmeService.confirmarCheckinRotina(widget.idAlarme, cicloEpochMs: widget.ciclo);
    } catch (e) {
      debugPrint('⚠️ [DespertadorIos] Falha ao confirmar o check-in: $e');
    }
    final l10n = await _l10n();
    await NotificacaoService.exibirAvisoDespertador(
      id: 1999999991,
      titulo: l10n.despertadorDesativadoTitulo,
      corpo: l10n.despertadorDesativadoCorpo(_etiqueta(l10n)),
    );
    // Fecha o teclado (o próprio diálogo se fecha depois deste callback).
    WidgetsBinding.instance.addPostFrameCallback((_) => _sair());
  }

  Future<void> _aoEsgotarTolerancia() async {
    if (_encerrado) return;
    if (_dialogoAberto && mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      _dialogoAberto = false;
    }
    // Se a nuvem já resolveu esta ocorrência (o servidor alertou ou outro
    // caminho confirmou), não manda de novo.
    final status = await AlarmeAgendadoCloudService()
        .statusDaOcorrencia(widget.idAlarme.toString(), widget.ciclo);
    if (status == AlarmeAgendadoStatus.confirmadoSeguro) {
      _encerrado = true;
      await _pararSom();
      await DespertadorIosService().resolverOcorrencia(widget.idAlarme, widget.ciclo);
      _sair();
      return;
    }
    if (status == AlarmeAgendadoStatus.alertaDisparado) {
      _encerrado = true;
      await _pararSom();
      await DespertadorIosService().resolverOcorrencia(widget.idAlarme, widget.ciclo);
      if (mounted) setState(() => _alertaEnviado = true);
      return;
    }
    await _enviarAlerta(TipoAlertaHistorico.despertadorExpirado);
  }

  Future<void> _enviarAlerta(String tipo) async {
    if (_encerrado) return;
    _encerrado = true;
    _timerTolerancia?.cancel();
    await _pararSom();
    final ocorrencia = _ocorrencia ??
        CicloDespertador.ocorrenciaDoCiclo(_alarme ?? {'id': widget.idAlarme}, widget.ciclo);
    final l10n = await _l10n();
    final etiqueta = _etiqueta(l10n);
    final motivo = tipo == TipoAlertaHistorico.despertadorPinIncorreto
        ? l10n.historicoCheckinRotinaPinIncorretoMotivo(etiqueta)
        : l10n.historicoCheckinRotinaFalhaMotivo(etiqueta);

    // Ciclo resolvido localmente e na nuvem ANTES do envio: o servidor não
    // manda um segundo alerta por esta ocorrência.
    await CicloDespertador.marcarResolvido(widget.idAlarme, widget.ciclo);
    await AlarmeAgendadoCloudService().marcarAlertaDisparado(
      widget.idAlarme.toString(),
      cicloEpochMs: widget.ciclo,
      eventoId: ocorrencia.eventoId,
    );
    AlarmeAgendadoCloudService().sinalizarNovoCiclo(widget.idAlarme.toString());
    if (mounted) setState(() => _alertaEnviado = true);

    await HistoricoAlertasService().dispararAlertaCronometro(
      tipo: tipo,
      motivo: motivo,
      posicao: LocationService().ultimaPosicao,
      eventoId: ocorrencia.eventoId,
    );
    await NotificacaoService.exibirAvisoDespertador(
      id: 1999999992,
      titulo: l10n.despertadorAlertaEnviadoTitulo,
      corpo: l10n.despertadorAlertaEnviadoCorpo,
    );
    await DespertadorIosService().resolverOcorrencia(widget.idAlarme, widget.ciclo);
  }

  Future<AppLocalizations> _l10n() async {
    if (mounted) {
      final l10n = AppLocalizations.of(context);
      if (l10n != null) return l10n;
    }
    return L10nHeadlessService.obter();
  }

  String _etiqueta(AppLocalizations l10n) =>
      _alarme == null ? l10n.familiaEtiquetaPadrao : AlarmeRotina.fromMap(_alarme!).etiquetaExibida(l10n);

  /// Volta ao app (no iOS um app não pode se fechar sozinho).
  void _sair() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  String _restante() {
    final o = _ocorrencia;
    if (o == null) return '';
    final r = o.fimTolerancia.difference(DateTime.now());
    if (r.isNegative) return '00:00';
    return '${r.inMinutes.toString().padLeft(2, '0')}:${(r.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = _ocorrencia;
    return PopScope(
      canPop: _alertaEnviado,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Icon(
                  _alertaEnviado ? Icons.check_circle_rounded : Icons.alarm_on_rounded,
                  color: _alertaEnviado ? Colors.greenAccent : Colors.white70,
                  size: 110,
                ),
                const SizedBox(height: 24),
                if (o != null)
                  Text(
                    '${o.horario.hour.toString().padLeft(2, '0')}:${o.horario.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Colors.white, fontSize: 56, fontWeight: FontWeight.w300),
                  ),
                Text(
                  _etiqueta(l10n),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 18),
                ),
                const SizedBox(height: 24),
                Text(
                  _alertaEnviado
                      ? l10n.despertadorAlertaEnviadoCorpo
                      : l10n.despertadorTelaInstrucao(_restante()),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _alertaEnviado ? Colors.greenAccent : Colors.redAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: _alertaEnviado
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
                            backgroundColor: Colors.blue.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                          ),
                          onPressed: _encerrado ? null : _abrirTecladoPin,
                          icon: const Icon(Icons.alarm_off, size: 26),
                          label: Text(l10n.desligarAlarmeBotao,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
