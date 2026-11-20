import Foundation
import PRBarRemoteKit
import PRBarWire

/// What the phone asks the Mac to do is an `AppCommand` (spec P.6). `remoteSetPresenceRequirement` goes with an empty
/// `device`: the Mac's bridge replaces it with the session's device (spec Q.4).
public extension AppCommand {
    /// Spec P.7/P.8: the phone asks for Face ID exactly where the Mac will demand it.
    var needsPresence: Bool { RemotePolicy.decide(self) == .gated }

    /// The bytes that travel in `req.cmd` and that a presence proof signs (spec P.6, P.8).
    func commandBytes() throws -> Data {
        try CommandProtocol.encoder.encode(self)
    }

    /// "Require Face ID for merge, push, approve and tests" from this iPhone.
    static func presenceRequirement(enabled: Bool) -> AppCommand {
        .remoteSetPresenceRequirement(device: "", enabled: enabled)
    }
}
