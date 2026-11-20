import ArgumentParser
import Foundation
import PRBarCore

// MARK: - runners (spec J.4)

struct RunnersGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runners", abstract: "Where Claude runs: this Mac or SSH hosts (Settings › Claude › Run On).",
        discussion: "Reviews, fixes and PR chats run on the host with its own git access, Claude login and plugins. GitHub, posting, pushing, merging and Slack stay on this Mac.",
        subcommands: [RunnersList.self, RunnersAdd.self, RunnersSet.self, RunnersRemove.self, RunnersTest.self, RunnersDefault.self],
        defaultSubcommand: RunnersList.self)
}

enum RunnerRender {
    static func row(_ runner: RunnerInfo, now: Date) -> [String] {
        [runner.name + (runner.isDefault ? " (default)" : ""), runner.host, runner.dir, runner.fallback ? "on" : "off",
         runner.lastCheck?.statusSummary(now: now) ?? "not checked"]
    }

    static func table(_ runners: [RunnerInfo], _ output: Output, now: Date = Date()) {
        guard !runners.isEmpty else { return output.line("Claude runs on this Mac. Add a host with `prbar runners add <host>`.") }
        output.table(["Runner", "Host", "Folder", "Fallback", "Status"], runners.map { row($0, now: now) })
        if !runners.contains(where: \.isDefault) { output.line(output.paint("Default: this Mac.", .dim)) }
    }
}

/// Lo que valida la CLI antes de mandar el comando (la app vuelve a validar).
enum RunnerValidation {
    static func name(_ name: String) throws {
        guard RunnerDestination.isValidName(name) else { throw ValidationError(RunnerConfigError.invalidName(name).localizedDescription) }
    }

    static func dir(_ dir: String) throws {
        guard RunnerDestination.isValidRemoteDir(dir) else {
            throw ValidationError(RunnerConfigError.invalidRemoteDir(dir).localizedDescription)
        }
    }

    /// `local`, `default` (si se permite) o el nombre de un destino.
    static func target(_ value: String, allowDefault: Bool) throws {
        if allowDefault && value == "default" { return }
        guard RunTarget(cliValue: value) != nil else {
            throw ValidationError(allowDefault ? "Use local, a runner’s name or default." : "Use local or a runner’s name.")
        }
    }
}

struct RunnersList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The SSH hosts and their last check (also: prbar runners).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .runnersList }
    func render(_ result: JSONValue, _ output: Output) throws { RunnerRender.table(try result.decode(), output) }
}

struct RunnersAdd: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Add an SSH host (a Host from ~/.ssh/config or user@host[:port]) and test it.",
        discussion: "PRBar never stores passwords: the host needs your SSH key or agent.")
    @Argument(help: "devbox, user@host or user@host:port.") var host: String
    @Option(help: "Its name in PRBar (default: the host).") var name: String?
    @Option(help: "The remote folder PRBar owns (default ~/.prbar).") var dir: String?
    @Flag(help: "Fail instead of running on this Mac when the host is down.") var noFallback = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        do { _ = try SSHEndpoint.parse(host) } catch { throw ValidationError(error.localizedDescription) }
        if let name { try RunnerValidation.name(name) }
        if let dir { try RunnerValidation.dir(dir) }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .runnerAdd(host: host, name: name, dir: dir, fallback: !noFallback) }
    func render(_ result: JSONValue, _ output: Output) throws { RunnerRender.table([try result.decode()], output) }
}

struct RunnersSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change an SSH host’s folder or fallback.")
    @Argument(help: "The runner’s name.") var name: String
    @Option(help: "The remote folder.") var dir: String?
    @Option(help: "on: run on this Mac when the host is down; off: fail.") var fallback: OnOff?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let dir { try RunnerValidation.dir(dir) }
        if dir == nil && fallback == nil { throw ValidationError("Nothing to change: use --dir or --fallback.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .runnerSet(name: name, dir: dir, fallback: fallback?.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws { RunnerRender.table([try result.decode()], output) }
}

struct RunnersRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an SSH host (repos using it go back to Default).")
    @Argument(help: "The runner’s name.") var name: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .runnerRemove(name: name) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Removed \(name). Its folder on the host was left as is.") }
}

struct RunnersTest: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "test", abstract: "Test Connection: tools, folder and Claude’s login on the host.",
        discussion: "Exits with 1 when the check finds problems (also with --json).")
    @Argument(help: "The runner’s name.") var name: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .runnerTest(name: name) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let runner: RunnerInfo = try result.decode()
        guard let check = runner.lastCheck else { return output.line("No result.") }
        let system = [check.os, check.arch].compactMap { $0 }.joined(separator: " ")
        Render.pairs([("Host", runner.host),
                      ("OS", system.isEmpty ? "?" : system),
                      ("git", check.gitVersion ?? "missing"),
                      ("claude", check.claudeVersion ?? "missing"),
                      ("Logged in", check.claudeLoggedIn.map { $0 ? "yes" : "no" } ?? "—"),
                      ("Folder", check.root ?? "—")], output)
        if check.problems.isEmpty {
            output.line(output.paint("✓ Ready", .green))
        } else {
            for problem in check.problems { output.line(output.paint("! " + problem, .red)) }
        }
    }

    /// Exit ≠ 0 si la verificación encontró problemas (también con `--json`).
    func exitCode(for result: JSONValue) throws -> Int32 {
        let runner: RunnerInfo = try result.decode()
        return (runner.lastCheck?.problems.isEmpty ?? false) ? CLIExit.ok : CLIExit.generalError
    }
}

struct RunnersDefault: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "default", abstract: "Where Claude runs for repos set to Default.")
    @Argument(help: "local or a runner’s name.") var target: String
    @OptionGroup var global: GlobalOptions
    func validate() throws { try RunnerValidation.target(target, allowDefault: false) }
    func appCommand(confirmed: Bool) -> AppCommand { .runnerDefault(target: target) }
    func render(_ result: JSONValue, _ output: Output) throws {
        output.line(target == "local" ? "Claude runs on this Mac by default." : "Claude runs on \(target) by default.")
    }
}
