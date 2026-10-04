import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/diagnostico_service.dart';
import 'diagnostico_localizacao_screen.dart';

/// Mostra e permite copiar os últimos erros/avisos registrados por
/// [DiagnosticoService]. Aberta por Configurações > Diagnóstico e também
/// por 5 toques no cadeado da tela de bloqueio (que tem Navigator próprio
/// — continua acessível mesmo se a navegação principal falhar).
class DiagnosticoScreen extends StatelessWidget {
  const DiagnosticoScreen({super.key});

  Future<void> _copiar(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await Clipboard.setData(ClipboardData(text: DiagnosticoService().textoParaCopiar()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.diagnosticoCopiado)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.diagnosticoTitulo),
        actions: [
          IconButton(
            tooltip: l10n.rcDiagTitulo,
            icon: const Icon(Icons.share_location_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DiagnosticoLocalizacaoScreen()),
            ),
          ),
          IconButton(
            tooltip: l10n.diagnosticoLimpar,
            icon: const Icon(Icons.delete_outline),
            onPressed: DiagnosticoService().limpar,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _copiar(context),
        icon: const Icon(Icons.copy),
        label: Text(l10n.diagnosticoCopiar),
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: DiagnosticoService().versao,
        builder: (context, _, __) {
          final registros = DiagnosticoService().registros;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text(l10n.diagnosticoExplicacao, style: const TextStyle(fontSize: 13.5)),
              const SizedBox(height: 16),
              if (registros.isEmpty)
                Text(l10n.diagnosticoVazio, style: const TextStyle(color: Colors.black54))
              else
                SelectableText(
                  registros.join('\n\n'),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                ),
            ],
          );
        },
      ),
    );
  }
}
