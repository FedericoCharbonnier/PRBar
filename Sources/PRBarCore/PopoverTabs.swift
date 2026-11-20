import Combine
import Foundation

/// Las dos pestañas del popover (spec H.1). El `rawValue` es el de la CLI (`--tab`) y el de `UserDefaults`.
public enum PopoverTab: String, Codable, CaseIterable, Sendable, Identifiable {
    case toReview = "to-review"
    case mine

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .mine: "My PRs"
        }
    }
}

/// Una sección del popover. Las de siempre (una por `PRCategory` accionable) más las dos "calladas": Other (PRs
/// ajenos sin nada que hacer) y Waiting for Review (mis PRs sin nada que hacer). Spec H.1.
public enum PopoverSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case toReview
    case updatedSinceMyReview
    case otherToReview = "other"
    case myFeedback
    case readyToMerge
    case waitingForReview = "waiting"

    public var id: String { rawValue }

    public var category: PRCategory {
        switch self {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .otherToReview, .waitingForReview: .other
        case .myFeedback: .myFeedback
        case .readyToMerge: .readyToMerge
        }
    }

    public var tab: PopoverTab {
        switch self {
        case .toReview, .updatedSinceMyReview, .otherToReview: .toReview
        case .myFeedback, .readyToMerge, .waitingForReview: .mine
        }
    }

    public var title: String {
        switch self {
        case .otherToReview: "Other"
        case .waitingForReview: "Waiting for Review"
        default: category.title
        }
    }

    public var subtitle: String? {
        switch self {
        case .otherToReview: "drafts and nothing to do"
        case .waitingForReview: "no new feedback, not ready to merge"
        default: nil
        }
    }

    /// Colapsada al abrir, atenuada y sin contar en el badge ni en el contador de la pestaña.
    public var isQuiet: Bool { self == .otherToReview || self == .waitingForReview }
}

/// Reparto de los PRs del snapshot entre pestañas y secciones. No clasifica: usa la categoría de §7.
public enum PopoverTabs {
    /// El PR es de la cuenta desde la que se ve (sin distinguir mayúsculas, como GitHub).
    public static func isMine(_ item: ClassifiedPR) -> Bool {
        item.pr.author.caseInsensitiveCompare(item.account) == .orderedSame
    }

    public static func section(of item: ClassifiedPR) -> PopoverSection {
        switch item.category {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .myFeedback: .myFeedback
        case .readyToMerge: .readyToMerge
        case .other: isMine(item) ? .waitingForReview : .otherToReview
        }
    }

    public static func tab(of item: ClassifiedPR) -> PopoverTab { section(of: item).tab }

    /// En el orden en que se muestran: primero las accionables, la callada al final.
    public static func sections(_ tab: PopoverTab) -> [PopoverSection] {
        PopoverSection.allCases.filter { $0.tab == tab }
    }

    public static func items(_ section: PopoverSection, in snapshot: Snapshot) -> [ClassifiedPR] {
        snapshot.items(in: section.category).filter { self.section(of: $0) == section }
    }

    /// PRs accionables de la pestaña (lo que suma el badge).
    public static func count(_ tab: PopoverTab, in snapshot: Snapshot) -> Int {
        snapshot.items.filter { $0.category.countsForBadge && self.tab(of: $0) == tab }.count
    }

    public static func counts(in snapshot: Snapshot?) -> [PopoverTab: Int] {
        Dictionary(uniqueKeysWithValues: PopoverTab.allCases.map { tab in (tab, snapshot.map { count(tab, in: $0) } ?? 0) })
    }

    public static func emptyState(_ tab: PopoverTab) -> (title: String, text: String) {
        switch tab {
        case .toReview: ("Nothing to review 🎉", "No PRs are waiting for your review.")
        case .mine: ("No PRs of yours need anything", "No new feedback and nothing ready to merge.")
        }
    }

    /// Etiqueta del control segmentado: el control nativo ignora colores, así que el "punto de acento" es `•`
    /// (spec H.1: pestaña no elegida con algo pendiente).
    public static func label(_ tab: PopoverTab, count: Int, selected: Bool) -> String {
        "\(tab.title) \(count)" + (!selected && count > 0 ? " •" : "")
    }

    public static func accessibilityLabel(_ tab: PopoverTab, count: Int) -> String {
        "\(tab.title), \(count) \(count == 1 ? "needs" : "need") your action"
    }
}

/// La pestaña elegida del popover; se recuerda entre aperturas y reinicios (`UserDefaults`, clave `popoverTab`).
/// La cambian el control segmentado, ⌘1/⌘2, `prbar app popover --tab` y el clic en una notificación de un PR.
@MainActor
public final class PopoverTabState: ObservableObject {
    public nonisolated static let defaultsKey = "popoverTab"

    private let defaults: UserDefaults

    @Published public var selected: PopoverTab {
        didSet { defaults.set(selected.rawValue, forKey: Self.defaultsKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.defaultsKey).flatMap(PopoverTab.init(rawValue:)) ?? .toReview
    }
}
