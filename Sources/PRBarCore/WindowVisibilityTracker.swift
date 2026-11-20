import AppKit

/// Si una ventana está en pantalla: avisa al entrar en una ventana, en cada cambio de oclusión (minimizada, en otro
/// Space, tapada del todo) y `false` al cerrarse, aunque el contenido siga vivo (`WindowPresenter` guarda la vista).
/// Lo usa PRBar Activity para que `ResourceMonitor` muestree solo mientras se la ve (decisión I.1.7).
@MainActor
public final class WindowVisibilityTracker {
    private let isOnScreen: @MainActor (NSWindow) -> Bool
    private let onChange: (Bool) -> Void
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    public init(isOnScreen: @escaping @MainActor (NSWindow) -> Bool = WindowVisibilityTracker.isOnScreen,
                onChange: @escaping (Bool) -> Void) {
        self.isOnScreen = isOnScreen
        self.onChange = onChange
    }

    public static func isOnScreen(_ window: NSWindow) -> Bool {
        window.isVisible && window.occlusionState.contains(.visible)
    }

    /// La ventana que tiene ahora el contenido (`nil` = salió de la ventana).
    public func track(_ window: NSWindow?) {
        if window !== self.window {
            stopObserving()
            self.window = window
            if let window {
                // `queue: nil`: AppKit las manda en el hilo principal y se atienden en el acto.
                observers = [
                    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                           queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    },
                    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                           queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.stopObserving()
                            self?.window = nil
                            self?.onChange(false)
                        }
                    },
                ]
            }
        }
        report()
    }

    private func report() {
        onChange(window.map(isOnScreen) ?? false)
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
