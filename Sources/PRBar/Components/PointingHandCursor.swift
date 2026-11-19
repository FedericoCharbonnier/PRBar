import AppKit
import SwiftUI

/// Manito sobre un `Link` real. El resto de los elementos clickeables (filas, botones, chips) conservan la
/// flecha: su fondo al pasar el mouse ya indica que se pueden tocar.
///
/// Usa un rectángulo de cursor de AppKit (`resetCursorRects`) en vez de `NSCursor.push`/`pop`: lo maneja la
/// ventana, así que no queda "pegado" si la vista desaparece o se deshabilita con el mouse encima.
private struct PointingHandArea: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.enabled = enabled
        return view
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.enabled = enabled
    }

    final class CursorRectView: NSView {
        var enabled = true {
            didSet { if enabled != oldValue { window?.invalidateCursorRects(for: self) } }
        }

        override func resetCursorRects() {
            if enabled { addCursorRect(bounds, cursor: .pointingHand) }
        }

        /// No recibe clicks: los maneja la vista de SwiftUI que está debajo.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.overlay(PointingHandArea(enabled: isEnabled).allowsHitTesting(false))
    }
}

/// Fondo de hover compartido por filas y botones de ícono.
private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    var opacity: Double
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(hovering && isEnabled ? Color.primary.opacity(opacity) : .clear)
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Solo para `Link`s (ver `PointingHandArea`).
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }

    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.row, opacity: Double = 0.07) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, opacity: opacity))
    }
}

/// Botón de solo ícono: área de 22×22, fondo al pasar el mouse y tooltip obligatorio (que es también su
/// etiqueta de accesibilidad).
struct IconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = 12
    var weight: Font.Weight = .medium
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: Theme.Radius.button)
        .help(help)
        .accessibilityLabel(help)
    }
}
