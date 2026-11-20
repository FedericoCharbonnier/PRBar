import Foundation

/// Decisiones puras de "Merge…", la ventana de Merge, Retry y la CLI (spec F.3, F.8.11, G). `AppModel` solo las
/// ejecuta: abrir la ventana, mergear, mostrar el error o refrescar.
public enum MergeFlow {
    /// Qué hace "Merge…" (la fila, el menú contextual, la notificación): abrir la ventana de Merge (spec G.1), que es
    /// la confirmación y dice por qué no se puede si no se puede. Un PR ya mergeado no la abre.
    public enum RequestRoute: Equatable, Sendable {
        case ignore
        case open
    }

    public static func request(phase: MergePhase?) -> RequestRoute {
        if case .merged? = phase { return .ignore }
        return .open
    }

    /// Lo que verifica `prbar merge` (y `--preview`) contra el snapshot actual. `expectedHeadOid`: el head que la CLI
    /// le mostró al usuario (`nil` en la vista previa); si el PR cambió desde entonces no se mergea, así nunca se
    /// mergea un head que no se vio. Devuelve el método a usar.
    public static func commandCheck(
        _ item: ClassifiedPR, method: MergeMethod?, options: MergeOptions, blockedReason: String?, phase: MergePhase?,
        expectedHeadOid: String?
    ) -> Result<MergeMethod, CommandFailure> {
        let id = item.id
        guard item.category == .readyToMerge else {
            return .failure(CommandFailure(.invalidState, "\(id) isn’t in Ready to Merge. Run `prbar prs --list ready-to-merge`."))
        }
        if let blockedReason { return .failure(CommandFailure(.invalidState, blockedReason)) }
        switch phase {
        case .merging?: return .failure(CommandFailure(.invalidState, "\(id) is already being merged."))
        case .merged?: return .failure(CommandFailure(.invalidState, "\(id) was already merged."))
        default: break
        }
        if let problem = MergePolicy.problem(item, method: method, options: options) {
            return .failure(CommandFailure(.invalidState, problem.localizedDescription))
        }
        guard let chosen = method ?? options.defaultMethod else {
            return .failure(CommandFailure(.invalidState, "This repo doesn’t allow any merge method."))
        }
        if let expectedHeadOid {
            guard !expectedHeadOid.isEmpty else {
                return .failure(CommandFailure(.invalidUsage, "The merge request doesn’t say which head was confirmed. Update prbar."))
            }
            guard expectedHeadOid == item.pr.headOid else {
                return .failure(CommandFailure(.invalidState,
                    "\(id) changed since you looked at it (head \(item.pr.headOid.prefix(7)), you saw \(expectedHeadOid.prefix(7))). Run `prbar merge \(id)` again to see it."))
            }
        }
        return .success(chosen)
    }

    /// Por qué el botón Merge de la ventana está deshabilitado (spec G.2, F.8.19: nunca un silencio); `nil` = se puede.
    /// `current`: el PR en el snapshot actual. `shownHead`: el head que muestra la ventana (nil = cargando). `stale`: un
    /// refresco vio otro head. En orden: una actualización instalándose, el PR fuera de la lista, cargando, head nuevo,
    /// y lo que diga `MergePolicy` (Ready to Merge, `mergeStateStatus`, permiso, método).
    public static func windowProblem(
        current: ClassifiedPR?, options: MergeOptions?, method: MergeMethod?, shownHead: String?, stale: Bool,
        blockedReason: String?
    ) -> String? {
        if let blockedReason { return blockedReason }
        guard let current else { return "This PR isn’t in PRBar’s list anymore." }
        guard shownHead != nil, let options else { return "Loading…" }
        if stale { return MergeWindowModel.staleText }
        return MergePolicy.problem(current, method: method, options: options)?.localizedDescription
    }

    /// Qué hace Retry después de refrescar.
    public enum RetryRoute: Equatable, Sendable {
        /// Pedir de nuevo (`request`) con el PR refrescado y el mismo método.
        case request(ClassifiedPR, MergeMethod?)
        /// El PR cambió desde lo que se mostró: solo se limpia el error; la fila muestra el PR nuevo y el usuario
        /// vuelve a apretar Merge. Nunca se mergea un head que no se vio, con o sin confirmación.
        case changed
        /// El PR ya no está en la lista: hay que preguntarle a GitHub si se mergeó (`MergeQueue.resolveMissing`).
        case missing
    }

    /// `current`: el PR en el snapshot refrescado (`nil` si ya no está).
    public static func retry(_ failure: MergeFailure, current: ClassifiedPR?) -> RetryRoute {
        guard let current else { return .missing }
        if failure.error == .headChanged || current.pr.headOid != failure.item.pr.headOid { return .changed }
        return .request(current, failure.method)
    }
}
