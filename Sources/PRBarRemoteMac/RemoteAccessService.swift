import Combine
import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit

/// Dónde vive `AppConfig.remote` (en la app, `ConfigStore` vía `AppModel`; en los tests, en memoria).
@MainActor
public protocol RemoteSettingsStore: AnyObject {
    var remoteSettings: RemoteSettings { get }
    func updateRemoteSettings(_ mutate: (inout RemoteSettings) -> Void) throws
}

/// El estado de la conexión con el relay (Settings › iPhone y `prbar remote status`).
public enum RemoteConnectionState: Equatable, Sendable {
    case disabled
    case connecting
    case connected
    case offline(retryAt: Date?, reason: String)
    case failed(String)

    public var name: String {
        switch self {
        case .disabled: "disabled"
        case .connecting: "connecting"
        case .connected: "connected"
        case .offline: "offline"
        case .failed: "failed"
        }
    }
}

/// Lo que el servicio usa por fuera (los tests lo arman con `InMemoryRelay`, un llavero falso y relojes propios).
public struct RemoteServiceEnvironment {
    public var keys: RemoteKeyStore
    public var devices: RemoteDeviceStore
    public var enroller: any RelayEnrolling
    /// Host del relay → conexiones con él.
    public var linkFactory: @Sendable (String) -> RelayLinkFactory
    public var macName: String
    public var appVersion: String
    public var clock: @Sendable () -> Date
    /// Ajustes del host (los tests acortan esperas).
    public var tune: @Sendable (inout RemoteHost.Configuration) -> Void
    public var keepAwake: KeepAwake?
    /// Espera entre intentos de la primera conexión (después reconecta el host con su backoff).
    public var connectBackoff: @Sendable (Int) -> Duration
    public var mailboxInterval: Duration
    public var feedDebounce: Duration
    public var activityInterval: Duration
    /// Hosts con IP literal y `ws://` (solo la integración contra el relay local).
    public var allowInsecureForTests: Bool

    public init(keys: RemoteKeyStore, devices: RemoteDeviceStore, enroller: any RelayEnrolling,
                linkFactory: @escaping @Sendable (String) -> RelayLinkFactory, macName: String, appVersion: String,
                clock: @escaping @Sendable () -> Date = { Date() },
                tune: @escaping @Sendable (inout RemoteHost.Configuration) -> Void = { _ in },
                keepAwake: KeepAwake? = nil, connectBackoff: @escaping @Sendable (Int) -> Duration = RemoteBackoff.standard,
                mailboxInterval: Duration = .seconds(60), feedDebounce: Duration = .milliseconds(300),
                activityInterval: Duration = .seconds(5), allowInsecureForTests: Bool = false) {
        self.keys = keys
        self.devices = devices
        self.enroller = enroller
        self.linkFactory = linkFactory
        self.macName = macName
        self.appVersion = appVersion
        self.clock = clock
        self.tune = tune
        self.keepAwake = keepAwake
        self.connectBackoff = connectBackoff
        self.mailboxInterval = mailboxInterval
        self.feedDebounce = feedDebounce
        self.activityInterval = activityInterval
        self.allowInsecureForTests = allowInsecureForTests
    }

    /// La app real: llavero, `remote/devices.json`, `URLSession` y `WebSocketRelayLink`.
    @MainActor
    public static func live(macName: String, appVersion: String) -> RemoteServiceEnvironment {
        RemoteServiceEnvironment(
            keys: RemoteKeyStore(), devices: RemoteDeviceStore(), enroller: URLSessionRelayEnroller(),
            linkFactory: { host in WebSocketRelayLink.factory(host: host) }, macName: macName, appVersion: appVersion,
            keepAwake: KeepAwake(power: IOKitPowerSource(), assertions: IOKitSleepAssertion()))
    }
}

/// Secretos en memoria (el modo de capturas: nunca toca el llavero del usuario).
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ key: String) throws -> String? { lock.withLock { values[key] } }
    public func exists(_ key: String) throws -> Bool { lock.withLock { values[key]?.isEmpty == false } }
    public func write(_ value: String?, for key: String) throws { lock.withLock { values[key] = value } }
}

/// Una conexión que nunca llega al relay (el modo de capturas).
final class OfflineRelayLink: RelayLink, @unchecked Sendable {
    let incoming = AsyncThrowingStream<RelayMessage, Error> { $0.finish() }
    func connect() async throws -> RelayReady { throw RelayClosed(code: nil, reason: "Offline") }
    func send(_ message: RelayMessage) throws { throw RelayClosed(code: nil, reason: "Offline") }
    func close() async {}
}

extension RemoteServiceEnvironment {
    /// El modo de capturas: llavero en memoria, dispositivos en `directory`, sin red.
    @MainActor
    public static func offline(directory: URL, appVersion: String) -> RemoteServiceEnvironment {
        RemoteServiceEnvironment(
            keys: RemoteKeyStore(secrets: MemorySecretStore()), devices: RemoteDeviceStore(directory: directory),
            enroller: URLSessionRelayEnroller(), linkFactory: { _ in { _ in OfflineRelayLink() } },
            macName: "Federico’s MacBook Pro", appVersion: appVersion)
    }
}

/// El acceso desde el iPhone del lado Mac (spec Q.1): dueño del `RemoteHost`, de la conexión con el relay, del
/// emparejamiento, de los dispositivos, del feed de estado, del buzón, de los pushes y de "Keep awake". Implementa
/// los comandos `remote*` (la app los expone por `AppModel`, igual para la UI, `prbar` y el test de paridad).
@MainActor
public final class RemoteAccessService: ObservableObject {
    @Published public private(set) var state: RemoteConnectionState = .disabled
    @Published public private(set) var devices: [StoredDevice] = []
    @Published public private(set) var online: Set<String> = []
    /// La ranura abierta (con el código cuando un teléfono se unió).
    @Published public private(set) var pairing: RemotePairingInfo?
    @Published public private(set) var keepingAwake = false

    /// A quién le llegan los comandos del teléfono (el `AppModel`, igual que la CLI).
    public weak var actions: (any PRBarActions)?

    private let store: any RemoteSettingsStore
    private let env: RemoteServiceEnvironment
    private var host: RemoteHost?
    private var eventsTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var mailboxTask: Task<Void, Never>?
    private var pairingTimer: Task<Void, Never>?
    private var pairWaiters: [CheckedContinuation<RemotePairingInfo, Error>] = []
    private var feed: RemoteStateFeed?
    private var mailbox: RemoteMailboxWriter?

    public init(settings: any RemoteSettingsStore, environment: RemoteServiceEnvironment) {
        store = settings
        env = environment
        devices = environment.devices.devices
    }

    public var settings: RemoteSettings { store.remoteSettings }

    // MARK: - Ciclo de vida

    /// Al arrancar la app: conecta si está habilitado.
    public func start() {
        devices = env.devices.devices
        updateKeepAwake()
        guard settings.enabled else { return }
        startHost()
    }

    /// Al salir de la app o al dormir: corta la conexión (los teléfonos ven "offline").
    public func stop() async {
        connectTask?.cancel()
        connectTask = nil
        mailboxTask?.cancel()
        mailboxTask = nil
        feed?.stop()
        feed = nil
        mailbox = nil
        eventsTask?.cancel()
        eventsTask = nil
        failPairWaiters(CommandFailure(.cancelled, "iPhone access was turned off."))
        pairing = nil
        pairingTimer?.cancel()
        let current = host
        host = nil
        online = []
        await current?.disconnect()
        state = .disabled
        updateKeepAwake()
    }

    /// Volvió la red o la Mac despertó: si no está conectado, reintenta ya (sin esperar el backoff).
    public func retryNow() async {
        guard settings.enabled else { return }
        if let host, await host.isConnected { return }
        await stop()
        startHost()
    }

    /// Algo cambió en la app: el feed recalcula los tópicos (agrupado).
    public func stateChanged() {
        feed?.changed()
    }

    private func startHost() {
        guard host == nil, settings.enabled, let relay = settings.relayHost, let account = settings.accountId else { return }
        let keys: MacKeys
        do {
            keys = try env.keys.loadOrCreate()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        var config = RemoteHost.Configuration(accountId: account, relayHost: relay, macName: env.macName,
                                              appVersion: env.appVersion, keys: keys)
        env.tune(&config)
        let host = RemoteHost(configuration: config, devices: env.devices.devices.map(\.device),
                              linkFactory: env.linkFactory(relay), clock: env.clock,
                              deviceHandler: { [weak self] command, device, events in
                                  guard let self else { return .failure(CommandFailure(.cancelled, "PRBar is quitting.")) }
                                  return await self.handleRemote(command, device: device, events: events)
                              })
        self.host = host
        let feed = RemoteStateFeed(host: host, actions: { [weak self] in self?.actions }, debounce: env.feedDebounce,
                                   activityInterval: env.activityInterval)
        let mailbox = RemoteMailboxWriter(host: host, enabled: settings.mailboxEnabled)
        feed.onHome = { [weak mailbox] value in mailbox?.homeChanged(value) }
        self.feed = feed
        self.mailbox = mailbox
        eventsTask = Task { [weak self] in
            for await event in host.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        state = .connecting
        let backoff = env.connectBackoff
        connectTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                do {
                    try await host.connect()
                    await self?.connected()
                    return
                } catch {
                    let delay = backoff(attempt)
                    self?.connectFailed(error, retryIn: delay)
                    try? await Task.sleep(for: delay)
                    attempt += 1
                }
            }
        }
        let interval = env.mailboxInterval
        mailboxTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.mailbox?.tick()
            }
        }
        updateKeepAwake()
    }

    private func connected() async {
        state = .connected
        await feed?.recompute()
    }

    private func connectFailed(_ error: Error, retryIn delay: Duration) {
        guard host != nil else { return }
        let reason = (error as? RelayClosed)?.reason ?? error.localizedDescription
        state = .offline(retryAt: env.clock().addingTimeInterval(Double(delay.components.seconds)), reason: reason)
    }

    private func handle(_ event: RemoteHostEvent) async {
        switch event {
        case .status(let status):
            switch status {
            case .connecting: state = .connecting
            case .connected:
                state = .connected
                await feed?.recompute()
            case .disconnected: if host == nil || !settings.enabled { state = .disabled }
            case .offline(let retryIn):
                state = .offline(retryAt: env.clock().addingTimeInterval(TimeInterval(retryIn)), reason: "Connection lost")
                online = []
            }
        case .pairingJoined(let sas, let name, let model):
            guard var info = pairing else { return }
            info.code = sas.count == 6 ? "\(sas.prefix(3)) \(sas.suffix(3))" : sas
            info.deviceName = name
            info.model = model
            pairing = info
            let waiters = pairWaiters
            pairWaiters = []
            waiters.forEach { $0.resume(returning: info) }
        case .pairingEnded(let reason):
            if reason != "paired" {
                failPairWaiters(CommandFailure(.cancelled, Self.pairingEndedMessage(reason)))
            }
            pairing = nil
            pairingTimer?.cancel()
        case .devicesChanged(let current):
            syncDevices(current)
        case .deviceOnline(let id, let isOnline):
            if isOnline { online.insert(id) } else { online.remove(id) }
            try? env.devices.update(lastSeen: env.clock(), for: id)
            devices = env.devices.devices
        case .sessionRejected(let device):
            AppLog.write("iPhone \(device.prefix(4)): session rejected")
        case .commandRefused(let device, let name):
            AppLog.write("iPhone \(device.prefix(4)): refused \(name.rawValue)")
        case .rateLimited(let device):
            AppLog.write("iPhone \(device.prefix(4)): rate limited")
        case .subscriptionsChanged(let topics):
            feed?.setSubscriptions(topics)
        }
    }

    static func pairingEndedMessage(_ reason: String) -> String {
        switch reason {
        case "expired": "The pairing code expired. Start again."
        case "cancelled", "replaced": "Pairing was cancelled."
        case "not confirmed", "not delivered": "Your iPhone didn’t confirm the pairing. Try again."
        default: "Pairing stopped (\(reason)). Start again."
        }
    }

    /// Lo que sabe el host es la verdad (altas por emparejamiento, bajas por Revoke o "Unpair this iPhone").
    private func syncDevices(_ current: [PairedDevice]) {
        let ids = Set(current.map(\.deviceId))
        do {
            for stored in env.devices.devices where !ids.contains(stored.device.deviceId) {
                try env.devices.remove(stored.device.deviceId)
                AppLog.write("iPhone \(stored.device.deviceId.prefix(4)): removed")
            }
            for device in current {
                if let stored = env.devices.device(device.deviceId) {
                    if stored.device.requirePresence != device.requirePresence {
                        try env.devices.setRequirePresence(device.requirePresence, for: device.deviceId)
                    }
                } else {
                    try env.devices.add(device)
                    mailbox?.forceNext()
                    AppLog.write("iPhone \(device.deviceId.prefix(4)): paired")
                }
            }
        } catch {
            AppLog.write("iPhone access: couldn’t save the paired iPhones: \(error.localizedDescription)")
        }
        devices = env.devices.devices
    }

    private func updateKeepAwake() {
        env.keepAwake?.update(enabled: settings.enabled && settings.keepAwakeWhileCharging)
        keepingAwake = env.keepAwake?.isHolding ?? false
    }

    // MARK: - El puente de comandos (spec Q.1)

    /// El teléfono es un cliente más de `AppCommand` (spec P.1): mismos métodos de `AppModel` que la UI y `prbar`.
    /// `RemoteHost` ya aplicó la política y Face ID; acá se vuelve a mirar la política (defensa en profundidad) y
    /// `remoteSetPresenceRequirement` se aplica siempre al propio teléfono. Se loguea el nombre, nunca los argumentos.
    public func handleRemote(_ command: AppCommand, device: PairedDevice, events: @escaping CommandEventSink) async
        -> Result<JSONValue, CommandFailure> {
        AppLog.write("iPhone \(device.deviceId.prefix(4)): \(command.name.rawValue)")
        guard RemotePolicy.decide(command) != .denied else {
            return .failure(CommandFailure(.unauthorized, RemotePolicy.deniedMessage))
        }
        var command = command
        if case .remoteSetPresenceRequirement(_, let enabled) = command {
            command = .remoteSetPresenceRequirement(device: device.deviceId, enabled: enabled)
        }
        guard let actions else { return .failure(CommandFailure(.invalidState, "PRBar isn’t ready yet. Try again.")) }
        let result = await CommandDispatcher.run(command, on: actions, events: events)
        // Ni rutas locales ni herramientas hacia el teléfono (spec P.7).
        return result.map(RemoteRedaction.scrub)
    }

    /// El modo de capturas: muestra un estado sin conectarse a nada.
    public func applySnapshot(state: RemoteConnectionState, devices: [StoredDevice], online: Set<String>,
                              pairing: RemotePairingInfo?) {
        self.state = state
        self.devices = devices
        self.online = online
        self.pairing = pairing
    }

    // MARK: - Pushes (spec P.9)

    /// Las mismas notificaciones que la Mac, cifradas para cada iPhone que no tenga las notificaciones apagadas.
    public func push(_ notifications: [PlannedNotification], badge: Int?) {
        guard let host, !notifications.isEmpty else { return }
        let payloads = RemotePushPlanner.payloads(for: notifications, badge: badge, now: env.clock())
        let targets = devices.map(\.device.deviceId)
        Task { [weak self] in
            for id in targets {
                for payload in payloads {
                    do {
                        let status = try await host.push(payload, to: id)
                        self?.pushAnswered(id, status: status)
                    } catch {
                        // Sin conexión o sin respuesta: el teléfono igual ve el estado en vivo o en el buzón.
                        break
                    }
                }
            }
        }
    }

    private func pushAnswered(_ id: String, status: Int) {
        // 410 o 400: APNs olvidó el token ("Notifications off" hasta que el teléfono registre uno nuevo).
        let off = status == 410 || status == 400
        guard status == 200 || off else { return }
        try? env.devices.setNotificationsOff(off, for: id)
        devices = env.devices.devices
    }

    /// Un chat que no inició el teléfono (p. ej. desde la Mac): a quien mire `pr:<id>`.
    public func chatDelta(pr: String, text: String) {
        guard let host else { return }
        Task { await host.sendChatDelta(pr: pr, text: text) }
    }

    /// Para los tests: escribe el buzón ahora (en la app, cada `mailboxInterval`).
    @discardableResult
    public func flushMailbox() async -> Bool {
        await mailbox?.tick() ?? false
    }

    /// Para los tests: recalcula los tópicos ahora.
    public func recomputeState() async {
        await feed?.recompute()
    }

    // MARK: - Comandos remote* (RemoteActions)

    private func resolveDevice(_ text: String) throws -> StoredDevice {
        let query = text.trimmingCharacters(in: .whitespaces)
        if let exact = devices.first(where: { $0.device.deviceId == query }) { return exact }
        var matches = query.count >= 4 ? devices.filter { $0.device.deviceId.hasPrefix(query.lowercased()) } : []
        if matches.isEmpty { matches = devices.filter { $0.device.name.caseInsensitiveCompare(query) == .orderedSame } }
        guard !matches.isEmpty else { throw CommandFailure(.notFound, "No paired iPhone matches “\(query)”. See prbar remote devices.") }
        guard matches.count == 1 else {
            throw CommandFailure(.invalidUsage, "More than one iPhone matches “\(query)”: use its id (prbar remote devices).")
        }
        return matches[0]
    }

    public func deviceInfo(_ stored: StoredDevice) -> RemoteDeviceInfo {
        RemoteDeviceInfo(id: stored.device.deviceId, name: stored.device.name, model: stored.device.model,
                         pairedAt: stored.device.pairedAt, lastSeen: stored.lastSeen,
                         online: online.contains(stored.device.deviceId),
                         requirePresence: stored.device.requirePresence, notifications: !stored.notificationsOff)
    }

    public func status() -> RemoteStatusInfo {
        let settings = settings
        var detail: String?
        switch state {
        case .offline(let retryAt, let reason):
            let seconds = retryAt.map { max(0, Int($0.timeIntervalSince(env.clock()).rounded())) }
            detail = seconds.map { "\(reason) — retrying in \($0) s" } ?? reason
        case .failed(let message):
            detail = message
        default:
            break
        }
        return RemoteStatusInfo(enabled: settings.enabled, relayHost: settings.relayHost, state: state.name, detail: detail,
                                devices: devices.count, devicesOnline: online.count, keepAwake: settings.keepAwakeWhileCharging,
                                keepingAwake: keepingAwake, mailbox: settings.mailboxEnabled,
                                appInstallURL: settings.appInstallURL, accountPrefix: settings.accountId.map { String($0.prefix(4)) })
    }

    public func enable(relay: String, enrollToken: String) async throws -> RemoteStatusInfo {
        guard let host = RemoteSettings.normalizedRelayHost(relay, allowIPForTests: env.allowInsecureForTests) else {
            throw CommandFailure(.invalidUsage, "“\(relay)” isn’t a relay host. Use a name like \(RemoteSettings.defaultRelayHost).")
        }
        let token = enrollToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = settings
        if current.relayHost == host, current.accountId != nil, token.isEmpty {
            // Ya hay cuenta en este relay: volver a habilitar no pide el token (spec P.12).
            try store.updateRemoteSettings { $0.enabled = true }
        } else {
            guard !token.isEmpty else { throw CommandFailure(.invalidUsage, "Enter the relay’s enrollment token.") }
            let keys = try env.keys.loadOrCreate()
            let account = try await env.enroller.enroll(host: host, token: token,
                                                        macRelayKey: keys.relay.publicKey.rawRepresentation)
            guard RemoteSettings.normalizedRelayHost(host, allowIPForTests: env.allowInsecureForTests) != nil,
                  !account.isEmpty, account.count <= 64 else {
                throw CommandFailure(.failed, "The relay answered something PRBar doesn’t understand.")
            }
            if current.accountId != nil, current.relayHost != host || current.accountId != account {
                // Otra cuenta (u otro relay): los teléfonos de la anterior ya no sirven.
                try env.devices.removeAll()
                devices = []
            }
            try store.updateRemoteSettings {
                $0.enabled = true
                $0.relayHost = host
                $0.accountId = account
            }
        }
        AppLog.write("iPhone access: enabled")
        await stop()
        startHost()
        return status()
    }

    public func disable() async throws -> RemoteStatusInfo {
        try store.updateRemoteSettings { $0.enabled = false }
        await stop()
        AppLog.write("iPhone access: disabled")
        return status()
    }

    public func pairStart() async throws -> RemotePairingInfo {
        guard settings.enabled, let host else {
            throw CommandFailure(.invalidState, "Turn on iPhone access first (prbar remote enable).")
        }
        guard await host.isConnected else {
            throw CommandFailure(.invalidState, "PRBar isn’t connected to the relay. Check prbar remote status.")
        }
        failPairWaiters(CommandFailure(.cancelled, "Pairing was cancelled."))
        let qr: PairingQR
        do {
            qr = try await host.startPairing()
        } catch {
            throw CommandFailure(.failed, "Couldn’t open a pairing slot: \(error.localizedDescription)")
        }
        let expires = env.clock().addingTimeInterval(300)
        let info = RemotePairingInfo(pairing: qr.pairingId, qr: qr.url, expiresAt: expires)
        pairing = info
        pairingTimer?.cancel()
        pairingTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, self.pairing?.pairing == info.pairing else { return }
            await self.host?.cancelPairing()
            self.failPairWaiters(CommandFailure(.cancelled, Self.pairingEndedMessage("expired")))
            self.pairing = nil
        }
        AppLog.write("iPhone access: pairing started")
        return info
    }

    public func pairWait(pairing id: String, events: CommandEventSink) async throws -> RemotePairingInfo {
        guard let current = pairing, current.pairing == id else {
            throw CommandFailure(.notFound, "That pairing code isn’t open anymore. Start again.")
        }
        if current.code != nil { return current }
        events(.progress(message: "Waiting for your iPhone…"))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pairWaiters.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.failPairWaiters(CancellationError())
            }
        }
    }

    private func failPairWaiters(_ error: Error) {
        let waiters = pairWaiters
        pairWaiters = []
        waiters.forEach { $0.resume(throwing: error) }
    }

    public func pairConfirm(pairing id: String, accepted: Bool) async throws -> RemotePairResult {
        guard let current = pairing, current.pairing == id, let host else {
            if accepted { throw CommandFailure(.notFound, "That pairing code isn’t open anymore. Start again.") }
            return RemotePairResult(device: nil)
        }
        guard accepted else {
            if current.code != nil { _ = try? await host.confirmPairing(false) } else { await host.cancelPairing() }
            pairing = nil
            pairingTimer?.cancel()
            return RemotePairResult(device: nil)
        }
        guard current.code != nil else { throw CommandFailure(.invalidState, "No iPhone has joined yet.") }
        guard let device = try await host.confirmPairing(true) else { return RemotePairResult(device: nil) }
        syncDevices(await host.pairedDevices)
        pairing = nil
        pairingTimer?.cancel()
        let stored = env.devices.device(device.deviceId) ?? StoredDevice(device: device)
        return RemotePairResult(device: deviceInfo(stored))
    }

    public func deviceList() -> [RemoteDeviceInfo] { devices.map(deviceInfo) }

    public func revoke(_ query: String) async throws -> RemoteDeviceInfo {
        let stored = try resolveDevice(query)
        let id = stored.device.deviceId
        if let host {
            await host.revoke(id)
        }
        try env.devices.remove(id)
        devices = env.devices.devices
        online.remove(id)
        AppLog.write("iPhone \(id.prefix(4)): revoked")
        return deviceInfo(stored)
    }

    public func setKeepAwake(_ enabled: Bool) throws -> RemoteStatusInfo {
        try store.updateRemoteSettings { $0.keepAwakeWhileCharging = enabled }
        updateKeepAwake()
        return status()
    }

    /// "Reset iPhone Access…" (spec P.12): da de baja a todos, borra las claves y la cuenta. Para volver a usarlo hay
    /// que habilitarlo con el token y emparejar de nuevo.
    public func reset() async throws -> RemoteStatusInfo {
        if let host {
            for device in devices { await host.revoke(device.device.deviceId) }
        }
        await stop()
        try env.devices.removeAll()
        devices = []
        try env.keys.reset()
        try store.updateRemoteSettings {
            $0.enabled = false
            $0.accountId = nil
        }
        AppLog.write("iPhone access: reset")
        return status()
    }

    public func setPresenceRequirement(_ query: String, enabled: Bool) async throws -> RemoteDeviceInfo {
        let stored = try resolveDevice(query)
        let id = stored.device.deviceId
        try env.devices.setRequirePresence(enabled, for: id)
        if let host { await host.setRequirePresence(id, enabled) }
        devices = env.devices.devices
        AppLog.write("iPhone \(id.prefix(4)): Face ID \(enabled ? "required" : "not required")")
        return deviceInfo(env.devices.device(id) ?? stored)
    }

    public func setMailbox(_ enabled: Bool) async throws -> RemoteStatusInfo {
        try store.updateRemoteSettings { $0.mailboxEnabled = enabled }
        mailbox?.enabled = enabled
        if enabled {
            mailbox?.forceNext()
            await feed?.recompute()
            await mailbox?.tick()
        } else {
            await mailbox?.clear()
        }
        return status()
    }

    public func setAppLink(_ text: String?) throws -> RemoteStatusInfo {
        let url = try text.map { try RemoteSettings.installURL($0) }
        try store.updateRemoteSettings { $0.appInstallURL = url }
        return status()
    }
}
