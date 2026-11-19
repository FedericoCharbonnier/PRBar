import Foundation

public struct ReviewRequest: Sendable {
    public let item: ClassifiedPR
    public let localPath: String?
    public let baseRef: String          // pr.baseRef

    public init(item: ClassifiedPR, localPath: String?, baseRef: String) {
        self.item = item
        self.localPath = localPath
        self.baseRef = baseRef
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

    public init(underlying: Error, logURL: URL?) {
        self.underlying = underlying
        self.logURL = logURL
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
    private let logURLProvider: @Sendable (UUID) -> URL

    /// `logURLProvider` recibe el `id` del draft. `ghPath` solo hace falta en modo solo diff. `api` trae la
    /// descripción del PR (para `pr.md` y el idioma de los comentarios). `settings`: los skills (solo se cargan sus
    /// plugins), el filtro y el modelo.
    public init(
        processRunner: ProcessRunning, streamingRunner: StreamingProcessRunning, tokens: TokenProviding,
        api: GitHubAPI = GitHubClient(), gitPath: String, ghPath: String?, claudePath: String, worktreeRoot: URL = AppPaths.worktreesDir,
        pluginCacheDirectory: URL = ClaudePlugins.defaultCacheDirectory, settings: ClaudeSettings = ClaudeSettings(),
        logURLProvider: @escaping @Sendable (UUID) -> URL
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
        self.logURLProvider = logURLProvider
    }

    public func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let pr = request.item.pr
        let draftID = UUID()
        let logURL = logURLProvider(draftID)

        do {
            let token = try await tokens.token(for: request.item.account)
            let pluginDirs = try ClaudePlugins.locate(skills: settings.reviewSkills, in: pluginCacheDirectory)
            try Task.checkCancellation()
            await onPhase(.preparing)
            let description = try await Self.description(of: pr, api: api, token: token)
            let language = PRLanguage.detect(description: description, title: pr.title)
            let workspace = try await worktrees.prepare(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: request.localPath)

            let result: (summary: String, items: [ReviewItem])
            let headOid: String
            do {
                headOid = try await context.write(pr: pr, workspace: workspace, token: token, description: description ?? "")
                try Task.checkCancellation()
                let reviewer = ClaudeReviewer(
                    runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs,
                    toolPaths: toolPaths, redacting: [token], logURL: logURL, settings: settings
                )
                result = try await reviewer.review(pr: pr, workspace: workspace, language: language) { stage, agents in
                    onPhase(stage == .reviewing ? .reviewing(agents: agents) : .filtering)
                }
            } catch {
                await cleanup(workspace, request)
                throw error
            }
            await cleanup(workspace, request)
            try Task.checkCancellation()

            var draft = ReviewDraft(
                prID: request.item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                author: pr.author, headOid: headOid, account: request.item.account,
                summary: result.summary, items: result.items, language: language
            )
            draft.id = draftID
            return draft
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? ReviewFailure { throw failure }
            let existingLog = FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil
            throw ReviewFailure(underlying: error, logURL: existingLog)
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

    /// Corre en una tarea aparte para que la cancelación del job no mate los `git` de la limpieza.
    private func cleanup(_ workspace: ReviewWorkspace, _ request: ReviewRequest) async {
        let worktrees = self.worktrees
        await Task.detached {
            await worktrees.cleanup(workspace, localPath: request.localPath)
        }.value
    }
}
