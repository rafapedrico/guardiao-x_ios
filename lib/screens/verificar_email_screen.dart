import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../app_navigator.dart';
import '../main.dart' show TelaInicialComPossivelDialogoPin;
import '../services/firebase_auth_service.dart';
import '../services/onboarding_service.dart';
import '../utils/mensagens_erro_auth.dart';
import 'login_screen.dart';
import 'onboarding_screen.dart';

/// Tela OBRIGATÓRIA de confirmação de e-mail, exibida logo após o cadastro
/// por e-mail/senha ([CadastroScreen], via `pushReplacement` — substitui a
/// tela de cadastro na pilha, ficando diretamente sobre a [LoginScreen]).
///
/// A sessão do `createUserWithEmailAndPassword` (ainda ativa neste ponto)
/// é MANTIDA deliberadamente enquanto esta tela está aberta — é o que
/// permite tanto "Reenviar e-mail" (`User.sendEmailVerification()` exige
/// um usuário autenticado) quanto "Já verifiquei, entrar" funcionarem sem
/// pedir a senha de novo. Mesmo padrão já usado por [LoginScreen] no
/// diálogo de bloqueio por e-mail não verificado (`_exibirDialogoEmailNaoVerificado`)
/// e por [CompletarPerfilScreen] (perfil social incompleto) — em ambos os
/// casos a sessão sobrevive só até a PRÓPRIA tela decidir o que fazer com
/// ela, nunca vazando para fora.
///
/// [PopScope] com `canPop: false`: a ÚNICA saída sem confirmar o e-mail é
/// o botão "Sair" (encerra a sessão e volta ao Login): nenhuma sessão com
/// e-mail não verificado entra no app (a splash em `main.dart` também
/// manda essa conta para o Login).
class VerificarEmailScreen extends StatefulWidget {
  const VerificarEmailScreen({
    super.key,
    required this.email,
    this.avisoEnvioEmail,
    this.avisoTelefoneEmUso = false,
  });

  /// E-mail cadastrado, exibido na mensagem principal.
  final String email;

  /// Mensagem de erro do ENVIO INICIAL do e-mail de verificação (ver
  /// [CadastroScreen._criarConta]), se houver — a conta já foi criada com
  /// sucesso nesse ponto, então uma falha aqui é só um aviso (o usuário
  /// pode reenviar manualmente), nunca um bloqueio.
  final String? avisoEnvioEmail;

  /// `true` quando o telefone informado no cadastro já pertencia a outra
  /// conta (ver `ResultadoSalvarTelefone.telefoneEmUso`) — mesmo aviso já
  /// usado em [CompletarPerfilScreen], informativo: a conta e o e-mail de
  /// verificação já foram criados/enviados normalmente; o telefone pode
  /// ser ajustado depois em Configurações > Meu Perfil.
  final bool avisoTelefoneEmUso;

  @override
  State<VerificarEmailScreen> createState() => _VerificarEmailScreenState();
}

class _VerificarEmailScreenState extends State<VerificarEmailScreen> {
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corAcentoClaro = Color(0xFF9CCC65);

  /// Janela de espera cliente-side entre reenvios (defesa em profundidade
  /// além do próprio limite de taxa do Firebase Auth, ver
  /// [_mensagemErroReenvio]): evita martelar o botão e bater no limite
  /// (`auth/too-many-requests`) por puro excesso de cliques.
  static const int _cooldownPadraoSegundos = 45;

  /// Cooldown mais longo aplicado quando o PRÓPRIO Firebase Auth já
  /// sinalizou `too-many-requests` — sinal de que o limite real do
  /// servidor está mais próximo do que o cooldown padrão sozinho cobre.
  static const int _cooldownAposThrottleSegundos = 120;

  bool _reenviando = false;
  bool _verificando = false;
  bool _saindo = false;
  int _cooldownSegundos = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _iniciarCooldown(int segundos) {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSegundos = segundos);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _cooldownSegundos--;
        if (_cooldownSegundos <= 0) timer.cancel();
      });
    });
  }

  /// Reenvia o e-mail de verificação para a sessão ainda ativa. Tratamento
  /// de erro robusto: `too-many-requests` (limite de envio do próprio
  /// Firebase Auth) ganha uma mensagem específica e orientativa, em vez do
  /// genérico "falha ao reenviar" — e já inicia um cooldown mais longo,
  /// já que o limite real do servidor claramente está mais próximo.
  Future<void> _reenviarEmail() async {
    if (_reenviando || _cooldownSegundos > 0) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _reenviando = true);
    try {
      await FirebaseAuthService().enviarEmailVerificacao();
      if (!mounted) return;
      _iniciarCooldown(_cooldownPadraoSegundos);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.emailVerificacaoReenviada),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      final classificado = classificarErroEnvioVerificacao(
        e, l10n,
        cooldownPadraoSegundos: _cooldownPadraoSegundos,
        cooldownThrottleSegundos: _cooldownAposThrottleSegundos,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(classificado.mensagem),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
      if (classificado.cooldownSegundos > 0) {
        _iniciarCooldown(classificado.cooldownSegundos);
      }
    } catch (e) {
      debugPrint('⚠️ [VerificarEmailScreen] Falha ao reenviar e-mail de verificação: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.emailVerificacaoReenvioFalhou),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _reenviando = false);
    }
  }

  /// Recarrega o usuário direto do servidor e checa `emailVerified`. Se
  /// confirmado, encerra esta tela e segue DIRETO para o fluxo principal
  /// (Onboarding ou Dashboard, mesma decisão de
  /// `LoginScreen._decidirProximaTelaAposLogin`) — sem pedir a senha de
  /// novo, já que a sessão desta conta nunca deixou de ser válida. Usa
  /// [appNavigatorKey] (não `Navigator.of(context)`) pelo mesmo motivo já
  /// documentado em `LoginScreen._navegarParaFluxoPrincipal`: a troca de
  /// rota que segue pode acontecer bem depois deste `context` ainda ser
  /// considerado válido (ex: o usuário demora minutos no Assistente de
  /// Configuração antes de `aoConcluir` ser chamado).
  ///
  /// Uma conta recém-criada nunca tem contatos locais para sincronizar nem
  /// uma notificação de solicitação de localização pendente (ambos exigem
  /// tempo de conta/uso que uma conta com segundos de vida não teve) — por
  /// isso, diferente de `_finalizarLoginComSucesso`, não replica essa
  /// parte: seria trabalho morto, nunca aplicável aqui.
  Future<void> _jaVerifiquei() async {
    if (_verificando) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() => _verificando = true);
    try {
      await FirebaseAuthService().recarregarUsuarioAtual();
      final usuario = FirebaseAuthService().usuarioAtual;

      if (usuario == null || !usuario.emailVerified) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.verificarEmailAindaNaoConfirmado),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final onboardingConcluido = await OnboardingService().jaConcluido();
      if (onboardingConcluido) {
        appNavigatorKey.currentState?.pushReplacement(
          MaterialPageRoute(
            builder: (context) =>
                const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false),
          ),
        );
      } else {
        appNavigatorKey.currentState?.pushReplacement(
          MaterialPageRoute(
            builder: (context) => OnboardingScreen(
              aoConcluir: () async {
                appNavigatorKey.currentState?.pushReplacement(
                  MaterialPageRoute(
                    builder: (context) =>
                        const TelaInicialComPossivelDialogoPin(aguardandoConfirmacaoPin: false),
                  ),
                );
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('⚠️ [VerificarEmailScreen] Falha ao checar confirmação do e-mail: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.erroLoginSemConexao),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  /// Única saída possível sem confirmar o e-mail — encerra a sessão
  /// transitória e volta ao Login com a pilha limpa (mesmo padrão de
  /// `CompletarPerfilScreen._sair`).
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
    final ocupado = _reenviando || _verificando || _saindo;

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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.mark_email_read_outlined, color: _corAcentoClaro, size: 64),
                    const SizedBox(height: 20),
                    Text(
                      l10n.verificarEmailTitulo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.verificarEmailMensagem(widget.email),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                    ),
                    if (widget.avisoEnvioEmail != null) ...[
                      const SizedBox(height: 16),
                      _buildAviso(widget.avisoEnvioEmail!),
                    ],
                    if (widget.avisoTelefoneEmUso) ...[
                      const SizedBox(height: 16),
                      _buildAviso(l10n.telefoneJaEmUso),
                    ],
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: ocupado ? null : _jaVerifiquei,
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: _verificando
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(l10n.verificarEmailBotaoJaVerifiquei),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: (ocupado || _cooldownSegundos > 0) ? null : _reenviarEmail,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: Colors.white38),
                      ),
                      child: _reenviando
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                            )
                          : Text(
                              _cooldownSegundos > 0
                                  ? l10n.verificarEmailBotaoReenviarCooldown(_cooldownSegundos)
                                  : l10n.emailNaoVerificadoReenviar,
                              style: const TextStyle(color: Colors.white),
                            ),
                    ),
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: ocupado ? null : _sair,
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
    );
  }

  Widget _buildAviso(String texto) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.shade800.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade800.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.orange.shade300, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(color: Colors.orange.shade100, fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
