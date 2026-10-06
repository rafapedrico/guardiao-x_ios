import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/historico_alertas_service.dart';

/// Rótulo e cor do status de envio de um alerta do Histórico.
class StatusAlertaVisual {
  const StatusAlertaVisual(this.rotulo, this.cor, this.icone);
  final String rotulo;
  final Color cor;
  final IconData icone;

  /// `null` para eventos sem envio (cronômetro ativado/desarmado).
  static StatusAlertaVisual? de(AppLocalizations l10n, String? status) {
    switch (status) {
      case StatusAlertaHistorico.enviando:
        return StatusAlertaVisual(l10n.historicoStatusEnviando, Colors.blueGrey, Icons.schedule_send);
      case StatusAlertaHistorico.enviado:
        return StatusAlertaVisual(l10n.historicoStatusEnviado, Colors.green.shade700, Icons.check_circle);
      case StatusAlertaHistorico.pendente:
        return StatusAlertaVisual(l10n.historicoStatusPendente, Colors.orange.shade800, Icons.cloud_off);
      case StatusAlertaHistorico.falhou:
        return StatusAlertaVisual(l10n.historicoStatusFalhou, Colors.red.shade700, Icons.error_outline);
      default:
        return null;
    }
  }
}

/// Detalhe de um alerta enviado (área protegida do Histórico): data e hora,
/// status do envio, miniatura da foto (cópia local; sem ela, o `foto_url`),
/// localização com a precisão e "Ver no mapa" (Apple Maps), e o texto
/// personalizado quando houver.
class DetalheAlertaEnviadoScreen extends StatelessWidget {
  const DetalheAlertaEnviadoScreen({super.key, required this.evento});

  /// Linha da tabela `historico`.
  final Map<String, dynamic> evento;

  double? get _latitude => (evento['latitude'] as num?)?.toDouble();
  double? get _longitude => (evento['longitude'] as num?)?.toDouble();
  double? get _precisao => (evento['precisao'] as num?)?.toDouble();

  Future<void> _abrirMapa() async {
    final lat = _latitude;
    final lng = _longitude;
    if (lat == null || lng == null) return;
    final uri = Uri.parse('https://maps.apple.com/?ll=$lat,$lng&q=$lat,$lng');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('⚠️ [DetalheAlerta] Falha ao abrir o Apple Maps: $e');
    }
  }

  Widget _foto(BuildContext context, AppLocalizations l10n) {
    final local = evento['foto_local'] as String?;
    final url = evento['foto_url'] as String?;
    Widget? imagem;
    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      imagem = Image.file(File(local), fit: BoxFit.cover);
    } else if (url != null && url.isNotEmpty) {
      imagem = Image.network(
        url,
        fit: BoxFit.cover,
        loadingBuilder: (context, filho, progresso) =>
            progresso == null ? filho : const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, __, ___) => Center(child: Text(l10n.historicoDetalheFotoIndisponivel)),
      );
    }
    if (imagem == null) {
      return Text(l10n.historicoDetalheSemFoto, style: TextStyle(color: Colors.grey.shade700));
    }
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
          body: InteractiveViewer(child: Center(child: imagem)),
        ),
      )),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(height: 220, width: double.infinity, child: imagem),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tipo = evento['tipo'] as String?;
    final titulo = tipo != null
        ? HistoricoAlertasService.tituloDoTipo(l10n, tipo)
        : (evento['titulo'] as String? ?? '');
    final dataHora = DateTime.tryParse(evento['timestamp'] as String? ?? '');
    final locale = Localizations.localeOf(context).toString();
    final status = StatusAlertaVisual.de(l10n, evento['status'] as String?);
    final contexto = (evento['contexto'] as String?)?.trim();
    final lat = _latitude;
    final lng = _longitude;
    final precisao = _precisao;

    Widget secao(String rotulo, Widget conteudo) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(rotulo,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: Colors.grey.shade600, letterSpacing: 0.5)),
              const SizedBox(height: 6),
              conteudo,
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.historicoDetalheTitulo)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(titulo, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          secao(
            l10n.historicoDetalheDataHora,
            Text(
              dataHora == null ? '—' : DateFormat.yMd(locale).add_Hms().format(dataHora.toLocal()),
              style: const TextStyle(fontSize: 16),
            ),
          ),
          if (status != null)
            secao(
              l10n.historicoDetalheStatus,
              Row(children: [
                Icon(status.icone, color: status.cor, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(status.rotulo, style: TextStyle(fontSize: 16, color: status.cor))),
              ]),
            ),
          if (!TipoAlertaHistorico.semEnvio.contains(tipo))
            secao(l10n.historicoDetalheFoto, _foto(context, l10n)),
          secao(
            l10n.historicoDetalheLocalizacao,
            lat == null || lng == null
                ? Text(l10n.historicoDetalheSemLocalizacao, style: TextStyle(color: Colors.grey.shade700))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText('${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                          style: const TextStyle(fontSize: 16)),
                      if (precisao != null)
                        Text(l10n.historicoDetalhePrecisao(precisao.round()),
                            style: TextStyle(color: Colors.grey.shade700)),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: _abrirMapa,
                        icon: const Icon(Icons.map_outlined),
                        label: Text(l10n.historicoDetalheVerNoMapa),
                      ),
                    ],
                  ),
          ),
          if (contexto != null && contexto.isNotEmpty)
            secao(l10n.historicoDetalheTexto, Text(contexto, style: const TextStyle(fontSize: 15))),
        ],
      ),
    );
  }
}
