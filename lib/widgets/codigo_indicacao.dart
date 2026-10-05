import 'package:flutter/material.dart';
import 'package:security_check_app/l10n/app_localizations.dart';

import '../services/indicacao_service.dart';

/// Mensagem para o `motivo` de `registrarIndicacao` (sem valor nem
/// recompensa — ver [IndicacaoService]).
String textoResultadoIndicacao(AppLocalizations l10n, ResultadoIndicacao resultado) =>
    switch (resultado) {
      ResultadoIndicacao.ok => l10n.indicacaoResultadoOk,
      ResultadoIndicacao.codigoInvalido => l10n.indicacaoResultadoCodigoInvalido,
      ResultadoIndicacao.autoindicacao => l10n.indicacaoResultadoAutoindicacao,
      ResultadoIndicacao.jaVinculado => l10n.indicacaoResultadoJaVinculado,
      ResultadoIndicacao.jaPremium => l10n.indicacaoResultadoJaPremium,
      ResultadoIndicacao.erro => l10n.indicacaoResultadoErro,
    };

/// Cartão "Tem um código de indicação?" de Configurações: só aparece
/// enquanto o usuário não é Premium nem tem vínculo
/// ([IndicacaoService.podeInformarCodigo]) e some sozinho depois de
/// vinculado. Pré-preenche com o código de um Universal Link.
class CartaoCodigoIndicacao extends StatefulWidget {
  const CartaoCodigoIndicacao({super.key});

  @override
  State<CartaoCodigoIndicacao> createState() => _CartaoCodigoIndicacaoState();
}

class _CartaoCodigoIndicacaoState extends State<CartaoCodigoIndicacao> {
  final IndicacaoService _servico = IndicacaoService();
  final TextEditingController _controller = TextEditingController();
  late final Stream<bool> _podeInformar = _servico.podeInformarCodigo();
  bool _enviando = false;
  ResultadoIndicacao? _resultado;

  @override
  void initState() {
    super.initState();
    _aplicarCodigoDoLink();
    _servico.codigoDoLink.addListener(_aplicarCodigoDoLink);
  }

  @override
  void dispose() {
    _servico.codigoDoLink.removeListener(_aplicarCodigoDoLink);
    _controller.dispose();
    super.dispose();
  }

  void _aplicarCodigoDoLink() {
    final codigo = _servico.codigoDoLink.value;
    if (codigo == null || _controller.text == codigo) return;
    _controller.text = codigo;
    if (mounted) setState(() => _resultado = null);
  }

  Future<void> _aplicar() async {
    final codigo = _controller.text.trim();
    if (codigo.isEmpty || _enviando) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _enviando = true;
      _resultado = null;
    });
    final resultado = await _servico.registrar(codigo);
    if (!mounted) return;
    setState(() {
      _enviando = false;
      _resultado = resultado;
    });
    if (resultado == ResultadoIndicacao.ok) {
      // O cartão some (indicadoPor gravado); o aviso fica no SnackBar.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(textoResultadoIndicacao(AppLocalizations.of(context)!, resultado)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: _podeInformar,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context)!;
        final resultado = _resultado;
        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.person_add_alt_1_outlined, color: Color(0xFF4C7040)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.indicacaoPergunta,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: !_enviando,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLength: 12,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _aplicar(),
                        decoration: InputDecoration(
                          labelText: l10n.indicacaoCampoLabel,
                          counterText: '',
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      height: 44,
                      child: FilledButton(
                        onPressed: _enviando ? null : _aplicar,
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF4C7040)),
                        child: _enviando
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(l10n.indicacaoBotaoAplicar),
                      ),
                    ),
                  ],
                ),
                if (resultado != null && resultado != ResultadoIndicacao.ok)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      textoResultadoIndicacao(l10n, resultado),
                      style: TextStyle(fontSize: 12.5, color: Colors.red.shade700),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
