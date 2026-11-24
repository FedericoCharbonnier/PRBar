import Foundation
import os

public struct ReviewRequest: Sendable {
    public let item: ClassifiedPR
    public let localPath: String?
    public let baseRef: String          // pr.baseRef
    /// The repo's ignored paths (spec E.5).
    public let ignorePaths: [String]

    public init(item: ClassifiedPR, localPath: String?, baseRef: String, ignorePaths: [String] = []) {
        self.item = item
        self.localPath = localPath
        self.baseRef = baseRef
        self.ignorePaths = ignorePaths
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

/// Implementación real: token → plugins (los de los skills configurados) → worktree → contexto (`pr.diff`, `pr.md`) → `ClaudeReviewer`
/// (2 etapas) → limpieza.
public struct ReviewPipeline: ReviewPipelineRunning {
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
        let reviewer: ClaudeReviewer
    }

    private func parts(_ request: ReviewRequest, token: String, logURL: URL) async throws -> Parts {
        let pr = request.item.pr
        let settings = self.settings
        guard let remote = placement else {
            let pluginDirs = try ClaudePlugins.locate(skills: settings.reviewSkills, in: pluginCacheDirectory)
            let worktrees = self.worktrees
            let context = self.context
            return Parts(
                prepare: { try await worktrees.prepare(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: request.localPath) },
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
                reviewer: ClaudeReviewer(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs, toolPaths: toolPaths,
                                         redacting: [token], logURL: logURL, settings: settings, rules: rules))
        }
        let pluginDirs = try await remote.plugins(skills: settings.reviewSkills)
        let bare = try await remote.preparing { try await remote.workspaces.mirror(pr.repo) }
        let spaces = remote.workspaces
        let context = ReviewContextWriter(runner: remote.runner, gitPath: remote.gitPath, ghPath: nil, files: spaces.contextFiles)
        return Parts(
            prepare: {
                try await remote.preparing {
                    try await spaces.prepare(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: bare, name: nil,
                                             pinnedHeadOid: nil)
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
            let workspace = try await parts.prepare()

            let result: (summary: String, items: [ReviewItem])
            let headOid: String
            do {
                headOid = try await parts.writeContext(workspace, description ?? "")
                try Task.checkCancellation()
                result = try await parts.reviewer.review(
                    pr: pr, workspace: workspace, language: language, ignorePaths: request.ignorePaths,
                    onSession: { stage, stamp in
                        let session = ClaudeSessionRef.reviewStage(stage, stamp: stamp, directory: workspace.directory.path,
                                                                   runner: runnerName)
                        recorded.withLock { $0[stage] = session }
                    }
                ) { stage, agents in
                    onPhase(stage == .reviewing ? .reviewing(agents: agents) : .filtering)
                }
            } catch {
                await Self.cleanup(workspace, parts, after: error)
                throw error
            }
            // Kept for "Open in Terminal" (spec T.3) only with a Claude session to resume and the setting on; otherwise
            // cleaned up as before.
            let keep = keepsSessionFolders && !sessions().isEmpty
            if keep {
                await parts.release(workspace)
            } else {
                await Self.cleanup(workspace, parts, after: nil)
            }
            if Task.isCancelled {
                if keep { await Self.cleanup(workspace, parts, after: nil) }
                throw CancellationError()
            }

            var draft = ReviewDraft(
                prID: request.item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                author: pr.author, headOid: headOid, account: request.item.account,
                summary: result.summary,
                items: ReviewOptionsFilter.apply(result.items, options: settings.review, repoIgnorePaths: request.ignorePaths),
                language: language
            )
            draft.id = draftID
            draft.sessions = sessions()
            draft.retainedLocation = keep ? parts.location(workspace) : nil
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

    /// Corre en una tarea aparte para que la cancelación del job no mate los `git` de la limpieza. Si no se pudo
    /// confirmar que Claude paró en el host, el worktree queda como está (lo dice el error).
    private static func cleanup(_ workspace: ReviewWorkspace, _ parts: Parts, after error: Error?) async {
        if let error, RemoteUnstoppedJobs.isNotStopped(error) {
            AppLog.write("Review: Claude may still be running in \(workspace.directory.path); leaving it as is.")
            return
        }
        await Task.detached { await parts.cleanup(workspace) }.value
    }
}
