import Foundation
import PRBarWire

// Marcos de aplicación (spec P.6): viajan dentro de la sesión de Noise, partidos en trozos (`Framing`). JSON con
// `CommandProtocol.encoder` (claves ordenadas, fechas ISO 8601), un objeto plano con `t` = el tipo.

/// Versión del framing y de estos marcos. Cambia solo si cambia el formato de abajo.
public enum RemoteProtocol {
    public static let version = 1
}

public struct RemoteHello: Codable, Equatable, Sendable {
    /// Por qué el otro lado no puede seguir (solo en el `hello` de la Mac).
    public enum Incompatibility: String, Codable, Sendable {
        /// El teléfono es más nuevo que la Mac: "Update PRBar on your Mac".
        case updateMac
        /// El teléfono es más viejo que lo que acepta la Mac: "Update PRBar on this iPhone".
        case updateIPhone
    }

    public var remoteProtocol: Int
    public var commandProtocol: Int
    public var appVersion: String
    public var deviceName: String?
    public var macName: String?
    public var incompatible: Incompatibility?

    public init(remoteProtocol: Int = RemoteProtocol.version, commandProtocol: Int = CommandProtocol.version,
                appVersion: String, deviceName: String? = nil, macName: String? = nil,
                incompatible: Incompatibility? = nil) {
        self.remoteProtocol = remoteProtocol
        self.commandProtocol = commandProtocol
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.macName = macName
        self.incompatible = incompatible
    }
}

public struct RemoteRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var sentAt: Date
    /// Los bytes JSON del `AppCommand` tal cual se firmaron (P.8): la Mac hashea esto y recién después decodifica.
    public var cmd: Data
    public var presence: PresenceProof?

    public init(id: Int, sentAt: Date, cmd: Data, presence: PresenceProof? = nil) {
        self.id = id
        self.sentAt = sentAt
        self.cmd = cmd
        self.presence = presence
    }

    public init(id: Int, sentAt: Date, command: AppCommand, presence: PresenceProof? = nil) throws {
        self.init(id: id, sentAt: sentAt, cmd: try CommandProtocol.encoder.encode(command), presence: presence)
    }

    public func command() throws -> AppCommand {
        try CommandProtocol.decoder.decode(AppCommand.self, from: cmd)
    }
}

public struct RemoteStateUpdate: Codable, Equatable, Sendable {
    public var topic: String
    public var rev: Int
    public var data: JSONValue

    public init(topic: String, rev: Int, data: JSONValue) {
        self.topic = topic
        self.rev = rev
        self.data = data
    }
}

public enum RemoteFrame: Equatable, Sendable {
    case hello(RemoteHello)
    case req(RemoteRequest)
    case res(CommandResponse)
    case sub(topics: [String])
    case state(RemoteStateUpdate)
    case chatDelta(pr: String, text: String)
    case unpair
    case presencePolicy(requirePresence: Bool, gated: [AppCommand.Name])
    case bye(reason: String?)
    /// Un tipo que esta versión no conoce: se ignora (no rompe la sesión).
    case unknown(String)

    public var type: String {
        switch self {
        case .hello: "hello"
        case .req: "req"
        case .res: "res"
        case .sub: "sub"
        case .state: "state"
        case .chatDelta: "chatDelta"
        case .unpair: "unpair"
        case .presencePolicy: "presencePolicy"
        case .bye: "bye"
        case .unknown(let t): t
        }
    }

    public func encoded() throws -> Data { try CommandProtocol.encoder.encode(self) }

    public static func decode(_ data: Data) throws -> RemoteFrame {
        try CommandProtocol.decoder.decode(RemoteFrame.self, from: data)
    }
}

extension RemoteFrame: Codable {
    private enum Keys: String, CodingKey { case t, topics, pr, text, requirePresence, gated, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "hello": self = .hello(try RemoteHello(from: decoder))
        case "req": self = .req(try RemoteRequest(from: decoder))
        case "res": self = .res(try CommandResponse(from: decoder))
        case "sub": self = .sub(topics: try c.decode([String].self, forKey: .topics))
        case "state": self = .state(try RemoteStateUpdate(from: decoder))
        case "chatDelta": self = .chatDelta(pr: try c.decode(String.self, forKey: .pr), text: try c.decode(String.self, forKey: .text))
        case "unpair": self = .unpair
        case "presencePolicy":
            // Un nombre de comando que esta versión no conoce no rompe el marco.
            let names = try c.decode([String].self, forKey: .gated)
            self = .presencePolicy(requirePresence: try c.decode(Bool.self, forKey: .requirePresence),
                                   gated: names.compactMap(AppCommand.Name.init(rawValue:)))
        case "bye": self = .bye(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        default: self = .unknown(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .t)
        switch self {
        case .hello(let hello): try hello.encode(to: encoder)
        case .req(let request): try request.encode(to: encoder)
        case .res(let response): try response.encode(to: encoder)
        case .sub(let topics): try c.encode(topics, forKey: .topics)
        case .state(let update): try update.encode(to: encoder)
        case .chatDelta(let pr, let text):
            try c.encode(pr, forKey: .pr)
            try c.encode(text, forKey: .text)
        case .presencePolicy(let requirePresence, let gated):
            try c.encode(requirePresence, forKey: .requirePresence)
            try c.encode(gated, forKey: .gated)
        case .bye(let reason): try c.encodeIfPresent(reason, forKey: .reason)
        case .unpair, .unknown: break
        }
    }
}
