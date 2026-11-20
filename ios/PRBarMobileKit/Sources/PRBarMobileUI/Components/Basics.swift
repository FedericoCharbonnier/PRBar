import SwiftUI
import PRBarMobileCore

// MARK: - Containers

extension View {
    /// A grouped card: bg2, rounded 22 (24 for row groups).
    public func card(radius: CGFloat = Metrics.cardRadius, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Liquid Glass in a capsule (nav pills, bottom-bar secondaries, chat input).
    public func glassCapsule() -> some View {
        modifier(Glass(shape: Capsule()))
    }

    public func glassCircle() -> some View {
        modifier(Glass(shape: Circle()))
    }
}

extension EnvironmentValues {
    /// Set by the snapshot renderer: Liquid Glass doesn't draw into an image, so glass falls back to the HUD fill.
    @Entry public var isSnapshot = false
}

struct Glass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
                .background(Tokens.hud, in: shape)
                .overlay(shape.stroke(Tokens.sep, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        } else {
            content.glassEffect(.regular.interactive(), in: shape)
        }
    }
}

/// The 0.5 pt separator.
public struct Hairline: View {
    var inset: CGFloat = 0
    public init(inset: CGFloat = 0) { self.inset = inset }
    public var body: some View {
        Rectangle().fill(Tokens.sep).frame(height: 0.5).padding(.leading, inset)
    }
}

// MARK: - Buttons

/// 44 pt glass circle with an SF Symbol (Back, Chat, More, Filter, Cancel).
public struct GlassCircleButton: View {
    let symbol: String
    let label: String
    var tint: Token = Tokens.fg
    let action: () -> Void

    public init(_ symbol: String, label: String, tint: Token = Tokens.fg, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Metrics.touch, height: Metrics.touch)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .accessibilityLabel(label)
    }
}

/// The accent capsule (Scan, Codes Match, Post, Merge, Done…), optionally with a leading symbol (`faceid`).
public struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var height: CGFloat = Metrics.bottomBarButton
    var enabled = true
    let action: () -> Void

    public init(_ title: String, symbol: String? = nil, height: CGFloat = Metrics.bottomBarButton, enabled: Bool = true,
                action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.height = height
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(Typo.headline)
            .foregroundStyle(enabled ? Tokens.white : Tokens.fg3)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(enabled ? AnyShapeStyle(Tokens.accent) : AnyShapeStyle(Tokens.fill), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A tinted capsule (accentbg/accentfg by default): "View on GitHub", "Try Again", "Undo", "Stop".
public struct TintedButton: View {
    let title: String
    var symbol: String?
    var foreground: Token = Tokens.accentfg
    var background: Token = Tokens.accentbg
    var height: CGFloat = 50
    var fullWidth = true
    let action: () -> Void

    public init(_ title: String, symbol: String? = nil, foreground: Token = Tokens.accentfg,
                background: Token = Tokens.accentbg, height: CGFloat = 50, fullWidth: Bool = true,
                action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.foreground = foreground
        self.background = background
        self.height = height
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let symbol { Image(systemName: symbol) }
            }
            .font(fullWidth ? Typo.headline : Typo.bodyBold)
            .foregroundStyle(foreground)
            .padding(.horizontal, fullWidth ? 0 : 14)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Leading-symbol variant used by "Try Again" (`arrow.clockwise`), "Stop" (`stop.fill`), "Undo".
public struct SymbolCapsule: View {
    let title: String
    let symbol: String
    var foreground: Token = Tokens.accentfg
    var background: Token = Tokens.accentbg
    var height: CGFloat = Metrics.touch
    let action: () -> Void

    public init(_ title: String, symbol: String, foreground: Token = Tokens.accentfg, background: Token = Tokens.accentbg,
                height: CGFloat = Metrics.touch, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.foreground = foreground
        self.background = background
        self.height = height
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(Typo.bodyBold)
                .foregroundStyle(foreground)
                .padding(.horizontal, 16)
                .frame(minHeight: height)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - People and status

/// Initials on a per-person color circle.
public struct Avatar: View {
    let name: String
    let login: String
    var size: CGFloat = 34
    var disabled = false

    public init(name: String, login: String, size: CGFloat = 34, disabled: Bool = false) {
        self.name = name
        self.login = login
        self.size = size
        self.disabled = disabled
    }

    public var body: some View {
        Circle()
            .fill(disabled ? AnyShapeStyle(Tokens.fg3) : AnyShapeStyle(Tokens.avatars[Format.avatarIndex(login, count: Tokens.avatars.count)]))
            .frame(width: size, height: size)
            .overlay {
                Text(Format.initials(name))
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// `+214 −38` in mono 12.
public struct DiffCounts: View {
    let additions: Int
    let deletions: Int
    var disabled = false
    var font: Font = Typo.monoSmall

    public init(_ additions: Int, _ deletions: Int, disabled: Bool = false, font: Font = Typo.monoSmall) {
        self.additions = additions
        self.deletions = deletions
        self.disabled = disabled
        self.font = font
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: "+\(additions)").foregroundStyle(disabled ? Tokens.fg3 : Tokens.green)
            Text(verbatim: "−\(deletions)").foregroundStyle(disabled ? Tokens.fg3 : Tokens.red)
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}

/// Branch chips: mono 12 on fill, r6: `fix/session-expiry` → `main`.
public struct BranchChips: View {
    let head: String
    let base: String
    var trailing: String?

    public init(head: String, base: String, trailing: String? = nil) {
        self.head = head
        self.base = base
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: 6) {
            chip(head)
            Image(systemName: "arrow.right").font(.caption2.weight(.semibold)).foregroundStyle(Tokens.fg3)
            chip(base)
            if let trailing { Text(verbatim: trailing).font(Typo.footnote).foregroundStyle(Tokens.fg2) }
        }
    }

    func chip(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Typo.monoSmall)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(Tokens.fg2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Tokens.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The app glyph on its blue tile (Welcome 100 r23, Settings 40 r11, notifications 38 r9).
public struct AppTile: View {
    let size: CGFloat
    let symbol: String

    public init(size: CGFloat, symbol: String = "arrow.triangle.pull") {
        self.size = size
        self.symbol = symbol
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Tokens.appTile)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A small 7 pt status dot (Mac connected / offline).
public struct StatusDot: View {
    let online: Bool
    public init(online: Bool) { self.online = online }
    public var body: some View {
        Circle().fill(online ? Tokens.connected : Tokens.fg3).frame(width: 7, height: 7)
    }
}
