import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ponte entre o Widget SOS do iOS ("Botão de Pânico Virtual",
/// `ios/SOSWidget/`) e o fluxo do SOS ([SosWidgetFluxoService]).
///
/// SUBSTITUTO DE PRODUTO PARA O `volume_sos` NO iOS (ver
/// `docs/migracao-ios-relatorio-2026-09-12.md`, seção 5, item 4): a Apple
/// não deixa nenhum app escutar o botão de volume em segundo plano. O
/// toque no widget abre o app por `guardiaox://sos`.
///
/// A URL é capturada NATIVAMENTE no `SceneDelegate.swift` (nos dois pontos
/// do ciclo UIScene: abertura a frio e app já rodando) e chega aqui por
/// canal próprio — nada de `app_links` nem do deep linking do Flutter (que
/// empilhava a splash/login por cima do SOS; ver o comentário no
/// SceneDelegate). Cada toque é um evento com id único, entregue ao Dart
/// exatamente uma vez:
///   - [consumirAberturaInicial]: chamado pelo `main()` antes do `runApp`,
///     diz se o app foi aberto pelo widget (o primeiro quadro já é a tela
///     preta do SOS);
///   - [aoTocarNoWidget]: cada toque recebido depois disso (app em
///     primeiro/segundo plano). O lado nativo guarda os toques num buffer
///     até este stream ser ouvido.
class SosDeepLinkService {
  SosDeepLinkService._internal();
  static final SosDeepLinkService _instance = SosDeepLinkService._internal();
  factory SosDeepLinkService() => _instance;

  static const MethodChannel _canal = MethodChannel('guardiaox/sos_widget_link');
  static const EventChannel _canalEventos =
      EventChannel('guardiaox/sos_widget_link/eventos');

  /// Teto de espera da consulta inicial — bem acima da espera máxima do
  /// lado nativo (1 s), para a resposta nunca chegar depois de desistirmos.
  static const Duration _tetoConsultaInicial = Duration(seconds: 3);

  final StreamController<String> _toques = StreamController<String>.broadcast();
  final Set<String> _idsJaEntregues = <String>{};
  StreamSubscription<dynamic>? _assinaturaNativa;
  int _contadorTardio = 0;

  /// `true` quando o app foi aberto (a frio) por um toque no widget. O
  /// toque é consumido aqui: não reaparece em [aoTocarNoWidget]. Nunca
  /// lança exceção.
  ///
  /// Se a resposta nativa chegar depois do teto (não deveria), o toque não
  /// se perde: vira um evento em [aoTocarNoWidget].
  Future<bool> consumirAberturaInicial() {
    if (!Platform.isIOS) return Future<bool>.value(false);
    final resultado = Completer<bool>();
    _canal.invokeMethod<bool>('consumirAberturaInicial').then((veioDoWidget) {
      if (!resultado.isCompleted) {
        resultado.complete(veioDoWidget ?? false);
      } else if (veioDoWidget == true) {
        debugPrint('⚠️ [SosDeepLinkService] Abertura pelo widget respondida tarde — tratada como toque.');
        _toques.add('tardio_${_contadorTardio++}');
      }
    }, onError: (Object e) {
      debugPrint('⚠️ [SosDeepLinkService] Falha ao consultar a abertura pelo widget: $e');
      if (!resultado.isCompleted) resultado.complete(false);
    });
    Timer(_tetoConsultaInicial, () {
      if (!resultado.isCompleted) resultado.complete(false);
    });
    return resultado.future;
  }

  /// Cada toque no widget recebido com o app já rodando. Começar a ouvir
  /// libera o buffer nativo — por isso só depois de
  /// [consumirAberturaInicial] (ver `main()`).
  Stream<String> get aoTocarNoWidget {
    if (Platform.isIOS) {
      _assinaturaNativa ??= _canalEventos.receiveBroadcastStream().listen((evento) {
        final id = evento.toString();
        // Defesa extra: o nativo já entrega cada id uma única vez.
        if (!_idsJaEntregues.add(id)) return;
        _toques.add(id);
      }, onError: (Object e) {
        debugPrint('⚠️ [SosDeepLinkService] Erro no canal de toques do widget: $e');
      });
    }
    return _toques.stream;
  }
}
