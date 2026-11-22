import PRBarCore
import SwiftUI

/// Lo que hacen los botones de una fila de PR (el pill y el menú contextual), en el popover y en la lista de la ventana
/// principal (`AppModel.rowActions`).
struct PRRowActions {
    var review: ReviewButtonActions
    var respond: RespondButtonActions
    var ciFix: RespondButtonActions
    var merge: MergeButtonActions
}

/// El pill de la derecha de una fila (Review, N findings, Respond, Fix CI, Merge…), con el progreso en vivo. Lo
/// comparten `PRRowView` (popover) y `PRListRow` (ventana principal).
struct PRRowAccessory: View {
    let item: ClassifiedPR
    let model: AppModel
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue
    @ObservedObject var merges: MergeQueue

    var body: some View {
        let actions = model.rowActions(item)
        if hasCIFix {
            RespondButton(
                phase: respond.phases[item.id], runningTests: respond.runningTests.contains(item.id),
                unavailableReason: model.ciFixUnavailableReason(item), hasRecord: respond.records[item.id] != nil,
                actions: actions.ciFix, isCI: true
            )
        } else {
            categoryAccessory(actions)
        }
    }

    /// The PR's Respond slot holds a Fix CI (spec K).
    private var hasCIFix: Bool { respond.modes[item.id] == .ciFix && respond.phases[item.id] != nil }
    /// "Fix CI" goes on the row: a PR of mine whose CI failed, with nothing in its Respond slot.
    private var offersFixCI: Bool { model.isCIFixCandidate(item) && respond.phases[item.id] == nil }

    @ViewBuilder
    private func categoryAccessory(_ actions: PRRowActions) -> some View {
        switch item.category {
        case .myFeedback:
            HStack(spacing: 6) {
                if offersFixCI {
                    FixCIButton(unavailableReason: model.ciFixUnavailableReason(item), start: actions.ciFix.start)
                }
                RespondButton(
                    phase: respond.phases[item.id], runningTests: respond.runningTests.contains(item.id),
                    unavailableReason: model.respondUnavailableReason(item), hasRecord: respond.records[item.id] != nil,
                    actions: actions.respond
                )
            }
        case .toReview, .updatedSinceMyReview:
            ReviewButton(phase: reviews.phases[item.id], unavailableReason: model.jobsBlockedReason, actions: actions.review)
        case .readyToMerge:
            MergeButton(phase: merges.phases[item.id], availability: model.mergeOptions(item).availability, actions: actions.merge)
        default:
            if offersFixCI {
                FixCIButton(unavailableReason: model.ciFixUnavailableReason(item), start: actions.ciFix.start)
            } else {
                EmptyView()
            }
        }
    }
}
