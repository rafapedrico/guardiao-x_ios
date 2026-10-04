import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/rastreamento_continuo_service.dart';

/// Consentimento explícito do compartilhamento contínuo (aba Monitoramento),
/// em duas etapas — o iOS só oferece "Sempre" depois de "Durante o uso":
///   1. o que é e para quem → localização "Durante o uso";
///   2. por que "Sempre" e Movimento → localização "Sempre" + Movimento
///      (o pedido de Movimento só existe aqui, nunca no primeiro uso do app).
/// Só depois do "Concordo" marcado e das permissões o rastreamento liga
/// ([RastreamentoContinuoService.registrarConsentimento]).
class ConsentimentoRastreamentoScreen extends StatefulWidget {
  const ConsentimentoRastreamentoScreen({super.key});

  @override
  State<ConsentimentoRastreamentoScreen> createState() => _ConsentimentoRastreamentoScreenState();
}

class _ConsentimentoRastreamentoScreenState extends State<ConsentimentoRastreamentoScreen> {
  static const Color _corDestaque = Color(0xFF4C7040);

  int _etapa = 0;
  bool _concordo = false;
  bool _ocupado = false;

  String get _nomes =>
      RastreamentoContinuoService().monitorandoMe.value.map((c) => c.nome).join(', ');

  @override
  void initState() {
    super.initState();
    _pularEtapa1SeJaPermitido();
  }

  Future<void> _pularEtapa1SeJaPermitido() async {
    try {
      if ((await Permission.locationWhenInUse.status).isGranted && mounted) {
        setState(() => _etapa = 1);
      }
    } catch (_) {}
  }

  Future<void> _etapa1() async {
    setState(() => _ocupado = true);
    final status = await Permission.locationWhenInUse.request();
    if (!mounted) return;
    setState(() {
      _ocupado = false;
      if (status.isGranted) _etapa = 1;
    });
    if (!status.isGranted) await openAppSettings();
  }

  Future<void> _etapa2() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _ocupado = true);
    final sempre = await Permission.locationAlways.request();
    await RastreamentoContinuoService().pedirPermissaoMovimento();
    await RastreamentoContinuoService().registrarConsentimento();
    if (!mounted) return;
    setState(() => _ocupado = false);
    final mensageiro = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(true);
    mensageiro.showSnackBar(SnackBar(
      content: Text(sempre.isGranted ? l10n.rcConcluido : l10n.rcSemSempre),
      duration: Duration(seconds: sempre.isGranted ? 3 : 8),
      action: sempre.isGranted
          ? null
          : SnackBarAction(label: l10n.rcAbrirAjustes, onPressed: openAppSettings),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final primeira = _etapa == 0;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.rcTitulo)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              primeira ? Icons.location_on_outlined : Icons.directions_walk_rounded,
              size: 64,
              color: _corDestaque,
            ),
            const SizedBox(height: 16),
            Text(
              '${_etapa + 1}/2',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              primeira ? l10n.rcEtapa1Titulo : l10n.rcEtapa2Titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(
              primeira ? l10n.rcEtapa1Texto : l10n.rcEtapa2Texto,
              style: const TextStyle(fontSize: 15, height: 1.45),
            ),
            if (!primeira) ...[
              const SizedBox(height: 20),
              CheckboxListTile(
                value: _concordo,
                onChanged: (v) => setState(() => _concordo = v ?? false),
                activeColor: _corDestaque,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.rcConcordo(_nomes), style: const TextStyle(fontSize: 14)),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _ocupado || (!primeira && !_concordo) ? null : (primeira ? _etapa1 : _etapa2),
              style: FilledButton.styleFrom(
                backgroundColor: _corDestaque,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(primeira ? l10n.rcEtapa1Botao : l10n.rcEtapa2Botao),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _ocupado ? null : () => Navigator.of(context).pop(false),
              child: Text(l10n.agoraNao),
            ),
          ],
        ),
      ),
    );
  }
}
