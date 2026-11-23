import PRBarCore
import SwiftUI

// Piezas visuales compartidas por las ventanas de Review e Historial.

extension Severity {
    var color: Color {
        switch self {
        case .high: Theme.red
        case .medium: Theme.orange
        case .low: Theme.blue
        }
    }

    /// Para el texto de la severidad: variantes más oscuras en modo claro (contraste sobre la tarjeta).
    var textColor: Color {
        switch self {
        case .high: Theme.redText
        case .medium: Theme.orangeText
        case .low: Theme.blueText
        }
    }
}

extension ReviewRecord.Action {
    init(_ event: ReviewEvent) {
        switch event {
        case .approve: self = .approve
        case .requestChanges: self = .requestChanges
        case .comment: self = .comment
        }
    }
}

/// Pill de color con texto corto ("Aprobado", "Sin publicar"…).
struct StatusPill: View {
    let text: String
    let color: Color
    var background: Color?
    /// En una fila seleccionada (fondo de acento) el color de estado no se lee: va en blanco.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onAccent = prominence == .increased
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(onAccent ? Color.white : color)
            .background(Capsule().fill(onAccent ? Color.white.opacity(0.2) : background ?? Theme.tint(color)))
    }

    /// Acción publicada: Aprobado (verde), Cambios pedidos (naranja) o Comentado (gris).
    static func action(_ action: ReviewRecord.Action) -> StatusPill {
        switch action {
        case .approve: StatusPill(text: "Approved", color: Theme.greenText, background: Theme.tint(Theme.green))
        case .requestChanges: StatusPill(text: "Changes requested", color: Theme.orangeText, background: Theme.tint(Theme.orange))
        case .comment, .none: StatusPill(text: "Commented", color: .secondary, background: Color.primary.opacity(0.08))
        }
    }

    /// Estado de un registro del historial.
    static func record(_ record: ReviewRecord) -> StatusPill {
        switch record.status {
        case .published: action(record.action)
        case .ready: StatusPill(text: "Not posted", color: Theme.blueText, background: Theme.tint(Theme.blue))
        case .failed: StatusPill(text: "Failed", color: Theme.redText, background: Theme.tint(Theme.red))
        case .abandoned: StatusPill(text: "Abandoned", color: .secondary, background: Color.primary.opacity(0.08))
        }
    }

    /// Estado de una corrida de "Responder": Failed, Responded o Not posted.
    static func respond(_ record: RespondRecord) -> StatusPill {
        if record.errorMessage != nil {
            return StatusPill(text: "Failed", color: Theme.redText, background: Theme.tint(Theme.red))
        }
        if record.finishedAt != nil {
            return StatusPill(text: record.draft.isCIFix ? "CI fixed" : "Responded", color: Theme.greenText, background: Theme.tint(Theme.green))
        }
        return StatusPill(text: record.draft.isCIFix ? "Not pushed" : "Not posted", color: Theme.blueText, background: Theme.tint(Theme.blue))
    }
}

/// `repo#N` en monoespaciada + link a GitHub, como encabezan las ventanas de Review e Historial.
struct PRReferenceLine: View {
    let repo: RepoRef
    let number: Int
    let url: URL
    let linkTitle: String

    init(draft: ReviewDraft, linkTitle: String) {
        self.init(repo: draft.repo, number: draft.number, url: draft.url, linkTitle: linkTitle)
    }

    init(repo: RepoRef, number: Int, url: URL, linkTitle: String) {
        self.repo = repo
        self.number = number
        self.url = url
        self.linkTitle = linkTitle
    }

    /// false in a PR window: its title bar already says `repo#N`.
    @Environment(\.showsPRReference) private var showsReference

    var body: some View {
        HStack {
            if showsReference {
                Text("\(repo.fullName) #\(number)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            ExternalLink(linkTitle, destination: url)
                .font(.callout)
        }
    }
}

extension EnvironmentValues {
    /// Whether the PR headers start with `owner/repo #N` (not in a PR window, whose title already has it).
    @Entry var showsPRReference = true
}

/// Link a una página web con la flecha ↗: sigue el color de acento del sistema y muestra la mano solo acá.
/// Es el único control "View on GitHub" de los estados finales de Review y Responder.
struct ExternalLink: View {
    let title: String
    let destination: URL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right")
                    .imageScale(.small)
                    .fontWeight(.semibold)
            }
        }
        .pointingHandCursor()
        .help(destination.absoluteString)
    }
}

/// Encabezado "✨ Resumen de Claude" + texto.
struct ClaudeSummary: View {
    var title = "Claude’s Summary"
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.violet)
            Text(summary.isEmpty ? "No summary." : summary)
                .font(.callout)
                .lineSpacing(2)
                .foregroundStyle(summary.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ReviewDates {
    /// The user's locale (`Locale.current`) for formats and ordering, but always with English wording: the app
    /// UI is English-only, so "5 minutes ago" must not come out as "hace 5 minutos" on a Spanish system.
    static var locale: Locale {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Language.Components(languageCode: "en")
        return Locale(components: components)
    }

    /// "just now", "5 minutes ago", "2 hours ago"…
    static func ago(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Today 09:58", "Yesterday 17:20" or "Nov 14" (day/month order follows the user's locale).
    static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(ClockTime.hhmm(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(ClockTime.hhmm(date))"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM y")
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}
