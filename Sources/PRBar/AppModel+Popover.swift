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
}
