import Flutter
import UIKit
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Rastreamento contínuo do Monitoramento (RastreamentoContinuo.swift):
    // precisa ser recriado aqui — inclusive quando o iOS relança o app em
    // segundo plano por um evento de localização (cerca, visit, mudança
    // significativa), sem cena e sem Flutter.
    RastreamentoContinuo.shared.retomarNoLancamento(launchOptions)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    // Best-effort: o iOS nem sempre chama isto quando o usuário encerra o
    // app pelo seletor. A cerca continua relançando o app de todo modo.
    RastreamentoContinuo.shared.aoEncerrarApp()
    super.applicationWillTerminate(application)
  }

  /// Pedido de posição sob demanda (push silencioso `pedido_localizacao`
  /// da function `pedirLocalizacaoAtual`): respondido aqui, sem Dart.
  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    if userInfo["tipo"] as? String == "pedido_localizacao" {
      RastreamentoContinuo.shared.atenderPedido(origemPush: userInfo["origem"] as? String) { ok in
        completionHandler(ok ? .newData : .failed)
      }
      return
    }
    super.application(
      application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
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
    // Universal Link de indicação capturado no SceneDelegate (ver SceneDelegate.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "IndicacaoLink") {
      IndicacaoLinkPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Rastreamento") {
      RastreamentoPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SosDispatch") {
      SosDispatchPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ProtecaoArquivo") {
      ProtecaoArquivoPlugin.register(with: registrar)
    }
  }
}

/// Canal "com.example.security_check_app/sos_dispatch" (ver
/// lib/services/sos_dispatch_native_service.dart): no Android é o
/// Foreground Service do envio do SOS; aqui é uma background task do iOS
/// (`beginBackgroundTask`), que dá ao app tempo extra para terminar o envio
/// da localização e da foto se ele for para o segundo plano no meio. Envios
/// simultâneos (localização e foto) dividem a mesma task: ela termina
/// quando o último `parar` chega, ou quando o iOS avisa que o tempo acabou.
final class SosDispatchPlugin: NSObject, FlutterPlugin {
  private var canal: FlutterMethodChannel?
  private var tarefa: UIBackgroundTaskIdentifier = .invalid
  private var envios = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let instancia = SosDispatchPlugin()
    let canal = FlutterMethodChannel(
      name: "com.example.security_check_app/sos_dispatch", binaryMessenger: registrar.messenger())
    instancia.canal = canal
    canal.setMethodCallHandler { [weak instancia] chamada, resultado in
      guard let instancia = instancia else {
        resultado(nil)
        return
      }
      switch chamada.method {
      case "iniciar":
        instancia.iniciar()
        resultado(nil)
      case "parar":
        instancia.parar()
        resultado(nil)
      default:
        resultado(FlutterMethodNotImplemented)
      }
    }
    registrar.publish(instancia)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    canal?.setMethodCallHandler(nil)
    canal = nil
    encerrarTarefa()
  }

  private func iniciar() {
    envios += 1
    guard tarefa == .invalid else { return }
    tarefa = UIApplication.shared.beginBackgroundTask(withName: "envio_sos") { [weak self] in
      self?.encerrarTarefa()
    }
  }

  private func parar() {
    envios = max(0, envios - 1)
    if envios == 0 { encerrarTarefa() }
  }

  private func encerrarTarefa() {
    envios = 0
    guard tarefa != .invalid else { return }
    UIApplication.shared.endBackgroundTask(tarefa)
    tarefa = .invalid
  }
}

/// Canal "guardiaox/protecao_arquivo" (ver
/// lib/services/protecao_arquivo_service.dart): aplica
/// `FileProtectionType.complete` aos arquivos sensíveis (banco SQLite com o
/// PIN e o histórico de alertas, cópias das fotos do SOS). Caminhos que não
/// existem são ignorados; para uma pasta, os arquivos criados nela depois
/// herdam a mesma proteção.
final class ProtecaoArquivoPlugin: NSObject, FlutterPlugin {
  private var canal: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instancia = ProtecaoArquivoPlugin()
    let canal = FlutterMethodChannel(
      name: "guardiaox/protecao_arquivo", binaryMessenger: registrar.messenger())
    instancia.canal = canal
    canal.setMethodCallHandler { chamada, resultado in
      guard chamada.method == "proteger",
            let argumentos = chamada.arguments as? [String: Any],
            let caminhos = argumentos["caminhos"] as? [String] else {
        resultado(FlutterMethodNotImplemented)
        return
      }
      let gerenciador = FileManager.default
      var falhas: [String] = []
      for caminho in caminhos where gerenciador.fileExists(atPath: caminho) {
        do {
          try gerenciador.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: caminho)
        } catch {
          falhas.append(caminho)
        }
      }
      resultado(falhas.isEmpty ? nil : FlutterError(
        code: "falha_protecao", message: "Sem proteção: \(falhas.joined(separator: ", "))", details: nil))
    }
    registrar.publish(instancia)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    canal?.setMethodCallHandler(nil)
    canal = nil
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
