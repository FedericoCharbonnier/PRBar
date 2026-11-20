import Foundation

/// Dónde corre cada trabajo de Claude (spec J): el destino del repo, con fallback a esta Mac (review, análisis de
/// Respond, el primer turno de un chat de Review/Merge), o el host fijo de algo que ya empezó en un lugar (las etapas
/// siguientes de Respond y los chats con worktree), sin fallback.
public enum RunnerDispatch {
    /// La falla de preparación en el host (antes de que arrancara Claude) que permite caer a esta Mac (J.7.10):
    /// Respond la lanza tal cual; el review la envuelve en `ReviewFailure`.
    public static func preparationFailure(in error: Error) -> RemotePreparationFailure? {
        if let failure = error as? RemotePreparationFailure { return failure }
        return (error as? ReviewFailure)?.underlying as? RemotePreparationFailure
    }

    /// Corre el trabajo donde dice `destination` (`nil` = esta Mac). Con fallback, un host caído o no listo corre en
    /// esta Mac; y, con `fallbackOnPreparation`, también una falla de preparación en el host (nunca una vez que
    /// arrancó Claude ni si se canceló). `canRunLocally == false` (Respond sin carpeta local) nunca cae a esta Mac.
    /// `onPlacement` recibe dónde corre (y, si después cae, el fallback). Lo remoto corre con la `ProcessActivity`
    /// actual "on <host>": la ventana Activity lo muestra sin CPU/RAM locales y su Stop cancela el trabajo remoto.
    public static func run<T: Sendable>(
        destination: RunnerDestination?, coordinator: RunnerCoordinator,
        fallbackOnPreparation: Bool = true, canRunLocally: Bool = true,
        onPlacement: @Sendable (JobPlacement) async -> Void,
        local: @Sendable () async throws -> T,
        remote: @Sendable (RemotePlacement) async throws -> T
    ) async throws -> T {
        var destination = destination
        if !canRunLocally { destination?.fallbackToLocal = false }
        switch try await coordinator.choice(for: destination) {
        case .local:
            await onPlacement(.local)
            return try await local()
        case .fallback(let fallback):
            await onPlacement(.fallback(fallback))
            return try await local()
        case .remote(let placement):
            await onPlacement(.remote(host: placement.name))
            do {
                return try await onHost(placement.name) { try await remote(placement) }
            } catch {
                guard fallbackOnPreparation, destination?.fallbackToLocal == true, !Task.isCancelled,
                      let failure = preparationFailure(in: error) else { throw error }
                AppLog.write("Runner \(placement.name): \(failure.fallback.detail) — running on this Mac")
                await onPlacement(.fallback(failure.fallback))
                return try await local()
            }
        }
    }

    /// Lo que ya empezó en un lugar sigue ahí: `runner == nil` = esta Mac; si no, ese host (verificado, sin
    /// fallback). Un host que ya no está en la configuración es un error claro.
    public static func pinned<T: Sendable>(
        runner: String?, settings: RunnerSettings, coordinator: RunnerCoordinator,
        onPlacement: @Sendable (JobPlacement) async -> Void,
        local: @Sendable () async throws -> T,
        remote: @Sendable (RemotePlacement) async throws -> T
    ) async throws -> T {
        guard let runner else { return try await local() }
        let placement = try await placement(named: runner, settings: settings, coordinator: coordinator)
        await onPlacement(.remote(host: placement.name))
        return try await onHost(placement.name) { try await remote(placement) }
    }

    /// El host `name` verificado (con la caché de salud), o el error de que ya no está configurado.
    public static func placement(named name: String, settings: RunnerSettings,
                                 coordinator: RunnerCoordinator) async throws -> RemotePlacement {
        guard let destination = settings.destination(named: name) else { throw PRBarError.respond(removedMessage(name)) }
        return try await coordinator.placement(for: destination)
    }

    public static func removedMessage(_ name: String) -> String {
        "This ran on \(name), which isn’t in Settings › Claude › Run On anymore. Start it again."
    }

    /// `body` con la tarea actual marcada "on <host>" (los procesos `ssh` que lance se anotan así en el registro).
    public static func onHost<T>(_ host: String, _ body: () async throws -> T) async rethrows -> T {
        try await ProcessActivity.$current.withValue(ProcessActivity.current?.on(host: host)) { try await body() }
    }

    /// Dónde corre un turno o la limpieza de un chat.
    public enum ChatTarget: Equatable, Sendable {
        /// Donde ya está su worktree (`nil` = esta Mac): `--resume` necesita la misma máquina.
        case pinned(String?)
        /// Todavía no tiene worktree: el destino del repo (Review/Merge).
        case repoDestination
    }

    /// Respond: el host del análisis (`draft.runner`). Review/Merge: donde se armó su worktree (`session.runner`),
    /// o el destino del repo si todavía no tiene.
    public static func chatTarget(subject: ChatSubject, session: ChatSession) -> ChatTarget {
        if case .respond(let draft) = subject { return .pinned(draft.runner) }
        return session.worktreePath == nil ? .repoDestination : .pinned(session.runner)
    }
}

/// Dónde corrió (o corre) el último trabajo de cada PR y el último fallback de cada repo (spec J.4): la fila del PR
/// muestra `label(prID:)` ("on devbox" / "Ran on this Mac — devbox unreachable") y Settings › Repos `repoWarning`.
/// Un trabajo que no cae a esta Mac borra el aviso del repo. En memoria: es el estado de esta sesión de la app.
public struct RunnerPlacements: Equatable, Sendable {
    public private(set) var byPR: [String: JobPlacement] = [:]
    /// Por `RepoRef.fullName` en minúsculas.
    public private(set) var lastFallback: [String: RunnerFallback] = [:]

    public init() {}

    public mutating func record(_ placement: JobPlacement, prID: String, repo: RepoRef) {
        byPR[prID] = placement == .local ? nil : placement
        let key = Self.key(repo)
        if case .fallback(let fallback) = placement { lastFallback[key] = fallback } else { lastFallback[key] = nil }
    }

    public func placement(prID: String) -> JobPlacement? { byPR[prID] }
    public func label(prID: String) -> String? { byPR[prID]?.label }
    public func fallback(for repo: RepoRef) -> RunnerFallback? { lastFallback[Self.key(repo)] }
    /// "Last job ran on this Mac — devbox was unreachable (fallback)."
    public func repoWarning(_ repo: RepoRef) -> String? { fallback(for: repo)?.repoWarning }

    private static func key(_ repo: RepoRef) -> String { repo.fullName.lowercased() }
}

/// Lo que un trabajo necesita en esta Mac (spec J): git siempre (el diff, el import de los fixes, el chat);
/// claude solo si el trabajo corre acá.
public enum LocalTools {
    /// La herramienta que falta (`"git"` o `"claude"`), o `nil`.
    public static func missing(git: String?, claude: String?, runsOnHost: Bool) -> String? {
        if git == nil { return "git" }
        if claude == nil && !runsOnHost { return "claude" }
        return nil
    }

    /// La fila "This Mac" de Settings › Claude › Run On: "✓ claude 2.1.318 · git 2.47.1" o "⚠ claude isn’t installed".
    public static func statusSummary(git: String?, claude: String?, gitVersion: String?, claudeVersion: String?) -> String {
        if git == nil { return "⚠ git isn’t installed" }
        if claude == nil { return "⚠ claude isn’t installed" }
        let claudeText = claudeVersion?.split(separator: " ").first.map { "claude \($0)" } ?? "claude"
        let gitText = gitVersion.map { $0.replacingOccurrences(of: "git version ", with: "") }
            .flatMap { $0.split(separator: " ").first }.map { "git \($0)" } ?? "git"
        return "✓ \(claudeText) · \(gitText)"
    }
}
