import AppKit
import PRBarCore
import SwiftUI

/// Lo que puede hacer el botón Responder; lo arma `PRRowView` a partir de `AppModel`.
struct RespondButtonActions {
    var start: () -> Void
    var cancel: () -> Void
    var open: () -> Void
    var retry: () -> Void
    var dismiss: () -> Void
}

/// Botón Responder de una fila de "Mis PRs con feedback", con el progreso en vivo. Mismo estilo que
/// `ReviewButton`: siempre un `Button` real, hermano (no hijo) del botón de la fila.
struct RespondButton: View {
    let phase: RespondPhase?
    let runningTests: Bool
    /// Por qué no se puede responder (sin carpeta local); `nil` = se puede.
    let unavailableReason: String?
    /// Hay un registro abierto (la ventana tiene algo que mostrar).
    let hasRecord: Bool
    let actions: RespondButtonActions

    var body: some View {
        content
            .font(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case nil:
            Button("Respond", action: actions.start)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(unavailableReason != nil)
                .help(unavailableReason ?? "Respond to this PR’s feedback with Claude")
                .accessibilityHint(unavailableReason ?? "Claude analyzes the unresolved comments")
        case .queued?:
            cancellable(label: "Queued", tooltip: "Queued · click to cancel", fg: .secondary, bg: Color.primary.opacity(0.06)) {
                Image(systemName: "pause.fill").font(.system(size: 9))
            }
        case .preparing?:
            cancellable(label: "Preparing…", tooltip: "Preparing the worktree · click to cancel") {
                Image(systemName: "hourglass").font(.system(size: 10, weight: .semibold))
            }
        case .analyzing(let agents)?:
            cancellable(label: "Analyzing…", tooltip: analyzingTooltip(agents)) {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            }
        case .implementing(let done, let total)?:
            cancellable(label: "Implementing \(min(done + 1, max(total, 1)))/\(max(total, 1))…",
                        tooltip: "Claude is implementing the fixes · click to cancel") {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            }
        case .ready(let draft)?:
            openPill(label: "\(draft.items.count) to review", icon: "checkmark.circle.fill",
                     tooltip: "Open the analysis to choose what to fix and what to reply to")
        case .readyToPush?:
            if runningTests {
                Button(action: actions.open) {
                    PhasePill(fg: Theme.violet, bg: Theme.tint(Theme.violet)) {
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                        Text("Running tests…")
                    }
                }
                .buttonStyle(.plain)
                .help("Open the window to see the tests")
            } else {
                openPill(label: "Ready to push", icon: "arrow.up.circle.fill",
                         tooltip: "Open to review the diff and push")
            }
        case .pushing?:
            Button(action: actions.open) {
                PhasePill(fg: Theme.violet, bg: Theme.tint(Theme.violet)) {
                    ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                    Text("Posting…")
                }
            }
            .buttonStyle(.plain)
            .help("Pushing and posting the replies")
        case .done?:
            openPill(label: "Responded", icon: "checkmark.seal.fill", tooltip: "See what was pushed and what was replied")
        case .failed(let message, let logURL)?:
            Button {
                showFailureMenu(message: message, logURL: logURL)
            } label: {
                PhasePill(fg: Theme.redText, bg: Theme.tint(Theme.red), leading: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                    Text("Error")
                }
            }
            .buttonStyle(.plain)
            .help(message)
            .accessibilityLabel("Respond failed")
            .accessibilityHint("Opens a menu to show the log, retry, or dismiss")
        }
    }

    private func analyzingTooltip(_ agents: Int) -> String {
        agents == 0
            ? "Claude is analyzing the comments · click to cancel"
            : "\(agents) agent\(agents == 1 ? "" : "s") · click to cancel"
    }

    private func openPill(label: String, icon: String, tooltip: String) -> some View {
        Button(action: actions.open) {
            PhasePill(fg: Theme.greenText, bg: Theme.tint(Theme.green), leading: 6) {
                Image(systemName: icon).font(.callout)
                Text(label).fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    /// Fase activa: con hover dice "Cancel"; el clic pregunta antes de cancelar (`CancellablePill`).
    private func cancellable<Icon: View>(
        label: String, tooltip: String, fg: Color = Theme.violet, bg: Color = Theme.tint(Theme.violet),
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        CancellablePill(label: label, tooltip: tooltip, fg: fg, bg: bg, job: "response",
                        accessibilityValue: accessibilityValue, cancel: actions.cancel, icon: icon)
    }

    /// "Analyzing, 2 agents" for VoiceOver (the label says what the button does: cancel).
    private var accessibilityValue: String {
        switch phase {
        case .queued?: "Queued"
        case .preparing?: "Preparing the worktree"
        case .analyzing(let agents)?: agents == 0 ? "Analyzing" : "Analyzing, \(agents) agent\(agents == 1 ? "" : "s")"
        case .implementing(let done, let total)?: "Implementing fix \(min(done + 1, max(total, 1))) of \(max(total, 1))"
        default: ""
        }
    }

    /// "Show Log / Retry / Dismiss". If fixes or replies are already in play, "Open" shows the window
    /// (posting is retried there without losing anything).
    private func showFailureMenu(message: String, logURL: URL?) {
        var items: [NSMenuItem] = []
        if hasRecord { items.append(ClosureMenuItem(title: "Open", action: actions.open)) }
        items.append(ClosureMenuItem(title: "Retry", action: actions.retry))
        FailureMenu.show(message: message, logURL: logURL, items: items, dismiss: actions.dismiss)
    }
}
