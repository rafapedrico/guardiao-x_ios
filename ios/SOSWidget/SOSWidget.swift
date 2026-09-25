import SwiftUI
import WidgetKit

/// Timeline com uma ÚNICA entrada fixa — este widget não tem nenhum dado
/// dinâmico (nem relógio, nem estado do app): é puramente um atalho
/// estático ("Botão de Pânico Virtual"), então `.never` como política de
/// recarga é suficiente — nunca precisa atualizar sozinho.
struct SOSEntry: TimelineEntry {
    let date: Date = Date()
}

struct SOSTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SOSEntry {
        SOSEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (SOSEntry) -> Void) {
        completion(SOSEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SOSEntry>) -> Void) {
        completion(Timeline(entries: [SOSEntry()], policy: .never))
    }
}

/// Mesmo vermelho de marca da tela de alerta em tela cheia do app (ver
/// `CameraCapturaScreen._buildTelaDissuasao`, `Color(0xFFB71C1C)` no
/// Flutter — Material Red 900). Mantido em sincronia manual: o widget
/// (Swift/WidgetKit) e o app (Dart/Flutter) são bundles/linguagens
/// separados, sem nenhuma forma de compartilhar uma constante de cor
/// diretamente.
private let corAlertaGuardiaoX = Color(red: 0xB7 / 255, green: 0x1C / 255, blue: 0x1C / 255)

struct SOSWidgetEntryView: View {
    var entry: SOSTimelineProvider.Entry

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
            Text("SOS")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ÚNICO gesto possível dentro de um widget — a Apple não permite
        // NENHUM código/lógica rodando aqui, só a UI estática mais um
        // destino de toque. Abre o app através do URL Scheme registrado
        // em ios/Runner/Info.plist (CFBundleURLTypes → "guardiaox"); o
        // lado Dart resolve esse link em
        // lib/services/sos_deep_link_service.dart (chamado a partir de
        // lib/main.dart).
        .widgetURL(URL(string: "guardiaox://sos"))
    }
}

struct SOSWidget: Widget {
    let kind: String = "SOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SOSTimelineProvider()) { entry in
            if #available(iOSApplicationExtension 17.0, *) {
                SOSWidgetEntryView(entry: entry)
                    .containerBackground(corAlertaGuardiaoX, for: .widget)
            } else {
                ZStack {
                    corAlertaGuardiaoX
                    SOSWidgetEntryView(entry: entry)
                }
            }
        }
        .configurationDisplayName("Botão de Pânico")
        .description("Toque para abrir o Guardião-X direto no fluxo de emergência (SOS).")
        // 1x1 apenas — pedido explícito do produto (ver checklist da
        // migração iOS): um "Botão de Pânico Virtual" precisa ser pequeno
        // e discreto na tela de início, não um dashboard.
        .supportedFamilies([.systemSmall])
    }
}
