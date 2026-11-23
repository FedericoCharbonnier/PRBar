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
    /// CPU y RAM del subtítulo en Activity (solo muestrea mientras se ve Activity).
    @ObservedObject var resources: ResourceMonitor
    @State private var columns = NavigationSplitViewVisibility.all

    init(model: AppModel) {
        self.model = model
        state = model.main
        prStore = model.prStore
        detail = model.main.detail
        resources = model.resources
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MainSidebar(model: model, state: state, prStore: prStore)
                .navigationSplitViewColumnWidth(Theme.MainLayout.sidebarWidth)
        } detail: {
            GeometryReader { geometry in
                // Con el chat abierto el detalle se queda angosto: la lista toma su mínimo (280 pt).
                let chatOpen = chatInspector.enabled && detail.focus.chatShown && model.chatEnabled
                content(windowWidth: geometry.size.width + (columns == .detailOnly || chatOpen ? 0 : Theme.MainLayout.sidebarWidth))
            }
            .modifier(chatInspector)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        // View › Back (⌘[) y Pull Request › Open in New Window (⇧⌘O) / Open on GitHub.
        .windowCommand(.back, enabled: state.nav.back.canGoBack) { state.goBack() }
        .windowCommand(.openInNewWindow, enabled: selectedPRID != nil) {
            if let prID = selectedPRID { model.openPRWindow(prID: prID) }
        }
        .windowCommand(.openOnGitHub, enabled: selectedPRURL != nil) {
            if let url = selectedPRURL { NSWorkspace.shared.open(url) }
        }
        .sheet(item: $state.updateSheet) { mode in
            UpdateSheet(updates: model.updates, mode: mode) { state.updateSheet = nil }
        }
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
            .animation(.easeInOut(duration: 0.2), value: detail.focus.isFocused)
            .modifier(SearchField(text: $state.search))
        case .history:
            HStack(spacing: 0) {
                HistoryListPane(model: model, state: state)
                    .frame(width: MainLayout.listWidth(windowWidth: windowWidth))
                Divider()
                HistoryDetailPane(model: model, state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .modifier(SearchField(text: $state.search))
        case .activity:
            ActivityPane(model: model, monitor: resources)
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

    /// El chat del PR elegido, a la derecha de lista + detalle (en la columna de detalle de `NavigationSplitView`).
    private var chatInspector: ChatInspectorModifier {
        let prID = state.nav.section == nil ? nil : state.nav.place.prID
        let tab = prID.flatMap { id in model.tabContext(prID: id).map { state.nav.tab(for: id, context: $0) } }
        return ChatInspectorModifier(model: model, detail: detail, prID: prID ?? "", tab: tab ?? .review,
                                     enabled: prID != nil && tab != nil)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { state.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .disabled(!state.nav.back.canGoBack)
                .help("Back (⌘[)")
        }
        // Las pestañas del PR elegido, centradas (spec M.1).
        ToolbarItem(placement: .principal) {
            if let (prID, context, tab) = selectedTabs {
                PRDetailToolbar.tabBar(model: model, state: state, prID: prID, context: context, tab: tab)
            } else if state.nav.place.sidebar == .history {
                // All · Reviews · Responds · Merges (spec M.1 "History").
                HistoryFilterBar(selection: $state.historyFilter)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if state.nav.place.sidebar == .activity {
                // En Activity, Refresh vuelve a medir el disco (como su ⌘R).
                if resources.scanningDisk {
                    ProgressView().controlSize(.small).frame(width: 28)
                } else {
                    Button { resources.refreshDisk(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Measure the disk again (⌘R)")
                }
            } else if prStore.isRefreshing {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                Button { Task { await prStore.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
            }
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                if let prID = selectedPRID { model.openPRWindow(prID: prID) }
            }
                .disabled(selectedPRID == nil)
                .help("Open in New Window (⇧⌘O)")
            Button {
                if let url = selectedPRURL { NSWorkspace.shared.open(url) }
            } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                .disabled(selectedPRURL == nil)
                .help("Open on GitHub")
            if selectedTabs != nil && model.chatEnabled {
                PRDetailToolbar.chatButton(detail: detail)
            }
        }
        // La búsqueda (170 pt, "Search ⌘F") va a la derecha de este grupo: la pone `SearchField` en To Review, My PRs
        // y History (en Activity no hay campo).
    }

    /// El PR elegido en To Review / My PRs con sus pestañas (nil si no hay o ya no está).
    private var selectedTabs: (String, PRTabContext, PRTab)? {
        guard case .section = state.nav.place.sidebar, let prID = state.nav.place.prID,
              let context = model.tabContext(prID: prID) else { return nil }
        return (prID, context, state.nav.tab(for: prID, context: context))
    }

    /// El PR elegido en To Review / My PRs (aunque ya no esté en la lista).
    private var selectedPRID: String? {
        guard case .section = state.nav.place.sidebar else { return nil }
        return state.nav.place.prID
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
        if state.nav.place.sidebar == .activity { return ActivityPane.subtitle(resources) }
        if state.nav.place.sidebar == .history {
            let count = state.history.all.count
            return count == 1 ? "1 record" : "\(count) records"
        }
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

/// El campo de búsqueda de la toolbar (spec M.1, ⌘F): `.searchable` lo pone a la derecha, después del grupo de botones,
/// sin mover las pestañas centradas. SwiftUI no deja fijar su ancho: se lo pone al `NSSearchToolbarItem` de la ventana.
/// ⌘F (View › Find) lo enfoca con `WindowCommandCenter.find`.
private struct SearchField: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: "Search ⌘F")
            .background(WindowAccessor { window in
                // La toolbar de SwiftUI suma el ítem después de que la vista entra en la ventana.
                DispatchQueue.main.async { Self.setWidth(in: window) }
            })
    }

    @MainActor
    private static func setWidth(in window: NSWindow?) {
        for case let item as NSSearchToolbarItem in window?.toolbar?.items ?? [] {
            item.preferredWidthForSearchField = Theme.MainLayout.searchWidth
        }
    }
}
