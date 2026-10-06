import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_navigator.dart';
import '../screens/camera_captura_screen.dart';
import 'plano_ciclo_service.dart';

/// Orquestra a abertura do recurso de Captura e Dissuasão
/// ([CameraCapturaScreen]) a partir de qualquer ponto de disparo de
/// emergência da UI.
class CapturaDissuasaoService {
  CapturaDissuasaoService._internal();
  static final CapturaDissuasaoService _instance =
      CapturaDissuasaoService._internal();
  factory CapturaDissuasaoService() => _instance;

  /// [origemUnificada], quando informado, identifica a sequência
  /// unificada de SOS (ver [SosDisparoService]/[CameraCapturaScreen]) —
  /// repassado direto para a tela, sem alterar a checagem de plano nem o
  /// retry-loop de navegação abaixo.
  ///
  /// Retorna `true` só quando a [CameraCapturaScreen] foi de fato
  /// empurrada para a navegação — `false` em qualquer caminho que NÃO
  /// abre a câmera (fora da janela de 10 dias ativos do Plano Free,
  /// `NavigatorState` indisponível). Usado por
  /// `main.dart::_dispararSequenciaUnificadaDeSos` para decidir se a
  /// tela preta do cold-start via botão físico ([_TelaPretaAguardandoSos])
  /// precisa de um fallback de saída — ver documentação completa lá.
  ///
  /// [planoJaVerificado]: o chamador já leu a janela do Plano Free (Widget
  /// SOS, que compartilha uma única leitura com o envio da localização).
  /// [aoResolverAbertura]/[limiteAbertura]: repassados à
  /// [CameraCapturaScreen] (tela preta do Widget SOS). [alertaId]: o SOS
  /// a que a foto pertence (mesma entrada do Histórico).
  Future<bool> abrirCapturaSePermitido({
    String? origemUnificada,
    String? alertaId,
    bool planoJaVerificado = false,
    ValueChanged<bool>? aoResolverAbertura,
    Duration? limiteAbertura,
  }) async {
    try {
      // 1. Verifica se o Plano Free está dentro da janela de 10 dias
      // ativos (ou se é Premium) — ver PlanoCicloService. REESPECIFICAÇÃO
      // DO USUÁRIO (2026-09-04): antes a foto era gated por um teto
      // separado de 2/mês (PlanoLimiteService, removido), que contradizia
      // a regra oficial "todos os recursos liberados dentro dos 10 dias
      // ativos" — agora usa a MESMA trava única de SMS/Push (ver
      // `EmergencyAlertService._enviarSms`/`FirebaseSyncService`), sem
      // nenhum teto numérico adicional.
      final bool permitido =
          planoJaVerificado || await PlanoCicloService().podeUsarRecursosAvancados();
      debugPrint('📷 [CapturaDissuasaoService] podeUsarRecursosAvancados() retornou: $permitido');
      if (!permitido) {
        debugPrint(
            '📷 [CapturaDissuasaoService] Plano Free fora da janela de 10 dias ativos do mês — captura não será aberta.');
        return false;
      }

      // 2. Apenas verifica o status da permissão de CÂMERA, sem solicitar.
      // A solicitação real (Permission.camera.request()) acontece uma
      // única vez, dentro de CameraCapturaScreen._inicializarCamera().
      // Chamar request() também aqui causava uma corrida entre as duas
      // telas — o permission_handler não permite duas solicitações
      // simultâneas e uma delas falhava com PlatformException
      // ("A request for permissions is already running"), deixando a
      // permissão presa em "denied".
      try {
        final status = await Permission.camera.status;
        debugPrint('📷 [CapturaDissuasaoService] Status atual da permissão de câmera: $status');
      } catch (e) {
        debugPrint('⚠️ [CapturaDissuasaoService] Falha ao verificar permissão de câmera: $e');
      }

      // 3. RETRY LOOP: Aguarda até 3s usando appNavigatorKey
      NavigatorState? navigatorState = appNavigatorKey.currentState;
      int tentativas = 0;
      while (navigatorState == null && tentativas < 10) {
        debugPrint(
            '⏳ [CapturaDissuasaoService] NavigatorState ainda nulo. Aguardando montagem da UI (tentativa ${tentativas + 1}/10)...');
        await Future.delayed(const Duration(milliseconds: 300));
        navigatorState = appNavigatorKey.currentState;
        tentativas++;
      }

      if (navigatorState == null) {
        debugPrint(
            '⚠️ [CapturaDissuasaoService] NavigatorState indisponível após aguardar — captura não pôde ser aberta.');
        return false;
      }

      // 4. Navega para a CameraCapturaScreen
      debugPrint('📷 [CapturaDissuasaoService] Navegando para CameraCapturaScreen...');
      navigatorState.push(
        MaterialPageRoute(
          builder: (_) => CameraCapturaScreen(
            origemUnificada: origemUnificada,
            alertaId: alertaId,
            aoResolverAbertura: aoResolverAbertura,
            limiteAbertura: limiteAbertura,
          ),
          fullscreenDialog: true,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('⚠️ [CapturaDissuasaoService] Falha ao tentar abrir a tela de captura: $e');
      return false;
    }
  }
}