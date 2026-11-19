import PRBarCore
import SwiftUI

/// Fila al pie del popover: "PRBar 1.3.0 is available — Update…" con punto azul (spec D.2), o "Updating PRBar…"
/// mientras se instala. No se muestra si no hay nada.
struct UpdateRow: View {
    @ObservedObject var updates: UpdateController
    let open: () -> Void

    var body: some View {
        if let text {
            VStack(spacing: 0) {
                Divider()
                Button(action: open) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.blue)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(text).font(.callout).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight()
                .accessibilityLabel(text)
            }
        }
    }

    private var text: String? {
        if updates.isInstalling { return "Updating PRBar…" }
        return updates.available.map { "PRBar \($0.version) is available — Update…" }
    }
}
