import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/monitoramento_service.dart';
import '../../services/plano_ciclo_service.dart';
import '../../services/rastreamento_continuo_service.dart';
import '../../services/sos_plano_aviso_service.dart' show formatarDiaMes;
import '../consentimento_rastreamento_screen.dart';
import '../../services/wallpaper_service.dart';
import '../../widgets/contato_agenda_picker.dart';
import '../../widgets/monitoramento_decisao_dialog.dart';
import '../../widgets/plano_bloqueado_dialog.dart';

const Color _corDestaque = Color(0xFF4C7040);

/// A partir desta idade, a posição de um contato é sinalizada como
/// possivelmente desatualizada (card e confirmação antes do mapa).
const Duration _idadePosicaoDesatualizada = Duration(minutes: 15);

/// Momento da última posição gravada em `usuarios/{uid}/monitoramento/atual`.
DateTime? _momentoDaPosicao(Map<String, dynamic>? dados) {
  final atualizadoEm = dados?['atualizadoEm'];
  return atualizadoEm is Timestamp ? atualizadoEm.toDate() : null;
}

/// "Atualizado há X min" (ou "há X h" a partir de 1 hora).
String _textoIdadePosicao(AppLocalizations l10n, DateTime momento) {
  final idade = DateTime.now().difference(momento);
  final minutos = idade.isNegative ? 0 : idade.inMinutes;
  if (minutos < 1) return l10n.monitoramentoAtualizadoAgora;
  if (minutos < 60) return l10n.monitoramentoAtualizadoHaMinutos(minutos);
  return l10n.monitoramentoAtualizadoHaHoras(minutos ~/ 60);
}

bool _posicaoDesatualizada(DateTime? momento) =>
    momento == null || DateTime.now().difference(momento) > _idadePosicaoDesatualizada;

/// Aba Monitoramento: permite ao usuário controlar, contato a contato, o
/// compartilhamento bilateral de localização GPS em tempo real com
/// familiares que também usam o Guardião X — com consentimento explícito
/// em ambas as direções (ver [MonitoramentoService]).
///
/// EXCLUSIVAMENTE de visualização/gerenciamento: esta tela NÃO contém
/// teclado de PIN nem dispara qualquer som de alarme/sirene — apenas lê e
/// escreve permissões e localização na nuvem.
///
/// Lista única "Localização real" com TODOS os contatos
/// cadastrados localmente. Cada card reúne as duas direções independentes
/// de permissão para aquele contato:
/// - "Solicitar Localização" (`uidSolicitante` = eu): pede para VER a
///   localização dele.
/// - Switch de pré-autorização (`uidAlvo` = eu): permite CONCEDER ou
///   BLOQUEAR, individualmente e preventivamente, se ELE pode receber a
///   MINHA localização — mesmo que ele nunca tenha solicitado antes (ver
///   [MonitoramentoService.definirPermissaoCompartilhamento]). Pedidos
///   recebidos enquanto a tela está aberta continuam sendo interceptados
///   por um diálogo de consentimento explícito antes de qualquer decisão
///   automática.
class MonitoramentoTab extends StatefulWidget {
  const MonitoramentoTab({super.key});

  @override
  State<MonitoramentoTab> createState() => MonitoramentoTabState();
}

class MonitoramentoTabState extends State<MonitoramentoTab> {
  final MonitoramentoService _servico = MonitoramentoService();

  bool _carregando = true;
  List<Map<String, dynamic>> _contatos = [];

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _pedidosSub;
  final Set<String> _pedidosJaNotificados = {};

  // ==========================================================
  // SOBREPOSIÇÃO OTIMISTA DOS SWITCHES (pedido explícito do usuário,
  // 2026-09-07)
  // ==========================================================
  // Antes, os dois switches desta aba ("Permitir enviar minha
  // localização" e "Permitir ou Bloquear solicitação de localização")
  // liam o estado (verde/vermelho) EXCLUSIVAMENTE do `StreamBuilder`
  // ligado ao Firestore — a mudança visual só chegava depois da viagem
  // de ida e volta ao servidor (até ~3s em rede mais lenta), dando a
  // falsa impressão de que o toque não tinha funcionado e levando o
  // usuário a tocar repetidamente. Cada mapa guarda o valor otimista por
  // contato local (`contato['id']`) assim que o usuário toca/confirma, e
  // é limpo automaticamente no próprio `StreamBuilder` assim que o
  // snapshot do servidor confirma esse mesmo valor — ou revertido, se a
  // escrita falhar (ver [_alternarBloqueioSolicitante] e
  // [_alternarPermissaoCompartilhar]).
  final Map<int, bool> _overrideBloqueio = {};
  final Map<int, bool> _overrideCompartilhamento = {};

  // Teste de 2026-10-04: o switch "Permitir enviar minha localização"
  // chegou ao servidor como permitir:true e, ~1 s depois, permitir:false
  // (três vezes seguidas) — um segundo toque logo após a resposta, quando a
  // lista piscava/se deslocava. Enquanto a escrita está em voo e por
  // [_carenciaToqueSwitch] depois dela, novos toques no MESMO switch do
  // MESMO contato são ignorados.
  static const Duration _carenciaToqueSwitch = Duration(milliseconds: 1500);
  final Map<int, DateTime> _travaCompartilhamentoAte = {};
  final Map<int, DateTime> _travaBloqueioAte = {};

  /// `true` (e trava o switch) se o toque pode seguir; `false` se ainda há
  /// uma escrita em voo ou ela terminou há menos de [_carenciaToqueSwitch].
  bool _tentarTravarSwitch(Map<int, DateTime> travas, int id) {
    final ate = travas[id];
    if (ate != null && DateTime.now().isBefore(ate)) return false;
    // Em voo: trava "infinita" até [_liberarSwitch].
    travas[id] = DateTime(9999);
    return true;
  }

  void _liberarSwitch(Map<int, DateTime> travas, int id) {
    travas[id] = DateTime.now().add(_carenciaToqueSwitch);
  }

  // Botão "Atualizar localização" de cada card (por uid do contato): pedido
  // em andamento (ignora novos toques) e o resultado do último pedido, para
  // o aviso no próprio card.
  final Set<String> _atualizandoPosicao = {};
  final Map<String, ResultadoPedidoPosicao> _resultadoAtualizacao = {};

  // ==========================================================
  // TRAVA DO CICLO DO PLANO FREE (pedido explícito do usuário, 2026-09-04)
  // ==========================================================
  // `null` = ainda não chegou nenhum snapshot nesta sessão (blindagem
  // permissiva — ver [_planoBloqueado]). Assinado via
  // [PlanoCicloService.statusStream] (mesma fonte reativa já usada pelo
  // indicador da InicioDashboard) em vez de uma leitura única, para que
  // TODOS os controles desta aba (botão "Solicitar Localização", os dois
  // switches de cada card) reflitam a mudança de "ativo" para "bloqueado"
  // em tempo real, sem exigir um pull-to-refresh manual.
  StreamSubscription<PlanoCicloStatus?>? _statusPlanoSub;
  PlanoCicloStatus? _statusPlano;

  /// `true` só quando já temos confirmação de que o ciclo está FORA da
  /// janela de 10 dias ativos (e sem Premium) — `_statusPlano == null`
  /// (stream ainda sem nenhum valor, ou sem sessão/Firebase indisponível)
  /// NUNCA bloqueia nada, mesma blindagem permissiva usada em todo o
  /// resto do app.
  bool get _planoBloqueado => _statusPlano?.ativo == false;

  @override
  void initState() {
    super.initState();
    _carregarContatos();
    MonitoramentoService.versaoMonitoramento.addListener(_aoAlterarLocal);
    _pedidosSub = _servico
        .pedidosRecebidosPendentesStream()
        .listen(_aoAtualizarPedidosRecebidos);
    _statusPlanoSub = PlanoCicloService().statusStream().listen((status) {
      if (!mounted) return;
      setState(() => _statusPlano = status);
    });
  }

  @override
  void dispose() {
    MonitoramentoService.versaoMonitoramento.removeListener(_aoAlterarLocal);
    _pedidosSub?.cancel();
    _statusPlanoSub?.cancel();
    super.dispose();
  }

  void _aoAlterarLocal() => _carregarContatos();

  Future<void> _carregarContatos() async {
    if (!mounted) return;
    // Spinner só na primeira carga: recarregar por trás (toda escrita do
    // serviço notifica [versaoMonitoramento]) trocava a lista inteira pelo
    // spinner e de volta, piscando os cards logo depois de um toque nos
    // switches — e recriando seus StreamBuilders.
    if (_contatos.isEmpty) setState(() => _carregando = true);
    final contatos = await _servico.listarContatos();
    if (!mounted) return;
    setState(() {
      _contatos = contatos;
      _carregando = false;
    });
  }

  /// Sempre que uma NOVA solicitação pendente aparecer (id ainda não
  /// visto nesta sessão da tela), exibe o diálogo de consentimento
  /// explícito exigido pelo fluxo: "Fulano está solicitando a sua
  /// localização. Permitir ou Bloquear?".
  void _aoAtualizarPedidosRecebidos(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    for (final doc in snapshot.docs) {
      if (_pedidosJaNotificados.contains(doc.id)) continue;
      _pedidosJaNotificados.add(doc.id);
      _exibirDialogoSolicitacaoRecebida(doc);
    }
  }

  Future<void> _exibirDialogoSolicitacaoRecebida(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    if (!mounted) return;
    // CORREÇÃO DE BUG REAL CONFIRMADO EM TESTE FÍSICO (2026-09-06): ver
    // documentação completa em
    // [MonitoramentoService.marcarResolvidoDireto]/[foiResolvidoDireto] —
    // sem esta checagem, tocar [Aceitar]/[Recusar] direto na notificação
    // (que reabre o app) fazia este listener, ao reconectar, achar a
    // MESMA solicitação ainda "pendente" (a escrita da resposta ainda em
    // voo — ou processando numa isolate headless separada) e abrir o
    // modal de decisão por cima de uma escolha que o usuário já tinha
    // feito. Uma pequena espera ANTES da checagem dá tempo de sobra para
    // essa marcação (em disco, cruza isolates) vencer a corrida —
    // imperceptível no caso comum (nenhuma ação tocada, o usuário só
    // abriu o app de verdade).
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    if (await MonitoramentoService.foiResolvidoDireto(doc.id)) return;
    if (!mounted) return;
    final dados = doc.data();
    await exibirDialogoDecisaoMonitoramento(
      context: context,
      idPermissao: doc.id,
      uidSolicitante: dados['uidSolicitante'] as String? ?? '',
      nomeSolicitante: dados['nomeSolicitante'] as String? ?? '',
      telefoneSolicitante: dados['telefoneSolicitante'] as String? ?? '',
    );
  }

  // ==========================================================
  // GERENCIAMENTO DE CONTATOS (adicionar/editar/excluir)
  // ==========================================================

  /// Acionado pelo botão "+" do AppBar global (ver HomeScreen), mesmo
  /// padrão de [FamiliaTabState.abrirModalAdicionarAlarme].
  Future<void> abrirModalAdicionarContato() async {
    // REGRA DE NEGÓCIO (pedido explícito do usuário, 2026-09-04): fora dos
    // 10 dias ativos do mês (e sem Premium), não é possível cadastrar
    // NENHUM contato novo de monitoramento — exibe o aviso de upsell e
    // interrompe aqui, ANTES de abrir o próprio diálogo de cadastro.
    // [adicionarContato] em si é uma gravação 100% local (SQLite, sem
    // chamada de rede/Cloud Function) — diferente de
    // solicitar/compartilhar localização, não precisa de uma segunda
    // trava no lado do serviço.
    if (!await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final nomeController = TextEditingController();
    final telefoneController = TextEditingController();
    String? erroValidacao;

    // Folha inferior de altura livre (`isScrollControlled`) em vez de
    // AlertDialog — feedback do 1º teste no iPhone (build 105): no diálogo,
    // o `autofocus` do campo de nome subia o teclado na hora e o conteúdo
    // era esmagado, sumindo com "Buscar na agenda" (sobravam só o nome e
    // os botões). Agora: sem autofocus, "Buscar na agenda" fixo no topo,
    // conteúdo rolável e o padding inferior acompanha o teclado
    // (`viewInsets`). O erro de validação continua DENTRO da folha
    // (StatefulBuilder): um SnackBar da tela ficaria atrás dela.
    final salvou = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.monitoramentoAdicionarContato,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _importarContatoDaAgenda(
                    nomeController: nomeController,
                    telefoneController: telefoneController,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _corDestaque,
                    side: BorderSide(color: _corDestaque.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  icon: const Icon(Icons.contact_phone_outlined, size: 18),
                  // O rótulo do OutlinedButton.icon já é flexível: com fonte
                  // grande quebra em 2 linhas em vez de estourar a largura.
                  label: Text(l10n.adicionarContatoAgenda, softWrap: true),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nomeController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.monitoramentoNomeLabel,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: telefoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: l10n.monitoramentoTelefoneLabel,
                    // Sem isso, o label às vezes não flutua acima da borda a
                    // tempo (efeito visível ao digitar rápido no teclado
                    // numérico) e fica sobreposto aos dígitos já digitados.
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ),
                ),
                if (erroValidacao != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    erroValidacao!,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: Text(l10n.cancelar),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _corDestaque),
                        onPressed: () {
                          final nome = nomeController.text.trim();
                          final telefone = telefoneController.text.trim();
                          if (nome.isEmpty || telefone.isEmpty) {
                            setStateDialog(() {
                              erroValidacao = l10n.monitoramentoCamposObrigatorios;
                            });
                            return;
                          }
                          Navigator.of(ctx).pop(true);
                        },
                        child: Text(l10n.monitoramentoSalvarContato, textAlign: TextAlign.center),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (salvou != true) return;
    final nome = nomeController.text.trim();
    final telefone = telefoneController.text.trim();
    if (nome.isEmpty || telefone.isEmpty) return;

    await _servico.adicionarContato(nome: nome, telefone: telefone);
  }

  /// Abre o seletor nativo de contatos (mesmo mecanismo usado na aba
  /// Configurações, ver `ConfiguracoesTabState._adicionarContatoDaAgenda`)
  /// e apenas PRE-PREENCHE os campos da folha — quem confirma o
  /// cadastro continua sendo o botão "Salvar", dando ao usuário a chance
  /// de revisar/editar antes de gravar.
  Future<void> _importarContatoDaAgenda({
    required TextEditingController nomeController,
    required TextEditingController telefoneController,
  }) async {
    // Seletor + escolha do telefone (ver [escolherContatoDaAgenda]: funciona
    // com Contatos em "Acesso Limitado", inclusive fora da lista liberada).
    final contato = await escolherContatoDaAgenda(context);
    if (contato == null) return;
    if (contato.nome.isNotEmpty) nomeController.text = contato.nome;
    telefoneController.text = contato.telefone;
  }

  Future<void> _editarNomeContato(Map<String, dynamic> contato) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final controller = TextEditingController(text: contato['nome'] as String? ?? '');

    final novoNome = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.monitoramentoEditarNomeTooltip),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.monitoramentoNomeLabel,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _corDestaque),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l10n.monitoramentoSalvarContato),
          ),
        ],
      ),
    );

    if (novoNome == null || novoNome.isEmpty) return;
    await _servico.editarNomeContato(id, novoNome);
  }

  Future<void> _excluirContato(Map<String, dynamic> contato) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final nome = contato['nome'] as String? ?? '';

    final confirmou = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.monitoramentoExcluirContatoTitulo),
        content: Text(l10n.monitoramentoExcluirContatoConteudo(nome)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.excluir),
          ),
        ],
      ),
    );

    if (confirmou != true) return;
    final revogacaoOk = await _servico.removerContato(id);
    if (!mounted || revogacaoOk) return;

    // Falha CRÍTICA de privacidade em potencial: o contato já saiu da
    // lista local, mas a revogação da permissão de compartilhamento no
    // Firestore falhou de verdade (rede/servidor) — nunca deixar isso
    // passar em silêncio, ver `MonitoramentoService.removerContato`.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.monitoramentoRevogacaoFalhouAoExcluir),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  // ==========================================================
  // SOLICITAR / ABRIR MAPA
  // ==========================================================

  Future<void> _solicitarLocalizacao(int idContato) async {
    final l10n = AppLocalizations.of(context)!;
    final resultado = await _servico.solicitarLocalizacao(idContato);
    if (!mounted) return;

    // BLOQUEIO BIDIRECIONAL de localização do ciclo do Plano Free (ver
    // PlanoCicloService): modal de upsell dedicado, em vez do SnackBar
    // genérico de erro usado pelos demais resultados.
    if (resultado == MonitoramentoService.statusBloqueadoPlanoFree) {
      await _exibirUpsellPlanoBloqueado();
      return;
    }

    final mensagem = switch (resultado) {
      'enviada' => l10n.monitoramentoSolicitacaoEnviada,
      'ja_aprovado' => l10n.monitoramentoJaAprovado,
      'numero_nao_encontrado' => l10n.monitoramentoNumeroNaoEncontrado,
      'proprio_numero' => l10n.monitoramentoProprioNumero,
      'bloqueado_pelo_alvo' => l10n.monitoramentoContatoIndisponivel,
      _ => l10n.monitoramentoErroSolicitar,
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensagem), behavior: SnackBarBehavior.floating),
    );
  }

  /// Atalho para exibir o modal de upsell fora de um `Future<bool>` já em
  /// mãos (ver [garantirRecursoLiberadoOuExibirUpsell]) — usado quando o
  /// bloqueio já foi detectado pelo RESULTADO de uma chamada de serviço
  /// (em vez de checado antes de chamá-la).
  Future<void> _exibirUpsellPlanoBloqueado() async {
    if (!mounted) return;
    await garantirRecursoLiberadoOuExibirUpsell(context);
  }

  Future<void> _abrirMapa(String uidAlvo) async {
    // BLOQUEIO BIDIRECIONAL de localização do ciclo do Plano Free (ver
    // PlanoCicloService) — checado ANTES de consultar a localização,
    // exibindo o modal de upsell em vez de simplesmente não abrir nada.
    if (!await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;

    // Pede a posição ATUAL ao aparelho do contato (push silencioso) e espera
    // até 30 s (ou até o usuário tocar "Cancelar"); sem resposta, segue com
    // a última conhecida + horário.
    final resultado = await _pedirPosicaoAtualComAviso(uidAlvo);
    if (!mounted) return;
    if (resultado == ResultadoPedidoPosicao.semPermissao) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.monitoramentoContatoNaoCompartilha),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final dados = await _servico.buscarUltimaLocalizacao(uidAlvo);
    final latitude = (dados?['latitude'] as num?)?.toDouble();
    final longitude = (dados?['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) return;
    if (!mounted) return;

    // Antes do mapa: de quando é a posição (e o aviso se passar de 15 min)
    // — o mapa em si não mostra o horário.
    if (!await _confirmarAberturaDoMapa(_momentoDaPosicao(dados))) return;

    final uri = Uri.parse('https://maps.google.com/?q=$latitude,$longitude');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Best-effort — se não houver app de mapas disponível, ignora.
    }
  }

  /// Diálogo "Pedindo a posição atual…" com "Cancelar". Termina no que vier
  /// primeiro: a resposta do serviço, o toque em Cancelar (= seguir com a
  /// última posição) ou o teto de [_limitePedidoPosicao] — nunca fica
  /// girando para sempre, mesmo que a callable não responda.
  static const Duration _limitePedidoPosicao = Duration(seconds: 30);

  Future<ResultadoPedidoPosicao> _pedirPosicaoAtualComAviso(String uidAlvo) async {
    final l10n = AppLocalizations.of(context)!;
    final navegador = Navigator.of(context, rootNavigator: true);
    var aberto = true;
    final dialogoFechado = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (contextoDialogo) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: _corDestaque),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text(l10n.rcPedindoPosicao)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(contextoDialogo).pop(),
              child: Text(l10n.cancelar),
            ),
          ],
        ),
      ),
    ).whenComplete(() => aberto = false);
    try {
      return await Future.any<ResultadoPedidoPosicao>([
        _servico.pedirLocalizacaoAtual(uidAlvo, limite: _limitePedidoPosicao),
        dialogoFechado.then((_) => ResultadoPedidoPosicao.semResposta),
      ]).timeout(_limitePedidoPosicao,
          onTimeout: () => ResultadoPedidoPosicao.semResposta);
    } finally {
      if (aberto && navegador.mounted) navegador.pop();
    }
  }

  Future<bool> _confirmarAberturaDoMapa(DateTime? momento) async {
    final l10n = AppLocalizations.of(context)!;
    final desatualizada = _posicaoDesatualizada(momento);
    final locale = Localizations.localeOf(context).toString();
    final confirmou = await showDialog<bool>(
      context: context,
      builder: (contextoDialogo) => AlertDialog(
        title: Text(l10n.monitoramentoUltimaPosicaoTitulo),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (momento != null) ...[
              Text(l10n.monitoramentoUltimaPosicaoRegistradaEm(
                  DateFormat.yMd(locale).add_Hm().format(momento))),
              const SizedBox(height: 4),
              Text(
                _textoIdadePosicao(l10n, momento),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ] else
              Text(l10n.monitoramentoUltimaPosicaoSemHorario),
            if (desatualizada) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.monitoramentoPosicaoDesatualizadaAviso,
                      style: TextStyle(color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(contextoDialogo).pop(false),
            child: Text(l10n.cancelar),
          ),
          FilledButton(
            onPressed: () => Navigator.of(contextoDialogo).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _corDestaque),
            child: Text(l10n.monitoramentoAbrirMapa),
          ),
        ],
      ),
    );
    return confirmou ?? false;
  }

  // ==========================================================
  // BUILD
  // ==========================================================

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<String>(
      valueListenable: WallpaperService.wallpaperNotifier,
      builder: (context, fundoAtivo, _) {
        return Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            image: DecorationImage(image: AssetImage(fundoAtivo), fit: BoxFit.cover),
          ),
          child: SafeArea(
            child: RefreshIndicator(
              onRefresh: _carregarContatos,
              child: _carregando
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        if (Platform.isIOS) _CartaoCompartilhamentoContinuo(l10n: l10n),
                        if (_contatos.isEmpty)
                          _construirEstadoVazio(l10n)
                        else ...[
                          _construirCabecalhoSecao(
                            icone: Icons.location_searching,
                            titulo: l10n.monitoramentoSecaoVerLocalizacao,
                          ),
                          const SizedBox(height: 8),
                          ..._contatos.map(_construirCardVerLocalizacao),
                        ],
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _construirCabecalhoSecao({required IconData icone, required String titulo}) {
    return Row(
      children: [
        Icon(icone, color: _corDestaque),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            titulo,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  Widget _construirEstadoVazio(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.person_search, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            l10n.monitoramentoNenhumContato,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700, fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _construirAvatar(String nome) {
    return CircleAvatar(
      backgroundColor: const Color(0xFFE8F5E9),
      child: Text(
        nome.isNotEmpty ? nome[0].toUpperCase() : '?',
        style: const TextStyle(color: _corDestaque, fontWeight: FontWeight.bold),
      ),
    );
  }

  // ------------------------------------------------------------
  // Seção "Localização real" (Bloco A)
  // ------------------------------------------------------------

  Widget _construirCardVerLocalizacao(Map<String, dynamic> contato) {
    final l10n = AppLocalizations.of(context)!;
    final uid = contato['uid_contato'] as String?;
    final permissaoId = uid != null ? _servico.idPermissaoParaCompartilhar(uid) : null;

    // Sem doc de permissão ainda resolvido (contato nunca interagiu nesta
    // direção): não há nada bloqueado por definição — mas o controle já
    // fica disponível para bloquear preventivamente, já que
    // `definirBloqueioPorTelefone` resolve o telefone server-side, sem
    // depender de um `uid_contato` local previamente resolvido.
    if (permissaoId == null) {
      return _construirConteudoCardVerLocalizacao(
        contato: contato,
        bloqueado: false,
        l10n: l10n,
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        final bloqueadoServidor = snapshot.data?.data()?['bloqueado'] as bool? ?? false;
        final id = contato['id'] as int;
        final override = _overrideBloqueio[id];
        // O servidor já confirmou o valor otimista: some com a
        // sobreposição, o Firestore volta a ser a fonte da verdade.
        if (override != null && override == bloqueadoServidor) {
          _overrideBloqueio.remove(id);
        }
        return _construirConteudoCardVerLocalizacao(
          contato: contato,
          bloqueado: _overrideBloqueio[id] ?? bloqueadoServidor,
          l10n: l10n,
        );
      },
    );
  }

  /// Confirma (só para BLOQUEAR — desbloquear é sempre imediato, é uma
  /// ação reversível e não-destrutiva) e então persiste o bloqueio via
  /// [_alternarBloqueioSolicitante].
  Future<void> _alternarBloqueioComConfirmacao(
    Map<String, dynamic> contato,
    bool bloquear,
  ) async {
    final travaAte = _travaBloqueioAte[contato['id'] as int];
    if (travaAte != null && DateTime.now().isBefore(travaAte)) return;
    if (bloquear) {
      final l10n = AppLocalizations.of(context)!;
      final nome = contato['nome'] as String? ?? '';
      final confirmou = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(l10n.monitoramentoBloquearContatoTitulo),
              content: Text(l10n.monitoramentoBloquearContatoConteudo(nome)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.cancelar),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(l10n.monitoramentoBloquear),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmou) return;
    }
    final id = contato['id'] as int;
    if (!_tentarTravarSwitch(_travaBloqueioAte, id)) return;
    // Atualização OTIMISTA instantânea (pedido do usuário, 2026-09-07): o
    // Switch e o texto "Liberado"/"Bloqueado" mudam de cor no mesmo frame
    // do toque (ou da confirmação, no caso de bloquear), sem esperar a
    // viagem de ida e volta ao Firestore. Revertida em
    // [_alternarBloqueioSolicitante] se a escrita falhar.
    if (mounted) setState(() => _overrideBloqueio[id] = bloquear);
    await _alternarBloqueioSolicitante(contato, bloquear);
  }

  Future<void> _alternarBloqueioSolicitante(
    Map<String, dynamic> contato,
    bool bloquear,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final String resultado;
    try {
      resultado = await _servico.definirBloqueioSolicitante(
        idContatoLocal: id,
        bloquear: bloquear,
      );
    } finally {
      _liberarSwitch(_travaBloqueioAte, id);
    }
    if (!mounted) return;

    if (resultado != 'sucesso') {
      // Escrita falhou (ou foi recusada pelo servidor): reverte a
      // sobreposição otimista, o switch volta a refletir o valor real do
      // Firestore no próximo rebuild.
      setState(() => _overrideBloqueio.remove(id));
    }

    // BLOQUEIO do ciclo do Plano Free (ver PlanoCicloService) — mesmo
    // modal de upsell dedicado usado pelos demais controles desta aba.
    if (resultado == MonitoramentoService.statusBloqueadoPlanoFree) {
      await _exibirUpsellPlanoBloqueado();
      return;
    }

    final mensagem = switch (resultado) {
      'sucesso' => bloquear
          ? l10n.monitoramentoContatoBloqueadoSucesso
          : l10n.monitoramentoContatoDesbloqueadoSucesso,
      'numero_nao_encontrado' => l10n.monitoramentoNumeroNaoEncontrado,
      'proprio_numero' => l10n.monitoramentoProprioNumero,
      _ => l10n.monitoramentoErroSolicitar,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        behavior: SnackBarBehavior.floating,
        backgroundColor: resultado == 'sucesso' ? null : Colors.redAccent,
      ),
    );
  }

  Widget _construirConteudoCardVerLocalizacao({
    required Map<String, dynamic> contato,
    required bool bloqueado,
    required AppLocalizations l10n,
  }) {
    final id = contato['id'] as int;
    final nome = contato['nome'] as String? ?? '';
    final telefone = contato['telefone'] as String? ?? '';

    return Card(
      elevation: 0,
      color: Colors.white.withOpacity(0.92),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _construirAvatar(nome),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nome,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      Text(
                        telefone,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20, color: Colors.black54),
                  tooltip: l10n.monitoramentoEditarNomeTooltip,
                  onPressed: () => _editarNomeContato(contato),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                  tooltip: l10n.monitoramentoExcluirContatoTooltip,
                  onPressed: () => _excluirContato(contato),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _construirBlocoVerLocalizacao(contato, id, l10n),
            const Divider(height: 20),
            _construirSwitchCompartilhar(contato, l10n),
            const SizedBox(height: 10),
            _construirControleBloqueio(contato, bloqueado, l10n),
          ],
        ),
      ),
    );
  }

  /// Bloco ISOLADO e dedicado ao bloqueio de solicitações — texto
  /// explicativo, e logo abaixo um controle de arraste fluido (`Switch`,
  /// que no Material já aceita tanto toque quanto arrastar o próprio
  /// polegar para os dois lados) com hit-area PRÓPRIA, restrita a este
  /// bloco — ao contrário de um `Dismissible` cobrindo o card inteiro
  /// (tentativa anterior), nunca interfere com o resto do card (nome,
  /// telefone, botões de editar/excluir, o outro switch).
  ///
  /// CORREÇÃO DE INVERSÃO (bug real reportado, 2026-08-11): o `Switch`
  /// exibia `value: bloqueado` diretamente — ligado (polegar à direita)
  /// == BLOQUEADO. Isso ficava "ao contrário do esperado": o usuário
  /// espera que ligar/"ativar" o controle signifique PERMITIR (estado
  /// positivo), não bloquear. Agora o `Switch` representa `permitido`
  /// (`!bloqueado`) — ligado (verde) = permite solicitações; desligado
  /// (vermelho) = bloqueado — e o `onChanged` converte de volta
  /// (`bloquear: !valor`) antes de chamar
  /// [_alternarBloqueioComConfirmacao], que continua recebendo/tratando
  /// exclusivamente o significado "bloquear", sem nenhuma outra mudança
  /// de comportamento.
  Widget _construirControleBloqueio(
    Map<String, dynamic> contato,
    bool bloqueado,
    AppLocalizations l10n,
  ) {
    // REGRA DE NEGÓCIO (pedido explícito do usuário, 2026-09-04): fora dos
    // 10 dias ativos do mês (e sem Premium), este switch aparece travado
    // em vermelho — independente do estado real de `bloqueado` salvo no
    // Firestore — e qualquer toque mostra o aviso de upsell em vez de
    // tentar a escrita (que [_alternarBloqueioSolicitante] também recusa,
    // ver `MonitoramentoService.definirBloqueioPorTelefone`; isto só evita
    // o round-trip de rede e já avisa visualmente ANTES do toque).
    final bool bloqueadoPeloPlano = _planoBloqueado;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.monitoramentoPermitirOuBloquearSolicitacoes,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              _linhaStatus(
                icone: bloqueadoPeloPlano
                    ? Icons.lock_outline
                    : (bloqueado ? Icons.block : Icons.check_circle),
                cor: bloqueadoPeloPlano || bloqueado ? Colors.red.shade700 : Colors.green.shade700,
                texto: bloqueadoPeloPlano
                    ? l10n.monitoramentoRecursoBloqueadoPlano
                    : (bloqueado
                        ? l10n.monitoramentoIndicadorBloqueado
                        : l10n.monitoramentoIndicadorLiberado),
              ),
            ],
          ),
        ),
        Switch(
          value: bloqueadoPeloPlano ? false : !bloqueado,
          activeColor: Colors.green.shade600,
          activeTrackColor: Colors.green.shade100,
          inactiveThumbColor: Colors.red.shade600,
          inactiveTrackColor: Colors.red.shade100,
          onChanged: bloqueadoPeloPlano
              ? (_) => _exibirUpsellPlanoBloqueado()
              : (valor) => _alternarBloqueioComConfirmacao(contato, !valor),
        ),
      ],
    );
  }

  Widget _construirBlocoVerLocalizacao(
    Map<String, dynamic> contato,
    int id,
    AppLocalizations l10n,
  ) {
    final uid = contato['uid_contato'] as String?;

    if (uid == null) {
      return _botaoSolicitar(id, l10n);
    }

    final permissaoId = _servico.idPermissaoParaVer(uid);
    if (permissaoId == null) return _botaoSolicitar(id, l10n);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        // O cache local só vale enquanto o servidor não respondeu: um
        // documento de permissão que o servidor diz não existir NÃO está
        // aprovado, diga o cache o que disser (ver
        // MonitoramentoService._garantirCacheDaContaAtual).
        final documento = snapshot.data;
        final inexistenteNoServidor = documento != null &&
            !documento.exists &&
            !documento.metadata.isFromCache;
        final status = inexistenteNoServidor
            ? MonitoramentoService.statusVerNaoSolicitado
            : (documento?.data()?['status'] as String? ??
                (contato['status_ver_localizacao'] as String? ??
                    MonitoramentoService.statusVerNaoSolicitado));

        switch (status) {
          case MonitoramentoService.statusPendente:
            return _linhaStatus(
              icone: Icons.hourglass_top,
              cor: Colors.amber.shade800,
              texto: l10n.monitoramentoStatusAguardandoAprovacao,
            );
          case MonitoramentoService.statusNegado:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _linhaStatus(
                  icone: Icons.block,
                  cor: Colors.red.shade700,
                  texto: l10n.monitoramentoStatusNegado,
                ),
                const SizedBox(height: 4),
                _botaoSolicitar(id, l10n),
              ],
            );
          case MonitoramentoService.statusExpirado:
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _linhaStatus(
                  icone: Icons.timer_off_outlined,
                  cor: Colors.grey.shade600,
                  texto: l10n.monitoramentoStatusExpirado,
                ),
                const SizedBox(height: 4),
                _botaoSolicitar(id, l10n),
              ],
            );
          case MonitoramentoService.statusAprovado:
            return _construirLinhaAprovado(uid, l10n);
          default:
            return _botaoSolicitar(id, l10n);
        }
      },
    );
  }

  Widget _construirLinhaAprovado(String uid, AppLocalizations l10n) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _servico.buscarUltimaLocalizacao(uid),
      builder: (context, snapshot) {
        final aindaCarregando = snapshot.connectionState == ConnectionState.waiting;
        final dados = snapshot.data;
        // `dados == null` após a busca terminar significa que a permissão já
        // foi aprovada, mas o alvo ainda não teve nenhuma coordenada
        // capturada/enviada (ver Solução A em
        // `MonitoramentoService._enviarLocalizacaoImediataAoAceitar`, que é
        // fire-and-forget e pode levar alguns segundos) — em vez de deixar o
        // botão "Ver no mapa" silenciosamente desabilitado, avisamos
        // explicitamente que a primeira localização ainda está a caminho.
        final semLocalizacaoAinda = !aindaCarregando && dados == null;

        final momento = _momentoDaPosicao(dados);
        final String? subtitulo = momento == null ? null : _textoIdadePosicao(l10n, momento);
        final bool desatualizada = dados != null && _posicaoDesatualizada(momento);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Horário e avisos na largura toda; "Ver no mapa" em linha
            // própria (antes ficava espremido ao lado do aviso de 15 min).
            Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (semLocalizacaoAinda)
                    _linhaStatusAguardandoLocalizacao(l10n)
                  else
                    _linhaStatus(
                      icone: Icons.check_circle,
                      cor: Colors.green.shade700,
                      texto: l10n.monitoramentoStatusAprovado,
                    ),
                  if (subtitulo != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 22, top: 2),
                      child: Text(
                        subtitulo,
                        style: TextStyle(
                          fontSize: 11,
                          color: desatualizada ? Colors.orange.shade900 : Colors.grey.shade600,
                          fontWeight: desatualizada ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  _LinhaEstadoAlvo(uidAlvo: uid, l10n: l10n),
                  // Contato Android: o app dele não grava `plataforma` em
                  // monitoramento/atual (só o nativo do iOS grava "ios") e
                  // não tem rastreamento contínuo.
                  if (dados != null && dados['plataforma'] != 'ios')
                    Padding(
                      padding: const EdgeInsets.only(left: 22, top: 2),
                      child: Text(
                        l10n.monitoramentoContatoAndroid,
                        style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
                      ),
                    ),
                  if (desatualizada)
                    Padding(
                      padding: const EdgeInsets.only(left: 22, top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orange.shade800),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              l10n.monitoramentoPosicaoDesatualizada,
                              style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
            ),
            // Wrap: com fonte grande, "Atualizar localização" desce para a
            // linha de baixo em vez de estourar a largura do card.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: semLocalizacaoAinda
                      ? () => _avisarLocalizacaoAindaNaoDisponivel(l10n)
                      : (dados == null ? null : () => _abrirMapa(uid)),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(l10n.monitoramentoVerNoMapa),
                  style: TextButton.styleFrom(foregroundColor: _corDestaque),
                ),
                _botaoAtualizarLocalizacao(uid, l10n),
              ],
            ),
            if (_avisoAtualizacao(uid, l10n) case final aviso?)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  aviso,
                  style: TextStyle(fontSize: 11.5, color: Colors.red.shade700, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        );
      },
    );
  }

  /// "↻ Atualizar localização": pede a posição ATUAL ao aparelho do contato
  /// (mesmo push silencioso do "Ver no mapa" — o outro celular não mostra
  /// nada) sem diálogo nem travar a tela: durante a espera (até 30 s) o
  /// próprio botão vira um indicador pequeno. Depois de um
  /// `resource-exhausted` (1 pedido/min), fica desabilitado com "Aguarde Ns".
  Widget _botaoAtualizarLocalizacao(String uid, AppLocalizations l10n) {
    if (_atualizandoPosicao.contains(uid)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: _corDestaque),
            ),
            const SizedBox(width: 8),
            Text(l10n.monitoramentoAtualizandoLocalizacao,
                style: const TextStyle(fontSize: 13, color: _corDestaque)),
          ],
        ),
      );
    }
    final liberaEm = _servico.liberaNovoPedidoEm(uid);
    if (liberaEm != null) {
      return _ContagemLiberacao(
        ate: liberaEm,
        l10n: l10n,
        aoTerminar: () {
          if (mounted) setState(() {});
        },
      );
    }
    return TextButton.icon(
      onPressed: () => _atualizarLocalizacao(uid),
      icon: const Icon(Icons.refresh, size: 18),
      label: Text(l10n.monitoramentoAtualizarLocalizacao),
      style: TextButton.styleFrom(foregroundColor: _corDestaque),
    );
  }

  String? _avisoAtualizacao(String uid, AppLocalizations l10n) =>
      switch (_resultadoAtualizacao[uid]) {
        ResultadoPedidoPosicao.semResposta => l10n.monitoramentoSemRespostaAparelho,
        ResultadoPedidoPosicao.semPermissao => l10n.monitoramentoContatoNaoCompartilha,
        _ => null,
      };

  Future<void> _atualizarLocalizacao(String uid) async {
    // Toque duplo: ignorado enquanto o pedido estiver em andamento.
    if (_atualizandoPosicao.contains(uid) || _servico.liberaNovoPedidoEm(uid) != null) return;
    _atualizandoPosicao.add(uid);
    setState(() => _resultadoAtualizacao.remove(uid));
    if (!await garantirRecursoLiberadoOuExibirUpsell(context)) {
      if (mounted) setState(() => _atualizandoPosicao.remove(uid));
      return;
    }
    ResultadoPedidoPosicao resultado;
    try {
      resultado = await _servico
          .pedirLocalizacaoAtual(uid, limite: _limitePedidoPosicao)
          .timeout(_limitePedidoPosicao, onTimeout: () => ResultadoPedidoPosicao.semResposta);
    } catch (_) {
      resultado = ResultadoPedidoPosicao.semResposta;
    }
    if (!mounted) return;
    // O rebuild refaz a leitura de monitoramento/atual no card: com posição
    // nova, "Atualizado agora" e o aviso de mais de 15 min some sozinho.
    setState(() {
      _atualizandoPosicao.remove(uid);
      _resultadoAtualizacao[uid] = resultado;
    });
  }

  Widget _linhaStatusAguardandoLocalizacao(AppLocalizations l10n) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            l10n.monitoramentoAguardandoPrimeiraLocalizacao,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.amber.shade800,
            ),
          ),
        ),
      ],
    );
  }

  void _avisarLocalizacaoAindaNaoDisponivel(AppLocalizations l10n) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.monitoramentoLocalizacaoSendoAtualizada),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _botaoSolicitar(int id, AppLocalizations l10n) {
    // REGRA DE NEGÓCIO (pedido explícito do usuário, 2026-09-04): fora dos
    // 10 dias ativos do mês (e sem Premium), o botão já aparece em
    // vermelho — refletindo visualmente o mesmo bloqueio que
    // [_solicitarLocalizacao] já aplicaria via o retorno do serviço — e o
    // toque mostra o aviso de upsell diretamente, sem round-trip de rede.
    final bool bloqueado = _planoBloqueado;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () =>
            bloqueado ? _exibirUpsellPlanoBloqueado() : _solicitarLocalizacao(id),
        icon: Icon(bloqueado ? Icons.lock_outline : Icons.location_searching, size: 18),
        label: Text(
          bloqueado ? l10n.monitoramentoRecursoBloqueadoPlano : l10n.monitoramentoSolicitarLocalizacao,
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: bloqueado ? Colors.red.shade700 : _corDestaque,
          side: bloqueado ? BorderSide(color: Colors.red.shade300) : null,
        ),
      ),
    );
  }

  Widget _linhaStatus({required IconData icone, required Color cor, required String texto}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icone, size: 18, color: cor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            texto,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cor),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------
  // Switch de pré-autorização — "Permitir receber minha localização"
  // ------------------------------------------------------------

  /// Switch individual exibido em CADA card da lista, independentemente
  /// de o contato já ter solicitado a MINHA localização alguma vez — ver
  /// [MonitoramentoService.definirPermissaoCompartilhamento]. Sem
  /// documento de permissão ainda existente (contato nunca resolvido /
  /// nunca autorizado), o padrão é BLOQUEADO (nega por padrão).
  Widget _construirSwitchCompartilhar(
    Map<String, dynamic> contato,
    AppLocalizations l10n,
  ) {
    final uid = contato['uid_contato'] as String?;
    final permissaoId = uid != null
        ? _servico.idPermissaoParaCompartilhar(uid)
        : null;

    if (permissaoId == null) {
      return _linhaSwitchCompartilhar(
        contato: contato,
        status: contato['status_compartilhamento'] as String? ??
            MonitoramentoService.statusCompartilharInexistente,
        l10n: l10n,
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _servico.statusPermissaoStream(permissaoId),
      builder: (context, snapshot) {
        final statusServidor = snapshot.data?.data()?['status'] as String? ??
            (contato['status_compartilhamento'] as String? ??
                MonitoramentoService.statusCompartilharInexistente);
        final id = contato['id'] as int;
        final compartilhandoServidor = statusServidor == MonitoramentoService.statusAprovado;
        final override = _overrideCompartilhamento[id];
        // O servidor já confirmou o valor otimista: some com a
        // sobreposição, o Firestore volta a ser a fonte da verdade.
        if (override != null && override == compartilhandoServidor) {
          _overrideCompartilhamento.remove(id);
        }
        final compartilhandoAtual = _overrideCompartilhamento[id] ?? compartilhandoServidor;
        final status = compartilhandoAtual
            ? MonitoramentoService.statusAprovado
            : MonitoramentoService.statusBloqueado;
        return _linhaSwitchCompartilhar(contato: contato, status: status, l10n: l10n);
      },
    );
  }

  Widget _linhaSwitchCompartilhar({
    required Map<String, dynamic> contato,
    required String status,
    required AppLocalizations l10n,
  }) {
    final compartilhando = status == MonitoramentoService.statusAprovado;

    // REGRA DE NEGÓCIO (pedido explícito do usuário, 2026-09-04): mesmo
    // tratamento de [_construirControleBloqueio] — fora dos 10 dias
    // ativos do mês (e sem Premium), este switch aparece travado em
    // vermelho e qualquer toque mostra o aviso de upsell diretamente.
    final bool bloqueadoPeloPlano = _planoBloqueado;
    final String rotuloStatus = bloqueadoPeloPlano
        ? l10n.monitoramentoRecursoBloqueadoPlano
        : (compartilhando ? l10n.monitoramentoStatusAprovado : l10n.monitoramentoStatusBloqueado);

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        l10n.monitoramentoPermitirReceberLocalizacao,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        rotuloStatus,
        // CORREÇÃO (pedido do usuário, 2026-08-11): rótulo "Bloqueado"
        // usava cinza — sem destaque nenhum de urgência/restrição.
        // Agora vermelho quando bloqueado, mesma cor verde de sempre
        // quando aprovado.
        style: TextStyle(
          fontSize: 12,
          color: bloqueadoPeloPlano || !compartilhando ? Colors.red.shade700 : Colors.green.shade700,
          fontWeight: FontWeight.w600,
        ),
      ),
      // Cores padrão dos switches da aba Monitoramento (pedido do
      // usuário, 2026-08-11): verde quando ativado (permitido/
      // compartilhando), vermelho quando desativado (bloqueado) — antes
      // o estado desligado caía no cinza padrão do Material por falta de
      // `inactiveThumbColor`/`inactiveTrackColor` explícitos.
      activeColor: Colors.green.shade600,
      activeTrackColor: Colors.green.shade100,
      inactiveThumbColor: Colors.red.shade600,
      inactiveTrackColor: Colors.red.shade100,
      value: bloqueadoPeloPlano ? false : compartilhando,
      onChanged: bloqueadoPeloPlano
          ? (_) => _exibirUpsellPlanoBloqueado()
          : (valor) => _alternarPermissaoCompartilhar(contato, valor),
    );
  }

  Future<void> _alternarPermissaoCompartilhar(
    Map<String, dynamic> contato,
    bool permitir,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final id = contato['id'] as int;
    final travaAte = _travaCompartilhamentoAte[id];
    if (travaAte != null && DateTime.now().isBefore(travaAte)) return;
    // Desligar pede confirmação (teste da build 114: um toque a mais
    // revogou o compartilhamento recém-concedido sem ninguém perceber).
    // Ligar continua imediato.
    if (!permitir) {
      final nome = contato['nome'] as String? ?? '';
      final confirmou = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              content: Text(l10n.monitoramentoPararCompartilharConteudo(nome)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.cancelar),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(l10n.monitoramentoPararCompartilharBotao),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmou || !mounted) return;
    }
    if (!_tentarTravarSwitch(_travaCompartilhamentoAte, id)) return;
    // Atualização OTIMISTA instantânea (pedido do usuário, 2026-09-07): o
    // Switch e o rótulo "Aprovado"/"Bloqueado" mudam de cor no mesmo
    // frame do toque, sem esperar a viagem de ida e volta ao Firestore.
    // Revertida logo abaixo se a escrita falhar.
    if (mounted) setState(() => _overrideCompartilhamento[id] = permitir);
    final String resultado;
    try {
      resultado = await _servico.definirPermissaoCompartilhamento(
        idContatoLocal: id,
        permitir: permitir,
      );
    } finally {
      _liberarSwitch(_travaCompartilhamentoAte, id);
    }
    if (!mounted) return;
    if (resultado == 'sucesso') return;

    // Escrita falhou (ou foi recusada pelo servidor): reverte a
    // sobreposição otimista, o switch volta a refletir o valor real do
    // Firestore no próximo rebuild.
    setState(() => _overrideCompartilhamento.remove(id));

    // BLOQUEIO BIDIRECIONAL de localização do ciclo do Plano Free (ver
    // PlanoCicloService) — modal de upsell dedicado, em vez do SnackBar
    // genérico de erro.
    if (resultado == MonitoramentoService.statusBloqueadoPlanoFree) {
      await _exibirUpsellPlanoBloqueado();
      return;
    }

    final mensagem = switch (resultado) {
      'numero_nao_encontrado' => l10n.monitoramentoNumeroNaoEncontrado,
      'proprio_numero' => l10n.monitoramentoProprioNumero,
      _ => l10n.monitoramentoErroSolicitar,
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(mensagem),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.redAccent,
      ),
    );
  }
}

/// "Sua localização está sendo compartilhada continuamente com: …" — com o
/// botão de pausar/retomar, ou o convite para ativar (com consentimento
/// explícito em [ConsentimentoRastreamentoScreen]). Só aparece quando há
/// alguém aprovado para ver a minha localização.
class _CartaoCompartilhamentoContinuo extends StatelessWidget {
  const _CartaoCompartilhamentoContinuo({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final servico = RastreamentoContinuoService();
    return AnimatedBuilder(
      animation: Listenable.merge(
          [servico.monitorandoMe, servico.consentido, servico.pausado, servico.estado]),
      builder: (context, _) {
        final contatos = servico.monitorandoMe.value;
        if (contatos.isEmpty) return const SizedBox.shrink();
        final nomes = contatos.map((c) => c.nome).join(', ');
        final consentido = servico.consentido.value;
        final pausado = servico.pausado.value;
        final estado = servico.estado.value;

        String? situacao;
        Color corSituacao = Colors.green.shade800;
        if (consentido && !pausado && estado != null) {
          if (estado.rastreamentoAtivo) {
            situacao = l10n.rcAtivoAgora;
          } else if (estado.motivoInativo == 'plano_free') {
            final fim = servico.fimBloqueioPlano;
            situacao = l10n.rcIndisponivelPlano(fim == null ? '—' : formatarDiaMes(fim));
            corSituacao = Colors.red.shade700;
          } else if (!estado.sempre) {
            situacao = l10n.rcLimitadoSemSempre;
            corSituacao = Colors.orange.shade900;
          }
        } else if (consentido && pausado) {
          situacao = l10n.rcPausado;
          corSituacao = Colors.grey.shade700;
        }

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: _corDestaque.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.share_location_rounded, color: _corDestaque),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.rcTitulo,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                    if (consentido)
                      Switch(
                        value: !pausado,
                        activeThumbColor: _corDestaque,
                        onChanged: (ligado) => servico.definirPausa(!ligado),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  consentido ? l10n.rcCompartilhandoCom(nomes) : l10n.rcConvite(nomes),
                  style: const TextStyle(fontSize: 13.5, height: 1.35),
                ),
                if (situacao != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    situacao,
                    style: TextStyle(fontSize: 12.5, color: corSituacao, fontWeight: FontWeight.w600),
                  ),
                ],
                if (!consentido) ...[
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<bool>(
                      builder: (_) => const ConsentimentoRastreamentoScreen(),
                    )),
                    style: FilledButton.styleFrom(backgroundColor: _corDestaque),
                    child: Text(l10n.rcBotaoAtivar),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

}

/// Do lado de quem monitora: avisa quando o contato está nos dias
/// bloqueados do Plano Free ("Localização indisponível no Plano Free até
/// DD/MM") ou sem atualização contínua. Lê o `monitoramento/estado` que o
/// aparelho do contato grava.
class _LinhaEstadoAlvo extends StatelessWidget {
  const _LinhaEstadoAlvo({required this.uidAlvo, required this.l10n});

  final String uidAlvo;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>?>(
      stream: MonitoramentoService().estadoAlvoStream(uidAlvo),
      builder: (context, snapshot) {
        final estado = snapshot.data;
        if (estado == null) return const SizedBox.shrink();
        String? texto;
        Color cor = Colors.orange.shade900;
        final bloqueadoAte = estado['bloqueadoAte'];
        if (estado['motivoInativo'] == 'plano_free' && bloqueadoAte is Timestamp) {
          texto = l10n.rcAlvoIndisponivelPlano(formatarDiaMes(bloqueadoAte.toDate()));
          cor = Colors.red.shade700;
        } else if (estado['rastreamentoAtivo'] != true) {
          texto = l10n.rcAlvoLimitado;
        }
        if (texto == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 22, top: 2),
          child: Text(texto, style: TextStyle(fontSize: 11, color: cor, fontWeight: FontWeight.w600)),
        );
      },
    );
  }
}

/// "↻ Aguarde Ns" desabilitado depois de um `resource-exhausted` do
/// `pedirLocalizacaoAtual`. Conta com o próprio timer — só este botão se
/// redesenha a cada segundo, não o card (que releria a posição no
/// Firestore) — e avisa [aoTerminar] quando o pedido volta a ser aceito.
class _ContagemLiberacao extends StatefulWidget {
  const _ContagemLiberacao({required this.ate, required this.l10n, required this.aoTerminar});

  final DateTime ate;
  final AppLocalizations l10n;
  final VoidCallback aoTerminar;

  @override
  State<_ContagemLiberacao> createState() => _ContagemLiberacaoState();
}

class _ContagemLiberacaoState extends State<_ContagemLiberacao> {
  Timer? _timer;

  int get _segundosRestantes {
    final ms = widget.ate.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_segundosRestantes == 0) {
        _timer?.cancel();
        widget.aoTerminar();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: null,
      icon: const Icon(Icons.refresh, size: 18),
      label: Text(widget.l10n.monitoramentoAguardeSegundos(_segundosRestantes)),
    );
  }
}
