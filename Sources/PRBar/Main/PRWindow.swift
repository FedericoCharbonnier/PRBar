import PRBarCore
import SwiftUI

/// Una ventana con solo el detalle de un PR (spec M.2): sus pestañas y su chat, sin barra lateral ni lista. El modo
/// foco no tiene lista que ocultar: solo abre el chat. El título ("api#317") lo pone `openPRWindow`.
struct PRWindow: View {
    static let size = NSSize(width: 900, height: 760)
    static let minSize = NSSize(width: 640, height: 520)
    @ObservedObject var model: AppModel
    /// La pestaña elegida del PR (la memoria de pestañas es una sola, la de la ventana principal).
    @ObservedObject var state: MainWindowState
    @StateObject private var detail = PRDetailState()
    let prID: String

    init(model: AppModel, prID: String) {
        self.model = model
        state = model.main
        self.prID = prID
    }

    var body: some View {
        // El chat va al lado del detalle en un `HStack` y no como `.inspector`: en una ventana sin `NavigationSplitView`
        // el inspector deja la cabecera del pane debajo de la toolbar unificada.
        HStack(spacing: 0) {
            PRDetailView(model: model, prID: prID, detail: detail, ownsToolbar: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if detail.focus.chatShown && model.chatEnabled, let tab {
                Divider()
                ChatInspector(model: model, prID: prID, tab: tab)
                    .frame(width: Theme.MainLayout.inspectorWidth)
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }

    private var tab: PRTab? {
        model.tabContext(prID: prID).map { state.nav.tab(for: prID, context: $0) }
    }
}
