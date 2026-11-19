import Foundation

/// What a chat turn needs to prepare its workspace.
public struct ChatWorkspaceRequest: Sendable {
    public var session: ChatSession
    public var subject: ChatSubject
    /// The PR as the last refresh saw it (Review: its base branch, for the diff; both: `pr.md`). Nil if it's gone.
    public var pr: PullRequest?
    /// Review: the user's clone (nil = diff-only mode, as in spec §8.2).
    public var localPath: String?
    /// Respond: the fixes' result, for `fixes.diff`.
    public var respondResult: RespondResult?

    public init(session: ChatSession, subject: ChatSubject, pr: PullRequest?, localPath: String?,
                respondResult: RespondResult? = nil) {
        self.session = session
        self.subject = subject
        self.pr = pr
        self.localPath = localPath
        self.respondResult = respondResult
    }
}

/// Where a chat turn runs and what PRBar prepared for it.
public struct ChatWorkspace: Equatable, Sendable {
    /// Claude's cwd.
    public var directory: URL
    /// The context folder (`--add-dir`, read only).
    public var contextDirectory: URL
    public var files: ChatContextFiles
    /// Review: the files of the PR's diff (`addFinding` only accepts these).
    public var diffFiles: Set<String>
    public var isDiffOnly: Bool
    /// Review: PRBar's refs of the worktree, deleted with it.
    public var refs: [String]
    /// Shown once in the conversation (for example, the reviewed commit isn't available).
    public var note: String?

    public init(directory: URL, contextDirectory: URL, files: ChatContextFiles, diffFiles: Set<String>, isDiffOnly: Bool,
                refs: [String], note: String?) {
        self.directory = directory
        self.contextDirectory = contextDirectory
        self.files = files
        self.diffFiles = diffFiles
        self.isDiffOnly = isDiffOnly
        self.refs = refs
        self.note = note
    }
}

/// The chat's side effects: workspace, Claude, the respond worktree's guard and cleanup. `ChatService` is the real
/// one; `ChatCoordinator` only talks to this.
public protocol ChatBackend: Sendable {
    func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace
    /// A turn without file edits (Review, or Respond before implementing).
    func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
              onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput
    /// A Respond turn that may edit the worktree (`FixImplementer.chatTurn`).
    func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome)
    func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult
    func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool
    /// Review: deletes the chat's worktree and its refs. Respond: the context folder and the snapshot refs. Never throws.
    func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async
}

public struct ChatService: ChatBackend {
    public static let olderCommitNote = "Claude sees the PR’s latest commit, not the reviewed one."

    private let processRunner: ProcessRunning
    private let streamingRunner: StreamingProcessRunning
    private let tokens: TokenProviding
    private let api: GitHubAPI
    private let gitPath: String
    private let ghPath: String?
    private let claudePath: String
    private let settings: ClaudeSettings
    private let worktreeRoot: URL
    private let pluginCacheDirectory: URL
    private let gitEnvironment: [String: String]

    public init(processRunner: ProcessRunning, streamingRunner: StreamingProcessRunning, tokens: TokenProviding, api: GitHubAPI,
                gitPath: String, ghPath: String?, claudePath: String, settings: ClaudeSettings = ClaudeSettings(),
                worktreeRoot: URL = AppPaths.worktreesDir, pluginCacheDirectory: URL = ClaudePlugins.defaultCacheDirectory,
                gitEnvironment: [String: String] = [:]) {
        self.processRunner = processRunner
        self.streamingRunner = streamingRunner
        self.tokens = tokens
        self.api = api
        self.gitPath = gitPath
        self.ghPath = ghPath
        self.claudePath = claudePath
        self.settings = settings
        self.worktreeRoot = worktreeRoot
        self.pluginCacheDirectory = pluginCacheDirectory
        self.gitEnvironment = gitEnvironment
    }

    // MARK: Workspace

    public func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        switch request.subject {
        case .review(let draft): return try await reviewWorkspace(draft, request)
        case .respond(let draft): return try respondWorkspace(draft, request)
        }
    }

    /// Spec B.5: the review's worktree was deleted after the analysis; the chat makes its own on the first turn, on
    /// the reviewed commit, at a path fixed per session (so `--resume` finds the conversation).
    private func reviewWorkspace(_ draft: ReviewDraft, _ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        if let path = request.session.worktreePath,
           let existing = Self.existingReviewWorkspace(path: path, refs: request.session.worktreeRefs) {
            return existing
        }
        guard let pr = request.pr else {
            throw PRBarError.respond("This PR is no longer in the list: the chat can’t prepare its code.")
        }
        let token = try await tokens.token(for: draft.account)
        let description = try await ReviewPipeline.description(of: pr, api: api, token: token)
        let manager = WorktreeManager(runner: processRunner, gitPath: gitPath, root: worktreeRoot)
        let name = WorktreeManager.chatWorkspaceName(repo: draft.repo, number: draft.number, sessionID: request.session.id)
        let workspace = try await manager.prepare(repo: pr.repo, number: pr.number, baseRef: pr.baseRef,
                                                  localPath: request.localPath, name: name, pinnedHeadOid: draft.headOid)
        let headOid: String
        do {
            headOid = try await ReviewContextWriter(runner: processRunner, gitPath: gitPath, ghPath: ghPath)
                .write(pr: pr, workspace: workspace, token: token, description: description ?? "")
        } catch {
            let localPath = request.localPath
            await Task.detached { await manager.cleanup(workspace, localPath: localPath) }.value
            throw error
        }
        var result = Self.chatWorkspace(workspace)
        if headOid != draft.headOid { result.note = Self.olderCommitNote }
        return result
    }

    static func chatWorkspace(_ workspace: ReviewWorkspace) -> ChatWorkspace {
        let diff = (try? String(contentsOf: workspace.diffFile, encoding: .utf8)) ?? ""
        return ChatWorkspace(
            directory: workspace.directory, contextDirectory: workspace.contextDirectory,
            files: ChatContextFiles(diff: workspace.diffFile, metadata: workspace.metadataFile),
            diffFiles: ChatActions.files(inDiff: diff), isDiffOnly: workspace.isDiffOnly,
            refs: [workspace.prRef, workspace.baseRef].compactMap { $0 }, note: nil)
    }

    static func reviewWorkspace(path: String, refs: [String]) -> ReviewWorkspace {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        return ReviewWorkspace(directory: directory, baseRef: refs.first { $0.contains("/base-") },
                               prRef: refs.first { $0.contains("/pr-") },
                               isDiffOnly: directory.lastPathComponent.hasSuffix("-diff"))
    }

    /// The worktree of an earlier turn, if it's still there with its `pr.diff` (the startup cleanup deletes it).
    static func existingReviewWorkspace(path: String, refs: [String]) -> ChatWorkspace? {
        let workspace = reviewWorkspace(path: path, refs: refs)
        guard FileManager.default.fileExists(atPath: workspace.directory.path),
              FileManager.default.fileExists(atPath: workspace.diffFile.path) else { return nil }
        return chatWorkspace(workspace)
    }

    /// `<owner>-<repo>-<N>-<session UUID>.respond-context`: the same pattern as the analysis', so the startup
    /// cleanup deletes it.
    static func respondContextName(_ draft: RespondDraft, sessionID: UUID) -> String {
        "\(draft.repo.owner)-\(draft.repo.name)-\(draft.number)-\(sessionID.uuidString).respond-context"
    }

    /// Respond: Claude works in the respond's worktree. The context is written again on each turn.
    private func respondWorkspace(_ draft: RespondDraft, _ request: ChatWorkspaceRequest) throws -> ChatWorkspace {
        let files = FileManager.default
        let context = worktreeRoot.appendingPathComponent(Self.respondContextName(draft, sessionID: request.session.id), isDirectory: true)
        try files.createDirectory(at: context, withIntermediateDirectories: true)
        let feedback = context.appendingPathComponent("feedback.json")
        try RespondAnalyzer.encodeFeedback(draft.items.map(\.feedback)).write(to: feedback)
        var paths = ChatContextFiles(feedback: feedback)
        let metadata = context.appendingPathComponent("pr.md")
        if let pr = request.pr {
            try Data(ReviewContextWriter.metadata(pr, headOid: draft.startHeadOid, description: "").utf8).write(to: metadata)
            paths.metadata = metadata
        } else {
            try? files.removeItem(at: metadata)
        }
        let fixes = context.appendingPathComponent("fixes.diff")
        if let diff = request.respondResult?.diff {
            try Data(diff.utf8).write(to: fixes)
            paths.fixesDiff = fixes
        } else {
            try? files.removeItem(at: fixes)
        }
        return ChatWorkspace(directory: URL(fileURLWithPath: draft.worktree.path, isDirectory: true), contextDirectory: context,
                             files: paths, diffFiles: [], isDiffOnly: false, refs: [], note: nil)
    }

    // MARK: Turnos

    public func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        try await ChatEngine(claude: try await claude(for: subject, logURL: logURL)).send(input, onEvent: onEvent)
    }

    public func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                            onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome) {
        let claude = try await claude(for: .respond(draft), logURL: logURL)
        let engine = ChatEngine(claude: claude)
        let implementer = FixImplementer(claude: claude, runner: processRunner, gitPath: gitPath, environment: gitEnvironment)
        return try await implementer.chatTurn(draft: draft, current: result, sessionID: sessionID, turn: input.turn) {
            try await engine.send(input, onEvent: onEvent)
        }
    }

    public func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult {
        try await implementer(logURL: logURL).undoChatTurn(draft: draft, snapshot: snapshot)
    }

    public func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool {
        await implementer(logURL: URL(fileURLWithPath: "/dev/null")).chatFilesChangedSince(snapshot, draft: draft)
    }

    /// The same plugins as the review or the respond of that PR, the chat's model and the account's token only to
    /// redact it (Claude never gets it).
    private func claude(for subject: ChatSubject, logURL: URL) async throws -> ClaudeRunner {
        let account: String
        let skills: [String]
        switch subject {
        case .review(let draft):
            account = draft.account
            skills = settings.reviewSkills
        case .respond(let draft):
            account = draft.account
            skills = settings.respondSkills
        }
        let token = try await tokens.token(for: account)
        let pluginDirs = try ClaudePlugins.locate(skills: skills, in: pluginCacheDirectory)
        return ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs,
                            environment: ClaudeRunner.environment(toolPaths: [gitPath, claudePath] + (ghPath.map { [$0] } ?? [])),
                            logURL: logURL, redacting: [token], model: settings.effectiveChatModel)
    }

    /// Git only (undo, checks): the runner is only used to write the log.
    private func implementer(logURL: URL) -> FixImplementer {
        FixImplementer(claude: ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: [], environment: [:],
                                            logURL: logURL, redacting: []),
                       runner: processRunner, gitPath: gitPath, environment: gitEnvironment)
    }

    // MARK: Limpieza

    public func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async {
        switch subject {
        case .review:
            guard let path = session.worktreePath else { return }
            let workspace = Self.reviewWorkspace(path: path, refs: session.worktreeRefs)
            await WorktreeManager(runner: processRunner, gitPath: gitPath, root: worktreeRoot).cleanup(workspace, localPath: localPath)
        case .respond(let draft):
            try? FileManager.default.removeItem(
                at: worktreeRoot.appendingPathComponent(Self.respondContextName(draft, sessionID: session.id), isDirectory: true))
            // The turns' snapshot refs live in the clone's common dir (the worktree may be gone already).
            let repo = draft.worktree.localPath ?? draft.worktree.path
            let pattern = "refs/prbar/chat-\(session.id.uuidString.lowercased())-*"
            let environment = GitHardening.environment.merging(gitEnvironment) { _, extra in extra }
            guard let list = try? await processRunner.run(
                gitPath, ["-C", repo] + GitHardening.arguments + ["for-each-ref", "--format=%(refname)", pattern],
                environment: environment, currentDirectory: nil, timeout: ProcessTimeouts.standard), list.status == 0 else { return }
            for ref in list.stdout.split(whereSeparator: \.isNewline) {
                _ = try? await processRunner.run(gitPath, ["-C", repo] + GitHardening.arguments + ["update-ref", "-d", String(ref)],
                                                 environment: environment, currentDirectory: nil, timeout: ProcessTimeouts.standard)
            }
        }
    }
}
