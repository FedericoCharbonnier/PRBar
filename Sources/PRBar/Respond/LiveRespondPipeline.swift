import Foundation
import PRBarCore

/// Pipeline de "Responder" de la app. Igual que `LiveReviewPipeline`, las rutas de `git` y `claude` no se fijan al
/// crear la cola: cada etapa lee el `tools` actual de `AppModel` en el main actor y arma un `RespondPipeline`.
struct LiveRespondPipeline: RespondPipelineRunning {
    let runner: SystemProcessRunner
    let tokens: TokenProviding
    let api: GitHubAPI
    let history: RespondHistory
    let context: @MainActor @Sendable () -> ReviewContext
    /// Runner de Claude: 5 s entre SIGTERM y SIGKILL al grupo de procesos, como en el review.
    let claudeRunner = SystemProcessRunner(killGracePeriod: 5)

    func logURL(for id: UUID) -> URL { history.logURL(for: id) }

    func analyze(_ request: RespondRequest, draftID: UUID,
                 onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void) async throws -> RespondDraft {
        let context = await context()
        // Que la limpieza de huérfanos del arranque termine antes de tocar los repos.
        await context.orphanCleanup?.value
        try Task.checkCancellation()
        return try await pipeline(context).analyze(request, draftID: draftID, onPhase: onPhase)
    }

    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void) async throws -> RespondResult {
        try await pipeline(await context()).implement(draft: draft, selections: selections, onProgress: onProgress)
    }

    func runTests(draft: RespondDraft, testCommand: String) async -> TestRun {
        let pipeline: RespondPipeline
        do {
            pipeline = try self.pipeline(await context(), needsClaude: false)
        } catch {
            return TestRun(command: testCommand, passed: false, outputTail: error.localizedDescription)
        }
        return await pipeline.runTests(draft: draft, testCommand: testCommand)
    }

    func push(draft: RespondDraft, result: RespondResult) async throws {
        try await pipeline(await context(), needsClaude: false).push(draft: draft, result: result)
    }

    func cleanup(draft: RespondDraft) async {
        guard let pipeline = try? pipeline(await context(), needsClaude: false) else { return }
        await pipeline.cleanup(draft: draft)
    }

    func postReplies(draft: RespondDraft, selections: [String: RespondSelection], result: RespondResult?,
                     alreadyPosted: [String: PostedReply],
                     onPosted: @escaping @Sendable (String, PostedReply) async -> Void) async -> (posted: [String: PostedReply], error: Error?) {
        let pipeline: RespondPipeline
        do {
            pipeline = try self.pipeline(await context(), needsClaude: false)
        } catch {
            return (alreadyPosted, error)
        }
        return await pipeline.postReplies(draft: draft, selections: selections, result: result,
                                          alreadyPosted: alreadyPosted, onPosted: onPosted)
    }

    /// Push, respuestas y tests no usan Claude: alcanza con git.
    private func pipeline(_ context: ReviewContext, needsClaude: Bool = true) throws -> RespondPipeline {
        let tools = context.tools
        guard let git = tools.git else { throw PRBarError.toolNotFound("git") }
        let claude = tools.claude ?? "claude"
        if needsClaude && tools.claude == nil { throw PRBarError.toolNotFound("claude") }
        let history = self.history
        return RespondPipeline(
            processRunner: runner, streamingRunner: claudeRunner, tokens: tokens, api: api,
            gitPath: git, claudePath: claude, settings: context.claude, logURLProvider: { history.logURL(for: $0) })
    }
}
