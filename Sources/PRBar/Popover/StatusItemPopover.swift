import AppKit
import PRBarCore

/// Abre el popover del `MenuBarExtra` desde código (`prbar app popover`). SwiftUI no tiene una API para eso: se
/// busca el botón de la barra de menú (`NSStatusBarButton`) y se le hace clic. Responde si el popover quedó en
/// pantalla; si no (no se encontró el botón o no se abrió), la pestaña queda elegida igual (decisión H.4.8).
@MainActor
enum StatusItemPopover {
    /// `popoverWindow`: la ventana del popover si la app ya la conoce (la pone `WindowAccessor` al abrirse).
    static func show(popoverWindow: () -> NSWindow?) async -> Bool {
        // Activar antes del clic: si no, el popover se abre sin que la app sea la activa y ⌘1/⌘2 no llegan.
        NSApp.activate()
        let button = statusButton()
        let step = PopoverOpening.step(
            windowVisible: popoverWindow()?.isVisible == true,
            buttonFound: button != nil,
            buttonShowsOpen: button.map { $0.isHighlighted || $0.state == .on } ?? false
        )
        switch step {
        case .bringToFront:
            popoverWindow()?.makeKeyAndOrderFront(nil)
        case .click:
            button?.performClick(nil)
        case .unavailable:
            AppLog.write("Couldn't find PRBar’s menu bar button to open the popover.")
            return false
        }
        let shown = await PopoverOpening.waitUntilShown { popoverWindow()?.isVisible == true }
        if !shown { AppLog.write("Clicked PRBar’s menu bar button but the popover didn't show up.") }
        return shown
    }

    private static func statusButton() -> NSStatusBarButton? {
        let windows = NSApp.windows
        let order = PopoverOpening.searchOrder(windows.map { String(describing: type(of: $0)) })
        for index in order {
            if let button = find(in: windows[index].contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}
