import Foundation

public enum RespondStageKind: String, CaseIterable, Sendable {
    case analyzing, implementing, testing

    public var title: String {
        switch self {
        case .analyzing: "Analyzing"
        case .implementing: "Implementing"
        case .testing: "Running tests"
        }
    }
}

public enum RespondStageStatus: Equatable, Sendable { case pending, running, done, failed }

public struct RespondStage: Equatable, Sendable {
    public let kind: RespondStageKind
    public let status: RespondStageStatus
    public let startedAt: Date?
    public let finishedAt: Date?

    /// Segundos que lleva (corriendo) o que llevó (terminada); nil si no se sabe.
    public func duration(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// Las tres etapas de la tarjeta de progreso de Respond / Fix CI. `AppModel` llama a `note` cada vez que cambia la fase
/// de un PR (los tiempos no viven en `RespondPhase`).
public struct RespondStageTimeline: Equatable, Sendable {
    public private(set) var starts: [RespondStageKind: Date] = [:]
    public private(set) var ends: [RespondStageKind: Date] = [:]

    public init() {}

    static func current(_ phase: RespondPhase?, runningTests: Bool) -> RespondStageKind? {
        switch phase {
        case .queued?, .preparing?, .analyzing?: .analyzing
        case .implementing?: .implementing
        case .readyToPush? where runningTests: .testing
        default: nil
        }
    }

    public mutating func note(phase: RespondPhase?, runningTests: Bool, at date: Date) {
        guard let kind = Self.current(phase, runningTests: runningTests) else {
            for open in starts.keys where ends[open] == nil { ends[open] = date }
            return
        }
        if starts[kind] == nil { starts[kind] = date }
        for earlier in RespondStageKind.allCases.prefix(while: { $0 != kind }) where starts[earlier] != nil && ends[earlier] == nil {
            ends[earlier] = date
        }
    }

    public func stages(phase: RespondPhase?, runningTests: Bool, testsRan: Bool) -> [RespondStage] {
        let current = Self.current(phase, runningTests: runningTests)
        let reached: RespondStageKind? = switch phase {
        case .ready?: .analyzing
        case .readyToPush?, .pushing?, .done?: testsRan || runningTests ? .testing : .implementing
        default: current
        }
        let failedAt: RespondStageKind? = if case .failed? = phase {
            RespondStageKind.allCases.last { starts[$0] != nil } ?? .analyzing
        } else { nil }
        return RespondStageKind.allCases.map { kind in
            let status: RespondStageStatus
            if kind == failedAt { status = .failed }
            else if kind == current { status = .running }
            else if let failedAt, kind.order < failedAt.order { status = .done }
            else if let reached, kind.order <= reached.order, failedAt == nil { status = .done }
            else { status = .pending }
            return RespondStage(kind: kind, status: status, startedAt: starts[kind], finishedAt: ends[kind])
        }
    }
}

extension RespondStageKind {
    var order: Int { RespondStageKind.allCases.firstIndex(of: self)! }
}
