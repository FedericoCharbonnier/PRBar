import AppKit
import PRBarCore
import SwiftUI

/// Lo que puede hacer el botón Merge; lo arma `PRRowView` a partir de `AppModel`.
struct MergeButtonActions {
    /// `nil` = el método por defecto.
    var merge: (MergeMethod?) -> Void
    var retry: () -> Void
    var dismiss: () -> Void
}

/// Botón Merge de una fila de Ready to Merge (spec F.3): "Merge" con el método por defecto y un chevron con los
/// métodos permitidos. Mientras mergea, "Merging…"; después, "Merged" hasta que el refresco saca la fila; con error,
/// una pastilla roja con el texto de GitHub, Retry y Dismiss. Mismo estilo que `ReviewButton`.
struct MergeButton: View {
    let phase: MergePhase?
    let options: MergeOptions
    /// Rama base, para el tooltip ("Squash and Merge into main").
    let baseRef: String
    /// Mientras se instala una actualización no empieza ningún merge (`AppModel.jobsBlockedReason`).
    var unavailableReason: String? = nil
    let actions: MergeButtonActions

    var body: some View {
        content.font(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case nil:
            HStack(spacing: 2) {
                Button("Merge") { actions.merge(nil) }
                    .help(help)
                    .accessibilityHint(help)
                Button(action: showMethodMenu) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .help("Merge with another method")
                .accessibilityLabel("Merge With…")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!options.availability.isEnabled || unavailableReason != nil)
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
                    ClosureMenuItem(title: "Retry", action: actions.retry),
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

    /// El motivo si está deshabilitado (una actualización instalándose primero); si no, "Squash and Merge into main" (y la nota de `UNSTABLE`).
    private var help: String {
        if let unavailableReason { return unavailableReason }
        if let reason = options.availability.reason { return reason }
        let text = "\(options.defaultMethod?.actionTitle ?? "Merge") into \(baseRef)"
        return options.availability.note.map { "\(text) · \($0)" } ?? text
    }

    /// Los métodos permitidos, con ✓ en el de por defecto. Un `NSMenu` (como `FailureMenu`) para que el botón
    /// conserve su estilo.
    private func showMethodMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for method in options.methods {
            let item = ClosureMenuItem(title: method.actionTitle) { actions.merge(method) }
            item.state = method == options.defaultMethod ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
