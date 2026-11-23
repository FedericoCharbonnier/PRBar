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

    var body: some View {
        content
            .font(.subheadline.weight(.medium))
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
            // Violet like Claude's work in progress: green with a check read as "approved".
            Button(action: actions.open) {
                pill(fg: Theme.violet, bg: Theme.tint(Theme.violet), leading: 6) {
                    Image(systemName: "sparkles").font(.callout)
                    Text("Review ready · \(draft.keptCount)").fontWeight(.semibold)
                }
            }
            .buttonStyle(.plain)
            .help("Claude’s review is ready with \(draft.keptCount) comment\(draft.keptCount == 1 ? "" : "s"): open it to choose what to post")
            .accessibilityLabel("Review ready, \(draft.keptCount) comment\(draft.keptCount == 1 ? "" : "s")")
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

    /// Fase activa: con hover dice "Cancel"; el clic pregunta antes de cancelar (`CancellablePill`).
    private func cancellable<Icon: View>(
        label: String, tooltip: String, fg: Color = Theme.violet, bg: Color = Theme.tint(Theme.violet),
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        CancellablePill(label: label, tooltip: tooltip, fg: fg, bg: bg, job: "review",
                        accessibilityValue: accessibilityValue, cancel: actions.cancel, icon: icon)
    }

    /// "Reviewing, 2 agents" for VoiceOver (the label says what the button does: cancel).
    private var accessibilityValue: String {
        switch phase {
        case .queued?: "Queued"
        case .preparing?: "Preparing the worktree"
        case .reviewing(let agents)?: "Reviewing, \(agents) agent\(agents == 1 ? "" : "s")"
        case .filtering?: "Filtering the findings"
        default: ""
        }
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

/// The pill of a running job (Queued, Preparing, Reviewing, Analyzing…). A misclick mustn't throw away minutes of
/// Claude's work: on hover it turns red and says "Cancel", and clicking it asks first in a popover ("Keep Running"
/// is what Esc and Return do). VoiceOver reads it as "Cancel review", with the progress as its value.
struct CancellablePill<Icon: View>: View {
    let label: String
    let tooltip: String
    let fg: Color
    let bg: Color
    /// "review", "response": in "Cancel review" and the question.
    let job: String
    let accessibilityValue: String
    let cancel: () -> Void
    let icon: Icon
    @State private var hovering = false
    @State private var confirming = false

    init(label: String, tooltip: String, fg: Color, bg: Color, job: String, accessibilityValue: String,
         cancel: @escaping () -> Void, @ViewBuilder icon: () -> Icon) {
        self.label = label
        self.tooltip = tooltip
        self.fg = fg
        self.bg = bg
        self.job = job
        self.accessibilityValue = accessibilityValue
        self.cancel = cancel
        self.icon = icon()
    }

    private var armed: Bool { hovering || confirming }

    var body: some View {
        Button { confirming = true } label: {
            PhasePill(fg: armed ? Theme.redText : fg, bg: armed ? Theme.tint(Theme.red) : bg, trailing: 6) {
                icon
                // Both texts are laid out so the pill keeps its width on hover (and matches the copy `PRRowView`
                // measures).
                ZStack(alignment: .leading) {
                    Text(label).opacity(armed ? 0 : 1)
                    Text("Cancel").opacity(armed ? 1 : 0)
                }
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .padding(.leading, 2)
                    .opacity(armed ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityLabel("Cancel \(job)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Asks before cancelling")
        .popover(isPresented: $confirming, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cancel this \(job)?").font(.headline)
                Text("Claude stops and what it did so far is lost.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Keep Running") { confirming = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Cancel \(job.capitalized)", role: .destructive) {
                        confirming = false
                        cancel()
                    }
                }
            }
            .padding(14)
            .frame(width: 280)
        }
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
