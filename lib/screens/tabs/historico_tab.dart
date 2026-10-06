import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/alertas_recebidos_service.dart';
import '../../services/area_protegida_historico_service.dart';
import '../../services/database_helper.dart';
import '../../services/historico_alertas_service.dart';
import '../../services/wallpaper_service.dart';
import '../../widgets/pin_dialog.dart';
import '../../widgets/texto_com_links.dart';
import '../alerta_recebido_screen.dart';
import '../detalhe_alerta_enviado_screen.dart';

/// Tela de Histórico Geral: mescla os eventos administrativos locais
/// (tabela 'historico') com os alertas de emergência de TERCEIROS
/// recebidos via Push FCM (tabela 'alertas_terceiros_recebidos', ver
/// [AlertasRecebidosService]/`FcmService`), organizados numa única linha
/// do tempo.
///
/// Alertas recebidos são clicáveis (item 5 do pedido de UX do
/// guardião): um alerta de FOTO abre [AlertaRecebidoScreen] (imagem
/// carregada + Baixar/Compartilhar); um alerta de LOCALIZAÇÃO abre
/// direto o app de mapas do aparelho.
///
/// Regra de negócio de privacidade/blindagem (inalterada): os registros
/// LOCAIS da categoria 'critico' (alarmes de emergência e disparos de
/// SMS de socorro do PRÓPRIO usuário) NUNCA aparecem nesta tela — só na
/// tela de Auditoria de Eventos Sensíveis. Isso é ortogonal aos alertas
/// de TERCEIROS recebidos (sempre exibidos aqui), que são o alerta de
/// OUTRA pessoa, não um evento sensível do próprio usuário.
class HistoricoTab extends StatefulWidget {
  const HistoricoTab({super.key});

  @override
  State<HistoricoTab> createState() => _HistoricoTabState();
}

/// Item normalizado da linha do tempo — une as duas fontes de dados
/// (evento local administrativo vs. alerta de terceiro recebido) atrás
/// de um único formato para a UI, sem misturar os esquemas das duas
/// tabelas de origem.
class _ItemHistorico {
  const _ItemHistorico({
    required this.ehAlertaRecebido,
    required this.id,
    required this.titulo,
    required this.descricao,
    required this.categoria,
    required this.timestamp,
    this.latitude,
    this.longitude,
    this.fotoUrl,
    this.idEntrega,
    this.nomeRemetente,
    this.mensagemOriginal,
    this.visualizado = true,
  });

  final bool ehAlertaRecebido;
  final int id;
  final String titulo;
  final String descricao;
  final String categoria;
  final String timestamp;
  final double? latitude;
  final double? longitude;
  final String? fotoUrl;
  final String? idEntrega;
  final String? nomeRemetente;
  final String? mensagemOriginal;
  final bool visualizado;

  bool get ehFoto => fotoUrl != null && fotoUrl!.isNotEmpty;
}

class _HistoricoTabState extends State<HistoricoTab> with WidgetsBindingObserver {
  final DatabaseHelper _dbHelper = DatabaseHelper();

  static const String _categoriaRecebido = 'alerta_recebido';
  static const String _categoriaEnviados = 'enviados';

  // Filtro rápido selecionado no topo (chave interna neutra, independente
  // do idioma — o rótulo exibido é traduzido separadamente em
  // [_rotuloFiltro]). 'todos' por padrão.
  String _filtroSelecionado = 'todos';

  // EXATAMENTE quatro filtros (pedido de UX): "Todos" (agendamentos e
  // mensagens diversas), "Alerta de segurança recebido" (localização/foto
  // de terceiros), "Sistema" (alterações feitas em Configurações) e
  // "Alertas enviados" — a antiga AuditoriaSensivelScreen (alarmes de
  // emergência e disparos de SMS de socorro do PRÓPRIO usuário, categoria
  // 'critico'), agora integrada aqui como um filtro em vez de tela
  // separada, protegida pelo PIN de acesso (ver bloco abaixo) em vez da
  // antiga trava de carência de 2h.
  final List<String> _filtros = const [
    'todos',
    _categoriaRecebido,
    'sistema',
    _categoriaEnviados,
  ];

  /// Rótulo traduzido exibido no chip do filtro [chave].
  String _rotuloFiltro(String chave) {
    final l10n = AppLocalizations.of(context)!;
    switch (chave) {
      case 'sistema':
        return l10n.historicoFiltroSistema;
      case _categoriaRecebido:
        return l10n.alertaRecebidoTitulo;
      case _categoriaEnviados:
        return l10n.historicoFiltroAlertasEnviados;
      case 'todos':
      default:
        return l10n.historicoFiltroTodos;
    }
  }

  bool _carregando = true;
  List<_ItemHistorico> _itens = [];

  // ==========================================================
  // "ALERTAS ENVIADOS" (ex-AuditoriaSensivelScreen, migrado para cá)
  // ==========================================================
  // Registros mais críticos do histórico (categoria 'critico' —
  // EXCLUSIVAMENTE alarmes de emergência e disparos de SMS de socorro
  // para os contatos cadastrados) só podem ser visualizados após o
  // usuário confirmar o PIN de acesso — o mesmo cadastrado na aba
  // Configurações (ver [DatabaseHelper.salvarOuAgendarPinReal]) — usando
  // o mesmo teclado numérico ([exibirDialogoPin]) reaproveitado do
  // desarme de alarmes. Nunca aparecem misturados aos demais filtros: a
  // separação é garantida na origem, por [DatabaseHelper.getHistorico]
  // (exclui a categoria 'critico') e [DatabaseHelper.getEventosSensiveis]
  // (busca exclusivamente 'critico').
  final DatabaseHelper _dbAuditoria = DatabaseHelper();
  bool _carregandoAuditoria = true;
  bool _liberadoAuditoria = false;
  String? _pinReal;
  List<Map<String, dynamic>> _eventosSensiveis = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ver [DatabaseHelper.historicoAtualizadoNotifier]: cobre o caso de um
    // evento ser gravado com esta aba já visível/em primeiro plano (ex:
    // 3ª tentativa de PIN errada resolvida dentro da própria
    // `SegurancaTab`, sem nenhuma Activity nova por cima) — complementar
    // ao `WidgetsBindingObserver` abaixo, que só cobre o app
    // minimizado/reaberto.
    DatabaseHelper.historicoAtualizadoNotifier.addListener(_aoHistoricoAtualizado);
    _areaProtegida.liberado.addListener(_aoMudarLiberacao);
    _carregarHistorico();
    _atualizarStatusAuditoria();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DatabaseHelper.historicoAtualizadoNotifier.removeListener(_aoHistoricoAtualizado);
    _areaProtegida.liberado.removeListener(_aoMudarLiberacao);
    // Saiu da aba Histórico: a área protegida volta a pedir o PIN.
    _areaProtegida.bloquear();
    super.dispose();
  }

  final AreaProtegidaHistoricoService _areaProtegida = AreaProtegidaHistoricoService();

  void _aoMudarLiberacao() {
    if (mounted) _atualizarStatusAuditoria();
  }

  /// Pede o PIN de novo (com o mesmo limite de tentativas da área) antes de
  /// apagar uma entrada protegida. `true` só com o PIN correto.
  Future<bool> _confirmarComPin() async {
    final config = await _dbAuditoria.getUserConfig();
    if (!mounted) return false;
    var confirmado = false;
    await exibirDialogoPin(
      context: context,
      pinEsperado: config?['pin_real'] as String?,
      mostrarBotaoCancelar: true,
      mensagemSucesso: AppLocalizations.of(context)!.historicoPinConfirmado,
      controleTentativas: _areaProtegida,
      aoConfirmarPinCorreto: () async => confirmado = true,
    );
    return confirmado;
  }

  void _aoHistoricoAtualizado() {
    if (!mounted) return;
    _carregarHistorico();
    _atualizarStatusAuditoria();
  }

  /// CORREÇÃO DE BUG REAL (2026-08-12): esta aba fica MONTADA O TEMPO
  /// TODO dentro do `IndexedStack` da `HomeScreen` — `initState()` (e,
  /// portanto, [_carregarHistorico]/[_atualizarStatusAuditoria]) só roda
  /// UMA VEZ, logo no login, muito antes de qualquer alerta de emergência
  /// acontecer. Quando o Cronômetro dispara um alerta com o app já em
  /// primeiro plano, a tela nativa dedicada (`RotinaCheckinAlarmActivity`,
  /// engine PRÓPRIO — ver `cronometro_disparado_screen.dart`) abre POR
  /// CIMA da `MainActivity` já em uso, sem nunca desmontar/recriar este
  /// widget — ao fechar a confirmação e voltar para trás, esta aba
  /// reaparecia com os dados de ANTES do alerta (novo evento de histórico
  /// já salvo no SQLite, mas invisível até o usuário reabrir o app do
  /// zero). `WidgetsBindingObserver` reflete corretamente essa transição:
  /// a `MainActivity` recebe `onPause`/`onResume` do Android sempre que
  /// outra Activity é empilhada por cima dela e depois finalizada — o
  /// mesmo sinal que cobre o caso mais comum de app minimizado/reaberto.
  /// Recarrega os DOIS conjuntos de dados desta tela (histórico normal +
  /// status/eventos do cofre de Auditoria) sempre que o app volta ao
  /// primeiro plano.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _carregarHistorico();
      _atualizarStatusAuditoria();
    }
  }

  Future<void> _atualizarStatusAuditoria() async {
    final config = await _dbAuditoria.getUserConfig();
    final liberado = _areaProtegida.liberado.value;
    if (!mounted) return;

    setState(() {
      _liberadoAuditoria = liberado;
      _pinReal = config?['pin_real'] as String?;
      _carregandoAuditoria = false;
    });

    if (liberado) {
      final eventos = await _dbAuditoria.getEventosSensiveis();
      if (!mounted) return;
      setState(() => _eventosSensiveis = eventos);
    } else if (_eventosSensiveis.isNotEmpty) {
      setState(() => _eventosSensiveis = []);
    }
  }

  /// Abre o teclado numérico ([exibirDialogoPin]) pedindo o mesmo PIN de
  /// 4 dígitos cadastrado em Configurações. Só ao confirmar o PIN correto
  /// é que os "Alertas Enviados" são liberados para esta sessão do app —
  /// ver [AreaProtegidaHistoricoService] (validade da liberação e bloqueio
  /// após 3 PINs errados).
  Future<void> _desbloquearComPin() async {
    await exibirDialogoPin(
      context: context,
      pinEsperado: _pinReal,
      mostrarBotaoCancelar: true,
      mensagemSucesso: AppLocalizations.of(context)!.historicoPinConfirmado,
      controleTentativas: _areaProtegida,
      aoConfirmarPinCorreto: () async {
        _areaProtegida.liberar();
        if (!mounted) return;
        await _atualizarStatusAuditoria();
      },
    );
  }

  void _confirmarBloquearNovamenteAuditoria() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lock_outline, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppLocalizations.of(ctx)!.auditoriaBloquearNovamenteTitulo,
                softWrap: true,
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        ),
        content: Text(
          AppLocalizations.of(ctx)!.auditoriaBloquearNovamenteConteudo,
          softWrap: true,
          overflow: TextOverflow.visible,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx)!.cancelar),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _bloquearNovamenteAuditoria();
            },
            icon: const Icon(Icons.lock, size: 18),
            label: Text(AppLocalizations.of(ctx)!.auditoriaBloquearNovamenteBotao),
          ),
        ],
      ),
    );
  }

  Future<void> _bloquearNovamenteAuditoria() async {
    _areaProtegida.bloquear();
    if (!mounted) return;
    await _atualizarStatusAuditoria();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context)!.auditoriaBloqueadoNovamente),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _excluirEventoSensivel(Map<String, dynamic> evento) async {
    final id = evento['id'] as int;
    await _dbAuditoria.deletarEventoHistorico(id);
    await HistoricoAlertasService().apagarFotoLocal(evento['foto_local'] as String?);
    if (!mounted) return;
    setState(() {
      _eventosSensiveis = _eventosSensiveis.where((e) => e['id'] != id).toList();
    });
  }

  Future<void> _carregarHistorico() async {
    final eventosLocais = await _dbHelper.getHistorico();
    final alertasRecebidos = await _dbHelper.getAlertasTerceirosRecebidos();

    final itens = <_ItemHistorico>[
      ...eventosLocais.map((e) => _ItemHistorico(
            ehAlertaRecebido: false,
            id: e['id'] as int,
            titulo: e['titulo'] as String? ?? '',
            descricao: e['descricao'] as String? ?? '',
            categoria: e['categoria'] as String? ?? 'sistema',
            timestamp: e['timestamp'] as String? ?? '',
          )),
      ...alertasRecebidos.map((a) {
        final fotoUrl = a['foto_url'] as String?;
        final nomeRemetente = a['nome_remetente'] as String?;
        final ehFoto = fotoUrl != null && fotoUrl.isNotEmpty;
        return _ItemHistorico(
          ehAlertaRecebido: true,
          id: a['id'] as int,
          titulo: nomeRemetente != null && nomeRemetente.isNotEmpty
              ? nomeRemetente
              : AppLocalizations.of(context)!.alertaRecebidoTitulo,
          descricao: ehFoto
              ? AppLocalizations.of(context)!.alertaRecebidoBaixarFoto
              : (a['mensagem'] as String? ?? ''),
          categoria: _categoriaRecebido,
          timestamp: a['recebido_em'] as String? ?? '',
          latitude: (a['latitude'] as num?)?.toDouble(),
          longitude: (a['longitude'] as num?)?.toDouble(),
          fotoUrl: fotoUrl,
          idEntrega: a['id_entrega'] as String?,
          nomeRemetente: nomeRemetente,
          mensagemOriginal: a['mensagem'] as String?,
          visualizado: (a['visualizado'] as int? ?? 0) == 1,
        );
      }),
    ];

    itens.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    if (!mounted) return;
    setState(() {
      _itens = itens;
      _carregando = false;
    });
  }

  List<_ItemHistorico> get _itensFiltrados {
    if (_filtroSelecionado == 'todos') return _itens;
    return _itens.where((e) => e.categoria == _filtroSelecionado).toList();
  }

  Color _corCategoria(String categoria) {
    switch (categoria) {
      case _categoriaRecebido:
        return Colors.deepOrange;
      case 'seguranca':
        return Colors.redAccent;
      case 'familia':
        return Colors.blueAccent;
      case 'sistema':
        return Colors.green.shade600;
      default:
        return Colors.grey;
    }
  }

  IconData _iconeItem(_ItemHistorico item) {
    if (item.ehAlertaRecebido) {
      return item.ehFoto ? Icons.photo_camera : Icons.location_on;
    }
    switch (item.categoria) {
      case 'seguranca':
        return Icons.shield_outlined;
      case 'familia':
        return Icons.people_alt;
      case 'sistema':
        return Icons.settings_suggest;
      default:
        return Icons.event_note;
    }
  }

  /// Data + hora EXATA no idioma ativo do usuário (ex: "14/08/2026 22:15"
  /// em pt-BR) — reespecificação do usuário (2026-08-14): "todas as
  /// mensagens" devem mostrar o horário e data exata "para melhor
  /// visualização", em vez da descrição relativa ("há X minutos") usada
  /// antes. Mesmo formato de [AlertaRecebidoScreen._dataHoraExata].
  String _formatarDataHora(String timestampIso) {
    final dataHora = DateTime.tryParse(timestampIso);
    if (dataHora == null) return '';
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMd(locale).add_Hm().format(dataHora.toLocal());
  }

  Future<void> _excluirEvento(int id) async {
    await _dbHelper.deletarEventoHistorico(id);
    if (!mounted) return;
    setState(() {
      _itens.removeWhere((e) => !e.ehAlertaRecebido && e.id == id);
    });
  }

  /// Exclui um alerta de TERCEIRO recebido pelo gesto de swipe — item
  /// separado de [_excluirEvento] pois vive numa tabela diferente.
  Future<void> _excluirAlertaRecebido(int id) async {
    await _dbHelper.deletarAlertaTerceiroRecebido(id);
    if (!mounted) return;
    setState(() {
      _itens.removeWhere((e) => e.ehAlertaRecebido && e.id == id);
    });
    await AlertasRecebidosService.atualizarContagem();
  }

  /// Exibe a confirmação e, se aceita, apaga TODAS as mensagens da
  /// categoria atualmente em exibição (filtro selecionado) de uma vez —
  /// opção "Limpar Histórico" pedida no topo de cada filtro.
  void _confirmarLimparHistoricoAtual() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.historicoLimparConfirmarTitulo),
        content: Text(l10n.historicoLimparConfirmarConteudo, softWrap: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _limparHistoricoAtual();
            },
            child: Text(l10n.historicoLimparBotao),
          ),
        ],
      ),
    );
  }

  Future<void> _limparHistoricoAtual() async {
    switch (_filtroSelecionado) {
      case _categoriaRecebido:
        await _dbHelper.limparAlertasTerceirosRecebidos();
        break;
      case 'sistema':
        await _dbHelper.limparHistoricoPorCategoria('sistema');
        break;
      case _categoriaEnviados:
        // Área protegida: apagar pede o PIN de novo.
        if (!await _confirmarComPin()) return;
        final eventos = await _dbAuditoria.getEventosSensiveis();
        await _dbAuditoria.limparHistoricoPorCategoria('critico');
        for (final evento in eventos) {
          await HistoricoAlertasService().apagarFotoLocal(evento['foto_local'] as String?);
        }
        if (mounted) setState(() => _eventosSensiveis = []);
        return;
      case 'todos':
      default:
        await _dbHelper.limparHistoricoGeral();
        await _dbHelper.limparAlertasTerceirosRecebidos();
    }
    await AlertasRecebidosService.atualizarContagem();
    if (!mounted) return;
    await _carregarHistorico();
  }

  /// Roteamento do toque em um alerta de TERCEIRO recebido (item 5 do
  /// pedido de UX): foto -> abre [AlertaRecebidoScreen] (imagem +
  /// Baixar/Compartilhar); localização -> abre direto o app de mapas do
  /// aparelho. Marca como visualizado em ambos os casos.
  Future<void> _abrirAlertaRecebido(_ItemHistorico item) async {
    if (item.idEntrega != null && item.idEntrega!.isNotEmpty) {
      await AlertasRecebidosService.marcarVisualizadoPorIdEntrega(item.idEntrega!);
    } else {
      await AlertasRecebidosService.marcarVisualizado(item.id);
    }
    if (!item.visualizado && mounted) {
      setState(() {
        _itens = _itens
            .map((e) => e.id == item.id && e.ehAlertaRecebido
                ? _ItemHistorico(
                    ehAlertaRecebido: e.ehAlertaRecebido,
                    id: e.id,
                    titulo: e.titulo,
                    descricao: e.descricao,
                    categoria: e.categoria,
                    timestamp: e.timestamp,
                    latitude: e.latitude,
                    longitude: e.longitude,
                    fotoUrl: e.fotoUrl,
                    idEntrega: e.idEntrega,
                    nomeRemetente: e.nomeRemetente,
                    mensagemOriginal: e.mensagemOriginal,
                    visualizado: true,
                  )
                : e)
            .toList();
      });
    }

    if (!mounted) return;

    if (item.ehFoto) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AlertaRecebidoScreen(
            mensagem: item.mensagemOriginal ?? item.descricao,
            nomeRemetente: item.nomeRemetente,
            latitude: item.latitude,
            longitude: item.longitude,
            fotoUrl: item.fotoUrl,
            idEntrega: item.idEntrega,
            recebidoEm: item.timestamp,
          ),
        ),
      );
      return;
    }

    if (item.latitude != null && item.longitude != null) {
      final uri = Uri.parse('https://maps.google.com/?q=${item.latitude},${item.longitude}');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  /// Abre [url] no aplicativo mais apropriado do aparelho: um link do
  /// Google Maps abre o próprio app de mapas (coordenadas GPS); um link
  /// do Firebase Storage abre o navegador, exibindo a foto em alta
  /// resolução (com opção nativa de download/compartilhamento do
  /// navegador). Usado por [_linkificarTexto] — item 6 do pedido de UX:
  /// transformar os textos de GPS/foto do histórico de "Alertas
  /// Enviados" em links de fato clicáveis.
  Future<void> _abrirLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('⚠️ [HistoricoTab] Falha ao abrir link do histórico: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: WallpaperService.wallpaperNotifier,
      builder: (context, fundoAtivo, _) {
        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(
              image: AssetImage(fundoAtivo),
              fit: BoxFit.cover,
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 8),
                _construirFiltrosRapidos(),
                if (_mostrarBotaoLimpar) _construirBotaoLimpar(),
                const SizedBox(height: 8),
                Expanded(child: _construirCorpo()),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Se o botão "Limpar Histórico" do topo deve aparecer para o filtro
  /// atualmente selecionado. Para "Alertas enviados" a visibilidade
  /// depende de [_eventosSensiveis] (que vive fora de [_itens] por
  /// desenho — ver [DatabaseHelper.getHistorico]), não de
  /// [_itensFiltrados].
  bool get _mostrarBotaoLimpar {
    if (_filtroSelecionado == _categoriaEnviados) {
      return _liberadoAuditoria && _eventosSensiveis.isNotEmpty;
    }
    return !_carregando && _itensFiltrados.isNotEmpty;
  }

  /// Corpo principal abaixo dos filtros: para "Alertas enviados", exibe a
  /// UI de bloqueio por PIN/lista liberada (migrada da antiga
  /// AuditoriaSensivelScreen); para os demais filtros, a timeline normal.
  Widget _construirCorpo() {
    if (_filtroSelecionado == _categoriaEnviados) {
      if (_carregandoAuditoria) {
        return const Center(child: CircularProgressIndicator());
      }
      return _liberadoAuditoria
          ? _construirListaLiberadaAuditoria()
          : _construirTelaBloqueadaPin();
    }

    if (_carregando) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_itensFiltrados.isEmpty) {
      return _construirEstadoVazio();
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _itensFiltrados.length,
      itemBuilder: (context, index) {
        final item = _itensFiltrados[index];
        final isUltimo = index == _itensFiltrados.length - 1;
        return _construirCardTimeline(item, isUltimo);
      },
    );
  }

  /// Botão "Limpar Histórico" — apaga de uma vez todas as mensagens da
  /// categoria/filtro atualmente em exibição (pedido de UX).
  Widget _construirBotaoLimpar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _confirmarLimparHistoricoAtual,
          icon: const Icon(Icons.delete_sweep_outlined, size: 18, color: Colors.redAccent),
          label: Text(
            AppLocalizations.of(context)!.historicoLimparBotao,
            style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }

  Widget _construirFiltrosRapidos() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _filtros.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filtro = _filtros[index];
          final selecionado = _filtroSelecionado == filtro;
          return FilterChip(
            label: Text(
              _rotuloFiltro(filtro),
              softWrap: true,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: selecionado ? Colors.white : Colors.black87,
                fontWeight: selecionado ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            selected: selecionado,
            onSelected: (_) => setState(() => _filtroSelecionado = filtro),
            selectedColor: const Color(0xFF4C7040),
            backgroundColor: Colors.white.withOpacity(0.85),
            checkmarkColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: selecionado ? const Color(0xFF4C7040) : Colors.grey.shade300),
            ),
          );
        },
      ),
    );
  }

  Widget _construirEstadoVazio() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Flexible(
              child: Text(
                AppLocalizations.of(context)!.historicoNenhumEvento,
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirCardTimeline(_ItemHistorico item, bool isUltimo) {
    final cor = _corCategoria(item.categoria);
    final icone = _iconeItem(item);

    final conteudoCard = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Coluna da linha do tempo: ícone + linha vertical sutil.
          Column(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cor.withOpacity(0.15),
                  border: Border.all(color: cor, width: 1.5),
                ),
                child: Icon(icone, color: cor, size: 18),
              ),
              if (!isUltimo)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: Colors.grey.withOpacity(0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          // Card de conteúdo do evento.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: item.ehAlertaRecebido && !item.visualizado
                        ? cor
                        : Colors.white.withOpacity(0.4),
                    width: item.ehAlertaRecebido && !item.visualizado ? 2 : 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Barra lateral de categoria.
                    Container(
                      width: 5,
                      decoration: BoxDecoration(
                        color: cor,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          bottomLeft: Radius.circular(14),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (item.ehAlertaRecebido && !item.visualizado)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6, top: 4),
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(shape: BoxShape.circle, color: cor),
                                    ),
                                  ),
                                Expanded(
                                  child: Text(
                                    item.titulo,
                                    softWrap: true,
                                    overflow: TextOverflow.clip,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _formatarDataHora(item.timestamp),
                                    textAlign: TextAlign.right,
                                    softWrap: true,
                                    overflow: TextOverflow.clip,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (item.ehAlertaRecebido)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: Icon(Icons.chevron_right, color: Colors.grey.shade700, size: 18),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            // Item 3 (reespecificação do usuário,
                            // 2026-08-14): links de localização/foto
                            // embutidos na descrição (ex: mensagens de
                            // alertas recebidos) agora sempre aparecem em
                            // AZUL e clicáveis — mesmo tratamento já dado
                            // à lista de "Alertas Enviados" abaixo, via
                            // [construirSpansComLinks].
                            Text.rich(
                              TextSpan(
                                children: construirSpansComLinks(
                                  item.descricao,
                                  TextStyle(
                                    fontSize: 13,
                                    color: Colors.black.withOpacity(0.75),
                                  ),
                                  _abrirLink,
                                ),
                              ),
                              softWrap: true,
                              overflow: TextOverflow.clip,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // Alertas recebidos (item 5) são clicáveis, abrindo o mapa/a foto —
    // envolvido pelo Dismissible comum abaixo para também poderem ser
    // excluídos por swipe (pedido de UX), cada um na sua própria tabela.
    final conteudoComToque = item.ehAlertaRecebido
        ? InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _abrirAlertaRecebido(item),
            child: conteudoCard,
          )
        : conteudoCard;

    return Dismissible(
      key: ValueKey('${item.ehAlertaRecebido ? "recebido" : "local"}_${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 16, left: 48),
        decoration: BoxDecoration(
          color: Colors.red.shade400,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) =>
          item.ehAlertaRecebido ? _excluirAlertaRecebido(item.id) : _excluirEvento(item.id),
      child: conteudoComToque,
    );
  }

  // ==========================================================
  // UI DE "ALERTAS ENVIADOS" (ex-AuditoriaSensivelScreen)
  // ==========================================================

  Widget _construirTelaBloqueadaPin() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lock_outline,
              size: 72,
              color: Color(0xFF4C7040),
            ),
            const SizedBox(height: 24),
            Text(
              AppLocalizations.of(context)!.auditoriaRegistrosProtegidos,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context)!.auditoriaAvisoSolicitacao,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _desbloquearComPin,
                icon: const Icon(Icons.pin_outlined),
                label: Text(AppLocalizations.of(context)!.auditoriaSolicitarLiberacaoBotao),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4C7040),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirListaLiberadaAuditoria() {
    if (_eventosSensiveis.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_user, size: 56, color: Colors.green.shade400),
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(context)!.auditoriaNenhumEvento,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          color: Colors.green.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.verified_user, color: Colors.green.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.auditoriaPrazoLiberado,
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _confirmarBloquearNovamenteAuditoria,
                icon: Icon(Icons.lock, color: Colors.green.shade800, size: 16),
                label: Text(
                  AppLocalizations.of(context)!.auditoriaBloquearNovamenteBotao,
                  style: TextStyle(
                    color: Colors.green.shade800,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _eventosSensiveis.length,
            itemBuilder: (context, index) {
              final evento = _eventosSensiveis[index];
              final id = evento['id'] as int;
              final timestamp = evento['timestamp'] as String? ?? '';
              final tipo = evento['tipo'] as String?;
              final l10n = AppLocalizations.of(context)!;
              final estruturado = tipo != null;
              final titulo = estruturado
                  ? HistoricoAlertasService.tituloDoTipo(l10n, tipo)
                  : (evento['titulo'] as String? ?? '');
              final status = StatusAlertaVisual.de(l10n, evento['status'] as String?);
              final temFoto = ((evento['foto_local'] as String?) ?? (evento['foto_url'] as String?)) != null;
              final descricao = estruturado
                  ? [
                      if (status != null) status.rotulo,
                      if (evento['latitude'] != null) l10n.historicoComLocalizacao,
                      if (temFoto) l10n.historicoComFoto,
                    ].join(' · ')
                  : (evento['descricao'] as String? ?? '');

              return Dismissible(
                key: ValueKey('critico_$id'),
                direction: DismissDirection.endToStart,
                // Apagar uma entrada protegida pede o PIN de novo.
                confirmDismiss: (_) => _confirmarComPin(),
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade400,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.delete_outline, color: Colors.white),
                ),
                onDismissed: (_) => _excluirEventoSensivel(evento),
                child: Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    onTap: estruturado
                        ? () => Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => DetalheAlertaEnviadoScreen(evento: evento),
                            ))
                        : null,
                    leading: CircleAvatar(
                      backgroundColor: (status?.cor ?? Colors.red.shade400).withOpacity(0.12),
                      child: Icon(
                        temFoto ? Icons.photo_camera : (status?.icone ?? Icons.shield_outlined),
                        color: status?.cor ?? Colors.red.shade400,
                      ),
                    ),
                    title: Text(titulo, style: const TextStyle(fontWeight: FontWeight.bold)),
                    // Coordenadas GPS e o link da foto (quando presentes no
                    // texto — ver EmergencyAlertService) viram links de
                    // fato clicáveis: GPS abre o Google Maps, foto abre a
                    // imagem em alta resolução no navegador.
                    subtitle: Text.rich(
                      TextSpan(
                        children: construirSpansComLinks(
                          descricao,
                          TextStyle(fontSize: 14, color: Colors.grey.shade800),
                          _abrirLink,
                        ),
                      ),
                    ),
                    trailing: Text(
                      _formatarDataHora(timestamp),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
