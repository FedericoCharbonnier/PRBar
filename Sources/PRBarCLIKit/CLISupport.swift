import ArgumentParser
import Darwin
import Foundation
import PRBarCore

/// Códigos de salida de `prbar` (spec C.5 y D.4).
public enum CLIExit {
    public static let ok: Int32 = 0
    public static let generalError: Int32 = 1
    public static let usage: Int32 = 2
    public static let appUnavailable: Int32 = 3
    public static let confirmationRequired: Int32 = 4
    public static let notFound: Int32 = 5
    public static let invalidState: Int32 = 6
    public static let updateAvailable: Int32 = 10
    public static let cancelled: Int32 = 130

    public static func code(for failure: CommandFailure) -> Int32 {
        switch failure.code {
        case .invalidUsage: usage
        case .notFound: notFound
        case .invalidState: invalidState
        case .confirmationRequired: confirmationRequired
        case .cancelled: cancelled
        case .protocolMismatch, .unauthorized: appUnavailable
        case .failed: generalError
        }
    }
}

/// Lo que importa de la terminal: si hay TTY (prompts) y si se usan colores.
public struct Terminal: Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool
    public var colors: Bool

    public init(stdinIsTTY: Bool, stdoutIsTTY: Bool, colors: Bool) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
        self.colors = colors
    }

    /// Preguntar solo si hay alguien del otro lado (spec C.5).
    public var isInteractive: Bool { stdinIsTTY && stdoutIsTTY }

    /// Sin terminal ni color (scripts y tests).
    public static let plain = Terminal(stdinIsTTY: false, stdoutIsTTY: false, colors: false)

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Terminal {
        let stdoutTTY = isatty(STDOUT_FILENO) == 1
        return Terminal(stdinIsTTY: isatty(STDIN_FILENO) == 1, stdoutIsTTY: stdoutTTY,
                        colors: colorsEnabled(isTTY: stdoutTTY, environment: environment))
    }

    /// Color solo en una terminal, sin `NO_COLOR` (https://no-color.org) y con un `TERM` que no sea `dumb`.
    public static func colorsEnabled(isTTY: Bool, environment: [String: String]) -> Bool {
        isTTY && (environment["NO_COLOR"] ?? "").isEmpty && environment["TERM"] != "dumb"
    }
}

public enum Style: String {
    case bold = "1", dim = "2", red = "31", green = "32", yellow = "33", violet = "35", cyan = "36"
}

public enum Table {
    /// Columnas separadas por dos espacios y alineadas (la última sin relleno).
    public static func render(headers: [String], rows: [[String]]) -> [String] {
        let all = [headers] + rows
        let widths = headers.indices.map { column in all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0 }
        return all.map { row in
            headers.indices.map { column -> String in
                let cell = row.indices.contains(column) ? row[column] : ""
                guard column < headers.count - 1 else { return cell }
                return cell + String(repeating: " ", count: widths[column] - cell.count)
            }.joined(separator: "  ")
        }
    }
}

/// `--json`: `{"schemaVersion": 1, "data": …}`, claves ordenadas, fechas ISO 8601 (docs/cli.md).
public enum JSONOutput {
    public static let schemaVersion = 1

    private struct Envelope<T: Encodable>: Encodable {
        let schemaVersion: Int
        let data: T
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(schemaVersion: schemaVersion, data: value))
    }
}

/// La salida de un comando: texto (con color si corresponde), JSON, errores y eventos (progreso a stderr; el texto
/// del chat a stdout).
public final class Output {
    public let terminal: Terminal
    public let json: Bool
    private let out: (String) -> Void
    private let err: (String) -> Void

    public static let standardOut: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    public static let standardError: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }

    public init(terminal: Terminal, json: Bool, out: @escaping (String) -> Void = Output.standardOut,
                err: @escaping (String) -> Void = Output.standardError) {
        self.terminal = terminal
        self.json = json
        self.out = out
        self.err = err
    }

    public func write(_ text: String) { out(text) }
    public func line(_ text: String = "") { out(text + "\n") }
    public func error(_ message: String) { err(paint("Error: ", .red, .bold) + message + "\n") }
    public func note(_ message: String) { err(paint(message, .dim) + "\n") }

    public func paint(_ text: String, _ styles: Style...) -> String {
        guard terminal.colors, !styles.isEmpty else { return text }
        return "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m\(text)\u{1B}[0m"
    }

    public func table(_ headers: [String], _ rows: [[String]]) {
        let lines = Table.render(headers: headers, rows: rows)
        guard let header = lines.first else { return }
        line(paint(header, .bold))
        lines.dropFirst().forEach { line($0) }
    }

    public func printJSON<T: Encodable>(_ value: T) throws {
        line(String(decoding: try JSONOutput.encode(value), as: UTF8.self))
    }

    public func event(_ event: CommandEvent) {
        switch event {
        case .progress(let message): note(message)
        case .text(let delta): if !json { write(delta) }
        }
    }
}

/// `on`/`off` en la línea de comandos.
public enum OnOff: String, ExpressibleByArgument, CaseIterable {
    case on, off

    public var isOn: Bool { self == .on }
}

extension PRListFilter: ExpressibleByArgument {}
extension HistoryKind: ExpressibleByArgument {}
extension SettingsTabName: ExpressibleByArgument {}
extension NotificationSettingName: ExpressibleByArgument {}
extension ToolName: ExpressibleByArgument {}
extension SlackToggleName: ExpressibleByArgument {}
extension SlackEmojiKind: ExpressibleByArgument {}
extension SlackTemplateName: ExpressibleByArgument {}

/// Ayuda del argumento `<pr>`.
let prHelp: ArgumentHelp = "owner/repo#N, repo#N or the PR’s URL."

/// Una ruta de la línea de comandos → absoluta (la app no tiene el mismo directorio actual).
func absolutePath(_ raw: String) -> String {
    let expanded = NSString(string: raw).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}
