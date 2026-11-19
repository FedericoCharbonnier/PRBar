import Foundation

public enum SlackAction: Equatable, Sendable {
    /// `channelName` solo sirve para los mensajes de error (p. ej. "Join #x to post there").
    case announce(prID: String, repo: RepoRef, channelID: String, channelName: String?, text: String)
    /// `handledReviewAt`: `submittedAt` de la review que este "Updated" responde.
    case update(prID: String, repo: RepoRef, channelID: String, channelName: String?, threadTS: String, text: String, handledReviewAt: Date)
    /// Buscar en el canal el mensaje raíz con el link de un PR ajeno (spec §17.2, punto 1).
    case findMessage(prID: String, repo: RepoRef, channelID: String, channelName: String?, prURL: URL)
    /// Reaccionar al mensaje del PR ajeno.
    case react(prID: String, repo: RepoRef, channelName: String?, ref: SlackMessageRef, emoji: String, kind: ReviewReactionKind)
    /// "commented xN" en el hilo del mensaje del PR ajeno; `round` = N.
    case reply(prID: String, repo: RepoRef, channelName: String?, ref: SlackMessageRef, text: String, round: Int)
    /// "Merged" en el hilo del anuncio de un PR mío que mergeé desde PRBar (spec F.4).
    case merged(prID: String, repo: RepoRef, channelID: String, threadTS: String, text: String)

    public var prID: String {
        switch self {
        case .announce(let prID, _, _, _, _), .update(let prID, _, _, _, _, _, _), .findMessage(let prID, _, _, _, _),
             .react(let prID, _, _, _, _, _), .reply(let prID, _, _, _, _, _), .merged(let prID, _, _, _, _): prID
        }
    }

    public var repo: RepoRef {
        switch self {
        case .announce(_, let repo, _, _, _), .update(_, let repo, _, _, _, _, _), .findMessage(_, let repo, _, _, _),
             .react(_, let repo, _, _, _, _), .reply(_, let repo, _, _, _, _), .merged(_, let repo, _, _, _): repo
        }
    }

    public var channelName: String? {
        switch self {
        case .announce(_, _, _, let name, _), .update(_, _, _, let name, _, _, _), .findMessage(_, _, _, let name, _),
             .react(_, _, let name, _, _, _), .reply(_, _, let name, _, _, _): name
        case .merged: nil
        }
    }
}

public struct SlackPlan: Equatable, Sendable {
    public var actions: [SlackAction] = []
    public var newDrafts: Set<String> = []

    public init(actions: [SlackAction] = [], newDrafts: Set<String> = []) {
        self.actions = actions
        self.newDrafts = newDrafts
    }
}

/// Decide qué mandar a Slack (spec §17, antes §15.2). Función pura: no hace red ni disco.
public enum SlackPlanner {
    /// Sin mensaje encontrado, la búsqueda de un PR se repite como máximo cada 10 minutos.
    public static let searchInterval: TimeInterval = 10 * 60
    /// Un "Merged" que no se pudo publicar se reintenta en cada ciclo durante un día como máximo.
    public static let mergedReplyWindow: TimeInterval = 24 * 60 * 60

    /// `now` (por defecto, la hora del snapshot) solo se usa para espaciar las búsquedas.
    public static func plan(snapshot: Snapshot, config: AppConfig, state: SlackState, now: Date? = nil) -> SlackPlan {
        guard config.slack.enabled else { return SlackPlan() }
        var plan = SlackPlan()
        var plannedOthers: Set<String> = []

        for account in config.accounts where account.enabled {
            let me = account.login.lowercased()
            for repoConfig in account.repos {
                guard let channelID = repoConfig.slackChannelID,
                      let enabledAt = repoConfig.slackEnabledAt,
                      snapshot.fetchedScopes.contains(Snapshot.scope(account: account.login, repo: repoConfig.repo))
                else { continue }

                // Solo PRs nuevos: posteriores al canal, al baseline del estado y a encender Slack (spec §15.2).
                let cutoff = max(enabledAt, state.baselineAt, config.slack.enabledAt ?? .distantPast)
                let inRepo = snapshot.items.filter { $0.account == account.login && $0.pr.repo == repoConfig.repo }
                for item in inRepo where item.pr.author.lowercased() != me && plannedOthers.insert(item.pr.id).inserted {
                    // Mis reviews no cuentan antes de activar las reacciones, de encender Slack, de elegir el canal ni
                    // del baseline del estado (perder el estado no repite "commented xN").
                    guard let reactionsStart = config.slack.reviewReactionsEnabledAt else { continue }
                    let since = max(reactionsStart, config.slack.enabledAt ?? .distantPast, enabledAt, state.baselineAt)
                    plan.actions += reviewActions(
                        item.pr, me: me, since: since, channelID: channelID, channelName: repoConfig.slackChannelName,
                        settings: config.slack, tracking: state.reviewTracking[item.pr.id] ?? ReviewTracking(),
                        now: now ?? snapshot.fetchedAt
                    )
                }
                let mine = inRepo.filter { $0.pr.author.lowercased() == me }
                for item in mine {
                    let pr = item.pr
                    if let announcement = state.announcements[pr.id] {
                        if config.slack.postUpdated, let handledReviewAt = reviewNeedingUpdate(pr, me: me, since: announcement.lastHandledReviewAt ?? announcement.announcedAt) {
                            plan.actions.append(.update(
                                prID: pr.id, repo: pr.repo, channelID: announcement.channelID,
                                channelName: announcement.channelID == channelID ? repoConfig.slackChannelName : nil,
                                threadTS: announcement.ts,
                                text: SlackTemplate.render(config.slack.effectiveUpdateTemplate, pr: pr),
                                handledReviewAt: handledReviewAt
                            ))
                        }
                        continue
                    }
                    // Un draft cuenta como visto solo si se registró desde el corte; si no, se vuelve a registrar.
                    let seenAsDraft = state.seenAsDraft[pr.id].map { $0 >= cutoff } ?? false
                    if pr.isDraft {
                        if !seenAsDraft { plan.newDrafts.insert(pr.id) }
                    } else if config.slack.announceNewPRs && (pr.createdAt >= cutoff || seenAsDraft) {
                        plan.actions.append(.announce(
                            prID: pr.id, repo: pr.repo, channelID: channelID, channelName: repoConfig.slackChannelName,
                            text: SlackTemplate.render(config.slack.effectiveNewPRTemplate, pr: pr)
                        ))
                    }
                }
            }
        }
        // "Merged" en el hilo de los PRs que mergeé desde PRBar (spec F.4). No depende del snapshot: el PR ya no
        // está abierto.
        if config.slack.postMerged {
            let reference = now ?? snapshot.fetchedAt
            for (prID, reply) in state.mergedReplies.sorted(by: { $0.key < $1.key })
            where reply.postedAt == nil && reference.timeIntervalSince(reply.requestedAt) < mergedReplyWindow {
                plan.actions.append(.merged(
                    prID: prID, repo: reply.repo, channelID: reply.channelID, threadTS: reply.threadTS, text: reply.text
                ))
            }
        }
        return plan
    }

    /// Acciones por mis reviews de un PR ajeno (spec §17.2), en orden: 👀, 💬, "commented xN" y aprobado.
    /// Sin mensaje encontrado solo se busca, y solo si alguna reacción saldría al encontrarlo.
    static func reviewActions(
        _ pr: PullRequest, me: String, since: Date, channelID: String, channelName: String?,
        settings: SlackSettings, tracking: ReviewTracking, now: Date
    ) -> [SlackAction] {
        enum Step { case react(ReviewReactionKind), reply(round: Int) }
        let rounds = ReviewRounds.compute(reviews: pr.reviews, me: me, since: since)
        /// Una reacción ya hecha, o rechazada por Slack con el mismo emoji, no se vuelve a pedir.
        func pending(_ kind: ReviewReactionKind) -> Bool {
            !tracking.hasReacted(kind) && !tracking.emojiFailed(kind, emoji: emoji(for: kind, settings))
        }
        var steps: [Step] = []
        if settings.reactOnReviewStart, rounds.firstReviewAt != nil || tracking.pendingEyes, pending(.eyes) {
            steps.append(.react(.eyes))
        }
        if settings.reactOnFirstComment, rounds.commentRounds >= 1, pending(.comment) {
            steps.append(.react(.comment))
        }
        let firstRoundToPost = max(2, tracking.roundsPosted + 1)
        if settings.postRoundMessages, firstRoundToPost <= rounds.commentRounds {
            steps += (firstRoundToPost...rounds.commentRounds).map { .reply(round: $0) }
        }
        if settings.reactOnApprove, rounds.approved, pending(.approved) {
            steps.append(.react(.approved))
        }
        guard !steps.isEmpty else { return [] }

        guard let ref = tracking.message else {
            if let last = tracking.lastSearchAt, now.timeIntervalSince(last) < searchInterval { return [] }
            return [.findMessage(prID: pr.id, repo: pr.repo, channelID: channelID, channelName: channelName, prURL: pr.url)]
        }
        return steps.map { step in
            switch step {
            case .react(let kind):
                .react(prID: pr.id, repo: pr.repo, channelName: channelName, ref: ref, emoji: emoji(for: kind, settings), kind: kind)
            case .reply(let round):
                .reply(prID: pr.id, repo: pr.repo, channelName: channelName, ref: ref,
                       text: SlackTemplate.render(settings.effectiveRoundTemplate, pr: pr, n: round), round: round)
            }
        }
    }

    static func emoji(for kind: ReviewReactionKind, _ settings: SlackSettings) -> String {
        switch kind {
        case .eyes: settings.effectiveEyesEmoji
        case .comment: settings.effectiveCommentEmoji
        case .approved: settings.effectiveApprovedEmoji
        }
    }

    /// Si alguna review de otra persona (no bot) posterior a `since` se hizo sobre un commit que ya no es el head
    /// (hubo un push o un "Update branch" después), devuelve el `submittedAt` más reciente entre todas esas
    /// reviews sin manejar, así la próxima ronda arranca después de todas. Sin relojes ni fechas de commit.
    static func reviewNeedingUpdate(_ pr: PullRequest, me: String, since: Date) -> Date? {
        let unhandled = pr.reviews.filter {
            !$0.isBot && $0.author.lowercased() != me
                && [.approved, .changesRequested, .commented].contains($0.state)
                && $0.submittedAt > since
        }
        guard unhandled.contains(where: { $0.commitOID != nil && $0.commitOID != pr.headOid }) else { return nil }
        return unhandled.map(\.submittedAt).max()
    }
}
