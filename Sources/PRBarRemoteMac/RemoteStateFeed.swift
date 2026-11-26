import Foundation
import PRBarCore
import PRBarRemoteKit

/// El feed de estado (spec P.6): recalcula los tópicos suscritos cuando cambia la app (agrupado cada 300 ms) y
/// `activity` cada 5 s mientras alguien lo mire; `RemoteHost.publish` manda solo lo que cambió, con `rev` creciente.
@MainActor
final class RemoteStateFeed {
    private let host: RemoteHost
    private let actions: () -> (any PRBarActions)?
    private let debounce: Duration
    private let activityInterval: Duration
    private let stepDebounce: Duration
    private let redactor: () -> RemoteRedactor
    /// Lo llama con cada `home` calculado (el buzón guarda el último).
    var onHome: ((JSONValue) -> Void)?

    private var topics: [RemoteTopic] = []
    private var pending: Task<Void, Never>?
    private var activityTimer: Task<Void, Never>?
    private var computing = false
    /// Lo que se pidió mientras se calculaba (M4): un pedido completo no se pierde detrás de un tick de `activity`.
    private var pendingAll = false
    private var pendingOnly: Set<RemoteTopic> = []
    /// Los PRs cuyo paso cambió desde el último recálculo de pasos (spec LP.5).
    private var stepPRs: Set<String> = []
    private var stepPending: Task<Void, Never>?

    init(host: RemoteHost, actions: @escaping () -> (any PRBarActions)?, debounce: Duration, activityInterval: Duration,
         stepDebounce: Duration = .seconds(1), redactor: @escaping () -> RemoteRedactor) {
        self.host = host
        self.redactor = redactor
        self.actions = actions
        self.debounce = debounce
        self.activityInterval = activityInterval
        self.stepDebounce = stepDebounce
    }

    /// Cambió lo que miran los teléfonos.
    func setSubscriptions(_ names: Set<String>) {
        topics = RemoteTopic.parse(names.sorted())
        if topics.contains(.activity) {
            if activityTimer == nil {
                activityTimer = Task { [weak self, activityInterval] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: activityInterval)
                        guard !Task.isCancelled else { return }
                        await self?.recompute(only: [.activity])
                    }
                }
            }
        } else {
            activityTimer?.cancel()
            activityTimer = nil
        }
        Task { await recompute() }
    }

    /// Cambió algo en la app: se recalcula dentro de `debounce` (varios cambios seguidos, una sola vez).
    func changed() {
        guard pending == nil else { return }
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await self?.recompute()
        }
    }

    /// Cambió solo el paso de los trabajos de `prIDs` (spec LP.5): el paso no está en `home`, así que se recalculan
    /// solo los `pr:<id>` suscritos de esos PRs, agrupados cada `stepDebounce`. Si ningún teléfono los mira, nada.
    func stepsChanged(prIDs: Set<String>) {
        let watched = prIDs.filter { topics.contains(.pr($0)) }
        guard !watched.isEmpty else { return }
        stepPRs.formUnion(watched)
        guard stepPending == nil else { return }
        stepPending = Task { [weak self, stepDebounce] in
            try? await Task.sleep(for: stepDebounce)
            guard !Task.isCancelled, let self else { return }
            self.stepPending = nil
            let ids = self.stepPRs
            self.stepPRs = []
            // Lo suscrito ahora: un teléfono pudo dejar de mirar el PR mientras se esperaba.
            let list = self.topics.filter { topic in
                if case .pr(let id) = topic { ids.contains(id) } else { false }
            }
            guard !list.isEmpty else { return }
            await self.recompute(only: list)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        stepPending?.cancel()
        stepPending = nil
        stepPRs = []
        activityTimer?.cancel()
        activityTimer = nil
    }

    /// Calcula y publica. `home` se calcula siempre (lo usa el buzón aunque nadie esté conectado).
    /// Si ya está calculando, el pedido se junta con los demás (la unión de los tópicos; uno completo gana) y se
    /// calcula en la vuelta siguiente.
    func recompute(only: [RemoteTopic]? = nil) async {
        if computing {
            if let only { pendingOnly.formUnion(only) } else { pendingAll = true }
            return
        }
        computing = true
        defer { computing = false }
        var request: [RemoteTopic]? = only
        while true {
            guard let actions = actions() else { return }
            let redactor = redactor()
            var list = request ?? topics
            if request == nil, !list.contains(.home) { list.insert(.home, at: 0) }
            for topic in list {
                do {
                    let value = try await RemoteStateTopics.compute(topic, actions, system: { MacSystemSampler.sample() },
                                                                      redactor: redactor)
                    if topic == .home { onHome?(value) }
                    await host.publish(topic: topic.name, data: value)
                } catch {
                    AppLog.write("iPhone access: couldn’t compute \(topic == .home ? "home" : topic == .activity ? "activity" : "a PR"): \(error.localizedDescription)")
                }
            }
            if pendingAll {
                request = nil
            } else if !pendingOnly.isEmpty {
                request = pendingOnly.sorted { $0.name < $1.name }
            } else {
                return
            }
            pendingAll = false
            pendingOnly = []
        }
    }
}

/// El buzón (spec Q.1): el último `home`, cifrado para cada teléfono, como mucho cada 60 s y solo si cambió, para que
/// el teléfono tenga algo reciente aunque la Mac ya no esté. Apagado (`mailboxEnabled = false`) no escribe y deja el
/// slot vacío.
@MainActor
final class RemoteMailboxWriter {
    private let host: RemoteHost
    private var latest: Data?
    private var written: Data?
    var enabled: Bool

    init(host: RemoteHost, enabled: Bool) {
        self.host = host
        self.enabled = enabled
    }

    func homeChanged(_ value: JSONValue) {
        latest = try? CommandProtocol.encoder.encode(value)
    }

    /// Cada `interval` (60 s): escribe si hay algo nuevo. Devuelve si escribió.
    @discardableResult
    func tick() async -> Bool {
        guard enabled, let latest, latest != written else { return false }
        switch await host.putMailbox(slot: "home", data: latest) {
        case .sent:
            written = latest
            return true
        case .tooLarge:
            AppLog.write("iPhone access: the home state is too big for the relay mailbox; skipped.")
            written = latest
            return false
        case .notConnected:
            // Nada salió: la próxima vuelta (o el `forceNext` al reconectar) lo vuelve a intentar.
            return false
        }
    }

    /// Se apagó el buzón: no hay un "borrar" en el relay, así que se pisa el slot con un estado vacío (el teléfono lo
    /// trata como "nada"; el relay lo vence a los 7 días).
    func clear() async {
        written = nil
        await host.putMailbox(slot: "home", data: Data())
    }

    /// Un dispositivo nuevo: la próxima vuelta escribe aunque no haya cambiado.
    func forceNext() {
        written = nil
    }
}
