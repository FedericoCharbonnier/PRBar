import SwiftUI
import PRBarMobileCore

/// The PR row (`ios/DESIGN.md` § PR row).
public struct PRRowView: View {
    let row: HomeModel.Row
    let disabled: Bool
    let onAction: (HomeModel.Action) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(row: HomeModel.Row, disabled: Bool, onAction: @escaping (HomeModel.Action) -> Void) {
        self.row = row
        self.disabled = disabled
        self.onAction = onAction
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Metrics.rowGap) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: row.title)
                        .font(Typo.bodyBold)
                        .foregroundStyle(disabled ? Tokens.fg2 : Tokens.fg)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(row.age).font(Typo.footnote).foregroundStyle(disabled ? Tokens.fg3 : Tokens.fg2)
                }
                Text(verbatim: row.meta)
                    .font(Typo.footnote)
                    .foregroundStyle(disabled ? Tokens.fg3 : Tokens.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let status = row.status {
                    StatusLine(status: status, disabled: disabled)
                }
                bottomLine.padding(.top, 2)
            }
        }
        .padding(Metrics.rowPadding)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    @ViewBuilder var leading: some View {
        switch row.leading {
        case .avatar:
            Avatar(name: row.authorName, login: row.pr.author, disabled: disabled)
        case .state(let icon):
            StateCircle(icon: icon, disabled: disabled)
        }
    }

    @ViewBuilder var bottomLine: some View {
        let counts = DiffCounts(row.pr.additions, row.pr.deletions, disabled: disabled)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                counts
                if let action = row.action { ActionCapsule(action: action, disabled: disabled) { onAction(action) } }
            }
        } else {
            HStack {
                counts
                Spacer()
                if let action = row.action { ActionCapsule(action: action, disabled: disabled) { onAction(action) } }
            }
        }
    }
}

/// My PRs' leading icon on a tinted circle.
public struct StateCircle: View {
    let icon: HomeModel.StateIcon
    var disabled = false

    public init(icon: HomeModel.StateIcon, disabled: Bool = false) {
        self.icon = icon
        self.disabled = disabled
    }

    var symbol: String {
        switch icon {
        case .feedback: "text.bubble"
        case .ready: "checkmark"
        case .ciFailing: "xmark"
        case .waiting: "hourglass"
        }
    }

    var colors: (Token, Token) {
        switch icon {
        case .feedback: (Tokens.orange, Tokens.orangebg)
        case .ready: (Tokens.green, Tokens.greenbg)
        case .ciFailing: (Tokens.red, Tokens.redbg)
        case .waiting: (Tokens.fg2, Tokens.fill)
        }
    }

    public var body: some View {
        Circle().fill(disabled ? Tokens.fill : colors.1).frame(width: 34, height: 34)
            .overlay {
                Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(disabled ? Tokens.fg3 : colors.0)
            }
            .accessibilityHidden(true)
    }
}

/// The colored status line under the meta line.
public struct StatusLine: View {
    let status: HomeModel.Status
    var disabled = false

    public init(status: HomeModel.Status, disabled: Bool = false) {
        self.status = status
        self.disabled = disabled
    }

    var style: (String, Token) {
        switch status {
        case .working: ("terminal", Tokens.violet)
        case .changesRequested: ("exclamationmark.triangle.fill", Tokens.orange)
        case .approved: ("checkmark.circle.fill", Tokens.green)
        case .checksFailed: ("xmark.octagon.fill", Tokens.red)
        }
    }

    public var body: some View {
        Label {
            Text(verbatim: status.text)
        } icon: {
            Image(systemName: style.0)
        }
        .font(Typo.footnoteMedium)
        .foregroundStyle(disabled ? Tokens.fg3 : style.1)
        .labelStyle(TightLabel())
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// The row's trailing action capsule (30 pt, 14 semibold).
public struct ActionCapsule: View {
    let action: HomeModel.Action
    let disabled: Bool
    let tap: () -> Void

    public init(action: HomeModel.Action, disabled: Bool, tap: @escaping () -> Void) {
        self.action = action
        self.disabled = disabled
        self.tap = tap
    }

    var colors: (AnyShapeStyle, AnyShapeStyle) {
        if disabled { return (AnyShapeStyle(Tokens.fg3), AnyShapeStyle(Tokens.fill)) }
        switch action {
        case .review, .respond, .reviewReady: return (AnyShapeStyle(Tokens.accentfg), AnyShapeStyle(Tokens.accentbg))
        case .reviewing, .responding, .fixing: return (AnyShapeStyle(Tokens.violet), AnyShapeStyle(Tokens.violetbg))
        case .comments: return (AnyShapeStyle(Tokens.green), AnyShapeStyle(Tokens.greenbg))
        case .merge: return (AnyShapeStyle(Color.white), AnyShapeStyle(Tokens.accent))
        case .fixCI: return (AnyShapeStyle(Tokens.red), AnyShapeStyle(Tokens.redbg))
        }
    }

    public var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if action.isRunning && !disabled { Spinner(size: 12) }
                if case .comments = action { Image(systemName: "checkmark.circle.fill") }
                Text(action.title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(colors.0)
            .padding(.horizontal, 12)
            .frame(height: Metrics.capsule)
            .background(colors.1, in: Capsule())
            .frame(minHeight: Metrics.touch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(disabled ? "\(action.title), unavailable" : action.title)
    }
}

/// `home:offline`'s card.
public struct OfflineCard: View {
    let title: String
    let message: String
    let tryAgain: () -> Void

    public init(title: String, message: String, tryAgain: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.tryAgain = tryAgain
    }

    public var body: some View {
        VStack(spacing: 12) {
            Circle().fill(Tokens.fill).frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "laptopcomputer").font(.system(size: 34)).foregroundStyle(Tokens.fg2)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "moon.zzz").font(.system(size: 20, weight: .semibold)).foregroundStyle(Tokens.fg2)
                        .offset(x: 6, y: -4)
                }
                .accessibilityHidden(true)
            Text(verbatim: title).font(Typo.headline).foregroundStyle(Tokens.fg).multilineTextAlignment(.center)
            Text(verbatim: message).font(Typo.body).foregroundStyle(Tokens.fg2).multilineTextAlignment(.center)
            SymbolCapsule("Try Again", symbol: "arrow.clockwise", action: tryAgain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Metrics.groupRadius, style: .continuous))
    }
}

/// High / Medium / Low pill (dot + label, 22 pt).
public struct SeverityPill: View {
    let label: String
    let level: Int

    public init(label: String, level: Int) {
        self.label = label
        self.level = level
    }

    var colors: (Token, Token) {
        switch level {
        case 0: (Tokens.red, Tokens.redbg)
        case 1: (Tokens.orange, Tokens.orangebg)
        default: (Tokens.blue, Tokens.bluebg)
        }
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(colors.0).frame(width: 6, height: 6)
            Text(label).font(Typo.footnoteBold)
        }
        .foregroundStyle(colors.0)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(colors.1, in: Capsule())
    }
}
