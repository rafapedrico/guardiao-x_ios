import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Proteção de arquivo do iOS
/// (`NSFileProtectionCompleteUntilFirstUserAuthentication`) para os dados
/// sensíveis guardados pelo app — o banco SQLite (PIN e histórico de
/// alertas) e as cópias das fotos do SOS em Documents. Com essa classe, o
/// arquivo fica cifrado até o primeiro desbloqueio depois de ligar o
/// aparelho, e o app continua gravando com a tela bloqueada.
///
/// Canal "guardiaox/protecao_arquivo" (ver `ProtecaoArquivoPlugin` em
/// ios/Runner/AppDelegate.swift). Caminhos que ainda não existem são
/// ignorados pelo nativo. No Android não faz nada.
class ProtecaoArquivoService {
  ProtecaoArquivoService._internal();
  static final ProtecaoArquivoService _instance = ProtecaoArquivoService._internal();
  factory ProtecaoArquivoService() => _instance;

  static const MethodChannel _canal = MethodChannel('guardiaox/protecao_arquivo');

  Future<void> proteger(List<String> caminhos) async {
    if (!Platform.isIOS || caminhos.isEmpty) return;
    try {
      await _canal.invokeMethod<void>('proteger', {'caminhos': caminhos});
    } catch (e) {
      debugPrint('⚠️ [ProtecaoArquivoService] Falha ao aplicar a proteção de arquivo: $e');
    }
  }
}
