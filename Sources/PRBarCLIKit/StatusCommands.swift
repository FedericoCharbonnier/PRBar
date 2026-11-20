import ArgumentParser
import Foundation
import PRBarCore

struct StatusCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "What PRBar shows in the menu bar.")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .status }

    func render(_ result: JSONValue, _ output: Output) throws {
        let status: StatusInfo = try result.decode()
        var header = "PRBar \(status.appVersion)"
        if status.refreshing {
            header += " · updating…"
        } else if status.offline {
            header += " · offline"
        } else if let fetchedAt = status.fetchedAt {
            header += " · updated \(Render.age(fetchedAt))"
        }
        if let until = status.rateLimitedUntil, until > Date() { header += " · GitHub rate limit until \(ClockTime.hhmm(until))" }
        output.line(output.paint(header, .bold))
        output.table(["Section", "PRs"], PRCategory.allCases.map { [$0.title, String(status.counts[$0.rawValue] ?? 0)] })
        if !status.jobs.isEmpty {
            output.line()
            output.table(["Running", "Kind", "Phase"], status.jobs.map { [$0.pr, $0.kind, $0.phase] })
        }
        for issue in status.issues + status.slackIssues { output.line(output.paint("! " + issue, .red)) }
        let missing = status.tools.filter { $0.path == nil }.map(\.name)
        if !missing.isEmpty {
            output.line(output.paint("Missing tools: \(missing.joined(separator: ", ")). Run `prbar doctor`.", .yellow))
        }
    }
}

/// Comandos que no necesitan la app (spec C.2): `doctor`, `version`, `completion`, `app start`, `app logs`,
/// `repo open`, `notify system-settings`.
public protocol LocalCommand: ParsableCommand {}

struct PRsCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "prs", abstract: "The PRs in the menu bar.")
    @Option(help: "Only one section: to-review, updated, mine (my PRs with feedback), ready-to-merge or other.") var list: PRListFilter?
    @Option(help: "Only this account’s PRs.") var account: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .listPRs(list: list, account: account) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let prs: [PRInfo] = try result.decode()
        guard !prs.isEmpty else { return output.line("No PRs.") }
        output.table(["PR", "Title", "Author", "Section", "CI", "PRBar"], prs.map { pr in
            let prbar = [pr.review.map { "review: \($0)" }, pr.respond.map { "respond: \($0)" },
                         pr.merge.map { "merge: \($0)" }].compactMap { $0 }
            return [pr.id, Render.truncate(pr.title, 50), pr.author, pr.category, pr.ci, prbar.joined(separator: ", ")]
        })
        for pr in prs {
            if let error = pr.mergeError { output.line(output.paint("! \(pr.id): \(error)", .red)) }
        }
    }
}

struct RefreshCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "refresh", abstract: "Refresh the PRs now (⌘R).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .refresh }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Refreshed.") }
}

enum OpenTargetFlag: String, EnumerableFlag {
    case browser, review, respond, posted, worktree, merge

    var target: OpenTarget { OpenTarget(rawValue: rawValue) ?? .browser }

    static func help(for value: OpenTargetFlag) -> ArgumentHelp? {
        switch value {
        case .browser: "The PR on GitHub (default)."
        case .review: "Its Review window."
        case .respond: "Its Respond window."
        case .posted: "The posted review on GitHub."
        case .worktree: "The Respond worktree in Finder."
        case .merge: "Its Merge window (a PR of yours that’s Ready to Merge)."
        }
    }
}

struct OpenCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a PR on GitHub, or its window in PRBar.")
    @Argument(help: prHelp) var pr: String
    @Flag var target: OpenTargetFlag = .browser
    @Flag(help: "Copy the PR’s link instead of opening it (Copy Link).") var copy = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if copy && target != .browser { throw ValidationError("--copy only copies the PR’s link.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { copy ? .resolvePR(pr: pr) : .open(pr: pr, target: target.target) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let link: PRLink = try result.decode()
        if copy {
            try Pasteboard.copy(link.url.absoluteString)
            output.line("Copied \(link.url.absoluteString)")
        } else {
            output.line(link.url.isFileURL ? link.url.path : link.url.absoluteString)
        }
    }
}

struct HistoryGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Claude’s reviews, feedback responses and merges.",
        subcommands: [HistoryList.self, HistoryShow.self, HistoryReopen.self], defaultSubcommand: HistoryList.self)
}

struct HistoryList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the history (also: prbar history).")
    @Option(help: "Only this repo (owner/repo).") var repo: String?
    @Option(help: "review, respond or merge.") var kind: HistoryKind?
    @Option(help: "Title, repo or number (like the window’s search).") var search: String?
    @Option(help: "At most this many records (default 50).") var limit: Int?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .history(repo: repo, kind: kind, limit: limit, search: search) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let entries: [HistoryEntryInfo] = try result.decode()
        guard !entries.isEmpty else { return output.line("No history.") }
        output.table(["ID", "Kind", "PR", "Title", "Status", "Started"], entries.map {
            [String($0.id.uuidString.prefix(8)).lowercased(), $0.kind.rawValue, $0.pr, Render.truncate($0.title, 40), $0.status,
             Render.date($0.startedAt)]
        })
    }
}

struct HistoryShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One record (id or its first characters).")
    @Argument(help: "The record’s id (at least 4 characters).") var id: String
    @Flag(help: "Open Claude’s log of the run (Show Log).") var openLog = false
    @Flag(help: "Show Claude’s log in Finder.") var revealLog = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .historyShow(id: id) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let detail: HistoryDetail = try result.decode()
        let entry = detail.entry
        output.line(output.paint("\(entry.pr) · \(entry.kind.rawValue) · \(entry.status)", .bold))
        output.line(entry.title)
        var pairs: [(String, String)] = [("PR", detail.prURL.absoluteString), ("Started", Render.date(entry.startedAt))]
        if let action = detail.action { pairs.append(("Action", action)) }
        if let method = detail.mergeMethod { pairs.append(("Method", method.rawValue)) }
        if let head = detail.headOid { pairs.append(("Head", String(head.prefix(7)))) }
        if let url = detail.reviewURL { pairs.append(("Review", url.absoluteString)) }
        if let error = detail.errorMessage { pairs.append(("Error", error)) }
        if let log = detail.logPath { pairs.append(("Log", log)) }
        if detail.canReopen { pairs.append(("Open to post", "prbar history reopen \(id)")) }
        if detail.canOpen { pairs.append(("Response", "prbar open \(entry.pr) --respond")) }
        Render.pairs(pairs, output)
        if let summary = detail.summary, !summary.isEmpty { output.line(); output.line(summary) }
        for finding in detail.findings {
            output.line("\(finding.included ? "✓" : "·") #\(finding.number) \(finding.severity.rawValue) \(finding.location) — \(finding.title)")
        }
        if let general = detail.generalComment { output.line("General comment: \(general)") }
        for reply in detail.replies { output.line("↩ \(reply.location) \(reply.url.absoluteString)") }
        if let chat = detail.chat {
            output.line()
            output.line(output.paint("Chat (\(chat.messages.count) message\(chat.messages.count == 1 ? "" : "s"))", .bold))
            ChatRender.transcript(chat, output)
        }
        if openLog || revealLog {
            guard let log = detail.logPath else { throw CommandFailure(.notFound, "This record has no log.") }
            try LocalOpen.open(log, reveal: revealLog)
        }
    }
}

struct HistoryReopen: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reopen", abstract: "Open a ready review from the history to post it (“Open to Post”).")
    @Argument(help: "The record’s id.") var id: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .historyReopen(id: id) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Opened the review window.") }
}

struct AppGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app", abstract: "PRBar.app itself.",
        subcommands: [AppStart.self, AppQuit.self, AppSettings.self, AppHistory.self, AppLogs.self])
}

struct AppStart: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Open PRBar in the background.")

    func run() throws {
        do {
            let connection = try AppConnection.open()
            print("PRBar \(connection.appVersion) is running.")
            connection.close()
        } catch let unavailable as AppUnavailable {
            FileHandle.standardError.write(Data("Error: \(unavailable.message)\n".utf8))
            throw ExitCode(CLIExit.appUnavailable)
        }
    }
}

struct AppQuit: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "quit", abstract: "Quit PRBar (⌘Q).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .quit }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("PRBar is quitting.") }
}

struct AppSettings: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Open Settings (⌘,), optionally on a tab.")
    @Argument(help: "general, claude, instructions, accounts, repos or slack.") var tab: SettingsTabName?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .openSettings(tab: tab) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Opened Settings.") }
}

struct AppHistory: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "Open the History window (⌘Y), optionally on a record.")
    @Argument(help: "A record’s id.") var id: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .openHistory(id: id) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Opened History.") }
}

enum LogKind: String, EnumerableFlag {
    case app, slack, update, instructions

    static func help(for value: LogKind) -> ArgumentHelp? {
        switch value {
        case .app: "PRBar’s log (default)."
        case .slack: "The Slack connector’s log (Settings › Slack › Show Log)."
        case .update: "The last update’s log (Show Log in the update window)."
        case .instructions: "The Instructions chat’s log (Show Log under an error in that chat)."
        }
    }

    var url: URL {
        switch self {
        case .app: AppPaths.logFile
        case .slack: AppPaths.slackConnectorLog
        case .update: AppPaths.updateLog
        case .instructions: AppPaths.instructionsChatLog
        }
    }
}

struct AppLogs: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Open PRBar’s log (works without the app).")
    @Flag var kind: LogKind = .app
    @Flag(help: "Only print the path.") var path = false

    func run() throws {
        let url = kind.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("Error: There’s no log yet at \(url.path).\n".utf8))
            throw ExitCode(CLIExit.notFound)
        }
        if path { print(url.path) } else { try LocalOpen.open(url.path) }
    }
}

struct VersionCommand: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "prbar’s and PRBar.app’s versions (About PRBar).")
    @Flag(help: "Machine-readable output.") var json = false

    func run() throws {
        let versions = VersionReport.versions(cli: AppConnection.cliVersion) { try AppConnection.connect() }
        let output = Output(terminal: .current(), json: json)
        if json { return try output.printJSON(versions) }
        VersionReport.lines(versions).forEach { output.line($0) }
    }
}

/// `prbar version`: distingue "la app no corre" de "corre pero no puede hablar con este prbar".
public enum VersionReport {
    public struct Versions: Codable, Equatable {
        public let cli: String
        public let app: String?
        /// Por qué no se pudo hablar con la app que está corriendo (p. ej. versiones de protocolo distintas).
        public let error: String?

        public init(cli: String, app: String?, error: String?) {
            self.cli = cli
            self.app = app
            self.error = error
        }
    }

    public static func versions(cli: String, connect: () throws -> AppConnection) -> Versions {
        do {
            let connection = try connect()
            defer { connection.close() }
            return Versions(cli: cli, app: connection.appVersion, error: nil)
        } catch let failure as CommandFailure {
            return Versions(cli: cli, app: nil, error: failure.message)
        } catch {
            return Versions(cli: cli, app: nil, error: nil)
        }
    }

    public static func lines(_ versions: Versions) -> [String] {
        let app = if let version = versions.app {
            "PRBar.app \(version) (running)"
        } else if let error = versions.error {
            "PRBar.app is running but this prbar can’t talk to it: \(error)"
        } else {
            "PRBar.app isn’t running"
        }
        return ["prbar \(versions.cli)", app]
    }
}

enum Shell: String, ExpressibleByArgument, CaseIterable { case zsh, bash, fish }

struct CompletionCommand: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Print the shell completion script.",
                                                    discussion: "zsh: prbar completion zsh > ~/.zfunc/_prbar")
    @Argument(help: "zsh, bash or fish.") var shell: Shell

    func run() throws {
        guard let completion = CompletionShell(rawValue: shell.rawValue) else { throw ExitCode(CLIExit.usage) }
        print(PRBarCommand.completionScript(for: completion))
    }
}

public struct DoctorCheck: Codable {
    public let name: String
    public let ok: Bool
    public let detail: String
}

struct DoctorCommand: AsyncParsableCommand, LocalCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check PRBar’s installation (works without the app).")
    @Flag(help: "Machine-readable output.") var json = false

    func run() async throws {
        var checks: [DoctorCheck] = []
        let app = AppLauncher.appBundle()
        checks.append(DoctorCheck(name: "PRBar.app", ok: app != nil,
                                  detail: app?.path ?? "Not found. Install it with Scripts/bundle.sh --install."))
        do {
            let connection = try AppConnection.connect()
            checks.append(DoctorCheck(name: "App", ok: true, detail: "Running, PRBar \(connection.appVersion)"))
            connection.close()
        } catch let failure as CommandFailure {
            checks.append(DoctorCheck(name: "App", ok: false, detail: failure.message))
        } catch {
            checks.append(DoctorCheck(name: "App", ok: true, detail: "Not running (prbar opens it when needed)."))
        }
        checks.append(DoctorChecks.link())
        let config = try? JSONCoding.decoder.decode(AppConfig.self, from: Data(contentsOf: AppPaths.configFile))
        checks.append(DoctorCheck(name: "config.json", ok: config != nil,
                                  detail: config != nil ? AppPaths.configFile.path : "Missing or unreadable: \(AppPaths.configFile.path)"))
        let locator = ToolLocator(runner: SystemProcessRunner())
        for tool in ToolName.allCases {
            let path = await locator.locate(tool.rawValue, override: config?.toolPaths[keyPath: tool.keyPath])
            checks.append(DoctorCheck(name: tool.rawValue, ok: path != nil, detail: path ?? Self.installHint(tool)))
        }
        let output = Output(terminal: .current(), json: json)
        if json {
            try output.printJSON(checks)
        } else {
            for check in checks {
                output.line("\(check.ok ? output.paint("✓", .green) : output.paint("✗", .red)) \(check.name): \(check.detail)")
            }
        }
        if checks.contains(where: { !$0.ok }) { throw ExitCode(CLIExit.generalError) }
    }

    static func installHint(_ tool: ToolName) -> String {
        switch tool {
        case .gh: "Not found. Install it with `brew install gh`, then `gh auth login --hostname github.com`."
        case .git: "Not found. Install the Command Line Tools: `xcode-select --install`."
        case .claude: "Not found. Install Claude Code (https://claude.com/claude-code) and sign in."
        }
    }
}

public enum DoctorChecks {
    /// `~/.local/bin/prbar` (o `$PRBAR_BIN_DIR/prbar`) es un link al helper de un PRBar.app y su carpeta está en el
    /// PATH.
    public static func link(environment: [String: String] = ProcessInfo.processInfo.environment) -> DoctorCheck {
        let name = "prbar in PATH"
        let dir = environment["PRBAR_BIN_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/bin"
        let link = dir + "/prbar"
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) else {
            let detail = FileManager.default.fileExists(atPath: link)
                ? "\(link) isn’t a link to PRBar (another tool?). Remove it and run Scripts/bundle.sh --install."
                : "No \(link). Run Scripts/bundle.sh --install."
            return DoctorCheck(name: name, ok: false, detail: detail)
        }
        guard target.hasSuffix("PRBar.app/Contents/Helpers/prbar") else {
            return DoctorCheck(name: name, ok: false,
                               detail: "\(link) points to \(target), not to PRBar. Remove it and run Scripts/bundle.sh --install.")
        }
        let inPath = (environment["PATH"] ?? "").split(separator: ":").contains { $0 == dir }
        return DoctorCheck(name: name, ok: inPath,
                           detail: inPath ? "\(link) → \(target)" : "\(dir) isn’t in your PATH: add `export PATH=\"\(dir):$PATH\"` to ~/.zshrc.")
    }
}
