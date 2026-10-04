import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/onboarding_service.dart';
import '../services/plano_ciclo_service.dart';
import '../services/sos_plano_aviso_service.dart';
import '../widgets/premium_compra_aviso.dart';
import '../services/sessao_revogada_service.dart';
import '../services/sos_widget_status_service.dart';
import 'login_screen.dart';
import '../widgets/permissao_status_card.dart';

/// Tela "Status de Permissões", acessível a qualquer momento em
/// Configurações > Minha Conta > Status de Permissões — mostra EXATAMENTE
/// os mesmos cards de verificação de permissões exibidos no Assistente de
/// Configuração Inicial (`OnboardingScreen`, ver [PermissaoStatusCard]),
/// reaproveitando o mesmo [OnboardingService] de checagem/solicitação.
///
/// Diferente do onboarding, esta tela:
/// - Não é exibida automaticamente nem bloqueia nada — é só uma consulta/
///   ação avulsa, com um AppBar normal (botão Voltar).
/// - Não chama [OnboardingService.marcarConcluido] nem tem um botão
///   "Continuar" — o usuário sai tocando Voltar quando quiser.
/// - Todo card (não só Localização) ganha o atalho "Abrir Configurações",
///   permitindo abrir as configurações nativas do aparelho para QUALQUER
///   permissão pendente, não só a essencial.
class PermissoesStatusScreen extends StatefulWidget {
  const PermissoesStatusScreen({super.key});

  @override
  State<PermissoesStatusScreen> createState() => _PermissoesStatusScreenState();
}

class _PermissoesStatusScreenState extends State<PermissoesStatusScreen>
    with WidgetsBindingObserver {
  final OnboardingService _service = OnboardingService();

  StatusPermissaoOnboarding _bateria = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _notificacoes = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _localizacao = StatusPermissaoOnboarding.pendente;
  StatusPermissaoOnboarding _camera = StatusPermissaoOnboarding.pendente;

  StatusPermissaoOnboarding _telaCheia = StatusPermissaoOnboarding.pendente;

  /// Só iOS: Widget SOS instalado na tela de início/bloqueada (status real,
  /// do WidgetCenter — ver [SosWidgetStatusService]). `null` = desconhecido.
  bool? _widgetSos;

  /// Só iOS: botão SOS desativado agora pelos dias bloqueados do Plano
  /// Free (`null` = ativo ou Premium) — card vermelho com "Assinar Premium".
  BloqueioSosPlano? _bloqueioSosPlano;

  /// Só iOS: a sessão deste iPhone foi encerrada por login em outro
  /// aparelho ("uma conta, um aparelho ativo", ver SessaoRevogadaService).
  bool _sessaoEncerrada = false;

  bool _carregando = true;

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
    // Reverificado também a cada volta ao primeiro plano (ver
    // didChangeAppLifecycleState): fica verde sozinho depois que o
    // usuário adiciona o widget e volta ao app.
    final widgetSos = await SosWidgetStatusService.widgetInstalado();
    final bloqueioSosPlano = Platform.isIOS
        ? BloqueioSosPlano.vigente(await PlanoCicloService().obterStatusAtualizado())
        : null;
    // Confere com o servidor a cada abertura/volta ao primeiro plano; se a
    // sessão caiu, o serviço também abre o aviso.
    final sessaoEncerrada =
        Platform.isIOS && await SessaoRevogadaService().verificarAgora();
    if (!mounted) return;
    setState(() {
      _bateria = resultados[0];
      _notificacoes = resultados[1];
      _localizacao = resultados[2];
      _camera = resultados[3];
      _telaCheia = resultados[4];
      _widgetSos = widgetSos;
      _bloqueioSosPlano = bloqueioSosPlano;
      _sessaoEncerrada = sessaoEncerrada;
      _carregando = false;
    });
  }

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(title: Text(l10n.statusPermissoesTitulo)),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Text(
                    l10n.statusPermissoesIntroducao,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (Platform.isIOS)
                    PermissaoStatusCard(
                      icone: Icons.verified_user_rounded,
                      titulo: l10n.statusContaTitulo,
                      descricao: l10n.statusContaDescricao,
                      essencial: true,
                      status: _sessaoEncerrada
                          ? StatusPermissaoOnboarding.pendente
                          : StatusPermissaoOnboarding.concedida,
                      textoStatusConcedida: l10n.statusContaAtiva,
                      textoStatusPendente: l10n.statusContaEncerrada,
                      corStatusPendente: Colors.red.shade600,
                      textoBotaoConceder: l10n.sessaoEncerradaBotaoEntrar,
                      aoConceder: () => Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => const LoginScreen()),
                        (route) => false,
                      ),
                    ),
                  PermissaoStatusCard(
                    icone: Icons.notifications_active_rounded,
                    titulo: l10n.onboardingNotificacoesTitulo,
                    descricao: l10n.onboardingNotificacoesConteudo,
                    essencial: true,
                    status: _notificacoes,
                    aoConceder: _tocarNotificacoes,
                    aoAbrirConfiguracoes:
                        _notificacoes != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.my_location_rounded,
                    titulo: l10n.onboardingLocalizacaoTitulo,
                    descricao: l10n.onboardingLocalizacaoConteudo,
                    essencial: true,
                    status: _localizacao,
                    aoConceder: _tocarLocalizacao,
                    aoAbrirConfiguracoes:
                        _localizacao != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                    textoStatusParcial: l10n.onboardingLocalizacaoStatusParcial,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.battery_saver_rounded,
                    titulo: l10n.permissaoBateriaTitulo,
                    descricao: l10n.permissaoBateriaConteudo,
                    essencial: false,
                    status: _bateria,
                    aoConceder: _tocarBateria,
                    aoAbrirConfiguracoes:
                        _bateria != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.camera_alt_rounded,
                    titulo: l10n.onboardingCameraTitulo,
                    descricao: l10n.onboardingCameraConteudo,
                    essencial: false,
                    status: _camera,
                    aoConceder: _tocarCamera,
                    aoAbrirConfiguracoes:
                        _camera != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  PermissaoStatusCard(
                    icone: Icons.fullscreen_rounded,
                    titulo: l10n.onboardingTelaCheiaTitulo,
                    descricao: l10n.onboardingTelaCheiaConteudo,
                    essencial: false,
                    status: _telaCheia,
                    aoConceder: _tocarTelaCheia,
                    aoAbrirConfiguracoes:
                        _telaCheia != StatusPermissaoOnboarding.concedida
                            ? openAppSettings
                            : null,
                  ),
                  if (Platform.isIOS)
                    PermissaoStatusCard(
                      icone: Icons.sos_rounded,
                      titulo: l10n.sosWidgetStatusTitulo,
                      descricao: l10n.sosWidgetStatusDescricao,
                      essencial: false,
                      status: _widgetSos == true && _bloqueioSosPlano == null
                          ? StatusPermissaoOnboarding.concedida
                          : StatusPermissaoOnboarding.pendente,
                      textoStatusConcedida: l10n.sosWidgetStatusAtivo,
                      textoStatusPendente: _bloqueioSosPlano != null
                          ? l10n.sosPlanoStatusDesativado
                          : l10n.sosWidgetStatusNaoAdicionado,
                      corStatusPendente: Colors.red.shade600,
                      textoBotaoConceder: l10n.sosWidgetBotaoComoAdicionar,
                      aoConceder: () => SosWidgetStatusService.abrirTutorial(context),
                      aoTocarCard: () => SosWidgetStatusService.abrirTutorial(context),
                      aviso: _bloqueioSosPlano == null
                          ? null
                          : l10n.sosPlanoDesativadoAte(formatarDiaMes(_bloqueioSosPlano!.fim)),
                      textoBotaoAviso: l10n.sosPlanoBotaoAssinar,
                      aoTocarBotaoAviso: () => iniciarCompraPremiumComAviso(context),
                    ),
                ],
              ),
            ),
    );
  }
}
