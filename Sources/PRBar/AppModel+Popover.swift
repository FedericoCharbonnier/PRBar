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

    /// Clic en la notificación de un PR: la próxima vez que se abra el popover está en la pestaña de ese PR, sin
    /// pisar la que eligió el usuario (spec H.4.7).
    func selectTab(forNotificationPR prID: String) {
        guard let item = prStore.snapshot?.items.first(where: { $0.id == prID }) else { return }
        popoverTab.selectForNextOpening(PopoverTabs.tab(of: item))
    }

    /// Lo llama `StatusItemController` al abrir y cerrar el panel: avisa a `PopoverTabState` y al `ResourceMonitor`,
    /// que muestrea solo mientras se ve (spec I).
    func popoverVisibilityChanged(_ visible: Bool) {
        resources.setVisible("popover", visible)
        if visible { popoverTab.popoverDidOpen() } else { popoverTab.popoverDidClose() }
    }

    /// Return on the row selected with the arrow keys: what clicking the row does (the PR on GitHub).
    func openPRFromPopover(_ prID: String) {
        guard let url = prStore.snapshot?.items.first(where: { $0.id == prID })?.pr.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Lo que hacen el pill y el menú contextual de una fila (popover y ventana principal).
    func rowActions(_ item: ClassifiedPR) -> PRRowActions {
        let respond = self.respond
        // Con fixes hechos (o commits que dejó una implementación) no se vuelve a analizar: la ventana reintenta la
        // publicación, o pregunta antes de descartarlos.
        let hasWork = { respond.records[item.id]?.result != nil || respond.unpushedWork.contains(item.id) }
        return PRRowActions(
            review: ReviewButtonActions(
                start: { [weak self] in self?.startReview(item) },
                cancel: { [weak self] in self?.cancelReview(prID: item.id) },
                open: { [weak self] in self?.openReview(prID: item.id) },
                retry: { [weak self] in self?.startReview(item) },
                dismiss: { [weak self] in self?.dismissReview(prID: item.id) }
            ),
            respond: RespondButtonActions(
                start: { [weak self] in self?.startRespond(item) },
                cancel: { [weak self] in self?.cancelRespond(prID: item.id) },
                open: { [weak self] in self?.openRespond(prID: item.id) },
                retry: { [weak self] in hasWork() ? self?.openRespond(prID: item.id) : self?.startRespond(item) },
                dismiss: { [weak self] in self?.confirmDismissRespond(prID: item.id) }
            ),
            ciFix: RespondButtonActions(
                start: { [weak self] in self?.startCIFix(item) },
                cancel: { [weak self] in self?.cancelRespond(prID: item.id) },
                open: { [weak self] in self?.openRespond(prID: item.id) },
                retry: { [weak self] in hasWork() ? self?.openRespond(prID: item.id) : self?.startCIFix(item) },
                dismiss: { [weak self] in self?.confirmDismissRespond(prID: item.id) }
            ),
            merge: MergeButtonActions(
                open: { [weak self] in self?.requestMerge(item) },
                dismiss: { [weak self] in self?.dismissMergeError(prID: item.id) }
            )
        )
    }
}
