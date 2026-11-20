import Foundation

/// Prepara el árbol de trabajo donde Claude implementa los fixes de un PR propio (spec §14.2): **siempre un
/// worktree propio de PRBar, separado (detached)**. Nunca usa el clone principal del usuario ni sus worktrees, ni
/// crea o mueve ramas: el usuario puede tener cambios sin commitear, commits sin pushear o la rama en otro lado,
/// y nada de eso se toca ni se mezcla con lo que escribe Claude.
///
/// - `fetch` (endurecido, sin `FETCH_HEAD`) de `+refs/heads/<headRef>` a una ref propia
///   `refs/prbar/respond-<N>-<runID>`; ese commit es la base del review (`startHeadOid`).
/// - `worktree add --detach <worktreeDir>/<repo>-<N>-respond-<runID> <sha>`.
/// - Antes de nada valida `headRef` y que `origin` sea `github.com/<owner>/<repo>` (https o ssh).
/// - Todos los `git` llevan `GitHardening.arguments` (sin hooks: `post-checkout` correría código del árbol) y
///   nunca piden credenciales.
/// - `cleanup` saca el worktree y la ref; `cleanupOrphans` hace lo mismo con los que quedaron de corridas
///   anteriores (solo los que tienen nombre de Responder, están en `worktreeDir` y están separados).
public struct WorktreeResolver: Sendable {
    static let refPrefix = "refs/prbar/respond-"

    private let runner: ProcessRunning
    private let gitPath: String
    private let environment: [String: String]
    private let originMatches: @Sendable (String, RepoRef) -> Bool

    /// `environment` se suma al de cada `git` (los tests lo usan para aislar la configuración global);
    /// `GIT_TERMINAL_PROMPT=0` siempre se mantiene. `originMatches` decide si la URL de `origin` es la del repo
    /// (los tests la reemplazan porque sus remotos son carpetas locales).
    public init(runner: ProcessRunning, gitPath: String, environment: [String: String] = [:],
                originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) }) {
        self.runner = runner
        self.gitPath = gitPath
        self.environment = environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, forced in forced }
        self.originMatches = originMatches
    }

    /// Crea el worktree de una corrida. Devuelve el worktree y el SHA que se trajo (= `startHeadOid`). Si algo
    /// falla después del fetch, borra lo que haya quedado (ref y worktree) antes de lanzar.
    public func prepare(localPath: String, repo: RepoRef, number: Int, headRef: String, worktreeDir: String?,
                        runID: String = WorktreeManager.newRunID()) async throws -> (worktree: ResolvedWorktree, headOid: String) {
        try await validateBranchName(headRef)
        try await verifyOrigin(localPath, repo: repo)
        let base = worktreeDir ?? Self.defaultWorktreeDir(localPath: localPath)
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        guard let realBase = Self.realPath(base) else {
            throw PRBarError.respond("Couldn't use the worktrees folder \(base).")
        }
        let name = Self.directoryName(repo: repo, number: number, runID: runID)
        let target = (realBase as NSString).appendingPathComponent(name)
        // `attributesOfItem` no sigue el último symlink: también frena ante un link roto.
        if (try? FileManager.default.attributesOfItem(atPath: target)) != nil {
            throw PRBarError.respond("\(target) already exists. Move or delete it and try again.")
        }

        let ref = Self.respondRef(number: number, runID: runID)
        let worktree = ResolvedWorktree(path: target, origin: .dedicated, localPath: localPath, ref: ref)
        WorkspaceRegistry.shared.insert(target)
        do {
            try await git(localPath, ["fetch", "--no-write-fetch-head", "origin", "+refs/heads/\(headRef):\(ref)"],
                          timeout: WorktreeManager.slowTimeout)
            let output = try await git(localPath, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
            guard let sha = CommitSHA.parse(output) else {
                throw PRBarError.respond("git rev-parse \(ref) returned \"\(output.prefix(80))\"")
            }
            try await git(localPath, ["worktree", "add", "--detach", target, sha], timeout: WorktreeManager.slowTimeout)
            guard let realTarget = Self.realPath(target),
                  (realTarget as NSString).deletingLastPathComponent == realBase,
                  (realTarget as NSString).lastPathComponent == name else {
                throw PRBarError.respond("The worktree for \(headRef) ended up outside \(realBase).")
            }
            return (worktree, sha)
        } catch {
            // Fuera de esta tarea: si se canceló, el runner mataría la limpieza en el acto.
            let resolver = self
            await Task.detached { await resolver.cleanup(worktree) }.value
            throw error
        }
    }

    /// `<localPath>-worktrees` (sin la barra final de `localPath`).
    public static func defaultWorktreeDir(localPath: String) -> String {
        var path = localPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path + "-worktrees"
    }

    /// `<repo>-<N>-respond-<runID>`, de una sola componente.
    public static func directoryName(repo: RepoRef, number: Int, runID: String) -> String {
        let cleaned = repo.name.replacingOccurrences(of: "/", with: "_")
        let name = cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "repo" : cleaned
        return "\(name)-\(number)-respond-\(runID)"
    }

    public static func respondRef(number: Int, runID: String) -> String { "\(refPrefix)\(number)-\(runID)" }

    /// Los nombres que crea `prepare`: `<algo>-<N>-respond-<8 hex en minúscula>`.
    public static func isRespondWorktreeName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4, WorktreeManager.isRunID(parts[parts.count - 1]), parts[parts.count - 2] == "respond" else { return false }
        let number = parts[parts.count - 3]
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
            && !parts.dropLast(3).joined(separator: "-").isEmpty
    }

    /// La URL de `origin` es exactamente `github.com/<owner>/<name>` (sin distinguir mayúsculas, con o sin `.git`
    /// y `/` final): `https://github.com/o/r`, `git@github.com:o/r` o `ssh://git@github.com/o/r`.
    public static func originMatches(_ url: String, repo: RepoRef) -> Bool {
        let lowered = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var path: Substring
        if let rest = ["https://github.com/", "ssh://git@github.com/", "git@github.com:"].first(where: { lowered.hasPrefix($0) }) {
            path = lowered.dropFirst(rest.count)
        } else {
            return false
        }
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        return path == repo.fullName.lowercased()
    }

    // MARK: - Limpieza

    /// `worktree remove --force` del worktree y `update-ref -d` de su ref. Solo toca un worktree de Responder
    /// (`.dedicated`, con nombre de Responder) y refs `refs/prbar/respond-*`. Nunca lanza: los errores se loguean.
    public func cleanup(_ worktree: ResolvedWorktree) async {
        guard worktree.origin == .dedicated, let localPath = worktree.localPath else { return }
        let name = (worktree.path as NSString).lastPathComponent
        if Self.isRespondWorktreeName(name), FileManager.default.fileExists(atPath: worktree.path) {
            if await gitLogged(localPath, ["worktree", "remove", "--force", worktree.path]) == nil,
               FileManager.default.fileExists(atPath: worktree.path) {
                AppLog.write("Respond: couldn't remove the worktree \(worktree.path)")
            }
        }
        if let ref = worktree.ref, Self.isOwnRef(ref) {
            await gitLogged(localPath, ["update-ref", "-d", ref])
        }
        WorkspaceRegistry.shared.remove(worktree.path)
    }

    /// Al arrancar: saca los worktrees de Responder que quedaron en `worktreeDir` (separados y con nombre de
    /// Responder; nunca los del usuario) y borra las refs `refs/prbar/respond-*`. Nunca corre `worktree prune`.
    public func cleanupOrphans(localPath: String, worktreeDir: String?) async {
        let base = worktreeDir ?? Self.defaultWorktreeDir(localPath: localPath)
        if let realBase = Self.realPath(base), let list = await gitLogged(localPath, ["worktree", "list", "--porcelain"]) {
            for block in list.components(separatedBy: "\n\n") {
                let lines = block.split(separator: "\n").map(String.init)
                guard lines.contains("detached"), let line = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
                let path = String(line.dropFirst("worktree ".count))
                let parent = Self.realPath((path as NSString).deletingLastPathComponent) ?? (path as NSString).deletingLastPathComponent
                guard parent == realBase, Self.isRespondWorktreeName((path as NSString).lastPathComponent) else { continue }
                await gitLogged(localPath, ["worktree", "remove", "--force", path])
            }
        }
        guard let refs = await gitLogged(localPath, ["for-each-ref", "--format=%(refname)", "refs/prbar/"]) else { return }
        for ref in refs.split(whereSeparator: \.isNewline).map(String.init) where Self.isOwnRef(ref) {
            await gitLogged(localPath, ["update-ref", "-d", ref])
        }
    }

    static func isOwnRef(_ ref: String) -> Bool {
        ref.hasPrefix(refPrefix) && ref.count > refPrefix.count && !ref.contains("..")
    }

    // MARK: - Validaciones

    /// Rechaza vacío, `-…`, `..`, espacios, caracteres de control, `HEAD`, `@{` y todo lo que
    /// `git check-ref-format --branch` no acepte tal cual.
    /// Público para que `RespondPublisher` valide la rama otra vez antes del push.
    public func validateBranchName(_ headRef: String) async throws {
        let invalid = PRBarError.respond("The branch name \"\(headRef)\" isn't valid.")
        guard !headRef.isEmpty, !headRef.hasPrefix("-"), !headRef.contains(".."), !headRef.contains("@{"),
              headRef != "HEAD",
              !headRef.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else { throw invalid }
        let result = try await runner.run(
            gitPath, ["check-ref-format", "--branch", headRef], environment: environment, currentDirectory: nil,
            timeout: ProcessTimeouts.standard
        )
        guard result.status == 0, result.stdout.trimmingCharacters(in: .newlines) == headRef else { throw invalid }
    }

    /// `git remote get-url origin` en `path` tiene que ser `github.com/<owner>/<name>`. Público para el push.
    public func verifyOrigin(_ path: String, repo: RepoRef) async throws {
        let url = try await git(path, ["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard originMatches(url, repo) else {
            throw PRBarError.respond("The origin remote of \(path) is \(url), not github.com/\(repo.fullName): not using it.")
        }
    }

    // MARK: - Git

    @discardableResult
    private func git(_ path: String, _ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> String {
        let args = ["-C", path] + GitHardening.arguments + arguments
        let result = try await runner.run(gitPath, args, environment: environment, currentDirectory: nil, timeout: timeout)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(
                command: (["git"] + ["-C", path] + arguments).joined(separator: " "),
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// Corre git sin lanzar: devuelve stdout si salió bien y loguea cualquier error.
    @discardableResult
    private func gitLogged(_ path: String, _ arguments: [String]) async -> String? {
        do {
            return try await git(path, arguments, timeout: WorktreeManager.slowTimeout)
        } catch {
            AppLog.write("Respond: failed `git -C \(path) \(arguments.joined(separator: " "))`: \(error.localizedDescription)")
            return nil
        }
    }

    /// `realpath(3)`: la ruta absoluta sin symlinks (p. ej. `/private/var/...`), o nil si no existe.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
