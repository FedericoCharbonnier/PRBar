import Foundation

/// El estado de una ventana de Merge (spec G.3): el detalle que muestra y el **head fijo**. El merge siempre usa
/// `shownHead` como `expectedHeadOid`. Un refresco (⌘R en la ventana o un snapshot nuevo del popover) que trae otro head
/// no cambia lo mostrado: marca la ventana como desactualizada (`newerHead`, el banner) hasta que el usuario recarga.
/// Con el mismo head, ⌘R reemplaza el detalle (checks y reviews nuevos).
@MainActor
public final class MergeWindowModel: ObservableObject {
    public nonisolated static let staleText = "New commits were pushed since you opened this — Reload"

    public let prID: String
    /// El `MergeRecord` de la sesión (el historial y el log del chat).
    public let recordID: UUID
    @Published public private(set) var detail: MergeDetail?
    /// El head que muestra la ventana; `nil` hasta la primera carga.
    @Published public private(set) var shownHead: String?
    /// Un refresco vio otro head: hay que recargar antes de mergear.
    @Published public private(set) var newerHead: String?
    @Published public private(set) var isLoading = false
    /// El error de la última carga (lo cargado antes queda).
    @Published public private(set) var loadError: String?
    /// El método elegido en el popup; `nil` = el por defecto del repo.
    @Published public var method: MergeMethod?

    private let fetch: @MainActor () async throws -> MergeDetail
    private var loadToken = UUID()
    /// `newerHead` lo puso un snapshot del popover (no GitHub): un snapshot posterior con el head mostrado lo borra.
    private var newerHeadFromSnapshot = false
    /// Un head de un snapshot que GitHub desmintió después (una carga trajo el mostrado): el snapshot está atrasado y
    /// no vuelve a poner el banner con ese head.
    private var disprovedHead: String?

    /// `detail`: ya cargado (modo de capturas, o la CLI que lo trajo antes).
    public init(prID: String, recordID: UUID, detail: MergeDetail? = nil,
                fetch: @escaping @MainActor () async throws -> MergeDetail) {
        self.prID = prID
        self.recordID = recordID
        self.detail = detail
        shownHead = detail?.headOid
        self.fetch = fetch
    }

    public var isStale: Bool { newerHead != nil }

    /// Primera carga: adopta lo que trae GitHub.
    public func load() async { await fetchDetail(adopt: true) }

    /// ⌘R: con el mismo head reemplaza el detalle; con otro, solo el banner.
    public func refresh() async { await fetchDetail(adopt: shownHead == nil) }

    /// "Reload" del banner: adopta el head nuevo.
    public func reload() async { await fetchDetail(adopt: true) }

    /// Se abre la ventana (spec G.8): la primera vez carga; reabierta (estaba cerrada) refresca, con el head fijo (uno
    /// nuevo da el banner); ya abierta, nada.
    public func opened(alreadyOpen: Bool) async {
        guard !isLoading else { return }
        if detail == nil {
            await load()
        } else if !alreadyOpen {
            await refresh()
        }
    }

    /// Un snapshot nuevo del popover: si trae otro head que el mostrado, banner. El mismo head solo borra un banner que
    /// puso otro snapshot (uno que vio GitHub con ⌘R queda: el popover pudo no verlo todavía). Un head que GitHub ya
    /// desmintió no lo pone de nuevo (el snapshot está atrasado).
    public func noteHead(_ head: String?) {
        guard let head, let shownHead else { return }
        if head == shownHead {
            if newerHeadFromSnapshot { setNewerHead(nil, fromSnapshot: false) }
            return
        }
        guard head != disprovedHead else { return }
        if newerHead == head { return }
        setNewerHead(head, fromSnapshot: true)
    }

    private func setNewerHead(_ head: String?, fromSnapshot: Bool) {
        newerHead = head
        newerHeadFromSnapshot = head != nil && fromSnapshot
    }

    private func fetchDetail(adopt: Bool) async {
        let token = UUID()
        loadToken = token
        isLoading = true
        do {
            let fresh = try await fetch()
            guard loadToken == token else { return }
            loadError = nil
            if adopt || fresh.headOid == shownHead {
                if newerHeadFromSnapshot, let snapshotHead = newerHead, snapshotHead != fresh.headOid {
                    disprovedHead = snapshotHead
                }
                detail = fresh
                shownHead = fresh.headOid
                setNewerHead(nil, fromSnapshot: false)
            } else {
                setNewerHead(fresh.headOid, fromSnapshot: false)
            }
        } catch {
            guard loadToken == token else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        isLoading = false
    }
}
