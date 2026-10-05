import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Resposta de `registrarIndicacao` (campo `motivo`), mais [erro] para
/// falha de rede/servidor — que não é um motivo do contrato.
enum ResultadoIndicacao { ok, codigoInvalido, autoindicacao, jaVinculado, jaPremium, erro }

/// Programa de Indicação, lado do app (contrato no README do servidor,
/// ramo `feat/programa-indicacao`, seção "Programa de Indicação").
///
/// - [registrar]: callable `registrarIndicacao({codigo, origem: "digitado"})`.
/// - [podeInformarCodigo]: o campo só aparece enquanto o usuário não for
///   Premium nem tiver vínculo (`usuarios/{uid}.isPremium` /
///   `indicadoPor` — só as functions gravam esses campos).
/// - [codigoDoLink]: código vindo do Universal Link
///   https://meuguardiaox.com.br/i/{CODIGO} (capturado no
///   `SceneDelegate.swift`), para pré-preencher o campo. A área de
///   transferência nunca é lida.
///
/// Nada aqui mostra valor ou recompensa: a comissão é só do afiliado, fora
/// do app (diretrizes da App Store).
class IndicacaoService {
  IndicacaoService._internal();
  static final IndicacaoService _instance = IndicacaoService._internal();
  factory IndicacaoService() => _instance;

  static const MethodChannel _canal = MethodChannel('guardiaox/indicacao_link');

  /// Alfabeto dos códigos (sem O/0, I/1, L), 6 caracteres.
  static final RegExp _formatoCodigo = RegExp(r'^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$');

  /// Último código recebido por link e ainda não usado.
  final ValueNotifier<String?> codigoDoLink = ValueNotifier<String?>(null);

  bool _iniciado = false;

  /// Liga o canal nativo e consome o link que abriu o app (se houver).
  void iniciar() {
    if (_iniciado || !Platform.isIOS) return;
    _iniciado = true;
    _canal.setMethodCallHandler((chamada) async {
      if (chamada.method == 'codigoRecebido') await _consumirDoNativo();
    });
    unawaited(_consumirDoNativo());
  }

  Future<void> _consumirDoNativo() async {
    try {
      final bruto = await _canal.invokeMethod<String>('consumirCodigo');
      final codigo = normalizar(bruto);
      if (codigo != null) codigoDoLink.value = codigo;
    } catch (e) {
      debugPrint('⚠️ [IndicacaoService] Falha ao ler o link de indicação: $e');
    }
  }

  /// Maiúsculas, sem espaços nem hífen; `null` fora do formato do código.
  static String? normalizar(String? bruto) {
    if (bruto == null) return null;
    final codigo = bruto.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return _formatoCodigo.hasMatch(codigo) ? codigo : null;
  }

  /// O código do link já foi aplicado (ou recusado em definitivo): não
  /// pré-preenche mais nada.
  void descartarCodigoDoLink() => codigoDoLink.value = null;

  /// `true` enquanto o usuário logado não é Premium e não tem
  /// `indicadoPor`. Sem sessão/Firebase, `false` (o campo não aparece).
  Stream<bool> podeInformarCodigo() {
    if (Firebase.apps.isEmpty) return Stream.value(false);
    // Segue a conta logada (troca de conta sem recriar a tela): a cada
    // mudança, troca a escuta do perfil.
    StreamSubscription<User?>? assinaturaAuth;
    StreamSubscription<bool>? assinaturaPerfil;
    late final StreamController<bool> saida;
    saida = StreamController<bool>(
      onListen: () {
        assinaturaAuth = FirebaseAuth.instance.authStateChanges().listen((usuario) {
          unawaited(assinaturaPerfil?.cancel());
          assinaturaPerfil = null;
          if (usuario == null) {
            saida.add(false);
            return;
          }
          assinaturaPerfil = _podeInformarCodigoDe(usuario.uid).listen(saida.add);
        });
      },
      onCancel: () async {
        await assinaturaPerfil?.cancel();
        await assinaturaAuth?.cancel();
      },
    );
    return saida.stream;
  }

  Stream<bool> _podeInformarCodigoDe(String uid) {
    return FirebaseFirestore.instance
        .collection('usuarios')
        .doc(uid)
        .snapshots()
        .map((snap) {
          final dados = snap.data();
          final premium = dados?['isPremium'] == true;
          final indicadoPor = dados?['indicadoPor'];
          final vinculado = indicadoPor is String && indicadoPor.isNotEmpty;
          return !premium && !vinculado;
        })
        .handleError((Object e) {
          debugPrint('⚠️ [IndicacaoService] Falha ao ler o perfil: $e');
        });
  }

  /// Vincula a conta logada ao [codigo]. A recusa vem no `motivo` (não é
  /// erro); [ResultadoIndicacao.erro] é só falha de rede/servidor.
  Future<ResultadoIndicacao> registrar(String codigo) async {
    if (Firebase.apps.isEmpty || FirebaseAuth.instance.currentUser == null) {
      return ResultadoIndicacao.erro;
    }
    try {
      final resposta = await FirebaseFunctions.instance
          .httpsCallable('registrarIndicacao')
          .call<Map<String, dynamic>>({'codigo': codigo.trim(), 'origem': 'digitado'})
          .timeout(const Duration(seconds: 20));
      final resultado = resultadoDoMotivo(resposta.data['motivo'] as String?);
      if (resultado != ResultadoIndicacao.erro && resultado != ResultadoIndicacao.codigoInvalido) {
        // Vinculado, ou nunca mais vinculável (já vinculado/Premium/próprio
        // código): o link não precisa pré-preencher de novo.
        descartarCodigoDoLink();
      }
      return resultado;
    } catch (e) {
      debugPrint('⚠️ [IndicacaoService] Falha em registrarIndicacao: $e');
      return ResultadoIndicacao.erro;
    }
  }

  @visibleForTesting
  static ResultadoIndicacao resultadoDoMotivo(String? motivo) => switch (motivo) {
        'ok' => ResultadoIndicacao.ok,
        'codigo_invalido' => ResultadoIndicacao.codigoInvalido,
        'autoindicacao' => ResultadoIndicacao.autoindicacao,
        'ja_vinculado' => ResultadoIndicacao.jaVinculado,
        'ja_premium' => ResultadoIndicacao.jaPremium,
        _ => ResultadoIndicacao.erro,
      };
}
