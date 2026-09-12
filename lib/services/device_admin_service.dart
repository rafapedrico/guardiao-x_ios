import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Wrapper Dart em torno do plugin nativo local `DeviceAdminPlugin`
/// (Kotlin) — expõe o fluxo de Administrador do Dispositivo (Device
/// Admin), única forma que o Android permite bloquear a tela sob demanda
/// (`DevicePolicyManager.lockNow()`) sem privilégios de root/Device
/// Owner.
///
/// USADO POR:
/// - Tela de consentimento em Configurações/Segurança ([estaAtivo] +
///   [solicitarAtivacao]) — a ativação é sempre um passo EXPLÍCITO e
///   ANTECIPADO do usuário, nunca solicitada durante o próprio SOS.
/// - `CameraCapturaScreen` (P4 da sequência unificada de SOS, ver
///   `SosDisparoService`) — [bloquearTelaAgora], acionado ao deslizar a
///   tela vermelha de alerta para cima. Se a permissão não tiver sido
///   concedida, [bloquearTelaAgora] retorna `false` e o chamador cai no
///   fallback histórico (`SystemNavigator.pop()`).
class DeviceAdminService {
  DeviceAdminService._internal();
  static final DeviceAdminService _instance = DeviceAdminService._internal();
  factory DeviceAdminService() => _instance;

  static const MethodChannel _canal =
      MethodChannel('com.example.security_check_app/device_admin');

  /// `true` se o Guardião X já é um administrador do dispositivo ativo
  /// (permissão concedida em uma sessão anterior). `false` em caso de
  /// erro/plataforma não suportada (nunca lança exceção).
  ///
  /// MIGRAÇÃO iOS (achado durante a auditoria pós-Fase 4, 2026-09-12):
  /// Device Admin não existe no iOS — sem esta guarda, o cartão
  /// permanente em `ConfiguracoesTab._buildCartaoDeviceAdmin` ficaria
  /// visível PARA SEMPRE, com um botão "Ativar" ([solicitarAtivacao])
  /// que silenciosamente não faz nada. Retornar `true` (já "ativo", por
  /// não haver nada do que ativar) esconde o cartão — mesmo padrão já
  /// usado por `BatteryOptimizationService.estaIsento`. Único ponto de
  /// bifurcação deste arquivo — [bloquearTelaAgora] já não tinha handler
  /// nativo no iOS e já retornava `false` com segurança (usado pelo
  /// fallback do P4, ver `CameraCapturaScreen`).
  Future<bool> estaAtivo() async {
    if (Platform.isIOS) return true;
    try {
      final ativo = await _canal.invokeMethod<bool>('estaAtivo');
      return ativo ?? false;
    } catch (e) {
      debugPrint('⚠️ [DeviceAdminService] Falha ao consultar estaAtivo: $e');
      return false;
    }
  }

  /// Abre o diálogo NATIVO do Android pedindo a permissão de
  /// Administrador do Dispositivo, com uma explicação clara do motivo.
  /// O resultado real só é conhecido depois — chame [estaAtivo] de novo
  /// quando a tela voltar ao primeiro plano (ex: `didChangeAppLifecycleState`)
  /// para refletir a decisão do usuário na UI.
  Future<void> solicitarAtivacao() async {
    try {
      await _canal.invokeMethod('solicitarAtivacao');
    } catch (e) {
      debugPrint('⚠️ [DeviceAdminService] Falha ao solicitar ativação: $e');
    }
  }

  /// Bloqueia a tela imediatamente (`DevicePolicyManager.lockNow()`).
  /// Retorna `false` (sem lançar exceção) se a permissão não estiver
  /// ativa ou qualquer outra falha nativa ocorrer — o chamador deve
  /// tratar isso como "bloqueio nativo indisponível" e decidir um
  /// fallback.
  Future<bool> bloquearTelaAgora() async {
    try {
      final sucesso = await _canal.invokeMethod<bool>('bloquearTelaAgora');
      return sucesso ?? false;
    } catch (e) {
      debugPrint('⚠️ [DeviceAdminService] Falha ao bloquear a tela: $e');
      return false;
    }
  }
}
