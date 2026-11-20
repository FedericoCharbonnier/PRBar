import Foundation
import os

public struct ProcessResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessTimeouts {
    /// Para comandos cortos: `zsh -lc command -v`, `gh auth ...`, `git remote -v`.
    public static let standard: TimeInterval = 10
}

public protocol ProcessRunning: Sendable {
    /// `timeout == nil` significa sin límite. Al vencer el timeout o cancelarse la tarea se manda SIGTERM
    /// al grupo de procesos (el proceso y sus descendientes) y, tras un período de gracia, SIGKILL al grupo.
    func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult
}

extension ProcessRunning {
    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = ProcessTimeouts.standard) async throws -> ProcessResult {
        try await run(executable, arguments, environment: nil, currentDirectory: nil, timeout: timeout)
    }
}

public protocol StreamingProcessRunning: Sendable {
    /// Igual que `ProcessRunning.run`, pero llama a `onStdoutLine` (en un hilo de fondo) por cada línea
    /// completa de stdout, sin el `\n`. La última línea sin `\n` también se entrega al terminar.
    /// `stdout` en el resultado contiene todo lo leído.
    func runStreaming(
        _ executable: String, _ arguments: [String],
        environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult

    /// Igual que `runStreaming`, pero el proceso recibe exactamente `environment`: no hereda nada del entorno de
    /// la app. Lo usa Claude (ver `ClaudeRunner.environmentAllowlist`).
    func runStreamingIsolated(
        _ executable: String, _ arguments: [String],
        environment: [String: String], currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult
}

extension StreamingProcessRunning {
    /// Para runners que no lanzan procesos de verdad (p. ej. los de los tests): igual que `runStreaming`.
    public func runStreamingIsolated(
        _ executable: String, _ arguments: [String],
        environment: [String: String], currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try await runStreaming(executable, arguments, environment: environment, currentDirectory: currentDirectory,
                               timeout: timeout, onStdoutLine: onStdoutLine)
    }
}

public struct SystemProcessRunner: ProcessRunning, StreamingProcessRunning {
    /// Tokens de GitHub que nunca se heredan del entorno de la app: solo llegan a un proceso si se pasan
    /// explícitamente en `environment` (p. ej. `GH_TOKEN` para `gh pr diff`).
    public static let unheritedVariables = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"]

    /// Tiempo entre SIGTERM y SIGKILL (ambos al grupo de procesos).
    public let killGracePeriod: TimeInterval

    /// Dónde se anotan los procesos lanzados y su tarea (ventana Activity, spec I).
    public let registry: ProcessRegistry

    public init(killGracePeriod: TimeInterval = 2, registry: ProcessRegistry = .shared) {
        self.killGracePeriod = killGracePeriod
        self.registry = registry
    }

    public func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        try await execute(executable, arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout, onStdoutLine: nil)
    }

    public func runStreaming(
        _ executable: String, _ arguments: [String],
        environment: [String: String]?, currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try await execute(executable, arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout, onStdoutLine: onStdoutLine)
    }

    public func runStreamingIsolated(
        _ executable: String, _ arguments: [String],
        environment: [String: String], currentDirectory: URL?, timeout: TimeInterval?,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        try await execute(executable, arguments, environment: environment, inherit: false,
                          currentDirectory: currentDirectory, timeout: timeout, onStdoutLine: onStdoutLine)
    }

    /// Camino único de `run` y `runStreaming`: sin callback no se arma el separador de líneas.
    /// `inherit == false`: el proceso recibe solo `environment` (nada del entorno de la app).
    private func execute(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        inherit: Bool = true,
        currentDirectory: URL?,
        timeout: TimeInterval?,
        onStdoutLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var inherited = inherit ? ProcessInfo.processInfo.environment : [:]
        for key in Self.unheritedVariables { inherited[key] = nil }
        process.environment = inherited.merging(environment ?? [:]) { _, new in new }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let control = ProcessControl(grace: killGracePeriod)
        let command = ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ")

        let activity = ProcessActivity.current
        let registry = self.registry
        let executableName = URL(fileURLWithPath: executable).lastPathComponent

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { _ in control.markExited() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                control.markLaunched(pid: process.processIdentifier)
                let pid = process.processIdentifier
                let registered = RegisteredProcess(pid: pid, executable: executableName, activity: activity, startedAt: Date())
                registry.register(registered)
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { control.stop(.timedOut) }
                }
                DispatchQueue.global().async {
                    var splitter = onStdoutLine.map { LineSplitter(emit: $0) }
                    let (stdout, stderr) = PipeDrainer.drain(
                        out.fileHandleForReading.fileDescriptor,
                        err.fileHandleForReading.fileDescriptor,
                        hasExited: { control.hasExited },
                        onStdout: splitter == nil ? nil : { splitter?.append($0) }
                    )
                    control.waitUntilExited()
                    registry.unregister(registered)
                    // La última línea sin `\n` se entrega solo si el proceso terminó solo: tras un timeout
                    // o una cancelación quedaría cortada a la mitad.
                    if control.stopReason == nil { splitter?.finish() }
                    // Mantiene vivos los pipes (y sus descriptores) hasta terminar de leer.
                    withExtendedLifetime((out, err)) {}
                    switch control.stopReason {
                    case .timedOut:
                        continuation.resume(throwing: PRBarError.timedOut(command: command))
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case nil:
                        continuation.resume(returning: ProcessResult(
                            status: process.terminationStatus,
                            stdout: String(decoding: stdout, as: UTF8.self),
                            stderr: String(decoding: stderr, as: UTF8.self)
                        ))
                    }
                }
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }
}

/// Estado compartido entre el hilo lector, el `terminationHandler`, el timer de timeout y la cancelación.
///
/// Las señales van al grupo de procesos entero (`kill(-pid, …)`): `Process` lanza al hijo como líder de
/// su propio grupo, así que el grupo incluye a sus hijos y nietos (los subagentes de Claude, un `git` o un
/// `gh`), que si no quedarían vivos con ppid 1 trabajando sobre un worktree a punto de borrarse.
///
/// Reuso de PID: el SIGTERM solo se manda mientras el líder no terminó (su pid, y por lo tanto el id del
/// grupo, sigue reservado). El SIGKILL del final del período de gracia se manda aunque el líder ya haya
/// terminado, para alcanzar a los nietos: el id de un grupo no se reasigna mientras quede algún miembro vivo,
/// y si el grupo ya quedó vacío el riesgo se limita a que macOS (que asigna pids en forma secuencial) haya
/// reusado ese pid como líder de un grupo nuevo dentro de esos pocos segundos. Se manda una sola vez.
private final class ProcessControl: @unchecked Sendable {
    enum StopReason { case timedOut, cancelled }

    private struct State {
        var pid: pid_t?
        var exited = false
        var stopReason: StopReason?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let exitSignal = DispatchSemaphore(value: 0)
    private let grace: TimeInterval

    init(grace: TimeInterval) { self.grace = grace }

    var hasExited: Bool { state.withLock { $0.exited } }
    var stopReason: StopReason? { state.withLock { $0.stopReason } }

    func markLaunched(pid: pid_t) {
        // Si la tarea se canceló antes de lanzar el proceso, lo frena ahora.
        let pendingStop = state.withLock { state -> Bool in
            state.pid = pid
            return state.stopReason != nil
        }
        if pendingStop { terminateGroup() }
    }

    func markExited() {
        state.withLock { $0.exited = true }
        exitSignal.signal()
    }

    func waitUntilExited() { exitSignal.wait() }

    func stop(_ reason: StopReason) {
        let shouldSignal = state.withLock { state -> Bool in
            guard state.stopReason == nil, !state.exited else { return false }
            state.stopReason = reason
            return state.pid != nil
        }
        guard shouldSignal else { return }
        terminateGroup()
    }

    /// SIGTERM al grupo ahora (si el líder sigue vivo) y SIGKILL al grupo tras el período de gracia.
    private func terminateGroup() {
        state.withLock { state in
            guard let pid = state.pid, !state.exited else { return }
            kill(-pid, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            guard let pid = state.withLock({ $0.pid }) else { return }
            kill(-pid, SIGKILL)
        }
    }
}

/// Lee stdout y stderr sin bloquearse esperando EOF: si el proceso terminó pero un hijo en background
/// heredó el pipe, se vacía lo que haya y se sigue.
private enum PipeDrainer {
    /// `onStdout` recibe cada bloque de bytes de stdout apenas se lee.
    static func drain(_ outFD: Int32, _ errFD: Int32, hasExited: () -> Bool, onStdout: ((ArraySlice<UInt8>) -> Void)? = nil) -> (Data, Data) {
        var buffers: [Int32: Data] = [outFD: Data(), errFD: Data()]
        var open: Set<Int32> = [outFD, errFD]
        for fd in open { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        func readAvailable(_ fd: Int32) {
            while true {
                let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    buffers[fd, default: Data()].append(contentsOf: chunk[0..<count])
                    if fd == outFD { onStdout?(chunk[0..<count]) }
                } else if count == 0 {
                    open.remove(fd)
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    if errno != EAGAIN { open.remove(fd) }
                    return
                }
            }
        }

        while !open.isEmpty {
            // Se chequea antes de leer: todo lo que escribió el proceso ya está en el pipe.
            let exited = hasExited()
            var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), 100)
            if ready < 0, errno != EINTR { break }
            for fd in open { readAvailable(fd) }
            if exited { break }
        }
        return (buffers[outFD] ?? Data(), buffers[errFD] ?? Data())
    }
}

/// Arma líneas a partir de bloques de bytes. Corta por el byte `\n` (0x0A) y decodifica cada línea completa,
/// así un carácter UTF-8 partido entre dos lecturas no se rompe.
private struct LineSplitter {
    let emit: (String) -> Void
    private var pending: [UInt8] = []

    init(emit: @escaping (String) -> Void) { self.emit = emit }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        var rest = bytes
        while let newline = rest.firstIndex(of: 0x0A) {
            pending.append(contentsOf: rest[rest.startIndex..<newline])
            emit(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: true)
            rest = rest[(newline + 1)...]
        }
        pending.append(contentsOf: rest)
    }

    mutating func finish() {
        guard !pending.isEmpty else { return }
        emit(String(decoding: pending, as: UTF8.self))
        pending.removeAll()
    }
}
