import Foundation

/// Si el botón Merge está habilitado y por qué (spec F.3).
public enum MergeAvailability: Equatable, Sendable {
    /// `note`: aviso que no impide mergear (p. ej. `UNSTABLE`).
    case enabled(note: String?)
    case disabled(reason: String)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    public var note: String? {
        if case .enabled(let note) = self { return note }
        return nil
    }

    public var reason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

/// Lo que necesitan el botón, el menú, el diálogo y la CLI para mergear un PR.
public struct MergeOptions: Equatable, Sendable {
    public let availability: MergeAvailability
    /// Métodos permitidos, en el orden squash, merge, rebase.
    public let methods: [MergeMethod]
    /// `nil` solo si el repo no permite ninguno.
    public let defaultMethod: MergeMethod?

    public init(availability: MergeAvailability, methods: [MergeMethod], defaultMethod: MergeMethod?) {
        self.availability = availability
        self.methods = methods
        self.defaultMethod = defaultMethod
    }
}

/// Reglas puras del botón Merge (spec F.3). No hace red ni disco.
public enum MergePolicy {
    public static let checking = "Checking…"

    /// Sin datos del repo (refresco viejo o respuesta sin los campos) se ofrecen los tres: si el repo no permite el
    /// elegido, GitHub lo rechaza y la fila lo muestra.
    public static func allowedMethods(_ settings: RepoMergeSettings?) -> [MergeMethod] {
        settings?.allowedMethods ?? MergeMethod.allCases
    }

    /// El de `RepoConfig.mergeMethod` si está permitido; si no, `viewerDefaultMergeMethod`; si no, el primero
    /// permitido en el orden squash, merge, rebase.
    public static func defaultMethod(configured: MergeMethod?, settings: RepoMergeSettings?) -> MergeMethod? {
        let allowed = allowedMethods(settings)
        if let configured, allowed.contains(configured) { return configured }
        if let viewerDefault = settings?.viewerDefault, allowed.contains(viewerDefault) { return viewerDefault }
        return allowed.first
    }

    public static func availability(_ pr: PullRequest, settings: RepoMergeSettings?) -> MergeAvailability {
        if allowedMethods(settings).isEmpty { return .disabled(reason: "This repo doesn’t allow any merge method") }
        if settings?.viewerCanMerge == false {
            return .disabled(reason: "You don’t have permission to merge in \(pr.repo.fullName)")
        }
        guard pr.merge.nodeID != nil else { return .disabled(reason: checking) }
        if pr.merge.mergeable == .conflicting { return .disabled(reason: "This branch has conflicts") }
        switch pr.merge.status {
        case .clean, .hasHooks: return .enabled(note: nil)
        case .unstable: return .enabled(note: "Some checks that aren’t required are failing")
        case .blocked: return .disabled(reason: "Blocked by branch protection or required checks")
        case .behind: return .disabled(reason: "Branch is behind \(pr.baseRef)")
        case .dirty: return .disabled(reason: "This branch has conflicts")
        case .draft, .unknown: return .disabled(reason: checking)
        }
    }

    /// Junta los ajustes del repo vistos por la cuenta del PR, el método fijado en la config y el estado del PR.
    public static func options(for item: ClassifiedPR, snapshot: Snapshot?, config: AppConfig) -> MergeOptions {
        let settings = snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
        // Sin distinguir mayúsculas, como GitHub (`AppConfig.repoConfig`).
        let configured = config.repoConfig(account: item.account, repo: item.pr.repo)?.mergeMethod
        return MergeOptions(
            availability: availability(item.pr, settings: settings),
            methods: allowedMethods(settings),
            defaultMethod: defaultMethod(configured: configured, settings: settings)
        )
    }
}
