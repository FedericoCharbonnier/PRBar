import AppKit
import PRBarCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var slack: SlackAnnouncer
    @ObservedObject var tabs: PopoverTabState
    /// ↑/↓ selection among the rows (handled by `StatusItemController`).
    @ObservedObject var rows: PopoverRowSelection
    @State private var collapsed: Set<PopoverSection> = [.otherToReview, .waitingForReview]
    /// The height the panel can take on this screen (`.infinity` in snapshot mode).
    @Environment(\.popoverAvailableHeight) private var availableHeight
    /// Everything but the PR list (header, tabs, footer, update row), measured: the list gets what's left.
    @State private var totalHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsTabs {
                tabPicker
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider().padding(.bottom, 4)
            content
            // El pie de recursos, debajo del contenido y visible en las dos pestañas (spec I).
            if showsTabs {
                Divider()
                ResourceFooter(monitor: model.resources) { model.openActivityWindow() }
            }
            UpdateRow(updates: model.updates) { model.openUpdateWindow() }
        }
        .frame(width: Theme.popoverWidth)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { totalHeight = $0 }
        .onChange(of: visibleRowIDs, initial: true) { _, ids in rows.setRows(ids) }
    }

    /// The list's maximum height: `Theme.popoverMaxHeight`, or less if the screen doesn't have room for it next to
    /// the rest of the popover.
    private var listMaxHeight: CGFloat {
        guard availableHeight.isFinite else { return Theme.popoverMaxHeight }
        let chrome = max(totalHeight - listHeight, 0)
        return min(Theme.popoverMaxHeight, max(availableHeight - chrome, 120))
    }

    /// The PR rows on screen, top to bottom, for ↑/↓ (none when the popover shows a message instead of the list).
    private var visibleRowIDs: [String] {
        guard showsTabs, let snapshot = prStore.snapshot, !(snapshot.failedCompletely && snapshot.items.isEmpty) else { return [] }
        let sections = PopoverTabs.sections(tabs.selected).filter { !PopoverTabs.items($0, in: snapshot).isEmpty }
        let ordered = sections.filter { !$0.isQuiet } + sections.filter(\.isQuiet)
        return ordered.filter { !collapsed.contains($0) }.flatMap { PopoverTabs.items($0, in: snapshot).map(\.id) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("PRBar").font(.headline).foregroundStyle(.primary)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let limitedUntil = rateLimitedUntil(at: context.date)
                IconButton(
                    systemImage: "arrow.clockwise",
                    help: limitedUntil.map { "GitHub rate limit · retrying at \(ClockTime.hhmm($0))" } ?? "Refresh (⌘R)",
                    size: 13, weight: .semibold
                ) {
                    Task { await prStore.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(prStore.isRefreshing || limitedUntil != nil)
            }
            Menu {
                Button("History…") { model.openHistory() }
                    .keyboardShortcut("y", modifiers: .command)
                Button("Settings…") { model.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit PRBar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 22, height: 22)
            .hoverHighlight(cornerRadius: Theme.Radius.button)
            .help("More options")
            .accessibilityLabel("More options")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background { keyboardShortcuts }
    }

    /// El control solo tiene sentido con la lista de PRs (decisión H.4.6): no con "Set Up an Account", "GitHub CLI
    /// not found", "Offline" sin datos ni "Loading PRs…".
    private var showsTabs: Bool {
        guard let snapshot = prStore.snapshot else { return false }
        return configStore.config.accounts.contains(where: \.enabled)
            && !(model.toolsResolved && model.tools.gh == nil)
            && !(snapshot.failedCompletely && snapshot.items.isEmpty)
    }

    private var tabPicker: some View {
        let counts = PopoverTabs.counts(in: prStore.snapshot)
        return Picker("Tab", selection: $tabs.selected) {
            ForEach(PopoverTab.allCases) { tab in
                Text(PopoverTabs.label(tab, count: counts[tab] ?? 0, selected: tab == tabs.selected))
                    .accessibilityLabel(PopoverTabs.accessibilityLabel(tab, count: counts[tab] ?? 0,
                                                                       selected: tab == tabs.selected))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityValue(PopoverTabs.accessibilityValue(counts: counts, selected: tabs.selected))
        .help("⌘1 To Review · ⌘2 My PRs")
    }

    /// Los atajos del menú ⚙︎ también tienen que andar con el menú cerrado: un `Menu` solo atiende los de sus
    /// ítems mientras está abierto, así que se repiten en botones invisibles.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("History…") { model.openHistory() }
                .keyboardShortcut("y", modifiers: .command)
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Button("Quit PRBar") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
            // ⌘1/⌘2 solo cuando se ve el control (decisión H.4.6): sin él no hay pestañas que cambiar.
            if showsTabs {
                Button("To Review") { tabs.selected = .toReview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("My PRs") { tabs.selected = .mine }
                    .keyboardShortcut("2", modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Hora de reintento si GitHub nos limitó y todavía no pasó; `nil` si se puede refrescar.
    private func rateLimitedUntil(at now: Date) -> Date? {
        guard let until = prStore.snapshot?.rateLimitedUntil, until > now else { return nil }
        return until
    }

    private var subtitle: String {
        if prStore.isRefreshing { return "updating…" }
        guard let snapshot = prStore.snapshot else { return "no data" }
        if let until = rateLimitedUntil(at: Date()) { return "GitHub rate limit · retrying at \(ClockTime.hhmm(until))" }
        if snapshot.failedCompletely { return "offline" }
        return Self.updatedAgo(snapshot.fetchedAt)
    }

    /// "updated just now" or "updated 40 min ago".
    private static func updatedAgo(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "updated just now" : "updated \(RelativeAge.short(from: date)) ago"
    }

    // MARK: Contenido

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
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let limitedUntil = rateLimitedUntil(at: context.date)
                    VStack(spacing: 0) {
                        MessageView(
                            icon: limitedUntil == nil ? "wifi.slash" : "hourglass",
                            title: limitedUntil == nil ? "Offline" : "GitHub Rate Limit",
                            text: limitedUntil.map { "GitHub is rate-limiting requests. Retrying at \(ClockTime.hhmm($0))." }
                                ?? "Couldn’t reach GitHub.",
                            actionTitle: "Try Again",
                            action: { Task { await prStore.refresh() } },
                            actionDisabled: limitedUntil != nil
                        )
                        if !snapshot.issues.isEmpty {
                            IssuesBanner(groups: snapshot.issuesByAccount).padding(.bottom, 8)
                        }
                    }
                }
            } else {
                list(snapshot)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading PRs…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        }
    }

    private func list(_ snapshot: Snapshot) -> some View {
        let tab = tabs.selected
        let sections = PopoverTabs.sections(tab).filter { !PopoverTabs.items($0, in: snapshot).isEmpty }
        let loud = sections.filter { !$0.isQuiet }
        let quiet = sections.filter(\.isQuiet)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if snapshot.failedCompletely {
                        ErrorBanner(messages: ["Offline. Showing data from \(RelativeAge.short(from: snapshot.fetchedAt)) ago."])
                    }
                    if !snapshot.issues.isEmpty {
                        IssuesBanner(groups: snapshot.issuesByAccount)
                    }
                    if !slack.issues.isEmpty {
                        IssuesBanner(groups: [(account: "Slack", issues: slack.issues)])
                    }
                    if loud.isEmpty {
                        let empty = PopoverTabs.emptyState(tab)
                        MessageView(icon: "checkmark.seal", iconColor: Theme.green, title: empty.title, text: empty.text)
                    }
                    ForEach(loud) { section in
                        self.section(section, items: PopoverTabs.items(section, in: snapshot))
                    }
                    ForEach(quiet) { section in
                        Divider().padding(.vertical, 4)
                        self.section(section, items: PopoverTabs.items(section, in: snapshot))
                    }
                }
                .padding(.bottom, 6)
            }
            .frame(maxHeight: listMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            .onChange(of: rows.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder
    private func section(_ section: PopoverSection, items: [ClassifiedPR]) -> some View {
        SectionHeader(
            title: section.title,
            subtitle: section.subtitle,
            count: items.count,
            collapsed: collapsed.contains(section),
            dimmed: section.isQuiet
        ) {
            if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        }
        if !collapsed.contains(section) {
            ForEach(items) { item in
                PRRowView(item: item, dimmed: section.isQuiet, placement: model.placements.label(prID: item.id),
                          isSelected: rows.selectedID == item.id, model: model,
                          reviews: model.reviews, respond: model.respond, merges: model.merges, updateSession: model.updates.session)
                    .id(item.id)
                    // The mouse and the arrow keys share one highlighted row, as in a menu.
                    .onHover { inside in if inside { rows.select(item.id) } }
            }
        }
    }
}
