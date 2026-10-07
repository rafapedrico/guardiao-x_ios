import AVFoundation
import Flutter
import UIKit
import WidgetKit
#if canImport(AlarmKit)
import ActivityKit
import AlarmKit
import AppIntents
#endif

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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Despertador") {
      DespertadorPlugin.register(with: registrar)
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

/// Canal "guardiaox/despertador" (ver lib/services/despertador_ios_service.dart):
///   - AlarmKit (iOS 26+): um alarme do sistema por ocorrência do
///     despertador, com o som escolhido em Configurações, tocando mesmo no
///     silencioso. O botão secundário ("Desativar despertador") abre o app
///     direto na tela do despertador com o teclado do PIN
///     ([AbrirDespertadorIntent]); parar o som pelo sistema NÃO cancela o
///     alerta — só o PIN correto, no app.
///   - `prepararSom`: converte o .mp3 do som escolhido (asset do Flutter)
///     num .caf em Library/Sounds — é de lá que o iOS toca o som das
///     notificações e dos alarmes do AlarmKit.
///   - `fusoHorario`: identificador do fuso local, para os gatilhos.
///   - `consumirAbertura`: ocorrência que abriu o app pelo botão do alarme.
///   - `definirJanelasLocalizacao`: janelas (2 h antes até o fim da
///     tolerância) em que o rastreamento nativo grava a posição também no
///     documento do despertador (ver RastreamentoContinuo.swift).
final class DespertadorPlugin: NSObject, FlutterPlugin {
  static let chaveAberturaPendente = "gx_despertador_abertura_pendente"
  static let chaveJanelas = "gx_despertador_janelas"
  private static weak var instanciaAtual: DespertadorPlugin?
  private var canal: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instancia = DespertadorPlugin()
    let canal = FlutterMethodChannel(name: "guardiaox/despertador", binaryMessenger: registrar.messenger())
    instancia.canal = canal
    canal.setMethodCallHandler { [weak instancia] chamada, resultado in
      guard let instancia = instancia else {
        resultado(nil)
        return
      }
      instancia.tratar(chamada, resultado: resultado)
    }
    instanciaAtual = instancia
    registrar.publish(instancia)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    canal?.setMethodCallHandler(nil)
    canal = nil
  }

  /// Toque no botão secundário do alarme: guarda a ocorrência (o app pode
  /// estar abrindo agora) e avisa o Dart se ele já estiver rodando.
  static func registrarAbertura(idAlarme: Int, ciclo: Int) {
    UserDefaults.standard.set(["idAlarme": idAlarme, "ciclo": ciclo], forKey: chaveAberturaPendente)
    instanciaAtual?.canal?.invokeMethod("aberturaPorAlarme", arguments: nil)
  }

  private func tratar(_ chamada: FlutterMethodCall, resultado: @escaping FlutterResult) {
    let argumentos = chamada.arguments as? [String: Any] ?? [:]
    switch chamada.method {
    case "fusoHorario":
      resultado(TimeZone.current.identifier)
    case "prepararSom":
      guard let asset = argumentos["asset"] as? String else {
        resultado(nil)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let nome = Self.prepararSom(asset: asset)
        DispatchQueue.main.async { resultado(nome) }
      }
    case "consumirAbertura":
      let pendente = UserDefaults.standard.dictionary(forKey: Self.chaveAberturaPendente)
      UserDefaults.standard.removeObject(forKey: Self.chaveAberturaPendente)
      resultado(pendente)
    case "definirJanelasLocalizacao":
      UserDefaults.standard.set(argumentos["janelas"] as? [[String: Any]] ?? [], forKey: Self.chaveJanelas)
      resultado(nil)
    case "alarmKitDisponivel":
      resultado(Self.alarmKitDisponivel())
    case "pedirAutorizacaoAlarmKit":
      Self.pedirAutorizacao { resultado($0) }
    case "agendarAlarmes":
      let alarmes = argumentos["alarmes"] as? [[String: Any]] ?? []
      Self.agendar(alarmes, textoParar: argumentos["textoParar"] as? String ?? "Parar",
                   textoAbrir: argumentos["textoAbrir"] as? String ?? "Desativar despertador") { resultado($0) }
    case "pararAlarme":
      Self.parar(uuid: argumentos["uuid"] as? String)
      resultado(nil)
    default:
      resultado(FlutterMethodNotImplemented)
    }
  }

  // MARK: Som

  /// Converte o asset .mp3 em .caf (PCM, até 29 s — o limite de som de
  /// notificação é 30 s) em Library/Sounds. Devolve o nome do arquivo.
  private static func prepararSom(asset: String) -> String? {
    let chave = FlutterDartProject.lookupKey(forAsset: asset)
    guard let origem = Bundle.main.path(forResource: chave, ofType: nil) else { return nil }
    let base = ((asset as NSString).lastPathComponent as NSString).deletingPathExtension
    let nome = "gx_\(base).caf"
    let gerenciador = FileManager.default
    guard let biblioteca = gerenciador.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
    let pasta = biblioteca.appendingPathComponent("Sounds", isDirectory: true)
    let destino = pasta.appendingPathComponent(nome)
    if gerenciador.fileExists(atPath: destino.path) { return nome }
    do {
      try gerenciador.createDirectory(at: pasta, withIntermediateDirectories: true)
      let entrada = try AVAudioFile(forReading: URL(fileURLWithPath: origem))
      let formato = entrada.processingFormat
      let configuracao: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: formato.sampleRate,
        AVNumberOfChannelsKey: formato.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
      let temporario = pasta.appendingPathComponent("tmp_\(nome)")
      try? gerenciador.removeItem(at: temporario)
      let saida = try AVAudioFile(
        forWriting: temporario, settings: configuracao, commonFormat: formato.commonFormat,
        interleaved: formato.isInterleaved)
      let limite = AVAudioFramePosition(formato.sampleRate * 29)
      let capacidade: AVAudioFrameCount = 8192
      while entrada.framePosition < min(entrada.length, limite) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: capacidade) else { break }
        try entrada.read(into: buffer, frameCount: capacidade)
        if buffer.frameLength == 0 { break }
        try saida.write(from: buffer)
      }
      try gerenciador.moveItem(at: temporario, to: destino)
      return nome
    } catch {
      NSLog("[Despertador] Falha ao preparar o som \(asset): \(error)")
      return nil
    }
  }

  // MARK: AlarmKit

  private static func alarmKitDisponivel() -> Bool {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      return AlarmManager.shared.authorizationState != .denied
    }
    #endif
    return false
  }

  private static func pedirAutorizacao(_ conclusao: @escaping (Bool) -> Void) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      Task {
        let estado = (try? await AlarmManager.shared.requestAuthorization()) ?? AlarmManager.shared.authorizationState
        await MainActor.run { conclusao(estado == .authorized) }
      }
      return
    }
    #endif
    conclusao(false)
  }

  /// Substitui todos os alarmes do app pelos de [alarmes] (uuid, epochMs,
  /// titulo, som, idAlarme, ciclo). Devolve quantos foram agendados, ou -1
  /// se o AlarmKit não estiver disponível/autorizado.
  private static func agendar(_ alarmes: [[String: Any]], textoParar: String, textoAbrir: String,
                              conclusao: @escaping (Int) -> Void) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *) {
      Task {
        let gerente = AlarmManager.shared
        guard gerente.authorizationState == .authorized else {
          await MainActor.run { conclusao(-1) }
          return
        }
        let desejados = Set(alarmes.compactMap { ($0["uuid"] as? String).flatMap(UUID.init(uuidString:)) })
        for existente in (try? gerente.alarms) ?? [] where !desejados.contains(existente.id) {
          try? gerente.cancel(id: existente.id)
        }
        let jaAgendados = Set(((try? gerente.alarms) ?? []).map(\.id))
        var agendados = 0
        for dados in alarmes {
          guard let texto = dados["uuid"] as? String, let id = UUID(uuidString: texto),
                let epochMs = (dados["epochMs"] as? NSNumber)?.int64Value,
                let idAlarme = dados["idAlarme"] as? Int,
                let ciclo = (dados["ciclo"] as? NSNumber)?.int64Value else { continue }
          if jaAgendados.contains(id) {
            agendados += 1
            continue
          }
          let data = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
          guard data > Date() else { continue }
          let alerta = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: dados["titulo"] as? String ?? "Guardião-X"),
            stopButton: AlarmButton(
              text: LocalizedStringResource(stringLiteral: textoParar), textColor: .white,
              systemImageName: "stop.circle"),
            secondaryButton: AlarmButton(
              text: LocalizedStringResource(stringLiteral: textoAbrir), textColor: .white,
              systemImageName: "lock.open"),
            secondaryButtonBehavior: .custom)
          let atributos = AlarmAttributes<MetadadosDespertador>(
            presentation: AlarmPresentation(alert: alerta),
            metadata: MetadadosDespertador(idAlarme: idAlarme, ciclo: Int(ciclo)),
            tintColor: .red)
          let som: AlertConfiguration.AlertSound
          if let nome = dados["som"] as? String, !nome.isEmpty {
            som = .named(nome)
          } else {
            som = .default
          }
          let configuracao = AlarmManager.AlarmConfiguration<MetadadosDespertador>(
            schedule: .fixed(data),
            attributes: atributos,
            secondaryIntent: AbrirDespertadorIntent(idAlarme: idAlarme, ciclo: Int(ciclo)),
            sound: som)
          do {
            _ = try await gerente.schedule(id: id, configuration: configuracao)
            agendados += 1
          } catch {
            NSLog("[Despertador] Falha ao agendar o alarme \(texto): \(error)")
          }
        }
        await MainActor.run { conclusao(agendados) }
      }
      return
    }
    #endif
    conclusao(-1)
  }

  /// Para o toque do alarme do sistema desta ocorrência (o app assumiu o
  /// som na própria tela). Não resolve nada: só o PIN resolve.
  private static func parar(uuid: String?) {
    #if canImport(AlarmKit)
    if #available(iOS 26.0, *), let texto = uuid, let id = UUID(uuidString: texto) {
      try? AlarmManager.shared.stop(id: id)
    }
    #endif
  }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct MetadadosDespertador: AlarmMetadata {
  var idAlarme: Int
  var ciclo: Int
}

/// Botão secundário do alarme ("Desativar despertador"): abre o app direto
/// na tela do despertador, com o teclado do PIN.
@available(iOS 26.0, *)
struct AbrirDespertadorIntent: LiveActivityIntent {
  static var title: LocalizedStringResource = "Desativar despertador"
  static var openAppWhenRun: Bool = true
  static var isDiscoverable: Bool = false

  @Parameter(title: "Alarme")
  var idAlarme: Int

  @Parameter(title: "Ocorrência")
  var ciclo: Int

  init() {}

  init(idAlarme: Int, ciclo: Int) {
    self.idAlarme = idAlarme
    self.ciclo = ciclo
  }

  func perform() async throws -> some IntentResult {
    let id = idAlarme
    let ocorrencia = ciclo
    await MainActor.run { DespertadorPlugin.registrarAbertura(idAlarme: id, ciclo: ocorrencia) }
    return .result()
  }
}
#endif
