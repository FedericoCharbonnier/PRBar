import AppKit
import SwiftUI

/// The menu commands that act on the window in front (`AppMenu`). A window's SwiftUI content registers what it can do
/// with `.windowCommand`; the menu item asks the key window for it, so ⌥⌘I, ⌘R, ⌘[… work (and show up) in the menu
/// bar as in the toolbar.
enum WindowCommand: Hashable {
    /// Show or hide the chat inspector (Review, Respond, Merge).
    case toggleChat
    /// Reload the window's data (Merge). Without one, Refresh reloads the PR list.
    case refresh
    /// ⌘F. Without a handler, the search field of the window's toolbar.
    case find
    /// ⌘[ in the main window.
    case back
    /// ⇧⌘O: the selected PR in a window of its own.
    case openInNewWindow
    /// Open on GitHub (the selected PR).
    case openOnGitHub
    /// ⌥⌘1…3: the PR's tabs (1-based).
    case tab(Int)
    /// ⇧⌘M in the Merge tab.
    case merge
    /// ⌘. while Claude works on the tab's PR.
    case stopClaude
    /// ⌘Z outside a text field: undo Claude's last change from the tab's chat.
    case undoClaude
}

@MainActor
final class WindowCommandCenter: NSObject, NSMenuItemValidation {
    static let shared = WindowCommandCenter()

    struct Handler {
        var enabled: Bool
        /// For toggles: whether it's on now ("Hide Chat" / "Show Chat").
        var isOn: Bool?
        /// The menu item's title, if it depends on the content (the PR's tabs: "Review", "Details"…).
        var title: String? = nil
        var perform: () -> Void
        /// Quién lo registró (`WindowCommandModifier`): al irse borra solo el suyo, no el de la vista que lo reemplazó.
        var owner: ObjectIdentifier? = nil
    }

    /// Refresh when the key window has no refresh of its own: the PR list (`prbar refresh`). Set by `AppModel`.
    var refreshPRs: (() -> Void)?

    private let handlers = NSMapTable<NSWindow, Box>.weakToStrongObjects()

    private final class Box {
        var commands: [WindowCommand: Handler] = [:]
    }

    func register(_ command: WindowCommand, in window: NSWindow, _ handler: Handler) {
        let box = handlers.object(forKey: window) ?? Box()
        box.commands[command] = handler
        handlers.setObject(box, forKey: window)
    }

    /// Lo borra si sigue siendo de `owner`. En la ventana principal los panes van y vienen: el handler de uno que ya no
    /// está (p. ej. el ⌘R de Merge) no puede quedar colgado.
    func unregister(_ command: WindowCommand, in window: NSWindow, owner: ObjectIdentifier) {
        guard let box = handlers.object(forKey: window), box.commands[command]?.owner == owner else { return }
        box.commands[command] = nil
    }

    private func handler(_ command: WindowCommand) -> Handler? {
        guard let window = NSApp.keyWindow else { return nil }
        return handlers.object(forKey: window)?.commands[command]
    }

    @objc func toggleChat(_ sender: Any?) { perform(.toggleChat) }
    @objc func back(_ sender: Any?) { perform(.back) }
    @objc func openInNewWindow(_ sender: Any?) { perform(.openInNewWindow) }
    @objc func openOnGitHub(_ sender: Any?) { perform(.openOnGitHub) }
    @objc func merge(_ sender: Any?) { perform(.merge) }
    @objc func stopClaude(_ sender: Any?) { perform(.stopClaude) }

    /// ⌥⌘1…3: the menu item's `tag` is the tab's number.
    @objc func selectTab(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag else { return }
        perform(.tab(index))
    }

    /// ⌘F: the window's own search, or the search field of its toolbar.
    @objc func find(_ sender: Any?) {
        if let handler = handler(.find) {
            if handler.enabled { handler.perform() }
            return
        }
        guard let field = searchItem() else { return NSSound.beep() }
        field.beginSearchInteraction()
    }

    /// Edit › Undo (⌘Z): in an editable text it's the text's undo; otherwise it undoes Claude's last change from the
    /// tab's chat (spec M.6).
    @objc func undo(_ sender: Any?) {
        if isEditingText || handler(.undoClaude)?.enabled != true {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
        } else {
            handler(.undoClaude)?.perform()
        }
    }

    private var isEditingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
    }

    private func searchItem() -> NSSearchToolbarItem? {
        NSApp.keyWindow?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
    }

    private func perform(_ command: WindowCommand) {
        guard let handler = handler(command), handler.enabled else { return NSSound.beep() }
        handler.perform()
    }

    @objc func refresh(_ sender: Any?) {
        if let handler = handler(.refresh) {
            if handler.enabled { handler.perform() }
        } else {
            refreshPRs?()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleChat(_:)):
            let handler = handler(.toggleChat)
            menuItem.title = handler?.isOn == true ? "Hide Chat" : "Show Chat"
            return handler?.enabled ?? false
        case #selector(refresh(_:)):
            return handler(.refresh)?.enabled ?? (refreshPRs != nil)
        case #selector(back(_:)): return handler(.back)?.enabled ?? false
        case #selector(openInNewWindow(_:)): return handler(.openInNewWindow)?.enabled ?? false
        case #selector(openOnGitHub(_:)): return handler(.openOnGitHub)?.enabled ?? false
        case #selector(merge(_:)): return handler(.merge)?.enabled ?? false
        case #selector(stopClaude(_:)): return handler(.stopClaude)?.enabled ?? false
        case #selector(find(_:)): return handler(.find)?.enabled ?? (searchItem() != nil)
        case #selector(selectTab(_:)):
            let handler = handler(.tab(menuItem.tag))
            menuItem.title = handler?.title ?? "Tab \(menuItem.tag)"
            menuItem.state = handler?.isOn == true ? .on : .off
            return handler?.enabled ?? false
        case #selector(undo(_:)):
            // In a text field: the text's own undo (validated by the responder chain through its title).
            if !isEditingText, handler(.undoClaude)?.enabled == true {
                menuItem.title = "Undo Claude’s Change"
                return true
            }
            let undoManager = NSApp.keyWindow?.firstResponder?.undoManager
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo ?? false
        default:
            return true
        }
    }
}

/// The window a view is in, kept without re-rendering the view.
@MainActor
final class WindowBox {
    weak var window: NSWindow?
}

private struct WindowCommandModifier: ViewModifier {
    let command: WindowCommand
    let enabled: Bool
    let isOn: Bool?
    let title: String?
    let perform: () -> Void
    @State private var box = WindowBox()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                // Sale de la ventana (nil): se borra de la anterior.
                if window == nil { unregister() }
                box.window = window
                register()
            })
            .onChange(of: enabled) { _, _ in register() }
            .onChange(of: isOn) { _, _ in register() }
            .onChange(of: title) { _, _ in register() }
            .onDisappear { unregister() }
    }

    private func unregister() {
        guard let window = box.window else { return }
        WindowCommandCenter.shared.unregister(command, in: window, owner: ObjectIdentifier(box))
    }

    private func register() {
        guard let window = box.window else { return }
        WindowCommandCenter.shared.register(command, in: window, .init(enabled: enabled, isOn: isOn, title: title,
                                                                       perform: perform, owner: ObjectIdentifier(box)))
    }
}

extension View {
    /// Registers what the menu's `command` does while this view's window is in front.
    func windowCommand(_ command: WindowCommand, enabled: Bool = true, isOn: Bool? = nil, title: String? = nil,
                       perform: @escaping () -> Void) -> some View {
        modifier(WindowCommandModifier(command: command, enabled: enabled, isOn: isOn, title: title, perform: perform))
    }
}
