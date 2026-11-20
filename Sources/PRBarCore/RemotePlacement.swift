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
    public var shortReason: String {
        if case .unreachable? = underlying as? RemoteRunnerError { return "\(host) unreachable" }
        return "\(host) couldn’t prepare the repo"
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
    public static func live(_ destination: RunnerDestination, sshPath: String = "/usr/bin/ssh",
                            installationIDFile: URL = AppPaths.installationIDFile,
                            controlDirectory: String = ControlSocketDirectory.defaultPath,
                            sshEnvironment: [String: String] = [:]) async throws -> SSHHost {
        let id = try RemoteInstallation.id(file: installationIDFile)
        let directory = try ControlSocketDirectory.ensure(controlDirectory)
        let enforce = await enforcesHostKey(destination, sshPath: sshPath, sshEnvironment: sshEnvironment)
        return SSHHost(destination: destination, installationID: id, sshPath: sshPath, controlDirectory: directory,
                       enforceHostKey: enforce, sshEnvironment: sshEnvironment)
    }
}
