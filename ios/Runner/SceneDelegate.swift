import Flutter
import UIKit

/// Captura NATIVA do toque no Widget SOS (`guardiaox://sos`, ver
/// ios/SOSWidget/SOSWidget.swift) nos dois pontos em que o iOS entrega a
/// URL com o ciclo de vida UIScene:
///   - `scene(_:willConnectTo:options:)` → `connectionOptions.urlContexts`
///     (app fechado, ou cena descartada pelo sistema em segundo plano);
///   - `scene(_:openURLContexts:)` (app em primeiro ou segundo plano).
///
/// Antes (até o build 109) a URL ia para o `app_links` E para o deep
/// linking do próprio Flutter (`FlutterDeepLinkingEnabled` ausente no
/// Info.plist = ligado): o `app_links` responde "não tratei" por padrão,
/// então o engine também empurrava a URL como rota (`pushRouteInformation`)
/// e o `onGenerateRoute` do app — que devolve a tela inicial para QUALQUER
/// nome — empilhava a splash/login por cima do SOS. Agora o deep linking
/// do Flutter está desligado no Info.plist, o `app_links` saiu do projeto
/// e a URL do SOS é consumida aqui, sem chegar a nenhum plugin.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Antes do super: o toque fica no buffer antes de qualquer código Dart
    // poder perguntar por ele.
    SOSWidgetLinkPlugin.capturar(connectionOptions.urlContexts.map { $0.url })
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    SOSWidgetLinkPlugin.marcarCenaConectada()
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    SOSWidgetLinkPlugin.capturar(URLContexts.map { $0.url })
    // Outros esquemas (retorno do login do Google etc.) seguem para os
    // plugins normalmente.
    let outros = URLContexts.filter { !SOSWidgetLinkPlugin.ehLinkDeSos($0.url) }
    if !outros.isEmpty {
      super.scene(scene, openURLContexts: outros)
    }
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    SOSWidgetLinkPlugin.marcarCenaDesconectada()
    super.sceneDidDisconnect(scene)
  }
}

/// Canais "guardiaox/sos_widget_link" (método) e
/// "guardiaox/sos_widget_link/eventos" (eventos) — ver
/// lib/services/sos_deep_link_service.dart.
///
/// Cada toque vira UM evento com id único, guardado num buffer do PROCESSO
/// (estático: sobrevive à troca de engine quando o iOS descarta e recria a
/// cena) até ser entregue ao Dart por exatamente um destes caminhos:
///   - `consumirAberturaInicial` (chamado pelo `main()` antes do `runApp`):
///     devolve `true` e esvazia o buffer — o primeiro quadro já é a tela
///     preta do SOS;
///   - o stream de eventos: ao começar a ser ouvido, entrega o que estiver
///     no buffer; depois disso, cada toque novo vai direto ao Dart.
/// Um evento nunca é entregue pelos dois caminhos (o buffer é esvaziado na
/// entrega) nem perdido (sem ouvinte, fica no buffer).
final class SOSWidgetLinkPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static var pendentes: [String] = []
  private static var cenaConectada = false
  private static var consultasAguardandoCena: [FlutterResult] = []
  private static weak var ouvinteAtual: SOSWidgetLinkPlugin?

  /// Teto de espera da consulta inicial pela conexão da cena — na prática
  /// a cena já está conectada quando o Dart pergunta.
  private static let esperaMaximaPelaCena: TimeInterval = 1.0

  private var canalMetodos: FlutterMethodChannel?
  private var canalEventos: FlutterEventChannel?
  private var sink: FlutterEventSink?

  static func ehLinkDeSos(_ url: URL) -> Bool {
    return url.scheme?.lowercased() == "guardiaox" && url.host?.lowercased() == "sos"
  }

  static func capturar(_ urls: [URL]) {
    for url in urls where ehLinkDeSos(url) {
      let id = UUID().uuidString
      if let sink = ouvinteAtual?.sink {
        sink(id)
      } else {
        pendentes.append(id)
      }
    }
  }

  static func marcarCenaConectada() {
    cenaConectada = true
    let aguardando = consultasAguardandoCena
    consultasAguardandoCena.removeAll()
    aguardando.forEach(responderConsultaInicial)
  }

  static func marcarCenaDesconectada() {
    cenaConectada = false
  }

  private static func responderConsultaInicial(_ resultado: FlutterResult) {
    let houveToque = !pendentes.isEmpty
    pendentes.removeAll()
    resultado(houveToque)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instancia = SOSWidgetLinkPlugin()
    let metodos = FlutterMethodChannel(
      name: "guardiaox/sos_widget_link", binaryMessenger: registrar.messenger())
    let eventos = FlutterEventChannel(
      name: "guardiaox/sos_widget_link/eventos", binaryMessenger: registrar.messenger())
    instancia.canalMetodos = metodos
    instancia.canalEventos = eventos
    metodos.setMethodCallHandler { chamada, resultado in
      guard chamada.method == "consumirAberturaInicial" else {
        resultado(FlutterMethodNotImplemented)
        return
      }
      if cenaConectada {
        responderConsultaInicial(resultado)
        return
      }
      consultasAguardandoCena.append(resultado)
      DispatchQueue.main.asyncAfter(deadline: .now() + esperaMaximaPelaCena) {
        guard !consultasAguardandoCena.isEmpty else { return }
        let aguardando = consultasAguardandoCena
        consultasAguardandoCena.removeAll()
        aguardando.forEach(responderConsultaInicial)
      }
    }
    eventos.setStreamHandler(instancia)
    // Publicado no registrar (como o SOSWidgetStatusPlugin): o engine
    // mantém a instância viva e chama `detachFromEngine` no encerramento.
    registrar.publish(instancia)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    SOSWidgetLinkPlugin.ouvinteAtual = self
    let entregar = SOSWidgetLinkPlugin.pendentes
    SOSWidgetLinkPlugin.pendentes.removeAll()
    entregar.forEach { events($0) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    sink = nil
    canalMetodos?.setMethodCallHandler(nil)
    canalEventos?.setStreamHandler(nil)
    canalMetodos = nil
    canalEventos = nil
    if SOSWidgetLinkPlugin.ouvinteAtual === self {
      SOSWidgetLinkPlugin.ouvinteAtual = nil
    }
  }
}
