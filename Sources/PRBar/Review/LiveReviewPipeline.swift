import Foundation
import PRBarCore

/// Lo que el pipeline lee de `AppModel` (en el main actor) al arrancar cada review.
struct ReviewContext: Sendable {
    let tools: ResolvedTools
    let orphanCleanup: Task<Void, Never>?
    /// Skills, filtro y modelo de Configuración → Claude, leídos al arrancar cada corrida.
    let claude: ClaudeSettings
}

/// Pipeline de la app. Las rutas de `git` y `claude` se resuelven de forma asíncrona (y pueden cambiar desde
/// Configuración), así que no se fijan al crear la cola: cada review lee el `tools` actual de `AppModel`
/// en el main actor y arma un `ReviewPipeline` con esas rutas. No hay estado mutable compartido.
struct LiveReviewPipeline: ReviewPipelineRunning {
    let runner: SystemProcessRunner
    let tokens: TokenProviding
    let logURLProvider: @Sendable (UUID) -> URL
    let context: @MainActor @Sendable () -> ReviewContext
    /// Runner de Claude: spec §8.4 le da 5 s entre SIGTERM y SIGKILL (al grupo, con sus subagentes).
    let claudeRunner = SystemProcessRunner(killGracePeriod: 5)

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let context = await context()
        // Que la limpieza de huérfanos del arranque no borre el worktree de este review.
        await context.orphanCleanup?.value
        try Task.checkCancellation()
        guard let git = context.tools.git else { throw ReviewFailure(underlying: PRBarError.toolNotFound("git"), logURL: nil) }
        guard let claude = context.tools.claude else { throw ReviewFailure(underlying: PRBarError.toolNotFound("claude"), logURL: nil) }
        let pipeline = ReviewPipeline(
            processRunner: runner, streamingRunner: claudeRunner, tokens: tokens,
            gitPath: git, ghPath: context.tools.gh, claudePath: claude, settings: context.claude,
            logURLProvider: logURLProvider
        )
        return try await pipeline.run(request, onPhase: onPhase)
    }
}
