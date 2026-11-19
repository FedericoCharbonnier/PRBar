import Foundation

/// Un merge que salió bien.
public struct MergeCompletion: Equatable, Sendable {
    public let item: ClassifiedPR
    public let method: MergeMethod
    public let mergedAt: Date

    public init(item: ClassifiedPR, method: MergeMethod, mergedAt: Date) {
        self.item = item
        self.method = method
        self.mergedAt = mergedAt
    }
}

/// Estado del botón Merge de una fila (spec F.3).
public enum MergePhase: Equatable, Sendable {
    case merging(MergeMethod)
    /// Hecho: la fila muestra "Merged" hasta que el refresco la saca.
    case merged(MergeMethod)
    /// El texto del error y el método que se intentó (para Retry).
    case failed(method: MergeMethod, message: String)

    public var isActive: Bool {
        if case .merging = self { return true }
        return false
    }
}

/// Merges en curso y su resultado, por PR. Usa el token de la cuenta del PR: nunca pasa por Claude.
/// Lo usan la fila del popover, el diálogo de confirmación y (Plan 7) la CLI, por `AppModel`.
@MainActor
public final class MergeQueue: ObservableObject {
    @Published public private(set) var phases: [String: MergePhase] = [:]

    private let api: GitHubAPI
    private let tokens: TokenProviding
    private let now: () -> Date
    private let onMerged: @MainActor (MergeCompletion) -> Void

    public init(
        api: GitHubAPI, tokens: TokenProviding, now: @escaping () -> Date = { Date() },
        onMerged: @escaping @MainActor (MergeCompletion) -> Void = { _ in }
    ) {
        self.api = api
        self.tokens = tokens
        self.now = now
        self.onMerged = onMerged
    }

    /// Mergea `item` con `method`, con el `headOid` que tiene `item` (el que se mostró): si alguien pusheó después,
    /// GitHub lo rechaza. Un PR que ya se está mergeando o que ya se mergeó no se vuelve a mandar.
    @discardableResult
    public func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        let prID = item.id
        switch phases[prID] {
        case .merging?: return .failure(.alreadyInProgress)
        case .merged?: return .failure(.alreadyMerged)
        default: break
        }
        guard let nodeID = item.pr.merge.nodeID else { return fail(prID, method: method, .missingMergeData) }
        phases[prID] = .merging(method)
        do {
            let token = try await tokens.token(for: item.account)
            let mergedAt = try await api.mergePullRequest(
                id: nodeID, method: method, expectedHeadOid: item.pr.headOid, token: token)
            let completion = MergeCompletion(item: item, method: method, mergedAt: mergedAt ?? now())
            phases[prID] = .merged(method)
            AppLog.write("Merged \(prID) with \(method.rawValue) at \(item.pr.headOid)")
            onMerged(completion)
            return .success(completion)
        } catch {
            return fail(prID, method: method, MergeError(error))
        }
    }

    /// Borra el error de una fila (Dismiss). Un merge en curso no se toca.
    public func dismiss(prID: String) {
        guard phases[prID]?.isActive != true else { return }
        phases[prID] = nil
    }

    /// Descarta las fases de los PRs que ya no están en la lista (después del refresco que saca la fila).
    public func prune(keeping ids: Set<String>) {
        phases = phases.filter { ids.contains($0.key) || $0.value.isActive }
    }

    private func fail(_ prID: String, method: MergeMethod, _ error: MergeError) -> Result<MergeCompletion, MergeError> {
        phases[prID] = .failed(method: method, message: error.localizedDescription)
        AppLog.write("Couldn't merge \(prID): \(error.localizedDescription)")
        return .failure(error)
    }
}
