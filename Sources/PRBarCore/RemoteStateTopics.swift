import Foundation

/// Cómo se calcula cada tópico del feed (spec P.6) con los mismos métodos que usan la UI y `prbar`.
@MainActor
public enum RemoteStateTopics {
    public static func home(_ actions: any PRBarActions) async throws -> RemoteHome {
        RemoteHome(status: try await actions.status(), prs: try actions.listPRs(list: nil, account: nil, tab: nil),
                   ci: try actions.ciList())
    }

    /// `review`/`respond`/`chat` en nil cuando "no hay" (`notFound`/`invalidState`); otro error se propaga.
    public static func prDetail(_ id: String, _ actions: any PRBarActions) throws -> RemotePRDetail {
        func optional<T>(_ body: () throws -> T) throws -> T? {
            do {
                return try body()
            } catch let failure as CommandFailure where failure.code == .notFound || failure.code == .invalidState {
                return nil
            }
        }
        let pr = try actions.listPRs(list: nil, account: nil, tab: nil).first { $0.id == id }
        return RemotePRDetail(pr: pr, review: try optional { try actions.reviewShow(pr: id) },
                              respond: try optional { try actions.respondShow(pr: id) },
                              chat: try optional { try actions.chatShow(pr: id) })
    }

    public static func activity(_ actions: any PRBarActions) async throws -> RemoteActivity {
        RemoteActivity(resources: await actions.resources(), usage: try? actions.usage(month: nil),
                       history: actions.historyList(repo: nil, kind: nil, limit: 20, search: nil))
    }

    /// El valor de un tópico, ya sin rutas locales (`RemoteRedaction`).
    public static func compute(_ topic: RemoteTopic, _ actions: any PRBarActions) async throws -> JSONValue {
        let value: JSONValue = switch topic {
        case .home: try JSONValue(encoding: try await home(actions))
        case .pr(let id): try JSONValue(encoding: try prDetail(id, actions))
        case .activity: try JSONValue(encoding: try await activity(actions))
        }
        return RemoteRedaction.scrub(value)
    }
}
