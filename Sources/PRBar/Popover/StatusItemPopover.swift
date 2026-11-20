import AppKit
import PRBarCore

/// Abre el popover del `MenuBarExtra` desde código (`prbar app popover`). SwiftUI no tiene una API para eso: se
/// busca el botón de la barra de menú (`NSStatusBarButton`, en la ventana privada `NSStatusBarWindow`) y se le hace
/// clic. Si AppKit cambia y no se encuentra, devuelve `false` y la pestaña queda elegida igual (decisión H.4.8).
@MainActor
enum StatusItemPopover {
    static func show(popoverWindow: NSWindow?) -> Bool {
        if let popoverWindow, popoverWindow.isVisible {
            NSApp.activate()
            popoverWindow.makeKeyAndOrderFront(nil)
            return true
        }
        guard let button = statusButton() else {
            AppLog.write("Couldn't find PRBar’s menu bar button to open the popover.")
            return false
        }
        button.performClick(nil)
        return true
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let button = find(in: window.contentView) { return button }
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
