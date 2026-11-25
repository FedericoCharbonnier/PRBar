import PRBarCore
import SwiftUI

extension AppModel {
    /// Lo que Respond va a analizar, con la misma consulta y el mismo filtro que el análisis (`FeedbackFilter`).
    func pendingFeedback(_ item: ClassifiedPR) async throws -> [FeedbackItem] {
        let token = try await accounts.token(for: item.account)
        let feedback = try await api.reviewFeedback(repo: item.pr.repo, number: item.pr.number, token: token)
        return FeedbackFilter.select(feedback, me: item.account)
    }

    /// La última corrida terminada de Respond / Fix CI del PR (en History), para "Previous run".
    func lastFinishedRespond(prID: String) -> RespondRecord? {
        respondHistory.all()
            .filter { $0.draft.prID == prID && $0.finishedAt != nil }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
    }
}

/// The comments Respond will answer, before starting (round 1 and after a finished run): author, where, when, the
/// text and a link to GitHub.
struct RespondFeedbackList: View {
    @ObservedObject var model: AppModel
    let item: ClassifiedPR

    private enum Load: Equatable {
        case loading
        case loaded([FeedbackItem])
        case failed(String)
    }

    @State private var load: Load = .loading
    @State private var attempt = 0

    /// Reloads when the list's count of new feedback or the head changes (a refresh brought something new).
    private var reloadKey: String {
        "\(item.pr.headOid)·\(ActionClassifier.newFeedback(item.pr, me: item.account).count)·\(attempt)"
    }

    var body: some View {
        Group {
            switch load {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the comments…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    ErrorBanner(messages: ["Couldn’t load the comments: \(message)"])
                    Button("Retry") { attempt += 1 }
                        .controlSize(.small)
                        .help("Load the comments again")
                }
            case .loaded(let items) where items.isEmpty:
                Text("No unresolved comments waiting for an answer. Claude reads the PR again when you start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .loaded(let items):
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { feedback in
                        RespondFeedbackRow(feedback: feedback)
                    }
                }
            }
        }
        .task(id: reloadKey) { await reload() }
    }

    private func reload() async {
        if case .loaded = load {} else { load = .loading }
        do {
            let items = try await model.pendingFeedback(item)
            load = .loaded(items)
        } catch is CancellationError {
        } catch {
            load = .failed(error.localizedDescription)
        }
    }
}

/// One comment: its author, file:line (or "Review" / "Comment"), when, the text (long ones cut, with Show More) and ↗.
private struct RespondFeedbackRow: View {
    let feedback: FeedbackItem
    @State private var expanded = false

    /// The comment waiting for an answer: the last one of a thread.
    private var comment: FeedbackComment? { feedback.comments.last }

    private var location: String {
        switch feedback.kind {
        case .thread:
            guard let path = feedback.path else { return "Thread" }
            return feedback.line.map { "\(path):\($0)" } ?? path
        case .reviewBody: return "Review"
        case .conversation: return "Comment"
        case .ciChecks: return "Checks"
        case .mergeConflicts: return "Conflicts"
        }
    }

    private var isLong: Bool {
        guard let body = comment?.body else { return false }
        return body.count > 280 || body.split(whereSeparator: \.isNewline).count > 4
    }

    var body: some View {
        if let comment {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author).fontWeight(.semibold)
                    Text("·").foregroundStyle(.tertiary)
                    Text(location)
                        .font(.system(.callout, design: feedback.kind == .thread ? .monospaced : .default))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if feedback.isOutdated {
                        Text("outdated").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(ReviewDates.ago(comment.createdAt)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    ExternalLink("GitHub", destination: comment.url)
                }
                .font(.callout)
                Text(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if feedback.kind == .thread, feedback.comments.count > 1 {
                    Text("\(feedback.comments.count) comments in this thread")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }
}
