import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:intl/intl.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/rastreamento_continuo_service.dart';

/// Diagnóstico → Localização: os últimos eventos do rastreamento contínuo
/// nativo (horário, origem — cerca, visit, significativa, rajada,
/// movimento, pedido…, tipo de atividade, se gravou e por quê), para
/// validar em campo. Mais recentes primeiro.
class DiagnosticoLocalizacaoScreen extends StatefulWidget {
  const DiagnosticoLocalizacaoScreen({super.key});

  @override
  State<DiagnosticoLocalizacaoScreen> createState() => _DiagnosticoLocalizacaoScreenState();
}

class _DiagnosticoLocalizacaoScreenState extends State<DiagnosticoLocalizacaoScreen> {
  List<Map<dynamic, dynamic>> _eventos = const [];
  EstadoRastreamento? _estado;
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final servico = RastreamentoContinuoService();
    final eventos = await servico.eventos();
    final estado = await servico.atualizarEstado();
    if (!mounted) return;
    setState(() {
      _eventos = eventos;
      _estado = estado;
      _carregando = false;
    });
  }

  String _linha(Map<dynamic, dynamic> e) {
    final ts = (e['ts'] as num?)?.toInt() ?? 0;
    final hora = DateFormat('dd/MM HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(ts));
    final lat = (e['latitude'] as num?)?.toStringAsFixed(5);
    final lng = (e['longitude'] as num?)?.toStringAsFixed(5);
    final precisao = (e['precisao'] as num?)?.round();
    return [
      '$hora  ${e['origem']}${e['atividade'] != null ? ' · ${e['atividade']}' : ''}',
      '${e['gravou'] == true ? '✅' : '—'} ${e['motivo']}',
      if (lat != null) '$lat, $lng${precisao != null ? ' (±$precisao m)' : ''}',
    ].join('\n');
  }

  String _resumoEstado() {
    final e = _estado;
    if (e == null) return '';
    return 'permissão=${e.permissao} · movimento=${e.movimento} · 2º plano=${e.atualizacaoSegundoPlano}'
        ' · exata=${e.precisaoExata} · poucaEnergia=${e.modoPoucaEnergia}'
        ' · ativo=${e.rastreamentoAtivo}${e.motivoInativo != null ? ' (${e.motivoInativo})' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final texto = [_resumoEstado(), ..._eventos.map(_linha)].join('\n\n');
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.rcDiagTitulo),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _carregar),
          IconButton(
            tooltip: l10n.diagnosticoCopiar,
            icon: const Icon(Icons.copy),
            onPressed: () => Clipboard.setData(ClipboardData(text: texto)),
          ),
        ],
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_estado != null)
                  Text(_resumoEstado(), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                if (_eventos.isEmpty)
                  Text(l10n.rcDiagVazio, style: const TextStyle(color: Colors.black54))
                else
                  for (final e in _eventos)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SelectableText(
                        _linha(e),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: e['gravou'] == true ? Colors.green.shade900 : Colors.black87,
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}
