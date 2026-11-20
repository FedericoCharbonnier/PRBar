import SwiftUI

/// A design token with its light and dark values (`ios/DESIGN.md` § Tokens). It resolves against the environment's
/// color scheme, so it works as a `ShapeStyle` anywhere (`foregroundStyle`, `background`, `fill`) on iOS and in the
/// macOS snapshot renderer alike. `color(_:)` gives a plain `Color` where an API needs one (`tint`).
public struct Token: ShapeStyle, Sendable {
    public let light: Color
    public let dark: Color

    public init(_ light: Color, _ dark: Color) {
        self.light = light
        self.dark = dark
    }

    public init(_ both: Color) {
        self.init(both, both)
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        color(environment.colorScheme)
    }

    public func color(_ scheme: ColorScheme) -> Color { scheme == .dark ? dark : light }
}

extension Color {
    /// `0x2D4EFF`.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    /// `rgba(60,60,67,.18)`.
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

public enum Tokens {
    public static let bg = Token(Color(hex: 0xF2F2F7), Color(hex: 0x000000))
    public static let bg2 = Token(Color(hex: 0xFFFFFF), Color(hex: 0x1C1C1E))
    public static let bg3 = Token(Color(hex: 0xE9E9EB), Color(hex: 0x2C2C2E))
    public static let sheet = Token(Color(hex: 0xF2F2F7), Color(hex: 0x1C1C1E))
    public static let fg = Token(Color(hex: 0x000000), Color(hex: 0xFFFFFF))
    public static let fg2 = Token(Color(hex: 0x5E5E63), Color(hex: 0xAEAEB2))
    public static let fg3 = Token(Color(hex: 0x8A8A8E), Color(hex: 0x7C7C80))
    public static let sep = Token(Color(60, 60, 67, 0.18), Color(84, 84, 88, 0.55))
    public static let fill = Token(Color(118, 118, 128, 0.12), Color(118, 118, 128, 0.24))
    public static let fill2 = Token(Color(118, 118, 128, 0.22), Color(118, 118, 128, 0.36))
    public static let accent = Token(Color(hex: 0x2D4EFF), Color(hex: 0x3B5BFF))
    public static let accentfg = Token(Color(hex: 0x2D4EFF), Color(hex: 0x8FA3FF))
    public static let accentbg = Token(Color(45, 78, 255, 0.10), Color(80, 110, 255, 0.22))
    public static let green = Token(Color(hex: 0x12793A), Color(hex: 0x30D158))
    public static let greenbg = Token(Color(hex: 0xE1F3E6), Color(48, 209, 88, 0.18))
    public static let orange = Token(Color(hex: 0xA65300), Color(hex: 0xFF9F0A))
    public static let orangebg = Token(Color(hex: 0xFCEBD8), Color(255, 159, 10, 0.18))
    public static let red = Token(Color(hex: 0xC42B1F), Color(hex: 0xFF6961))
    public static let redbg = Token(Color(hex: 0xFBE5E3), Color(255, 69, 58, 0.20))
    public static let violet = Token(Color(hex: 0x6B2FB3), Color(hex: 0xD2B3FF))
    public static let violetbg = Token(Color(hex: 0xEFE6FB), Color(150, 90, 230, 0.28))
    public static let blue = Token(Color(hex: 0x1F5FBF), Color(hex: 0x7FB0FF))
    public static let bluebg = Token(Color(hex: 0xE3EDFB), Color(80, 140, 255, 0.20))
    public static let codebg = Token(Color(hex: 0xF5F6F8), Color(hex: 0x121214))
    public static let addbg = Token(Color(40, 170, 80, 0.13), Color(48, 209, 88, 0.16))
    public static let delbg = Token(Color(230, 60, 50, 0.11), Color(255, 69, 58, 0.16))
    public static let hud = Token(Color(246, 246, 248, 0.88), Color(38, 38, 42, 0.90))
    public static let connected = Token(Color(hex: 0x30C559))
    public static let badge = Token(Color(hex: 0xE5372B))
    public static let appTile = Token(Color(hex: 0x2D4EFF))
    public static let white = Token(Color.white)

    /// Per-person avatar colors (picked deterministically from the login, white initials).
    public static let avatars: [Color] = [
        Color(hex: 0x2D4EFF), Color(hex: 0x12793A), Color(hex: 0xA65300), Color(hex: 0x6B2FB3),
        Color(hex: 0xC42B1F), Color(hex: 0x1F5FBF), Color(hex: 0x0F7C80), Color(hex: 0x8A4B1F),
    ]
}

/// Spacing and radii (`ios/DESIGN.md`).
public enum Metrics {
    public static let gutter: CGFloat = 16
    public static let cardRadius: CGFloat = 22
    public static let groupRadius: CGFloat = 24
    public static let rowPadding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    public static let rowGap: CGFloat = 12
    public static let separatorInset: CGFloat = 62
    public static let touch: CGFloat = 44
    public static let capsule: CGFloat = 30
    public static let bottomBarButton: CGFloat = 54
    public static let phoneWidth: CGFloat = 393
}

/// Type ramp: the design's sizes mapped to the text styles that have them, so everything follows Dynamic Type.
public enum Typo {
    /// 34 bold.
    public static let largeTitle = Font.largeTitle.bold()
    /// 28 bold (`pair:paired`, `review:posted`).
    public static let title1 = Font.title.bold()
    /// 24 bold in the design (detail headers); the closest text style is 22.
    public static let title = Font.title2.bold()
    /// 20 bold ("Findings", "Feedback").
    public static let section = Font.title3.bold()
    /// 17 semibold.
    public static let headline = Font.headline
    /// 17 (chat bubbles, editor).
    public static let large = Font.body
    /// 15.
    public static let body = Font.subheadline
    public static let bodyBold = Font.subheadline.weight(.semibold)
    /// 16.
    public static let callout = Font.callout
    /// 13.
    public static let footnote = Font.footnote
    public static let footnoteMedium = Font.footnote.weight(.medium)
    public static let footnoteBold = Font.footnote.weight(.semibold)
    /// 12.
    public static let caption = Font.caption
    /// Mono 13 / 12 / 11.5.
    public static let mono = Font.system(.footnote, design: .monospaced)
    public static let monoSmall = Font.system(.caption, design: .monospaced)
    public static let code = Font.system(.caption2, design: .monospaced)
}
