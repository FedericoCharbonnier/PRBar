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

    init(model: AppModel, prID: String, detail: PRDetailState) {
        self.model = model
        state = model.main
        reviews = model.reviews
        respond = model.respond
        prStore = model.prStore
        self.detail = detail
        self.prID = prID
    }

    var body: some View {
        if let context = model.tabContext(prID: prID) {
            let tab = state.nav.tab(for: prID, context: context)
            pane(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        PRTabBar(tabs: PRTabs.tabs(context), selected: tab,
                                 indicator: { ClaudeTasksSidebar.indicator(prID: prID, tab: $0, rows: model.claudeTaskRows()) },
                                 choose: { state.choose($0, for: prID) })
                    }
                }
        } else {
            PRGoneView(prID: prID)
        }
    }

    /// Hasta su task, cada pestaña muestra un botón que abre la ventana de hoy.
    @ViewBuilder
    private func pane(_ tab: PRTab) -> some View {
        switch tab {
        case .review, .details:
            LegacyPaneButton(title: "Open Review Window") { model.openReview(prID: prID) }
        case .merge:
            LegacyPaneButton(title: "Open Merge Window") { if let item = model.currentItem(prID) { model.requestMerge(item) } }
        case .respond, .fixCI:
            LegacyPaneButton(title: "Open Respond Window") { model.openRespond(prID: prID) }
        }
    }
}

/// Provisorio (plan 21): la pestaña abre la ventana vieja hasta que llega su pane.
private struct LegacyPaneButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
