import Foundation

/// Lo que hace el pill de una fila (y ↩ en la lista) y la pestaña que abre (spec M.1, M.3).
public enum PRPrimaryAction: Equatable, Sendable {
    case startReview, openReview, startRespond, openRespond, startCIFix, openCIFix, startConflicts, openConflicts, openMerge, none

    public var tab: PRTab? {
        switch self {
        case .startReview, .openReview: .review
        // Resolve Conflicts se ve en la pestaña Respond (decisión C.9.8).
        case .startRespond, .openRespond, .startConflicts, .openConflicts: .respond
        case .startCIFix, .openCIFix: .fixCI
        case .openMerge: .merge
        case .none: nil
        }
    }

    /// The action's name for VoiceOver (the row's custom action); nil for `.none`.
    public var title: String? {
        switch self {
        case .startReview: "Start Review"
        case .openReview: "Open Review"
        case .startRespond: "Start Respond"
        case .openRespond: "Open Respond"
        case .startCIFix: "Start Fix CI"
        case .openCIFix: "Open Fix CI"
        case .startConflicts: "Start Resolve Conflicts"
        case .openConflicts: "Open Resolve Conflicts"
        case .openMerge: "Open Merge"
        case .none: nil
        }
    }

    public var startsJob: Bool {
        self == .startReview || self == .startRespond || self == .startCIFix || self == .startConflicts
    }

    public static func of(_ item: ClassifiedPR, review: ReviewPhase?, respond: RespondPhase?,
                          respondMode: RespondMode?) -> PRPrimaryAction {
        if respondMode == .conflicts, respond != nil { return .openConflicts }
        if respondMode == .ciFix, respond != nil { return .openCIFix }
        // Spec C.2: con conflictos GitHub no corre el CI del merge, así que Resolve Conflicts prima sobre Fix CI.
        let offersConflicts = PopoverTabs.isMine(item) && item.pr.merge.hasConflicts && respond == nil
        switch item.category {
        case .toReview, .updatedSinceMyReview:
            if case .failed? = review { return .startReview }
            return review == nil ? .startReview : .openReview
        case .myFeedback:
            if case .failed? = respond { return .startRespond }
            return respond == nil ? .startRespond : .openRespond
        case .readyToMerge:
            return offersConflicts ? .startConflicts : .openMerge
        case .other:
            if offersConflicts { return .startConflicts }
            return PopoverTabs.isMine(item) && item.pr.ciState == .failure && respond == nil ? .startCIFix : .none
        }
    }
}
