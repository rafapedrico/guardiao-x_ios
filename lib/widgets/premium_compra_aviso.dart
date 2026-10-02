import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/premium_purchase_service.dart';

/// Ação de TODOS os botões "Assinar Plano Premium" (card da tela inicial e
/// aviso de plano bloqueado em `plano_bloqueado_dialog.dart`): dispara a
/// compra e, se a tela de pagamento da loja não abrir, explica o motivo —
/// antes o botão simplesmente não
/// fazia nada (1º teste no iPhone: produto `assinatura_mensal` ainda não
/// disponível na App Store).
///
/// Nunca abre link externo para a loja: a Apple rejeita pagamento de
/// assinatura fora do In-App Purchase.
Future<void> iniciarCompraPremiumComAviso(BuildContext context) async {
  final resultado = await PremiumPurchaseService().comprarPremium();
  if (resultado == PremiumCompraInicio.iniciada || !context.mounted) return;

  final l10n = AppLocalizations.of(context)!;
  final String mensagem = switch (resultado) {
    PremiumCompraInicio.semSessao => l10n.premiumCompraSemSessao,
    PremiumCompraInicio.lojaIndisponivel => l10n.premiumCompraLojaIndisponivel,
    PremiumCompraInicio.produtoNaoEncontrado => l10n.premiumCompraProdutoIndisponivel,
    _ => l10n.premiumCompraFalhaIniciar,
  };

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.storefront_outlined, size: 32),
      title: Text(l10n.premiumCompraIndisponivelTitulo),
      content: Text(mensagem),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(l10n.premiumCompraAvisoOk),
        ),
      ],
    ),
  );
}
