import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/onboarding_service.dart';

/// Card de status de UMA permissão (ex: Notificações, Localização),
/// extraído do Assistente de Configuração Inicial (`OnboardingScreen`)
/// para ser reaproveitado, IDÊNTICO, também na tela "Status de
/// Permissões" acessível a qualquer momento em Configurações > Minha
/// Conta > Status de Permissões — mesmo widget, dois pontos de entrada
/// (onboarding + revisão avulsa posterior).
///
/// Widget propositalmente "burro": recebe o status já resolvido e
/// callbacks prontos — quem o usa (`OnboardingScreen`/
/// `PermissoesStatusScreen`) é responsável por checar/solicitar a
/// permissão de verdade via [OnboardingService].
class PermissaoStatusCard extends StatelessWidget {
  const PermissaoStatusCard({
    super.key,
    required this.icone,
    required this.titulo,
    required this.descricao,
    required this.essencial,
    required this.status,
    required this.aoConceder,
    this.aoAbrirConfiguracoes,
    this.textoStatusParcial,
    this.textoStatusConcedida,
    this.textoStatusPendente,
    this.corStatusPendente,
    this.textoBotaoConceder,
    this.aoTocarCard,
    this.aviso,
    this.textoBotaoAviso,
    this.aoTocarBotaoAviso,
  });

  final IconData icone;
  final String titulo;
  final String descricao;
  final bool essencial;
  final StatusPermissaoOnboarding status;
  final VoidCallback aoConceder;
  final VoidCallback? aoAbrirConfiguracoes;

  /// Texto exibido na tag de status quando [status] é
  /// [StatusPermissaoOnboarding.parcial], substituindo o genérico
  /// `l10n.onboardingStatusParcial` ("Parcial") por uma orientação mais
  /// específica de item — ex: para Localização, "Parcial (requer
  /// \"Permitir o tempo todo\")" (ver [PermissoesStatusScreen]/
  /// [OnboardingScreen]), deixando claro que falta só o grau "sempre",
  /// não a permissão básica. `null` usa o texto genérico.
  final String? textoStatusParcial;

  /// Substituem os textos/cor genéricos de status e o rótulo do botão —
  /// usados por itens que não são uma permissão do sistema (ex: o Widget
  /// SOS do iOS: "Ativo"/"Não adicionado", botão "Como adicionar").
  final String? textoStatusConcedida;
  final String? textoStatusPendente;
  final Color? corStatusPendente;
  final String? textoBotaoConceder;

  /// Toque em qualquer parte do card (além do botão).
  final VoidCallback? aoTocarCard;

  /// Quando informado, o card fica VERMELHO e mostra este aviso com o botão
  /// [textoBotaoAviso] — ex.: o botão SOS desativado nos dias bloqueados do
  /// Plano Free ("Assinar Premium").
  final String? aviso;
  final String? textoBotaoAviso;
  final VoidCallback? aoTocarBotaoAviso;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final concedida = status == StatusPermissaoOnboarding.concedida;
    final Color corStatus;
    final String textoStatus;
    switch (status) {
      case StatusPermissaoOnboarding.concedida:
        corStatus = Colors.green.shade600;
        textoStatus = textoStatusConcedida ?? l10n.onboardingStatusConcedida;
        break;
      case StatusPermissaoOnboarding.parcial:
        // CORREÇÃO DE BUG REAL (2026-09-05, pedido explícito do usuário —
        // testes reais mostraram o card de Localização marcado como
        // "Pendente", em cinza, mesmo com a permissão básica ("durante o
        // uso") já concedida e faltando só o grau "sempre"): este branch
        // reaproveitava por engano o MESMO texto do caso `pendente`
        // (embora já usasse a cor laranja correta) — visualmente
        // indistinguível de uma permissão totalmente negada.
        corStatus = Colors.orange.shade700;
        textoStatus = textoStatusParcial ?? l10n.onboardingStatusParcial;
        break;
      case StatusPermissaoOnboarding.pendente:
        corStatus = corStatusPendente ?? Colors.grey.shade600;
        textoStatus = textoStatusPendente ?? l10n.onboardingStatusPendente;
        break;
    }
    final corDestaque = essencial ? Colors.red.shade400 : Colors.blue.shade400;

    final card = Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: aviso != null ? Colors.red.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: aviso != null ? Colors.red.shade400 : Colors.grey.shade300,
          width: aviso != null ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: corDestaque.withValues(alpha: 0.12),
                child: Icon(icone, color: corDestaque),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      titulo,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                    _buildBadge(
                      essencial ? l10n.onboardingBadgeEssencial : l10n.onboardingBadgeRecomendado,
                      essencial,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            descricao,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.35),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                concedida ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 17,
                color: corStatus,
              ),
              const SizedBox(width: 6),
              Text(
                textoStatus,
                style: TextStyle(fontSize: 12.5, color: corStatus, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (!concedida && aviso == null)
                ElevatedButton(
                  onPressed: aoConceder,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                  child: Text(textoBotaoConceder ?? l10n.permissaoSmsPermitir),
                ),
            ],
          ),
          if (aviso != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade600,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    aviso!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  if (textoBotaoAviso != null && aoTocarBotaoAviso != null) ...[
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: aoTocarBotaoAviso,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.red.shade700,
                      ),
                      child: Text(textoBotaoAviso!),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (aoAbrirConfiguracoes != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: aoAbrirConfiguracoes,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  l10n.onboardingBotaoAbrirConfiguracoes,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    if (aoTocarCard == null) return card;
    return GestureDetector(
      onTap: aoTocarCard,
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }

  Widget _buildBadge(String texto, bool essencial) {
    final cor = essencial ? Colors.red.shade400 : Colors.blue.shade400;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        texto,
        style: TextStyle(fontSize: 10.5, color: cor, fontWeight: FontWeight.w700),
      ),
    );
  }
}
