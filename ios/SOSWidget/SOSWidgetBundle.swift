import SwiftUI
import WidgetKit

/// Ponto de entrada da extensão de Widget — um `WidgetBundle` com um
/// único membro ([SOSWidget]) porque, por enquanto, o "Botão de Pânico
/// Virtual" é o único widget do Guardião-X. Se novos widgets forem
/// adicionados no futuro, entram aqui como membros adicionais do mesmo
/// bundle (a Apple não permite mais de um `@main` por extensão).
@main
struct SOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        SOSWidget()
    }
}
