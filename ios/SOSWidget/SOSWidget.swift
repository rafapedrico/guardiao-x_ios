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

/// ÚNICO gesto possível dentro de um widget — a Apple não permite NENHUM
/// código/lógica rodando aqui, só a UI estática mais um destino de toque.
/// Abre o app pelo URL Scheme registrado em ios/Runner/Info.plist
/// (CFBundleURLTypes → "guardiaox"); o lado Dart resolve esse link em
/// lib/services/sos_deep_link_service.dart (chamado a partir de
/// lib/main.dart) e dispara a sequência unificada de SOS.
private let urlSOS = URL(string: "guardiaox://sos")

/// Imagem oficial do widget (Assets.xcassets → SOSWidgetImage, cópia de
/// 512x512 de ios/SOSWidget/sos_widget.png — widgets têm limite baixo de
/// memória). Exibida EXATAMENTE como é: sem cor, corte ou texto por cima.
struct SOSImagemOficial: View {
    var body: some View {
        #if compiler(>=6.0)
        if #available(iOSApplicationExtension 18.0, *) {
            // Modo "tingido" do iOS 18: mantém as cores originais da imagem.
            Image("SOSWidgetImage")
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fill)
        } else {
            imagemPadrao
        }
        #else
        imagemPadrao
        #endif
    }

    private var imagemPadrao: some View {
        Image("SOSWidgetImage")
            .resizable()
            .aspectRatio(contentMode: .fill)
    }
}

/// Contorno de escudo (mesmo símbolo da imagem oficial, só em traço).
struct EscudoShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        var p = Path()
        p.move(to: CGPoint(x: x + w * 0.5, y: y))
        p.addQuadCurve(to: CGPoint(x: x + w, y: y + h * 0.14),
                       control: CGPoint(x: x + w * 0.78, y: y + h * 0.12))
        p.addLine(to: CGPoint(x: x + w, y: y + h * 0.45))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y + h),
                       control: CGPoint(x: x + w * 0.95, y: y + h * 0.82))
        p.addQuadCurve(to: CGPoint(x: x, y: y + h * 0.45),
                       control: CGPoint(x: x + w * 0.05, y: y + h * 0.82))
        p.addLine(to: CGPoint(x: x, y: y + h * 0.14))
        p.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y),
                       control: CGPoint(x: x + w * 0.22, y: y + h * 0.12))
        p.closeSubpath()
        return p
    }
}

/// Dois arcos de onda concêntricos, abertos para baixo (sinal de alerta).
struct OndasShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for fracao in [0.55, 1.0] {
            let meia = r.width * 0.5 * fracao
            let base = r.maxY
            p.move(to: CGPoint(x: r.midX - meia, y: base))
            p.addQuadCurve(to: CGPoint(x: r.midX + meia, y: base),
                           control: CGPoint(x: r.midX, y: base - r.height * 2.0 * fracao))
        }
        return p
    }
}

/// Tela de bloqueio (.accessoryCircular): monocromática, então nada de
/// imagem colorida — o símbolo é redesenhado em traço branco.
@available(iOSApplicationExtension 16.0, *)
struct SOSTelaBloqueioView: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                EscudoShape()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: s * 0.045, lineJoin: .round))
                    .frame(width: s * 0.62, height: s * 0.72)
                VStack(spacing: s * 0.03) {
                    OndasShape()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
                        .frame(width: s * 0.34, height: s * 0.1)
                    Text(verbatim: "SOS")
                        .font(.system(size: s * 0.2, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .offset(y: s * 0.03)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

struct SOSWidgetEntryView: View {
    var entry: SOSTimelineProvider.Entry

    @Environment(\.widgetFamily) private var familia

    var body: some View {
        conteudo.widgetURL(urlSOS)
    }

    @ViewBuilder
    private var conteudo: some View {
        if #available(iOSApplicationExtension 16.0, *), familia == .accessoryCircular {
            if #available(iOSApplicationExtension 17.0, *) {
                SOSTelaBloqueioView()
                    .containerBackground(for: .widget) { AccessoryWidgetBackground() }
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    SOSTelaBloqueioView()
                }
            }
        } else if #available(iOSApplicationExtension 17.0, *) {
            // iOS 17+: a imagem é o fundo do widget, de borda a borda.
            Color.clear
                .containerBackground(for: .widget) { SOSImagemOficial() }
        } else {
            // iOS 15/16: sem margens de conteúdo — a imagem preenche tudo.
            ZStack {
                SOSImagemOficial()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

struct SOSWidget: Widget {
    /// Também usado pelo app (AppDelegate.swift, canal
    /// "guardiaox/sos_widget") para saber se o widget está instalado.
    let kind: String = "SOSWidget"

    private var familias: [WidgetFamily] {
        if #available(iOSApplicationExtension 16.0, *) {
            return [.systemSmall, .accessoryCircular]
        }
        return [.systemSmall]
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SOSTimelineProvider()) { entry in
            SOSWidgetEntryView(entry: entry)
        }
        // Chaves de SOSWidget/<idioma>.lproj/Localizable.strings (11 idiomas).
        .configurationDisplayName("widget.nome")
        .description("widget.descricao")
        // systemSmall: botão discreto na tela de início; accessoryCircular:
        // tela de bloqueio (iOS 16+).
        .supportedFamilies(familias)
    }
}
