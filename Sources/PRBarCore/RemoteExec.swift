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
