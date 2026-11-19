import Foundation

/// Un valor JSON cualquiera: el `result` de una respuesta (cada comando devuelve su DTO, ver `CommandResults`).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// `{"ok": true}`: la respuesta de los comandos que no devuelven nada.
    public static let ok = JSONValue.object(["ok": .bool(true)])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// El JSON de `value` (con la codificación del protocolo: fechas ISO 8601).
    public init<T: Encodable>(encoding value: T) throws {
        self = try CommandProtocol.decoder.decode(JSONValue.self, from: CommandProtocol.encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try CommandProtocol.decoder.decode(T.self, from: CommandProtocol.encoder.encode(self))
    }
}
