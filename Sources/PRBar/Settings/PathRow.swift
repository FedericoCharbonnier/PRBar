import SwiftUI

/// Fila de Configuración para una ruta: etiqueta, la ruta en monoespaciada (recortada al medio, completa en el
/// tooltip), "Choose…" y opcionalmente un botón para volver al valor por defecto o quitarla.
/// La usan la carpeta local y la de worktrees (Repos) y las rutas de herramientas (General).
struct PathRow<Label: View, Status: View>: View {
    /// Botón opcional junto a "Choose…" (p. ej. "Remove", "Use Default").
    struct Reset {
        let title: String
        let action: () -> Void
    }

    /// La ruta a mostrar.
    let path: String
    /// La ruta es un valor por defecto o un aviso (va en gris).
    var isPlaceholder = false
    var reset: Reset?
    let choose: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let status: () -> Status

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(isPlaceholder ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if let reset {
                    Button(reset.title, action: reset.action)
                }
                Button("Choose…", action: choose)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                label()
                status()
            }
        }
    }
}

extension PathRow where Status == EmptyView {
    init(
        path: String, isPlaceholder: Bool = false, reset: Reset? = nil, choose: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(path: path, isPlaceholder: isPlaceholder, reset: reset, choose: choose, label: label, status: { EmptyView() })
    }
}
