import Foundation

/// What never leaves the Mac towards an iPhone (spec P.7, review M1/L1): applied to every result, failure, event,
/// topic, chat delta and push. Two passes:
/// - by key (`RemoteRedaction`): path fields keep their last component, `tools` goes empty, an SSH destination
///   (`host`) becomes "remote";
/// - by value, on every string: the home folder, PRBar's folders, the temporary folder, the clones and worktree
///   folders of the configured repos and the runners' folders are rewritten (`~`, `$TMPDIR`, or the folder's last
///   component), any other `/Users/<name>`, `/home/<name>` or `/var/folders/…` too; terminal escapes, control and
///   bidi/zero-width characters go (`RemoteText.clean`); tokens and common secret shapes are masked (as in CI logs).
///   A diff keeps its text (it is the user's code), only without control and bidi characters.
public struct RemoteRedactor: Sendable {
    struct Root: Sendable {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let roots: [Root]

    /// `home`: replaced by `~`. `temporary`: by `$TMPDIR`. `folders`: by their last component (clones, worktree folders,
    /// PRBar's own folders, runner folders). `hosts`: SSH destinations, by "remote host".
    public init(home: String = NSHomeDirectory(), temporary: [String] = RemoteRedactor.temporaryFolders,
                folders: [String] = [], hosts: [String] = []) {
        var pairs: [(String, String)] = []
        let homePath = Self.normalized(home)
        for folder in folders {
            for path in Self.variants(folder) where path != homePath {
                let name = (path as NSString).lastPathComponent
                pairs.append((path, name.isEmpty ? "…" : name))
                // Also as `~/…` (how logs and messages often write it).
                if path.hasPrefix(homePath + "/") { pairs.append(("~" + path.dropFirst(homePath.count), name)) }
            }
        }
        for path in temporary.flatMap(Self.variants) { pairs.append((path, "$TMPDIR")) }
        for path in Self.variants(home) { pairs.append((path, "~")) }
        // Longest first: a clone inside the home folder is rewritten as the clone, not as `~/…`.
        var roots = pairs.filter { $0.0.count > 1 }.sorted { $0.0.count > $1.0.count }.compactMap { path, replacement -> Root? in
            let pattern = "(?<![A-Za-z0-9._-])" + NSRegularExpression.escapedPattern(for: path) + "(?=$|[^A-Za-z0-9._-])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Root(regex: regex, replacement: NSRegularExpression.escapedTemplate(for: replacement))
        }
        for host in hosts where host.count >= 3 {
            let pattern = "(?<![A-Za-z0-9.-])" + NSRegularExpression.escapedPattern(for: host) + "(?![A-Za-z0-9-])"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                roots.append(Root(regex: regex, replacement: "remote host"))
            }
        }
        roots += Self.generic
        self.roots = roots
    }

    /// The temporary folder (also as `/private/…`), where PRBar keeps worktrees and context folders.
    public static var temporaryFolders: [String] { [FileManager.default.temporaryDirectory.path, NSTemporaryDirectory()] }

    /// The redactor for this Mac: PRBar's folders plus `folders` (the clones, worktree folders and runner folders
    /// from the config) and `hosts` (SSH destinations).
    public static func standard(folders: [String] = [], hosts: [String] = []) -> RemoteRedactor {
        let own = [AppPaths.appSupport.path, AppPaths.worktreesDir.path, AppPaths.legacyWorktreesDir.path,
                   AppPaths.logFile.deletingLastPathComponent().path, AppPaths.slackConnectorDir.path]
        return RemoteRedactor(folders: own + folders, hosts: hosts)
    }

    /// Any other user's home or macOS temporary folder that slipped through (another account, a runner).
    private static let generic: [Root] = [
        (#"(?<![A-Za-z0-9._-])(?:/private)?/var/folders/[^/\s]+/[^/\s]+/[A-Z](?=$|[/\s"'’:;,)\]])"#, "$TMPDIR"),
        (#"(?<![A-Za-z0-9._-])/Users/[^/\s"'’:;,)\]]+"#, "~"),
        (#"(?<![A-Za-z0-9._-])/home/[^/\s"'’:;,)\]]+"#, "~"),
    ].map { Root(regex: try! NSRegularExpression(pattern: $0.0), replacement: NSRegularExpression.escapedTemplate(for: $0.1)) }

    private static func normalized(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The path, with `~` expanded, and its `/private` twin (`/var` and `/tmp` are links to `/private/…`).
    private static func variants(_ raw: String) -> [String] {
        let path = normalized((raw as NSString).expandingTildeInPath)
        guard path.hasPrefix("/") else { return [] }
        if path.hasPrefix("/private/") { return [path, String(path.dropFirst("/private".count))] }
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") || path == "/tmp" { return [path, "/private" + path] }
        return [path]
    }

    // MARK: - Passes

    public func scrub(_ value: JSONValue) -> JSONValue {
        walk(RemoteRedaction.scrub(value), key: nil)
    }

    public func scrub(_ failure: CommandFailure) -> CommandFailure {
        CommandFailure(failure.code, text(failure.message))
    }

    public func scrub(_ event: CommandEvent) -> CommandEvent {
        switch event {
        case .progress(let message): .progress(message: text(message))
        case .text(let delta): .text(delta: text(delta))
        }
    }

    public func scrub<T: Codable>(_ value: T) throws -> T {
        try scrub(try JSONValue(encoding: value)).decode(T.self)
    }

    /// A string for the phone: paths rewritten, escapes and invisible characters gone, secrets masked.
    public func text(_ raw: String) -> String {
        var text = RemoteText.clean(raw)
        if text.contains("/") {
            for root in roots {
                text = root.regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                           withTemplate: root.replacement)
            }
        } else {
            for root in roots where root.replacement == "remote host" {
                text = root.regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                           withTemplate: root.replacement)
            }
        }
        // Tokens are at least 20 characters long.
        if text.count >= 16 { text = CILogs.redactingCISecrets(RuleText.redacted(text)) }
        return text
    }

    /// A diff: the user's code as is, without control and bidi characters (each one shown as U+FFFD so a hidden
    /// reordering stays visible).
    func diffText(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control where scalar == "\n" || scalar == "\t": scalars.append(scalar)
            case .format where scalar.value == 0x200D: scalars.append(scalar)
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate: scalars.append("\u{FFFD}")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private func walk(_ value: JSONValue, key: String?) -> JSONValue {
        switch value {
        case .string(let string):
            return .string(key == "diff" ? diffText(string) : text(string))
        case .array(let items):
            return .array(items.map { walk($0, key: key) })
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, field) in fields { out[key] = walk(field, key: key) }
            return .object(out)
        default:
            return value
        }
    }
}

public extension AppConfig {
    /// Where this Mac's code lives, for `RemoteRedactor`: the clones and worktree folders of every repo (and the
    /// default `<clone>-worktrees`), and the runners' folders.
    var remoteRedactionFolders: [String] {
        var folders: [String] = []
        for account in accounts {
            for repo in account.repos {
                if let path = repo.localPath, !path.isEmpty {
                    folders.append(path)
                    folders.append(path + "-worktrees")
                }
                if let dir = repo.worktreeDir, !dir.isEmpty { folders.append(dir) }
            }
        }
        folders += runners.destinations.map(\.remoteDir).filter { $0.hasPrefix("/") }
        return folders
    }

    /// The SSH destinations' hosts, for `RemoteRedactor`.
    var remoteRedactionHosts: [String] { runners.destinations.map(\.endpoint.host) }
}
