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

    /// El modo foco no se apaga al irse: al elegir otro PR, su `onChange(initial:)` lo pone según ese PR (el orden entre
    /// el `onDisappear` de uno y el `onAppear` del otro no está garantizado).
    var body: some View { content }

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
                .modifier(PRDetailCommands(model: model, state: state, prID: prID, context: context, tab: tab))
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

/// Lo que el menú de la app hace sobre el PR en pantalla (spec M.6): ⌥⌘1–3 (sus pestañas), ⌘. (detener a Claude) y
/// ⌘Z fuera de un texto (deshacer el último cambio de Claude del chat de la pestaña).
private struct PRDetailCommands: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    let prID: String
    let context: PRTabContext
    let tab: PRTab

    init(model: AppModel, state: MainWindowState, prID: String, context: PRTabContext, tab: PRTab) {
        self.model = model
        self.state = state
        reviews = model.reviews
        respond = model.respond
        self.prID = prID
        self.context = context
        self.tab = tab
    }

    func body(content: Content) -> some View {
        let tabs = PRTabs.tabs(context)
        content
            .modifier(TabCommand(index: 1, tabs: tabs, selected: tab) { state.choose($0, for: prID) })
            .modifier(TabCommand(index: 2, tabs: tabs, selected: tab) { state.choose($0, for: prID) })
            .modifier(TabCommand(index: 3, tabs: tabs, selected: tab) { state.choose($0, for: prID) })
            // `WindowCommandModifier` registra la acción cuando cambia `enabled`: la pestaña se busca al ejecutarla (de
            // Respond a Fix CI `enabled` puede no cambiar y quedaría la de antes).
            .windowCommand(.stopClaude, enabled: canStop(tab)) { stop(currentTab) }
            .windowCommand(.undoClaude, enabled: undoChat(tab) != nil) {
                if let chat = undoChat(currentTab) { ChatUndo.perform(chat) }
            }
    }

    /// La pestaña que se ve ahora (`tab` es la del último render).
    private var currentTab: PRTab {
        model.tabContext(prID: prID).map { state.nav.tab(for: prID, context: $0) } ?? tab
    }

    /// Claude trabaja en la pestaña que se ve (la review, o el Respond / Fix CI; no mientras pushea).
    private func canStop(_ tab: PRTab) -> Bool {
        switch tab {
        case .review, .details: reviews.phases[prID]?.isActive == true
        case .respond, .fixCI: respond.phases[prID]?.isActive == true && respond.phases[prID] != .pushing
        case .merge: false
        }
    }

    /// Pregunta lo mismo que el Stop / Cancel de cada pane.
    private func stop(_ tab: PRTab) {
        guard canStop(tab) else { return }
        switch tab {
        case .review, .details:
            ConfirmAlert.present(title: "Cancel this review?", message: "Claude stops and what it did so far is lost.",
                                 action: "Cancel Review") { model.cancelReview(prID: prID) }
        case .respond, .fixCI:
            let isCI = tab == .fixCI
            ConfirmAlert.present(title: isCI ? "Stop fixing the CI?" : "Stop this response?",
                                 message: "Claude stops. Commits already made stay unpushed in PRBar’s worktree.",
                                 action: "Stop") { model.cancelRespond(prID: prID) }
        case .merge:
            break
        }
    }

    /// El chat de la pestaña con un cambio de Claude para deshacer (Review: el de la review lista; Respond / Fix CI: el
    /// de su análisis). Merge no deshace (su chat es de solo lectura).
    private func undoChat(_ tab: PRTab) -> ChatCoordinator? {
        let draftID: UUID?
        switch tab {
        case .review, .details:
            if case .ready(let draft)? = reviews.phases[prID] { draftID = draft.id } else { draftID = nil }
        case .respond, .fixCI:
            draftID = respond.records[prID]?.draft.id
        case .merge:
            draftID = nil
        }
        guard let draftID, let chat = model.existingChat(draftID: draftID),
              chat.session.undoableMessageID != nil, chat.canUndo else { return nil }
        return chat
    }
}

/// ⌥⌘`index`: la pestaña `index` del PR, con su nombre en el menú.
private struct TabCommand: ViewModifier {
    let index: Int
    let tabs: [PRTabItem]
    let selected: PRTab
    let choose: (PRTab) -> Void

    func body(content: Content) -> some View {
        let item = tabs.indices.contains(index - 1) ? tabs[index - 1] : nil
        content.windowCommand(.tab(index), enabled: item?.isEnabled == true, isOn: item?.tab == selected,
                              title: item?.tab.title) {
            if let item, item.isEnabled { choose(item.tab) }
        }
    }
}
