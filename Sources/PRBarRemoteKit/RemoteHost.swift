import CryptoKit
import Foundation
import PRBarWire

/// Lo que pasa en el host, para la UI de la Mac (Plan 18) y los tests.
public enum RemoteHostEvent: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        /// Se cortó; reintenta en `retryIn` segundos.
        case offline(retryIn: Int)
        /// El relay la reemplazó por otra Mac con la misma cuenta (4409): no reintenta sola, así las dos no se sacan
        /// el lugar una a la otra para siempre.
        case replaced
    }

    case status(Status)
    /// Un teléfono se unió con el QR: la Mac muestra el código y espera "Codes Match".
    case pairingJoined(sas: String, deviceName: String, model: String)
    /// La ranura se quemó (vencida, cancelada, un segundo teléfono…).
    case pairingEnded(reason: String)
    case devicesChanged([PairedDevice])
    case deviceOnline(String, Bool)
    /// Un handshake o un marco rechazado (estática desconocida, marco que no autentica). Solo el id, nunca el contenido.
    case sessionRejected(device: String)
    /// Comando denegado o sin Face ID: se loguea el nombre, nunca los argumentos (spec P.7).
    case commandRefused(device: String, name: AppCommand.Name)
    /// Un pedido o un handshake frenado por `RemoteLimits`.
    case rateLimited(device: String)
    /// Cambió la unión de los tópicos suscritos (el feed de la Mac calcula solo esos).
    case subscriptionsChanged(Set<String>)
}

/// Cómo terminó `RemoteHost.putMailbox`.
public enum MailboxPutResult: Equatable, Sendable {
    case sent
    case tooLarge
    case notConnected
}

/// Quién mandó un pedido: el dispositivo (como está registrado en la Mac) y si trajo una prueba de Face ID que la Mac
/// verificó para este pedido (spec P.8). El puente lo convierte en `CommandOrigin` (decisión H1).
public struct RemoteCaller: Sendable {
    public var device: PairedDevice
    public var presenceVerified: Bool

    public init(device: PairedDevice, presenceVerified: Bool) {
        self.device = device
        self.presenceVerified = presenceVerified
    }

    /// Lo que el teléfono puede hacer que ejecute código del repo: con la prueba verificada, o si el usuario apagó
    /// "Require Face ID" para ese iPhone en la Mac.
    public var mayRunRepoCode: Bool { presenceVerified || !device.requirePresence }
}

/// La máquina de estado de la Mac (spec P y Q.1): una conexión con el relay, una sesión de Noise KK por teléfono,
/// el emparejamiento, y cada `req` pasa por `RemotePolicy` → presencia → `handler` (el `CommandDispatcher` de la app).
public actor RemoteHost {
    public typealias Handler = @Sendable (AppCommand, @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure>
    /// Como `Handler`, con quién lo pidió (el puente de la Mac lo loguea, lo usa para que
    /// `remoteSetPresenceRequirement` solo cambie al propio teléfono, y para `CommandOrigin`: H1).
    public typealias DeviceHandler = @Sendable (AppCommand, RemoteCaller, @escaping CommandEventSink) async
        -> Result<JSONValue, CommandFailure>

    public struct Configuration: Sendable {
        public var accountId: String
        /// El host del relay que va en el QR (y que firma el desafío).
        public var relayHost: String
        /// El origen de la web app (W.5): el `origin` que tiene que traer cada aserción de WebAuthn. Su host (sin
        /// puerto) es el rpId de las passkeys. Por defecto `https://<relayHost>`.
        public var webOrigin: String
        public var macName: String
        public var appVersion: String
        public var keys: MacKeys
        /// Rango de `commandProtocol` del teléfono que se acepta (spec P.6).
        public var commandProtocol: Int
        public var minimumRemoteVersion: Int
        public var pairingLifetime: TimeInterval
        public var pushTimeout: Duration
        /// Cuánto espera "Codes Match" el acuse del teléfono antes de deshacer el alta.
        public var pairingAckTimeout: Duration
        public var limits: RemoteLimits
        /// Espera antes de reconectar con el relay (intento 1, 2, …).
        public var backoff: @Sendable (Int) -> Duration

        /// El rpId que tienen que tener las passkeys: el host de `webOrigin`, sin puerto.
        public var rpId: String { URLComponents(string: webOrigin)?.host ?? relayHost }

        public init(accountId: String, relayHost: String, macName: String, appVersion: String, keys: MacKeys,
                    commandProtocol: Int = CommandProtocol.version,
                    minimumRemoteVersion: Int = CommandProtocol.minimumRemoteVersion,
                    pairingLifetime: TimeInterval = 300, pushTimeout: Duration = .seconds(10),
                    pairingAckTimeout: Duration = .seconds(20), limits: RemoteLimits = .standard,
                    backoff: @escaping @Sendable (Int) -> Duration = RemoteBackoff.standard,
                    webOrigin: String? = nil) {
            self.accountId = accountId
            self.relayHost = relayHost
            self.webOrigin = webOrigin ?? "https://\(relayHost)"
            self.macName = macName
            self.appVersion = appVersion
            self.keys = keys
            self.commandProtocol = commandProtocol
            self.minimumRemoteVersion = minimumRemoteVersion
            self.pairingLifetime = pairingLifetime
            self.pushTimeout = pushTimeout
            self.pairingAckTimeout = pairingAckTimeout
            self.limits = limits
            self.backoff = backoff
        }
    }

    private struct Session {
        var channel: SecureChannel
        var lastRequestId = 0
        var topics: Set<String> = []
        var helloDone = false
        var incompatible = false
        var replayGuard = PresenceReplayGuard()
        var sentRevs: [String: Int] = [:]
        /// Pedidos ejecutándose ahora (tope `limits.maxConcurrentRequests`).
        var inFlight = 0
    }

    private struct PairingSlot {
        let pairingId: String
        let secret: Data
        let secrets: PairingSecrets
        let expires: Date
        var sid: String?
        var transport: NoiseTransport?
        var handshakeHash: Data?
        var deviceStatic: Data?
        var join: PairingJoin?
        var confirmed = false
        /// "Codes Match": el dispositivo que se guarda cuando el teléfono acusa recibo del resultado (M1).
        var pendingDevice: PairedDevice?
        var ackWaiter: CheckedContinuation<PairedDevice?, Error>?
    }

    private let config: Configuration
    private let linkFactory: RelayLinkFactory
    private let handler: DeviceHandler
    private let clock: @Sendable () -> Date
    private var link: RelayLink?
    private var receiveTask: Task<Void, Never>?
    private var wantsConnection = false
    /// Sube con cada `connect()`/`disconnect()`: un `openLink` o un ciclo de reconexión de antes no guarda su link.
    private var generation = 0
    /// Cuándo abrió el link actual: uno que se cae enseguida no reinicia el backoff (M7).
    private var linkOpenedAt: Date?
    /// Cortes seguidos de links que duraron menos que `stableLinkDuration`.
    private var quickDrops = 0
    static let stableLinkDuration: TimeInterval = 30
    private var devices: [String: PairedDevice]
    private var sessions: [String: Session] = [:]
    private var online: Set<String> = []
    private var pairing: PairingSlot?
    private var latest: [String: (rev: Int, data: JSONValue)] = [:]
    private var mailboxRev = 0
    private var pushWaiters: [String: CheckedContinuation<Int, Error>] = [:]
    /// Handshakes que todavía no probaron estar vivos: la sesión pasa a `sessions` cuando su primer marco descifra
    /// (un primer mensaje de KK repetido por el relay no tira la sesión viva, L2).
    private var pendingSessions: [String: Session] = [:]
    private var deviceListWaiters: [CheckedContinuation<[RelayDeviceEntry], Error>] = []
    private var requestBuckets: [String: TokenBucket] = [:]
    private var handshakeBuckets: [String: TokenBucket] = [:]

    public nonisolated let events: AsyncStream<RemoteHostEvent>
    private let eventSink: AsyncStream<RemoteHostEvent>.Continuation

    static let maxTopics = 32
    static let maxTopicLength = 256
    /// `sentAt` aceptado (spec P.6).
    static let maxRequestAge: TimeInterval = 120
    static let maxRequestFuture: TimeInterval = 30

    public init(configuration: Configuration, devices: [PairedDevice], linkFactory: @escaping RelayLinkFactory,
                clock: @escaping @Sendable () -> Date = { Date() }, handler: @escaping Handler) {
        self.init(configuration: configuration, devices: devices, linkFactory: linkFactory, clock: clock,
                  deviceHandler: { command, _, sink in await handler(command, sink) })
    }

    public init(configuration: Configuration, devices: [PairedDevice], linkFactory: @escaping RelayLinkFactory,
                clock: @escaping @Sendable () -> Date = { Date() }, deviceHandler: @escaping DeviceHandler) {
        config = configuration
        self.linkFactory = linkFactory
        self.handler = deviceHandler
        self.clock = clock
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.deviceId, $0) })
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    // MARK: - Conexión

    public var pairedDevices: [PairedDevice] { devices.values.sorted { $0.pairedAt < $1.pairedAt } }
    public var onlineDevices: Set<String> { online }
    public var isConnected: Bool { link != nil }
    /// La unión de los tópicos de las sesiones abiertas.
    public var subscribedTopics: Set<String> { sessions.values.reduce(into: Set<String>()) { $0.formUnion($1.topics) } }

    /// Conecta y se queda conectado (reconecta con `backoff`) hasta `disconnect()`.
    public func connect() async throws {
        wantsConnection = true
        generation += 1
        quickDrops = 0
        try await openLink(generation: generation)
    }

    /// Abre un link y lo guarda, salvo que mientras conectaba se haya llamado a `disconnect()` (o a otro `connect()`)
    /// o se haya cancelado la tarea: ahí lo cierra y lanza `CancellationError` (nada queda abierto sin dueño; H4).
    private func openLink(generation: Int) async throws {
        eventSink.yield(.status(.connecting))
        let link = linkFactory(.signed(account: config.accountId, client: "mac", key: config.keys.relay))
        do {
            _ = try await link.connect()
        } catch {
            await link.close()
            throw error
        }
        guard wantsConnection, generation == self.generation, self.link == nil, !Task.isCancelled else {
            await link.close()
            throw CancellationError()
        }
        self.link = link
        linkOpenedAt = clock()
        eventSink.yield(.status(.connected))
        receiveTask = Task { [weak self] in
            var closeError: Error?
            do {
                for try await message in link.incoming {
                    await self?.handle(message)
                }
            } catch {
                closeError = error
            }
            await self?.linkEnded(link, error: closeError)
        }
    }

    private func linkEnded(_ ended: RelayLink, error: Error?) async {
        guard link === ended else { return }
        dropAll()
        // Corta también el escritor y el ping del link (si no, quedan vivos; L4).
        await ended.close()
        guard wantsConnection else { return }
        if (error as? RelayClosed)?.code == RelayCloseCode.replaced.rawValue {
            // Otra Mac con la misma cuenta se conectó: esta da un paso al costado en vez de reconectar y sacarla.
            wantsConnection = false
            generation += 1
            eventSink.yield(.status(.replaced))
            return
        }
        // Un link que no duró nada no reinicia el backoff: si el relay lo corta enseguida, los reintentos se espacian.
        let stable = linkOpenedAt.map { clock().timeIntervalSince($0) >= Self.stableLinkDuration } ?? false
        quickDrops = stable ? 0 : quickDrops + 1
        let current = generation
        var attempt = 1 + quickDrops
        while wantsConnection, generation == current {
            let delay = config.backoff(attempt)
            eventSink.yield(.status(.offline(retryIn: Int(delay.components.seconds))))
            try? await Task.sleep(for: delay)
            guard wantsConnection, generation == current, link == nil else { return }
            do {
                try await openLink(generation: current)
                return
            } catch {
                attempt += 1
            }
        }
    }

    private func dropAll() {
        link = nil
        sessions = [:]
        pendingSessions = [:]
        online = []
        for (_, waiter) in pushWaiters { waiter.resume(throwing: RelayClosed(code: nil, reason: "Disconnected")) }
        pushWaiters = [:]
        failDeviceListWaiters()
    }

    public func disconnect() async {
        wantsConnection = false
        generation += 1
        let current = link
        receiveTask?.cancel()
        dropAll()
        await current?.close()
        eventSink.yield(.status(.disconnected))
    }

    private func send(_ message: RelayMessage) {
        guard let link else { return }
        do {
            try link.send(message)
        } catch {
            // Cola llena o conexión caída: la sesión se rehace al reconectar.
            Task { await link.close() }
        }
    }

    // MARK: - Mensajes del relay

    private func handle(_ message: RelayMessage) {
        switch message {
        case .recv(let from, let sid, let b):
            if from.hasPrefix("pair:") {
                handlePairing(from: from, sid: sid, b: b)
            } else {
                handleDevice(from, sid: sid, b: b)
            }
        case .presence(_, _, let device?, let state?):
            if state == "online" {
                online.insert(device)
            } else {
                online.remove(device)
                sessions[device] = nil
                pendingSessions[device] = nil
            }
            eventSink.yield(.deviceOnline(device, state == "online"))
        case .devices(let items?):
            let waiters = deviceListWaiters
            deviceListWaiters = []
            waiters.forEach { $0.resume(returning: items) }
        case .pushResult(let id, let status, _):
            pushWaiters.removeValue(forKey: id)?.resume(returning: status)
        case .pairClose(let pairingId):
            // El relay quemó la ranura (un segundo teléfono, proofs fallidos o vencida).
            endPairing(pairingId, reason: "closed by the relay", notifyPhone: true)
        case .undeliverable(let to, _) where to.hasPrefix("pair:"):
            // El resultado del emparejamiento no llegó: el alta (todavía sin guardar) se deshace. Fuera de esa espera
            // no hace nada: un `undeliverable` lo puede inventar el relay (M1).
            if let slot = pairing, "pair:\(slot.pairingId)" == to, slot.pendingDevice != nil {
                endPairing(slot.pairingId, reason: "not delivered", notifyPhone: false)
            }
        case .undeliverable(let to, let sid):
            // El teléfono se fue: su sesión ya no sirve.
            if sessions[to]?.channel.sid == sid { sessions[to] = nil }
        default:
            break
        }
    }

    private func handleDevice(_ deviceId: String, sid: String, b: Data) {
        guard RemoteSID.isValid(sid) else { return }
        if var session = sessions[deviceId], session.channel.sid == sid {
            do {
                guard let frame = try session.channel.open(b) else {
                    sessions[deviceId] = session
                    return
                }
                sessions[deviceId] = session
                handleFrame(frame, from: deviceId, sid: sid)
            } catch {
                // Repetido, fuera de orden, cambiado o malformado: la sesión se cierra (spec P.5).
                closeSession(deviceId, reason: "desync")
                eventSink.yield(.sessionRejected(device: deviceId))
            }
            return
        }
        if var pending = pendingSessions[deviceId], pending.channel.sid == sid {
            pendingSessions[deviceId] = nil
            do {
                let frame = try pending.channel.open(b)
                // El teléfono probó estar vivo: esta sesión reemplaza a la anterior (si había).
                sessions[deviceId] = pending
                if let frame { handleFrame(frame, from: deviceId, sid: sid) }
            } catch {
                eventSink.yield(.sessionRejected(device: deviceId))
            }
            return
        }
        acceptHandshake(from: deviceId, sid: sid, message: b)
    }

    /// Un `sid` nuevo es el primer mensaje de un KK. Solo con un dispositivo emparejado (la revocación la hace cumplir
    /// la Mac aunque el relay no obedezca, spec P.12).
    private func acceptHandshake(from deviceId: String, sid: String, message: Data) {
        guard let device = devices[deviceId],
              let deviceStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.noise) else {
            eventSink.yield(.sessionRejected(device: deviceId))
            return
        }
        // Cada handshake son cuatro Diffie-Hellman: un relay que repite primeros mensajes se frena acá.
        let now = clock()
        var bucket = handshakeBuckets[deviceId]
            ?? TokenBucket(capacity: config.limits.handshakeBurst, perSecond: config.limits.handshakesPerMinute / 60, now: now)
        let allowed = bucket.take(now: now)
        handshakeBuckets[deviceId] = bucket
        guard allowed else {
            eventSink.yield(.rateLimited(device: deviceId))
            return
        }
        do {
            var handshake = try NoiseHandshake(
                pattern: .kk, initiator: false,
                prologue: RemotePrologue.session(account: config.accountId, device: deviceId),
                localStatic: config.keys.noise, remoteStatic: deviceStatic, psk: nil)
            // El primer mensaje no lleva comandos (spec P.5): se ignora su payload.
            _ = try handshake.readMessage(message)
            let reply = try handshake.writeMessage()
            // Una sesión nueva del mismo dispositivo reemplaza a la anterior, pero recién cuando su primer marco
            // descifra (L2).
            pendingSessions[deviceId] = Session(channel: try SecureChannel(sid: sid, handshake: handshake, startedAt: clock()))
            send(.send(to: deviceId, sid: sid, b: reply))
        } catch {
            eventSink.yield(.sessionRejected(device: deviceId))
        }
    }

    private func closeSession(_ deviceId: String, reason: String) {
        sendFrame(.bye(reason: reason), to: deviceId)
        sessions[deviceId] = nil
    }

    private func sendFrame(_ frame: RemoteFrame, to deviceId: String, sid expected: String? = nil) {
        guard var session = sessions[deviceId] else { return }
        if let expected, session.channel.sid != expected { return }
        do {
            let chunks = try session.channel.seal(frame)
            let sid = session.channel.sid
            sessions[deviceId] = session
            for chunk in chunks { send(.send(to: deviceId, sid: sid, b: chunk)) }
            if case .bye = frame { return }
            // A las 24 h o 2²⁰ mensajes: el teléfono hace otro handshake (spec P.5).
            if session.channel.needsRotation(now: clock()) { closeSession(deviceId, reason: "rotate") }
        } catch {
            sessions[deviceId] = nil
        }
    }

    // MARK: - Marcos de aplicación

    private func handleFrame(_ frame: RemoteFrame, from deviceId: String, sid: String) {
        guard var session = sessions[deviceId] else { return }
        switch frame {
        case .hello(let hello):
            let incompatible: RemoteHello.Incompatibility? =
                hello.commandProtocol < config.minimumRemoteVersion ? .updateIPhone
                : hello.commandProtocol > config.commandProtocol ? .updateMac
                : hello.remoteProtocol != RemoteProtocol.version ? (hello.remoteProtocol < RemoteProtocol.version ? .updateIPhone : .updateMac)
                : nil
            session.helloDone = true
            session.incompatible = incompatible != nil
            sessions[deviceId] = session
            // La política va antes del `hello`: cuando el teléfono termina de conectar ya la tiene.
            if incompatible == nil, let device = devices[deviceId] {
                sendFrame(.presencePolicy(requirePresence: device.requirePresence, gated: RemotePolicy.gatedNames),
                          to: deviceId, sid: sid)
            }
            sendFrame(.hello(RemoteHello(commandProtocol: config.commandProtocol, appVersion: config.appVersion,
                                         macName: config.macName, incompatible: incompatible)), to: deviceId, sid: sid)
        case .req(let request):
            guard session.helloDone else { return closeSession(deviceId, reason: "protocol") }
            // Ids crecientes por sesión: uno repetido o menor se rechaza (spec P.6).
            guard request.id > session.lastRequestId else {
                return sendFrame(.res(.failure(id: request.id, CommandFailure(.invalidState, "Duplicate request."))),
                                 to: deviceId, sid: sid)
            }
            session.lastRequestId = request.id
            guard takeRequestToken(deviceId), session.inFlight < config.limits.maxConcurrentRequests else {
                sessions[deviceId] = session
                eventSink.yield(.rateLimited(device: deviceId))
                return sendFrame(.res(.failure(id: request.id, CommandFailure(.invalidState, RemoteLimits.tooManyRequestsMessage))),
                                 to: deviceId, sid: sid)
            }
            session.inFlight += 1
            sessions[deviceId] = session
            Task {
                await self.execute(request, from: deviceId, sid: sid)
                self.requestFinished(deviceId, sid: sid)
            }
        case .sub(let topics):
            guard takeRequestToken(deviceId) else {
                eventSink.yield(.rateLimited(device: deviceId))
                return
            }
            let accepted = Set(topics.prefix(Self.maxTopics).filter { $0.count <= Self.maxTopicLength })
            session.topics = accepted
            session.sentRevs = session.sentRevs.filter { accepted.contains($0.key) }
            sessions[deviceId] = session
            eventSink.yield(.subscriptionsChanged(subscribedTopics))
            for topic in accepted.sorted() { sendState(topic, to: deviceId) }
        case .unpair:
            revoke(deviceId)
        case .bye:
            sessions[deviceId] = nil
        case .res, .state, .chatDelta, .presencePolicy, .unknown:
            break
        }
    }

    private func takeRequestToken(_ deviceId: String) -> Bool {
        let now = clock()
        var bucket = requestBuckets[deviceId]
            ?? TokenBucket(capacity: config.limits.requestBurst, perSecond: config.limits.requestsPerSecond, now: now)
        let allowed = bucket.take(now: now)
        requestBuckets[deviceId] = bucket
        return allowed
    }

    private func requestFinished(_ deviceId: String, sid: String) {
        guard var session = sessions[deviceId], session.channel.sid == sid else { return }
        session.inFlight = max(0, session.inFlight - 1)
        sessions[deviceId] = session
    }

    private func execute(_ request: RemoteRequest, from deviceId: String, sid: String) async {
        let now = clock()
        func reply(_ failure: CommandFailure) {
            sendFrame(.res(.failure(id: request.id, failure)), to: deviceId, sid: sid)
        }
        guard let session = sessions[deviceId], session.channel.sid == sid else { return }
        guard !session.incompatible else {
            return reply(CommandFailure(.protocolMismatch, "Update PRBar on your Mac and iPhone."))
        }
        // El relay no puede retener un comando y soltarlo después (spec P.6).
        let age = now.timeIntervalSince(request.sentAt)
        // Ni después del plazo del teléfono, que ya mostró "no contestó" (L3).
        let pastDeadline = request.deadline.map { now > $0 } ?? false
        guard age <= Self.maxRequestAge, age >= -Self.maxRequestFuture, !pastDeadline else {
            return reply(CommandFailure(.invalidState, "This request expired. Try again."))
        }
        guard let command = try? request.command() else {
            return reply(CommandFailure.unknownCommand(app: config.appVersion))
        }
        // Solo `true` si la prueba de Face ID de este pedido se verificó recién (no "el dispositivo no la exige").
        var presenceVerified = false
        switch RemotePolicy.decide(command) {
        case .denied:
            eventSink.yield(.commandRefused(device: deviceId, name: command.name))
            return reply(CommandFailure(.unauthorized, RemotePolicy.deniedMessage))
        case .gated where devices[deviceId]?.requirePresence ?? true:
            if let device = devices[deviceId], device.presence == nil {
                // Se emparejó sin passkey (W.4.6): no hay con qué verificar Face ID.
                eventSink.yield(.commandRefused(device: deviceId, name: command.name))
                return reply(CommandFailure(.unauthorized, RemotePolicy.presenceNotSetUpMessage))
            }
            guard let device = devices[deviceId], let credential = device.presence, let proof = request.presence,
                  (try? WebAuthnPresenceVerifier.verify(proof, credential: credential, origin: config.webOrigin,
                                                        sessionHash: session.channel.handshakeHash,
                                                        reqId: UInt64(max(request.id, 0)), commandBytes: request.cmd,
                                                        now: now)) != nil,
                  checkReplay(deviceId: deviceId, sid: sid, reqId: request.id, now: now) else {
                eventSink.yield(.commandRefused(device: deviceId, name: command.name))
                return reply(CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))
            }
            presenceVerified = true
        case .gated, .allowed:
            break
        }
        // Los eventos salen en orden y antes de la respuesta final.
        let (stream, continuation) = AsyncStream<CommandEvent>.makeStream()
        let pump = Task {
            for await event in stream { self.sendFrame(.res(.event(id: request.id, event)), to: deviceId, sid: sid) }
        }
        guard let device = devices[deviceId] else {
            continuation.finish()
            await pump.value
            return reply(CommandFailure(.unauthorized, RemotePolicy.deniedMessage))
        }
        let caller = RemoteCaller(device: device, presenceVerified: presenceVerified)
        let result = await handler(command, caller) { continuation.yield($0) }
        continuation.finish()
        await pump.value
        switch result {
        case .success(let value): sendFrame(.res(.success(id: request.id, value)), to: deviceId, sid: sid)
        case .failure(let failure): reply(failure)
        }
    }

    private func checkReplay(deviceId: String, sid: String, reqId: Int, now: Date) -> Bool {
        guard var session = sessions[deviceId], session.channel.sid == sid else { return false }
        do {
            try session.replayGuard.check(sessionHash: session.channel.handshakeHash, reqId: UInt64(reqId), now: now)
            sessions[deviceId] = session
            return true
        } catch {
            return false
        }
    }

    // MARK: - Estado, buzón y pushes

    /// Guarda el último valor de un tópico y lo manda a las sesiones suscritas si cambió (`rev` creciente).
    public func publish(topic: String, data: JSONValue) {
        if let current = latest[topic], current.data == data { return }
        latest[topic] = ((latest[topic]?.rev ?? 0) + 1, data)
        for (deviceId, session) in sessions where session.topics.contains(topic) { sendState(topic, to: deviceId) }
    }

    /// Un pedazo de un chat que no inició el teléfono (p. ej. desde la Mac), a las sesiones suscritas a `pr:<pr>`.
    public func sendChatDelta(pr: String, text: String) {
        for (deviceId, session) in sessions where session.topics.contains("pr:\(pr)") {
            sendFrame(.chatDelta(pr: pr, text: text), to: deviceId)
        }
    }

    private func sendState(_ topic: String, to deviceId: String) {
        guard var session = sessions[deviceId], let current = latest[topic],
              session.sentRevs[topic] != current.rev else { return }
        session.sentRevs[topic] = current.rev
        sessions[deviceId] = session
        sendFrame(.state(RemoteStateUpdate(topic: topic, rev: current.rev, data: current.data)), to: deviceId)
    }

    /// Guarda `data` cifrado para cada dispositivo en la ranura `slot` del buzón del relay.
    /// Un blob del buzón viaja en un solo marco del relay (≤ 128 KiB de JSON, con `b` en base64): 90 KiB cifrados
    /// dejan margen. Más grande no se guarda (el teléfono igual recibe el estado en vivo).
    public static let maxMailboxBlob = 90 * 1024

    /// Devuelve `.tooLarge` si `data` no entra en el buzón y `.notConnected` si no hay conexión (no se mandó nada: hay
    /// que volver a escribirlo al reconectar; M8).
    @discardableResult
    public func putMailbox(slot: String, data: Data) -> MailboxPutResult {
        guard data.count + 1024 <= Self.maxMailboxBlob else { return .tooLarge }
        guard link != nil else { return .notConnected }
        let now = clock()
        mailboxRev = max(mailboxRev + 1, Int(now.timeIntervalSince1970 * 1000))
        let blob = MailboxBlob(slot: slot, rev: mailboxRev, createdAt: now, data: data)
        for device in devices.values {
            guard let push = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.push),
                  let sealed = try? blob.seal(from: config.keys.seal, to: push, account: config.accountId,
                                              device: device.deviceId) else { continue }
            guard sealed.count <= Self.maxMailboxBlob else { return .tooLarge }
            send(.mboxPut(to: device.deviceId, slot: slot, b: sealed))
        }
        return .sent
    }

    /// Manda un push cifrado; devuelve el status que informa el relay (200 entregado, 410 sin suscripción).
    public func push(_ payload: PushPayload, to deviceId: String) async throws -> Int {
        guard let device = devices[deviceId], link != nil else { throw RelayClosed(code: nil, reason: "Not connected") }
        let push = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.push)
        let envelope = try payload.sealedForPush(from: config.keys.seal, to: push,
                                                 info: SealedInfo.push(account: config.accountId, device: deviceId))
        let ids = try PushIdentifiers(macSeal: config.keys.seal, devicePush: push)
        let id = UUID().uuidString.lowercased()
        let pr = payload.pr ?? payload.threadId
        send(.push(id: id, to: deviceId, collapse: ids.collapse(kind: payload.kind, pr: pr), thread: ids.thread(pr: pr),
                   b: envelope))
        let timeout = config.pushTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            self.pushTimedOut(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { pushWaiters[id] = $0 }
    }

    private func pushTimedOut(_ id: String) {
        pushWaiters.removeValue(forKey: id)?.resume(throwing: RelayClosed(code: nil, reason: "No answer from the relay"))
    }

    // MARK: - Dispositivos

    /// Los dispositivos que el relay tiene para esta cuenta (para reconciliar con los de la Mac al conectar, M5).
    public func relayDevices(timeout: Duration = .seconds(10)) async throws -> [RelayDeviceEntry] {
        guard link != nil else { throw RelayClosed(code: nil, reason: "Not connected") }
        return try await withCheckedThrowingContinuation { continuation in
            deviceListWaiters.append(continuation)
            send(.devices(items: nil))
            Task {
                try? await Task.sleep(for: timeout)
                self.failDeviceListWaiters()
            }
        }
    }

    private func failDeviceListWaiters() {
        let waiters = deviceListWaiters
        deviceListWaiters = []
        waiters.forEach { $0.resume(throwing: RelayClosed(code: nil, reason: "No answer from the relay")) }
    }

    /// Da de baja en el relay un dispositivo que la Mac ya no tiene (un Revoke o un Reset hechos sin conexión, M5).
    public func removeFromRelay(_ deviceId: String) {
        guard devices[deviceId] == nil else { return }
        send(.deviceRemove(device: deviceId))
    }

    /// El dispositivo de un "Codes Match" que espera el acuse (ya dado de alta en el relay, todavía no en la Mac).
    public var pendingPairingDevice: String? { pairing?.pendingDevice?.deviceId }

    /// Revoke (spec P.12): la Mac lo olvida (deja de aceptar su estática) y le pide al relay que lo dé de baja.
    public func revoke(_ deviceId: String) {
        guard devices.removeValue(forKey: deviceId) != nil else { return }
        pendingSessions[deviceId] = nil
        if sessions[deviceId] != nil { closeSession(deviceId, reason: "revoked") }
        send(.deviceRemove(device: deviceId))
        eventSink.yield(.devicesChanged(pairedDevices))
    }

    /// Prende o apaga Face ID para un dispositivo y se lo avisa (`presencePolicy`).
    public func setRequirePresence(_ deviceId: String, _ required: Bool) {
        guard devices[deviceId] != nil else { return }
        devices[deviceId]?.requirePresence = required
        sendFrame(.presencePolicy(requirePresence: required, gated: RemotePolicy.gatedNames), to: deviceId)
        eventSink.yield(.devicesChanged(pairedDevices))
    }

    // MARK: - Emparejamiento (spec P.11)

    /// Abre una ranura (una por cuenta, 5 min) y devuelve el QR. Reemplaza a una ranura anterior.
    public func startPairing() throws -> PairingQR {
        guard link != nil else { throw RelayClosed(code: nil, reason: "Not connected") }
        if let old = pairing { endPairing(old.pairingId, reason: "replaced", notifyPhone: true) }
        let secret = randomBytes(32)
        let slot = PairingSlot(pairingId: RemoteIDs.newPairingId(), secret: secret, secrets: PairingSecrets(secret: secret),
                               expires: clock().addingTimeInterval(config.pairingLifetime))
        pairing = slot
        send(.pairOpen(pairing: slot.pairingId, authKey: slot.secrets.authKey,
                       expires: Int(slot.expires.timeIntervalSince1970)))
        return PairingQR(relayHost: config.relayHost, accountId: config.accountId, pairingId: slot.pairingId,
                         secret: secret, macStatic: config.keys.noise.publicKey.rawRepresentation, macName: config.macName)
    }

    private func endPairing(_ pairingId: String, reason: String, notifyPhone: Bool) {
        guard let slot = pairing, slot.pairingId == pairingId else { return }
        if let device = slot.pendingDevice {
            // El teléfono nunca acusó recibo: el alta en el relay se deshace y nada queda guardado en la Mac.
            send(.deviceRemove(device: device.deviceId))
            slot.ackWaiter?.resume(throwing: CommandFailure(.failed, Self.pairingNotConfirmedMessage))
        }
        if notifyPhone, var transport = slot.transport, let sid = slot.sid,
           let message = try? transport.send.encrypt(try PairingMessage.cancelled.encoded()) {
            send(.send(to: "pair:\(pairingId)", sid: sid, b: message))
        }
        send(.pairClose(pairing: pairingId))
        pairing = nil
        eventSink.yield(.pairingEnded(reason: reason))
    }

    public func cancelPairing() {
        if let slot = pairing { endPairing(slot.pairingId, reason: "cancelled", notifyPhone: true) }
    }

    private func handlePairing(from: String, sid: String, b: Data) {
        guard var slot = pairing, from == "pair:\(slot.pairingId)", RemoteSID.isValid(sid) else { return }
        guard clock() < slot.expires else { return endPairing(slot.pairingId, reason: "expired", notifyPhone: true) }
        if let current = slot.sid, current != sid {
            // Un segundo teléfono en la misma ranura: se quema (spec P.11).
            return endPairing(slot.pairingId, reason: "another device", notifyPhone: true)
        }
        do {
            if slot.sid == nil {
                var handshake = try NoiseHandshake(
                    pattern: .ikpsk2, initiator: false,
                    prologue: RemotePrologue.pairing(account: config.accountId, pairing: slot.pairingId),
                    localStatic: config.keys.noise, remoteStatic: nil, psk: slot.secrets.psk)
                guard case .join(var join) = try PairingMessage.decode(try handshake.readMessage(b)), join.isValid else {
                    throw NoiseError.malformed
                }
                // Una passkey de otro sitio nunca daría aserciones válidas para esta Mac.
                if let presence = join.presence, presence.rpId != config.rpId { throw NoiseError.malformed }
                // Lo muestra la hoja de emparejar, Settings y `prbar remote devices`: una línea sin bidi (L5).
                join.deviceName = RemoteText.displayName(join.deviceName)
                join.model = RemoteText.displayName(join.model)
                guard !join.deviceName.isEmpty else { throw NoiseError.malformed }
                let reply = try handshake.writeMessage()
                slot.sid = sid
                slot.join = join
                slot.deviceStatic = handshake.remoteStaticKey?.rawRepresentation
                slot.handshakeHash = handshake.handshakeHash
                slot.transport = try handshake.split()
                pairing = slot
                send(.send(to: from, sid: sid, b: reply))
            } else if !slot.confirmed, var transport = slot.transport {
                guard case .confirm = try PairingMessage.decode(try transport.receive.decrypt(b)),
                      let hash = slot.handshakeHash, let join = slot.join else { throw NoiseError.malformed }
                slot.transport = transport
                slot.confirmed = true
                pairing = slot
                eventSink.yield(.pairingJoined(sas: SAS.code(handshakeHash: hash), deviceName: join.deviceName,
                                               model: join.model))
            } else if let device = slot.pendingDevice, var transport = slot.transport {
                guard case .ack = try PairingMessage.decode(try transport.receive.decrypt(b)) else { throw NoiseError.malformed }
                // Recién ahora el dispositivo existe para la Mac (M1).
                let waiter = slot.ackWaiter
                send(.pairClose(pairing: slot.pairingId))
                pairing = nil
                devices[device.deviceId] = device
                eventSink.yield(.pairingEnded(reason: "paired"))
                eventSink.yield(.devicesChanged(pairedDevices))
                waiter?.resume(returning: device)
            }
        } catch {
            endPairing(slot.pairingId, reason: "failed", notifyPhone: false)
        }
    }

    static let pairingNotConfirmedMessage = "Your iPhone didn’t confirm the pairing. Try again."

    /// "Codes Match" (`true`) o "Cancel" (`false`). Con `true` manda el resultado y espera el acuse del teléfono: el
    /// dispositivo se guarda recién entonces (un relay no puede deshacer después un emparejamiento terminado, M1).
    /// Sin acuse a tiempo, el alta se deshace y falla.
    @discardableResult
    public func confirmPairing(_ accepted: Bool) async throws -> PairedDevice? {
        guard let slot = pairing, slot.confirmed, slot.pendingDevice == nil, var transport = slot.transport,
              let sid = slot.sid, let join = slot.join, let deviceStatic = slot.deviceStatic else {
            throw CommandFailure(.invalidState, "No iPhone is waiting to pair.")
        }
        guard accepted else {
            endPairing(slot.pairingId, reason: "cancelled", notifyPhone: true)
            return nil
        }
        let device = PairedDevice(deviceId: RemoteIDs.newDeviceId(), name: join.deviceName, model: join.model,
                                  noise: deviceStatic, push: join.push, presence: join.presence, pairedAt: clock())
        let result = PairingMessage.result(PairingResult(deviceId: device.deviceId, macName: config.macName,
                                                         macSeal: config.keys.seal.publicKey.rawRepresentation,
                                                         relayHost: config.relayHost))
        let message = try transport.send.encrypt(try result.encoded())
        let pairingId = slot.pairingId
        // El alta en el relay va antes que la respuesta: cuando el teléfono conecte como dispositivo, ya existe.
        send(.deviceAdd(device: device.deviceId, relayKey: join.relayKey))
        send(.send(to: "pair:\(pairingId)", sid: sid, b: message))
        let timeout = config.pairingAckTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pairing?.transport = transport
            pairing?.pendingDevice = device
            pairing?.ackWaiter = continuation
            Task {
                try? await Task.sleep(for: timeout)
                self.endPairing(pairingId, reason: "not confirmed", notifyPhone: true)
            }
        }
    }
}

public enum RemoteBackoff {
    /// 1 s, 2 s, 4 s … hasta 60 s, ±20 % (spec Q.1).
    public static let standard: @Sendable (Int) -> Duration = { attempt in
        let base = min(60.0, pow(2.0, Double(max(attempt - 1, 0))))
        return .milliseconds(Int(base * Double.random(in: 0.8...1.2) * 1000))
    }
}
