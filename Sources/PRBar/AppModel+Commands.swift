import AppKit
import PRBarCore

// MARK: - Ayudas comunes de los comandos

// `appVersion` ya existe: lo definió el plan 8 en `AppModel+Updates.swift`.
extension AppModel {
    /// Lo que no arranca mientras se instala una actualización (spec D.3): la misma razón que deshabilita los botones.
    func throwIfJobsBlocked() throws {
        if let jobsBlockedReason { throw CommandFailure(.invalidState, jobsBlockedReason) }
    }

    /// `owner/repo#N`, `repo#N` o la URL → id del PR entre los que conoce la app (snapshot, reviews y respuestas).
    func resolvePRID(_ text: String) throws -> String {
        guard let reference = PRReference.parse(text) else {
            throw CommandFailure(.invalidUsage, "“\(text)” isn’t a PR. Use owner/repo#N, repo#N or the PR’s URL.")
        }
        let known = (prStore.snapshot?.items.map(\.id) ?? []) + Array(reviews.phases.keys) + Array(respond.records.keys)
        switch reference.resolve(among: known) {
        case .success(let id):
            return id
        case .failure(.notFound):
            throw CommandFailure(.notFound, "\(text) isn’t in PRBar’s list. Run `prbar prs` to see the PRs.")
        case .failure(.ambiguous(let ids)):
            throw CommandFailure(.invalidUsage, "\(text) matches \(ids.joined(separator: ", ")). Use owner/repo#N.")
        }
    }

    func classifiedPR(_ prID: String) throws -> ClassifiedPR {
        guard let item = prStore.snapshot?.items.first(where: { $0.id == prID }) else {
            throw CommandFailure(.notFound, "\(prID) isn’t in the PR list anymore (merged or closed?). Run `prbar refresh`.")
        }
        return item
    }

    /// gh, git y claude: la ruta encontrada y si es una elegida a mano (Settings › General). También es
    /// `ConfigActions.toolsList` (Task 12).
    func toolsList() -> [ToolInfo] {
        ToolName.allCases.map { tool in
            let path = switch tool {
            case .gh: tools.gh
            case .git: tools.git
            case .claude: tools.claude
            }
            return ToolInfo(name: tool.rawValue, path: path, custom: configStore.config.toolPaths[keyPath: tool.keyPath] != nil)
        }
    }

    /// Espera (consultando cada 0,3 s) a que `isDone` sea verdad y avisa cada cambio de `describe`. Si la CLI se va
    /// (Ctrl-C), `Task.sleep` lanza `CancellationError` y la espera termina; el job sigue (o la CLI lo cancela aparte).
    func waitUntil(_ isDone: () -> Bool, describe: () -> String, events: CommandEventSink) async throws {
        var last = ""
        while !isDone() {
            let text = describe()
            if text != last {
                events(.progress(message: text))
                last = text
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

// MARK: - Estado, ventanas e historial

extension AppModel: StatusActions {
    func status() async throws -> StatusInfo {
        let snapshot = prStore.snapshot
        var counts: [String: Int] = [:]
        for category in PRCategory.allCases { counts[category.rawValue] = snapshot?.items(in: category).count ?? 0 }
        let reviewJobs = reviews.phases.filter { $0.value.isActive }
            .map { JobInfo(pr: $0.key, kind: "review", phase: $0.value.cliName) }
        // Los tests corren en `readyToPush`: cuentan aunque la fase no esté activa.
        let respondJobs = Set(respond.phases.filter { $0.value.isActive }.keys).union(respond.runningTests).map { prID in
            JobInfo(pr: prID, kind: "respond",
                    phase: respond.runningTests.contains(prID) ? "testing" : respond.phases[prID]?.cliName ?? "testing")
        }
        let mergeJobs = merges.phases.filter { $0.value.isActive }.map { JobInfo(pr: $0.key, kind: "merge", phase: $0.value.cliName) }
        let tabs = PopoverTabs.counts(in: snapshot)
        return StatusInfo(
            appVersion: appVersion, refreshing: prStore.isRefreshing, fetchedAt: snapshot?.fetchedAt,
            offline: snapshot?.failedCompletely ?? false, rateLimitedUntil: snapshot?.rateLimitedUntil,
            badgeCount: snapshot?.badgeCount ?? 0, counts: counts,
            issues: snapshot?.issues.map(\.message) ?? [], slackIssues: slack.issues.map(\.message),
            jobs: (reviewJobs + respondJobs + mergeJobs).sorted { ($0.pr, $0.kind) < ($1.pr, $1.kind) },
            accounts: configStore.config.accounts.filter(\.enabled).map(\.login), tools: toolsList(),
            blockedReason: jobsBlockedReason, updateAvailable: updates.available?.version.description,
            tabCounts: Dictionary(uniqueKeysWithValues: tabs.map { ($0.key.rawValue, $0.value) }),
            sectionCounts: Dictionary(uniqueKeysWithValues: PopoverTabs.sectionCounts(in: snapshot).map { ($0.key.rawValue, $0.value) })
        )
    }

    func listPRs(list: PRListFilter?, account: String?, tab: PopoverTab?) throws -> [PRInfo] {
        guard let snapshot = prStore.snapshot else {
            throw CommandFailure(.invalidState, "PRBar hasn’t loaded the PRs yet. Try again in a few seconds.")
        }
        if let account, !configStore.config.accounts.contains(where: { $0.login.caseInsensitiveCompare(account) == .orderedSame }) {
            throw CommandFailure(.notFound, "There’s no account \(account). Run `prbar account list`.")
        }
        return PRListing.filter(snapshot.items, list: list, tab: tab, account: account)
            .map { PRInfo(item: $0, review: reviews.phases[$0.id], respond: respond.phases[$0.id], merge: merges.phases[$0.id]) }
    }

    func resolvePR(_ pr: String) throws -> PRLink {
        let id = try resolvePRID(pr)
        return PRLink(pr: id, url: try prURL(id))
    }

    private func prURL(_ prID: String) throws -> URL {
        if let url = prStore.snapshot?.items.first(where: { $0.id == prID })?.pr.url ?? PRReference.githubURL(prID: prID) {
            return url
        }
        throw CommandFailure(.notFound, "No URL for \(prID).")
    }

    func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo] {
        var entries: [HistoryEntryInfo] = []
        if kind == nil || kind == .review { entries += history.all().map(HistoryEntryInfo.init(review:)) }
        // Respond and Fix CI share `respondHistory`; `listing` keeps the requested kind only.
        if kind == nil || kind == .respond || kind == .ciFix {
            entries += respondHistory.all().map(HistoryEntryInfo.init(respond:))
        }
        if kind == nil || kind == .merge { entries += mergeHistory.all().map(HistoryEntryInfo.init(merge:)) }
        return HistoryEntryInfo.listing(entries, repo: repo, kind: kind, limit: limit, search: search)
    }

    private enum HistoryHit {
        case review(ReviewRecord)
        case respond(RespondRecord)
        case merge(MergeRecord)
    }

    /// Un registro por su id completo o por un prefijo único (de al menos 4 caracteres).
    private func historyRecord(_ text: String) throws -> HistoryHit {
        let needle = text.lowercased()
        let reviewHits = history.all().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        let respondHits = respondHistory.all().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        let mergeHits = mergeHistory.all().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        let total = reviewHits.count + respondHits.count + mergeHits.count
        guard needle.count >= 4, total > 0 else {
            throw CommandFailure(.notFound, "There’s no history record \(text). Run `prbar history`.")
        }
        guard total == 1 else {
            throw CommandFailure(.invalidUsage, "\(text) matches \(total) records: use more characters of the id.")
        }
        if let record = reviewHits.first { return .review(record) }
        if let record = respondHits.first { return .respond(record) }
        return .merge(mergeHits[0])
    }

    private func canReopen(_ record: ReviewRecord) -> Bool {
        ReviewHistory.canReopen(
            record, among: history.all(),
            currentHeadOid: prStore.snapshot?.items.first(where: { $0.id == record.draft.prID })?.pr.headOid,
            reviewActive: reviews.phases[record.draft.prID]?.isActive == true
        )
    }

    private func existingPath(_ url: URL) -> String? {
        FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    func historyShow(id: String) throws -> HistoryDetail {
        switch try historyRecord(id) {
        case .review(let record):
            return HistoryDetail(review: record, logPath: existingPath(history.logURL(for: record.id)),
                                 canReopen: canReopen(record))
        case .respond(let record):
            return HistoryDetail(respond: record, logPath: existingPath(respondHistory.logURL(for: record.id)),
                                 canOpen: respond.records[record.draft.prID]?.id == record.id)
        case .merge(let record):
            return HistoryDetail(merge: record, logPath: existingPath(mergeHistory.logURL(for: record.id)))
        }
    }

    /// "Open to Post": vuelve a dejar listo un review del historial y abre su ventana.
    func historyReopen(id: String) throws {
        guard case .review(let record) = try historyRecord(id) else {
            throw CommandFailure(.invalidUsage, "Only reviews can be reopened. For a response use `prbar open <pr> --respond`.")
        }
        guard canReopen(record) else {
            throw CommandFailure(.invalidState, "This review can’t be posted anymore: the PR changed, it was already posted, or a review is running.")
        }
        reopenFromHistory(record.draft)
    }

    /// Como ⌘R, pero si ya había un refresco en curso lo espera y refresca de nuevo: lo que la CLI lea después
    /// está al día.
    func refresh() async {
        await prStore.refreshNow()
    }

    func open(pr: String, target: OpenTarget) throws -> PRLink {
        let id = try resolvePRID(pr)
        switch target {
        case .browser:
            NSWorkspace.shared.open(try prURL(id))
        case .review:
            switch reviews.phases[id] {
            case .ready?, .published?: openReview(prID: id)
            default: throw CommandFailure(.invalidState, "There’s no finished review of \(id). Run `prbar review \(id)`.")
            }
        case .respond:
            guard respond.records[id] != nil else {
                throw CommandFailure(.invalidState, "There’s no analysis of \(id)’s feedback. Run `prbar respond \(id)`.")
            }
            openRespond(prID: id)
        case .posted:
            guard let url = postedReviewURL(id) else {
                throw CommandFailure(.notFound, "There’s no posted review of \(id).")
            }
            NSWorkspace.shared.open(url)
            return PRLink(pr: id, url: url)
        case .worktree:
            guard let record = respond.records[id] else {
                throw CommandFailure(.invalidState, "There’s no analysis of \(id)’s feedback, so there’s no worktree.")
            }
            let folder = URL(fileURLWithPath: record.draft.worktree.path, isDirectory: true)
            NSWorkspace.shared.open(folder)
            return PRLink(pr: id, url: folder)
        case .merge:
            guard let item = currentItem(id), item.category == .readyToMerge else {
                throw CommandFailure(.invalidState, "\(id) isn’t in Ready to Merge. Run `prbar prs --list ready-to-merge`.")
            }
            requestMerge(item)
        }
        return PRLink(pr: id, url: try prURL(id))
    }

    private func postedReviewURL(_ prID: String) -> URL? {
        if case .published(let url)? = reviews.phases[prID] { return url }
        return history.all()
            .filter { $0.draft.prID == prID && $0.status == .published }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }?
            .reviewURL
    }

    func openSettings(tab: SettingsTabName?) {
        if let tab, let settingsTab = SettingsWindow.Tab(rawValue: tab.rawValue) { SettingsWindow.select(settingsTab) }
        openSettings()
    }

    func openHistory(id: String?) throws {
        guard let id else {
            openHistory()
            return
        }
        switch try historyRecord(id) {
        case .review(let record): openHistory(selecting: record.id)
        case .respond(let record): openHistory(selecting: record.id)
        case .merge(let record): openHistory(selecting: record.id)
        }
    }

    /// Contesta antes de salir.
    func quit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { QuitRequest.terminateWithoutAsking() }
    }
}

// MARK: - Review

extension AppModel: ReviewActions {
    func readyReviewDraft(_ prID: String) throws -> ReviewDraft {
        guard case .ready(let draft)? = reviews.phases[prID] else {
            throw CommandFailure(.invalidState, "There’s no review ready to post for \(prID). Run `prbar review \(prID)` first.")
        }
        return draft
    }

    func reviewInfo(_ prID: String) -> ReviewInfo {
        let phase = reviews.phases[prID]
        guard case .ready(let draft)? = phase else { return ReviewInfo(prID: prID, phase: phase) }
        return ReviewInfo(prID: prID, phase: phase, edits: reviewChat(for: draft).reviewEdits, outdated: isOutdated(draft))
    }

    private func reviewProgress(_ prID: String) -> String {
        switch reviews.phases[prID] {
        case .queued?: "Queued"
        case .preparing?: "Preparing the worktree…"
        case .reviewing(let agents)?: agents > 0 ? "Reviewing (\(agents) agent\(agents == 1 ? "" : "s"))…" : "Reviewing…"
        case .filtering?: "Filtering the findings…"
        default: "Finishing…"
        }
    }

    private func reviewItem(_ reference: String, in draft: ReviewDraft) throws -> ReviewItem {
        guard let item = reviewChat(for: draft).reviewEdits.item(reference, in: draft) else {
            throw CommandFailure(.notFound, "There’s no finding \(reference) in this review. Run `prbar review show \(draft.prID)`.")
        }
        return item
    }

    func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo {
        let item = try classifiedPR(try resolvePRID(pr))
        switch item.category {
        case .toReview, .updatedSinceMyReview: break
        case .myFeedback: throw CommandFailure(.invalidState, "\(item.id) is your PR: use `prbar respond \(item.id)`.")
        case .readyToMerge: throw CommandFailure(.invalidState, "\(item.id) is your PR and it’s ready to merge: use `prbar merge \(item.id)`.")
        case .other: throw CommandFailure(.invalidState, "PRBar reviews PRs in “To Review” and “Updated Since My Review”; \(item.id) isn’t in either.")
        }
        if reviews.phases[item.id]?.isActive == true {
            throw CommandFailure(.invalidState, "\(item.id) is already being reviewed.")
        }
        try throwIfJobsBlocked()
        startReview(item)
        guard wait else { return reviewInfo(item.id) }
        try await waitUntil({ reviews.phases[item.id]?.isActive != true },
                            describe: { reviewProgress(item.id) }, events: events)
        if case .failed(let message, _)? = reviews.phases[item.id] { throw CommandFailure(.failed, message) }
        return reviewInfo(item.id)
    }

    func reviewShow(pr: String) throws -> ReviewInfo {
        reviewInfo(try resolvePRID(pr))
    }

    func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        let item = try reviewItem(finding, in: draft)
        guard title != nil || body != nil else {
            throw CommandFailure(.invalidUsage, "Nothing to change: pass --title, --body, --body-file or --editor.")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CommandFailure(.invalidUsage, "The title can’t be empty.")
        }
        let chat = reviewChat(for: draft)
        if let title { chat.reviewEdits.setTitle(title, for: item.id, in: draft) }
        if let body { chat.reviewEdits.setBody(body, for: item.id, in: draft) }
        return reviewInfo(id)
    }

    func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        if all {
            let chat = reviewChat(for: draft)
            if included { chat.reviewEdits.selectAllKept(in: draft) } else { chat.reviewEdits.selected.removeAll() }
            return reviewInfo(id)
        }
        guard !findings.isEmpty else { throw CommandFailure(.invalidUsage, "Name the findings (numbers or ids) or pass --all.") }
        let items = try findings.map { try reviewItem($0, in: draft) }
        let chat = reviewChat(for: draft)
        for item in items {
            if included { chat.reviewEdits.selected.insert(item.id) } else { chat.reviewEdits.selected.remove(item.id) }
        }
        return reviewInfo(id)
    }

    func reviewSetComment(pr: String, text: String) throws -> ReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        reviewChat(for: draft).reviewEdits.generalComment = text
        return reviewInfo(id)
    }

    func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool,
                       allInBody: Bool) async throws -> PublishedReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        if let lock = reviewChat(for: draft).lockReason {
            throw CommandFailure(.invalidState, "\(lock) Wait for it to finish.")
        }
        let onlyIDs = try only.map { references in Set(try references.map { try reviewItem($0, in: draft).id }) }
        if event != .approve {
            // Comentar y Pedir cambios sin nada que publicar no se puede (como en la ventana).
            let edits = reviewChat(for: draft).reviewEdits
            let comments = withComments ? edits.comments(of: draft, only: onlyIDs) : []
            let general = withComments ? edits.generalComment.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !comments.isEmpty || !general.isEmpty else {
                throw CommandFailure(.invalidState, "Nothing to post: include findings (`prbar review include`) or write a general comment (`prbar review comment`).")
            }
        }
        do {
            let result = try await publishReview(draft: draft, event: event, only: onlyIDs, withComments: withComments,
                                                 allInBody: allInBody)
            return PublishedReviewInfo(pr: id, url: result.url, action: result.action.rawValue,
                                       comments: result.commentCount, publishedAt: result.publishedAt)
        } catch let error as InlineCommentsRejected {
            throw CommandFailure(.failed, "\(error.localizedDescription) Run it again with --all-in-body.")
        }
    }

    func reviewCancel(pr: String) throws {
        let id = try resolvePRID(pr)
        guard reviews.phases[id]?.isActive == true else {
            throw CommandFailure(.invalidState, "There’s no review of \(id) running.")
        }
        cancelReview(prID: id)
    }

    func reviewDismiss(pr: String) throws {
        let id = try resolvePRID(pr)
        guard let phase = reviews.phases[id] else { throw CommandFailure(.invalidState, "There’s no review of \(id) to dismiss.") }
        guard !phase.isActive else { throw CommandFailure(.invalidState, "The review is running: cancel it with `prbar review cancel \(id)`.") }
        dismissReview(prID: id)
    }
}

// MARK: - Respond

extension AppModel: RespondActions {
    func respondRecord(_ prID: String) throws -> RespondRecord {
        guard let record = respond.records[prID] else {
            throw CommandFailure(.invalidState, "There’s no analysis of \(prID)’s feedback. Run `prbar respond \(prID)` first.")
        }
        return record
    }

    func respondInfo(_ prID: String) -> RespondInfo {
        let record = respond.records[prID]
        var logPath: String?
        if case .failed(_, let log)? = respond.phases[prID] { logPath = log?.path }
        if logPath == nil, let record { logPath = existingPath(respondHistory.logURL(for: record.id)) }
        var info = RespondInfo(prID: prID, phase: respond.phases[prID], record: record,
                           selections: record.map { respondSelections(for: $0.draft) } ?? [:],
                           runningTests: respond.runningTests.contains(prID),
                           testCommand: record.flatMap { testCommand(for: $0.draft) }, logPath: logPath,
                           pushBlockedByTests: respondPushGate(prID: prID).isTestsFailed)
        info.pushBlockedByCI = respond.pushBlockedByCI[prID]
        info.mode = respond.mode(of: prID)
        info.unpushedWork = respond.unpushedWork.contains(prID) ? true : nil
        return info
    }

    private func respondProgress(_ prID: String) -> String {
        if respond.runningTests.contains(prID) { return "Running tests…" }
        if respond.mode(of: prID) == .ciFix {
            return switch respond.phases[prID] {
            case .queued?: "Queued…"
            case .preparing?: "Reading the failing checks and preparing the worktree…"
            case .implementing?: "Claude is fixing the CI…"
            case .pushing?: "Checking the CI again and pushing…"
            default: "Finishing…"
            }
        }
        return switch respond.phases[prID] {
        case .queued?: "Queued…"
        case .preparing?: "Preparing the worktree…"
        case .analyzing?: "Claude is analyzing the comments…"
        case .implementing(let done, let total)?: "Implementing \(min(done + 1, max(total, 1))) of \(max(total, 1))…"
        case .pushing?: "Pushing and posting the replies…"
        default: "Finishing…"
        }
    }

    private func throwIfRespondFailed(_ prID: String) throws {
        if case .failed(let message, _)? = respond.phases[prID] { throw CommandFailure(.failed, message) }
    }

    func waitForRespond(_ prID: String, events: CommandEventSink) async throws {
        try await waitUntil({ respond.phases[prID]?.isActive != true && !respond.runningTests.contains(prID) },
                            describe: { respondProgress(prID) }, events: events)
        try throwIfRespondFailed(prID)
    }

    /// El análisis listo de este PR, para elegir (también después de un fallo sin fixes, como en la ventana).
    private func choosableDraft(_ prID: String) throws -> RespondDraft {
        let record = try respondRecord(prID)
        switch respond.phases[prID] {
        case .ready(let draft)? where draft.id == record.draft.id:
            return draft
        case .failed? where record.result == nil:
            return record.draft
        default:
            throw CommandFailure(.invalidState, "\(prID) isn’t waiting for your choices (\(respond.phases[prID]?.cliName ?? "none")).")
        }
    }

    /// Un turno del chat bloquea implementar, correr tests y publicar en el PR (como en la ventana).
    private func throwIfChatting(_ prID: String) throws {
        if respond.chatting.contains(prID) {
            throw CommandFailure(.invalidState, "Wait for Claude to finish answering in the chat (`prbar chat \(prID) --stop` stops it).")
        }
    }

    /// Las colas ignoran en silencio lo que no pueden arrancar: si nada empezó, se avisa.
    func throwIfNothingStarted(_ prID: String, _ what: String) throws {
        guard respond.phases[prID]?.isActive == true || respond.runningTests.contains(prID) else {
            throw CommandFailure(.invalidState, "Couldn’t start \(what) for \(prID): something else is running on it. Try again in a moment.")
        }
    }

    private func respondItemID(_ reference: String, in draft: RespondDraft) throws -> String {
        guard let id = RespondItemReference.itemID(reference, in: draft) else {
            throw CommandFailure(.notFound, "There’s no comment \(reference) in this analysis. Run `prbar respond show \(draft.prID)`.")
        }
        return id
    }

    func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let item = try classifiedPR(try resolvePRID(pr))
        guard item.category == .myFeedback else {
            throw CommandFailure(.invalidState, "\(item.id) isn’t one of your PRs with feedback.")
        }
        if let reason = respondUnavailableReason(item) {
            throw CommandFailure(.invalidState, "\(reason) Or run `prbar repo set \(item.pr.repo.fullName) --path …`.")
        }
        if let reason = respondSlotConflictReason(item.id, starting: .feedback) {
            throw CommandFailure(.invalidState, "\(reason) (`prbar ci dismiss \(item.id)`)")
        }
        let phase = respond.phases[item.id]
        if phase?.isActive == true || respond.runningTests.contains(item.id) {
            throw CommandFailure(.invalidState, "\(item.id) is already being worked on: wait or cancel it (`prbar respond cancel \(item.id)`).")
        }
        if case .readyToPush? = phase {
            throw CommandFailure(.invalidState, "\(item.id) has fixes that weren’t pushed: push them (`prbar respond push \(item.id)`) or dismiss them first.")
        }
        if case .failed? = phase, respond.records[item.id]?.result != nil {
            throw CommandFailure(.invalidState, "\(item.id) already has fixes: retry with `prbar respond push \(item.id)`.")
        }
        if respond.unpushedWork.contains(item.id) {
            throw CommandFailure(.invalidState, "\(item.id) has changes that weren’t pushed in PRBar’s worktree: check them, then dismiss them (`prbar respond dismiss \(item.id)`) before analyzing again.")
        }
        startRespond(item)
        guard wait else { return respondInfo(item.id) }
        try await waitForRespond(item.id, events: events)
        return respondInfo(item.id)
    }

    func respondShow(pr: String) throws -> RespondInfo {
        respondInfo(try resolvePRID(pr))
    }

    func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let draft = try choosableDraft(id)
        guard !change.isEmpty else {
            throw CommandFailure(.invalidUsage, "Nothing to change: pass --implement, --reply-only, --skip, --no-reply, --reply or --plan.")
        }
        guard !items.isEmpty else { throw CommandFailure(.invalidUsage, "Name at least one comment (its number or id).") }
        let ids = try items.map { try respondItemID($0, in: draft) }
        for itemID in ids {
            updateRespondSelection(draft, itemID: itemID) { change.apply(to: &$0) }
        }
        return respondInfo(id)
    }

    func respondReset(pr: String) throws -> RespondInfo {
        let id = try resolvePRID(pr)
        resetRespondSelections(try choosableDraft(id))
        return respondInfo(id)
    }

    func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let record = try respondRecord(id)
        guard case .ready(let draft)? = respond.phases[id], draft.id == record.draft.id else {
            throw CommandFailure(.invalidState, "\(id) isn’t ready to implement fixes (\(respond.phases[id]?.cliName ?? "none")).")
        }
        guard RespondCounts.fixes(draft, respondSelections(for: draft)) > 0 else {
            throw CommandFailure(.invalidState, "No fixes selected. Use `prbar respond select \(id) <n> --implement`, or post only the replies with `prbar respond reply-only \(id)`.")
        }
        try throwIfJobsBlocked()
        try throwIfChatting(id)
        implementRespond(prID: id)
        try throwIfNothingStarted(id, "the fixes")
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        guard case .readyToPush(let draft, _)? = respond.phases[id] else {
            throw CommandFailure(.invalidState, "Tests run after the fixes are implemented (`prbar respond implement \(id)`).")
        }
        guard testCommand(for: draft) != nil else {
            throw CommandFailure(.invalidState, "There’s no test command for \(draft.repo.fullName). Set it with `prbar repo set \(draft.repo.fullName) --test-command …`.")
        }
        guard !respond.runningTests.contains(id) else { throw CommandFailure(.invalidState, "The tests are already running.") }
        try throwIfMayNotRunRepoCode()
        try throwIfJobsBlocked()
        try throwIfChatting(id)
        runRespondTests(prID: id)
        try throwIfNothingStarted(id, "the tests")
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    /// The test command and a push (git hooks) run code from the repository, which Claude may have changed: from an
    /// iPhone only with a fresh Face ID proof (decision H1; `RemotePolicy` already gates them, this is the last check).
    private func throwIfMayNotRunRepoCode() throws {
        guard CommandOrigin.mayRunRepoCode else {
            throw CommandFailure(.unauthorized, CommandOrigin.presenceRequiredMessage)
        }
    }

    func respondDiff(pr: String) throws -> RespondDiff {
        let id = try resolvePRID(pr)
        guard let result = try respondRecord(id).result else {
            throw CommandFailure(.invalidState, "\(id) has no implemented fixes yet.")
        }
        return RespondDiff(pr: id, diffStat: result.diffStat, diff: result.diff, truncated: result.diffTruncated ?? false,
                           sensitiveChanges: result.sensitiveChanges)
    }

    func respondPush(pr: String, wait: Bool, mode: RespondMode?, events: CommandEventSink) async throws -> RespondInfo {
        try await pushAndReply(pr: pr, anyway: false, wait: wait, mode: mode, events: events)
    }

    func respondPushAnyway(pr: String, wait: Bool, mode: RespondMode?, events: CommandEventSink) async throws -> RespondInfo {
        try await pushAndReply(pr: pr, anyway: true, wait: wait, mode: mode, events: events)
    }

    /// "Push and Reply" (o "Retry Pending Replies") y "Push Anyway". Con "Run tests before pushing" primero corren
    /// los tests (`pushRespond`); si fallan no se pushea y la respuesta lo dice.
    private func pushAndReply(pr: String, anyway: Bool, wait: Bool, mode: RespondMode?,
                              events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        try throwIfMayNotRunRepoCode()
        let record = try respondRecord(id)
        // `prbar ci push` nunca pushea una corrida de Responder (ni al revés), tampoco con --yes (spec K.6.14).
        if let problem = RespondPushGate.modeCheck(expected: mode, actual: respond.mode(of: id), prID: id) { throw problem }
        let gate = respondPushGate(prID: id)
        if let problem = RespondPushGate.commandCheck(
            record, phase: respond.phases[id], runningTests: respond.runningTests.contains(id),
            chatting: respond.chatting.contains(id), gate: gate, anyway: anyway,
            blockedByCI: respond.pushBlockedByCI[id] != nil
        ) {
            throw problem
        }
        do {
            try pushRespond(prID: id, ignoringFailedTests: anyway)
        } catch {
            throw CommandFailure(.invalidState, error.localizedDescription)
        }
        try throwIfNothingStarted(id, gate == .runTests ? "the tests before the push" : "the push")
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        if case .testsFailed(let run) = respondPushGate(prID: id), respond.records[id]?.pushed != true {
            throw CommandFailure(.failed, "“\(run.command)” failed, so PRBar didn’t push. Push anyway with `\(RespondPushGate.pushCommand(record.draft.mode)) \(id) --anyway`.")
        }
        if let blocked = respond.pushBlockedByCI[id], respond.records[id]?.pushed != true {
            throw CommandFailure(.failed, "\(blocked) Push anyway with `prbar ci push \(id) --anyway`.")
        }
        return respondInfo(id)
    }

    func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let record = try respondRecord(id)
        guard record.result == nil else {
            throw CommandFailure(.invalidState, "\(id) has implemented fixes: use `prbar respond push \(id)` (it pushes and posts the replies).")
        }
        switch respond.phases[id] {
        case .ready?, .failed?: break
        default: throw CommandFailure(.invalidState, "\(id) can’t post replies now (\(respond.phases[id]?.cliName ?? "none")).")
        }
        guard RespondCounts.plannedReplies(record.draft, respondSelections(for: record.draft)) > 0 else {
            throw CommandFailure(.invalidState, "No replies to post. Use `prbar respond select \(id) <n> --reply …`.")
        }
        try throwIfChatting(id)
        publishRespondReplies(prID: id)
        try throwIfNothingStarted(id, "posting the replies")
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func respondCancel(pr: String) throws {
        let id = try resolvePRID(pr)
        if case .pushing? = respond.phases[id] {
            throw CommandFailure(.invalidState, "Pushing and posting can’t be canceled.")
        }
        guard respond.phases[id]?.isActive == true || respond.runningTests.contains(id) else {
            throw CommandFailure(.invalidState, "There’s nothing running for \(id).")
        }
        cancelRespond(prID: id)
    }

    func respondDismiss(pr: String) throws {
        let id = try resolvePRID(pr)
        guard respond.phases[id] != nil || respond.records[id] != nil else {
            throw CommandFailure(.invalidState, "There’s nothing to dismiss for \(id).")
        }
        guard respond.phases[id]?.isActive != true, !respond.runningTests.contains(id) else {
            throw CommandFailure(.invalidState, "It’s running: cancel it first (`prbar respond cancel \(id)`).")
        }
        dismissRespond(prID: id)
    }
}

// MARK: - Fix CI y uso de Claude (specs K y O)

extension AppModel: CIFixUsageActions {
    func ciList() throws -> [CIListEntry] {
        let items = (prStore.snapshot?.items ?? []).filter { isCIFixCandidate($0) || respond.mode(of: $0.id) == .ciFix && respond.phases[$0.id] != nil }
        return items.sorted { $0.id < $1.id }.map { item in
            let isCI = respond.mode(of: item.id) == .ciFix
            let phase = respond.runningTests.contains(item.id) ? "testing" : respond.phases[item.id]?.cliName
            return CIListEntry(pr: item.id, title: item.pr.title, url: item.pr.url, account: item.account,
                               phase: isCI ? phase : nil, respondInProgress: !isCI && respond.phases[item.id] != nil,
                               unavailableReason: ciFixUnavailableReason(item),
                               failedChecks: failedCheckCount(item))
        }
    }

    /// Los checks que fallaron en el head actual, si un Fix CI ya los leyó (sin pedirle nada nuevo a GitHub).
    private func failedCheckCount(_ item: ClassifiedPR) -> Int? {
        guard let ci = respond.records[item.id]?.draft.ci, ci.headOid == item.pr.headOid else { return nil }
        return ci.checks.count + ci.omitted.count
    }

    func ciFix(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let item = try classifiedPR(id)
        guard PopoverTabs.isMine(item) else {
            throw CommandFailure(.invalidState, "\(id) isn’t your PR: Fix CI is only for your own PRs.")
        }
        // Un Fix CI que quedó en `ready` (no pudo arrancar solo): lo mismo que el botón "Fix CI" de la ventana, sin
        // volver a bajar los logs ni preparar otro worktree (L12).
        if case .ready(let draft)? = respond.phases[id], draft.isCIFix {
            if let jobsBlockedReason { throw CommandFailure(.invalidState, jobsBlockedReason) }
            guard respond.implementCI(prID: id) else {
                throw CommandFailure(.invalidState, "Couldn’t start Fix CI for \(id): something else is running on it. Try again in a moment.")
            }
            guard wait else { return respondInfo(id) }
            try await waitForRespond(id, events: events)
            return respondInfo(id)
        }
        // Como "Fix CI Again" en la ventana: una corrida de Fix CI abierta se puede repetir aunque el CI ya no figure
        // como fallido en el último refresco.
        let hasCIRun = respond.mode(of: id) == .ciFix && respond.phases[id] != nil
        guard item.pr.ciState == .failure || hasCIRun else {
            throw CommandFailure(.invalidState, "\(id)’s CI isn’t failing (as of the last refresh). Run `prbar refresh` if it just failed.")
        }
        if let reason = respondSlotConflictReason(id, starting: .ciFix) {
            throw CommandFailure(.invalidState, "\(reason) (`prbar respond dismiss \(id)`)")
        }
        if let reason = ciFixUnavailableReason(item) { throw CommandFailure(.invalidState, reason) }
        startCIFix(item)
        try throwIfNothingStarted(id, "Fix CI")
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func usage(month: String?) throws -> UsageInfo {
        let key: String
        if let month {
            guard let parsed = UsageSummary.parseMonth(month) else {
                throw CommandFailure(.invalidUsage, "“\(month)” isn’t a month: use YYYY-MM.")
            }
            key = parsed
        } else {
            key = UsageSummary.monthKey(Date())
        }
        let entries = usageLedger.entries()
        let inMonth = entries.filter { UsageSummary.monthKey($0.date) == key }
        return UsageInfo(month: usageLedger.month(key), tasks: UsageSummary.recentTasks(inMonth, limit: 50))
    }
}

// MARK: - Ready to Merge

extension AppModel: MergeActions {
    /// Lo mismo que confirmar el diálogo de Merge: valida contra el snapshot actual (`MergeFlow.commandCheck`,
    /// incluido que el head siga siendo el que la CLI mostró) y mergea. Un error anterior de la fila se descarta antes
    /// (el usuario ya vio el PR tal como está ahora en la vista previa).
    func merge(pr: String, method: MergeMethod?, expectedHeadOid: String) async throws -> MergeInfo {
        let id = try resolvePRID(pr)
        let item = try classifiedPR(id)
        let chosen = try MergeFlow.commandCheck(
            item, method: method, options: mergeOptions(item), blockedReason: jobsBlockedReason,
            phase: merges.phases[id], expectedHeadOid: expectedHeadOid
        ).get()
        merges.dismiss(prID: id)
        switch await merge(item, method: chosen) {
        case .success(let completion): return MergeInfo(completion: completion)
        case .failure(let error): throw CommandFailure(.failed, error.localizedDescription)
        }
    }

    /// Lo que muestra la ventana de Merge, para `prbar merge --preview` y la confirmación de `prbar merge` (spec G.5):
    /// lo del snapshot y el resumen que se pide a GitHub, también si todavía no se puede mergear (`problem`; la CLI no
    /// mergea). El head que se va a mergear es el del snapshot (el que valida
    /// `merge`); si GitHub ya tiene otro, refresca una vez y, si siguen distintos, no muestra un resumen de otro head
    /// (`detailError`; plan 11, decisión 10).
    func mergePreview(pr: String, method: MergeMethod?) async throws -> MergePreviewInfo {
        let id = try resolvePRID(pr)
        var item = try classifiedPR(id)
        var detail: MergeDetail?
        var detailError: String?
        do {
            let token = try await accounts.token(for: item.account)
            detail = try await api.mergeDetail(repo: item.pr.repo, number: item.pr.number, token: token)
        } catch {
            detailError = "Couldn’t load the PR’s summary: \(MergeError(error).localizedDescription)"
        }
        if let fetched = detail, fetched.headOid != item.pr.headOid {
            await prStore.refreshNow()
            item = try classifiedPR(id)
            if fetched.headOid != item.pr.headOid {
                detail = nil
                detailError = "GitHub has newer commits than PRBar’s list. Run `prbar refresh` and try again."
            }
        }
        let options = mergeOptions(item)
        let checked = MergeFlow.previewCheck(item, method: method, options: options, blockedReason: jobsBlockedReason,
                                             phase: merges.phases[id])
        let settings = prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
        return MergePreviewInfo(item: item, method: checked.method, options: options,
                                deletesBranch: settings?.deleteBranchOnMerge ?? false, phase: merges.phases[id],
                                detail: detail, detailError: detailError, problem: checked.problem)
    }

    func mergeDismiss(pr: String) throws {
        let id = try resolvePRID(pr)
        guard case .failed? = merges.phases[id] else {
            throw CommandFailure(.invalidState, "There’s no merge error to dismiss for \(id).")
        }
        dismissMergeError(prID: id)
    }
}
