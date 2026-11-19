import AppKit

enum MenuBarIconState: Equatable {
    case idle
    case count(Int)
    case error
}

/// Ícono template para la barra de menú: glifo + badge en cápsula con el número calado (diseño 01).
enum BadgeIcon {
    static func image(for state: MenuBarIconState) -> NSImage {
        let symbolName = state == .error ? "exclamationmark.triangle" : "arrow.triangle.pull"
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PRBar")?
            .withSymbolConfiguration(configuration) ?? NSImage()

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
