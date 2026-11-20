/// Every keyboard shortcut of the app, for Help › Keyboard Shortcuts. The popover's are here too: it has no menu bar.
public enum KeyboardShortcutList {
    public struct Shortcut: Equatable, Sendable {
        public let keys: String
        public let action: String
    }

    public struct Group: Equatable, Sendable {
        public let title: String
        public let shortcuts: [Shortcut]
    }

    public static let groups: [Group] = [
        Group(title: "Menu bar popover", shortcuts: [
            Shortcut(keys: "↑ ↓", action: "Select a PR"),
            Shortcut(keys: "↩", action: "Open the selected PR on GitHub"),
            Shortcut(keys: "⌘1 / ⌘2", action: "To Review / My PRs"),
            Shortcut(keys: "⌘R", action: "Refresh"),
            Shortcut(keys: "⌘Y", action: "History"),
            Shortcut(keys: "⌘,", action: "Settings"),
            Shortcut(keys: "⌘Q", action: "Quit PRBar"),
            Shortcut(keys: "esc", action: "Close the popover"),
        ]),
        Group(title: "Review, Respond and Merge windows", shortcuts: [
            Shortcut(keys: "⇧⌘C", action: "Show or hide the chat"),
            Shortcut(keys: "⌘R", action: "Refresh (Merge; elsewhere the PR list)"),
            Shortcut(keys: "⌘↩", action: "Post, push or merge"),
            Shortcut(keys: "⌃⌘F", action: "Enter or exit full screen"),
        ]),
        Group(title: "Chat", shortcuts: [
            Shortcut(keys: "↩", action: "Send"),
            Shortcut(keys: "⇧↩ or ⌥↩", action: "New line"),
        ]),
    ]
}
