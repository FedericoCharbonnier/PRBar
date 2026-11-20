import Foundation
import PRBarRemoteKit
import PRBarWire

/// What the phone asks the Mac to do. Almost everything is an `AppCommand`; the other cases are commands the spec
/// names (`ciFix`/`usage` from `feat/ci-cost`, `remoteSetPresenceRequirement` from plan 18, spec Q.3) that this
/// branch's `PRBarWire` does not have yet. They encode exactly like `AppCommand`'s synthesized `Codable`
/// (`{"<case>":{…}}`), so once those cases exist the live transport sends `.app(…)` and these cases go away.
public enum RemoteCommand: Equatable, Sendable {
    case app(AppCommand)
    case ciFix(pr: String, wait: Bool)
    case usage(month: String?)
    case remoteSetPresenceRequirement(enabled: Bool)

    public var name: String {
        switch self {
        case .app(let command): command.name.rawValue
        case .ciFix: "ciFix"
        case .usage: "usage"
        case .remoteSetPresenceRequirement: "remoteSetPresenceRequirement"
        }
    }

    /// Spec P.7/P.8: the phone asks for Face ID exactly where the Mac will demand it.
    public var decision: RemotePolicy.Decision {
        switch self {
        case .app(let command): RemotePolicy.decide(command)
        case .ciFix, .usage: .allowed
        // Turning the requirement on is free; turning it off is gated.
        case .remoteSetPresenceRequirement(let enabled): enabled ? .allowed : .gated
        }
    }

    public var needsPresence: Bool { decision == .gated }

    /// The bytes that travel in `req.cmd` and that a presence proof signs (spec P.6, P.8).
    public func commandBytes() throws -> Data {
        switch self {
        case .app(let command):
            return try CommandProtocol.encoder.encode(command)
        case .ciFix(let pr, let wait):
            return try CommandProtocol.encoder.encode(["ciFix": CIFixArgs(pr: pr, wait: wait)])
        case .usage(let month):
            return try CommandProtocol.encoder.encode(["usage": UsageArgs(month: month)])
        case .remoteSetPresenceRequirement(let enabled):
            return try CommandProtocol.encoder.encode(["remoteSetPresenceRequirement": PresenceArgs(enabled: enabled)])
        }
    }

    private struct CIFixArgs: Encodable { var pr: String; var wait: Bool }
    private struct UsageArgs: Encodable { var month: String? }
    private struct PresenceArgs: Encodable { var enabled: Bool }
}
