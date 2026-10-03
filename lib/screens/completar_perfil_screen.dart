import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../app_navigator.dart';
import '../services/database_helper.dart';
import '../services/firebase_auth_service.dart';
import '../services/firebase_sync_service.dart';
import '../utils/telefone_utils.dart';
import 'login_screen.dart';

/// Tela OBRIGATÓRIA de complemento de perfil, exibida logo após o
/// PRIMEIRO login social (Google/Apple) bem-sucedido quando a conta ainda
/// não tem `usuarios/{uid}.telefone` gravado (ver
/// `LoginScreen._finalizarLoginComSucesso`).
///
/// SUBSTITUIU `VerificacaoTelefoneScreen` (SMS OTP) em 2026-08-23 —
/// decisão de arquitetura para zerar custo de SMS e simplificar o
/// onboarding em larga escala, com diretriz mandatória de NÃO regredir o
/// motor de segurança: o telefone agora é só um campo de perfil (sem
/// espera de SMS, sem tela de bloqueio de código), mas continua indo
/// para `usuarios/{uid}.telefone` EXCLUSIVAMENTE via
/// [FirebaseSyncService.salvarTelefonePerfil] (Cloud Function
/// `atualizarTelefonePerfil`), que impõe UNICIDADE ESTRITA server-side —
/// a rede de segurança que substitui a antiga prova de posse por SMS (ver
/// documentação completa em `telefonePerfilService.js`).
///
/// [PopScope] com `canPop: false`: a ÚNICA saída sem completar o perfil é
/// o botão "Sair" (encerra a sessão e volta ao Login) — nunca avança para
/// o Dashboard sem o telefone salvo.
class CompletarPerfilScreen extends StatefulWidget {
  const CompletarPerfilScreen({super.key, required this.aoConcluir});

  /// Chamado exclusivamente após o telefone ser salvo com sucesso —
  /// decide a PRÓXIMA tela (Onboarding ou Dashboard direto, ver
  /// `LoginScreen._decidirProximaTelaAposLogin`).
  final Future<void> Function() aoConcluir;

  @override
  State<CompletarPerfilScreen> createState() => _CompletarPerfilScreenState();
}

class _CompletarPerfilScreenState extends State<CompletarPerfilScreen> {
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corCampoFundo = Color(0xFF1E313F);
  static const Color _corAcentoClaro = Color(0xFF9CCC65);

  final _formKey = GlobalKey<FormState>();
  final _telefoneController = TextEditingController();

  bool _salvando = false;
  bool _saindo = false;
  String? _erro;

  @override
  void dispose() {
    _telefoneController.dispose();
    super.dispose();
  }

  Future<void> _salvar() async {
    if (_formKey.currentState?.validate() != true) return;
    final l10n = AppLocalizations.of(context)!;
    final numero = TelefoneUtils.normalizarE164(_telefoneController.text);
    if (numero == null) {
      setState(() => _erro = l10n.campoCelularInvalido);
      return;
    }

    setState(() {
      _salvando = true;
      _erro = null;
    });

    final resultado = await FirebaseSyncService().salvarTelefonePerfil(numero);
    try {
      await DatabaseHelper().salvarTelefoneLocal(numero);
    } catch (e) {
      debugPrint('⚠️ [CompletarPerfilScreen] Falha ao gravar telefone no SQLite local: $e');
    }

    if (!mounted) return;

    switch (resultado) {
      case ResultadoSalvarTelefone.sucesso:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.telefoneSalvoComSucesso),
            behavior: SnackBarBehavior.floating,
            backgroundColor: Colors.green,
          ),
        );
        await widget.aoConcluir();
        return;
      case ResultadoSalvarTelefone.telefoneEmUso:
        setState(() {
          _salvando = false;
          _erro = l10n.telefoneJaEmUso;
        });
        return;
      case ResultadoSalvarTelefone.erro:
        // Mostra também o código técnico (ex: "unauthenticated: ..."),
        // como o login já faz — permite diagnosticar sem acesso aos logs.
        final detalhe = FirebaseSyncService().ultimoErroSalvarTelefone;
        setState(() {
          _salvando = false;
          _erro = detalhe == null
              ? l10n.otpErroGenerico
              : '${l10n.otpErroGenerico}\n\n${l10n.erroLoginDetalhesTecnicos} $detalhe';
        });
        return;
    }
  }

  /// Única saída possível sem completar o perfil — encerra a sessão e
  /// volta ao Login. Usa [appNavigatorKey] (não `Navigator.of(context)`)
  /// porque esta tela substitui a própria `LoginScreen` na pilha (ver
  /// `pushReplacement` em `_finalizarLoginComSucesso`).
  Future<void> _sair() async {
    setState(() => _saindo = true);
    await FirebaseAuthService().logout();
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
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
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.person_outline, color: _corAcentoClaro, size: 56),
                      const SizedBox(height: 16),
                      Text(
                        l10n.completarPerfilTitulo,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        l10n.completarPerfilIntroducao,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _telefoneController,
                        keyboardType: TextInputType.phone,
                        autofocus: true,
                        style: const TextStyle(color: Colors.white),
                        onFieldSubmitted: (_) {
                          if (!_salvando) _salvar();
                        },
                        decoration: InputDecoration(
                          labelText: l10n.campoCelularLabel,
                          labelStyle: const TextStyle(color: Colors.white70),
                          prefixIcon: const Icon(Icons.phone_android_outlined, color: Colors.white70),
                          filled: true,
                          fillColor: _corCampoFundo,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: _corAcentoClaro, width: 1.5),
                          ),
                          errorBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: Colors.redAccent, width: 1.2),
                          ),
                          contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                        ),
                        validator: (valor) {
                          if (valor == null || valor.trim().isEmpty) {
                            return l10n.campoCelularObrigatorio;
                          }
                          if (TelefoneUtils.normalizarE164(valor) == null) {
                            return l10n.campoCelularInvalido;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _salvando ? null : _salvar,
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                        child: _salvando
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(l10n.salvar),
                      ),
                      if (_erro != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _erro!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: _saindo ? null : _sair,
                        child: Text(
                          l10n.sairDaContaConfirmar,
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
