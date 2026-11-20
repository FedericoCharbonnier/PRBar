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
