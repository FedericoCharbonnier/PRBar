import AppKit
import Foundation
import PRBarCore

enum WindowVisibilityTests {
    static let cases: [TestCase] = [
        TestCase("resources: la ventana Activity avisa si está en pantalla al cambiar su oclusión y deja de estarlo al cerrarse") { @MainActor in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            var onScreen = true
            var reports: [Bool] = []
            let tracker = WindowVisibilityTracker(isOnScreen: { _ in onScreen }) { reports.append($0) }
            tracker.track(window)
            try expectEqual(reports, [true])
            onScreen = false   // minimizada u oculta detrás de otra
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            try expectEqual(reports, [true, false])
            onScreen = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            try expectEqual(reports, [true, false, true])
            // Al cerrarse: false aunque la ventana todavía diga que está en pantalla, y no escucha más.
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            try expectEqual(reports, [true, false, true, false])
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            try expectEqual(reports, [true, false, true, false])
            tracker.track(nil)
            try expectEqual(reports.last, false)
        },
    ]
}
