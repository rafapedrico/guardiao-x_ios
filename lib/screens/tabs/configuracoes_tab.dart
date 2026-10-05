import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../app_navigator.dart';
import '../../services/database_helper.dart';
import '../../services/device_admin_service.dart';
import '../../services/wallpaper_service.dart';
import '../../services/font_scale_service.dart';
import '../../services/contatos_emergencia_service.dart';
import '../../services/alarme_sonoro_service.dart';
import '../../services/firebase_auth_service.dart';
import '../../services/firebase_sync_service.dart';
import '../../services/locale_service.dart';
import '../../services/localization_service.dart';
import '../../services/battery_optimization_service.dart';
import '../../services/sms_permission_service.dart';
import '../../utils/telefone_utils.dart';
import '../excluir_conta_screen.dart';
import '../login_screen.dart';
import '../permissoes_status_screen.dart';
import '../diagnostico_screen.dart';
import '../../widgets/contato_agenda_picker.dart';



// Planos de fundo reais disponíveis em assets/ — nomes traduzidos via
// AppLocalizations, ver [_PresetWallpaper.rotulo].
const List<_PresetWallpaper> _presetWallpapers = [
  _PresetWallpaper('blue'),
  _PresetWallpaper('dark'),
  _PresetWallpaper('gray'),
  _PresetWallpaper('green'),
  _PresetWallpaper('lavender'),
  _PresetWallpaper('light'),
];

class ConfiguracoesTab extends StatefulWidget {
  const ConfiguracoesTab({super.key});

  @override
  State<ConfiguracoesTab> createState() => _ConfiguracoesTabState();
}

class _ConfiguracoesTabState extends State<ConfiguracoesTab> with WidgetsBindingObserver {
  final DatabaseHelper _db = DatabaseHelper();
  final AlarmeSonoroService _alarmeSonoroService = AlarmeSonoroService();
  final LocalizationService _localizationService = LocalizationService();

  // Bloqueio automático de tela (Administrador do Dispositivo — P4 da
  // sequência unificada de SOS, ver SosDisparoService/DeviceAdminService):
  // migrado da aba Segurança para cá. Regra de silêncio: só exibe algo
  // quando a permissão AINDA NÃO está ativa (pedindo ativação); uma vez
  // concedida, fica 100% silencioso — só volta a aparecer se a permissão
  // for revogada manualmente nas configurações do Android (detectado ao
  // voltar ao app em foreground, ver didChangeAppLifecycleState).
  bool _deviceAdminAtivo = false;
  bool _carregandoDeviceAdmin = true;

  // Isenção de otimização de bateria (ver BatteryOptimizationService) —
  // mesmo padrão de silêncio do card de Device Admin acima: só aparece
  // enquanto a isenção AINDA NÃO está concedida.
  bool _bateriaIsenta = false;
  bool _carregandoBateria = true;

  Map<String, dynamic>? _userConfig;
  bool _loading = true;

  // Seção "Meu Perfil" (ver FirebaseSyncService) — exibe e permite editar
  // o número vinculado à conta atual (Firebase/SQLite).
  //
  // HISTÓRICO: entre 2026-08-16 e 2026-08-23 este campo foi somente
  // leitura (só editável via SMS OTP) — reespecificação de segurança que
  // fechou a brecha de sequestro de alerta (digitar o número de outra
  // pessoa e passar a receber os alertas endereçados a ela). A remoção do
  // SMS OTP (decisão de arquitetura 2026-08-23) reabriu a edição direta,
  // mas SEM reabrir aquela brecha: toda escrita passa por
  // [FirebaseSyncService.salvarTelefonePerfil] (Cloud Function
  // `atualizarTelefonePerfil`), que impõe unicidade estrita server-side
  // (`firestore.rules` nega escrita direta do cliente neste campo) — não
  // prova posse do número, mas impede duas contas com o MESMO telefone.
  String? _telefoneAtual;
  bool _carregandoTelefone = true;
  bool _salvandoTelefone = false;

  // Estado local do Alerta Sonoro Customizável (Etapa 1 - Expansão
  // Global): número do som selecionado (1-10) e duração do toque em
  // segundos, carregados/persistidos via [AlarmeSonoroService].
  int _somSelecionado = AlarmeSonoroService.somPadrao;
  // TODO(duração-do-alerta-sonoro): carregado/persistido (ver
  // [_selecionarDuracaoSom] e o load em torno da linha 290), mas ainda
  // sem controle de UI (Slider/Stepper) que o exponha ao usuário — só a
  // seleção do SOM (_somSelecionado) chegou a ser conectada. Suprimido
  // aqui de propósito (não é lixo, é feature em andamento) em vez de
  // apagar o campo ou inventar uma UI sem contexto de design.
  // ignore: unused_field
  int _duracaoSomSegundos = AlarmeSonoroService.duracaoPadraoSegundos;
  bool _carregandoAlarmeSonoro = true;
  int? _somTestandoAgora;

  // Estado local do idioma selecionado (Etapa 2 - Internacionalização).
  String _idiomaSelecionado = LocalizationService.idiomaPadrao;
  bool _carregandoIdioma = true;


  // Máximo de contatos de emergência permitidos.
  static const int _maxContatos = 3;

  // Lista de contatos de emergência carregada do SQLite (tabela isolada
  // 'contatos_emergencia').
  List<Map<String, dynamic>> _contatosEmergencia = [];
  bool _carregandoContatos = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConfig();
    _carregarContatosEmergencia();
    _carregarConfiguracaoAlarmeSonoro();
    _carregarConfiguracaoIdioma();
    _carregarStatusDeviceAdmin();
    _carregarStatusBateria();
    _carregarTelefoneAtual();
  }

  /// Firestore continua sendo a fonte de verdade — só cai para o cache
  /// local (`user_config.telefone`, gravado por [_editarTelefone]/
  /// `CompletarPerfilScreen`/`CadastroScreen` sempre que o telefone é
  /// salvo com sucesso) quando a leitura online falhar (ex: sem internet
  /// no momento), para nunca exibir "sem telefone" indevidamente a um
  /// usuário que já tem número cadastrado, só porque está offline agora.
  Future<void> _carregarTelefoneAtual() async {
    var telefone = await FirebaseSyncService().obterTelefoneAtual();
    if (telefone == null || telefone.trim().isEmpty) {
      try {
        final config = await _db.getUserConfig();
        telefone = config?['telefone'] as String?;
      } catch (_) {
        // Sem cache local disponível — mantém `telefone` como está.
      }
    }
    if (mounted) {
      setState(() {
        _telefoneAtual = telefone;
        _carregandoTelefone = false;
      });
    }
  }

  /// Abre o diálogo de edição do telefone de contato e, se confirmado,
  /// grava via [FirebaseSyncService.salvarTelefonePerfil] (unicidade
  /// estrita server-side — ver comentário em [_telefoneAtual]). Erros de
  /// "já em uso" ficam visíveis DENTRO do próprio diálogo (o usuário pode
  /// tentar outro número sem reabrir o fluxo); qualquer outro erro fecha
  /// o diálogo e mostra um SnackBar genérico.
  Future<void> _editarTelefone() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: _telefoneAtual ?? '');
    final formKey = GlobalKey<FormState>();
    String? erroDialogo;

    final numeroSalvo = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(l10n.meuPerfilTelefoneEditarTooltip),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: controller,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10n.campoCelularLabel,
                errorText: erroDialogo,
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
          ),
          actions: [
            TextButton(
              onPressed: _salvandoTelefone ? null : () => Navigator.of(ctx).pop(),
              child: Text(l10n.cancelar),
            ),
            FilledButton(
              onPressed: _salvandoTelefone
                  ? null
                  : () async {
                      if (formKey.currentState?.validate() != true) return;
                      final numero = TelefoneUtils.normalizarE164(controller.text)!;
                      setDialogState(() => _salvandoTelefone = true);
                      final resultado =
                          await FirebaseSyncService().salvarTelefonePerfil(numero);
                      setDialogState(() => _salvandoTelefone = false);
                      switch (resultado) {
                        case ResultadoSalvarTelefone.sucesso:
                          if (ctx.mounted) Navigator.of(ctx).pop(numero);
                          return;
                        case ResultadoSalvarTelefone.telefoneEmUso:
                          setDialogState(() => erroDialogo = l10n.telefoneJaEmUso);
                          return;
                        case ResultadoSalvarTelefone.erro:
                          setDialogState(() => erroDialogo = l10n.erroLoginGenerico);
                          return;
                      }
                    },
              child: _salvandoTelefone
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.salvar),
            ),
          ],
        ),
      ),
    );

    if (numeroSalvo == null || !mounted) return;

    try {
      await _db.salvarTelefoneLocal(numeroSalvo);
    } catch (e) {
      debugPrint('⚠️ [ConfiguracoesTab] Falha ao gravar telefone no SQLite local: $e');
    }
    setState(() => _telefoneAtual = numeroSalvo);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.telefoneSalvoComSucesso),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.green,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reflete na UI a decisão do usuário no diálogo NATIVO de Device Admin
    // (ou uma revogação manual feita nas configurações do Android) assim
    // que o app volta ao primeiro plano — não há callback direto para
    // esse resultado, então basta reconsultar o status.
    if (state == AppLifecycleState.resumed) {
      _carregarStatusDeviceAdmin();
      _carregarStatusBateria();
    }
  }

  Future<void> _carregarStatusDeviceAdmin() async {
    final ativo = await DeviceAdminService().estaAtivo();
    if (mounted) {
      setState(() {
        _deviceAdminAtivo = ativo;
        _carregandoDeviceAdmin = false;
      });
    }
  }

  Future<void> _carregarStatusBateria() async {
    final isento = await BatteryOptimizationService().estaIsento();
    if (mounted) {
      setState(() {
        _bateriaIsenta = isento;
        _carregandoBateria = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Garante que nenhum som de teste continue tocando após sair da
    // tela de Configurações.
    _alarmeSonoroService.pararTeste();
    super.dispose();
  }

  // ==========================================================
  // ALERTA SONORO CUSTOMIZÁVEL (Etapa 1 - Expansão Global)
  // ==========================================================

  Future<void> _carregarConfiguracaoAlarmeSonoro() async {
    setState(() => _carregandoAlarmeSonoro = true);
    try {
      final som = await _alarmeSonoroService.carregarSomSelecionado();
      final duracao = await _alarmeSonoroService.carregarDuracaoSegundos();
      if (mounted) {
        setState(() {
          _somSelecionado = som;
          _duracaoSomSegundos = duracao;
          _carregandoAlarmeSonoro = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _carregandoAlarmeSonoro = false);
    }
  }
Future<void> _selecionarSom(int? numero) async {
    if (numero == null) return;
    setState(() => _somSelecionado = numero);
    await _alarmeSonoroService.salvarSomSelecionado(numero);
    await _db.salvarSomAlarmeSelecionado(numero);

    // 🟢 GRAVAÇÃO DIRETA NO SHAREDPREFERENCES PARA O BOTÃO AZUL LER:
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('tom_alarme_selecionado', 'som_$numero.mp3');
    await prefs.setInt('som_selecionado', numero);
    await prefs.reload();

    debugPrint('🎵 Som do alarme atualizado com sucesso para: som_$numero.mp3');
  }
 

  // TODO(duração-do-alerta-sonoro): pronto pra usar assim que houver um
  // controle de UI que o chame (ver nota em _duracaoSomSegundos acima).
  // ignore: unused_element
  Future<void> _selecionarDuracaoSom(int segundos) async {
    setState(() => _duracaoSomSegundos = segundos);
    await _alarmeSonoroService.salvarDuracaoSegundos(segundos);
    await _db.salvarDuracaoSomAlarme(segundos);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('alarm_duration', segundos);
  }


  /// Testa/ouve o som escolhido (toque único, sem loop), usado pelo
  /// botão de preview ao lado do Dropdown de seleção de som.
  ///
  /// Se o retorno do serviço indicar falha (asset vazio/inválido —
  /// placeholder ainda não substituído por um áudio real em
  /// `assets/sounds/`), exibe uma SnackBar amigável avisando o usuário,
  /// em vez de deixar o botão "testar" parecer simplesmente quebrado.
  Future<void> _testarSom(int numero) async {
    setState(() => _somTestandoAgora = numero);
    final sucesso = await _alarmeSonoroService.testarSom(numero);

    if (!sucesso && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.somTesteVazio),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    // Reseta o indicador visual de "tocando" em exatamente 4 segundos,
    // sincronizado com o auto-stop de 4s aplicado pelo
    // AlarmeSonoroService.testarSom (ver alarme_sonoro_service.dart).
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _somTestandoAgora == numero) {
        setState(() => _somTestandoAgora = null);
      }
    });

  }


  // ==========================================================
  // INTERNACIONALIZAÇÃO (Etapa 2 - Expansão Global)
  // ==========================================================

  Future<void> _carregarConfiguracaoIdioma() async {
    setState(() => _carregandoIdioma = true);
    try {
      final idioma = await _localizationService.carregarIdioma();
      if (mounted) {
        setState(() {
          _idiomaSelecionado = idioma;
          _carregandoIdioma = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _carregandoIdioma = false);
    }
  }

  Future<void> _selecionarIdioma(String? codigo) async {
    if (codigo == null) return;
    setState(() => _idiomaSelecionado = codigo);
    await _localizationService.salvarIdioma(codigo);
    // Aplica o novo idioma IMEDIATAMENTE em toda a árvore de widgets (ver
    // LocaleService/main.dart) — pt/en/es têm tradução completa; os
    // demais 8 idiomas do seletor ainda caem para o português até
    // ganharem seu próprio arquivo .arb.
    await LocaleService.definirIdioma(codigo);
    if (mounted) {
      final nomeNativo = _localizationService.idiomaPorCodigo(codigo).nomeNativo;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.idiomaAlteradoSnackbar(nomeNativo)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }


  Future<void> _carregarContatosEmergencia() async {
    setState(() => _carregandoContatos = true);
    try {
      // Antes de exibir a lista, remove definitivamente qualquer contato
      // cuja trava de segurança de 2h já tenha expirado.
      await _db.processarExclusoesPendentesExpiradas();
      final contatos = await _db.getContatosEmergencia();
      if (mounted) {
        setState(() {
          _contatosEmergencia = contatos;
          _carregandoContatos = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _carregandoContatos = false);
    }
  }

  /// Retorna true se o contato estiver marcado como "exclusão pendente"
  /// (aguardando o prazo de segurança de 2h para remoção definitiva).
  bool _isExclusaoPendente(Map<String, dynamic> contato) {
    final valor = contato['exclusao_pendente'];
    return valor == 1 || valor == true;
  }

  /// Solicita permissão de acesso aos contatos e, caso concedida, abre o
  /// seletor nativo de contatos para o usuário escolher um familiar.
  /// Após a seleção, o número é limpo e salvo na tabela isolada
  /// 'contatos_emergencia' do SQLite.
  Future<void> _adicionarContatoDaAgenda() async {
    // Capturado ANTES de qualquer 'await' para nunca usar o BuildContext
    // após um async gap (ver uso na linha do fallback de nome abaixo).
    final semNomeFallback = AppLocalizations.of(context)!.familiaSemNome;

    if (_contatosEmergencia.length >= _maxContatos) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.contatosMaximoAtingido(_maxContatos)),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 0) Verifica/solicita a permissão de SMS de emergência ANTES de
    // finalizar o cadastro do PRIMEIRO contato (ver SmsPermissionService)
    // — momento mais contextual para explicar o motivo: é exatamente
    // para ESTE contato que o SMS de pânico seria enviado. Nunca bloqueia
    // o cadastro em si, mesmo se o usuário negar.
    if (_contatosEmergencia.isEmpty) {
      await SmsPermissionService().verificarAoAdicionarPrimeiroContato(context);
      if (!mounted) return;
    }

    // 1–3) Permissão, seletor nativo e escolha do telefone (ver
    // [escolherContatoDaAgenda]: usa os dados do próprio seletor, então
    // funciona com Contatos em "Acesso Limitado", inclusive fora da lista
    // liberada). `null` = cancelou ou sem telefone (já avisado).
    if (!mounted) return;
    final contatoEscolhido = await escolherContatoDaAgenda(context);
    if (contatoEscolhido == null) return;

    final nome = contatoEscolhido.nome.isNotEmpty ? contatoEscolhido.nome : semNomeFallback;
    // Normaliza para E.164 internacional (ver TelefoneUtils) — CORREÇÃO
    // DE BUG REAL: números importados da agenda costumam já vir com o
    // DDI embutido (ex: "5515981343706", sem o "+"); a limpeza antiga só
    // removia caracteres de formatação e deixava esse número "cru" no
    // banco, que o backend então prefixava com "+55" de novo (DDI
    // duplicado, ex: "+555515981343706") — nem SMS nem os demais canais
    // chegavam de verdade a esse número. `TelefoneUtils.normalizarE164`
    // detecta e remove esse DDI duplicado corretamente, para qualquer
    // país.
    final telefoneOriginal = contatoEscolhido.telefone;
    final telefoneNormalizado = TelefoneUtils.normalizarE164(telefoneOriginal);

    if (telefoneNormalizado == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.telefoneInvalido),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    // 4) Salva na tabela isolada 'contatos_emergencia'.
    await _db.inserirContatoEmergencia({
      'nome': nome,
      'telefone': telefoneNormalizado,
    });

    // Registra no histórico ('familia') a adição do novo contato de
    // emergência, tornando a ação 100% transparente e auditável.
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoContatoAdicionadoTitulo,
        descricao: l10n.historicoContatoAdicionadoDescricao(nome),
        categoria: 'familia',
      );
    }

    await _carregarContatosEmergencia();

    // Notifica a aba Família (via ValueNotifier global) para que ela
    // recarregue automaticamente sua lista de contatos de emergência,
    // sem precisar que o usuário troque de aba manualmente ou puxe para
    // atualizar.
    ContatosEmergenciaService.notificarAlteracao();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.contatoAdicionado(nome)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green,
        ),
      );
    }
  }


  /// Solicita a exclusão de um contato de emergência, ativando a trava de
  /// segurança de 2h. O contato NÃO é removido imediatamente: fica marcado
  /// como "exclusao_pendente" e continua recebendo alertas de emergência
  /// normalmente até que o prazo de 2h expire.
  ///
  /// Exibe o modal de confirmação ("Apagar contato" / "Se aprovada a
  /// efetivação será concluída em 2h00") ANTES de sequer iniciar a
  /// contagem de 2h — o ícone de lixeira, sozinho, não deve mais
  /// disparar a exclusão. Só ao tocar em "Confirmar" é que
  /// [_excluirContato] (e, com ele, a trava de segurança de 2h) é
  /// acionado; "Cancelar" ou fechar o diálogo não tem nenhum efeito.
  Future<void> _confirmarEExcluirContato(int id, String nome) async {
    final l10n = AppLocalizations.of(context)!;
    final bool? confirmou = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            l10n.contatoApagarConfirmacaoTitulo,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          content: Text(
            l10n.contatoApagarConfirmacaoMensagem,
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelar),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.confirmar, style: const TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (confirmou != true || !mounted) return;
    await _excluirContato(id, nome);
  }

  Future<void> _excluirContato(int id, String nome) async {
    await _db.solicitarExclusaoContatoEmergencia(id);

    // Registra no histórico ('familia') a solicitação de exclusão do
    // contato, deixando claro que a remoção definitiva ainda está sujeita
    // à trava de segurança de 2h.
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoContatoExclusaoSolicitadaTitulo,
        descricao: l10n.historicoContatoExclusaoSolicitadaDescricao(nome),
        categoria: 'familia',
      );
    }

    await _carregarContatosEmergencia();

    // Notifica a aba Família (via ValueNotifier global) para que ela
    // recarregue automaticamente sua lista de contatos de emergência,
    // refletindo imediatamente o estado "Removendo em 2h...".
    ContatosEmergenciaService.notificarAlteracao();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.contatoRemocaoSolicitada(nome)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }



  Future<void> _loadConfig() async {
    setState(() => _loading = true);
    try {
      final config = await _db.getUserConfig();
      if (mounted) {
        setState(() {
          _userConfig = config;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? get _pinReal => _userConfig?['pin_real'] as String?;
  String? get _senhaPendente => _userConfig?['senha_pendente'] as String?;

  String? get _planoDeFundoUrl => _userConfig?['plano_de_fundo_url'] as String?;

  Future<void> _ensureUserConfig() async {
    if (_userConfig == null) {
      final id = await _db.insertUserConfig({
        'pin_real': null,
        'tempo_padrao_timer': 15,
        'tipo_plano': 'free',
        'plano_de_fundo_url': null,
      });
      _userConfig = {'id': id, 'tipo_plano': 'free', 'tempo_padrao_timer': 15};
    }
  }

  void _showPinRealDialog() {
    final pinController = TextEditingController(text: _pinReal ?? '');
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.lock_outline, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppLocalizations.of(ctx)!.pinRealTitulo,
                softWrap: true,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(ctx)!.pinRealDescricao,
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: pinController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(ctx)!.pinRealTitulo,
                  hintText: AppLocalizations.of(ctx)!.pinRealHint,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.pin),
                  counterText: '',
                ),
                maxLength: 4,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 24, letterSpacing: 12),
                obscureText: true,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return AppLocalizations.of(ctx)!.pinInformarObrigatorio;
                  if (v.trim().length != 4) return AppLocalizations.of(ctx)!.pinDeveTer4Digitos;
                  if (int.tryParse(v.trim()) == null) return AppLocalizations.of(ctx)!.pinApenasNumeros;
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx)!.cancelar),
          ),
          FilledButton.icon(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              await _savePinReal(pinController.text.trim());
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            icon: const Icon(Icons.check, size: 18),
            label: Text(AppLocalizations.of(ctx)!.salvar),
          ),
        ],
      ),
    );
  }

  Future<void> _savePinReal(String pin) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;

    // Regra de negócio:
    // 1) Primeiro cadastro (nenhum PIN ainda definido): o PIN é efetivado
    //    INSTANTANEAMENTE, sem qualquer carência.
    // 2) Alteração de um PIN já existente: a nova senha fica pendente por
    //    2 horas, mantendo a senha atual intacta até o prazo se cumprir.
    //
    // O método do DatabaseHelper decide qual dos dois casos se aplica e
    // retorna `true` quando a efetivação foi instantânea (primeiro
    // cadastro) ou `false` quando ficou pendente (alteração).
    final bool efetivadoInstantaneamente =
        await _db.salvarOuAgendarPinReal(id, pin);

    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      if (efetivadoInstantaneamente) {
        // Registra no histórico ('sistema') o cadastro inicial do PIN.
        await _db.inserirEventoHistorico(
          titulo: l10n.historicoPinDefinidoTitulo,
          descricao: l10n.historicoPinDefinidoDescricao,
          categoria: 'sistema',
        );
      } else {
        // Registra no histórico ('sistema') a solicitação de troca do PIN,
        // deixando claro que a nova senha só entra em vigor após 2h.
        await _db.inserirEventoHistorico(
          titulo: l10n.historicoPinAlteracaoSolicitadaTitulo,
          descricao: l10n.historicoPinAlteracaoSolicitadaDescricao,
          categoria: 'sistema',
        );
      }
    }

    await _loadConfig();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            efetivadoInstantaneamente
                ? AppLocalizations.of(context)!.pinDefinidoComSucesso
                : AppLocalizations.of(context)!.pinNovaSenhaEmVigorCarencia,
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }


  void _showWallpaperDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx)!.alterarPlanoFundo),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1,
            ),
            itemCount: _presetWallpapers.length,
            itemBuilder: (ctx, index) {
              final wp = _presetWallpapers[index];
              final l10nCtx = AppLocalizations.of(ctx)!;
              final isSelected = _planoDeFundoUrl == wp.key;
              return GestureDetector(
                onTap: () {
                  _saveWallpaper(wp.key);
                  Navigator.of(ctx).pop();
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey.shade300,
                        width: isSelected ? 3 : 1,
                      ),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.3),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.asset(
                          'assets/${wp.key}.png',
                          fit: BoxFit.cover,
                        ),
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(0.0),
                                Colors.black.withOpacity(0.55),
                              ],
                            ),
                          ),
                        ),
                        if (isSelected)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                              size: 22,
                            ),
                          ),
                        Positioned(
                          left: 4,
                          right: 4,
                          bottom: 4,
                          child: Text(
                            wp.rotulo(l10nCtx),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              color: Colors.white,
                              shadows: const [
                                Shadow(color: Colors.black87, blurRadius: 3),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(ctx)!.fechar),
          ),
        ],
      ),
    );
  }

  Future<void> _saveWallpaper(String key) async {
    await _ensureUserConfig();
    final id = _userConfig!['id'] as int;
    await _db.updateUserConfig({'id': id, 'plano_de_fundo_url': key});

    // Registra no histórico ('sistema') a alteração do plano de fundo.
    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      final nomeTema = _presetWallpapers
          .firstWhere((w) => w.key == key, orElse: () => const _PresetWallpaper('light'))
          .rotulo(l10n);
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoPlanoFundoAlteradoTitulo,
        descricao: l10n.historicoPlanoFundoAlteradoDescricao(nomeTema),
        categoria: 'sistema',
      );
    }

    // Espelha a escolha em SharedPreferences para acesso rápido/síncrono
    // nas demais telas (ex: Segurança, Família).
    await WallpaperService.salvar('assets/$key.png');
    await _loadConfig();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.planoFundoAlterado),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Abre um modal inferior (showModalBottomSheet) com as opções de
  /// tamanho de fonte disponíveis para acessibilidade visual.
  void _mostrarModalTamanhoFonte(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return ValueListenableBuilder<double>(
          valueListenable: FontScaleService.fontScaleNotifier,
          builder: (context, fatorAtual, _) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.text_fields, color: Color(0xFF4C7040)),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.of(context)!.tamanhoLetrasTitulo,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  _opcaoTamanhoFonte(
                    ctx,
                    label: AppLocalizations.of(ctx)!.fontTamanhoPequeno,
                    fator: FontScaleService.pequeno,
                    fatorAtual: fatorAtual,
                    amostraFontSize: 14,
                  ),
                  _opcaoTamanhoFonte(
                    ctx,
                    label: AppLocalizations.of(ctx)!.fontTamanhoPadrao,
                    fator: FontScaleService.padrao,
                    fatorAtual: fatorAtual,
                    amostraFontSize: 16,
                  ),
                  _opcaoTamanhoFonte(
                    ctx,
                    label: AppLocalizations.of(ctx)!.fontTamanhoGrande,
                    fator: FontScaleService.grande,
                    fatorAtual: fatorAtual,
                    amostraFontSize: 18,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _opcaoTamanhoFonte(
    BuildContext ctx, {
    required String label,
    required double fator,
    required double fatorAtual,
    required double amostraFontSize,
  }) {
    final bool isSelected = fatorAtual == fator;
    return ListTile(
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? const Color(0xFF4C7040) : Colors.grey,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontSize: amostraFontSize,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: Text(
        'Aa',
        style: TextStyle(fontSize: amostraFontSize, color: Colors.grey.shade600),
      ),
      onTap: () async {
        await _salvarTamanhoFonte(fator);
        if (ctx.mounted) Navigator.of(ctx).pop();
      },
    );
  }

  Future<void> _salvarTamanhoFonte(double fator) async {
    await FontScaleService.salvar(fator);
    if (mounted) {
      setState(() {});
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.tamanhoLetrasAlterado(FontScaleService.rotuloPara(fator, l10n))),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }


  /// Encerra a sessão do Firebase Auth e volta para a LoginScreen,
  /// limpando toda a pilha de navegação — usa a [appNavigatorKey] global
  /// (em vez do `context` local desta aba) porque esta tela pode estar
  /// aninhada várias rotas abaixo da raiz do app.
  Future<void> _sairDaConta() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx)!.sairDaContaTitulo),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppLocalizations.of(ctx)!.cancelar),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(AppLocalizations.of(ctx)!.sairDaContaConfirmar),
          ),
        ],
      ),
    );
    if (confirmar != true) return;

    await FirebaseAuthService().logout();
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

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
          child: ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [

        _sectionHeader(theme, Icons.security, AppLocalizations.of(context)!.tabSeguranca),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: _pinReal != null ? Colors.green.shade100 : Colors.orange.shade100,
            child: Icon(
              _pinReal != null ? Icons.lock : Icons.lock_open,
              color: _pinReal != null ? Colors.green.shade700 : Colors.orange.shade700,
            ),
          ),
          title: Text(
            AppLocalizations.of(context)!.pinRealTitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            _senhaPendente != null
                ? AppLocalizations.of(context)!.pinNovaSenhaPendente
                : (_pinReal != null ? AppLocalizations.of(context)!.pinDefinido : AppLocalizations.of(context)!.pinNaoDefinido),
            softWrap: true,
            overflow: TextOverflow.clip,
            style: TextStyle(
              color: _senhaPendente != null
                  ? Colors.blue.shade600
                  : (_pinReal != null ? Colors.green.shade600 : Colors.orange.shade600),
              fontSize: 13,
            ),
          ),
          trailing: const Icon(Icons.edit),
          onTap: _showPinRealDialog,
        ),

        _buildCartaoDeviceAdmin(),
        _buildCartaoOtimizacaoBateria(),

        const Divider(),

        // =========================================
        // SEÇÃO: CONTATOS DE EMERGÊNCIA
        // =========================================
        _sectionHeader(theme, Icons.contact_emergency, AppLocalizations.of(context)!.familiaContatosEmergenciaTitulo),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            AppLocalizations.of(context)!.contatosDescricao(_maxContatos),
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
        const SizedBox(height: 12),

        if (_carregandoContatos)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_contatosEmergencia.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                AppLocalizations.of(context)!.familiaNenhumContato,
                textAlign: TextAlign.center,
                softWrap: true,
                overflow: TextOverflow.clip,
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: List.generate(_contatosEmergencia.length, (index) {
                final contato = _contatosEmergencia[index];
                final id = contato['id'] as int;
                final nome = contato['nome'] as String? ?? AppLocalizations.of(context)!.familiaSemNome;
                final telefone = contato['telefone'] as String? ?? '';
                return Card(
                  elevation: 0,
                  color: Colors.white,
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFFE8F5E9),
                      child: Text(
                        nome.isNotEmpty ? nome[0].toUpperCase() : '?',
                        style: const TextStyle(
                          color: Color(0xFF4C7040),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      nome,
                      softWrap: true,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: _isExclusaoPendente(contato)
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.hourglass_bottom, size: 14, color: Colors.orange),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  AppLocalizations.of(context)!.familiaRemovendoEmCarencia,
                                  softWrap: true,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.orange.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Text(
                            telefone,
                            softWrap: true,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                    trailing: _isExclusaoPendente(contato)
                        ? const Icon(Icons.hourglass_bottom, color: Colors.orange)
                        : IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            tooltip: AppLocalizations.of(context)!.tooltipExcluirContato,
                            onPressed: () => _confirmarEExcluirContato(id, nome),
                          ),
                  ),
                );
              }),
            ),
          ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _contatosEmergencia.length >= _maxContatos
                  ? null
                  : _adicionarContatoDaAgenda,
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(
                AppLocalizations.of(context)!.adicionarContatoAgenda,
                softWrap: true,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4C7040),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),
        const Divider(),

        _sectionHeader(theme, Icons.palette, AppLocalizations.of(context)!.visualDoChatTitulo),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.purple.shade100,
            child: Icon(Icons.wallpaper, color: Colors.purple.shade700),
          ),
          title: Text(
            AppLocalizations.of(context)!.alterarPlanoFundo,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            _planoDeFundoUrl != null
                ? _presetWallpapers
                        .firstWhere(
                          (w) => w.key == _planoDeFundoUrl,
                          orElse: () => const _PresetWallpaper('light'),
                        )
                        .rotulo(AppLocalizations.of(context)!)
                : AppLocalizations.of(context)!.planoFundoPadrao,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13),
          ),
          trailing: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Image.asset(
                'assets/${_planoDeFundoUrl ?? 'light'}.png',
                fit: BoxFit.cover,
              ),
            ),
          ),
          onTap: _showWallpaperDialog,
        ),

        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.teal.shade50,
            child: Icon(Icons.text_fields, color: Colors.teal.shade700),
          ),
          title: Text(
            AppLocalizations.of(context)!.tamanhoLetrasTitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            FontScaleService.rotuloPara(
                FontScaleService.fontScaleNotifier.value, AppLocalizations.of(context)!),
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _mostrarModalTamanhoFonte(context),
        ),

        const Divider(),

        // =========================================
        // SEÇÃO: ALERTA SONORO CUSTOMIZÁVEL (Etapa 1)
        // =========================================
        _sectionHeader(theme, Icons.notifications_active, AppLocalizations.of(context)!.alertaSonoroTitulo),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            AppLocalizations.of(context)!.alertaSonoroDescricao,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
        const SizedBox(height: 12),

        if (_carregandoAlarmeSonoro)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              // "start" garante que, se o Dropdown crescer de altura por
              // causa de fonte grande do sistema, o botão de teste ao
              // lado permaneça alinhado ao topo em vez de forçar uma
              // altura fixa/cortar o conteúdo do campo.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _somSelecionado,
                    // Permite que o texto do item selecionado use toda a
                    // largura disponível do campo, evitando corte
                    // horizontal quando a fonte do sistema aumenta.
                    isExpanded: true,
                    // "isDense: false" (padrão) garante altura extra
                    // suficiente para acomodar fontes grandes, em vez de
                    // manter o campo com altura mínima fixa.
                    isDense: false,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context)!.somAlarmeLabel,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      // Padding vertical generoso e simétrico, permitindo
                      // que o campo cresça verticalmente conforme o
                      // fatorEscala de fonte do sistema, em vez de um
                      // valor rígido que corta texto em fontes GRANDES.
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                    ),
                    items: AlarmeSonoroService.sonsDisponiveis
                        .map(
                          (som) => DropdownMenuItem<int>(
                            value: som.numero,
                            child: Text(
                              som.nomeLocalizado(AppLocalizations.of(context)!),
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _selecionarSom,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: AppLocalizations.of(context)!.tooltipTestarSom,
                  onPressed: () => _testarSom(_somSelecionado),
                  icon: Icon(
                    _somTestandoAgora == _somSelecionado
                        ? Icons.volume_up
                        : Icons.play_arrow,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF4C7040),
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
        ],

        const Divider(),

        // =========================================
        // SEÇÃO: IDIOMA (Etapa 2 - Internacionalização)
        // =========================================
        _sectionHeader(theme, Icons.language, AppLocalizations.of(context)!.configuracoesIdiomaTitulo),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            AppLocalizations.of(context)!.configuracoesIdiomaDescricao,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ),
        // Espaçamento adaptável: usa o textScaleFactor do MediaQuery para
        // que, com fontes GRANDES do sistema, o texto explicativo acima
        // tenha folga suficiente antes do Dropdown de idioma, evitando a
        // sensação de que o campo abaixo está "atropelando" o texto.
        SizedBox(
          height: 12 *
              MediaQuery.of(context)
                  .textScaler
                  .scale(1.0)
                  .clamp(1.0, 1.6),
        ),


        if (_carregandoIdioma)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String>(
              value: _idiomaSelecionado,
              // Permite que o texto do item selecionado (emoji + nome em
              // português + nome nativo) use toda a largura disponível do
              // campo, evitando corte horizontal com fontes grandes.
              isExpanded: true,
              // "isDense: false" (padrão) dá altura extra ao campo para
              // acomodar fontes maiores sem cortar o conteúdo.
              isDense: false,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.configuracoesIdiomaLabel,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                // Padding vertical generoso, sem valor rígido demais,
                // permitindo que o campo cresça com fontes GRANDES.
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
              items: LocalizationService.idiomasSuportados
                  .map(
                    (idioma) => DropdownMenuItem<String>(
                      value: idioma.codigo,
                      // Exibe só o nome nativo do idioma (sem o descritor em
                      // português, que nunca era traduzido) — autoexplicativo
                      // para qualquer falante daquele idioma.
                      child: Text(
                        '${idioma.bandeiraEmoji}  ${idioma.nomeNativo}',
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: _selecionarIdioma,
            ),
          ),
        const SizedBox(height: 8),


        const Divider(),

        // =========================================
        // SEÇÃO: MEU PERFIL (número de contato — somente leitura)
        // =========================================
        _sectionHeader(theme, Icons.person_outline, AppLocalizations.of(context)!.meuPerfilTitulo),
        if (_carregandoTelefone)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          ListTile(
            leading: CircleAvatar(
              backgroundColor: _telefoneAtual != null && _telefoneAtual!.isNotEmpty
                  ? Colors.green.shade100
                  : Colors.orange.shade100,
              child: Icon(
                Icons.phone_android_outlined,
                color: _telefoneAtual != null && _telefoneAtual!.isNotEmpty
                    ? Colors.green.shade700
                    : Colors.orange.shade700,
              ),
            ),
            title: Text(
              AppLocalizations.of(context)!.meuPerfilTelefoneTitulo,
              softWrap: true,
              overflow: TextOverflow.clip,
            ),
            subtitle: Text(
              _telefoneAtual != null && _telefoneAtual!.isNotEmpty
                  ? _telefoneAtual!
                  : AppLocalizations.of(context)!.meuPerfilTelefoneNaoCadastrado,
              softWrap: true,
              overflow: TextOverflow.clip,
              style: TextStyle(
                color: _telefoneAtual != null && _telefoneAtual!.isNotEmpty
                    ? Colors.green.shade600
                    : Colors.orange.shade600,
                fontSize: 13,
              ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: AppLocalizations.of(context)!.meuPerfilTelefoneEditarTooltip,
              onPressed: _editarTelefone,
            ),
          ),

        const Divider(),
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.blue.shade50,
            child: Icon(Icons.verified_user_outlined, color: Colors.blue.shade700),
          ),
          title: Text(
            AppLocalizations.of(context)!.statusPermissoesTitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.statusPermissoesSubtitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 12.5),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const PermissoesStatusScreen()),
            );
          },
        ),
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.blueGrey.shade50,
            child: Icon(Icons.bug_report_outlined, color: Colors.blueGrey.shade700),
          ),
          title: Text(
            AppLocalizations.of(context)!.diagnosticoTitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.diagnosticoSubtitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 12.5),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const DiagnosticoScreen()),
            );
          },
        ),
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.red.shade50,
            child: Icon(Icons.delete_forever_outlined, color: Colors.red.shade700),
          ),
          title: Text(
            AppLocalizations.of(context)!.excluirContaTitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: TextStyle(color: Colors.red.shade700),
          ),
          subtitle: Text(
            AppLocalizations.of(context)!.excluirContaSubtitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: const TextStyle(fontSize: 12.5),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const ExcluirContaScreen()),
            );
          },
        ),

        const Divider(),
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.red.shade50,
            child: Icon(Icons.logout, color: Colors.red.shade700),
          ),
          title: Text(
            AppLocalizations.of(context)!.sairDaContaTitulo,
            softWrap: true,
            overflow: TextOverflow.clip,
          ),
          onTap: _sairDaConta,
        ),

        const SizedBox(height: 24),
      ],
          ),
        );
      },
    );
  }

  /// Cartão de consentimento para a permissão de Administrador do
  /// Dispositivo (bloqueio automático de tela — P4 da sequência unificada
  /// de SOS, ver DeviceAdminService). Regra de silêncio: só é renderizado
  /// enquanto a permissão NÃO está ativa; uma vez concedida, não exibe
  /// nenhum aviso/card — só reaparece se a permissão for revogada.
  Widget _buildCartaoDeviceAdmin() {
    if (_carregandoDeviceAdmin || _deviceAdminAtivo) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_open, color: Colors.black45),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context)!.deviceAdminTitulo,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppLocalizations.of(context)!.deviceAdminDescricaoInativo,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => DeviceAdminService().solicitarAtivacao(),
              child: Text(AppLocalizations.of(context)!.deviceAdminBotaoAtivar),
            ),
          ],
        ),
      ),
    );
  }

  /// Cartão de consentimento para a isenção de otimização de bateria
  /// (ver BatteryOptimizationService) — mesmo padrão de silêncio do
  /// cartão de Device Admin acima: só é renderizado enquanto a isenção
  /// NÃO está concedida.
  Widget _buildCartaoOtimizacaoBateria() {
    if (_carregandoBateria || _bateriaIsenta) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            const Icon(Icons.battery_charging_full, color: Colors.black45),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context)!.batteriaOtimizacaoTitulo,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppLocalizations.of(context)!.batteriaOtimizacaoDescricaoInativo,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => BatteryOptimizationService()
                  .solicitarComExplicacao(context)
                  .then((_) => _carregarStatusBateria()),
              child: Text(AppLocalizations.of(context)!.batteriaOtimizacaoBotaoAtivar),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, IconData icon, String title) {

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetWallpaper {
  final String key;

  const _PresetWallpaper(this.key);

  /// Nome do tema traduzido no idioma ativo do app — nunca hardcoded.
  /// Renomeações pedidas: "Escuro Absoluto" -> "Cinza Platina",
  /// "Cinza Urbano" -> "Luz do Amanhecer", "Lavanda Suave" -> "Rosa Claro".
  String rotulo(AppLocalizations l10n) {
    switch (key) {
      case 'blue':
        return l10n.temaAzulProfundo;
      case 'dark':
        return l10n.temaCinzaPlatina;
      case 'gray':
        return l10n.temaLuzDoAmanhecer;
      case 'green':
        return l10n.temaVerdeBotanico;
      case 'lavender':
        return l10n.temaRosaClaro;
      case 'light':
      default:
        return l10n.temaLuzClassica;
    }
  }
}
