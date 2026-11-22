import AppKit
import PRBarCore
import SwiftUI

/// Detalle (solo lectura) de un merge en el Historial (spec G.4): el PR, el método, el head, el resultado y la
/// conversación de la ventana de Merge.
struct MergeHistoryDetailView: View {
    let record: MergeRecord
    let logURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    PRReferenceLine(repo: record.repo, number: record.number, url: record.url, linkTitle: "Open PR")
                    Text(record.title)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge").accessibilityLabel("Merge")
                        Text(details).foregroundStyle(.secondary)
                        Spacer()
                        StatusPill.merge(record)
                    }
                    .font(.callout)
                    if record.chat?.usage != nil { ClaudeUsageLine(usage: record.chat?.usage) }
                }
                if let error = record.errorMessage, record.status == .failed {
                    ErrorBanner(messages: [error]).padding(.horizontal, -10)
                }
                if let chat = record.chat, !chat.messages.isEmpty {
                    ChatTranscriptSection(session: chat, summary: { _ in "" }, logURL: logURL)
                } else {
                    Text("No chat with Claude").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bottomBar { HistoryDetailBar(logURL: logURL, prURL: record.url) { EmptyView() } }
    }

    /// "Squash and Merge · abc1234 · Nov 19, 10:00".
    private var details: String {
        var parts: [String] = []
        if let method = record.method { parts.append(method.actionTitle) }
        if let head = record.headOid { parts.append(String(head.prefix(7))) }
        parts.append(ReviewDates.short(record.finishedAt ?? record.startedAt))
        return parts.joined(separator: " · ")
    }
}

extension StatusPill {
    /// Merged (verde), Failed (rojo) o Not merged (azul).
    static func merge(_ record: MergeRecord) -> StatusPill {
        switch record.status {
        case .merged: StatusPill(text: "Merged", color: Theme.greenText, background: Theme.tint(Theme.green))
        case .failed: StatusPill(text: "Failed", color: Theme.redText, background: Theme.tint(Theme.red))
        case .open: StatusPill(text: "Not merged", color: Theme.blueText, background: Theme.tint(Theme.blue))
        }
    }
}
