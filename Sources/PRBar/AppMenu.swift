import AppKit
import PRBarCore

/// Menú principal para cuando la app es `.regular` (hay una ventana abierta): PRBar, Edit, View, Pull Request, Window y
/// Help (spec M.6). Se arma en AppKit porque la app no tiene escenas de SwiftUI a las que colgarles `.commands`. Every
/// shortcut the windows have is here too, so it can be found in the menu bar; the items that act on the window in front
/// (Show Chat, Refresh, Back, the PR's tabs, Merge, Stop Claude…) go through `WindowCommandCenter`. ⌘↩ isn't here: a
/// menu item would take it before the chat's text field (it's each button's own shortcut).
@MainActor
enum AppMenu {
    /// What the menu opens; `WindowPresenter` forwards them to `AppModel`.
    struct Actions {
        var openSettings: () -> Void
        /// ⌘1–4: a place in the main window (`AppModel.navigate(to:)`).
        var navigate: (MainDestination) -> Void
        /// ⌘0: open or focus the main window.
        var openMainWindow: () -> Void
        /// "Check for Updates…", or the Update window when a version is offered (`AppModel.checkForUpdatesFromMenu`).
        var checkForUpdates: () -> Void
        /// The version offered, if any: the item then reads "Update to PRBar 1.3.0…".
        var availableUpdate: () -> String?
    }

    static func build(_ actions: Actions) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(actions)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu(actions)))
        main.addItem(submenu(pullRequestMenu()))
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
        // Text undo in a text field; otherwise Claude's last change from the tab's chat (`WindowCommandCenter.undo`).
        menu.addItem(item("Undo", #selector(WindowCommandCenter.undo(_:)), "z", target: WindowCommandCenter.shared))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    /// AppKit adds Show Tab Bar / Show All Tabs here when the windows can be tabbed.
    private static func viewMenu(_ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "View")
        let commands = WindowCommandCenter.shared
        menu.addItem(item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", modifiers: [.command, .control]))
        menu.addItem(item("Show Chat", #selector(WindowCommandCenter.toggleChat(_:)), "i", modifiers: [.command, .option],
                          target: commands))
        menu.addItem(.separator())
        let places: [(String, String, MainDestination)] = [
            ("To Review", "1", .list(.toReview)), ("My PRs", "2", .list(.myPRs)),
            ("History", "3", .history(recordID: nil)), ("Activity", "4", .activity),
        ]
        for (title, key, destination) in places {
            menu.addItem(ClosureMenuItem(title: title, keyEquivalent: key) { actions.navigate(destination) })
        }
        menu.addItem(.separator())
        menu.addItem(item("Back", #selector(WindowCommandCenter.back(_:)), "[", target: commands))
        menu.addItem(item("Refresh", #selector(WindowCommandCenter.refresh(_:)), "r", target: commands))
        menu.addItem(item("Find", #selector(WindowCommandCenter.find(_:)), "f", target: commands))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return menu
    }

    /// The PR in front (main window or a PR window): its tabs (retitled with the tab's name), Merge and Stop Claude.
    private static func pullRequestMenu() -> NSMenu {
        let menu = NSMenu(title: "Pull Request")
        let commands = WindowCommandCenter.shared
        menu.addItem(item("Open in New Window", #selector(WindowCommandCenter.openInNewWindow(_:)), "o",
                          modifiers: [.command, .shift], target: commands))
        menu.addItem(item("Open on GitHub", #selector(WindowCommandCenter.openOnGitHub(_:)), target: commands))
        menu.addItem(.separator())
        for index in 1...3 {
            let tab = item("Tab \(index)", #selector(WindowCommandCenter.selectTab(_:)), "\(index)",
                           modifiers: [.command, .option], target: commands)
            tab.tag = index
            menu.addItem(tab)
        }
        menu.addItem(.separator())
        menu.addItem(item("Merge…", #selector(WindowCommandCenter.merge(_:)), "m", modifiers: [.command, .shift],
                          target: commands))
        menu.addItem(item("Resolve Conflicts", #selector(WindowCommandCenter.resolveConflicts(_:)), target: commands))
        menu.addItem(item("Stop Claude", #selector(WindowCommandCenter.stopClaude(_:)), ".", target: commands))
        menu.addItem(item("Open Claude Session in Terminal", #selector(WindowCommandCenter.openClaudeSession(_:)), "t",
                          modifiers: [.command, .option], target: commands))
        return menu
    }

    private static func windowMenu(_ actions: Actions) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "PRBar", keyEquivalent: "0", action: actions.openMainWindow))
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
