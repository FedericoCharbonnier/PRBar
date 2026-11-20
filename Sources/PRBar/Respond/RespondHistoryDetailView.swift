import AppKit
import PRBarCore
import SwiftUI

/// Detalle (solo lectura) de una corrida de "Responder" en el Historial: comentarios y decisiones, commits,
/// tests, respuestas publicadas y el log.
struct RespondHistoryDetailView: View {
    let record: RespondRecord
    let logURL: URL
    /// La corrida sigue en la cola: se puede abrir su ventana.
    let canOpen: Bool
    let open: () -> Void

    private var draft: RespondDraft { record.draft }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let error = record.errorMessage {
                    ErrorBanner(messages: [error]).padding(.horizontal, -10)
                }
                if let result = record.result, !result.sensitiveChanges.isEmpty {
                    SensitiveChangesBanner(paths: result.sensitiveChanges)
                }
                if !draft.items.isEmpty { itemsSection }
                if let result = record.result { commitsSection(result) }
                if let tests = record.result?.tests { testsSection(tests) }
                if !record.posted.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Posted replies (\(record.posted.count))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        RespondRepliesList(record: record)
                    }
                }
                if let chat = record.chat, !chat.messages.isEmpty {
                    ChatTranscriptSection(session: chat, summary: { message in
                        ChatActions.summary(message.changes) { id in draft.items.firstIndex { $0.id == id }.map { $0 + 1 } }
                    }, logURL: logURL)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(repo: draft.repo, number: draft.number, url: draft.url, linkTitle: "Open PR")
            Text(draft.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: draft.isCIFix ? "wrench.and.screwdriver" : "arrowshape.turn.up.left")
                    .accessibilityLabel(draft.isCIFix ? "Fix CI" : "Feedback response")
                Text("@\(draft.account)").foregroundStyle(.primary)
                Text("·").foregroundStyle(.tertiary)
                Text(ReviewDates.short(record.finishedAt ?? record.startedAt))
                Text("·").foregroundStyle(.tertiary)
                StatusPill.respond(record)
                if record.pushed {
                    StatusPill(text: "Pushed", color: Theme.greenText, background: Theme.tint(Theme.green))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ClaudeUsageLine(usage: record.totalUsage)
            if !draft.worktree.path.isEmpty {
                Text("Worktree: \(draft.worktree.path)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(draft.worktree.path)
            }
        }
    }

    /// Cada comentario con lo que decidió el usuario (o lo que propuso Claude, si no llegó a decidir).
    private var itemsSection: some View {
        section(draft.isCIFix ? "Failing checks (\(draft.ci?.checkNames.count ?? 0))" : "Comments (\(draft.items.count))") {
            ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                let selection = record.selections[item.id]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        RespondItemHeader(feedback: item.feedback)
                        decisionPills(selection)
                    }
                    if !item.assessment.isEmpty {
                        Text(item.assessment)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let selection, selection.reply,
                       !selection.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(selection.replyText)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
    }

    @ViewBuilder
    private func decisionPills(_ selection: RespondSelection?) -> some View {
        if let selection {
            if selection.implement {
                StatusPill(text: "Fix", color: Theme.violet)
            }
            if selection.reply {
                StatusPill(text: "Reply", color: Theme.blue)
            }
            if !selection.implement && !selection.reply {
                StatusPill(text: "Skipped", color: .secondary, background: Color.primary.opacity(0.08))
            }
        } else {
            StatusPill(text: "Undecided", color: .secondary, background: Color.primary.opacity(0.08))
        }
    }

    private func commitsSection(_ result: RespondResult) -> some View {
        section("Commits (\(RespondCounts.commits(result)))") {
            ForEach(Array(result.items.enumerated()), id: \.element.id) { index, itemResult in
                if index > 0 { Divider() }
                CommitRow(result: itemResult, item: draft.items.first { $0.id == itemResult.id },
                          commitURL: record.pushed ? commitURL(itemResult.commit) : nil)
            }
            if !result.diffStat.isEmpty {
                Divider()
                Text(result.diffStat)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private func testsSection(_ tests: TestRun) -> some View {
        section("Tests") {
            VStack(alignment: .leading, spacing: 4) {
                Label(tests.passed ? "Passed" : "Failed",
                      systemImage: tests.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tests.passed ? Theme.greenText : Theme.orangeText)
                Text(tests.command)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(10)
        }
    }

    private func commitURL(_ sha: String?) -> URL? {
        guard let sha, !sha.isEmpty else { return nil }
        return URL(string: "https://github.com/\(draft.repo.owner)/\(draft.repo.name)/commit/\(sha)")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
                .cardBorder()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                if !NSWorkspace.shared.open(logURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            } label: {
                Label("Show Log", systemImage: "terminal")
            }
            .disabled(!FileManager.default.fileExists(atPath: logURL.path))
            if canOpen {
                Button("Show Response", action: open)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
