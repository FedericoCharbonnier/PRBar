import Foundation
import os

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

    /// Una sola pasada por `root` (sin seguir symlinks): los bytes de cada `bucket` (rutas relativas a `root`; si
    /// se anidan, cada archivo va al más profundo) y el resto, con `root` mismo.
    public static func allocatedSizes(_ root: URL, buckets: [String]) -> (buckets: [String: Int64], rest: Int64) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func size(_ item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var totals = Dictionary(uniqueKeysWithValues: buckets.map { ($0, Int64(0)) })
        var rest = size(root)
        guard CanonicalPath.isDirectory(root.path),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            return (totals, rest)
        }
        let prefix = root.standardizedFileURL.path + "/"
        // El más profundo primero.
        let ordered = buckets.sorted { $0.count > $1.count }
        for case let item as URL in enumerator {
            let path = item.standardizedFileURL.path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
            let bytes = size(item)
            if let relative, let bucket = ordered.first(where: { relative == $0 || relative.hasPrefix($0 + "/") }) {
                totals[bucket, default: 0] += bytes
            } else {
                rest += bytes
            }
        }
        return (totals, rest)
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
        let active = Set(input.activePaths.map(CanonicalPath.of))
        let activeIdentities = Set(input.activePaths.compactMap(CanonicalPath.identity))
        // El clone sale de la configuración: el `.git` del worktree solo dice cuál de los configurados es.
        let configuredClones = Dictionary(input.repoByClone.map { (CanonicalPath.of($0.key), (clone: $0.key, repo: $0.value)) },
                                          uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()

        func state(_ path: String) -> DiskItemState {
            if active.contains(path) { return .active }
            if let identity = CanonicalPath.identity(path), activeIdentities.contains(identity) { return .active }
            if let date = modified(URL(fileURLWithPath: path)), input.now.timeIntervalSince(date) < freshInterval { return .active }
            return .orphan
        }

        /// Las carpetas de verdad (nunca symlinks) de `directory` cuyo nombre acepta `isOwn`, con su ruta canónica y sin
        /// repetir (dos repos pueden compartir `worktreeDir`).
        func entries(of directory: String, _ isOwn: (String) -> Bool) -> [(path: String, name: String)] {
            guard let real = CanonicalPath.realPath(directory) else { return [] }
            return ((try? files.contentsOfDirectory(atPath: real)) ?? []).sorted().compactMap { name in
                let path = (real as NSString).appendingPathComponent(name)
                guard isOwn(name), CanonicalPath.isDirectory(path), seen.insert(path).inserted else { return nil }
                return (path, name)
            }
        }

        // Worktrees y carpetas de contexto de review/chat (raíz temporal).
        for root in input.worktreeRoots {
            for entry in entries(of: root.path, WorktreeManager.isWorkspaceName) {
                let url = URL(fileURLWithPath: entry.path)
                let configured = cloneOfWorktree(url).flatMap { configuredClones[CanonicalPath.of($0)] }
                items.append(DiskItem(path: entry.path, bytes: allocatedSize(url), kind: .worktrees, state: state(entry.path),
                                      repo: configured?.repo, clone: configured?.clone, title: entry.name))
            }
        }
        // Worktrees de Responder (solo los que tienen nombre de PRBar).
        for dir in input.respondDirs {
            for entry in entries(of: dir.path, WorktreeResolver.isRespondWorktreeName) {
                items.append(DiskItem(path: entry.path, bytes: allocatedSize(URL(fileURLWithPath: entry.path)), kind: .worktrees,
                                      state: state(entry.path), repo: dir.repo, clone: dir.localPath, title: entry.name))
            }
        }
        // Application Support.
        let support = input.appSupport
        let source = support.appendingPathComponent("source")
        let build = source.appendingPathComponent(".build")
        let staging = support.appendingPathComponent("update-staging")
        let history = support.appendingPathComponent("history")
        // Una sola pasada por Application Support (`.build` puede tener cientos de miles de archivos).
        let sizes = allocatedSizes(support, buckets: ["source/.build", "source", "update-staging", "history"])
        let buildBytes = sizes.buckets["source/.build"] ?? 0
        if buildBytes > 0 {
            items.append(DiskItem(path: CanonicalPath.of(build.path), bytes: buildBytes, kind: .updater, state: .cache, title: "Updater builds"))
        }
        let sourceBytes = sizes.buckets["source"] ?? 0
        if sourceBytes > 0 {
            items.append(DiskItem(path: CanonicalPath.of(source.path), bytes: sourceBytes, kind: .updater, state: .data, title: "Updater clone"))
        }
        let stagingBytes = sizes.buckets["update-staging"] ?? 0
        if stagingBytes > 0 {
            items.append(DiskItem(path: CanonicalPath.of(staging.path), bytes: stagingBytes, kind: .updater, state: .cache, title: "Update staging"))
        }
        let historyBytes = sizes.buckets["history"] ?? 0
        if historyBytes > 0 {
            items.append(DiskItem(path: CanonicalPath.of(history.path), bytes: historyBytes, kind: .history, state: .data, title: "History"))
        }
        let rest = sizes.rest
        if rest > 0 {
            items.append(DiskItem(path: CanonicalPath.of(support.path), bytes: rest, kind: .appData, state: .data, title: "Settings and state"))
        }
        let logBytes = allocatedSize(input.logsDir)
        if logBytes > 0 {
            items.append(DiskItem(path: CanonicalPath.of(input.logsDir.path), bytes: logBytes, kind: .logs, state: .data, title: "Logs"))
        }
        return DiskUsage(items: items, scannedAt: input.now)
    }
}

/// Las carpetas de worktrees y de contexto que tiene una corrida en curso (spec I: Clean Up nunca las toca). Las
/// anotan `WorktreeManager.prepare`/`WorktreeResolver.prepare` antes de crearlas y las borran sus `cleanup`.
/// Guarda la clave canónica (`CanonicalPath.of`, calculada al anotar, cuando la carpeta que la contiene ya existe) y
/// `contains` además compara por inodo: se la reconoce por un symlink, con otras mayúsculas o por `/private/var`.
public final class WorkspaceRegistry: Sendable {
    public static let shared = WorkspaceRegistry()

    /// Ruta estandarizada con la que se anotó → clave canónica.
    private let paths = OSAllocatedUnfairLock(initialState: [String: String]())

    public init() {}

    private static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    public func insert(_ path: String) {
        let key = CanonicalPath.of(path)
        paths.withLock { $0[Self.standardized(path)] = key }
    }

    public func remove(_ path: String) {
        let raw = Self.standardized(path)
        let key = CanonicalPath.of(path)
        paths.withLock { $0 = $0.filter { $0.key != raw && $0.value != key } }
    }

    public func contains(_ path: String) -> Bool {
        let key = CanonicalPath.of(path)
        let registered = all()
        if registered.contains(key) { return true }
        guard let identity = CanonicalPath.identity(path) else { return false }
        return registered.contains { CanonicalPath.identity($0) == identity }
    }

    /// Las claves canónicas.
    public func all() -> Set<String> { paths.withLock { Set($0.values) } }
}
