import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/onboarding_service.dart';
import '../widgets/permissao_status_card.dart';

/// Assistente de Configuração Inicial — reespecificação do usuário
/// (2026-08-16): exibido uma única vez, logo após o primeiro login bem
/// sucedido nesta instalação (ver `LoginScreen._finalizarLoginComSucesso`),
/// guiando o usuário permissão por permissão para que o botão de pânico e
/// os alertas funcionem de forma confiável em QUALQUER aparelho Android —
/// mesmo com a tela bloqueada ou em Modo Doze.
///
/// Cada item é ESSENCIAL (bloqueia a conclusão, ver [_essenciaisConcedidas])
/// ou RECOMENDADO (visível, mas não bloqueia — o app continua funcional de
/// forma degradada sem ele). Tocar em "Continuar" SEMPRE avança para o
/// app — nunca prende o usuário nesta tela — mas só marca o Assistente
/// como concluído (`OnboardingService.marcarConcluido`) quando os itens
/// essenciais já estiverem concedidos; caso contrário, a tela volta a
/// aparecer no próximo login.
///
/// PROPOSITALMENTE não inclui um item de "Serviço de Acessibilidade" — ver
/// documentação completa em `OnboardingService`.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.aoConcluir});

  /// Chamado quando o usuário toca em "Continuar" — SEMPRE, independente
  /// de quais permissões foram concedidas (ver documentação da classe).
  final VoidCallback aoConcluir;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final OnboardingService _service = OnboardingService();

  StatusPermissaoOnboarding _bateria = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _notificacoes = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _localizacao = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _camera = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _telaCheia = StatusPermissaoOnboarding.pendente;

  bool _carregando = true;
  bool _concluindo = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _carregarStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Reavalia o status de tudo (exceto tela cheia, ver [_telaCheia]) toda
  /// vez que o app volta ao primeiro plano — cobre o caso comum de o
  /// usuário ter ido manualmente até Configurações (ex: pra trocar
  /// localização de "durante o uso" para "sempre") e voltado.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _carregarStatus();
    }
  }

  Future<void> _carregarStatus() async {
    final resultados = await Future.wait([
      _service.statusBateria(),
      _service.statusNotificacoes(),
      _service.statusLocalizacao(),
      _service.statusCamera(),
      _service.statusTelaCheia(),
    ]);
    if (!mounted) return;
    setState(() {
      _bateria = resultados[0];
      _notificacoes = resultados[1];
      _localizacao = resultados[2];
      _camera = resultados[3];
      _telaCheia = resultados[4];
      _carregando = false;
    });
  }

  /// ESSENCIAIS: notificações (sem elas, nenhum alerta aparece de jeito
  /// nenhum) e localização em algum grau (sem ela, nem o botão de pânico
  /// manual consegue anexar posição ao alerta). Bateria/câmera/tela cheia
  /// são recomendadas mas o app continua funcional sem elas (fallbacks já
  /// existentes em todo o resto do código — ver `SosDisparoService`).
  bool get _essenciaisConcedidas =>
      _notificacoes == StatusPermissaoOnboarding.concedida &&
      _localizacao != StatusPermissaoOnboarding.pendente;

  Future<void> _tocarBateria() async {
    await _service.solicitarBateria();
    final novo = await _service.statusBateria();
    if (mounted) setState(() => _bateria = novo);
  }

  Future<void> _tocarNotificacoes() async {
    await _service.solicitarNotificacoes();
    final novo = await _service.statusNotificacoes();
    if (mounted) setState(() => _notificacoes = novo);
  }

  Future<void> _tocarLocalizacao() async {
    await _service.solicitarLocalizacao();
    final novo = await _service.statusLocalizacao();
    if (mounted) setState(() => _localizacao = novo);
  }

  Future<void> _tocarCamera() async {
    await _service.solicitarCamera();
    final novo = await _service.statusCamera();
    if (mounted) setState(() => _camera = novo);
  }

  Future<void> _tocarTelaCheia() async {
    await _service.solicitarTelaCheia();
    final novo = await _service.statusTelaCheia();
    if (mounted) setState(() => _telaCheia = novo);
  }

  Future<void> _continuar() async {
    if (_essenciaisConcedidas) {
      await _service.marcarConcluido();
    }
    if (!mounted) return;
    widget.aoConcluir();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return PopScope(
      // Sem botão "voltar" — este assistente só aparece uma vez, logo
      // após o login, e "Continuar" (sempre disponível) é o único jeito
      // de sair dela.
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F6F8),
        appBar: AppBar(title: Text(l10n.onboardingTitulo)),
        body: _carregando
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        children: [
                          Text(
                            l10n.onboardingIntroducao,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 20),
                          PermissaoStatusCard(
                            icone: Icons.notifications_active_rounded,
                            titulo: l10n.onboardingNotificacoesTitulo,
                            descricao: l10n.onboardingNotificacoesConteudo,
                            essencial: true,
                            status: _notificacoes,
                            aoConceder: _tocarNotificacoes,
                          ),
                          PermissaoStatusCard(
                            icone: Icons.my_location_rounded,
                            titulo: l10n.onboardingLocalizacaoTitulo,
                            descricao: Platform.isIOS
                                ? l10n.onboardingLocalizacaoConteudoIos
                                : l10n.onboardingLocalizacaoConteudo,
                            essencial: true,
                            status: _localizacao,
                            aoConceder: _tocarLocalizacao,
                            aoAbrirConfiguracoes:
                                _localizacao != StatusPermissaoOnboarding.concedida
                                    ? openAppSettings
                                    : null,
                            textoStatusParcial: Platform.isIOS
                                ? l10n.onboardingLocalizacaoStatusParcialIos
                                : l10n.onboardingLocalizacaoStatusParcial,
                          ),
                          // Só Android: no iOS não existe isenção de otimização de bateria nem botão físico de pânico.
                          if (!Platform.isIOS)
                            PermissaoStatusCard(
                              icone: Icons.battery_saver_rounded,
                              titulo: l10n.permissaoBateriaTitulo,
                              descricao: l10n.permissaoBateriaConteudo,
                              essencial: false,
                              status: _bateria,
                              aoConceder: _tocarBateria,
                            ),
                          PermissaoStatusCard(
                            icone: Icons.camera_alt_rounded,
                            titulo: l10n.onboardingCameraTitulo,
                            descricao: l10n.onboardingCameraConteudo,
                            essencial: false,
                            status: _camera,
                            aoConceder: _tocarCamera,
                          ),
                          // Só Android: no iOS não existe alerta em tela cheia por cima da tela bloqueada.
                          if (!Platform.isIOS)
                            PermissaoStatusCard(
                              icone: Icons.fullscreen_rounded,
                              titulo: l10n.onboardingTelaCheiaTitulo,
                              descricao: l10n.onboardingTelaCheiaConteudo,
                              essencial: false,
                              status: _telaCheia,
                              aoConceder: _tocarTelaCheia,
                            ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Column(
                          children: [
                            if (!_essenciaisConcedidas)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  l10n.onboardingAvisoEssenciaisPendentes,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: Colors.orange.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: _concluindo
                                    ? null
                                    : () async {
                                        setState(() => _concluindo = true);
                                        await _continuar();
                                      },
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                ),
                                child: Text(l10n.onboardingBotaoContinuar),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

}
