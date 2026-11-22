import Foundation

/// Las secciones de la lista de la ventana principal (spec M.1 "Lista"). Reparte con `PopoverTabs` (la misma
/// clasificación que el popover) y separa "CI Failing" de los PRs míos que esperan review.
public enum MainListSection: String, CaseIterable, Identifiable, Sendable {
    case toReview, updatedSinceMyReview, otherToReview
    case withFeedback, ciFailing, readyToMerge, waitingForReview

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .updatedSinceMyReview: "Updated Since My Review"
        case .otherToReview: "Other"
        case .withFeedback: "With Feedback"
        case .ciFailing: "CI Failing"
        case .readyToMerge: "Ready to Merge"
        case .waitingForReview: "Waiting for Review"
        }
    }

    public var mainSection: MainSection {
        switch self {
        case .toReview, .updatedSinceMyReview, .otherToReview: .toReview
        default: .myPRs
        }
    }

    /// Plegada al abrir y atenuada (como en el popover).
    public var isQuiet: Bool { self == .otherToReview || self == .waitingForReview }

    /// Sus PRs piden una acción y suman al contador de la barra lateral (y al de la pestaña del popover y al badge de la
    /// barra de menú, que cuentan lo mismo): To Review y Updated Since My Review; With Feedback y Ready to Merge.
    /// Other, CI Failing y Waiting for Review no suman.
    public var needsAction: Bool {
        switch self {
        case .toReview, .updatedSinceMyReview, .withFeedback, .readyToMerge: true
        case .otherToReview, .ciFailing, .waitingForReview: false
        }
    }
}

public enum MainList {
    public static func mainSection(of item: ClassifiedPR) -> MainSection {
        PopoverTabs.tab(of: item) == .mine ? .myPRs : .toReview
    }

    public static func section(of item: ClassifiedPR) -> MainListSection {
        switch PopoverTabs.section(of: item) {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .otherToReview: .otherToReview
        case .myFeedback: .withFeedback
        case .readyToMerge: .readyToMerge
        case .waitingForReview: item.pr.ciState == .failure ? .ciFailing : .waitingForReview
        }
    }

    public static func sections(_ section: MainSection) -> [MainListSection] {
        MainListSection.allCases.filter { $0.mainSection == section }
    }

    /// En el orden del snapshot, filtrados por la búsqueda.
    public static func items(_ section: MainListSection, in snapshot: Snapshot, query: String = "") -> [ClassifiedPR] {
        snapshot.items.filter { self.section(of: $0) == section && ListSearch.matches($0.pr, query: query) }
    }

    /// El contador de la barra lateral: los PRs de las secciones que piden acción (`needsAction`), el mismo número
    /// que la pestaña del popover. nil sin datos.
    public static func count(_ section: MainSection, in snapshot: Snapshot?) -> Int? {
        snapshot.map { snapshot in
            sections(section).filter(\.needsAction).reduce(0) { $0 + items($1, in: snapshot).count }
        }
    }

    public static func initiallyCollapsed(_ section: MainListSection, itemCount: Int) -> Bool {
        itemCount == 0 || section.isQuiet
    }

    /// Borradores de otros que quedan en "Other" (el aviso "N drafts hidden · Show" del vacío).
    public static func hiddenDraftCount(in snapshot: Snapshot) -> Int {
        items(.otherToReview, in: snapshot).filter(\.pr.isDraft).count
    }
}
