import Foundation

public enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case newToReview, reviewedPRUpdated, myPRFeedback, reviewFinished, myPRApprovedOrCIFailed
    /// Hay una versión nueva de PRBar (spec D.2). Solo depende del interruptor general.
    case updateAvailable
    /// Un PR mío entró a Ready to Merge (spec F.5).
    case readyToMerge
    /// PRBar pasó el umbral de disco (spec I). Solo depende del interruptor general.
    case diskUsage
}

public struct PlannedNotification: Equatable, Sendable {
    public let kind: NotificationKind
    public let title: String
    public let body: String
    public let url: URL?
    /// Id del PR cuyo review terminó; el click en la notificación abre su ventana de Review.
    public let reviewPRID: String?
    /// Registro del historial de un review que falló: el click abre el Historial con ese registro elegido.
    public let reviewRecordID: UUID?
    /// Id del PR propio cuya corrida de "Responder" avanzó; el click abre su ventana de Responder.
    public let respondPRID: String?
    /// PR al que se refiere (`nil` en las agrupadas): agrupa sus notificaciones en el Centro de notificaciones.
    public let prID: String?
    /// Versión nueva de PRBar: el click abre la ventana "Update PRBar".
    public let updateVersion: String?
    /// PR propio que quedó listo para mergear: el click abre su ventana de Merge (spec G.1).
    public let mergePRID: String?
    /// Identificador estable: una notificación nueva del mismo evento y PR reemplaza a la anterior en vez de
    /// apilarse.
    public let identifier: String
    /// La pestaña del PR que abre el clic (spec M.4); nil en las que no son de un PR.
    public let tab: PRTab?

    public init(
        kind: NotificationKind, title: String, body: String, url: URL?, reviewPRID: String? = nil,
        reviewRecordID: UUID? = nil, respondPRID: String? = nil, prID: String? = nil, event: String? = nil,
        updateVersion: String? = nil, mergePRID: String? = nil, tab: PRTab? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.url = url
        self.reviewPRID = reviewPRID
        self.reviewRecordID = reviewRecordID
        self.respondPRID = respondPRID
        self.prID = prID ?? reviewPRID ?? respondPRID
        self.updateVersion = updateVersion
        self.mergePRID = mergePRID
        self.tab = tab
        identifier = [kind.rawValue, event, self.prID ?? "group"].compactMap { $0 }.joined(separator: ":")
    }

    /// Hilo del Centro de notificaciones: las de un mismo PR van juntas; las agrupadas, por tipo.
    public var threadIdentifier: String { prID ?? kind.rawValue }
}

extension NotificationSettings {
    public func isOn(_ kind: NotificationKind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .newToReview: return newToReview
        case .reviewedPRUpdated: return reviewedPRUpdated
        case .myPRFeedback: return myPRFeedback
        case .reviewFinished: return reviewFinished
        case .myPRApprovedOrCIFailed: return myPRApprovedOrCIFailed
        case .updateAvailable: return true
        case .readyToMerge: return readyToMerge
        case .diskUsage: return true
        }
    }
}

public enum NotificationPlanner {
    static let groupingThreshold = 5

    public static func plan(previous: Snapshot?, current: Snapshot, settings: NotificationSettings) -> [PlannedNotification] {
        // Sin un refresco anterior bueno no hay contra qué comparar: todo parecería nuevo.
        guard settings.enabled, let previous, !previous.failedCompletely else { return [] }
        let before = Dictionary(previous.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var planned: [PlannedNotification] = []

        // Solo PRs de scopes que ya se habían consultado bien: un repo/cuenta recién agregado o que se
        // recupera de un error traería de golpe PRs que no son novedades.
        for item in current.items where previous.fetchedScopes.contains(Snapshot.scope(account: item.account, repo: item.pr.repo)) {
            let old = before[item.id]
            let pr = item.pr
            let body = "\(pr.repo.name)#\(pr.number) · \(pr.author): \(pr.title)"

            var notifiedReady = false
            if item.category == .readyToMerge {
                if settings.isOn(.readyToMerge), isNewlyReadyToMerge(item, old: old) {
                    planned.append(PlannedNotification(
                        kind: .readyToMerge, title: "\(pr.repo.fullName)#\(pr.number) is ready to merge", body: pr.title,
                        url: pr.url, prID: item.id, mergePRID: item.id, tab: .merge
                    ))
                    notifiedReady = true
                }
            } else if item.category.countsForBadge, old?.category != item.category,
                      let kind = kind(for: item.category), settings.isOn(kind) {
                planned.append(PlannedNotification(kind: kind, title: title(for: kind), body: body, url: pr.url, prID: item.id,
                                                   tab: tab(for: kind)))
            }

            let isMine = pr.author.lowercased() == item.account.lowercased()
            if isMine, let old, settings.isOn(.myPRApprovedOrCIFailed) {
                // Si el PR acaba de quedar listo para mergear, ese aviso ya dice que se aprobó (spec F.5).
                if !notifiedReady && old.pr.reviewDecision != .approved && pr.reviewDecision == .approved {
                    planned.append(PlannedNotification(
                        kind: .myPRApprovedOrCIFailed, title: "Your PR Was Approved", body: body, url: pr.url,
                        prID: item.id, event: "approved", tab: .merge
                    ))
                }
                if old.pr.ciState != .failure && pr.ciState == .failure {
                    planned.append(PlannedNotification(
                        kind: .myPRApprovedOrCIFailed, title: "CI Failed on Your PR", body: body, url: pr.url,
                        prID: item.id, event: "ciFailed", tab: .fixCI
                    ))
                }
            }
        }
        return group(planned)
    }

    /// Ready to Merge se avisa una vez, cuando GitHub ya calculó la mergeabilidad (con `UNKNOWN` el PR puede resultar
    /// con conflictos): "ya avisado" es haber estado en la categoría con la mergeabilidad conocida. Un snapshot anterior
    /// sin datos de merge (de antes de Ready to Merge) no sirve para comparar: los PRs aprobados no son novedad.
    /// Con conflictos no está listo de verdad (spec F.1.1): avisa cuando se resuelven.
    static func isNewlyReadyToMerge(_ item: ClassifiedPR, old: ClassifiedPR?) -> Bool {
        guard item.pr.merge.mergeable != .unknown, !item.pr.merge.hasConflicts else { return false }
        guard let old else { return true }
        if old.pr.merge.nodeID == nil { return false }
        return old.category != .readyToMerge || old.pr.merge.mergeable == .unknown || old.pr.merge.hasConflicts
    }

    private static func kind(for category: PRCategory) -> NotificationKind? {
        switch category {
        case .toReview: .newToReview
        case .updatedSinceMyReview: .reviewedPRUpdated
        case .myFeedback: .myPRFeedback
        case .other: nil
        case .readyToMerge: .readyToMerge
        }
    }

    /// La pestaña que abre el clic en un aviso del snapshot (spec M.4).
    private static func tab(for kind: NotificationKind) -> PRTab? {
        switch kind {
        case .newToReview, .reviewedPRUpdated: .review
        case .myPRFeedback: .respond
        case .readyToMerge: .merge
        default: nil
        }
    }

    private static func title(for kind: NotificationKind) -> String {
        switch kind {
        case .newToReview: "New PR to Review"
        case .reviewedPRUpdated: "A PR You Reviewed Has New Commits"
        case .myPRFeedback: "Your PR Got Feedback"
        case .reviewFinished: "Review Ready"
        case .myPRApprovedOrCIFailed: "Updates on Your PR"
        case .updateAvailable: "PRBar Update Available"
        case .readyToMerge: "Ready to Merge"
        case .diskUsage: "PRBar Is Using a Lot of Disk"
        }
    }

    private static func groupTitle(for kind: NotificationKind, count: Int) -> String {
        switch kind {
        case .newToReview: "\(count) new PRs to review"
        case .reviewedPRUpdated: "\(count) PRs you reviewed have new commits"
        case .myPRFeedback: "\(count) of your PRs got feedback"
        case .reviewFinished: "\(count) reviews ready"
        case .myPRApprovedOrCIFailed: "\(count) updates on your PRs"
        case .updateAvailable: "\(count) PRBar updates available"
        case .readyToMerge: "\(count) of your PRs are ready to merge"
        case .diskUsage: "PRBar disk usage"
        }
    }

    private static func group(_ planned: [PlannedNotification]) -> [PlannedNotification] {
        guard planned.count > groupingThreshold else { return planned }
        return NotificationKind.allCases.compactMap { kind in
            let list = planned.filter { $0.kind == kind }
            guard !list.isEmpty else { return nil }
            if list.count == 1 { return list[0] }
            return PlannedNotification(
                kind: kind,
                title: groupTitle(for: kind, count: list.count),
                body: list.prefix(3).map(\.body).joined(separator: "\n"),
                url: nil
            )
        }
    }
}

extension NotificationPlanner {
    /// `keptCount == nil` indica que el review falló.
    /// `keptCount == nil` es un review que falló; `recordID` es su registro en el historial (para abrirlo al
    /// hacer click).
    public static func reviewFinished(
        prID: String, repo: RepoRef, number: Int, keptCount: Int?, recordID: UUID? = nil, settings: NotificationSettings
    ) -> PlannedNotification? {
        guard settings.isOn(.reviewFinished) else { return nil }
        let body = keptCount.map { "\(repo.name)#\(number): \($0) comment\($0 == 1 ? "" : "s") to choose from" }
            ?? "\(repo.name)#\(number): the review failed. Open PRBar to see the log."
        return PlannedNotification(kind: .reviewFinished, title: keptCount == nil ? "Review Failed" : "Review Ready",
                                   body: body, url: nil, reviewPRID: prID, reviewRecordID: keptCount == nil ? recordID : nil,
                                   tab: .review)
    }

    /// Hitos de "Responder" que se avisan (con el mismo interruptor que las reviews terminadas).
    public enum RespondEvent: Equatable, Sendable {
        /// Terminó el análisis: `count` comentarios para revisar.
        case analysisReady(count: Int)
        /// Terminaron los fixes: `commits` commits para revisar antes de pushear.
        case fixesReady(commits: Int)
        /// Se publicaron las respuestas (`pushed`: también se pushearon fixes).
        case published(replies: Int, pushed: Bool)
        case failed
        /// Fix CI (spec K.6.7): Claude's fix is ready to review (`commits == 0`: it changed nothing).
        case ciFixReady(commits: Int)
        case ciFixPushed
        case ciFixFailed
        /// Fix CI's push stopped because the checks that failed pass now (spec K.6.6): back to the diff.
        case ciFixNotPushed
    }

    public static func respondFinished(
        prID: String, repo: RepoRef, number: Int, event: RespondEvent, settings: NotificationSettings
    ) -> PlannedNotification? {
        guard settings.isOn(.reviewFinished) else { return nil }
        let ref = "\(repo.name)#\(number)"
        let title: String, body: String, key: String
        let tab: PRTab
        switch event {
        case .analysisReady, .fixesReady, .published, .failed: tab = .respond
        case .ciFixReady, .ciFixPushed, .ciFixFailed, .ciFixNotPushed: tab = .fixCI
        }
        switch event {
        case .analysisReady(let count):
            (title, key) = ("Analysis Ready", "analysis")
            body = "\(ref): \(count) comment\(count == 1 ? "" : "s")"
        case .fixesReady(let commits):
            (title, key) = ("Fixes Ready to Review", "fixes")
            body = commits == 0 ? "\(ref): Claude made no changes" : "\(ref): \(commits) unpushed commit\(commits == 1 ? "" : "s")"
        case .published(let replies, let pushed):
            (title, key) = ("Replies Posted", "published")
            let answers = "\(replies) repl\(replies == 1 ? "y" : "ies") posted"
            body = pushed ? "\(ref): fixes pushed and \(answers)" : "\(ref): \(answers)"
        case .failed:
            (title, key) = ("Couldn't Respond", "failed")
            body = "\(ref): open PRBar to see the error."
        case .ciFixReady(let commits):
            (title, key) = ("CI Fix Ready", "ci-fix")
            body = commits == 0 ? "\(ref): Claude made no changes — see why" : "\(ref): review the fix and push it"
        case .ciFixPushed:
            (title, key) = ("CI Fix Pushed", "ci-pushed")
            body = "\(ref): the fix is on the branch; CI will run again"
        case .ciFixFailed:
            (title, key) = ("Couldn't Fix CI", "ci-failed")
            body = "\(ref): open PRBar to see the error."
        case .ciFixNotPushed:
            (title, key) = ("CI Fix Not Pushed", "ci-not-pushed")
            body = "\(ref): the failing checks pass now. Push Anyway if you still want the fix."
        }
        return PlannedNotification(kind: .reviewFinished, title: title, body: body, url: nil, respondPRID: prID, event: "respond-\(key)",
                                   tab: tab)
    }
}

extension NotificationPlanner {
    /// "PRBar 1.3.0 is available" con la primera línea de las notas (spec D.2). `nil` con las notificaciones apagadas.
    public static func updateAvailable(_ release: ReleaseInfo, settings: NotificationSettings) -> PlannedNotification? {
        guard settings.isOn(.updateAvailable) else { return nil }
        let version = release.version.description
        return PlannedNotification(
            kind: .updateAvailable, title: "PRBar \(version) is available", body: release.summary ?? "Open PRBar to update.",
            url: nil, event: version, updateVersion: version
        )
    }

    /// El total pasó el umbral de Settings › General (spec I). El clic abre la ventana Activity (`event: "disk"`).
    public static func diskWarning(totalBytes: Int64, limitGB: Int, settings: NotificationSettings) -> PlannedNotification? {
        guard settings.isOn(.diskUsage) else { return nil }
        // Formato fijo (no `ByteCountFormatter`): el texto no depende del locale de quien corre los tests.
        let used = String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), Double(totalBytes) / 1_000_000_000)
        return PlannedNotification(kind: .diskUsage, title: "PRBar Is Using a Lot of Disk",
                                   body: "PRBar is using \(used) (your limit is \(limitGB) GB). Open PRBar Activity to clean up.",
                                   url: nil, event: "disk")
    }
}
