import Foundation

public struct ReviewWorkspace: Equatable, Sendable {
    /// Directorio donde corre Claude. Con clone local es el worktree; sin clone, una carpeta temporal vacía.
    public let directory: URL
    /// Ref de la base (`refs/prbar/base-<N>-<id>`) o nil en modo solo diff.
    public let baseRef: String?
    /// Ref del PR (`refs/prbar/pr-<N>-<id>`) o nil en modo solo diff.
    public let prRef: String?
    public let isDiffOnly: Bool
    /// SHA del commit que se trajo para el worktree (`git rev-parse` de la ref del PR justo después del fetch).
    /// Es el commit que se revisa y contra el que se publica. Nil en modo solo diff: ahí lo averigua
    /// `ReviewContextWriter` justo antes de bajar el diff.
    public let headOid: String?

    public init(directory: URL, baseRef: String?, prRef: String? = nil, isDiffOnly: Bool, headOid: String? = nil) {
        self.directory = directory
        self.baseRef = baseRef
        self.prRef = prRef
        self.isDiffOnly = isDiffOnly
        self.headOid = headOid
    }

    /// Carpeta con los datos que PRBar prepara para Claude (`pr.diff`, `pr.md`). Está junto al worktree,
    /// dentro de la misma raíz pero fuera del checkout del PR: `<root>/<nombre>.context`.
    public var contextDirectory: URL {
        directory.deletingLastPathComponent()
            .appendingPathComponent(directory.lastPathComponent + ".context", isDirectory: true)
    }

    /// El diff del PR (`base...HEAD`), calculado por PRBar.
    public var diffFile: URL { contextDirectory.appendingPathComponent("pr.diff") }

    /// Los metadatos del PR en Markdown.
    public var metadataFile: URL { contextDirectory.appendingPathComponent("pr.md") }
}

/// SHA de un commit tal como lo imprimen `git rev-parse` o `gh` (40 o 64 dígitos hexadecimales).
public enum CommitSHA {
    public static func parse(_ output: String) -> String? {
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard sha.count == 40 || sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }
}

/// Worktrees temporales para las reviews (spec §8.2). Solo usa refs propias (`refs/prbar/*`) y
/// `worktree add --detach`: nunca toca las ramas ni el working copy del usuario. Solo borra carpetas
/// que estén directamente dentro de `root`.
///
/// Cada `prepare` lleva un id de corrida (8 caracteres hexadecimales) en las refs y en el nombre de la
/// carpeta: si se cancela una review y se vuelve a pedir enseguida, la limpieza de la corrida vieja no
/// toca las refs ni el worktree de la nueva.
public struct WorktreeManager: Sendable {
    /// Para `fetch` y `worktree add`, que pueden tardar en repos grandes.
    public static let slowTimeout: TimeInterval = 120
    static let refPrefix = "refs/prbar/"

    private let runner: ProcessRunning
    private let gitPath: String
    private let root: URL
    private let now: @Sendable () -> Date
    private let runID: @Sendable () -> String

    public init(
        runner: ProcessRunning, gitPath: String, root: URL = AppPaths.worktreesDir,
        now: @escaping @Sendable () -> Date = { Date() }, runID: @escaping @Sendable () -> String = WorktreeManager.newRunID
    ) {
        self.runner = runner
        self.gitPath = gitPath
        self.root = root.standardizedFileURL
        self.now = now
        self.runID = runID
    }

    /// 8 caracteres hexadecimales (en minúscula) de un UUID nuevo.
    @Sendable public static func newRunID() -> String {
        String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8))
    }

    /// Todos los `git` llevan `GitHardening`; el fetch no escribe `FETCH_HEAD` en el repo del usuario.
    /// Con `localPath`: fetch de `+pull/<N>/head:refs/prbar/pr-<N>-<id>` y `+refs/heads/<base>:refs/prbar/base-<N>-<id>`,
    /// `rev-parse` de la ref del PR (el `headOid` del workspace) y `worktree add --detach
    /// <root>/<repo>-<N>-<epoch>-<id> refs/prbar/pr-<N>-<id>`.
    /// Sin `localPath`: crea `<root>/<repo>-<N>-<epoch>-<id>-diff` vacío.
    /// For the chat (spec B.5):
    /// - `name`: the folder's name instead of `<repo>-<N>-<epoch>-<id>` (the refs still use the run id);
    /// - `pinnedHeadOid`: the commit to check out instead of the PR's current head, if the clone has it (`cat-file -e`).
    ///   If it doesn't, the current head (the workspace's `headOid` says which one it is).
    public func prepare(repo: RepoRef, number: Int, baseRef: String, localPath: String?,
                        name customName: String? = nil, pinnedHeadOid: String? = nil) async throws -> ReviewWorkspace {
        if let customName {
            // A single folder name of the chat's pattern (`chatWorkspaceName`), never a path.
            guard Self.isChatWorkspaceName(customName), !customName.contains("/"),
                  !customName.hasSuffix(".context"), !customName.hasSuffix("-diff") else {
                throw PRBarError.invalidResponse("Invalid chat workspace name: \(customName)")
            }
        }
        if let pinnedHeadOid {
            // It goes to `cat-file` and `update-ref`: only a full, lowercase commit sha.
            guard CommitSHA.parse(pinnedHeadOid) == pinnedHeadOid else {
                throw PRBarError.invalidResponse("Invalid pinned commit: \(pinnedHeadOid.prefix(80))")
            }
        }
        let id = runID()
        let name = customName ?? "\(Self.sanitize(repo.name))-\(number)-\(Int(now().timeIntervalSince1970))-\(id)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard let localPath else {
            let directory = root.appendingPathComponent(name + "-diff", isDirectory: true)
            WorkspaceRegistry.shared.insert(directory.path)
            WorkspaceRegistry.shared.insert(directory.path + ".context")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                WorkspaceRegistry.shared.remove(directory.path)
                WorkspaceRegistry.shared.remove(directory.path + ".context")
                throw error
            }
            return ReviewWorkspace(directory: directory, baseRef: nil, isDiffOnly: true)
        }

        let directory = root.appendingPathComponent(name, isDirectory: true)
        WorkspaceRegistry.shared.insert(directory.path)
        WorkspaceRegistry.shared.insert(directory.path + ".context")
        let prRef = Self.prRef(number, id)
        let baseRefName = Self.baseRef(number, id)
        let headOid: String
        do {
            try await git(localPath, ["fetch", "--no-write-fetch-head", "origin", "+pull/\(number)/head:\(prRef)", "+refs/heads/\(baseRef):\(baseRefName)"], timeout: Self.slowTimeout)
            // El commit que se trajo de verdad: el PR pudo recibir commits después del snapshot.
            let output = try await git(localPath, ["rev-parse", "--verify", "--quiet", "\(prRef)^{commit}"])
            guard var sha = CommitSHA.parse(output) else {
                throw PRBarError.invalidResponse("git rev-parse \(prRef) returned \"\(output.prefix(80))\"")
            }
            if let pinned = pinnedHeadOid, pinned != sha,
               (try? await git(localPath, ["cat-file", "-e", "\(pinned)^{commit}"])) != nil {
                try await git(localPath, ["update-ref", prRef, pinned])
                sha = pinned
            }
            headOid = sha
            try await git(localPath, ["worktree", "add", "--detach", directory.path, prRef], timeout: Self.slowTimeout)
            try await neutralizeSymlinks(in: directory)
        } catch {
            // Falló o se canceló a mitad de camino: pueden haber quedado las refs (un fetch cortado puede
            // haberlas escrito) y un worktree a medio crear. Se limpian en una tarea aparte, como
            // `ReviewPipeline.cleanup`: si la tarea está cancelada, el runner mataría estos `git` en el acto.
            let partial = ReviewWorkspace(directory: directory, baseRef: baseRefName, prRef: prRef, isDiffOnly: false)
            let manager = self
            await Task.detached { await manager.cleanup(partial, localPath: localPath) }.value
            throw error
        }
        return ReviewWorkspace(directory: directory, baseRef: baseRefName, prRef: prRef, isDiffOnly: false, headOid: headOid)
    }

    /// `worktree remove --force` del worktree de esta corrida, `update-ref -d` de sus dos refs y borrar la
    /// carpeta y su carpeta de contexto. Nunca corre `git worktree prune`: eso podaría todos los worktrees
    /// "perdidos" del repo del usuario (p. ej. los suyos en un disco desmontado). Si git no pudo sacar el
    /// worktree (la carpeta ya no estaba), se borra solo su carpeta de administración (`.git/worktrees/<nombre>`).
    /// Nunca lanza: los errores se loguean.
    public func cleanup(_ workspace: ReviewWorkspace, localPath: String?) async {
        if isDirectChildOfRoot(workspace.contextDirectory) { removeItem(workspace.contextDirectory) }
        let insideRoot = isDirectChildOfRoot(workspace.directory)
        if !insideRoot {
            AppLog.write("Worktree: not deleting \(workspace.directory.path) because it isn't inside \(root.path)")
        }
        if let localPath, !workspace.isDiffOnly {
            if insideRoot { await removeWorktrees([workspace.directory], of: localPath) }
            for ref in [workspace.prRef, workspace.baseRef].compactMap({ $0 }) where Self.isOwnRef(ref) {
                await gitLogged(localPath, ["update-ref", "-d", ref])
            }
        } else if insideRoot {
            removeItem(workspace.directory)
        }
        WorkspaceRegistry.shared.remove(workspace.directory.path)
        WorkspaceRegistry.shared.remove(workspace.contextDirectory.path)
    }

    /// The review's folder stays for "Open in Terminal" (spec T.3): its context folder goes, the worktree and its refs
    /// stay, and it stops counting as in use (Activity and Clean Up see it). Never throws.
    public func release(_ workspace: ReviewWorkspace) {
        if isDirectChildOfRoot(workspace.contextDirectory) { removeItem(workspace.contextDirectory) }
        WorkspaceRegistry.shared.remove(workspace.directory.path)
        WorkspaceRegistry.shared.remove(workspace.contextDirectory.path)
    }

    /// Al arrancar: en cada `localPath`, saca los worktrees que `git worktree list --porcelain` muestra dentro
    /// de `root` (y solo esos) y borra cada ref en `refs/prbar/` salvo las de los worktrees de Responder que siguen
    /// en pie; después borra lo que haya quedado en `root`. `kept`: the folders kept for "Open in Terminal" (spec T.3),
    /// left in place with their two refs (Clean Up counts on them to tell the PR's commits from unpushed work).
    /// A worktree with uncommitted changes or unpushed commits also stays, with its refs (logged): if the list of
    /// kept folders was lost, the user's work in one isn't.
    public func cleanupOrphans(localPaths: [String], keeping kept: Set<String>) async {
        var keptPaths = Set(kept.map(CanonicalPath.of))
        var keptRefs = Set(kept.flatMap { Self.reviewRefs(forWorkspaceName: ($0 as NSString).lastPathComponent) })
        for path in localPaths {
            // Las refs de Responder de los worktrees que siguen en pie no se tocan: `WorktreeResolver.cleanupOrphans`
            // guarda los que tienen trabajo sin pushear.
            var keptRespondRefs: Set<String>?
            if let list = await gitLogged(path, ["worktree", "list", "--porcelain"]) {
                let paths = Self.worktreePaths(fromPorcelain: list)
                var own: [URL] = []
                for url in paths.map({ URL(fileURLWithPath: $0) })
                where isDirectChildOfRoot(url) && Self.isWorkspaceName(url.lastPathComponent)
                    && !keptPaths.contains(CanonicalPath.of(url.path)) {
                    // A lost worktree (its folder is gone) has nothing left to lose.
                    if FileManager.default.fileExists(atPath: url.path), let reason = await unpushedWork(url.path) {
                        AppLog.write("Worktree: kept \(url.path) at launch: it \(reason)")
                        keptPaths.insert(CanonicalPath.of(url.path))
                        keptRefs.formUnion(Self.reviewRefs(forWorkspaceName: url.lastPathComponent))
                        continue
                    }
                    own.append(url)
                }
                await removeWorktrees(own, of: path)
                keptRespondRefs = Set(paths.compactMap { WorktreeResolver.respondRef(forWorktreePath: $0) })
            }
            guard let output = await gitLogged(path, ["for-each-ref", "--format=%(refname)", Self.refPrefix]) else { continue }
            let refs = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { Self.isOwnRef($0) && !keptRefs.contains($0) }
                // Sin la lista no se sabe qué worktree de Responder sigue en pie: ninguna de sus refs se borra.
                .filter { ref in keptRespondRefs.map { !$0.contains(ref) } ?? !ref.hasPrefix(WorktreeResolver.refPrefix) }
            for ref in refs {
                await gitLogged(path, ["update-ref", "-d", ref])
            }
        }
        if Self.isSafeRoot(root) {
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for entry in entries
            where Self.isWorkspaceName(entry.lastPathComponent) && !keptPaths.contains(CanonicalPath.of(entry.path)) {
                // A git worktree no `worktree list` above covered (its repo isn't set up any more, or git failed
                // there): never lose its work. One that can't be checked stays too.
                if FileManager.default.fileExists(atPath: entry.appendingPathComponent(".git").path),
                   let reason = await unpushedWork(entry.path) {
                    AppLog.write("Worktree: kept \(entry.path) at launch: it \(reason)")
                    continue
                }
                removeItem(entry)
            }
        } else {
            AppLog.write("Worktree: not emptying \(root.path) because it doesn't look like a PRBar folder")
        }
    }

    // MARK: - Symlinks

    /// Un PR puede commitear symlinks que apunten fuera del repo (p. ej. a `~/.ssh/id_rsa`); el `Read` de Claude
    /// los seguiría y podría copiar un secreto en un hallazgo. Cada entrada con modo `120000` de
    /// `git ls-files -s -z` se reemplaza en el worktree por un archivo de texto común con
    /// `[symlink a <destino> omitido por PRBar]`. Nunca se sigue el link: `lstat`, `readlink` y `unlink`.
    /// Si no se puede neutralizar alguno, lanza (la review no debe correr con el link en su lugar).
    private func neutralizeSymlinks(in worktree: URL) async throws {
        let output = try await git(worktree.path, ["ls-files", "-s", "-z"], timeout: Self.slowTimeout)
        for path in Self.symlinkPaths(fromLsFiles: output) {
            try Self.neutralizeSymlink(at: path, in: worktree)
        }
    }

    /// Las rutas con modo `120000` (symlink) de la salida de `git ls-files -s -z`
    /// (`<modo> <sha> <etapa>\t<ruta>\0`).
    public static func symlinkPaths(fromLsFiles output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry in
            guard let tab = entry.firstIndex(of: "\t") else { return nil }
            let mode = entry[entry.startIndex..<tab].split(separator: " ").first
            return mode == "120000" ? String(entry[entry.index(after: tab)...]) : nil
        }
    }

    /// Texto que reemplaza a un symlink del PR.
    public static func symlinkPlaceholder(target: String) -> String {
        "[symlink to \(target) omitted by PRBar]\n"
    }

    static func neutralizeSymlink(at relativePath: String, in worktree: URL) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw PRBarError.invalidResponse("invalid path in the PR: \(relativePath)")
        }
        let url = worktree.appendingPathComponent(relativePath)
        // La carpeta que lo contiene tiene que estar de verdad dentro del worktree (sin symlinks en el camino).
        let realWorktree = worktree.resolvingSymlinksInPath().standardizedFileURL.path
        let realParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard realParent == realWorktree || realParent.hasPrefix(realWorktree + "/") else {
            throw PRBarError.invalidResponse("the symlink \(relativePath) is outside the worktree")
        }
        let fullPath = realParent + "/" + url.lastPathComponent
        var info = stat()
        guard lstat(fullPath, &info) == 0 else {
            // No se hizo checkout (p. ej. sparse checkout): no hay nada que seguir. Salvo que la ruta no sea
            // UTF-8 válido (la salida de git se decodificó con reemplazos): ahí no se puede saber, así que falla.
            if errno == ENOENT, !relativePath.contains("\u{FFFD}") { return }
            throw PRBarError.invalidResponse("couldn't read \(relativePath): \(String(cString: strerror(errno)))")
        }
        guard info.st_mode & S_IFMT == S_IFLNK else { return }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(fullPath, &buffer, buffer.count - 1)
        let target = length >= 0
            ? String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "?"
        guard unlink(fullPath) == 0 else {
            throw PRBarError.invalidResponse("couldn't delete the symlink \(relativePath): \(String(cString: strerror(errno)))")
        }
        // O_EXCL | O_NOFOLLOW: si alguien recreó un link en ese lugar, falla en vez de escribir a través de él.
        let fd = open(fullPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw PRBarError.invalidResponse("couldn't replace the symlink \(relativePath): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let bytes = Array(symlinkPlaceholder(target: target).utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            throw PRBarError.invalidResponse("couldn't write the replacement for \(relativePath)")
        }
    }

    // MARK: - Limpieza (ayudantes)

    /// Las rutas de los worktrees (líneas `worktree <ruta>`) de `git worktree list --porcelain`.
    public static func worktreePaths(fromPorcelain output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }

    /// Saca de `localPath` los worktrees `directories` (todos directamente dentro de `root`): `worktree remove
    /// --force` si la carpeta existe; si git no pudo (o la carpeta ya no estaba), borra la carpeta y la
    /// carpeta de administración de git que apunta a ella.
    private func removeWorktrees(_ directories: [URL], of localPath: String) async {
        var forgotten: [URL] = []
        for directory in directories where isDirectChildOfRoot(directory) {
            let removedByGit = FileManager.default.fileExists(atPath: directory.path)
                ? await gitLogged(localPath, ["worktree", "remove", "--force", directory.path]) != nil
                : false
            removeItem(directory)
            if !removedByGit { forgotten.append(directory) }
        }
        guard !forgotten.isEmpty else { return }
        await removeAdminDirectories(pointingTo: forgotten, of: localPath)
    }

    /// Borra `<git-common-dir>/worktrees/<nombre>` de los worktrees `directories`: solo las carpetas cuyo
    /// archivo `gitdir` apunta a `<uno de directories>/.git`, y todos están directamente dentro de `root`.
    private func removeAdminDirectories(pointingTo directories: [URL], of localPath: String) async {
        guard let output = await gitLogged(localPath, ["rev-parse", "--git-common-dir"]) else { return }
        let commonPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonPath.isEmpty else { return }
        let common = commonPath.hasPrefix("/")
            ? URL(fileURLWithPath: commonPath, isDirectory: true)
            : URL(fileURLWithPath: localPath, isDirectory: true).appendingPathComponent(commonPath, isDirectory: true)
        let adminRoot = common.appendingPathComponent("worktrees", isDirectory: true).standardizedFileURL
        let names = Set(directories.map(\.lastPathComponent))
        let entries = (try? FileManager.default.contentsOfDirectory(at: adminRoot, includingPropertiesForKeys: nil)) ?? []
        for admin in entries {
            guard let gitdir = try? String(contentsOf: admin.appendingPathComponent("gitdir"), encoding: .utf8) else { continue }
            let pointsTo = URL(fileURLWithPath: gitdir.trimmingCharacters(in: .whitespacesAndNewlines))
            // `<worktree>/.git`: el worktree tiene que ser uno de los nuestros, directamente dentro de `root`.
            guard pointsTo.lastPathComponent == ".git" else { continue }
            let worktree = pointsTo.deletingLastPathComponent()
            guard names.contains(worktree.lastPathComponent), isDirectChildOfRoot(worktree),
                  admin.standardizedFileURL.deletingLastPathComponent().path == adminRoot.path else { continue }
            AppLog.write("Worktree: deleting \(admin.path), which pointed to \(worktree.path) (no longer exists)")
            removeItem(admin)
        }
    }

    // MARK: - Seguridad

    /// `false` para rutas en las que nunca se debe borrar nada: `/`, el home, sus ancestros y rutas muy cortas
    /// (p. ej. `~/Library` o `/tmp`).
    public static func isSafeRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix("/"), url.standardizedFileURL.pathComponents.count >= 5 else { return false }
        if path == home || (home + "/").hasPrefix(path + "/") { return false }
        return true
    }

    /// The review chat's worktree (spec B.5): `chat-<repo>-<N>-<session UUID>`, fixed per session so `--resume`
    /// runs in the same cwd. Without a clone, `prepare` adds `-diff`.
    public static func chatWorkspaceName(repo: RepoRef, number: Int, sessionID: UUID) -> String {
        "chat-\(sanitize(repo.name))-\(number)-\(sessionID.uuidString.lowercased())"
    }

    /// `chat-<repo>-<N>-<UUID>`, with `-diff` and/or `.context`.
    static func isChatWorkspaceName(_ name: String) -> Bool {
        var base = Substring(name)
        guard base.hasPrefix("chat-") else { return false }
        if base.hasSuffix(".context") { base = base.dropLast(8) }
        if base.hasSuffix("-diff") { base = base.dropLast(5) }
        guard base.count > 5 + 37, base.dropLast(36).last == "-", UUID(uuidString: String(base.suffix(36))) != nil else { return false }
        let rest = base.dropFirst(5).dropLast(37)   // "<repo>-<N>"
        guard let dash = rest.lastIndex(of: "-"), dash > rest.startIndex else { return false }
        let number = rest[rest.index(after: dash)...]
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Nombres que crea `prepare`: `<repo>-<N>-<epoch>-<id>` o `<repo>-<N>-<epoch>-<id>-diff`, y sus carpetas
    /// de contexto (`<nombre>.context`), y la carpeta de review del PR (`<repo>-<N>-review`, spec RM.2).
    /// También acepta los de versiones anteriores, sin `-<id>`.
    public static func isWorkspaceName(_ name: String) -> Bool {
        if isChatWorkspaceName(name) { return true }
        if isReviewFolderName(name) { return true }
        if name.hasSuffix(".respond-context") { return isRespondContextName(name) }
        var base = Substring(name)
        if base.hasSuffix(".context") { base = base.dropLast(8) }
        if base.hasSuffix("-diff") { base = base.dropLast(5) }
        var parts = base.split(separator: "-", omittingEmptySubsequences: false)
        if let last = parts.last, isRunID(last) { parts.removeLast() }
        guard parts.count >= 3 else { return false }
        let isNumber = { (part: Substring) in !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) }
        return isNumber(parts[parts.count - 1]) && isNumber(parts[parts.count - 2])
            && !parts.dropLast(2).joined(separator: "-").isEmpty
    }

    /// Las carpetas de contexto de Responder: `<owner>-<repo>-<N>-<UUID>.respond-context`.
    static func isRespondContextName(_ name: String) -> Bool {
        guard name.hasSuffix(".respond-context") else { return false }
        let base = name.dropLast(".respond-context".count)
        guard base.count > 37, base.dropLast(36).last == "-", UUID(uuidString: String(base.suffix(36))) != nil else { return false }
        let rest = base.dropLast(37)
        guard let dash = rest.lastIndex(of: "-"), dash > rest.startIndex else { return false }
        let number = rest[rest.index(after: dash)...]
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// 8 caracteres hexadecimales en minúscula, como los de `newRunID`.
    static func isRunID(_ text: Substring) -> Bool {
        text.count == 8 && text.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
    }

    /// Solo se borran refs propias: `refs/prbar/<algo>`.
    static func isOwnRef(_ ref: String) -> Bool {
        ref.hasPrefix(refPrefix) && ref.count > refPrefix.count && !ref.contains("..")
    }

    /// `url` está directamente dentro de `root` (comparando también con symlinks resueltos: git guarda rutas
    /// reales, p. ej. `/private/var/...` en vez de `/var/...`).
    private func isDirectChildOfRoot(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name != "/" else { return false }
        let parent = standardized.deletingLastPathComponent()
        let rootPaths = [root.path, root.resolvingSymlinksInPath().path]
        let parentPaths = [parent.path, parent.resolvingSymlinksInPath().path]
        return Self.isSafeRoot(root) && parentPaths.contains { rootPaths.contains($0) }
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "repo" : cleaned
    }

    /// `nil` if the worktree can go; otherwise why not. The same check as Clean Up and `WorktreeResolver`: uncommitted
    /// changes, or commits on no branch, remote, tag or `refs/prbar/*` (the run's own refs hold the PR's commits).
    public func unpushedWork(_ path: String) async -> String? {
        guard let status = await gitLogged(path, ["status", GitHardening.ignoreSubmodules, "--porcelain", "--untracked-files=all"]) else {
            return "couldn't be checked with git"
        }
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "has uncommitted changes" }
        guard let count = await gitLogged(path, ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags", "--glob=refs/prbar/*"]),
              let commits = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "couldn't be checked with git" }
        return commits == 0 ? nil : "has \(commits) unpushed commit\(commits == 1 ? "" : "s")"
    }

    /// The two refs of a review folder `<repo>-<N>-<epoch>-<id>` (`refs/prbar/pr-<N>-<id>`, `refs/prbar/base-<N>-<id>`);
    /// none for any other name (diff-only, context, chat or without a run id).
    public static func reviewRefs(forWorkspaceName name: String) -> [String] {
        if isReviewFolderName(name) {
            guard !name.hasSuffix(".context"),
                  let number = name.dropLast("-review".count).split(separator: "-").last.flatMap({ Int($0) }) else { return [] }
            return [prRef(number, reviewRunID), baseRef(number, reviewRunID)]
        }
        guard !isChatWorkspaceName(name), !name.hasSuffix(".context"), !name.hasSuffix("-diff"), isWorkspaceName(name) else { return [] }
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4, let id = parts.last, isRunID(id), let number = Int(parts[parts.count - 3]) else { return [] }
        return [prRef(number, String(id)), baseRef(number, String(id))]
    }

    static func prRef(_ number: Int, _ id: String) -> String { "\(refPrefix)pr-\(number)-\(id)" }
    static func baseRef(_ number: Int, _ id: String) -> String { "\(refPrefix)base-\(number)-\(id)" }

    // MARK: - The PR's review folder (spec RM.2)

    /// The run id of the PR's review folder: its refs are `refs/prbar/pr-<N>-review` and `refs/prbar/base-<N>-review`.
    public static let reviewRunID = "review"

    /// `<repo>-<N>-review`: the folder every review of the PR uses (spec RM.2).
    public static func reviewFolderName(repo: RepoRef, number: Int) -> String {
        "\(sanitize(repo.name))-\(number)-review"
    }

    /// `<repo>-<N>-review` or its `<…>.context`.
    public static func isReviewFolderName(_ name: String) -> Bool {
        var base = Substring(name)
        if base.hasSuffix(".context") { base = base.dropLast(8) }
        guard base.hasSuffix("-review") else { return false }
        let rest = base.dropLast(7)   // "<repo>-<N>"
        guard let dash = rest.lastIndex(of: "-"), dash > rest.startIndex else { return false }
        let number = rest[rest.index(after: dash)...]
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The workspace is the PR's review folder: not a diff-only one, nor a per-run one (the fallback of decision 1).
    public static func isReviewFolder(_ workspace: ReviewWorkspace) -> Bool {
        let name = workspace.directory.lastPathComponent
        return !workspace.isDiffOnly && !name.hasSuffix(".context") && isReviewFolderName(name)
    }

    // MARK: - Git

    @discardableResult
    private func git(_ path: String, _ arguments: [String], timeout: TimeInterval = ProcessTimeouts.standard) async throws -> String {
        let args = ["-C", path] + arguments
        let result = try await runner.run(
            gitPath, GitHardening.arguments + args, environment: GitHardening.environment, currentDirectory: nil, timeout: timeout
        )
        guard result.status == 0 else {
            throw PRBarError.commandFailed(
                command: (["git"] + args).joined(separator: " "),
                status: result.status,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }

    /// Corre git sin lanzar: devuelve stdout si salió bien y loguea cualquier error.
    @discardableResult
    private func gitLogged(_ path: String, _ arguments: [String]) async -> String? {
        let args = ["-C", path] + arguments
        do {
            let result = try await runner.run(
                gitPath, GitHardening.arguments + args, environment: GitHardening.environment,
                currentDirectory: nil, timeout: ProcessTimeouts.standard
            )
            guard result.status == 0 else {
                AppLog.write("Worktree: `git \(args.joined(separator: " "))` failed (code \(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return nil
            }
            return result.stdout
        } catch {
            AppLog.write("Worktree: `git \(args.joined(separator: " "))` failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func removeItem(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.write("Worktree: couldn't delete \(url.path): \(error.localizedDescription)")
        }
    }
}
