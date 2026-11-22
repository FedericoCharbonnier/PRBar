import AppKit
import PRBarCore
import SwiftUI

/// La lista de PRs de To Review o My PRs (spec M.1 "Lista"): secciones plegables con contador, filas anchas con su
/// pill, ↩ para la acción del pill, doble clic para abrir el PR en una ventana aparte, y los estados vacío y cargando.
struct PRListPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var prStore: PRStore
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    let section: MainSection
    @FocusState private var listFocused: Bool

    init(model: AppModel, state: MainWindowState, prStore: PRStore, section: MainSection) {
        self.model = model
        self.state = state
        self.prStore = prStore
        configStore = model.configStore
        reviews = model.reviews
        respond = model.respond
        self.section = section
    }

    var body: some View {
        content
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if model.toolsResolved && model.tools.gh == nil {
            MessageView(
                icon: "exclamationmark.triangle.fill", iconColor: Theme.orange,
                title: "GitHub CLI not found",
                text: "Install GitHub CLI (brew install gh) or set its path in Settings → General.",
                actionTitle: "Open Settings", action: model.openSettings
            )
        } else if !configStore.config.accounts.contains(where: \.enabled) {
            MessageView(
                icon: "person.crop.circle",
                title: "Set Up an Account",
                text: "Choose which GitHub accounts, repos, and people to follow.",
                actionTitle: "Open Settings", action: model.openSettings
            )
        } else if let snapshot = prStore.snapshot {
            if snapshot.failedCompletely && snapshot.items.isEmpty {
                MessageView(
                    icon: "wifi.slash", title: "Offline", text: "Couldn’t reach GitHub.",
                    actionTitle: "Try Again", action: { Task { await prStore.refresh() } }
                )
            } else {
                list(snapshot)
            }
        } else {
            loading
        }
    }

    // MARK: Lista

    private func list(_ snapshot: Snapshot) -> some View {
        let sections = MainList.sections(section).map { ($0, MainList.items($0, in: snapshot)) }
        let loudEmpty = sections.allSatisfy { $0.0.isQuiet || $0.1.isEmpty }
        // Las vacías quedan (plegadas) salvo las quietas, que sin PRs no aparecen.
        let shown = sections.filter { !$0.1.isEmpty || !$0.0.isQuiet }
        return Group {
            if loudEmpty && sections.allSatisfy({ !$0.0.isQuiet || $0.1.isEmpty }) {
                emptyState(snapshot)
            } else {
                List(selection: Binding(get: { state.nav.place.prID }, set: { state.select(prID: $0) })) {
                    if snapshot.failedCompletely {
                        banner("Offline. Showing data from \(RelativeAge.short(from: snapshot.fetchedAt)) ago.")
                    }
                    if loudEmpty {
                        // Solo hay PRs callados (borradores, esperando review): el aviso arriba y ellos plegados abajo.
                        emptyMessage(snapshot)
                            .selectionDisabled()
                    }
                    ForEach(loudEmpty ? shown.filter { $0.0.isQuiet } : shown, id: \.0) { listSection, items in
                        Section(isExpanded: expanded(listSection, count: items.count)) {
                            ForEach(items) { item in
                                PRListRow(item: item, model: model, section: listSection)
                                    .tag(item.id)
                            }
                        } header: {
                            sectionHeader(listSection, count: items.count)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                .defaultFocus($listFocused, true)
                .onKeyPress(.return) {
                    guard let prID = state.nav.place.prID else { return .ignored }
                    model.performPrimaryAction(prID: prID)
                    return .handled
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let prID = ids.first, let item = model.currentItem(prID) {
                        Button("Open on GitHub") { NSWorkspace.shared.open(item.pr.url) }
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.pr.url.absoluteString, forType: .string)
                        }
                    }
                } primaryAction: { _ in
                    // Doble clic: la ventana de PR (Task 14).
                }
            }
        }
    }

    private func expanded(_ section: MainListSection, count: Int) -> Binding<Bool> {
        Binding(get: { !state.isCollapsed(section, itemCount: count) },
                set: { state.setCollapsed(!$0, section) })
    }

    private func sectionHeader(_ section: MainListSection, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
            Text("\(count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 15)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .foregroundStyle(section.isQuiet ? .secondary : .primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title), \(count == 1 ? "1 PR" : "\(count) PRs")")
    }

    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "wifi.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }

    // MARK: Vacío y cargando

    private func emptyState(_ snapshot: Snapshot) -> some View {
        VStack {
            Spacer()
            emptyMessage(snapshot)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// "All caught up" y, en To Review, "N drafts hidden · Show" (despliega "Other").
    private func emptyMessage(_ snapshot: Snapshot) -> some View {
        let empty = PopoverTabs.emptyState(section == .toReview ? .toReview : .mine)
        let drafts = section == .toReview ? MainList.hiddenDraftCount(in: snapshot) : 0
        let draftsShown = !state.isCollapsed(.otherToReview, itemCount: MainList.items(.otherToReview, in: snapshot).count)
        return VStack(spacing: 0) {
            MessageView(icon: "checkmark.seal", iconColor: Theme.green, title: "All caught up", text: empty.text)
            if drafts > 0 && !draftsShown {
                Button("\(drafts == 1 ? "1 draft" : "\(drafts) drafts") hidden · Show") {
                    state.setCollapsed(false, .otherToReview)
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Cinco filas esqueleto mientras no hay datos.
    private var loading: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<5, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Color.primary.opacity(0.08)).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                            .frame(height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                            .frame(width: index.isMultiple(of: 2) ? 140 : 110, height: 10)
                    }
                }
            }
            Spacer()
        }
        .padding(16)
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading PRs")
    }
}
