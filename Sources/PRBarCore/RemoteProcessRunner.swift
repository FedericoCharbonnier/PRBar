import Foundation

/// Un runner que además manda datos por stdin (el prompt de Claude en un host remoto, decisión J.7.2).
public protocol StandardInputStreamingRunning: StreamingProcessRunning {
    func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                              timeout: TimeInterval?, standardInput: Data,
                              onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult
}

/// git y Claude en el host. `run`/`runStreaming`: git con el entorno de git (`RemoteEnvironment.git`);
/// `runStreamingIsolated`: Claude con su lista blanca. Los dos corren como trabajos (`SSHHost.runJob`): el pgid en
/// `<raíz>/jobs/<job>.pid` y Stop/timeout que matan al grupo remoto, no solo al `ssh` local. El `environment` que manda
/// `ClaudeRunner` (rutas de la Mac) se ignora: el remoto se arma acá.
public struct RemoteProcessRunner: ProcessRunning, StandardInputStreamingRunning {
    public let host: SSHHost
    public let root: RemoteRoot
    public let toolDirectories: [String]

    public init(host: SSHHost, root: RemoteRoot, toolDirectories: [String]) {
        self.host = host
        self.root = root
        self.toolDirectories = toolDirectories
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                    timeout: TimeInterval?) async throws -> ProcessResult {
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: try RemoteEnvironment.git(passing: environment, pathDirectories: toolDirectories, root: root))
        return try await host.runJob(exec, root: root, timeout: timeout)
    }

    public func runStreaming(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                             timeout: TimeInterval?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: try RemoteEnvironment.git(passing: environment, pathDirectories: toolDirectories, root: root))
        return try await host.runJob(exec, root: root, timeout: timeout, onStdoutLine: onStdoutLine)
    }

    public func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                                     timeout: TimeInterval?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        try await isolated(executable, arguments, currentDirectory: currentDirectory, timeout: timeout, standardInput: nil, onStdoutLine: onStdoutLine)
    }

    public func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                                     timeout: TimeInterval?, standardInput: Data,
                                     onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        try await isolated(executable, arguments, currentDirectory: currentDirectory, timeout: timeout, standardInput: standardInput,
                           onStdoutLine: onStdoutLine)
    }

    private func isolated(_ executable: String, _ arguments: [String], currentDirectory: URL?, timeout: TimeInterval?,
                          standardInput: Data?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let job = UUID().uuidString.lowercased()
        var stdinPath: String?
        if let standardInput {
            let path = try root.child(["tmp", job + ".stdin"])
            try await host.upload(standardInput, to: path, root: root)
            stdinPath = path
        }
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: RemoteEnvironment.claude(pathDirectories: toolDirectories, root: root),
                              standardInput: stdinPath.map { .remoteFile($0) } ?? .null)
        let host = self.host
        return try await host.runJob(exec, root: root, job: job, leftovers: stdinPath.map { [$0] } ?? [], timeout: timeout,
                                     onStdoutLine: onStdoutLine) { error in
            AppLog.write("Remote (\(host.name)): couldn’t confirm the job stopped after: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                         + (currentDirectory.map { "; leaving \($0.path) as is" } ?? ""))
            // Claude puede seguir escribiendo ahí: ninguna limpieza de esta sesión lo toca.
            if let currentDirectory { RemoteUnstoppedJobs.shared.insert(host: host.name, path: currentDirectory.path) }
            return RemoteRunnerError.jobNotStopped(host: host.name)
        }
    }
}

extension SSHHost {
    /// Corre `exec` como un trabajo: su pgid en `<raíz>/jobs/<job>.pid` (que el script borra al terminar). Si la corrida
    /// lanza (Stop, timeout, conexión caída), mata al grupo remoto (fuera de esta tarea, para que la cancelación no lo
    /// corte) y espera la confirmación antes de devolver: quien llama puede mirar el worktree recién después. Sin
    /// confirmación lanza `unconfirmed(error)` (por defecto, el error original, con un aviso en el log) y los restos
    /// quedan para los huérfanos. `leftovers`: otros archivos del trabajo para borrar al final.
    func runJob(_ exec: RemoteExec, root: RemoteRoot, job: String = UUID().uuidString.lowercased(), leftovers: [String] = [],
                timeout: TimeInterval?, onStdoutLine: (@Sendable (String) -> Void)? = nil,
                unconfirmed: (@Sendable (Error) -> Error)? = nil) async throws -> ProcessResult {
        let pidFile = try root.child(["jobs", job + ".pid"])
        var exec = exec
        exec.pidFile = pidFile
        let host = self
        let all = [pidFile, RemoteExec.cancelFile(forPidFile: pidFile)] + leftovers
        do {
            let result = try await run(exec, timeout: timeout, onStdoutLine: onStdoutLine)
            if !leftovers.isEmpty { Task.detached { await host.removeFiles(all, root: root) } }
            return result
        } catch {
            let stopped = await Task.detached { () -> Bool in
                guard await host.killGroup(pidFile: pidFile, root: root) else { return false }
                await host.removeFiles(all, root: root)
                return true
            }.value
            guard stopped else {
                if let unconfirmed { throw unconfirmed(error) }
                AppLog.write("Remote (\(name)): couldn’t confirm \(exec.argv.first ?? "a command") stopped after: "
                             + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                throw error
            }
            throw error
        }
    }
}

/// Los tests del usuario en el host (decisión J.7.13): `/bin/sh -lc <cmd>` con el entorno de login, sin `env -i`. Como
/// trabajo (`SSHHost.runJob`): un timeout o un Stop matan al grupo remoto, no solo al `ssh` local.
public struct RemoteLoginRunner: ProcessRunning {
    public let host: SSHHost
    public let root: RemoteRoot

    public init(host: SSHHost, root: RemoteRoot) {
        self.host = host
        self.root = root
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                    timeout: TimeInterval?) async throws -> ProcessResult {
        try await host.runJob(RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path, environment: nil),
                              root: root, timeout: timeout)
    }
}
