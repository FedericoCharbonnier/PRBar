import AppKit
import PRBarCore
import SwiftUI

/// Editor de una plantilla de mensaje de Slack: texto de varias líneas, un menú «Insert Variable» (con «Reset to
/// Default» al final) y, mientras se edita o si no es la de por defecto, una vista previa con un PR de ejemplo.
///
/// Edita una copia local (`draft`) y guarda con debounce (`saveDelay` sin teclear) y al perder el foco, así
/// `onCommit` (que reprocesa Slack) no corre en cada tecla.
struct SlackTemplateEditor: View {
    let title: String
    let kind: SlackTemplateKind
    /// Valor guardado en la configuración.
    let value: String
    /// Login de la cuenta conectada, para el autor del PR de ejemplo.
    let author: String?
    let onCommit: (String) -> Void

    static let saveDelay: Duration = .milliseconds(500)

    @State private var draft: String
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, kind: SlackTemplateKind, value: String, author: String?, onCommit: @escaping (String) -> Void) {
        self.title = title
        self.kind = kind
        self.value = value
        self.author = author
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var previewText: String { SlackTemplatePreview.text(draft, kind: kind, author: author) }

    /// La vista previa solo aparece mientras se edita o si la plantilla no es la de por defecto, para que el
    /// formulario no crezca con tres previews iguales al placeholder.
    private var showsPreview: Bool { focused || !kind.isDefault(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                templateMenu
            }

            TextField(title, text: $draft, prompt: Text(kind.defaultTemplate), axis: .vertical)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...6)
                .focused($focused)
                .accessibilityLabel("\(title) template")
                .accessibilityHint("Variables in curly braces are replaced when the message is sent")

            if isEmpty {
                Text("Empty — the default will be used: \(kind.defaultTemplate)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Empty. The default will be used: \(kind.defaultTemplate)")
            }

            if showsPreview {
                (Text("Preview: ") + Text(previewText).foregroundColor(.primary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview: \(previewText)")
            }
        }
        .onChange(of: draft) { scheduleSave() }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { flush() }
        }
        .onChange(of: value) { _, newValue in
            // Un cambio de afuera (p. ej. otra ventana) no pisa lo que se está tecleando.
            if saveTask == nil, !focused, newValue != draft { draft = newValue }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { flush() }
        }
        .onDisappear { flush() }
    }

    /// "Insert Variable": las variables, un separador y "Reset to Default" (solo si cambió).
    private var templateMenu: some View {
        Menu("Insert Variable") {
            ForEach(kind.variables, id: \.name) { variable in
                Button {
                    insert(variable.token)
                } label: {
                    Text("\(variable.token)  \(variable.summary)")
                }
                .accessibilityLabel("\(variable.summary), \(variable.token)")
            }
            Divider()
            Button("Reset to Default", action: reset)
                .disabled(kind.isDefault(draft))
                .help("Restore \(kind.defaultTemplate)")
                .accessibilityLabel("Reset \(title) to default")
        }
        .fixedSize()
        .help("Insert a variable at the cursor, or reset the template")
        .accessibilityLabel("Insert Variable into \(title)")
    }

    // MARK: - Insertar

    /// Inserta en el cursor si el campo tiene el foco (el editor de campo de AppKit conserva la selección);
    /// si no, al final del texto.
    private func insert(_ token: String) {
        if focused,
           let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isFieldEditor,
           textView.string == draft {
            textView.insertText(token, replacementRange: textView.selectedRange())
            draft = textView.string
        } else {
            draft += token
        }
    }

    private func reset() {
        draft = kind.defaultTemplate
        flush()
    }

    // MARK: - Guardar

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// Guarda ya (pérdida de foco, reset, cierre de la pestaña) y cancela el guardado pendiente.
    private func flush() {
        saveTask?.cancel()
        commit()
    }

    private func commit() {
        saveTask = nil
        if draft != value { onCommit(draft) }
    }
}
