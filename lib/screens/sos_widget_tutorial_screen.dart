import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

/// Passo a passo para adicionar o Widget SOS do iOS ("Botão de Pânico")
/// na tela de início e na tela bloqueada. O iOS não deixa o app adicionar
/// widgets nem abrir a galeria de widgets por código, então a tela só
/// explica — aberta pelo card "Botão SOS na tela de início" em Status de
/// Permissões e, uma única vez, depois do primeiro login (ver
/// `SosWidgetStatusService`).
class SosWidgetTutorialScreen extends StatelessWidget {
  const SosWidgetTutorialScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(title: Text(l10n.sosWidgetTutorialTitulo)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset(
                        'assets/images/sos_widget.png',
                        width: 150,
                        height: 150,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.sosWidgetTutorialIntro,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade800, height: 1.4),
                  ),
                  const SizedBox(height: 20),
                  _SecaoPassos(
                    icone: Icons.phone_iphone_rounded,
                    titulo: l10n.sosWidgetTutorialTelaInicioTitulo,
                    passos: [
                      l10n.sosWidgetTutorialTelaInicioPasso1,
                      l10n.sosWidgetTutorialTelaInicioPasso2,
                      l10n.sosWidgetTutorialTelaInicioPasso3,
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SecaoPassos(
                    icone: Icons.lock_outline_rounded,
                    titulo: l10n.sosWidgetTutorialTelaBloqueioTitulo,
                    passos: [
                      l10n.sosWidgetTutorialTelaBloqueioPasso1,
                      l10n.sosWidgetTutorialTelaBloqueioPasso2,
                      l10n.sosWidgetTutorialTelaBloqueioPasso3,
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(l10n.sosWidgetTutorialEntendi),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecaoPassos extends StatelessWidget {
  const _SecaoPassos({
    required this.icone,
    required this.titulo,
    required this.passos,
  });

  final IconData icone;
  final String titulo;
  final List<String> passos;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icone, color: Colors.red.shade400),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < passos.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: Colors.red.shade400,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      passos[i],
                      style: TextStyle(fontSize: 13.5, color: Colors.grey.shade800, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
