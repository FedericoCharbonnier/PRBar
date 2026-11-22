import CryptoKit
import Foundation
import PRBarWire

/// Errores del lado del teléfono, con el texto que muestra la UI.
public enum RemoteError: Error, Equatable, Sendable, LocalizedError {
    case notPaired
    case macOffline(since: Date?)
    case relayUnreachable
    case revoked
    /// El relay cerró con 4401/4403. No es una revocación (eso lo dice solo la Mac, dentro de la sesión, M3): el
    /// relay pudo perder su base o portarse mal. No se borra nada.
    case relayRejected
    case incompatible(RemoteHello.Incompatibility)
    case pairingCancelled
    case pairingExpired
    case handshakeFailed
    case sessionClosed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notPaired: "This iPhone isn’t paired with a Mac."
        case .macOffline: "Your Mac is offline."
        case .relayUnreachable: "Can’t reach the relay server."
        case .revoked: "This iPhone was removed from your Mac."
        case .relayRejected: "The relay server didn’t accept this iPhone. Check iPhone access in PRBar on your Mac."
        case .incompatible(.updateMac): "Update PRBar on your Mac."
        case .incompatible(.updateIPhone): "Update PRBar on this iPhone."
        case .pairingCancelled: "Pairing was cancelled on your Mac."
        case .pairingExpired: "This code expired or was already used. Show a new one on your Mac."
        case .handshakeFailed: "Couldn’t open a secure session with your Mac."
        case .sessionClosed: "The connection with your Mac was reset. Try again."
        case .timeout: "Your Mac didn’t answer in time. Refresh to see whether it ran."
        }
    }
}

public enum RemoteClientStatus: Equatable, Sendable {
    case unpaired
    case disconnected
    case connecting
    case online
    case macOffline(since: Date?)
    case relayUnreachable
    case relayRejected
    case revoked
    case incompatible(RemoteHello.Incompatibility)
}

/// La máquina de estado del teléfono (spec P y R.3): emparejar, conectar (Noise KK), mandar comandos con sus eventos,
/// suscribirse a tópicos, leer el buzón y registrar la suscripción de Web Push.
public actor RemoteClient {
    public struct Configuration: Sendable {
        public var appVersion: String
        public var deviceName: String
        public var model: String
        public var commandProtocol: Int
        public var handshakeTimeout: Duration
        public var requestTimeout: Duration

        public init(appVersion: String, deviceName: String, model: String, commandProtocol: Int = CommandProtocol.version,
                    handshakeTimeout: Duration = .seconds(15), requestTimeout: Duration = .seconds(60)) {
            self.appVersion = appVersion
            self.deviceName = deviceName
            self.model = model
            self.commandProtocol = commandProtocol
            self.handshakeTimeout = handshakeTimeout
            self.requestTimeout = requestTimeout
        }
    }

    private struct Pending {
        let continuation: AsyncThrowingStream<CommandResponse, Error>.Continuation
    }

    private let config: Configuration
    private let linkFactory: RelayLinkFactory
    private let clock: @Sendable () -> Date
    public private(set) var paired: PairedMac?
    public private(set) var keys: DeviceKeys?
    public private(set) var status: RemoteClientStatus {
        didSet { if status != oldValue { statusSink.yield(status) } }
    }
    /// El último código con el que el relay cerró (o no abrió) la conexión: 4401, 4403, 4409… Solo informa (M3).
    public private(set) var lastRelayCloseCode: Int?
    public private(set) var presencePolicy: (requirePresence: Bool, gated: [AppCommand.Name]) = (true, [])
    public private(set) var macHello: RemoteHello?

    private var link: RelayLink?
    private var receiveTask: Task<Void, Never>?
    /// La conexión en curso: un `connect()` concurrente (la reconexión de la app y un comando a la vez) espera esta en
    /// vez de abrir otra sesión que pise el handshake de la primera (una continuación perdida cuelga para siempre).
    private var connecting: (id: UUID, task: Task<Void, Error>)?
    private var channel: SecureChannel?
    private var handshake: (sid: String, state: NoiseHandshake, waiter: CheckedContinuation<Void, Error>)?
    private var helloWaiter: CheckedContinuation<RemoteHello, Error>?
    /// Cada espera con tiempo límite lleva un número: un timeout viejo no corta una espera nueva.
    private var waitGeneration = 0
    private var nextRequestId = 0
    private var pending: [Int: Pending] = [:]
    private var topics: [String] = []
    private var stateRevs: [String: Int] = [:]
    private var mailboxRevs: [String: Int] = [:]
    private var mailboxWaiter: CheckedContinuation<[RelayMailboxItem], Error>?
    private var pairingFlow: PairingFlow?

    public nonisolated let states: AsyncStream<RemoteStateUpdate>
    private let stateSink: AsyncStream<RemoteStateUpdate>.Continuation
    /// Pedazos de chats que no inició este teléfono (`chatDelta`, spec P.6).
    public nonisolated let chatDeltas: AsyncStream<RemoteChatDelta>
    private let chatSink: AsyncStream<RemoteChatDelta>.Continuation
    /// Cada cambio de `status` (los tests lo miran para reconectar).
    public nonisolated let statusUpdates: AsyncStream<RemoteClientStatus>
    private let statusSink: AsyncStream<RemoteClientStatus>.Continuation
    /// Cada `presencePolicy` de la Mac, también a mitad de sesión (la Mac prendió o apagó Face ID para este teléfono,
    /// revisión L2): `requirePresence`.
    public nonisolated let presencePolicyUpdates: AsyncStream<Bool>
    private let policySink: AsyncStream<Bool>.Continuation

    public init(configuration: Configuration, paired: PairedMac? = nil, keys: DeviceKeys? = nil,
                linkFactory: @escaping RelayLinkFactory, clock: @escaping @Sendable () -> Date = { Date() }) {
        config = configuration
        self.paired = paired
        self.keys = keys
        self.linkFactory = linkFactory
        self.clock = clock
        status = paired == nil ? .unpaired : .disconnected
        (states, stateSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        (chatDeltas, chatSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
        (statusUpdates, statusSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (presencePolicyUpdates, policySink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4))
    }

    /// El `sid` de la sesión abierta (tests).
    public var sessionId: String? { channel?.sid }

    // MARK: - Emparejamiento (spec P.11)

    private struct PairingFlow {
        let link: RelayLink
        let qr: PairingQR
        let keys: DeviceKeys
        let sid: String
        var transport: NoiseTransport?
        var resultWaiter: CheckedContinuation<PairingResult, Error>?
        /// Lo que llegó antes de que alguien llamara a `finishPairing()`.
        var outcome: Result<PairingResult, RemoteError>?
        var handshakeWaiter: CheckedContinuation<Data, Error>?
        var receiveTask: Task<Void, Never>?
    }

    /// Se une a la ranura del QR, hace el handshake IKpsk2 y devuelve el código de 6 dígitos para comparar con la Mac.
    /// `presence`: la passkey creada antes del handshake (W.4.6; `nil` si no se pudo). `keys`: las claves nuevas del
    /// teléfono (se guardan recién cuando la Mac confirma).
    public func startPairing(qr: PairingQR, presence: PresenceCredential?, keys: DeviceKeys = DeviceKeys()) async throws
        -> String {
        await cancelPairingFlow()
        let secrets = PairingSecrets(secret: qr.secret)
        let link = linkFactory(.pairing(account: qr.accountId, pairing: qr.pairingId, authKey: secrets.authKey))
        do {
            _ = try await link.connect()
        } catch {
            throw RemoteError.pairingExpired
        }
        let sid = RemoteSID.new()
        if let old = pairingFlow {
            // Otro `startPairing()` llegó mientras este conectaba: se suelta el suyo sin dejar esperas colgadas.
            failPairing(.pairingCancelled)
            old.receiveTask?.cancel()
            Task { await old.link.close() }
        }
        pairingFlow = PairingFlow(link: link, qr: qr, keys: keys, sid: sid)
        pairingFlow?.receiveTask = Task { [weak self] in
            do {
                for try await message in link.incoming { await self?.handlePairingMessage(message) }
            } catch {}
            await self?.pairingLinkEnded()
        }
        do {
            var handshake = try NoiseHandshake(
                pattern: .ikpsk2, initiator: true, prologue: RemotePrologue.pairing(account: qr.accountId, pairing: qr.pairingId),
                localStatic: keys.noise, remoteStatic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: qr.macStatic),
                psk: secrets.psk)
            let join = PairingJoin(deviceName: config.deviceName, model: config.model,
                                   relayKey: keys.relay.publicKey.rawRepresentation,
                                   push: keys.push.publicKey.rawRepresentation, presence: presence)
            try link.send(.send(to: "mac", sid: sid, b: try handshake.writeMessage(payload: try PairingMessage.join(join).encoded())))
            let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                guard pairingFlow?.sid == sid else { return c.resume(throwing: RemoteError.pairingCancelled) }
                pairingFlow?.handshakeWaiter?.resume(throwing: RemoteError.pairingCancelled)
                pairingFlow?.handshakeWaiter = c
                scheduleTimeout { client in
                    // Solo si sigue esperando este handshake (un timeout viejo no pisa nada).
                    guard client.pairingFlow?.sid == sid, let waiter = client.pairingFlow?.handshakeWaiter else { return }
                    client.pairingFlow?.handshakeWaiter = nil
                    waiter.resume(throwing: RemoteError.pairingExpired)
                }
            }
            _ = try handshake.readMessage(reply)
            var transport = try handshake.split()
            try link.send(.send(to: "mac", sid: sid, b: try transport.send.encrypt(try PairingMessage.confirm.encoded())))
            pairingFlow?.transport = transport
            return SAS.code(handshakeHash: handshake.handshakeHash)
        } catch {
            await cancelPairingFlow()
            if let remote = error as? RemoteError { throw remote }
            throw RemoteError.pairingExpired
        }
    }

    /// Espera "Codes Match" en la Mac. Devuelve la Mac emparejada (y guarda las claves nuevas).
    public func finishPairing() async throws -> PairedMac {
        guard pairingFlow?.transport != nil else { throw RemoteError.pairingCancelled }
        let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<PairingResult, Error>) in
            guard pairingFlow != nil else { return c.resume(throwing: RemoteError.pairingCancelled) }
            if let outcome = pairingFlow?.outcome {
                c.resume(with: outcome.mapError { $0 as Error })
                return
            }
            // Un segundo `finishPairing()` a la vez reemplaza al primero, que vuelve con `pairingCancelled`.
            pairingFlow?.resultWaiter?.resume(throwing: RemoteError.pairingCancelled)
            pairingFlow?.resultWaiter = c
            // La ranura dura 5 min; después la Mac o el relay la cierran. Esto es solo una red de seguridad.
            let sid = pairingFlow?.sid
            scheduleTimeout(.seconds(360)) { client in
                guard client.pairingFlow?.sid == sid else { return }
                client.failPairing(.pairingExpired)
            }
        }
        guard let flow = pairingFlow else { throw RemoteError.pairingCancelled }
        let name = RemoteText.displayName(result.macName)
        let mac = PairedMac(accountId: flow.qr.accountId, deviceId: result.deviceId, relayHost: flow.qr.relayHost,
                            macName: name.isEmpty ? flow.qr.macName : name, macStatic: flow.qr.macStatic,
                            macSeal: result.macSeal)
        paired = mac
        keys = flow.keys
        status = .disconnected
        await cancelPairingFlow()
        return mac
    }

    private func handlePairingMessage(_ message: RelayMessage) {
        guard case .recv(let from, let sid, let b) = message, from == "mac", var flow = pairingFlow, sid == flow.sid else {
            return
        }
        if let waiter = flow.handshakeWaiter {
            flow.handshakeWaiter = nil
            pairingFlow = flow
            waiter.resume(returning: b)
            return
        }
        guard var transport = flow.transport, let plaintext = try? transport.receive.decrypt(b),
              let decoded = try? PairingMessage.decode(plaintext) else {
            return failPairing(.pairingCancelled)
        }
        flow.transport = transport
        pairingFlow = flow
        switch decoded {
        case .result(let result):
            guard pairingFlow?.outcome == nil else { return }
            // Acuse: la Mac guarda el dispositivo recién cuando lo recibe (M1).
            if var transport = pairingFlow?.transport, let ack = try? transport.send.encrypt(try PairingMessage.ack.encoded()) {
                pairingFlow?.transport = transport
                try? pairingFlow?.link.send(.send(to: "mac", sid: flow.sid, b: ack))
            }
            pairingFlow?.outcome = .success(result)
            pairingFlow?.resultWaiter?.resume(returning: result)
            pairingFlow?.resultWaiter = nil
        case .cancelled:
            failPairing(.pairingCancelled)
        case .join, .confirm, .ack:
            failPairing(.pairingCancelled)
        }
    }

    private func pairingLinkEnded() {
        failPairing(.pairingCancelled)
    }

    private func failPairing(_ error: RemoteError) {
        pairingFlow?.handshakeWaiter?.resume(throwing: error)
        pairingFlow?.handshakeWaiter = nil
        // Solo la primera palabra cuenta: el cierre de la ranura después del resultado no lo pisa.
        guard pairingFlow != nil, pairingFlow?.outcome == nil else { return }
        pairingFlow?.outcome = .failure(error)
        pairingFlow?.resultWaiter?.resume(throwing: error)
        pairingFlow?.resultWaiter = nil
    }

    /// "Codes Don't Match" o Cancel en el teléfono: suelta la ranura (la Mac ve que el teléfono se fue).
    public func cancelPairing() async {
        await cancelPairingFlow()
    }

    private func cancelPairingFlow() async {
        guard let flow = pairingFlow else { return }
        failPairing(.pairingCancelled)
        flow.receiveTask?.cancel()
        pairingFlow = nil
        await flow.link.close()
    }

    // MARK: - Conexión

    /// Conecta con el relay y, si la Mac está online, abre la sesión (Noise KK + `hello`).
    ///
    /// Un llamador cancelado vuelve enseguida con `CancellationError` (no al vencer el handshake); el intento sigue
    /// para los demás que lo esperan y termina solo (o con `disconnect()`).
    public func connect() async throws {
        if let connecting { return try await Self.value(of: connecting.task) }
        let id = UUID()
        // El intento se borra solo al terminar, quede quien quede esperándolo.
        let task = Task {
            defer { self.connectFinished(id) }
            try await self.connectOnce()
        }
        connecting = (id, task)
        try await Self.value(of: task)
    }

    private func connectFinished(_ id: UUID) {
        if connecting?.id == id { connecting = nil }
    }

    /// El resultado de `task`, o `CancellationError` apenas se cancela quien espera (sin cancelar `task`, que es
    /// compartida).
    private static func value(of task: Task<Void, Error>) async throws {
        try Task.checkCancellation()
        let gate = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                gate.arm(c)
                Task {
                    do {
                        try await task.value
                        gate.resume(.success(()))
                    } catch {
                        gate.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            gate.resume(.failure(CancellationError()))
        }
    }

    private func connectOnce() async throws {
        guard let paired, let keys else { throw RemoteError.notPaired }
        if link != nil, channel != nil { return }
        status = .connecting
        if link == nil {
            let link = linkFactory(.signed(account: paired.accountId, client: paired.deviceId, key: keys.relay))
            let ready: RelayReady
            lastRelayCloseCode = nil
            do {
                ready = try await link.connect()
            } catch let closed as RelayClosed where closed.code == RelayCloseCode.deviceRemoved.rawValue
                || closed.code == RelayCloseCode.unauthorized.rawValue {
                // Solo un indicio: la revocación la dice la Mac con `bye(revoked)` dentro de la sesión (M3).
                lastRelayCloseCode = closed.code
                status = .relayRejected
                throw RemoteError.relayRejected
            } catch {
                lastRelayCloseCode = (error as? RelayClosed)?.code
                status = .relayUnreachable
                throw RemoteError.relayUnreachable
            }
            self.link = link
            receiveTask = Task { [weak self] in
                var ending: Error?
                do {
                    for try await message in link.incoming { await self?.handle(message) }
                } catch {
                    ending = error
                }
                await self?.linkEnded(link, error: ending)
            }
            guard ready.macOnline else {
                status = .macOffline(since: Date(timeIntervalSince1970: TimeInterval(ready.since)))
                throw RemoteError.macOffline(since: Date(timeIntervalSince1970: TimeInterval(ready.since)))
            }
        }
        try await openSession()
    }

    public func disconnect() async {
        let current = link
        receiveTask?.cancel()
        tearDown(.sessionClosed)
        link = nil
        await current?.close()
        if paired != nil, status != .revoked { status = .disconnected }
    }

    private func openSession() async throws {
        guard let paired, let keys, let link else { throw RemoteError.notPaired }
        let sid = RemoteSID.new()
        var state = try NoiseHandshake(
            pattern: .kk, initiator: true, prologue: RemotePrologue.session(account: paired.accountId, device: paired.deviceId),
            localStatic: keys.noise, remoteStatic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: paired.macStatic),
            psk: nil)
        let first = try state.writeMessage()
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // Nunca se pisa una espera: la que hubiera se falla antes (cada continuación se retoma una vez).
                handshake?.waiter.resume(throwing: RemoteError.sessionClosed)
                handshake = (sid, state, c)
                do {
                    try link.send(.send(to: "mac", sid: sid, b: first))
                } catch {
                    handshake = nil
                    c.resume(throwing: RemoteError.relayUnreachable)
                    return
                }
                // Una Mac que no reconoce la estática (dispositivo revocado) no contesta: se corta por tiempo.
                scheduleTimeout { client in
                    guard let pending = client.handshake, pending.sid == sid else { return }
                    client.handshake = nil
                    pending.waiter.resume(throwing: RemoteError.handshakeFailed)
                }
            }
        } catch {
            if let pending = handshake, pending.sid == sid { handshake = nil }
            if case .revoked = status { throw RemoteError.revoked }
            if case .macOffline(let since) = status { throw RemoteError.macOffline(since: since) }
            throw (error as? RemoteError) ?? .handshakeFailed
        }
        // La sesión pudo morir mientras se retomaba el handshake (la Mac reconectó, `bye`): no se espera un `hello`
        // que nunca va a salir.
        guard channel?.sid == sid else { throw RemoteError.sessionClosed }
        var hello = try await withCheckedThrowingContinuation { (c: CheckedContinuation<RemoteHello, Error>) in
            helloWaiter?.resume(throwing: RemoteError.sessionClosed)
            helloWaiter = c
            waitGeneration += 1
            let generation = waitGeneration
            sendFrame(.hello(RemoteHello(commandProtocol: config.commandProtocol, appVersion: config.appVersion,
                                         deviceName: config.deviceName)))
            scheduleTimeout { client in
                guard client.waitGeneration == generation else { return }
                client.helloWaiter?.resume(throwing: RemoteError.handshakeFailed)
                client.helloWaiter = nil
            }
        }
        hello.macName = hello.macName.map { RemoteText.displayName($0) }
        macHello = hello
        if let incompatible = hello.incompatible {
            status = .incompatible(incompatible)
            throw RemoteError.incompatible(incompatible)
        }
        status = .online
        // Una sesión nueva puede ser de una Mac que reinició y numera desde 1 (L1): el orden vale dentro de la sesión.
        stateRevs = [:]
        if !topics.isEmpty { sendFrame(.sub(topics: topics)) }
    }

    private func linkEnded(_ ended: RelayLink, error: Error?) {
        guard link === ended else { return }
        link = nil
        let closed = error as? RelayClosed
        lastRelayCloseCode = closed?.code
        if status == .revoked {
            tearDown(.revoked)
        } else if closed?.code == RelayCloseCode.deviceRemoved.rawValue {
            // No es una revocación autenticada (M3): no se borra nada y la próxima operación reintenta.
            status = .relayRejected
            tearDown(.relayRejected)
        } else {
            if status != .revoked { status = .relayUnreachable }
            tearDown(.relayUnreachable)
        }
    }

    /// La sesión murió pero la conexión con el relay sigue (un marco que no autentica, `bye` de la Mac, rotación, un
    /// pedido sin respuesta, la Mac que reconectó): se falla lo que estaba en vuelo y el estado pasa a `.disconnected`,
    /// así la app reconecta y vuelve a suscribirse en vez de quedar "online" con una sesión muerta (revisión M3).
    private func dropSession(_ error: RemoteError = .sessionClosed) {
        tearDown(error)
        switch status {
        case .online, .connecting: status = .disconnected
        default: break
        }
    }

    /// Corta la sesión y falla lo que estaba en vuelo con `error`.
    private func tearDown(_ error: RemoteError) {
        channel = nil
        handshake?.waiter.resume(throwing: error)
        handshake = nil
        helloWaiter?.resume(throwing: error)
        helloWaiter = nil
        mailboxWaiter?.resume(throwing: error)
        mailboxWaiter = nil
        for (_, request) in pending { request.continuation.finish(throwing: error) }
        pending = [:]
    }

    // MARK: - Marcos

    private func handle(_ message: RelayMessage) {
        switch message {
        case .recv(let from, let sid, let b) where from == "mac":
            if let pendingHandshake = handshake, pendingHandshake.sid == sid {
                var state = pendingHandshake.state
                handshake = nil
                do {
                    _ = try state.readMessage(b)
                    channel = try SecureChannel(sid: sid, handshake: state, startedAt: clock())
                    pendingHandshake.waiter.resume()
                } catch {
                    pendingHandshake.waiter.resume(throwing: RemoteError.handshakeFailed)
                }
                return
            }
            guard var current = channel, current.sid == sid else { return }
            do {
                guard let frame = try current.open(b) else {
                    channel = current
                    return
                }
                channel = current
                handleFrame(frame)
            } catch {
                // Un marco que no autentica: la sesión no sirve más; la próxima operación hace otro handshake.
                dropSession()
            }
        case .presence(let mac?, let since, _, _):
            if mac == "online" {
                if case .macOffline = status {
                    status = .disconnected
                } else if channel != nil || handshake != nil {
                    // La Mac volvió a conectarse con el relay sin pasar por offline (cambió de red, una conexión
                    // medio abierta): la Mac nueva no tiene nuestra sesión. Se rehace (M3).
                    dropSession()
                }
            } else {
                status = .macOffline(since: since.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                tearDown(.macOffline(since: since.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
            }
        case .undeliverable(_, let sid):
            guard sid == channel?.sid || sid == handshake?.sid else { return }
            status = .macOffline(since: nil)
            tearDown(.macOffline(since: nil))
        case .mbox(let items):
            mailboxWaiter?.resume(returning: items)
            mailboxWaiter = nil
        default:
            break
        }
    }

    private func handleFrame(_ frame: RemoteFrame) {
        switch frame {
        case .hello(let hello):
            helloWaiter?.resume(returning: hello)
            helloWaiter = nil
        case .res(let response):
            guard let request = pending[response.id] else { return }
            request.continuation.yield(response)
            if response.event == nil {
                request.continuation.finish()
                pending[response.id] = nil
            }
        case .state(let update):
            // El estado no vuelve atrás: un `rev` viejo se ignora.
            guard update.rev > stateRevs[update.topic, default: 0] else { return }
            stateRevs[update.topic] = update.rev
            stateSink.yield(update)
        case .presencePolicy(let requirePresence, let gated):
            presencePolicy = (requirePresence, gated)
            policySink.yield(requirePresence)
        case .bye(let reason):
            if reason == "revoked" {
                status = .revoked
                tearDown(.revoked)
            } else {
                // `rotate`, `desync`, `protocol`…: otra sesión en la próxima operación (y la app reconecta).
                dropSession()
            }
        case .chatDelta(let pr, let text):
            chatSink.yield(RemoteChatDelta(pr: pr, text: text))
        case .req, .sub, .unpair, .unknown:
            break
        }
    }

    private func sendFrame(_ frame: RemoteFrame) {
        guard var current = channel, let link else { return }
        do {
            let chunks = try current.seal(frame)
            channel = current
            for chunk in chunks { try link.send(.send(to: "mac", sid: current.sid, b: chunk)) }
            if current.needsRotation(now: clock()) {
                // Handshake nuevo en la próxima operación (spec P.5).
                sendFrameIgnoringRotation(.bye(reason: "rotate"))
                dropSession()
            }
        } catch {
            dropSession()
        }
    }

    private func sendFrameIgnoringRotation(_ frame: RemoteFrame) {
        guard var current = channel, let link, let chunks = try? current.seal(frame) else { return }
        channel = current
        for chunk in chunks { try? link.send(.send(to: "mac", sid: current.sid, b: chunk)) }
    }

    // MARK: - Comandos y estado

    private func ensureSession() async throws {
        if case .revoked = status { throw RemoteError.revoked }
        if channel == nil { try await connect() }
        guard channel != nil else { throw RemoteError.sessionClosed }
    }

    /// Manda un comando. Los eventos (`progress`, `text`) llegan antes de la respuesta final, que cierra el stream.
    /// `presence`: firma el desafío de Face ID con la passkey (para los comandos gated, W.5).
    public func send(_ command: AppCommand, presence: WebAuthnAuthenticator? = nil) async throws
        -> AsyncThrowingStream<CommandResponse, Error> {
        try await ensureSession()
        guard let current = channel else { throw RemoteError.sessionClosed }
        nextRequestId += 1
        let id = nextRequestId
        let cmd = try CommandProtocol.encoder.encode(command)
        var proof: PresenceProof?
        if let presence {
            proof = try await PresenceProof.make(authenticator: presence, sessionHash: current.handshakeHash, reqId: UInt64(id),
                                                 commandBytes: cmd, at: clock())
            // La firma pudo tardar (Face ID): si la sesión cambió, la prueba ya no sirve.
            guard channel?.sid == current.sid else { throw RemoteError.sessionClosed }
        }
        let (stream, continuation) = AsyncThrowingStream<CommandResponse, Error>.makeStream()
        pending[id] = Pending(continuation: continuation)
        let timeout = config.requestTimeout
        let sentAt = clock()
        sendFrame(.req(RemoteRequest(id: id, sentAt: sentAt, cmd: cmd, presence: proof,
                                     deadline: sentAt.addingTimeInterval(Double(timeout.components.seconds)))))
        let sid = current.sid
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id, sid: sid)
        }
        return stream
    }

    /// Un pedido sin respuesta a tiempo: la sesión queda en duda (la Mac pudo perderla sin avisar), así que se descarta
    /// y la próxima operación hace otro handshake (M3). Solo si sigue siendo la sesión que mandó el pedido.
    private func expire(_ id: Int, sid: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.finish(throwing: RemoteError.timeout)
        if channel?.sid == sid { dropSession() }
    }

    /// Manda un comando y espera solo el resultado final.
    public func run(_ command: AppCommand, presence: WebAuthnAuthenticator? = nil) async throws -> CommandResponse {
        var last: CommandResponse?
        for try await response in try await send(command, presence: presence) where response.event == nil {
            last = response
        }
        guard let last else { throw RemoteError.sessionClosed }
        return last
    }

    /// Reemplaza el conjunto de tópicos (también al reconectar).
    public func subscribe(_ topics: [String]) async throws {
        self.topics = topics
        try await ensureSession()
        sendFrame(.sub(topics: topics))
    }

    /// Lee el buzón y abre lo que se pueda; ignora lo que no autentique o tenga un `rev` viejo.
    public func fetchMailbox() async throws -> [MailboxBlob] {
        guard let paired, let keys, let link else { throw RemoteError.notPaired }
        let items = try await withCheckedThrowingContinuation { (c: CheckedContinuation<[RelayMailboxItem], Error>) in
            mailboxWaiter?.resume(throwing: RemoteError.timeout)
            mailboxWaiter = c
            waitGeneration += 1
            let generation = waitGeneration
            do {
                try link.send(.mboxGet)
            } catch {
                mailboxWaiter = nil
                c.resume(throwing: RemoteError.relayUnreachable)
                return
            }
            scheduleTimeout { client in
                guard client.waitGeneration == generation else { return }
                client.mailboxWaiter?.resume(throwing: RemoteError.timeout)
                client.mailboxWaiter = nil
            }
        }
        let macSeal = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: paired.macSeal)
        var blobs: [MailboxBlob] = []
        for item in items {
            guard let blob = try? MailboxBlob.open(item.b, by: keys.push, from: macSeal, account: paired.accountId,
                                                   device: paired.deviceId, slot: item.slot,
                                                   minimumRev: mailboxRevs[item.slot, default: 0], now: clock()) else { continue }
            mailboxRevs[item.slot] = blob.rev
            blobs.append(blob)
        }
        return blobs
    }

    /// El último `rev` visto por ranura del buzón: la app lo guarda (`restoreMailboxRevisions` al armar el cliente) para
    /// no aceptar un estado viejo después de reabrirse (revisión M2).
    public var mailboxRevisions: [String: Int] {
        get { mailboxRevs }
    }

    public func restoreMailboxRevisions(_ revisions: [String: Int]) {
        mailboxRevs = revisions
    }

    /// Registra (o actualiza) la suscripción de Web Push de este teléfono en el relay (marco `webpush`, W.6).
    public func registerWebPush(endpoint: String, p256dh: Data, auth: Data) throws {
        guard let link else { throw RemoteError.notPaired }
        try link.send(.webpush(endpoint: endpoint, p256dh: p256dh, auth: auth))
    }

    /// "Unpair this iPhone": la Mac lo da de baja como un Revoke. Las claves locales las borra la app.
    public func unpair() async {
        if channel != nil { sendFrameIgnoringRotation(.unpair) }
        await disconnect()
        paired = nil
        keys = nil
        status = .unpaired
    }

    /// Corre `action` dentro del actor después de `limit` (por defecto `handshakeTimeout`). La acción decide si todavía
    /// hay algo esperando.
    private func scheduleTimeout(_ limit: Duration? = nil, _ action: @escaping @Sendable (isolated RemoteClient) -> Void) {
        let limit = limit ?? config.handshakeTimeout
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.runIsolated(action)
        }
    }

    private func runIsolated(_ action: @Sendable (isolated RemoteClient) -> Void) {
        action(self)
    }
}

/// Una continuación que se retoma una sola vez, con lo primero que llegue (el resultado o la cancelación); si llega
/// antes de armarla, se guarda.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var early: Result<Void, Error>?
    private var done = false

    func arm(_ c: CheckedContinuation<Void, Error>) {
        let ready = lock.withLock { () -> Result<Void, Error>? in
            if let early {
                done = true
                return early
            }
            continuation = c
            return nil
        }
        if let ready { c.resume(with: ready) }
    }

    func resume(_ result: Result<Void, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !done else { return nil }
            guard let continuation else {
                if early == nil { early = result }
                return nil
            }
            done = true
            self.continuation = nil
            return continuation
        }
        c?.resume(with: result)
    }
}
