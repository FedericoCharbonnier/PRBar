import CoreGraphics

/// How big the list of a searchable picker (Settings › Repos › Add Repo…, base branches, people to follow) opens.
///
/// The list used to measure its rows from inside a lazy scroll view: on the first layout that measure is 0 (or only
/// the rows drawn so far), the popover took that size, and the list opened about one row tall. Its height is now
/// computed from the rows it shows: all of them up to about 14 rows, then it scrolls, never taller than the screen.
public enum PickerListSizing {
    /// A one-line row (title) and a row with a subtitle under it.
    public static let rowHeight: CGFloat = 28
    public static let subtitledRowHeight: CGFloat = 44
    /// An owner's header in the repo list.
    public static let sectionHeaderHeight: CGFloat = 26
    /// Around the rows (top and bottom).
    public static let padding: CGFloat = 8
    /// Wide enough for `owner/a-long-repo-name` and branch names.
    public static let minimumWidth: CGFloat = 360
    /// About this many one-line rows show before the list scrolls.
    public static let visibleRows = 14
    public static let defaultMaxHeight = CGFloat(visibleRows) * rowHeight + padding
    /// What the popover needs besides the list (search field, footer, arrow, margins).
    public static let chrome: CGFloat = 140
    /// The list is never shorter than this (a "No Results" or loading message fits).
    public static let minimumHeight: CGFloat = 60

    /// The height of every row: `subtitled[i]` says whether row `i` has a subtitle.
    public static func contentHeight(subtitled: [Bool], sections: Int) -> CGFloat {
        let rows = subtitled.reduce(CGFloat(0)) { $0 + ($1 ? subtitledRowHeight : rowHeight) }
        return rows + CGFloat(sections) * sectionHeaderHeight + padding
    }

    /// The list's height: its content, up to `maxHeight`, and up to what fits on a screen whose visible area is
    /// `screenHeight` tall.
    public static func listHeight(contentHeight: CGFloat, maxHeight: CGFloat = defaultMaxHeight,
                                  screenHeight: CGFloat?) -> CGFloat {
        var cap = maxHeight
        if let screenHeight { cap = min(cap, screenHeight - chrome) }
        return max(min(contentHeight, cap), minimumHeight)
    }

    public static func width(requested: CGFloat) -> CGFloat { max(requested, minimumWidth) }
}
