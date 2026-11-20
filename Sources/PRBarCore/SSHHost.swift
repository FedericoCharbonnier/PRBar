import Foundation

/// Un host por ssh (spec J.1/J.3): corre scripts (`/bin/sh -c '<script>'`), sube y baja archivos y borra solo
/// dentro de la raíz de PRBar. Todo pasa por el `ssh` del sistema con `SSHCommandBuilder`.
public struct SSHHost: Sendable {
    /// Linux limita cada argumento a 128 KiB; el script viaja como un solo argumento del shell de login.
    public static let maxScriptBytes = 100_000

    public let destination: RunnerDestination
    public let sshPath: String
    public let controlDirectory: String
    public let enforceHostKey: Bool
    /// Entorno del `ssh` local (además del de la app; los tests pasan el del stub).
    public let sshEnvironment: [String: String]
    public let killGracePeriod: TimeInterval
    let local: SystemProcessRunner

    public init(destination: RunnerDestination, sshPath: String = "/usr/bin/ssh", controlDirectory: String, enforceHostKey: Bool,
                sshEnvironment: [String: String] = [:], killGracePeriod: TimeInterval = 5, local: SystemProcessRunner = SystemProcessRunner()) {
        self.destination = destination
        self.sshPath = sshPath
        self.controlDirectory = controlDirectory
        self.enforceHostKey = enforceHostKey
        self.sshEnvironment = sshEnvironment
        self.killGracePeriod = killGracePeriod
        self.local = local
    }

    public var name: String { destination.name }

    public func run(_ exec: RemoteExec, timeout: TimeInterval?, standardInput: URL? = nil, standardOutput: URL? = nil,
                    onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try await runScript(try exec.script(), timeout: timeout, standardInput: standardInput, standardOutput: standardOutput,
                            onStdoutLine: onStdoutLine)
    }

    /// `script` ya tiene todo con comillas (`RemoteExec`, `ShellQuote`). Va como `/bin/sh -c '<script>'`.
    public func runScript(_ script: String, timeout: TimeInterval?, standardInput: URL? = nil, standardOutput: URL? = nil,
                          onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let command = "/bin/sh -c " + (try ShellQuote.posix(script))
        guard command.utf8.count <= Self.maxScriptBytes else { throw RemoteRunnerError.commandTooLong(host: name) }
        let args = SSHCommandBuilder.arguments(destination, controlDirectory: controlDirectory, enforceHostKey: enforceHostKey,
                                               remoteCommand: command)
        let result = try await local.runWithFiles(sshPath, args, environment: sshEnvironment, currentDirectory: nil, timeout: timeout,
                                                  standardInput: standardInput, standardOutput: standardOutput, onStdoutLine: onStdoutLine)
        if result.status == 255 {
            throw RemoteRunnerError.unreachable(host: name, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Lanza si salió con error.
    @discardableResult
    func checked(_ result: ProcessResult, _ what: String) throws -> ProcessResult {
        guard result.status == 0 else {
            throw RemoteRunnerError.commandFailed(host: name, command: what, status: result.status,
                                                  stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Escribe `data` en `path` (dentro de la raíz): a un `.part` y `mv`, con `umask 077`.
    public func upload(_ data: Data, to path: String, root: RemoteRoot, timeout: TimeInterval = 300) async throws {
        guard root.contains(path) else { throw RemoteRunnerError.outsideRoot(path) }
        let localFile = try LocalScratch.file(with: data)
        defer { try? FileManager.default.removeItem(at: localFile) }
        let part = try ShellQuote.posix(path + ".part")
        let script = "umask 077 && cat > \(part) && mv -f -- \(part) \(try ShellQuote.posix(path))"
        try checked(try await runScript(script, timeout: timeout, standardInput: localFile), "upload")
    }

    /// Baja `path` (dentro de la raíz) a `local`, binario.
    public func download(_ path: String, to local: URL, root: RemoteRoot, timeout: TimeInterval = 300) async throws {
        guard root.contains(path) else { throw RemoteRunnerError.outsideRoot(path) }
        try checked(try await runScript("cat -- \(try ShellQuote.posix(path))", timeout: timeout, standardOutput: local), "download")
    }

    /// `rm -rf` de `path`, solo si está dentro de la raíz, dos niveles abajo, y la raíz tiene la marca.
    public func removeTree(_ path: String, root: RemoteRoot) async throws {
        guard root.isRemovable(path) else { throw RemoteRunnerError.outsideRoot(path) }
        let script = "[ -f \(try ShellQuote.posix(root.markerPath)) ] || exit 96\nrm -rf -- \(try ShellQuote.posix(path))"
        try checked(try await runScript(script, timeout: 120), "rm")
    }

    /// Borra archivos sueltos de la raíz (pid, stdin de un trabajo). Nunca lanza.
    public func removeFiles(_ paths: [String], root: RemoteRoot) async {
        let safe = paths.filter(root.isRemovable)
        guard !safe.isEmpty, let quoted = try? safe.map(ShellQuote.posix).joined(separator: " ") else { return }
        _ = try? await runScript("rm -f -- \(quoted)", timeout: 30)
    }

    /// Stop (decisión J.7.15): SIGTERM al grupo remoto guardado en `pidFile`, y SIGKILL a los `killGracePeriod`
    /// segundos. Nunca lanza.
    public func killGroup(pidFile: String, root: RemoteRoot) async {
        guard root.isRemovable(pidFile), let file = try? ShellQuote.posix(pidFile) else { return }
        let grace = max(1, Int(killGracePeriod.rounded(.up)))
        let script = """
        [ -f \(file) ] || exit 0
        pgid=$(cat -- \(file))
        case $pgid in ''|*[!0-9]*) exit 3;; esac
        [ "$pgid" -gt 1 ] || exit 3
        kill -TERM -- "-$pgid" 2>/dev/null
        sleep \(grace)
        kill -KILL -- "-$pgid" 2>/dev/null
        rm -f -- \(file)
        exit 0
        """
        _ = try? await runScript(script, timeout: killGracePeriod + 30)
    }

    /// `ssh -O exit` (al sacar el destino). Nunca lanza.
    public func closeMaster() async {
        _ = try? await local.run(sshPath, SSHCommandBuilder.exitArguments(destination, controlDirectory: controlDirectory),
                                 environment: sshEnvironment, currentDirectory: nil, timeout: 10)
    }

    /// `ssh -G`: si hay que forzar `StrictHostKeyChecking=yes`.
    public static func enforcesHostKey(_ destination: RunnerDestination, sshPath: String = "/usr/bin/ssh",
                                       sshEnvironment: [String: String] = [:]) async -> Bool {
        guard let result = try? await SystemProcessRunner().run(sshPath, SSHCommandBuilder.configArguments(destination),
                                                                environment: sshEnvironment, currentDirectory: nil, timeout: 10),
              result.status == 0 else { return true }
        return SSHCommandBuilder.enforcesHostKey(fromConfig: result.stdout)
    }
}

/// Archivos locales de paso (subidas, bundles), 0600, en `$TMPDIR/PRBar/ssh-io`.
enum LocalScratch {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/ssh-io", isDirectory: true) }

    static func file(with data: Data) throws -> URL {
        let url = try newFile()
        try data.write(to: url)
        return url
    }

    static func newFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
