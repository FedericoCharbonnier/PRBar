import PRBarCore
import SwiftUI

/// La fila ancha de la lista de la ventana principal (spec M.1 "Fila"): avatar (PR ajeno) o ícono de estado (PR propio),
/// título en dos líneas, edad, `repo#N · base`, CI + `+adds −dels` y el pill de la acción a la derecha. La selección la
/// pinta `List` (fondo de acento, texto blanco).
struct PRListRow: View {
    let item: ClassifiedPR
    let model: AppModel
    let section: MainListSection

    private var pr: PullRequest { item.pr }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(pr.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(section.isQuiet ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The age moves on by itself (like the popover's rows).
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(RelativeAge.short(from: pr.updatedAt, now: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Text("\(pr.repo.name)#\(pr.number)")
                        .lineLimit(1)
                        .layoutPriority(2)
                    Text("·")
                    Text(pr.baseRef)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // The popover's status line: what the feedback is, or what blocks the merge.
                if item.category == .myFeedback {
                    FeedbackLabel(summary: ActionClassifier.newFeedback(pr, me: item.account))
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if item.category == .readyToMerge {
                    MergeStatusLabel(availability: model.mergeOptions(item).availability)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Fuera de Ready to Merge también avisa que la rama choca con la base (spec C.2).
                if item.category != .readyToMerge && model.isConflictsCandidate(item) {
                    ConflictsStatusLabel()
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // Spec LP.5: what the running job is doing.
                JobActivityRowLine(item: item, reviews: model.reviews, respond: model.respond)
                HStack(spacing: 6) {
                    CIIcon(state: pr.ciState).font(.caption2.weight(.bold))
                    // Never squeezed (they wrapped digit by digit next to a wide pill with the chat open).
                    DiffStat(additions: pr.additions, deletions: pr.deletions)
                    Spacer(minLength: 6)
                    PRRowAccessory(item: item, model: model, reviews: model.reviews, respond: model.respond,
                                   merges: model.merges)
                        .font(.subheadline.weight(.medium))
                        // In a tight row (the chat open) the pill's text truncates; the +/− stats don't.
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // One element with one label (with `.contain` VoiceOver read the title again in the children); the pill is
        // a custom action, the same one ↩ runs.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if let title = rowAction.title {
                Button(title) { model.performPrimaryAction(prID: item.id) }
            }
        }
        .help("\(pr.repo.fullName)#\(pr.number) · \(pr.title)")
    }

    @ViewBuilder
    private var leading: some View {
        if PopoverTabs.isMine(item) {
            Image(systemName: statusIcon.name)
                .font(.system(size: 17))
                .foregroundStyle(statusIcon.color)
                .accessibilityHidden(true)
        } else {
            AvatarView(login: pr.author, url: pr.authorAvatarURL, size: 28)
        }
    }

    /// El estado de un PR propio según su sección.
    private var statusIcon: (name: String, color: Color) {
        switch section {
        case .withFeedback: ("bubble.left.and.exclamationmark.bubble.right", Theme.orange)
        case .ciFailing: ("xmark.octagon.fill", Theme.red)
        case .readyToMerge: ("checkmark.circle.fill", Theme.green)
        default: ("clock", .secondary)
        }
    }

    private var rowAction: PRPrimaryAction {
        let respondPhase = model.respond.phases[item.id]
        return PRPrimaryAction.of(item, review: model.reviews.phases[item.id], respond: respondPhase,
                                  respondMode: respondPhase == nil ? nil : model.respond.mode(of: item.id))
    }

    private var accessibilityLabel: String {
        var parts = [pr.title, "\(pr.repo.name) number \(pr.number)", "by \(pr.author)", "into \(pr.baseRef)",
                     "updated \(RelativeAge.short(from: pr.updatedAt)) ago"]
        if let ci = CIIcon.label(for: pr.ciState) { parts.append(ci) }
        parts.append("\(pr.additions) \(pr.additions == 1 ? "line" : "lines") added, \(pr.deletions) removed")
        if item.category == .myFeedback {
            parts.append(FeedbackLabel.text(for: ActionClassifier.newFeedback(pr, me: item.account)))
        }
        if model.isConflictsCandidate(item) { parts.append(MergePolicy.conflicts) }
        return parts.joined(separator: ", ")
    }
}

/// "+46 −12" on one line, never compressed: when the row is tight, the title and the pill give way.
struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(Theme.greenText)
            Text("−\(deletions)").foregroundStyle(Theme.redText)
        }
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(2)
    }
}
