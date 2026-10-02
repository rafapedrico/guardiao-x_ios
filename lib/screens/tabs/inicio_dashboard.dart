import 'dart:io' show Platform;

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/locale_service.dart';
import '../../services/plano_ciclo_service.dart';
import '../../services/premium_price_service.dart';
import '../../widgets/premium_compra_aviso.dart';
import '../faq_screen.dart';
import '../suporte_chat_screen.dart';
import '../termos_privacidade_screen.dart';

/// Conteúdo da nova Tela de Início (Dashboard) exibida no lugar das 4 abas
/// enquanto `HomeScreen._mostrandoInicio` for `true` — ver
/// [HomeScreen._mostrandoInicio]. Fundo 100% preto do topo ao rodapé,
/// puramente informacional: os cards de plano abrem modais explicativos
/// nesta própria tela — não navega para Configurações.
class InicioDashboard extends StatelessWidget {
  const InicioDashboard({super.key});

  static const String _site = 'https://www.meuguardiaox.com.br';

  static const Color _corDestaquePremium = Color(0xFF9C6BFF);

  static Future<void> _abrirUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('⚠️ [InicioDashboard] Falha ao abrir URL "$url": $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Container preservando o fundo preto por trás de todo o conteúdo,
    // inclusive na área de overscroll/bounce da ListView.
    return Container(
      color: Colors.black,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _buildCabecalho(context),
          _buildSecaoPlanos(context),
          _buildIndicadorPlanoFree(context),
          _buildRodape(context),
        ],
      ),
    );
  }

  /// Imagem de destaque (a mesma por idioma usada no topo do Login, já
  /// com ícone + nome "Guardião-X" + ilustração embutidos) em largura
  /// total, com altura proporcional (sem forçar um tamanho fixo que
  /// distorça a imagem). DOIS níveis de fallback — se o asset do idioma
  /// atual falhar, cai para a imagem padrão em português; se até essa
  /// falhar, cai para um cabeçalho de texto simples — garantindo que a
  /// tela nunca fique em branco.
  Widget _buildCabecalho(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: LocaleService.codigoIdiomaCompletoNotifier,
      builder: (context, codigoIdioma, _) {
        // Gradiente transparente -> preto na base da imagem, fundindo-a
        // suavemente com o fundo AMOLED do restante da tela, sem nenhuma
        // moldura/container ao redor (a imagem continua width:
        // double.infinity, sem Container/borda).
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.transparent],
            stops: [0.6, 1.0],
          ).createShader(Rect.fromLTRB(0, 0, rect.width, rect.height)),
          child: Image.asset(
            LocaleService.caminhoImagemLoginPara(codigoIdioma),
            width: double.infinity,
            fit: BoxFit.fitWidth,
            errorBuilder: (context, error, stackTrace) => Image.asset(
              LocaleService.imagemLoginPadrao,
              width: double.infinity,
              fit: BoxFit.fitWidth,
              errorBuilder: (context, error, stackTrace) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    AppLocalizations.of(context)!.marcaGuardiaoX,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSecaoPlanos(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: Text(
              l10n.dashboardSecaoPlanosTitulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // IntrinsicHeight: dá ao Row uma altura finita baseada no
          // conteúdo antes de aplicar `stretch`, permitindo que os dois
          // cartões fiquem com a mesma altura sem propagar uma altura
          // infinita para os filhos (o Row está dentro de uma ListView,
          // cuja altura vertical é irrestrita — aplicar `stretch` direto
          // ali quebrava o layout e deixava a tela em branco).
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _CartaoPlano(
                    titulo: l10n.dashboardPlanoFreeTitulo,
                    preco: null,
                    descricao: l10n.dashboardPlanoFreeDescricao,
                    corPrincipal: Colors.white24,
                    destaque: false,
                    // Item 4: o Card Free não abre nenhum modal ao ser
                    // tocado.
                    onTap: null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // Preço 100% dinâmico, consultado direto da loja
                  // (Google Play Billing/App Store — ver
                  // PremiumPriceService), na moeda local da conta do
                  // usuário. Enquanto a consulta assíncrona está em
                  // andamento (ou se a loja/produto não estiverem
                  // disponíveis), mostra um texto genérico SEM valor —
                  // nunca um preço fixo/hardcoded.
                  child: FutureBuilder<String?>(
                    future: PremiumPriceService().obterPrecoFormatado(),
                    builder: (context, snapshot) {
                      final precoLoja = snapshot.data;
                      final preco = precoLoja != null
                          ? l10n.premiumPrecoMensalComValor(precoLoja)
                          : l10n.premiumPrecoGenerico;
                      return _CartaoPlano(
                        titulo: l10n.planoPremiumTitulo,
                        preco: preco,
                        descricao: l10n.dashboardPlanoPremiumDescricao,
                        corPrincipal: _corDestaquePremium,
                        destaque: true,
                        selo: l10n.premiumBadge,
                        onTap: () => _abrirModalPremium(context),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Indicador visual simples do status do ciclo do Plano Free (item 4 do
  /// pedido: "Plano Free: Restam X dias de proteção completa este mês") —
  /// reativo em tempo real via [PlanoCicloService.statusStream], nunca
  /// exibido para quem já é Premium (sem contagem, proteção sempre
  /// ilimitada) nem enquanto o status ainda não foi carregado (evita um
  /// "pisca" de estado incorreto no primeiro frame).
  Widget _buildIndicadorPlanoFree(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return StreamBuilder<PlanoCicloStatus?>(
      stream: PlanoCicloService().statusStream(),
      builder: (context, snapshot) {
        final status = snapshot.data;
        if (status == null || status.isPremium) return const SizedBox.shrink();

        final bool ativo = status.ativo;
        final String texto = ativo
            ? l10n.planoFreeIndicadorAtivo(status.diasRestantesAtivos)
            : l10n.planoFreeIndicadorBloqueado(
                status.diasParaRenovacao, _formatarData(status.dataRenovacao));

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: (ativo ? Colors.green : _corDestaquePremium).withOpacity(0.14),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (ativo ? Colors.green : _corDestaquePremium).withOpacity(0.4),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  ativo ? Icons.shield_outlined : Icons.lock_clock,
                  size: 18,
                  color: ativo ? Colors.greenAccent : _corDestaquePremium,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    texto,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatarData(DateTime data) {
    final dia = data.day.toString().padLeft(2, '0');
    final mes = data.month.toString().padLeft(2, '0');
    return '$dia/$mes/${data.year}';
  }

  /// Lê `isPremium` de `usuarios/{uid}` no Firestore — mesma fonte de
  /// verdade server-side usada por [PlanoCicloService] em todos os
  /// pontos de bloqueio — para saber se o usuário tem atualmente o Plano
  /// Premium ativo. Qualquer falha de leitura resulta em `false` (trata
  /// como Free), já que este método só controla a exibição de um botão
  /// de UI, nunca uma regra de segurança.
  Future<bool> _possuiPlanoPremiumAtivo() async {
    final status = await PlanoCicloService().obterStatusAtualizado();
    return status?.isPremium ?? false;
  }

  Future<void> _abrirModalPremium(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final bool premiumAtivo = await _possuiPlanoPremiumAtivo();
    // Reaproveita o mesmo cache do PremiumPriceService (a consulta já
    // deve ter sido feita pelo FutureBuilder do card, ver
    // _buildSecaoPlanos) — mesmo texto/valor genérico de fallback caso a
    // loja/produto não estejam disponíveis.
    final String? precoLoja = await PremiumPriceService().obterPrecoFormatado();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => _ModalDetalhePlano(
        icone: Icons.workspace_premium,
        corPrincipal: _corDestaquePremium,
        titulo: l10n.planoPremiumTitulo,
        destaque: l10n.premiumModalDestaque,
        beneficios: [
          l10n.beneficioLocalizacaoTempoReal,
          // iOS: sem botão físico (substituído pelo SOS da tela principal)
          // e sem SMS — por isso a versão própria e sem o item das duas
          // camadas (App + SMS).
          Platform.isIOS ? l10n.beneficioBotaoFisicoIos : l10n.beneficioBotaoFisico,
          l10n.beneficioModoSeguranca,
          l10n.beneficioModoFamilia,
          if (!Platform.isIOS) l10n.beneficioTresCamadas,
          l10n.beneficioTempoEspera,
        ],
        botaoPrincipalTexto: precoLoja != null
            ? l10n.premiumAssinarBotaoComPreco(precoLoja)
            : l10n.premiumAssinarBotaoGenerico,
        onBotaoPrincipal: () {
          Navigator.of(ctx).pop();
          // Compra REAL via Google Play Billing (ver PremiumPurchaseService)
          // — não mais um deep-link pra página da loja. O resultado chega
          // de forma assíncrona pelo purchaseStream global (ver o
          // SnackBar em main.dart::_SecurityCheckAppState), então este
          // método não precisa ser aguardado aqui. Se a tela de pagamento
          // não abrir (loja/produto indisponível), mostra um aviso.
          iniciarCompraPremiumComAviso(context);
        },
        botaoSecundarioTexto: l10n.agoraNao,
        // O botão "Cancelar Plano Premium" só é exibido quando o plano
        // Premium está de fato ativo — no Plano Free, não há nada para
        // cancelar, então o botão fica oculto (item 1 do pedido).
        onCancelarPremium:
            premiumAtivo ? () => _confirmarCancelamentoPremium(context) : null,
      ),
    );
  }

  /// Confirma e efetiva a reversão do plano do usuário para o Free,
  /// acionado pelo botão "Cancelar Plano Premium" dentro do modal
  /// informativo do Premium. Chama a Cloud Function
  /// `cancelarPremiumDoProprioUsuario` (ver `functions/planoCicloService.js`)
  /// — `isPremium` agora vive em `usuarios/{uid}` no Firestore, protegido
  /// por `firestore.rules` contra escrita direta do cliente (ver
  /// [PlanoCicloService]); um self-downgrade (nunca upgrade) continua
  /// seguro de ser exposto como callable simples, sem risco de fraude.
  Future<void> _confirmarCancelamentoPremium(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final bool? confirmou = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.premiumCancelarConfirmTitulo),
        content: Text(l10n.premiumCancelarConfirmConteudo),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.voltar),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.premiumCancelarConfirmBotao),
          ),
        ],
      ),
    );

    if (confirmou != true || !context.mounted) return;

    try {
      await FirebaseFunctions.instance
          .httpsCallable('cancelarPremiumDoProprioUsuario')
          .call();
    } catch (e) {
      debugPrint('⚠️ [InicioDashboard] Falha ao cancelar Plano Premium: $e');
    }

    if (!context.mounted) return;
    Navigator.of(context).pop(); // fecha o modal do Premium
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.premiumCanceladoSnackbar)),
    );
  }

  Widget _buildRodape(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Item 4: só um botão/link elegante para a nova FaqScreen
          // dedicada — o accordion inline foi removido daqui.
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FaqScreen()),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.help_outline, color: Color(0xFF9CCC65)),
              label: Text(
                l10n.dashboardFaqTitulo,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          Center(
            child: InkWell(
              onTap: () => _abrirUrl(_site),
              child: const Text(
                'www.meuguardiaox.com.br',
                style: TextStyle(
                  color: Color(0xFF9CCC65),
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          // A partir daqui (dados corporativos e central de atendimento)
          // todo o conteúdo fica centralizado, conforme pedido de UX.
          Center(
            child: Text(
              l10n.footerEmpresaRazaoSocial,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              // Endereço completo em uma única linha (inclui o CEP), sem
              // quebra manual — o Text já faz o wrap automático se a tela
              // for estreita demais.
              l10n.footerEmpresaEndereco,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              l10n.footerEmpresaCnpj,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),

          const SizedBox(height: 24),
          const Divider(color: Colors.white24),
          const SizedBox(height: 20),

          Center(
            child: Text(
              l10n.dashboardCentralAtendimentoTitulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SuporteChatScreen()),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _corDestaquePremium,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                elevation: 0,
              ),
              icon: const Icon(Icons.chat_bubble_outline, size: 22),
              label: Text(
                l10n.suporteChatBotaoInicio,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Links jurídicos: abrem a TermosPrivacidadeScreen já na aba
          // correspondente. `width: double.infinity` + `textAlign.center`
          // garante a centralização mesmo quando o texto (mais longo em
          // alguns idiomas) quebra em duas linhas — só o Center() do
          // InkWell não bastava: sem textAlign, a 2ª linha ficava alinhada
          // à esquerda da caixa de texto em vez de centralizada.
          Center(
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const TermosPrivacidadeScreen(abaInicial: 0),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  l10n.footerTermosLink,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const TermosPrivacidadeScreen(abaInicial: 1),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  l10n.termosTabPrivacidade,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ),

          // Padding inferior para o conteúdo não terminar colado na
          // BottomNavigationBar.
          const SizedBox(height: 56),
        ],
      ),
    );
  }
}

/// Card de plano com visual moderno: fundo translúcido escuro para o
/// Free (discreto, se funde ao fundo preto da página) e um brilho/glow
/// gradiente para o Premium (borda e sombra luminosas, chamando atenção).
class _CartaoPlano extends StatelessWidget {
  const _CartaoPlano({
    required this.titulo,
    required this.preco,
    required this.descricao,
    required this.corPrincipal,
    required this.destaque,
    this.onTap,
    this.selo,
  });

  final String titulo;
  final String? preco;
  final String descricao;
  final Color corPrincipal;
  final bool destaque;
  // Item 4: nullable — o Card Free não deve abrir nenhum modal ao ser
  // tocado, então recebe `null` aqui (o InkWell fica com o efeito de
  // toque desativado).
  final VoidCallback? onTap;
  final String? selo;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: destaque
              ? const LinearGradient(
                  colors: [Color(0xFF2A43C2), Color(0xFF4A00E0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: destaque ? null : const Color(0xFF1A1B26),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: destaque ? const Color(0xFF4A00E0) : Colors.white24,
            width: destaque ? 1.4 : 1,
          ),
          boxShadow: destaque
              ? [
                  BoxShadow(
                    color: const Color(0xFF2A43C2).withOpacity(0.55),
                    blurRadius: 20,
                    spreadRadius: 1,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selo != null) ...[
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD700),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, color: Colors.black87, size: 12),
                      const SizedBox(width: 3),
                      Text(
                        selo!.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              titulo,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (preco != null) ...[
              const SizedBox(height: 4),
              Text(
                preco!,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              descricao,
              style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal de detalhes de um plano (Free ou Premium), aberto ao tocar no
/// respectivo card. Estrutura compartilhada: ícone + título, banner de
/// destaque, lista de benefícios e ação(ões) no rodapé.
class _ModalDetalhePlano extends StatelessWidget {
  const _ModalDetalhePlano({
    required this.icone,
    required this.corPrincipal,
    required this.titulo,
    required this.destaque,
    required this.beneficios,
    required this.botaoPrincipalTexto,
    required this.onBotaoPrincipal,
    this.botaoSecundarioTexto,
    this.onCancelarPremium,
  });

  final IconData icone;
  final Color corPrincipal;
  final String titulo;
  final String destaque;
  final List<String> beneficios;
  final String botaoPrincipalTexto;
  final VoidCallback onBotaoPrincipal;
  final String? botaoSecundarioTexto;

  /// Quando informado (apenas no modal do Premium), exibe o botão
  /// "Cancelar Plano Premium" — reverte o usuário para o Plano Free.
  final VoidCallback? onCancelarPremium;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Row(
        children: [
          Icon(icone, color: corPrincipal),
          const SizedBox(width: 8),
          Expanded(child: Text(titulo)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: corPrincipal.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: corPrincipal.withOpacity(0.4)),
              ),
              child: Text(
                destaque,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: corPrincipal,
                ),
              ),
            ),
            const SizedBox(height: 14),
            ...beneficios.map(
              (texto) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle, size: 18, color: corPrincipal),
                    const SizedBox(width: 10),
                    Expanded(child: Text(texto, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
            if (onCancelarPremium != null) ...[
              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 4),
              Center(
                child: TextButton.icon(
                  onPressed: onCancelarPremium,
                  icon: const Icon(Icons.cancel_outlined, size: 18, color: Colors.red),
                  label: Text(
                    l10n.premiumCancelarBotaoModal,
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (botaoSecundarioTexto != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(botaoSecundarioTexto!),
          ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: corPrincipal),
          onPressed: onBotaoPrincipal,
          child: Text(botaoPrincipalTexto),
        ),
      ],
    );
  }
}
