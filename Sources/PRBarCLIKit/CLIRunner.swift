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
    /// Conecta y, si la app no está corriendo, la abre.
    public var connect: () throws -> AppConnection
    /// Solo conecta (cancelar con Ctrl-C: si la app no está, no hay nada que cancelar).
    public var reconnect: () throws -> AppConnection
    public var ask: (String) -> Bool

    /// `reconnect == nil` = `connect` (los tests nunca abren la app).
    public init(terminal: Terminal, out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                connect: @escaping () throws -> AppConnection, reconnect: (() throws -> AppConnection)? = nil,
                ask: @escaping (String) -> Bool) {
        self.terminal = terminal
        self.out = out
        self.err = err
        self.connect = connect
        self.reconnect = reconnect ?? connect
        self.ask = ask
    }

    public static var live: CLIEnvironment {
        CLIEnvironment(terminal: .current(), out: Output.standardOut, err: Output.standardError,
                       connect: { try AppConnection.open() }, reconnect: { try AppConnection.connect() },
                       ask: Prompt.confirm)
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
                InterruptHandler(cancel: $0, connect: environment.reconnect, err: environment.err)
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

/// Ctrl-C mientras se espera (`--wait`, chat): cancela el job en la app y sale con 130 (spec C.5). El cancel va por
/// una conexión nueva (la de la espera está ocupada) que solo conecta, nunca abre la app, en otro hilo y con un plazo:
/// pasado `deadline` sale igual. Un segundo Ctrl-C sale enseguida.
public final class InterruptHandler: @unchecked Sendable {
    private let cancel: AppCommand
    private let connect: () throws -> AppConnection
    private let err: (String) -> Void
    private let deadline: TimeInterval
    private let terminate: @Sendable (Int32) -> Void
    private let lock = NSLock()
    private var interrupts = 0
    private var finished = false
    private var source: DispatchSourceSignal?

    /// `connect` tiene que ser solo conectar (`AppConnection.connect`), no `open`. `terminate` e
    /// `installsSignalHandler` cambian en los tests.
    public init(cancel: AppCommand, connect: @escaping () throws -> AppConnection, err: @escaping (String) -> Void,
                deadline: TimeInterval = 2, terminate: @escaping @Sendable (Int32) -> Void = { exit($0) },
                installsSignalHandler: Bool = true) {
        self.cancel = cancel
        self.connect = connect
        self.err = err
        self.deadline = deadline
        self.terminate = terminate
        guard installsSignalHandler else { return }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in self?.interrupted() }
        source.resume()
        self.source = source
    }

    /// Lo que hace cada Ctrl-C (público para los tests).
    public func interrupted() {
        lock.lock()
        interrupts += 1
        let first = interrupts == 1
        lock.unlock()
        guard first else { return finish() }
        let cancel = self.cancel
        let connect = self.connect
        Thread.detachNewThread { [self] in
            if let connection = try? connect() {
                _ = try? connection.run(cancel)
                connection.close()
            }
            finish()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { [self] in finish() }
    }

    /// Sale una sola vez (el cancel, el plazo o el segundo Ctrl-C: lo que llegue primero).
    private func finish() {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        err("\nCanceled.\n")
        terminate(CLIExit.cancelled)
    }

    public func remove() {
        source?.cancel()
        source = nil
        signal(SIGINT, SIG_DFL)
    }
}
