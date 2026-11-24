import AppKit
import PRBarCore
import SwiftUI

/// `PRBar --snapshots <dir> [--appearance light|dark|both]`: renders every screen with fictional sample data
/// (`SnapshotFixtures`) into PNGs in `<dir>` and exits.
///
/// Nothing real starts: each screen gets its own `AppModel` built with `startsServices: false` and in-memory
/// fakes (`SnapshotFakes`), so there's no refresh, no `gh`/`git`/`claude`, no Slack, no notifications and no
/// worktree cleanup. The stores that need files (config, state, history) use a scratch folder inside `<dir>`
/// that is deleted before exiting, the popover's tab is kept in memory (not in UserDefaults) and the app log is turned
/// off: nothing is written outside `<dir>`.
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

        try menuBarIcon("menubar-icon", updateDot: false)
        try menuBarIcon("menubar-icon-update", updateDot: true)

        // The popover first: the respond queue of this model is driven further below.
        let main = try makeModel("main", snapshot: fixtures.snapshot)
        main.reviews.restore(fixtures.reactQueryDraft)
        main.reviews.enqueue(ReviewRequest(item: fixtures.loginRedirect, localPath: nil, baseRef: "main"))
        try await waitUntil("the review in progress") {
            if case .reviewing? = main.reviews.phases[self.fixtures.loginRedirect.id] { return true }
            return false
        }
        try await popover("popover", model: main)
        main.popoverTab.selected = .mine
        try await popover("popover-mine", model: main)
        main.popoverTab.selected = .toReview
        // The same popover with a new version offered: the "Update" button in the header.
        main.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
        try await popover("popover-update", model: main)
        main.updates.applySnapshotState(available: nil)
        // La ventana principal (plan 21): To Review con la review lista de react-query elegida y la otra corriendo.
        main.main.go(to: .pr(prID: fixtures.reactQuery.id, tab: nil), snapshot: main.prStore.snapshot)
        try await window("main-list", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: main) }
        // ⌘F (spec M.1): la lista filtrada por "web-app", con las secciones que tienen resultados desplegadas.
        main.main.search = "web-app"
        try await window("main-search", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: main) }
        main.main.search = ""
        main.reviews.cancelAll()

        let empty = try makeModel("empty", snapshot: fixtures.caughtUpSnapshot)
        try await popover("popover-empty", model: empty)
        empty.popoverTab.selected = .mine
        try await popover("popover-empty-mine", model: empty)
        // La ventana principal sin nada que hacer, en su tamaño mínimo (spec M.1 "Vacío").
        empty.main.go(to: .list(.toReview), snapshot: empty.prStore.snapshot)
        try await window("main-empty", title: "PRBar", size: Theme.MainLayout.minSize) { MainWindow(model: empty) }
        // Recién arrancada, sin `state.json`: las filas esqueleto.
        let loading = try makeModel("loading", snapshot: nil)
        try await window("main-loading", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: loading) }

        try await reviewTab()
        try await respondTabs(model: main)
        try await mergeTabs()
        try await history()
        try await settings()
        try await notification()
        try await updateSheet()
        try await fixCITab()
        let activity = try makeModel("activity", snapshot: fixtures.snapshot)
        activity.snapshotLiveUsage = fixtures.liveUsage
        activity.main.go(to: .activity, snapshot: activity.prStore.snapshot)
        try await window("main-activity", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: activity) }
        return written
    }

    // MARK: Models

    private func makeModel(_ name: String, snapshot: Snapshot?, holdsImplementation: Bool = false) throws -> AppModel {
        let dir = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateURL = dir.appendingPathComponent("state.json")
        let configURL = dir.appendingPathComponent("config.json")
        if let snapshot { try JSONCoding.encoder.encode(snapshot).write(to: stateURL) }
        try JSONCoding.encoder.encode(fixtures.config).write(to: configURL)
        let historyDir = dir.appendingPathComponent("history", isDirectory: true)
        let respondHistory = RespondHistory(historyDir: historyDir)
        try JSONCoding.encoder.encode(fixtures.instructions).write(to: dir.appendingPathComponent("instructions.json"))
        try DiscardStatsStore(fileURL: dir.appendingPathComponent("discard-stats.json")).record(fixtures.discards, now: fixtures.date())
        // Claude's usage (spec O): the ledger of PRBar Activity, in this model's folder.
        let ledger = UsageLedger(url: dir.appendingPathComponent("usage.json"))
        for entry in fixtures.usageEntries { ledger.append(entry, now: fixtures.date()) }
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
                                                     logDirectory: respondHistory.directory.appendingPathComponent("logs"),
                                                     ciDraft: fixtures.ciFixDraft, ciResult: fixtures.ciFixResult,
                                                     holdsImplementation: holdsImplementation),
            chatBackend: SnapshotChatBackend(),
            instructionsStore: InstructionsStore(fileURL: dir.appendingPathComponent("instructions.json")),
            instructionsChatBackend: SnapshotInstructionsChatBackend(),
            discardStats: DiscardStatsStore(fileURL: dir.appendingPathComponent("discard-stats.json")),
            mergeHistory: MergeHistory(historyDir: historyDir),
            popoverDefaults: nil,   // the popover's tab only in memory: the user's UserDefaults aren't touched
            usageLedger: ledger,
            // Nothing outside the snapshot folder (spec T.3's file included).
            retainedWorktrees: RetainedWorktreeStore(fileURL: dir.appendingPathComponent("retained-worktrees.json"))
        )
        let model = AppModel(services: services, startsServices: false)
        model.applySnapshotState(tools: SnapshotFixtures.tools, ghAccounts: SnapshotFixtures.ghAccounts, launchAtLogin: true)
        // Run On: the last checks and where jobs ran, filled in directly (the coordinator is never used here, and
        // the local versions are set so Settings doesn't run `--version`).
        model.runnerChecks = [SnapshotFixtures.devbox.name: fixtures.devboxCheck]
        model.placements = fixtures.placements
        model.localToolVersions = LocalToolVersions(tools: SnapshotFixtures.tools, git: "git version 2.47.1",
                                                    claude: "2.1.318 (Claude Code)")
        model.resources.applySnapshotState(usage: fixtures.resourceUsage, disk: fixtures.diskUsage)
        return model
    }

    // MARK: Screens

    private func updateSheet() async throws {
        let model = try makeModel("update", snapshot: fixtures.snapshot)
        model.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
        // The sheet over the main window (spec M.2): a sheet of an offscreen window isn't captured, so it's drawn on
        // top of the window's content, centered at the top and dimmed behind, the way it looks attached.
        try await window("main-update-sheet", title: "PRBar", size: Theme.MainLayout.defaultSize) {
            MainWindow(model: model)
                .overlay {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .overlay(alignment: .top) {
                            UpdateSheet(updates: model.updates, mode: .available(SnapshotFixtures.updateRelease), close: {})
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                        }
                }
        }
    }

    /// With `updateDot`, the blue dot `UpdateDotView` draws over the icon in the real menu bar.
    private func menuBarIcon(_ name: String, updateDot: Bool) throws {
        let state = MenuBarIconState.count(5)
        let icon = BadgeIcon.image(for: state, updateDot: updateDot)
        let dot = BadgeIcon.updateDotRect(imageSize: icon.size)
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
                let iconY = (rect.height - ours.size.height) / 2
                ours.draw(in: NSRect(x: x, y: iconY, width: ours.size.width, height: ours.size.height))
                if updateDot {
                    NSColor.systemBlue.setFill()
                    NSBezierPath(ovalIn: dot.offsetBy(dx: x, dy: iconY)).fill()
                }
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
            try write(data, name, appearance)
        }
    }

    private func popover(_ name: String, model: AppModel) async throws {
        for appearance in options.appearances {
            let content = PopoverView(model: model, prStore: model.prStore, configStore: model.configStore, slack: model.slack,
                                      tabs: model.popoverTab, rows: model.popoverRows)
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

    /// The Review tab of api#317 in the main window: the editor with the discarded findings open and one expanded, and
    /// then with the chat open and a rule proposed in it.
    private func reviewTab() async throws {
        let model = try makeModel("review", snapshot: fixtures.snapshot)
        let draft = fixtures.loginRedirectDraft
        model.reviews.restore(draft)
        model.reviewChat(for: draft).reviewEdits.generalComment = SnapshotFixtures.generalComment
        model.main.go(to: .pr(prID: draft.prID, tab: .review), snapshot: model.prStore.snapshot)
        try await window("main-review", title: "PRBar", size: Theme.MainLayout.defaultSize) {
            MainWindow(model: model)
                .environment(\.reviewEditorInitialState, .init(showsDiscarded: true, expandedFindings: ["open-redirect"]))
        }
        var ruleDraft = fixtures.loginRedirectDraft
        // Its own id: `reviewChat(for:)` keeps one coordinator per draft id.
        ruleDraft.id = UUID()
        ruleDraft.chat = fixtures.reviewChatWithRule
        ruleDraft.edits = fixtures.reviewChatEdits
        model.reviews.restore(ruleDraft)
        model.main.detail.focus.setChatShown(true)
        try await window("main-review-chat", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }
    }

    /// web-app#475 (mine, with feedback) in the Respond tab: choosing what to fix, and then, in its own model whose
    /// pipeline holds the implementation, Claude implementing (focus mode: no list, chat open).
    private func respondTabs(model: AppModel) async throws {
        let item = fixtures.csvExport
        let prID = item.id
        model.respond.analyze(item, localPath: "/Users/sam/Code/web-app", worktreeDir: "/Users/sam/Code/worktrees")
        try await waitUntil("the analysis") {
            if case .ready? = model.respond.phases[prID] { return true }
            return false
        }
        guard let draft = model.respond.records[prID]?.draft else { throw SnapshotError(message: "No respond draft") }
        model.respond.setChat(prID: prID, draftID: draft.id, chat: fixtures.respondChat)
        model.main.go(to: .pr(prID: prID, tab: .respond), snapshot: model.prStore.snapshot)
        try await window("main-respond-choose", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }

        let focus = try makeModel("respond-focus", snapshot: fixtures.snapshot, holdsImplementation: true)
        focus.respond.analyze(item, localPath: "/Users/sam/Code/web-app", worktreeDir: "/Users/sam/Code/worktrees")
        try await waitUntil("the analysis") {
            if case .ready? = focus.respond.phases[prID] { return true }
            return false
        }
        guard let focusDraft = focus.respond.records[prID]?.draft else { throw SnapshotError(message: "No respond draft") }
        focus.respond.setChat(prID: prID, draftID: focusDraft.id, chat: fixtures.respondChat)
        let selections = Dictionary(uniqueKeysWithValues: focusDraft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
        focus.respond.implement(prID: prID, selections: selections)
        try await waitUntil("the implementation") {
            if case .implementing(let done, _)? = focus.respond.phases[prID] { return done > 0 }
            return false
        }
        focus.main.go(to: .pr(prID: prID, tab: .respond), snapshot: focus.prStore.snapshot)
        try await window("main-respond-focus", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: focus) }
        focus.respond.cancel(prID: prID)
    }

    /// Fix CI (spec K) of web-app#475: the popover row while the fix waits to be pushed, and its Fix CI tab.
    private func fixCITab() async throws {
        let model = try makeModel("ci-fix", snapshot: fixtures.snapshot)
        let item = fixtures.csvExport
        let prID = item.id
        model.respond.analyze(item, localPath: "/Users/sam/Code/web-app", worktreeDir: "/Users/sam/Code/worktrees", mode: .ciFix)
        try await waitUntil("the CI fix") {
            if case .readyToPush? = model.respond.phases[prID] { return true }
            return false
        }
        guard model.respond.records[prID] != nil else { throw SnapshotError(message: "No CI fix draft") }
        model.popoverTab.selected = .mine
        try await popover("popover-mine-ci-fix", model: model)
        model.main.go(to: .pr(prID: prID, tab: .fixCI), snapshot: model.prStore.snapshot)
        try await window("main-fix-ci-ready", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }
    }

    /// api#322 (mine, Ready to Merge) in the Merge tab with its summary loaded, and web-app#491 (someone else's) in
    /// Details (spec M.1).
    private func mergeTabs() async throws {
        let model = try makeModel("merge", snapshot: fixtures.snapshot)
        let item = fixtures.idempotencyKeys
        let detail = fixtures.idempotencyDetail
        let record = MergeRecord(item: item, startedAt: fixtures.date(minutes: -8))
        model.mergeSessions[item.id] = MergeSession(
            window: MergeDetailModel(prID: item.id, recordID: record.id, detail: detail) { detail }, record: record)
        model.main.go(to: .pr(prID: item.id, tab: .merge), snapshot: model.prStore.snapshot)
        try await window("main-merge", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }
        // El mismo PR en su ventana (⇧⌘O, spec M.2): solo el detalle, sin barra lateral ni lista.
        try await window("pr-window", title: ClaudeTasksSidebar.shortName(item.id), size: PRWindow.size) {
            PRWindow(model: model, prID: item.id)
        }

        let other = fixtures.rateLimiting
        var otherDetail = detail
        otherDetail.number = other.pr.number
        otherDetail.title = other.pr.title
        otherDetail.url = other.pr.url
        otherDetail.author = other.pr.author
        otherDetail.baseRef = other.pr.baseRef
        otherDetail.headRef = other.pr.headRef
        otherDetail.headOid = other.pr.headOid
        otherDetail.additions = other.pr.additions
        otherDetail.deletions = other.pr.deletions
        otherDetail.body = "Adds a token bucket to `/sync` so a client that retries in a loop can’t starve the others."
        otherDetail.reviews = []
        otherDetail.reviewDecision = .reviewRequired
        let otherRecord = MergeRecord(item: other, startedAt: fixtures.date(minutes: -3))
        model.mergeSessions[other.id] = MergeSession(
            window: MergeDetailModel(prID: other.id, recordID: otherRecord.id, detail: otherDetail) { otherDetail },
            record: otherRecord)
        model.main.go(to: .pr(prID: other.id, tab: .details), snapshot: model.prStore.snapshot)
        try await window("main-details", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }
    }

    /// History in the main window: the newest record selected, then the Fix CI one (its checks, commit and Claude's
    /// estimated cost; specs K and O).
    private func history() async throws {
        let model = try makeModel("history", snapshot: fixtures.snapshot)
        for record in fixtures.historyReviews { try model.history.save(record) }
        let responds = fixtures.historyResponds
        for record in responds { try model.respondHistory.save(record) }
        await model.main.history.reload(model)
        model.main.go(to: .history(recordID: model.main.history.all.first?.id), snapshot: model.prStore.snapshot)
        try await window("main-history", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }
        model.main.go(to: .history(recordID: responds[0].id), snapshot: model.prStore.snapshot)
        try await window("main-history-ci-fix", title: "PRBar", size: Theme.MainLayout.defaultSize) { MainWindow(model: model) }
    }

    private func settings() async throws {
        let model = try makeModel("settings", snapshot: fixtures.snapshot)
        model.updates.applySnapshotState(available: SnapshotFixtures.updateRelease)
        // Settings › iPhone: conectado, con dos iPhones y el link de instalación (spec Q.2).
        try SnapshotFixtures.applyIPhone(model, .connected)
        let sizes: [SettingsWindow.Tab: NSSize] = [
            .general: NSSize(width: 700, height: 905),
            .claude: NSSize(width: 700, height: 860),
            .instructions: NSSize(width: 700, height: 1330),
            .repos: NSSize(width: 700, height: 1330),
            .slack: NSSize(width: 700, height: 1260),
            .iphone: NSSize(width: 700, height: 880),
        ]
        // Settings › Claude is split in pages: its Review page and its Run On page (the hosts) get a snapshot each.
        typealias Shot = (tab: SettingsWindow.Tab, page: ClaudeTab.Page?, name: String, size: NSSize?)
        var pages: [Shot] = []
        for tab in SettingsWindow.Tab.allCases {
            if tab == .claude {
                pages.append((tab, .review, "settings-claude", sizes[tab]))
                pages.append((tab, .runOn, "settings-claude-run-on", NSSize(width: 700, height: 580)))
            } else {
                pages.append((tab, nil, "settings-\(tab.rawValue)", sizes[tab]))
            }
        }
        for (tab, page, name, size) in pages {
            ClaudeTab.initialPage = page ?? .review
            for appearance in options.appearances {
                let controller = SettingsWindow.makeController(model: model, tab: tab)
                if let size, let tabs = controller as? NSTabViewController {
                    // Taller than in the app, so the whole tab fits without scrolling.
                    for item in tabs.tabViewItems { item.viewController?.preferredContentSize = size }
                }
                let window = SnapshotRenderer.makeWindow(
                    controller: controller, size: size ?? tab.contentSize, style: [.titled, .closable],
                    title: tab.title, toolbarStyle: .preference, appearance: SnapshotRenderer.appearance(appearance)
                )
                window.setContentSize(size ?? tab.contentSize)
                await SnapshotRenderer.settle(window, seconds: 1)
                if appearance == .dark {
                    // Offscreen, the selected tab's glass capsule draws as a solid white block in Dark Mode: the
                    // dark snapshots show the toolbar without a selected tab (the title still names it).
                    window.toolbar?.selectedItemIdentifier = nil
                    await SnapshotRenderer.settle(window, seconds: 0.2)
                }
                try write(SnapshotRenderer.capture(window, includeFrame: true, cornerRadius: 16), name, appearance)
            }
        }
        ClaudeTab.initialPage = .review
        try await iphoneSettings(model)
    }

    /// Los otros estados de Settings › iPhone y las dos caras de "Pair iPhone…" (spec Q.2).
    private func iphoneSettings(_ model: AppModel) async throws {
        for (state, name) in [(SnapshotFixtures.IPhoneState.off, "settings-iphone-off")] {
            try SnapshotFixtures.applyIPhone(model, state)
            for appearance in options.appearances {
                let tab = SettingsWindow.Tab.iphone
                let size = NSSize(width: 700, height: 720)
                let controller = SettingsWindow.makeController(model: model, tab: tab)
                if let tabs = controller as? NSTabViewController {
                    for item in tabs.tabViewItems { item.viewController?.preferredContentSize = size }
                }
                let window = SnapshotRenderer.makeWindow(
                    controller: controller, size: size,
                    style: [.titled, .closable], title: tab.title, toolbarStyle: .preference,
                    appearance: SnapshotRenderer.appearance(appearance)
                )
                window.setContentSize(size)
                await SnapshotRenderer.settle(window, seconds: 1)
                if appearance == .dark {
                    window.toolbar?.selectedItemIdentifier = nil
                    await SnapshotRenderer.settle(window, seconds: 0.2)
                }
                try write(SnapshotRenderer.capture(window, includeFrame: true, cornerRadius: 16), name, appearance)
            }
        }
        for (state, name) in [(SnapshotFixtures.IPhoneState.pairingQR, "iphone-pair-qr"), (.pairingCode, "iphone-pair-code")] {
            try SnapshotFixtures.applyIPhone(model, state)
            try await sheet(name, size: NSSize(width: 420, height: 400)) {
                PairIPhoneSheet(model: model, remote: model.remoteAccess, startsPairing: false) {}
            }
        }
        try await sheet("iphone-enable", size: NSSize(width: 460, height: 300)) {
            EnableRemoteSheet(model: model, initialHost: RemoteSettings.defaultRelayHost) {}
        }
    }

    /// Una hoja sola, como se ve sobre su ventana (sin barra de título).
    private func sheet<Content: View>(_ name: String, size: NSSize, content: @escaping () -> Content) async throws {
        for appearance in options.appearances {
            let controller = NSHostingController(rootView: content()
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.controlActiveState, .key))
            let window = SnapshotRenderer.makeWindow(
                controller: controller, size: size, style: [.titled], title: "",
                appearance: SnapshotRenderer.appearance(appearance)
            )
            await SnapshotRenderer.settle(window, seconds: 0.5)
            window.setContentSize(controller.view.fittingSize)
            await SnapshotRenderer.settle(window, seconds: 0.3)
            try write(SnapshotRenderer.capture(window, includeFrame: false), name, appearance)
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
