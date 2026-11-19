import PRBarCore
import SwiftUI

/// Qué campo de texto de la ventana de Responder tiene el foco.
enum RespondFocus: Hashable {
    case fixPlan(String)
    case reply(String)
}

/// Tarjeta de un comentario de review en la etapa "ready": quién y dónde, el hilo, la evaluación de Claude y las
/// dos decisiones (implementar el fix con su plan; responder con su texto).
struct RespondItemCard: View {
    let item: RespondItem
    @Binding var selection: RespondSelection
    let disabled: Bool
    var focus: FocusState<RespondFocus?>.Binding
    /// The PR's language: replies (and PRBar's "Fixed in …") are posted in it.
    var language: PRLanguage = .english
    @State private var showThread = false

    private var feedback: FeedbackItem { item.feedback }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RespondItemHeader(feedback: feedback)
            thread
            assessment
            Divider()
            decisions.disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
        .cardBorder()
    }

    // MARK: Hilo

    /// El último comentario (recortado); expandido, el hilo entero.
    @ViewBuilder
    private var thread: some View {
        let comments = feedback.comments
        VStack(alignment: .leading, spacing: 6) {
            if showThread {
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    CommentBubble(comment: comment, lineLimit: nil)
                }
            } else if let last = comments.last {
                CommentBubble(comment: last, lineLimit: 3)
            }
            HStack(spacing: 10) {
                Button {
                    showThread.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showThread ? "chevron.down" : "chevron.right")
                            .imageScale(.small)
                            .fontWeight(.semibold)
                        Text(showThread ? "Hide thread" : comments.count > 1 ? "Show full thread (\(comments.count))" : "Show full comment")
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showThread ? "Hide thread" : "Show full thread")
                Spacer()
                if let url = comments.last?.url {
                    ExternalLink("View on GitHub", destination: url)
                        .font(.subheadline)
                }
            }
        }
    }

    private var assessment: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Claude’s Assessment", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.violet)
            Text(item.assessment.isEmpty ? "No assessment." : item.assessment)
                .font(.callout)
                .foregroundStyle(item.assessment.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Theme.tint(Theme.violet)))
    }

    // MARK: Decisiones

    private var decisions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Implement fix", isOn: $selection.implement)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Implement fix for \(RespondItemHeader.location(feedback))")
            if selection.implement {
                editor(text: $selection.fixPlan, field: .fixPlan(item.id), height: 80,
                       label: "Fix plan for \(RespondItemHeader.location(feedback))")
                Text("Claude implements this plan in the worktree; PRBar makes a commit (without hooks) and you see the diff before pushing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Reply", isOn: $selection.reply)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Reply to \(feedback.reviewer) on \(RespondItemHeader.location(feedback))")
            if selection.reply {
                editor(text: $selection.replyText, field: .reply(item.id), height: 64,
                       label: "Reply to \(feedback.reviewer)")
                Text(replyCaption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var replyCaption: String {
        let empty = selection.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selection.implement {
            let fixed = PublishedPhrases.fixedIn("<commit>", language: language)
            return empty
                ? "Only “\(fixed)” is posted (if the fix changes anything)."
                : "If the fix is implemented, “\(fixed)” is added at the start."
        }
        return empty ? "Nothing is posted without text." : "Markdown · posted \(feedback.kind == .thread ? "in the thread" : "as a PR comment mentioning @\(feedback.reviewer)")."
    }

    private func editor(text: Binding<String>, field: RespondFocus, height: CGFloat, label: String) -> some View {
        TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .focused(focus, equals: field)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color(nsColor: .textBackgroundColor)))
            .cardBorder(cornerRadius: Theme.Radius.button, opacity: 0.15)
            .focusRing(focus.wrappedValue == field)
            .accessibilityLabel(label)
    }
}

/// Reviewer + `path:line` (o "Comentario general") + "desactualizado".
struct RespondItemHeader: View {
    let feedback: FeedbackItem

    static func location(_ feedback: FeedbackItem) -> String {
        guard let path = feedback.path else { return "General comment" }
        return feedback.line.map { "\(path):\($0)" } ?? path
    }

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(login: feedback.reviewer, url: nil, size: 16)
            Text(feedback.reviewer).font(.callout.weight(.semibold))
            Text(Self.location(feedback))
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Self.location(feedback))
            if feedback.isOutdated {
                StatusPill(text: "Outdated", color: Theme.orangeText, background: Theme.tint(Theme.orange))
                    .help("The code changed since this comment")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Un comentario del hilo: autor, fecha y texto.
private struct CommentBubble: View {
    let comment: FeedbackComment
    let lineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(comment.author).fontWeight(.semibold)
                Text("·")
                Text(ReviewDates.short(comment.createdAt))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(comment.body)
                .font(.callout)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 2)
        }
    }
}
