import SwiftUI
import PRBarMobileCore

/// The top row of detail screens: glass circle buttons left and right, an optional centered title.
public struct NavHeader<Leading: View, Center: View, Trailing: View>: View {
    let leading: Leading
    let center: Center
    let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center,
                @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    public var body: some View {
        ZStack {
            center.frame(maxWidth: 220)
            HStack {
                leading
                Spacer()
                trailing
            }
        }
        .frame(minHeight: Metrics.touch)
        .padding(.horizontal, Metrics.gutter)
    }
}

extension NavHeader where Center == EmptyView {
    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.init(leading: leading, center: { EmptyView() }, trailing: trailing)
    }
}

/// Mac pill (Home, Activity): glass capsule with the laptop, the Mac's name and its link state.
public struct MacPill: View {
    let name: String
    let status: String
    let online: Bool
    let accessibility: String

    public init(name: String, status: String, online: Bool, accessibility: String) {
        self.name = name
        self.status = status
        self.online = online
        self.accessibility = accessibility
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Tokens.fill).frame(width: 32, height: 32)
                .overlay { Image(systemName: "laptopcomputer").font(.system(size: 14, weight: .medium)).foregroundStyle(Tokens.fg) }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Tokens.fg).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(online: online)
                    Text(status).font(Typo.caption).foregroundStyle(Tokens.fg2).lineLimit(1)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: Metrics.touch)
        .glassCapsule()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }
}

/// "To Review 2 ⌄": the whole header toggles its section.
public struct SectionHeader: View {
    let title: String
    let count: Int
    let expanded: Bool
    var dimmed = false
    let action: () -> Void

    public init(title: String, count: Int, expanded: Bool, dimmed: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.expanded = expanded
        self.dimmed = dimmed
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Typo.headline).foregroundStyle(dimmed ? Tokens.fg2 : Tokens.fg)
                Text("\(count)").font(.system(size: 15)).foregroundStyle(Tokens.fg2)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Tokens.fg3)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: Metrics.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count), \(expanded ? "expanded" : "collapsed")")
    }
}

/// Pinned bottom bar over a fade: secondary glass capsule + primary accent capsule (`ios/DESIGN.md` § Bottom action bar).
public struct BottomActionBar<Secondary: View, Primary: View>: View {
    let secondary: Secondary
    let primary: Primary

    public init(@ViewBuilder secondary: () -> Secondary, @ViewBuilder primary: () -> Primary) {
        self.secondary = secondary()
        self.primary = primary()
    }

    public var body: some View {
        HStack(spacing: 12) {
            secondary
            primary
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 40)
        .padding(.bottom, 30)
        .background(alignment: .bottom) { FadeBackground().allowsHitTesting(false) }
    }
}

/// The bg-colored fade under the bottom bar (150 pt).
struct FadeBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let bg = Tokens.bg.color(scheme)
        LinearGradient(colors: [bg.opacity(0), bg.opacity(0.92), bg], startPoint: .top, endPoint: .bottom)
            .frame(height: 150)
    }
}

/// Secondary capsule of the bottom bar (glass, 54 pt).
public struct GlassCapsuleButton: View {
    let title: String
    var symbol: String?
    var tint: Token = Tokens.fg
    var enabled = true
    let action: () -> Void

    public init(_ title: String, symbol: String? = nil, tint: Token = Tokens.fg, enabled: Bool = true,
                action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(Typo.headline)
            .foregroundStyle(enabled ? tint : Tokens.fg3)
            .padding(.horizontal, 22)
            .frame(minHeight: Metrics.bottomBarButton)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .disabled(!enabled)
    }
}

/// A large green/accent result circle (posted, merged, paired).
public struct ResultBadge: View {
    let symbol: String
    let size: CGFloat
    var fill: Token = Tokens.green

    public init(symbol: String, size: CGFloat, fill: Token = Tokens.green) {
        self.symbol = symbol
        self.size = size
        self.fill = fill
    }

    public var body: some View {
        Circle().fill(fill).frame(width: size, height: size)
            .overlay { Image(systemName: symbol).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

/// An inline error/notice banner (a failed action's message).
public struct NoticeBanner: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tone: Token = Tokens.orange
    var background: Token = Tokens.orangebg

    public init(_ text: String, symbol: String = "exclamationmark.triangle.fill", tone: Token = Tokens.orange,
                background: Token = Tokens.orangebg) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.background = background
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tone)
            Text(verbatim: text).font(Typo.body).foregroundStyle(Tokens.fg)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
