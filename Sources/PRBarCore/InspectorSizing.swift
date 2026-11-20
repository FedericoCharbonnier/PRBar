import CoreGraphics

/// How much to grow a window when its chat inspector opens, so the editor keeps its minimum width, without leaving
/// the visible area of its screen.
public enum InspectorSizing {
    /// - Parameters:
    ///   - window: the window's frame.
    ///   - contentWidth: the width of its content area now (the inspector included if SwiftUI already added it).
    ///   - requiredContentWidth: the editor's minimum plus the inspector's width.
    ///   - visibleFrame: the visible area of the window's screen.
    /// - Returns: the new frame, or `nil` if the window is already wide enough and on screen.
    public static func frame(window: CGRect, contentWidth: CGFloat, requiredContentWidth: CGFloat,
                             visibleFrame: CGRect) -> CGRect? {
        let chrome = max(window.width - contentWidth, 0)
        let width = min(max(window.width, requiredContentWidth + chrome), visibleFrame.width)
        var frame = window
        frame.size.width = width
        if frame.maxX > visibleFrame.maxX { frame.origin.x = visibleFrame.maxX - width }
        if frame.minX < visibleFrame.minX { frame.origin.x = visibleFrame.minX }
        return frame == window ? nil : frame
    }
}
