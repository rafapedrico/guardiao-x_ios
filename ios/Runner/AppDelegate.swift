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
      registrarCanalSosWidget(messenger: registrar.messenger())
    }
  }

  /// Canal "guardiaox/sos_widget" (ver lib/services/sos_widget_status_service.dart):
  /// `widgetInstalado` responde se existe algum widget de kind "SOSWidget"
  /// (ios/SOSWidget/SOSWidget.swift) na tela de início OU na tela de
  /// bloqueio — status real, lido do WidgetCenter, não suposto.
  private func registrarCanalSosWidget(messenger: FlutterBinaryMessenger) {
    let canal = FlutterMethodChannel(name: "guardiaox/sos_widget", binaryMessenger: messenger)
    canal.setMethodCallHandler { chamada, resultado in
      guard chamada.method == "widgetInstalado" else {
        resultado(FlutterMethodNotImplemented)
        return
      }
      WidgetCenter.shared.getCurrentConfigurations { consulta in
        let instalado: Bool?
        switch consulta {
        case .success(let widgets):
          instalado = widgets.contains { $0.kind == "SOSWidget" }
        case .failure:
          instalado = nil
        }
        DispatchQueue.main.async { resultado(instalado) }
      }
    }
  }
}
