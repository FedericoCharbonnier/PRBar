import Foundation

/// What to open: a shell command (already quoted), the folder on this Mac it belongs to and a title.
public struct TerminalRequest: Equatable, Sendable {
    public var command: String
    /// Where the terminal starts (`cd`), Orca's worktree and `{dir}`. For a runner's session, the repo's local folder;
    /// nil if it has none.
    public var directory: String?
    public var title: String

    public init(command: String, directory: String?, title: String) {
        self.command = command
        self.directory = directory
        self.title = title
    }
}

/// How each terminal opens it (spec T.5, verified 2026-11-24).
public enum TerminalPlan: Equatable, Sendable {
    /// An executable `.command` script opened with `open -a <app>`.
    case commandFile(app: String, script: String)
    /// `orca <arguments>`.
    case orca(arguments: [String])
    /// `/bin/sh -c <command>` (Custom).
    case shell(command: String)
}

public enum TerminalLaunchError: Error, Equatable, LocalizedError {
    case notInstalled(String)
    case noCustomCommand
    case customCommandWithoutPlaceholder
    case quotedPlaceholder
    case notInOrca
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) isn’t installed. Choose another terminal in Settings › General."
        case .noCustomCommand: "There’s no custom terminal command. Set one in Settings › General."
        case .customCommandWithoutPlaceholder: "The custom terminal command needs {command}: it’s where Claude runs."
        case .quotedPlaceholder: "Don’t put quotes around {dir} or {command}: PRBar quotes them."
        case .notInOrca: "This folder isn’t in Orca. Add the repo in Orca or choose another terminal."
        case .failed(let message): "The terminal couldn’t open Claude’s session: \(message)"
        }
    }
}

/// The plans, without side effects (`TerminalOpener` runs them).
public enum TerminalLauncher {
    /// Installed = an app with this bundle id (Terminal always is; Custom has none).
    public static let bundleIDs: [TerminalChoice: String] = [
        .terminal: "com.apple.Terminal", .iterm: "com.googlecode.iterm2", .warp: "dev.warp.Warp-Stable",
        .ghostty: "com.mitchellh.ghostty", .orca: "com.stablyai.orca",
    ]

    /// The name `open -a` takes, for the terminals that open a `.command` file.
    public static func appName(_ choice: TerminalChoice) -> String? {
        switch choice {
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .warp: "Warp"
        case .ghostty: "Ghostty"
        case .orca, .custom: nil
        }
    }

    /// `#!/bin/zsh`, `cd '<folder>' && <command>`, then a login shell so the window stays open after Claude.
    public static func script(_ request: TerminalRequest) throws -> String {
        let run = try request.directory.map { "cd \(try ShellQuote.posix($0)) && \(request.command)" } ?? request.command
        return "#!/bin/zsh\n\(run)\nexec /bin/zsh -l\n"
    }

    public static func plan(_ request: TerminalRequest, choice: TerminalChoice, customCommand: String?) throws -> TerminalPlan {
        if let app = appName(choice) { return .commandFile(app: app, script: try script(request)) }
        switch choice {
        case .orca:
            return .orca(arguments: try orcaArguments(request))
        case .custom:
            let template = customCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .shell(command: try expand(template, request))
        case .terminal, .iterm, .warp, .ghostty:
            throw TerminalLaunchError.failed("unknown terminal")   // `appName` covers them.
        }
    }

    /// `terminal create --worktree=path:<folder> --title=<title> --command=<command> --focus --json` (verified with
    /// Orca: only a worktree of a repo added in Orca works). Each value is glued to its flag with `=` so a value that
    /// starts with `-` can't be read as another flag (Orca's parser accepts `--flag=value`, checked 2026-11-24).
    public static func orcaArguments(_ request: TerminalRequest) throws -> [String] {
        guard let directory = request.directory else { throw TerminalLaunchError.notInOrca }
        return ["terminal", "create", "--worktree=path:\(directory)", "--title=\(request.title)",
                "--command=\(request.command)", "--focus", "--json"]
    }

    static let placeholders = ["{dir}", "{command}"]

    /// What Settings › General checks while typing the Custom command (and `plan` before running it): not empty, with
    /// `{command}`, and each placeholder a bare word. PRBar inserts them already single-quoted, so inside `"…"`, `'…'` or
    /// backticks, or glued to a quote, `\` or `$` (`$'…'`), the quotes would pair differently and part of the value
    /// would run as shell.
    public static func validateCustomCommand(_ template: String) throws {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw TerminalLaunchError.noCustomCommand }
        guard template.contains("{command}") else { throw TerminalLaunchError.customCommandWithoutPlaceholder }
        let characters = Array(template.unicodeScalars)
        var quote: Unicode.Scalar?   // `'`, `"` or `` ` `` while inside one.
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let length = placeholderLength(characters, at: index) {
                let before = index > 0 ? characters[index - 1] : " "
                let after = index + length < characters.count ? characters[index + length] : " "
                if quote != nil || "'\"\\$`".unicodeScalars.contains(before) || "'\"`".unicodeScalars.contains(after) {
                    throw TerminalLaunchError.quotedPlaceholder
                }
                index += length
                continue
            }
            switch (quote, character) {
            case (nil, "\\"), ("\"", "\\"), ("`", "\\"):   // Escapes the next character (never a placeholder's `{`).
                if placeholderLength(characters, at: index + 1) != nil { throw TerminalLaunchError.quotedPlaceholder }
                index += 1
            case (nil, "'"), (nil, "\""), (nil, "`"): quote = character
            case let (open?, close) where open == close: quote = nil
            default: break
            }
            index += 1
        }
        if quote != nil { throw TerminalLaunchError.quotedPlaceholder }   // An unclosed quote would swallow what follows.
    }

    private static func placeholderLength(_ characters: [Unicode.Scalar], at index: Int) -> Int? {
        for placeholder in placeholders {
            let scalars = Array(placeholder.unicodeScalars)
            if index + scalars.count <= characters.count, Array(characters[index..<index + scalars.count]) == scalars {
                return scalars.count
            }
        }
        return nil
    }

    /// `{dir}` and `{command}`, each as one single-quoted word (`validateCustomCommand` first).
    /// One pass over the template: a value that contains `{command}` or `{dir}` (a folder can be named that) is never
    /// expanded again, which would leave the other value outside the quotes.
    public static func expand(_ template: String, _ request: TerminalRequest) throws -> String {
        try validateCustomCommand(template)
        let values = ["{dir}": try ShellQuote.posix(request.directory ?? NSHomeDirectory()),
                      "{command}": try ShellQuote.posix(request.command)]
        var result = ""
        var rest = template[...]
        while !rest.isEmpty {
            if let (placeholder, value) = values.first(where: { rest.hasPrefix($0.key) }) {
                result += value
                rest = rest.dropFirst(placeholder.count)
            } else {
                result.append(rest.removeFirst())
            }
        }
        return result
    }

    /// nil = Orca opened it (`"ok": true`). Without a JSON answer (an older Orca, or a wrapper on the PATH), the exit
    /// status decides: 0 counts as opened, since `--json` output is the only thing that could say otherwise; a failure
    /// shows stderr, else stdout, else the status.
    public static func orcaOutcome(stdout: String, stderr: String = "", status: Int32) -> TerminalLaunchError? {
        guard let data = stdout.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            guard status != 0 else { return nil }
            let text = [stderr, stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            return .failed(text ?? "orca exited with status \(status)")
        }
        if object["ok"] as? Bool == true { return nil }
        let error = object["error"] as? [String: Any]
        if (error?["code"] as? String) == "selector_not_found" { return .notInOrca }
        return .failed((error?["message"] as? String) ?? "orca exited with status \(status)")
    }
}

/// Runs a `TerminalPlan`: writes the `.command` file (Application Support `terminal/`, 755) and opens it, runs Orca's
/// CLI or the custom command.
public struct TerminalOpener: Sendable {
    /// Where Orca's CLI may be (`/Applications/Orca.app` ships it; it can also be linked on the PATH).
    public static let orcaCandidates = ["/Applications/Orca.app/Contents/Resources/bin/orca", "/opt/homebrew/bin/orca",
                                        "/usr/local/bin/orca"]
    /// `.command` files older than this are deleted at each opening.
    public static let commandFileLifetime: TimeInterval = 86_400

    let runner: ProcessRunning
    let directory: URL
    let now: @Sendable () -> Date
    let isExecutable: @Sendable (String) -> Bool

    public init(runner: ProcessRunning, directory: URL = AppPaths.terminalDir, now: @escaping @Sendable () -> Date = { Date() },
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.runner = runner
        self.directory = directory
        self.now = now
        self.isExecutable = isExecutable
    }

    public func open(_ request: TerminalRequest, choice: TerminalChoice, customCommand: String?) async throws {
        switch try TerminalLauncher.plan(request, choice: choice, customCommand: customCommand) {
        case .commandFile(let app, let script):
            let file = try writeCommandFile(script)
            let result = try await runner.run("/usr/bin/open", ["-a", app, file.path], environment: nil, currentDirectory: nil, timeout: 30)
            guard result.status == 0 else { throw TerminalLaunchError.failed(Self.message(result)) }
        case .orca(let arguments):
            guard let orca = Self.orcaCandidates.first(where: isExecutable) else { throw TerminalLaunchError.notInstalled("Orca") }
            let result = try await runner.run(orca, arguments, environment: nil, currentDirectory: nil, timeout: 30)
            if let error = TerminalLauncher.orcaOutcome(stdout: result.stdout, stderr: result.stderr, status: result.status) { throw error }
        case .shell(let command):
            let result = try await runner.run("/bin/sh", ["-c", Self.detachedLauncher, "prbar-terminal", command],
                                              environment: nil, currentDirectory: nil, timeout: 30)
            guard result.status == 0 else {
                throw TerminalLaunchError.failed("the custom command exited with status \(result.status)")
            }
        }
    }

    /// Runs `$1` (the Custom command) in the background so a terminal that stays in the foreground (`kitty`,
    /// `alacritty -e`, `wezterm start`) isn't waited for nor killed by the runner's timeout: `set -m` puts it in its own
    /// process group (the runner signals only the launcher's), with stdin/stdout/stderr on /dev/null so no pipe of
    /// PRBar stays open. The launcher waits up to a second: if the command already ended, its status is the launcher's
    /// (an immediate failure is reported); if it is still running, the launch counts as done.
    static let detachedLauncher = """
        set -m
        /bin/sh -c "$1" </dev/null >/dev/null 2>&1 &
        pid=$!
        i=0
        while [ "$i" -lt 10 ]; do
          if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
          sleep 0.1
          i=$((i + 1))
        done
        exit 0
        """

    func writeCommandFile(_ script: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.prune(directory, now: now())
        let file = directory.appendingPathComponent("prbar-session-\(UUID().uuidString.lowercased()).command")
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// Deletes PRBar's `prbar-session-*.command` files modified more than `commandFileLifetime` ago.
    static func prune(_ directory: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "command" && file.lastPathComponent.hasPrefix("prbar-session-") {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(date) > commandFileLifetime else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func message(_ result: ProcessResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit status \(result.status)" : text
    }
}
