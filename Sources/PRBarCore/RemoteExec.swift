import Foundation

public enum RemoteRunnerError: Error, Equatable, LocalizedError {
    case unsafeControlDirectory(String, String)
    case unreachable(host: String, detail: String)
    case commandFailed(host: String, command: String, status: Int32, stderr: String)
    case outsideRoot(String)
    case commandTooLong(host: String)
    case secretInEnvironment(String)
    case hostProblems(host: String, problems: [String])
    case cannotFetch(host: String, repo: String)
    case pluginMissing(host: String, plugin: String, skill: String)
    case guardFailed(host: String, detail: String)
    case malformedOutput(host: String, what: String)
    case importMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeControlDirectory(let path, let reason): "PRBar’s SSH folder \(path) isn’t safe: \(reason). Delete it and try again."
        case .unreachable(let host, let detail): "\(host) is unreachable\(detail.isEmpty ? "" : ": \(detail)")"
        case .commandFailed(let host, let command, let status, let stderr):
            "`\(command)` failed on \(host) (exit \(status))\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .outsideRoot(let path): "Internal error: \(path) is outside PRBar’s remote folder."
        case .commandTooLong(let host): "Internal error: the command for \(host) is too long."
        case .secretInEnvironment(let name): "Internal error: \(name) can’t be sent to a remote host."
        case .hostProblems(let host, let problems): "\(host) can’t run Claude for PRBar: " + problems.joined(separator: " ")
        case .cannotFetch(let host, let repo): "\(host) can't fetch \(repo) — set up git access on the server."
        case .pluginMissing(let host, let plugin, let skill):
            "\(host) doesn’t have the plugin \(plugin) (for \(skill)). Install it there: run `claude` on \(host), then `/plugin install \(plugin)`."
        case .guardFailed(let host, let detail): "PRBar’s integrity check failed on \(host): \(detail)"
        case .malformedOutput(let host, let what): "\(host) returned an unexpected \(what)."
        case .importMismatch(let detail): "The commits from the server don’t match what you reviewed: \(detail) Nothing was pushed."
        }
    }
}

/// Una variable del entorno remoto. `inherit`: la del host (`HOME`); `inheritIfSet`: solo si el host la tiene.
public enum RemoteEnv: Equatable, Sendable {
    case literal(String, String)
    case inherit(String)
    case inheritIfSet(String)

    var name: String {
        switch self {
        case .literal(let name, _), .inherit(let name), .inheritIfSet(let name): name
        }
    }

    func render() throws -> String {
        guard ShellQuote.isEnvironmentName(name) else { throw ShellQuote.Failure.invalidEnvironmentName(name) }
        switch self {
        case .literal(let name, let value): return try ShellQuote.posix("\(name)=\(value)")
        case .inherit(let name): return "\"\(name)=$\(name)\""
        case .inheritIfSet(let name): return "${\(name):+\"\(name)=$\(name)\"}"
        }
    }
}

/// Un comando para el host, armado como script POSIX: `cd`, el pgid a un archivo (para Stop), y `exec env -i <lista
/// blanca> <argv>` con stdin de `/dev/null`, de un archivo remoto o del de ssh. Nada se interpola: todo va con
/// `ShellQuote`.
public struct RemoteExec: Sendable {
    public enum StandardInput: Equatable, Sendable {
        case null
        case remoteFile(String)
        /// El stdin del `ssh` local (subidas y el guardián Perl).
        case passThrough
    }

    public var argv: [String]
    public var cwd: String?
    /// `nil` = el entorno de login del host (solo los tests del usuario, decisión J.7.13).
    public var environment: [RemoteEnv]?
    public var standardInput: StandardInput
    public var pidFile: String?

    public init(argv: [String], cwd: String? = nil, environment: [RemoteEnv]?, standardInput: StandardInput = .null,
                pidFile: String? = nil) {
        self.argv = argv
        self.cwd = cwd
        self.environment = environment
        self.standardInput = standardInput
        self.pidFile = pidFile
    }

    /// Absoluto (`/…`) o un nombre suelto (`git`, `perl`); nunca con `=` (env lo leería como variable), espacios
    /// ni `-` al principio.
    static func isValidExecutable(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("-"), !path.contains("="),
              path.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else { return false }
        if path.hasPrefix("/") { return !path.split(separator: "/").contains { $0 == ".." } }
        return !path.contains("/")
    }

    public func script() throws -> String {
        guard let program = argv.first, Self.isValidExecutable(program) else {
            throw ShellQuote.Failure.invalidExecutable(argv.first ?? "")
        }
        var lines = ["umask 077"]
        if let cwd { lines.append("cd -- \(try ShellQuote.posix(cwd)) || exit 97") }
        if let pidFile {
            lines.append("pgid=$(ps -o pgid= -p $$ | tr -d ' ')")
            lines.append("case $pgid in ''|*[!0-9]*) exit 98;; esac")
            lines.append("printf '%s\\n' \"$pgid\" > \(try ShellQuote.posix(pidFile)) || exit 98")
        }
        var command = "exec "
        if let environment {
            command += "/usr/bin/env -i " + (try environment.map { try $0.render() }.joined(separator: " ")) + " "
        }
        command += try ShellQuote.command(argv)
        switch standardInput {
        case .null: command += " < /dev/null"
        case .remoteFile(let path): command += " < " + (try ShellQuote.posix(path))
        case .passThrough: break
        }
        lines.append(command)
        return lines.joined(separator: "\n")
    }
}

/// Los entornos remotos (decisión J.7.5).
public enum RemoteEnvironment {
    static let systemPath = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// Lo único que se copia del `environment` que pasa quien llama (los tests aíslan la config de git así).
    public static let gitPassthrough: Set<String> = [
        "GIT_TERMINAL_PROMPT", "GIT_LFS_SKIP_SMUDGE", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
        "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
    ]

    static func path(_ directories: [String]) -> RemoteEnv {
        var unique: [String] = []
        for dir in directories + systemPath where !unique.contains(dir) { unique.append(dir) }
        return .literal("PATH", unique.joined(separator: ":"))
    }

    public static func claude(pathDirectories: [String], root: RemoteRoot) -> [RemoteEnv] {
        [path(pathDirectories), .inherit("HOME"), .inheritIfSet("USER"), .inheritIfSet("LOGNAME"), .inheritIfSet("LANG"),
         .inheritIfSet("LC_ALL"), .literal("SHELL", "/bin/sh"), .literal("TMPDIR", root.tmp)]
    }

    public static func git(passing environment: [String: String]?, pathDirectories: [String], root: RemoteRoot) throws -> [RemoteEnv] {
        var result = [path(pathDirectories), .inherit("HOME"), .inheritIfSet("USER"), .inheritIfSet("LOGNAME"), .inheritIfSet("LANG"),
                      .inheritIfSet("LC_ALL"), .inheritIfSet("SSH_AUTH_SOCK"),
                      .literal("GIT_TERMINAL_PROMPT", "0"), .literal("GIT_LFS_SKIP_SMUDGE", "1"),
                      .literal("GIT_SSH_COMMAND", "ssh -o BatchMode=yes")]
        for (name, value) in (environment ?? [:]).sorted(by: { $0.key < $1.key }) {
            if SystemProcessRunner.unheritedVariables.contains(name) || name.hasSuffix("_TOKEN") {
                throw RemoteRunnerError.secretInEnvironment(name)
            }
            guard gitPassthrough.contains(name) else { continue }
            result.removeAll { $0.name == name }
            result.append(.literal(name, value))
        }
        return result
    }

    /// El guardián Perl: sin `PERL5OPT`/`PERL5LIB`.
    public static func perl() -> [RemoteEnv] {
        [path([]), .inherit("HOME"), .inheritIfSet("LANG")]
    }
}

/// La carpeta remota de PRBar, ya verificada (`pwd -P` en el host). Todo lo que PRBar crea o borra en el host pasa por
/// acá (decisión J.7.6).
public struct RemoteRoot: Hashable, Sendable {
    public static let marker = ".prbar-root"
    public let path: String

    public init(verified path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.hasSuffix("/"), path.count <= 400, components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw RemoteRunnerError.outsideRoot(path)
        }
        self.path = path
    }

    public var work: String { path + "/work" }
    public var repos: String { path + "/repos" }
    public var jobs: String { path + "/jobs" }
    public var tmp: String { path + "/tmp" }
    public var markerPath: String { path + "/" + Self.marker }

    /// Un hijo de la raíz: cada componente `[A-Za-z0-9._-]`, sin `.`/`..` y sin empezar con `-`.
    public func child(_ components: [String]) throws -> String {
        guard !components.isEmpty else { throw RemoteRunnerError.outsideRoot(path) }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.hasPrefix("-"),
                  component.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) else {
                throw RemoteRunnerError.outsideRoot(([path] + components).joined(separator: "/"))
            }
        }
        return ([path] + components).joined(separator: "/")
    }

    /// Estrictamente adentro, sin `.`, `..` ni `//`.
    public func contains(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(path + "/") else { return false }
        let rest = candidate.dropFirst(path.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return !rest.isEmpty && rest.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Se puede borrar: adentro y al menos dos niveles abajo (`work/x`, nunca `work`).
    public func isRemovable(_ candidate: String) -> Bool {
        contains(candidate) && candidate.dropFirst(path.count + 1).split(separator: "/").count >= 2
    }
}
