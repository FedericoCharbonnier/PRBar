import AppKit
import PRBarCore
import SwiftUI

/// Grows the window when its inspector opens so the content keeps `minContentWidth` next to it, without leaving the
/// screen's visible area (`InspectorSizing`).
private struct InspectorWindowSizing: ViewModifier {
    let isPresented: Bool
    let minContentWidth: CGFloat
    let inspectorWidth: CGFloat
    @State private var box = WindowBox()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in box.window = window })
            .onChange(of: isPresented) { _, shown in
                guard shown else { return }
                // After SwiftUI lays out the inspector (it may have widened the window already).
                DispatchQueue.main.async { grow() }
            }
    }

    private func grow() {
        guard let window = box.window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
              !window.styleMask.contains(.fullScreen),
              let frame = InspectorSizing.frame(window: window.frame, contentWidth: window.contentLayoutRect.width,
                                                requiredContentWidth: minContentWidth + inspectorWidth, visibleFrame: visible)
        else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}

extension View {
    /// See `InspectorWindowSizing`.
    func growsWindowForInspector(isPresented: Bool, minContentWidth: CGFloat, inspectorWidth: CGFloat) -> some View {
        modifier(InspectorWindowSizing(isPresented: isPresented, minContentWidth: minContentWidth, inspectorWidth: inspectorWidth))
    }
}
