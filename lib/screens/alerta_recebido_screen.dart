import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:security_check_app/l10n/app_localizations.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/alertas_recebidos_service.dart';
import '../services/firebase_auth_service.dart';
import '../services/notificacao_service.dart';
import '../services/bloqueio_app_service.dart';
import '../widgets/texto_com_links.dart';
import 'home_screen.dart';
import 'login_screen.dart';

/// Tela exibida quando ESTE aparelho recebe, via Push FCM, o alerta de
/// emergência de OUTRO usuário que o cadastrou como contato de emergência
/// (ver `FcmService`/`NotificacaoService.exibirNotificacaoAlertaRecebido`).
///
/// Distinta da [AlarmeDisparadoScreen] — aquela é para o PRÓPRIO alarme
/// do usuário (com fluxo de PIN para desarmar); esta é somente
/// informativa, mostrando quem disparou o alerta e a foto/localização
/// recebida.
///
/// **Migração iOS (2026-09-12):** auditada e SEM nenhuma alteração
/// necessária — todos os plugins usados aqui (`gal`, `share_plus`,
/// `url_launcher`) já são cross-platform, e as duas únicas chamadas a
/// canais nativos Android-only ([NotificacaoService.pararAlarmeCritico]/
/// [NotificacaoService.cancelarNotificacaoAlertaRecebido]) já eram
/// protegidas por try/catch antes desta migração — no iOS, elas só
/// logam um aviso e seguem normalmente, nunca travam o fechamento da
/// tela nem o cancelamento da notificação.
class AlertaRecebidoScreen extends StatefulWidget {
  const AlertaRecebidoScreen({
    super.key,
    required this.mensagem,
    this.nomeRemetente,
    this.latitude,
    this.longitude,
    this.fotoUrl,
    this.idEntrega,
    this.recebidoEm,
  });

  final String mensagem;
  final String? nomeRemetente;
  final double? latitude;
  final double? longitude;

  /// Link (Firebase Storage) da foto do SOS, quando o alerta for do tipo
  /// `sos_fisico_foto` (ver `functions/alertaHibridoService.js`). Quando
  /// presente, a tela CARREGA E EXIBE a imagem diretamente — nunca
  /// mostra a URL crua em texto.
  final String? fotoUrl;

  /// Identifica o documento `entregas_alerta/{idEntrega}` — usado para
  /// marcar este alerta como visualizado localmente (ver
  /// [AlertasRecebidosService], indicador de "não visualizado" no
  /// HomeScreen/aba Histórico).
  final String? idEntrega;

  /// Data/hora EXATA (ISO 8601) em que este alerta foi recebido neste
  /// aparelho — reespecificação do usuário (2026-08-14): "todas as
  /// mensagens" devem mostrar horário e data exata, em vez de só uma
  /// descrição relativa. Vem de `NotificacaoService.exibirNotificacaoAlertaRecebido`
  /// (campo `recebidoEm` do payload) ou, quando aberta a partir do
  /// Histórico, do `recebido_em` já gravado localmente (ver
  /// `historico_tab.dart`). `null` só em payloads antigos/incompletos —
  /// nesse caso o bloco de data/hora simplesmente não aparece.
  final String? recebidoEm;

  @override
  State<AlertaRecebidoScreen> createState() => _AlertaRecebidoScreenState();
}

// Emergência: funciona sem desbloquear o app (ver BloqueioAppService).
class _AlertaRecebidoScreenState extends State<AlertaRecebidoScreen>
    with LiberaBloqueioEnquantoAberta<AlertaRecebidoScreen> {
  Uint8List? _fotoBytes;
  bool _carregandoFoto = false;
  bool _erroFoto = false;
  bool _baixando = false;
  bool _compartilhando = false;

  bool get _temFoto => widget.fotoUrl != null && widget.fotoUrl!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Item 4 do pedido ("Despertador de Emergência"): abrir esta tela —
    // por qualquer caminho (toque na notificação, no card do Histórico,
    // etc.) — já é uma ação clara do usuário sobre o alerta, então
    // silencia o alarme sonoro imediatamente. Dois mecanismos, cobrindo
    // os dois cenários documentados em `NotificacaoService`/
    // `AlertaRecebidoAlarmService.kt`: [pararAlarmeCritico] para o
    // plugin nativo customizado (só ativo quando o app já tinha um
    // engine "de verdade" rodando) e [cancelarNotificacaoAlertaRecebido]
    // remove a notificação em si — o que, por sua vez, é o que
    // efetivamente para o som em loop contínuo
    // (`Notification.FLAG_INSISTENT`, funciona mesmo vindo do isolate
    // headless). Ambos idempotentes/seguros mesmo sem nada tocando.
    NotificacaoService.pararAlarmeCritico();
    final idEntrega = widget.idEntrega;
    if (idEntrega != null && idEntrega.isNotEmpty) {
      AlertasRecebidosService.marcarVisualizadoPorIdEntrega(idEntrega);
      NotificacaoService.cancelarNotificacaoAlertaRecebido(idEntrega);
    }
    if (_temFoto) _carregarFoto();
  }

  Future<void> _carregarFoto() async {
    setState(() {
      _carregandoFoto = true;
      _erroFoto = false;
    });
    try {
      final resposta = await http.get(Uri.parse(widget.fotoUrl!)).timeout(const Duration(seconds: 20));
      if (resposta.statusCode != 200) throw Exception('HTTP ${resposta.statusCode}');
      if (mounted) setState(() => _fotoBytes = resposta.bodyBytes);
    } catch (e) {
      debugPrint('⚠️ [AlertaRecebidoScreen] Falha ao carregar foto: $e');
      if (mounted) setState(() => _erroFoto = true);
    } finally {
      if (mounted) setState(() => _carregandoFoto = false);
    }
  }

  Future<void> _baixarFoto() async {
    final bytes = _fotoBytes;
    if (bytes == null || _baixando) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _baixando = true);
    try {
      final permitido = await Gal.requestAccess();
      if (!permitido) {
        _mostrarSnack(l10n.alertaRecebidoPermissaoNegada);
        return;
      }
      await Gal.putImageBytes(bytes);
      _mostrarSnack(l10n.alertaRecebidoFotoSalva);
    } catch (e) {
      debugPrint('⚠️ [AlertaRecebidoScreen] Falha ao salvar foto: $e');
      _mostrarSnack(l10n.alertaRecebidoFalhaSalvar);
    } finally {
      if (mounted) setState(() => _baixando = false);
    }
  }

  Future<void> _compartilharFoto() async {
    final bytes = _fotoBytes;
    if (bytes == null || _compartilhando) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _compartilhando = true);
    try {
      final arquivo = XFile.fromData(bytes, name: 'foto_sos.jpg', mimeType: 'image/jpeg');
      await Share.shareXFiles([arquivo], text: widget.mensagem);
    } catch (e) {
      debugPrint('⚠️ [AlertaRecebidoScreen] Falha ao compartilhar foto: $e');
      _mostrarSnack(l10n.alertaRecebidoFalhaCompartilhar);
    } finally {
      if (mounted) setState(() => _compartilhando = false);
    }
  }

  /// Formata [widget.recebidoEm] como data + hora exata no idioma ativo
  /// do usuário (ex: "14/08/2026 22:15" em pt-BR, "8/14/2026 10:15 PM" em
  /// en-US) — ver documentação completa em [AlertaRecebidoScreen.recebidoEm].
  /// Devolve `null` quando não há timestamp (esconde o bloco no `build`).
  String? _dataHoraExata(BuildContext context) {
    final iso = widget.recebidoEm;
    if (iso == null || iso.isEmpty) return null;
    final dataHora = DateTime.tryParse(iso);
    if (dataHora == null) return null;
    final locale = Localizations.localeOf(context).toString();
    return DateFormat.yMd(locale).add_Hm().format(dataHora.toLocal());
  }

  void _mostrarSnack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _abrirMapa() async {
    if (widget.latitude == null || widget.longitude == null) return;
    // Item 4 do pedido: "clicar no link de localização" também silencia
    // o alarme — redundante com o `initState` acima (já parado ao abrir
    // esta tela), mas mantido aqui explicitamente por segurança/clareza.
    NotificacaoService.pararAlarmeCritico();
    final idEntrega = widget.idEntrega;
    if (idEntrega != null && idEntrega.isNotEmpty) {
      NotificacaoService.cancelarNotificacaoAlertaRecebido(idEntrega);
    }
    final uri = Uri.parse('https://maps.google.com/?q=${widget.latitude},${widget.longitude}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Fecha esta tela e SEMPRE volta para o fluxo normal do app — NUNCA
  /// fecha/minimiza o app. Se ainda houver alguma rota abaixo (caso
  /// comum: aberta por cima da Home/Login já visível), um pop simples já
  /// resolve; caso contrário (ex: cold start via toque na notificação
  /// com o app totalmente fechado, onde esta pode acabar sendo a única
  /// rota), força explicitamente a navegação para a Home (se
  /// autenticado) ou a Login — nunca deixa o Android tratar a ausência
  /// de rotas como "sair do app".
  void _fecharTela() {
    // Redundante com [initState] (o alarme já para assim que esta tela
    // abre) — mantido aqui explicitamente porque o botão "Fechar" é, por
    // si só, um gesto claro de "dispensar o alerta" (reespecificação do
    // usuário, 2026-08-16). Idempotente/seguro chamar de novo mesmo já
    // parado.
    NotificacaoService.pararAlarmeCritico();
    final idEntregaFechar = widget.idEntrega;
    if (idEntregaFechar != null && idEntregaFechar.isNotEmpty) {
      NotificacaoService.cancelarNotificacaoAlertaRecebido(idEntregaFechar);
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    final autenticado = FirebaseAuthService().uidAtual != null;
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => autenticado ? const HomeScreen() : const LoginScreen(),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) _fecharTela();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF14212E),
        appBar: AppBar(
          backgroundColor: Colors.red.shade700,
          title: Text(l10n.alertaRecebidoTitulo),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 72),
                const SizedBox(height: 16),
                if (widget.nomeRemetente != null && widget.nomeRemetente!.isNotEmpty)
                  Text(
                    l10n.alertaRecebidoDe(widget.nomeRemetente!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                if (_dataHoraExata(context) != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.schedule, color: Colors.white54, size: 15),
                      const SizedBox(width: 6),
                      Text(
                        _dataHoraExata(context)!,
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                if (_temFoto) _buildFoto(l10n) else _buildMensagemTexto(),
                if (widget.latitude != null && widget.longitude != null) ...[
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: _abrirMapa,
                    icon: const Icon(Icons.map),
                    label: Text(l10n.alertaRecebidoVerNoMapa),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4C7040),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: _fecharTela,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white38),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    l10n.fechar,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Item 3 (reespecificação do usuário, 2026-08-14): o link de
  /// localização/foto embutido no corpo bruto da mensagem (ver
  /// [EmergencyAlertService._formatarPosicao]) agora aparece em AZUL e
  /// clicável — mesmo tratamento dado aos cards do Histórico (ver
  /// `historico_tab.dart`/[construirSpansComLinks]), em vez de texto cru
  /// na mesma cor do restante da mensagem.
  Widget _buildMensagemTexto() {
    const estiloBase = TextStyle(color: Colors.white70, fontSize: 14);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E313F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text.rich(
        TextSpan(
          children: construirSpansComLinks(widget.mensagem, estiloBase, _abrirLinkDaMensagem),
        ),
      ),
    );
  }

  Future<void> _abrirLinkDaMensagem(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('⚠️ [AlertaRecebidoScreen] Falha ao abrir link da mensagem: $e');
    }
  }

  Widget _buildFoto(AppLocalizations l10n) {
    if (_carregandoFoto) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    if (_erroFoto || _fotoBytes == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E313F),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
            const SizedBox(height: 8),
            Text(
              l10n.alertaRecebidoFotoIndisponivel,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _carregarFoto, child: Text(l10n.alertaRecebidoTentarNovo)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(_fotoBytes!, fit: BoxFit.cover, width: double.infinity),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _baixando ? null : _baixarFoto,
                icon: _baixando
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.download),
                label: Text(l10n.alertaRecebidoBaixarFoto),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _compartilhando ? null : _compartilharFoto,
                icon: _compartilhando
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.share),
                label: Text(l10n.alertaRecebidoCompartilhar),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4C7040),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
