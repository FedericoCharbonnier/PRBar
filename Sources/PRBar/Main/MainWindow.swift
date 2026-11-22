import AppKit
import PRBarCore
import SwiftUI

/// La ventana principal (spec M.1): barra lateral | contenido. El contenido de To Review y My PRs es la lista + el
/// detalle del PR en un `HStack` (no tres columnas nativas): así Activity ocupa todo el ancho y el modo foco oculta solo
/// la lista (decisión 1 del plan 21).
struct MainWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var prStore: PRStore
    @ObservedObject var detail: PRDetailState
    @State private var columns = NavigationSplitViewVisibility.all

    init(model: AppModel) {
        self.model = model
        state = model.main
        prStore = model.prStore
        detail = model.main.detail
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MainSidebar(model: model, state: state, prStore: prStore)
                .navigationSplitViewColumnWidth(Theme.MainLayout.sidebarWidth)
        } detail: {
            GeometryReader { geometry in
                content(windowWidth: geometry.size.width + (columns == .detailOnly ? 0 : Theme.MainLayout.sidebarWidth))
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .frame(minWidth: Theme.MainLayout.minSize.width, minHeight: Theme.MainLayout.minSize.height)
    }

    @ViewBuilder
    private func content(windowWidth: Double) -> some View {
        switch state.nav.place.sidebar {
        case .section(let section):
            HStack(spacing: 0) {
                if !detail.focus.isFocused {
                    PRListPane(model: model, state: state, prStore: prStore, section: section)
                        .frame(width: MainLayout.listWidth(windowWidth: windowWidth))
                    Divider()
                }
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .history:
            Text("History")   // Task 9
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .activity:
            Text("Activity")   // Task 10
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let prID = state.nav.place.prID {
            PRDetailView(model: model, prID: prID, detail: detail)
                .id(prID)
        } else {
            EmptyDetailView()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { state.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .disabled(!state.nav.back.canGoBack)
                .help("Back (⌘[)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if prStore.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                Button { Task { await prStore.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
            }
            Button {} label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
                .disabled(true)   // Task 14
                .help("Open in New Window (⇧⌘O)")
            Button {
                if let url = selectedPRURL { NSWorkspace.shared.open(url) }
            } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                .disabled(selectedPRURL == nil)
                .help("Open on GitHub")
        }
    }

    private var selectedPRURL: URL? {
        guard case .section = state.nav.place.sidebar, let prID = state.nav.place.prID else { return nil }
        return model.currentItem(prID)?.pr.url ?? PRReference.githubURL(prID: prID)
    }

    // MARK: Title

    private var title: String {
        switch state.nav.place.sidebar {
        case .section(let section): section.title
        case .history: "History"
        case .activity: "Activity"
        }
    }

    /// "8 PRs · updated 2 min ago", "updating…", "offline" (como el popover).
    private var subtitle: String {
        guard case .section(let section) = state.nav.place.sidebar else { return "" }
        if prStore.isRefreshing { return "updating…" }
        guard let snapshot = prStore.snapshot else { return "no data" }
        if snapshot.failedCompletely { return "offline" }
        let count = MainList.count(section, in: snapshot) ?? 0
        let updated = Date().timeIntervalSince(snapshot.fetchedAt) < 60
            ? "updated just now" : "updated \(RelativeAge.short(from: snapshot.fetchedAt)) ago"
        return "\(count == 1 ? "1 PR" : "\(count) PRs") · \(updated)"
    }
}
