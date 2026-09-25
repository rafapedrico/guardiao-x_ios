import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Ponte entre o Widget de Home Screen do iOS ("Botão de Pânico Virtual")
/// e o fluxo unificado de SOS ([SosDisparoService], acionado a partir de
/// `main.dart`).
///
/// SUBSTITUTO DE PRODUTO PARA O `volume_sos` NO iOS (decisão de produto já
/// registrada em `docs/migracao-ios-relatorio-2026-09-12.md`, seção 5,
/// item 4): a Apple não permite que nenhum app escute o botão físico de
/// Volume+ em segundo plano/com o app fechado — sem rota de código
/// possível, só um substituto de produto (o relatório já sugeria um
/// Atalho/Botão de Ação). Este serviço cobre essa necessidade via um
/// Widget 1x1 estático na tela de início do iPhone (WidgetKit nativo, ver
/// `ios/SOSWidget/`) cujo único gesto é abrir o app através do URL Scheme
/// `guardiaox://sos` (`.widgetURL(...)` no SwiftUI) — o toque no widget É
/// o gatilho; a Apple não permite lógica alguma rodando dentro do próprio
/// widget além de exibir a UI estática.
///
/// Cobre os DOIS cenários de lançamento de um URL Scheme custom no iOS:
///   - App fechado/morto: [linkInicial] resolve o link que causou o cold
///     start (consumido uma única vez, o mais cedo possível em `main()`).
///   - App já rodando (foreground ou suspenso em segundo plano):
///     [aoReceberLink] emite cada novo link recebido enquanto o processo
///     já está vivo.
///
/// Mantido como singleton para nunca abrir duas assinaturas concorrentes
/// de [aoReceberLink] (mesmo padrão de [VolumeSosService]/[NotificacaoService]).
class SosDeepLinkService {
  SosDeepLinkService._internal();
  static final SosDeepLinkService _instance = SosDeepLinkService._internal();
  factory SosDeepLinkService() => _instance;

  final AppLinks _appLinks = AppLinks();

  /// Host esperado no URL Scheme `guardiaox://sos` — comparado via
  /// `uri.host`, nunca via `uri.toString()` cru, para tolerar variações
  /// (barra final, maiúsculas) sem risco de falso negativo.
  static const String _hostSos = 'sos';

  /// `true` quando [uri] representa o gatilho de SOS do widget
  /// (`guardiaox://sos`) — comparação por scheme + host, não pela string
  /// completa.
  bool ehLinkDeSos(Uri uri) {
    return uri.scheme.toLowerCase() == 'guardiaox' &&
        uri.host.toLowerCase() == _hostSos;
  }

  /// Resolve o link (se houver) que causou o COLD START do app — `null`
  /// em qualquer abertura normal (ícone, notificação, etc.) ou se a
  /// própria checagem falhar. Nunca lança exceção: um `app_links`
  /// indisponível por qualquer motivo não pode impedir o boot do app.
  Future<Uri?> linkInicial() async {
    try {
      return await _appLinks.getInitialLink();
    } catch (e) {
      debugPrint('⚠️ [SosDeepLinkService] Falha ao ler o link inicial: $e');
      return null;
    }
  }

  /// Emite cada link recebido enquanto o app já está com o processo vivo
  /// (foreground ou background) — nunca repete o [linkInicial] já
  /// consumido no cold start (garantia do próprio `app_links`).
  Stream<Uri> get aoReceberLink => _appLinks.uriLinkStream;
}
