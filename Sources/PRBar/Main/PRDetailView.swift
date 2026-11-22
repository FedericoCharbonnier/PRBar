import AppKit
import PRBarCore
import SwiftUI

/// El detalle de un PR con sus pestañas (spec M.1 "Detalle del PR: pestañas"). Lo usan la ventana principal y la de PR;
/// cada una con su `PRDetailState` (modo foco y chat).
struct PRDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    @ObservedObject var prStore: PRStore
    @ObservedObject var detail: PRDetailState
    let prID: String
    /// Pone sus pestañas y el botón del chat en la toolbar (la ventana de PR); en la principal los pone `MainWindow`. El
    /// chat lo pone siempre quien contiene la vista: la principal, a la derecha de lista + detalle (un `.inspector`
    /// adentro de la columna de un `NavigationSplitView` desarma su layout); la de PR, al lado en un `HStack` (un
    /// `.inspector` en una ventana sin split view deja la cabecera del pane debajo de la toolbar).
    let ownsToolbar: Bool

    init(model: AppModel, prID: String, detail: PRDetailState, ownsToolbar: Bool = false) {
        self.model = model
        state = model.main
        reviews = model.reviews
        respond = model.respond
        prStore = model.prStore
        self.detail = detail
        self.prID = prID
        self.ownsToolbar = ownsToolbar
    }

    var body: some View {
        content
            .onAppear { model.detailAppeared(prID) }
            // El modo foco no se apaga acá: al elegir otro PR, su `onChange(initial:)` lo pone según ese PR (el orden
            // entre el `onDisappear` de uno y el `onAppear` del otro no está garantizado).
            .onDisappear { model.detailDisappeared(prID) }
    }

    /// Claude trabaja en Respond o Fix CI del PR que se ve (spec M.1 "Modo foco").
    private func claudeWorking(_ tab: PRTab) -> Bool {
        (tab == .respond || tab == .fixCI) && (respond.phases[prID]?.isActive == true || respond.runningTests.contains(prID))
    }

    @ViewBuilder
    private var content: some View {
        if let context = model.tabContext(prID: prID) {
            let tab = state.nav.tab(for: prID, context: context)
            pane(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Modo foco (spec M.1): mientras Claude trabaja en Respond o Fix CI del PR que se ve.
                .onChange(of: claudeWorking(tab), initial: true) { _, working in detail.focus.setClaudeWorking(working) }
                // View › Show Chat in the menu bar.
                .windowCommand(.toggleChat, enabled: model.chatEnabled, isOn: detail.focus.chatShown && model.chatEnabled) {
                    detail.focus.toggleChat()
                }
                .toolbar {
                    // En la ventana principal las pone `MainWindow` (en orden: pestañas al centro, después los botones).
                    if ownsToolbar {
                        ToolbarItem(placement: .principal) {
                            PRDetailToolbar.tabBar(model: model, state: state, prID: prID, context: context, tab: tab)
                        }
                        if model.chatEnabled {
                            ToolbarItem(placement: .primaryAction) {
                                PRDetailToolbar.chatButton(detail: detail)
                            }
                        }
                    }
                }
        } else {
            PRGoneView(prID: prID)
        }
    }

    @ViewBuilder
    private func pane(_ tab: PRTab) -> some View {
        switch tab {
        case .review:
            ReviewPane(model: model, prID: prID)
        case .details, .merge:
            // La sesión de merge del PR (detalle cargado, head fijo, chat); sin PR en la lista no hay qué mostrar.
            if let item = model.currentItem(prID) {
                MergeDetailPane(model: model, session: model.mergeSession(for: item), mode: tab == .merge ? .merge : .details)
            } else {
                PRGoneView(prID: prID)
            }
        case .respond, .fixCI:
            RespondPane(model: model, prID: prID, mode: tab == .fixCI ? .ciFix : .feedback) { state.choose($0, for: prID) }
        }
    }
}

/// Las piezas del detalle que van en la toolbar: las pestañas y el botón del chat.
@MainActor
enum PRDetailToolbar {
    static func tabBar(model: AppModel, state: MainWindowState, prID: String, context: PRTabContext, tab: PRTab) -> some View {
        PRTabBar(tabs: PRTabs.tabs(context), selected: tab,
                 indicator: { ClaudeTasksSidebar.indicator(prID: prID, tab: $0, rows: model.claudeTaskRows()) },
                 choose: { state.choose($0, for: prID) })
    }

    static func chatButton(detail: PRDetailState) -> some View {
        Button { detail.focus.toggleChat() } label: {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
        }
        .help(detail.focus.chatShown ? "Hide Chat (⌥⌘I)" : "Show Chat (⌥⌘I)")
    }
}

/// Un PR que ya no está en la lista y no tiene review ni Respond (se mergeó o se cerró).
private struct PRGoneView: View {
    let prID: String

    var body: some View {
        VStack(spacing: 0) {
            MessageView(icon: "questionmark.folder", title: "This PR is no longer in your list",
                        text: "It may have been merged or closed.")
            if let url = PRReference.githubURL(prID: prID) {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// El chat de la pestaña como inspector de 300 pt (spec M.1), abierto según el modo foco del detalle.
struct ChatInspectorModifier: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var detail: PRDetailState
    let prID: String
    let tab: PRTab
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content.inspector(isPresented: Binding(get: { detail.focus.chatShown && model.chatEnabled },
                                                   set: { detail.focus.setChatShown($0) })) {
                ChatInspector(model: model, prID: prID, tab: tab)
                    .inspectorColumnWidth(min: Theme.MainLayout.inspectorWidth, ideal: Theme.MainLayout.inspectorWidth,
                                          max: 480)
            }
        } else {
            content
        }
    }
}
