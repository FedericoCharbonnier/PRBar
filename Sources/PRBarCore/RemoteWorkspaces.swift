import Foundation

/// Dónde se escriben la carpeta de contexto y sus archivos (`pr.diff`, `pr.md`, `feedback.json`). PRBar genera el
/// contenido igual que siempre (fences, neutralización); acá solo cambia dónde queda.
public protocol ContextFiles: Sendable {
    func createDirectory(_ path: String) async throws
    func write(_ data: Data, to path: String) async throws
    func removeTree(_ path: String) async
    func exists(_ path: String) async -> Bool
    /// El contenido (hasta `limit` bytes), o nil si no se puede leer.
    func read(_ path: String, limit: Int) async -> Data?
}

public struct LocalContextFiles: ContextFiles {
    public init() {}
    public func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    public func write(_ data: Data, to path: String) async throws { try data.write(to: URL(fileURLWithPath: path)) }
    public func removeTree(_ path: String) async { try? FileManager.default.removeItem(atPath: path) }
    public func exists(_ path: String) async -> Bool { FileManager.default.fileExists(atPath: path) }
    public func read(_ path: String, limit: Int) async -> Data? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= limit else { return nil }
        return data
    }
}

public struct RemoteContextFiles: ContextFiles {
    let host: SSHHost
    let root: RemoteRoot

    public init(host: SSHHost, root: RemoteRoot) {
        self.host = host
        self.root = root
    }

    public func createDirectory(_ path: String) async throws {
        guard root.isRemovable(path) else { throw RemoteRunnerError.outsideRoot(path) }
        try host.checked(try await host.runScript("umask 077 && mkdir -p -- \(try ShellQuote.posix(path))", timeout: 30), "mkdir")
    }
    public func write(_ data: Data, to path: String) async throws { try await host.upload(data, to: path, root: root) }
    public func removeTree(_ path: String) async { try? await host.removeTree(path, root: root) }
    public func exists(_ path: String) async -> Bool {
        guard root.contains(path), let quoted = try? ShellQuote.posix(path) else { return false }
        return (try? await host.runScript("[ -e \(quoted) ]", timeout: 30).status) == 0
    }
    public func read(_ path: String, limit: Int) async -> Data? {
        guard root.contains(path), let local = try? LocalScratch.newFile() else { return nil }
        defer { try? FileManager.default.removeItem(at: local) }
        guard (try? await host.download(path, to: local, root: root, maxBytes: limit)) == true,
              let data = FileManager.default.contents(atPath: local.path), data.count <= limit else { return nil }
        return data
    }
}

/// Repos y worktrees en el host (spec J.3, decisiones J.7.7 y J.7.16). Los mismos refs (`refs/prbar/*`), el mismo
/// `GitHardening` y la misma neutralización de symlinks que en la Mac; el "clone" es un mirror bare propio de PRBar.
public struct RemoteWorkspaces: Sendable {
    public let host: SSHHost
    public let root: RemoteRoot
    public let gitPath: String
    public let runner: RemoteProcessRunner
    public let fs: RemoteWorkspaceFS
    public let gitEnvironment: [String: String]
    let remoteURLs: @Sendable (RepoRef) -> [String]
    let originMatches: @Sendable (String, RepoRef) -> Bool
    let runID: @Sendable () -> String
    let now: @Sendable () -> Date

    public init(host: SSHHost, root: RemoteRoot, gitPath: String, runner: RemoteProcessRunner, fs: RemoteWorkspaceFS,
                gitEnvironment: [String: String] = [:],
                remoteURLs: @escaping @Sendable (RepoRef) -> [String] = { ["https://github.com/\($0.fullName).git", "git@github.com:\($0.fullName).git"] },
                originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) },
                runID: @escaping @Sendable () -> String = WorktreeManager.newRunID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.root = root
        self.gitPath = gitPath
        self.runner = runner
        self.fs = fs
        self.gitEnvironment = gitEnvironment.merging(GitHardening.environment) { _, forced in forced }
        self.remoteURLs = remoteURLs
        self.originMatches = originMatches
        self.runID = runID
        self.now = now
    }

    public var contextFiles: RemoteContextFiles { RemoteContextFiles(host: host, root: root) }

    // MARK: Git

    @discardableResult
    func git(_ path: String, _ arguments: [String], timeout: TimeInterval = WorktreeManager.slowTimeout) async throws -> String {
        guard root.contains(path) else { throw RemoteRunnerError.outsideRoot(path) }
        let result = try await runner.run(gitPath, GitHardening.arguments + ["-C", path] + arguments, environment: gitEnvironment,
                                          currentDirectory: nil, timeout: timeout)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "), status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    @discardableResult
    func gitLogged(_ path: String, _ arguments: [String]) async -> String? {
        do { return try await git(path, arguments) } catch {
            AppLog.write("Remote (\(host.name)): `git \(arguments.joined(separator: " "))` failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Mirror

    /// `<raíz>/repos/<owner>/<name>.git`, bare; lo crea la primera vez. El `origin` queda en la primera URL que fetchea.
    public func mirror(_ repo: RepoRef) async throws -> String {
        let bare = try root.child(["repos", repo.owner, repo.name + ".git"])
        let exists = (try? await host.runScript("[ -d \(try ShellQuote.posix(bare + "/objects")) ]", timeout: 30).status) == 0
        if !exists {
            try host.checked(try await host.runScript("umask 077 && mkdir -p -- \(try ShellQuote.posix(bare))", timeout: 30), "mkdir")
            let created = try await runner.run(gitPath, ["init", "--bare", "-q", bare], environment: gitEnvironment, currentDirectory: nil, timeout: 60)
            guard created.status == 0 else { throw RemoteRunnerError.cannotFetch(host: host.name, repo: repo.fullName) }
            try await git(bare, ["remote", "add", "origin", remoteURLs(repo).first ?? ""])
        }
        return bare
    }

    /// `fetch` con la URL de `origin`; si falla, prueba las otras y deja la que anduvo.
    func fetch(_ bare: String, repo: RepoRef, _ refspecs: [String]) async throws {
        let urls = remoteURLs(repo)
        let current = (try? await git(bare, ["remote", "get-url", "origin"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in [current].compactMap({ $0 }) + urls.filter({ $0 != current }) {
            if url != current { try await git(bare, ["remote", "set-url", "origin", url]) }
            if (try? await git(bare, ["fetch", "--no-write-fetch-head", "--no-tags", "origin"] + refspecs)) != nil { return }
        }
        throw RemoteRunnerError.cannotFetch(host: host.name, repo: repo.fullName)
    }

    // MARK: Review y chat

    /// Como `WorktreeManager.prepare`, en el host. `localPath` es el mirror (`mirror(_:)`).
    public func prepare(repo: RepoRef, number: Int, baseRef: String, localPath: String?, name customName: String?,
                        pinnedHeadOid: String?) async throws -> ReviewWorkspace {
        guard let bare = localPath, root.contains(bare) else { throw RemoteRunnerError.outsideRoot(localPath ?? "") }
        if let customName {
            guard WorktreeManager.isChatWorkspaceName(customName), !customName.hasSuffix(".context"), !customName.hasSuffix("-diff") else {
                throw PRBarError.invalidResponse("Invalid chat workspace name: \(customName)")
            }
        }
        if let pinnedHeadOid, CommitSHA.parse(pinnedHeadOid) != pinnedHeadOid {
            throw PRBarError.invalidResponse("Invalid pinned commit: \(pinnedHeadOid.prefix(80))")
        }
        let id = runID()
        let name = customName ?? "\(repo.name)-\(number)-\(Int(now().timeIntervalSince1970))-\(id)"
        let directory = try root.child(["work", name])
        let prRef = WorktreeManager.prRef(number, id)
        let base = WorktreeManager.baseRef(number, id)
        let workspace = ReviewWorkspace(directory: URL(fileURLWithPath: directory, isDirectory: true), baseRef: base, prRef: prRef, isDiffOnly: false)
        do {
            try await fetch(bare, repo: repo, ["+pull/\(number)/head:\(prRef)", "+refs/heads/\(baseRef):\(base)"])
            guard var sha = CommitSHA.parse(try await git(bare, ["rev-parse", "--verify", "--quiet", "\(prRef)^{commit}"])) else {
                throw RemoteRunnerError.malformedOutput(host: host.name, what: "commit id")
            }
            if let pinned = pinnedHeadOid, pinned != sha, (try? await git(bare, ["cat-file", "-e", "\(pinned)^{commit}"])) != nil {
                try await git(bare, ["update-ref", prRef, pinned])
                sha = pinned
            }
            try await git(bare, ["worktree", "add", "--detach", directory, prRef])
            let listing = try await git(directory, ["ls-files", "-s", "-z"])
            try await fs.neutralizeSymlinks(WorktreeManager.symlinkPaths(fromLsFiles: listing), in: directory)
            return ReviewWorkspace(directory: workspace.directory, baseRef: base, prRef: prRef, isDiffOnly: false, headOid: sha)
        } catch {
            let spaces = self
            await Task.detached { await spaces.cleanup(workspace, localPath: bare) }.value
            throw error
        }
    }

    /// §8.5 en el host: `worktree remove --force` de ese worktree, su carpeta y su admin dir en el mirror propio, las dos
    /// refs y la carpeta de contexto. Nunca `git worktree prune`. Nunca lanza.
    public func cleanup(_ workspace: ReviewWorkspace, localPath: String?) async {
        let directory = workspace.directory.path
        guard !RemoteUnstoppedJobs.shared.contains(host: host.name, path: directory) else {
            AppLog.write("Remote (\(host.name)): Claude may still be running in \(directory); not cleaning it up.")
            return
        }
        try? await host.removeTree(workspace.contextDirectory.path, root: root)
        guard root.isRemovable(directory) else { return }
        if let bare = localPath, root.contains(bare) {
            await gitLogged(bare, ["worktree", "remove", "--force", directory])
            for ref in [workspace.prRef, workspace.baseRef].compactMap({ $0 }) where ref.hasPrefix("refs/prbar/") {
                await gitLogged(bare, ["update-ref", "-d", ref])
            }
            // Si git no pudo sacarlo, su admin dir en el mirror propio (nunca `git worktree prune`).
            let admin = bare + "/worktrees/" + workspace.directory.lastPathComponent
            if root.isRemovable(admin) { try? await host.removeTree(admin, root: root) }
        }
        try? await host.removeTree(directory, root: root)
    }

    /// The review's folder stays on the host for "Open in Terminal" (spec T.3): only its context folder goes.
    public func release(_ workspace: ReviewWorkspace) async {
        try? await host.removeTree(workspace.contextDirectory.path, root: root)
    }

    // MARK: The PR's review folder (spec RM.2)

    /// `WorktreeManager.prepareReview` on the host: `<root>/work/<repo>-<N>-review` in PRBar's mirror, created once and
    /// then updated in place; a failed fetch leaves it as it is; invalid or a failing checkout → removed and created again;
    /// with the user's work or another mirror's → untouched, a per-run folder.
    public func prepareReview(repo: RepoRef, number: Int, baseRef: String, localPath: String?) async throws -> ReviewWorkspace {
        guard let bare = localPath, root.contains(bare) else { throw RemoteRunnerError.outsideRoot(localPath ?? "") }
        let directory = try root.child(["work", WorktreeManager.reviewFolderName(repo: repo, number: number)])
        let workspace = ReviewWorkspace(directory: URL(fileURLWithPath: directory, isDirectory: true),
                                        baseRef: WorktreeManager.baseRef(number, WorktreeManager.reviewRunID),
                                        prRef: WorktreeManager.prRef(number, WorktreeManager.reviewRunID), isDiffOnly: false)
        let spaces = self
        // Claude may still be running in it (a Stop that couldn't be confirmed): not touched in this session.
        if RemoteUnstoppedJobs.shared.contains(host: host.name, path: directory) {
            AppLog.write("Remote (\(host.name)): Claude may still be running in \(directory); this review uses a folder of its own.")
            return try await prepare(repo: repo, number: number, baseRef: baseRef, localPath: bare, name: nil, pinnedHeadOid: nil)
        }
        if await reviewFolderExists(directory) {
            let state = await reviewFolderState(directory, bare: bare)
            if state == .valid, let reason = await reviewFolderWork(directory) {
                AppLog.write("Remote (\(host.name)): \(directory) \(reason); left as is, this review uses a folder of its own.")
                return try await prepare(repo: repo, number: number, baseRef: baseRef, localPath: bare, name: nil, pinnedHeadOid: nil)
            }
            switch state {
            case .valid:
                // A fetch that fails says nothing about the folder: it stays as it is.
                let sha = try await fetchReviewRefs(workspace, repo: repo, number: number, baseRef: baseRef, bare: bare)
                do {
                    return try await updateReviewFolder(workspace.at(sha))
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    AppLog.write("Remote (\(host.name)): couldn’t update \(directory) (\(error.localizedDescription)); creating it again.")
                }
            case .invalid(let why):
                AppLog.write("Remote (\(host.name)): \(directory) \(why); creating it again.")
            case .foreign:
                AppLog.write("Remote (\(host.name)): \(directory) belongs to another mirror; this review uses a folder of its own.")
                return try await prepare(repo: repo, number: number, baseRef: baseRef, localPath: bare, name: nil, pinnedHeadOid: nil)
            }
            await Task.detached { await spaces.cleanup(workspace, localPath: bare) }.value
        }
        do {
            let sha = try await fetchReviewRefs(workspace, repo: repo, number: number, baseRef: baseRef, bare: bare)
            try await git(bare, ["worktree", "add", "--detach", directory, workspace.prRef ?? ""])
            try await neutralizeReviewSymlinks(directory)
            return workspace.at(sha)
        } catch {
            await Task.detached { await spaces.cleanup(workspace, localPath: bare) }.value
            throw error
        }
    }

    /// `WorktreeManager.reviewFolderState` on the host: a real folder whose `.git` file points to an admin dir in this
    /// mirror's `worktrees/`, listed and without nested `.git`. A symlink, a `.git` folder or a gitdir anywhere else is
    /// foreign (never touched); so is a folder the host can't describe.
    public func reviewFolderState(_ directory: String, bare: String) async -> WorktreeManager.ReviewFolderState {
        let dotGit = directory + "/.git"
        guard let kinds = try? await fs.describe([directory, dotGit]), kinds[directory]?.hasPrefix("dir:") == true else {
            return .foreign
        }
        let kind = kinds[dotGit] ?? "none"
        if kind == "none" { return .invalid("isn’t a git worktree") }
        guard kind.hasPrefix("file:") else { return .foreign }
        guard let text = try? await fs.readText(dotGit, limit: 4096), text.hasPrefix("gitdir: ") else {
            return .invalid("has a .git file git can’t read")
        }
        let gitdir = WorktreeManager.resolvedGitdir(text, in: directory)
        let parent = (gitdir as NSString).deletingLastPathComponent
        let admins = bare + "/worktrees"
        if parent != admins {
            guard let real = await realDirectory(parent), real == (await realDirectory(admins)) else { return .foreign }
        }
        if let list = await gitLogged(bare, ["worktree", "list", "--porcelain"]),
           WorktreeManager.worktreePaths(fromPorcelain: list).contains(directory) {
            guard let nested = try? await fs.nestedGits(directory) else { return .invalid("couldn’t be checked") }
            return nested.isEmpty ? .valid : .invalid("has nested .git entries")
        }
        return await contextFiles.exists(gitdir) ? .foreign : .invalid("is a worktree this mirror no longer knows")
    }

    /// Something is at `path` (`lstat`: a dangling symlink counts).
    private func reviewFolderExists(_ path: String) async -> Bool {
        guard let kinds = try? await fs.describe([path]) else { return await contextFiles.exists(path) }
        return (kinds[path] ?? "none") != "none"
    }

    /// `pwd -P` of a folder on the host, or nil.
    private func realDirectory(_ path: String) async -> String? {
        guard let quoted = try? ShellQuote.posix(path),
              let result = try? await host.runScript("cd -P -- \(quoted) 2>/dev/null && pwd -P", timeout: 30), result.status == 0 else {
            return nil
        }
        let real = result.stdout.trimmingCharacters(in: .newlines)
        return real.isEmpty ? nil : real
    }

    /// The folder at the fetched head (`workspace.headOid`): checkout, clean, symlinks neutralized, `.context` empty.
    private func updateReviewFolder(_ workspace: ReviewWorkspace) async throws -> ReviewWorkspace {
        let directory = workspace.directory.path
        try? await host.removeTree(workspace.contextDirectory.path, root: root)
        try await git(directory, ["checkout", "--detach", "--force", workspace.prRef ?? ""])
        try await git(directory, ["clean", "-ffdx"])
        try await neutralizeReviewSymlinks(directory)
        return workspace
    }

    /// `WorktreeManager.reviewFolderWork` on the host.
    func reviewFolderWork(_ path: String) async -> String? {
        guard let listing = await gitLogged(path, ["ls-files", "-s", "-z"]),
              let status = await gitLogged(path, ["status", GitHardening.ignoreSubmodules, "--porcelain", "-z", "--untracked-files=all"]) else {
            return "couldn't be checked with git"
        }
        if WorktreeManager.hasUserChanges(statusZ: status, neutralizedSymlinks: Set(WorktreeManager.symlinkPaths(fromLsFiles: listing))) {
            return "has uncommitted changes"
        }
        guard let count = await gitLogged(path, ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags", "--glob=refs/prbar/*"]),
              let commits = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "couldn't be checked with git" }
        return commits == 0 ? nil : "has \(commits) unpushed commit\(commits == 1 ? "" : "s")"
    }

    private func fetchReviewRefs(_ workspace: ReviewWorkspace, repo: RepoRef, number: Int, baseRef: String,
                                 bare: String) async throws -> String {
        guard let prRef = workspace.prRef, let base = workspace.baseRef else {
            throw RemoteRunnerError.malformedOutput(host: host.name, what: "review refs")
        }
        try await fetch(bare, repo: repo, ["+pull/\(number)/head:\(prRef)", "+refs/heads/\(baseRef):\(base)"])
        guard let sha = CommitSHA.parse(try await git(bare, ["rev-parse", "--verify", "--quiet", "\(prRef)^{commit}"])) else {
            throw RemoteRunnerError.malformedOutput(host: host.name, what: "commit id")
        }
        return sha
    }

    private func neutralizeReviewSymlinks(_ directory: String) async throws {
        let listing = try await git(directory, ["ls-files", "-s", "-z"])
        try await fs.neutralizeSymlinks(WorktreeManager.symlinkPaths(fromLsFiles: listing), in: directory)
    }

    /// `WorktreeResolver.unpushedWork` on the host: `nil` if the worktree at `path` (inside the root) can go; otherwise why
    /// not (uncommitted changes, commits on no branch, remote, tag or `refs/prbar/*`, or git couldn't tell).
    public func unpushedWork(_ path: String) async -> String? {
        guard let status = await gitLogged(path, ["status", GitHardening.ignoreSubmodules, "--porcelain", "--untracked-files=all"]) else {
            return "couldn't be checked with git"
        }
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "has uncommitted changes" }
        guard let count = await gitLogged(path, ["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags", "--glob=refs/prbar/*"]),
              let commits = Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "couldn't be checked with git" }
        return commits == 0 ? nil : "has \(commits) unpushed commit\(commits == 1 ? "" : "s")"
    }

    // MARK: Respond

    /// Como `WorktreeResolver.prepare`, en el host. `worktreeDir` se ignora (siempre `<raíz>/work`).
    public func prepareRespond(localPath bare: String, repo: RepoRef, number: Int, headRef: String, worktreeDir: String?,
                               runID: String = WorktreeManager.newRunID()) async throws -> (worktree: ResolvedWorktree, headOid: String) {
        guard root.contains(bare) else { throw RemoteRunnerError.outsideRoot(bare) }
        let resolver = WorktreeResolver(runner: runner, gitPath: gitPath, environment: gitEnvironment, originMatches: originMatches)
        try await resolver.validateBranchName(headRef)
        let name = WorktreeResolver.directoryName(repo: repo, number: number, runID: runID)
        let target = try root.child(["work", name])
        let ref = WorktreeResolver.respondRef(number: number, runID: runID)
        let worktree = ResolvedWorktree(path: target, origin: .dedicated, localPath: bare, ref: ref)
        do {
            try await fetch(bare, repo: repo, ["+refs/heads/\(headRef):\(ref)"])
            try await resolver.verifyOrigin(bare, repo: repo)
            guard let sha = CommitSHA.parse(try await git(bare, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])) else {
                throw RemoteRunnerError.malformedOutput(host: host.name, what: "commit id")
            }
            try await git(bare, ["worktree", "add", "--detach", target, sha])
            let real = try host.checked(try await host.runScript("cd -P -- \(try ShellQuote.posix(target)) && pwd -P", timeout: 30), "pwd")
                .stdout.trimmingCharacters(in: .newlines)
            guard real == target else { throw RemoteRunnerError.outsideRoot(real) }
            return (worktree, sha)
        } catch {
            let spaces = self
            await Task.detached { await spaces.cleanupRespond(worktree) }.value
            throw error
        }
    }

    /// Como `WorktreeResolver.fetchBase`, en el mirror del host.
    public func fetchRespondBase(_ worktree: ResolvedWorktree, repo: RepoRef, baseRef: String) async throws -> String {
        guard worktree.origin == .dedicated, let bare = worktree.localPath, root.contains(bare), let ref = worktree.ref,
              ref.hasPrefix("refs/prbar/respond-"), !ref.contains("..") else { throw RemoteRunnerError.outsideRoot(worktree.path) }
        let resolver = WorktreeResolver(runner: runner, gitPath: gitPath, environment: gitEnvironment, originMatches: originMatches)
        try await resolver.validateBranchName(baseRef)
        let target = WorktreeResolver.baseRef(forRunRef: ref)
        try await fetch(bare, repo: repo, ["+refs/heads/\(baseRef):\(target)"])
        guard let sha = CommitSHA.parse(try await git(bare, ["rev-parse", "--verify", "--quiet", "\(target)^{commit}"])) else {
            throw RemoteRunnerError.malformedOutput(host: host.name, what: "commit id")
        }
        return sha
    }

    /// `WorktreeResolver.markPushed` on the host: the push ran from the Mac, so the run's `refs/prbar/respond-…` in the
    /// mirror moves to the pushed sha (the mirror has no branches: otherwise the kept folder always looks unpushed).
    /// Never throws.
    public func markPushed(_ worktree: ResolvedWorktree, sha: String) async {
        guard worktree.origin == .dedicated, let bare = worktree.localPath, root.contains(bare), let ref = worktree.ref,
              ref.hasPrefix("refs/prbar/respond-"), !ref.contains(".."), FixImplementer.isFullSHA(sha) else { return }
        await gitLogged(bare, ["update-ref", ref, sha])
    }

    public func cleanupRespond(_ worktree: ResolvedWorktree) async {
        guard worktree.origin == .dedicated, let bare = worktree.localPath, root.contains(bare),
              WorktreeResolver.isRespondWorktreeName((worktree.path as NSString).lastPathComponent) else { return }
        guard !RemoteUnstoppedJobs.shared.contains(host: host.name, path: worktree.path) else {
            AppLog.write("Remote (\(host.name)): Claude may still be running in \(worktree.path); not cleaning it up.")
            return
        }
        await gitLogged(bare, ["worktree", "remove", "--force", worktree.path])
        if let ref = worktree.ref, ref.hasPrefix("refs/prbar/respond-") {
            await gitLogged(bare, ["update-ref", "-d", ref])
            await gitLogged(bare, ["update-ref", "-d", WorktreeResolver.baseRef(forRunRef: ref)])
        }
        try? await host.removeTree(worktree.path, root: root)
    }

    // MARK: Huérfanos

    /// Al arrancar (decisión J.7.16). Solo dentro de la raíz de esta instalación (`installs/<id>`: otra Mac con la
    /// misma carpeta tiene la suya) y con un candado (`cleanup.lock`, un `mkdir` atómico: la app y la CLI de esta Mac
    /// comparten la raíz). Aun así, solo lo que seguro no está en uso: los pid de grupos que ya no existen (y su
    /// lápida), y en `work/` y `tmp/` lo que no cambió en `olderThan`. Los trabajos no la esperan: un worktree
    /// registrado sin carpeta se vuelve a mirar antes de sacarlo, y las refs `refs/prbar/*` de un mirror se borran
    /// solo si ya no le queda ningún worktree y no cambiaron en `olderThan`. Nunca lanza.
    public func cleanupOrphans(olderThan age: TimeInterval = 12 * 3600, keeping kept: Set<String>) async {
        guard let marker = try? ShellQuote.posix(root.markerPath), let lockPath = try? root.child(["cleanup.lock"]),
              let lock = try? ShellQuote.posix(lockPath), let work = try? ShellQuote.posix(root.work),
              let jobs = try? ShellQuote.posix(root.jobs), let tmp = try? ShellQuote.posix(root.tmp),
              let repos = try? ShellQuote.posix(root.repos) else { return }
        let minutes = max(1, Int((age / 60).rounded(.up)))
        let acquire = """
        [ -f \(marker) ] || exit 96
        mkdir -- \(lock) 2>/dev/null && exit 0
        [ -n "$(find \(lock) -maxdepth 0 -mmin +60 2>/dev/null)" ] && rmdir -- \(lock) 2>/dev/null && mkdir -- \(lock) 2>/dev/null && exit 0
        exit 75
        """
        guard (try? await host.runScript(acquire, timeout: 30))?.status == 0 else {
            AppLog.write("Remote (\(host.name)): another PRBar is cleaning \(root.path); skipping the orphan cleanup.")
            return
        }

        // Trabajos: un pid cuyo grupo ya no existe (o inválido y viejo) se borra con su lápida; lápidas viejas sueltas.
        let jobsScript = """
        cd -- \(jobs) || exit 0
        for f in *.pid; do
          [ -f "$f" ] || continue
          pgid=$(cat -- "$f" 2>/dev/null)
          case $pgid in
            ''|*[!0-9]*) [ -n "$(find "$f" -mmin +\(minutes) 2>/dev/null)" ] && rm -f -- "$f" "${f%.pid}.cancel" ;;
            *) if [ "$pgid" -le 1 ] || ! kill -0 -- "-$pgid" 2>/dev/null; then rm -f -- "$f" "${f%.pid}.cancel"; fi ;;
          esac
        done
        for f in *.cancel; do
          [ -f "$f" ] && [ ! -e "${f%.cancel}.pid" ] && [ -n "$(find "$f" -mmin +\(minutes) 2>/dev/null)" ] && rm -f -- "$f"
        done
        exit 0
        """
        _ = try? await host.runScript("[ -f \(marker) ] || exit 96\n" + jobsScript, timeout: 60)

        // `work/`: cada entrada, vieja (nada adentro cambió en `olderThan`) o no.
        let workScript = """
        cd -- \(work) || exit 0
        for d in * .[!.]* ..?*; do
          [ -e "$d" ] || [ -L "$d" ] || continue
          g=; [ -e "$d/.git" ] && g=+git
          if [ -z "$(find "$d" -mmin -\(minutes) -print 2>/dev/null | head -n 1)" ]; then printf 'old%s %s\\n' "$g" "$d"; else printf 'new%s %s\\n' "$g" "$d"; fi
        done
        exit 0
        """
        var stale: Set<String> = []
        var present: Set<String> = []
        var gitWorktrees: Set<String> = []
        for line in ((try? await host.runScript(workScript, timeout: 300))?.stdout ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let path = try? root.child(["work", parts[1]]) else { continue }
            present.insert(path)
            if parts[0].hasPrefix("old") { stale.insert(path) }
            if parts[0].hasSuffix("+git") { gitWorktrees.insert(path) }
        }
        // Kept for "Open in Terminal" (spec T.3): never stale, however old.
        stale.subtract(kept)
        stale.subtract(await protectedStale(stale, gitWorktrees: gitWorktrees))

        let listing = "for d in \(repos)/*/*.git; do [ -d \"$d/objects\" ] && printf '%s\\n' \"$d\"; done; exit 0"
        let mirrors = ((try? await host.runScript(listing, timeout: 60))?.stdout ?? "")
            .split(separator: "\n").map(String.init).filter(root.contains)
        // Los trabajos no esperan a esta limpieza (ni toman el candado): uno puede fetchear sus refs o agregar su
        // worktree mientras corre. Por eso un worktree "perdido" se vuelve a mirar justo antes de sacarlo, y una ref
        // se borra solo si también es vieja.
        for bare in mirrors {
            guard let list = await gitLogged(bare, ["worktree", "list", "--porcelain"]) else { continue }
            var remaining = 0
            for path in WorktreeManager.worktreePaths(fromPorcelain: list) where path.hasPrefix(root.work + "/") {
                // Viejo, o perdido: registrado pero su carpeta no está (ni estaba al mirar `work/`, ni ahora: un
                // `worktree add` crea la carpeta antes de registrarlo).
                var dead = stale.contains(path)
                if !dead && !present.contains(path) { dead = !(await exists(path)) }
                if dead {
                    await gitLogged(bare, ["worktree", "remove", "--force", path])
                } else {
                    remaining += 1
                }
            }
            guard remaining == 0, let refs = await gitLogged(bare, ["for-each-ref", "--format=%(refname)", "refs/prbar/"]) else { continue }
            let old = await oldRefs(bare, minutes: minutes)
            for ref in refs.split(separator: "\n").map(String.init)
            where ref.hasPrefix("refs/prbar/") && !ref.contains("..") && old(ref) {
                await gitLogged(bare, ["update-ref", "-d", ref])
            }
        }
        for path in stale.sorted() { try? await host.removeTree(path, root: root) }
        _ = try? await host.runScript("[ -f \(marker) ] || exit 96\nfind \(tmp) -mindepth 1 -maxdepth 1 -mmin +\(minutes) -exec rm -rf -- {} +",
                                      timeout: 300)
        _ = try? await host.runScript("rmdir -- \(lock)", timeout: 30)
    }

    /// The old `work/` folders that must stay (like the local cleanups): a process has its cwd inside (`lsof`; if it
    /// can't be checked, all of them), or a git worktree with uncommitted changes or unpushed commits (or git can't
    /// tell). Each one is logged.
    private func protectedStale(_ stale: Set<String>, gitWorktrees: Set<String>) async -> Set<String> {
        let candidates = stale.sorted()
        guard !candidates.isEmpty else { return [] }
        var protected: Set<String> = []
        if let script = try? ProcessCwd.remoteScript(resolving: candidates),
           let result = try? await host.runScript(script, timeout: 60), result.status == 0 {
            protected = ProcessCwd.busyDirectories(candidates, remoteOutput: result.stdout)
            for path in protected.sorted() {
                AppLog.write("Remote (\(host.name)): kept \(path) at launch: it has a process working in it")
            }
        } else {
            AppLog.write("Remote (\(host.name)): couldn’t check with lsof which old folders are in use; keeping them.")
            return Set(candidates)
        }
        for path in candidates where gitWorktrees.contains(path) && !protected.contains(path) {
            if let reason = await unpushedWork(path) {
                AppLog.write("Remote (\(host.name)): kept \(path) at launch: it \(reason)")
                protected.insert(path)
            }
        }
        return protected
    }

    /// Si `path` existe en el host (también un symlink roto). Ante la duda, sí.
    private func exists(_ path: String) async -> Bool {
        guard let quoted = try? ShellQuote.posix(path), let result = try? await host.runScript("[ -e \(quoted) ] || [ -L \(quoted) ]", timeout: 30),
              result.status == 0 || result.status == 1 else { return true }
        return result.status == 0
    }

    /// Qué refs de `refs/prbar/` del mirror no cambiaron en `minutes`: una ref suelta por la fecha de su archivo, una
    /// empaquetada por la de `packed-refs`. Ante la duda (no se pudo mirar), ninguna.
    private func oldRefs(_ bare: String, minutes: Int) async -> @Sendable (String) -> Bool {
        guard let quoted = try? ShellQuote.posix(bare) else { return { _ in false } }
        let script = """
        cd -- \(quoted) || exit 1
        if [ -d refs/prbar ]; then
          find refs/prbar -type f -print | sed 's/^/loose /'
          find refs/prbar -type f -mmin +\(minutes) -print | sed 's/^/old /'
        fi
        if [ -f packed-refs ] && [ -n "$(find packed-refs -mmin +\(minutes) 2>/dev/null)" ]; then echo packed-old; fi
        exit 0
        """
        guard let result = try? await host.runScript(script, timeout: 60), result.status == 0 else { return { _ in false } }
        var loose: Set<String> = []
        var old: Set<String> = []
        var packedOld = false
        for line in result.stdout.split(separator: "\n").map(String.init) {
            if line == "packed-old" { packedOld = true }
            else if line.hasPrefix("loose ") { loose.insert(String(line.dropFirst(6))) }
            else if line.hasPrefix("old ") { old.insert(String(line.dropFirst(4))) }
        }
        return { [loose, old, packedOld] ref in loose.contains(ref) ? old.contains(ref) : packedOld }
    }
}
