import Foundation
import os

/// La tarea de PRBar a la que pertenece un proceso (spec I: "Review api#317 · claude"). Se propaga con un
/// `@TaskLocal`: quien arranca una tarea (`JobScheduler`, el updater, Slack) la pone y `SystemProcessRunner` la anota
/// junto al pid de cada proceso que lanza.
public struct ProcessActivity: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case review, respond, chat, instructions, update, slack
    }

    public var kind: Kind
    public var prID: String?
    public var title: String
    /// El host remoto donde corre el trabajo (Plan 14); `nil` = esta Mac.
    public var host: String?
    /// El chat (`ChatSession.id`) de un trabajo `.chat`: Stop busca ese coordinador, no "el chat del PR" (un PR puede
    /// tener el de Review, el de Respond y el de Merge).
    public var chatSessionID: UUID?

    public init(kind: Kind, prID: String? = nil, title: String, host: String? = nil, chatSessionID: UUID? = nil) {
        self.kind = kind
        self.prID = prID
        self.title = title
        self.host = host
        self.chatSessionID = chatSessionID
    }

    @TaskLocal public static var current: ProcessActivity?

    public static func review(_ prID: String) -> ProcessActivity { .init(kind: .review, prID: prID, title: "Review \(shortPR(prID))") }
    public static func respond(_ prID: String) -> ProcessActivity { .init(kind: .respond, prID: prID, title: "Respond \(shortPR(prID))") }
    public static func chat(_ prID: String, sessionID: UUID? = nil) -> ProcessActivity {
        .init(kind: .chat, prID: prID, title: "Chat \(shortPR(prID))", chatSessionID: sessionID)
    }
    public static let instructions = ProcessActivity(kind: .instructions, title: "Instructions chat")
    public static let update = ProcessActivity(kind: .update, title: "Update build")
    public static let slack = ProcessActivity(kind: .slack, title: "Slack")

    /// `acme/api#317` → `api#317`.
    public static func shortPR(_ prID: String) -> String {
        prID.split(separator: "/").last.map(String.init) ?? prID
    }

    public func on(host: String?) -> ProcessActivity {
        var copy = self
        copy.host = host
        return copy
    }
}

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
    public func unregister(pid: Int32) { _ = state.withLock { $0.removeValue(forKey: pid) } }
    public func all() -> [RegisteredProcess] { state.withLock { Array($0.values) }.sorted { $0.pid < $1.pid } }
    public func byPID() -> [Int32: RegisteredProcess] { state.withLock { $0 } }
}
