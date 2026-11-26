import PRBarCore
import SwiftUI

/// Lo que hacen los botones de una fila de PR (el pill y el menú contextual), en el popover y en la lista de la ventana
/// principal (`AppModel.rowActions`).
struct PRRowActions {
    var review: ReviewButtonActions
    var respond: RespondButtonActions
    var ciFix: RespondButtonActions
    var conflicts: RespondButtonActions
    var merge: MergeButtonActions
}

/// El pill de la derecha de una fila (Review, N findings, Respond, Fix CI, Resolve Conflicts, Merge…), con el progreso en vivo. Lo
/// comparten `PRRowView` (popover) y `PRListRow` (ventana principal).
struct PRRowAccessory: View {
    let item: ClassifiedPR
    let model: AppModel
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    @ObservedObject var merges: MergeQueue

    var body: some View {
        let actions = model.rowActions(item)
        if let mode = slotMode {
            RespondButton(
                phase: respond.phases[item.id], runningTests: respond.runningTests.contains(item.id),
                unavailableReason: mode == .ciFix ? model.ciFixUnavailableReason(item) : model.conflictsUnavailableReason(item),
                hasRecord: respond.records[item.id] != nil,
                actions: mode == .ciFix ? actions.ciFix : actions.conflicts, mode: mode,
                steps: respondSteps
            )
        } else {
            categoryAccessory(actions)
        }
    }

    /// The running jobs' steps (spec LP.5) are read by the pills' tooltips alone (`jobStepHelp`): a step change of any
    /// PR doesn't re-evaluate this view.
    private var respondSteps: JobStepSource { JobStepSource(feed: respond.activityFeed, prID: item.id) }

    /// The PR's Respond slot holds a Fix CI or a Resolve Conflicts (specs K, C).
    private var slotMode: RespondMode? {
        guard respond.phases[item.id] != nil, let mode = respond.modes[item.id], mode != .feedback else { return nil }
        return mode
    }
    /// "Resolve Conflicts" goes on the row: a PR of mine with conflicts and nothing in its Respond slot. It wins over Fix CI.
    private var offersConflicts: Bool { model.isConflictsCandidate(item) && respond.phases[item.id] == nil }
    /// "Fix CI" goes on the row: a PR of mine whose CI failed, with nothing in its Respond slot (and no conflicts).
    private var offersFixCI: Bool { !offersConflicts && model.isCIFixCandidate(item) && respond.phases[item.id] == nil }

    /// Resolve Conflicts o Fix CI, al lado de Respond o solo (decisión C.9.8).
    @ViewBuilder
    private func secondaryButton(_ actions: PRRowActions) -> some View {
        if offersConflicts {
            ResolveConflictsButton(unavailableReason: model.conflictsUnavailableReason(item), start: actions.conflicts.start)
        } else if offersFixCI {
            FixCIButton(unavailableReason: model.ciFixUnavailableReason(item), start: actions.ciFix.start)
        }
    }

    @ViewBuilder
    private func categoryAccessory(_ actions: PRRowActions) -> some View {
        switch item.category {
        case .myFeedback:
            HStack(spacing: 6) {
                secondaryButton(actions)
                RespondButton(
                    phase: respond.phases[item.id], runningTests: respond.runningTests.contains(item.id),
                    unavailableReason: model.respondUnavailableReason(item), hasRecord: respond.records[item.id] != nil,
                    actions: actions.respond, steps: respondSteps
                )
            }
        case .toReview, .updatedSinceMyReview:
            ReviewButton(phase: reviews.phases[item.id], unavailableReason: model.jobsBlockedReason, actions: actions.review,
                         steps: JobStepSource(feed: reviews.activityFeed, prID: item.id))
        case .readyToMerge:
            // Con conflictos, Resolve Conflicts reemplaza al Merge deshabilitado (spec C.2).
            if offersConflicts {
                ResolveConflictsButton(unavailableReason: model.conflictsUnavailableReason(item), start: actions.conflicts.start)
            } else {
                MergeButton(phase: merges.phases[item.id], availability: model.mergeOptions(item).availability, actions: actions.merge)
            }
        default:
            secondaryButton(actions)
        }
    }
}
