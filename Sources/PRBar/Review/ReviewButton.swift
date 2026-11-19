import AppKit
import PRBarCore
import SwiftUI

/// Lo que puede hacer el botón Review; lo arma `PRRowView` a partir de `AppModel`.
struct ReviewButtonActions {
    var start: () -> Void
    var cancel: () -> Void
    var open: () -> Void
    var retry: () -> Void
    var dismiss: () -> Void
}

/// Botón Review de una fila, con el progreso de la review en vivo (ver `docs/design/ReviewButtons.dc.html`).
/// Es siempre un `Button` real, hermano (no hijo) del botón de la fila.
struct ReviewButton: View {
    let phase: ReviewPhase?
    /// Why a review can't start (an update is being installed); `nil` = it can.
    var unavailableReason: String? = nil
    let actions: ReviewButtonActions
    @State private var hovering = false

    var body: some View {
        content
            .font(.subheadline.weight(.medium))
            .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case nil:
            Button("Review", action: actions.start)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(unavailableReason != nil)
                .help(unavailableReason ?? "Review this PR with Claude")
        case .queued?:
            cancellable(label: "Queued", tooltip: "Queued · click to cancel", fg: .secondary, bg: Color.primary.opacity(0.06)) {
                Image(systemName: "pause.fill").font(.system(size: 9))
            }
        case .preparing?:
            cancellable(label: "Preparing…", tooltip: "Preparing the worktree · click to cancel") {
                Image(systemName: "hourglass").font(.system(size: 10, weight: .semibold))
            }
        case .reviewing(let agents)?:
            cancellable(label: "Reviewing…", tooltip: "\(agents) agent\(agents == 1 ? "" : "s") · click to cancel") {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            }
        case .filtering?:
            cancellable(label: "Filtering…", tooltip: "Filtering the findings · click to cancel") {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .bold))
            }
        case .ready(let draft)?:
            Button(action: actions.open) {
                pill(fg: Theme.greenText, bg: Theme.tint(Theme.green), leading: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.callout)
                    Text("\(draft.keptCount) comment\(draft.keptCount == 1 ? "" : "s")").fontWeight(.semibold)
                }
            }
            .buttonStyle(.plain)
            .help("Open the review to choose comments and post")
        case .failed(let message, let logURL)?:
            Button {
                showFailureMenu(message: message, logURL: logURL)
            } label: {
                pill(fg: Theme.redText, bg: Theme.tint(Theme.red), leading: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                    Text("Error")
                }
            }
            .buttonStyle(.plain)
            .help(message)
        case .published(let url)?:
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                pill(fg: Theme.greenText, bg: Theme.tint(Theme.green), leading: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.callout)
                    Text("Posted")
                }
            }
            .buttonStyle(.plain)
            .help("View the review on GitHub")
        }
    }

    /// Fase activa: el click cancela; con hover aparece la ✕ que lo indica (su lugar está siempre reservado).
    private func cancellable<Icon: View>(
        label: String, tooltip: String, fg: Color = Theme.violet, bg: Color = Theme.tint(Theme.violet),
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        let icon = icon()
        return Button(action: actions.cancel) {
            pill(fg: fg, bg: bg, trailing: 6) {
                icon
                Text(label)
                // The ✕ slot is always reserved (drawn transparent) so the pill keeps its width on hover and
                // the copy `PRRowView` measures matches the visible one.
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .padding(.leading, 2)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        // La ✕ solo se ve con el mouse encima: VoiceOver ofrece cancelar como acción.
        .accessibilityLabel(label)
        .accessibilityHint("Activate to cancel the review")
        .accessibilityAction(named: "Cancel Review", actions.cancel)
    }

    private func pill<Content: View>(
        fg: Color, bg: Color, leading: CGFloat = 8, trailing: CGFloat = 8, @ViewBuilder content: () -> Content
    ) -> some View {
        PhasePill(fg: fg, bg: bg, leading: leading, trailing: trailing, content: content)
    }

    private func showFailureMenu(message: String, logURL: URL?) {
        FailureMenu.show(message: message, logURL: logURL, items: [
            ClosureMenuItem(title: "Retry", action: actions.retry),
        ], dismiss: actions.dismiss)
    }
}

/// Etiqueta en forma de pastilla de los botones de fase (Review, Responder).
struct PhasePill<Content: View>: View {
    let fg: Color
    let bg: Color
    let leading: CGFloat
    let trailing: CGFloat
    let content: Content

    init(fg: Color, bg: Color, leading: CGFloat = 8, trailing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.fg = fg
        self.bg = bg
        self.leading = leading
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) { content }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(height: 20)
            .foregroundStyle(fg)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.button).fill(bg))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
    }
}

/// Menú de una corrida fallida. Es un `NSMenu` en la posición del mouse para que la etiqueta conserve
/// su estilo (un `Menu` de SwiftUI en macOS la reemplaza por un pop-up button estándar).
/// El primer ítem (deshabilitado) es el mensaje de error, recortado; el texto completo queda en su tooltip.
/// Después van "Ver log", `items` y "Descartar".
enum FailureMenu {
    static func show(message: String, logURL: URL?, items: [NSMenuItem], dismiss: @escaping () -> Void) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let singleLine = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        let error = NSMenuItem(
            title: singleLine.count > 120 ? String(singleLine.prefix(119)) + "…" : singleLine, action: nil, keyEquivalent: ""
        )
        error.isEnabled = false
        error.toolTip = message
        menu.addItem(error)
        menu.addItem(.separator())
        let log = ClosureMenuItem(title: "Show Log") { if let logURL { NSWorkspace.shared.open(logURL) } }
        log.isEnabled = logURL != nil
        menu.addItem(log)
        items.forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Dismiss", action: dismiss))
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
