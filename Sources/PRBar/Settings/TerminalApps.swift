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

    /// Asks Launch Services for each terminal: Settings keeps the answer instead of asking on every redraw.
    static func installed() -> Set<TerminalChoice> {
        Set(TerminalChoice.allCases.filter(isInstalled))
    }

    /// What the picker lists: the installed ones, Custom, and the saved one even if it was uninstalled (so it shows).
    static func offered(current: TerminalChoice, installed: Set<TerminalChoice>) -> [TerminalChoice] {
        TerminalChoice.allCases.filter { installed.contains($0) || $0 == current }
    }

    static func menuTitle(_ choice: TerminalChoice, installed: Bool) -> String {
        if choice == .custom { return "Custom…" }
        return installed ? choice.displayName : "\(choice.displayName) (not installed)"
    }
}
