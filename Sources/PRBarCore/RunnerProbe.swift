import Foundation

/// Lo que se sabe de un host después de verificarlo (spec J.3).
public struct RunnerHostInfo: Codable, Equatable, Sendable {
    public var host: String
    public var os: String?
    public var arch: String?
    /// El `HOME` del usuario en el host (para `~/` en los includes de git del guardián).
    public var home: String?
    public var gitPath: String?
    public var gitVersion: String?
    public var claudePath: String?
    public var claudeVersion: String?
    public var perl: Bool
    public var quotingOK: Bool
    /// La raíz verificada (`pwd -P`).
    public var root: String?
    public var problems: [String]
    public var checkedAt: Date
    /// Solo "Test Connection" lo prueba (`nil` = no se probó).
    public var claudeLoggedIn: Bool?

    public init(host: String, os: String? = nil, arch: String? = nil, home: String? = nil, gitPath: String? = nil, gitVersion: String? = nil,
                claudePath: String? = nil, claudeVersion: String? = nil, perl: Bool = false, quotingOK: Bool = false,
                root: String? = nil, problems: [String] = [], checkedAt: Date = Date(), claudeLoggedIn: Bool? = nil) {
        self.host = host
        self.os = os
        self.arch = arch
        self.home = home
        self.gitPath = gitPath
        self.gitVersion = gitVersion
        self.claudePath = claudePath
        self.claudeVersion = claudeVersion
        self.perl = perl
        self.quotingOK = quotingOK
        self.root = root
        self.problems = problems
        self.checkedAt = checkedAt
        self.claudeLoggedIn = claudeLoggedIn
    }

    /// Una verificación que ni siquiera pudo correr (host caído, ssh mal configurado).
    public init(host: String, problem: String) {
        self.init(host: host, problems: [problem])
    }

    public var isUsable: Bool { problems.isEmpty && root != nil && gitPath != nil && claudePath != nil }

    /// Carpetas de `git` y `claude` del host (para el `PATH` remoto).
    public var toolDirectories: [String] {
        [claudePath, gitPath].compactMap { $0 }.map { ($0 as NSString).deletingLastPathComponent }
    }
}

public enum RunnerProbe {
    public static let quotingPayload = "a'b\"c\\d$e`f!g*h;i|j&k#l m\tn~o"
    public static let minimumGit = (2, 31, 0)

    /// `uname; git --version; command -v claude; claude --version` (spec J.3), la sonda de comillas y la raíz.
    /// La raíz de PRBar en el host es `<carpeta>/installs/<installationID>`: cada Mac (instalación) tiene la suya y
    /// nunca limpia la de otra. La carpeta de arriba lleva la marca para no adueñarse de una carpeta ajena.
    public static func script(for destination: RunnerDestination, installationID: String) throws -> String {
        guard RemoteInstallation.isValidID(installationID) else { throw RemoteRunnerError.outsideRoot(installationID) }
        let install = try ShellQuote.posix("installs/" + installationID)
        return """
        printf 'os=%s\\n' "$(uname -s 2>/dev/null)"
        printf 'arch=%s\\n' "$(uname -m 2>/dev/null)"
        printf 'home=%s\\n' "$HOME"
        g=$(command -v git 2>/dev/null)
        printf 'gitpath=%s\\n' "$g"
        [ -n "$g" ] && printf 'git=%s\\n' "$("$g" --version 2>/dev/null | head -n 1)"
        c=$(command -v claude 2>/dev/null || "${SHELL:-/bin/sh}" -lc 'command -v claude' 2>/dev/null | tail -n 1)
        printf 'claudepath=%s\\n' "$c"
        [ -n "$c" ] && printf 'claude=%s\\n' "$("$c" --version 2>/dev/null | head -n 1)"
        if /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin perl -MDigest::SHA -MTime::HiRes=lstat -e 1 2>/dev/null; then printf 'perl=ok\\n'; fi
        printf 'quoting=%s\\n' \(try ShellQuote.posix(quotingPayload))
        d=\(try destination.remoteDirExpression())
        umask 077
        if mkdir -p -- "$d" 2>/dev/null && cd -- "$d"; then
          if [ ! -e \(RemoteRoot.marker) ] && [ -n "$(ls -A)" ]; then printf 'rootproblem=notempty\\n'
          elif : > \(RemoteRoot.marker) && mkdir -p -- \(install) && chmod 700 . installs \(install) && cd -- \(install) \\
            && : > \(RemoteRoot.marker) && mkdir -p work repos jobs tmp && chmod 700 work repos jobs tmp; then printf 'root=%s\\n' "$(pwd -P)"
          else printf 'rootproblem=mkdir\\n'; fi
        else printf 'rootproblem=mkdir\\n'; fi
        """
    }

    public static func check(_ host: SSHHost, now: Date = Date()) async throws -> RunnerHostInfo {
        let result = try host.checked(try await host.runScript(try script(for: host.destination, installationID: host.installationID), timeout: 60), "verification")
        return parse(result.stdout, host: host.name, remoteDir: host.destination.remoteDir, now: now)
    }

    public static func parse(_ output: String, host: String, remoteDir: String = RunnerDestination.defaultRemoteDir, now: Date) -> RunnerHostInfo {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        func absolute(_ key: String) -> String? {
            guard let value = values[key], value.hasPrefix("/"), !value.contains("\n") else { return nil }
            return value
        }
        var info = RunnerHostInfo(host: host, os: values["os"], arch: values["arch"], home: absolute("home"), gitPath: absolute("gitpath"),
                                  gitVersion: values["git"], claudePath: absolute("claudepath"), claudeVersion: values["claude"],
                                  perl: values["perl"] == "ok", quotingOK: values["quoting"] == quotingPayload,
                                  root: absolute("root").flatMap { (try? RemoteRoot(verified: $0))?.path }, problems: [], checkedAt: now)
        if !info.quotingOK {
            info.problems.append("\(host)’s login shell changed PRBar’s test string — set sh, bash or zsh as the login shell for this user.")
        }
        if info.gitPath == nil {
            info.problems.append("git isn’t installed on \(host).")
        } else if let version = info.gitVersion.flatMap(gitVersion), version < minimumGit {
            info.problems.append("\(host) has \(info.gitVersion ?? "an old git"); PRBar needs git 2.31 or later.")
        }
        if info.claudePath == nil || (info.claudeVersion ?? "").isEmpty {
            info.problems.append("claude isn’t installed on \(host) (or isn’t in its PATH). Install Claude Code there.")
        }
        if !info.perl { info.problems.append("\(host) needs Perl with Digest::SHA and Time::HiRes (PRBar’s integrity checks use it).") }
        switch values["rootproblem"] {
        case "notempty"?: info.problems.append("\(remoteDir) on \(host) already exists and isn’t PRBar’s. Choose another folder.")
        case "mkdir"?: info.problems.append("PRBar can’t create \(remoteDir) on \(host).")
        default: if info.root == nil && values["rootproblem"] == nil { info.problems.append("PRBar can’t use \(remoteDir) on \(host).") }
        }
        return info
    }

    /// `git version 2.39.3 (Apple Git-146)` → (2, 39, 3).
    public static func gitVersion(_ text: String) -> (Int, Int, Int)? {
        guard let token = text.split(separator: " ").first(where: { $0.first?.isNumber == true }) else { return nil }
        let numbers = token.split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 0)
    }

    /// "Test Connection": un `claude -p` mínimo con `--model haiku`, aislado y con el prompt por stdin.
    public static func claudeLoggedIn(_ host: SSHHost, info: RunnerHostInfo) async throws -> Bool {
        guard let claude = info.claudePath, let rootPath = info.root else { return false }
        let root = try RemoteRoot(verified: rootPath)
        let promptPath = try root.child(["tmp", "login-check-\(UUID().uuidString.lowercased()).txt"])
        try await host.upload(Data("Reply with the single word: ok".utf8), to: promptPath, root: root)
        defer { Task.detached { await host.removeFiles([promptPath], root: root) } }
        let exec = RemoteExec(
            argv: [claude, "-p", "--model", "haiku", "--output-format", "text", "--setting-sources", "", "--strict-mcp-config",
                   "--mcp-config", #"{"mcpServers":{}}"#, "--tools", "", "--permission-mode", "dontAsk"],
            cwd: root.tmp, environment: RemoteEnvironment.claude(pathDirectories: info.toolDirectories, root: root),
            standardInput: .remoteFile(promptPath))
        let result = try await host.run(exec, timeout: 120)
        return result.status == 0 && result.stdout.lowercased().contains("ok")
    }
}

/// Verificación antes de cada trabajo: 5 min si salió bien, 60 s si falló (decisión J.7.11).
public actor RunnerHealthCache {
    public static let successTTL: TimeInterval = 300
    public static let failureTTL: TimeInterval = 60

    private var entries: [String: (at: Date, result: Result<RunnerHostInfo, Error>)] = [:]

    public init() {}

    public func info(for host: SSHHost, force: Bool = false, now: Date = Date()) async throws -> RunnerHostInfo {
        let key = host.name.lowercased()
        if !force, let entry = entries[key] {
            let ttl = (try? entry.result.get()) != nil ? Self.successTTL : Self.failureTTL
            if now.timeIntervalSince(entry.at) < ttl { return try entry.result.get() }
        }
        let result: Result<RunnerHostInfo, Error>
        do {
            let info = try await RunnerProbe.check(host, now: now)
            result = info.isUsable ? .success(info) : .failure(RemoteRunnerError.hostProblems(host: host.name, problems: info.problems))
        } catch {
            result = .failure(error)
        }
        entries[key] = (now, result)
        return try result.get()
    }

    public func last(_ name: String) -> RunnerHostInfo? { try? entries[name.lowercased()]?.result.get() }
    public func forget(_ name: String) { entries[name.lowercased()] = nil }
}
