import Foundation
import PRBarCore

// MARK: - Fix CI (spec K)

extension AppModel {
    /// A PR of mine whose CI failed: the row offers "Fix CI" (manual only, never automatic).
    func isCIFixCandidate(_ item: ClassifiedPR) -> Bool {
        PopoverTabs.isMine(item) && item.pr.ciState == .failure
    }

    /// Why "Fix CI" can't start now; nil = it can. It shares the PR's Respond slot (spec K.6.1).
    func ciFixUnavailableReason(_ item: ClassifiedPR) -> String? {
        if let reason = respondUnavailableReason(item) {
            return reason.replacingOccurrences(of: "to respond with Claude", with: "to fix the CI with Claude")
        }
        let prID = item.id
        if respond.phases[prID]?.isActive == true || respond.runningTests.contains(prID) {
            return "\(prID) is already being worked on: wait or cancel it."
        }
        if case .readyToPush? = respond.phases[prID] {
            return "\(prID) has changes that weren’t pushed: push or dismiss them first."
        }
        if case .failed? = respond.phases[prID], respond.records[prID]?.result != nil {
            return "\(prID) has changes that weren’t pushed: open it to retry or dismiss it."
        }
        return nil
    }

    /// "Fix CI": reads the failing checks and their logs on this Mac, prepares the worktree (here or on the repo's host)
    /// and Claude fixes the code. Replaces a finished Respond or Fix CI of the PR.
    func startCIFix(_ item: ClassifiedPR) {
        guard ciFixUnavailableReason(item) == nil else { return }
        let worktreeDir = repoConfig(account: item.account, repo: item.pr.repo)?.worktreeDir
        respond.analyze(item, localPath: localPath(for: item), worktreeDir: worktreeDir, mode: .ciFix)
    }

    /// The Respond window's title for the PR's run.
    func respondWindowTitle(_ draft: RespondDraft) -> String {
        "\(draft.isCIFix ? "Fix CI" : "Respond") · \(draft.repo.name)#\(draft.number)"
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
