import AppKit
import PRBarCore

// MARK: - Pestañas del popover (spec H)

extension AppModel {
    /// `prbar app popover [--tab]`: elige la pestaña (si viene) y abre el popover. `shown` dice si quedó en pantalla.
    func openPopover(tab: PopoverTab?) async -> PopoverInfo {
        if let tab { popoverTab.selected = tab }
        let shown = showPopover?() ?? false
        if !shown { AppLog.write("Couldn't show PRBar’s popover.") }
        return PopoverInfo(tab: popoverTab.selected, shown: shown)
    }

    /// Lo llama `StatusItemController` al abrir y cerrar el panel: avisa al `ResourceMonitor`, que muestrea solo
    /// mientras se ve (spec I).
    func popoverVisibilityChanged(_ visible: Bool) {
        resources.setVisible("popover", visible)
    }

    /// Return on the row selected with the arrow keys: what clicking the row does (the PR in the main window).
    func openPRFromPopover(_ prID: String) {
        navigate(to: .pr(prID: prID, tab: nil))
    }

    /// Lo que hacen el pill y el menú contextual de una fila (popover y ventana principal). Abrir lleva a la pestaña de
    /// la acción; empezar algo además la abre (spec M.3). En la ventana principal navegar al mismo PR no hace nada.
    func rowActions(_ item: ClassifiedPR) -> PRRowActions {
        let respond = self.respond
        let prID = item.id
        // Con fixes hechos (o commits que dejó una implementación) no se vuelve a analizar: la pestaña reintenta la
        // publicación, o pregunta antes de descartarlos.
        let hasWork = { respond.records[prID]?.result != nil || respond.unpushedWork.contains(prID) }
        let startReview = { [weak self] in
            self?.startReview(item)
            self?.navigate(to: .pr(prID: prID, tab: .review))
        }
        let startRespond = { [weak self] in
            self?.startRespond(item)
            self?.navigate(to: .pr(prID: prID, tab: .respond))
        }
        let startCIFix = { [weak self] in
            self?.startCIFix(item)
            self?.navigate(to: .pr(prID: prID, tab: .fixCI))
        }
        let startConflicts: () -> Void = { [weak self] in self?.startConflictsAndOpen(item) }
        return PRRowActions(
            review: ReviewButtonActions(
                start: startReview,
                cancel: { [weak self] in self?.cancelReview(prID: prID) },
                open: { [weak self] in self?.openReview(prID: prID) },
                retry: startReview,
                dismiss: { [weak self] in self?.dismissReview(prID: prID) }
            ),
            respond: RespondButtonActions(
                start: startRespond,
                cancel: { [weak self] in self?.cancelRespond(prID: prID) },
                open: { [weak self] in self?.openRespond(prID: prID) },
                retry: { [weak self] in hasWork() ? self?.openRespond(prID: prID) : startRespond() },
                dismiss: { [weak self] in self?.confirmDismissRespond(prID: prID) }
            ),
            ciFix: RespondButtonActions(
                start: startCIFix,
                cancel: { [weak self] in self?.cancelRespond(prID: prID) },
                open: { [weak self] in self?.openRespond(prID: prID) },
                retry: { [weak self] in hasWork() ? self?.openRespond(prID: prID) : startCIFix() },
                dismiss: { [weak self] in self?.confirmDismissRespond(prID: prID) }
            ),
            conflicts: RespondButtonActions(
                start: startConflicts,
                cancel: { [weak self] in self?.cancelRespond(prID: prID) },
                open: { [weak self] in self?.openRespond(prID: prID) },
                retry: { [weak self] in hasWork() ? self?.openRespond(prID: prID) : startConflicts() },
                dismiss: { [weak self] in self?.confirmDismissRespond(prID: prID) }
            ),
            merge: MergeButtonActions(
                open: { [weak self] in self?.requestMerge(item) },
                dismiss: { [weak self] in self?.dismissMergeError(prID: prID) }
            )
        )
    }
}
