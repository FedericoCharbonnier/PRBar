import AppKit
import PRBarCore
import SwiftUI

/// Los registros de History de la ventana principal (reviews, respuestas, Fix CI y merges, del más nuevo al más viejo).
/// Vive en `MainWindowState`: la lista y el detalle leen lo mismo, y se recarga cuando cambia `historyRevision`.
@MainActor
final class HistoryEntries: ObservableObject {
    @Published private(set) var all: [HistoryEntry] = []
    /// false until the first load finishes (so "No History" doesn't flash while it reads the folder).
    @Published private(set) var loaded = false
    /// Records whose log file exists, checked while loading (context menus don't touch the disk).
    @Published private(set) var withLogs: Set<UUID> = []
    private var generation = 0

    /// Lists and decodes every record off the main thread; a newer reload wins over one still running.
    func reload(_ model: AppModel) async {
        generation += 1
        let current = generation
        let (history, respondHistory, mergeHistory) = (model.history, model.respondHistory, model.mergeHistory)
        let (entries, logs) = await Task.detached(priority: .userInitiated) {
            let entries = (history.all().map(HistoryEntry.review) + respondHistory.all().map(HistoryEntry.respond)
                + mergeHistory.all().map(HistoryEntry.merge))
                .sorted { $0.startedAt > $1.startedAt }
            let logs = Set(entries.filter { entry in
                let url = switch entry {
                case .review(let record): history.logURL(for: record.id)
                case .respond(let record): respondHistory.logURL(for: record.id)
                case .merge(let record): mergeHistory.logURL(for: record.id)
                }
                return FileManager.default.fileExists(atPath: url.path)
            }.map(\.id))
            return (entries, logs)
        }.value
        guard current == generation else { return }
        all = entries
        withLogs = logs
        loaded = true
    }

    /// false si el registro no está cargado todavía o lo esconden la pestaña o la búsqueda.
    func matchesFilters(_ id: UUID, _ filter: HistoryFilter, query: String) -> Bool {
        entry(id).map { $0.matches(filter) && $0.matches(query: query) } ?? false
    }

    func entry(_ id: UUID?) -> HistoryEntry? { id.flatMap { id in all.first { $0.id == id } } }

    /// Los de la pestaña de la toolbar (Responses incluye Fix CI) que encuentra la búsqueda.
    func filtered(_ filter: HistoryFilter, query: String) -> [HistoryEntry] {
        all.filter { $0.matches(filter) && $0.matches(query: query) }
    }
}

/// La columna de la lista en History (spec M.1 "History"): por día, con el chip del tipo, `repo#N`, la hora, el
/// iPhone si se pidió desde el teléfono, el título y el resultado.
struct HistoryListPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var entries: HistoryEntries
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue

    init(model: AppModel, state: MainWindowState) {
        self.model = model
        self.state = state
        entries = state.history
        reviews = model.reviews
        respond = model.respond
    }

    private var filtered: [HistoryEntry] { entries.filtered(state.historyFilter, query: state.search) }

    var body: some View {
        List(selection: Binding(get: { state.nav.place.historyRecordID }, set: { state.select(historyRecord: $0) })) {
            ForEach(DayGrouping.group(filtered, date: \.startedAt, now: Date()), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { record in
                        HistoryRow(record: record)
                            .tag(record.id)
                            .contextMenu { contextMenu(for: record) }
                    }
                }
            }
        }
        .overlay {
            if !entries.loaded {
                EmptyView()
            } else if entries.all.isEmpty {
                MessageView(icon: "clock.arrow.circlepath", title: "No History",
                            text: "Claude’s reviews, feedback responses and merges appear here when they finish.")
            } else if filtered.isEmpty {
                Text("No Results").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: model.historyRevision) { await reload() }
    }

    /// Recarga y, si no hay registro elegido (o ya no está), elige el primero.
    private func reload() async {
        await entries.reload(model)
        if entries.entry(state.nav.place.historyRecordID) == nil {
            state.select(historyRecord: entries.all.first?.id)
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: HistoryEntry) -> some View {
        switch entry {
        case .review(let record): reviewContextMenu(for: record)
        case .respond(let record): respondContextMenu(for: record)
        case .merge(let record): mergeContextMenu(for: record)
        }
    }

    @ViewBuilder
    private func respondContextMenu(for record: RespondRecord) -> some View {
        Button("Open PR on GitHub") { NSWorkspace.shared.open(record.draft.url) }
        Button("Copy PR Link") {
            Pasteboard.copy(record.draft.url.absoluteString)
        }
        if entries.withLogs.contains(record.id) {
            let logURL = model.respondHistory.logURL(for: record.id)
            Divider()
            Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        }
        if HistoryActions.canOpen(record, respond: respond) {
            Divider()
            Button("Show Response") { model.openRespond(prID: record.draft.prID) }
        }
    }

    @ViewBuilder
    private func mergeContextMenu(for record: MergeRecord) -> some View {
        Button("Open PR on GitHub") { NSWorkspace.shared.open(record.url) }
        Button("Copy PR Link") {
            Pasteboard.copy(record.url.absoluteString)
        }
        if entries.withLogs.contains(record.id) {
            let logURL = model.mergeHistory.logURL(for: record.id)
            Divider()
            Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        }
    }

    @ViewBuilder
    private func reviewContextMenu(for record: ReviewRecord) -> some View {
        Button("Open PR on GitHub") { NSWorkspace.shared.open(record.draft.url) }
        if let url = record.reviewURL {
            Button("View Review on GitHub") { NSWorkspace.shared.open(url) }
        }
        Button("Copy PR Link") {
            Pasteboard.copy(record.draft.url.absoluteString)
        }
        if entries.withLogs.contains(record.id) {
            let logURL = model.history.logURL(for: record.id)
            Divider()
            Button("Show Claude Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        }
        if HistoryActions.canReopen(record, model: model, entries: entries.all) {
            Divider()
            Button("Open to Post") { model.reopenFromHistory(record.draft) }
        }
    }
}

/// El detalle del registro elegido en History (los de siempre, solo lectura).
struct HistoryDetailPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    @ObservedObject var entries: HistoryEntries
    @ObservedObject var prStore: PRStore
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue

    init(model: AppModel, state: MainWindowState) {
        self.model = model
        self.state = state
        entries = state.history
        prStore = model.prStore
        reviews = model.reviews
        respond = model.respond
    }

    var body: some View {
        switch entries.entry(state.nav.place.historyRecordID) {
        case .review(let record)?:
            HistoryDetailView(
                record: record, canReopen: HistoryActions.canReopen(record, model: model, entries: entries.all),
                logURL: model.history.logURL(for: record.id),
                reopen: { model.reopenFromHistory(record.draft) },
                terminal: terminalButton(record.id)
            )
            .id(record.id)
        case .respond(let record)?:
            RespondHistoryDetailView(
                record: record, logURL: model.respondHistory.logURL(for: record.id),
                canOpen: HistoryActions.canOpen(record, respond: respond), open: { model.openRespond(prID: record.draft.prID) },
                terminal: terminalButton(record.id)
            )
            .id(record.id)
        case .merge(let record)?:
            MergeHistoryDetailView(record: record, logURL: model.mergeHistory.logURL(for: record.id))
                .id(record.id)
        case nil:
            MessageView(
                icon: "clock.arrow.circlepath", title: entries.all.isEmpty ? "No History" : "Select a Record",
                text: entries.all.isEmpty
                    ? "Claude’s reviews, feedback responses and merges appear here when they finish."
                    : "Its details appear here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The record's sessions while its folder is kept; nil hides the button.
    private func terminalButton(_ recordID: UUID) -> SessionTerminalButton? {
        let sessions = SessionOffer.ofRecord(recordID, retained: model.retainedWorktrees)
        return sessions.isEmpty ? nil : SessionTerminalButton(model: model, sessions: sessions, title: "Open in Terminal")
    }
}

/// Lo que se puede hacer con un registro desde History.
@MainActor
enum HistoryActions {
    /// La corrida sigue abierta en la cola (todavía no se descartó): su pestaña la muestra.
    static func canOpen(_ record: RespondRecord, respond: RespondQueue) -> Bool {
        respond.records[record.draft.prID]?.id == record.id
    }

    /// "Abrir para publicar" (§10): ver `ReviewHistory.canReopen`.
    static func canReopen(_ record: ReviewRecord, model: AppModel, entries: [HistoryEntry]) -> Bool {
        ReviewHistory.canReopen(
            record, among: entries.compactMap(\.review),
            currentHeadOid: model.prStore.snapshot?.items.first(where: { $0.id == record.draft.prID })?.pr.headOid,
            reviewActive: model.reviews.phases[record.draft.prID]?.isActive == true
        )
    }
}

/// La barra de abajo del detalle de History (spec M.1): View Claude Log y la acción del registro. GitHub is the
/// header's link (one per screen).
struct HistoryDetailBar<Trailing: View>: View {
    let logURL: URL
    @ViewBuilder let trailing: () -> Trailing
    /// Checked off the main thread when the record changes, not on every render.
    @State private var logExists = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if !NSWorkspace.shared.open(logURL) {
                    NSWorkspace.shared.activateFileViewerSelecting([logURL])
                }
            } label: {
                Label("View Claude Log", systemImage: "terminal")
            }
            .disabled(!logExists)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .windowBar()
        .task(id: logURL) {
            let url = logURL
            logExists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
        }
    }
}

/// Un registro del historial: una review de Claude o una corrida de "Responder".
enum HistoryEntry: Identifiable, Sendable {
    case review(ReviewRecord)
    case respond(RespondRecord)
    case merge(MergeRecord)

    var id: UUID {
        switch self {
        case .review(let record): record.id
        case .respond(let record): record.id
        case .merge(let record): record.id
        }
    }

    var review: ReviewRecord? {
        if case .review(let record) = self { return record }
        return nil
    }

    var repo: RepoRef {
        switch self {
        case .review(let record): record.draft.repo
        case .respond(let record): record.draft.repo
        case .merge(let record): record.repo
        }
    }

    var number: Int {
        switch self {
        case .review(let record): record.draft.number
        case .respond(let record): record.draft.number
        case .merge(let record): record.number
        }
    }

    var title: String {
        switch self {
        case .review(let record): record.draft.title
        case .respond(let record): record.draft.title
        case .merge(let record): record.title
        }
    }

    var startedAt: Date {
        switch self {
        case .review(let record): record.startedAt
        case .respond(let record): record.startedAt
        case .merge(let record): record.startedAt
        }
    }

    /// Si se pidió desde el iPhone (spec M.4): el ícono de la fila.
    var requestedOnPhone: Bool {
        switch self {
        case .review(let record): record.requestedOnPhone == true
        case .respond(let record): record.requestedOnPhone == true
        case .merge(let record): record.requestedOnPhone == true
        }
    }

    var url: URL {
        switch self {
        case .review(let record): record.draft.url
        case .respond(let record): record.draft.url
        case .merge(let record): record.url
        }
    }

    /// La pestaña de la toolbar: Responses incluye Fix CI.
    func matches(_ filter: HistoryFilter) -> Bool {
        switch (filter, self) {
        case (.all, _), (.reviews, .review), (.responds, .respond), (.merges, .merge): true
        default: false
        }
    }

    /// La búsqueda (⌘F): título, repo y `repo#N`, sin mayúsculas ni acentos.
    func matches(query: String) -> Bool {
        ListSearch.matches(fields: [title, repo.fullName, "\(repo.name)#\(number)"], number: number, query: query)
    }

    /// Claude's usage for the whole job and its chat (spec O); nil in older records.
    var usage: ClaudeUsage? {
        switch self {
        case .review(let record): record.draft.totalUsage
        case .respond(let record): record.totalUsage
        case .merge(let record): record.chat?.usage
        }
    }
}

/// Fila de la lista (spec M.1 "History"): chip del tipo, `repo#N`, hora, iPhone; título; resultado y costo.
private struct HistoryRow: View {
    let record: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                kindChip
                Text("\(record.repo.name)#\(record.number)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if record.requestedOnPhone {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Requested from iPhone")
                        .accessibilityLabel("Requested from iPhone")
                }
                Text(ClockTime.hhmm(record.startedAt))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(record.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                switch record {
                case .review(let review): StatusPill.record(review)
                case .respond(let respond): StatusPill.respond(respond)
                case .merge(let merge): StatusPill.merge(merge)
                }
                Spacer(minLength: 4)
                // Estimated cost of the job (spec O.2); older entries have none.
                if let usage = record.usage, usage.hasData {
                    Text(UsageFormat.cost(usage))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Claude: \(UsageFormat.summary(usage)). \(UsageFormat.note)")
                        .accessibilityLabel("Estimated Claude cost \(UsageFormat.cost(usage))")
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Review violeta, Respond naranja, Fix CI rojo, Merge acento.
    private var kindChip: some View {
        let (title, color): (String, Color) = switch record {
        case .review: ("Review", Theme.violet)
        case .respond(let respond) where respond.draft.isConflicts: ("Conflicts", Theme.orangeText)
        case .respond(let respond) where respond.draft.isCIFix: ("Fix CI", Theme.red)
        case .respond: ("Respond", Theme.orange)
        case .merge: ("Merge", Theme.accent)
        }
        return Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.tint(color)))
    }
}
