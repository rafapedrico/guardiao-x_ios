import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import 'login_screen.dart';

/// Aberta quando o Widget SOS (ou o botão físico) é tocado num aparelho
/// onde ninguém nunca entrou na conta: sem sessão não há como enviar o
/// alerta, então explica que é preciso entrar UMA vez para ativar o botão
/// — em vez de cair na LoginScreen crua, sem contexto nenhum.
class SosSemLoginScreen extends StatelessWidget {
  const SosSemLoginScreen({super.key});

  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corAcento = Color(0xFF9CCC65);

  void _irParaLogin(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: _corFundo,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.sos_rounded, color: Colors.redAccent, size: 72),
                  const SizedBox(height: 20),
                  Text(
                    l10n.sosSemLoginTitulo,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.sosSemLoginTexto,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.45),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    onPressed: () => _irParaLogin(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: _corAcento,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: Text(l10n.sosSemLoginBotaoEntrar),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
