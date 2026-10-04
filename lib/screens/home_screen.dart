import 'dart:async';

import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import '../main.dart' show iniciarServicosPosLoginOuDashboard;
import '../services/alertas_recebidos_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/sms_permission_service.dart';
import '../services/sos_widget_status_service.dart';
import 'tabs/seguranca_tab.dart';
import 'tabs/familia_tab.dart';
import 'tabs/monitoramento_tab.dart';
import 'tabs/historico_tab.dart';
import 'tabs/configuracoes_tab.dart';
import 'tabs/inicio_dashboard.dart';
import '../widgets/aviso_sos_plano_banner.dart';


class HomeScreen extends StatefulWidget {
  /// Índice da aba exibida ao abrir esta tela — usado para abrir
  /// diretamente na aba Monitoramento (índice 2) ao tocar numa
  /// notificação de push de solicitação/resposta de localização (ver
  /// NotificacaoService.exibirNotificacaoMonitoramento). `0` (Segurança)
  /// no fluxo normal de login/cold start.
  final int abaInicial;

  const HomeScreen({super.key, this.abaInicial = 0});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _indiceAbaAtual = widget.abaInicial;

  // Nova Tela de Início (Dashboard): estado inicial da própria HomeScreen
  // em vez de uma rota/aba separada — reaproveita o mesmo Scaffold/AppBar/
  // BottomNavigationBar das 4 abas. Começa `true` apenas no fluxo normal de
  // login (abaInicial == 0); deep-links explícitos (ex.: notificação de
  // Monitoramento, abaInicial == 2) pulam direto para a aba, sem passar
  // pelo Dashboard.
  late bool _mostrandoInicio = widget.abaInicial == 0;

  // GlobalKey usada para acionar, a partir do AppBar global (botão "+"),
  // o modal de "Adicionar Alarme" definido dentro da FamiliaTab.
  final GlobalKey<FamiliaTabState> _familiaTabKey = GlobalKey<FamiliaTabState>();

  // GlobalKey usada para acionar, a partir do AppBar global (botão "+"),
  // o modal de "Adicionar Contato" definido dentro da MonitoramentoTab —
  // mesmo padrão de [_familiaTabKey].
  final GlobalKey<MonitoramentoTabState> _monitoramentoTabKey =
      GlobalKey<MonitoramentoTabState>();

  @override
  void initState() {
    super.initState();

    // ETAPA 3 do lazy loading do cold start (ver main.dart): só agora,
    // com o usuário efetivamente chegando no dashboard, é que sobem os
    // serviços nativos pesados (Alarme de rotina, notificação,
    // Foreground Service do botão físico, fila de retry, FCM,
    // heartbeat de localização, limites do plano) — nunca durante o
    // cold start em si. Guardada internamente para nunca
    // rodar duas vezes na mesma sessão do engine (ex.: navegar para
    // fora e voltar para a Home).
    unawaited(iniciarServicosPosLoginOuDashboard());

    // Indicador de "não visualizado" no ícone da aba Histórico (item 4
    // do pedido de UX do guardião) — recarrega a contagem toda vez que a
    // Home é (re)construída, garantindo que reflita alertas recebidos
    // enquanto o app estava fechado/em segundo plano.
    AlertasRecebidosService.atualizarContagem();

    // Checklist de permissões do onboarding — uma única vez por
    // instalação, logo na primeira entrada na Home (pós post-frame, já
    // com o BuildContext totalmente montado). Encadeado (não paralelo)
    // de propósito: nunca empilha dois diálogos de permissão ao mesmo
    // tempo — SMS/READ_PHONE_STATE primeiro (ver SmsPermissionService),
    // isenção de bateria depois (ver BatteryOptimizationService).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await SmsPermissionService().verificarNoOnboarding(context);
      if (!mounted) return;
      await BatteryOptimizationService().verificarNoOnboarding(context);
      if (!mounted) return;
      // Só iOS: passo a passo do Widget SOS, uma única vez, se ainda não
      // estiver instalado.
      await SosWidgetStatusService.exibirTutorialNoPrimeiroLoginSeNecessario(context);
    });
  }

  // Ordem exata das abas: Segurança, Família, Monitoramento, Histórico
  late final List<Widget> _telas = [
    const SegurancaTab(),
    FamiliaTab(key: _familiaTabKey),
    MonitoramentoTab(key: _monitoramentoTabKey),
    const HistoricoTab(),
  ];


  List<String> _titulos(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [l10n.tabSeguranca, l10n.tabFamilia, l10n.tabMonitoramento, l10n.tabHistorico];
  }

  void _aoSelecionarAba(int indice) {
    setState(() {
      _indiceAbaAtual = indice;
      _mostrandoInicio = false;
    });
  }

  /// Volta a HomeScreen para o modo "Início" (Dashboard) — acionado pelo
  /// ícone de casa exibido no topo de Família/Monitoramento/Histórico/
  /// Configurações.
  void _voltarParaInicio() {
    setState(() => _mostrandoInicio = true);
  }

  void _abrirConfiguracoes(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.home_outlined),
              tooltip: AppLocalizations.of(context)!.homeTooltipInicio,
              onPressed: () {
                Navigator.of(context).pop();
                _voltarParaInicio();
              },
            ),
            title: Text(AppLocalizations.of(context)!.appTituloConfiguracoes),
          ),
          body: const ConfiguracoesTab(),
        ),
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final titulos = _titulos(context);
    // Ícone de casa: some apenas no próprio Dashboard (já é o "início");
    // aparece em Segurança/Família/Monitoramento/Histórico, permitindo
    // voltar diretamente ao Dashboard de qualquer aba.
    final bool mostrarIconeCasa = !_mostrandoInicio;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _mostrandoInicio ? Colors.black : null,
        foregroundColor: _mostrandoInicio ? Colors.white : null,
        elevation: _mostrandoInicio ? 0 : null,
        leading: mostrarIconeCasa
            ? IconButton(
                icon: const Icon(Icons.home_outlined),
                tooltip: l10n.homeTooltipInicio,
                onPressed: _voltarParaInicio,
              )
            : null,
        // No Dashboard, a marca "Guardião-X" já aparece na própria imagem
        // de destaque do corpo — o título do AppBar fica vazio para não
        // duplicar o texto.
        title: _mostrandoInicio
            ? null
            : Text(titulos[_indiceAbaAtual], style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (!_mostrandoInicio && _indiceAbaAtual == 1)
            IconButton(
              icon: const Icon(Icons.add_alarm),
              tooltip: l10n.tooltipAdicionarAlarme,
              onPressed: () => _familiaTabKey.currentState?.abrirModalAdicionarAlarme(),
            ),
          if (!_mostrandoInicio && _indiceAbaAtual == 2)
            IconButton(
              icon: const Icon(Icons.person_add_alt_1),
              tooltip: l10n.monitoramentoAdicionarContato,
              onPressed: () => _monitoramentoTabKey.currentState?.abrirModalAdicionarContato(),
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _abrirConfiguracoes(context),
          ),
        ],
      ),


      // Faixa do botão SOS desativado (dias bloqueados do Plano Free) no
      // topo, em qualquer aba — ver AvisoSosPlanoBanner.
      body: Column(
        children: [
          const AvisoSosPlanoBanner(),
          Expanded(
            child: _mostrandoInicio
                ? const InicioDashboard()
                : IndexedStack(
                    index: _indiceAbaAtual,
                    children: _telas,
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _BarraAbas(
        indiceAtual: _indiceAbaAtual,
        // Estado neutro do Dashboard: nenhuma aba deve parecer "ativa"
        // enquanto _mostrandoInicio for true.
        nenhumaSelecionada: _mostrandoInicio,
        onTap: _aoSelecionarAba,
        itens: [
          _ItemAba(icone: const Icon(Icons.shield), rotulo: l10n.tabSeguranca),
          _ItemAba(icone: const Icon(Icons.people), rotulo: l10n.tabFamilia),
          _ItemAba(
            icone: const Icon(Icons.location_on_outlined),
            rotulo: l10n.tabMonitoramento,
          ),
          _ItemAba(
            icone: ValueListenableBuilder<int>(
              valueListenable: AlertasRecebidosService.naoVisualizados,
              builder: (context, contagem, _) {
                return Badge(
                  isLabelVisible: contagem > 0,
                  label: Text('$contagem'),
                  child: const Icon(Icons.history),
                );
              },
            ),
            rotulo: l10n.tabHistorico,
          ),
        ],
      ),
    );
  }
}

class _ItemAba {
  const _ItemAba({required this.icone, required this.rotulo});

  final Widget icone;
  final String rotulo;
}

/// Barra de abas inferior. Substitui a `BottomNavigationBar` padrão, que
/// só aceita o rótulo como String: com o tamanho de letra "Padrão"/"Grande"
/// (ver [FontScaleService]) e idiomas de palavras longas, "Segurança",
/// "Despertador", "Monitoramento" e "Histórico" não cabiam na largura de
/// um iPhone. Aqui o rótulo tem fonte fixa (a escala de fonte do app não
/// se aplica à barra), uma linha só e `FittedBox(scaleDown)` — encolhe
/// só o que não couber, em qualquer tamanho de fonte ou idioma.
class _BarraAbas extends StatelessWidget {
  const _BarraAbas({
    required this.indiceAtual,
    required this.nenhumaSelecionada,
    required this.onTap,
    required this.itens,
  });

  final int indiceAtual;
  final bool nenhumaSelecionada;
  final ValueChanged<int> onTap;
  final List<_ItemAba> itens;

  static const Color _corFundo = Color(0xFF12131C);
  static const Color _corInativa = Color(0xFF8E8E93);

  @override
  Widget build(BuildContext context) {
    return MediaQuery.withNoTextScaling(
      child: Material(
        color: _corFundo,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                for (var i = 0; i < itens.length; i++)
                  Expanded(child: _buildItem(i)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItem(int indice) {
    final item = itens[indice];
    final bool selecionado = !nenhumaSelecionada && indice == indiceAtual;
    final Color cor = selecionado ? Colors.white : _corInativa;
    return Semantics(
      selected: selecionado,
      button: true,
      label: item.rotulo,
      excludeSemantics: true,
      child: InkResponse(
        onTap: () => onTap(indice),
        highlightShape: BoxShape.rectangle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconTheme(
                data: IconThemeData(color: cor, size: 24),
                child: item.icone,
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  item.rotulo,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: cor,
                    fontSize: 12,
                    fontWeight: selecionado ? FontWeight.w600 : FontWeight.normal,
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
