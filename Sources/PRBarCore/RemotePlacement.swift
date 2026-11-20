import Foundation
import os

/// Todo lo necesario para que un trabajo corra en un host ya verificado (spec J.3).
public struct RemotePlacement: Sendable {
    public let host: SSHHost
    public let root: RemoteRoot
    public let info: RunnerHostInfo
    public let runner: RemoteProcessRunner
    public let workspaces: RemoteWorkspaces
    public let fs: RemoteWorkspaceFS

    /// `gitEnvironment`: lo que se suma al entorno de git en el host (la identidad de commit de la Mac; los tests aíslan
    /// la config). `remoteURLs`/`originMatches`: ver `RemoteWorkspaces` (los tests usan carpetas locales).
    public init(host: SSHHost, info: RunnerHostInfo, gitEnvironment: [String: String] = [:],
                remoteURLs: (@Sendable (RepoRef) -> [String])? = nil,
                originMatches: (@Sendable (String, RepoRef) -> Bool)? = nil) throws {
        guard info.isUsable, let rootPath = info.root, let git = info.gitPath else {
            throw RemoteRunnerError.hostProblems(host: host.name, problems: info.problems)
        }
        // La raíz es la de esta instalación (`<carpeta>/installs/<id>`); la carpeta en sí no se compara (`pwd -P`
        // resuelve symlinks). Que sea la del destino actual lo asegura `RunnerHealthCache`.
        guard rootPath.hasSuffix("/installs/" + host.installationID) else { throw RemoteRunnerError.outsideRoot(rootPath) }
        let root = try RemoteRoot(verified: rootPath)
        let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
        let fs = RemoteWorkspaceFS.ssh(host: host, home: info.home ?? (rootPath as NSString).deletingLastPathComponent, root: root)
        self.host = host
        self.root = root
        self.info = info
        self.runner = runner
        self.fs = fs
        self.workspaces = RemoteWorkspaces(
            host: host, root: root, gitPath: git, runner: runner, fs: fs, gitEnvironment: gitEnvironment,
            remoteURLs: remoteURLs ?? { ["https://github.com/\($0.fullName).git", "git@github.com:\($0.fullName).git"] },
            originMatches: originMatches ?? { WorktreeResolver.originMatches($0, repo: $1) })
    }

    public var name: String { host.name }
    public var gitPath: String { workspaces.gitPath }
    public var claudePath: String { info.claudePath ?? "claude" }
    /// El entorno de git en el host (con `GitHardening.environment`).
    public var gitEnvironment: [String: String] { workspaces.gitEnvironment }

    /// El mirror bare de PRBar para `repo` en el host (no lo crea).
    public func mirrorPath(_ repo: RepoRef) throws -> String { try root.child(["repos", repo.owner, repo.name + ".git"]) }

    /// `--plugin-dir` del host para esos skills (§8.0 en el host). Es preparación: una falla permite el fallback.
    public func plugins(skills: [String]) async throws -> [String] {
        try await preparing { try await RemotePlugins.locate(skills: skills, host: host) }
    }

    /// Envuelve las fallas de preparación (antes de que arranque Claude): son las que permiten el fallback (J.7.10).
    public func preparing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CancellationError {
            throw error
        } catch let error as RemotePreparationFailure {
            throw error
        } catch {
            throw RemotePreparationFailure(host: name, underlying: error)
        }
    }

    /// `claude -p` en el host: el prompt por stdin, el entorno remoto lo arma `RemoteProcessRunner`.
    public func claude(pluginDirs: [String], logURL: URL, secrets: [String], model: ClaudeModel?) -> ClaudeRunner {
        ClaudeRunner(runner: runner, claudePath: claudePath, pluginDirs: pluginDirs, environment: [:], logURL: logURL,
                     redacting: secrets, model: model, promptViaStandardInput: true)
    }
}

/// Una falla del host antes de que arrancara Claude (la única que permite caer a esta Mac, J.7.10).
public struct RemotePreparationFailure: Error, LocalizedError {
    public let host: String
    public let underlying: Error

    public init(host: String, underlying: Error) {
        self.host = host
        self.underlying = underlying
    }

    public var errorDescription: String? { (underlying as? LocalizedError)?.errorDescription ?? "\(underlying)" }
    /// Para la fila: "devbox unreachable" o "devbox couldn’t prepare the repo".
    public var shortReason: String { fallback.reason }

    /// El fallback que corresponde (la Task 17 lo usa cuando Review/Respond caen a esta Mac en la preparación).
    public var fallback: RunnerFallback {
        let cause: RunnerFallback.Cause = if case .unreachable? = underlying as? RemoteRunnerError { .unreachable } else { .preparation }
        return RunnerFallback(host: host, cause: cause, detail: errorDescription ?? "")
    }
}

/// Los worktrees remotos donde Claude puede seguir corriendo: un Stop o una conexión caída que no se pudo confirmar
/// (`RemoteRunnerError.jobNotStopped`). Nadie los toca en esta sesión de la app (ni las limpiezas de los pipelines ni
/// la de los chats): la limpieza de huérfanos al arrancar los saca cuando el grupo ya no existe y quedaron viejos.
public final class RemoteUnstoppedJobs: Sendable {
    public static let shared = RemoteUnstoppedJobs()

    private let entries = OSAllocatedUnfairLock(initialState: Set<String>())

    public init() {}

    private static func key(host: String, path: String) -> String { host.lowercased() + "\u{0}" + path }

    public func insert(host: String, path: String) {
        entries.withLock { _ = $0.insert(Self.key(host: host, path: path)) }
    }

    /// `path` o algo adentro (o su carpeta de contexto `<path>.context`).
    public func contains(host: String, path: String) -> Bool {
        let all = entries.withLock { $0 }
        let prefix = host.lowercased() + "\u{0}"
        return all.contains { entry in
            guard entry.hasPrefix(prefix) else { return false }
            let kept = String(entry.dropFirst(prefix.count))
            return path == kept || path.hasPrefix(kept + "/") || path == kept + ".context"
        }
    }

    /// Un error de "no se pudo confirmar que Claude paró en el host".
    public static func isNotStopped(_ error: Error) -> Bool {
        if let failure = error as? ReviewFailure { return isNotStopped(failure.underlying) }
        return (error as? RemoteRunnerError)?.jobHost != nil
    }
}

extension SSHHost {
    /// El host de verdad para un destino: el `ssh` elegido, la carpeta del socket, la política de host key de `ssh -G`
    /// y el id de esta instalación (`RemoteInstallation.id`, que fija la raíz `<carpeta>/installs/<id>`).
    /// Un `ssh` propio (no `/usr/bin/ssh`) tiene que ser OpenSSH 8.7 o más nuevo: se verifica antes de correr nada.
    public static func live(_ destination: RunnerDestination, sshPath: String = OpenSSHVersion.systemPath,
                            installationIDFile: URL = AppPaths.installationIDFile,
                            controlDirectory: String = ControlSocketDirectory.defaultPath,
                            sshEnvironment: [String: String] = [:]) async throws -> SSHHost {
        if sshPath != OpenSSHVersion.systemPath {
            try await OpenSSHVersion.require(sshPath: sshPath, environment: sshEnvironment)
        }
        let id = try RemoteInstallation.id(file: installationIDFile)
        let directory = try ControlSocketDirectory.ensure(controlDirectory)
        let enforce = await enforcesHostKey(destination, sshPath: sshPath, sshEnvironment: sshEnvironment)
        return SSHHost(destination: destination, installationID: id, sshPath: sshPath, controlDirectory: directory,
                       enforceHostKey: enforce, sshEnvironment: sshEnvironment)
    }
}

/// Por qué un trabajo de un repo con destino remoto corrió en esta Mac (J.7.10).
public struct RunnerFallback: Codable, Equatable, Sendable {
    public enum Cause: String, Codable, Sendable {
        /// ssh no llegó al host.
        case unreachable
        /// La verificación encontró problemas (o no se pudo armar el host: `ssh` propio viejo, carpeta del socket).
        case notReady
        /// Falló la preparación en el host (mirror, fetch, worktree, contexto, plugins).
        case preparation
    }

    public var host: String
    public var cause: Cause
    /// El error completo (para el log y un tooltip).
    public var detail: String

    public init(host: String, cause: Cause, detail: String = "") {
        self.host = host
        self.cause = cause
        self.detail = detail
    }

    /// Para la fila y la ventana: "devbox unreachable".
    public var reason: String {
        switch cause {
        case .unreachable: "\(host) unreachable"
        case .notReady: "\(host) isn’t ready"
        case .preparation: "\(host) couldn’t prepare the repo"
        }
    }

    /// El aviso de Settings › Repos cuando el último trabajo del repo cayó a esta Mac.
    public var repoWarning: String {
        switch cause {
        case .unreachable: "Last job ran on this Mac — \(host) was unreachable (fallback)."
        case .notReady: "Last job ran on this Mac — \(host) wasn’t ready (fallback)."
        case .preparation: "Last job ran on this Mac — \(host) couldn’t prepare the repo (fallback)."
        }
    }
}

/// Dónde corrió (o corre) un trabajo, para la fila y la ventana (spec J.4).
public enum JobPlacement: Codable, Equatable, Sendable {
    case local
    case remote(host: String)
    case fallback(RunnerFallback)

    public var label: String? {
        switch self {
        case .local: nil
        case .remote(let host): "on \(host)"
        case .fallback(let fallback): "Ran on this Mac — \(fallback.reason)"
        }
    }

    /// El host donde corre (`nil` en esta Mac, también en un fallback).
    public var host: String? {
        if case .remote(let host) = self { return host }
        return nil
    }
}

/// Elige dónde corre un trabajo: esta Mac, el host (verificado, con caché) o esta Mac por fallback (J.7.10–11).
public actor RunnerCoordinator {
    public enum Choice: Sendable {
        case local
        case remote(RemotePlacement)
        case fallback(RunnerFallback)

        public var jobPlacement: JobPlacement {
            switch self {
            case .local: .local
            case .remote(let placement): .remote(host: placement.name)
            case .fallback(let fallback): .fallback(fallback)
            }
        }
    }

    private let health: RunnerHealthCache
    private let makeHost: @Sendable (RunnerDestination) async throws -> SSHHost
    private let gitEnvironment: @Sendable () async -> [String: String]
    private let remoteURLs: (@Sendable (RepoRef) -> [String])?
    private let originMatches: (@Sendable (String, RepoRef) -> Bool)?

    /// `makeHost`: `RunnerCoordinator.liveHost` en la app y la CLI; los tests pasan el `ssh` falso.
    /// `remoteURLs`/`originMatches`: ver `RemotePlacement` (los tests usan carpetas locales).
    public init(health: RunnerHealthCache = RunnerHealthCache(),
                makeHost: @escaping @Sendable (RunnerDestination) async throws -> SSHHost,
                gitEnvironment: @escaping @Sendable () async -> [String: String] = { [:] },
                remoteURLs: (@Sendable (RepoRef) -> [String])? = nil,
                originMatches: (@Sendable (String, RepoRef) -> Bool)? = nil) {
        self.health = health
        self.makeHost = makeHost
        self.gitEnvironment = gitEnvironment
        self.remoteURLs = remoteURLs
        self.originMatches = originMatches
    }

    /// El host real (`SSHHost.live`): el id de esta instalación, la carpeta del socket, la política de host key de
    /// `ssh -G` y, con un `ssh` propio, la exigencia de OpenSSH 8.7.
    public static func liveHost(_ destination: RunnerDestination, sshPath: String = OpenSSHVersion.systemPath) async throws -> SSHHost {
        try await SSHHost.live(destination, sshPath: sshPath)
    }

    /// `nil` = esta Mac. Si el host no responde o no está listo y el destino tiene fallback, esta Mac con el motivo;
    /// sin fallback, el error.
    public func choice(for destination: RunnerDestination?) async throws -> Choice {
        guard let destination else { return .local }
        do {
            return .remote(try await placement(for: destination))
        } catch let error as CancellationError {
            throw error
        } catch {
            guard destination.fallbackToLocal else { throw error }
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            AppLog.write("Runner \(destination.name): \(detail) — running on this Mac")
            let cause: RunnerFallback.Cause = if case .unreachable? = error as? RemoteRunnerError { .unreachable } else { .notReady }
            return .fallback(RunnerFallback(host: destination.name, cause: cause, detail: detail))
        }
    }

    /// Sin fallback: para las etapas siguientes de Respond (siempre el host del análisis) y "Test Connection".
    public func placement(for destination: RunnerDestination, force: Bool = false) async throws -> RemotePlacement {
        let host = try await makeHost(destination)
        let info = try await health.info(for: host, force: force)
        return try RemotePlacement(host: host, info: info, gitEnvironment: await gitEnvironment(),
                                   remoteURLs: remoteURLs, originMatches: originMatches)
    }

    /// "Test Connection": verifica sin caché y además prueba el login de Claude. Nunca lanza: los problemas van en
    /// `problems`. Después, el próximo trabajo vuelve a verificar.
    public func test(_ destination: RunnerDestination) async -> RunnerHostInfo {
        let info: RunnerHostInfo
        do {
            let host = try await makeHost(destination)
            var checked = try await RunnerProbe.check(host)
            if checked.isUsable { checked.claudeLoggedIn = try await RunnerProbe.claudeLoggedIn(host, info: checked) }
            if checked.claudeLoggedIn == false {
                checked.problems.append("Claude isn’t signed in on \(destination.name): run `claude` there once to log in.")
            }
            info = checked
        } catch {
            info = RunnerHostInfo(host: destination.name, problem: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        await health.forget(destination.name)
        return info
    }

    public func lastInfo(_ name: String) async -> RunnerHostInfo? { await health.last(name) }
    public func forget(_ name: String) async { await health.forget(name) }
}
