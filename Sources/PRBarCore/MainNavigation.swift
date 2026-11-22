import Foundation

/// Las secciones con lista de PRs de la barra lateral (spec M.1).
public enum MainSection: String, CaseIterable, Codable, Sendable {
    case toReview, myPRs

    public var title: String { self == .toReview ? "To Review" : "My PRs" }
}

/// Las pestañas del detalle de un PR (spec M.1, M.4).
public enum PRTab: String, CaseIterable, Codable, Sendable {
    case review, details, merge, respond, fixCI

    public var title: String {
        switch self {
        case .review: "Review"
        case .details: "Details"
        case .merge: "Merge"
        case .respond: "Respond"
        case .fixCI: "Fix CI"
        }
    }

    /// En los links `prbar://pr/<owner>/<repo>/<n>/<tab>`.
    public var urlName: String { self == .fixCI ? "fix-ci" : rawValue }

    public init?(urlName: String) {
        switch urlName.lowercased() {
        case "fix-ci", "fixci": self = .fixCI
        case let name: guard let tab = PRTab(rawValue: name), tab != .fixCI else { return nil }; self = tab
        }
    }
}

/// A dónde lleva `AppModel.navigate(to:)` (spec M.4).
public enum MainDestination: Hashable, Sendable {
    case list(MainSection)
    /// `tab == nil`: la recordada para ese PR o la inicial según su estado.
    case pr(prID: String, tab: PRTab?)
    case history(recordID: UUID?)
    case activity

    /// El mismo destino con el id del PR como está en `ids` (sin distinguir mayúsculas: un link `prbar://` puede venir
    /// escrito a mano). Si no está, queda como vino.
    public func canonicalized(among ids: [String]) -> MainDestination {
        guard case .pr(let prID, let tab) = self else { return self }
        return .pr(prID: MainNavigationState.canonicalPRID(prID, among: ids), tab: tab)
    }
}

/// Lo elegido en la barra lateral.
public enum SidebarItem: Hashable, Sendable {
    case section(MainSection)
    case history
    case activity
}

/// Lo que hace falta saber de un PR para elegir sus pestañas.
public struct PRTabContext: Equatable, Sendable {
    public var isMine: Bool
    /// Tiene cambios pedidos o comentarios nuevos (categoría My PRs with Feedback).
    public var hasFeedback: Bool
    public var ciFailing: Bool
    /// Lo que ocupa el lugar de Respond del PR (`RespondQueue.records` o `phases`), en cualquier fase.
    public var respondTask: RespondMode?

    public init(isMine: Bool, hasFeedback: Bool, ciFailing: Bool, respondTask: RespondMode?) {
        self.isMine = isMine
        self.hasFeedback = hasFeedback
        self.ciFailing = ciFailing
        self.respondTask = respondTask
    }

    public init(item: ClassifiedPR, respondTask: RespondMode?) {
        self.init(isMine: PopoverTabs.isMine(item), hasFeedback: item.category == .myFeedback,
                  ciFailing: item.pr.ciState == .failure, respondTask: respondTask)
    }
}

public struct PRTabItem: Equatable, Sendable {
    public let tab: PRTab
    public let isEnabled: Bool
}

/// Pestañas disponibles e inicial (spec M.1 "Detalle del PR: pestañas").
public enum PRTabs {
    public static func tabs(_ c: PRTabContext) -> [PRTabItem] {
        guard c.isMine else {
            return [PRTabItem(tab: .review, isEnabled: true), PRTabItem(tab: .details, isEnabled: true)]
        }
        return [
            PRTabItem(tab: .merge, isEnabled: true),
            PRTabItem(tab: .respond, isEnabled: c.hasFeedback || c.respondTask == .feedback),
            PRTabItem(tab: .fixCI, isEnabled: c.ciFailing || c.respondTask == .ciFix),
        ]
    }

    public static func initial(_ c: PRTabContext) -> PRTab {
        guard c.isMine else { return .review }
        if c.hasFeedback { return .respond }
        if c.ciFailing { return .fixCI }
        switch c.respondTask {
        case .feedback?: return .respond
        case .ciFix?: return .fixCI
        case nil: return .merge
        }
    }

    /// La recordada si el PR la tiene y está habilitada; si no, la inicial.
    public static func resolve(remembered: PRTab?, context c: PRTabContext) -> PRTab {
        if let remembered, tabs(c).contains(PRTabItem(tab: remembered, isEnabled: true)) { return remembered }
        return initial(c)
    }

    /// ⌥⌘1…3 (`index` empieza en 1); nil fuera de rango o deshabilitada.
    public static func tab(atShortcut index: Int, _ c: PRTabContext) -> PRTab? {
        let all = tabs(c)
        guard all.indices.contains(index - 1), all[index - 1].isEnabled else { return nil }
        return all[index - 1].tab
    }
}

/// Un lugar de la ventana principal (lo que guarda la pila de Back).
public struct MainPlace: Hashable, Sendable {
    public var sidebar: SidebarItem
    public var prID: String?
    public var historyRecordID: UUID?

    public init(sidebar: SidebarItem, prID: String? = nil, historyRecordID: UUID? = nil) {
        self.sidebar = sidebar
        self.prID = prID
        self.historyRecordID = historyRecordID
    }

    public static let start = MainPlace(sidebar: .section(.toReview))
}

/// Back (⌘[): los últimos 20 lugares.
public struct BackStack: Equatable, Sendable {
    public static let limit = 20
    public private(set) var places: [MainPlace] = []

    public init() {}

    public var canGoBack: Bool { !places.isEmpty }

    public mutating func push(_ place: MainPlace) {
        guard places.last != place else { return }
        places.append(place)
        if places.count > Self.limit { places.removeFirst(places.count - Self.limit) }
    }

    public mutating func pop() -> MainPlace? { places.popLast() }
}

/// Dónde está la ventana principal. `go(to:)` es lo que hace `navigate(to:)` y empuja el lugar anterior a Back;
/// elegir a mano en la lista o en History (`select`) y cambiar de pestaña (`choose`) no.
public struct MainNavigationState: Equatable, Sendable {
    public private(set) var place: MainPlace = .start
    public private(set) var back = BackStack()
    /// La pestaña elegida por PR mientras la app está abierta.
    public private(set) var rememberedTabs: [String: PRTab] = [:]
    /// El último PR elegido en cada sección (⌘1/⌘2 vuelven a él).
    public private(set) var selectedPRs: [MainSection: String] = [:]

    public init() {}

    public var section: MainSection? {
        if case .section(let section) = place.sidebar { return section }
        return nil
    }

    /// `sectionOf`: la sección de un PR en el snapshot de ahora (nil si no está).
    public mutating func go(to destination: MainDestination, sectionOf: (String) -> MainSection?) {
        switch destination {
        case .list(let section):
            move(to: MainPlace(sidebar: .section(section), prID: selectedPRs[section]))
        case .pr(let prID, let tab):
            if let tab { rememberedTabs[prID] = tab }
            let section = sectionOf(prID) ?? self.section ?? .toReview
            move(to: MainPlace(sidebar: .section(section), prID: prID))
        case .history(let recordID):
            let keep = place.sidebar == .history ? place.historyRecordID : nil
            move(to: MainPlace(sidebar: .history, historyRecordID: recordID ?? keep))
        case .activity:
            move(to: MainPlace(sidebar: .activity))
        }
    }

    /// Con cada snapshot (`sectionOf` y `ids` son los suyos): el PR elegido toma el id del snapshot y, si quedó en otra
    /// sección (p. ej. se navegó antes del primer snapshot y cayó en To Review), pasa a la suya. No empuja nada a Back.
    public mutating func reconcile(ids: [String], sectionOf: (String) -> MainSection?) {
        guard let current = section, let prID = place.prID else { return }
        let id = Self.canonicalPRID(prID, among: ids)
        guard let target = sectionOf(id), target != current || id != prID else { return }
        if id != prID, let tab = rememberedTabs.removeValue(forKey: prID), rememberedTabs[id] == nil {
            rememberedTabs[id] = tab
        }
        if selectedPRs[current] == prID { selectedPRs[current] = nil }
        place = MainPlace(sidebar: .section(target), prID: id)
        selectedPRs[target] = id
    }

    /// `owner/repo#N` como está en `ids`, sin distinguir mayúsculas; si no está, el mismo.
    public static func canonicalPRID(_ prID: String, among ids: [String]) -> String {
        guard let reference = PRReference.parse(prID), case .full = reference,
              case .success(let id) = reference.resolve(among: ids) else { return prID }
        return id
    }

    public mutating func select(prID: String?) {
        guard let section else { return }
        place.prID = prID
        selectedPRs[section] = prID
    }

    public mutating func select(historyRecord id: UUID?) {
        guard place.sidebar == .history else { return }
        place.historyRecordID = id
    }

    public mutating func choose(_ tab: PRTab, for prID: String) { rememberedTabs[prID] = tab }

    public func tab(for prID: String, context: PRTabContext) -> PRTab {
        PRTabs.resolve(remembered: rememberedTabs[prID], context: context)
    }

    public mutating func goBack() {
        guard let previous = back.pop() else { return }
        place = previous
        if case .section(let section) = previous.sidebar { selectedPRs[section] = previous.prID }
    }

    private mutating func move(to next: MainPlace) {
        guard next != place else { return }
        back.push(place)
        place = next
        if case .section(let section) = next.sidebar { selectedPRs[section] = next.prID }
    }
}

/// Medidas de la ventana principal que dependen del ancho (spec M.1).
public enum MainLayout {
    /// La lista: 32 % del ancho de la ventana, entre 280 y 340 pt.
    public static func listWidth(windowWidth: Double) -> Double { min(max(windowWidth * 0.32, 280), 340) }
}
