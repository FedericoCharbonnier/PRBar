import AppKit

enum MenuBarIconState: Equatable {
    case idle
    case count(Int)
    case error
}

/// Ícono template para la barra de menú: glifo + badge en cápsula con el número calado (diseño 01).
///
/// With `updateDot`, the image grows a little to the right and its top-right corner is kept clear (a transparent ring
/// cut out of the glyph or the count badge) for the blue "update available" dot. The image stays a template (so the
/// menu bar tints it for light, dark and the auto-hidden bar); the dot, which must keep its color, is drawn on top by
/// `UpdateDotView` at `updateDotRect(imageSize:)`.
enum BadgeIcon {
    static let updateDotDiameter: CGFloat = 6
    /// How much wider the image gets for the dot: it only overlaps the icon's top-right corner by a point.
    private static let updateDotExtraWidth: CGFloat = 5
    /// The transparent gap around the dot, so it reads apart from the icon on any menu bar.
    private static let updateDotGap: CGFloat = 1.5

    /// The dot's rect in the image's coordinates (origin bottom-left): its top-right corner.
    static func updateDotRect(imageSize: NSSize) -> NSRect {
        NSRect(x: imageSize.width - updateDotDiameter, y: imageSize.height - updateDotDiameter,
               width: updateDotDiameter, height: updateDotDiameter)
    }

    private static func glyph(for state: MenuBarIconState) -> NSImage {
        let symbolName = state == .error ? "exclamationmark.triangle" : "arrow.triangle.pull"
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "PRBar")?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }

    static func image(for state: MenuBarIconState, updateDot: Bool = false) -> NSImage {
        let base = baseImage(for: state)
        guard updateDot else { return base }
        let size = NSSize(width: base.size.width + updateDotExtraWidth, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: updateDotRect(imageSize: size).insetBy(dx: -updateDotGap, dy: -updateDotGap)).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func baseImage(for state: MenuBarIconState) -> NSImage {
        let glyph = glyph(for: state)

        guard case .count(let count) = state, count > 0 else {
            glyph.isTemplate = true
            return glyph
        }

        let text = count > 99 ? "99+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let badgeHeight: CGFloat = 14
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 8)
        let size = NSSize(width: glyph.size.width + 3 + badgeWidth, height: max(glyph.size.height, badgeHeight))

        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            let badge = NSRect(x: glyph.size.width + 3, y: (size.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            (text as NSString).draw(
                at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                withAttributes: attributes
            )
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The blue "update available" dot over the status item's icon. A subview of the status bar button so it keeps its
/// color while the template image under it follows the menu bar's appearance. Doesn't take clicks or VoiceOver focus
/// (the button's description says "update available").
final class UpdateDotView: NSView {
    /// The dot in the icon image's coordinates, and that image's size; `nil` hides the dot.
    var dot: (rect: NSRect, imageSize: NSSize)? {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let dot, dot.imageSize.width > 0, dot.imageSize.height > 0 else { return }
        // Where the button draws its image, in this view's coordinates (the cell centers it).
        var imageRect = NSRect(x: (bounds.width - dot.imageSize.width) / 2, y: (bounds.height - dot.imageSize.height) / 2,
                               width: dot.imageSize.width, height: dot.imageSize.height)
        if let button = superview as? NSButton, let cell = button.cell {
            imageRect = convert(cell.imageRect(forBounds: button.bounds), from: button)
        }
        let scaleX = imageRect.width / dot.imageSize.width
        let scaleY = imageRect.height / dot.imageSize.height
        let rect = NSRect(x: imageRect.minX + dot.rect.minX * scaleX, y: imageRect.minY + dot.rect.minY * scaleY,
                          width: dot.rect.width * scaleX, height: dot.rect.height * scaleY)
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: backingAlignedRect(rect, options: .alignAllEdgesNearest)).fill()
    }
}
