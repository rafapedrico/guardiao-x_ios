import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SOSWidgetStatus") {
      SOSWidgetStatusPlugin.register(with: registrar)
    }
    // Toque no Widget SOS capturado no SceneDelegate (ver SceneDelegate.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SOSWidgetLink") {
      SOSWidgetLinkPlugin.register(with: registrar)
    }
  }
}

/// Canal "guardiaox/sos_widget" (ver lib/services/sos_widget_status_service.dart):
/// `widgetInstalado` responde se existe algum widget de kind "SOSWidget"
/// (ios/SOSWidget/SOSWidget.swift) na tela de início OU na tela de
/// bloqueio — status real, lido do WidgetCenter, não suposto.
///
/// Plugin de verdade (antes era só um FlutterMethodChannel solto criado no
/// AppDelegate, com registrar sem `publish`): a instância é publicada no
/// registrar, então o engine a mantém viva e chama `detachFromEngine` no
/// encerramento da cena (build 107: crash SIGABRT no teardown do engine).
/// No detach o handler é removido e nenhuma resposta pendente do
/// WidgetCenter é entregue a um engine já destruído.
final class SOSWidgetStatusPlugin: NSObject, FlutterPlugin {
  private var canal: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instancia = SOSWidgetStatusPlugin()
    let canal = FlutterMethodChannel(
      name: "guardiaox/sos_widget", binaryMessenger: registrar.messenger())
    instancia.canal = canal
    canal.setMethodCallHandler { [weak instancia] chamada, resultado in
      guard let instancia = instancia else {
        resultado(nil)
        return
      }
      instancia.tratar(chamada, resultado: resultado)
    }
    registrar.publish(instancia)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    canal?.setMethodCallHandler(nil)
    canal = nil
  }

  private func tratar(_ chamada: FlutterMethodCall, resultado: @escaping FlutterResult) {
    guard chamada.method == "widgetInstalado" else {
      resultado(FlutterMethodNotImplemented)
      return
    }
    WidgetCenter.shared.getCurrentConfigurations { [weak self] consulta in
      let instalado: Bool?
      switch consulta {
      case .success(let widgets):
        instalado = widgets.contains { $0.kind == "SOSWidget" }
      case .failure:
        instalado = nil
      }
      DispatchQueue.main.async {
        // Engine já encerrado (detach): não responde a um canal morto.
        guard self?.canal != nil else { return }
        resultado(instalado)
      }
    }
  }
}
