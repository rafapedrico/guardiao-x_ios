import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_helper.dart';
import 'l10n_headless_service.dart';
import 'monitoramento_service.dart';
import 'plano_ciclo_service.dart';
import 'sos_plano_aviso_service.dart';

/// Estado do rastreamento contínuo lido do nativo (mesmo conteúdo gravado
/// em `usuarios/{uid}/monitoramento/estado`).
@immutable
class EstadoRastreamento {
  const EstadoRastreamento({
    required this.permissao,
    required this.precisaoExata,
    required this.movimento,
    required this.atualizacaoSegundoPlano,
    required this.modoPoucaEnergia,
    required this.rastreamentoAtivo,
    this.motivoInativo,
    this.atividade,
  });

  /// `sempre` | `durante_uso` | `negada` | `nao_determinada`.
  final String permissao;
  final bool precisaoExata;

  /// `permitido` | `negado` | `nao_determinado` | `indisponivel`.
  final String movimento;
  final bool atualizacaoSegundoPlano;
  final bool modoPoucaEnergia;
  final bool rastreamentoAtivo;
  final String? motivoInativo;
  final String? atividade;

  bool get sempre => permissao == 'sempre';

  factory EstadoRastreamento.doMapa(Map<dynamic, dynamic> m) => EstadoRastreamento(
        permissao: m['permissao'] as String? ?? 'nao_determinada',
        precisaoExata: m['precisaoExata'] as bool? ?? false,
        movimento: m['movimento'] as String? ?? 'nao_determinado',
        atualizacaoSegundoPlano: m['atualizacaoSegundoPlano'] as bool? ?? false,
        modoPoucaEnergia: m['modoPoucaEnergia'] as bool? ?? false,
        rastreamentoAtivo: m['rastreamentoAtivo'] as bool? ?? false,
        motivoInativo: m['motivoInativo'] as String?,
        atividade: m['atividade'] as String?,
      );
}

/// Quem pode ver a MINHA localização (permissão "aprovado" em que sou o alvo).
@immutable
class ContatoQueMeMonitora {
  const ContatoQueMeMonitora({required this.uid, required this.nome});
  final String uid;
  final String nome;
}

/// Liga/desliga o rastreamento contínuo NATIVO (`ios/Runner/RastreamentoContinuo.swift`)
/// da aba Monitoramento. Só iOS.
///
/// Fica ativo só com TUDO isto: sessão, ao menos uma permissão "aprovado"
/// em que eu sou o alvo, consentimento explícito em tela
/// (`ConsentimentoRastreamentoScreen`), compartilhamento não pausado e,
/// conferido também pelo nativo, permissão "Sempre" e Plano Free nos dias
/// ativos (ou Premium). O nativo guarda a configuração e segue sozinho
/// quando o iOS relança o app sem Flutter.
///
/// Para tudo (e limpa as cercas) ao sair da conta, excluir a conta, ter a
/// sessão revogada por login em outro aparelho ou perder o último
/// monitorador.
class RastreamentoContinuoService {
  RastreamentoContinuoService._internal();
  static final RastreamentoContinuoService _instance = RastreamentoContinuoService._internal();
  factory RastreamentoContinuoService() => _instance;

  static const MethodChannel _canal = MethodChannel('guardiaox/rastreamento');

  bool get suportado => Platform.isIOS;

  /// Quem vê minha localização agora (permissões "aprovado").
  final ValueNotifier<List<ContatoQueMeMonitora>> monitorandoMe =
      ValueNotifier<List<ContatoQueMeMonitora>>(const []);
  final ValueNotifier<bool> consentido = ValueNotifier<bool>(false);
  final ValueNotifier<bool> pausado = ValueNotifier<bool>(false);
  final ValueNotifier<EstadoRastreamento?> estado = ValueNotifier<EstadoRastreamento?>(null);

  /// Fim do bloqueio do Plano Free em vigor (`null` fora dele/Premium).
  DateTime? get fimBloqueioPlano => BloqueioSosPlano.vigente(_plano)?.fim;

  bool _iniciado = false;
  String? _uid;
  PlanoCicloStatus? _plano;
  StreamSubscription<PlanoCicloStatus?>? _assinaturaPlano;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assinaturaPermissoes;

  String _chaveConsentimento(String uid) => 'rastreamento_continuo_consentido_$uid';
  String _chavePausa(String uid) => 'rastreamento_continuo_pausado_$uid';

  /// Chamado uma vez por sessão do engine (ver `iniciarServicosPosLoginOuDashboard`).
  void iniciar() {
    if (!suportado || _iniciado || Firebase.apps.isEmpty) return;
    _iniciado = true;
    // Assinatura pela vida inteira do processo (singleton).
    FirebaseAuth.instance.authStateChanges().listen(_aoMudarSessao);
  }

  Future<void> _aoMudarSessao(User? usuario) async {
    await _assinaturaPlano?.cancel();
    await _assinaturaPermissoes?.cancel();
    _assinaturaPlano = null;
    _assinaturaPermissoes = null;
    _plano = null;
    monitorandoMe.value = const [];

    if (usuario == null) {
      // Saiu da conta, conta excluída ou sessão revogada (login em outro
      // aparelho): para e limpa as cercas.
      if (_uid != null) await pararAntesDeSair('sessao_encerrada');
      _uid = null;
      return;
    }
    _uid = usuario.uid;
    try {
      final prefs = await SharedPreferences.getInstance();
      consentido.value = prefs.getBool(_chaveConsentimento(usuario.uid)) ?? false;
      pausado.value = prefs.getBool(_chavePausa(usuario.uid)) ?? false;
    } catch (_) {}

    _assinaturaPlano = PlanoCicloService().statusStream().listen((status) {
      _plano = status;
      unawaited(_sincronizar());
    });
    _assinaturaPermissoes = FirebaseFirestore.instance
        .collection(MonitoramentoService.colecaoPermissoes)
        .where('uidAlvo', isEqualTo: usuario.uid)
        .where('status', isEqualTo: MonitoramentoService.statusAprovado)
        .snapshots()
        .listen((snap) async {
      monitorandoMe.value = await _resolverNomes(snap.docs);
      unawaited(_sincronizar());
    }, onError: (Object e) {
      debugPrint('⚠️ [Rastreamento] Falha ao ouvir quem me monitora: $e');
    });
    unawaited(_sincronizar());
  }

  Future<List<ContatoQueMeMonitora>> _resolverNomes(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    final lista = <ContatoQueMeMonitora>[];
    for (final doc in docs) {
      final dados = doc.data();
      if (dados['bloqueado'] == true) continue;
      final uid = dados['uidSolicitante'] as String?;
      if (uid == null) continue;
      String? nome;
      try {
        nome = (await DatabaseHelper().buscarContatoMonitoramentoPorUid(uid))?['nome'] as String?;
      } catch (_) {}
      nome ??= (dados['nomeSolicitante'] as String?)?.trim();
      if (nome == null || nome.isEmpty) nome = dados['telefoneSolicitante'] as String? ?? '—';
      lista.add(ContatoQueMeMonitora(uid: uid, nome: nome));
    }
    return lista;
  }

  /// Motivo para o Dart pedir "desligado" (`null` = pedir ligado).
  String? _motivoInativoDart() {
    if (monitorandoMe.value.isEmpty) return 'sem_monitores';
    if (!consentido.value) return 'sem_consentimento';
    if (pausado.value) return 'pausado';
    return null;
  }

  Future<void> _sincronizar() async {
    final uid = _uid;
    if (!suportado || uid == null) return;
    final motivo = _motivoInativoDart();
    try {
      final l10n = await L10nHeadlessService.obter();
      final resposta = await _canal.invokeMethod<Map<dynamic, dynamic>>('configurar', {
        'ativo': motivo == null,
        'motivoInativo': motivo,
        'uid': uid,
        'isPremium': _plano?.isPremium ?? false,
        'cicloInicioMs': _plano?.cycleStartDate.millisecondsSinceEpoch,
        'tituloEncerramento': l10n.marcaGuardiaoX,
        'textoEncerramento': l10n.rcEncerradoTexto,
      });
      if (resposta != null) estado.value = EstadoRastreamento.doMapa(resposta);
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao configurar o nativo: $e');
    }
  }

  Future<EstadoRastreamento?> atualizarEstado() async {
    if (!suportado) return null;
    try {
      final resposta = await _canal.invokeMethod<Map<dynamic, dynamic>>('estado');
      if (resposta != null) estado.value = EstadoRastreamento.doMapa(resposta);
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao ler o estado: $e');
    }
    return estado.value;
  }

  /// Consentimento explícito dado na tela (ver `ConsentimentoRastreamentoScreen`).
  Future<void> registrarConsentimento() async {
    final uid = _uid;
    if (uid == null) return;
    consentido.value = true;
    pausado.value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chaveConsentimento(uid), true);
      await prefs.setBool(_chavePausa(uid), false);
    } catch (_) {}
    await _sincronizar();
  }

  Future<void> definirPausa(bool pausar) async {
    final uid = _uid;
    if (uid == null) return;
    pausado.value = pausar;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_chavePausa(uid), pausar);
    } catch (_) {}
    await _sincronizar();
  }

  /// Para e limpa as cercas ANTES de a sessão acabar (para o estado
  /// "desligado" ainda chegar ao servidor). Sair da conta / excluir conta.
  Future<void> pararAntesDeSair(String motivo) async {
    if (!suportado) return;
    try {
      await _canal.invokeMethod<void>('parar', {'motivo': motivo})
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao parar o nativo: $e');
    }
  }

  /// Pede a permissão de Movimento (só na tela explicativa).
  Future<String> pedirPermissaoMovimento() async {
    if (!suportado) return 'indisponivel';
    try {
      return await _canal.invokeMethod<String>('pedirPermissaoMovimento') ?? 'indisponivel';
    } catch (_) {
      return 'indisponivel';
    }
  }

  /// Grava a posição no formato ÚNICO de documento (o mesmo do nativo) —
  /// usado por `FirebaseSyncService.atualizarLocalizacaoAtual` no iOS.
  Future<bool> gravarPosicao({
    required double latitude,
    required double longitude,
    double? precisao,
    required String origem,
  }) async {
    try {
      return await _canal.invokeMethod<bool>('gravarPosicao', {
            'latitude': latitude,
            'longitude': longitude,
            'precisao': precisao,
            'origem': origem,
          }) ??
          false;
    } catch (e) {
      debugPrint('⚠️ [Rastreamento] Falha ao gravar a posição pelo nativo: $e');
      return false;
    }
  }

  /// Últimos eventos de localização (mais recentes primeiro) — Diagnóstico.
  Future<List<Map<dynamic, dynamic>>> eventos() async {
    if (!suportado) return const [];
    try {
      final lista = await _canal.invokeMethod<List<dynamic>>('eventos');
      return (lista ?? const []).cast<Map<dynamic, dynamic>>();
    } catch (_) {
      return const [];
    }
  }
}
