import CoreGraphics

/// How PRBar's windows behave with Spaces and full screen, so opening one from the menu bar never moves the user to
/// another Space.
public enum WindowSpaces {
    /// What a window is for.
    public enum Kind: Sendable {
        /// The main window and the PR windows: can go full screen and be grouped in tabs (with the windows of its kind).
        case document
        /// Settings: a single window that comes to the Space you're on.
        case utility
    }

    /// The `collectionBehavior` flags to add, and whether the app shows in the Dock (`.regular`) for it.
    public struct Behavior: Equatable, Sendable {
        /// Opens on (and moves to) the Space you're on instead of switching to the one it was on.
        public var moveToActiveSpace: Bool
        /// Can show over another app's full-screen window (and so can't go full screen itself).
        public var fullScreenAuxiliary: Bool
        /// Turn PRBar into a regular app (Dock icon, ⌘Tab, its menus). Not while another app is in full screen in
        /// front: the policy change could take the user to another Space; it happens when they leave it.
        public var promotesToRegular: Bool

        public init(moveToActiveSpace: Bool, fullScreenAuxiliary: Bool, promotesToRegular: Bool) {
            self.moveToActiveSpace = moveToActiveSpace
            self.fullScreenAuxiliary = fullScreenAuxiliary
            self.promotesToRegular = promotesToRegular
        }
    }

    /// - Parameters:
    ///   - overFullScreenApp: another app is in front in full screen (`isFullScreen`).
    ///   - inTabsOrFullScreen: the window is already a tab of a group or in full screen itself: it's left as it is
    ///     (moving it would split the group or leave its Space).
    public static func behavior(kind: Kind, overFullScreenApp: Bool, inTabsOrFullScreen: Bool = false) -> Behavior {
        switch kind {
        case .utility:
            return Behavior(moveToActiveSpace: true, fullScreenAuxiliary: true, promotesToRegular: !overFullScreenApp)
        case .document:
            let follow = overFullScreenApp && !inTabsOrFullScreen
            return Behavior(moveToActiveSpace: follow, fullScreenAuxiliary: follow, promotesToRegular: !overFullScreenApp)
        }
    }

    /// Whether one of the front app's windows covers a whole screen (that app is in full screen there).
    /// `windowBounds` and `screenFrames` in the same coordinates (`cgFrame` converts a screen's frame to the window
    /// list's, which has its origin at the top left of the main display).
    public static func isFullScreen(windowBounds: [CGRect], screenFrames: [CGRect]) -> Bool {
        windowBounds.contains { window in
            screenFrames.contains { screen in
                abs(window.minX - screen.minX) <= 1 && abs(window.minY - screen.minY) <= 1
                    && abs(window.width - screen.width) <= 1 && abs(window.height - screen.height) <= 1
            }
        }
    }

    /// A screen's frame (AppKit: origin at the bottom left of the main display, y up) in the window list's
    /// coordinates (origin at the top left of the main display, y down).
    public static func cgFrame(_ frame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
