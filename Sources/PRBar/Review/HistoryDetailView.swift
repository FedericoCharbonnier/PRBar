import AppKit
import PRBarCore
import SwiftUI

/// Detalle (solo lectura) de un registro del historial.
struct HistoryDetailView: View {
    let record: ReviewRecord
    let canReopen: Bool
    let logURL: URL
    let reopen: () -> Void
    /// "Open in Terminal" (spec T.4): only when the record's folder is still kept.
    var terminal: SessionTerminalButton? = nil

    private var draft: ReviewDraft { record.draft }
    /// The findings as the chat left them (edited titles, added ones), or the draft's.
    private var items: [ReviewItem] { draft.edits?.items(of: draft) ?? draft.items }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if record.status == .failed {
                    ErrorBanner(messages: [record.errorMessage ?? "The review failed."]).padding(.horizontal, -10)
                }
                if record.status != .failed || !draft.summary.isEmpty {
                    ClaudeSummary(title: "Summary", summary: draft.summary)
                }
                if let general = record.generalComment, !general.isEmpty {
                    section("General comment") {
                        Text(general)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                }
                findingSections
                if let chat = draft.chat, !chat.messages.isEmpty {
                    ChatTranscriptSection(session: chat, summary: { message in
                        ChatActions.summary(message.changes) { id in draft.edits?.number(of: id, in: draft) }
                    }, logURL: logURL)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bottomBar { footer }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(draft: draft, linkTitle: "Open on GitHub")
            Text(draft.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                AvatarView(login: draft.author, url: nil, size: 16)
                Text(draft.author).foregroundStyle(.primary)
                Text("·").foregroundStyle(.tertiary)
                Text(ReviewDates.short(record.finishedAt ?? record.startedAt))
                Text("·").foregroundStyle(.tertiary)
                StatusPill.record(record)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ClaudeUsageLine(usage: draft.totalUsage)
        }
    }

    /// Publicado: lo que se publicó y lo que no. Sin publicar: lo que el filtro mantuvo y lo que descartó.
    @ViewBuilder
    private var findingSections: some View {
        let (main, rest): ([ReviewItem], [ReviewItem]) = record.status == .published
            ? (items.filter { record.published[$0.id] != nil }, items.filter { record.published[$0.id] == nil })
            : (items.filter(\.keep), items.filter { !$0.keep })
        if !main.isEmpty {
            section("\(record.status == .published ? "Posted" : "Findings") (\(main.count))") {
                ForEach(Array(main.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Circle().fill(item.finding.severity.color).frame(width: 8, height: 8)
                        locationText(item.finding)
                        Text(item.finding.title).lineLimit(1).help(item.finding.title)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
        }
        if !rest.isEmpty {
            section("Discarded (\(rest.count))", dimmed: true) {
                ForEach(Array(rest.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            locationText(item.finding)
                            Text(item.finding.title).lineLimit(1).help(item.finding.title)
                        }
                        .font(.callout)
                        Text(reason(for: item))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
        }
    }

    private func locationText(_ finding: ReviewFinding) -> some View {
        Text(finding.location)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
    }

    private func reason(for item: ReviewItem) -> String {
        if let reason = item.reason, !reason.isEmpty, !item.keep { return reason }
        return item.keep ? "Not selected when posting" : "No reason given"
    }

    private func section<Content: View>(_ title: String, dimmed: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(dimmed ? Color.primary.opacity(0.05) : Color(nsColor: .controlBackgroundColor))
                )
                .cardBorder(opacity: dimmed ? 0 : 0.1)
        }
    }

    private var footer: some View {
        HistoryDetailBar(logURL: logURL) {
            if let terminal { terminal }
            if let url = record.reviewURL {
                ExternalLink("View Review", destination: url)
            }
            if canReopen {
                Button("Open to Post", action: reopen)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// "Claude · 3m 12s · 92.1k tokens · $0.42 (estimated)" in a History entry (spec O.2); "—" for older entries.
struct ClaudeUsageLine: View {
    let usage: ClaudeUsage?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").accessibilityHidden(true)
            Text("Claude")
            Text("·").foregroundStyle(.tertiary)
            Text(UsageFormat.summary(usage)).monospacedDigit()
            if let usage, usage.hasData {
                Text("·").foregroundStyle(.tertiary)
                Text(UsageFormat.tokenBreakdown(usage)).monospacedDigit()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .help(UsageFormat.note)
        .accessibilityElement(children: .combine)
    }
}
