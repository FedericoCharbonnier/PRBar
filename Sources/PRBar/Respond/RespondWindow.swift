import AppKit
import PRBarCore
import SwiftUI

/// Ventana de Responder (spec §14): elegir qué arreglar y qué responder, ver los fixes de Claude (diff, archivos
/// sensibles, tests a pedido) y pushear + responder. Sigue en vivo la fase del PR en `RespondQueue`.
///
/// Seguridad: nada que escribió Claude se ejecuta antes de que el usuario vea el diff **completo** (y los commits
/// con sus mensajes), que va arriba de "Correr tests" y del push. Los tests corren solo con "Correr tests"; el push
/// (con los hooks del usuario, en el worktree de PRBar) y las respuestas, solo después de confirmar, y Return en
/// la confirmación cancela (`ConfirmAlert`).
struct RespondWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: RespondQueue
    @ObservedObject var prStore: PRStore
    let prID: String
    /// El análisis con el que se abrió la ventana. Si el PR se vuelve a analizar, `AppModel.openRespond` la
    /// reemplaza con el nuevo.
    let draft: RespondDraft
    /// Avisa si hay decisiones o textos sin usar (etapa de elección).
    let reportUnsaved: (Bool) -> Void
    let close: () -> Void
    /// The decisions (shared with the chat, which can draft replies and choose fixes).
    @ObservedObject var chat: ChatCoordinator
    private let initialSelections: [String: RespondSelection]

    @FocusState private var focus: RespondFocus?
    @State private var showsChat: Bool
    /// The panel's width, remembered between windows (320–480).
    @AppStorage("ChatPanelWidth") private var chatWidth = 360.0

    static let size = NSSize(width: 760, height: 680)

    init(model: AppModel, prID: String, draft: RespondDraft, chat: ChatCoordinator, showsChat: Bool = false,
         reportUnsaved: @escaping (Bool) -> Void = { _ in }, close: @escaping () -> Void) {
        self.model = model
        queue = model.respond
        prStore = model.prStore
        self.prID = prID
        self.draft = draft
        self.reportUnsaved = reportUnsaved
        self.close = close
        // Lo que ya se eligió (p. ej. se canceló la implementación o falló la publicación) o, si no, lo que propuso
        // Claude: `AppModel.respondChat` arma las decisiones del coordinador.
        self.chat = chat
        initialSelections = chat.selections
        _showsChat = State(initialValue: showsChat)
    }

    // MARK: Estado

    /// El registro de este análisis (nil si se descartó o se reemplazó).
    private var record: RespondRecord? {
        queue.records[prID].flatMap { $0.id == draft.id ? $0 : nil }
    }

    private enum Stage {
        /// Elegir qué arreglar y qué responder; `error` si falló lo último que se intentó.
        case choosing(error: String?, canAct: Bool)
        case waiting(String)
        case implementing(done: Int, total: Int)
        /// Fixes hechos: diff, tests y push. `error` si falló el push o alguna respuesta.
        case review(RespondResult, error: String?)
        case pushing
        case done(RespondRecord)
        /// Hay un análisis más nuevo de este PR.
        case superseded
        /// Ya no hay nada que mostrar (se descartó o el análisis nuevo falló).
        case gone(String?)
    }

    /// A Fix CI (spec K): the checks instead of comments, no replies, "Push" instead of "Push and Reply".
    private var isCI: Bool { draft.isCIFix }

    private var stage: Stage {
        switch queue.phases[prID] {
        case .ready(let ready)?:
            return ready.id == draft.id ? .choosing(error: nil, canAct: true) : .superseded
        case .queued?:
            return .waiting(record?.result == nil ? "Queued…" : "Queued to post…")
        case .preparing?:
            return .waiting(isCI ? "Reading the failing checks and preparing the worktree…" : "Preparing the worktree…")
        case .analyzing?:
            return .waiting("Claude is analyzing the comments…")
        case .implementing(let done, let total)?:
            return .implementing(done: done, total: total)
        case .readyToPush(let current, let result)?:
            return current.id == draft.id ? .review(result, error: nil) : .superseded
        case .pushing?:
            return .pushing
        case .done(let done)?:
            return done.id == draft.id ? .done(done) : .superseded
        case .failed(let message, _)?:
            guard let record else { return .gone(message) }
            if let result = record.result { return .review(result, error: message) }
            return .choosing(error: message, canAct: false)
        case nil:
            return .gone(nil)
        }
    }

    private var isChoosing: Bool {
        if case .choosing = stage { return true }
        return false
    }

    private var hasUnsavedChanges: Bool { isChoosing && chat.selections != initialSelections }
    private var fixCount: Int { RespondCounts.fixes(draft, chat.selections) }
    private var replyCount: Int { RespondCounts.plannedReplies(draft, chat.selections) }
    private var testCommand: String? { model.testCommand(for: draft) }
    private var runningTests: Bool { queue.runningTests.contains(prID) }

    /// The chat waits while PRBar analyzes, implements, tests or pushes.
    private var chatLock: String? {
        switch stage {
        case .waiting: "Wait for the analysis to finish."
        case .implementing: isCI ? "Claude is fixing the CI." : "Claude is implementing the fixes."
        case .pushing: isCI ? "Pushing…" : "Pushing and posting the replies…"
        case .review where runningTests: "The tests are running."
        default: nil
        }
    }

    /// Pushed or done: the conversation stays, read only.
    private var isFinished: Bool {
        if case .done = stage { return true }
        return record?.pushed == true
    }

    // MARK: Vista

    var body: some View {
        VStack(spacing: 0) {
            RespondHeader(draft: draft, placement: draft.runner.map { "on \($0)" } ?? model.placements.label(prID: draft.prID))
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            content
        }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity, alignment: .top)
        .onChange(of: hasUnsavedChanges, initial: true) { _, unsaved in reportUnsaved(unsaved) }
        .onChange(of: chatLock, initial: true) { _, reason in chat.setLock(reason) }
        .onChange(of: isFinished, initial: true) { _, finished in if finished { chat.markReadOnly() } }
        // Opening the chat widens the window as needed, staying on the screen.
        .growsWindowForInspector(isPresented: showsChat && model.chatEnabled, minContentWidth: 620, inspectorWidth: chatWidth)
        // View › Show Chat (⇧⌘C) in the menu bar.
        .windowCommand(.toggleChat, enabled: model.chatEnabled, isOn: showsChat && model.chatEnabled) { showsChat.toggle() }
        .inspector(isPresented: Binding(get: { showsChat && model.chatEnabled }, set: { showsChat = $0 })) {
            ChatPanel(chat: chat, unavailableReason: model.chatUnavailableReason(for: chat),
                      notice: nil,
                      host: model.chatHost(chat), logURL: model.respondHistory.logURL(for: draft.id))
                .inspectorColumnWidth(min: 320, ideal: chatWidth, max: 480)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width) { _, width in chatWidth = min(max(width, 320), 480) }
                })
        }
        .toolbar {
            if model.chatEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button { showsChat.toggle() } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Chat with Claude (⇧⌘C)")
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .choosing(let error, let canAct):
            if isCI { ciChoosing(error: error, canAct: canAct) } else { choosing(error: error, canAct: canAct) }
        case .waiting(let text):
            progress(text, cancellable: true)
        case .implementing(let done, let total):
            implementing(done: done, total: total)
        case .review(let result, let error):
            review(result, error: error)
        case .pushing:
            progress(isCI ? "Checking the CI again and pushing to \(draft.headRef)…" : "Pushing to \(draft.headRef) and posting the replies…",
                     cancellable: false)
        case .done(let record):
            RespondDoneView(record: record, close: close)
        case .superseded:
            message(icon: "arrow.triangle.2.circlepath", title: "There’s a Newer Analysis of This PR",
                    text: "This window shows the previous one.", action: ("Open New Analysis", { model.openRespond(prID: prID) }))
        case .gone(let error):
            message(icon: error == nil ? "tray" : "exclamationmark.triangle",
                    title: error == nil ? "Discarded" : isCI ? "Couldn’t Fix the CI" : "Couldn’t Analyze the PR",
                    text: error ?? "This analysis is no longer in progress. It’s still in History.", action: nil)
        }
    }

    // MARK: Etapa: Fix CI sin arrancar

    /// A Fix CI whose fix didn't start on its own (or failed before committing): the checks and "Fix CI".
    private func ciChoosing(error: String?, canAct: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error { ErrorBanner(messages: [error]).padding(.horizontal, -10) }
                    CIChecksSection(draft: draft, result: nil)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Claude reads the CI output above and fixes the code in PRBar’s worktree. Nothing is pushed until you push.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    // After a failure: read the checks again (they may have changed) and fix from scratch.
                    Button(canAct ? "Fix CI" : "Fix CI Again") {
                        if canAct {
                            queue.implementCI(prID: prID)
                        } else if let item = currentItem {
                            model.startCIFix(item)
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled((!canAct && currentItem.map(model.ciFixUnavailableReason) != .some(nil)) || chat.isRunning
                                  || model.jobsBlockedReason != nil)
                        .help(model.jobsBlockedReason ?? "Claude fixes the code; you review the diff before pushing")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    // MARK: Etapa: elegir

    private func choosing(error: String?, canAct: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(draft.items.count) unresolved comment\(draft.items.count == 1 ? "" : "s")")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("Reset to Claude’s Suggestions") {
                    model.resetRespondSelections(draft)
                }
                .controlSize(.small)
                .help("Go back to Claude’s decisions and texts")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(draft.items) { item in
                        RespondItemCard(item: item, selection: selection(item), disabled: false, focus: $focus,
                                        language: draft.language, isHighlighted: chat.highlighted.contains(item.id))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { choosingFooter(error: error, canAct: canAct) }
        }
    }

    private func choosingFooter(error: String?, canAct: Bool) -> some View {
        let alreadyPosted = record?.posted.count ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            if let error {
                ErrorBanner(messages: [error]).padding(.horizontal, -10)
            }
            Label("Replies will be posted in \(draft.language.displayName)", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Detected from the PR description, including PRBar’s “Fixed in …” prefix. Text you write is posted as is.")
            HStack(spacing: 8) {
                Text("\(fixCount) fix\(fixCount == 1 ? "" : "es") · \(replyCount) repl\(replyCount == 1 ? "y" : "ies")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(fixCount) fix\(fixCount == 1 ? "" : "es") and \(replyCount) repl\(replyCount == 1 ? "y" : "ies") selected")
                Spacer()
                if fixCount > 0 {
                    if canAct {
                        Button(fixCount == 1 ? "Implement 1 Fix" : "Implement \(fixCount) Fixes") {
                            model.implementRespond(prID: prID)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(chat.isRunning || model.jobsBlockedReason != nil)
                        .help(model.jobsBlockedReason
                            ?? "Claude implements each fix and PRBar makes one commit per fix. Nothing is pushed yet.")
                    } else {
                        // After an error, fixes aren't re-implemented on top of whatever was left: the PR is analyzed again.
                        Button("Analyze Again", action: reanalyze)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(currentItem == nil || model.jobsBlockedReason != nil)
                            .help(model.jobsBlockedReason ?? "")
                    }
                } else {
                    Button(alreadyPosted > 0 ? "Retry Pending Replies" : replyCount == 1 ? "Post 1 Reply" : "Post \(replyCount) Replies") {
                        ConfirmAlert.present(
                            title: replyCount == 1 ? "Post 1 reply?" : "Post \(replyCount) replies?",
                            message: "They’ll be posted to \(draft.repo.name)#\(draft.number) as @\(draft.account). Nothing is pushed.",
                            action: "Post"
                        ) { model.publishRespondReplies(prID: prID) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(replyCount == 0 || chat.isRunning)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func selection(_ item: RespondItem) -> Binding<RespondSelection> {
        Binding(
            get: { chat.selections[item.id] ?? RespondSelection.defaults(for: item) },
            set: { chat.selections[item.id] = $0 }
        )
    }

    /// El PR tal como está en el último snapshot (para volver a analizarlo).
    private var currentItem: ClassifiedPR? {
        prStore.snapshot?.items.first { $0.id == prID }
    }

    private func reanalyze() {
        guard let item = currentItem else { return }
        model.startRespond(item)
    }

    // MARK: Etapa: implementando

    private func implementing(done: Int, total: Int) -> some View {
        let chosen = draft.items.filter { chat.selections[$0.id]?.implement == true }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(chosen.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            implementingStatus(index: index, done: done)
                                .frame(width: 18)
                            RespondItemHeader(feedback: item.feedback)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
                .cardBorder()
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 120)
                        .accessibilityLabel("Fixes implemented")
                    Text(isCI ? "Claude is fixing the CI…" : "Implementing \(min(done + 1, max(total, 1))) of \(max(total, 1))…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { queue.cancel(prID: prID) }
                        .keyboardShortcut(.cancelAction)
                        .help("Stops Claude. Commits already made stay unpushed in the worktree.")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    @ViewBuilder
    private func implementingStatus(index: Int, done: Int) -> some View {
        if index < done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityLabel("Done")
        } else if index == done {
            ProgressView().controlSize(.small).accessibilityLabel("In progress")
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary).accessibilityLabel("Pending")
        }
    }

    // MARK: Etapa: revisar y pushear

    private func review(_ result: RespondResult, error: String?) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error {
                        ErrorBanner(messages: [error]).padding(.horizontal, -10)
                    }
                    if queue.pushBlockedByTests.contains(prID), let run = result.tests, !run.passed {
                        TestsBlockedPushBanner(command: run.command) { confirmPushAnyway(run) }
                    }
                    if let blocked = queue.pushBlockedByCI[prID] {
                        CIPassingBanner(message: blocked) { confirmPushAnywayCI(blocked) }
                    }
                    if isCI {
                        CIChecksSection(draft: draft, result: result)
                    }
                    if !result.sensitiveChanges.isEmpty {
                        SensitiveChangesBanner(paths: result.sensitiveChanges)
                    }
                    if !model.configStore.config.claude.respond.allowNewDependencies,
                       let dependencies = result.dependencyChanges, !dependencies.isEmpty {
                        DependencyChangesBanner(paths: dependencies)
                    }
                    commitsSection(result)
                    if !isCI { repliesSection() }
                    diffSection(result)
                    // El diff completo va antes de "Correr tests" y del push: es lo que se ejecuta y se pushea.
                    fullDiffSection(result)
                    if let testCommand {
                        TestsSection(command: testCommand, run: result.tests, running: runningTests,
                                     disabled: queue.phases[prID] != .readyToPush(draft, result) || chat.isRunning
                                         || model.jobsBlockedReason != nil,
                                     start: { model.runRespondTests(prID: prID) },
                                     cancel: { queue.cancel(prID: prID) })
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { reviewFooter(result) }
        }
    }

    private func commitsSection(_ result: RespondResult) -> some View {
        let commits = RespondCounts.commits(result)
        return section("Commits (\(commits))") {
            ForEach(Array(result.items.enumerated()), id: \.element.id) { index, itemResult in
                if index > 0 { Divider() }
                CommitRow(result: itemResult, item: draft.items.first { $0.id == itemResult.id },
                          commitURL: record?.pushed == true ? commitURL(itemResult.commit) : nil)
            }
            if result.items.isEmpty {
                Text("No fixes were implemented.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
            if let commits = result.commits, !commits.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Messages of the commits to push").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(commits, id: \.sha) { commit in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(String(commit.sha.prefix(7))).foregroundStyle(.secondary)
                            Text(commit.message).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(.subheadline, design: .monospaced))
                        .textSelection(.enabled)
                    }
                }
                .padding(10)
            }
        }
    }

    /// I3: el diff completo (`startHeadOid..HEAD`), con scroll, monoespaciado y +/- en color.
    @ViewBuilder
    private func fullDiffSection(_ result: RespondResult) -> some View {
        if let diff = result.diff {
            section("Full diff") {
                VStack(alignment: .leading, spacing: 0) {
                    DiffTextView(diff: diff)
                        .frame(minHeight: 160, idealHeight: 360, maxHeight: 420)
                    if result.diffTruncated == true {
                        Divider()
                        Label(RespondCopy.diffTruncatedNote, systemImage: "scissors")
                            .font(.subheadline)
                            .foregroundStyle(Theme.orangeText)
                            .padding(10)
                    }
                }
            }
        } else {
            Text("This result doesn’t include the full diff: review it in the worktree before pushing.")
                .font(.subheadline)
                .foregroundStyle(Theme.orangeText)
        }
    }

    private func diffSection(_ result: RespondResult) -> some View {
        section("Changes") {
            let lines = result.diffStat.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            VStack(alignment: .leading, spacing: 1) {
                if result.diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No changes").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let sensitive = result.sensitiveChanges.contains { line.contains($0) }
                        Text(line)
                            .foregroundStyle(sensitive ? Theme.redText : .primary)
                            .fontWeight(sensitive ? .semibold : .regular)
                    }
                }
            }
            .font(.system(.subheadline, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func reviewFooter(_ result: RespondResult) -> some View {
        let commits = RespondCounts.commits(result)
        let pending = record.map(RespondCounts.pendingReplies) ?? 0
        let pushed = record?.pushed == true
        let title: String = if isCI {
            "Push"
        } else if pushed {
            "Retry Pending Replies"
        } else if commits == 0 {
            pending == 1 ? "Post 1 Reply" : "Post \(pending) Replies"
        } else {
            "Push and Reply"
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Pushing runs your hooks (pre-push) in PRBar’s worktree, on Claude’s code. " + RespondCopy.ownWorktreeNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: draft.worktree.path, isDirectory: true))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show Worktree in Finder (\(draft.worktree.path))")
                .accessibilityLabel("Show Worktree in Finder")
                Spacer()
                Button(title) { confirmPublish(commits: commits, pending: pending, pushed: pushed, result: result) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(runningTests || (pushed && pending == 0) || chat.isRunning || (isCI && commits == 0))
                    .help(chat.isRunning ? "Wait for Claude to finish"
                        : runningTests ? "Wait for the tests to finish"
                        : isCI ? (commits == 0 ? "Claude made no changes: nothing to push" : "Asks for confirmation, checks the CI again and pushes")
                        : "Asks for confirmation before pushing and posting")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// M1: Return cancela; pushear o publicar necesita un clic. Con "Run tests before pushing" el mensaje avisa que
    /// primero corren los tests; si ya fallaron, ofrece "Push Anyway".
    private func confirmPublish(commits: Int, pending: Int, pushed: Bool, result: RespondResult) {
        let onlyReplies = pushed || commits == 0
        if !onlyReplies, case .testsFailed(let run) = model.respondPushGate(prID: prID) {
            confirmPushAnyway(run)
            return
        }
        var message = onlyReplies
            ? "They’ll be posted as @\(draft.account)."
            : RespondCopy.pushConfirmation(account: draft.account, worktree: draft.worktree.path, headRef: draft.headRef,
                                           sha: result.headOid ?? "")
        if !onlyReplies, model.respondPushGate(prID: prID) == .runTests, let testCommand {
            message += "\n\nPRBar runs “\(testCommand)” first and pushes only if it passes."
        }
        if !onlyReplies, !model.configStore.config.claude.respond.allowNewDependencies,
           let dependencies = result.dependencyChanges, !dependencies.isEmpty {
            message += "\n\nClaude changed dependency manifests: \(dependencies.joined(separator: ", "))."
        }
        if isCI {
            message += "\n\nPRBar first checks on GitHub that the PR is still at the commit whose checks failed and that they still fail. No comment is posted."
        }
        ConfirmAlert.present(
            title: isCI ? "Push \(commits) commit\(commits == 1 ? "" : "s") to \(draft.headRef)?"
                        : pushQuestion(commits: commits, pending: pending, pushed: pushed),
            message: message,
            action: isCI ? "Push" : onlyReplies ? "Post" : "Push and Reply"
        ) { push(ignoringFailedTests: false) }
    }

    private func push(ignoringFailedTests: Bool) {
        do {
            if case .testsFailed(let run) = try model.pushRespond(prID: prID, ignoringFailedTests: ignoringFailedTests) {
                confirmPushAnyway(run)
            }
        } catch {
            InfoAlert.present(title: "Couldn’t push", message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func confirmPushAnyway(_ run: TestRun) {
        ConfirmAlert.present(
            title: "The tests failed",
            message: "“\(run.command)” failed in PRBar’s worktree, so PRBar didn’t push. Push the fixes and post the replies anyway?",
            action: "Push Anyway"
        ) { push(ignoringFailedTests: true) }
    }

    /// Fix CI's "Push Anyway": the checks that failed pass now (spec K.6.6).
    private func confirmPushAnywayCI(_ reason: String) {
        ConfirmAlert.present(
            title: "The CI passes now",
            message: reason + " Push Claude’s fix anyway?",
            action: "Push Anyway"
        ) { push(ignoringFailedTests: true) }
    }

    private func pushQuestion(commits: Int, pending: Int, pushed: Bool) -> String {
        let replies = pending == 1 ? "1 reply" : "\(pending) replies"
        if pushed { return "Post \(pending == 1 ? "1 pending reply" : "\(pending) pending replies")?" }
        if commits == 0 { return "Post \(replies)?" }
        return "Push \(commits) commit\(commits == 1 ? "" : "s") to \(draft.headRef) and post \(replies)?"
    }

    private func commitURL(_ sha: String?) -> URL? {
        guard let sha, !sha.isEmpty else { return nil }
        return URL(string: "https://github.com/\(draft.repo.owner)/\(draft.repo.name)/commit/\(sha)")
    }

    // MARK: Piezas

    /// The replies the push will post, as the window and the chat left them (highlighted when the chat changed them).
    @ViewBuilder
    private func repliesSection() -> some View {
        let items = draft.items.filter { chat.selections[$0.id]?.reply == true }
        if !items.isEmpty {
            section("Replies to post (\(items.count))") {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 4) {
                        RespondItemHeader(feedback: item.feedback)
                        Text(replyPreview(item))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(chat.highlighted.contains(item.id) ? Theme.tint(Theme.accent) : Color.clear)
                }
            }
        }
    }

    private func replyPreview(_ item: RespondItem) -> String {
        let text = chat.selections[item.id]?.replyText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Only “Fixed in <commit>”" : text
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
                .cardBorder()
        }
    }

    private func progress(_ text: String, cancellable: Bool) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).font(.title3).foregroundStyle(.secondary)
            if cancellable {
                Button("Cancel") { queue.cancel(prID: prID) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(icon: String, title: String, text: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 10) {
            MessageView(icon: icon, title: title, text: text)
            HStack(spacing: 8) {
                if let action {
                    Button(action.0, action: action.1)
                }
                Button("Close", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Encabezado: `repo#N` + "Abrir en GitHub", título, cuenta, rama y worktree.
private struct RespondHeader: View {
    let draft: RespondDraft
    /// Where the analysis ran (spec J): "on devbox" or "Ran on this Mac — devbox unreachable"; nil = this Mac.
    let placement: String?

    private var origin: String {
        switch draft.worktree.origin {
        case .mainClone: "main clone"
        case .existingWorktree: "existing worktree"
        case .created: "new worktree"
        case .dedicated: "PRBar worktree"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(repo: draft.repo, number: draft.number, url: draft.url, linkTitle: "Open on GitHub")
            Text(draft.title)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("@\(draft.account)").foregroundStyle(.primary)
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "arrow.triangle.branch").imageScale(.small).fontWeight(.semibold)
                Text(draft.headRef)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .truncationMode(.middle)
                if let placement {
                    Text("·").foregroundStyle(.tertiary)
                    PlacementLabel(text: placement)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: "folder").imageScale(.small).fontWeight(.semibold)
                Text("Worktree:")
                Text(draft.worktree.path)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(draft.worktree.path)
                Text("(\(origin))")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Banner rojo con los archivos que pueden ejecutar código. Va arriba de "Correr tests" y del push.
struct SensitiveChangesBanner: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Claude changed files that can run code (hooks, scripts, CI, dependencies). Review them before running tests or pushing.")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(paths, id: \.self) { path in
                    Text(path).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(.leading, 24)
        }
        .foregroundStyle(Theme.redText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.red)))
        .accessibilityElement(children: .combine)
    }
}

/// Spec E.5: Claude changed dependency manifests although "Allow new dependencies" is off. It warns, it doesn't block.
struct DependencyChangesBanner: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Claude changed dependencies, which your settings don’t allow (Settings › Claude › Fixes). Check them before pushing.")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "shippingbox.fill")
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(paths, id: \.self) { path in
                    Text(path).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(.leading, 24)
        }
        .foregroundStyle(Theme.orangeText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.orange)))
        .accessibilityElement(children: .combine)
    }
}

/// Spec E.5: the push stopped because the tests failed.
struct TestsBlockedPushBanner: View {
    let command: String
    let pushAnyway: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
            Text("“\(command)” failed, so PRBar didn’t push. Fix it with the chat or push anyway.")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Push Anyway…", action: pushAnyway)
                .controlSize(.small)
        }
        .foregroundStyle(Theme.redText)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.red)))
    }
}

/// Un fix: estado, sha corto (con link si ya se pusheó), resumen de Claude y a qué comentario responde.
struct CommitRow: View {
    let result: ItemResult
    let item: RespondItem?
    let commitURL: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            status.frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    sha
                    Text(result.summary.isEmpty ? "No summary" : result.summary)
                        .font(.callout)
                        .foregroundStyle(result.summary.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .help(result.summary)
                }
                if let item {
                    Text("\(item.feedback.reviewer) · \(RespondItemHeader.location(item.feedback))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var status: some View {
        switch result.status {
        case .committed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityLabel("Committed")
        case .noChanges:
            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("No changes")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.red).accessibilityLabel("Failed")
        }
    }

    @ViewBuilder
    private var sha: some View {
        switch result.status {
        case .committed:
            let short = String((result.commit ?? "").prefix(7))
            if let commitURL {
                Link(short, destination: commitURL)
                    .font(.system(.subheadline, design: .monospaced))
                    .pointingHandCursor()
                    .help(commitURL.absoluteString)
            } else {
                Text(short).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .noChanges:
            StatusPill(text: "No changes", color: .secondary, background: Color.primary.opacity(0.08))
        case .failed:
            StatusPill(text: "Failed", color: Theme.redText, background: Theme.tint(Theme.red))
        }
    }
}

/// "Correr tests": solo a pedido, después de ver el diff. Muestra el progreso y el resultado con la salida.
private struct TestsSection: View {
    let command: String
    let run: TestRun?
    let running: Bool
    let disabled: Bool
    let start: () -> Void
    let cancel: () -> Void
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tests").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(command)
                    Spacer()
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Running tests…").font(.subheadline).foregroundStyle(.secondary)
                        Button("Cancel", action: cancel)
                    } else {
                        Button(run == nil ? "Run Tests" : "Run Again", action: start)
                            .disabled(disabled)
                    }
                }
                Text("Runs the code Claude wrote in the worktree: do it after reviewing the diff.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let run, !running {
                    result(run)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
            .cardBorder()
        }
    }

    private func result(_ run: TestRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(run.passed ? "Tests passed" : "Tests failed",
                  systemImage: run.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(run.passed ? Theme.greenText : Theme.orangeText)
            if !run.passed {
                Text("This doesn’t block the push: it’s your call.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !run.outputTail.isEmpty {
                DisclosureGroup(isExpanded: $showOutput) {
                    ScrollView {
                        Text(run.outputTail)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color(nsColor: .textBackgroundColor)))
                } label: {
                    Text("Show output (last lines)").font(.subheadline)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button)
            .fill(Theme.tint(run.passed ? Theme.green : Theme.orange)))
    }
}

/// Estado final: lo que se pusheó y las respuestas publicadas, con sus links.
private struct RespondDoneView: View {
    let record: RespondRecord
    let close: () -> Void

    private var commits: Int { record.result.map(RespondCounts.commits) ?? 0 }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.green)
                .padding(.bottom, 6)
            Text(record.draft.isCIFix ? "CI Fix Pushed" : "Responded").font(.title.weight(.semibold))
            Text(summary).font(.callout).foregroundStyle(.secondary)
            RespondRepliesList(record: record)
                .frame(maxWidth: 520)
                .padding(.top, 8)
            HStack(spacing: 8) {
                ExternalLink("View on GitHub", destination: record.draft.url)
                    .padding(.trailing, 8)
                Button("Close", action: close)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        if record.draft.isCIFix {
            return "Pushed ✓ · \(commits) commit\(commits == 1 ? "" : "s") · the CI runs again on GitHub"
        }
        let replies = record.posted.count
        let posted = replies == 1 ? "1 reply posted" : "\(replies) replies posted"
        guard record.pushed, commits > 0 else { return posted }
        return "Pushed ✓ · \(commits) commit\(commits == 1 ? "" : "s") · \(posted)"
    }
}

/// Lista de las respuestas publicadas de un registro, cada una con su link.
struct RespondRepliesList: View {
    let record: RespondRecord

    var body: some View {
        let posted = record.draft.items.compactMap { item in record.posted[item.id].map { (item, $0) } }
        if !posted.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(posted.enumerated()), id: \.element.0.id) { index, pair in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Image(systemName: "arrowshape.turn.up.left.fill").font(.caption).foregroundStyle(.secondary)
                        Text("\(pair.0.feedback.reviewer) · \(RespondItemHeader.location(pair.0.feedback))")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        ExternalLink("View Reply", destination: pair.1.url)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .multilineTextAlignment(.leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
            .cardBorder()
        }
    }
}

/// El diff en un `NSTextView` de solo lectura (rápido con miles de líneas): monoespaciado, seleccionable, con las
/// líneas `+` en verde, las `-` en rojo y los encabezados (`diff --git`, `@@`) en gris.
struct DiffTextView: NSViewRepresentable {
    let diff: String

    final class Coordinator {
        var shown: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.isRichText = false
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 8, height: 8)
            // Sin cortar líneas: el scroll horizontal muestra el código como es.
            text.isHorizontallyResizable = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.setAccessibilityLabel("Full diff")
        }
        update(scroll, context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        update(scroll, context.coordinator)
    }

    /// Solo se vuelve a colorear si cambió el diff.
    private func update(_ scroll: NSScrollView, _ coordinator: Coordinator) {
        guard coordinator.shown != diff, let text = scroll.documentView as? NSTextView else { return }
        coordinator.shown = diff
        text.textStorage?.setAttributedString(Self.colored(diff))
    }

    static func colored(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let result = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let color: NSColor
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") || line.hasPrefix("index ") {
                color = .secondaryLabelColor
            } else if line.hasPrefix("@@") {
                color = .systemPurple
            } else if line.hasPrefix("+") {
                color = Theme.AppKitColors.greenText
            } else if line.hasPrefix("-") {
                color = Theme.AppKitColors.redText
            } else {
                color = .labelColor
            }
            result.append(NSAttributedString(string: String(line) + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        return result
    }
}

/// Fix CI (spec K): the checks that failed, what Claude saw of each and, after the fix, its summary.
struct CIChecksSection: View {
    let draft: RespondDraft
    let result: RespondResult?
    @State private var expanded: Set<String> = []

    private var item: RespondItem? { draft.items.first }
    private var summary: String? { result?.items.first?.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Failing checks on \(String(draft.startHeadOid.prefix(7)))").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array((draft.ci?.checks ?? []).enumerated()), id: \.element.id) { index, check in
                    if index > 0 { Divider() }
                    checkRow(check, comment: item?.feedback.comments.first { $0.author == check.name })
                }
                if let omitted = draft.ci?.omitted, !omitted.isEmpty {
                    Divider()
                    Text("Also failing (no output passed to Claude): \(omitted.joined(separator: ", "))")
                        .font(.subheadline).foregroundStyle(.secondary).padding(10)
                }
                if let summary, !summary.isEmpty {
                    Divider()
                    Label { Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "sparkles").foregroundStyle(Theme.violet)
                    }
                    .font(.callout)
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
            .cardBorder()
            Text("CI output is untrusted text: Claude treats it as information about the failure, never as instructions.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func checkRow(_ check: CICheckFailure, comment: FeedbackComment?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.redText).accessibilityHidden(true)
                Text(check.name).font(.callout.weight(.semibold))
                Text(check.conclusion.replacingOccurrences(of: "_", with: " ")).font(.subheadline).foregroundStyle(.secondary)
                if let app = check.appName { Text("· \(app)").font(.subheadline).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Text(check.hasLog ? "job log" : "summary only").font(.caption).foregroundStyle(.secondary)
                if let url = check.detailsURL, url.scheme == "https" {
                    ExternalLink("Details", destination: url).font(.subheadline)
                }
            }
            if let comment {
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(check.id) },
                                                    set: { if $0 { expanded.insert(check.id) } else { expanded.remove(check.id) } })) {
                    ScrollView {
                        Text(comment.body)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                } label: {
                    Text("What Claude saw").font(.subheadline)
                }
            }
        }
        .padding(10)
    }
}

/// Fix CI: PRBar didn't push because the checks that failed pass now (spec K.6.6).
private struct CIPassingBanner: View {
    let message: String
    let pushAnyway: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.orangeText)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Push Anyway…", action: pushAnyway)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Theme.tint(Theme.orange)))
    }
}
