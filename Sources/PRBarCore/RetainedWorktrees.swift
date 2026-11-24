import Foundation

/// Where a kept folder lives and what removes it (spec T.3).
public struct WorktreeLocation: Codable, Equatable, Hashable, Sendable {
    /// The folder, on the machine where it is.
    public var directory: String
    /// `nil` = this Mac; otherwise the runner's name.
    public var runner: String?
    /// The repo the worktree hangs from: the user's clone on this Mac or PRBar's bare mirror on the runner. Nil for a
    /// diff-only review folder (not a git worktree).
    public var repository: String?
    /// PRBar's own refs of that run (`refs/prbar/…`), deleted with the folder.
    public var refs: [String]

    public init(directory: String, runner: String?, repository: String?, refs: [String]) {
        self.directory = directory
        self.runner = runner
        self.repository = repository
        self.refs = refs
    }
}

extension WorktreeLocation {
    /// The review workspace `WorktreeManager.cleanup` / `RemoteWorkspaces.cleanup` remove.
    public var reviewWorkspace: ReviewWorkspace {
        ReviewWorkspace(directory: URL(fileURLWithPath: directory, isDirectory: true),
                        baseRef: refs.first { $0.hasPrefix("refs/prbar/base-") },
                        prRef: refs.first { $0.hasPrefix("refs/prbar/pr-") },
                        isDiffOnly: repository == nil)
    }

    /// The Respond worktree `WorktreeResolver.cleanup` / `RemoteWorkspaces.cleanupRespond` remove.
    public var respondWorktree: ResolvedWorktree {
        ResolvedWorktree(path: directory, origin: .dedicated, localPath: repository, ref: refs.first)
    }
}

/// A folder PRBar keeps after a review or pushed fixes so its Claude sessions can be resumed (spec T.3).
public struct RetainedWorktree: Codable, Equatable, Hashable, Sendable {
    /// Respond and Fix CI share the branch's folder: one `respond` folder per PR.
    public enum Job: String, Codable, Sendable { case review, respond }

    public var prID: String
    public var account: String
    public var repo: RepoRef
    public var number: Int
    public var job: Job
    /// The History record whose sessions ran here.
    public var recordID: UUID
    public var location: WorktreeLocation
    /// That record's sessions (spec T.1): what "Terminal" offers, without reading History on every render.
    public var sessions: [ClaudeSessionRef]
    public var retainedAt: Date
    /// A newer job replaced it but a process had its cwd inside (spec T.3.2): not offered, left for Clean Up.
    public var superseded: Bool

    public init(prID: String, account: String, repo: RepoRef, number: Int, job: Job, recordID: UUID,
                location: WorktreeLocation, sessions: [ClaudeSessionRef], retainedAt: Date, superseded: Bool = false) {
        self.prID = prID
        self.account = account
        self.repo = repo
        self.number = number
        self.job = job
        self.recordID = recordID
        self.location = location
        self.sessions = sessions
        self.retainedAt = retainedAt
        self.superseded = superseded
    }
}

/// `retained-worktrees.json` in Application Support: survives restarting PRBar.
public struct RetainedWorktreeStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AppPaths.retainedWorktreesFile) {
        self.fileURL = fileURL
    }

    /// Empty if the file doesn't exist. Entry by entry: one that can't be decoded (e.g. written by a newer PRBar) is
    /// skipped and logged, and the file is copied aside first (the next `save` would drop it). A file that can't be
    /// read at all is moved aside to `retained-worktrees.json.corrupt-<date>` instead of being overwritten later.
    public func load() -> [RetainedWorktree] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let entries: [Lossy]
        do {
            entries = try JSONCoding.decoder.decode([Lossy].self, from: Data(contentsOf: fileURL))
        } catch {
            AppLog.write("Retained worktrees: couldn't read \(fileURL.lastPathComponent): \(error)")
            setAside(move: true)
            return []
        }
        let decoded = entries.compactMap(\.value)
        if decoded.count < entries.count {
            AppLog.write("Retained worktrees: skipped \(entries.count - decoded.count) entr\(entries.count - decoded.count == 1 ? "y" : "ies") of \(fileURL.lastPathComponent) that couldn't be read.")
            setAside(move: false)
        }
        return decoded
    }

    /// One entry of the file: `nil` if it can't be decoded.
    private struct Lossy: Decodable {
        let value: RetainedWorktree?
        init(from decoder: Decoder) throws {
            value = try? RetainedWorktree(from: decoder)
        }
    }

    /// Moves (or copies) the file to `<name>.corrupt-<yyyyMMdd-HHmmss>` next to it. Logs failures.
    private func setAside(move: Bool) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))")
        do {
            if move {
                try FileManager.default.moveItem(at: fileURL, to: target)
            } else {
                try FileManager.default.copyItem(at: fileURL, to: target)
            }
            AppLog.write("Retained worktrees: kept the unreadable file as \(target.lastPathComponent).")
        } catch {
            AppLog.write("Retained worktrees: couldn't set \(fileURL.lastPathComponent) aside: \(error.localizedDescription)")
        }
    }

    public func save(_ entries: [RetainedWorktree]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}

/// The retention rules (spec T.3), without side effects.
public enum RetainedWorktreeRules {
    /// How often PRBar asks GitHub whether a PR that left the list was merged or closed.
    public static let stateCheckInterval: TimeInterval = 3600

    /// `entry` becomes the kept folder of its (PR, job); the previous ones of that pair come back to be removed. They
    /// also stay in `entries`, `superseded` (not offered, still protected from the orphan cleanups), until they are
    /// really gone (`AppModel.forgetRetained`): quitting before their removal mustn't turn them into orphans.
    public static func retain(_ entry: RetainedWorktree, in entries: [RetainedWorktree])
        -> (entries: [RetainedWorktree], replaced: [RetainedWorktree]) {
        let isSamePair: (RetainedWorktree) -> Bool = { $0.prID == entry.prID && $0.job == entry.job }
        // Another folder: a different path, or the same path on another machine.
        let isOtherFolder: (RetainedWorktree) -> Bool = {
            $0.location.directory != entry.location.directory || $0.location.runner != entry.location.runner
        }
        let replaced = entries.filter { isSamePair($0) && isOtherFolder($0) }.map { old in
            var old = old
            old.superseded = true
            return old
        }
        let kept = entries.filter { !isSamePair($0) }
        return (kept + replaced + [entry], replaced)
    }

    /// The entries whose PR isn't in the list any more, whose repo was fetched fine in this refresh and that weren't
    /// asked about in the last `stateCheckInterval`: GitHub has to say whether they were merged or closed.
    public static func needsStateCheck(_ entries: [RetainedWorktree], listed: Set<String>, fetchedScopes: Set<String>,
                                       checkedAt: [String: Date], now: Date) -> [RetainedWorktree] {
        entries.filter { entry in
            guard !listed.contains(entry.prID),
                  fetchedScopes.contains(Snapshot.scope(account: entry.account, repo: entry.repo)) else { return false }
            guard let last = checkedAt[entry.prID] else { return true }
            return now.timeIntervalSince(last) >= stateCheckInterval
        }
    }

    /// The entries of merged or closed PRs (spec T.3.1). An unknown state keeps the folder.
    public static func closedOnes(_ entries: [RetainedWorktree], states: [String: PRDetails.State]) -> [RetainedWorktree] {
        entries.filter { [.merged, .closed].contains(states[$0.prID]) }
    }
}

/// Which processes have their working directory inside a folder (`lsof -d cwd -Fn`, spec T.3.2).
public enum ProcessCwd {
    public static let lsofPath = "/usr/sbin/lsof"
    public static let lsofArguments = ["-n", "-P", "-w", "-d", "cwd", "-Fn"]
    /// The line `remoteScript` prints before `lsof`'s output with each folder's real path (`pwd -P`).
    static let resolvedPrefix = "prbar-resolved "

    /// On a runner: exit 97 when there is no `lsof` (then the folder counts as busy). First prints each folder's real
    /// path (`prbar-resolved <path>`, one line per folder in order, empty if it's gone): `lsof` shows resolved paths,
    /// and the runner's root may sit under a symlink. Read its output with `anyInside(_:remoteOutput:)` or
    /// `busyDirectories(_:remoteOutput:)`.
    public static func remoteScript(resolving directories: [String]) throws -> String {
        var lines = ["command -v lsof >/dev/null 2>&1 || exit 97"]
        for directory in directories {
            let quoted = try ShellQuote.posix(directory)
            lines.append("r=$(cd -P -- \(quoted) 2>/dev/null && pwd -P); printf 'prbar-resolved %s\\n' \"$r\"")
        }
        lines += ["lsof -n -P -w -d cwd -Fn 2>/dev/null", "exit 0"]
        return lines.joined(separator: "\n")
    }

    /// Some `n<path>` line of the output is one of `directories` or inside one of them.
    public static func anyInside(_ directories: [String], lsofOutput: String) -> Bool {
        let roots = directories.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
        return lsofOutput.split(whereSeparator: \.isNewline).contains { line in
            guard line.hasPrefix("n") else { return false }
            let path = String(line.dropFirst())
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    /// `anyInside` for the output of `remoteScript`: also with the real paths it printed.
    public static func anyInside(_ directories: [String], remoteOutput: String) -> Bool {
        let resolved = remoteOutput.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix(resolvedPrefix) }
            .map { String($0.dropFirst(resolvedPrefix.count)) }
        return anyInside(directories + resolved, lsofOutput: remoteOutput)
    }

    /// Which of `directories` (the ones given to `remoteScript`, same order) have a process inside. If the resolved
    /// lines don't match them one to one (a path with a newline, a truncated output), all count as busy.
    public static func busyDirectories(_ directories: [String], remoteOutput: String) -> Set<String> {
        let resolved = remoteOutput.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix(resolvedPrefix) }
            .map { String($0.dropFirst(resolvedPrefix.count)) }
        guard resolved.count == directories.count else { return Set(directories) }
        return Set(zip(directories, resolved).filter { directory, real in
            anyInside([directory, real], lsofOutput: remoteOutput)
        }.map(\.0))
    }
}

/// Removes kept folders unless a process has its cwd inside or they hold work that isn't pushed (uncommitted changes
/// or commits on no branch, remote, tag or `refs/prbar/*`): those come back marked `superseded`, left for Clean Up
/// (which skips them while the work is there, and says so).
public struct RetainedWorktreeCleaner: Sendable {
    let isBusy: @Sendable (WorktreeLocation) async -> Bool
    /// `nil` if the folder can go; otherwise why not (e.g. "has uncommitted changes"). A folder that isn't a git
    /// worktree (`repository == nil`, diff only) has nothing to lose: `nil`.
    let unpushedWork: @Sendable (WorktreeLocation) async -> String?
    /// Removes it; `true` if the folder is gone afterwards (checked on disk, not assumed).
    let remove: @Sendable (RetainedWorktree) async -> Bool

    public init(isBusy: @escaping @Sendable (WorktreeLocation) async -> Bool,
                unpushedWork: @escaping @Sendable (WorktreeLocation) async -> String?,
                remove: @escaping @Sendable (RetainedWorktree) async -> Bool) {
        self.isBusy = isBusy
        self.unpushedWork = unpushedWork
        self.remove = remove
    }

    /// Returns the ones left on disk, with `superseded` set (also those whose removal failed: retried at launch).
    public func removeUnlessBusy(_ entries: [RetainedWorktree]) async -> [RetainedWorktree] {
        var left: [RetainedWorktree] = []
        for entry in entries {
            var reason: String?
            if await isBusy(entry.location) {
                reason = "has a process working in it"
            } else {
                reason = await unpushedWork(entry.location)
            }
            if reason == nil, await !remove(entry) { reason = "couldn’t be removed" }
            if let reason {
                var kept = entry
                kept.superseded = true
                left.append(kept)
                AppLog.write("Retained worktree: \(entry.location.directory) \(reason); left for Clean Up.")
            }
        }
        return left
    }
}
