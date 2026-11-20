import CoreGraphics

/// Where the menu bar panel goes (the popover that `StatusItemController` shows under PRBar's icon). AppKit
/// coordinates: origin at the bottom left, y grows up.
///
/// The panel's top edge is fixed when it opens, at the menu bar's resting position. When the menu bar hides (the
/// "Automatically hide and show the menu bar" setting, or any full-screen Space) the icon's window slides off the top
/// of the screen; the panel stays where it is instead of following it, and every resize keeps that top edge.
public enum StatusPanelLayout {
    /// Space between the menu bar and the panel.
    public static let gap: CGFloat = 4
    /// Space kept free between the panel and the bottom (Dock) or the sides of the visible area.
    public static let margin: CGFloat = 8
    /// The panel is never made shorter than this, even on a tiny visible area.
    public static let minimumHeight: CGFloat = 160

    /// The y of the panel's top edge: right under the icon, or under the menu bar's resting position when the icon is
    /// higher than that (the menu bar is hidden or sliding away).
    /// - Parameters:
    ///   - buttonFrame: the status item button, in screen coordinates.
    ///   - screenFrame: the full frame of the screen the icon is on.
    ///   - menuBarHeight: the menu bar's height on that screen (taller on displays with a notch).
    public static func top(buttonFrame: CGRect, screenFrame: CGRect, menuBarHeight: CGFloat) -> CGFloat {
        let resting = screenFrame.maxY - menuBarHeight
        return min(buttonFrame.minY, resting) - gap
    }

    /// How tall the panel can be below `top` without going past the bottom of the visible area.
    public static func maxHeight(top: CGFloat, visibleFrame: CGRect) -> CGFloat {
        max(minimumHeight, top - visibleFrame.minY - margin)
    }

    /// The panel's frame for content of `contentSize`: the top edge at `top`, centered under the icon (`anchorX`) and
    /// kept inside the visible area, and no taller than `maxHeight(top:visibleFrame:)`.
    public static func frame(contentSize: CGSize, top: CGFloat, anchorX: CGFloat, visibleFrame: CGRect) -> CGRect {
        let height = min(contentSize.height, maxHeight(top: top, visibleFrame: visibleFrame))
        let width = contentSize.width
        let lowest = visibleFrame.minX + margin
        let highest = visibleFrame.maxX - margin - width
        let x = highest < lowest ? visibleFrame.minX : min(max(anchorX - width / 2, lowest), highest)
        return CGRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height.rounded())
    }

    /// What the open panel does when the icon's window moves.
    public enum ButtonMove: Equatable, Sendable {
        /// Only vertical (the menu bar hid or came back): the panel stays put.
        case keep
        /// The icon moved sideways on the same screen (another icon appeared, the badge got wider): the panel follows
        /// it horizontally and keeps its top edge.
        case follow
        /// The icon is on another screen now: the panel closes.
        case close
    }

    /// `screenFrames`: the frames of every screen, to tell which one each position is on. Only x is compared, since
    /// a hidden menu bar puts the icon above the top of its screen.
    public static func buttonMove(from old: CGRect, to new: CGRect, screenFrames: [CGRect]) -> ButtonMove {
        func screen(_ x: CGFloat) -> Int? { screenFrames.firstIndex { $0.minX <= x && x < $0.maxX } }
        if screen(old.midX) != screen(new.midX) { return .close }
        return abs(old.midX - new.midX) > 0.5 ? .follow : .keep
    }

    /// The menu bar's height on a screen: the larger of the status bar's thickness, the top safe area (the notch) and
    /// the strip above the visible area (0 while the menu bar is hidden).
    public static func menuBarHeight(statusBarThickness: CGFloat, safeAreaTop: CGFloat, screenFrame: CGRect,
                                     visibleFrame: CGRect) -> CGFloat {
        max(statusBarThickness, safeAreaTop, screenFrame.maxY - visibleFrame.maxY)
    }
}
