import Foundation

/// Cómo se mergea un PR (spec F.3). En `config.json` va en minúsculas (`"squash"`); en GraphQL, en mayúsculas.
public enum MergeMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case squash, merge, rebase

    public var id: String { rawValue }

    /// `PullRequestMergeMethod` de GraphQL.
    public var graphQLValue: String { rawValue.uppercased() }

    public init?(graphQL: String?) {
        guard let graphQL, let method = MergeMethod(rawValue: graphQL.lowercased()) else { return nil }
        self = method
    }

    /// Botón por defecto del diálogo y los ítems de "Merge With…".
    public var actionTitle: String {
        switch self {
        case .squash: "Squash and Merge"
        case .merge: "Merge"
        case .rebase: "Rebase and Merge"
        }
    }

    /// Nombre corto (Settings › Repos).
    public var title: String {
        switch self {
        case .squash: "Squash"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }
}

/// `MergeableState` de GitHub. `UNKNOWN` = GitHub todavía lo está calculando.
public enum MergeableState: String, Codable, Sendable {
    case mergeable, conflicting, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "MERGEABLE": self = .mergeable
        case "CONFLICTING": self = .conflicting
        default: self = .unknown
        }
    }
}

/// `MergeStateStatus` de GitHub. `DRAFT` está deprecado en la API (se usa `isDraft`), pero todavía puede llegar.
public enum MergeStateStatus: String, Codable, Sendable {
    case clean, hasHooks, unstable, blocked, behind, dirty, draft, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "CLEAN": self = .clean
        case "HAS_HOOKS": self = .hasHooks
        case "UNSTABLE": self = .unstable
        case "BLOCKED": self = .blocked
        case "BEHIND": self = .behind
        case "DIRTY": self = .dirty
        case "DRAFT": self = .draft
        default: self = .unknown
        }
    }
}

/// Lo que dice GitHub de un PR para mergearlo (spec F.2). Todo es opcional o `unknown`: un `state.json` viejo o una
/// respuesta sin estos campos se leen como "todavía no se sabe".
public struct PRMergeState: Hashable, Codable, Sendable {
    /// `PullRequest.id` (node ID), el que pide `mergePullRequest`.
    public var nodeID: String?
    public var mergeable: MergeableState
    public var status: MergeStateStatus
    public var viewerCanUpdate: Bool?
    /// Commits del PR (`commits.totalCount`), para el diálogo de confirmación.
    public var commitCount: Int?

    public static let unknown = PRMergeState()

    public init(
        nodeID: String? = nil, mergeable: MergeableState = .unknown, status: MergeStateStatus = .unknown,
        viewerCanUpdate: Bool? = nil, commitCount: Int? = nil
    ) {
        self.nodeID = nodeID
        self.mergeable = mergeable
        self.status = status
        self.viewerCanUpdate = viewerCanUpdate
        self.commitCount = commitCount
    }

    private enum CodingKeys: String, CodingKey { case nodeID, mergeable, status, viewerCanUpdate, commitCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try? c.decodeIfPresent(String.self, forKey: .nodeID)
        mergeable = (try? c.decodeIfPresent(MergeableState.self, forKey: .mergeable)) ?? .unknown
        status = (try? c.decodeIfPresent(MergeStateStatus.self, forKey: .status)) ?? .unknown
        viewerCanUpdate = try? c.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate)
        commitCount = try? c.decodeIfPresent(Int.self, forKey: .commitCount)
    }
}

/// Ajustes de merge de un repo vistos desde una cuenta (spec F.2). Se guardan en `Snapshot.repoMergeSettings`.
public struct RepoMergeSettings: Hashable, Codable, Sendable {
    public var squashAllowed: Bool
    public var mergeCommitAllowed: Bool
    public var rebaseAllowed: Bool
    /// `viewerDefaultMergeMethod`: el método que GitHub propone a esta cuenta en este repo.
    public var viewerDefault: MergeMethod?
    public var deleteBranchOnMerge: Bool
    /// `viewerPermission` (`ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, `READ`); `nil` si GitHub no lo dijo.
    public var viewerPermission: String?

    public init(
        squashAllowed: Bool = true, mergeCommitAllowed: Bool = true, rebaseAllowed: Bool = true,
        viewerDefault: MergeMethod? = nil, deleteBranchOnMerge: Bool = false, viewerPermission: String? = nil
    ) {
        self.squashAllowed = squashAllowed
        self.mergeCommitAllowed = mergeCommitAllowed
        self.rebaseAllowed = rebaseAllowed
        self.viewerDefault = viewerDefault
        self.deleteBranchOnMerge = deleteBranchOnMerge
        self.viewerPermission = viewerPermission
    }

    /// Los métodos que el repo permite, en el orden squash, merge, rebase.
    public var allowedMethods: [MergeMethod] {
        MergeMethod.allCases.filter { method in
            switch method {
            case .squash: squashAllowed
            case .merge: mergeCommitAllowed
            case .rebase: rebaseAllowed
            }
        }
    }

    /// `false` solo si GitHub dijo que la cuenta no puede escribir en el repo; `nil` si no se sabe.
    public var viewerCanMerge: Bool? {
        viewerPermission.map { ["ADMIN", "MAINTAIN", "WRITE"].contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case squashAllowed, mergeCommitAllowed, rebaseAllowed, viewerDefault, deleteBranchOnMerge, viewerPermission
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        squashAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .squashAllowed)) ?? true
        mergeCommitAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .mergeCommitAllowed)) ?? true
        rebaseAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .rebaseAllowed)) ?? true
        viewerDefault = try? c.decodeIfPresent(MergeMethod.self, forKey: .viewerDefault)
        deleteBranchOnMerge = (try? c.decodeIfPresent(Bool.self, forKey: .deleteBranchOnMerge)) ?? false
        viewerPermission = try? c.decodeIfPresent(String.self, forKey: .viewerPermission)
    }
}
