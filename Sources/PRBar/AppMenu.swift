import AppKit
import PRBarCore

/// Menú principal para cuando la app es `.regular` (hay una ventana abierta): PRBar, Edit, View, Window y Help.
/// Se arma en AppKit porque la app no tiene escenas de SwiftUI a las que colgarles `.commands`. Every shortcut the
/// windows have is here too, so it can be found in the menu bar: View › Show Chat (⇧⌘C) and Refresh (⌘R) act on the
/// window in front through `WindowCommandCenter`.
@MainActor
enum AppMenu {
    /// What the menu opens; `WindowPresenter` forwards them to `AppModel`.
    struct Actions {
        var openSettings: () -> Void
        var openHistory: () -> Void
        var openActivity: () -> Void
        /// "Check for Updates…", or the Update window when a version is offered (`AppModel.checkForUpdatesFromMenu`).
        var checkForUpdates: () -> Void
        /// The version offered, if any: the item then reads "Update to PRBar 1.3.0…".
        var availableUpdate: () -> String?
    }

    static func build(_ actions: Actions) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(actions)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(windowMenu(actions)))
        main.addItem(submenu(helpMenu()))
        return main
    }

    private static func appMenu(_ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "PRBar")
        menu.addItem(item("About PRBar", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        // Retitled each time the menu opens (`validateMenuItem`).
        menu.addItem(ClosureMenuItem(title: "Check for Updates…", action: actions.checkForUpdates)
            .retitled { UpdatePrompt.menuTitle(availableVersion: actions.availableUpdate()) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",", action: actions.openSettings))
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

    /// AppKit adds Show Tab Bar / Show All Tabs here when the windows can be tabbed.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let commands = WindowCommandCenter.shared
        menu.addItem(item("Show Chat", #selector(WindowCommandCenter.toggleChat(_:)), "c", modifiers: [.command, .shift],
                          target: commands))
        menu.addItem(item("Refresh", #selector(WindowCommandCenter.refresh(_:)), "r", target: commands))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return menu
    }

    private static func windowMenu(_ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "History", keyEquivalent: "y", action: actions.openHistory))
        menu.addItem(ClosureMenuItem(title: "PRBar Activity", action: actions.openActivity))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    /// The system adds the search field. "Keyboard Shortcuts" lists every shortcut, the popover's included (it has
    /// no menu bar of its own).
    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(ClosureMenuItem(title: "Keyboard Shortcuts") { showShortcuts() })
        menu.addItem(ClosureMenuItem(title: "Show Log") { NSWorkspace.shared.open(AppPaths.logFile) })
        return menu
    }

    private static func showShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = KeyboardShortcutList.groups.map { group in
            ([group.title] + group.shortcuts.map { "\($0.keys)\t\($0.action)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        alert.window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        NSApp.activate()
        alert.runModal()
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// `NSMenuItem` que corre un closure. Es su propio `target` (referencia débil): lo retiene el menú.
final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    private var titleProvider: (() -> String)?

    init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// A title worked out again every time the menu is about to show (e.g. "Update to PRBar 1.3.0…").
    func retitled(_ provider: @escaping () -> String) -> ClosureMenuItem {
        titleProvider = provider
        title = provider()
        return self
    }

    @objc private func run() { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let titleProvider { menuItem.title = titleProvider() }
        return true
    }
}
