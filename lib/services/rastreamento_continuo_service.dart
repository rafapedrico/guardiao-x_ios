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

  /// Registro do lado Dart (Diagnóstico → Localização): por que a seção do
  /// Monitoramento está oculta ou o rastreamento desligado.
  final List<String> registro = <String>[];
  String? _erroConsulta;
  int _aprovadosNoServidor = 0;

  void _registrar(String texto) {
    final agora = DateTime.now();
    String dois(int n) => n.toString().padLeft(2, '0');
    registro.insert(0, '${dois(agora.hour)}:${dois(agora.minute)}:${dois(agora.second)} $texto');
    if (registro.length > 60) registro.removeLast();
    debugPrint('📍 [Rastreamento] $texto');
  }

  /// Resumo do porquê (Diagnóstico → Localização).
  List<String> resumoDiagnostico() {
    final e = estado.value;
    return [
      'serviço iniciado: $_iniciado · Firebase: ${Firebase.apps.isNotEmpty} · sessão: ${_uid ?? "nenhuma"}',
      'permissões "aprovado" em que sou o alvo: $_aprovadosNoServidor '
          '(${monitorandoMe.value.map((c) => c.nome).join(", ")})'
          '${_erroConsulta != null ? " · ERRO na consulta: $_erroConsulta" : ""}',
      'seção no Monitoramento: ${monitorandoMe.value.isEmpty ? "OCULTA (ninguém aprovado)" : "visível"}',
      'plano: ${_plano == null ? "não lido" : "isPremium=${_plano!.isPremium}, ativo=${_plano!.ativo}, dia ${_plano!.diaAtualCiclo}"}',
      'consentimento: ${consentido.value} · pausado: ${pausado.value} · motivo (app): ${_motivoInativoDart() ?? "nenhum — pede ligado"}',
      'nativo: ${e == null ? "sem resposta" : "ativo=${e.rastreamentoAtivo}, motivo=${e.motivoInativo ?? "—"}, permissão=${e.permissao}"}',
    ];
  }
  PlanoCicloStatus? _plano;
  StreamSubscription<PlanoCicloStatus?>? _assinaturaPlano;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assinaturaPermissoes;

  String _chaveConsentimento(String uid) => 'rastreamento_continuo_consentido_$uid';
  String _chavePausa(String uid) => 'rastreamento_continuo_pausado_$uid';

  /// Chamado uma vez por sessão do engine (ver `iniciarServicosPosLoginOuDashboard`).
  /// Idempotente; chamado depois do Firebase/sessão (ver `main.dart`) e de
  /// novo pela Home — sem Firebase ainda, tenta de novo na próxima chamada.
  void iniciar() {
    if (!suportado || _iniciado) return;
    if (Firebase.apps.isEmpty) {
      _registrar('iniciar adiado: Firebase ainda não inicializado');
      return;
    }
    _iniciado = true;
    _registrar('serviço iniciado');
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
      _registrar('sem sessão — rastreamento parado');
      return;
    }
    _uid = usuario.uid;
    _registrar('sessão ${usuario.uid}');
    // Contrato comum aos dois apps: `usuarios/{uid}.plataforma` ("ios" ou
    // "android"; ausente = Android antigo).
    unawaited(FirebaseFirestore.instance
        .collection('usuarios')
        .doc(usuario.uid)
        .set({'plataforma': 'ios'}, SetOptions(merge: true))
        .catchError((Object e) => _registrar('falha ao gravar plataforma: $e')));
    try {
      final prefs = await SharedPreferences.getInstance();
      consentido.value = prefs.getBool(_chaveConsentimento(usuario.uid)) ?? false;
      pausado.value = prefs.getBool(_chavePausa(usuario.uid)) ?? false;
    } catch (_) {}

    _assinaturaPlano = PlanoCicloService().statusStream().listen((status) {
      _plano = status;
      _registrar('plano: isPremium=${status?.isPremium}, ativo=${status?.ativo}');
      unawaited(_sincronizar());
    });
    _assinaturaPermissoes = FirebaseFirestore.instance
        .collection(MonitoramentoService.colecaoPermissoes)
        .where('uidAlvo', isEqualTo: usuario.uid)
        .where('status', isEqualTo: MonitoramentoService.statusAprovado)
        .snapshots()
        .listen((snap) async {
      _erroConsulta = null;
      _aprovadosNoServidor = snap.docs.length;
      monitorandoMe.value = await _resolverNomes(snap.docs);
      _registrar('permissões aprovadas (sou o alvo): ${snap.docs.map((d) => d.id).join(", ")}'
          '${snap.docs.isEmpty ? "nenhuma" : ""}; válidas: ${monitorandoMe.value.length}');
      unawaited(_sincronizar());
    }, onError: (Object e) {
      _erroConsulta = '$e';
      _registrar('ERRO ao consultar quem me monitora: $e');
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

  /// Por que o rastreamento está desligado (`null` = nada a explicar):
  /// primeiro o motivo do app (quem me monitora, consentimento, pausa),
  /// depois o do nativo (permissão "Sempre", Plano Free, sessão).
  String? get motivoInativo => _motivoInativoDart() ?? estado.value?.motivoInativo;

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
        'temMonitorAprovado': monitorandoMe.value.isNotEmpty,
      });
      if (resposta != null) estado.value = EstadoRastreamento.doMapa(resposta);
      _registrar('configurar: pede ${motivo == null ? "LIGADO" : "desligado ($motivo)"} → nativo '
          'ativo=${estado.value?.rastreamentoAtivo}, motivo=${estado.value?.motivoInativo ?? "—"}');
    } catch (e) {
      _registrar('ERRO ao configurar o nativo: $e');
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
