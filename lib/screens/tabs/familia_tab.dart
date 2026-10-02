import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import '../../services/alarme_agendado_cloud_service.dart';
import '../../services/database_helper.dart';
import '../../services/wallpaper_service.dart';
import '../../services/rotina_alarme_service.dart';
import '../../services/api_service.dart';
import '../../services/contatos_emergencia_service.dart';
import '../../services/emergency_alert_service.dart';
import '../../services/firebase_sync_service.dart';
import '../../models/alarme_rotina.dart';
import '../../widgets/pin_dialog.dart';
import '../../widgets/plano_bloqueado_dialog.dart';

/// Aba responsável pelo gerenciador de múltiplos alarmes de rotina de
/// check-in, no estilo do despertador do iPhone: uma lista de alarmes,
/// cada um com seu próprio horário, dias de repetição e etiqueta, que
/// podem ser ativados/desativados individualmente com um switch.
///
/// Abaixo da lista de alarmes, exibe também (em modo somente leitura) os
/// contatos de emergência que receberão o alerta — reaproveitando
/// EXATAMENTE os mesmos dados cadastrados e centralizados na aba de
/// Configurações (tabela 'contatos_emergencia'), sem duplicar o cadastro.
class FamiliaTab extends StatefulWidget {
  const FamiliaTab({super.key});

  @override
  State<FamiliaTab> createState() => FamiliaTabState();
}

class FamiliaTabState extends State<FamiliaTab> with WidgetsBindingObserver {
  final DatabaseHelper _db = DatabaseHelper();

  bool _carregandoAlarmes = true;
  List<AlarmeRotina> _alarmes = [];

  bool _carregandoContatos = true;
  List<Map<String, dynamic>> _contatosEmergencia = [];
  Map<int, bool> _pausadoHojeMap = {};

  // 🟢 TRAVA ADICIONADA AQUI (Impede o clique duplo/concorrência)
  bool _processandoDespausa = false;

  static const List<int> _valoresDias = [1, 2, 3, 4, 5, 6, 7];

  /// Iniciais de 1 caractere dos dias da semana (chip circular do
  /// seletor de repetição), traduzidas via [AppLocalizations] — nunca
  /// hardcoded, para exibir corretamente nos 11 idiomas suportados.
  List<String> _iniciaisDias(AppLocalizations l10n) => [
        l10n.familiaDiaInicialSeg,
        l10n.familiaDiaInicialTer,
        l10n.familiaDiaInicialQua,
        l10n.familiaDiaInicialQui,
        l10n.familiaDiaInicialSex,
        l10n.familiaDiaInicialSab,
        l10n.familiaDiaInicialDom,
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _carregarAlarmes();
    _carregarContatosEmergencia();
    ContatosEmergenciaService.versaoContatos.addListener(_aoContatosAlterados);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _carregarAlarmes();
      _carregarContatosEmergencia();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ContatosEmergenciaService.versaoContatos.removeListener(_aoContatosAlterados);
    super.dispose();
  }

  void _aoContatosAlterados() {
    _carregarContatosEmergencia();
  }

  /// Retorna a data de hoje formatada em String (ex: '2026-07-19')
  String _obterDataHojeFormatada() {
    final agora = DateTime.now();
    return '${agora.year}-${agora.month.toString().padLeft(2, '0')}-${agora.day.toString().padLeft(2, '0')}';
  }

  Future<void> _carregarAlarmes() async {
    if (!mounted) return;
    setState(() => _carregandoAlarmes = true);
    try {
      final dados = await _db.listarAlarmes();
      print('DEBUG: Encontrados ${dados.length} alarmes no banco SQLite');

      final alarmesAtualizados = <AlarmeRotina>[];
      final pausadoHojeMap = <int, bool>{};
      final dataHoje = _obterDataHojeFormatada();

      for (var mapa in dados) {
        final alarme = AlarmeRotina.fromMap(mapa);
        if (alarme.id != null) {
          final String estadoPausaNoBanco = mapa['alarme_pausado']?.toString() ?? '0';
          pausadoHojeMap[alarme.id!] = (estadoPausaNoBanco == dataHoje);
        }
        alarmesAtualizados.add(alarme);
      }

      if (mounted) {
        setState(() {
          _alarmes = alarmesAtualizados;
          _pausadoHojeMap = pausadoHojeMap;
          _carregandoAlarmes = false;
        });
      }
    } catch (e) {
      print('DEBUG ERRO ao carregar alarmes: $e');
      if (mounted) setState(() => _carregandoAlarmes = false);
    }
  }

  Future<void> _carregarContatosEmergencia() async {
    if (!mounted) return;
    setState(() => _carregandoContatos = true);
    try {
      await _db.processarExclusoesPendentesExpiradas();
      final contatos = await _db.getContatosEmergencia();
      if (!mounted) return;
      setState(() {
        _contatosEmergencia = contatos;
        _carregandoContatos = false;
      });
    } catch (_) {
      if (mounted) setState(() => _carregandoContatos = false);
    }
  }

  bool _isExclusaoPendente(Map<String, dynamic> contato) {
    final valor = contato['exclusao_pendente'];
    return valor == 1 || valor == true;
  }

  /// PROTEÇÃO PARA PAUSAR/EDITAR/EXCLUIR: exige o PIN correto antes de
  /// qualquer uma dessas ações prosseguir. Reaproveita [exibirDialogoPin]
  /// (mesmo componente do desarme do alarme de rotina), com
  /// `mostrarBotaoCancelar: true` — como o diálogo não é
  /// `barrierDismissible` mas NÃO bloqueia o botão/gesto de voltar do
  /// sistema, apertar "Voltar" fecha o diálogo sem chamar
  /// `aoConfirmarPinCorreto`, cancelando a ação (retorna `false` aqui).
  /// Duas tentativas erradas de PIN disparam o alerta de emergência com
  /// localização, exatamente como no desarme do alarme.
  Future<bool> _confirmarComPin(String acaoDescricao) async {
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    final config = await _db.getUserConfig();
    final pinReal = config?['pin_real'] as String? ?? '1234';

    bool confirmado = false;
    if (!mounted) return false;
    await exibirDialogoPin(
      context: context,
      pinEsperado: pinReal,
      mostrarBotaoCancelar: true,
      limiteErrosConsecutivos: 2,
      aoConfirmarPinCorreto: () async {
        confirmado = true;
      },
      aoAtingirLimiteDeErros: () => _dispararAlertaPinIncorretoNaFamilia(
        motivo: l10n.familiaPinMotivoTexto(acaoDescricao),
      ),
    );
    return confirmado;
  }

  /// Mesmo padrão de disparo (nuvem primeiro, aguardada, depois o fluxo
  /// local) já usado em todo o resto do app para tentativas de desarme
  /// com PIN incorreto — ver
  /// [FirebaseSyncService.dispararAlertaTentativaDesarmeIncorreto] e
  /// [EmergencyAlertService.dispararAlertaTentativaDesarmeIncorreto].
  Future<void> _dispararAlertaPinIncorretoNaFamilia({required String motivo}) async {
    try {
      await FirebaseSyncService().dispararAlertaTentativaDesarmeIncorreto(motivo: motivo);
    } catch (e) {
      debugPrint('⚠️ [Família] Falha ao disparar alerta prioritário na nuvem: $e');
    }
    try {
      await EmergencyAlertService().dispararAlertaTentativaDesarmeIncorreto(motivo: motivo);
    } catch (e) {
      debugPrint('⚠️ [Família] Falha ao disparar alerta de tentativa de desarme incorreta: $e');
    }
  }

Future<void> _alternarAtivo(AlarmeRotina alarme, bool ativo) async {
    if (alarme.id == null) return;

    // REGRA DE NEGÓCIO (pedido explícito do usuário, 2026-09-04): reativar
    // um alarme pelo switch é, na prática, o mesmo "recurso" que salvar um
    // alarme novo — fora dos 10 dias ativos do mês (e sem Premium), não
    // pode funcionar. Checado ANTES de qualquer outra coisa, senão o
    // switch viraria um atalho para contornar a mesma trava do botão
    // "Salvar Alarme" (ver modal de criação/edição mais abaixo).
    if (ativo && !await garantirRecursoLiberadoOuExibirUpsell(context)) return;
    if (!mounted) return;

    final bool estaPausado = _pausadoHojeMap[alarme.id] ?? false;

    // Se estava pausado e o usuário tocou para ativar/ligar a chave
    if (estaPausado && ativo) {
      await _despausarAlarmeManual(alarme);
      return;
    }

    // PROTEÇÃO: desativar pelo switch é, na prática, uma forma de
    // "pausar" o alarme — exige o mesmo PIN que o gesto de deslizar.
    if (!ativo) {
      final confirmado =
          await _confirmarComPin(AppLocalizations.of(context)!.familiaAcaoPausar);
      if (!confirmado) return;
    }

    await _db.alternarAtivoAlarme(alarme.id!, ativo);

    if (ativo) {
      final atualizado = await _db.buscarAlarmePorId(alarme.id!);
      if (atualizado != null) {
        await RotinaAlarmeService.agendarAlarme(atualizado);
        // Reativado pelo usuário — pode carregar um status antigo
        // (CONFIRMADO_SEGURA/ALERTA_DISPARADO) de antes de ter sido
        // desativado; o ciclo que está começando agora precisa nascer
        // PENDENTE. Ver [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
        AlarmeAgendadoCloudService().sinalizarNovoCiclo(alarme.id!.toString());
      }
    } else {
      await RotinaAlarmeService.cancelarAlarme(alarme.id!);
    }

    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      final etiquetaEvento = alarme.etiquetaExibida(l10n);
      await _db.inserirEventoHistorico(
        titulo: ativo ? l10n.historicoAlarmeAtivadoTitulo : l10n.historicoAlarmeDesativadoTitulo,
        descricao: ativo
            ? l10n.historicoAlarmeAtivadoDescricao(etiquetaEvento, alarme.horarioFormatado)
            : l10n.historicoAlarmeDesativadoDescricao(etiquetaEvento, alarme.horarioFormatado),
        categoria: 'familia',
      );
    }

    ApiService().salvarRotina(
      alarmeId: alarme.id,
      horario: '${alarme.hora.toString().padLeft(2, '0')}:'
          '${alarme.minuto.toString().padLeft(2, '0')}:00',
      toleranciaMinutos: alarme.minutosTolerancia,
      etiqueta: alarme.etiqueta,
      contextoPersonalizado: alarme.contextoPersonalizado,
      diasSemana: alarme.diasSemana.map((d) => d.toString()).toList(),
      ativo: ativo,
    );

    await _carregarAlarmes();
  }

  Future<void> _excluirAlarme(AlarmeRotina alarme) async {
    if (alarme.id == null) return;

    await RotinaAlarmeService.cancelarAlarme(alarme.id!);
    await _db.deletarAlarme(alarme.id!);

    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      final etiquetaEvento = alarme.etiquetaExibida(l10n);
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoAlarmeRemovidoTitulo,
        descricao: l10n.historicoAlarmeRemovidoDescricao(etiquetaEvento, alarme.horarioFormatado),
        categoria: 'familia',
      );
    }

    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.familiaAlarmeRemovido),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

Future<void> _pausarAlarmePorHoje(AlarmeRotina alarme) async {
    if (alarme.id == null) return;
    final dataHoje = _obterDataHojeFormatada();

    final dbInstancia = await _db.database;
    await dbInstancia.update(
      'alarmes_rotina',
      {'alarme_pausado': dataHoje},
      where: 'id = ?',
      whereArgs: [alarme.id],
    );

    // CORREÇÃO (bug real observado em teste): a atualização do SQLite
    // acima só controla o texto exibido nesta tela ("Pausado até
    // 00:00") — sozinha, ela NUNCA cancelava o disparo já agendado no
    // AndroidAlarmManager/alarme nativo paralelo, que continuava
    // tocando normalmente no horário mesmo com o alarme "pausado". Esta
    // chamada cancela de fato o disparo de hoje e reagenda diretamente
    // para o próximo dia válido (ver
    // [RotinaAlarmeService.pausarAlarmePorHoje]).
    try {
      await RotinaAlarmeService.pausarAlarmePorHoje(alarme.id!, alarme.toMap());
    } catch (e) {
      debugPrint('⚠️ Falha ao cancelar o disparo nativo do alarme pausado por hoje: $e');
    }

    if (mounted) {
      final l10n = AppLocalizations.of(context)!;
      final etiquetaEvento = alarme.etiquetaExibida(l10n);
      await _db.inserirEventoHistorico(
        titulo: l10n.historicoAlarmePausadoTitulo,
        descricao: l10n.historicoAlarmePausadoDescricao(etiquetaEvento, alarme.horarioFormatado),
        categoria: 'familia',
      );
    }

    await _carregarAlarmes();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.familiaAlarmePausadoAte),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
  String _obterDiaRetorno(AlarmeRotina alarme, AppLocalizations l10n) {
    final diasSiglas = [
      l10n.familiaDiaAbrevSeg,
      l10n.familiaDiaAbrevTer,
      l10n.familiaDiaAbrevQua,
      l10n.familiaDiaAbrevQui,
      l10n.familiaDiaAbrevSex,
      l10n.familiaDiaAbrevSab,
      l10n.familiaDiaAbrevDom,
    ];
    final agora = DateTime.now();
    // Amanhã (dia seguinte à pausa)
    final amanha = agora.add(const Duration(days: 1));
    return diasSiglas[amanha.weekday - 1];
  }
Future<void> _despausarAlarmeManual(AlarmeRotina alarme) async {
    if (alarme.id == null) return;
    // Trava contra clique duplo/concorrência (campo já existia, mas nunca
    // era lido/escrito — a função fazia update no SQLite, reagendava o
    // alarme nativo, inseria histórico e sincronizava com o backend sem
    // nenhuma proteção contra duas chamadas concorrentes, ex: usuário
    // batendo duas vezes rápido no switch ou no "toque para reativar").
    if (_processandoDespausa) return;
    _processandoDespausa = true;

    // 1. Atualização visual instantânea no mesmo frame (sem delay)
    if (mounted) {
      setState(() {
        _pausadoHojeMap[alarme.id!] = false;
        final index = _alarmes.indexWhere((item) => item.id == alarme.id);
        if (index != -1) {
          _alarmes[index] = _alarmes[index].copyWith(pausado: false, ativo: true);
        }
      });
    }

    try {
      // 2. Atualiza o banco SQLite zerando a pausa e ativando o alarme
      final dbInstancia = await _db.database;
      await dbInstancia.update(
        'alarmes_rotina',
        {
          'alarme_pausado': '0',
          'ativo': 1,
        },
        where: 'id = ?',
        whereArgs: [alarme.id],
      );

      // 3. Reagenda apenas o alarme nativo no Android (sem re-disparar o ciclo de alteração do banco)
      final alarmeReativado = alarme.copyWith(pausado: false, ativo: true);
      await RotinaAlarmeService.agendarAlarme(alarmeReativado.toMap());
      // Ver [AlarmeAgendadoCloudService.sinalizarNovoCiclo] — mesmo motivo
      // do toggle em [_alternarAtivo].
      AlarmeAgendadoCloudService().sinalizarNovoCiclo(alarme.id!.toString());

      // 4. Registra no histórico
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        final etiquetaEvento = alarme.etiquetaExibida(l10n);
        await _db.inserirEventoHistorico(
          titulo: l10n.historicoAlarmeReativadoTitulo,
          descricao: l10n.historicoAlarmeReativadoDescricao(etiquetaEvento, alarme.horarioFormatado),
          categoria: 'familia',
        );
      }

      // 5. Sincroniza em segundo plano
      _sincronizarRotinaComBackend(alarmeReativado);

      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.familiaReativadoComSucesso(
                alarme.etiquetaExibida(l10n),
                alarme.horarioFormatado,
              ),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      _processandoDespausa = false;
    }
  }

  void abrirModalAdicionarAlarme() {
    _abrirModalAlarme();
  }

  Future<void> _sincronizarRotinaComBackend(AlarmeRotina alarme) async {
    try {
      await ApiService().salvarRotina(
        alarmeId: alarme.id,
        horario: '${alarme.hora.toString().padLeft(2, '0')}:${alarme.minuto.toString().padLeft(2, '0')}:00',
        toleranciaMinutos: alarme.minutosTolerancia,
        etiqueta: alarme.etiqueta,
        contextoPersonalizado: alarme.contextoPersonalizado,
        diasSemana: alarme.diasSemana.map((d) => d.toString()).toList(),
        ativo: alarme.ativo,
      );
    } catch (e) {
      print('⚠️ Backend offline ($e). Alarme mantido normalmente no SQLite.');
    }
  }

  Future<void> _abrirModalAlarme({AlarmeRotina? alarmeExistente}) async {
    int horaSelecionada = alarmeExistente?.hora ?? TimeOfDay.now().hour;
    int minutoSelecionado = alarmeExistente?.minuto ?? 0;
    final Set<int> diasSelecionados = Set<int>.from(alarmeExistente?.diasSemana ?? {});
    // Se a etiqueta atual for a chave neutra padrão (ou uma tradução
    // legada — ver AlarmeRotina.temEtiquetaPadrao), o campo começa VAZIO
    // em vez de mostrar "KEY_ALARME_ROTINA"/um texto de outro idioma: o
    // usuário só vê algo aqui quando de fato digitou um rótulo próprio.
    final etiquetaController = TextEditingController(
      text: (alarmeExistente == null || alarmeExistente.temEtiquetaPadrao)
          ? ''
          : alarmeExistente.etiqueta,
    );
    final contextoController =
        TextEditingController(text: alarmeExistente?.contextoPersonalizado ?? '');
    int minutosTolerancia = alarmeExistente?.minutosTolerancia ?? 10;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.alarm_add, color: Color(0xFF4C7040)),
                          const SizedBox(width: 8),
                          Text(
                            alarmeExistente == null
                                ? AppLocalizations.of(ctx)!.familiaAdicionarAlarme
                                : AppLocalizations.of(ctx)!.familiaEditarAlarme,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Column(
                            children: [
                              Text(
                                AppLocalizations.of(ctx)!.familiaHoraLabel,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: horaSelecionada),
                                  onSelectedItemChanged: (index) => setModalState(() => horaSelecionada = index),
                                  children: List.generate(
                                    24,
                                    (index) => Center(
                                      child: Text(
                                        index.toString().padLeft(2, '0'),
                                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              ':',
                              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey),
                            ),
                          ),
                          Column(
                            children: [
                              Text(
                                AppLocalizations.of(ctx)!.familiaMinutoLabel,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                              ),
                              SizedBox(
                                width: 70,
                                height: 110,
                                child: CupertinoPicker(
                                  itemExtent: 36,
                                  scrollController: FixedExtentScrollController(initialItem: minutoSelecionado),
                                  onSelectedItemChanged: (index) => setModalState(() => minutoSelecionado = index),
                                  children: List.generate(
                                    60,
                                    (index) => Center(
                                      child: Text(
                                        index.toString().padLeft(2, '0'),
                                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        AppLocalizations.of(ctx)!.familiaRepetirLabel,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: List.generate(_valoresDias.length, (index) {
                          final iniciaisDias = _iniciaisDias(AppLocalizations.of(ctx)!);
                          final valorDia = _valoresDias[index];
                          final selecionado = diasSelecionados.contains(valorDia);
                          return GestureDetector(
                            onTap: () {
                              setModalState(() {
                                if (selecionado) {
                                  diasSelecionados.remove(valorDia);
                                } else {
                                  diasSelecionados.add(valorDia);
                                }
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selecionado ? const Color(0xFF4C7040) : Colors.grey.shade200,
                              ),
                              child: Center(
                                child: Text(
                                  iniciaisDias[index],
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: selecionado ? Colors.white : Colors.black54,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: etiquetaController,
                        decoration: InputDecoration(
                          labelText: AppLocalizations.of(ctx)!.familiaEtiquetaLabel,
                          hintText: AppLocalizations.of(ctx)!.familiaEtiquetaHint,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.label_outline),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: contextoController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: AppLocalizations.of(ctx)!.familiaDicaContextoOpcionalLabel,
                          hintText: AppLocalizations.of(ctx)!.familiaDicaContextoOpcionalHint,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          prefixIcon: const Icon(Icons.edit_note),
                          helperText: Platform.isIOS
                              ? AppLocalizations.of(ctx)!.familiaDicaContextoHelperIos
                              : AppLocalizations.of(ctx)!.familiaDicaContextoHelper,
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Icon(Icons.timer_outlined, color: Colors.grey, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppLocalizations.of(ctx)!.familiaToleranciaLabel,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                          DropdownButton<int>(
                            value: minutosTolerancia,
                            items: const [5, 10, 15, 20, 30, 45, 60]
                                .map((minutos) => DropdownMenuItem(
                                      value: minutos,
                                      child: Text(AppLocalizations.of(ctx)!.familiaMinutosAbrev(minutos)),
                                    ))
                                .toList(),
                            onChanged: (valor) {
                              if (valor == null) return;
                              setModalState(() => minutosTolerancia = valor);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF4C7040),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            // REGRA DE NEGÓCIO (pedido explícito do usuário,
                            // 2026-09-04): fora dos 10 dias ativos do mês (e
                            // sem Premium), o app não deve salvar NENHUM
                            // alarme de rotina novo/editado — exibe o mesmo
                            // aviso de upsell já usado em outros pontos do
                            // app (SOS manual/físico) e interrompe aqui,
                            // ANTES de qualquer escrita no SQLite. Mesma
                            // trava única do ciclo do Plano Free (ver
                            // PlanoCicloService) — nunca um teto numérico
                            // separado.
                            if (!await garantirRecursoLiberadoOuExibirUpsell(ctx)) return;
                            if (!ctx.mounted) return;

                            final etiqueta = etiquetaController.text.trim();
                            final contexto = contextoController.text.trim();

                            final alarme = AlarmeRotina(
                              id: alarmeExistente?.id,
                              hora: horaSelecionada,
                              minuto: minutoSelecionado,
                              diasSemana: diasSelecionados,
                              ativo: alarmeExistente?.ativo ?? true,
                              // Chave NEUTRA (independente de idioma) quando
                              // o campo fica em branco — nunca o texto já
                              // traduzido: é isso que garante que este
                              // agendamento também traduza corretamente ao
                              // trocar o idioma do app mais tarde (ver
                              // AlarmeRotina.etiquetaExibida).
                              etiqueta: etiqueta.isNotEmpty
                                  ? etiqueta
                                  : AlarmeRotina.chaveEtiquetaPadrao,
                              contextoPersonalizado: contexto,
                              minutosTolerancia: minutosTolerancia,
                            );

                            final l10nCtx = AppLocalizations.of(ctx)!;
                            int idSalvo;
                            if (alarmeExistente == null) {
                              idSalvo = await _db.inserirAlarme(alarme.toMap());
                              await _db.inserirEventoHistorico(
                                titulo: l10nCtx.historicoAlarmeCriadoTitulo,
                                descricao: l10nCtx.historicoAlarmeCriadoEditadoDescricao(
                                  alarme.etiquetaExibida(l10nCtx),
                                  alarme.horarioFormatado,
                                  alarme.diasResumidos(l10nCtx),
                                ),
                                categoria: 'familia',
                              );
                            } else {
                              idSalvo = alarmeExistente.id!;
                              await _db.atualizarAlarme(alarme.toMap());
                              await _db.inserirEventoHistorico(
                                titulo: l10nCtx.historicoAlarmeEditadoTitulo,
                                descricao: l10nCtx.historicoAlarmeCriadoEditadoDescricao(
                                  alarme.etiquetaExibida(l10nCtx),
                                  alarme.horarioFormatado,
                                  alarme.diasResumidos(l10nCtx),
                                ),
                                categoria: 'familia',
                              );
                            }

                            if (alarme.ativo) {
                              final dadosSalvos = await _db.buscarAlarmePorId(idSalvo);
                              if (dadosSalvos != null) {
                                await RotinaAlarmeService.agendarAlarme(dadosSalvos);
                                // Criado ou editado (horário/dias podem ter
                                // mudado) — o ciclo que está começando
                                // agora não pode herdar o status de uma
                                // programação anterior. Ver
                                // [AlarmeAgendadoCloudService.sinalizarNovoCiclo].
                                AlarmeAgendadoCloudService()
                                    .sinalizarNovoCiclo(idSalvo.toString());
                              }
                            } else {
                              await RotinaAlarmeService.cancelarAlarme(idSalvo);
                            }

                            _sincronizarRotinaComBackend(alarme.copyWith(id: idSalvo));

                            if (ctx.mounted) Navigator.of(ctx).pop();
                            await _carregarAlarmes();
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.check, color: Colors.white),
                          label: Text(
                            AppLocalizations.of(ctx)!.familiaSalvarAlarme,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<String>(
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
              child: RefreshIndicator(
                onRefresh: () async {
                  await _carregarAlarmes();
                  await _carregarContatosEmergencia();
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.alarm, color: Color(0xFF4C7040), size: 28),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            AppLocalizations.of(context)!.familiaAlarmesRotinaTitulo,
                            textAlign: TextAlign.center,
                            softWrap: true,
                            overflow: TextOverflow.clip,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _construirListaAlarmes(),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 8),
                    _construirCardContatosEmergencia(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
Widget _construirListaAlarmes() {
    if (_carregandoAlarmes) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_alarmes.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          children: [
            Icon(Icons.alarm_off, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context)!.familiaNenhumAlarme,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return Column(
      children: _alarmes.map((alarme) {
        final bool estaPausadoHoje = _pausadoHojeMap[alarme.id] ?? false;

        return Dismissible(
          key: ValueKey('alarme_dismiss_${alarme.id}'),
          direction: estaPausadoHoje 
              ? DismissDirection.endToStart 
              : DismissDirection.horizontal,
          onDismissed: (direction) async {
            setState(() {
              _alarmes.removeWhere((item) => item.id == alarme.id);
            });

            if (direction == DismissDirection.endToStart) {
              await _excluirAlarme(alarme);
            } else if (direction == DismissDirection.startToEnd) {
              await _pausarAlarmePorHoje(alarme);
            }
          },
          background: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.pause_circle_filled, color: Colors.white),
                const SizedBox(width: 8),
                Text(AppLocalizations.of(context)!.familiaPausarPorHoje, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          secondaryBackground: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: Colors.red.shade600,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(AppLocalizations.of(context)!.familiaExcluirPermanente, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                const Icon(Icons.delete, color: Colors.white),
              ],
            ),
          ),
          confirmDismiss: (direction) async {
            // Capturados ANTES de qualquer 'await' para nunca usar o
            // BuildContext após um async gap.
            final acaoExcluir = AppLocalizations.of(context)!.familiaAcaoExcluir;
            final acaoPausar = AppLocalizations.of(context)!.familiaAcaoPausar;
            if (direction == DismissDirection.endToStart) {
              final confirmouIntencao = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(AppLocalizations.of(ctx)!.familiaExcluirAlarmeTitulo),
                      content: Text(AppLocalizations.of(ctx)!.familiaExcluirAlarmeConteudo(alarme.etiquetaExibida(AppLocalizations.of(ctx)!), alarme.horarioFormatado)),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(AppLocalizations.of(ctx)!.cancelar)),
                        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.of(ctx).pop(true), child: Text(AppLocalizations.of(ctx)!.excluir)),
                      ],
                    ),
                  ) ?? false;
              // PROTEÇÃO: exclusão só prossegue com o PIN correto.
              if (!confirmouIntencao) return false;
              return await _confirmarComPin(acaoExcluir);
            } else if (direction == DismissDirection.startToEnd && !estaPausadoHoje) {
              final confirmouIntencao = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(AppLocalizations.of(ctx)!.familiaPausarAlarmeTitulo),
                      content: Text(AppLocalizations.of(ctx)!.familiaPausarAlarmeConteudo(alarme.etiquetaExibida(AppLocalizations.of(ctx)!), alarme.horarioFormatado)),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: Text(AppLocalizations.of(ctx)!.cancelar)),
                        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.blue), onPressed: () => Navigator.of(ctx).pop(true), child: Text(AppLocalizations.of(ctx)!.familiaPausarBotao)),
                      ],
                    ),
                  ) ?? false;
              // PROTEÇÃO: pausa só prossegue com o PIN correto.
              if (!confirmouIntencao) return false;
              return await _confirmarComPin(acaoPausar);
            }
            return false;
          },
          child: Card(
            elevation: 0,
            color: estaPausadoHoje ? Colors.amber.shade50.withOpacity(0.9) : Colors.white.withOpacity(0.92),
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: estaPausadoHoje ? Colors.amber.shade300 : Colors.grey.shade200, width: estaPausadoHoje ? 1.5 : 1),
            ),
            child: GestureDetector(
              onLongPress: () async {
                // PROTEÇÃO: editar um alarme existente exige o PIN
                // correto antes de abrir o formulário.
                final confirmado =
                    await _confirmarComPin(AppLocalizations.of(context)!.familiaAcaoEditar);
                if (confirmado) _abrirModalAlarme(alarmeExistente: alarme);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (estaPausadoHoje) ...[
                            Row(
                              children: [
                                Icon(Icons.pause_circle_filled, color: Colors.amber.shade800, size: 22),
                                const SizedBox(width: 6),
                                Text(
                                  AppLocalizations.of(context)!.familiaPausadoAte0000,
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.amber.shade800),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              AppLocalizations.of(context)!.familiaRetorna(
                                  alarme.horarioFormatado,
                                  _obterDiaRetorno(alarme, AppLocalizations.of(context)!)),
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              alarme.etiquetaExibida(AppLocalizations.of(context)!),
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                            const SizedBox(height: 6),
                            InkWell(
                              onTap: () async {
                                await _despausarAlarmeManual(alarme);
                              },
                              child: Text(
                                AppLocalizations.of(context)!.familiaToqueReativar,
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.blue.shade700),
                              ),
                            ),
                          ] else ...[
                            Text(
                              alarme.horarioFormatado,
                              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: alarme.ativo ? Colors.black87 : Colors.grey),
                            ),
                            Text(
                              alarme.diasResumidos(AppLocalizations.of(context)!),
                              style: TextStyle(color: alarme.ativo ? Colors.grey.shade800 : Colors.grey.shade400, fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              alarme.etiquetaExibida(AppLocalizations.of(context)!),
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Switch(
                      activeColor: const Color(0xFF4C7040),
                      // Se estiver pausado hoje, o switch fica cinza/desligado (false)
                      value: estaPausadoHoje ? false : alarme.ativo,
                      onChanged: (ativo) => _alternarAtivo(alarme, ativo),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
   Widget _construirCardContatosEmergencia() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.contact_emergency, color: Color(0xFF4C7040)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  AppLocalizations.of(context)!.familiaContatosEmergenciaTitulo,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            AppLocalizations.of(context)!.familiaContatosEmergenciaDescricao,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          if (_carregandoContatos)
            const Center(child: CircularProgressIndicator())
          else if (_contatosEmergencia.isEmpty)
            Text(
              AppLocalizations.of(context)!.familiaNenhumContato,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            )
          else
            Column(
              children: _contatosEmergencia.map((contato) {
                final nome = contato['nome'] as String? ?? AppLocalizations.of(context)!.familiaSemNome;
                final telefone = contato['telefone'] as String? ?? '';
                final pendente = _isExclusaoPendente(contato);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFFE8F5E9),
                        child: Text(
                          nome.isNotEmpty ? nome[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Color(0xFF4C7040),
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              nome,
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            Text(
                              pendente ? AppLocalizations.of(context)!.familiaRemovendoEmCarencia : telefone,
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: pendente ? Colors.orange.shade800 : Colors.black54,
                                fontWeight: pendente ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (pendente)
                        const Icon(Icons.hourglass_bottom, color: Colors.orange, size: 18),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}