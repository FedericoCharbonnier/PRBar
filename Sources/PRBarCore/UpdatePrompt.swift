import Foundation

/// How the app announces a new version outside Settings: the "Update" button in the popover's header, the dot on the
/// menu bar icon (and its VoiceOver description) and the app menu's "Check for Updates…" item. One place for the
/// texts, so the three agree with each other and with `UpdateController`'s state.
public enum UpdatePrompt: Equatable, Sendable {
    /// A version is offered (`UpdateController.available`); clicking opens the Update window.
    case available(version: String)
    /// An update is being installed: the button shows a spinner and does nothing.
    case installing

    /// `nil` when there's nothing to show (up to date, skipped or never checked). Installing wins over the offer.
    public init?(availableVersion: String?, isInstalling: Bool) {
        if isInstalling {
            self = .installing
        } else if let availableVersion {
            self = .available(version: availableVersion)
        } else {
            return nil
        }
    }

    /// The header button's label: short, so it fits next to the title.
    public var title: String {
        switch self {
        case .available: "Update"
        case .installing: "Updating…"
        }
    }

    /// Its tooltip and VoiceOver label (the icon-only form shows just the symbol, so this carries the version).
    public var help: String {
        switch self {
        case .available(let version): "PRBar \(version) is available — Update"
        case .installing: "Updating PRBar…"
        }
    }

    public var isEnabled: Bool { self != .installing }

    /// The app menu item: "Check for Updates…" or, with a version offered, "Update to PRBar 1.3.0…".
    public static func menuTitle(availableVersion: String?) -> String {
        availableVersion.map { "Update to PRBar \($0)…" } ?? "Check for Updates…"
    }

    /// The status item's VoiceOver description: "PRBar, 3 PRs need your action" plus ", update available" (or
    /// ", updating") when there is one.
    public static func statusItemAccessibilityLabel(state: String, prompt: UpdatePrompt?) -> String {
        let base = "PRBar, \(state)"
        switch prompt {
        case nil: return base
        case .available: return base + ", update available"
        case .installing: return base + ", updating"
        }
    }
}
