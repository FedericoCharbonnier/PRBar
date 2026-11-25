import Foundation

/// Lo que hace falta para analizar el feedback de un PR propio.
public struct RespondRequest: Sendable {
    public let item: ClassifiedPR
    /// El clone del usuario (`RepoConfig.localPath`). Solo un destino remoto acepta nil (el worktree sale del mirror
    /// del host, decisión J.7.14).
    public let localPath: String?
    /// `RepoConfig.worktreeDir`; nil = `<localPath>-worktrees`.
    public let worktreeDir: String?
    /// Responder el feedback o arreglar el CI (spec K).
    public let mode: RespondMode

    public init(item: ClassifiedPR, localPath: String?, worktreeDir: String?, mode: RespondMode = .feedback) {
        self.item = item
        self.localPath = localPath
        self.worktreeDir = worktreeDir
        self.mode = mode
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
    /// Claude's usage for the analysis and the fixes (spec O; the chat keeps its own). Nil in older history files.
    public var usage: ClaudeUsage?
    /// La pidió un iPhone (spec M.4); nil = desde la Mac o un registro viejo.
    public var requestedOnPhone: Bool?
    /// The Claude sessions of the fixes or the Fix CI (spec T.2). Nil in older history files.
    public var sessions: [ClaudeSessionRef]?

    public init(draft: RespondDraft, selections: [String: RespondSelection] = [:], result: RespondResult? = nil,
                posted: [String: PostedReply] = [:], pushed: Bool = false, startedAt: Date, finishedAt: Date? = nil,
                errorMessage: String? = nil, chat: ChatSession? = nil, usage: ClaudeUsage? = nil,
                requestedOnPhone: Bool? = nil, sessions: [ClaudeSessionRef]? = nil) {
        self.draft = draft
        self.selections = selections
        self.result = result
        self.posted = posted
        self.pushed = pushed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.errorMessage = errorMessage
        self.chat = chat
        self.usage = usage
        self.requestedOnPhone = requestedOnPhone
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case draft, selections, result, posted, pushed, startedAt, finishedAt, errorMessage, chat, usage, requestedOnPhone
        case sessions
    }

    /// The run and its chat (spec O.4.4); nil if neither has data (older history files).
    public var totalUsage: ClaudeUsage? { ClaudeUsage.sum([usage, chat?.usage]) }

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
        usage = (try? c.decodeIfPresent(ClaudeUsage.self, forKey: .usage)) ?? nil
        requestedOnPhone = try c.decodeIfPresent(Bool.self, forKey: .requestedOnPhone)
        sessions = (try? c.decodeIfPresent([ClaudeSessionRef].self, forKey: .sessions)) ?? nil
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

/// Fix CI (spec K.6.6): todos los checks que habían fallado pasan ahora en el mismo head; no se pushea salvo "Push Anyway".
public struct CIPassingNow: Error, Equatable, LocalizedError {
    public let checks: [String]
    public let headOid: String

    public init(checks: [String], headOid: String) {
        self.checks = checks
        self.headOid = headOid
    }

    public var errorDescription: String? {
        "The checks that failed (\(CILogs.nameList(checks))) pass now on \(headOid.prefix(7)), so PRBar didn’t push. "
            + "Push anyway, or dismiss the fix."
    }
}

extension RespondPipelineRunning {
    public func checkCIBeforePush(draft: RespondDraft, result: RespondResult?, ignoringPassingChecks: Bool) async throws {}
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
    /// A pushed run whose worktree is kept for "Open in Terminal" (spec T.3): the worktree and its ref stay, it stops
    /// counting as in use, and the Mac-side copy of a runner's fixes (temporary clone, `refs/prbar/remote-…`) goes.
    /// Never throws.
    func release(draft: RespondDraft) async
    /// Fix CI (K.4) y Resolve Conflicts (C.3.6), justo antes del push. Fix CI: el head del PR en GitHub sigue siendo
    /// el que falló y (salvo `ignoringPassingChecks`, "Push Anyway") el CI no pasó: si todos los checks que fallaron
    /// pasan ahora, lanza `CIPassingNow`. Resolve Conflicts: el PR sigue abierto, con el mismo head y la misma base.
    /// Un Respond normal no verifica nada. Si el head en GitHub ya es `result.headOid`, un push anterior llegó sin
    /// quedar anotado: no se verifica más y el push lo reconoce (`RespondPublisher`, `ls-remote`).
    func checkCIBeforePush(draft: RespondDraft, result: RespondResult?, ignoringPassingChecks: Bool) async throws
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
    public static let alreadyContainsBaseMessage = "The PR already contains its base branch: there’s nothing to merge. GitHub may not have updated yet; refresh in a minute."
    public static let needsLocalPathMessage = "This repo needs a local folder to respond."
    public static let noFailingChecksMessage = "No failing checks on the PR’s latest commit: CI may have passed or still be running. Refresh and try again."

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
    /// El disco del worktree (para el guardián y la cancelación): esta Mac o el host del trabajo.
    private let workspaceFS: any WorkspaceFS
    /// El host donde corre todo lo de Claude (worktree, análisis, fixes, tests); nil = esta Mac. GitHub y el push
    /// siguen en la Mac: los fixes vuelven con `importer` (decisión J.7.9).
    private let placement: RemotePlacement?
    private let importer: RemoteFixImport?
    /// Los checks y logs de Fix CI (spec K); nil = el `api`, si los sabe pedir.
    private let ciAPI: (any CIChecksAPI)?

    /// `worktreeRoot`: donde van las carpetas de contexto (`AppPaths.worktreesDir`). `gitEnvironment` se suma
    /// al de cada git (los tests aíslan la configuración global). `logURLProvider` recibe el id del draft.
    /// `originMatches`: ver `WorktreeResolver` (los tests lo reemplazan porque sus remotos son carpetas locales).
    public init(
        processRunner: ProcessRunning, streamingRunner: StreamingProcessRunning, tokens: TokenProviding, api: GitHubAPI,
        gitPath: String, claudePath: String, worktreeRoot: URL = AppPaths.worktreesDir,
        pluginCacheDirectory: URL = ClaudePlugins.defaultCacheDirectory, settings: ClaudeSettings = ClaudeSettings(),
        rules: [Rule] = [], gitEnvironment: [String: String] = [:],
        logURLProvider: @escaping @Sendable (UUID) -> URL,
        originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) },
        workspaceFS: any WorkspaceFS = LocalWorkspaceFS(),
        placement: RemotePlacement? = nil, importer: RemoteFixImport? = nil, ciAPI: (any CIChecksAPI)? = nil
    ) {
        self.ciAPI = ciAPI ?? (api as? any CIChecksAPI)
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
        self.placement = placement
        // Con un host, el disco del trabajo es el del host.
        self.workspaceFS = placement?.fs ?? workspaceFS
        self.importer = importer ?? placement.map {
            RemoteFixImport(spaces: $0.workspaces, localGit: gitPath, gitEnvironment: gitEnvironment, originMatches: originMatches)
        }
    }

    public func logURL(for id: UUID) -> URL { logURLProvider(id) }

    // MARK: - Análisis

    public func analyze(_ request: RespondRequest, draftID: UUID,
                        onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        if request.mode == .conflicts { return try await analyzeConflicts(request, draftID: draftID) }
        if request.mode == .ciFix { return try await analyzeCI(request, draftID: draftID) }
        let item = request.item
        let pr = item.pr
        let token = try await tokens.token(for: item.account)
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        if feedback.isCrossRepository { throw PRBarError.respond(Self.forkMessage) }
        let items = FeedbackFilter.select(feedback, me: item.account)
        guard !items.isEmpty else { throw PRBarError.respond(Self.noItemsMessage) }
        // On demand (the refresh doesn't bring it): context for Claude and the language of the replies.
        let description = try await ReviewPipeline.description(of: pr, api: api, token: token)
        let headRef = feedback.headRefName
        let pluginDirs: [String]
        let worktree: ResolvedWorktree
        let startHeadOid: String
        if let remote = placement {
            pluginDirs = try await remote.plugins(skills: settings.respondSkills)
            try Task.checkCancellation()
            // Siempre un worktree propio y separado en el host, del mirror de PRBar (también sin `localPath`).
            (worktree, startHeadOid) = try await remote.preparing {
                let bare = try await remote.workspaces.mirror(pr.repo)
                return try await remote.workspaces.prepareRespond(localPath: bare, repo: pr.repo, number: pr.number, headRef: headRef,
                                                                  worktreeDir: nil)
            }
        } else {
            guard let localPath = request.localPath, !localPath.isEmpty else { throw PRBarError.respond(Self.needsLocalPathMessage) }
            pluginDirs = try ClaudePlugins.locate(skills: settings.respondSkills, in: pluginCacheDirectory)
            try Task.checkCancellation()
            // Siempre un worktree propio y separado; su commit es la base de todo lo que sigue.
            (worktree, startHeadOid) = try await resolver.prepare(
                localPath: localPath, repo: pr.repo, number: pr.number, headRef: headRef, worktreeDir: request.worktreeDir)
        }
        let worktreeURL = URL(fileURLWithPath: worktree.path, isDirectory: true)
        do {
            try Task.checkCancellation()
            return try await analyze(item: item, items: items, headRef: headRef, worktree: worktree, worktreeURL: worktreeURL,
                                     startHeadOid: startHeadOid, pluginDirs: pluginDirs, token: token, draftID: draftID,
                                     description: description, localPath: request.localPath, onPhase: onPhase)
        } catch {
            // Sin draft no hay nada que revisar: el worktree se borra (fuera de esta tarea, que puede estar cancelada).
            // Salvo si Claude puede seguir corriendo en el host: ahí no se toca.
            if RemoteUnstoppedJobs.isNotStopped(error) {
                AppLog.write("Respond: Claude may still be running in \(worktree.path); leaving it as is.")
                throw error
            }
            let pipeline = self
            await Task.detached { await pipeline.removeWorktree(worktree) }.value
            throw error
        }
    }

    // MARK: - Fix CI (spec K)

    /// Token → head y checks del PR (en la Mac) → logs de Actions (sin token en la redirección) → worktree en el head que
    /// falló (acá o en el host) → draft con un solo ítem. Sin Claude: la implementación arranca después (K.6.3).
    private func analyzeCI(_ request: RespondRequest, draftID: UUID) async throws -> RespondDraft {
        let item = request.item
        let pr = item.pr
        guard let ciAPI else { throw PRBarError.respond("PRBar can’t read this PR’s checks.") }
        let token = try await tokens.token(for: item.account)
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        if feedback.isCrossRepository { throw PRBarError.respond(Self.forkMessage) }
        let head = feedback.headRefOid
        let runs = try await ciAPI.checkRuns(repo: pr.repo, headOid: head, token: token)
        let failing = CILogs.failing(runs)
        guard !failing.isEmpty else { throw PRBarError.respond(Self.noFailingChecksMessage) }
        var logs: [Int: String] = [:]
        for run in failing.prefix(CILogs.maxChecks) where run.isActions {
            try Task.checkCancellation()
            guard let id = run.id else { continue }
            do {
                logs[id] = try await ciAPI.actionsJobLog(repo: pr.repo, jobID: id, token: token)
            } catch {
                // Sin log (expirado, sin permiso): Claude ve el resumen del check.
                AppLog.write("Fix CI: couldn't download the log of \(run.name) on \(pr.repo.fullName)#\(pr.number): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        let (worktree, startHeadOid) = try await prepareWorktree(request, headRef: feedback.headRefName)
        // Cancelado justo cuando terminaba de armarlo: nadie va a recibir el draft, así que el worktree se borra acá (L1).
        if Task.isCancelled {
            await Task.detached { [self] in await removeWorktree(worktree) }.value
            throw CancellationError()
        }
        guard startHeadOid == head else {
            await Task.detached { [self] in await removeWorktree(worktree) }.value
            throw PRBarError.respond("The PR got new commits while PRBar was reading its CI (now at \(startHeadOid.prefix(7))). Try Fix CI again.")
        }
        let (ciItem, context) = CIFixItem.make(headOid: head, failing: failing, logs: logs, secrets: [token], prURL: pr.url,
                                               total: Set(runs.map { $0.name.lowercased() }).count)
        return RespondDraft(
            id: draftID, prID: item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
            headRef: feedback.headRefName, account: item.account, worktree: worktree, startHeadOid: startHeadOid,
            items: [ciItem], runner: placement?.name, localPath: placement == nil ? nil : request.localPath,
            mode: .ciFix, ci: context)
    }

    public func checkCIBeforePush(draft: RespondDraft, result: RespondResult?, ignoringPassingChecks: Bool) async throws {
        if draft.isConflicts { return try await checkConflictsBeforePush(draft, reviewed: result?.headOid) }
        guard draft.isCIFix, let context = draft.ci else { return }
        guard let ciAPI else { throw PRBarError.respond("PRBar can’t read this PR’s checks.") }
        let token = try await tokens.token(for: draft.account)
        let details = try await api.pullRequestDetails(repo: draft.repo, number: draft.number, token: token)
        if let state = details.state, state != .open {
            throw PRBarError.respond("The PR isn’t open anymore. Not pushing.")
        }
        // Ya pusheado (lo revisado está en GitHub): los checks que fallaron eran de otro head.
        if let head = details.headOid, head == result?.headOid { return }
        guard let head = details.headOid, head == draft.startHeadOid else {
            throw PRBarError.respond("The PR has new commits since Fix CI read its checks"
                + "\(details.headOid.map { " (now at \($0.prefix(7)))" } ?? ""). Not pushing: run Fix CI again.")
        }
        guard !ignoringPassingChecks else { return }
        let runs = try await ciAPI.checkRuns(repo: draft.repo, headOid: head, token: token)
        guard CILogs.stillFailing(context.checkNames, now: runs) else {
            throw CIPassingNow(checks: context.checkNames, headOid: head)
        }
    }

    // MARK: - Resolve Conflicts (spec C)

    /// Spec C.3.6 (decisión C.9.2): el PR sigue abierto, con el mismo head que se mergeó (o ya con el merge revisado,
    /// `reviewed`: un push anterior que llegó sin quedar anotado) y la misma base.
    private func checkConflictsBeforePush(_ draft: RespondDraft, reviewed: String?) async throws {
        guard let context = draft.conflicts else {
            throw PRBarError.respond("This Resolve Conflicts run has no merge to push. Start Resolve Conflicts again.")
        }
        let token = try await tokens.token(for: draft.account)
        let details = try await api.pullRequestDetails(repo: draft.repo, number: draft.number, token: token)
        if let state = details.state, state != .open { throw PRBarError.respond("The PR isn’t open anymore. Not pushing.") }
        guard let head = details.headOid, head == draft.startHeadOid || head == reviewed else {
            throw PRBarError.respond("The PR has new commits since PRBar merged \(context.baseRef)"
                + "\(details.headOid.map { " (now at \($0.prefix(7)))" } ?? ""). Not pushing: run Resolve Conflicts again.")
        }
        if let base = details.baseRef, base != context.baseRef {
            throw PRBarError.respond("The PR’s base is now \(base), not \(context.baseRef). Not pushing: run Resolve Conflicts again.")
        }
    }

    /// Token → head (feedback, fork) y base (detalles) en la Mac → worktree en el head (acá o en el host) → base a su ref
    /// propia → `merge --no-commit` → draft con un solo ítem. Sin Claude: la implementación arranca después, sola.
    private func analyzeConflicts(_ request: RespondRequest, draftID: UUID) async throws -> RespondDraft {
        let item = request.item
        let pr = item.pr
        let token = try await tokens.token(for: item.account)
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        if feedback.isCrossRepository { throw PRBarError.respond(Self.forkMessage) }
        let details = try await api.pullRequestDetails(repo: pr.repo, number: pr.number, token: token)
        if let state = details.state, state != .open { throw PRBarError.respond("The PR isn’t open anymore.") }
        let baseRef = details.baseRef ?? pr.baseRef
        try Task.checkCancellation()
        let (worktree, startHeadOid) = try await prepareWorktree(request, headRef: feedback.headRefName)
        do {
            try Task.checkCancellation()
            guard startHeadOid == feedback.headRefOid else {
                throw PRBarError.respond("The PR got new commits while PRBar was preparing it (now at \(startHeadOid.prefix(7))). "
                    + "Try Resolve Conflicts again.")
            }
            let baseOid: String
            if let remote = placement {
                baseOid = try await remote.workspaces.fetchRespondBase(worktree, repo: pr.repo, baseRef: baseRef)
            } else {
                baseOid = try await resolver.fetchBase(worktree, baseRef: baseRef)
            }
            let merger = await conflictMerger(worktree, localPath: request.localPath)
            let outcome = try await merger.merge(baseRef: baseRef, baseOid: baseOid, startHeadOid: startHeadOid)
            let conflictsItem = ConflictsItem.make(startHeadOid: startHeadOid, context: outcome.context, description: details.body,
                                                   incomingLog: outcome.incomingLog, prDiff: outcome.prDiff,
                                                   diffTruncated: outcome.prDiffTruncated, prURL: pr.url)
            return RespondDraft(
                id: draftID, prID: item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url,
                headRef: feedback.headRefName, account: item.account, worktree: worktree, startHeadOid: startHeadOid,
                items: [conflictsItem], runner: placement?.name, localPath: placement == nil ? nil : request.localPath,
                mode: .conflicts, conflicts: outcome.context)
        } catch {
            // Sin draft no hay nada que revisar: el worktree (a mitad del merge) y sus refs se borran fuera de esta tarea.
            await Task.detached { [self] in await removeWorktree(worktree) }.value
            throw error
        }
    }

    /// git endurecido en el worktree del trabajo (acá o en el host), sin lanzar por el código de salida. `merge` pide
    /// la identidad de commit aunque no commitee: en el host va la de la Mac, como en los commits (decisión J.7.5).
    private func conflictMerger(_ worktree: ResolvedWorktree, localPath: String?) async -> ConflictMerger {
        let runner = placement?.runner ?? processRunner
        let git = placement?.gitPath ?? gitPath
        var environment = (placement?.gitEnvironment ?? gitEnvironment).merging(GitHardening.environment) { _, hardened in hardened }
        if placement != nil {
            let identity = await Self.commitIdentity(runner: processRunner, gitPath: gitPath, localPath: localPath,
                                                     environment: gitEnvironment)
            environment.merge(identity) { _, new in new }
        }
        let path = worktree.path
        return ConflictMerger { [environment] arguments in
            try await runner.run(git, ["-C", path] + GitHardening.arguments + arguments, environment: environment,
                                 currentDirectory: nil, timeout: WorktreeManager.slowTimeout)
        }
    }

    /// El worktree propio de PRBar en la rama del PR: en el host (de su mirror) o en el clone local.
    private func prepareWorktree(_ request: RespondRequest, headRef: String) async throws -> (ResolvedWorktree, String) {
        let pr = request.item.pr
        if let remote = placement {
            return try await remote.preparing {
                let bare = try await remote.workspaces.mirror(pr.repo)
                return try await remote.workspaces.prepareRespond(localPath: bare, repo: pr.repo, number: pr.number, headRef: headRef,
                                                                  worktreeDir: nil)
            }
        }
        guard let localPath = request.localPath, !localPath.isEmpty else { throw PRBarError.respond(Self.needsLocalPathMessage) }
        return try await resolver.prepare(localPath: localPath, repo: pr.repo, number: pr.number, headRef: headRef,
                                          worktreeDir: request.worktreeDir)
    }

    /// Las etapas siguientes corren donde corrió el análisis (decisión J.7.10): nunca un worktree del host con git de
    /// esta Mac ni al revés.
    private func checkRunner(_ draft: RespondDraft) throws {
        guard draft.runner?.lowercased() != placement?.name.lowercased() else { return }
        if let runner = draft.runner {
            throw PRBarError.respond("This analysis ran on \(runner), which isn’t available now. Analyze the PR again.")
        }
        throw PRBarError.respond("This analysis ran on this Mac. Analyze the PR again.")
    }

    /// El worktree de PRBar (en esta Mac o en el host). Nunca lanza.
    private func removeWorktree(_ worktree: ResolvedWorktree) async {
        if let remote = placement {
            await remote.workspaces.cleanupRespond(worktree)
        } else {
            await resolver.cleanup(worktree)
        }
    }

    private func analyze(item: ClassifiedPR, items: [FeedbackItem], headRef: String, worktree: ResolvedWorktree,
                         worktreeURL: URL, startHeadOid: String, pluginDirs: [String], token: String, draftID: UUID,
                         description: String?, localPath: String?, onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        let pr = item.pr
        let language = PRLanguage.detect(description: description, title: pr.title)

        await onPhase(.analyzing(agents: 0))
        let contextName = "\(pr.repo.owner)-\(pr.repo.name)-\(pr.number)-\(draftID.uuidString).respond-context"
        let contextDir: URL
        let files: any ContextFiles
        if let remote = placement {
            contextDir = URL(fileURLWithPath: try remote.root.child(["work", contextName]), isDirectory: true)
            files = remote.workspaces.contextFiles
        } else {
            contextDir = worktreeRoot.appendingPathComponent(contextName, isDirectory: true)
            files = LocalContextFiles()
            WorkspaceRegistry.shared.insert(contextDir.path)
        }
        let analyzer = RespondAnalyzer(claude: claude(pluginDirs: pluginDirs, token: token, logURL: logURL(for: draftID)),
                                       settings: settings, rules: rules, files: files)
        let relay = MainActorRelay<Int> { agents in onPhase(.analyzing(agents: agents)) }
        let analyzed: [RespondItem]
        let removeContext: @Sendable () async -> Void = { [placement] in
            await Task.detached { await files.removeTree(contextDir.path) }.value
            if placement == nil { WorkspaceRegistry.shared.remove(contextDir.path) }
        }
        do {
            analyzed = try await analyzer.analyze(pr: pr, items: items, worktree: worktreeURL, contextDir: contextDir,
                                                 description: description ?? "", language: language) { relay.send($0) }
        } catch {
            await relay.finish()
            // Si Claude puede seguir corriendo en el host, su carpeta de contexto también queda.
            if !RemoteUnstoppedJobs.isNotStopped(error) { await removeContext() }
            throw error
        }
        await removeContext()
        await relay.finish()
        try Task.checkCancellation()

        return RespondDraft(
            id: draftID, prID: item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, headRef: headRef,
            account: item.account, worktree: worktree, startHeadOid: startHeadOid, items: analyzed, language: language,
            runner: placement?.name, localPath: placement == nil ? nil : localPath)
    }

    // MARK: - Fixes y tests

    public func implement(draft: RespondDraft, selections: [String: RespondSelection],
                          onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult {
        guard draft.worktree.origin == .dedicated else {
            throw PRBarError.respond("This analysis is from an older version of PRBar. Analyze the PR again.")
        }
        try checkRunner(draft)
        try ensureStopped(draft)
        let token = try await tokens.token(for: draft.account)
        // Fix CI y Conflicts no nombran skills (spec K.3, C.9): no hay plugins que cargar.
        let skills = draft.implementsAlone ? [] : settings.respondSkills
        let pluginDirs: [String]
        if let remote = placement {
            pluginDirs = try await remote.plugins(skills: skills)
        } else {
            pluginDirs = try ClaudePlugins.locate(skills: skills, in: pluginCacheDirectory)
        }
        let implementer = await fixImplementer(claude: claude(pluginDirs: pluginDirs, token: token, logURL: logURL(for: draft.id)),
                                               draft: draft)
        do {
            let result = try await implementer.implement(draft: draft, selections: selections, onProgress: onProgress)
            guard let importer else { return result }
            // El diff, los commits y los sensibles que ve el usuario se calculan en la Mac desde los objetos traídos.
            return try await importer.importFixes(draft: draft, localPath: draft.localPath, items: result.items,
                                                  integrity: result.gitIntegrity, token: token)
        } catch {
            // Claude puede seguir corriendo en el host: el error lo dice (también si fue un Stop), y nada mira el worktree.
            if RemoteUnstoppedJobs.isNotStopped(error) { throw error }
            guard error is CancellationError || Task.isCancelled else { throw error }
            // `FixImplementer` ya restauró el árbol (en su propia tarea). Lo que queda se mira fuera de esta tarea
            // cancelada, que no puede lanzar procesos.
            let pipeline = self
            throw await Task.detached { await pipeline.cancellation(of: draft) }.value
        }
    }

    /// Cuenta los commits nuevos (`startHeadOid..HEAD`) y si el árbol quedó sucio, con git endurecido. Si apareció
    /// un `.git` anidado no corre ningún git: no se sabe cuántos commits quedaron y el árbol cuenta como sucio.
    /// Con el `WorkspaceFS` del trabajo; un draft de un host sin el `WorkspaceFS` de ese host (solo el de esta Mac)
    /// no se mira: cuenta como cambiado y sin commits conocidos.
    /// En un host: nada nuevo corre en el worktree mientras Claude puede seguir ahí (J.7.15).
    private func ensureStopped(_ draft: RespondDraft) throws {
        guard let remote = placement else { return }
        try RemoteUnstoppedJobs.shared.ensureStopped(host: remote.name, path: draft.worktree.path)
    }

    public func cancellation(of draft: RespondDraft) async -> RespondCancellation {
        let worktree = URL(fileURLWithPath: draft.worktree.path, isDirectory: true)
        let unknown = RespondCancellation(unpushedCommits: nil, path: draft.worktree.path, dirty: true)
        if draft.runner != nil && workspaceFS is LocalWorkspaceFS { return unknown }
        if let remote = placement, RemoteUnstoppedJobs.shared.contains(host: remote.name, path: draft.worktree.path) { return unknown }
        // A nested repo in a folder git ignores (left by the test command) doesn't count; anything else runs no git.
        guard let nested = try? await workspaceFS.nestedGits(worktree.path),
              let repositories = try? FixImplementer.pendingNestedRepos(nested, allowed: [], allowIgnored: true, worktree: worktree),
              let unignored = try? await FixImplementer.unignoredRepositories(repositories, git: { arguments in
                  try await (self.placement?.runner ?? self.processRunner).run(
                      self.placement?.gitPath ?? self.gitPath, ["-C", worktree.path] + GitHardening.arguments + arguments,
                      environment: self.placement?.gitEnvironment ?? self.gitEnvironment, currentDirectory: nil,
                      timeout: ProcessTimeouts.standard)
              }), unignored.isEmpty else { return unknown }
        let count = try? await git(worktree, ["rev-list", "--count", "\(draft.startHeadOid)..HEAD"])
        let status = try? await git(worktree, ["status", GitHardening.ignoreSubmodules, "--porcelain", "--untracked-files=all"])
        return RespondCancellation(
            unpushedCommits: count.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            path: draft.worktree.path,
            dirty: status.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
    }

    public func runTests(draft: RespondDraft, testCommand: String) async -> TestRun {
        do {
            try checkRunner(draft)
            try ensureStopped(draft)
        } catch {
            return TestRun(command: testCommand, passed: false, outputTail: error.localizedDescription)
        }
        // Sin plugins ni Claude: el runner solo se usa para escribir el log de la corrida.
        let implementer = await fixImplementer(
            claude: ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: [],
                                 environment: [:], logURL: logURL(for: draft.id), redacting: []),
            draft: draft)
        return await implementer.runTests(worktree: URL(fileURLWithPath: draft.worktree.path, isDirectory: true),
                                          testCommand: testCommand)
    }

    // MARK: - Push y respuestas

    public func push(draft: RespondDraft, result: RespondResult) async throws {
        try checkRunner(draft)
        try ensureStopped(draft)
        if let importer, placement != nil {
            // Desde la Mac, después de verificar de nuevo lo traído del host (decisión J.7.9).
            try await importer.push(draft: draft, result: result, token: try await tokens.token(for: draft.account))
            return
        }
        try await publisher.push(draft: draft, result: result)
    }

    public func cleanup(draft: RespondDraft) async {
        guard (try? checkRunner(draft)) != nil else {
            AppLog.write("Respond: not cleaning up \(draft.worktree.path): it ran on \(draft.runner ?? "this Mac").")
            return
        }
        await removeWorktree(draft.worktree)
        if let importer, placement != nil { await importer.discard(draft: draft) }
    }

    public func release(draft: RespondDraft) async {
        WorkspaceRegistry.shared.remove(draft.worktree.path)
        guard (try? checkRunner(draft)) != nil else {
            AppLog.write("Respond: not releasing \(draft.worktree.path): it ran on \(draft.runner ?? "this Mac").")
            return
        }
        if let importer, placement != nil { await importer.discard(draft: draft) }
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

    /// El `FixImplementer` del trabajo: en esta Mac, o en el host (git y Claude allá, el guardián Perl, los tests con
    /// `/bin/sh -lc` y el entorno de login del host, decisión J.7.13).
    private func fixImplementer(claude: ClaudeRunner, draft: RespondDraft) async -> FixImplementer {
        guard let remote = placement else {
            return FixImplementer(claude: claude, runner: processRunner, gitPath: gitPath, environment: gitEnvironment,
                                  settings: settings, rules: rules, fs: workspaceFS)
        }
        let identity = await Self.commitIdentity(runner: processRunner, gitPath: gitPath, localPath: draft.localPath,
                                                 environment: gitEnvironment)
        return FixImplementer(claude: claude, runner: remote.runner, gitPath: remote.gitPath,
                              environment: remote.gitEnvironment.merging(identity) { _, new in new },
                              settings: settings, rules: rules, fs: remote.fs, testShell: "/bin/sh",
                              testRunner: RemoteLoginRunner(host: remote.host, root: remote.root))
    }

    /// La identidad de commit de la Mac (`git config user.name`/`user.email`, del clone si hay; si no, la global) para
    /// los commits del host (decisión J.7.5; no es un secreto). Vacía si no hay.
    static func commitIdentity(runner: ProcessRunning, gitPath: String, localPath: String?,
                               environment: [String: String]) async -> [String: String] {
        func value(_ key: String) async -> String? {
            let args = (localPath.map { ["-C", $0] } ?? []) + ["config", "--get", key]
            guard let result = try? await runner.run(gitPath, args, environment: environment, currentDirectory: nil,
                                                     timeout: ProcessTimeouts.standard), result.status == 0 else { return nil }
            let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 200, !text.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
            return text
        }
        var identity: [String: String] = [:]
        if let name = await value("user.name") {
            identity["GIT_AUTHOR_NAME"] = name
            identity["GIT_COMMITTER_NAME"] = name
        }
        if let email = await value("user.email") {
            identity["GIT_AUTHOR_EMAIL"] = email
            identity["GIT_COMMITTER_EMAIL"] = email
        }
        return identity
    }

    private func claude(pluginDirs: [String], token: String, logURL: URL) -> ClaudeRunner {
        if let remote = placement {
            return remote.claude(pluginDirs: pluginDirs, logURL: logURL, secrets: [token], model: settings.model)
        }
        return ClaudeRunner(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs,
                     environment: ClaudeRunner.environment(toolPaths: [gitPath, claudePath]),
                     logURL: logURL, redacting: [token], model: settings.model)
    }

    private func git(_ worktree: URL, _ arguments: [String]) async throws -> String {
        let args = ["-C", worktree.path] + GitHardening.arguments + arguments
        // En el worktree del trabajo: el del host corre allá.
        let result = try await (placement?.runner ?? processRunner).run(
            placement?.gitPath ?? gitPath, args, environment: placement?.gitEnvironment ?? gitEnvironment, currentDirectory: nil,
            timeout: ProcessTimeouts.standard)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "),
                                           status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }
}
