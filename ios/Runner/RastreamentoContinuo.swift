import CoreLocation
import CoreMotion
import FirebaseAuth
import FirebaseCore
import Flutter
import UIKit
import UserNotifications

// Rastreamento contínuo da aba Monitoramento ("localização quase
// permanente"), 100% nativo: quando o iOS relança o app em segundo plano por
// um evento de localização, a cena não é conectada e o Flutter não sobe —
// tudo aqui roda sem Dart.
//
// Base (sempre ligada enquanto ativo, custo quase zero): cerca de 150 m em
// volta da última posição + mudanças significativas + visits. Os três
// relançam o app mesmo depois de encerrado pelo usuário (exige "Sempre" e a
// Atualização em 2º plano ligada).
//
// Movimento: rajada de GPS (iOS 17+: CLLocationUpdate.liveUpdates +
// CLBackgroundActivitySession; iOS 18+: também CLServiceSession; iOS 15–16:
// startUpdatingLocation), aberta pelo Core Motion (início de movimento) ou
// por um evento da base, encerrada por "parado", pelo limite de 10 min ou
// pelo teto diário de ~2 h.
//
// Limites: grava no máximo 1x/min, e só se andou ≥ 100 m ou passaram 15 min;
// sem rajada em Modo Pouca Energia ou bateria < 20%.
//
// O Dart liga/desliga ([configurar]) e passa o ciclo do Plano Free; o
// nativo confere sozinho sessão do Firebase Auth, permissão e plano antes de
// qualquer gravação. Gravação pela API REST do Firestore (não pelo SDK):
// o SDK nativo dividiria a instância (e as configurações) com o plugin do
// Flutter.

// MARK: - Configuração (gravada pelo Dart, lida mesmo sem Dart)

struct ConfigRastreamento: Codable {
  var ativo: Bool
  var uid: String
  var isPremium: Bool
  /// Início do ciclo do Plano Free (ms). `nil` = desconhecido (liberado).
  var cicloInicioMs: Double?
  /// Motivo quando `ativo == false` (pausado, sem_monitores…).
  var motivoInativo: String?
  var tituloEncerramento: String
  var textoEncerramento: String
}

// MARK: - Documento de posição (formato ÚNICO, usado também pelo Dart via canal)

enum DocumentoPosicao {
  /// Campos de `usuarios/{uid}/monitoramento/atual`.
  static func camposAtual(
    latitude: Double, longitude: Double, precisao: Double?, origem: String,
    atividade: String?, rastreamentoContinuo: Bool
  ) -> [String: Any] {
    var campos: [String: Any] = [
      "latitude": ["doubleValue": latitude],
      "longitude": ["doubleValue": longitude],
      "origem": ["stringValue": origem],
      "plataforma": ["stringValue": "ios"],
      "rastreamentoContinuo": ["booleanValue": rastreamentoContinuo],
    ]
    if let precisao = precisao { campos["precisao"] = ["doubleValue": precisao] }
    if let atividade = atividade { campos["atividade"] = ["stringValue": atividade] }
    return campos
  }

  /// Campos espelhados em `usuarios/{uid}` (usados pela Cloud Function do
  /// SOS/PIN incorreto como "última posição conhecida").
  static func camposUsuario(latitude: Double, longitude: Double) -> [String: Any] {
    return [
      "latitude": ["doubleValue": latitude],
      "longitude": ["doubleValue": longitude],
    ]
  }
}

// MARK: - Diagnóstico (tela Diagnóstico → Localização)

struct EventoLocalizacao: Codable {
  let ts: Double
  let origem: String
  let atividade: String?
  let gravou: Bool
  let motivo: String
  let latitude: Double?
  let longitude: Double?
  let precisao: Double?
}

// MARK: - Serviço

final class RastreamentoContinuo: NSObject, CLLocationManagerDelegate {
  static let shared = RastreamentoContinuo()

  private enum Chave {
    static let config = "gx_rastreamento_config"
    static let eventos = "gx_rastreamento_eventos"
    static let ultimaGravacao = "gx_rastreamento_ultima_gravacao"
    static let rajadaDia = "gx_rastreamento_rajada_dia"
    static let rajadaSegundos = "gx_rastreamento_rajada_segundos"
    static let estadoAssinatura = "gx_rastreamento_estado_assinatura"
  }

  private static let idCerca = "gx_cerca_dinamica"
  private static let raioCerca: CLLocationDistance = 150
  private static let intervaloMinimoGravacao: TimeInterval = 60
  private static let distanciaMinimaGravacao: CLLocationDistance = 100
  private static let intervaloMaximoSemGravar: TimeInterval = 15 * 60
  private static let duracaoMaximaRajada: TimeInterval = 10 * 60
  private static let tetoDiarioRajada: TimeInterval = 2 * 60 * 60
  private static let paradoParaEncerrar: TimeInterval = 2 * 60
  private static let maxEventos = 200

  private let gerente = CLLocationManager()
  private let movimento = CMMotionActivityManager()
  private let defaults = UserDefaults.standard

  private var config: ConfigRastreamento?
  private var monitoresAtivos = false
  private var atividadeAtual: String?

  // Rajada.
  private var rajadaInicio: Date?
  private var rajadaFim: Date?
  private var timerRajada: Timer?
  private var timerParado: Timer?
  private var rajadaFallbackLigado = false
  private var tarefaRajada: Any?  // Task (iOS 17+)
  private var sessaoSegundoPlano: Any?  // CLBackgroundActivitySession (iOS 17+)
  private var sessaoServico: Any?  // CLServiceSession (iOS 18+)
  private var ultimaPosicaoRajada: CLLocation?
  private var rajadaRecebeuAtualizacao = false

  // Leituras avulsas (requestLocation) pendentes: origem + conclusão.
  private var origemLeituraAvulsa: String?
  private var conclusoesLeitura: [(Bool) -> Void] = []

  private override init() {
    super.init()
    gerente.delegate = self
    gerente.desiredAccuracy = kCLLocationAccuracyHundredMeters
    gerente.pausesLocationUpdatesAutomatically = true
    UIDevice.current.isBatteryMonitoringEnabled = true
    config = carregarConfig()
  }

  // MARK: Entrada (AppDelegate / canal)

  /// Chamado em `didFinishLaunching` — inclusive quando o iOS relança o app
  /// em segundo plano por um evento de localização: recriar o gerente com o
  /// delegate é o que faz o evento pendente ser entregue.
  func retomarNoLancamento(_ opcoes: [UIApplication.LaunchOptionsKey: Any]?) {
    if opcoes?[.location] != nil {
      registrar(origem: "relancamento", gravou: false, motivo: "app relançado por evento de localização")
    }
    aplicar()
  }

  func configurar(_ novo: ConfigRastreamento) {
    config = novo
    salvarConfig(novo)
    aplicar()
  }

  /// Para tudo e limpa as cercas. [desativar] também apaga o "ativo" da
  /// configuração (sair da conta, conta excluída, sessão revogada).
  func parar(motivo: String, desativar: Bool, conclusao: (() -> Void)? = nil) {
    if desativar, var atual = config {
      atual.ativo = false
      atual.motivoInativo = motivo
      config = atual
      salvarConfig(atual)
    }
    pararMonitores(motivo: motivo)
    gravarEstado(forcar: true, conclusao: conclusao)
  }

  func aoEncerrarApp() {
    guard monitoresAtivos, let config = config else { return }
    let conteudo = UNMutableNotificationContent()
    conteudo.title = config.tituloEncerramento
    conteudo.body = config.textoEncerramento
    let gatilho = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "gx_app_encerrado", content: conteudo, trigger: gatilho))
    registrar(origem: "encerramento", gravou: false, motivo: "app encerrado com rastreamento ativo — aviso local agendado")
  }

  /// Pedido sob demanda (push silencioso `pedido_localizacao`).
  func atenderPedido(conclusao: @escaping (Bool) -> Void) {
    guard monitoresAtivos else {
      registrar(origem: "pedido", gravou: false, motivo: "rastreamento contínuo inativo — pedido ignorado")
      conclusao(false)
      return
    }
    lerPosicaoAvulsa(origem: "pedido", conclusao: conclusao)
  }

  /// Gravação pedida pelo Dart (aceite de solicitação, cronômetro, SOS) —
  /// mesmo formato de documento da gravação nativa.
  func gravarPeloApp(latitude: Double, longitude: Double, precisao: Double?, origem: String,
                     conclusao: @escaping (Bool) -> Void) {
    gravarPosicao(
      latitude: latitude, longitude: longitude, precisao: precisao, origem: origem,
      atividade: atividadeAtual, doApp: true
    ) { ok, motivo in
      self.registrar(origem: origem, gravou: ok, motivo: motivo,
                     latitude: latitude, longitude: longitude, precisao: precisao)
      if ok { self.marcarGravacao(latitude: latitude, longitude: longitude) }
      conclusao(ok)
    }
  }

  func pedirPermissaoMovimento(conclusao: @escaping (String) -> Void) {
    guard CMMotionActivityManager.isActivityAvailable() else {
      conclusao("indisponivel")
      return
    }
    // A consulta é o que dispara o pedido de permissão do sistema.
    let agora = Date()
    movimento.queryActivityStarting(from: agora.addingTimeInterval(-60), to: agora, to: .main) { _, _ in
      conclusao(self.statusMovimento())
      self.aplicar()
    }
  }

  func estado() -> [String: Any] {
    var mapa = estadoCampos()
    mapa["atividade"] = nulo(atividadeAtual)
    return mapa
  }

  func eventos() -> [[String: Any]] {
    return carregarEventos().reversed().map { e in
      [
        "ts": e.ts, "origem": e.origem, "atividade": nulo(e.atividade), "gravou": e.gravou,
        "motivo": e.motivo, "latitude": nulo(e.latitude), "longitude": nulo(e.longitude),
        "precisao": nulo(e.precisao),
      ]
    }
  }

  /// Opcional → valor para o canal (NSNull quando ausente).
  private func nulo(_ valor: Any?) -> Any {
    return valor ?? NSNull()
  }

  // MARK: Decisão liga/desliga

  /// Motivo para NÃO rastrear agora (`nil` = pode rastrear).
  private func motivoInativo() -> String? {
    guard let config = config else { return "nao_configurado" }
    if !config.ativo { return config.motivoInativo ?? "desligado" }
    if gerente.authorizationStatus != .authorizedAlways { return "sem_permissao_sempre" }
    if planoBloqueadoAte() != nil { return "plano_free" }
    garantirFirebase()
    if let uid = Auth.auth().currentUser?.uid {
      if uid != config.uid { return "sessao_diferente" }
    } else {
      return "sem_sessao"
    }
    return nil
  }

  private func aplicar() {
    if let motivo = motivoInativo() {
      if motivo == "sessao_diferente" || motivo == "sem_sessao" {
        // Sessão revogada/encerrada sem o Dart ter avisado: desliga de vez.
        if var atual = config, atual.ativo {
          atual.ativo = false
          atual.motivoInativo = motivo
          config = atual
          salvarConfig(atual)
        }
      }
      pararMonitores(motivo: motivo)
    } else {
      iniciarMonitores()
    }
    gravarEstado(forcar: false)
  }

  private func iniciarMonitores() {
    if !monitoresAtivos {
      registrar(origem: "sistema", gravou: false, motivo: "rastreamento contínuo ligado")
    }
    monitoresAtivos = true
    gerente.allowsBackgroundLocationUpdates = true
    gerente.startMonitoringSignificantLocationChanges()
    gerente.startMonitoringVisits()
    if #available(iOS 18.0, *), sessaoServico == nil {
      sessaoServico = CLServiceSession(authorization: .always)
    }
    iniciarMovimento()
    if !gerente.monitoredRegions.contains(where: { $0.identifier == Self.idCerca }) {
      lerPosicaoAvulsa(origem: "cerca_inicial", conclusao: nil)
    }
  }

  private func pararMonitores(motivo: String) {
    let estavamAtivos = monitoresAtivos
    monitoresAtivos = false
    encerrarRajada(motivo: "rastreamento desligado")
    gerente.stopMonitoringSignificantLocationChanges()
    gerente.stopMonitoringVisits()
    for regiao in gerente.monitoredRegions where regiao.identifier.hasPrefix("gx_") {
      gerente.stopMonitoring(for: regiao)
    }
    movimento.stopActivityUpdates()
    timerParado?.invalidate()
    if #available(iOS 18.0, *) {
      (sessaoServico as? CLServiceSession)?.invalidate()
    }
    sessaoServico = nil
    if estavamAtivos {
      registrar(origem: "sistema", gravou: false, motivo: "rastreamento contínuo desligado: \(motivo)")
    }
  }

  // MARK: Plano Free (dias 11–30 do ciclo: desligado)

  private func planoBloqueadoAte() -> Date? {
    guard let config = config, !config.isPremium, let inicioMs = config.cicloInicioMs else { return nil }
    let inicio = Date(timeIntervalSince1970: inicioMs / 1000)
    let dia = Int(Date().timeIntervalSince(inicio) / 86_400) + 1
    guard dia > 10 && dia <= 30 else { return nil }
    return inicio.addingTimeInterval(30 * 86_400)
  }

  // MARK: Core Motion

  private func statusMovimento() -> String {
    guard CMMotionActivityManager.isActivityAvailable() else { return "indisponivel" }
    switch CMMotionActivityManager.authorizationStatus() {
    case .authorized: return "permitido"
    case .denied, .restricted: return "negado"
    case .notDetermined: return "nao_determinado"
    @unknown default: return "nao_determinado"
    }
  }

  private func iniciarMovimento() {
    // Só com a permissão JÁ concedida (pedida na tela explicativa): nunca
    // dispara o pedido do sistema por aqui.
    guard statusMovimento() == "permitido" else { return }
    movimento.startActivityUpdates(to: .main) { [weak self] atividade in
      guard let self = self, let atividade = atividade, atividade.confidence != .low else { return }
      self.aoMudarAtividade(Self.tipo(de: atividade))
    }
  }

  private static func tipo(de atividade: CMMotionActivity) -> String {
    if atividade.automotive { return "veiculo" }
    if atividade.cycling { return "bicicleta" }
    if atividade.running { return "corrida" }
    if atividade.walking { return "a_pe" }
    if atividade.stationary { return "parado" }
    return "desconhecida"
  }

  private func aoMudarAtividade(_ tipo: String) {
    guard tipo != atividadeAtual else { return }
    atividadeAtual = tipo
    guard monitoresAtivos else { return }
    switch tipo {
    case "parado":
      // Sinal fechado/fila não encerra: precisa ficar parado por 2 min.
      timerParado?.invalidate()
      timerParado = Timer.scheduledTimer(withTimeInterval: Self.paradoParaEncerrar, repeats: false) { [weak self] _ in
        self?.encerrarRajada(motivo: "parado (Core Motion)")
      }
    case "desconhecida":
      break
    default:
      timerParado?.invalidate()
      if rajadaInicio == nil {
        abrirRajada(origem: "movimento")
      } else {
        ajustarRajadaAoTipo()
      }
    }
  }

  /// Relançado por cerca/visit/significativa: estava em movimento?
  /// Sem Core Motion, o próprio evento conta como movimento.
  private func verificarMovimentoEAbrirRajada(origem: String) {
    guard statusMovimento() == "permitido" else {
      abrirRajada(origem: origem)
      return
    }
    let agora = Date()
    movimento.queryActivityStarting(from: agora.addingTimeInterval(-5 * 60), to: agora, to: .main) { [weak self] lista, _ in
      guard let self = self else { return }
      let ultima = lista?.last(where: { $0.confidence != .low })
      let tipo = ultima.map(Self.tipo(de:)) ?? "desconhecida"
      self.atividadeAtual = tipo
      if tipo == "parado" {
        self.registrar(origem: origem, gravou: false, motivo: "histórico de movimento: parado — sem rajada")
      } else {
        self.abrirRajada(origem: origem)
      }
    }
  }

  // MARK: Rajada

  private var distanciaPorTipo: CLLocationDistance {
    switch atividadeAtual {
    case "veiculo": return 50
    case "bicicleta": return 75
    case "a_pe", "corrida": return 100
    default: return 75
    }
  }

  private func motivoSemRajada() -> String? {
    if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Modo Pouca Energia" }
    let bateria = UIDevice.current.batteryLevel
    if bateria >= 0 && bateria < 0.2 { return "bateria abaixo de 20%" }
    if segundosRajadaHoje() >= Self.tetoDiarioRajada { return "teto diário de ~2 h atingido" }
    return nil
  }

  private func abrirRajada(origem: String) {
    guard monitoresAtivos, rajadaInicio == nil else { return }
    if let motivo = motivoSemRajada() {
      registrar(origem: origem, gravou: false, motivo: "sem rajada: \(motivo)")
      return
    }
    let restante = Self.tetoDiarioRajada - segundosRajadaHoje()
    let duracao = min(Self.duracaoMaximaRajada, restante)
    rajadaInicio = Date()
    rajadaFim = Date().addingTimeInterval(duracao)
    ultimaPosicaoRajada = nil
    registrar(origem: origem, gravou: false,
              motivo: "rajada aberta (\(Int(duracao / 60)) min, filtro \(Int(distanciaPorTipo)) m)")
    timerRajada?.invalidate()
    timerRajada = Timer.scheduledTimer(withTimeInterval: duracao, repeats: false) { [weak self] _ in
      self?.encerrarRajada(motivo: "limite de tempo")
    }

    if #available(iOS 17.0, *) {
      abrirRajadaLiveUpdates()
    } else {
      ligarFallbackRajada()
    }
  }

  @available(iOS 17.0, *)
  private func abrirRajadaLiveUpdates() {
    sessaoSegundoPlano = CLBackgroundActivitySession()
    let configuracao: CLLocationUpdate.LiveConfiguration
    switch atividadeAtual {
    case "veiculo": configuracao = .automotiveNavigation
    case "a_pe", "corrida", "bicicleta": configuracao = .fitness
    default: configuracao = .otherNavigation
    }
    rajadaRecebeuAtualizacao = false
    tarefaRajada = Task { @MainActor [weak self] in
      do {
        var paradoDesde: Date?
        for try await atualizacao in CLLocationUpdate.liveUpdates(configuracao) {
          guard let self = self, self.rajadaInicio != nil else { break }
          self.rajadaRecebeuAtualizacao = true
          if let local = atualizacao.location {
            self.ultimaPosicaoRajada = local
            self.processar(local, origem: "rajada")
          }
          if atualizacao.isStationary {
            paradoDesde = paradoDesde ?? Date()
            if Date().timeIntervalSince(paradoDesde!) >= Self.paradoParaEncerrar {
              self.encerrarRajada(motivo: "parado (liveUpdates)")
              break
            }
          } else {
            paradoDesde = nil
          }
        }
      } catch {
        self?.registrar(origem: "rajada", gravou: false, motivo: "liveUpdates falhou: \(error.localizedDescription)")
      }
    }
    // Rede de segurança: aberta em segundo plano, a sessão pode não valer
    // — sem nenhuma atualização em 20 s, cai no startUpdatingLocation.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      guard let self = self, self.rajadaInicio != nil, !self.rajadaRecebeuAtualizacao else { return }
      self.registrar(origem: "rajada", gravou: false, motivo: "liveUpdates sem resposta em 20 s — fallback startUpdatingLocation")
      self.ligarFallbackRajada()
    }
  }

  private func ligarFallbackRajada() {
    rajadaFallbackLigado = true
    gerente.desiredAccuracy = kCLLocationAccuracyHundredMeters
    gerente.distanceFilter = distanciaPorTipo
    gerente.activityType = atividadeAtual == "veiculo" ? .automotiveNavigation : .otherNavigation
    gerente.startUpdatingLocation()
  }

  private func ajustarRajadaAoTipo() {
    guard rajadaFallbackLigado else { return }
    gerente.distanceFilter = distanciaPorTipo
    gerente.activityType = atividadeAtual == "veiculo" ? .automotiveNavigation : .otherNavigation
  }

  private func encerrarRajada(motivo: String) {
    guard let inicio = rajadaInicio else { return }
    rajadaInicio = nil
    rajadaFim = nil
    timerRajada?.invalidate()
    timerParado?.invalidate()
    if #available(iOS 17.0, *) {
      (tarefaRajada as? Task<Void, Never>)?.cancel()
      (sessaoSegundoPlano as? CLBackgroundActivitySession)?.invalidate()
    }
    tarefaRajada = nil
    sessaoSegundoPlano = nil
    if rajadaFallbackLigado {
      gerente.stopUpdatingLocation()
      rajadaFallbackLigado = false
    }
    somarSegundosRajada(Date().timeIntervalSince(inicio))
    registrar(origem: "rajada", gravou: false, motivo: "rajada encerrada: \(motivo)")
    if let ultima = ultimaPosicaoRajada ?? gerente.location {
      redesenharCerca(em: ultima)
    }
  }

  // MARK: Leituras e gravação

  private func lerPosicaoAvulsa(origem: String, conclusao: ((Bool) -> Void)?) {
    origemLeituraAvulsa = origem
    if let conclusao = conclusao { conclusoesLeitura.append(conclusao) }
    gerente.requestLocation()
    // requestLocation pode levar até ~10 s; o push silencioso tem ~30 s.
    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
      self?.concluirLeituras(false)
    }
  }

  private func concluirLeituras(_ ok: Bool) {
    let pendentes = conclusoesLeitura
    conclusoesLeitura.removeAll()
    pendentes.forEach { $0(ok) }
  }

  /// Decide se grava (limites de frequência) e grava.
  private func processar(_ local: CLLocation, origem: String, forcar: Bool = false) {
    guard local.horizontalAccuracy >= 0, local.horizontalAccuracy <= 1500 else {
      registrar(origem: origem, gravou: false, motivo: "precisão ruim (\(Int(local.horizontalAccuracy)) m)",
                local: local)
      if forcar { concluirLeituras(false) }
      return
    }
    guard monitoresAtivos || forcar else { return }

    if let motivo = motivoParaNaoGravar(local, forcar: forcar) {
      registrar(origem: origem, gravou: false, motivo: motivo, local: local)
      if forcar { concluirLeituras(true) }
      return
    }
    marcarGravacao(latitude: local.coordinate.latitude, longitude: local.coordinate.longitude)
    let tarefa = UIApplication.shared.beginBackgroundTask(withName: "gx_gravar_posicao", expirationHandler: nil)
    gravarPosicao(
      latitude: local.coordinate.latitude, longitude: local.coordinate.longitude,
      precisao: local.horizontalAccuracy, origem: origem, atividade: atividadeAtual
    ) { ok, motivo in
      self.registrar(origem: origem, gravou: ok, motivo: motivo, local: local)
      if !ok { self.desmarcarGravacao() }
      if forcar { self.concluirLeituras(ok) }
      if tarefa != .invalid { UIApplication.shared.endBackgroundTask(tarefa) }
    }
  }

  private func motivoParaNaoGravar(_ local: CLLocation, forcar: Bool) -> String? {
    guard let ultima = defaults.dictionary(forKey: Chave.ultimaGravacao),
      let ts = ultima["ts"] as? Double, let lat = ultima["lat"] as? Double, let lng = ultima["lng"] as? Double
    else { return nil }
    let decorrido = Date().timeIntervalSince1970 - ts
    if forcar { return decorrido < 20 ? "gravado há menos de 20 s" : nil }
    if decorrido < Self.intervaloMinimoGravacao { return "intervalo mínimo de 1 min" }
    let distancia = local.distance(from: CLLocation(latitude: lat, longitude: lng))
    if distancia < Self.distanciaMinimaGravacao && decorrido < Self.intervaloMaximoSemGravar {
      return "andou \(Int(distancia)) m (< 100 m) e gravou há \(Int(decorrido / 60)) min"
    }
    return nil
  }

  private func marcarGravacao(latitude: Double, longitude: Double) {
    defaults.set(["ts": Date().timeIntervalSince1970, "lat": latitude, "lng": longitude], forKey: Chave.ultimaGravacao)
  }

  private func desmarcarGravacao() {
    defaults.removeObject(forKey: Chave.ultimaGravacao)
  }

  private func redesenharCerca(em local: CLLocation) {
    guard monitoresAtivos else { return }
    let regiao = CLCircularRegion(center: local.coordinate, radius: Self.raioCerca, identifier: Self.idCerca)
    regiao.notifyOnEntry = false
    regiao.notifyOnExit = true
    gerente.startMonitoring(for: regiao)
  }

  // MARK: CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    aplicar()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let local = locations.last else { return }
    if let origem = origemLeituraAvulsa {
      origemLeituraAvulsa = nil
      processar(local, origem: origem, forcar: origem == "pedido")
      if rajadaInicio == nil { redesenharCerca(em: local) }
      return
    }
    if rajadaFallbackLigado {
      ultimaPosicaoRajada = local
      processar(local, origem: "rajada")
      return
    }
    // Fora de rajada e sem leitura avulsa: mudança significativa.
    processar(local, origem: "significativa")
    redesenharCerca(em: local)
    verificarMovimentoEAbrirRajada(origem: "significativa")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if let erro = error as? CLError, erro.code == .locationUnknown { return }
    registrar(origem: origemLeituraAvulsa ?? "sistema", gravou: false,
              motivo: "erro de localização: \(error.localizedDescription)")
    origemLeituraAvulsa = nil
    concluirLeituras(false)
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard region.identifier == Self.idCerca else { return }
    registrar(origem: "cerca", gravou: false, motivo: "saiu da cerca de 150 m")
    lerPosicaoAvulsa(origem: "cerca", conclusao: nil)
    verificarMovimentoEAbrirRajada(origem: "cerca")
  }

  func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
    registrar(origem: "cerca", gravou: false, motivo: "falha ao monitorar a cerca: \(error.localizedDescription)")
  }

  func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
    let local = CLLocation(
      coordinate: visit.coordinate, altitude: 0, horizontalAccuracy: visit.horizontalAccuracy,
      verticalAccuracy: -1, timestamp: Date())
    if visit.departureDate == Date.distantFuture {
      // Chegou e ficou: grava, redesenha a cerca e encerra a rajada.
      processar(local, origem: "visit")
      encerrarRajada(motivo: "chegada (visit)")
      redesenharCerca(em: local)
    } else {
      registrar(origem: "visit", gravou: false, motivo: "saída de um local (visit)", local: local)
      verificarMovimentoEAbrirRajada(origem: "visit")
    }
  }

  func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
    encerrarRajada(motivo: "pausa automática do iOS")
  }

  // MARK: Firestore (REST)

  private func garantirFirebase() {
    if FirebaseApp.app() == nil {
      FirebaseApp.configure()
    }
  }

  /// [exigirContaConfigurada]: gravações do próprio rastreamento só valem
  /// para a conta que o ligou; as pedidas pelo app usam a sessão atual.
  private func comToken(exigirContaConfigurada: Bool = true,
                        _ acao: @escaping (_ uid: String, _ token: String, _ projeto: String) -> Void,
                        falha: @escaping (String) -> Void) {
    garantirFirebase()
    guard let usuario = Auth.auth().currentUser, let projeto = FirebaseApp.app()?.options.projectID else {
      falha("sem sessão")
      return
    }
    if exigirContaConfigurada, let config = config, config.uid != usuario.uid {
      falha("sessão de outra conta")
      return
    }
    usuario.getIDToken { token, erro in
      guard let token = token else {
        falha("sem token: \(erro?.localizedDescription ?? "?")")
        return
      }
      acao(usuario.uid, token, projeto)
    }
  }

  private func commit(projeto: String, token: String, escritas: [[String: Any]],
                      conclusao: @escaping (Bool, String) -> Void) {
    guard
      let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(projeto)/databases/(default)/documents:commit"),
      let corpo = try? JSONSerialization.data(withJSONObject: ["writes": escritas])
    else {
      conclusao(false, "requisição inválida")
      return
    }
    var requisicao = URLRequest(url: url, timeoutInterval: 20)
    requisicao.httpMethod = "POST"
    requisicao.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    requisicao.setValue("application/json", forHTTPHeaderField: "Content-Type")
    requisicao.httpBody = corpo
    URLSession.shared.dataTask(with: requisicao) { dados, resposta, erro in
      let codigo = (resposta as? HTTPURLResponse)?.statusCode ?? 0
      DispatchQueue.main.async {
        if let erro = erro {
          conclusao(false, "rede: \(erro.localizedDescription)")
        } else if (200..<300).contains(codigo) {
          conclusao(true, "gravado")
        } else {
          let texto = dados.flatMap { String(data: $0, encoding: .utf8) }?.prefix(160) ?? ""
          conclusao(false, "HTTP \(codigo) \(texto)")
        }
      }
    }.resume()
  }

  private func gravarPosicao(latitude: Double, longitude: Double, precisao: Double?, origem: String,
                             atividade: String?, doApp: Bool = false,
                             conclusao: @escaping (Bool, String) -> Void) {
    if !doApp, let ate = planoBloqueadoAte() {
      conclusao(false, "Plano Free bloqueado até \(ate)")
      return
    }
    comToken(exigirContaConfigurada: !doApp, { uid, token, projeto in
      let base = "projects/\(projeto)/databases/(default)/documents/usuarios/\(uid)"
      let horario: [[String: Any]] = [["fieldPath": "atualizadoEm", "setToServerValue": "REQUEST_TIME"]]
      let camposUsuario = DocumentoPosicao.camposUsuario(latitude: latitude, longitude: longitude)
      let escritas: [[String: Any]] = [
        [
          "update": ["name": base, "fields": camposUsuario],
          "updateMask": ["fieldPaths": Array(camposUsuario.keys)],
          "updateTransforms": horario,
        ],
        [
          "update": [
            "name": "\(base)/monitoramento/atual",
            "fields": DocumentoPosicao.camposAtual(
              latitude: latitude, longitude: longitude, precisao: precisao, origem: origem,
              atividade: atividade, rastreamentoContinuo: self.monitoresAtivos),
          ],
          "updateTransforms": horario,
        ],
      ]
      self.commit(projeto: projeto, token: token, escritas: escritas, conclusao: conclusao)
    }, falha: { motivo in
      conclusao(false, motivo)
    })
  }

  // MARK: Estado (usuarios/{uid}/monitoramento/estado)

  private func estadoCampos() -> [String: Any] {
    let permissao: String
    switch gerente.authorizationStatus {
    case .authorizedAlways: permissao = "sempre"
    case .authorizedWhenInUse: permissao = "durante_uso"
    case .denied, .restricted: permissao = "negada"
    default: permissao = "nao_determinada"
    }
    let motivo: Any = nulo(monitoresAtivos ? nil : motivoInativo())
    let bloqueadoAte: Any = nulo(planoBloqueadoAte().map { $0.timeIntervalSince1970 * 1000 })
    return [
      "permissao": permissao,
      "precisaoExata": gerente.accuracyAuthorization == .fullAccuracy,
      "movimento": statusMovimento(),
      "atualizacaoSegundoPlano": UIApplication.shared.backgroundRefreshStatus == .available,
      "modoPoucaEnergia": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "rastreamentoAtivo": monitoresAtivos,
      "motivoInativo": motivo,
      "bloqueadoAte": bloqueadoAte,
    ]
  }

  /// Grava o estado quando muda (ou a cada 6 h). Sem sessão, não grava.
  private func gravarEstado(forcar: Bool, conclusao: (() -> Void)? = nil) {
    // Quem nunca ligou o rastreamento não grava nada (nem configura o
    // Firebase nativo).
    guard config != nil else {
      conclusao?()
      return
    }
    let campos = estadoCampos()
    let assinatura = campos.keys.sorted().map { "\($0)=\(String(describing: campos[$0]!))" }.joined(separator: ";")
    let anterior = defaults.dictionary(forKey: Chave.estadoAssinatura)
    let tsAnterior = anterior?["ts"] as? Double ?? 0
    if !forcar, anterior?["assinatura"] as? String == assinatura,
      Date().timeIntervalSince1970 - tsAnterior < 6 * 3600 {
      conclusao?()
      return
    }
    comToken({ uid, token, projeto in
      var fields: [String: Any] = ["plataforma": ["stringValue": "ios"]]
      for (chave, valor) in campos {
        switch valor {
        case let b as Bool: fields[chave] = ["booleanValue": b]
        case let s as String: fields[chave] = ["stringValue": s]
        case let d as Double:
          let data = Date(timeIntervalSince1970: d / 1000)
          fields[chave] = ["timestampValue": ISO8601DateFormatter().string(from: data)]
        default: fields[chave] = ["nullValue": NSNull()]
        }
      }
      let escrita: [String: Any] = [
        "update": [
          "name": "projects/\(projeto)/databases/(default)/documents/usuarios/\(uid)/monitoramento/estado",
          "fields": fields,
        ],
        "updateTransforms": [["fieldPath": "atualizadoEm", "setToServerValue": "REQUEST_TIME"]],
      ]
      self.commit(projeto: projeto, token: token, escritas: [escrita]) { ok, motivo in
        if ok {
          self.defaults.set(["assinatura": assinatura, "ts": Date().timeIntervalSince1970], forKey: Chave.estadoAssinatura)
        } else {
          self.registrar(origem: "estado", gravou: false, motivo: "estado não gravado: \(motivo)")
        }
        conclusao?()
      }
    }, falha: { _ in conclusao?() })
  }

  // MARK: Persistência local

  private func carregarConfig() -> ConfigRastreamento? {
    guard let dados = defaults.data(forKey: Chave.config) else { return nil }
    return try? JSONDecoder().decode(ConfigRastreamento.self, from: dados)
  }

  private func salvarConfig(_ config: ConfigRastreamento) {
    if let dados = try? JSONEncoder().encode(config) {
      defaults.set(dados, forKey: Chave.config)
    }
  }

  private func hoje() -> String {
    let formato = DateFormatter()
    formato.dateFormat = "yyyy-MM-dd"
    return formato.string(from: Date())
  }

  private func segundosRajadaHoje() -> TimeInterval {
    guard defaults.string(forKey: Chave.rajadaDia) == hoje() else { return 0 }
    return defaults.double(forKey: Chave.rajadaSegundos)
  }

  private func somarSegundosRajada(_ segundos: TimeInterval) {
    let total = segundosRajadaHoje() + max(0, segundos)
    defaults.set(hoje(), forKey: Chave.rajadaDia)
    defaults.set(total, forKey: Chave.rajadaSegundos)
  }

  private func carregarEventos() -> [EventoLocalizacao] {
    guard let dados = defaults.data(forKey: Chave.eventos) else { return [] }
    return (try? JSONDecoder().decode([EventoLocalizacao].self, from: dados)) ?? []
  }

  private func registrar(origem: String, gravou: Bool, motivo: String, local: CLLocation) {
    registrar(origem: origem, gravou: gravou, motivo: motivo, latitude: local.coordinate.latitude,
              longitude: local.coordinate.longitude, precisao: local.horizontalAccuracy)
  }

  private func registrar(origem: String, gravou: Bool, motivo: String, latitude: Double? = nil,
                         longitude: Double? = nil, precisao: Double? = nil) {
    var lista = carregarEventos()
    lista.append(EventoLocalizacao(
      ts: Date().timeIntervalSince1970 * 1000, origem: origem, atividade: atividadeAtual, gravou: gravou,
      motivo: motivo, latitude: latitude, longitude: longitude, precisao: precisao))
    if lista.count > Self.maxEventos { lista.removeFirst(lista.count - Self.maxEventos) }
    if let dados = try? JSONEncoder().encode(lista) {
      defaults.set(dados, forKey: Chave.eventos)
    }
  }
}

// MARK: - Canal "guardiaox/rastreamento" (ver lib/services/rastreamento_continuo_service.dart)

final class RastreamentoPlugin: NSObject, FlutterPlugin {
  private var canal: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instancia = RastreamentoPlugin()
    let canal = FlutterMethodChannel(name: "guardiaox/rastreamento", binaryMessenger: registrar.messenger())
    instancia.canal = canal
    canal.setMethodCallHandler { chamada, resultado in
      instancia.tratar(chamada, resultado: resultado)
    }
    registrar.publish(instancia)
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    canal?.setMethodCallHandler(nil)
    canal = nil
  }

  private func tratar(_ chamada: FlutterMethodCall, resultado: @escaping FlutterResult) {
    let rastreamento = RastreamentoContinuo.shared
    let args = chamada.arguments as? [String: Any] ?? [:]
    switch chamada.method {
    case "configurar":
      guard let uid = args["uid"] as? String else {
        resultado(FlutterError(code: "args", message: "uid ausente", details: nil))
        return
      }
      rastreamento.configurar(ConfigRastreamento(
        ativo: args["ativo"] as? Bool ?? false,
        uid: uid,
        isPremium: args["isPremium"] as? Bool ?? false,
        cicloInicioMs: (args["cicloInicioMs"] as? NSNumber)?.doubleValue,
        motivoInativo: args["motivoInativo"] as? String,
        tituloEncerramento: args["tituloEncerramento"] as? String ?? "Guardião-X",
        textoEncerramento: args["textoEncerramento"] as? String ?? ""))
      resultado(rastreamento.estado())
    case "parar":
      rastreamento.parar(motivo: args["motivo"] as? String ?? "parado", desativar: true) {
        resultado(nil)
      }
    case "estado":
      resultado(rastreamento.estado())
    case "eventos":
      resultado(rastreamento.eventos())
    case "pedirPermissaoMovimento":
      rastreamento.pedirPermissaoMovimento { resultado($0) }
    case "gravarPosicao":
      guard let lat = (args["latitude"] as? NSNumber)?.doubleValue,
        let lng = (args["longitude"] as? NSNumber)?.doubleValue
      else {
        resultado(false)
        return
      }
      rastreamento.gravarPeloApp(
        latitude: lat, longitude: lng, precisao: (args["precisao"] as? NSNumber)?.doubleValue,
        origem: args["origem"] as? String ?? "app"
      ) { resultado($0) }
    default:
      resultado(FlutterMethodNotImplemented)
    }
  }
}
