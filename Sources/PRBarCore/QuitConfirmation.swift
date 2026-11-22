/// Whether ⌘Q (the menu, the popover or the Dock) asks before quitting: while reviews, analyses, fixes, chats, posts,
/// merges, Clean Up or an update are running, which quitting cancels, or while Respond has fixes that aren't pushed
/// (the run's state lives in memory: after relaunching, its worktree stays on disk but the window can't push it).
/// `prbar app quit`, the updater's relaunch and a logout don't ask.
public enum QuitConfirmation {
    public static func shouldAsk(activeJobs: Int, unpushed: Int = 0, programmatic: Bool) -> Bool {
        (activeJobs > 0 || unpushed > 0) && !programmatic
    }

    public static func title(activeJobs: Int, unpushed: Int = 0) -> String {
        if activeJobs == 0 && unpushed > 0 {
            return unpushed == 1 ? "Quit PRBar while a PR has fixes that aren’t pushed?"
                : "Quit PRBar while \(unpushed) PRs have fixes that aren’t pushed?"
        }
        return activeJobs == 1 ? "Quit PRBar while a job is running?" : "Quit PRBar while \(activeJobs) jobs are running?"
    }

    public static func message(activeJobs: Int, unpushed: Int = 0) -> String {
        var parts: [String] = []
        if activeJobs > 0 {
            parts.append("Quitting cancels the reviews, analyses, fixes, chat replies, merges, posts, Clean Up and "
                + "updates that are still running.")
        }
        if unpushed > 0 {
            parts.append(unpushedMessage(unpushed))
        }
        return parts.joined(separator: " ")
    }

    /// Also the Update window's warning.
    public static func unpushedMessage(_ unpushed: Int) -> String {
        (unpushed == 1 ? "1 PR has fixes that aren’t pushed." : "\(unpushed) PRs have fixes that aren’t pushed.")
            + " Their commits stay in their worktrees, but PRBar won’t offer to push them after it restarts."
    }
}
