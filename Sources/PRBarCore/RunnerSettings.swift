import Foundation

/// `host`, `user@host`, `user@host:port` o `user@[ipv6]:port` (spec J.1). El host puede ser un `Host` de
/// `~/.ssh/config`. Solo letras, números, `.`, `_` y `-` (nunca empieza con `-`: ssh lo leería como una opción).
public struct SSHEndpoint: Codable, Hashable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    public struct ParseError: Error, Equatable, LocalizedError {
        public let text: String
        public var errorDescription: String? {
            "“\(text)” isn’t an SSH host. Use a Host from ~/.ssh/config or user@host[:port]."
        }
    }

    public static func parse(_ text: String) throws -> SSHEndpoint {
        let raw = text.trimmingCharacters(in: .whitespaces)
        let fail = ParseError(text: text)
        guard !raw.isEmpty, raw.count <= 255, !raw.hasPrefix("-"),
              raw.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { throw fail }
        var rest = Substring(raw)
        var user: String?
        if let at = rest.firstIndex(of: "@") {
            let name = String(rest[..<at])
            guard isName(name) else { throw fail }
            user = name
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        let host: String
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw fail }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { throw fail }
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = Int(after.dropFirst()), (1...65_535).contains(value) else { throw fail }
                port = value
            }
        } else {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, isName(String(parts[0])) else { throw fail }
            host = String(parts[0])
            if parts.count == 2 {
                guard let value = Int(parts[1]), (1...65_535).contains(value) else { throw fail }
                port = value
            }
        }
        return SSHEndpoint(user: user, host: host, port: port)
    }

    /// Letras, números, `.`, `_` y `-`, sin empezar con `-`.
    static func isName(_ text: String) -> Bool {
        guard let first = text.first, first != "-" else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    public var display: String {
        (user.map { "\($0)@" } ?? "") + (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
    }
}

/// Un host donde puede correr Claude (Settings › Claude › Run On).
public struct RunnerDestination: Codable, Hashable, Sendable, Identifiable {
    public static let defaultRemoteDir = "~/.prbar"
    /// Carpetas que Claude tiene negadas (`ClaudeRunner.deniedPaths`): la carpeta remota no puede estar adentro.
    static let deniedHomeFolders = [".ssh", ".aws", ".config", "Library", ".gnupg"]

    public var name: String
    public var endpoint: SSHEndpoint
    public var remoteDir: String
    public var fallbackToLocal: Bool

    public var id: String { name }

    public init(name: String, endpoint: SSHEndpoint, remoteDir: String = defaultRemoteDir, fallbackToLocal: Bool = true) {
        self.name = name
        self.endpoint = endpoint
        self.remoteDir = remoteDir
        self.fallbackToLocal = fallbackToLocal
    }

    public static func isValidName(_ name: String) -> Bool {
        name.count <= 40 && SSHEndpoint.isName(name) && !["local", "default"].contains(name.lowercased())
    }

    /// `~/<ruta>` o `/<a>/<b>…`; componentes `[A-Za-z0-9._-]`, sin `.` ni `..`; nunca dentro de una carpeta negada.
    public static func isValidRemoteDir(_ dir: String) -> Bool {
        guard dir.count <= 200 else { return false }
        let components: [Substring]
        if dir.hasPrefix("~/") {
            components = dir.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
            guard let first = components.first, !deniedHomeFolders.contains(String(first)) else { return false }
        } else if dir.hasPrefix("/") {
            components = dir.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard components.count >= 2 else { return false }
        } else {
            return false
        }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
        }
    }

    /// La carpeta como expresión de shell: `"$HOME"/'.prbar'` o `'/srv/prbar'`.
    public func remoteDirExpression() throws -> String {
        guard Self.isValidRemoteDir(remoteDir) else { throw RunnerConfigError.invalidRemoteDir(remoteDir) }
        if remoteDir.hasPrefix("~/") { return #""$HOME"/"# + (try ShellQuote.posix(String(remoteDir.dropFirst(2)))) }
        return try ShellQuote.posix(remoteDir)
    }
}

/// Dónde corre Claude: esta Mac o un destino por nombre. En JSON y en la CLI es `local` o el nombre.
public enum RunTarget: Hashable, Sendable, Codable {
    case local
    case runner(String)

    public init?(cliValue: String) {
        if cliValue == "local" {
            self = .local
        } else if RunnerDestination.isValidName(cliValue) {
            self = .runner(cliValue)
        } else {
            return nil
        }
    }

    public var cliValue: String {
        switch self {
        case .local: "local"
        case .runner(let name): name
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let target = RunTarget(cliValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid run target \(text)"))
        }
        self = target
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cliValue)
    }
}

public struct RunnerSettings: Codable, Hashable, Sendable {
    public var destinations: [RunnerDestination] = []
    public var defaultTarget: RunTarget = .local

    public init() {}

    enum CodingKeys: String, CodingKey { case destinations, defaultTarget }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinations = (try? c.decodeIfPresent([RunnerDestination].self, forKey: .destinations)) ?? []
        defaultTarget = (try? c.decodeIfPresent(RunTarget.self, forKey: .defaultTarget)) ?? .local
    }

    public func destination(named name: String) -> RunnerDestination? {
        destinations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public enum RunTargetResolver {
    /// Repo → global → This Mac (spec J.1). `nil` = esta Mac. Un nombre que ya no existe cuenta como "Default"; un
    /// default que ya no existe, como This Mac.
    public static func destination(for repo: RepoConfig?, settings: RunnerSettings) -> RunnerDestination? {
        switch repo?.runOn {
        case .local?: return nil
        case .runner(let name)?: if let found = settings.destination(named: name) { return found }
        case nil: break
        }
        if case .runner(let name) = settings.defaultTarget { return settings.destination(named: name) }
        return nil
    }
}

public enum RunnerConfigError: Error, Equatable, LocalizedError {
    case duplicate(String)
    case notFound(String)
    case invalidName(String)
    case invalidRemoteDir(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let name): "There’s already a runner named \(name)."
        case .notFound(let name): "There’s no runner named \(name). Run `prbar runners list`."
        case .invalidName(let name): "“\(name)” can’t be a runner name: use letters, numbers, . _ and - (not “local” or “default”)."
        case .invalidRemoteDir(let dir): "“\(dir)” can’t be the remote folder: use ~/<folder> or an absolute path with at least two parts, outside ~/.ssh, ~/.aws, ~/.config, ~/Library and ~/.gnupg."
        }
    }
}

extension AppConfig {
    public mutating func addRunner(_ destination: RunnerDestination) throws {
        guard RunnerDestination.isValidName(destination.name) else { throw RunnerConfigError.invalidName(destination.name) }
        guard RunnerDestination.isValidRemoteDir(destination.remoteDir) else { throw RunnerConfigError.invalidRemoteDir(destination.remoteDir) }
        guard runners.destination(named: destination.name) == nil else { throw RunnerConfigError.duplicate(destination.name) }
        runners.destinations.append(destination)
    }

    public mutating func updateRunner(named name: String, _ mutate: (inout RunnerDestination) -> Void) throws {
        guard let index = runners.destinations.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw RunnerConfigError.notFound(name)
        }
        var copy = runners.destinations[index]
        mutate(&copy)
        guard RunnerDestination.isValidRemoteDir(copy.remoteDir) else { throw RunnerConfigError.invalidRemoteDir(copy.remoteDir) }
        copy.name = runners.destinations[index].name
        runners.destinations[index] = copy
    }

    /// Saca el destino; los repos que lo usaban vuelven a "Default" y, si era el default, el default es This Mac.
    public mutating func removeRunner(named name: String) throws {
        guard let found = runners.destination(named: name) else { throw RunnerConfigError.notFound(name) }
        runners.destinations.removeAll { $0.name == found.name }
        if runners.defaultTarget == .runner(found.name) { runners.defaultTarget = .local }
        for a in accounts.indices {
            for r in accounts[a].repos.indices where accounts[a].repos[r].runOn == .runner(found.name) {
                accounts[a].repos[r].runOn = nil
            }
        }
    }

    public mutating func setDefaultRunTarget(_ target: RunTarget) throws {
        if case .runner(let name) = target {
            guard let found = runners.destination(named: name) else { throw RunnerConfigError.notFound(name) }
            runners.defaultTarget = .runner(found.name)
        } else {
            runners.defaultTarget = .local
        }
    }

    /// `nil` = "Default".
    public mutating func setRunOn(_ target: RunTarget?, repoID: String, login: String) {
        for a in accounts.indices where accounts[a].login.caseInsensitiveCompare(login) == .orderedSame {
            for r in accounts[a].repos.indices where accounts[a].repos[r].id.caseInsensitiveCompare(repoID) == .orderedSame {
                accounts[a].repos[r].runOn = target
            }
        }
    }
}
