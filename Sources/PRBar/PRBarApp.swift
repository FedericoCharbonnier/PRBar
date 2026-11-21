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
        WindowPresenter.shared.installMainMenu()
        model.showPopover = { [weak statusItem] in statusItem?.show() ?? false }
    }

    /// ⌘Q (menu, popover, Dock) while jobs are running asks first: quitting cancels them. `prbar app quit`, the
    /// updater's relaunch and a logout/restart don't ask.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        let activeJobs = model.activeJobCount + (model.updates.isInstalling ? 1 : 0)
        let unpushed = model.respond.unpushedWork.count
        guard QuitConfirmation.shouldAsk(activeJobs: activeJobs, unpushed: unpushed,
                                         programmatic: QuitRequest.skipsConfirmation || systemQuit)
        else { return terminateAfterStoppingProcesses(model) }
        // The panel is at menu level and would cover the alert. From it the app isn't active: the alert needs it, on
        // the Space the user is on.
        statusItem?.close()
        NSApp.activate()
        let alert = ConfirmAlert.make(title: QuitConfirmation.title(activeJobs: activeJobs, unpushed: unpushed),
                                      message: QuitConfirmation.message(activeJobs: activeJobs, unpushed: unpushed),
                                      action: "Quit")
        alert.window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        return ConfirmAlert.confirmed(alert.runModal()) ? terminateAfterStoppingProcesses(model) : .terminateCancel
    }

    private var stoppingProcesses = false

    /// Cancela todo y espera (unos segundos como mucho) a que terminen los procesos que lanzó PRBar; los que no
    /// terminan con SIGTERM reciben SIGKILL (`ProcessShutdown`). Recién después sale.
    private func terminateAfterStoppingProcesses(_ model: AppModel) -> NSApplication.TerminateReply {
        guard !stoppingProcesses else { return .terminateCancel }
        stoppingProcesses = true
        model.cancelEverythingForQuit()
        Task { @MainActor in
            await ProcessShutdown.terminateAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Quits that don't ask even with jobs running (`QuitConfirmation`).
@MainActor
enum QuitRequest {
    static var skipsConfirmation = false

    /// `prbar app quit` and the updater's relaunch.
    static func terminateWithoutAsking() {
        skipsConfirmation = true
        NSApp.terminate(nil)
    }
}
