import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/sos_widget_tutorial_screen.dart';

/// Status do Widget SOS do iOS ("Botão de Pânico" na tela de início/tela
/// bloqueada, ver ios/SOSWidget/). Só existe no iOS — no Android o gatilho
/// físico de SOS é o botão de volume.
///
/// O status é REAL: vem do `WidgetCenter.getCurrentConfigurations` via o
/// canal nativo "guardiaox/sos_widget" (ios/Runner/AppDelegate.swift).
/// O iOS não permite abrir a galeria de widgets nem a tela de início por
/// código — por isso o app só mostra o passo a passo
/// ([SosWidgetTutorialScreen]).
class SosWidgetStatusService {
  SosWidgetStatusService._();

  static const MethodChannel _canal = MethodChannel('guardiaox/sos_widget');
  static const String _chaveTutorialExibido = 'sos_widget_tutorial_exibido';

  /// `true`/`false` = widget instalado ou não; `null` = indisponível
  /// (fora do iOS, ou o WidgetCenter não respondeu).
  static Future<bool?> widgetInstalado() async {
    if (!Platform.isIOS) return null;
    try {
      return await _canal.invokeMethod<bool>('widgetInstalado');
    } catch (e) {
      debugPrint('⚠️ [SosWidgetStatusService] Falha ao consultar o WidgetCenter: $e');
      return null;
    }
  }

  static Future<void> abrirTutorial(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SosWidgetTutorialScreen()),
    );
  }

  /// Mostra o passo a passo UMA única vez, na primeira entrada na Home
  /// depois do login, e só se o widget ainda não estiver instalado.
  static Future<void> exibirTutorialNoPrimeiroLoginSeNecessario(BuildContext context) async {
    if (!Platform.isIOS) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_chaveTutorialExibido) ?? false) return;

      final instalado = await widgetInstalado();
      if (instalado == null) return; // Sem resposta agora — tenta no próximo login.
      await prefs.setBool(_chaveTutorialExibido, true);
      if (instalado || !context.mounted) return;
      await abrirTutorial(context);
    } catch (e) {
      debugPrint('⚠️ [SosWidgetStatusService] Falha ao exibir o passo a passo do widget: $e');
    }
  }
}
