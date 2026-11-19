import Foundation

/// Por qué no se pudo mergear (spec F.3). Los textos son los que muestra la fila (y la CLI).
public enum MergeError: Error, Equatable, Sendable, LocalizedError {
    /// Alguien pusheó después de lo que se mostró: `expectedHeadOid` no coincide.
    case headChanged
    case forbidden(String)
    case notMergeable(String)
    case alreadyInProgress
    case alreadyMerged
    /// El PR no tiene node ID (un `state.json` viejo): hay que refrescar.
    case missingMergeData
    /// No se puede empezar ahora (p. ej. se está instalando una actualización); el texto es el motivo.
    case blocked(String)
    /// PRBar no lo manda: el PR no está en Ready to Merge, el botón estaría deshabilitado (el texto es el motivo) o el
    /// repo no permite el método.
    case unavailable(String)
    /// El PR ya no está abierto (cerrado sin mergear, o PRBar no lo encuentra en la lista).
    case noLongerOpen
    /// El repo exige merge queue: la mutación directa no sirve.
    case mergeQueueRequired(String)
    case github(PRBarError)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .headChanged: "The PR changed since you looked at it — refresh and try again."
        case .forbidden(let message): "GitHub didn’t let you merge this PR: \(message)"
        case .notMergeable(let message): "GitHub can’t merge this PR: \(message)"
        case .alreadyInProgress: "This PR is already being merged."
        case .alreadyMerged: "This PR was already merged."
        case .missingMergeData: "PRBar doesn’t have this PR’s merge data yet — refresh and try again."
        case .blocked(let reason): reason
        case .unavailable(let reason): reason
        case .noLongerOpen: "This PR is no longer open."
        case .mergeQueueRequired(let message): "This repo uses a merge queue — add the PR to the queue on GitHub. (\(message))"
        case .github(let error): error.localizedDescription
        case .other(let message): "GitHub error: \(message)"
        }
    }

    /// Cualquier error de un merge, como `MergeError`.
    public init(_ error: Error) {
        switch error {
        case let error as MergeError: self = error
        case let error as PRBarError: self = .github(error)
        case let error as URLError: self = .github(.network(error.localizedDescription))
        default: self = .other(error.localizedDescription)
        }
    }

    /// Los errores de GraphQL de `mergePullRequest`. GitHub no documenta los textos: se reconocen por frases conocidas
    /// y por `type` (`FORBIDDEN`, `UNPROCESSABLE`). El QA confirma el texto real del head cambiado. Precedencia: head
    /// cambiado, merge queue, permiso, no mergeable, otro.
    public static func classify(messages: [String], types: [String?]) -> MergeError {
        let message = messages.joined(separator: "; ")
        let lower = message.lowercased()
        if ["head branch was modified", "expected head", "expectedheadoid", "head sha"].contains(where: { lower.contains($0) }) {
            return .headChanged
        }
        if lower.contains("merge queue") { return .mergeQueueRequired(message) }
        if types.contains("FORBIDDEN") || lower.contains("permission") || lower.contains("not authorized") {
            return .forbidden(message)
        }
        if types.contains("UNPROCESSABLE") || lower.contains("not mergeable") || lower.contains("not allowed") {
            return .notMergeable(message)
        }
        return .other(message)
    }
}
