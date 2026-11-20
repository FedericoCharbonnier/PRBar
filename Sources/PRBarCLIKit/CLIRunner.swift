import ArgumentParser
import Darwin
import Foundation
import PRBarCore

/// Opciones de todos los comandos remotos.
public struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable output ({\"schemaVersion\": 1, \"data\": …}, see docs/cli.md).")
    public var json = false

    @Flag(name: [.short, .long], help: "Don’t ask: confirm actions that post, push or approve.")
    public var yes = false

    public init() {}
}

public enum ConfirmationPolicy {
    /// Sin terminal hace falta `--yes` (publicar, pushear, aprobar, mensaje de prueba de Slack).
    case always
    /// Pregunta en la terminal; en scripts sigue sin preguntar (lo que la UI confirma pero no publica nada).
    case interactiveOnly
}

/// Un comando que ejecuta la app: arma el `AppCommand`, lo manda y muestra el resultado.
public protocol RemoteCommand: ParsableCommand {
    var global: GlobalOptions { get }
    /// `confirmed`: el usuario confirmó (`--yes` o la pregunta de la terminal).
    func appCommand(confirmed: Bool) throws -> AppCommand
    /// Antes de armar el comando (p. ej. abrir `$EDITOR` con el texto actual).
    mutating func prepare(_ connection: AppConnection, _ output: Output) throws
    /// La pregunta de confirmación (`nil` = no hace falta). Puede mostrar un resumen o una lista interactiva.
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String?
    var confirmationPolicy: ConfirmationPolicy { get }
    /// Lo que cancela el job si el usuario aprieta Ctrl-C mientras espera (`--wait`).
    var cancelCommand: AppCommand? { get }
    func render(_ result: JSONValue, _ output: Output) throws
}

extension RemoteCommand {
    public mutating func prepare(_ connection: AppConnection, _ output: Output) throws {}
    public func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? { nil }
    public var confirmationPolicy: ConfirmationPolicy { .always }
    public var cancelCommand: AppCommand? { nil }
    public func render(_ result: JSONValue, _ output: Output) throws { output.line("Done.") }

    public mutating func run() throws {
        try CLIRunner.run(self)
    }
}

/// Lo que usa `CLIRunner` del mundo exterior (los tests lo reemplazan).
public struct CLIEnvironment {
    public var terminal: Terminal
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var connect: () throws -> AppConnection
    public var ask: (String) -> Bool

    public init(terminal: Terminal, out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                connect: @escaping () throws -> AppConnection, ask: @escaping (String) -> Bool) {
        self.terminal = terminal
        self.out = out
        self.err = err
        self.connect = connect
        self.ask = ask
    }

    public static var live: CLIEnvironment {
        CLIEnvironment(terminal: .current(), out: Output.standardOut, err: Output.standardError,
                       connect: { try AppConnection.open() }, ask: Prompt.confirm)
    }
}

public enum CLIRunner {
    public static func run<C: RemoteCommand>(_ command: C, environment: CLIEnvironment = .live) throws {
        var command = command
        let output = Output(terminal: environment.terminal, json: command.global.json, out: environment.out,
                            err: environment.err)
        do {
            let connection = try environment.connect()
            defer { connection.close() }
            try command.prepare(connection, output)
            var confirmed = command.global.yes
            if !confirmed, let question = try command.confirmation(connection, output) {
                if output.terminal.isInteractive && !output.json {
                    guard environment.ask(question) else { throw CommandFailure(.cancelled, "Canceled.") }
                    confirmed = true
                } else if command.confirmationPolicy == .always {
                    throw CommandFailure(.confirmationRequired, "\(question) Run it again with --yes to confirm.")
                } else {
                    confirmed = true
                }
            }
            let request = try command.appCommand(confirmed: confirmed)
            let interrupt = command.cancelCommand.map {
                InterruptHandler(cancel: $0, connect: environment.connect, err: environment.err)
            }
            defer { interrupt?.remove() }
            let result = try connection.run(request) { output.event($0) }
            if output.json {
                try output.printJSON(result)
            } else {
                try command.render(result, output)
            }
        } catch let failure as CommandFailure {
            output.error(failure.message)
            throw ExitCode(CLIExit.code(for: failure))
        } catch let unavailable as AppUnavailable {
            output.error(unavailable.message)
            throw ExitCode(CLIExit.appUnavailable)
        }
    }
}

/// Ctrl-C mientras se espera (`--wait`, chat): cancela el job en la app y sale con 130 (spec C.5).
final class InterruptHandler {
    private let source: DispatchSourceSignal

    init(cancel: AppCommand, connect: @escaping () throws -> AppConnection, err: @escaping (String) -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            if let connection = try? connect() {
                _ = try? connection.run(cancel)
                connection.close()
            }
            err("\nCanceled.\n")
            exit(CLIExit.cancelled)
        }
        source.resume()
    }

    func remove() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
