import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Centraliza a solicitação PROATIVA das permissões de runtime exigidas
/// pelo canal de SMS de emergência (`SEND_SMS`) e pela resolução
/// correta do chip ativo em aparelhos dual-SIM (`READ_PHONE_STATE`, ver
/// `SmsSender.kt`/`SubscriptionManager`) — o canal 1, "sempre funciona,
/// nunca depende de nuvem", do botão de pânico (ver `SosDisparoService`).
///
/// BUG REAL ENCONTRADO EM CAMPO: diferente de câmera/localização/
/// contatos (cada uma já pedida em algum ponto de uso específico do
/// app), `SEND_SMS` não tinha NENHUM ponto de solicitação em runtime em
/// todo o app — ficava `denied` permanentemente em qualquer instalação
/// onde o usuário não abrisse manualmente os Ajustes do Android, fazendo
/// o SMS de emergência falhar silenciosamente em TODO disparo de pânico
/// (`PlatformException(SMS_ERROR, ...)`, nunca exposto na UI). Dois
/// pontos de solicitação PROATIVA cobrem isso agora:
/// 1. [verificarNoOnboarding] — uma vez por instalação, na primeira
///    entrada na Home (ver `HomeScreen.initState`).
/// 2. [verificarAoAdicionarPrimeiroContato] — ao cadastrar o PRIMEIRO
///    contato de emergência (ver `ConfiguracoesTab`), reforçando a
///    explicação no momento em que ela é mais contextual para o usuário
///    — inclusive cobrindo quem negou no onboarding mas pode
///    reconsiderar ao ver o motivo de novo (o Android só bloqueia
///    definitivamente o diálogo nativo após a SEGUNDA negativa).
class SmsPermissionService {
  SmsPermissionService._internal();
  static final SmsPermissionService _instance = SmsPermissionService._internal();
  factory SmsPermissionService() => _instance;

  static const String _chaveJaPerguntadoOnboarding =
      'sms_permissao_perguntada_onboarding';

  /// `true` quando SEND_SMS já está concedida — `READ_PHONE_STATE`
  /// (usada só para resolver o chip ativo em aparelhos dual-SIM) é
  /// tratada como um bônus best-effort, nunca bloqueante: sem ela, o SMS
  /// ainda é enviado normalmente via `SmsManager` "padrão" (ver
  /// `SmsSender.kt`), só perde a resolução explícita de chip.
  Future<bool> estaConcedida() async {
    final sms = await Permission.sms.status;
    return sms.isGranted;
  }

  /// Chamado uma única vez por instalação (flag em SharedPreferences),
  /// logo na primeira entrada na Home — explica o motivo ANTES do
  /// diálogo nativo do Android e solicita as duas permissões.
  Future<void> verificarNoOnboarding(BuildContext context) async {
    // MIGRAÇÃO iOS (achado durante a auditoria pós-Fase 4, 2026-09-12):
    // sem esta guarda, TODO usuário iOS veria, na primeira entrada na
    // Home, um diálogo pedindo pra "ativar o SMS de emergência" — uma
    // permissão que a Apple nem expõe e que o produto decidiu desativar
    // por completo no iOS (ver nota de migração em
    // `emergency_alert_service.dart`, Fase 2). Contradiz diretamente
    // essa decisão se não for bloqueado aqui. Comportamento Android
    // 100% inalterado.
    if (Platform.isIOS) return;
    if (await estaConcedida()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_chaveJaPerguntadoOnboarding) == true) return;
      await prefs.setBool(_chaveJaPerguntadoOnboarding, true);
    } catch (e) {
      debugPrint('⚠️ [SmsPermissionService] Falha ao ler/gravar flag de onboarding: $e');
    }

    if (!context.mounted) return;
    await _explicarESolicitar(context);
  }

  /// Chamado ao adicionar o PRIMEIRO contato de emergência (ver
  /// `ConfiguracoesTab._adicionarContatoDaAgenda`) — reforça a
  /// solicitação no momento em que ela é mais contextual para o
  /// usuário, independente de [verificarNoOnboarding] já ter perguntado
  /// antes. NUNCA bloqueia o cadastro do contato: só informa/pergunta.
  Future<void> verificarAoAdicionarPrimeiroContato(BuildContext context) async {
    // Ver nota de migração em [verificarNoOnboarding] — mesmo motivo.
    if (Platform.isIOS) return;
    if (await estaConcedida()) return;
    if (!context.mounted) return;
    await _explicarESolicitar(context);
  }

  /// Mostra a explicação (ANTES do diálogo nativo do Android, boa
  /// prática recomendada — dá contexto sobre por que a permissão é
  /// necessária antes do usuário ver o prompt do sistema) e, se aceito,
  /// solicita SEND_SMS + READ_PHONE_STATE. "Agora não" ou fechar o
  /// diálogo simplesmente não solicita nada — nunca força o prompt
  /// nativo sobre um usuário que ainda nem entendeu o motivo.
  Future<void> _explicarESolicitar(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final bool? prosseguir = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.permissaoSmsTitulo),
        content: Text(l10n.permissaoSmsConteudo),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.permissaoSmsAgoraNao),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.permissaoSmsPermitir),
          ),
        ],
      ),
    );

    if (prosseguir != true) return;

    try {
      await Permission.sms.request();
      // READ_PHONE_STATE (grupo "phone" no permission_handler) — só
      // usada para resolver o chip ativo em aparelhos dual-SIM (ver
      // SmsSender.kt); best-effort, nunca bloqueia o fluxo se negada.
      await Permission.phone.request();
    } catch (e) {
      debugPrint('⚠️ [SmsPermissionService] Falha ao solicitar permissões de SMS/telefone: $e');
    }
  }
}
