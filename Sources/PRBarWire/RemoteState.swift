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
///
/// Los campos opcionales (nombres, aprobaciones, archivos en `PRInfo`; checks fallidos en `CIListEntry`) son lo que
/// muestra el iPhone y ningún comando necesitaba: un teléfono o una Mac sin ellos siguen funcionando (spec R.7).
public struct RemoteHome: Codable, Equatable, Sendable {
    public var status: StatusInfo
    public var prs: [PRInfo]
    public var ci: [CIListEntry]
    /// Comentarios incluidos de un review listo, por PR ("4 comments").
    public var findingCounts: [String: Int]?

    public init(status: StatusInfo, prs: [PRInfo], ci: [CIListEntry], findingCounts: [String: Int]? = nil) {
        self.status = status
        self.prs = prs
        self.ci = ci
        self.findingCounts = findingCounts
    }
}

/// `pr:<id>`: el PR y lo que haya de review, respond y chat (nil = no hay).
public struct RemotePRDetail: Codable, Equatable, Sendable {
    public var pr: PRInfo?
    public var review: ReviewInfo?
    public var respond: RespondInfo?
    public var chat: ChatInfo?
    /// El canal de Slack donde PRBar avisa el merge de este PR ("#web-reviews"), si ese aviso está prendido.
    public var slackChannel: String?

    public init(pr: PRInfo?, review: ReviewInfo?, respond: RespondInfo?, chat: ChatInfo?, slackChannel: String? = nil) {
        self.pr = pr
        self.review = review
        self.respond = respond
        self.chat = chat
        self.slackChannel = slackChannel
    }
}

/// `activity`: recursos, el uso de Claude del mes y los últimos 20 del historial.
public struct RemoteActivity: Codable, Equatable, Sendable {
    public var resources: ResourcesInfo
    public var usage: UsageInfo?
    public var history: [HistoryEntryInfo]
    /// Los totales de la Mac (las tarjetas de Activity: núcleos, RAM, disco). `resources` solo trae lo de PRBar.
    public var system: MacSystemInfo?
    /// Los trabajos en curso con su hora de inicio (y su costo, cuando se sepa).
    public var running: [RunningJobInfo]?

    public init(resources: ResourcesInfo, usage: UsageInfo?, history: [HistoryEntryInfo], system: MacSystemInfo? = nil,
                running: [RunningJobInfo]? = nil) {
        self.resources = resources
        self.usage = usage
        self.history = history
        self.system = system
        self.running = running
    }
}

/// La Mac entera, no solo PRBar.
public struct MacSystemInfo: Codable, Equatable, Sendable {
    public var cores: Int
    public var memoryTotalBytes: UInt64
    public var memoryUsedBytes: UInt64
    public var diskFreeBytes: Int64
    public var diskTotalBytes: Int64

    public init(cores: Int, memoryTotalBytes: UInt64, memoryUsedBytes: UInt64, diskFreeBytes: Int64, diskTotalBytes: Int64) {
        self.cores = cores
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
    }
}

/// Un trabajo en curso (`StatusInfo.jobs` con más datos).
public struct RunningJobInfo: Codable, Equatable, Sendable {
    public var pr: String
    /// `review`, `respond` (Fix CI también) o `merge`.
    public var kind: String
    /// El título del PR.
    public var title: String
    /// La fase (`JobInfo.phase`).
    public var phase: String
    /// Cuándo arrancó el proceso de Claude más viejo del trabajo; nil si todavía no hay ninguno.
    public var startedAt: Date?
    /// Lo que lleva gastado. Claude informa el costo recién al terminar: hoy siempre nil mientras corre.
    public var costUSD: Double?

    public init(pr: String, kind: String, title: String, phase: String, startedAt: Date?, costUSD: Double? = nil) {
        self.pr = pr
        self.kind = kind
        self.title = title
        self.phase = phase
        self.startedAt = startedAt
        self.costUSD = costUSD
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
