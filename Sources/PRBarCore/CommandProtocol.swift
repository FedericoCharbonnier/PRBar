import Foundation

/// Protocolo entre `prbar` y PRBar.app por el socket (spec C.2): una línea JSON por mensaje.
///
/// 1. La CLI manda `HelloMessage` con su versión de protocolo; la app contesta con la suya o con un error
///    `protocolMismatch` y cierra.
/// 2. Cada pedido es un `CommandRequest`; la app manda cero o más `CommandResponse` con `event` y una final con
///    `ok` + `result` o `error`.
public enum CommandProtocol {
    /// Sube cuando un cambio rompe la compatibilidad entre la CLI y la app.
    /// 2: `merge` lleva el head confirmado (`expectedHeadOid`) y existe `mergePreview`.
    /// 3: se quita `setConfirmMerge` (spec G.1), `mergePreview` trae el resumen del PR y existe `open --merge`.
    /// 4: `listPRs` lleva la pestaña del popover (`--tab`) y existe `openPopover`.
    public static let version = 4

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sin `.prettyPrinted`: la línea nunca tiene `\n`.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func line<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: String) throws -> T {
        try decoder.decode(T.self, from: Data(line.utf8))
    }
}

public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// Versión de quien manda el mensaje (`prbar` o PRBar.app), para los mensajes de error.
    public var version: String

    public init(protocolVersion: Int, version: String) {
        self.protocolVersion = protocolVersion
        self.version = version
    }
}

public struct HelloMessage: Codable, Equatable, Sendable {
    public var hello: Hello

    public init(hello: Hello) {
        self.hello = hello
    }
}

/// Error de un comando. `code` decide el exit code de la CLI (`CLIExit`); `message` es el texto de la UI más el
/// comando sugerido cuando aplica (spec C.6).
public struct CommandFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case invalidUsage, notFound, invalidState, confirmationRequired, failed, cancelled, protocolMismatch, unauthorized
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func protocolMismatch(cli: String, app: String) -> CommandFailure {
        CommandFailure(.protocolMismatch, "prbar \(cli) can't talk to PRBar \(app) — run `prbar update` or reinstall")
    }

    /// El pedido tiene un comando que la app no conoce: `prbar` es más nuevo que la PRBar que está corriendo.
    public static func unknownCommand(app: String) -> CommandFailure {
        CommandFailure(.protocolMismatch, "PRBar \(app) doesn’t know this command — prbar is newer. Restart PRBar (or update it with `prbar update`).")
    }
}

/// Lo que manda la app mientras corre un comando largo (`--wait`, chat, update).
public enum CommandEvent: Codable, Equatable, Sendable {
    /// Una línea de progreso ("Reviewing (2 agents)…").
    case progress(message: String)
    /// Texto parcial (la respuesta del chat en streaming).
    case text(delta: String)
}

public typealias CommandEventSink = @Sendable (CommandEvent) -> Void

public struct CommandResponse: Codable, Equatable, Sendable {
    public var id: Int
    /// `nil` en los eventos.
    public var ok: Bool?
    public var result: JSONValue?
    public var error: CommandFailure?
    public var event: CommandEvent?

    public init(id: Int, ok: Bool? = nil, result: JSONValue? = nil, error: CommandFailure? = nil, event: CommandEvent? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
        self.event = event
    }

    public static func success(id: Int, _ result: JSONValue) -> CommandResponse {
        CommandResponse(id: id, ok: true, result: result)
    }

    public static func failure(id: Int, _ error: CommandFailure) -> CommandResponse {
        CommandResponse(id: id, ok: false, error: error)
    }

    public static func event(id: Int, _ event: CommandEvent) -> CommandResponse {
        CommandResponse(id: id, event: event)
    }
}

public struct CommandRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var command: AppCommand

    public init(id: Int, command: AppCommand) {
        self.id = id
        self.command = command
    }
}
