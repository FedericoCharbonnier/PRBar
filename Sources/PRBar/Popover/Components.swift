import AppKit
import PRBarCore
import SwiftUI

struct AvatarView: View {
    let login: String
    let url: URL?
    var size: CGFloat = 22
    /// `false` in snapshot mode: always the initials, never a network request.
    static var loadsRemoteImages = true

    var body: some View {
        AsyncImage(url: Self.loadsRemoteImages ? url : nil) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Theme.avatarPalette[AvatarColor.index(for: login, paletteCount: Theme.avatarPalette.count)]
                Text(Initials.of(login))
                    .font(.system(size: size * 0.43, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct CIIcon: View {
    let state: CIState

    /// Estado del CI para el tooltip y VoiceOver (`nil` si el PR no tiene CI).
    static func label(for state: CIState) -> String? {
        switch state {
        case .success: "CI OK"
        case .failure: "CI failing"
        case .pending: "CI running"
        case .none: nil
        }
    }

    var body: some View {
        if let label = Self.label(for: state) {
            icon
                .help(label)
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .success: Image(systemName: "checkmark").foregroundStyle(Theme.green)
        case .failure: Image(systemName: "xmark").foregroundStyle(Theme.red)
        case .pending, .none: Image(systemName: "circle.fill").foregroundStyle(Theme.orange)
        }
    }
}

struct FeedbackLabel: View {
    let summary: FeedbackSummary

    static func text(for summary: FeedbackSummary) -> String {
        if summary.changesRequested { return "Changes requested" }
        return summary.count == 1 ? "1 comment" : "\(summary.count) comments"
    }

    var body: some View {
        if summary.changesRequested {
            Label(Self.text(for: summary), systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.orangeText)
        } else {
            Label(Self.text(for: summary), systemImage: "text.bubble")
                .foregroundStyle(.secondary)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    let count: Int
    let collapsed: Bool
    var dimmed = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title).font(.callout.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 15)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(dimmed ? .secondary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.row, opacity: 0.05)
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .help(collapsed ? "Show \(title)" : "Hide \(title)")
        .accessibilityLabel([title, subtitle, count == 1 ? "1 PR" : "\(count) PRs"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(collapsed ? "collapsed" : "expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

struct MessageView: View {
    let icon: String
    var iconColor: Color = .secondary
    let title: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var actionDisabled = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(iconColor)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, 10).disabled(actionDisabled)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }
}

struct ErrorBanner: View {
    let messages: [String]
    /// Margen lateral: 10 en el popover, 20 en Configuración (el de los `Form` agrupados).
    var horizontalInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.redText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.red)))
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, 4)
    }
}

/// Problemas del último refresco, agrupados por cuenta.
struct IssuesBanner: View {
    let groups: [(account: String, issues: [RefreshIssue])]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.account) { group in
                VStack(alignment: .leading, spacing: 3) {
                    if groups.count > 1 {
                        Text(group.account).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(group.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.redText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if group.issues.contains(where: \.requiresLogin) {
                        CopyableCommand("gh auth login --hostname github.com")
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.tint(Theme.red)))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.subheadline, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { copied = false }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(Color.primary.opacity(0.06)))
    }
}
