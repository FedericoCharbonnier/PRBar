import Foundation

/// Cómo se calcula cada tópico del feed (spec P.6) con los mismos métodos que usan la UI y `prbar`, más lo que el
/// iPhone muestra y ningún comando necesitaba (spec R.7): todo sale de lo que la app ya tiene, sin pedirle nada nuevo a
/// GitHub.
@MainActor
public enum RemoteStateTopics {
    public static func home(_ actions: any PRBarActions) async throws -> RemoteHome {
        let prs = try actions.listPRs(list: nil, account: nil, tab: nil)
        var findingCounts: [String: Int] = [:]
        for pr in prs where pr.review == "ready" {
            if let review = try? actions.reviewShow(pr: pr.id) {
                findingCounts[pr.id] = review.findings.filter(\.included).count
            }
        }
        return RemoteHome(status: try await actions.status(), prs: prs, ci: try actions.ciList(),
                          findingCounts: findingCounts.isEmpty ? nil : findingCounts)
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
                              chat: try optional { try actions.chatShow(pr: id) },
                              slackChannel: pr.flatMap { mergeChannel(for: $0, actions) })
    }

    /// El canal donde PRBar avisa el merge del PR: Slack prendido, el aviso de merge prendido y el repo con canal.
    public static func mergeChannel(for pr: PRInfo, _ actions: any PRBarActions) -> String? {
        let slack = actions.slackShow()
        guard slack.enabled, slack.toggles[SlackToggleName.merged.rawValue] ?? false,
              let repo = try? actions.repoList(account: pr.account).first(where: { $0.id == pr.repo }),
              let channel = repo.slackChannel, !channel.isEmpty else { return nil }
        let name = channel.hasPrefix("#") ? String(channel.dropFirst()) : channel
        // Sin nombre guardado queda el id ("C0123ABCD"): mejor nada que un id.
        let looksLikeID = name.count >= 9 && name.allSatisfy { $0.isUppercase || $0.isNumber }
        return looksLikeID || name.isEmpty ? nil : "#" + name
    }

    public static func activity(_ actions: any PRBarActions, system: MacSystemInfo? = nil) async throws -> RemoteActivity {
        let resources = await actions.resources()
        let jobs = (try? await actions.status())?.jobs ?? []
        let titles = Dictionary((try? actions.listPRs(list: nil, account: nil, tab: nil))?.map { ($0.id, $0.title) } ?? [],
                                uniquingKeysWith: { first, _ in first })
        return RemoteActivity(resources: resources, usage: try? actions.usage(month: nil),
                              history: actions.historyList(repo: nil, kind: nil, limit: 20, search: nil),
                              system: system, running: running(jobs, processes: resources.usage.processes, titles: titles))
    }

    /// Los trabajos de `status` con la hora del proceso de Claude más viejo de cada uno.
    nonisolated public static func running(_ jobs: [JobInfo], processes: [ProcessUsage], titles: [String: String]) -> [RunningJobInfo] {
        func kinds(_ job: String) -> Set<ProcessActivity.Kind> {
            switch job {
            case "review": [.review]
            case "respond": [.respond, .ciFix, .conflicts]
            case "merge": [.merge]
            default: []
            }
        }
        return jobs.map { job in
            let started = processes.filter { process in
                guard let activity = process.activity else { return false }
                return activity.prID == job.pr && kinds(job.kind).contains(activity.kind)
            }.compactMap(\.startedAt).min()
            return RunningJobInfo(pr: job.pr, kind: job.kind, title: titles[job.pr] ?? job.pr, phase: job.phase,
                                  startedAt: started)
        }
    }

    /// El valor de un tópico, ya sin rutas locales, escapes ni secretos (`RemoteRedactor`, revisión M1).
    public static func compute(_ topic: RemoteTopic, _ actions: any PRBarActions,
                               system: () -> MacSystemInfo? = { nil },
                               redactor: RemoteRedactor = RemoteRedactor.standard()) async throws -> JSONValue {
        let value: JSONValue = switch topic {
        case .home: try JSONValue(encoding: try await home(actions))
        case .pr(let id): try JSONValue(encoding: try prDetail(id, actions))
        case .activity: try JSONValue(encoding: try await activity(actions, system: system()))
        }
        return redactor.scrub(value)
    }
}
