import AppKit
import PRBarCore

// MARK: - Pestañas del popover (spec H)

extension AppModel {
    /// `prbar app popover [--tab]`: elige la pestaña (si viene) y abre el popover. `shown` dice si quedó en pantalla.
    func openPopover(tab: PopoverTab?) async -> PopoverInfo {
        if let tab { popoverTab.selected = tab }
        let shown = await StatusItemPopover.show { [weak self] in self?.popoverWindow }
        return PopoverInfo(tab: popoverTab.selected, shown: shown)
    }

    /// Clic en la notificación de un PR: la próxima vez que se abra el popover está en la pestaña de ese PR, sin
    /// pisar la que eligió el usuario (spec H.4.7).
    func selectTab(forNotificationPR prID: String) {
        guard let item = prStore.snapshot?.items.first(where: { $0.id == prID }) else { return }
        popoverTab.selectForNextOpening(PopoverTabs.tab(of: item))
    }

    /// Lo llama `WindowAccessor` cuando el contenido del popover entra en una ventana (o sale, con `nil`). Se miran
    /// sus cambios de key/visibilidad para avisar a `PopoverTabState` cuándo se abre y se cierra, y al
    /// `ResourceMonitor` cuándo puede muestrear (spec I).
    func setPopoverWindow(_ window: NSWindow?) {
        resources.setVisible("popover", window != nil)
        guard window !== popoverWindow else { return syncPopoverVisibility() }
        popoverWindowObservers.forEach(NotificationCenter.default.removeObserver)
        popoverWindowObservers = []
        popoverWindow = window
        if let window {
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didChangeOcclusionStateNotification]
            popoverWindowObservers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    // Al cerrarse, la ventana deja de ser key antes de salir de pantalla: se vuelve a mirar después.
                    let occlusion = note.name == NSWindow.didChangeOcclusionStateNotification
                    Task { @MainActor in
                        // `MenuBarExtra` deja la ventana creada al cerrarse: su `occlusionState` dice si está en
                        // pantalla, y el muestreo se para en cuanto deja de estarlo (spec I).
                        if occlusion, let window = self?.popoverWindow {
                            self?.resources.setVisible("popover", window.occlusionState.contains(.visible))
                        }
                        self?.syncPopoverVisibility()
                    }
                }
            }
        }
        syncPopoverVisibility()
    }

    private func syncPopoverVisibility() {
        if popoverWindow?.isVisible == true { popoverTab.popoverDidOpen() } else { popoverTab.popoverDidClose() }
    }
}
