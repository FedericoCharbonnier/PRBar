import Foundation

/// El clon propio del repo de PRBar del que se compilan las actualizaciones (spec D.3, paso 2). Se crea con
/// `git init` (sin plantillas) la primera vez y después se reusa.
///
/// No confía en nada del clon salvo los objetos: cada `fetch` lleva la URL y los refspecs explícitos (solo `main` y
/// el tag pedido, sin tags de más), y antes de usarlo se revisa que su `.git/config` tenga solo las claves que deja
/// `git init` y que no haya `.git/info/attributes`; si no, se borra y se empieza de cero. Todos los `git` llevan
/// `GitHardening` (sin hooks, fsmonitor ni submódulos), sin la config global ni la del sistema (ni `insteadOf`,
/// proxies, credential helpers, `include` o filtros de ahí), sin attributes globales y sin pedir credenciales.
public struct UpdateSource: Sendable {
    /// Para `fetch`.
    public static let fetchTimeout: TimeInterval = 300
    /// El tag tiene que ser alcanzable desde acá.
    public static let mainRef = "refs/remotes/origin/main"
    public static let gitArguments = GitHardening.arguments + [
        "-c", "core.attributesFile=/dev/null", "-c", "credential.helper=",
    ]
    public static let environment = GitHardening.environment.merging([
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    ]) { _, new in new }
    /// Lo que deja `git init` en `.git/config`. Cualquier otra clave (`remote.*`, `url.*`, `http.*`, `credential.*`,
    /// `include.*`, `filter.*`, `core.sshCommand`…) hace que el clon se descarte.
    public static let allowedConfigKeys: Set<String> = [
        "core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates", "core.ignorecase",
        "core.precomposeunicode",
    ]

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
    /// para que el build sea incremental). Devuelve el sha. Rechaza un tag que no es exactamente `vX.Y.Z`, que no
    /// existe o cuyo commit no es alcanzable desde `main`. Si falla otra cosa (un fetch o un `rev-parse` raro: el
    /// clon pudo romperse) borra el clon y prueba una vez más desde cero.
    @discardableResult
    public func checkout(tag: String) async throws -> String {
        guard SemanticVersion(releaseTag: tag) != nil else { throw UpdateError.invalidTag(tag) }
        do {
            return try await attempt(tag: tag)
        } catch let error as UpdateError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: directory)
            return try await attempt(tag: tag)
        }
    }

    private func attempt(tag: String) async throws -> String {
        let path = directory.path
        try await prepareRepository()

        let tagRef = "refs/tags/\(tag)"
        let fetch = try await run(
            ["-C", path, "fetch", "--quiet", "--no-tags", "--force", remoteURL,
             "+refs/heads/main:\(Self.mainRef)", "+\(tagRef):\(tagRef)"],
            timeout: Self.fetchTimeout
        )
        if fetch.status != 0 {
            // ¿Falló porque el tag no está en el remoto?
            let remote = try await run(["ls-remote", "--tags", remoteURL, tagRef], timeout: Self.fetchTimeout)
            if remote.status == 0, remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw UpdateError.tagMissing(tag)
            }
            throw Self.failure(["fetch", remoteURL, tagRef], fetch)
        }

        let revParse = ["-C", path, "rev-parse", "--verify", "--quiet", "\(tagRef)^{commit}"]
        let resolved = try await run(revParse)
        if resolved.status == 1 { throw UpdateError.tagMissing(tag) }
        guard resolved.status == 0, let sha = CommitSHA.parse(resolved.stdout) else { throw Self.failure(revParse, resolved) }

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

    /// Reusa el clon si es de confianza; si no (o si no hay), lo borra y hace `git init` sin plantillas.
    private func prepareRepository() async throws {
        let fileManager = FileManager.default
        if try await isTrustedRepository() { return }
        // Un clon a medio hacer, de otra versión de PRBar o tocado por alguien más.
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(["init", "--quiet", "--template=", directory.path])
    }

    private func isTrustedRepository() async throws -> Bool {
        let gitDir = directory.appendingPathComponent(".git", isDirectory: true)
        let values = try? gitDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return false }
        // Attributes del repo fuera del árbol: podrían pedir filtros (aunque sin config no hay ninguno definido).
        let attributes = gitDir.appendingPathComponent("info/attributes")
        guard (try? attributes.checkResourceIsReachable()) != true else { return false }
        let config = try await run(["-C", directory.path, "config", "--local", "--list", "--name-only"])
        guard config.status == 0 else { return false }
        let keys = config.stdout.split(whereSeparator: \.isNewline).map { $0.lowercased() }
        let allowed = Set(Self.allowedConfigKeys.map { $0.lowercased() })
        return keys.allSatisfy(allowed.contains)
    }

    private func run(_ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> ProcessResult {
        try await runner.run(gitPath, Self.gitArguments + arguments, environment: Self.environment,
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
