import Foundation

/// Lo que hace falta para analizar el feedback de un PR propio.
public struct RespondRequest: Sendable {
    public let item: ClassifiedPR
    /// El clone del usuario (`RepoConfig.localPath`).
    public let localPath: String
    /// `RepoConfig.worktreeDir`; nil = `<localPath>-worktrees`.
    public let worktreeDir: String?

    public init(item: ClassifiedPR, localPath: String, worktreeDir: String?) {
        self.item = item
        self.localPath = localPath
        self.worktreeDir = worktreeDir
    }
}

public enum RespondPhase: Equatable, Sendable {
    case queued, preparing
    case analyzing(agents: Int)
    case ready(RespondDraft)
    case implementing(done: Int, total: Int)
    case readyToPush(RespondDraft, RespondResult)
    case pushing
    case done(RespondRecord)
    case failed(String, logURL: URL?)

    /// Hay un job en cola o corriendo (los tests de `readyToPush` se ven en `RespondQueue.runningTests`).
    public var isActive: Bool {
        switch self {
        case .queued, .preparing, .analyzing, .implementing, .pushing: true
        case .ready, .readyToPush, .done, .failed: false
        }
    }
}

/// Una corrida de "Responder", tal como se guarda en `RespondHistory`.
public struct RespondRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { draft.id }
    public var draft: RespondDraft
    public var selections: [String: RespondSelection]
    public var result: RespondResult?
    /// Respuestas ya publicadas, por id de ítem. Se guarda después de cada una: un reintento nunca las repite.
    public var posted: [String: PostedReply]
    public var pushed: Bool
    public var startedAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?
    /// The chat about this run (spec B.3).
    public var chat: ChatSession?

    public init(draft: RespondDraft, selections: [String: RespondSelection] = [:], result: RespondResult? = nil,
                posted: [String: PostedReply] = [:], pushed: Bool = false, startedAt: Date, finishedAt: Date? = nil,
                errorMessage: String? = nil, chat: ChatSession? = nil) {
        self.draft = draft
        self.selections = selections
        self.result = result
        self.posted = posted
        self.pushed = pushed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.chat = chat
    }

    private enum CodingKeys: String, CodingKey {
        case draft, selections, result, posted, pushed, startedAt, finishedAt, errorMessage, chat
    }

    /// A broken `chat` doesn't lose the record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        draft = try c.decode(RespondDraft.self, forKey: .draft)
        selections = try c.decodeIfPresent([String: RespondSelection].self, forKey: .selections) ?? [:]
        result = try c.decodeIfPresent(RespondResult.self, forKey: .result)
        posted = try c.decodeIfPresent([String: PostedReply].self, forKey: .posted) ?? [:]
        pushed = try c.decodeIfPresent(Bool.self, forKey: .pushed) ?? false
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        chat = (try? c.decodeIfPresent(ChatSession.self, forKey: .chat)) ?? nil
    }
}

/// La implementación se canceló. Los commits ya hechos no se borran: quedan sin pushear en `path`.
public struct RespondCancellation: Error, Equatable, LocalizedError {
    /// nil si no se pudo contar.
    public let unpushedCommits: Int?
    public let path: String
    /// `git status` no quedó vacío (p. ej. se canceló en medio de un commit).
    public let dirty: Bool

    public init(unpushedCommits: Int?, path: String, dirty: Bool = false) {
        self.unpushedCommits = unpushedCommits
        self.path = path
        self.dirty = dirty
    }

    public var errorDescription: String? {
        var message: String
        switch unpushedCommits {
        case nil: message = "Canceled: couldn't check whether unpushed commits were left in \(path)."
        case 1?: message = "Canceled: 1 unpushed commit was left in \(path)."
        case let count?: message = "Canceled: \(count) unpushed commits were left in \(path)."
        }
        if dirty { message += " Uncommitted changes were left too: check them before continuing." }
        return message
    }
}

public protocol RespondPipelineRunning: Sendable {
    /// Token → feedback → filtro → worktree → análisis de Claude. El draft sale con `id == draftID`.
    func analyze(_ request: RespondRequest, draftID: UUID,
                 onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft
    /// Un fix por ítem elegido. Si se cancela, el árbol queda limpio y se lanza `RespondCancellation`.
    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult
    /// El `testCommand` del repo, en el worktree. Nunca lanza.
    func runTests(draft: RespondDraft, testCommand: String) async -> TestRun
    /// Pushea `result.headOid` (lo que vio el usuario). Ver `RespondPublisher.push`.
    func push(draft: RespondDraft, result: RespondResult) async throws
    /// Saca el worktree de PRBar y su ref (al terminar o al descartar). Nunca lanza.
    func cleanup(draft: RespondDraft) async
    /// Ver `RespondPublisher.postReplies`. Un error al pedir el token vuelve como error, sin publicar nada.
    func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                     alreadyPosted: [String: PostedReply],
                     onPosted: @escaping @Sendable (String, PostedReply) async -> Void) async -> (posted: [String: PostedReply], error: Error?)
    func logURL(for id: UUID) -> URL
}

/// Implementación real. Claude corre aislado con `ClaudeRunner` (solo el plugin del skill de responder, con el
/// modelo de `ClaudeSettings`; sin token: el token
/// solo se usa para la API de GitHub y se tacha del log). git nunca recibe el token.
public struct RespondPipeline: RespondPipelineRunning {
    public static let noItemsMessage = "There are no unresolved comments"
    public static let forkMessage = "The PR comes from a fork: PRBar can't push to it"

    private let processRunner: ProcessRunning
    private let streamingRunner: StreamingProcessRunning
    private let tokens: TokenProviding
    private let api: GitHubAPI
    private let gitPath: String
    private let claudePath: String
    private let worktreeRoot: URL
    private let pluginCacheDirectory: URL
    private let settings: ClaudeSettings
    private let rules: [Rule]
    private let gitEnvironment: [String: String]
    private let logURLProvider: @Sendable (UUID) -> URL
    private let originMatches: @Sendable (String, RepoRef) -> Bool

    /// `worktreeRoot`: donde van las carpetas de contexto (`AppPaths.worktreesDir`). `gitEnvironment` se suma
    /// al de cada git (los tests aíslan la configuración global). `logURLProvider` recibe el id del draft.
    /// `originMatches`: ver `WorktreeResolver` (los tests lo reemplazan porque sus remotos son carpetas locales).
    public init(
        processRunner: ProcessRunning, streamingRunner: StreamingProcessRunning, tokens: TokenProviding, api: GitHubAPI,
        gitPath: String, claudePath: String, worktreeRoot: URL = AppPaths.worktreesDir,
        pluginCacheDirectory: URL = ClaudePlugins.defaultCacheDirectory, settings: ClaudeSettings = ClaudeSettings(),
        rules: [Rule] = [], gitEnvironment: [String: String] = [:],
        logURLProvider: @escaping @Sendable (UUID) -> URL,
        originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) }
    ) {
        self.processRunner = processRunner
        self.streamingRunner = streamingRunner
        self.tokens = tokens
        self.api = api
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.worktreeRoot = worktreeRoot
        self.pluginCacheDirectory = pluginCacheDirectory
        self.settings = settings
        self.rules = rules
        self.gitEnvironment = gitEnvironment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, forced in forced }
        self.logURLProvider = logURLProvider
        self.originMatches = originMatches
    }

    public func logURL(for id: UUID) -> URL { logURLProvider(id) }

    // MARK: - Análisis

    public func analyze(_ request: RespondRequest, draftID: UUID,
                        onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        let item = request.item
        let pr = item.pr
        let token = try await tokens.token(for: item.account)
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        if feedback.isCrossRepository { throw PRBarError.respond(Self.forkMessage) }
        let items = FeedbackFilter.select(
            threads: feedback.threads,
            reviewBodies: feedback.reviews.map { ($0.item, $0.state, $0.submittedAt) },
            me: item.account, lastCommitAt: feedback.lastCommitAt)
        guard !items.isEmpty else { throw PRBarError.respond(Self.noItemsMessage) }
        // On demand (the refresh doesn't bring it): context for Claude and the language of the replies.
        let description = try await ReviewPipeline.description(of: pr, api: api, token: token)
        let pluginDirs = try ClaudePlugins.locate(skills: settings.respondSkills, in: pluginCacheDirectory)
        try Task.checkCancellation()

        let headRef = feedback.headRefName
        // Siempre un worktree propio y separado; su commit es la base de todo lo que sigue.
        let (worktree, startHeadOid) = try await resolver.prepare(
            localPath: request.localPath, repo: pr.repo, number: pr.number, headRef: headRef, worktreeDir: request.worktreeDir)
        let worktreeURL = URL(fileURLWithPath: worktree.path, isDirectory: true)
        do {
            try Task.checkCancellation()
            return try await analyze(item: item, items: items, headRef: headRef, worktree: worktree, worktreeURL: worktreeURL,
                                     startHeadOid: startHeadOid, pluginDirs: pluginDirs, token: token, draftID: draftID,
                                     description: description, onPhase: onPhase)
        } catch {
            // Sin draft no hay nada que revisar: el worktree se borra (fuera de esta tarea, que puede estar cancelada).
            let resolver = self.resolver
            await Task.detached { await resolver.cleanup(worktree) }.value
            throw error
        }
    }

    private func analyze(item: ClassifiedPR, items: [FeedbackItem], headRef: String, worktree: ResolvedWorktree,
                         worktreeURL: URL, startHeadOid: String, pluginDirs: [String], token: String, draftID: UUID,
                         description: String?, onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        let pr = item.pr
        let language = PRLanguage.detect(description: description, title: pr.title)

        await onPhase(.analyzing(agents: 0))
        let contextDir = worktreeRoot.appendingPathComponent(
            "\(pr.repo.owner)-\(pr.repo.name)-\(pr.number)-\(draftID.uuidString).respond-context", isDirectory: true)
        let analyzer = RespondAnalyzer(claude: claude(pluginDirs: pluginDirs, token: token, logURL: logURL(for: draftID)),
                                       settings: settings, rules: rules)
        let relay = MainActorRelay<Int> { agents in onPhase(.analyzing(agents: agents)) }
        let analyzed: [RespondItem]
        WorkspaceRegistry.shared.insert(contextDir.path)
        do {
            defer {
                try? FileManager.default.removeItem(at: contextDir)
                WorkspaceRegistry.shared.remove(contextDir.path)
            }
            analyzed = try await analyzer.analyze(pr: pr, items: items, worktree: worktreeURL, contextDir: contextDir,
                                                 description: description ?? "", language: language) { relay.send($0) }
        } catch {
            await relay.finish()
            throw error
        }
        await relay.finish()
        try Task.checkCancellation()

        return RespondDraft(
            id: draftID, prID: item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, headRef: headRef,
            account: item.account, worktree: worktree, startHeadOid: startHeadOid, items: analyzed, language: language)
    }

    // MARK: - Fixes y tests

    public func implement(draft: RespondDraft, selections: [String: RespondSelection],
                          onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult {
        guard draft.worktree.origin == .dedicated else {
            throw PRBarError.respond("This analysis is from an older version of PRBar. Analyze the PR again.")
        }
        let token = try await tokens.token(for: draft.account)
        let pluginDirs = try ClaudePlugins.locate(skills: settings.respondSkills, in: pluginCacheDirectory)
        let implementer = FixImplementer(claude: claude(pluginDirs: pluginDirs, token: token, logURL: logURL(for: draft.id)),
                                         runner: processRunner, gitPath: gitPath, environment: gitEnvironment,
                                         settings: settings, rules: rules)
        do {
            return try await implementer.implement(draft: draft, selections: selections, onProgress: onProgress)
        } catch {
            guard error is CancellationError || Task.isCancelled else { throw error }
            // `FixImplementer` ya restauró el árbol (en su propia tarea). Lo que queda se mira fuera de esta tarea
            // cancelada, que no puede lanzar procesos.
            let pipeline = self
            throw await Task.detached { await pipeline.cancellation(of: draft) }.value
        }
    }

    /// Cuenta los commits nuevos (`startHeadOid..HEAD`) y si el árbol quedó sucio, con git endurecido. Si apareció
    /// un `.git` anidado no corre ningún git: no se sabe cuántos commits quedaron y el árbol cuenta como sucio.
    func cancellation(of draft: RespondDraft) async -> RespondCancellation {
        let worktree = URL(fileURLWithPath: draft.worktree.path, isDirectory: true)
        guard WorktreeIntegrity.nestedGitEntries(in: worktree).isEmpty else {
            return RespondCancellation(unpushedCommits: nil, path: draft.worktree.path, dirty: true)
        }
        let count = try? await git(worktree, ["rev-list", "--count", "\(draft.startHeadOid)..HEAD"])
        let status = try? await git(worktree, ["status", GitHardening.ignoreSubmodules, "--porcelain", "--untracked-files=all"])
        return RespondCancellation(
            unpushedCommits: count.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            path: draft.worktree.path,
            dirty: status.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
    }

    public func runTests(draft: RespondDraft, testCommand: String) async -> TestRun {
        // Sin plugins ni Claude: el runner solo se usa para escribir el log de la corrida.
        let implementer = FixImplementer(
            claude: ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: [],
                                 environment: [:], logURL: logURL(for: draft.id), redacting: []),
            runner: processRunner, gitPath: gitPath, environment: gitEnvironment)
        return await implementer.runTests(worktree: URL(fileURLWithPath: draft.worktree.path, isDirectory: true),
                                          testCommand: testCommand)
    }

    // MARK: - Push y respuestas

    public func push(draft: RespondDraft, result: RespondResult) async throws {
        try await publisher.push(draft: draft, result: result)
    }

    public func cleanup(draft: RespondDraft) async {
        await resolver.cleanup(draft.worktree)
    }

    public func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                            alreadyPosted: [String: PostedReply],
                            onPosted: @escaping @Sendable (String, PostedReply) async -> Void) async -> (posted: [String: PostedReply], error: Error?) {
        let token: String
        do {
            token = try await tokens.token(for: draft.account)
        } catch {
            return (alreadyPosted, error)
        }
        return await publisher.postReplies(draft: draft, selections: selections, result: result,
                                           alreadyPosted: alreadyPosted, token: token,
                                           replyTemplate: settings.respond.effectiveReplyTemplate, onPosted: onPosted)
    }

    // MARK: - Privado

    private var publisher: RespondPublisher {
        RespondPublisher(runner: processRunner, gitPath: gitPath, api: api, environment: gitEnvironment, originMatches: originMatches)
    }

    private var resolver: WorktreeResolver {
        WorktreeResolver(runner: processRunner, gitPath: gitPath, environment: gitEnvironment, originMatches: originMatches)
    }

    private func claude(pluginDirs: [String], token: String, logURL: URL) -> ClaudeRunner {
        ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs,
                     environment: ClaudeRunner.environment(toolPaths: [gitPath, claudePath]),
                     logURL: logURL, redacting: [token], model: settings.model)
    }

    private func git(_ worktree: URL, _ arguments: [String]) async throws -> String {
        let args = ["-C", worktree.path] + GitHardening.arguments + arguments
        let result = try await processRunner.run(gitPath, args, environment: gitEnvironment, currentDirectory: nil,
                                                 timeout: ProcessTimeouts.standard)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "),
                                           status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }
}
