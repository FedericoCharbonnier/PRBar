import Foundation

/// El clon propio del repo de PRBar del que se compilan las actualizaciones (spec D.3, paso 2). Se crea con
/// `git clone --no-checkout` la primera vez y después se reusa. Todos los `git` llevan `GitHardening` (sin hooks,
/// sin fsmonitor, sin submódulos, sin pedir credenciales).
public struct UpdateSource: Sendable {
    /// Para `clone` y `fetch`.
    public static let fetchTimeout: TimeInterval = 300
    /// El tag tiene que ser alcanzable desde acá.
    public static let mainRef = "refs/remotes/origin/main"

    public let directory: URL
    public let remoteURL: String
    private let runner: ProcessRunning
    private let gitPath: String

    public init(runner: ProcessRunning, gitPath: String, directory: URL = AppPaths.updateSourceDir, remoteURL: String) {
        self.runner = runner
        self.gitPath = gitPath
        self.directory = directory
        self.remoteURL = remoteURL
    }

    /// `owner/name` (ya validado con `UpdateSettings.effectiveRepo`) → URL https del repo.
    public static func remoteURL(forRepo repo: String) -> String { "https://github.com/\(repo).git" }

    /// Deja `directory` en el commit del tag, detached y sin archivos de más (los ignorados, como `.build`, quedan
    /// para que el build sea incremental). Devuelve el sha. Rechaza un tag que no es versión, que no existe o cuyo
    /// commit no es alcanzable desde `origin/main`.
    @discardableResult
    public func checkout(tag: String) async throws -> String {
        guard !tag.hasPrefix("-"), SemanticVersion(tag) != nil else { throw UpdateError.invalidTag(tag) }
        let fileManager = FileManager.default
        let path = directory.path
        if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            // El repo pudo cambiar en la config (un fork).
            try await git(["-C", path, "remote", "set-url", "origin", remoteURL])
        } else {
            // Un clon a medio hacer de un intento anterior.
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await git(["clone", "--no-checkout", "--quiet", remoteURL, path], timeout: Self.fetchTimeout)
        }
        try await git(["-C", path, "fetch", "--quiet", "--tags", "--force", "--prune", "origin"], timeout: Self.fetchTimeout)

        let resolved = try await run(["-C", path, "rev-parse", "--verify", "--quiet", "refs/tags/\(tag)^{commit}"])
        guard resolved.status == 0, let sha = CommitSHA.parse(resolved.stdout) else { throw UpdateError.tagMissing(tag) }

        let reachable = try await run(["-C", path, "merge-base", "--is-ancestor", sha, Self.mainRef])
        switch reachable.status {
        case 0: break
        case 1: throw UpdateError.tagNotOnMain(tag)
        default: throw Self.failure(["merge-base", "--is-ancestor", sha, Self.mainRef], reachable)
        }

        // Se hace checkout del sha verificado, no del tag: un fetch en el medio no puede cambiar lo que se compila.
        try await git(["-C", path, "checkout", "--quiet", "--force", "--detach", sha], timeout: Self.fetchTimeout)
        try await git(["-C", path, "clean", "-ffdq"])
        return sha
    }

    private func run(_ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> ProcessResult {
        try await runner.run(gitPath, GitHardening.arguments + arguments, environment: GitHardening.environment,
                             currentDirectory: nil, timeout: timeout)
    }

    @discardableResult
    private func git(_ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> String {
        let result = try await run(arguments, timeout: timeout)
        guard result.status == 0 else { throw Self.failure(arguments, result) }
        return result.stdout
    }

    private static func failure(_ arguments: [String], _ result: ProcessResult) -> PRBarError {
        .commandFailed(command: (["git"] + arguments).joined(separator: " "), status: result.status,
                       stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
