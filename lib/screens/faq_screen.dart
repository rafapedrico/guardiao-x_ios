import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

/// Tela dedicada de Perguntas Frequentes (FAQ), acessada a partir do
/// botão "Perguntas Frequentes (FAQ)" na Tela de Início (Dashboard) — ver
/// [InicioDashboard]. Fundo 100% preto AMOLED, com campo de busca que
/// filtra as perguntas/respostas em tempo real e uma lista de
/// [ExpansionTile] estilizados no mesmo padrão visual escuro do restante
/// do app.
///
/// Todo o conteúdo (título, dica de busca, perguntas e respostas) vem de
/// [AppLocalizations] — nenhum texto fica preso em português, exibindo
/// sempre o idioma selecionado pelo usuário.
class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  final TextEditingController _buscaController = TextEditingController();
  String _termoBusca = '';

  @override
  void dispose() {
    _buscaController.dispose();
    super.dispose();
  }

  List<_FaqItem> _itensFiltrados(List<_FaqItem> todasAsPerguntas) {
    if (_termoBusca.trim().isEmpty) return todasAsPerguntas;
    final termo = _termoBusca.trim().toLowerCase();
    return todasAsPerguntas
        .where((item) =>
            item.pergunta.toLowerCase().contains(termo) ||
            item.resposta.toLowerCase().contains(termo))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final itens = _itensFiltrados(_todasAsPerguntas(l10n));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.home_outlined),
          tooltip: l10n.faqTooltipInicio,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.faqAppBarTitulo),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _buscaController,
              onChanged: (valor) => setState(() => _termoBusca = valor),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: l10n.faqBuscaHint,
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white38),
                suffixIcon: _termoBusca.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white38),
                        onPressed: () {
                          _buscaController.clear();
                          setState(() => _termoBusca = '');
                        },
                      ),
                filled: true,
                fillColor: const Color(0xFF1A1B26),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          Expanded(
            child: itens.isEmpty
                ? Center(
                    child: Text(
                      l10n.faqNenhumaEncontrada,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                    itemCount: itens.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) => _buildFaqTile(itens[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaqTile(_FaqItem item) {
    return Theme(
      data: ThemeData.dark().copyWith(dividerColor: Colors.transparent),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1B26),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: Text(
            item.pergunta,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
          ),
          iconColor: const Color(0xFF9CCC65),
          collapsedIconColor: Colors.white70,
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                item.resposta,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Monta a lista de perguntas/respostas a partir de [AppLocalizations],
  /// garantindo que todo o conteúdo do FAQ acompanhe o idioma selecionado
  /// pelo usuário (item 0 do pedido de ajustes de i18n).
  List<_FaqItem> _todasAsPerguntas(AppLocalizations l10n) => [
        _FaqItem(pergunta: l10n.faqPergunta1, resposta: l10n.faqResposta1),
        _FaqItem(pergunta: l10n.faqPergunta2, resposta: l10n.faqResposta2),
        _FaqItem(pergunta: l10n.faqPergunta3, resposta: l10n.faqResposta3),
        _FaqItem(pergunta: l10n.faqPergunta4, resposta: l10n.faqResposta4),
        _FaqItem(pergunta: l10n.faqPergunta5, resposta: l10n.faqResposta5),
        _FaqItem(pergunta: l10n.faqPergunta6, resposta: l10n.faqResposta6),
        _FaqItem(pergunta: l10n.faqPergunta7, resposta: l10n.faqResposta7),
        _FaqItem(pergunta: l10n.faqPergunta9, resposta: Platform.isIOS ? l10n.faqResposta9Ios : l10n.faqResposta9),
        // Item 7 do pedido original (2026-08-XX): resposta sobre o
        // atendimento ao consumidor — atualizada em 2026-08-11 (remoção
        // do WhatsApp) para não mais descrever um chat automático; agora
        // reflete o link direto de WhatsApp da Tela de Início (suporte
        // humano) + atendente físico conforme a política da RMF Global,
        // com exclusividade de até 48h para o Plano Premium.
        _FaqItem(pergunta: l10n.faqPergunta11, resposta: l10n.faqResposta11),
        _FaqItem(pergunta: l10n.faqPergunta12, resposta: Platform.isIOS ? l10n.faqResposta12Ios : l10n.faqResposta12),
        _FaqItem(pergunta: l10n.faqPergunta13, resposta: l10n.faqResposta13),
        // Só iOS: Widget SOS ("Botão de Pânico") — mesmo passo a passo da
        // SosWidgetTutorialScreen.
        if (Platform.isIOS)
          _FaqItem(pergunta: l10n.faqPerguntaWidgetSos, resposta: l10n.faqRespostaWidgetSos),
      ];
}

class _FaqItem {
  const _FaqItem({required this.pergunta, required this.resposta});
  final String pergunta;
  final String resposta;
}
