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
    case jobNotStopped(host: String)
    case unsupportedEnvironment(String)

    /// El host de un `.jobNotStopped`.
    public var jobHost: String? {
        if case .jobNotStopped(let host) = self { return host }
        return nil
    }

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
        case .unsupportedEnvironment(let name): "Internal error: \(name) can’t be passed to git on a remote host."
        case .jobNotStopped(let host):
            "PRBar lost the connection to \(host) and couldn’t confirm Claude stopped there. The worktree was left as is; PRBar will clean it up when it can reach \(host) again."
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
    /// Byte a byte: para `String`, `=` o `-` seguidos de una marca combinante no son `=` ni `-`.
    static func isValidExecutable(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard let first = bytes.first, first != UInt8(ascii: "-"), !bytes.contains(UInt8(ascii: "=")),
              bytes.allSatisfy({ $0 > 0x20 && $0 != 0x7F }) else { return false }
        if first == UInt8(ascii: "/") { return !PathBytes.components(bytes).contains { PathBytes.isDots($0) } }
        return !bytes.contains(UInt8(ascii: "/"))
    }

    /// La lápida de Stop de un trabajo: `<trabajo>.cancel` al lado de `<trabajo>.pid`.
    public static func cancelFile(forPidFile pidFile: String) -> String {
        (pidFile.hasSuffix(".pid") ? String(pidFile.dropLast(4)) : pidFile) + ".cancel"
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
            // Después de escribir el pid: un Stop que llegó antes (y no pudo leerlo) dejó la lápida.
            lines.append("[ -e \(try ShellQuote.posix(Self.cancelFile(forPidFile: pidFile))) ] && exit 99")
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
            if name == "GIT_INDEX_FILE" {
                // Solo el índice temporal de un snapshot del chat, nunca el de un worktree.
                guard root.isTemporaryFile(value) else { throw RemoteRunnerError.unsupportedEnvironment(name) }
            } else if !gitPassthrough.contains(name) {
                // Una variable de git que no está en la lista cambiaría qué hace git (GIT_DIR, GIT_SSH_COMMAND, …).
                if name.hasPrefix("GIT_") { throw RemoteRunnerError.unsupportedEnvironment(name) }
                continue
            }
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
        let bytes = Array(path.utf8)
        let components = PathBytes.components(bytes)
        guard bytes.first == UInt8(ascii: "/"), bytes.last != UInt8(ascii: "/"), bytes.count <= 400, components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && !PathBytes.isDots($0) }),
              !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
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

    /// Lo que sigue a `<raíz>/`, en componentes de bytes, si `candidate` está estrictamente adentro (sin `.`, `..`
    /// ni `//`). Byte a byte: `String` compara por equivalencia canónica (`é` = `e` + U+0301) y agrupa `/` o `.`
    /// con una marca combinante, y el disco del host no.
    private func inside(_ candidate: String) -> [ArraySlice<UInt8>]? {
        let prefix = Array((path + "/").utf8)
        let bytes = Array(candidate.utf8)
        guard bytes.count > prefix.count, bytes.starts(with: prefix) else { return nil }
        let rest = PathBytes.components(Array(bytes[prefix.count...]))
        guard !rest.isEmpty, rest.allSatisfy({ !$0.isEmpty && !PathBytes.isDots($0) }) else { return nil }
        return rest
    }

    /// Estrictamente adentro, sin `.`, `..` ni `//`.
    public func contains(_ candidate: String) -> Bool { inside(candidate) != nil }

    /// Un archivo suelto en `tmp/` (`<raíz>/tmp/<nombre>`, nombre `[A-Za-z0-9._-]`, sin `.`/`..`).
    public func isTemporaryFile(_ candidate: String) -> Bool {
        let prefix = Array((tmp + "/").utf8)
        let bytes = Array(candidate.utf8)
        guard bytes.count > prefix.count, bytes.starts(with: prefix) else { return false }
        let name = bytes.dropFirst(prefix.count)
        guard name.first != UInt8(ascii: "-"), !name.elementsEqual(".".utf8), !name.elementsEqual("..".utf8) else { return false }
        return name.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    /// Se puede borrar: adentro y al menos dos niveles abajo (`work/x`, nunca `work`).
    public func isRemovable(_ candidate: String) -> Bool { (inside(candidate)?.count ?? 0) >= 2 }
}

/// Rutas como bytes (lo que ve el disco del host).
enum PathBytes {
    static func components(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
    }

    /// `.` o `..`.
    static func isDots(_ component: ArraySlice<UInt8>) -> Bool {
        component.elementsEqual([0x2E]) || component.elementsEqual([0x2E, 0x2E])
    }
}
