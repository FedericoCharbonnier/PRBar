import AppKit
import PRBarCore
import SwiftUI

/// La pestaña Respond o Fix CI del PR (spec M.1 "Respond / Fix CI"): sin tarea, qué hay para responder o qué falla y
/// Start; mientras Claude analiza, el progreso; con el análisis, `RespondRunView` (sigue el registro actual, así que un
/// análisis nuevo reemplaza al anterior sin preguntar: lo elegido vive en el coordinador de cada draft).
struct RespondPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: RespondQueue
    @ObservedObject var prStore: PRStore
    let prID: String
    let mode: RespondMode
    /// Lleva a la otra pestaña (Respond ↔ Fix CI) cuando la corrida abierta es del otro tipo.
    let showTab: (PRTab) -> Void

    init(model: AppModel, prID: String, mode: RespondMode, showTab: @escaping (PRTab) -> Void) {
        self.model = model
        queue = model.respond
        prStore = model.prStore
        self.prID = prID
        self.mode = mode
        self.showTab = showTab
    }

    private var hasRun: Bool { queue.records[prID] != nil || queue.phases[prID] != nil }

    var body: some View {
        if hasRun, queue.mode(of: prID) != mode {
            RespondOtherRunView(model: model, prID: prID, mode: mode, showTab: showTab)
        } else if let record = queue.records[prID] {
            RespondRunView(model: model, prID: prID, draft: record.draft, chat: model.respondChat(for: record.draft))
                .id(record.draft.id)
        } else if queue.phases[prID]?.isActive == true {
            RespondAnalyzingView(model: model, prID: prID, mode: mode)
        } else {
            RespondStartView(model: model, prID: prID, mode: mode)
        }
    }
}

/// La cabecera de la pestaña antes del análisis (sin draft): `repo#N`, título y estado.
private struct RespondItemHeaderView: View {
    let item: ClassifiedPR
    let mode: RespondMode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(repo: item.pr.repo, number: item.pr.number, url: item.pr.url, linkTitle: "Open on GitHub")
            Text(item.pr.title)
                .font(.system(size: 20, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(status, systemImage: mode == .ciFix ? "xmark.octagon.fill" : "bubble.left.and.exclamationmark.bubble.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(mode == .ciFix ? Theme.redText : Theme.orangeText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var status: String {
        if mode == .ciFix {
            return item.pr.ciState == .failure ? "Checks failed on \(item.pr.headRef)" : "The CI isn’t failing"
        }
        let feedback = ActionClassifier.newFeedback(item.pr, me: item.account)
        let comments = feedback.count == 1 ? "1 new comment" : "\(feedback.count) new comments"
        return feedback.changesRequested ? "Changes requested · \(comments)" : comments
    }
}

/// Sin tarea: qué hay para responder o qué checks fallan, y Start Respond / Start Fix CI.
private struct RespondStartView: View {
    @ObservedObject var model: AppModel
    let prID: String
    let mode: RespondMode

    var body: some View {
        if let item = model.currentItem(prID) {
            VStack(alignment: .leading, spacing: 0) {
                RespondItemHeaderView(item: item, mode: mode)
                Divider()
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: mode == .ciFix ? "wrench.and.screwdriver" : "arrowshape.turn.up.left.2")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(Theme.violet)
                        .accessibilityHidden(true)
                    Text(mode == .ciFix ? "Fix the CI with Claude" : "Respond with Claude").font(.title3.weight(.semibold))
                    Text(mode == .ciFix
                         ? "Claude reads the failing checks and their logs and fixes the code in PRBar’s worktree. You review the diff before pushing."
                         : "Claude reads the unresolved comments and proposes fixes and replies. You choose what to do before anything is pushed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    if mode == .ciFix {
                        HStack(spacing: 6) {
                            CIIcon(state: item.pr.ciState)
                            Text(CIIcon.label(for: item.pr.ciState) ?? "No CI")
                            Text("·").foregroundStyle(.tertiary)
                            Text(String(item.pr.headOid.prefix(7))).font(.system(.callout, design: .monospaced))
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    if case .failed(let message, let logURL)? = model.respond.phases[prID] {
                        VStack(spacing: 6) {
                            ErrorBanner(messages: [message])
                            if let logURL {
                                Button("Show Log") { NSWorkspace.shared.open(logURL) }
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: 520)
                    }
                    let reason = unavailableReason(item)
                    Button(mode == .ciFix ? "Start Fix CI" : "Start Respond") {
                        if mode == .ciFix { model.startCIFix(item) } else { model.startRespond(item) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(reason != nil)
                    .help(reason ?? (mode == .ciFix ? "Fix the failing checks with Claude" : "Respond to the comments with Claude"))
                    if let reason {
                        Text(reason).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        } else {
            MessageView(icon: "questionmark.folder", title: "This PR is no longer in your list",
                        text: "There’s nothing to respond to or fix.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unavailableReason(_ item: ClassifiedPR) -> String? {
        mode == .ciFix ? model.ciFixUnavailableReason(item)
                       : model.respondUnavailableReason(item) ?? model.respondSlotConflictReason(prID, starting: .feedback)
    }
}

/// Claude analiza (todavía no hay draft): la tarjeta de progreso y Stop.
private struct RespondAnalyzingView: View {
    @ObservedObject var model: AppModel
    let prID: String
    let mode: RespondMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = model.currentItem(prID) {
                RespondItemHeaderView(item: item, mode: mode)
            }
            RespondProgressCard(model: model, prID: prID, isCI: mode == .ciFix, draft: nil)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(Theme.violet)
                Text(mode == .ciFix ? "Reading the failing checks and preparing the worktree…" : "Claude is analyzing the comments…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button("Stop") {
                    ConfirmAlert.present(title: mode == .ciFix ? "Stop fixing the CI?" : "Stop this response?",
                                         message: "Claude stops and what it did so far is lost.", action: "Stop") {
                        model.cancelRespond(prID: prID)
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop Claude (⌘.)")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .windowBar()
        }
    }
}

/// La corrida abierta del PR es del otro tipo (un Respond y un Fix CI comparten el lugar; spec K.2.1).
private struct RespondOtherRunView: View {
    @ObservedObject var model: AppModel
    let prID: String
    let mode: RespondMode
    let showTab: (PRTab) -> Void

    var body: some View {
        VStack(spacing: 10) {
            MessageView(icon: "arrow.left.arrow.right",
                        title: mode == .ciFix ? "A Respond Run Is Open" : "A Fix CI Run Is Open",
                        text: model.respondSlotConflictReason(prID, starting: mode)
                            ?? "Finish or dismiss the other run first.")
            Button(mode == .ciFix ? "Go to Respond" : "Go to Fix CI") { showTab(mode == .ciFix ? .respond : .fixCI) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// La tarjeta de progreso (spec M.1): título, worktree, tiempo · costo y las tres etapas (Analyzing · Implementing ·
/// Running tests) con su estado, subtítulo y reloj.
struct RespondProgressCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: RespondQueue
    let prID: String
    let isCI: Bool
    /// nil mientras analiza (todavía no hay draft).
    let draft: RespondDraft?

    init(model: AppModel, prID: String, isCI: Bool, draft: RespondDraft?) {
        self.model = model
        queue = model.respond
        self.prID = prID
        self.isCI = isCI
        self.draft = draft
    }

    private var phase: RespondPhase? { queue.phases[prID] }
    private var running: Bool { phase?.isActive == true || queue.runningTests.contains(prID) }
    private var record: RespondRecord? { queue.records[prID] }

    var body: some View {
        TimelineView(.periodic(from: .now, by: running ? 1 : 3600)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let timeline = model.respondTimelines[prID] ?? RespondStageTimeline()
        let stages = timeline.stages(phase: phase, runningTests: queue.runningTests.contains(prID),
                                     testsRan: record?.result?.tests != nil)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.violet).accessibilityHidden(true)
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Text(timeAndCost(timeline, now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(UsageFormat.note)
            }
            if let draft {
                let path = draft.worktree.path
                Label("\((path as NSString).abbreviatingWithTildeInPath) (\(draft.worktreeOrigin))", systemImage: "folder")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(stages, id: \.kind) { stage in
                    stageView(stage, now: now)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.violet).opacity(0.6)))
        .cardBorder()
    }

    private var title: String {
        let state: String = switch phase {
        case .queued?: "Queued"
        case .preparing?, .analyzing?: "Analyzing"
        case .ready?: isCI ? "Ready to fix" : "Choose what to fix"
        case .implementing?: "Implementing"
        case .readyToPush? where queue.runningTests.contains(prID): "Running tests"
        case .readyToPush?: "Ready to push"
        case .pushing?: "Pushing"
        case .done?: "Pushed"
        case .failed?: "Stopped"
        case nil: ""
        }
        return "\(isCI ? "Fix CI" : "Respond") · \(state)"
    }

    /// "1:12 · $0.42": desde que empezó la primera etapa hasta ahora (o hasta que terminó la última).
    private func timeAndCost(_ timeline: RespondStageTimeline, now: Date) -> String {
        var parts: [String] = []
        if let start = timeline.starts.values.min() ?? queue.runs[prID]?.startedAt {
            let end = running ? now : (timeline.ends.values.max() ?? now)
            parts.append(ClaudeTasksSidebar.clock(end.timeIntervalSince(start)))
        }
        if let usage = record?.usage { parts.append(UsageFormat.cost(usage)) }
        return parts.joined(separator: " · ")
    }

    private func stageView(_ stage: RespondStage, now: Date) -> some View {
        HStack(alignment: .top, spacing: 6) {
            stageIcon(stage.status).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.kind.title)
                    .font(.subheadline.weight(stage.status == .running ? .semibold : .regular))
                    .foregroundStyle(stage.status == .pending ? .secondary : .primary)
                let detail = [subtitle(stage), stage.duration(now: now).map(ClaudeTasksSidebar.clock)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stageIcon(_ status: RespondStageStatus) -> some View {
        switch status {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityLabel("Pending")
        case .running: ProgressView().controlSize(.mini).tint(Theme.violet).accessibilityLabel("Running")
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.red).accessibilityLabel("Failed")
        }
    }

    private func subtitle(_ stage: RespondStage) -> String? {
        switch stage.kind {
        case .analyzing:
            guard let draft else { return nil }
            if isCI {
                let count = draft.ci?.checkNames.count ?? 0
                return count == 1 ? "1 check" : "\(count) checks"
            }
            return draft.items.count == 1 ? "1 comment" : "\(draft.items.count) comments"
        case .implementing:
            if case .implementing(let done, let total)? = phase {
                return isCI ? "Fixing" : "Fix \(min(done + 1, max(total, 1))) of \(max(total, 1))"
            }
            guard stage.status == .done, let result = record?.result else { return nil }
            let commits = RespondCounts.commits(result)
            return commits == 1 ? "1 commit" : "\(commits) commits"
        case .testing:
            if queue.runningTests.contains(prID) { return draft.flatMap(model.testCommand(for:)) }
            if let tests = record?.result?.tests { return tests.passed ? "Passed" : "Failed" }
            return draft.flatMap(model.testCommand(for:)) ?? "No test command"
        }
    }
}

/// El Respond o el Fix CI de un PR en la ventana principal (spec §14): elegir qué arreglar y qué responder, ver los
/// fixes de Claude (diff, archivos sensibles, tests a pedido) y pushear + responder. Sigue en vivo la fase del PR en
/// `RespondQueue`.
///
/// Seguridad: nada que escribió Claude se ejecuta antes de que el usuario vea el diff **completo** (y los commits
/// con sus mensajes): la pestaña abre en Diff, y los tests corren solo con "Run Tests" (en Tests). El push (con los
/// hooks del usuario, en el worktree de PRBar) y las respuestas, solo después de confirmar, y Return en la
/// confirmación cancela (`ConfirmAlert`).
struct RespondRunView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var queue: RespondQueue
    @ObservedObject var prStore: PRStore
    let prID: String
    /// El análisis que se muestra: `RespondPane` sigue el registro actual y re-crea la vista con `.id(draft.id)`.
    let draft: RespondDraft
    /// nil: sin botón Close (la pestaña no se cierra).
    let close: (() -> Void)?
    /// The decisions (shared with the chat, which can draft replies and choose fixes).
    @ObservedObject var chat: ChatCoordinator

    @FocusState private var focus: RespondFocus?
    @State private var output = RespondOutput.diff
    /// El chip de archivo elegido en Diff (nil = todos).
    @State private var diffFile: String?
    /// The chosen file's part of the diff, kept between renders.
    @State private var diffSections = DiffSectionMemo()

    init(model: AppModel, prID: String, draft: RespondDraft, chat: ChatCoordinator, close: (() -> Void)? = nil) {
        self.model = model
        queue = model.respond
        prStore = model.prStore
        self.prID = prID
        self.draft = draft
        self.close = close
        // Lo que ya se eligió (p. ej. se canceló la implementación o falló la publicación) o, si no, lo que propuso
        // Claude: `AppModel.respondChat` arma las decisiones del coordinador.
        self.chat = chat
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
            RespondHeader(draft: draft, status: RespondStatusLine.of(draft),
                          placement: draft.runner.map { "on \($0)" } ?? model.placements.label(prID: draft.prID))
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
            if showsProgressCard {
                RespondProgressCard(model: model, prID: prID, isCI: isCI, draft: draft)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: chatLock, initial: true) { _, reason in chat.setLock(reason) }
        .onChange(of: isFinished, initial: true) { _, finished in if finished { chat.markReadOnly() } }
    }

    /// La tarjeta de progreso, mientras hay una corrida que seguir (no en el final ni si ya no hay nada).
    private var showsProgressCard: Bool {
        switch stage {
        case .done, .superseded, .gone: false
        default: true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .choosing(let error, let canAct):
            if isCI { ciChoosing(error: error, canAct: canAct) } else { choosing(error: error, canAct: canAct) }
        case .waiting(let text):
            VStack(spacing: 0) {
                progress(text)
                bottomBar(running: true, help: nil) { EmptyView() }
            }
        case .implementing(let done, let total):
            implementing(done: done, total: total)
        case .review(let result, let error):
            review(result, error: error)
        case .pushing:
            progress(isCI ? "Checking the CI again and pushing to \(draft.headRef)…" : "Pushing to \(draft.headRef) and posting the replies…")
        case .done(let record):
            RespondDoneView(record: record, close: close)
        case .superseded:
            // No debería verse: `RespondPane` sigue el registro actual.
            message(icon: "arrow.triangle.2.circlepath", title: "There’s a Newer Analysis of This PR",
                    text: "This is the previous one.", action: nil)
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
            bottomBar(running: false,
                      help: "Claude reads the CI output above and fixes the code in PRBar’s worktree. Nothing is pushed until you push.") {
                // After a failure: read the checks again (they may have changed) and fix from scratch.
                Button(canAct ? "Fix CI" : "Fix CI Again") {
                    if canAct {
                        queue.implementCI(prID: prID)
                    } else if let item = currentItem {
                        model.discardAndRestartRespond(item, mode: .ciFix)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled((!canAct && currentItem.map { model.ciFixUnavailableReason($0, ignoringUnpushed: true) } != .some(nil))
                          || chat.isRunning
                          || model.jobsBlockedReason != nil)
                .help(model.jobsBlockedReason ?? "Claude fixes the code; you review the diff before pushing")
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
            choosingFooter(error: error, canAct: canAct)
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
                leadingControls(running: false)
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
        .windowBar()
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
        model.discardAndRestartRespond(item, mode: .feedback)
    }

    // MARK: Etapa: implementando

    private func implementing(done: Int, total: Int) -> some View {
        let chosen = draft.items.filter { chat.selections[$0.id]?.implement == true }
        let fix = min(done + 1, max(total, 1))
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isCI {
                        CIChecksSection(draft: draft, result: nil)
                    } else if !chosen.isEmpty {
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
                    }
                    // No hay diff en vivo (plan 21, decisión 7): el progreso de Claude en su lugar.
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(Theme.violet)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude is editing…").font(.callout.weight(.semibold))
                            Text(isCI ? "Fixing the failing checks in PRBar’s worktree" : "Fix \(fix) of \(max(total, 1))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.violet)))
                    .accessibilityElement(children: .combine)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            bottomBar(running: true, help: "Stop keeps the commits already made, unpushed, in the worktree.") {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                    .accessibilityLabel("Fixes implemented")
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
                        CIChecksSection(draft: draft, result: result, localTests: result.tests)
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
                    // Diff · Tests · Log. Abre en Diff: el diff completo se ve antes de correr los tests o pushear.
                    outputSection(result)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            reviewFooter(result)
        }
    }

    // MARK: Diff · Tests · Log

    private func outputSection(_ result: RespondResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Show", selection: $output) {
                ForEach(RespondOutput.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch output {
            case .diff:
                fileChips(result)
                fullDiffSection(result)
            case .tests:
                if let testCommand {
                    TestsSection(command: testCommand, run: result.tests, running: runningTests,
                                 disabled: queue.phases[prID] != .readyToPush(draft, result) || chat.isRunning
                                     || model.jobsBlockedReason != nil,
                                 start: { model.runRespondTests(prID: prID) },
                                 cancel: { queue.cancel(prID: prID) })
                } else {
                    Text("This repo has no test command. Set one in Settings › Repos to run its tests here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .log:
                RespondLogView(url: model.respondHistory.logURL(for: draft.id))
            }
        }
    }

    /// Un chip por archivo cambiado (del diffstat); clic muestra solo ese archivo en el diff. Los que pueden ejecutar
    /// código, en rojo.
    @ViewBuilder
    private func fileChips(_ result: RespondResult) -> some View {
        let files = DiffFiles.files(stat: result.diffStat)
        if files.isEmpty {
            Text("No changes").font(.callout).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All files (\(files.count))", selected: diffFile == nil, sensitive: false) { diffFile = nil }
                    ForEach(files, id: \.self) { file in
                        chip((file as NSString).lastPathComponent, selected: diffFile == file,
                             sensitive: result.sensitiveChanges.contains(file)) { diffFile = diffFile == file ? nil : file }
                            .help(file)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, sensitive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(selected ? Color.white : sensitive ? Theme.redText : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.accent : sensitive ? Theme.tint(Theme.red) : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    /// I3: el diff completo (`startHeadOid..HEAD`), con scroll, monoespaciado y +/- en color; con un chip elegido, solo
    /// ese archivo.
    @ViewBuilder
    private func fullDiffSection(_ result: RespondResult) -> some View {
        if let diff = result.diff {
            let shown = diffFile.map { diffSections.section(of: diff, file: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? diff
            VStack(alignment: .leading, spacing: 0) {
                DiffTextView(diff: shown)
                    .frame(minHeight: 160, idealHeight: 360, maxHeight: 420)
                if result.diffTruncated == true {
                    Divider()
                    Label(RespondCopy.diffTruncatedNote, systemImage: "scissors")
                        .font(.subheadline)
                        .foregroundStyle(Theme.orangeText)
                        .padding(10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
            .cardBorder()
        } else {
            Text("This result doesn’t include the full diff: review it in the worktree before pushing.")
                .font(.subheadline)
                .foregroundStyle(Theme.orangeText)
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
            "Push & Reply"
        }
        return bottomBar(running: runningTests, help: pushHelp(result, pushed: pushed)) {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: draft.worktree.path, isDirectory: true))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show Worktree in Finder (\(draft.worktree.path))")
            .accessibilityLabel("Show Worktree in Finder")
            Button(title) { confirmPublish(commits: commits, pending: pending, pushed: pushed, result: result) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(runningTests || (pushed && pending == 0) || chat.isRunning || (isCI && commits == 0))
                .help(chat.isRunning ? "Wait for Claude to finish"
                    : runningTests ? "Wait for the tests to finish"
                    : isCI ? (commits == 0 ? "Claude made no changes: nothing to push" : "Asks for confirmation, checks the CI again and pushes (⌘↩)")
                    : "Asks for confirmation before pushing and posting (⌘↩)")
        }
    }

    /// El texto de ayuda de la barra según `respondPushGate` (spec M.1; plan 21, decisión 7).
    private func pushHelp(_ result: RespondResult, pushed: Bool) -> String {
        if pushed { return "Pushed. Only the pending replies are left." }
        if runningTests { return "Running the tests…" }
        switch model.respondPushGate(prID: prID) {
        case .runTests: return "Tests run before pushing"
        case .testsFailed: return "Tests failed"
        case .ready:
            if let tests = result.tests { return tests.passed ? "Tests passed" : "Tests failed" }
            return "Pushing runs your pre-push hooks in PRBar’s worktree"
        }
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

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(Theme.violet)
            Text(text).font(.title3).foregroundStyle(.secondary)
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
                if let close {
                    Button("Close", action: close)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Barra inferior

    /// La barra de abajo (spec M.1): Undo, Stop ⌘. (corriendo) o Discard, el texto de ayuda y la acción de la etapa.
    private func bottomBar<Primary: View>(running: Bool, help: String?, @ViewBuilder primary: () -> Primary) -> some View {
        HStack(spacing: 8) {
            leadingControls(running: running)
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(help == pushHooksNote ? RespondCopy.ownWorktreeNote : help)
            }
            Spacer(minLength: 8)
            primary()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .windowBar()
    }

    private var pushHooksNote: String { "Pushing runs your pre-push hooks in PRBar’s worktree" }

    @ViewBuilder
    private func leadingControls(running: Bool) -> some View {
        Button { ChatUndo.perform(chat) } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
        }
        .disabled(running || chat.session.undoableMessageID == nil || !chat.canUndo)
        .help("Undo Claude’s last change from the chat")
        if running {
            Button("Stop") { confirmStop() }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop Claude (⌘.)")
        } else {
            Button("Discard") { model.confirmDismissRespond(prID: prID) }
                .disabled(queue.phases[prID]?.isActive == true)
                .help(isCI ? "Discard this CI fix and its worktree" : "Discard this analysis and its worktree")
        }
    }

    /// Pregunta como la pastilla (`CancellablePill`) antes de parar a Claude.
    private func confirmStop() {
        ConfirmAlert.present(
            title: isCI ? "Stop fixing the CI?" : "Stop this response?",
            message: "Claude stops. Commits already made stay unpushed in PRBar’s worktree.",
            action: "Stop"
        ) { model.cancelRespond(prID: prID) }
    }
}

/// Qué muestra la sección de abajo del resultado.
enum RespondOutput: CaseIterable {
    case diff, tests, log

    var title: String {
        switch self {
        case .diff: "Diff"
        case .tests: "Tests"
        case .log: "Log"
        }
    }
}

/// Las últimas 400 líneas del log de Claude de la corrida, y "Open Log".
private struct RespondLogView: View {
    let url: URL
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text, !text.isEmpty {
                DiffTextView(diff: text, colored: false)
                    .frame(minHeight: 160, idealHeight: 360, maxHeight: 420)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color(nsColor: .controlBackgroundColor)))
                    .cardBorder()
            } else {
                Text(text == nil ? "Loading the log…" : "There’s no log of this run yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Last 400 lines").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Log") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
        }
        .task(id: url) {
            let url = url
            let loaded = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)).map { DiffFiles.tail($0, lines: 400) } }.value
            text = loaded ?? ""
        }
    }
}

extension RespondDraft {
    /// De dónde salió el worktree: "PRBar worktree", "main clone"…
    var worktreeOrigin: String {
        switch worktree.origin {
        case .mainClone: "main clone"
        case .existingWorktree: "existing worktree"
        case .created: "new worktree"
        case .dedicated: "PRBar worktree"
        }
    }
}

/// "Changes requested by ana, luis" / "3 checks failed": la línea de estado de la cabecera.
enum RespondStatusLine {
    static func of(_ draft: RespondDraft) -> String {
        if draft.isCIFix {
            let count = draft.ci?.checkNames.count ?? 0
            return count == 1 ? "1 check failed" : "\(count) checks failed"
        }
        var reviewers: [String] = []
        for item in draft.items where !reviewers.contains(item.feedback.reviewer) { reviewers.append(item.feedback.reviewer) }
        return reviewers.isEmpty ? "No unresolved comments" : "Changes requested by \(reviewers.joined(separator: ", "))"
    }
}

/// Encabezado: `repo#N` + "Abrir en GitHub", título, cuenta, rama y worktree.
private struct RespondHeader: View {
    let draft: RespondDraft
    /// "Changes requested by ana" / "2 checks failed".
    let status: String
    /// Where the analysis ran (spec J): "on devbox" or "Ran on this Mac — devbox unreachable"; nil = this Mac.
    let placement: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PRReferenceLine(repo: draft.repo, number: draft.number, url: draft.url, linkTitle: "Open on GitHub")
            Text(draft.title)
                .font(.system(size: 20, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(status, systemImage: draft.isCIFix ? "xmark.octagon.fill" : "bubble.left.and.exclamationmark.bubble.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(draft.isCIFix ? Theme.redText : Theme.orangeText)
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
            // El worktree va en la tarjeta de progreso.
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
    let close: (() -> Void)?

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
                if let close {
                    Button("Close", action: close)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
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
    /// false: texto plano (el log de Claude), sin los colores del diff.
    var colored = true

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
        text.textStorage?.setAttributedString(colored ? Self.colored(diff) : Self.plain(diff))
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    static func colored(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let result = NSMutableAttributedString()
        for line in TextLines.split(diff, strippingCarriageReturns: true) {
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
    /// Los tests del repo que corrieron en el worktree después del fix: "falla en GitHub → pasa local" (no hay resultado
    /// local por check; plan 21, decisión 7).
    var localTests: TestRun? = nil
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
                    Text("Also failing (no output passed to Claude): \(CILogs.nameList(omitted))")
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
                // Names come from the CI (untrusted): one line, without bidi or format characters that could spoof the list.
                Text(CILogs.displayName(check.name)).font(.callout.weight(.semibold))
                Text(CILogs.displayName(check.conclusion.replacingOccurrences(of: "_", with: " "))).font(.subheadline).foregroundStyle(.secondary)
                if let app = check.appName { Text("· \(CILogs.displayName(app))").font(.subheadline).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Text(check.hasLog ? "job log" : "summary only").font(.caption).foregroundStyle(.secondary)
                localResult
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

extension CIChecksSection {
    /// "Fails on GitHub" y, si corrieron los tests del repo, "→ passes locally" / "→ fails locally".
    @ViewBuilder
    var localResult: some View {
        HStack(spacing: 4) {
            Text("Fails on GitHub").foregroundStyle(Theme.redText)
            if let localTests {
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(localTests.passed ? "passes locally" : "fails locally")
                    .foregroundStyle(localTests.passed ? Theme.greenText : Theme.redText)
            }
        }
        .font(.caption.weight(.medium))
        .help(localTests == nil ? "The repo’s tests haven’t run in the worktree"
                                : "The repo’s tests (“\(localTests?.command ?? "")”) in PRBar’s worktree, after the fix")
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
