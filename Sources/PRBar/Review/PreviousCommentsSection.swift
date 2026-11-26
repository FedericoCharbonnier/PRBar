import PRBarCore
import SwiftUI

/// "Previous comments" (spec RM.6): what PRBar posted before on this PR and whether Claude found it fixed. Only with
/// memory. Nothing here touches GitHub.
struct PreviousCommentsSection: View {
    let draft: ReviewDraft
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Previous comments").fontWeight(.semibold).foregroundColor(.primary)
                if let header = draft.previousHeader {
                    Text("· \(header)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            ForEach(draft.previous) { comment in row(comment) }
        }
        .padding(.bottom, 8)
    }

    private func row(_ comment: PreviousCommentStatus) -> some View {
        let isExpanded = expanded.contains(comment.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(comment.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(comment.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.tint(color(comment.status))))
                Text(comment.location)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("GitHub: \(comment.githubLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !comment.note.isEmpty {
                Text(comment.note)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if isExpanded { expanded.remove(comment.id) } else { expanded.insert(comment.id) }
            } label: {
                Label(isExpanded ? "Hide Posted Comment" : "Show Posted Comment",
                      systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if isExpanded {
                Text(comment.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(.separator))
    }

    private func color(_ status: PreviousStatus) -> Color {
        switch status {
        case .fixed: Theme.green
        case .notFixed: Theme.red
        case .partially: Theme.orange
        case .unclear: Color.secondary
        }
    }
}
