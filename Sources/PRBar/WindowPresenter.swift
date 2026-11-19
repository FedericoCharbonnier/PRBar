import AppKit
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
/// con `AppMenu`); al cerrarse la última vuelve a `.accessory`.
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
    func close(id: String) {
        windows[id]?.close()
    }

    // MARK: Política de activación y menú

    private func bringToFront(_ id: String, _ window: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        installMainMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// SwiftUI arma su propio menú principal; el nuestro se reinstala cada vez que una ventana pasa al frente.
    private func installMainMenu() {
        guard NSApp.mainMenu !== mainMenu else { return }
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = mainMenu.items.last?.submenu
    }

    private func updateActivationPolicy() {
        guard windows.isEmpty, NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
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

    func windowDidBecomeKey(_ notification: Notification) {
        installMainMenu()
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveSharedFrame(window) }
    }

    func windowDidMove(_ notification: Notification) {
        if let window = notification.object as? NSWindow { saveSharedFrame(window) }
    }
}
