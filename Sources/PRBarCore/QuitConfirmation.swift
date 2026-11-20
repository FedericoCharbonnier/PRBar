/// Whether ⌘Q (the menu, the popover or the Dock) asks before quitting: only while reviews, analyses, fixes, chats or
/// posts are running, which quitting cancels. `prbar app quit`, the updater's relaunch and a logout don't ask.
public enum QuitConfirmation {
    public static func shouldAsk(activeJobs: Int, programmatic: Bool) -> Bool {
        activeJobs > 0 && !programmatic
    }

    public static func title(activeJobs: Int) -> String {
        activeJobs == 1 ? "Quit PRBar while a job is running?" : "Quit PRBar while \(activeJobs) jobs are running?"
    }

    public static let message =
        "Quitting cancels the reviews, analyses, fixes and chat replies that are still running."
}
