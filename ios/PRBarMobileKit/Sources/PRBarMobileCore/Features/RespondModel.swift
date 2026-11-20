import Foundation
import Observation
import PRBarWire

/// `respond`, `respond:fixci`, `respond:diff` (design §respond): Claude answers review feedback or fixes CI on my PR,
/// then I look at the diff and push (Face ID).
@MainActor @Observable
public final class RespondModel {
    public enum Mode: String, Sendable { case feedback, ciFix }

    public enum StageState: Equatable, Sendable { case pending, current, done }

    public struct Stage: Identifiable, Equatable, Sendable {
        public var id: String { title }
        public var title: String
        public var state: StageState
        public var detail: String?
    }

    public let pr: String
    public let connection: RemoteConnection
    public private(set) var diffFiles: [DiffFile] = []
    public private(set) var diffTruncated = false
    public var selectedFile: String?
    public var alert: String?
    /// The Mac asked to confirm an undo ("Undo will also discard your manual edits since then.").
    public var undoConfirmation: String?
    public private(set) var needsRepair = false
    public private(set) var isBusy = false
    @ObservationIgnored private let runner: ActionRunner
    @ObservationIgnored private let fallbackMode: Mode
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var startedAt: Date?

    public init(pr: String, mode: Mode, connection: RemoteConnection, runner: ActionRunner,
                now: @escaping () -> Date = Date.init) {
        self.pr = pr
        self.fallbackMode = mode
        self.connection = connection
        self.runner = runner
        self.now = now
    }

    public var topic: String { Topic.pr(pr) }
    public func appear() async { await connection.retain(topic) }
    public func disappear() async { await connection.release(topic) }

    public var detail: RemotePRDetail? { connection.store.detail(for: pr) }
    public var info: PRInfo? { detail?.pr ?? connection.store.home?.prs.first { $0.id == pr } }
    public var respond: RespondInfo? { detail?.respond }
    public var extras: RespondExtras? { detail?.respondExtras }
    public var isOffline: Bool { connection.store.isStale }

    public var mode: Mode { extras?.mode.flatMap(Mode.init(rawValue:)) ?? fallbackMode }

    public var title: String { mode == .feedback ? "Respond" : "Fix CI" }

    public var phase: String? { respond?.phase }

    public var isRunning: Bool {
        guard let phase else { return false }
        return ["queued", "preparing", "analyzing", "implementing", "pushing"].contains(phase) || (respond?.runningTests ?? false)
    }

    public var isDone: Bool { phase == "readyToPush" || phase == "done" }

    // MARK: Header

    public func displayName(_ login: String) -> String { connection.store.home?.people?[login] ?? login }

    public enum HeaderTone: Sendable { case orange, red, green }

    public var headerStatus: (tone: HeaderTone, text: String) {
        if isDone, let files = diffStatFiles {
            let tests = respond?.tests.map { $0.passed ? "tests passing" : "tests failing" } ?? "tests passing"
            return (.green, "\(Format.count(files, "file")) · \(tests)")
        }
        if mode == .ciFix {
            let failed = extras?.ciChecks?.count ?? 0
            return (.red, Format.count(failed, "check") + " failed")
        }
        let reviewers = Array(Set(items.map(\.reviewer))).sorted().map(displayName)
        return (.orange, "Changes requested by " + (reviewers.isEmpty ? "a reviewer" : reviewers.joined(separator: ", ")))
    }

    var diffStatFiles: Int? {
        guard let stat = respond?.diffStat, let first = stat.split(separator: " ").first else { return nil }
        return Int(first)
    }

    // MARK: Feedback

    public var items: [RespondItemInfo] { respond?.items ?? [] }

    public var selectionSummary: String {
        "\(items.filter(\.implement).count) of \(items.count) selected"
    }

    public func toggle(_ item: RespondItemInfo) async {
        await perform(.app(.respondSelect(pr: pr, items: [item.id], change: RespondSelectionChange(implement: !item.implement))))
    }

    // MARK: Fix CI

    public var checks: [CICheck] { extras?.ciChecks ?? [] }

    public var checksSummary: String? {
        guard let failed = extras?.ciChecks?.count else { return nil }
        return extras?.totalChecks.map { "\(failed) of \($0)" } ?? "\(failed) failed"
    }

    // MARK: Progress

    public var progressTitle: String {
        if isDone { return "Fixed · tests passing" }
        let count = mode == .feedback ? Format.count(items.filter(\.implement).count, "comment")
                                      : Format.count(checks.count, "check")
        return "Claude is fixing \(count)"
    }

    public var elapsed: String? {
        guard let startedAt else { return nil }
        return Format.clock(now().timeIntervalSince(startedAt))
    }

    public var stages: [Stage] {
        let phase = phase ?? "queued"
        let testing = respond?.runningTests ?? false
        let order: [String] = ["Analyzing", "Implementing", "Running tests"]
        let currentIndex: Int
        switch phase {
        case "queued", "preparing", "analyzing", "ready": currentIndex = 0
        case "implementing": currentIndex = testing ? 2 : 1
        case "readyToPush", "pushing", "done": currentIndex = 3
        default: currentIndex = 0
        }
        return order.enumerated().map { index, title in
            let state: StageState = index < currentIndex ? .done : index == currentIndex ? .current : .pending
            var detail: String?
            if index == 1, state == .current { detail = extras?.currentFile.map { "Editing \($0)" } }
            if index == 2, state == .done || state == .current { detail = extras?.testSummary ?? respond?.tests?.outputTail }
            return Stage(title: title, state: state, detail: detail)
        }
    }

    // MARK: Actions

    public func start() async {
        startedAt = now()
        switch mode {
        case .feedback: await perform(.app(.respondStart(pr: pr, wait: false)))
        case .ciFix: await perform(.ciFix(pr: pr, wait: false))
        }
    }

    public func implement() async {
        startedAt = startedAt ?? now()
        await perform(.app(.respondImplement(pr: pr, wait: false)))
    }

    public func runTests() async {
        await perform(.app(.respondTest(pr: pr, wait: false)))
    }

    public func stop() async {
        await perform(.app(.respondCancel(pr: pr)))
    }

    public func loadDiff() async {
        do {
            let diff = try await runner.run(.respondDiff(pr: pr)).decoded(RespondDiff.self)
            diffFiles = UnifiedDiff.parse(diff.diff ?? "", sensitive: diff.sensitiveChanges)
            diffTruncated = diff.truncated
            selectedFile = selectedFile ?? diffFiles.first?.path
        } catch {
            handle(error)
        }
    }

    public var selectedDiff: DiffFile? { diffFiles.first { $0.path == selectedFile } ?? diffFiles.first }

    /// Nothing to implement: the replies go out without a push (no Face ID).
    public var isReplyOnly: Bool { mode == .feedback && !items.isEmpty && !items.contains(where: \.implement) }

    public var primaryTitle: String {
        if isReplyOnly { return "Reply" }
        if respond?.pushBlockedByTests == true { return "Push Anyway" }
        return mode == .feedback ? "Push & Reply" : "Push"
    }

    public var primaryNeedsFaceID: Bool { !isReplyOnly }

    public var canPush: Bool { !isRunning && isDone && !isOffline && !isBusy }

    /// The bottom bar's primary: Face ID, then `respondPush`/`respondPushAnyway` (or `respondReplyOnly` without).
    public func push() async {
        let command: AppCommand
        if isReplyOnly {
            command = .respondReplyOnly(pr: pr, confirmed: true, wait: false)
        } else if respond?.pushBlockedByTests == true {
            command = .respondPushAnyway(pr: pr, confirmed: true, wait: false)
        } else {
            command = .respondPush(pr: pr, confirmed: true, wait: false)
        }
        await perform(.app(command), reason: "Push \(pr)")
    }

    /// "Undo" when done: undoes Claude's last change through the chat (spec R.4).
    public func undo() async {
        do {
            try await runner.run(.chatUndo(pr: pr, confirmed: false))
        } catch .needsConfirmation(let question) {
            undoConfirmation = question
        } catch {
            handle(error)
        }
    }

    public func confirmUndo() async {
        undoConfirmation = nil
        await perform(.app(.chatUndo(pr: pr, confirmed: true)))
    }

    private func perform(_ command: RemoteCommand, reason: String? = nil) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await runner.run(command, reason: reason)
        } catch {
            handle(error)
        }
    }

    private func handle(_ error: ActionError) {
        switch error {
        case .presenceCancelled: break
        case .presenceKeyInvalid: needsRepair = true
        default: alert = error.message
        }
    }
}
