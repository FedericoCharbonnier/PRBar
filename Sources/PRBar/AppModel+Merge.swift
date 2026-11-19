import AppKit
import PRBarCore
import SwiftUI

/// Ready to Merge (spec F). La UI (fila, menú contextual, diálogo) y la CLI (Plan 7) pasan por acá.
extension AppModel {
    /// Métodos permitidos, método por defecto y si se puede mergear ahora.
    func mergeOptions(_ item: ClassifiedPR) -> MergeOptions {
        MergePolicy.options(for: item, snapshot: prStore.snapshot, config: configStore.config)
    }

    /// El botón Merge y el menú contextual. Con `merge.confirm` abre el diálogo; si no, mergea enseguida.
    /// `method == nil` = el método por defecto. No hace nada si el botón estaría deshabilitado.
    func requestMerge(_ item: ClassifiedPR, method: MergeMethod? = nil) {
        // Mientras se instala una actualización el botón está deshabilitado (`jobsBlockedReason`): nada nuevo empieza.
        guard jobsBlockedReason == nil else { return }
        let options = mergeOptions(item)
        guard options.availability.isEnabled, let chosen = method ?? options.defaultMethod,
              options.methods.contains(chosen) else { return }
        if configStore.config.merge.confirm {
            openMergeConfirmation(item, method: chosen, options: options)
        } else {
            Task { _ = await merge(item, method: chosen) }
        }
    }

    /// Mergea sin preguntar (el diálogo ya confirmó, o la CLI con `--yes`). Usa el `headOid` de `item`: si alguien
    /// pusheó después, GitHub lo rechaza (`MergeError.headChanged`). Cuenta en `postings`: una actualización espera a
    /// que termine; mientras se instala una, no empieza (`MergeError.blocked`).
    @discardableResult
    func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        await postings.track { await merges.merge(item, method: method) }
    }

    /// Retry de una fila con error: refresca (el PR pudo cambiar) y vuelve a pedir el merge con el mismo método
    /// (con `merge.confirm`, se vuelve a confirmar).
    func retryMerge(prID: String) {
        guard case .failed(let method, _)? = merges.phases[prID] else { return }
        merges.dismiss(prID: prID)
        Task {
            await prStore.refresh()
            guard let item = prStore.snapshot?.items.first(where: { $0.id == prID && $0.category == .readyToMerge }) else { return }
            requestMerge(item, method: method)
        }
    }

    func dismissMergeError(prID: String) {
        merges.dismiss(prID: prID)
    }

    /// Settings › Repos: `nil` = el método por defecto de GitHub.
    func setMergeMethod(_ method: MergeMethod?, repoID: String, login: String) {
        updateConfig(refresh: false) { $0.setMergeMethod(method, repoID: repoID, login: login) }
    }

    /// Settings › General › "Confirm before merging".
    func setConfirmBeforeMerging(_ on: Bool) {
        updateConfig(refresh: false) { $0.merge.confirm = on }
    }

    /// Lo llama `MergeQueue` después de un merge: "Merged" en Slack y, a los 2 s ("Merged" en la fila), un refresco
    /// que saca la fila.
    func mergeFinished(_ completion: MergeCompletion) {
        let config = configStore.config
        let slack = self.slack
        let postings = self.postings
        Task { await postings.track { await slack.prMerged(completion.item.pr, method: completion.method, config: config) } }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await self.prStore.refresh()
            self.merges.prune(keeping: Set(self.prStore.snapshot?.items.map(\.id) ?? []))
        }
    }

    static func mergeWindowID(_ prID: String) -> String { "merge-\(prID)" }

    private func openMergeConfirmation(_ item: ClassifiedPR, method: MergeMethod, options: MergeOptions) {
        let windowID = Self.mergeWindowID(item.id)
        let settings = prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
        WindowPresenter.shared.show(
            id: windowID, title: "Merge Pull Request", size: MergeConfirmView.size,
            options: WindowOptions(miniaturizable: false, resizable: false, allowsTabbing: false),
            contentID: "\(item.pr.headOid)|\(method.rawValue)"
        ) {
            MergeConfirmView(
                item: item, methods: options.methods, initialMethod: method, note: options.availability.note,
                deletesBranch: settings?.deleteBranchOnMerge ?? false,
                onMerge: { [weak self] chosen in
                    WindowPresenter.shared.close(id: windowID)
                    Task { _ = await self?.merge(item, method: chosen) }
                },
                onCancel: { WindowPresenter.shared.close(id: windowID) }
            )
        }
    }
}
