import AppKit
import PRBarCore
import SwiftUI

/// Ventana de Historial: lista de reviews y de respuestas al feedback a la izquierda y el detalle (solo lectura)
/// a la derecha (ver `docs/design/HistoryWindow.dc.html`).
struct HistoryWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue

    @State private var records: [HistoryEntry] = []
    @State private var selection: UUID?
    @State private var query = ""
    @State private var repoFilter: String?

    static let size = NSSize(width: 760, height: 520)

    init(model: AppModel) {
        self.model = model
        prStore = model.prStore
        reviews = model.reviews
        respond = model.respond
    }

    private var repos: [String] { Array(Set(records.map(\.repo.fullName))).sorted() }

    private var filtered: [HistoryEntry] {
        records.filter { record in
            (repoFilter == nil || record.repo.fullName == repoFilter) && HistorySearch.matches(record, query: query)
        }
    }

    private var selectedRecord: HistoryEntry? { records.first { $0.id == selection } }

    // La ventana toma la barra de herramientas, el título y la búsqueda de SwiftUI
    // (`WindowOptions.bridgesToolbar`).
    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 400)
        } detail: {
            switch selectedRecord {
            case .review(let record)?:
                HistoryDetailView(
                    record: record, canReopen: canReopen(record), logURL: model.history.logURL(for: record.id),
                    reopen: { model.reopenFromHistory(record.draft) }
                )
            case .respond(let record)?:
                RespondHistoryDetailView(
                    record: record, logURL: model.respondHistory.logURL(for: record.id),
                    canOpen: canOpen(record), open: { model.openRespond(prID: record.draft.prID) }
                )
            case .merge(let record)?:
                MergeHistoryDetailView(record: record, logURL: model.mergeHistory.logURL(for: record.id))
            case nil:
                MessageView(
                    icon: "clock.arrow.circlepath", title: records.isEmpty ? "No History" : "Select a Record",
                    text: records.isEmpty
                        ? "Claude’s reviews, feedback responses and merges appear here when they finish."
                        : "Its details appear here."
                )
                .frame(maxHeight: .infinity)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search by title, repo, or number")
        .navigationTitle("History")
        .navigationSubtitle("\(records.count) record\(records.count == 1 ? "" : "s") · read-only")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Repo", selection: $repoFilter) {
                    Text("All Repos").tag(String?.none)
                    if !repos.isEmpty { Divider() }
                    ForEach(repos, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Filter by repo")
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .onAppear {
            reload()
            applySelectionRequest()
        }
        .onChange(of: model.historyRevision) { reload() }
        .onChange(of: model.historySelectionRequest) { applySelectionRequest() }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(HistoryGroup.group(filtered), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.records) { record in
                        HistoryRow(record: record)
                            .tag(record.id)
                            .contextMenu { contextMenu(for: record) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if filtered.isEmpty && !records.isEmpty {
                Text("No Results").font(.callout).foregroundStyle(.secondary)
            }
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.draft.url.absoluteString, forType: .string)
        }
        let logURL = model.respondHistory.logURL(for: record.id)
        if FileManager.default.fileExists(atPath: logURL.path) {
            Divider()
            Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        }
        if canOpen(record) {
            Divider()
            Button("Show Response") { model.openRespond(prID: record.draft.prID) }
        }
    }

    @ViewBuilder
    private func mergeContextMenu(for record: MergeRecord) -> some View {
        Button("Open PR on GitHub") { NSWorkspace.shared.open(record.url) }
        Button("Copy PR Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.url.absoluteString, forType: .string)
        }
        let logURL = model.mergeHistory.logURL(for: record.id)
        if FileManager.default.fileExists(atPath: logURL.path) {
            Divider()
            Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        }
    }

    /// La corrida sigue abierta en la cola (todavía no se descartó): su ventana se puede abrir.
    private func canOpen(_ record: RespondRecord) -> Bool {
        respond.records[record.draft.prID]?.id == record.id
    }

    @ViewBuilder
    private func reviewContextMenu(for record: ReviewRecord) -> some View {
        Button("Open PR on GitHub") { NSWorkspace.shared.open(record.draft.url) }
        if let url = record.reviewURL {
            Button("View Review on GitHub") { NSWorkspace.shared.open(url) }
        }
        Button("Copy PR Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.draft.url.absoluteString, forType: .string)
        }
        let logURL = model.history.logURL(for: record.id)
        if FileManager.default.fileExists(atPath: logURL.path) {
            Divider()
            Button("Show Claude Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
        }
        if canReopen(record) {
            Divider()
            Button("Open to Post") { model.reopenFromHistory(record.draft) }
        }
    }

    /// "Abrir para publicar" (§10): ver `ReviewHistory.canReopen`.
    private func canReopen(_ record: ReviewRecord) -> Bool {
        ReviewHistory.canReopen(
            record, among: records.compactMap(\.review),
            currentHeadOid: prStore.snapshot?.items.first(where: { $0.id == record.draft.prID })?.pr.headOid,
            reviewActive: reviews.phases[record.draft.prID]?.isActive == true
        )
    }

    /// Elige el registro pedido por `AppModel.openHistory(selecting:)` (p. ej. al tocar la notificación de un
    /// review que falló). Limpia la búsqueda y el filtro para que se vea.
    private func applySelectionRequest() {
        guard let id = model.consumeHistorySelection() else { return }
        if !records.contains(where: { $0.id == id }) { records = loadEntries() }
        guard records.contains(where: { $0.id == id }) else { return }
        query = ""
        repoFilter = nil
        selection = id
    }

    private func reload() {
        records = loadEntries()
        if let selection, !records.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = records.first?.id }
    }

    /// Reviews y respuestas, de la más nueva a la más vieja.
    private func loadEntries() -> [HistoryEntry] {
        (model.history.all().map(HistoryEntry.review) + model.respondHistory.all().map(HistoryEntry.respond)
            + model.mergeHistory.all().map(HistoryEntry.merge))
            .sorted { $0.startedAt > $1.startedAt }
    }
}

/// Un registro del historial: una review de Claude o una corrida de "Responder".
enum HistoryEntry: Identifiable {
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
}

/// Fila de la lista: `repo#N` + fecha, título y pill de estado.
private struct HistoryRow: View {
    let record: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                kindIcon
                Text("\(record.repo.name)#\(record.number)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(ReviewDates.short(record.startedAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(record.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            switch record {
            case .review(let review): StatusPill.record(review)
            case .respond(let respond): StatusPill.respond(respond)
            case .merge(let merge): StatusPill.merge(merge)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var kindIcon: some View {
        let (icon, label) = switch record {
        case .review: ("text.magnifyingglass", "Review")
        case .respond: ("arrowshape.turn.up.left", "Feedback response")
        case .merge: ("arrow.triangle.merge", "Merge")
        }
        return Image(systemName: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// Grupos de la lista: "Hoy", "Esta semana" y "Antes" (los vacíos no se muestran).
struct HistoryGroup {
    let title: String
    let records: [HistoryEntry]

    static func group(_ records: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [HistoryGroup] {
        var today: [HistoryEntry] = [], week: [HistoryEntry] = [], older: [HistoryEntry] = []
        for record in records {
            if calendar.isDate(record.startedAt, inSameDayAs: now) {
                today.append(record)
            } else if calendar.isDate(record.startedAt, equalTo: now, toGranularity: .weekOfYear) {
                week.append(record)
            } else {
                older.append(record)
            }
        }
        return [("Today", today), ("This Week", week), ("Earlier", older)]
            .filter { !$0.1.isEmpty }
            .map { HistoryGroup(title: $0.0, records: $0.1) }
    }
}

/// Búsqueda por título, repo o número ("482" o "#482").
enum HistorySearch {
    static func matches(_ record: HistoryEntry, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if record.title.lowercased().contains(query) || record.repo.fullName.lowercased().contains(query) { return true }
        let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return !number.isEmpty && String(record.number).hasPrefix(number)
            || "\(record.repo.name)#\(record.number)".lowercased().contains(query)
    }
}
