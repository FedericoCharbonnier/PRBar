import AppKit
import PRBarCore
import SwiftUI

/// Ready to Merge (spec F). La UI (fila, menú contextual, diálogo) y la CLI (Plan 7) pasan por acá.
extension AppModel {
    /// Métodos permitidos, método por defecto y si se puede mergear ahora.
    func mergeOptions(_ item: ClassifiedPR) -> MergeOptions {
        MergePolicy.options(for: item, snapshot: prStore.snapshot, config: configStore.config)
    }

    /// El botón Merge, el menú contextual y Retry: abren el diálogo (spec G.1: siempre se confirma).
    /// `method == nil` = el método por defecto. Lo que no se puede mergear queda como error en la fila
    /// (`MergeFlow.request`).
    func requestMerge(_ item: ClassifiedPR, method: MergeMethod? = nil) {
        let options = mergeOptions(item)
        switch MergeFlow.request(
            item, method: method, options: options, blockedReason: jobsBlockedReason, phase: merges.phases[item.id]
        ) {
        case .ignore: break
        case .confirm(let chosen): openMergeConfirmation(item, method: chosen, options: options)
        case .fail(let chosen, let error): merges.reject(item, method: chosen, error: error)
        }
    }

    /// Mergea sin preguntar (el diálogo ya confirmó, o la CLI con `--yes`). Usa el `headOid` de `item`: si alguien
    /// pusheó después, GitHub lo rechaza (`MergeError.headChanged`). Antes vuelve a mirar el PR en el snapshot actual:
    /// si ya no está en Ready to Merge, el botón estaría deshabilitado o el repo no permite `method`, no lo manda
    /// (`MergeError.unavailable`; `.noLongerOpen` si ya no está en la lista). Cuenta en `postings`: una actualización
    /// espera a que termine; mientras se instala una, no empieza (`MergeError.blocked`).
    @discardableResult
    func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        let precheck: MergeError?
        if let current = prStore.snapshot?.items.first(where: { $0.id == item.id }) {
            precheck = MergePolicy.problem(current, method: method, options: mergeOptions(current))
        } else {
            precheck = .noLongerOpen
        }
        return await postings.track { await merges.merge(item, method: method, precheck: precheck) }
    }

    /// Retry de una fila con error: refresca (el PR pudo cambiar) y decide con `MergeFlow.retry`: si el PR cambió
    /// (head distinto, o el error fue `headChanged`) solo limpia el error, así nunca se mergea un head que no se vio;
    /// si es el mismo, vuelve a pedir el merge con el mismo método (se vuelve a confirmar); si
    /// ya no está en la lista, le pregunta a GitHub si se mergeó.
    func retryMerge(prID: String) {
        guard let failure = merges.failure(prID: prID) else { return }
        merges.dismiss(prID: prID)
        Task {
            await prStore.refreshNow()
            switch MergeFlow.retry(failure, current: prStore.snapshot?.items.first { $0.id == prID }) {
            case .request(let current, let method): requestMerge(current, method: method)
            case .changed: break
            case .missing: await merges.resolveMissing(failure)
            }
        }
    }

    func dismissMergeError(prID: String) {
        merges.dismiss(prID: prID)
    }

    /// Settings › Repos: `nil` = el método por defecto de GitHub.
    func setMergeMethod(_ method: MergeMethod?, repoID: String, login: String) {
        updateConfig(refresh: false) { $0.setMergeMethod(method, repoID: repoID, login: login) }
    }

    /// Lo llama `MergeQueue` después de un merge: "Merged" en Slack y, a los 2 s ("Merged" en la fila), un refresco
    /// que saca la fila.
    func mergeFinished(_ completion: MergeCompletion) {
        let config = configStore.config
        let slack = self.slack
        let postings = self.postings
        // Se guarda ahora, dentro del `postings.track` del merge: una actualización o un cierre justo después no lo
        // pierden. Publicarlo puede esperar al Task (o al próximo ciclo).
        if slack.queueMergedReply(completion.item.pr, method: completion.method, config: config) {
            Task { await postings.track { await slack.postQueued(config: config) } }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            // Espera un refresco en curso (pudo empezar antes del merge) y refresca de nuevo; el snapshot nuevo
            // descarta la fase "Merged" (`mergePruneObserver`).
            await self.prStore.refreshNow()
        }
    }

    static func mergeWindowID(_ prID: String) -> String { "merge-\(prID)" }

    /// Cierra los diálogos de confirmación de PRs que salieron de Ready to Merge en `snapshot` (o que ya no están).
    func closeStaleMergeConfirmations(_ snapshot: Snapshot) {
        mergeConfirmations = mergeConfirmations.filter { WindowPresenter.shared.isOpen(id: Self.mergeWindowID($0)) }
        for prID in MergeFlow.confirmationsToClose(open: mergeConfirmations, snapshot: snapshot) {
            WindowPresenter.shared.close(id: Self.mergeWindowID(prID))
            mergeConfirmations.remove(prID)
        }
    }

    private func openMergeConfirmation(_ item: ClassifiedPR, method: MergeMethod, options: MergeOptions) {
        let windowID = Self.mergeWindowID(item.id)
        let settings = prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
        let deletesBranch = settings?.deleteBranchOnMerge ?? false
        mergeConfirmations.insert(item.id)
        WindowPresenter.shared.show(
            id: windowID, title: "Merge Pull Request", size: MergeConfirmView.size,
            options: WindowOptions(miniaturizable: false, resizable: false, allowsTabbing: false),
            // Cualquier cambio en lo que muestra (nota, borrado de rama, métodos…) reemplaza el contenido reusado.
            contentID: MergeFlow.confirmationContentID(item, method: method, options: options, deletesBranch: deletesBranch)
        ) {
            MergeConfirmView(
                item: item, methods: options.methods, initialMethod: method, note: options.availability.note,
                deletesBranch: deletesBranch,
                onMerge: { [weak self] chosen in
                    WindowPresenter.shared.close(id: windowID)
                    Task { _ = await self?.merge(item, method: chosen) }
                },
                onCancel: { WindowPresenter.shared.close(id: windowID) }
            )
        }
    }
}
