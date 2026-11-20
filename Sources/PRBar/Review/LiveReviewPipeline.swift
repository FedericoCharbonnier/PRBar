import Foundation
import PRBarCore

/// Avisa dónde corre el trabajo de un PR (`AppModel.recordPlacement`). Un alias: `ReviewContext` no es un control
/// de la UI (el inventario de paridad cuenta los structs con miembros `-> Void`).
typealias PlacementSink = @MainActor @Sendable (_ prID: String, _ placement: JobPlacement) -> Void

/// Lo que el pipeline lee de `AppModel` (en el main actor) al arrancar cada trabajo, para el repo del pedido.
struct ReviewContext: Sendable {
    let tools: ResolvedTools
    let orphanCleanup: Task<Void, Never>?
    /// Skills, filtro y modelo de Configuración → Claude, leídos al arrancar cada corrida.
    let claude: ClaudeSettings
    /// The user's rules (spec E.1), read when each run starts.
    var rules: [Rule] = []
    /// Dónde corre Claude para este repo (spec J; `RunTargetResolver`): `nil` = esta Mac.
    var runner: RunnerDestination?
    /// Los destinos configurados, para lo que ya corre en un host (`draft.runner`, `ChatSession.runner`).
    var runnerSettings = RunnerSettings()
    /// El coordinador de `AppModel` (comparte la caché de salud de los hosts).
    let coordinator: RunnerCoordinator
    /// Dónde corre el trabajo de cada PR ("on devbox", fallback): `AppModel.placements`.
    var onPlacement: PlacementSink = { _, _ in }
}

/// Pipeline de la app. Las rutas de `git` y `claude` se resuelven de forma asíncrona (y pueden cambiar desde
/// Configuración), así que no se fijan al crear la cola: cada review lee el `tools` actual de `AppModel`
/// en el main actor y arma un `ReviewPipeline` con esas rutas, en esta Mac o en el host del repo (spec J).
struct LiveReviewPipeline: ReviewPipelineRunning {
    let runner: SystemProcessRunner
    let tokens: TokenProviding
    let logURLProvider: @Sendable (UUID) -> URL
    /// El contexto para la cuenta y el repo del pedido.
    let context: @MainActor @Sendable (_ account: String, _ repo: RepoRef) -> ReviewContext
    /// Runner de Claude: spec §8.4 le da 5 s entre SIGTERM y SIGKILL (al grupo, con sus subagentes).
    let claudeRunner = SystemProcessRunner(killGracePeriod: 5)

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let context = await context(request.item.account, request.item.pr.repo)
        // Que la limpieza de huérfanos del arranque no borre el worktree de este review.
        await context.orphanCleanup?.value
        try Task.checkCancellation()
        let prID = request.item.id
        let (runner, claudeRunner, tokens, logURLProvider) = (self.runner, self.claudeRunner, self.tokens, self.logURLProvider)
        // Fallback a esta Mac solo antes de que arranque Claude: host caído o no listo, o falla de preparación
        // (`ReviewFailure.underlying` es `RemotePreparationFailure`).
        return try await RunnerDispatch.run(
            destination: context.runner, coordinator: context.coordinator,
            onPlacement: { await context.onPlacement(prID, $0) },
            local: {
                guard let git = context.tools.git else { throw ReviewFailure(underlying: PRBarError.toolNotFound("git"), logURL: nil) }
                guard let claude = context.tools.claude else { throw ReviewFailure(underlying: PRBarError.toolNotFound("claude"), logURL: nil) }
                return try await ReviewPipeline(
                    processRunner: runner, streamingRunner: claudeRunner, tokens: tokens,
                    gitPath: git, ghPath: context.tools.gh, claudePath: claude, settings: context.claude, rules: context.rules,
                    logURLProvider: logURLProvider
                ).run(request, onPhase: onPhase)
            },
            remote: { placement in
                // En el host: su git y su claude; el `gh` no se usa (el diff lo arma git en el host).
                try await ReviewPipeline(
                    processRunner: runner, streamingRunner: claudeRunner, tokens: tokens,
                    gitPath: context.tools.git ?? "git", ghPath: nil, claudePath: placement.claudePath,
                    settings: context.claude, rules: context.rules, logURLProvider: logURLProvider, placement: placement
                ).run(request, onPhase: onPhase)
            })
    }
}
