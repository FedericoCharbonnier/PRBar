import AppKit
import PRBarCore
import SwiftUI

/// Cómo se arma una ventana de `WindowPresenter`.
struct WindowOptions {
    /// Nombre con el que AppKit guarda y restaura el frame (ventanas únicas: Configuración, Historial).
    var autosaveName: String?
    /// Clave de `UserDefaults` con el frame que comparten las ventanas de un mismo tipo (Review): la primera
    /// se abre donde quedó la última, y las siguientes se escalonan desde la que ya está abierta.
    var sharedFrameKey: String?
    var miniaturizable = true
    /// Sin redimensionar, la ventana se abre siempre con el tamaño pedido (del frame guardado solo se usa la
    /// posición). Configuración: cada pestaña tiene su tamaño.
    var resizable = true
    var allowsTabbing = true
    /// Only windows with the same identifier are grouped in tabs (reviews with reviews, not with History), when the
    /// user's "Prefer tabs when opening documents" setting asks for tabs.
    var tabbingIdentifier: String?
    /// Document windows can go full screen and into tabs; utility windows (Settings, Activity, Update) always come to
    /// the Space you're on (`WindowSpaces`).
    var kind: WindowSpaces.Kind = .document
    /// La ventana toma la barra de herramientas y el título de SwiftUI (`.toolbar`, `navigationTitle`),
    /// con el contenido debajo de la barra unificada.
    var bridgesToolbar = false
    var toolbarStyle: NSWindow.ToolbarStyle = .automatic
    /// Tamaño mínimo del contenido, para controladores que no lo informan (p. ej. pestañas de Configuración).
    var minContentSize: NSSize?
    /// Si la ventana tiene cambios sin guardar (`setUnsavedChanges`), cerrarla pide confirmación.
    var closeConfirmation: CloseConfirmation?
}

struct CloseConfirmation {
    let message: String
    let info: String
}

/// Presenta ventanas AppKit desde una app solo-barra de menú (LSUIElement) y las trae al frente.
///
/// Mientras haya alguna ventana abierta la app pasa a `.regular` (ícono en el Dock, ⌘Tab y barra de menús
/// con `AppMenu`); al cerrarse la última vuelve a `.accessory`. Over another app in full screen it stays as it is
/// until the user leaves that Space, and the window shows over that app (`WindowSpaces`): opening a window from the
/// menu bar never moves the user to another Space.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()

    /// Acción de "Configuración…" (⌘,) del menú de la app. La asigna `AppModel`.
    var openSettings: (() -> Void)?

    private var windows: [String: NSWindow] = [:]
    /// Qué contenido muestra cada ventana (ver `contentID` en `present`).
    private var contentIDs: [String: String] = [:]
    private var windowOptions: [String: WindowOptions] = [:]
    /// Ventanas con cambios sin guardar (p. ej. una review con hallazgos editados), según lo informa su contenido.
    private var unsavedChanges: Set<String> = []
    private lazy var mainMenu = AppMenu.build(openSettings: { [weak self] in self?.openSettings?() })
    private var spaceObserver: NSObjectProtocol?

    override init() {
        super.init()
        // Leaving another app's full-screen Space: the windows opened over it can now make PRBar a regular app.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivationPolicy() }
        }
    }

    /// Lo llama el contenido de la ventana `id` cuando cambia si tiene cambios sin guardar.
    func setUnsavedChanges(_ unsaved: Bool, for id: String) {
        if unsaved { unsavedChanges.insert(id) } else { unsavedChanges.remove(id) }
        windows[id]?.isDocumentEdited = unsaved
    }

    /// Muestra una ventana con contenido SwiftUI (ver `present`).
    func show<Content: View>(
        id: String, title: String, size: NSSize, options: WindowOptions = WindowOptions(), contentID: String? = nil,
        replaceConfirmation: String? = nil, @ViewBuilder content: @escaping () -> Content
    ) {
        present(
            id: id, title: title, size: size, options: options, contentID: contentID, replaceConfirmation: replaceConfirmation
        ) {
            let controller = NSHostingController(rootView: content())
            if options.bridgesToolbar { controller.sceneBridgingOptions = [.toolbars, .title] }
            return controller
        }
    }

    /// Muestra la ventana `id`, creándola si hace falta. Si ya existe, se reusa con su contenido (y su
    /// estado de SwiftUI) mientras `contentID` no cambie; con un `contentID` distinto se reemplaza el contenido,
    /// así una ventana reusada nunca muestra datos viejos (p. ej. el draft anterior de un PR revisado de nuevo).
    /// Si la ventana tiene cambios sin guardar (`setUnsavedChanges`), antes de reemplazar el contenido se pide
    /// confirmación con `replaceConfirmation` en una hoja; si el usuario elige mantenerla, no se toca.
    func present(
        id: String, title: String, size: NSSize, options: WindowOptions = WindowOptions(), contentID: String? = nil,
        replaceConfirmation: String? = nil, makeController: @escaping () -> NSViewController
    ) {
        if let window = windows[id] {
            bringToFront(id, window)
            guard contentIDs[id] != contentID else { return }
            guard let message = replaceConfirmation, unsavedChanges.contains(id) else {
                replaceContent(of: window, id: id, title: title, contentID: contentID, controller: makeController())
                return
            }
            guard window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "Your selected comments and edited text will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace").hasDestructiveAction = true
            alert.addButton(withTitle: "Keep Previous").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self, self.windows[id] === window else { return }
                self.replaceContent(of: window, id: id, title: title, contentID: contentID, controller: makeController())
            }
            return
        }

        var style: NSWindow.StyleMask = [.titled, .closable]
        if options.resizable { style.insert(.resizable) }
        if options.miniaturizable { style.insert(.miniaturizable) }
        if options.bridgesToolbar { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = options.allowsTabbing ? .automatic : .disallowed
        if let identifier = options.tabbingIdentifier { window.tabbingIdentifier = identifier }
        window.toolbarStyle = options.toolbarStyle
        window.contentViewController = makeController()
        window.setContentSize(size)
        if let minSize = options.minContentSize { window.contentMinSize = minSize }
        window.delegate = self
        place(window, size: size, options: options)
        windows[id] = window
        contentIDs[id] = contentID
        windowOptions[id] = options
        bringToFront(id, window)
    }

    /// Cierra la ventana `id` (si está abierta) sin pedir confirmación. Se olvida su contenido: la próxima vez
    /// se arma de cero.
    func isOpen(id: String) -> Bool { windows[id] != nil }

    func close(id: String) {
        windows[id]?.close()
    }

    // MARK: Política de activación y menú

    /// Puts the window on the Space you're on (over a full-screen app if that's what's in front), orders it front
    /// and only then makes the app regular, so the policy change finds the window already on this Space.
    private func bringToFront(_ id: String, _ window: NSWindow) {
        let overFullScreen = SpaceContext.otherAppIsFullScreen()
        let inTabsOrFullScreen = (window.tabbedWindows?.count ?? 0) > 1 || window.styleMask.contains(.fullScreen)
        let behavior = WindowSpaces.behavior(kind: windowOptions[id]?.kind ?? .document, overFullScreenApp: overFullScreen,
                                             inTabsOrFullScreen: inTabsOrFullScreen)
        if !inTabsOrFullScreen { Self.apply(behavior, to: window) }
        window.makeKeyAndOrderFront(nil)
        if behavior.promotesToRegular, NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    private static func apply(_ behavior: WindowSpaces.Behavior, to window: NSWindow) {
        var flags = window.collectionBehavior
        if behavior.moveToActiveSpace { flags.insert(.moveToActiveSpace) } else { flags.remove(.moveToActiveSpace) }
        if behavior.fullScreenAuxiliary {
            flags.remove(.fullScreenPrimary)
            flags.insert(.fullScreenAuxiliary)
        } else {
            flags.remove(.fullScreenAuxiliary)
        }
        window.collectionBehavior = flags
    }

    /// The app's menu bar (`AppMenu`). Installed once at launch: there are no SwiftUI scenes to replace it.
    func installMainMenu() {
        guard NSApp.mainMenu !== mainMenu else { return }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = mainMenu.items.first { $0.submenu?.title == "Window" }?.submenu
        NSApp.helpMenu = mainMenu.items.first { $0.submenu?.title == "Help" }?.submenu
    }

    /// No windows: back to `.accessory` (no Dock icon). With windows: `.regular`, unless another app is in full
    /// screen in front (see `WindowSpaces.Behavior.promotesToRegular`).
    private func updateActivationPolicy() {
        if windows.isEmpty {
            if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        } else if NSApp.activationPolicy() != .regular, !SpaceContext.otherAppIsFullScreen() {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: Frames

    private func place(_ window: NSWindow, size: NSSize, options: WindowOptions) {
        if let name = options.autosaveName {
            window.center()
            // Si había un frame guardado con este nombre, AppKit lo aplica acá.
            window.setFrameAutosaveName(name)
            if !options.resizable {
                // Del frame guardado solo vale la posición (arriba a la izquierda): el tamaño es el pedido.
                let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
                window.setContentSize(size)
                window.setFrameTopLeftPoint(topLeft)
            }
        } else if let key = options.sharedFrameKey {
            let siblings = windows.filter { windowOptions[$0.key]?.sharedFrameKey == key && $0.value.isVisible }
            if let last = siblings.values.max(by: { $0.orderedIndex > $1.orderedIndex }) {
                window.setContentSize(last.contentRect(forFrameRect: last.frame).size)
                window.cascadeTopLeft(from: last.cascadeTopLeft(from: .zero))
            } else if let saved = UserDefaults.standard.string(forKey: key) {
                window.setFrame(from: saved)
            } else {
                window.center()
            }
        } else {
            window.center()
        }
        // Un frame restaurado puede haber quedado en una pantalla que ya no está conectada.
        if !Self.isOnScreen(window.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)) { window.center() }
    }

    /// Si al menos 80 pt de la barra de título del frame quedan dentro del área visible de alguna pantalla.
    nonisolated static func isOnScreen(_ frame: NSRect, visibleFrames: [NSRect]) -> Bool {
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        return visibleFrames.contains { $0.intersection(titleBar).width >= min(80, frame.width) }
    }

    private func saveSharedFrame(_ window: NSWindow) {
        guard let id = id(for: window), let key = windowOptions[id]?.sharedFrameKey else { return }
        UserDefaults.standard.set(window.frameDescriptor, forKey: key)
    }

    private func replaceContent(of window: NSWindow, id: String, title: String, contentID: String?, controller: NSViewController) {
        setUnsavedChanges(false, for: id)
        let frame = window.frame
        window.contentViewController = controller
        window.setFrame(frame, display: true)
        window.title = title
        contentIDs[id] = contentID
    }

    private func id(for window: NSWindow) -> String? {
        windows.first { $0.value === window }?.key
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let id = id(for: sender), unsavedChanges.contains(id),
              let confirmation = windowOptions[id]?.closeConfirmation else { return true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = confirmation.message
        alert.informativeText = confirmation.info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.setUnsavedChanges(false, for: id)
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = id(for: window) else { return }
        saveSharedFrame(window)
        // Una ventana cerrada se olvida: al volver a abrirla se arma de cero (sin lo editado ni descartado).
        windows[id] = nil
        contentIDs[id] = nil
        windowOptions[id] = nil
        unsavedChanges.remove(id)
        window.delegate = nil
        // Después de que termine el cierre, para que AppKit no reactive la app al ceder el foco.
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveSharedFrame(window) }
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveSharedFrame(window) }
    }
}

/// What's in front on the current Space.
@MainActor
enum SpaceContext {
    /// Another app is in front with a window covering a whole screen: it's in full screen on this Space. Read from
    /// the window list's bounds (no Screen Recording permission needed for them).
    static func otherAppIsFullScreen() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let bounds = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { WindowSpaces.cgFrame($0.frame, mainScreenHeight: mainHeight) }
        return WindowSpaces.isFullScreen(windowBounds: bounds, screenFrames: screens)
    }
}
