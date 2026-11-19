import AppKit

/// Menú principal mínimo para cuando la app es `.regular` (hay una ventana abierta): PRBar, Edición y Ventana.
/// Se arma en AppKit porque un `MenuBarExtra` no tiene escenas de ventana a las que colgarles `.commands`.
@MainActor
enum AppMenu {
    static func build(openSettings: @escaping () -> Void) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(openSettings: openSettings)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(windowMenu()))
        return main
    }

    private static func appMenu(openSettings: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(title: "PRBar")
        menu.addItem(item("About PRBar", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",", action: openSettings))
        menu.addItem(.separator())
        menu.addItem(item("Hide PRBar", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PRBar", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// `NSMenuItem` que corre un closure. Es su propio `target` (referencia débil): lo retiene el menú.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func run() { handler() }
}
