import AppKit
import SwiftUI

enum Theme {
    static let accent = Color.dynamic(light: 0x2D4EFF, dark: 0x4D6BFF)
    static let green = Color.dynamic(light: 0x1A9E46, dark: 0x32D35A)
    static let orange = Color.dynamic(light: 0xD46B00, dark: 0xFF9F0A)
    static let red = Color.dynamic(light: 0xD92D20, dark: 0xFF5A50)
    static let violet = Color.dynamic(light: 0x8B3FD9, dark: 0xC88BFF)
    static let blue = Color.dynamic(light: 0x0A72E8, dark: 0x47A0FF)

    /// Variantes para texto de estado: en modo claro son más oscuras que `green`/`orange`/`red` (que quedan
    /// para íconos y puntos) para llegar al contraste mínimo sobre fondo blanco o sobre su propio tinte.
    static let greenText = Color(nsColor: AppKitColors.greenText)
    static let orangeText = Color.dynamic(light: 0xA85400, dark: 0xFF9F0A)
    static let redText = Color(nsColor: AppKitColors.redText)
    static let blueText = Color.dynamic(light: 0x0A5FC4, dark: 0x47A0FF)

    /// Los mismos colores de texto como `NSColor`, para vistas AppKit (p. ej. el diff).
    enum AppKitColors {
        static let greenText = NSColor.dynamic(light: 0x157F3A, dark: 0x32D35A)
        static let redText = NSColor.dynamic(light: 0xC0261A, dark: 0xFF5A50)
    }

    static func tint(_ color: Color) -> Color { color.opacity(0.16) }

    static let avatarPalette: [Color] = [0xC2410C, 0x0E7490, 0x6D28D9, 0x15803D, 0xA16207, 0xBE185D, 0x1D4ED8].map(Color.init(hex:))

    enum Radius {
        static let popover: CGFloat = 12
        static let card: CGFloat = 8
        static let row: CGFloat = 7
        static let button: CGFloat = 6
    }

    static let popoverWidth: CGFloat = 380
    static let popoverMaxHeight: CGFloat = 640

    /// Medidas fijas de la ventana principal (spec M.1). El ancho de la lista depende de la ventana: `MainLayout`
    /// de PRBarCore.
    enum MainLayout {
        static let defaultSize = NSSize(width: 1280, height: 800)
        static let minSize = NSSize(width: 960, height: 600)
        static let sidebarWidth: CGFloat = 236
        /// The chat inspector: below 340 pt its words hyphenate and the rule card's buttons truncate. It opens at its
        /// minimum so the detail keeps room at the default window size; it can be dragged wider.
        static let inspectorMinWidth: CGFloat = 340
        static let inspectorWidth: CGFloat = 340
        static let searchWidth: CGFloat = 170
        static let titleColumnWidth: CGFloat = 220
        static let mergeSideColumnWidth: CGFloat = 240
    }
}

/// Borde fino de una tarjeta. Con "Aumentar contraste" usa el color de separador del sistema.
private struct CardBorder: ViewModifier {
    let cornerRadius: CGFloat
    let opacity: Double
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(contrast == .increased ? Color(nsColor: .separatorColor) : Color.primary.opacity(opacity))
        )
    }
}

extension View {
    /// Anillo de foco del sistema (sigue el color de acento) alrededor de un editor propio, como el de un
    /// `NSTextField` con borde.
    func focusRing(_ isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.button) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 1.5)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        )
    }

    func cardBorder(cornerRadius: CGFloat = Theme.Radius.card, opacity: Double = 0.1) -> some View {
        modifier(CardBorder(cornerRadius: cornerRadius, opacity: opacity))
    }

    /// La barra inferior de un pane (Post Review, Push…): fondo opaco de ventana con un separador arriba. Va debajo del
    /// `ScrollView` en un `VStack` (no en `safeAreaInset`): el contenido termina arriba de la barra, no por debajo.
    func windowBar() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
    }

    /// Pone `bar` (una `windowBar()`) debajo de la vista, no encima de su scroll.
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(spacing: 0) {
            self
            bar()
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor.dynamic(light: light, dark: dark))
    }
}

extension NSColor {
    /// Color sRGB que cambia con la apariencia (clara u oscura).
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}
