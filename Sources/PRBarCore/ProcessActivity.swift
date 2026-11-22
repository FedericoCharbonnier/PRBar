import Foundation
import os

/// Un proceso que lanzó PRBar y sigue vivo.
public struct RegisteredProcess: Equatable, Sendable {
    public var pid: Int32
    public var executable: String
    public var activity: ProcessActivity?
    public var startedAt: Date

    public init(pid: Int32, executable: String, activity: ProcessActivity?, startedAt: Date) {
        self.pid = pid
        self.executable = executable
        self.activity = activity
        self.startedAt = startedAt
    }
}

/// Los procesos vivos que lanzó `SystemProcessRunner`, con su tarea. Seguro entre hilos.
public final class ProcessRegistry: Sendable {
    public static let shared = ProcessRegistry()

    private let state = OSAllocatedUnfairLock(initialState: [Int32: RegisteredProcess]())

    public init() {}

    public func register(_ process: RegisteredProcess) { state.withLock { $0[process.pid] = process } }
    /// Solo si sigue anotado ese mismo proceso: si el pid ya lo reusó otro (que se anotó después), no lo toca.
    public func unregister(_ process: RegisteredProcess) {
        state.withLock { if $0[process.pid] == process { $0[process.pid] = nil } }
    }
    public func all() -> [RegisteredProcess] { state.withLock { Array($0.values) }.sorted { $0.pid < $1.pid } }
    public func byPID() -> [Int32: RegisteredProcess] { state.withLock { $0 } }
}

/// Al salir de la app (M4): lo que sigue vivo de lo que lanzó PRBar recibe SIGTERM (a su grupo); lo que no terminó
/// en `grace` recibe SIGKILL. Mientras tanto corren las cancelaciones que ya se pidieron (p. ej. matar el Claude de un
/// host por ssh), que también se esperan. Sin esto, un `claude` que ignora SIGTERM (o tarda) queda huérfano: el
/// SIGKILL que programa `ProcessControl` nunca llega porque la app ya salió.
public enum ProcessShutdown {
    public static func terminateAll(registry: ProcessRegistry = .shared, grace: TimeInterval = 3,
                                    signal: @Sendable (Int32, Int32) -> Void = { pid, sig in kill(-pid, sig) }) async {
        let deadline = Date().addingTimeInterval(grace)
        var termed: Set<Int32> = []
        while Date() < deadline {
            let alive = registry.all()
            if alive.isEmpty { return }
            // También lo que arrancó después (el ssh que mata el Claude de un host recibe SIGTERM recién al final).
            for process in alive where !termed.contains(process.pid) && !process.isShutdownHelper {
                signal(process.pid, SIGTERM)
                termed.insert(process.pid)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        for process in registry.all() {
            signal(process.pid, SIGTERM)
            signal(process.pid, SIGKILL)
        }
        // Lo justo para que el runner vea los procesos terminados (no bloquea la salida si alguno no se va).
        let after = Date().addingTimeInterval(0.5)
        while Date() < after, !registry.all().isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
    }
}

extension RegisteredProcess {
    /// El `ssh` que mata un trabajo en un host: no se le manda SIGTERM antes del final (cortaría la limpieza).
    var isShutdownHelper: Bool { activity == nil && executable == "ssh" }
}
