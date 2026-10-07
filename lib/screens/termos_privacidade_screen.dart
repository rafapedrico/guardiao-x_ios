import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

/// Tela jurídica dedicada, com o Contrato de Consentimento do Usuário e a
/// Política de Privacidade do aplicativo Guardião-X, operado pela RMF
/// Global LTDA. Acessada pelo link no rodapé da Tela de Início
/// (Dashboard) — ver [InicioDashboard].
///
/// Todo o conteúdo jurídico (títulos e corpo de cada seção, títulos das
/// abas e o aviso de rodapé) vem de [AppLocalizations], garantindo que o
/// Contrato de Consentimento e a Política de Privacidade sejam exibidos
/// integralmente no idioma selecionado pelo usuário, nos 11 idiomas
/// suportados pelo aplicativo.
class TermosPrivacidadeScreen extends StatefulWidget {
  const TermosPrivacidadeScreen({super.key, this.abaInicial = 0});

  /// 0 = abre direto no Contrato de Consentimento, 1 = Política de
  /// Privacidade.
  final int abaInicial;

  @override
  State<TermosPrivacidadeScreen> createState() => _TermosPrivacidadeScreenState();
}

class _TermosPrivacidadeScreenState extends State<TermosPrivacidadeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.abaInicial,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  static const TextStyle _estiloTituloSecao = TextStyle(
    color: Colors.white,
    fontSize: 15,
    fontWeight: FontWeight.bold,
  );
  static const TextStyle _estiloCorpo = TextStyle(
    color: Colors.white70,
    fontSize: 13,
    height: 1.5,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.home_outlined),
          tooltip: l10n.homeTooltipInicio,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(l10n.termosAppBarTitulo),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF9CCC65),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: [
            Tab(text: l10n.termosTabContrato),
            Tab(text: l10n.termosTabPrivacidade),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildConteudo(l10n, _secoesContrato(l10n)),
          _buildConteudo(l10n, _secoesPrivacidade(l10n)),
        ],
      ),
    );
  }

  Widget _buildConteudo(AppLocalizations l10n, List<_Secao> secoes) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
      children: [
        Text(
          l10n.footerEmpresaRazaoSocial,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.footerEmpresaEndereco,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.footerEmpresaCnpj,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 20),
        for (final secao in secoes) ...[
          Text(secao.titulo, style: _estiloTituloSecao),
          const SizedBox(height: 6),
          Text(secao.corpo, style: _estiloCorpo),
          const SizedBox(height: 18),
        ],
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1B26),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            l10n.termosAvisoRodape,
            style: const TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }

  List<_Secao> _secoesContrato(AppLocalizations l10n) => [
        _Secao(titulo: l10n.termosContratoTitulo1, corpo: l10n.termosContratoCorpo1),
        _Secao(titulo: l10n.termosContratoTitulo2, corpo: l10n.termosContratoCorpo2),
        _Secao(titulo: l10n.termosContratoTitulo3, corpo: l10n.termosContratoCorpo3),
        _Secao(titulo: l10n.termosContratoTitulo4, corpo: l10n.termosContratoCorpo4),
        _Secao(titulo: l10n.termosContratoTitulo5, corpo: l10n.termosContratoCorpo5),
        _Secao(titulo: l10n.termosContratoTitulo6, corpo: l10n.termosContratoCorpo6),
        _Secao(titulo: l10n.termosContratoTitulo7, corpo: l10n.termosContratoCorpo7),
        _Secao(titulo: l10n.termosContratoTitulo8, corpo: l10n.termosContratoCorpo8),
        _Secao(titulo: l10n.termosContratoTitulo9, corpo: l10n.termosContratoCorpo9),
      ];

  List<_Secao> _secoesPrivacidade(AppLocalizations l10n) => [
        _Secao(titulo: l10n.termosPrivacidadeTitulo1, corpo: l10n.termosPrivacidadeCorpo1),
        _Secao(titulo: l10n.termosPrivacidadeTitulo2, corpo: l10n.termosPrivacidadeCorpo2),
        _Secao(titulo: l10n.termosPrivacidadeTitulo3, corpo: l10n.termosPrivacidadeCorpo3),
        _Secao(titulo: l10n.termosPrivacidadeTitulo4, corpo: l10n.termosPrivacidadeCorpo4),
        _Secao(titulo: l10n.termosPrivacidadeTitulo5, corpo: l10n.termosPrivacidadeCorpo5),
        _Secao(titulo: l10n.termosPrivacidadeTitulo6, corpo: l10n.termosPrivacidadeCorpo6),
        _Secao(titulo: l10n.termosPrivacidadeTitulo7, corpo: l10n.termosPrivacidadeCorpo7),
        _Secao(titulo: l10n.termosPrivacidadeTitulo8, corpo: l10n.termosPrivacidadeCorpo8),
      ];
}

class _Secao {
  const _Secao({required this.titulo, required this.corpo});
  final String titulo;
  final String corpo;
}
