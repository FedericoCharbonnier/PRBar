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
    /// Cada cuánto, como mucho, un cambio de paso de un trabajo recalcula los `pr:<id>` que miran los teléfonos.
    public var stepDebounce: Duration
    /// Hosts con IP literal y `ws://` (solo la integración contra el relay local).
    public var allowInsecureForTests: Bool

    public init(keys: RemoteKeyStore, devices: RemoteDeviceStore, enroller: any RelayEnrolling,
                linkFactory: @escaping @Sendable (String) -> RelayLinkFactory, macName: String, appVersion: String,
                clock: @escaping @Sendable () -> Date = { Date() },
                tune: @escaping @Sendable (inout RemoteHost.Configuration) -> Void = { _ in },
                keepAwake: KeepAwake? = nil, connectBackoff: @escaping @Sendable (Int) -> Duration = RemoteBackoff.standard,
                mailboxInterval: Duration = .seconds(60), feedDebounce: Duration = .milliseconds(300),
                activityInterval: Duration = .seconds(5), stepDebounce: Duration = .seconds(1),
                allowInsecureForTests: Bool = false) {
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
        self.stepDebounce = stepDebounce
        self.allowInsecureForTests = allowInsecureForTests
    }

    /// La app real: llavero, `remote/devices.json`, `URLSession` y `WebSocketRelayLink`.
    @MainActor
    public static func live(macName: String, appVersion: String) -> RemoteServiceEnvironment {
        RemoteServiceEnvironment(
            keys: RemoteKeyStore(), devices: RemoteDeviceStore(), enroller: URLSessionRelayEnroller(),
            // Sin el `ping` propio del link: lo manda `RemoteHost`, que además vigila el `pong` (L6).
            linkFactory: { host in WebSocketRelayLink.factory(host: host, pingInterval: nil) }, macName: macName,
            appVersion: appVersion,
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
    /// Las carpetas (clones, worktrees, runners) y hosts SSH de la config que no salen hacia el teléfono
    /// (`RemoteRedactor`, revisión M1). La app lo arma desde `AppConfig`.
    public var redactionInputs: @MainActor () -> (folders: [String], hosts: [String]) = { ([], []) }
    private var cachedRedactor: (inputs: [String], redactor: RemoteRedactor)?

    private let store: any RemoteSettingsStore
    private let env: RemoteServiceEnvironment
    private var host: RemoteHost?
    private var eventsTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var mailboxTask: Task<Void, Never>?
    private var pairingTimer: Task<Void, Never>?
    private var pairWaiters: [UUID: CheckedContinuation<RemotePairingInfo, Error>] = [:]
    /// `retryNow` (al despertar y al volver la red) no se pisa consigo mismo (revisión L6).
    private var retrying = false
    /// El relay cambió esta Mac por otra con la misma cuenta (4409): despertar o volver la red no reconecta (si no, las
    /// dos se sacarían el lugar). Lo limpia volver a habilitar el acceso o reiniciar la app.
    private var replacedByAnotherMac = false
    public static let replacedMessage = "Another PRBar is connected to iPhone access with this account, so this Mac stepped back. "
        + "Turn Remote Control off and on to use this Mac instead."
    private var cleanupTask: Task<Void, Never>?
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
        replacedByAnotherMac = false
        devices = env.devices.devices
        updateKeepAwake()
        cleanUpRetiredAccounts()
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
        // Mientras se cortaba, otro camino pudo arrancar un host nuevo: su estado no se pisa (L6).
        if host == nil { state = replacedByAnotherMac && settings.enabled ? .failed(Self.replacedMessage) : .disabled }
        updateKeepAwake()
    }

    /// Volvió la red o la Mac despertó: si no está conectado, reintenta ya (sin esperar el backoff). Una sola vez a la
    /// vez: el aviso de despertar y el de la red llegan juntos (L6).
    public func retryNow() async {
        guard settings.enabled, !retrying, !replacedByAnotherMac else { return }
        retrying = true
        defer { retrying = false }
        if let host, await host.isConnected {
            // Parece conectado, pero el socket pudo quedar muerto al dormir o al cambiar de red: un `ping` ya.
            await host.checkLiveness()
            return
        }
        await stop()
        startHost()
    }

    /// Algo cambió en la app: el feed recalcula los tópicos (agrupado).
    public func stateChanged() {
        feed?.changed()
    }

    /// Cambió solo el paso de los trabajos de esos PRs (spec LP.5): recalcula solo sus `pr:<id>` suscritos.
    public func stepsChanged(prIDs: Set<String>) {
        feed?.stepsChanged(prIDs: prIDs)
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
                              deviceHandler: { [weak self] command, caller, events in
                                  guard let self else { return .failure(CommandFailure(.cancelled, "PRBar is quitting.")) }
                                  return await self.handleRemote(command, caller: caller, events: events)
                              })
        self.host = host
        let feed = RemoteStateFeed(host: host, actions: { [weak self] in self?.actions }, debounce: env.feedDebounce,
                                   activityInterval: env.activityInterval, stepDebounce: env.stepDebounce,
                                   redactor: { [weak self] in self?.redactor() ?? RemoteRedactor.standard() })
        let mailbox = RemoteMailboxWriter(host: host, enabled: settings.mailboxEnabled)
        feed.onHome = { [weak mailbox] value in mailbox?.homeChanged(value) }
        self.feed = feed
        self.mailbox = mailbox
        eventsTask = Task { [weak self] in
            for await event in host.events {
                guard let self else { return }
                // Lo que avise un host que ya se reemplazó o se apagó no toca el estado (H4).
                guard self.host === host else { return }
                await self.handle(event)
            }
        }
        state = .connecting
        let backoff = env.connectBackoff
        connectTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                do {
                    // El estado, el feed y la reconciliación los pone el evento `.connected` del host.
                    try await host.connect()
                    return
                } catch {
                    // Se apagó o se durmió mientras conectaba: el host de esta tarea ya no es el vigente (H4).
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    let delay = backoff(attempt)
                    self?.connectFailed(error, host: host, retryIn: delay)
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

    /// Al conectar, el relay tiene que saber lo mismo que la Mac (revisión M5): un Revoke, un emparejamiento que no
    /// terminó o un buzón apagado mientras no había conexión se mandan ahora. Los dispositivos que el relay tiene y la
    /// Mac no se dan de baja (con eso el relay borra su buzón); con el buzón apagado se pisa el slot de cada iPhone.
    private func reconcileRelay() async {
        guard let host else { return }
        if !settings.mailboxEnabled { await mailbox?.clear() }
        guard let listed = try? await host.relayDevices(), self.host === host else { return }
        let known = Set(await host.pairedDevices.map(\.deviceId))
        let pending = await host.pendingPairingDevice
        for entry in listed where !known.contains(entry.id) && entry.id != pending {
            await host.removeFromRelay(entry.id)
            AppLog.write("iPhone \(entry.id.prefix(4)): removed from the relay")
        }
    }

    private func connectFailed(_ error: Error, host failed: RemoteHost, retryIn delay: Duration) {
        guard let host, host === failed else { return }
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
                // Lo que se escribió en el buzón sin conexión no salió: se vuelve a escribir (M8).
                mailbox?.forceNext()
                await feed?.recompute()
                await reconcileRelay()
            case .disconnected: if (host == nil || !settings.enabled) && !replacedByAnotherMac { state = .disabled }
            case .replaced:
                AppLog.write("iPhone access: another Mac connected with this account; this one stepped back")
                replacedByAnotherMac = true
                await stop()
                state = .failed(Self.replacedMessage)
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
            pairWaiters = [:]
            waiters.values.forEach { $0.resume(returning: info) }
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
    /// Ejecutar código del repo (tests, push) pide la prueba de Face ID de ese pedido (decisión H1): además de
    /// `RemotePolicy` (gated), el puente lo vuelve a mirar y lo deja en `CommandOrigin` para Core.
    public func handleRemote(_ command: AppCommand, caller: RemoteCaller, events: @escaping CommandEventSink) async
        -> Result<JSONValue, CommandFailure> {
        let device = caller.device
        AppLog.write("iPhone \(device.deviceId.prefix(4)): \(command.name.rawValue)")
        guard RemotePolicy.decide(command) != .denied else {
            return .failure(CommandFailure(.unauthorized, RemotePolicy.deniedMessage))
        }
        if RemotePolicy.runsRepoCode.contains(command.name), !caller.mayRunRepoCode {
            return .failure(CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))
        }
        var command = command
        if case .remoteSetPresenceRequirement(_, let enabled) = command {
            command = .remoteSetPresenceRequirement(device: device.deviceId, enabled: enabled)
        }
        guard let actions else { return .failure(CommandFailure(.invalidState, "PRBar isn’t ready yet. Try again.")) }
        let origin = CommandOrigin.phone(device: device.deviceId, mayRunRepoCode: caller.mayRunRepoCode)
        // Ni rutas locales, ni herramientas, ni escapes o secretos hacia el teléfono (spec P.7, revisión M1): en el
        // resultado, en el error y en cada evento (el texto del chat en streaming).
        let redactor = redactor()
        let result = await CommandOrigin.$current.withValue(origin) {
            await CommandDispatcher.run(command, on: actions, events: { events(redactor.scrub($0)) })
        }
        return result.map(redactor.scrub).mapError(redactor.scrub)
    }

    /// El `RemoteRedactor` con las carpetas y hosts de la config de ahora (se rearma solo si cambiaron).
    public func redactor() -> RemoteRedactor {
        let inputs = redactionInputs()
        let key = inputs.folders + ["\u{0}"] + inputs.hosts
        if let cachedRedactor, cachedRedactor.inputs == key { return cachedRedactor.redactor }
        let redactor = RemoteRedactor.standard(folders: inputs.folders, hosts: inputs.hosts)
        cachedRedactor = (key, redactor)
        return redactor
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

    /// Las mismas notificaciones que la Mac, cifradas para cada iPhone emparejado (el relay contesta 410 si ese
    /// iPhone no tiene una suscripción de Web Push).
    public func push(_ notifications: [PlannedNotification], badge: Int?) {
        guard let host, !notifications.isEmpty else { return }
        let payloads = RemotePushPlanner.payloads(for: notifications, badge: badge, now: env.clock(), redactor: redactor())
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
        // 410: el relay no tiene suscripción de Web Push o el servicio de push la dio de baja ("Notifications off"
        // hasta que el teléfono registre una nueva).
        let off = status == 410
        guard status == 200 || off else { return }
        try? env.devices.setNotificationsOff(off, for: id)
        devices = env.devices.devices
    }

    /// Un chat que no inició el teléfono (p. ej. desde la Mac): a quien mire `pr:<id>`. `text` ya viene redactado
    /// (`chatDeltaText`).
    public func chatDelta(pr: String, text: String) {
        guard let host, !text.isEmpty else { return }
        Task { await host.sendChatDelta(pr: pr, text: text) }
    }

    /// Lo nuevo de un chat para el teléfono: redacta el texto entero (una ruta puede venir partida entre dos
    /// pedazos) y devuelve lo que se agregó desde `previous` (también redactado), o nil si el texto cambió de otra forma.
    public func chatDeltaText(previous: String, current: String) -> String? {
        let redactor = redactor()
        let before = redactor.text(previous)
        let now = redactor.text(current)
        guard now.count > before.count, now.hasPrefix(before) else { return nil }
        return String(now.dropFirst(before.count))
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
        var info = RemoteDeviceInfo(id: stored.device.deviceId, name: stored.device.name, model: stored.device.model,
                                    pairedAt: stored.device.pairedAt, lastSeen: stored.lastSeen,
                                    online: online.contains(stored.device.deviceId),
                                    requirePresence: stored.device.requirePresence, notifications: !stored.notificationsOff)
        info.faceIDSetUp = stored.device.presence != nil
        return info
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
                                accountPrefix: settings.accountId.map { String($0.prefix(4)) })
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
            // Lo mismo que acepta `RemoteSettings` al leer la config (si no, el próximo arranque apagaría el acceso en
            // silencio; L4).
            guard RemoteSettings.normalizedRelayHost(host, allowIPForTests: env.allowInsecureForTests) != nil,
                  RemoteSettings.isValidAccountId(account) else {
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
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pairWaiters[id] = continuation
            }
        } onCancel: {
            // Solo esta espera (la hoja de Settings puede estar esperando la misma ranura; L3).
            Task { @MainActor [weak self] in
                self?.pairWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func failPairWaiters(_ error: Error) {
        let waiters = pairWaiters
        pairWaiters = [:]
        waiters.values.forEach { $0.resume(throwing: error) }
    }

    public func pairConfirm(pairing id: String, accepted: Bool) async throws -> RemotePairResult {
        guard let current = pairing, current.pairing == id, let host else {
            if accepted { throw CommandFailure(.notFound, "That pairing code isn’t open anymore. Start again.") }
            return RemotePairResult(device: nil)
        }
        guard accepted else {
            // También durante la espera del acuse de "Codes Match": la ranura se cierra en el host, el alta en el relay
            // se deshace y un acuse que llegue después ya no encuentra nada (L3).
            await host.cancelPairing()
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

    /// Sin conexión (o con el acceso apagado) el `device.remove` sale al reconectar (`reconcileRelay`, M5); la Mac igual
    /// deja de aceptar su estática ya.
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
    /// Antes de olvidar las claves se guarda la clave de relay de la cuenta vieja como "retirada" y
    /// `cleanUpRetiredAccounts` la borra del relay (`account.delete`: cuenta, iPhones, suscripciones y buzones) en
    /// cuanto puede, con o sin conexión ahora (revisión M5). Después la olvida.
    public func reset() async throws -> RemoteStatusInfo {
        if let host {
            for device in devices { await host.revoke(device.device.deviceId) }
        }
        await stop()
        if let account = settings.accountId, let relay = settings.relayHost, let keys = env.keys.loadExisting() {
            try env.keys.retire(.init(relayHost: relay, accountId: account, relayKey: keys.relay))
        }
        try env.devices.removeAll()
        devices = []
        try env.keys.reset()
        try store.updateRemoteSettings {
            $0.enabled = false
            $0.accountId = nil
        }
        AppLog.write("iPhone access: reset")
        cleanUpRetiredAccounts()
        return status()
    }

    /// Borra del relay las cuentas retiradas y las olvida. Si no llega al relay (o el relay no pudo borrarla), queda
    /// para el próximo arranque o la próxima vez que se habilite.
    public func cleanUpRetiredAccounts() {
        guard cleanupTask == nil, !env.keys.retiredAccounts().isEmpty else { return }
        let env = env
        cleanupTask = Task { [weak self] in
            for retired in env.keys.retiredAccounts() {
                if await Self.cleanUp(retired, env: env) {
                    try? env.keys.forgetRetired(retired)
                    AppLog.write("iPhone access: the old relay account \(retired.accountId.prefix(4)) is gone")
                }
            }
            self?.cleanupTask = nil
        }
    }

    /// Para los tests: espera la limpieza en curso.
    public func waitForCleanup() async {
        await cleanupTask?.value
    }

    /// Cuánto espera cada respuesta del relay durante la limpieza.
    nonisolated static let cleanupTimeout: Duration = .seconds(15)

    /// Entra como la Mac de la cuenta retirada y le pide al relay que la borre (`account.delete`). `true` si ya no
    /// queda nada (y se puede olvidar la clave); `false` para reintentar más tarde. Un relay viejo sin
    /// `account.delete` contesta `forbidden`: ahí se dan de baja sus dispositivos uno por uno, como antes.
    nonisolated static func cleanUp(_ retired: RemoteKeyStore.RetiredAccount, env: RemoteServiceEnvironment) async -> Bool {
        guard let key = retired.signingKey else { return true }
        let link = env.linkFactory(retired.relayHost)(.signed(account: retired.accountId, client: "mac", key: key))
        defer { Task { await link.close() } }
        do {
            _ = try await link.connect()
            try link.send(.accountDelete)
            switch try await withThrowingTimeout(cleanupTimeout, { try await accountDeleteAnswer(link) }) {
            case .deleted: return true
            case .unsupported: return try await removeDevices(link)
            case .failed: return false
            }
        } catch let closed as RelayClosed where closed.code == RelayCloseCode.unauthorized.rawValue {
            // El relay ya no conoce la cuenta: no queda nada que limpiar.
            return true
        } catch {
            return false
        }
    }

    enum AccountDeleteAnswer: Sendable { case deleted, unsupported, failed }

    /// La respuesta a `account.delete`: `account.deleted` (o el cierre 1000 que lo sigue), `forbidden` (relay viejo) u
    /// otro error (`internal`: no borró nada).
    nonisolated static func accountDeleteAnswer(_ link: RelayLink) async throws -> AccountDeleteAnswer {
        do {
            for try await message in link.incoming {
                switch message {
                case .accountDeleted: return .deleted
                case .error("forbidden"): return .unsupported
                case .error: return .failed
                default: continue
                }
            }
        } catch let closed as RelayClosed where closed.code == 1000 {
            // `account.deleted` se pudo perder con el cierre; el relay solo cierra así a la Mac después de borrarla.
            return .deleted
        }
        throw RelayClosed(code: nil, reason: "Closed")
    }

    /// Lo de antes de `account.delete`: da de baja cada dispositivo que el relay tiene y vuelve a pedir la lista para
    /// confirmar que quedó vacía (el relay procesa en orden). La cuenta, vacía, queda en ese relay.
    nonisolated static func removeDevices(_ link: RelayLink) async throws -> Bool {
        @Sendable func list() async throws -> [RelayDeviceEntry] {
            try link.send(.devices(items: nil))
            for try await message in link.incoming {
                if case .devices(let items?) = message { return items }
            }
            throw RelayClosed(code: nil, reason: "Closed")
        }
        let listed = try await withThrowingTimeout(cleanupTimeout) { try await list() }
        for entry in listed { try link.send(.deviceRemove(device: entry.id)) }
        let after = try await withThrowingTimeout(cleanupTimeout) { try await list() }
        return after.isEmpty
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

}

/// `body`, o falla si tarda más que `limit` (y lo cancela).
func withThrowingTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw RelayClosed(code: nil, reason: "No answer from the relay")
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw CancellationError() }
        return value
    }
}
