import AppKit
import SwiftUI

// Renders PRBar's app icon following the macOS icon grid: an 824×824 body centered on a 1024 canvas with
// continuous ("squircle") corners of radius ~185, in sRGB.
//
// Usage: swift Scripts/icon/make_icon.swift <out.png> [light|dark] [pixels]
//   pixels defaults to 1024. Sizes of 64 px and below use a simplified small-size variant: no shadows,
//   no sparkle, no inner border and a heavier, slightly larger glyph so it stays legible.
// Regenerate Resources/AppIcon.icns with Scripts/icon/build_icns.sh.

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"
let dark = args.count > 2 && args[2] == "dark"
let pixels = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
let small = pixels <= 64

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The body outline with continuous corners (the same curve SwiftUI uses for `.continuous`).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let cg = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("could not create the sRGB context") }
cg.interpolationQuality = .high
// Everything below is drawn in 1024-point canvas coordinates.
cg.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

let bodyPath = squircle(body, radius: radius)

// Drop shadow under the body (as macOS icons have), only where it can be seen.
if !small {
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(bodyPath)
    cg.setFillColor(color(dark ? 0x10152A : 0x2D4EFF).cgColor)
    cg.fillPath()
    cg.restoreGState()
}

// Background gradient, clipped to the body.
cg.saveGState()
cg.addPath(bodyPath)
cg.clip()
let gradient = dark
    ? NSGradient(colors: [color(0x1E2C66), color(0x10152A), color(0x0B0E1A)])!
    : NSGradient(colors: [color(0x6A83FF), color(0x2D4EFF), color(0x1A33C9)])!
gradient.draw(in: body, angle: -60)

// Soft top highlight ("glass").
let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(dark ? 0.10 : 0.22), NSColor.white.withAlphaComponent(0)])!
highlight.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

// Main glyph: branches merging into a PR.
func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, colors: [NSColor]) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: colors))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}

let glyphColor = dark ? color(0x8299FF) : NSColor.white
let glyph = symbol("arrow.triangle.pull", size: small ? 500 : 430, weight: small ? .heavy : .semibold, colors: [glyphColor])
let gSize = glyph.size
// The full-size glyph sits slightly left to leave room for the sparkle; the small one is centered.
let gOffset = small ? CGPoint(x: 0, y: -6) : CGPoint(x: -18, y: -10)
let gRect = CGRect(x: body.midX - gSize.width / 2 + gOffset.x, y: body.midY - gSize.height / 2 + gOffset.y,
                   width: gSize.width, height: gSize.height)
cg.saveGState()
if !small {
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
}
glyph.draw(in: gRect)
cg.restoreGState()

// Review sparkle (Claude) in the upper right.
if !small {
    let sparkleColors = dark ? [color(0xC88BFF)] : [color(0xF2E6FF)]
    let sparkle = symbol("sparkle", size: 150, weight: .bold, colors: sparkleColors)
    let sSize = sparkle.size
    let sRect = CGRect(x: body.maxX - sSize.width - 120, y: body.maxY - sSize.height - 110, width: sSize.width, height: sSize.height)
    cg.saveGState()
    cg.setShadow(offset: .zero, blur: 30, color: (dark ? color(0xC88BFF, 0.8) : color(0xFFFFFF, 0.7)).cgColor)
    sparkle.draw(in: sRect)
    cg.restoreGState()
}
cg.restoreGState()

// Thin inner border for definition (sub-pixel, so skipped at small sizes).
if !small {
    cg.addPath(squircle(body.insetBy(dx: 1.5, dy: 1.5), radius: radius - 1.5))
    cg.setStrokeColor(color(0xFFFFFF, dark ? 0.10 : 0.18).cgColor)
    cg.setLineWidth(3)
    cg.strokePath()
}

NSGraphicsContext.restoreGraphicsState()

guard let image = cg.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("could not encode \(outPath)") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(outPath)") }
print("wrote \(outPath) (\(pixels)×\(pixels)\(small ? ", small variant" : ""))")
