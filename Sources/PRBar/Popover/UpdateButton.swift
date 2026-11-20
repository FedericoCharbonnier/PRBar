import PRBarCore
import SwiftUI

/// The "Update" capsule in the popover's header (spec D.2): shown only while a new version is offered or being
/// installed (`UpdatePrompt`). Click → the Update window. While installing: a spinner and "Updating…", disabled.
/// `compact` is the icon-only form for a crowded header; the tooltip and VoiceOver label always carry the version.
struct UpdateButton: View {
    @ObservedObject var updates: UpdateController
    var compact = false
    let open: () -> Void

    var body: some View {
        if let prompt = UpdatePrompt(availableVersion: updates.available?.version.description,
                                     isInstalling: updates.isInstalling) {
            Button(action: open) {
                UpdateButtonLabel(prompt: prompt, compact: compact)
            }
            .buttonStyle(UpdateCapsuleStyle(compact: compact))
            .disabled(!prompt.isEnabled)
            .fixedSize()
            .help(prompt.help)
            .accessibilityLabel(prompt.help)
        }
    }
}

private struct UpdateButtonLabel: View {
    let prompt: UpdatePrompt
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            switch prompt {
            case .available:
                Image(systemName: "arrow.down.circle")
            case .installing:
                if reduceMotion {
                    // No spinning with Reduce Motion: a still symbol says the same.
                    Image(systemName: "hourglass")
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .environment(\.colorScheme, .dark)   // a light spinner on the blue fill
                        .frame(width: 12, height: 12)
                }
            }
            if !compact {
                Text(prompt.title).lineLimit(1)
            }
        }
    }
}

/// White on a blue capsule, darker than `Theme.blue` so the text keeps ≥ 4.5:1 in light and dark.
private struct UpdateCapsuleStyle: ButtonStyle {
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    static let fill = Color.dynamic(light: 0x0A64D0, dark: 0x0B66D6)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 4 : 8)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                Capsule().fill(Self.fill.opacity(isEnabled ? 1 : 0.75))
                    .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0), lineWidth: 1)
            )
            .contentShape(Capsule())
    }
}
