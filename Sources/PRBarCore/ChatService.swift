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
    /// Merge: what the window shows, for its `pr.md` (spec G.4).
    public var mergeDetail: MergeDetail?

    public init(session: ChatSession, subject: ChatSubject, pr: PullRequest?, localPath: String?,
                respondResult: RespondResult? = nil, mergeDetail: MergeDetail? = nil) {
        self.session = session
        self.subject = subject
        self.pr = pr
        self.localPath = localPath
        self.respondResult = respondResult
        self.mergeDetail = mergeDetail
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
    /// The host where it is (`RunnerDestination.name`); nil = this Mac. The session keeps it (`ChatSession.runner`).
    public var runner: String?

    public init(directory: URL, contextDirectory: URL, files: ChatContextFiles, diffFiles: Set<String>, isDiffOnly: Bool,
                refs: [String], note: String?, runner: String? = nil) {
        self.directory = directory
        self.contextDirectory = contextDirectory
        self.files = files
        self.diffFiles = diffFiles
        self.isDiffOnly = isDiffOnly
        self.refs = refs
        self.note = note
        self.runner = runner
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
    /// The host the chat runs on (worktree, context and Claude there, spec J.3); nil = this Mac.
    private let placement: RemotePlacement?
    /// Brings a Respond chat's commits back to this Mac (decision J.7.9); only with `placement`.
    private let importer: RemoteFixImport?

    public init(processRunner: ProcessRunning, streamingRunner: StreamingProcessRunning, tokens: TokenProviding, api: GitHubAPI,
                gitPath: String, ghPath: String?, claudePath: String, settings: ClaudeSettings = ClaudeSettings(),
                worktreeRoot: URL = AppPaths.worktreesDir, pluginCacheDirectory: URL = ClaudePlugins.defaultCacheDirectory,
                gitEnvironment: [String: String] = [:], placement: RemotePlacement? = nil, importer: RemoteFixImport? = nil) {
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
        self.placement = placement
        self.importer = importer ?? placement.map { RemoteFixImport(spaces: $0.workspaces, localGit: gitPath, gitEnvironment: gitEnvironment) }
    }

    /// Where the context folders are: this Mac or the host.
    private var contextFiles: any ContextFiles { placement?.workspaces.contextFiles ?? LocalContextFiles() }
    /// The worktree's disk, for the guard: this Mac or the host.
    private var fs: any WorkspaceFS { placement?.fs ?? LocalWorkspaceFS() }

    // MARK: Workspace

    public func workspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        var workspace = try await preparedWorkspace(request)
        workspace.runner = placement?.name
        return workspace
    }

    private func preparedWorkspace(_ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        switch request.subject {
        case .review(let draft):
            return try await pinnedWorkspace(account: draft.account, headOid: draft.headOid, request)
        case .respond(let draft):
            return try await respondWorkspace(draft, request)
        case .merge(let target):
            // The review chat's worktree, on the head the merge window shows (spec G.4), with the merge's own `pr.md`.
            var workspace = try await pinnedWorkspace(account: target.account, headOid: target.headOid, request,
                                                      description: request.mergeDetail?.body)
            // Only a summary of the same commit: after a reload to a newer head, an older chat keeps the review `pr.md`.
            if let detail = request.mergeDetail, detail.headOid == target.headOid, let metadata = workspace.files.metadata {
                let data = Data(MergeContextWriter.metadata(target: target, detail: detail).utf8)
                if placement == nil {
                    try data.write(to: metadata, options: .atomic)
                } else {
                    try await contextFiles.write(data, to: metadata.path)   // Upload: `.part` + `mv`.
                }
            }
            if workspace.note == Self.olderCommitNote { workspace.note = Self.olderMergeCommitNote }
            return workspace
        }
    }

    public static let olderMergeCommitNote = "Claude sees the PR’s latest commit, not the one this window shows."

    /// Spec B.5: the review's worktree was deleted after the analysis; the chat makes its own on the first turn, on
    /// the reviewed commit (merge: the shown head), at a path fixed per session (so `--resume` finds the conversation).
    /// `description`: the PR's description if it's known already (the merge window loaded it).
    private func pinnedWorkspace(account: String, headOid pinned: String, _ request: ChatWorkspaceRequest,
                                 description known: String? = nil) async throws -> ChatWorkspace {
        if let path = request.session.worktreePath,
           let existing = await existingReviewWorkspace(path: path, refs: request.session.worktreeRefs) {
            return existing
        }
        guard let pr = request.pr else {
            throw PRBarError.respond("This PR is no longer in the list: the chat can’t prepare its code.")
        }
        let token = try await tokens.token(for: account)
        let description: String?
        if let known { description = known } else { description = try await ReviewPipeline.description(of: pr, api: api, token: token) }
        let name = WorktreeManager.chatWorkspaceName(repo: pr.repo, number: pr.number, sessionID: request.session.id)
        let workspace: ReviewWorkspace
        let writer: ReviewContextWriter
        let cleanup: @Sendable () async -> Void
        if let remote = placement {
            // The host's own mirror (there's no diff-only mode there).
            let bare = try await remote.workspaces.mirror(pr.repo)
            let spaces = remote.workspaces
            workspace = try await spaces.prepare(repo: pr.repo, number: pr.number, baseRef: pr.baseRef, localPath: bare, name: name,
                                                 pinnedHeadOid: pinned)
            writer = ReviewContextWriter(runner: remote.runner, gitPath: remote.gitPath, ghPath: nil, files: spaces.contextFiles)
            cleanup = { [workspace] in await spaces.cleanup(workspace, localPath: bare) }
        } else {
            let manager = WorktreeManager(runner: processRunner, gitPath: gitPath, root: worktreeRoot)
            workspace = try await manager.prepare(repo: pr.repo, number: pr.number, baseRef: pr.baseRef,
                                                  localPath: request.localPath, name: name, pinnedHeadOid: pinned)
            writer = ReviewContextWriter(runner: processRunner, gitPath: gitPath, ghPath: ghPath)
            let localPath = request.localPath
            cleanup = { [workspace] in await manager.cleanup(workspace, localPath: localPath) }
        }
        let headOid: String
        do {
            headOid = try await writer.write(pr: pr, workspace: workspace, token: token, description: description ?? "")
        } catch {
            await Task.detached { await cleanup() }.value
            throw error
        }
        var result = await chatWorkspace(workspace)
        if headOid != pinned { result.note = Self.olderCommitNote }
        return result
    }

    /// `chatWorkspace(_:)` with the diff read where it is (this Mac or the host).
    private func chatWorkspace(_ workspace: ReviewWorkspace) async -> ChatWorkspace {
        guard placement != nil else { return Self.chatWorkspace(workspace) }
        let diff = await contextFiles.read(workspace.diffFile.path, limit: Self.maxRemoteDiffBytes).map { String(decoding: $0, as: UTF8.self) }
        return Self.chatWorkspace(workspace, diff: diff ?? "")
    }

    /// The most of a remote `pr.diff` that's brought back to know the diff's files.
    static let maxRemoteDiffBytes = 64 * 1024 * 1024

    /// `existingReviewWorkspace(path:refs:)`, checked where the worktree is.
    private func existingReviewWorkspace(path: String, refs: [String]) async -> ChatWorkspace? {
        guard placement != nil else { return Self.existingReviewWorkspace(path: path, refs: refs) }
        let workspace = Self.reviewWorkspace(path: path, refs: refs)
        guard await contextFiles.exists(workspace.directory.path), await contextFiles.exists(workspace.diffFile.path) else { return nil }
        return await chatWorkspace(workspace)
    }

    static func chatWorkspace(_ workspace: ReviewWorkspace) -> ChatWorkspace {
        chatWorkspace(workspace, diff: (try? String(contentsOf: workspace.diffFile, encoding: .utf8)) ?? "")
    }

    static func chatWorkspace(_ workspace: ReviewWorkspace, diff: String) -> ChatWorkspace {
        ChatWorkspace(
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
    private func respondWorkspace(_ draft: RespondDraft, _ request: ChatWorkspaceRequest) async throws -> ChatWorkspace {
        try checkRunner(draft)
        let files = contextFiles
        let name = Self.respondContextName(draft, sessionID: request.session.id)
        let context = URL(fileURLWithPath: try placement?.root.child(["work", name]) ?? worktreeRoot.appendingPathComponent(name).path,
                          isDirectory: true)
        try await files.createDirectory(context.path)
        let feedback = context.appendingPathComponent("feedback.json")
        try await files.write(try RespondAnalyzer.encodeFeedback(draft.items.map(\.feedback)), to: feedback.path)
        var paths = ChatContextFiles(feedback: feedback)
        let metadata = context.appendingPathComponent("pr.md")
        if let pr = request.pr {
            try await files.write(Data(ReviewContextWriter.metadata(pr, headOid: draft.startHeadOid, description: "").utf8), to: metadata.path)
            paths.metadata = metadata
        } else {
            await files.removeTree(metadata.path)
        }
        let fixes = context.appendingPathComponent("fixes.diff")
        if let diff = request.respondResult?.diff {
            try await files.write(Data(diff.utf8), to: fixes.path)
            paths.fixesDiff = fixes
        } else {
            await files.removeTree(fixes.path)
        }
        return ChatWorkspace(directory: URL(fileURLWithPath: draft.worktree.path, isDirectory: true), contextDirectory: context,
                             files: paths, diffFiles: [], isDiffOnly: false, refs: [], note: nil)
    }

    // MARK: Turnos

    public func send(_ input: ChatTurnInput, subject: ChatSubject, logURL: URL,
                     onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ChatTurnOutput {
        try ensureStopped(input.workingDirectory.path)
        if case .respond(let draft) = subject { try ensureStopped(draft.worktree.path) }
        return try await ChatEngine(claude: try await claude(for: subject, logURL: logURL)).send(input, onEvent: onEvent)
    }

    public func sendEditing(_ input: ChatTurnInput, draft: RespondDraft, result: RespondResult, sessionID: UUID, logURL: URL,
                            onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> (ChatTurnOutput, ChatFilesOutcome) {
        try checkRunner(draft)
        try ensureStopped(draft.worktree.path)
        let claude = try await claude(for: .respond(draft), logURL: logURL)
        let engine = ChatEngine(claude: claude)
        let implementer = await implementer(claude: claude, draft: draft)
        let worktree = input.workingDirectory.path
        let fs = self.fs
        let (output, outcome) = try await implementer.chatTurn(draft: draft, current: result, sessionID: sessionID, turn: input.turn) {
            // The tree as Claude finds it: a failed `--resume` is only rebuilt if Claude didn't touch anything.
            let before = try? await fs.snapshot(worktree)
            return try await engine.send(input, canRebuild: {
                guard let before, let after = try? await fs.snapshot(worktree) else { return false }
                return before.changes(to: after).all.isEmpty
            }, onEvent: onEvent)
        }
        guard let changed = outcome.result else { return (output, outcome) }
        // From a host: the result the user sees is computed on this Mac from the commits brought back.
        let imported: RespondResult
        do {
            imported = try await importFromHost(draft: draft, result: changed)
        } catch {
            // The host has a commit this Mac doesn't (and no Undo would be offered for it): it's undone there, so the
            // host, this Mac and the fixes' result stay as they were before the turn.
            guard let snapshot = outcome.snapshot else { throw error }
            let host = placement?.name ?? "the server"
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let service = self
            let rollback: Error? = await Task.detached {
                do {
                    let before = try await implementer.undoChatTurn(draft: draft, snapshot: snapshot)
                    // The local copy goes back too, if the import got that far (best effort: the push checks it).
                    _ = try? await service.importFromHost(draft: draft, result: before)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let rollback {
                AppLog.write("Chat: couldn’t undo a turn on \(host) after its import failed: \(rollback.localizedDescription)")
                throw PRBarError.respond("Claude’s changes are on \(host) but couldn’t be brought to this Mac (\(detail)), and undoing "
                                         + "them there failed (\(rollback.localizedDescription)). Analyze the PR again before pushing.")
            }
            if error is CancellationError { throw error }
            throw PRBarError.respond("Claude’s changes couldn’t be brought from \(host) to this Mac, so PRBar undid them there: \(detail)")
        }
        return (output, ChatFilesOutcome(changedFiles: outcome.changedFiles, snapshot: outcome.snapshot, result: imported))
    }

    public func undoFiles(draft: RespondDraft, snapshot: ChatFileSnapshot, logURL: URL) async throws -> RespondResult {
        try checkRunner(draft)
        try ensureStopped(draft.worktree.path)
        let implementer = await implementer(claude: gitOnlyClaude(logURL: logURL), draft: draft)
        let before = try await implementer.undoChatTurn(draft: draft, snapshot: snapshot)
        // The local copy of a host's commits goes back too (the push checks it's at the reviewed commit).
        do {
            return try await importFromHost(draft: draft, result: before)
        } catch {
            // The host went back but this Mac didn't: the undo is taken back there, so the turn (and its Undo) stays
            // as the user sees it.
            let host = placement?.name ?? "the server"
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            let redo: Error? = await Task.detached {
                do {
                    try await implementer.redoChatTurn(draft: draft, snapshot: snapshot)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let redo {
                AppLog.write("Chat: couldn’t redo a turn on \(host) after the undo’s import failed: \(redo.localizedDescription)")
                throw PRBarError.respond("PRBar undid the change on \(host) but couldn’t bring that to this Mac (\(detail)). "
                                         + "Implement the fixes again before pushing.")
            }
            if error is CancellationError { throw error }
            throw PRBarError.respond("The change wasn’t undone: PRBar couldn’t bring the result from \(host) to this Mac (\(detail)).")
        }
    }

    public func filesChangedSince(draft: RespondDraft, snapshot: ChatFileSnapshot) async -> Bool {
        guard (try? checkRunner(draft)) != nil, (try? ensureStopped(draft.worktree.path)) != nil else { return true }
        return await implementer(claude: gitOnlyClaude(logURL: URL(fileURLWithPath: "/dev/null")), draft: draft)
            .chatFilesChangedSince(snapshot, draft: draft)
    }

    /// On a host: the worktree's HEAD brought to this Mac and the result recomputed here (`RemoteFixImport`). On this
    /// Mac: `result` as is.
    private func importFromHost(draft: RespondDraft, result: RespondResult) async throws -> RespondResult {
        guard placement != nil, let importer else { return result }
        let token = try await tokens.token(for: draft.account)
        return try await importer.importFixes(draft: draft, localPath: draft.localPath, items: result.items,
                                              integrity: result.gitIntegrity, token: token)
    }

    /// On a host: nothing new runs in `path` while Claude may still be running there (J.7.15).
    private func ensureStopped(_ path: String) throws {
        guard let remote = placement else { return }
        try RemoteUnstoppedJobs.shared.ensureStopped(host: remote.name, path: path)
    }

    /// A Respond chat runs where its analysis ran (never a host's worktree with this Mac's git, or the other way).
    private func checkRunner(_ draft: RespondDraft) throws {
        guard draft.runner?.lowercased() != placement?.name.lowercased() else { return }
        if let runner = draft.runner {
            throw PRBarError.respond("This run happened on \(runner), which isn’t available now: the chat can’t use its worktree.")
        }
        throw PRBarError.respond("This run happened on this Mac: the chat can’t use its worktree on \(placement?.name ?? "the server").")
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
            // A Fix CI uses no skill (spec K.3).
            skills = draft.isCIFix ? [] : settings.respondSkills
        case .merge(let target):
            // No stage with a skill: the merge chat only reads.
            account = target.account
            skills = []
        }
        let token = try await tokens.token(for: account)
        if let remote = placement {
            // The same plugins, from the host's cache (§8.0 on the host).
            let pluginDirs = try await remote.plugins(skills: skills)
            return remote.claude(pluginDirs: pluginDirs, logURL: logURL, secrets: [token], model: settings.effectiveChatModel)
        }
        let pluginDirs = try ClaudePlugins.locate(skills: skills, in: pluginCacheDirectory)
        return ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs,
                            environment: ClaudeRunner.environment(toolPaths: [gitPath, claudePath] + (ghPath.map { [$0] } ?? [])),
                            logURL: logURL, redacting: [token], model: settings.effectiveChatModel)
    }

    /// Git only (undo, checks): the runner is only used to write the log.
    private func gitOnlyClaude(logURL: URL) -> ClaudeRunner {
        ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: [], environment: [:], logURL: logURL, redacting: [])
    }

    /// The respond worktree's guard and git: on this Mac, or on the host (its git, the Perl guard, this Mac's commit
    /// identity).
    private func implementer(claude: ClaudeRunner, draft: RespondDraft) async -> FixImplementer {
        guard let remote = placement else {
            return FixImplementer(claude: claude, runner: processRunner, gitPath: gitPath, environment: gitEnvironment)
        }
        let identity = await RespondPipeline.commitIdentity(runner: processRunner, gitPath: gitPath, localPath: draft.localPath,
                                                            environment: gitEnvironment)
        return FixImplementer(claude: claude, runner: remote.runner, gitPath: remote.gitPath,
                              environment: remote.gitEnvironment.merging(identity) { _, new in new }, fs: remote.fs,
                              testShell: "/bin/sh", testRunner: RemoteLoginRunner(host: remote.host, root: remote.root))
    }

    // MARK: Limpieza

    public func cleanup(session: ChatSession, subject: ChatSubject, localPath: String?) async {
        switch subject {
        case .review, .merge:
            guard let path = session.worktreePath else { return }
            let workspace = Self.reviewWorkspace(path: path, refs: session.worktreeRefs)
            if let remote = placement {
                let repo: RepoRef
                switch subject {
                case .review(let draft): repo = draft.repo
                case .merge(let target): repo = target.repo
                case .respond(let draft): repo = draft.repo
                }
                guard let bare = try? remote.mirrorPath(repo) else { return }
                await remote.workspaces.cleanup(workspace, localPath: bare)
                return
            }
            await WorktreeManager(runner: processRunner, gitPath: gitPath, root: worktreeRoot).cleanup(workspace, localPath: localPath)
        case .respond(let draft):
            guard (try? checkRunner(draft)) != nil else {
                AppLog.write("Chat: not cleaning up \(draft.worktree.path)’s chat: it ran on \(draft.runner ?? "this Mac").")
                return
            }
            if (try? ensureStopped(draft.worktree.path)) == nil {
                // Claude may still be running there, reading the context folder (`--add-dir`).
                AppLog.write("Chat: Claude may still be running in \(draft.worktree.path); not cleaning up its chat.")
                return
            }
            let name = Self.respondContextName(draft, sessionID: session.id)
            if let remote = placement {
                if let context = try? remote.root.child(["work", name]) { await remote.workspaces.contextFiles.removeTree(context) }
            } else {
                try? FileManager.default.removeItem(at: worktreeRoot.appendingPathComponent(name, isDirectory: true))
            }
            // The turns' snapshot refs live in the clone's common dir (the worktree may be gone already).
            let repo = draft.worktree.localPath ?? draft.worktree.path
            let pattern = "refs/prbar/chat-\(session.id.uuidString.lowercased())-*"
            let processRunner: ProcessRunning = placement?.runner ?? self.processRunner
            let gitPath = placement?.gitPath ?? self.gitPath
            let environment = placement?.gitEnvironment ?? GitHardening.environment.merging(gitEnvironment) { _, extra in extra }
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
