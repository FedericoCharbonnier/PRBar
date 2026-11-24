import Foundation
import PRBarCore

/// Pipeline de "Responder" de la app. Igual que `LiveReviewPipeline`, las rutas de `git` y `claude` no se fijan al
/// crear la cola: cada etapa lee el `tools` actual de `AppModel` en el main actor y arma un `RespondPipeline`.
/// El análisis corre donde dice el repo (con fallback antes de que arranque Claude); las etapas siguientes, en el host
/// del análisis (`draft.runner`), nunca con fallback. Las respuestas en GitHub siempre salen de esta Mac.
struct LiveRespondPipeline: RespondPipelineRunning {
    let runner: SystemProcessRunner
    let tokens: TokenProviding
    let api: GitHubAPI
    let history: RespondHistory
    /// El contexto para la cuenta y el repo del PR.
    let context: @MainActor @Sendable (_ account: String, _ repo: RepoRef) -> ReviewContext
    /// Runner de Claude: 5 s entre SIGTERM y SIGKILL al grupo de procesos, como en el review.
    let claudeRunner = SystemProcessRunner(killGracePeriod: 5)

    func logURL(for id: UUID) -> URL { history.logURL(for: id) }

    func analyze(_ request: RespondRequest, draftID: UUID,
                 onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        let context = await context(request.item.account, request.item.pr.repo)
        // Que la limpieza de huérfanos del arranque termine antes de tocar los repos.
        await context.orphanCleanup?.value
        try Task.checkCancellation()
        let prID = request.item.id
        // Sin carpeta local, git o claude en esta Mac no hay a dónde caer: el error del host.
        return try await RunnerDispatch.run(
            destination: context.runner, coordinator: context.coordinator,
            canRunLocally: !(request.localPath ?? "").isEmpty && context.tools.git != nil && context.tools.claude != nil,
            onPlacement: { await context.onPlacement(prID, $0) },
            local: { try await pipeline(context).analyze(request, draftID: draftID, onPhase: onPhase) },
            remote: { try await pipeline(context, placement: $0).analyze(request, draftID: draftID, onPhase: onPhase) })
    }

    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult {
        try await pinned(draft) { try await $0.implement(draft: draft, selections: selections, onProgress: onProgress) }
    }

    func runTests(draft: RespondDraft, testCommand: String) async -> TestRun {
        do {
            return try await pinned(draft, needsClaude: false) { await $0.runTests(draft: draft, testCommand: testCommand) }
        } catch {
            return TestRun(command: testCommand, passed: false, outputTail: error.localizedDescription)
        }
    }

    func push(draft: RespondDraft, result: RespondResult) async throws {
        try await pinned(draft, needsClaude: false) { try await $0.push(draft: draft, result: result) }
    }

    /// Siempre en esta Mac: es GitHub (spec K.4).
    func checkCIBeforePush(draft: RespondDraft, ignoringPassingChecks: Bool) async throws {
        try await pipeline(await context(draft.account, draft.repo), needsClaude: false).checkCIBeforePush(draft: draft, ignoringPassingChecks: ignoringPassingChecks)
    }

    func cleanup(draft: RespondDraft) async {
        do {
            try await pinned(draft, needsClaude: false, reports: false) { await $0.cleanup(draft: draft) }
        } catch {
            AppLog.write("Respond: couldn’t clean up \(draft.worktree.path)\(draft.runner.map { " on \($0)" } ?? ""): \(error.localizedDescription)")
        }
    }

    func release(draft: RespondDraft) async {
        // Esta Mac deja de contarlo como en uso aunque el runner no esté.
        WorkspaceRegistry.shared.remove(draft.worktree.path)
        do {
            try await pinned(draft, needsClaude: false, reports: false) { await $0.release(draft: draft) }
        } catch {
            AppLog.write("Respond: couldn’t release \(draft.worktree.path)\(draft.runner.map { " on \($0)" } ?? ""): \(error.localizedDescription)")
        }
    }

    /// Siempre en esta Mac: es GitHub.
    func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                     alreadyPosted: [String: PostedReply],
                     onPosted: @escaping @Sendable (String, PostedReply) async -> Void) async -> (posted: [String: PostedReply], error: Error?) {
        let pipeline: RespondPipeline
        do {
            pipeline = try self.pipeline(await context(draft.account, draft.repo), needsClaude: false)
        } catch {
            return (alreadyPosted, error)
        }
        return await pipeline.postReplies(draft: draft, selections: selections, result: result,
                                          alreadyPosted: alreadyPosted, onPosted: onPosted)
    }

    /// Una etapa después del análisis: en esta Mac o en el host del análisis (verificado, sin fallback).
    /// `reports == false`: no cambia lo que muestra la fila (la limpieza).
    private func pinned<T: Sendable>(_ draft: RespondDraft, needsClaude: Bool = true, reports: Bool = true,
                                     _ body: @escaping @Sendable (RespondPipeline) async throws -> T) async throws -> T {
        let context = await context(draft.account, draft.repo)
        let prID = draft.prID
        return try await RunnerDispatch.pinned(
            runner: draft.runner, settings: context.runnerSettings, coordinator: context.coordinator,
            onPlacement: { if reports { await context.onPlacement(prID, $0) } },
            local: { try await body(try pipeline(context, needsClaude: needsClaude)) },
            remote: { try await body(try pipeline(context, needsClaude: false, placement: $0)) })
    }

    /// Push, respuestas y tests no usan Claude: alcanza con git. En un host, el `claude` es el de allá; el git de esta
    /// Mac trae los fixes y pushea.
    private func pipeline(_ context: ReviewContext, needsClaude: Bool = true, placement: RemotePlacement? = nil) throws -> RespondPipeline {
        let tools = context.tools
        guard let git = tools.git else { throw PRBarError.toolNotFound("git") }
        if needsClaude && tools.claude == nil { throw PRBarError.toolNotFound("claude") }
        let claude = placement?.claudePath ?? tools.claude ?? "claude"
        let history = self.history
        return RespondPipeline(
            processRunner: runner, streamingRunner: claudeRunner, tokens: tokens, api: api,
            gitPath: git, claudePath: claude, settings: context.claude, rules: context.rules,
            logURLProvider: { history.logURL(for: $0) }, placement: placement)
    }
}
