import Foundation

/// Un runner que además manda datos por stdin (el prompt de Claude en un host remoto, decisión J.7.2).
public protocol StandardInputStreamingRunning: StreamingProcessRunning {
    func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                              timeout: TimeInterval?, standardInput: Data,
                              onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult
}

/// git y Claude en el host. `run`/`runStreaming`: git con el entorno de git (`RemoteEnvironment.git`);
/// `runStreamingIsolated`: Claude con su lista blanca, el pgid en `<raíz>/jobs/<job>.pid` y Stop/timeout que matan al
/// grupo remoto. El `environment` que manda `ClaudeRunner` (rutas de la Mac) se ignora: el remoto se arma acá.
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
        return try await host.run(exec, timeout: timeout)
    }

    public func runStreaming(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                             timeout: TimeInterval?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: try RemoteEnvironment.git(passing: environment, pathDirectories: toolDirectories, root: root))
        return try await host.run(exec, timeout: timeout, onStdoutLine: onStdoutLine)
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
        let pidFile = try root.child(["jobs", job + ".pid"])
        var stdinPath: String?
        if let standardInput {
            let path = try root.child(["tmp", job + ".stdin"])
            try await host.upload(standardInput, to: path, root: root)
            stdinPath = path
        }
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: RemoteEnvironment.claude(pathDirectories: toolDirectories, root: root),
                              standardInput: stdinPath.map { .remoteFile($0) } ?? .null, pidFile: pidFile)
        let host = self.host
        let root = self.root
        let leftovers = [pidFile, RemoteExec.cancelFile(forPidFile: pidFile)] + (stdinPath.map { [$0] } ?? [])
        do {
            let result = try await host.run(exec, timeout: timeout, onStdoutLine: onStdoutLine)
            Task.detached { await host.removeFiles(leftovers, root: root) }
            return result
        } catch {
            // Stop, timeout, conexión caída o cualquier otro error: el grupo remoto puede seguir vivo. Se mata (fuera
            // de esta tarea, para que la cancelación no lo corte) y se espera la confirmación antes de devolver: quien
            // llama corre el guardián recién después. Sin confirmación, los restos quedan para los huérfanos.
            let stopped = await Task.detached { () -> Bool in
                guard await host.killGroup(pidFile: pidFile, root: root) else { return false }
                await host.removeFiles(leftovers, root: root)
                return true
            }.value
            guard stopped else {
                AppLog.write("Remote (\(host.name)): couldn’t confirm the job stopped after: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                throw RemoteRunnerError.jobNotStopped(host: host.name)
            }
            throw error
        }
    }
}

/// Los tests del usuario en el host (decisión J.7.13): `/bin/sh -lc <cmd>` con el entorno de login, sin `env -i`.
public struct RemoteLoginRunner: ProcessRunning {
    public let host: SSHHost

    public init(host: SSHHost) { self.host = host }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                    timeout: TimeInterval?) async throws -> ProcessResult {
        try await host.run(RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path, environment: nil), timeout: timeout)
    }
}
