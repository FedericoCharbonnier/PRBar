/// The keys the menu bar panel handles itself, as system menu bar extras do: ↑/↓ move between the PR rows, Return
/// opens the selected one and Esc closes the panel.
public enum PopoverKey: Equatable, Sendable {
    case up, down, open, close

    /// `hasModifiers`: ⌘, ⌥, ⌃ or ⇧ is down (those keys are left to the shortcuts and the focused control).
    public init?(keyCode: UInt16, hasModifiers: Bool) {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .open   // Return, keypad Enter
        case 53: self = .close      // Esc
        default: return nil
        }
    }
}

/// Which PR row is selected after ↑/↓. `ids` are the rows on screen, top to bottom (the chosen tab, without the
/// collapsed sections).
public enum PopoverRowNavigation {
    public static func move(from current: String?, in ids: [String], key: PopoverKey) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            switch key {
            case .up: return ids.last
            case .down: return ids.first
            case .open, .close: return nil
            }
        }
        switch key {
        case .up: return ids[max(index - 1, 0)]
        case .down: return ids[min(index + 1, ids.count - 1)]
        case .open, .close: return current
        }
    }

    /// The selection after the rows change (a refresh, another tab, a collapsed section): kept while its row is
    /// still there, otherwise none.
    public static func keep(_ current: String?, in ids: [String]) -> String? {
        current.flatMap { ids.contains($0) ? $0 : nil }
    }
}
