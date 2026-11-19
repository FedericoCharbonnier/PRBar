import Foundation

public enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case newToReview, reviewedPRUpdated, myPRFeedback, reviewFinished, myPRApprovedOrCIFailed
    /// Hay una versión nueva de PRBar (spec D.2). Solo depende del interruptor general.
    case updateAvailable
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
    /// Identificador estable: una notificación nueva del mismo evento y PR reemplaza a la anterior en vez de
    /// apilarse.
    public let identifier: String

    public init(
        kind: NotificationKind, title: String, body: String, url: URL?, reviewPRID: String? = nil,
        reviewRecordID: UUID? = nil, respondPRID: String? = nil, prID: String? = nil, event: String? = nil,
        updateVersion: String? = nil
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

            if item.category.countsForBadge, old?.category != item.category,
               let kind = kind(for: item.category), settings.isOn(kind) {
                planned.append(PlannedNotification(kind: kind, title: title(for: kind), body: body, url: pr.url, prID: item.id))
            }

            let isMine = pr.author.lowercased() == item.account.lowercased()
            if isMine, let old, settings.isOn(.myPRApprovedOrCIFailed) {
                if old.pr.reviewDecision != .approved && pr.reviewDecision == .approved {
                    planned.append(PlannedNotification(
                        kind: .myPRApprovedOrCIFailed, title: "Your PR Was Approved", body: body, url: pr.url,
                        prID: item.id, event: "approved"
                    ))
                }
                if old.pr.ciState != .failure && pr.ciState == .failure {
                    planned.append(PlannedNotification(
                        kind: .myPRApprovedOrCIFailed, title: "CI Failed on Your PR", body: body, url: pr.url,
                        prID: item.id, event: "ciFailed"
                    ))
                }
            }
        }
        return group(planned)
    }

    private static func kind(for category: PRCategory) -> NotificationKind? {
        switch category {
        case .toReview: .newToReview
        case .updatedSinceMyReview: .reviewedPRUpdated
        case .myFeedback: .myPRFeedback
        case .other: nil
        case .readyToMerge: nil
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
                                   body: body, url: nil, reviewPRID: prID, reviewRecordID: keptCount == nil ? recordID : nil)
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
    }

    public static func respondFinished(
        prID: String, repo: RepoRef, number: Int, event: RespondEvent, settings: NotificationSettings
    ) -> PlannedNotification? {
        guard settings.isOn(.reviewFinished) else { return nil }
        let ref = "\(repo.name)#\(number)"
        let title: String, body: String, key: String
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
        }
        return PlannedNotification(kind: .reviewFinished, title: title, body: body, url: nil, respondPRID: prID, event: "respond-\(key)")
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
}
