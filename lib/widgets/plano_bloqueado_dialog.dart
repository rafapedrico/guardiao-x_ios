import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/plano_ciclo_service.dart';
import 'premium_compra_aviso.dart';

const Color _corDestaquePremium = Color(0xFF9C6BFF);

/// Verifica, NA HORA (sempre uma leitura fresca, nunca cacheada — ver
/// [PlanoCicloService.podeUsarRecursosAvancados]), se o usuário pode usar
/// mensagens/alertas em tempo real ou localização em tempo real agora. Se
/// puder, retorna `true` imediatamente sem exibir nada — o chamador
/// prossegue normalmente. Se NÃO puder (Plano Free fora da janela de 10
/// dias ativos do mês), exibe o modal explicativo de upsell do Plano
/// Premium e retorna `false` — o chamador DEVE interromper o fluxo
/// (nenhum SMS/Push é disparado nem nenhuma localização é
/// solicitada/compartilhada, nem a câmera de Captura e Dissuasão é aberta
/// a partir daqui).
///
/// REGRA OFICIAL DO PLANO FREE (reespecificação do usuário, 2026-09-04):
/// dentro dos 10 dias ativos do mês (ou com Premium), TODOS os recursos
/// são liberados sem nenhum teto numérico adicional; fora deles, NENHUMA
/// mensagem é enviada — o usuário precisa esperar os 20 dias restantes
/// do ciclo ou assinar o Plano Premium. Esta é a ÚNICA trava do Plano
/// Free no app: existiu, por um curto período, um teto separado de 5
/// alertas/2 fotos por mês (`PlanoLimiteService`) que contradizia essa
/// regra (bloqueava mesmo DENTRO dos 10 dias ativos) — removido.
///
/// Usada tanto nos pontos onde o usuário toca em algo NA TELA (botão de
/// SOS manual, solicitar/compartilhar localização) quanto — reespecificação
/// do usuário, 2026-09-04 — no gatilho FÍSICO (ver
/// `main.dart::_dispararSequenciaUnificadaDeSos` para a ressalva de
/// segurança completa dessa decisão: um diálogo aqui pode expor o
/// disfarce do app a quem estiver olhando a tela naquele instante, já
/// que o gatilho físico pode disparar com o aparelho bloqueado/escondido).
/// Fluxos automáticos/headless que genuinamente não têm nenhum
/// `BuildContext` disponível (alarme de rotina disparando com o app
/// fechado) continuam bloqueados diretamente dentro de
/// [EmergencyAlertService]/[FirebaseSyncService]/[MonitoramentoService],
/// sem exibir este modal.
Future<bool> garantirRecursoLiberadoOuExibirUpsell(BuildContext context) async {
  final bool liberado = await PlanoCicloService().podeUsarRecursosAvancados();
  debugPrint('💎 [PlanoBloqueadoDialog] garantirRecursoLiberadoOuExibirUpsell() -> liberado=$liberado');
  if (liberado) return true;
  if (!context.mounted) return false;
  await _exibirModalPlanoBloqueado(context);
  return false;
}

Future<void> _exibirModalPlanoBloqueado(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  // Reaproveita a MESMA leitura fresca acima (não uma nova consulta) só
  // para extrair a data de renovação a exibir — best-effort: sem ela,
  // mostra o modal com um placeholder neutro em vez de travar o fluxo.
  final status = await PlanoCicloService().obterStatusAtualizado();
  final String dataFormatada = status != null
      ? _formatarData(status.dataRenovacao)
      : '—';
  final int diasRestantes = status?.diasParaRenovacao ?? 0;

  if (!context.mounted) {
    debugPrint(
        '⚠️ [PlanoBloqueadoDialog] Plano Free bloqueado, mas o contexto já não '
        'está mais montado — aviso NÃO exibido.');
    return;
  }
  debugPrint('💎 [PlanoBloqueadoDialog] Exibindo aviso de plano bloqueado...');
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.lock_clock, color: _corDestaquePremium, size: 32),
      title: Text(l10n.planoBloqueadoModalTitulo),
      content: Text(l10n.planoBloqueadoModalConteudo(diasRestantes, dataFormatada)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.agoraNao),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _corDestaquePremium),
          onPressed: () {
            debugPrint('💎 [PlanoBloqueadoDialog] Usuário tocou em "Assinar" no aviso de plano bloqueado.');
            Navigator.of(ctx).pop();
            // Compra REAL via Google Play Billing (ver
            // PremiumPurchaseService) — não mais um deep-link pra página
            // da loja. O resultado chega de forma assíncrona pelo
            // purchaseStream global (ver o SnackBar em
            // main.dart::_SecurityCheckAppState). Se a tela de pagamento
            // não abrir (loja/produto indisponível), mostra um aviso.
            iniciarCompraPremiumComAviso(context);
          },
          child: Text(l10n.planoBloqueadoModalBotaoAssinar),
        ),
      ],
    ),
  );
  debugPrint('💎 [PlanoBloqueadoDialog] Aviso de plano bloqueado fechado.');
}

String _formatarData(DateTime data) {
  final dia = data.day.toString().padLeft(2, '0');
  final mes = data.month.toString().padLeft(2, '0');
  return '$dia/$mes/${data.year}';
}
