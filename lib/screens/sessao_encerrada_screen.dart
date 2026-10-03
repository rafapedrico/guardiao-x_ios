import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import 'login_screen.dart';

/// Só iOS — aviso de que a conta foi aberta em outro aparelho e a sessão
/// deste iPhone foi encerrada pelo servidor ("uma conta, um aparelho
/// ativo", ver `SessaoRevogadaService`). Sem sessão, este iPhone não recebe
/// alertas e o Botão SOS não funciona — por isso a tela é explícita e leva
/// direto ao login.
class SessaoEncerradaScreen extends StatefulWidget {
  const SessaoEncerradaScreen({super.key});

  /// Evita abrir a mesma tela duas vezes (detecção + cold start).
  static bool aberta = false;

  @override
  State<SessaoEncerradaScreen> createState() => _SessaoEncerradaScreenState();
}

class _SessaoEncerradaScreenState extends State<SessaoEncerradaScreen> {
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corAcento = Color(0xFF9CCC65);

  @override
  void initState() {
    super.initState();
    SessaoEncerradaScreen.aberta = true;
  }

  @override
  void dispose() {
    SessaoEncerradaScreen.aberta = false;
    super.dispose();
  }

  void _entrarDeNovo() {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: false,
      child: Scaffold(
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
                    const Icon(Icons.phonelink_erase_rounded, color: Colors.orangeAccent, size: 72),
                    const SizedBox(height: 20),
                    Text(
                      l10n.sessaoEncerradaTitulo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.sessaoEncerradaTexto,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.45),
                    ),
                    const SizedBox(height: 28),
                    FilledButton(
                      onPressed: _entrarDeNovo,
                      style: FilledButton.styleFrom(
                        backgroundColor: _corAcento,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(l10n.sessaoEncerradaBotaoEntrar),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
