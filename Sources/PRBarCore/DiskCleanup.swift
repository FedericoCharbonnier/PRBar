import Foundation

public enum CleanupKind: String, Codable, Sendable {
    /// Worktree o carpeta de review/chat (raíz temporal de PRBar).
    case workspace
    /// Worktree de Responder en el `worktreeDir` de un repo.
    case respondWorktree
    case updaterBuild, updaterStaging
    case oldFile
}

public struct CleanupCandidate: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var kind: CleanupKind
    public var clone: String?
    public var title: String
    public var id: String { path }

    public init(path: String, bytes: Int64, kind: CleanupKind, clone: String?, title: String) {
        self.path = path
        self.bytes = bytes
        self.kind = kind
        self.clone = clone
        self.title = title
    }
}

public struct CleanupPlan: Codable, Equatable, Sendable {
    public var candidates: [CleanupCandidate]
    public var totalBytes: Int64 { candidates.map(\.bytes).reduce(0, +) }
    public var isEmpty: Bool { candidates.isEmpty }

    public init(candidates: [CleanupCandidate]) { self.candidates = candidates }
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public var removed: [String] = []
    public var freedBytes: Int64 = 0
    /// "<título>: <motivo>".
    public var skipped: [String] = []
    public var failed: [String] = []

    public init() {}
}

public enum DiskCleanup {
    /// Lo que se puede borrar: huérfanos, y caché del updater si no hay una actualización en curso (decisiones I.1.4–6).
    public static func plan(usage: DiskUsage, oldFiles: [CleanupCandidate], updateInProgress: Bool) -> CleanupPlan {
        var candidates: [CleanupCandidate] = []
        for item in usage.items {
            switch (item.kind, item.state) {
            case (.worktrees, .orphan):
                let kind: CleanupKind = WorktreeResolver.isRespondWorktreeName(item.title) ? .respondWorktree : .workspace
                candidates.append(CleanupCandidate(path: item.path, bytes: item.bytes, kind: kind, clone: item.clone, title: item.title))
            case (.updater, .cache) where !updateInProgress:
                let kind: CleanupKind = item.path.hasSuffix("/.build") ? .updaterBuild : .updaterStaging
                candidates.append(CleanupCandidate(path: item.path, bytes: item.bytes, kind: kind, clone: nil, title: item.title))
            default:
                continue
            }
        }
        return CleanupPlan(candidates: candidates + oldFiles)
    }

    /// Archivos regulares de `directories` (recursivo, sin seguir symlinks) modificados hace más de `olderThanDays`.
    /// `prbar.log` (el log en uso) nunca.
    public static func oldFiles(in directories: [URL], olderThanDays days: Int, now: Date = Date()) -> [CleanupCandidate] {
        let limit = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        var found: [CleanupCandidate] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let date = values.contentModificationDate, date < limit,
                      url.lastPathComponent != AppPaths.logFile.lastPathComponent else { continue }
                found.append(CleanupCandidate(path: url.standardizedFileURL.path, bytes: Int64(values.totalFileAllocatedSize ?? 0),
                                              kind: .oldFile, clone: nil, title: url.lastPathComponent))
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

/// Borra lo de un plan, re-verificando cada ítem justo antes (decisión I.1.12). Worktrees con el mecanismo de §8.5
/// (`WorktreeManager.cleanup` / `WorktreeResolver.cleanup`: `worktree remove --force` de ese worktree, nunca
/// `git worktree prune`). Nunca lanza.
public struct DiskCleanupExecutor: Sendable {
    let runner: ProcessRunning
    let gitPath: String
    let worktreeRoots: [URL]
    let gitEnvironment: [String: String]
    let registry: WorkspaceRegistry
    let updaterDirectories: [URL]
    let oldFileRoots: [URL]

    public init(runner: ProcessRunning, gitPath: String, worktreeRoots: [URL], gitEnvironment: [String: String] = [:],
                registry: WorkspaceRegistry = .shared,
                updaterDirectories: [URL] = [AppPaths.updateSourceDir.appendingPathComponent(".build"), AppPaths.updateStagingDir],
                oldFileRoots: [URL] = [AppPaths.historyDir, AppPaths.logFile.deletingLastPathComponent()]) {
        self.runner = runner
        self.gitPath = gitPath
        self.worktreeRoots = worktreeRoots.map(\.standardizedFileURL)
        self.gitEnvironment = gitEnvironment
        self.registry = registry
        self.updaterDirectories = updaterDirectories.map(\.standardizedFileURL)
        self.oldFileRoots = oldFileRoots.map(\.standardizedFileURL)
    }

    public func run(_ plan: CleanupPlan) async -> CleanupResult {
        var result = CleanupResult()
        for candidate in plan.candidates {
            let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
            if registry.contains(url.path) {
                result.skipped.append("\(candidate.title): in use")
                continue
            }
            switch candidate.kind {
            case .workspace:
                guard let root = worktreeRoots.first(where: { url.deletingLastPathComponent().path == $0.path }),
                      WorktreeManager.isWorkspaceName(url.lastPathComponent) else {
                    result.skipped.append("\(candidate.title): not in PRBar’s worktrees folder")
                    continue
                }
                let manager = WorktreeManager(runner: runner, gitPath: gitPath, root: root)
                let clone = DiskScanner.cloneOfWorktree(url)
                await manager.cleanup(ReviewWorkspace(directory: url, baseRef: nil, isDiffOnly: clone == nil), localPath: clone)
                if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            case .respondWorktree:
                guard WorktreeResolver.isRespondWorktreeName(url.lastPathComponent), let clone = candidate.clone else {
                    result.skipped.append("\(candidate.title): not a PRBar Respond worktree")
                    continue
                }
                if let reason = await unpushedWork(url) {
                    result.skipped.append("\(candidate.title): \(reason)")
                    continue
                }
                let resolver = WorktreeResolver(runner: runner, gitPath: gitPath, environment: gitEnvironment)
                await resolver.cleanup(ResolvedWorktree(path: url.path, origin: .dedicated, localPath: clone, ref: nil))
            case .updaterBuild, .updaterStaging:
                guard updaterDirectories.contains(where: { $0.path == url.path }) else {
                    result.skipped.append("\(candidate.title): not the updater’s folder")
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            case .oldFile:
                var info = stat()
                guard oldFileRoots.contains(where: { url.path.hasPrefix($0.path + "/") }),
                      url.lastPathComponent != AppPaths.logFile.lastPathComponent,
                      lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    result.skipped.append("\(candidate.title): not an old history or log file")
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                result.failed.append(candidate.title)
            } else {
                result.removed.append(candidate.path)
                result.freedBytes += candidate.bytes
            }
        }
        return result
    }

    /// `nil` si se puede borrar; si no, el motivo. Cambios sin commitear, o commits que no están en ninguna rama,
    /// remoto, tag ni `refs/prbar/*` (decisión I.1.4). Si git falla, no se borra.
    func unpushedWork(_ worktree: URL) async -> String? {
        func git(_ arguments: [String]) async -> String? {
            let result = try? await runner.run(gitPath, ["-C", worktree.path] + GitHardening.arguments + arguments,
                                               environment: gitEnvironment.merging(GitHardening.environment) { a, _ in a },
                                               currentDirectory: nil, timeout: ProcessTimeouts.standard)
            guard let result, result.status == 0 else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let status = await git(["status", GitHardening.ignoreSubmodules, "--porcelain", "--untracked-files=all"]) else {
            return "couldn’t check it with git"
        }
        if !status.isEmpty { return "has uncommitted changes" }
        guard let count = await git(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags", "--glob=refs/prbar/*"]),
              let commits = Int(count) else { return "couldn’t check it with git" }
        return commits == 0 ? nil : "has \(commits) unpushed commit\(commits == 1 ? "" : "s")"
    }
}
