import AppKit
import PRBarCore
import SwiftUI

/// `PRBar --snapshots <dir> [--appearance light|dark|both]`: renders every screen with fictional sample data
/// (`SnapshotFixtures`) into PNGs in `<dir>` and exits.
///
/// Nothing real starts: each screen gets its own `AppModel` built with `startsServices: false` and in-memory
/// fakes (`SnapshotFakes`), so there's no refresh, no `gh`/`git`/`claude`, no Slack, no notifications and no
/// worktree cleanup. The stores that need files (config, state, history) use a scratch folder inside `<dir>`
/// that is deleted before exiting, and the app log is turned off: nothing is written outside `<dir>`.
@MainActor
enum SnapshotMode {
    static func run(_ options: SnapshotOptions) -> Never {
        AppLog.setDestination(nil)
        AvatarView.loadsRemoteImages = false
        let app = SnapshotApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let written = try await SnapshotSession(options: options).renderAll()
                print("Wrote \(written.count) snapshots to \(options.outputDirectory.path):")
                for name in written { print("  \(name)") }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Snapshots failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(0)
    }
}

/// Reports itself as active, so AppKit draws controls (switches, traffic lights, toolbar selection) with their
/// active colors. Snapshot mode never actually activates: the windows stay offscreen and the app has no Dock icon.
final class SnapshotApplication: NSApplication {
    /// The window being rendered, reported as the key and main window.
    weak var renderedWindow: NSWindow?
    override var isActive: Bool { true }
    override var keyWindow: NSWindow? { renderedWindow }
    override var mainWindow: NSWindow? { renderedWindow }
}

struct SnapshotError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class SnapshotSession {
    let options: SnapshotOptions
    let fixtures = SnapshotFixtures(now: Date())
    let scratch: URL
    private(set) var written: [String] = []

    init(options: SnapshotOptions) {
        self.options = options
        scratch = options.outputDirectory.appendingPathComponent(".snapshot-scratch", isDirectory: true)
    }

    private var out: URL { options.outputDirectory }

    func renderAll() async throws -> [String] {
        let files = FileManager.default
        try files.createDirectory(at: out, withIntermediateDirectories: true)
        try? files.removeItem(at: scratch)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        try menuBarIcon()

        // The popover first: the respond queue of this model is driven further below.
        let main = try makeModel("main", snapshot: fixtures.snapshot)
        main.reviews.restore(fixtures.reactQueryDraft)
        main.reviews.enqueue(ReviewRequest(item: fixtures.loginRedirect, localPath: nil, baseRef: "main"))
        try await waitUntil("the review in progress") {
            if case .reviewing? = main.reviews.phases[self.fixtures.loginRedirect.id] { return true }
            return false
        }
        try await popover("popover", model: main)
        main.reviews.cancelAll()

        let empty = try makeModel("empty", snapshot: fixtures.caughtUpSnapshot)
        try await popover("popover-empty", model: empty)

        try await reviewWindows(model: main)
        try await respondWindows(model: main)
        try await history()
        try await settings()
        try await notification()
        try await updateWindow()
        return written
    }

    // MARK: Models

    private func makeModel(_ name: String, snapshot: Snapshot) throws -> AppModel {
        let dir = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateURL = dir.appendingPathComponent("state.json")
        let configURL = dir.appendingPathComponent("config.json")
        try JSONCoding.encoder.encode(snapshot).write(to: stateURL)
        try JSONCoding.encoder.encode(fixtures.config).write(to: configURL)
        let historyDir = dir.appendingPathComponent("history", isDirectory: true)
        let respondHistory = RespondHistory(historyDir: historyDir)
        let services = AppModelServices(
            configStore: ConfigStore(fileURL: configURL),
            stateStore: SnapshotStore(url: stateURL),
            accounts: AccountProvider(runner: SnapshotProcessRunner(accounts: SnapshotFixtures.ghAccounts),
                                      ghPath: SnapshotFixtures.tools.gh),
            api: SnapshotFixtures.gitHubAPI,
            slack: SlackAnnouncer(api: SnapshotSlackAPI(channels: SnapshotFixtures.slackChannels), provider: .claudeConnector,
                                  secrets: SnapshotSecretStore(),
                                  stateStore: SlackStateStore(url: dir.appendingPathComponent("slack-state.json"))),
            notifications: nil,
            history: ReviewHistory(directory: historyDir),
            respondHistory: respondHistory,
            claudeSkills: ClaudeSkills(fixedEntries: SnapshotFixtures.skills),
            reviewPipeline: SnapshotReviewPipeline(drafts: [fixtures.reactQuery.id: fixtures.reactQueryDraft],
                                                   inProgress: [fixtures.loginRedirect.id]),
            respondPipeline: SnapshotRespondPipeline(draft: fixtures.csvDraft, result: fixtures.csvResult, tests: fixtures.csvTests,
                                                     logDirectory: respondHistory.directory.appendingPathComponent("logs")),
            chatBackend: SnapshotChatBackend(),
            instructionsStore: InstructionsStore(fileURL: dir.appendingPathComponent("instructions.json")),
            instructionsChatBackend: SnapshotInstructionsChatBackend(),
            discardStats: DiscardStatsStore(fileURL: dir.appendingPathComponent("discard-stats.json"))
        )
        let model = AppModel(services: services, startsServices: false)
        model.applySnapshotState(tools: SnapshotFixtures.tools, ghAccounts: SnapshotFixtures.ghAccounts, launchAtLogin: true)
        return model
    }

    // MARK: Screens

    private func updateWindow() async throws {
        let model = try makeModel("update", snapshot: fixtures.snapshot)
        model.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
        try await window("update", title: "Update PRBar", size: UpdateWindow.size) {
            UpdateWindow(updates: model.updates, mode: .available(SnapshotFixtures.updateRelease), close: {})
        }
    }

    private func menuBarIcon() throws {
        let icon = BadgeIcon.image(for: .count(5))
        for appearance in options.appearances {
            let dark = appearance == .dark
            let size = NSSize(width: 176, height: 30)
            let data = SnapshotRenderer.png(size: size) { rect in
                let strip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                strip.fill()
                let ink = dark ? NSColor.white : NSColor.black
                // Our icon, then two dimmed neighbors so it reads as a menu bar.
                var x: CGFloat = 16
                let ours = SnapshotRenderer.tinted(icon, ink)
                ours.draw(in: NSRect(x: x, y: (rect.height - ours.size.height) / 2, width: ours.size.width, height: ours.size.height))
                x += ours.size.width + 22
                let neighbors = ["wifi", "battery.75percent", "magnifyingglass"]
                for name in neighbors {
                    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                        .withSymbolConfiguration(config) else { continue }
                    let glyph = SnapshotRenderer.tinted(symbol, ink.withAlphaComponent(0.55))
                    glyph.draw(in: NSRect(x: x, y: (rect.height - glyph.size.height) / 2, width: glyph.size.width,
                                          height: glyph.size.height))
                    x += glyph.size.width + 18
                }
            }
            try write(data, "menubar-icon", appearance)
        }
    }

    private func popover(_ name: String, model: AppModel) async throws {
        for appearance in options.appearances {
            let content = PopoverView(model: model, prStore: model.prStore, configStore: model.configStore, slack: model.slack)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.popover, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            let controller = NSHostingController(rootView: content.environment(\.controlActiveState, .key))
            let window = SnapshotRenderer.makeWindow(
                controller: controller, size: NSSize(width: Theme.popoverWidth, height: 400), style: [.borderless],
                title: "PRBar", appearance: SnapshotRenderer.appearance(appearance), transparent: true
            )
            await SnapshotRenderer.settle(window)
            window.setContentSize(controller.view.fittingSize)
            await SnapshotRenderer.settle(window, seconds: 0.3)
            try write(SnapshotRenderer.capture(window, includeFrame: false), name, appearance)
        }
    }

    private func reviewWindows(model: AppModel) async throws {
        let draft = fixtures.loginRedirectDraft
        let title = "Review · \(draft.repo.name)#\(draft.number)"
        let chat = model.reviewChat(for: draft)
        chat.reviewEdits.generalComment = SnapshotFixtures.generalComment
        try await window("review-window", title: title, size: NSSize(width: 760, height: 980)) {
            ReviewWindow(model: model, draft: draft, chat: chat, published: nil, close: {}, initialState: .init(
                showsDiscarded: true, expandedFindings: ["open-redirect"]
            ))
        }
        var chatDraft = fixtures.loginRedirectDraft
        chatDraft.chat = fixtures.reviewChat
        chatDraft.edits = fixtures.reviewChatEdits
        let reviewChat = model.reviewChat(for: chatDraft)
        try await window("review-chat", title: title, size: NSSize(width: 1180, height: 980)) {
            ReviewWindow(model: model, draft: chatDraft, chat: reviewChat, published: nil, close: {},
                         initialState: .init(showsChat: true))
        }
        let published = PublishedReview(record: fixtures.publishedLoginRedirect)
        let publishedDraft = fixtures.loginRedirectDraft
        try await window("review-published", title: title, size: ReviewWindow.size) {
            ReviewWindow(model: model, draft: publishedDraft, chat: model.reviewChat(for: publishedDraft), published: published, close: {})
        }
    }

    private func respondWindows(model: AppModel) async throws {
        let item = fixtures.csvExport
        let prID = item.id
        model.respond.analyze(item, localPath: "/Users/sam/Code/web-app", worktreeDir: "/Users/sam/Code/worktrees")
        try await waitUntil("the analysis") {
            if case .ready? = model.respond.phases[prID] { return true }
            return false
        }
        guard let draft = model.respond.records[prID]?.draft else { throw SnapshotError(message: "No respond draft") }
        model.respond.setChat(prID: prID, draftID: draft.id, chat: fixtures.respondChat)
        let title = "Respond · \(draft.repo.name)#\(draft.number)"
        try await window("respond-choose", title: title, size: NSSize(width: 760, height: 1440)) {
            RespondWindow(model: model, prID: prID, draft: draft, chat: model.respondChat(for: draft), close: {})
        }

        let selections = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
        model.respond.implement(prID: prID, selections: selections)
        try await waitUntil("the fixes") {
            if case .readyToPush? = model.respond.phases[prID] { return true }
            return false
        }
        model.runRespondTests(prID: prID)
        try await waitUntil("the tests") {
            if case .readyToPush(_, let result)? = model.respond.phases[prID] { return result.tests != nil }
            return false
        }
        try await window("respond-ready-to-push", title: title, size: NSSize(width: 760, height: 1140)) {
            RespondWindow(model: model, prID: prID, draft: draft, chat: model.respondChat(for: draft), close: {})
        }
        try await window("respond-chat", title: title, size: NSSize(width: 1180, height: 1140)) {
            RespondWindow(model: model, prID: prID, draft: draft, chat: model.respondChat(for: draft), showsChat: true, close: {})
        }
    }

    private func history() async throws {
        let model = try makeModel("history", snapshot: fixtures.snapshot)
        for record in fixtures.historyReviews { try model.history.save(record) }
        for record in fixtures.historyResponds { try model.respondHistory.save(record) }
        for appearance in options.appearances {
            let controller = NSHostingController(rootView: HistoryWindow(model: model).environment(\.controlActiveState, .key))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = SnapshotRenderer.makeWindow(
                controller: controller, size: NSSize(width: 900, height: 600),
                style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], title: "History",
                toolbarStyle: .unified, appearance: SnapshotRenderer.appearance(appearance)
            )
            await SnapshotRenderer.settle(window, seconds: 1)
            try write(SnapshotRenderer.capture(window, includeFrame: true, cornerRadius: 16), "history", appearance)
        }
    }

    private func settings() async throws {
        let model = try makeModel("settings", snapshot: fixtures.snapshot)
        model.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
        let sizes: [SettingsWindow.Tab: NSSize] = [
            .general: NSSize(width: 700, height: 880),
            .claude: NSSize(width: 700, height: 820),
            .repos: NSSize(width: 700, height: 940),
            .slack: NSSize(width: 700, height: 1180),
        ]
        for tab in SettingsWindow.Tab.allCases {
            for appearance in options.appearances {
                let controller = SettingsWindow.makeController(model: model, tab: tab)
                if let size = sizes[tab], let tabs = controller as? NSTabViewController {
                    // Taller than in the app, so the whole tab fits without scrolling.
                    for item in tabs.tabViewItems { item.viewController?.preferredContentSize = size }
                }
                let window = SnapshotRenderer.makeWindow(
                    controller: controller, size: sizes[tab] ?? tab.contentSize, style: [.titled, .closable],
                    title: tab.title, toolbarStyle: .preference, appearance: SnapshotRenderer.appearance(appearance)
                )
                window.setContentSize(sizes[tab] ?? tab.contentSize)
                await SnapshotRenderer.settle(window, seconds: 1)
                if appearance == .dark {
                    // Offscreen, the selected tab's glass capsule draws as a solid white block in Dark Mode: the
                    // dark snapshots show the toolbar without a selected tab (the title still names it).
                    window.toolbar?.selectedItemIdentifier = nil
                    await SnapshotRenderer.settle(window, seconds: 0.2)
                }
                try write(SnapshotRenderer.capture(window, includeFrame: true, cornerRadius: 16), "settings-\(tab.rawValue)", appearance)
            }
        }
    }

    private func notification() async throws {
        let draft = fixtures.reactQueryDraft
        guard let planned = NotificationPlanner.reviewFinished(
            prID: draft.prID, repo: draft.repo, number: draft.number, keptCount: draft.keptCount,
            settings: NotificationSettings()
        ) else { throw SnapshotError(message: "No notification") }
        for appearance in options.appearances {
            let controller = NSHostingController(rootView: NotificationIllustration(title: planned.title, message: planned.body))
            let window = SnapshotRenderer.makeWindow(
                controller: controller, size: NSSize(width: 412, height: 120), style: [.borderless], title: "Notification",
                appearance: SnapshotRenderer.appearance(appearance), transparent: true
            )
            await SnapshotRenderer.settle(window, seconds: 0.3)
            window.setContentSize(controller.view.fittingSize)
            await SnapshotRenderer.settle(window, seconds: 0.2)
            try write(SnapshotRenderer.capture(window, includeFrame: false), "notification", appearance)
        }
    }

    // MARK: Helpers

    /// A titled window like `WindowPresenter` makes, with SwiftUI content, captured with its title bar.
    private func window<Content: View>(_ name: String, title: String, size: NSSize,
                                       content: @escaping () -> Content) async throws {
        for appearance in options.appearances {
            let controller = NSHostingController(rootView: content().environment(\.controlActiveState, .key))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = SnapshotRenderer.makeWindow(
                controller: controller, size: size,
                style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], title: title,
                toolbarStyle: .unified, appearance: SnapshotRenderer.appearance(appearance)
            )
            await SnapshotRenderer.settle(window)
            try write(SnapshotRenderer.capture(window, includeFrame: true, cornerRadius: 10), name, appearance)
        }
    }

    private func write(_ data: Data?, _ base: String, _ appearance: SnapshotOptions.Appearance) throws {
        guard let data else { throw SnapshotError(message: "Couldn’t render \(base) (\(appearance.rawValue))") }
        let name = options.fileName(base, appearance: appearance)
        try data.write(to: out.appendingPathComponent(name))
        written.append(name)
    }

    private func waitUntil(_ what: String, timeout: Double = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw SnapshotError(message: "Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
