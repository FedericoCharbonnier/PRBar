import Foundation
import PRBarCore

// `prbar runners` (spec J.4). Settings › Claude › Run On (Task 18) usa los mismos métodos.
extension AppModel: RunnerActions {
    func runnersList() async -> [RunnerInfo] {
        var result: [RunnerInfo] = []
        for destination in configStore.config.runners.destinations {
            var check = runnerChecks[destination.name]
            if check == nil { check = await runners.lastInfo(destination.name) }
            result.append(runnerInfo(destination, lastCheck: check))
        }
        return result
    }

    func runnerAdd(host: String, name: String?, dir: String?, fallback: Bool) async throws -> RunnerInfo {
        let endpoint: SSHEndpoint
        do { endpoint = try SSHEndpoint.parse(host) } catch { throw CommandFailure(.invalidUsage, error.localizedDescription) }
        let destination = RunnerDestination(name: name ?? endpoint.host, endpoint: endpoint,
                                            remoteDir: dir ?? RunnerDestination.defaultRemoteDir, fallbackToLocal: fallback)
        try updateRunners { try $0.addRunner(destination) }
        // Queda agregado aunque la verificación encuentre problemas (se ven en el resultado y en Settings).
        return try await runnerTest(name: destination.name)
    }

    func runnerSet(name: String, dir: String?, fallback: Bool?) async throws -> RunnerInfo {
        try updateRunners { config in
            try config.updateRunner(named: name) { destination in
                if let dir { destination.remoteDir = dir }
                if let fallback { destination.fallbackToLocal = fallback }
            }
        }
        guard let destination = configStore.config.runners.destination(named: name) else {
            throw CommandFailure(.notFound, RunnerConfigError.notFound(name).localizedDescription)
        }
        // La salud cacheada es de la carpeta vieja: el próximo trabajo vuelve a verificar.
        if dir != nil { runnerChecks[destination.name] = nil }
        await runners.forget(destination.name)
        return runnerInfo(destination, lastCheck: runnerChecks[destination.name])
    }

    func runnerRemove(name: String) async throws {
        guard let destination = configStore.config.runners.destination(named: name) else {
            throw CommandFailure(.notFound, RunnerConfigError.notFound(name).localizedDescription)
        }
        try updateRunners { try $0.removeRunner(named: destination.name) }
        runnerChecks[destination.name] = nil
        await runners.forget(destination.name)
        if let host = try? await RunnerCoordinator.liveHost(destination) { await host.closeMaster() }
    }

    func runnerTest(name: String) async throws -> RunnerInfo {
        guard let destination = configStore.config.runners.destination(named: name) else {
            throw CommandFailure(.notFound, RunnerConfigError.notFound(name).localizedDescription)
        }
        let info = await runners.test(destination)
        runnerChecks[destination.name] = info
        return runnerInfo(destination, lastCheck: info)
    }

    func runnerDefault(target: String) throws {
        guard let parsed = RunTarget(cliValue: target) else { throw CommandFailure(.invalidUsage, "Use local or a runner’s name.") }
        try updateRunners { try $0.setDefaultRunTarget(parsed) }
    }

    private func runnerInfo(_ destination: RunnerDestination, lastCheck: RunnerHostInfo?) -> RunnerInfo {
        RunnerInfo(destination: destination, isDefault: configStore.config.runners.defaultTarget == .runner(destination.name),
                   lastCheck: lastCheck)
    }

    /// Aplica el cambio sobre una copia (los errores de validación no guardan nada) y después lo guarda.
    private func updateRunners(_ mutate: (inout AppConfig) throws -> Void) throws {
        var updated = configStore.config
        do {
            try mutate(&updated)
        } catch let error as RunnerConfigError {
            let code: CommandFailure.Code = switch error {
            case .notFound: .notFound
            case .duplicate: .invalidState
            case .invalidName, .invalidRemoteDir: .invalidUsage
            }
            throw CommandFailure(code, error.localizedDescription)
        }
        try applyConfig(refresh: false) { $0 = updated }
    }
}

// Dónde corre cada trabajo (spec J.3–J.4): el contexto de los pipelines, "on devbox" y la limpieza al arrancar.
extension AppModel {
    /// Lo que leen los pipelines y el chat al arrancar un trabajo del repo `repo` de `account`.
    func jobContext(account: String, repo: RepoRef) -> ReviewContext {
        ReviewContext(tools: tools, orphanCleanup: orphanCleanup, claude: configStore.config.claude, rules: instructions.rules,
                      runner: runnerDestination(account: account, repo: repo), runnerSettings: configStore.config.runners,
                      coordinator: runners,
                      onPlacement: { [weak self] prID, placement in self?.recordPlacement(placement, prID: prID, repo: repo) })
    }

    /// El destino del repo (su "Run Claude on" o el predeterminado); `nil` = esta Mac.
    func runnerDestination(account: String, repo: RepoRef) -> RunnerDestination? {
        RunTargetResolver.destination(for: repoConfig(account: account, repo: repo), settings: configStore.config.runners)
    }

    func recordPlacement(_ placement: JobPlacement, prID: String, repo: RepoRef) {
        placements.record(placement, prID: prID, repo: repo)
    }

    /// Al arrancar (decisión J.7.16): en segundo plano, cada destino que responde limpia lo que quedó de corridas
    /// anteriores de esta instalación. Nunca bloquea nada: un trabajo nuevo no espera, y `cleanupOrphans` solo toca
    /// grupos muertos y lo que no cambió en 12 h (con su candado), así que no pisa un trabajo en curso.
    func startRemoteOrphanCleanup() {
        let destinations = configStore.config.runners.destinations
        guard !destinations.isEmpty else { return }
        let runners = self.runners
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for destination in destinations {
                    group.addTask {
                        do {
                            let placement = try await runners.placement(for: destination)
                            await placement.workspaces.cleanupOrphans()
                        } catch {
                            AppLog.write("Runner \(destination.name): skipping the startup cleanup: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Un destino editado (host, carpeta, fallback) o quitado, por cualquier camino (Settings o `prbar`): su salud
    /// cacheada ya no vale, y su última verificación tampoco si cambió a dónde se conecta o su carpeta.
    func runnersChanged(from before: RunnerSettings) {
        let after = configStore.config.runners
        for old in before.destinations {
            let new = after.destination(named: old.name)
            guard new != old else { continue }
            if new == nil || new?.endpoint != old.endpoint || new?.remoteDir != old.remoteDir {
                runnerChecks.removeValue(forKey: old.name)
            }
            let runners = self.runners
            Task { await runners.forget(old.name) }
        }
    }
}

extension ReviewContext {
    /// Sin `AppModel` (la app se está cerrando): nada corre en un host.
    static let closed = ReviewContext(tools: ResolvedTools(), orphanCleanup: nil, claude: ClaudeSettings(),
                                      coordinator: RunnerCoordinator(makeHost: { _ in throw CancellationError() }))
}
