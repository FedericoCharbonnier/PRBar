import Foundation
import PRBarCore

// MARK: - Resolve Conflicts (spec C)

extension AppModel {
    /// A PR of mine that GitHub says conflicts with its base (spec C.2): the row offers "Resolve Conflicts". Drafts too.
    func isConflictsCandidate(_ item: ClassifiedPR) -> Bool {
        PopoverTabs.isMine(item) && item.pr.merge.hasConflicts
    }

    /// Why "Resolve Conflicts" can't start now; nil = it can. It shares the PR's Respond slot (spec C.2).
    /// `ignoringUnpushed`: "Resolve Conflicts Again" in the window, which asks before discarding that work.
    func conflictsUnavailableReason(_ item: ClassifiedPR, ignoringUnpushed: Bool = false) -> String? {
        if let reason = respondUnavailableReason(item) {
            return reason.replacingOccurrences(of: "to respond with Claude", with: "to resolve the conflicts with Claude")
        }
        let prID = item.id
        if let reason = respondSlotConflictReason(prID, starting: .conflicts) { return reason }
        if respond.phases[prID]?.isActive == true || respond.runningTests.contains(prID) {
            return "\(prID) is already being worked on: wait or cancel it."
        }
        if case .readyToPush? = respond.phases[prID] {
            return "\(prID) has changes that weren’t pushed: push or dismiss them first."
        }
        if case .failed? = respond.phases[prID], respond.unpushedWork.contains(prID), !ignoringUnpushed {
            return "\(prID) has changes that weren’t pushed: open it to retry or dismiss it."
        }
        return nil
    }

    /// "Resolve Conflicts": merges the base in PRBar's worktree (here or on the repo's host) and Claude resolves the
    /// conflicts. Replaces a finished run of the PR.
    func startConflicts(_ item: ClassifiedPR) {
        guard conflictsUnavailableReason(item) == nil else { return }
        let worktreeDir = repoConfig(account: item.account, repo: item.pr.repo)?.worktreeDir
        let previous = respond.records[item.id]?.draft
        if respond.analyze(item, localPath: localPath(for: item), worktreeDir: worktreeDir, mode: .conflicts), let previous {
            discardChat(draftID: previous.id)
        }
    }

    /// The mode the PR's Respond tab shows (decisión C.9.8, `PRTabs.respondMode`): the running run's, or Resolve
    /// Conflicts for a PR of mine with conflicts and no feedback (its "Start Resolve Conflicts" view), else feedback.
    func respondTabMode(_ prID: String) -> RespondMode {
        let running = respond.phases[prID] == nil ? nil : respond.mode(of: prID)
        guard let context = tabContext(prID: prID) else { return running == .conflicts ? .conflicts : .feedback }
        return PRTabs.respondMode(context, running: running)
    }

    /// "Resolve Conflicts" from a row, a menu or the Merge tab: starts it and opens the Respond tab only if a run
    /// actually started (it may have been refused).
    func startConflictsAndOpen(_ item: ClassifiedPR) {
        startConflicts(item)
        if respond.phases[item.id] != nil { navigate(to: .pr(prID: item.id, tab: .respond)) }
    }

    /// Spec C.6 / C.9.10: a finished Resolve Conflicts goes back to idle when the PR has conflicts again.
    func dropConflictRunsWithNewConflicts(_ snapshot: Snapshot) {
        var conflicting = Set<String>()
        var heads: [String: String] = [:]
        for item in snapshot.items where PopoverTabs.isMine(item) {
            heads[item.id] = item.pr.headOid
            if item.pr.merge.hasConflicts { conflicting.insert(item.id) }
        }
        for prID in respond.conflictRunsToDrop(conflicting: conflicting, heads: heads) { dismissRespond(prID: prID) }
    }
}

extension AppModel: ConflictsActions {
    func conflictsList() throws -> [ConflictsListEntry] {
        let items = (prStore.snapshot?.items ?? []).filter {
            isConflictsCandidate($0) || respond.mode(of: $0.id) == .conflicts && respond.phases[$0.id] != nil
        }
        return items.sorted { $0.id < $1.id }.map { item in
            let mode = respond.mode(of: item.id)
            let busy = respond.phases[item.id] != nil
            let phase = respond.runningTests.contains(item.id) ? "testing" : respond.phases[item.id]?.cliName
            return ConflictsListEntry(pr: item.id, title: item.pr.title, url: item.pr.url, account: item.account,
                                      baseRef: item.pr.baseRef, phase: mode == .conflicts ? phase : nil,
                                      otherRun: busy && mode != .conflicts ? mode : nil,
                                      unavailableReason: conflictsUnavailableReason(item))
        }
    }

    func conflictsResolve(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let item = try classifiedPR(id)
        guard PopoverTabs.isMine(item) else {
            throw CommandFailure(.invalidState, "\(id) isn’t your PR: Resolve Conflicts is only for your own PRs.")
        }
        // Uno que quedó en `ready` (no pudo arrancar solo): arranca sin volver a mergear (como Fix CI, L12).
        if case .ready(let draft)? = respond.phases[id], draft.isConflicts {
            if let jobsBlockedReason { throw CommandFailure(.invalidState, jobsBlockedReason) }
            guard respond.implementCI(prID: id) else {
                throw CommandFailure(.invalidState, "Couldn’t start Resolve Conflicts for \(id): something else is running on it. Try again in a moment.")
            }
            guard wait else { return respondInfo(id) }
            try await waitForRespond(id, events: events)
            return respondInfo(id)
        }
        let hasRun = respond.mode(of: id) == .conflicts && respond.phases[id] != nil
        guard item.pr.merge.hasConflicts || hasRun else {
            throw CommandFailure(.invalidState, "\(id) has no conflicts with its base (as of the last refresh). Run `prbar refresh` if it just got them.")
        }
        if let reason = respondSlotConflictReason(id, starting: .conflicts) {
            throw CommandFailure(.invalidState, "\(reason) (`prbar respond dismiss \(id)`)")
        }
        if let reason = conflictsUnavailableReason(item) { throw CommandFailure(.invalidState, reason) }
        startConflicts(item)
        try throwIfNothingStarted(id, "Resolve Conflicts")
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }
}
