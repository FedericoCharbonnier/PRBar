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
    case otherToReview
    case myFeedback
    case readyToMerge
    case waitingForReview

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
        case .waitingForReview: "nothing to do right now"
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

    /// Lo que lee VoiceOver de una pestaña: el `•` no se lee, así que se dice con palabras.
    public static func accessibilityLabel(_ tab: PopoverTab, count: Int, selected: Bool) -> String {
        "\(tab.title), \(needs(count))" + (!selected && count > 0 ? ", has pending items" : "")
    }

    /// Valor del control entero: describe las dos pestañas por si el segmentado nativo ignora las etiquetas de
    /// cada segmento ("To Review selected, 3 need your action; My PRs, 2 need your action, has pending items").
    public static func accessibilityValue(counts: [PopoverTab: Int], selected: PopoverTab) -> String {
        PopoverTab.allCases.map { tab in
            let count = counts[tab] ?? 0
            return tab == selected ? "\(tab.title) selected, \(needs(count))"
                                   : accessibilityLabel(tab, count: count, selected: false)
        }.joined(separator: "; ")
    }

    private static func needs(_ count: Int) -> String {
        "\(count) \(count == 1 ? "needs" : "need") your action"
    }
}

/// Dónde se guarda la pestaña del popover. `UserDefaults` en la app; los tests usan uno en memoria (así no dejan
/// `.plist` en `~/Library/Preferences`).
public protocol PopoverTabStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PopoverTabStore {}

/// La pestaña elegida del popover; se recuerda entre aperturas y reinicios (clave `popoverTab`). La cambian el
/// control segmentado, ⌘1/⌘2 y `prbar app popover --tab`. El clic en una notificación de un PR la cambia solo para
/// la próxima apertura (`selectForNextOpening`, spec H.4.7): al cerrarse el popover vuelve la guardada.
@MainActor
public final class PopoverTabState: ObservableObject {
    public nonisolated static let defaultsKey = "popoverTab"

    private let store: (any PopoverTabStore)?
    /// La que eligió el usuario (la guardada).
    private var saved: PopoverTab
    /// `selected` es temporal (la puso una notificación) y todavía no se mostró / ya se está mostrando.
    private var transient: (shown: Bool, active: Bool) = (false, false)
    private var isOpen = false
    private var settingTransiently = false

    @Published public var selected: PopoverTab {
        didSet {
            guard !settingTransiently else { return }
            saved = selected
            transient = (false, false)
            store?.set(selected.rawValue, forKey: Self.defaultsKey)
        }
    }

    /// `store == nil`: se recuerda solo en memoria (el modo de capturas, que no escribe fuera de su carpeta).
    public init(store: (any PopoverTabStore)? = UserDefaults.standard) {
        self.store = store
        let initial = store?.string(forKey: Self.defaultsKey).flatMap(PopoverTab.init(rawValue:)) ?? .toReview
        saved = initial
        selected = initial
    }

    /// Muestra `tab` en la próxima apertura (o ya, si el popover está abierto) sin guardarla.
    public func selectForNextOpening(_ tab: PopoverTab) {
        setSilently(tab)
        transient = (shown: isOpen, active: true)
    }

    public func popoverDidOpen() {
        isOpen = true
        if transient.active { transient.shown = true }
    }

    public func popoverDidClose() {
        isOpen = false
        guard transient.active, transient.shown else { return }
        transient = (false, false)
        setSilently(saved)
    }

    private func setSilently(_ tab: PopoverTab) {
        settingTransiently = true
        selected = tab
        settingTransiently = false
    }
}

/// Respuesta de `prbar app popover`.
public struct PopoverInfo: Codable, Equatable, Sendable {
    public var tab: PopoverTab
    /// `false` si no se pudo abrir el popover (la pestaña igual quedó elegida).
    public var shown: Bool

    public init(tab: PopoverTab, shown: Bool) {
        self.tab = tab
        self.shown = shown
    }
}
