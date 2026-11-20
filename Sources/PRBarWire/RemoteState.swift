import Foundation

// Los tópicos del feed de estado (spec P.6): la Mac los arma con los mismos resultados de `AppCommand` y el teléfono
// los decodifica. Solo Foundation.

/// Un tópico del feed: `home`, `pr:<owner/repo#N>` o `activity`.
public enum RemoteTopic: Hashable, Sendable {
    case home
    case pr(String)
    case activity

    /// Tópicos que la Mac calcula por suscripción (el resto se ignora).
    public static let maxPerSubscription = 20

    public init?(_ text: String) {
        switch text {
        case "home": self = .home
        case "activity": self = .activity
        default:
            guard text.hasPrefix("pr:") else { return nil }
            let id = String(text.dropFirst(3))
            // `owner/repo#N`: una barra, un número positivo, sin espacios ni nada raro.
            let parts = id.split(separator: "#", omittingEmptySubsequences: false)
            guard parts.count == 2, let number = Int(parts[1]), number > 0, String(number) == parts[1] else { return nil }
            let repo = parts[0].split(separator: "/", omittingEmptySubsequences: false)
            guard repo.count == 2, repo.allSatisfy({ part in
                !part.isEmpty && part.count <= 100 && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            }) else { return nil }
            self = .pr(id)
        }
    }

    public var name: String {
        switch self {
        case .home: "home"
        case .activity: "activity"
        case .pr(let id): "pr:\(id)"
        }
    }

    /// Los tópicos válidos de una suscripción, sin repetidos y como mucho `maxPerSubscription`.
    public static func parse(_ topics: [String]) -> [RemoteTopic] {
        var seen = Set<RemoteTopic>()
        return topics.compactMap(RemoteTopic.init).filter { seen.insert($0).inserted }.prefix(maxPerSubscription).map { $0 }
    }
}

/// `home`: las dos pestañas del popover, el estado y el CI fallido (`status` + `listPRs` + `ciList`).
public struct RemoteHome: Codable, Equatable, Sendable {
    public var status: StatusInfo
    public var prs: [PRInfo]
    public var ci: [CIListEntry]

    public init(status: StatusInfo, prs: [PRInfo], ci: [CIListEntry]) {
        self.status = status
        self.prs = prs
        self.ci = ci
    }
}

/// `pr:<id>`: el PR y lo que haya de review, respond y chat (nil = no hay).
public struct RemotePRDetail: Codable, Equatable, Sendable {
    public var pr: PRInfo?
    public var review: ReviewInfo?
    public var respond: RespondInfo?
    public var chat: ChatInfo?

    public init(pr: PRInfo?, review: ReviewInfo?, respond: RespondInfo?, chat: ChatInfo?) {
        self.pr = pr
        self.review = review
        self.respond = respond
        self.chat = chat
    }
}

/// `activity`: recursos, el uso de Claude del mes y los últimos 20 del historial.
public struct RemoteActivity: Codable, Equatable, Sendable {
    public var resources: ResourcesInfo
    public var usage: UsageInfo?
    public var history: [HistoryEntryInfo]

    public init(resources: ResourcesInfo, usage: UsageInfo?, history: [HistoryEntryInfo]) {
        self.resources = resources
        self.usage = usage
        self.history = history
    }
}

/// Lo que nunca sale de la Mac hacia el teléfono (spec P.7: ni rutas locales ni herramientas). Se aplica a cada
/// resultado y a cada tópico: las rutas quedan en su último componente (el nombre de la carpeta o del log) y la lista
/// de herramientas, vacía. Los tipos se siguen decodificando igual.
public enum RemoteRedaction {
    static let pathKeys: Set<String> = ["logPath", "worktree", "path"]

    public static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map(scrub))
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, field) in fields {
                if key == "tools", case .array = field {
                    out[key] = .array([])
                } else if pathKeys.contains(key), case .string(let text) = field {
                    out[key] = .string((text as NSString).lastPathComponent)
                } else {
                    out[key] = scrub(field)
                }
            }
            return .object(out)
        default:
            return value
        }
    }
}
