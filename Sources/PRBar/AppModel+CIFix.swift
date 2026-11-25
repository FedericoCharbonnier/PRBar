import Foundation
import PRBarCore

// MARK: - Fix CI (spec K)

extension AppModel {
    /// A PR of mine whose CI failed: the row offers "Fix CI" (manual only, never automatic).
    func isCIFixCandidate(_ item: ClassifiedPR) -> Bool {
        PopoverTabs.isMine(item) && item.pr.ciState == .failure
    }

    /// Why "Fix CI" can't start now; nil = it can. It shares the PR's Respond slot (spec K.6.1).
    /// `ignoringUnpushed`: "Fix CI Again" in the window, which asks before discarding that work.
    func ciFixUnavailableReason(_ item: ClassifiedPR, ignoringUnpushed: Bool = false) -> String? {
        if let reason = respondUnavailableReason(item) {
            return reason.replacingOccurrences(of: "to respond with Claude", with: "to fix the CI with Claude")
        }
        let prID = item.id
        if let reason = respondSlotConflictReason(prID, starting: .ciFix) { return reason }
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

    /// Spec K.2.1: a Respond and a Fix CI share the PR's slot; neither replaces an open run (any phase but done) of the
    /// other kind, so the user's decisions or unpushed fix are never lost without a word.
    func respondSlotConflictReason(_ prID: String, starting mode: RespondMode) -> String? {
        switch respond.openRunConflict(prID: prID, starting: mode) {
        case .feedback?: "\(prID) has a Respond run open: finish or dismiss it before fixing the CI."
        case .ciFix?: "\(prID) has a Fix CI run open: finish or dismiss it before responding."
        case .conflicts?: "\(prID) has a Resolve Conflicts run open: finish or dismiss it first."
        case nil: nil
        }
    }

    /// "Fix CI": reads the failing checks and their logs on this Mac, prepares the worktree (here or on the repo's host)
    /// and Claude fixes the code. Replaces a finished Respond or Fix CI of the PR.
    func startCIFix(_ item: ClassifiedPR) {
        guard ciFixUnavailableReason(item) == nil else { return }
        let worktreeDir = repoConfig(account: item.account, repo: item.pr.repo)?.worktreeDir
        let previous = respond.records[item.id]?.draft
        // La corrida anterior se reemplaza: su chat se va con su worktree (M5).
        if respond.analyze(item, localPath: localPath(for: item), worktreeDir: worktreeDir, mode: .ciFix), let previous {
            discardChat(draftID: previous.id)
        }
    }
}

// MARK: - Claude usage (spec O)

extension AppModel {
    /// What a running task's finished Claude runs cost so far (Activity's Cost column). The snapshot mode fills
    /// `snapshotLiveUsage`.
    func liveClaudeUsage(_ activity: ProcessActivity) -> ClaudeUsage? {
        snapshotLiveUsage[activity] ?? ClaudeUsageCenter.shared.liveUsage(for: activity)
    }
}
