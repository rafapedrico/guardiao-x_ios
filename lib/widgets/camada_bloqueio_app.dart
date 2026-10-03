import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../app_navigator.dart';
import '../screens/login_screen.dart';
import '../services/bloqueio_app_service.dart';
import '../services/database_helper.dart';
import '../services/firebase_auth_service.dart';
import 'pin_dialog.dart';

/// Camada de bloqueio do app, colocada em `MaterialApp.builder` POR CIMA do
/// Navigator principal (ver [BloqueioAppService] para a regra completa).
/// O conteúdo de baixo continua montado (serviços, alarmes e o botão de
/// SOS seguem funcionando), só fica coberto e sem toque/semântica.
class CamadaBloqueioApp extends StatelessWidget {
  const CamadaBloqueioApp({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final servico = BloqueioAppService();
    return AnimatedBuilder(
      animation: Listenable.merge([servico.bloqueado, servico.emergenciasAbertas]),
      child: child,
      builder: (context, conteudo) {
        final visivel = servico.camadaVisivel;
        return Stack(
          children: [
            ExcludeSemantics(excluding: visivel, child: conteudo!),
            if (visivel) const Positioned.fill(child: _TelaBloqueio()),
          ],
        );
      },
    );
  }
}

/// Navigator próprio (fora do principal): o PIN abre como diálogo aqui
/// dentro, por cima da tela de bloqueio — no Navigator principal ele
/// ficaria escondido atrás desta camada.
class _TelaBloqueio extends StatelessWidget {
  const _TelaBloqueio();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const _ConteudoBloqueio(),
        transitionDuration: Duration.zero,
      ),
    );
  }
}

class _ConteudoBloqueio extends StatefulWidget {
  const _ConteudoBloqueio();

  @override
  State<_ConteudoBloqueio> createState() => _ConteudoBloqueioState();
}

class _ConteudoBloqueioState extends State<_ConteudoBloqueio> with WidgetsBindingObserver {
  static const Color _corFundo = Color(0xFF14212E);
  static const Color _corAcento = Color(0xFF9CCC65);

  final LocalAuthentication _localAuth = LocalAuthentication();

  bool _aparelhoSuporta = false;
  String? _pinGuardiao;
  bool _autenticando = false;
  bool _falhou = false;
  Timer? _timerTentativaAutomatica;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _carregarOpcoes();
    _agendarTentativaAutomatica();
  }

  @override
  void dispose() {
    _timerTentativaAutomatica?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _agendarTentativaAutomatica();
  }

  Future<void> _carregarOpcoes() async {
    bool suporta = false;
    try {
      suporta = await _localAuth.isDeviceSupported();
    } catch (_) {}
    String? pin;
    try {
      final config = await DatabaseHelper().getUserConfig();
      final valor = config?['pin_real'] as String?;
      if (valor != null && valor.isNotEmpty) pin = valor;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _aparelhoSuporta = suporta;
      _pinGuardiao = pin;
    });
  }

  /// Abre o Face ID/biometria sozinho, mas com um pequeno atraso: quando o
  /// app volta do segundo plano por um toque no Widget SOS, o link do SOS
  /// chega logo depois do `resumed` e esconde esta camada — o atraso
  /// evita abrir o prompt de biometria por cima da câmera do SOS.
  void _agendarTentativaAutomatica() {
    _timerTentativaAutomatica?.cancel();
    _timerTentativaAutomatica = Timer(const Duration(milliseconds: 700), () {
      if (!mounted || !BloqueioAppService().camadaVisivel) return;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
      _autenticarComAparelho();
    });
  }

  Future<void> _autenticarComAparelho() async {
    if (_autenticando) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _autenticando = true;
      _falhou = false;
    });
    bool ok = false;
    try {
      // biometricOnly: false — o código do aparelho é aceito como
      // alternativa à biometria (Face ID/Touch ID/digital).
      ok = await _localAuth.authenticate(
        localizedReason: l10n.bloqueioMotivoBiometria,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('⚠️ [CamadaBloqueioApp] Falha na autenticação do aparelho: $e');
    }
    if (!mounted) return;
    setState(() {
      _autenticando = false;
      _falhou = !ok;
    });
    if (ok) BloqueioAppService().desbloquear();
  }

  Future<void> _usarPin() async {
    final l10n = AppLocalizations.of(context)!;
    var confirmado = false;
    await exibirDialogoPin(
      context: context,
      pinEsperado: _pinGuardiao,
      aoConfirmarPinCorreto: () async => confirmado = true,
      // Errar o PIN aqui NÃO dispara o alerta de coação (diferente do
      // desarme do alarme): é só o desbloqueio do app.
      limiteErrosConsecutivos: 1 << 30,
      mostrarBotaoCancelar: true,
      mensagemSucesso: l10n.bloqueioDesbloqueado,
    );
    if (confirmado) BloqueioAppService().desbloquear();
  }

  Future<void> _sairDaConta() async {
    await FirebaseAuthService().logout();
    BloqueioAppService().aoEncerrarSessao();
    appNavigatorKey.currentState?.pushAndRemoveUntil(
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
                    const Icon(Icons.lock_outline_rounded, color: _corAcento, size: 64),
                    const SizedBox(height: 20),
                    Text(
                      l10n.bloqueioTitulo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.bloqueioSubtitulo,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
                    ),
                    if (_falhou) ...[
                      const SizedBox(height: 12),
                      Text(
                        l10n.bloqueioFalha,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
                      ),
                    ],
                    const SizedBox(height: 28),
                    if (_aparelhoSuporta)
                      FilledButton.icon(
                        onPressed: _autenticando ? null : _autenticarComAparelho,
                        style: FilledButton.styleFrom(
                          backgroundColor: _corAcento,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.fingerprint),
                        label: Text(l10n.bloqueioBotaoDesbloquear),
                      ),
                    if (_pinGuardiao != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _usarPin,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.pin_outlined),
                        label: Text(l10n.bloqueioBotaoUsarPin),
                      ),
                    ],
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: _sairDaConta,
                      style: TextButton.styleFrom(foregroundColor: Colors.white60),
                      child: Text(l10n.bloqueioBotaoSair),
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
