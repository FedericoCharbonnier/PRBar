import AppKit
import PRBarCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var slack: SlackAnnouncer
    @State private var collapsed: Set<PRCategory> = [.other]

    private let actionable: [PRCategory] = [.toReview, .updatedSinceMyReview, .myFeedback]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.bottom, 4)
            content
            UpdateRow(updates: model.updates) { model.openUpdateWindow() }
        }
        .frame(width: Theme.popoverWidth)
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

                let sections = actionable.filter { !snapshot.items(in: $0).isEmpty }
                if sections.isEmpty {
                    MessageView(
                        icon: "checkmark.seal", iconColor: Theme.green,
                        title: "All Caught Up",
                        text: "No PRs are waiting for your review and there’s no new feedback on yours."
                    )
                }
                ForEach(sections) { category in
                    section(category, items: snapshot.items(in: category))
                }

                let others = snapshot.items(in: .other)
                if !others.isEmpty {
                    Divider().padding(.vertical, 4)
                    section(.other, items: others, dimmed: true)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: Theme.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ category: PRCategory, items: [ClassifiedPR], dimmed: Bool = false) -> some View {
        SectionHeader(
            title: category == .other ? "Other" : category.title,
            subtitle: category == .other ? "drafts and nothing to do" : nil,
            count: items.count,
            collapsed: collapsed.contains(category),
            dimmed: dimmed
        ) {
            if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) }
        }
        if !collapsed.contains(category) {
            ForEach(items) { item in
                PRRowView(item: item, dimmed: dimmed, model: model, reviews: model.reviews, respond: model.respond,
                          updateSession: model.updates.session)
            }
        }
    }
}
