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
        Group(title: "PRBar window", shortcuts: [
            Shortcut(keys: "⌘0", action: "Open or focus PRBar's window"),
            Shortcut(keys: "⌘1 · ⌘2 · ⌘3 · ⌘4", action: "To Review · My PRs · History · Activity"),
            Shortcut(keys: "⌥⌘1–3", action: "The PR's tabs"),
            Shortcut(keys: "↑ ↓", action: "Move through the list"),
            Shortcut(keys: "↩", action: "The row's action (Review, Respond, Merge…)"),
            Shortcut(keys: "⌘↩", action: "Post Review · Push · Push & Reply (the tab's action)"),
            Shortcut(keys: "⇧⌘M", action: "Merge"),
            Shortcut(keys: "⌘.", action: "Stop Claude"),
            Shortcut(keys: "⌘Z", action: "Undo Claude's last change (outside text fields)"),
            Shortcut(keys: "⌥⌘I", action: "Show or hide the chat"),
            Shortcut(keys: "⌥⌘T", action: "Open Claude's session of the PR in your terminal"),
            Shortcut(keys: "⌃⌘S", action: "Show or hide the sidebar"),
            Shortcut(keys: "⇧⌘O", action: "Open the PR in a new window"),
            Shortcut(keys: "⌘R", action: "Refresh"),
            Shortcut(keys: "⌘F", action: "Search"),
            Shortcut(keys: "⌘[", action: "Back"),
            Shortcut(keys: "⌘,", action: "Settings"),
            Shortcut(keys: "⌃⌘F", action: "Enter or exit full screen"),
        ]),
        Group(title: "Menu bar popover", shortcuts: [
            Shortcut(keys: "↑ ↓", action: "Select a PR"),
            Shortcut(keys: "↩", action: "Open the selected PR in PRBar"),
            Shortcut(keys: "⌘1 / ⌘2", action: "To Review / My PRs"),
            Shortcut(keys: "⌘R", action: "Refresh"),
            Shortcut(keys: "⌘0", action: "Open PRBar"),
            Shortcut(keys: "⌘,", action: "Settings"),
            Shortcut(keys: "⌘Q", action: "Quit PRBar"),
            Shortcut(keys: "esc", action: "Close the popover"),
        ]),
        Group(title: "Chat", shortcuts: [
            Shortcut(keys: "↩", action: "Send"),
            Shortcut(keys: "⇧↩ or ⌥↩", action: "New line"),
            Shortcut(keys: "⌘↩", action: "Send (the tab's action waits while you type in the chat)"),
        ]),
    ]
}
