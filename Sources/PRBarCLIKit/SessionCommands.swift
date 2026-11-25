import ArgumentParser
import Foundation
import PRBarCore

extension SessionJob: ExpressibleByArgument {}

/// `prbar session` (spec T.4): Claude's sessions of a PR, resumed in your terminal.
struct SessionGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session", abstract: "Claude’s sessions of a PR, resumed in your terminal.",
        discussion: "The sessions of the PR’s last review and of its last Respond or Fix CI (they share the branch’s folder) whose folder PRBar kept. They open with claude --resume in the terminal of Settings › General (prbar config set terminal).",
        subcommands: [SessionList.self, SessionOpen.self])
}

enum SessionRender {
    static func list(_ sessions: [ClaudeSessionInfo], _ output: Output) {
        guard !sessions.isEmpty else { return output.line("No Claude session for this PR yet.") }
        output.table(["#", "Session", "Kind", "Machine", "Folder", "Started"], sessions.map {
            ["\($0.number)", $0.label + ($0.busy ? " (Claude is working on it)" : ""), $0.kind, $0.machine, $0.directory,
             Render.date($0.startedAt)]
        })
    }
}

struct SessionList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The PR’s Claude sessions you can open.")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .sessionList(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { SessionRender.list(try result.decode(), output) }
}

struct SessionOpen: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open one in your terminal (without options, the most recent).",
        discussion: "Exit 6 if the PR has none or PRBar is working in its folder.")
    @Argument(help: prHelp) var pr: String
    @Option(help: "review, respond, ci-fix or conflicts: that job’s most recent session.") var job: SessionJob?
    @Option(help: "The session’s number in prbar session list.") var run: Int?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let run, run < 1 { throw ValidationError("--run takes the session’s number in prbar session list (1 or more).") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .sessionOpen(pr: pr, job: job, run: run) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let session: ClaudeSessionInfo = try result.decode()
        output.line("Opened \(session.label) (\(session.machine)).")
    }
}
