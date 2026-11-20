import AppKit
import PRBarCore

// MARK: - Pestañas del popover (spec H)

extension AppModel {
    /// `prbar app popover [--tab]`: elige la pestaña (si viene) y abre el popover.
    func openPopover(tab: PopoverTab?) -> PopoverInfo {
        if let tab { popoverTab.selected = tab }
        let shown = StatusItemPopover.show(popoverWindow: popoverWindow)
        return PopoverInfo(tab: popoverTab.selected, shown: shown)
    }

    /// Clic en la notificación de un PR: la próxima vez que se abra el popover está en la pestaña de ese PR.
    func selectTab(forNotificationPR prID: String) {
        guard let item = prStore.snapshot?.items.first(where: { $0.id == prID }) else { return }
        popoverTab.selected = PopoverTabs.tab(of: item)
    }
}
