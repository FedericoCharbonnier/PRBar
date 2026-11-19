import Foundation

public struct SlackChannel: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public let isMember: Bool

    public init(id: String, name: String, isPrivate: Bool, isMember: Bool) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.isMember = isMember
    }
}

public struct SlackChannelList: Equatable, Sendable {
    public let channels: [SlackChannel]
    /// Se llegó al tope de páginas y Slack tenía más canales: la lista está incompleta.
    public let truncated: Bool

    public init(channels: [SlackChannel], truncated: Bool) {
        self.channels = channels
        self.truncated = truncated
    }
}

public struct SlackIdentity: Equatable, Sendable {
    public let team: String
    public let user: String
    /// ID del usuario dueño del token (`U…`).
    public let userID: String

    public init(team: String, user: String, userID: String = "") {
        self.team = team
        self.user = user
        self.userID = userID
    }
}

/// Mensaje raíz de un canal, con lo necesario para encontrar el link de un PR (spec §17.2).
public struct SlackMessage: Equatable, Sendable {
    public let ts: String
    public let text: String
    /// URLs de `attachments[].from_url`/`title_link` y de los `blocks`.
    public let linkedURLs: [String]
    /// Autor (`U…`), cuando se conoce: sirve para reconocer los mensajes propios (anti-duplicados, spec §17.5).
    public let user: String?

    public init(ts: String, text: String, linkedURLs: [String] = [], user: String? = nil) {
        self.ts = ts
        self.text = text
        self.linkedURLs = linkedURLs
        self.user = user
    }
}

/// Un mensaje publicado: su `ts` y, si Slack lo dice, el canal real (p. ej. el `D…` de un DM pedido con un `U…`).
public struct SlackPostResult: Equatable, Sendable {
    public let ts: String
    public let channel: String?

    public init(ts: String, channel: String?) {
        self.ts = ts
        self.channel = channel
    }
}

public protocol SlackAPI: Sendable {
    /// Devuelve el `ts` del mensaje publicado.
    func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String
    /// Como `postMessage`, con el canal real cuando se conoce.
    func postMessageResult(channel: String, text: String, threadTS: String?, token: String) async throws -> SlackPostResult
    /// El mensaje `ts` y sus respuestas, en orden (el padre primero).
    func threadReplies(channel: String, ts: String, token: String) async throws -> [SlackMessage]
    func authTest(token: String) async throws -> SlackIdentity
    func channels(token: String) async throws -> SlackChannelList
    /// Mensajes raíz del canal desde `oldest`, los más nuevos primero (hasta `SlackClient.historyLimit` revisados).
    func history(channel: String, oldest: Date, token: String) async throws -> [SlackMessage]
    /// `already_reacted` no es un error.
    func addReaction(channel: String, ts: String, name: String, token: String) async throws
}

public extension SlackAPI {
    func postMessageResult(channel: String, text: String, threadTS: String?, token: String) async throws -> SlackPostResult {
        SlackPostResult(ts: try await postMessage(channel: channel, text: text, threadTS: threadTS, token: token), channel: nil)
    }
}

public struct SlackClient: SlackAPI {
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private static let maxChannelPages = 10
    private static let channelPageSize = 200
    /// Máximo de canales que se listan (`maxChannelPages` × `channelPageSize`).
    public static let channelLimit = maxChannelPages * channelPageSize
    private static let historyPageSize = 200
    /// Máximo de mensajes que se revisan al buscar el mensaje de un PR.
    public static let historyLimit = 1000

    private struct Envelope: Decodable { let ok: Bool; let error: String? }

    public init(transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func postMessage(channel: String, text: String, threadTS: String?, token: String) async throws -> String {
        try await postMessageResult(channel: channel, text: text, threadTS: threadTS, token: token).ts
    }

    public func postMessageResult(channel: String, text: String, threadTS: String?, token: String) async throws -> SlackPostResult {
        struct Response: Decodable { let ts: String; let channel: String? }
        var body: [String: Any] = ["channel": channel, "text": text]
        if let threadTS { body["thread_ts"] = threadTS }
        let response: Response = try await call("chat.postMessage", json: body, token: token)
        return SlackPostResult(ts: response.ts, channel: response.channel)
    }

    public func threadReplies(channel: String, ts: String, token: String) async throws -> [SlackMessage] {
        struct Response: Decodable {
            struct Message: Decodable { let ts: String; let text: String?; let user: String? }
            let messages: [Message]
        }
        let response: Response = try await call(
            "conversations.replies", query: ["channel": channel, "ts": ts, "limit": "\(Self.historyPageSize)"], token: token
        )
        return response.messages.map { SlackMessage(ts: $0.ts, text: $0.text ?? "", user: $0.user) }
    }

    public func authTest(token: String) async throws -> SlackIdentity {
        struct Response: Decodable { let team: String; let user: String; let user_id: String? }
        let response: Response = try await call("auth.test", json: [:], token: token)
        return SlackIdentity(team: response.team, user: response.user, userID: response.user_id ?? "")
    }

    public func history(channel: String, oldest: Date, token: String) async throws -> [SlackMessage] {
        struct Response: Decodable {
            struct Message: Decodable {
                struct Attachment: Decodable { let from_url: String?; let title_link: String? }
                let ts: String
                let text: String?
                let user: String?
                let thread_ts: String?
                let attachments: [Attachment]?
                let blocks: SlackBlockJSON?
            }
            struct Metadata: Decodable { let next_cursor: String? }
            let messages: [Message]
            let response_metadata: Metadata?
        }
        var result: [SlackMessage] = []
        var seen = 0
        var cursor: String?
        while seen < Self.historyLimit {
            var query = [
                "channel": channel,
                "oldest": String(format: "%.6f", oldest.timeIntervalSince1970),
                "limit": "\(min(Self.historyPageSize, Self.historyLimit - seen))",
            ]
            if let cursor { query["cursor"] = cursor }
            let response: Response = try await call("conversations.history", query: query, token: token)
            seen += response.messages.count
            for message in response.messages where message.thread_ts == nil || message.thread_ts == message.ts {
                let attachmentURLs = (message.attachments ?? []).flatMap { [$0.from_url, $0.title_link].compactMap { $0 } }
                result.append(SlackMessage(ts: message.ts, text: message.text ?? "",
                                           linkedURLs: attachmentURLs + (message.blocks?.urls ?? []), user: message.user))
            }
            guard let next = response.response_metadata?.next_cursor, !next.isEmpty, !response.messages.isEmpty else { break }
            cursor = next
        }
        return result
    }

    public func addReaction(channel: String, ts: String, name: String, token: String) async throws {
        struct Response: Decodable {}
        do {
            let _: Response = try await call("reactions.add", json: ["channel": channel, "timestamp": ts, "name": name], token: token)
        } catch PRBarError.slack("already_reacted") {
            return
        }
    }

    public func channels(token: String) async throws -> SlackChannelList {
        struct Response: Decodable {
            struct Channel: Decodable {
                let id: String
                let name: String
                let is_private: Bool?
                let is_member: Bool?
            }
            struct Metadata: Decodable { let next_cursor: String? }
            let channels: [Channel]
            let response_metadata: Metadata?
        }
        var result: [SlackChannel] = []
        var cursor: String?
        var truncated = false
        for page in 0..<Self.maxChannelPages {
            var query = ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": "\(Self.channelPageSize)"]
            if let cursor { query["cursor"] = cursor }
            let response: Response = try await call("conversations.list", query: query, token: token)
            result += response.channels.map {
                SlackChannel(id: $0.id, name: $0.name, isPrivate: $0.is_private ?? false, isMember: $0.is_member ?? false)
            }
            guard let next = response.response_metadata?.next_cursor, !next.isEmpty else { break }
            if page == Self.maxChannelPages - 1 { truncated = true }
            cursor = next
        }
        let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SlackChannelList(channels: sorted, truncated: truncated)
    }

    private func call<T: Decodable>(_ method: String, json: [String: Any]? = nil, query: [String: String]? = nil, token: String) async throws -> T {
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        if let query {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as PRBarError {
            throw error
        } catch {
            throw PRBarError.network(error.localizedDescription)
        }

        if response.statusCode == 429 {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) } ?? 60
            throw PRBarError.rateLimited(resetAt: now().addingTimeInterval(retry))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PRBarError.http(status: response.statusCode, message: "Slack \(method)")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("Slack \(method): \(error)")
        }
        guard envelope.ok else { throw PRBarError.slack(envelope.error ?? "unknown_error") }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PRBarError.invalidResponse("Slack \(method): \(error)")
        }
    }
}

/// JSON genérico para recorrer los `blocks` de Slack, cuyo esquema varía por tipo de bloque.
indirect enum SlackBlockJSON: Decodable, Sendable {
    case string(String)
    case array([SlackBlockJSON])
    case object([String: SlackBlockJSON])
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([SlackBlockJSON].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: SlackBlockJSON].self) {
            self = .object(object)
        } else {
            self = .other
        }
    }

    /// Todos los valores string de claves `url` (links de `rich_text`, botones, etc.), en orden de aparición.
    var urls: [String] {
        switch self {
        case .array(let values): return values.flatMap(\.urls)
        case .object(let object):
            var found: [String] = []
            for key in object.keys.sorted() {
                if key == "url", case .string(let url)? = object[key] { found.append(url) }
                found += object[key]?.urls ?? []
            }
            return found
        case .string, .other: return []
        }
    }
}
