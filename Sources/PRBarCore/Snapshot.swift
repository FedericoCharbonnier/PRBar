import Foundation

/// Un problema de un refresco, atado a la cuenta y (si aplica) al repo donde ocurrió.
public struct RefreshIssue: Codable, Equatable, Sendable {
    public var account: String
    public var repo: RepoRef?
    public var error: PRBarError
    /// Dato extra para el mensaje; en Slack, el nombre del canal.
    public var detail: String?

    public init(account: String, repo: RepoRef?, error: PRBarError, detail: String? = nil) {
        self.account = account
        self.repo = repo
        self.error = error
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey { case account, repo, error, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decode(String.self, forKey: .account)
        repo = try c.decodeIfPresent(RepoRef.self, forKey: .repo)
        error = try c.decode(PRBarError.self, forKey: .error)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    /// La cuenta no tiene sesión válida en `gh`: hay que correr `gh auth login`.
    public var requiresLogin: Bool {
        switch error {
        case .unauthorized: true
        case .commandFailed(let command, _, _): command.hasPrefix("gh auth token")
        default: false
        }
    }

    public var message: String {
        if account == "slack" { return slackMessage }
        if requiresLogin { return "The account \(account) isn't signed in" }
        if case .rateLimited(let resetAt) = error {
            return "GitHub rate limit reached · retrying at \(ClockTime.hhmm(resetAt))"
        }
        return "\(repo?.fullName ?? account): \(error.localizedDescription)"
    }

    private var slackMessage: String {
        if case .rateLimited(let resetAt) = error {
            return "Slack is rate limiting messages · retrying at \(ClockTime.hhmm(resetAt))"
        }
        let text: String
        switch (error, detail) {
        case (.network(let message), _): text = "Couldn't connect to Slack: \(message)"
        case (.http(let status, _), _): text = "Slack responded \(status). Will retry on the next refresh."
        case (.invalidResponse(let message), _): text = "Unexpected response from Slack: \(message)"
        case (.slack("not_in_channel"), let channel?): text = "Join #\(channel) to post there"
        case (.slack("invalid_name"), let emoji?): text = "Emoji :\(emoji): doesn't exist in this workspace"
        case (.slack("missing_scope"), let scopes?): text = "Your Slack token is missing a scope (needs \(scopes))"
        case (.slack("channel_not_found"), let channel?):
            text = "Couldn't find #\(channel). Choose it again in Settings → Repos."
        default: text = error.localizedDescription
        }
        return "Slack\(repo.map { " · \($0.name)" } ?? ""): \(text)"
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var items: [ClassifiedPR]
    /// Fecha del último refresco con al menos una consulta exitosa.
    public var fetchedAt: Date
    public var issues: [RefreshIssue]
    /// `true` si fallaron todas las consultas: el popover muestra "Sin conexión".
    public var failedCompletely: Bool
    public var rateLimitedUntil: Date?
    /// Scopes (`Snapshot.scope(account:repo:)`) consultados con éxito en este refresco. Las notificaciones
    /// solo se disparan para PRs cuyo scope ya se había consultado bien en el refresco anterior (spec §9).
    public var fetchedScopes: Set<String>
    /// Ajustes de merge de cada repo consultado, por scope (`Snapshot.scope(account:repo:)`): dependen de la cuenta
    /// (método por defecto, permiso). Spec F.2.
    public var repoMergeSettings: [String: RepoMergeSettings]

    public init(
        items: [ClassifiedPR], fetchedAt: Date, issues: [RefreshIssue] = [], failedCompletely: Bool = false,
        rateLimitedUntil: Date? = nil, fetchedScopes: Set<String> = [],
        repoMergeSettings: [String: RepoMergeSettings] = [:]
    ) {
        self.items = items
        self.fetchedAt = fetchedAt
        self.issues = issues
        self.failedCompletely = failedCompletely
        self.rateLimitedUntil = rateLimitedUntil
        self.fetchedScopes = fetchedScopes
        self.repoMergeSettings = repoMergeSettings
    }

    /// `"login|owner/repo"`.
    public static func scope(account: String, repo: RepoRef) -> String {
        "\(account)|\(repo.fullName)"
    }

    private enum CodingKeys: String, CodingKey {
        case items, fetchedAt, issues, failedCompletely, rateLimitedUntil, fetchedScopes, repoMergeSettings
    }

    /// Los `state.json` viejos guardaban `errors: [String]`; se ignoran y se leen como sin issues.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ClassifiedPR].self, forKey: .items)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        issues = try container.decodeIfPresent([RefreshIssue].self, forKey: .issues) ?? []
        failedCompletely = try container.decodeIfPresent(Bool.self, forKey: .failedCompletely) ?? false
        rateLimitedUntil = try container.decodeIfPresent(Date.self, forKey: .rateLimitedUntil)
        fetchedScopes = try container.decodeIfPresent(Set<String>.self, forKey: .fetchedScopes) ?? []
        repoMergeSettings = (try? container.decodeIfPresent([String: RepoMergeSettings].self, forKey: .repoMergeSettings)) ?? [:]
    }

    /// Issues agrupados por cuenta, en el orden en que aparecieron.
    public var issuesByAccount: [(account: String, issues: [RefreshIssue])] {
        var order: [String] = []
        var grouped: [String: [RefreshIssue]] = [:]
        for issue in issues {
            if grouped[issue.account] == nil { order.append(issue.account) }
            grouped[issue.account, default: []].append(issue)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    public var badgeCount: Int { items.filter { $0.category.countsForBadge }.count }

    public func items(in category: PRCategory) -> [ClassifiedPR] {
        items.filter { $0.category == category }
    }
}

public struct SnapshotBuilder: Sendable {
    private let api: GitHubAPI
    private let tokens: TokenProviding
    private let now: @Sendable () -> Date

    public init(api: GitHubAPI, tokens: TokenProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.tokens = tokens
        self.now = now
    }

    public func build(config: AppConfig, previous: Snapshot?) async -> Snapshot {
        var collected: [ClassifiedPR] = []
        var issues: [RefreshIssue] = []
        var attempts = 0
        var successes = 0
        var rateLimitedUntil: Date?
        var fetchedScopes: Set<String> = []

        func record(_ error: Error, account: String, repo: RepoRef?) {
            let prbarError: PRBarError = switch error {
            case let error as PRBarError: error
            case let error as URLError: .network(error.localizedDescription)
            default: .invalidResponse(error.localizedDescription)
            }
            issues.append(RefreshIssue(account: account, repo: repo, error: prbarError))
            AppLog.write("Error refreshing \(repo.map { "\($0.fullName) (\(account))" } ?? account): \(error)")
            if case PRBarError.rateLimited(let reset) = error {
                rateLimitedUntil = max(rateLimitedUntil ?? reset, reset)
            }
        }

        // Cada repo es una consulta; una cuenta sin repos cuenta como una sola, que se resuelve con el token.
        // Solo es "falla total" si hubo consultas y ninguna salió bien.
        for account in config.accounts where account.enabled {
            // Con el rate limit encima, no se gastan más consultas en este ciclo: se conserva lo anterior.
            if rateLimitedUntil != nil {
                collected += carryOver(previous, account: account.login, repo: nil)
                continue
            }
            let token: String
            do {
                token = try await tokens.token(for: account.login)
            } catch {
                attempts += 1
                record(error, account: account.login, repo: nil)
                collected += carryOver(previous, account: account.login, repo: nil)
                continue
            }
            if account.repos.isEmpty {
                attempts += 1
                successes += 1
            }
            for repoConfig in account.repos {
                if rateLimitedUntil != nil {
                    collected += carryOver(previous, account: account.login, repo: repoConfig.repo)
                    continue
                }
                attempts += 1
                do {
                    let result = try await api.openPullRequests(in: repoConfig.repo, token: token)
                    successes += 1
                    fetchedScopes.insert(Snapshot.scope(account: account.login, repo: repoConfig.repo))
                    let bases = Set(repoConfig.baseBranches.isEmpty ? [result.defaultBranch] : repoConfig.baseBranches)
                    for pr in result.pullRequests where bases.contains(pr.baseRef) {
                        if let category = ActionClassifier.classify(pr, me: account.login, watchedUsers: Set(repoConfig.watchedUsers)) {
                            collected.append(ClassifiedPR(pr: pr, category: category, account: account.login))
                        }
                    }
                } catch {
                    record(error, account: account.login, repo: repoConfig.repo)
                    collected += carryOver(previous, account: account.login, repo: repoConfig.repo)
                }
            }
        }

        let failedCompletely = attempts > 0 && successes == 0
        return Snapshot(
            items: Self.dedupeAndSort(collected),
            fetchedAt: failedCompletely ? (previous?.fetchedAt ?? now()) : now(),
            issues: issues,
            failedCompletely: failedCompletely,
            rateLimitedUntil: rateLimitedUntil,
            fetchedScopes: fetchedScopes
        )
    }

    private func carryOver(_ previous: Snapshot?, account: String, repo: RepoRef?) -> [ClassifiedPR] {
        (previous?.items ?? []).filter { item in
            item.account == account && (repo == nil || item.pr.repo == repo)
        }
    }

    /// Un PR visto desde varias cuentas queda una sola vez. Si lo escribió una de esas cuentas, gana su
    /// perspectiva ("mi PR"), aunque otra cuenta mía lo tenga en *Para revisar*; si no, la categoría más urgente.
    static func dedupeAndSort(_ items: [ClassifiedPR]) -> [ClassifiedPR] {
        func isAuthorView(_ item: ClassifiedPR) -> Bool {
            item.pr.author.lowercased() == item.account.lowercased()
        }
        var best: [String: ClassifiedPR] = [:]
        for item in items {
            if let current = best[item.id] {
                if isAuthorView(current) != isAuthorView(item) {
                    if isAuthorView(current) { continue }
                } else if current.category <= item.category {
                    continue
                }
            }
            best[item.id] = item
        }
        return best.values.sorted {
            $0.category != $1.category ? $0.category < $1.category : $0.pr.updatedAt > $1.pr.updatedAt
        }
    }
}

public struct SnapshotStore: Sendable {
    private let url: URL

    public init(url: URL = AppPaths.stateFile) {
        self.url = url
    }

    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONCoding.decoder.decode(Snapshot.self, from: data)
        } catch {
            AppLog.write("state.json is unreadable, ignoring it: \(error)")
            return nil
        }
    }

    public func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            AppLog.write("Couldn't save state.json: \(error)")
        }
    }
}
