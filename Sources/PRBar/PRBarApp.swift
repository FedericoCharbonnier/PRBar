import AppKit
import PRBarCore

/// The menu bar app: AppKit's lifecycle with `AppDelegate`. There are no SwiftUI scenes: the icon and its panel are
/// `StatusItemController`, and every window goes through `WindowPresenter`.
@MainActor
enum PRBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `NSApplication.delegate` is weak; `run()` only returns when the app quits.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launching finishes: a click on a notification that launched the app needs the notification
        // delegate that `AppModel` installs.
        model = AppModel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let statusItem = StatusItemController(model: model)
        self.statusItem = statusItem
        model.showPopover = { [weak statusItem] in statusItem?.show() ?? false }
    }
}
