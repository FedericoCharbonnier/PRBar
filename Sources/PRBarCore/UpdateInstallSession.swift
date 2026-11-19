import Combine
import Foundation

/// En qué está la instalación de una actualización (ventana "Update PRBar", popover, Settings).
public enum UpdateInstallState: Equatable, Sendable {
    case idle
    case running(UpdatePhase)
    case failed(String)
}

/// El estado de la instalación y la espera de trabajos (spec D.3, paso 1). Tanto la ventana como la CLI pasan por
/// acá, así el estado nunca queda en "instalando" después de un error:
///
/// - `begin()` marca "instalando" en el acto (un segundo click o un `prbar update` a la vez falla con
///   `alreadyInstalling`) y desde ahí no se pueden empezar trabajos nuevos (`blockedReason`).
/// - `run` espera (o cancela, según la política) los trabajos que había al pedir la actualización y corre la
///   instalación. Si falla deja `.failed` (o `.idle` si se canceló) y relanza el error.
/// - El `beforeReplace` que recibe la instalación vuelve a esperar trabajos (p. ej. una publicación que empezó
///   durante el build) pero nunca cancela: lo que había al pedir la actualización ya se canceló al principio.
@MainActor
public final class UpdateInstallSession: ObservableObject {
    public static let blockedReason = "PRBar is installing an update. Try again after it restarts."

    @Published public private(set) var state: UpdateInstallState = .idle
    /// Trabajos que se están esperando antes de seguir.
    @Published public private(set) var waitingJobs = 0

    private let activeJobs: @MainActor () -> Int
    private let cancelJobs: @MainActor () -> Void
    private let pollInterval: Duration

    public init(
        activeJobs: @escaping @MainActor () -> Int, cancelJobs: @escaping @MainActor () -> Void,
        pollInterval: Duration = .seconds(1)
    ) {
        self.activeJobs = activeJobs
        self.cancelJobs = cancelJobs
        self.pollInterval = pollInterval
    }

    public var isInstalling: Bool {
        if case .running = state { return true }
        return false
    }

    /// Por qué no se puede empezar un trabajo nuevo (review, respond, chat); `nil` = se puede.
    public var blockedReason: String? { isInstalling ? Self.blockedReason : nil }

    /// Marca la instalación como empezada. Lanza `alreadyInstalling` si ya hay una.
    public func begin() throws {
        guard !isInstalling else { throw UpdateError.alreadyInstalling }
        waitingJobs = 0
        state = .running(.fetching)
    }

    /// Cambia la etapa (solo mientras se instala: un evento tardío no revive una instalación terminada).
    public func enter(_ phase: UpdatePhase) {
        guard isInstalling else { return }
        state = .running(phase)
    }

    /// Después de `begin()`: espera los trabajos según `policy` y corre `install`, que recibe el `beforeReplace`.
    /// `onEvent` recibe la etapa "esperando trabajos" y las líneas del log de esta parte.
    public func run(
        _ policy: UpdateBusyPolicy, onEvent: @escaping @MainActor (UpdateEvent) -> Void,
        install: @MainActor (_ beforeReplace: @escaping @Sendable () async throws -> Void) async throws -> Void
    ) async throws {
        guard isInstalling else { throw UpdateError.notStarted }
        do {
            try await drain(policy, onEvent: onEvent)
            try await install { [weak self] in try await self?.drain(.wait, onEvent: onEvent) }
        } catch is CancellationError {
            state = .idle
            waitingJobs = 0
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            waitingJobs = 0
            throw error
        }
    }

    private func drain(_ policy: UpdateBusyPolicy, onEvent: @MainActor (UpdateEvent) -> Void) async throws {
        guard activeJobs() > 0 else { return }
        if policy == .cancelJobs {
            onEvent(.log("Canceling running jobs (posting and pushing finish first)."))
            cancelJobs()
        }
        guard activeJobs() > 0 else { return }
        onEvent(.phase(.waitingForJobs))
        while activeJobs() > 0 {
            waitingJobs = activeJobs()
            try await Task.sleep(for: pollInterval)
        }
        waitingJobs = 0
    }
}
