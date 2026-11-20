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
    /// El error y el método que se intentó (para Retry); `nil` si no se llegó a elegir uno.
    case failed(method: MergeMethod?, error: MergeError)

    public var isActive: Bool {
        if case .merging = self { return true }
        return false
    }

    /// El texto del error (la fila y la CLI); `nil` si no falló.
    public var message: String? {
        if case .failed(_, let error) = self { return error.localizedDescription }
        return nil
    }
}

/// Un merge que falló: el PR tal como se intentó (con el head que se mostró), el método y el error. Lo usa Retry.
public struct MergeFailure: Equatable, Sendable {
    public let item: ClassifiedPR
    public let method: MergeMethod?
    public let error: MergeError

    public init(item: ClassifiedPR, method: MergeMethod?, error: MergeError) {
        self.item = item
        self.method = method
        self.error = error
    }
}

/// Merges en curso y su resultado, por PR. Usa el token de la cuenta del PR: nunca pasa por Claude.
/// Lo usan la fila del popover, el diálogo de confirmación y (Plan 7) la CLI, por `AppModel`.
@MainActor
public final class MergeQueue: ObservableObject {
    @Published public private(set) var phases: [String: MergePhase] = [:]
    /// El PR tal como se intentó, por cada fase `.failed`.
    private var failedItems: [String: ClassifiedPR] = [:]

    private let api: GitHubAPI
    private let tokens: TokenProviding
    private let now: () -> Date
    /// Por qué no se puede empezar un merge ahora (spec D.3: mientras se instala una actualización); `nil` = se puede.
    private let blockedReason: @MainActor () -> String?
    private let onMerged: @MainActor (MergeCompletion) -> Void

    public init(
        api: GitHubAPI, tokens: TokenProviding, now: @escaping () -> Date = { Date() },
        blockedReason: @escaping @MainActor () -> String? = { nil },
        onMerged: @escaping @MainActor (MergeCompletion) -> Void = { _ in }
    ) {
        self.api = api
        self.tokens = tokens
        self.now = now
        self.blockedReason = blockedReason
        self.onMerged = onMerged
    }

    /// Mergea `item` con `method`, con el `headOid` que tiene `item` (el que se mostró): si alguien pusheó después,
    /// GitHub lo rechaza. Un PR que ya se está mergeando o que ya se mergeó no se vuelve a mandar. `precheck`: un
    /// motivo para no mandarlo (`MergePolicy.problem`), que queda como error de la fila.
    @discardableResult
    public func merge(
        _ item: ClassifiedPR, method: MergeMethod, precheck: MergeError? = nil
    ) async -> Result<MergeCompletion, MergeError> {
        let prID = item.id
        switch phases[prID] {
        case .merging?: return .failure(.alreadyInProgress)
        case .merged?: return .failure(.alreadyMerged)
        default: break
        }
        if let reason = blockedReason() { return fail(item, method: method, .blocked(reason)) }
        if let precheck { return fail(item, method: method, precheck) }
        guard let nodeID = item.pr.merge.nodeID else { return fail(item, method: method, .missingMergeData) }
        phases[prID] = .merging(method)
        failedItems[prID] = nil
        do {
            // Lo que lance (p. ej. `gh auth token`) va en la fila "Merge <repo>#N" de PRBar Activity (sin Stop).
            let mergedAt = try await ProcessActivity.$current.withValue(.merge(prID)) {
                let token = try await tokens.token(for: item.account)
                return try await api.mergePullRequest(id: nodeID, method: method, expectedHeadOid: item.pr.headOid, token: token)
            }
            let completion = MergeCompletion(item: item, method: method, mergedAt: mergedAt ?? now())
            phases[prID] = .merged(method)
            AppLog.write("Merged \(prID) with \(method.rawValue) at \(item.pr.headOid)")
            onMerged(completion)
            return .success(completion)
        } catch {
            return fail(item, method: method, MergeError(error))
        }
    }

    /// Muestra en la fila por qué no se pudo pedir el merge (p. ej. Retry de un PR que ya no se puede mergear).
    /// No toca un merge en curso ni uno hecho.
    public func reject(_ item: ClassifiedPR, method: MergeMethod?, error: MergeError) {
        switch phases[item.id] {
        case .merging?, .merged?: return
        default: _ = fail(item, method: method, error)
        }
    }

    /// El merge fallido de `prID`, si la fila muestra un error.
    public func failure(prID: String) -> MergeFailure? {
        guard case .failed(let method, let error)? = phases[prID], let item = failedItems[prID] else { return nil }
        return MergeFailure(item: item, method: method, error: error)
    }

    /// Retry de un PR que ya no está en la lista: pudo mergearse aunque el pedido diera error (p. ej. se cortó la red
    /// después de que GitHub lo mergeó). Si GitHub dice que está mergeado, queda "Merged" y avisa como un merge
    /// propio (Slack "Merged"); si no, la fila muestra por qué no se puede.
    public func resolveMissing(_ failure: MergeFailure) async {
        let item = failure.item
        let method = failure.method ?? .merge
        do {
            let details = try await ProcessActivity.$current.withValue(.merge(item.id)) {
                let token = try await tokens.token(for: item.account)
                return try await api.pullRequestDetails(repo: item.pr.repo, number: item.pr.number, token: token)
            }
            switch details.state {
            case .merged?:
                switch phases[item.id] {
                case .merging?, .merged?: return
                default: break
                }
                phases[item.id] = .merged(method)
                failedItems[item.id] = nil
                AppLog.write("\(item.id) was already merged on GitHub")
                onMerged(MergeCompletion(item: item, method: method, mergedAt: details.mergedAt ?? now()))
            case .closed?:
                reject(item, method: failure.method, error: .noLongerOpen)
            case .open?, nil:
                reject(item, method: failure.method,
                       error: .unavailable("This PR isn’t in PRBar’s list anymore — refresh and try again."))
            }
        } catch {
            reject(item, method: failure.method, error: MergeError(error))
        }
    }

    /// Borra el error de una fila (Dismiss). Un merge en curso no se toca.
    public func dismiss(prID: String) {
        guard phases[prID]?.isActive != true else { return }
        phases[prID] = nil
        failedItems[prID] = nil
    }

    /// Descarta las fases de los PRs que ya no están en la lista (después del refresco que saca la fila).
    public func prune(keeping ids: Set<String>) {
        phases = phases.filter { ids.contains($0.key) || $0.value.isActive }
        failedItems = failedItems.filter { phases[$0.key] != nil }
    }

    private func fail(_ item: ClassifiedPR, method: MergeMethod?, _ error: MergeError) -> Result<MergeCompletion, MergeError> {
        phases[item.id] = .failed(method: method, error: error)
        failedItems[item.id] = item
        AppLog.write("Couldn't merge \(item.id): \(error.localizedDescription)")
        return .failure(error)
    }
}
