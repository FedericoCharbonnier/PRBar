import AppKit
import PRBarCore

/// The terminals installed on this Mac (by bundle id, spec T.6). Terminal is always there; Custom always offered.
@MainActor
enum TerminalApps {
    static func isInstalled(_ choice: TerminalChoice) -> Bool {
        switch choice {
        case .terminal, .custom: true
        case .iterm, .warp, .ghostty, .orca:
            TerminalLauncher.bundleIDs[choice].map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? false
        }
    }

    /// What the picker lists: the installed ones, Custom, and the saved one even if it was uninstalled (so it shows).
    static func offered(current: TerminalChoice) -> [TerminalChoice] {
        TerminalChoice.allCases.filter { isInstalled($0) || $0 == current }
    }

    static func menuTitle(_ choice: TerminalChoice) -> String {
        choice == .custom ? "Custom…" : choice.displayName
    }
}
