import AppKit
import SwiftUI

/// The commands of the View menu that act on the window in front (`AppMenu`). A window's SwiftUI content registers
/// what it can do with `.windowCommand`; the menu item asks the key window for it, so ⇧⌘C and ⌘R work (and show up)
/// in the menu bar as in the toolbar.
enum WindowCommand: Hashable {
    /// Show or hide the chat inspector (Review, Respond, Merge).
    case toggleChat
    /// Reload the window's data (Merge). Without one, Refresh reloads the PR list.
    case refresh
}

@MainActor
final class WindowCommandCenter: NSObject, NSMenuItemValidation {
    static let shared = WindowCommandCenter()

    struct Handler {
        var enabled: Bool
        /// For toggles: whether it's on now ("Hide Chat" / "Show Chat").
        var isOn: Bool?
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

    @objc func toggleChat(_ sender: Any?) {
        guard let handler = handler(.toggleChat), handler.enabled else { return NSSound.beep() }
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
            .onDisappear { unregister() }
    }

    private func unregister() {
        guard let window = box.window else { return }
        WindowCommandCenter.shared.unregister(command, in: window, owner: ObjectIdentifier(box))
    }

    private func register() {
        guard let window = box.window else { return }
        WindowCommandCenter.shared.register(command, in: window, .init(enabled: enabled, isOn: isOn, perform: perform,
                                                                       owner: ObjectIdentifier(box)))
    }
}

extension View {
    /// Registers what the View menu's `command` does while this view's window is in front.
    func windowCommand(_ command: WindowCommand, enabled: Bool = true, isOn: Bool? = nil,
                       perform: @escaping () -> Void) -> some View {
        modifier(WindowCommandModifier(command: command, enabled: enabled, isOn: isOn, perform: perform))
    }
}
