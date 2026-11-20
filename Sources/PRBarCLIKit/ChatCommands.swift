import ArgumentParser
import Foundation
import PRBarCore

enum ChatRender {
    static func message(_ message: ChatMessageInfo, _ output: Output, pr: String = "<pr>") {
        switch message.role {
        case "user": output.line(output.paint("you› ", .bold) + message.text)
        case "error": output.line(output.paint("! " + message.text, .red))
        default: output.line(output.paint("claude› ", .violet, .bold) + message.text)
        }
        if let changes = message.changes {
            output.line(output.paint("  \(changes)\(message.undone ? " (undone)" : message.undoable ? " · undo: prbar chat \(pr) --undo" : "")", .dim))
        }
        message.notes.forEach { output.line(output.paint("  \($0)", .dim)) }
        proposals(message, output, pr: pr)
    }

    /// Las tarjetas "Save as rule" (spec E.3) y cómo guardarlas.
    static func proposals(_ message: ChatMessageInfo, _ output: Output, pr: String = "<pr>") {
        for proposal in message.proposals {
            let stages = proposal.appliesTo.map { $0 == .respond ? "fixes" : $0.rawValue }.joined(separator: ", ")
            if let number = proposal.number {
                output.line(output.paint("  Save as rule #\(number) (\(proposal.scope), \(stages)): ", .yellow) + proposal.text)
                output.line(output.paint("    prbar rules proposal save \(pr) \(number) · prbar rules proposal dismiss \(pr) \(number)", .dim))
            } else {
                output.line(output.paint("  Rule (\(proposal.status)): \(proposal.text)", .dim))
            }
        }
    }

    static func transcript(_ info: ChatInfo, _ output: Output) {
        if info.messages.isEmpty { output.line(output.paint("No messages yet.", .dim)) }
        info.messages.forEach { message($0, output, pr: info.pr) }
        if info.readOnly { output.line(output.paint("Read only.", .dim)) }
        if let lock = info.lockReason { output.line(output.paint(lock, .yellow)) }
    }

    /// Después de `chat send`: la respuesta (si no se vio en streaming) y sus cambios.
    static func reply(_ info: ChatInfo, _ output: Output) {
        guard let last = info.messages.last(where: { $0.role != "user" }) else { return }
        if info.streamed && last.role == "assistant" {
            output.line()
            if let changes = last.changes { output.line(output.paint("  \(changes)", .dim)) }
            last.notes.forEach { output.line(output.paint("  \($0)", .dim)) }
            proposals(last, output, pr: info.pr)
        } else {
            message(last, output, pr: info.pr)
        }
    }
}

struct ChatCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat", abstract: "Chat with Claude about a review or a Respond analysis.",
        discussion: "Without a message, in a terminal: an interactive chat (/undo, /show, /stop, /quit). Without a terminal the message is read from stdin.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "The message.") var message: String?
    @Flag(help: "Undo the last change Claude made.") var undo = false
    @Flag(help: "Print the conversation.") var show = false
    @Flag(help: "Stop the answer that’s running.") var stop = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [message != nil, undo, show, stop].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use one of: a message, --undo, --show or --stop.")
        }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard message == nil, !undo, !show, !stop else { return }
        message = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if undo { return .chatUndo(pr: pr, confirmed: confirmed) }
        if show { return .chatShow(pr: pr) }
        if stop { return .chatStop(pr: pr) }
        return .chatSend(pr: pr, message: message ?? "")
    }

    var cancelCommand: AppCommand? { message != nil ? .chatStop(pr: pr) : nil }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: ChatInfo = try result.decode()
        if show { ChatRender.transcript(info, output) } else if stop { output.line("Stopped.") } else { ChatRender.reply(info, output) }
    }

    mutating func run() throws {
        let terminal = Terminal.current()
        if message == nil && !undo && !show && !stop && terminal.isInteractive && !global.json {
            let pr = pr
            return try ChatREPL.run(show: .chatShow(pr: pr), send: { .chatSend(pr: pr, message: $0) },
                                    undo: { .chatUndo(pr: pr, confirmed: $0) }, stop: .chatStop(pr: pr))
        }
        do {
            try CLIRunner.run(self)
        } catch let exit as ExitCode where exit.rawValue == CLIExit.confirmationRequired && undo && terminal.isInteractive {
            // B.6: deshacer pisaría ediciones manuales; la app lo dijo y acá se pregunta.
            guard Prompt.confirm("Undo anyway?") else { throw ExitCode(CLIExit.cancelled) }
            var confirmed = self
            confirmed.global.yes = true
            try CLIRunner.run(confirmed)
        }
    }
}

/// `prbar chat <pr>` (y `prbar rules chat`) en una terminal: la conversación con streaming. Ctrl-C mientras Claude
/// contesta lo detiene (y sale con 130); Ctrl-D o `/quit` salen. Una línea que termina en `\` sigue en la próxima.
enum ChatREPL {
    static func run(show: AppCommand, send: (String) -> AppCommand, undo: (Bool) -> AppCommand, stop: AppCommand,
                    hint: String = "Type a message") throws {
        let environment = CLIEnvironment.live
        let output = Output(terminal: environment.terminal, json: false)
        do {
            let connection = try environment.connect()
            defer { connection.close() }
            ChatRender.transcript(try connection.run(show).decode(), output)
            output.note("\(hint) (end a line with \\ to continue). /undo, /show, /stop, /quit.")
            while true {
                output.write(output.paint("you› ", .bold))
                guard var text = readLine() else { output.line(); return }
                while text.hasSuffix("\\"), let more = readLine() { text = String(text.dropLast()) + "\n" + more }
                switch text.trimmingCharacters(in: .whitespaces) {
                case "":
                    continue
                case "/quit", "/exit":
                    return
                case "/show":
                    ChatRender.transcript(try connection.run(show).decode(), output)
                case "/stop":
                    _ = try? connection.run(stop)
                case "/undo":
                    do {
                        ChatRender.transcript(try connection.run(undo(false)).decode(), output)
                    } catch let failure as CommandFailure where failure.code == .confirmationRequired {
                        if Prompt.confirm("\(failure.message) Undo anyway?") {
                            ChatRender.transcript(try connection.run(undo(true)).decode(), output)
                        }
                    } catch let failure as CommandFailure {
                        output.error(failure.message)
                    }
                default:
                    let interrupt = InterruptHandler(cancel: stop, connect: environment.reconnect, err: environment.err)
                    defer { interrupt.remove() }
                    output.write(output.paint("claude› ", .violet, .bold))
                    do {
                        let info: ChatInfo = try connection.run(send(text)) { output.event($0) }.decode()
                        ChatRender.reply(info, output)
                    } catch let failure as CommandFailure {
                        output.line()
                        output.error(failure.message)
                    }
                }
            }
        } catch let unavailable as AppUnavailable {
            output.error(unavailable.message)
            throw ExitCode(CLIExit.appUnavailable)
        } catch let failure as CommandFailure {
            output.error(failure.message)
            throw ExitCode(CLIExit.code(for: failure))
        }
    }
}
