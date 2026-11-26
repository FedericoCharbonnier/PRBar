import Foundation
import os

public struct ReviewRequest: Sendable {
    public let item: ClassifiedPR
    public let localPath: String?
    public let baseRef: String          // pr.baseRef
    /// The repo's ignored paths (spec E.5).
    public let ignorePaths: [String]
    /// Spec RM.3.1: the reviews PRBar posted on this PR before (`ReviewMemory.publishedRecords`), oldest first; empty = a
    /// first review.
    public let previousReviews: [ReviewRecord]

    public init(item: ClassifiedPR, localPath: String?, baseRef: String, ignorePaths: [String] = [],
                previousReviews: [ReviewRecord] = []) {
        self.item = item
        self.localPath = localPath
        self.baseRef = baseRef
        self.ignorePaths = ignorePaths
        self.previousReviews = previousReviews
    }
}

public enum ReviewPhase: Equatable, Sendable {
    case queued, preparing
    case reviewing(agents: Int)
    case filtering
    case ready(ReviewDraft)
    case failed(String, logURL: URL?)
    case published(URL)

    /// Hay un job en cola o corriendo.
    public var isActive: Bool {
        switch self {
        case .queued, .preparing, .reviewing, .filtering: true
        case .ready, .failed, .published: false
        }
    }
}

public protocol ReviewPipelineRunning: Sendable {
    /// Hace worktree → Claude → limpieza (la limpieza corre siempre, incluso con error o cancelación).
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft
}

/// Error de una review, con el log de Claude si llegó a escribirse.
public struct ReviewFailure: Error, LocalizedError {
    public let underlying: Error
    public let logURL: URL?
    /// The sessions of the stages that started (spec T.2): History keeps them.
    public var sessions: [ClaudeSessionRef]

    public init(underlying: Error, logURL: URL?, sessions: [ClaudeSessionRef] = []) {
        self.underlying = underlying
        self.logURL = logURL
        self.sessions = sessions
    }

    public var errorDescription: String? { underlying.localizedDescription }
}

/// Implementación real: token → plugins (los de los skills configurados) → carpeta del PR (spec RM.2) → contexto (`pr.diff`,
/// `pr.md`) y memoria (`previous-reviews.md`, `since-last-review.diff`) → `ClaudeReviewer` (2 etapas) → release o limpieza.
public struct ReviewPipeline: ReviewPipelineRunning {
    private let processRunner: ProcessRunning
    private let streamingRunner: StreamingProcessRunning
    private let tokens: TokenProviding
    private let api: GitHubAPI
    private let worktrees: WorktreeManager
    private let context: ReviewContextWriter
    private let claudePath: String
    private let toolPaths: [String]
    private let pluginCacheDirectory: URL
    private let settings: ClaudeSettings
    private let rules: [Rule]
    private let logURLProvider: @Sendable (UUID) -> URL
    /// El host donde corre (worktree, contexto y Claude allá); nil = esta Mac.
    private let placement: RemotePlacement?
    /// Settings › Keep folders for Terminal (spec T.3): off, the folder is cleaned up when the review ends, as before.
    private let keepsSessionFolders: Bool

    /// `logURLProvider` recibe el `id` del draft. `ghPath` solo hace falta en modo solo diff. `api` trae la
    /// descripción del PR (para `pr.md` y el idioma de los comentarios). `settings`: los skills (solo se cargan sus
    /// plugins), el filtro y el modelo.
    public init(
        processRunner: ProcessRunning, streamingRunner: StreamingProcessRunning, tokens: TokenProviding,
        api: GitHubAPI = GitHubClient(), gitPath: String, ghPath: String?, claudePath: String, worktreeRoot: URL = AppPaths.worktreesDir,
        pluginCacheDirectory: URL = ClaudePlugins.defaultCacheDirectory, settings: ClaudeSettings = ClaudeSettings(),
        rules: [Rule] = [], logURLProvider: @escaping @Sendable (UUID) -> URL, placement: RemotePlacement? = nil,
        keepsSessionFolders: Bool = true
    ) {
        self.processRunner = processRunner
        self.streamingRunner = streamingRunner
        self.tokens = tokens
        self.api = api
        self.worktrees = WorktreeManager(runner: processRunner, gitPath: gitPath, root: worktreeRoot)
        self.context = ReviewContextWriter(runner: processRunner, gitPath: gitPath, ghPath: ghPath)
        self.claudePath = claudePath
        self.toolPaths = [gitPath, ghPath].compactMap { $0 }
        self.pluginCacheDirectory = pluginCacheDirectory
        self.settings = settings
        self.rules = rules
        self.logURLProvider = logURLProvider
        self.placement = placement
        self.keepsSessionFolders = keepsSessionFolders
    }

    /// Lo que cambia entre esta Mac y un host: preparar/limpiar el worktree, dónde va el contexto y con qué corre Claude.
    private struct Parts: Sendable {
        let prepare: @Sendable () async throws -> ReviewWorkspace
        let cleanup: @Sendable (ReviewWorkspace) async -> Void
        /// Success (spec T.3): the folder stays, without its context.
        let release: @Sendable (ReviewWorkspace) async -> Void
        let location: @Sendable (ReviewWorkspace) -> WorktreeLocation
        let writeContext: @Sendable (ReviewWorkspace, String) async throws -> String
        let writeMemory: @Sendable (ReviewWorkspace, ReviewMemory) async throws -> Void
        /// Decision 7: a process with its cwd in the PR's folder (a Terminal) doesn't stop the review; the log says so.
        let noteBusy: @Sendable (ReviewWorkspace) async -> Void
        let reviewer: ClaudeReviewer
    }

    private func parts(_ request: ReviewRequest, token: String, logURL: URL) async throws -> Parts {
        let pr = request.item.pr
        let settings = self.settings
        guard let remote = placement else {
            let pluginDirs = try ClaudePlugins.locate(skills: settings.reviewSkills, in: pluginCacheDirectory)
            let worktrees = self.worktrees
            let context = self.context
            let runner = self.processRunner
            return Parts(
                prepare: {
                    try await worktrees.prepareReview(repo: pr.repo, number: pr.number, baseRef: request.baseRef,
                                                      localPath: request.localPath)
                },
                cleanup: { workspace in await worktrees.cleanup(workspace, localPath: request.localPath) },
                release: { workspace in worktrees.release(workspace) },
                location: { workspace in
                    WorktreeLocation(directory: workspace.directory.path, runner: nil,
                                     repository: workspace.isDiffOnly ? nil : request.localPath,
                                     refs: [workspace.prRef, workspace.baseRef].compactMap { $0 })
                },
                writeContext: { workspace, description in
                    try await context.write(pr: pr, workspace: workspace, token: token, description: description)
                },
                writeMemory: { workspace, memory in try await context.writeMemory(memory, workspace: workspace) },
                noteBusy: { workspace in
                    let paths = [workspace.directory.path, CanonicalPath.of(workspace.directory.path)]
                    guard let result = try? await runner.run(ProcessCwd.lsofPath, ProcessCwd.lsofArguments, timeout: 30),
                          ProcessCwd.anyInside(paths, lsofOutput: result.stdout) else { return }
                    ReviewPipeline.logBusy(workspace)
                },
                reviewer: ClaudeReviewer(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs, toolPaths: toolPaths,
                                         redacting: [token], logURL: logURL, settings: settings, rules: rules))
        }
        let pluginDirs = try await remote.plugins(skills: settings.reviewSkills)
        let bare = try await remote.preparing { try await remote.workspaces.mirror(pr.repo) }
        let spaces = remote.workspaces
        let context = ReviewContextWriter(runner: remote.runner, gitPath: remote.gitPath, ghPath: nil, files: spaces.contextFiles,
                                          gitEnvironment: spaces.gitEnvironment)
        return Parts(
            prepare: {
                try await remote.preparing {
                    try await spaces.prepareReview(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: bare)
                }
            },
            cleanup: { workspace in await spaces.cleanup(workspace, localPath: bare) },
            release: { workspace in await spaces.release(workspace) },
            location: { workspace in
                WorktreeLocation(directory: workspace.directory.path, runner: remote.name, repository: bare,
                                 refs: [workspace.prRef, workspace.baseRef].compactMap { $0 })
            },
            writeContext: { workspace, description in
                try await remote.preparing { try await context.write(pr: pr, workspace: workspace, token: token, description: description) }
            },
            writeMemory: { workspace, memory in
                try await remote.preparing { try await context.writeMemory(memory, workspace: workspace) }
            },
            noteBusy: { workspace in
                guard let script = try? ProcessCwd.remoteScript(resolving: [workspace.directory.path]),
                      let result = try? await remote.host.runScript(script, timeout: 30), result.status == 0,
                      ProcessCwd.anyInside([workspace.directory.path], remoteOutput: result.stdout) else { return }
                ReviewPipeline.logBusy(workspace)
            },
            reviewer: ClaudeReviewer(runner: remote.runner, claudePath: remote.claudePath, pluginDirs: pluginDirs, toolPaths: [],
                                     redacting: [token], logURL: logURL, settings: settings, rules: rules,
                                     promptViaStandardInput: true))
    }

    public func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let pr = request.item.pr
        let draftID = UUID()
        let logURL = logURLProvider(draftID)
        // The stages' sessions (spec T.2), by stage: a retry replaces its stage's.
        let recorded = OSAllocatedUnfairLock(initialState: [Int: ClaudeSessionRef]())
        let sessions: @Sendable () -> [ClaudeSessionRef] = {
            recorded.withLock { $0.sorted { $0.key < $1.key }.map(\.value) }
        }
        let runnerName = placement?.name

        do {
            let token = try await tokens.token(for: request.item.account)
            let parts = try await parts(request, token: token, logURL: logURL)
            try Task.checkCancellation()
            await onPhase(.preparing)
            let description = try await Self.description(of: pr, api: api, token: token)
            let language = PRLanguage.detect(description: description, title: pr.title)
            let memory = try await Self.memory(for: request, api: api, token: token)
            let unlock = await ReviewFolderLocks.shared.acquire(Self.folderKey(pr, runner: runnerName))
            defer { unlock() }
            let workspace = try await parts.prepare()
            let perPR = WorktreeManager.isReviewFolder(workspace)
            if perPR { await parts.noteBusy(workspace) }

            let outcome: ClaudeReviewer.ReviewOutcome
            let headOid: String
            do {
                headOid = try await parts.writeContext(workspace, description ?? "")
                if let memory { try await parts.writeMemory(workspace, memory) }
                try Task.checkCancellation()
                outcome = try await parts.reviewer.review(
                    pr: pr, workspace: workspace, language: language, ignorePaths: request.ignorePaths, memory: memory,
                    onSession: { stage, stamp in
                        let session = ClaudeSessionRef.reviewStage(stage, stamp: stamp, directory: workspace.directory.path,
                                                                   runner: runnerName)
                        recorded.withLock { $0[stage] = session }
                    }
                ) { stage, agents in
                    onPhase(stage == .reviewing ? .reviewing(agents: agents) : .filtering)
                }
            } catch {
                await Self.finish(workspace, parts, keepsFolder: perPR, after: error)
                throw error
            }
            // The PR's folder always stays (spec RM.2); a per-run one only with a session to resume and the setting on (T.3).
            let keep = perPR || (keepsSessionFolders && !sessions().isEmpty)
            if keep {
                await parts.release(workspace)
            } else {
                await Self.finish(workspace, parts, keepsFolder: false, after: nil)
            }
            if Task.isCancelled {
                if keep && !perPR { await Self.finish(workspace, parts, keepsFolder: false, after: nil) }
                throw CancellationError()
            }

            var draft = ReviewDraft(
                prID: request.item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                author: pr.author, headOid: headOid, account: request.item.account,
                summary: outcome.summary,
                items: ReviewOptionsFilter.apply(outcome.items, options: settings.review, repoIgnorePaths: request.ignorePaths),
                language: language
            )
            draft.id = draftID
            draft.sessions = sessions()
            draft.retainedLocation = keep ? parts.location(workspace) : nil
            draft.previous = outcome.previous
            draft.reviewedSince = memory?.reviewedSince
            return draft
        } catch {
            if RemoteUnstoppedJobs.isNotStopped(error) {
                // Claude puede seguir corriendo en el host: el error lo dice (también si fue un Stop).
                let existingLog = FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
                throw ReviewFailure(underlying: error, logURL: existingLog, sessions: sessions())
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? ReviewFailure { throw failure }
            let existingLog = FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
            throw ReviewFailure(underlying: error, logURL: existingLog, sessions: sessions())
        }
    }

    /// The PR description, fetched on demand (the refresh query doesn't bring it). If GitHub fails the review
    /// still runs: the language is detected from the title and the window shows which one it is.
    static func description(of pr: PullRequest, api: GitHubAPI, token: String) async throws -> String? {
        do {
            return try await api.pullRequestDetails(repo: pr.repo, number: pr.number, token: token).body
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            AppLog.write("Could not fetch the description of \(pr.repo.fullName)#\(pr.number): \(error.localizedDescription)")
            return nil
        }
    }

    /// Spec RM.3.1: nil without previous reviews. The threads come from `reviewFeedback`; if it fails the review goes on
    /// and every comment is `unknown` (RM.7).
    static func memory(for request: ReviewRequest, api: GitHubAPI, token: String) async throws -> ReviewMemory? {
        guard !request.previousReviews.isEmpty else { return nil }
        let pr = request.item.pr
        var feedback: PRFeedback?
        do {
            feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            AppLog.write("Review memory: couldn’t read the threads of \(pr.repo.fullName)#\(pr.number); previous comments go as unknown: \(error.localizedDescription)")
        }
        return ReviewMemory.build(records: request.previousReviews, feedback: feedback)
    }

    static func folderKey(_ pr: PullRequest, runner: String?) -> String {
        "\(runner ?? "this Mac")|\(pr.repo.fullName)#\(pr.number)"
    }

    static func logBusy(_ workspace: ReviewWorkspace) {
        AppLog.write("Review: a process (e.g. a Terminal) works in \(workspace.directory.path); its checkout is now the PR’s current head.")
    }

    /// In its own task so the job's cancellation doesn't kill the cleanup's `git`. Not confirmed that Claude stopped on the
    /// host: left as is. The PR's folder is released (RM.7: it stays, without `.context`); a per-run one is cleaned up.
    private static func finish(_ workspace: ReviewWorkspace, _ parts: Parts, keepsFolder: Bool, after error: Error?) async {
        if let error, RemoteUnstoppedJobs.isNotStopped(error) {
            AppLog.write("Review: Claude may still be running in \(workspace.directory.path); leaving it as is.")
            return
        }
        if keepsFolder {
            await Task.detached { await parts.release(workspace) }.value
        } else {
            await Task.detached { await parts.cleanup(workspace) }.value
        }
    }
}

/// One review at a time in a PR's folder (spec RM.2, decision 3). `ReviewQueue.cancel` frees the PR's slot at once while
/// the cancelled run may still be releasing the folder: the next review of the PR waits for it here.
public actor ReviewFolderLocks {
    public static let shared = ReviewFolderLocks()
    private var tails: [String: Task<Void, Never>] = [:]

    /// Waits until the previous holder of `key` lets go; returns what lets go of it (call it exactly once).
    public func acquire(_ key: String) async -> @Sendable () -> Void {
        let previous = tails[key]
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        tails[key] = Task { for await _ in stream {} }
        await previous?.value
        return { continuation.finish() }
    }
}
