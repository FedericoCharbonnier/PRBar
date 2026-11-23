import Foundation

/// Lo que hace el pill de una fila (y ↩ en la lista) y la pestaña que abre (spec M.1, M.3).
public enum PRPrimaryAction: Equatable, Sendable {
    case startReview, openReview, startRespond, openRespond, startCIFix, openCIFix, openMerge, none

    public var tab: PRTab? {
        switch self {
        case .startReview, .openReview: .review
        case .startRespond, .openRespond: .respond
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
        case .openMerge: "Open Merge"
        case .none: nil
        }
    }

    public var startsJob: Bool { self == .startReview || self == .startRespond || self == .startCIFix }

    public static func of(_ item: ClassifiedPR, review: ReviewPhase?, respond: RespondPhase?,
                          respondMode: RespondMode?) -> PRPrimaryAction {
        if respondMode == .ciFix, respond != nil { return .openCIFix }
        switch item.category {
        case .toReview, .updatedSinceMyReview:
            if case .failed? = review { return .startReview }
            return review == nil ? .startReview : .openReview
        case .myFeedback:
            if case .failed? = respond { return .startRespond }
            return respond == nil ? .startRespond : .openRespond
        case .readyToMerge:
            return .openMerge
        case .other:
            return PopoverTabs.isMine(item) && item.pr.ciState == .failure && respond == nil ? .startCIFix : .none
        }
    }
}
