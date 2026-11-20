import Foundation
import os

public enum DiskCategoryKind: String, Codable, CaseIterable, Sendable {
    case worktrees, updater, history, logs, appData

    public var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .updater: "Updater"
        case .history: "History"
        case .logs: "Logs"
        case .appData: "App data"
        }
    }
}

public enum DiskItemState: String, Codable, Sendable {
    /// Un worktree o carpeta de una corrida en curso (o de un draft que la app tiene).
    case active
    /// Con nombre de PRBar y sin corrida: Clean Up lo puede borrar.
    case orphan
    /// Reconstruible (staging y builds del updater).
    case cache
    /// Datos (historial, logs, config): solo se borra lo viejo, a pedido.
    case data
}

public struct DiskItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var kind: DiskCategoryKind
    public var state: DiskItemState
    public var repo: String?
    /// El clone del usuario al que pertenece el worktree (para sacarlo con git).
    public var clone: String?
    public var title: String

    public var id: String { path }
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var items: [DiskItem]
    public var scannedAt: Date

    public var total: Int64 { items.map(\.bytes).reduce(0, +) }
    public func bytes(_ kind: DiskCategoryKind) -> Int64 { items.filter { $0.kind == kind }.map(\.bytes).reduce(0, +) }
    /// Worktrees por repo ("Other" sin repo conocido).
    public var worktreesByRepo: [(repo: String, bytes: Int64)] {
        Dictionary(grouping: items.filter { $0.kind == .worktrees }, by: { $0.repo ?? "Other" })
            .map { ($0.key, $0.value.map(\.bytes).reduce(0, +)) }
            .sorted { $0.bytes > $1.bytes }
    }
}

public struct DiskScanInput: Sendable {
    public struct RespondDir: Sendable {
        public var repo: String
        public var path: String
        public var localPath: String?
        public init(repo: String, path: String, localPath: String?) {
            self.repo = repo
            self.path = path
            self.localPath = localPath
        }
    }

    public var appSupport: URL
    /// `$TMPDIR/PRBar/worktrees` y la raíz vieja de `~/Library/Caches`.
    public var worktreeRoots: [URL]
    public var logsDir: URL
    public var respondDirs: [RespondDir]
    /// `WorkspaceRegistry` + los worktrees de los drafts de Responder que tiene la app.
    public var activePaths: Set<String>
    /// clone → `owner/repo`, para poner el repo en los worktrees de la raíz temporal.
    public var repoByClone: [String: String]
    public var now: Date

    public init(appSupport: URL, worktreeRoots: [URL], logsDir: URL, respondDirs: [RespondDir], activePaths: Set<String>,
                repoByClone: [String: String] = [:], now: Date = Date()) {
        self.appSupport = appSupport
        self.worktreeRoots = worktreeRoots
        self.logsDir = logsDir
        self.respondDirs = respondDirs
        self.activePaths = activePaths
        self.repoByClone = repoByClone
        self.now = now
    }

    public static func live(respondDirs: [RespondDir], activePaths: Set<String>, repoByClone: [String: String]) -> DiskScanInput {
        DiskScanInput(appSupport: AppPaths.appSupport, worktreeRoots: [AppPaths.worktreesDir, AppPaths.legacyWorktreesDir],
                      logsDir: AppPaths.logFile.deletingLastPathComponent(), respondDirs: respondDirs,
                      activePaths: activePaths, repoByClone: repoByClone)
    }
}

public enum DiskScanner {
    /// Margen para una corrida que está arrancando (decisión I.1.3).
    public static let freshInterval: TimeInterval = 5 * 60

    /// Bytes asignados de `url` y todo lo de adentro, sin seguir symlinks.
    public static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        func size(_ item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total = size(url)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return total
        }
        for case let item as URL in enumerator { total += size(item) }
        return total
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// El clone de un worktree, del archivo `.git` (`gitdir: <clone>/.git/worktrees/<nombre>`). Lee a lo sumo 4 KB y
    /// solo si `.git` es un archivo regular (no sigue symlinks).
    public static func cloneOfWorktree(_ directory: URL) -> String? {
        let dotGit = directory.appendingPathComponent(".git")
        var info = stat()
        guard lstat(dotGit.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096,
              let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
        let gitdir = String(line.dropFirst("gitdir: ".count))
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }

    public static func scan(_ input: DiskScanInput) -> DiskUsage {
        var items: [DiskItem] = []
        let files = FileManager.default
        let active = Set(input.activePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        func state(_ url: URL) -> DiskItemState {
            if active.contains(url.standardizedFileURL.path) { return .active }
            if let date = modified(url), input.now.timeIntervalSince(date) < freshInterval { return .active }
            return .orphan
        }

        // Worktrees y carpetas de contexto de review/chat (raíz temporal).
        for root in input.worktreeRoots {
            for entry in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let name = entry.lastPathComponent
                guard WorktreeManager.isWorkspaceName(name) else { continue }
                let clone = cloneOfWorktree(entry)
                items.append(DiskItem(path: entry.standardizedFileURL.path, bytes: allocatedSize(entry), kind: .worktrees,
                                      state: state(entry), repo: clone.flatMap { input.repoByClone[$0] }, clone: clone, title: name))
            }
        }
        // Worktrees de Responder (solo los que tienen nombre de PRBar).
        for dir in input.respondDirs {
            let url = URL(fileURLWithPath: dir.path)
            for entry in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            where WorktreeResolver.isRespondWorktreeName(entry.lastPathComponent) {
                items.append(DiskItem(path: entry.standardizedFileURL.path, bytes: allocatedSize(entry), kind: .worktrees,
                                      state: state(entry), repo: dir.repo, clone: dir.localPath, title: entry.lastPathComponent))
            }
        }
        // Application Support.
        let support = input.appSupport
        let source = support.appendingPathComponent("source")
        let build = source.appendingPathComponent(".build")
        let staging = support.appendingPathComponent("update-staging")
        let history = support.appendingPathComponent("history")
        let buildBytes = allocatedSize(build)
        if buildBytes > 0 {
            items.append(DiskItem(path: build.standardizedFileURL.path, bytes: buildBytes, kind: .updater, state: .cache, title: "Updater builds"))
        }
        let sourceBytes = allocatedSize(source) - buildBytes
        if sourceBytes > 0 {
            items.append(DiskItem(path: source.standardizedFileURL.path, bytes: sourceBytes, kind: .updater, state: .data, title: "Updater clone"))
        }
        let stagingBytes = allocatedSize(staging)
        if stagingBytes > 0 {
            items.append(DiskItem(path: staging.standardizedFileURL.path, bytes: stagingBytes, kind: .updater, state: .cache, title: "Update staging"))
        }
        let historyBytes = allocatedSize(history)
        if historyBytes > 0 {
            items.append(DiskItem(path: history.standardizedFileURL.path, bytes: historyBytes, kind: .history, state: .data, title: "History"))
        }
        let rest = allocatedSize(support) - allocatedSize(source) - stagingBytes - historyBytes
        if rest > 0 {
            items.append(DiskItem(path: support.standardizedFileURL.path, bytes: rest, kind: .appData, state: .data, title: "Settings and state"))
        }
        let logBytes = allocatedSize(input.logsDir)
        if logBytes > 0 {
            items.append(DiskItem(path: input.logsDir.standardizedFileURL.path, bytes: logBytes, kind: .logs, state: .data, title: "Logs"))
        }
        return DiskUsage(items: items, scannedAt: input.now)
    }
}

/// Las carpetas de worktrees y de contexto que tiene una corrida en curso (spec I: Clean Up nunca las toca). Las
/// anotan `WorktreeManager.prepare`/`WorktreeResolver.prepare` antes de crearlas y las borran sus `cleanup`.
public final class WorkspaceRegistry: Sendable {
    public static let shared = WorkspaceRegistry()

    private let paths = OSAllocatedUnfairLock(initialState: Set<String>())

    public init() {}

    private static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    public func insert(_ path: String) { _ = paths.withLock { $0.insert(Self.key(path)) } }
    public func remove(_ path: String) { _ = paths.withLock { $0.remove(Self.key(path)) } }
    public func contains(_ path: String) -> Bool { paths.withLock { $0.contains(Self.key(path)) } }
    public func all() -> Set<String> { paths.withLock { $0 } }
}
