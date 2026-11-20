import AppKit
import PRBarCore
import SwiftUI

/// Lo que puede hacer el botón "Merge…"; lo arma `PRRowView` a partir de `AppModel`.
struct MergeButtonActions {
    /// Abre la ventana de Merge (spec G.1).
    var open: () -> Void
    var dismiss: () -> Void
}

/// Botón de una fila de Ready to Merge (spec G.1): "Merge…" abre la ventana de Merge, que muestra el PR y ofrece el
/// método y el merge. Mientras mergea, "Merging…"; después, "Merged" hasta que el refresco saca la fila; con error,
/// una pastilla roja con el texto de GitHub, "Merge…" (la ventana, con Retry) y Dismiss. Mismo estilo que
/// `ReviewButton`.
struct MergeButton: View {
    let phase: MergePhase?
    let availability: MergeAvailability
    let actions: MergeButtonActions

    var body: some View {
        content.font(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case nil:
            Button("Merge…", action: actions.open)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(help)
                .accessibilityHint(help)
        case .merging?:
            PhasePill(fg: Theme.violet, bg: Theme.tint(Theme.violet)) {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                Text("Merging…")
            }
            .help("Merging on GitHub")
            .accessibilityLabel("Merging")
        case .merged?:
            PhasePill(fg: Theme.greenText, bg: Theme.tint(Theme.green), leading: 6) {
                Image(systemName: "checkmark.circle.fill").font(.callout)
                Text("Merged").fontWeight(.semibold)
            }
            .help("Merged on GitHub")
            .accessibilityLabel("Merged")
        case .failed(_, let error)?:
            let message = error.localizedDescription
            Button {
                FailureMenu.show(message: message, logURL: AppPaths.logFile, items: [
                    ClosureMenuItem(title: "Merge…", action: actions.open),
                ], dismiss: actions.dismiss)
            } label: {
                PhasePill(fg: Theme.redText, bg: Theme.tint(Theme.red), leading: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                    Text("Error")
                }
            }
            .buttonStyle(.plain)
            .help(message)
            .accessibilityLabel("Merge failed: \(message)")
        }
    }

    /// Por qué todavía no se puede (la ventana lo explica), o qué hace el botón.
    private var help: String {
        if let reason = availability.reason { return "\(reason) · Opens the PR’s summary" }
        if let note = availability.note { return "Review the PR and merge it · \(note)" }
        return "Review the PR and merge it"
    }
}

/// Línea de estado de una fila de Ready to Merge: lista, lista con aviso, o por qué todavía no se puede.
struct MergeStatusLabel: View {
    let availability: MergeAvailability

    static func text(for availability: MergeAvailability) -> String {
        availability.reason ?? availability.note ?? "Approved · ready to merge"
    }

    var body: some View {
        if let reason = availability.reason {
            Label(reason, systemImage: reason == MergePolicy.checking ? "clock" : "lock")
                .foregroundStyle(.secondary)
        } else if let note = availability.note {
            Label(note, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.orangeText)
        } else {
            Label(Self.text(for: availability), systemImage: "checkmark.seal")
                .foregroundStyle(Theme.greenText)
        }
    }
}
