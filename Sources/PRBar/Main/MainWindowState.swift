import PRBarCore
import SwiftUI

/// Las pestañas de la toolbar en History (spec M.1 "History").
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, reviews, responds, merges

    var id: String { rawValue }
    /// All · Reviews · Responds · Merges.
    var title: String { rawValue.capitalized }
}

/// La ventana principal mientras la app está abierta: sobrevive a cerrarla con ⌘W (`WindowPresenter` arma la vista de
/// cero al reabrirla, el estado queda acá).
@MainActor
final class MainWindowState: ObservableObject {
    @Published private(set) var nav = MainNavigationState()
    @Published var search = ""
    /// Secciones plegadas o desplegadas a mano (las demás siguen `MainList.initiallyCollapsed`).
    @Published private var collapsedByUser: [MainListSection: Bool] = [:]
    @Published var updateSheet: UpdateWindowMode?
    @Published var historyFilter: HistoryFilter = .all
    let detail = PRDetailState()
    /// Los registros de History (lista y detalle).
    let history = HistoryEntries()

    /// `navigate(to:)`: mueve la ventana y empuja el lugar anterior a Back. Cambiar de sección limpia la búsqueda.
    func go(to destination: MainDestination, snapshot: Snapshot?) {
        let before = nav.place.sidebar
        let destination = destination.canonicalized(among: snapshot?.items.map(\.id) ?? [])
        nav.go(to: destination) { prID in Self.section(of: prID, in: snapshot) }
        if nav.place.sidebar != before { search = "" }
        // Un registro pedido (notificación, `prbar app history <id>`) tiene que verse: sin filtro ni búsqueda.
        if case .history(let recordID?) = destination, !history.matchesFilters(recordID, historyFilter, query: search) {
            historyFilter = .all
            search = ""
        }
    }

    /// Con cada snapshot: el PR elegido pasa a su sección si quedó en otra (se navegó antes de tener datos).
    func reconcile(with snapshot: Snapshot) {
        let ids = snapshot.items.map(\.id)
        var next = nav
        next.reconcile(ids: ids) { prID in Self.section(of: prID, in: snapshot) }
        if next != nav { nav = next }
    }

    private static func section(of prID: String, in snapshot: Snapshot?) -> MainSection? {
        snapshot?.items.first { $0.id == prID }.map(MainList.mainSection(of:))
    }

    func select(prID: String?) { nav.select(prID: prID) }
    func select(historyRecord id: UUID?) { nav.select(historyRecord: id) }
    func choose(_ tab: PRTab, for prID: String) { nav.choose(tab, for: prID) }
    func goBack() { nav.goBack() }

    func isCollapsed(_ section: MainListSection, itemCount: Int) -> Bool {
        collapsedByUser[section] ?? MainList.initiallyCollapsed(section, itemCount: itemCount)
    }

    func setCollapsed(_ collapsed: Bool, _ section: MainListSection) { collapsedByUser[section] = collapsed }
}

extension UpdateWindowMode: Identifiable {}
