import Foundation

public struct SlackAnnouncement: Codable, Equatable, Sendable {
    public var channelID: String
    public var ts: String
    public var announcedAt: Date
    /// `submittedAt` de la última review que ya se respondió con un "Updated" (no la hora del post), así una
    /// review que llega mientras se postea no queda tapada.
    public var lastHandledReviewAt: Date?

    public init(channelID: String, ts: String, announcedAt: Date, lastHandledReviewAt: Date? = nil) {
        self.channelID = channelID
        self.ts = ts
        self.announcedAt = announcedAt
        self.lastHandledReviewAt = lastHandledReviewAt
    }

    private enum CodingKeys: String, CodingKey { case channelID, ts, announcedAt, lastHandledReviewAt, lastUpdatePostedAt }

    /// Los archivos viejos guardaban `lastUpdatePostedAt` (hora del post): toda review anterior ya estaba manejada.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelID = try c.decode(String.self, forKey: .channelID)
        ts = try c.decode(String.self, forKey: .ts)
        announcedAt = try c.decode(Date.self, forKey: .announcedAt)
        lastHandledReviewAt = try c.decodeIfPresent(Date.self, forKey: .lastHandledReviewAt)
            ?? c.decodeIfPresent(Date.self, forKey: .lastUpdatePostedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelID, forKey: .channelID)
        try c.encode(ts, forKey: .ts)
        try c.encode(announcedAt, forKey: .announcedAt)
        try c.encodeIfPresent(lastHandledReviewAt, forKey: .lastHandledReviewAt)
    }
}

/// Mensaje de Slack (canal + `ts`) donde se anunció un PR ajeno.
public struct SlackMessageRef: Codable, Hashable, Sendable {
    public var channelID: String
    public var ts: String

    public init(channelID: String, ts: String) {
        self.channelID = channelID
        self.ts = ts
    }
}

/// Reacciones a mis reviews en un PR ajeno (spec §17.2).
public enum ReviewReactionKind: String, Codable, CaseIterable, Sendable {
    case eyes, comment, approved
}

/// Lo hecho en Slack por mis reviews de un PR ajeno.
public struct ReviewTracking: Codable, Equatable, Sendable {
    /// Mensaje raíz del canal con el link del PR; `nil` si todavía no se encontró.
    public var message: SlackMessageRef?
    /// Última búsqueda del mensaje (encontrado o no): sin mensaje se reintenta cada 10 minutos como máximo.
    public var lastSearchAt: Date?
    /// Reacciones ya hechas: `ReviewReactionKind.rawValue`.
    public var reacted: Set<String> = []
    /// Última ronda con mensaje "commented xN" en el hilo (0 = ninguna).
    public var roundsPosted = 0
    /// Se apretó Review en PRBar y todavía no se reaccionó con 👀.
    public var pendingEyes = false
    /// Emoji que Slack rechazó (`invalid_name`) por reacción: no se reintenta hasta que cambie el configurado.
    public var failedEmoji: [String: String] = [:]

    public init(
        message: SlackMessageRef? = nil, lastSearchAt: Date? = nil, reacted: Set<String> = [], roundsPosted: Int = 0,
        pendingEyes: Bool = false, failedEmoji: [String: String] = [:]
    ) {
        self.message = message
        self.lastSearchAt = lastSearchAt
        self.reacted = reacted
        self.roundsPosted = roundsPosted
        self.pendingEyes = pendingEyes
        self.failedEmoji = failedEmoji
    }

    private enum CodingKeys: String, CodingKey { case message, lastSearchAt, reacted, roundsPosted, pendingEyes, failedEmoji }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try? c.decodeIfPresent(SlackMessageRef.self, forKey: .message)
        lastSearchAt = try c.decodeIfPresent(Date.self, forKey: .lastSearchAt)
        reacted = try c.decodeIfPresent(Set<String>.self, forKey: .reacted) ?? []
        roundsPosted = try c.decodeIfPresent(Int.self, forKey: .roundsPosted) ?? 0
        pendingEyes = try c.decodeIfPresent(Bool.self, forKey: .pendingEyes) ?? false
        failedEmoji = try c.decodeIfPresent([String: String].self, forKey: .failedEmoji) ?? [:]
    }

    public func hasReacted(_ kind: ReviewReactionKind) -> Bool { reacted.contains(kind.rawValue) }

    /// La reacción ya falló con este mismo emoji (`invalid_name`).
    public func emojiFailed(_ kind: ReviewReactionKind, emoji: String) -> Bool { failedEmoji[kind.rawValue] == emoji }
}

/// Espera de un PR tras errores del conector de Claude (spec §17.5): 10, 30 y después 60 minutos.
public struct SlackBackoff: Codable, Equatable, Sendable {
    public static let delays: [TimeInterval] = [10 * 60, 30 * 60, 60 * 60]

    /// Errores seguidos.
    public var failures: Int
    /// No se intenta nada de ese PR antes de esta hora.
    public var until: Date

    public init(failures: Int, until: Date) {
        self.failures = failures
        self.until = until
    }

    public static func next(after previous: SlackBackoff?, now: Date) -> SlackBackoff {
        let failures = (previous?.failures ?? 0) + 1
        return SlackBackoff(failures: failures, until: now.addingTimeInterval(delays[min(failures, delays.count) - 1]))
    }
}

/// "Merged" en el hilo de un PR mío que mergeé desde PRBar (spec F.4): pendiente hasta que se publica.
public struct MergedReply: Codable, Equatable, Sendable {
    public var repo: RepoRef
    public var channelID: String
    /// `ts` del anuncio: la respuesta va en su hilo.
    public var threadTS: String
    /// Texto ya armado con la plantilla (el método solo se conoce al mergear).
    public var text: String
    public var requestedAt: Date
    /// `nil` mientras no se publicó.
    public var postedAt: Date?

    public init(repo: RepoRef, channelID: String, threadTS: String, text: String, requestedAt: Date, postedAt: Date? = nil) {
        self.repo = repo
        self.channelID = channelID
        self.threadTS = threadTS
        self.text = text
        self.requestedAt = requestedAt
        self.postedAt = postedAt
    }
}

public struct SlackState: Codable, Equatable, Sendable {
    /// Desde cuándo vale este estado. Un estado nuevo (sin archivo, o el anterior era ilegible) arranca en
    /// `now`: así perder el archivo no vuelve a anunciar los PRs que ya existían (spec §15.3).
    public var baselineAt: Date
    /// Clave: `owner/repo#número`.
    public var announcements: [String: SlackAnnouncement] = [:]
    /// PRs vistos como draft con el canal ya configurado, con la fecha en que se vieron: se anuncian al
    /// pasar a ready si esa fecha no es anterior al corte del planner.
    public var seenAsDraft: [String: Date] = [:]
    /// Se borró el token de bot de §15 y todavía no se pegó el de usuario (spec §17): la UI lo pide.
    public var needsUserToken = false
    /// Reacciones a mis reviews en PRs ajenos. Clave: `owner/repo#número`.
    public var reviewTracking: [String: ReviewTracking] = [:]
    /// Escrituras empezadas cuyo resultado no se confirmó (clave: `uncertainKey(for:)`), con la hora del primer
    /// intento. Se guardan antes de escribir: después de un error dudoso o de un cierre a mitad de camino, PRBar
    /// busca en Slack si ya se hizo antes de volver a intentarlo (spec §17.5).
    public var uncertain: [String: Date] = [:]
    /// Backoff por PR tras errores del conector. Clave: `owner/repo#número`.
    public var backoff: [String: SlackBackoff] = [:]
    /// ID de Slack (`U…`) de quien publica, para reconocer sus mensajes. Se olvida al cambiar de conexión.
    public var selfUserID: String?
    /// "Merged" pedidos al mergear desde PRBar. Clave: `owner/repo#número`.
    public var mergedReplies: [String: MergedReply] = [:]

    public init(baselineAt: Date) {
        self.baselineAt = baselineAt
    }

    /// Cuánto se guarda un "Merged" pedido: el día de reintentos (`SlackPlanner.mergedReplyWindow`) y un día más, que
    /// sigue evitando pedirlo dos veces para el mismo PR.
    public static let mergedReplyRetention: TimeInterval = SlackPlanner.mergedReplyWindow + 24 * 60 * 60

    /// Borra los "Merged" pedidos hace más de `mergedReplyRetention`. Devuelve `true` si borró alguno.
    public mutating func pruneMergedReplies(now: Date) -> Bool {
        let before = mergedReplies.count
        mergedReplies = mergedReplies.filter { now.timeIntervalSince($0.value.requestedAt) <= Self.mergedReplyRetention }
        return mergedReplies.count != before
    }

    /// Clave de una escritura no idempotente (anuncio, "Updated", "commented xN"); las reacciones no la necesitan:
    /// repetirlas no duplica nada.
    public static func uncertainKey(for action: SlackAction) -> String? {
        switch action {
        case .announce(let prID, _, _, _, _): "announce:\(prID)"
        case .update(let prID, _, _, _, _, _, _): "update:\(prID)"
        case .reply(let prID, _, _, _, _, let round): "reply:\(prID):\(round)"
        case .merged(let prID, _, _, _, _): "merged:\(prID)"
        case .findMessage, .react: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case baselineAt, announcements, seenAsDraft, needsUserToken, reviewTracking, uncertain, backoff, selfUserID
        case mergedReplies
    }

    /// Lectura tolerante. Un archivo sin `baselineAt` es anterior a ese campo: el estado no se perdió, así que
    /// vale desde siempre. `seenAsDraft` era una lista sin fechas; esas entradas quedan viejas y el planner
    /// las vuelve a registrar si el PR sigue en draft.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baselineAt = try c.decodeIfPresent(Date.self, forKey: .baselineAt) ?? .distantPast
        announcements = try c.decodeIfPresent([String: SlackAnnouncement].self, forKey: .announcements) ?? [:]
        if let dated = try? c.decodeIfPresent([String: Date].self, forKey: .seenAsDraft) {
            seenAsDraft = dated
        } else if let legacy = try? c.decodeIfPresent([String].self, forKey: .seenAsDraft) {
            seenAsDraft = Dictionary(legacy.map { ($0, Date.distantPast) }, uniquingKeysWith: { first, _ in first })
        }
        needsUserToken = try c.decodeIfPresent(Bool.self, forKey: .needsUserToken) ?? false
        reviewTracking = try c.decodeIfPresent([String: ReviewTracking].self, forKey: .reviewTracking) ?? [:]
        uncertain = (try? c.decodeIfPresent([String: Date].self, forKey: .uncertain)) ?? [:]
        backoff = (try? c.decodeIfPresent([String: SlackBackoff].self, forKey: .backoff)) ?? [:]
        selfUserID = try? c.decodeIfPresent(String.self, forKey: .selfUserID)
        mergedReplies = (try? c.decodeIfPresent([String: MergedReply].self, forKey: .mergedReplies)) ?? [:]
    }
}

public struct SlackStateStore: Sendable {
    private let url: URL

    public init(url: URL = AppPaths.slackStateFile) {
        self.url = url
    }

    /// Sin archivo, o con uno ilegible (que se mueve a `slack-state.json.bak`), arranca un estado nuevo con
    /// `baselineAt = now` y lo guarda enseguida para que el baseline sobreviva a un reinicio.
    public func load(now: Date = Date()) -> SlackState {
        if let data = try? Data(contentsOf: url) {
            do {
                return try JSONCoding.decoder.decode(SlackState.self, from: data)
            } catch {
                AppLog.write("slack-state.json is unreadable; moving it to .bak and starting over: \(error)")
                backUpUnreadableFile()
            }
        }
        let fresh = SlackState(baselineAt: now)
        do {
            try save(fresh)
        } catch {
            AppLog.write("Couldn't save slack-state.json: \(error)")
        }
        return fresh
    }

    public func save(_ state: SlackState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(state).write(to: url, options: .atomic)
    }

    private func backUpUnreadableFile() {
        let backup = url.appendingPathExtension("bak")
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.moveItem(at: url, to: backup)
        } catch {
            AppLog.write("Couldn't move slack-state.json to .bak: \(error)")
        }
    }
}
