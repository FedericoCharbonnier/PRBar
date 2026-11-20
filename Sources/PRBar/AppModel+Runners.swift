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
