import AppKit
import PRBarCore
import SwiftUI

/// Resultado de publicar una review, para el estado "Review publicada" de la ventana.
struct PublishedReview: Equatable {
    let url: URL
    let action: ReviewRecord.Action
    /// Comentarios en línea; `nil` si no se sabe (registro reabierto desde el historial).
    let inlineCount: Int?
    /// Comentarios elegidos (en línea + los que fueron al comentario general).
    let commentCount: Int
    let hasGeneralComment: Bool
    let publishedAt: Date

    /// A partir de un registro publicado del historial (`nil` si no tiene URL).
    init?(record: ReviewRecord) {
        guard record.status == .published, let url = record.reviewURL else { return nil }
        self.url = url
        action = record.action
        inlineCount = nil
        commentCount = record.published.count
        hasGeneralComment = !(record.generalComment ?? "").isEmpty
        publishedAt = record.finishedAt ?? record.startedAt
    }

    init(url: URL, action: ReviewRecord.Action, submission: ReviewSubmission, commentCount: Int, publishedAt: Date) {
        self.url = url
        self.action = action
        inlineCount = submission.comments.count
        self.commentCount = commentCount
        hasGeneralComment = !submission.body.isEmpty
        self.publishedAt = publishedAt
    }

    func detail(now: Date) -> String {
        var parts: [String] = []
        if let inlineCount {
            parts.append(inlineCount == 1 ? "1 inline comment" : "\(inlineCount) inline comments")
        } else {
            parts.append(commentCount == 1 ? "1 comment" : "\(commentCount) comments")
        }
        if hasGeneralComment { parts.append("1 general comment") }
        parts.append(ReviewDates.ago(publishedAt, now: now))
        return parts.joined(separator: " · ")
    }
}

/// Estado final de la ventana de Review, una vez publicada.
struct ReviewPublishedView: View {
    let result: PublishedReview
    let close: () -> Void
    let model: AppModel
    let repo: RepoRef
    @ObservedObject private var instructions: InstructionsStore

    init(result: PublishedReview, close: @escaping () -> Void, model: AppModel, repo: RepoRef) {
        self.result = result
        self.close = close
        self.model = model
        self.repo = repo
        _instructions = ObservedObject(wrappedValue: model.instructions)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.green)
                .padding(.bottom, 6)
            Text("Review Posted").font(.title.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 6) {
                    StatusPill.action(result.action)
                    Text(result.detail(now: context.date))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ExternalLink("View on GitHub", destination: result.url)
                    .padding(.trailing, 8)
                Button("Close", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
            let suggestions = model.ruleSuggestions(for: repo)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(suggestions) { RuleSuggestionCard(model: model, suggestion: $0) }
                }
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(maxWidth: 460)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
                .padding(.top, 18)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 80)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { Divider() }
    }
}
