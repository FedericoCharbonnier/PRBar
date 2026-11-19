import AppKit
import PRBarCore
import SwiftUI

/// Draws views and windows offscreen into 2x PNGs. Windows are created with `backing: .buffered, defer: false`
/// and never ordered front; their content (and, for windows with a toolbar, the whole frame view with the title
/// bar and toolbar) is captured with `cacheDisplay(in:to:)`, which draws AppKit controls, Forms and SwiftUI.
@MainActor
enum SnapshotRenderer {
    static let scale: CGFloat = 2

    /// An offscreen window that draws as the active (key) window, so prominent buttons, selections and the
    /// toolbar use their active colors even though the window is never shown.
    final class OffscreenWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        // AppKit asks these (private) for the active look of switches, traffic lights and the toolbar.
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc func _hasActiveControls() -> Bool { true }
        @objc func _hasKeyAppearance() -> Bool { true }
        @objc func _hasMainAppearance() -> Bool { true }
    }

    static func appearance(_ appearance: SnapshotOptions.Appearance) -> NSAppearance {
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)!
    }

    static func makeWindow(
        controller: NSViewController, size: NSSize, style: NSWindow.StyleMask, title: String,
        toolbarStyle: NSWindow.ToolbarStyle = .automatic, appearance: NSAppearance, transparent: Bool = false
    ) -> NSWindow {
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: style, backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.title = title
        window.toolbarStyle = toolbarStyle
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
        }
        (NSApp as? SnapshotApplication)?.renderedWindow = window
        window.contentViewController = controller
        window.setContentSize(size)
        return window
    }

    /// Lets SwiftUI run `onAppear`/`task`, lay out and draw.
    static func settle(_ window: NSWindow, seconds: Double = 0.6) async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .seconds(0.1))
    }

    /// The window's content, or with `includeFrame` the whole window: title bar, toolbar and content.
    ///
    /// `cacheDisplay` draws a window's frame view at 1x whatever the bitmap's size, so the frame is composed
    /// instead: the window background, then each of the frame view's subviews (the content view and the title bar
    /// container, with the traffic lights and the toolbar) drawn on its own at `scale`.
    static func capture(_ window: NSWindow, includeFrame: Bool, cornerRadius: CGFloat = 0) -> Data? {
        guard let content = window.contentView else { return nil }
        let hidden = hideLiveEffects(in: content.superview ?? content)
        defer { hidden.forEach { $0.isHidden = false } }
        guard includeFrame, let frameView = content.superview else { return png(of: content, cornerRadius: cornerRadius) }
        let size = frameView.bounds.size
        func rect(of view: NSView) -> NSRect {
            var rect = view.convert(view.bounds, to: frameView)
            if frameView.isFlipped { rect.origin.y = size.height - rect.maxY }
            return rect
        }
        var parts: [Part] = []
        for subview in frameView.subviews where !subview.isHidden && subview.frame.width > 0 && subview.frame.height > 0 {
            guard let rep = bitmap(of: subview) else { continue }
            parts.append(Part(rep: rep, rect: rect(of: subview), panel: false))
            // Glass panels (the Tahoe sidebar) draw their content through the window server: their content is
            // drawn on its own, over a plain rounded panel. (The toolbar's glass item groups draw fine.)
            for glass in subview === content ? descendants(of: subview, named: "GlassEffectView") : [] {
                guard let inner = glass.subviews.first, let rep = bitmap(of: inner) else { continue }
                parts.append(Part(rep: rep, rect: rect(of: inner), panel: true))
            }
        }
        let background = window.backgroundColor ?? .windowBackgroundColor
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return png(size: size) { bounds in
            if cornerRadius > 0 { NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip() }
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                background.setFill()
                bounds.fill()
            }
            for part in parts {
                if part.panel {
                    let panel = NSBezierPath(roundedRect: part.rect, xRadius: 14, yRadius: 14)
                    NSColor(white: dark ? 0.2 : 0.95, alpha: 1).setFill()
                    panel.fill()
                    NSColor(white: dark ? 1 : 0, alpha: 0.08).setStroke()
                    panel.lineWidth = 0.5
                    panel.stroke()
                }
                part.rep.draw(in: part.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
    }

    private struct Part {
        let rep: NSBitmapImageRep
        let rect: NSRect
        let panel: Bool
    }

    private static func descendants(of view: NSView, named fragment: String) -> [NSView] {
        view.subviews.flatMap { child -> [NSView] in
            if child.isHidden { return [] }
            if String(describing: type(of: child)).contains(fragment) { return [child] }
            return descendants(of: child, named: fragment)
        }
    }

    /// Views that the window server composites live (backdrops, scroll-edge blur, glass portals, split view
    /// shadows, the glass behind the selected Settings tab). `cacheDisplay` can't draw them and paints them as opaque black or white over the content, so
    /// they're hidden while capturing; the content under them shows through instead.
    private static let liveEffectClassNames = ["Backdrop", "Portal", "PocketBlur", "PocketMask", "BlurryAlleyway",
                                               "SplitViewShadow", "AdditionalDimming", "LuminanceAdjustment",
                                               "NSGlassView", "NSGlassContainerView"]

    private static func hideLiveEffects(in view: NSView) -> [NSView] {
        var hidden: [NSView] = []
        func visit(_ view: NSView) {
            let name = String(describing: type(of: view))
            // A switch's knob is one of these: switches draw fine as they are.
            if name.contains("Switch") { return }
            if !view.isHidden, liveEffectClassNames.contains(where: name.contains) {
                view.isHidden = true
                hidden.append(view)
                return
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return hidden
    }

    /// Draws `view` into an sRGB PNG at `scale`, optionally with transparent rounded corners.
    static func png(of view: NSView, cornerRadius: CGFloat = 0) -> Data? {
        guard let rep = bitmap(of: view) else { return nil }
        let image = cornerRadius > 0 ? rounded(rep, radius: cornerRadius) : rep
        return image.retagging(with: .sRGB)?.representation(using: .png, properties: [:])
    }

    private static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()),
                pixelsHigh: Int((bounds.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Draws with `draw` into a `size`-point canvas at `scale`.
    static func png(size: NSSize, draw: (NSRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // The size in points before the context: then the context maps points to `scale` pixels.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.retagging(with: .sRGB)?.representation(using: .png, properties: [:])
    }

    /// `rep` with its corners cut to `radius` points (like the window server does for a window).
    private static func rounded(_ rep: NSBitmapImageRep, radius: CGFloat) -> NSBitmapImageRep {
        guard let copy = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return rep }
        copy.size = rep.size
        guard let context = NSGraphicsContext(bitmapImageRep: copy) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: rep.size)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        rep.draw(in: rect)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return copy
    }

    /// A template image filled with `color` (as the menu bar draws it).
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
