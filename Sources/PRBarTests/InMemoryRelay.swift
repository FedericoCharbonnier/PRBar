import CryptoKit
import Foundation
import PRBarRemoteKit

/// Un relay en memoria con la semántica de P.4 a nivel de `RelayMessage` (el de verdad está en `relay/`, en Go):
/// cuentas, auth por firma o `proof`, ruteo FIFO, presencia, `undeliverable`, buzón, ranuras de emparejamiento,
/// `device.add/remove` (4403) y los pushes en una lista. Tiene perillas para portarse mal (relay comprometido).
actor InMemoryRelay {
    nonisolated let host = "relay.test"
    private let clock: @Sendable () -> Date

    private struct Slot {
        var id: String
        var authKey: Data
        var expires: Int
        var failures = 0
        var link: InMemoryRelayLink?
    }

    private struct Account {
        var macKey: Curve25519.Signing.PublicKey
        var devices: [String: Curve25519.Signing.PublicKey] = [:]
        var apns: [String: (token: String, env: String)] = [:]
        var mailbox: [String: [String: (b: Data, at: Int)]] = [:]
        var slot: Slot?
        var burnedSlots: Set<String> = []
        var mac: InMemoryRelayLink?
        var deviceLinks: [String: InMemoryRelayLink] = [:]
        var macSince = 0
    }

    private var accounts: [String: Account] = [:]
    private(set) var pushes: [RelayMessage] = []
    private var lastToMac: [String: RelayMessage] = [:]
    /// Relay comprometido: no obedece `device.remove`.
    var ignoreDeviceRemoval = false
    var pushStatus = 200
    /// Relay comprometido: deja pasar solo los primeros N mensajes del teléfono que empareja (p. ej. sin el acuse).
    var pairForwardLimit: Int?
    private var pairForwarded = 0
    /// Todo lo que el relay le entregó a la Mac, en orden (para repetirlo como un relay malicioso).
    private(set) var deliveredToMac: [RelayMessage] = []
    /// Bytes de `b` que la Mac mandó a cada dispositivo.
    private(set) var bytesToDevice: [String: Int] = [:]
    /// Marcos `send` de la Mac a cada dispositivo.
    private(set) var framesToDevice: [String: Int] = [:]

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    private var now: Int { Int(clock().timeIntervalSince1970) }

    func enroll(macKey: Curve25519.Signing.PublicKey) -> String {
        let id = RemoteIDs.newAccountId()
        accounts[id] = Account(macKey: macKey, macSince: now)
        return id
    }

    func setIgnoreDeviceRemoval(_ value: Bool) { ignoreDeviceRemoval = value }

    func setPairForwardLimit(_ value: Int?) {
        pairForwardLimit = value
        pairForwarded = 0
    }

    /// Relay malicioso: le entrega a la Mac un mensaje inventado.
    func injectToMac(_ acct: String, _ message: RelayMessage) {
        accounts[acct]?.mac?.deliver(message)
    }

    /// Relay malicioso u olvidadizo: corta la conexión de un dispositivo con un código, sin darlo de baja.
    func closeDevice(_ acct: String, _ device: String, code: Int) {
        accounts[acct]?.deviceLinks[device]?.closeByRelay(code: code, reason: "closed by the relay")
        accounts[acct]?.deviceLinks[device] = nil
    }

    /// Relay que perdió su base: ya no conoce al dispositivo (rechaza su `auth` con 4401).
    func forgetDevice(_ acct: String, _ device: String) {
        accounts[acct]?.devices[device] = nil
    }

    func pairingSlot(_ account: String) -> String? { accounts[account]?.slot?.id }

    func hasDevice(_ account: String, _ device: String) -> Bool { accounts[account]?.devices[device] != nil }

    func mailboxItem(_ account: String, device: String, slot: String) -> Data? {
        accounts[account]?.mailbox[device]?[slot]?.b
    }

    func replaceMailbox(_ account: String, device: String, slot: String, b: Data) {
        accounts[account]?.mailbox[device, default: [:]][slot] = (b, now)
    }

    nonisolated func factory() -> RelayLinkFactory {
        { [self] credential in InMemoryRelayLink(relay: self, credential: credential) }
    }

    // MARK: - Auth

    func challenge() -> Data { randomBytes(32) }

    func authenticate(_ link: InMemoryRelayLink, _ message: RelayMessage, nonce: Data) throws -> RelayReady {
        guard case .auth(let acct, let client, let sig, let pairing, let proof) = message, var account = accounts[acct] else {
            throw RelayClosed(code: 4401, reason: "unauthorized")
        }
        let signed = RelayAuth.message(host: host, account: acct, client: client, nonce: nonce)
        switch client {
        case "mac":
            guard let sig, account.macKey.isValidSignature(sig, for: signed) else {
                throw RelayClosed(code: 4401, reason: "unauthorized")
            }
            account.mac?.closeByRelay(code: 4409, reason: "replaced")
            account.mac = link
            account.macSince = now
            link.role = .mac(acct)
            accounts[acct] = account
            for device in account.deviceLinks.values {
                device.deliver(.presence(mac: "online", since: account.macSince, device: nil, state: nil))
            }
            return RelayReady(mac: "online", since: account.macSince)
        case "pair":
            guard var slot = account.slot, slot.id == pairing, let proof, now < slot.expires else {
                throw RelayClosed(code: 4401, reason: "unauthorized")
            }
            guard constantTimeEquals(proof, PairingSecrets.proof(authKey: slot.authKey, nonce: nonce)) else {
                slot.failures += 1
                account.slot = slot.failures >= 3 ? nil : slot
                if slot.failures >= 3 { account.mac?.deliver(.pairClose(pairing: slot.id)) }
                accounts[acct] = account
                throw RelayClosed(code: 4401, reason: "unauthorized")
            }
            if let existing = slot.link {
                // Un segundo teléfono en la misma ranura: se quema.
                existing.closeByRelay(code: 4401, reason: "pairing burned")
                account.mac?.deliver(.pairClose(pairing: slot.id))
                account.slot = nil
                accounts[acct] = account
                throw RelayClosed(code: 4401, reason: "unauthorized")
            }
            slot.link = link
            account.slot = slot
            link.role = .pair(acct, slot.id)
            accounts[acct] = account
            return RelayReady(mac: account.mac == nil ? "offline" : "online", since: account.macSince)
        default:
            guard let key = account.devices[client], let sig, key.isValidSignature(sig, for: signed) else {
                throw RelayClosed(code: 4401, reason: "unauthorized")
            }
            account.deviceLinks[client]?.closeByRelay(code: 4409, reason: "replaced")
            account.deviceLinks[client] = link
            link.role = .device(acct, client)
            accounts[acct] = account
            account.mac?.deliver(.presence(mac: nil, since: nil, device: client, state: "online"))
            return RelayReady(mac: account.mac == nil ? "offline" : "online", since: account.macSince)
        }
    }

    func disconnected(_ link: InMemoryRelayLink) {
        switch link.role {
        case .mac(let acct):
            guard accounts[acct]?.mac === link else { return }
            accounts[acct]?.mac = nil
            accounts[acct]?.macSince = now
            for device in accounts[acct]?.deviceLinks.values.map({ $0 }) ?? [] {
                device.deliver(.presence(mac: "offline", since: now, device: nil, state: nil))
            }
        case .device(let acct, let id):
            guard accounts[acct]?.deviceLinks[id] === link else { return }
            accounts[acct]?.deviceLinks[id] = nil
            accounts[acct]?.mac?.deliver(.presence(mac: nil, since: nil, device: id, state: "offline"))
        case .pair(let acct, _):
            if accounts[acct]?.slot?.link === link { accounts[acct]?.slot?.link = nil }
        case .none:
            break
        }
    }

    // MARK: - Ruteo

    func receive(_ message: RelayMessage, from link: InMemoryRelayLink) {
        if case .ping = message { return link.deliver(.pong) }
        switch link.role {
        case .mac(let acct): fromMac(message, acct: acct, link: link)
        case .device(let acct, let id): fromDevice(message, acct: acct, id: id, link: link)
        case .pair(let acct, let pairing):
            guard case .send("mac", let sid, let b) = message else { return link.deliver(.error(reason: "forbidden")) }
            if let limit = pairForwardLimit {
                guard pairForwarded < limit else { return }
                pairForwarded += 1
            }
            toMac(.recv(from: "pair:\(pairing)", sid: sid, b: b), acct: acct, sid: sid, link: link)
        case .none:
            break
        }
    }

    private func toMac(_ message: RelayMessage, acct: String, sid: String, link: InMemoryRelayLink) {
        guard let mac = accounts[acct]?.mac else { return link.deliver(.undeliverable(to: "mac", sid: sid)) }
        lastToMac[acct] = message
        deliveredToMac.append(message)
        mac.deliver(message)
    }

    private func fromDevice(_ message: RelayMessage, acct: String, id: String, link: InMemoryRelayLink) {
        switch message {
        case .send("mac", let sid, let b):
            toMac(.recv(from: id, sid: sid, b: b), acct: acct, sid: sid, link: link)
        case .mboxGet:
            let items = (accounts[acct]?.mailbox[id] ?? [:]).map { RelayMailboxItem(slot: $0.key, b: $0.value.b, at: $0.value.at) }
            link.deliver(.mbox(items: items.sorted { $0.slot < $1.slot }))
        case .apns(let token, let env):
            accounts[acct]?.apns[id] = (token, env)
        default:
            link.deliver(.error(reason: "forbidden"))
        }
    }

    private func fromMac(_ message: RelayMessage, acct: String, link: InMemoryRelayLink) {
        switch message {
        case .send(let to, let sid, let b):
            let target = to.hasPrefix("pair:") ? accounts[acct]?.slot.flatMap { "pair:\($0.id)" == to ? $0.link : nil }
                : accounts[acct]?.deviceLinks[to]
            guard let target else { return link.deliver(.undeliverable(to: to, sid: sid)) }
            if !to.hasPrefix("pair:") {
                bytesToDevice[to, default: 0] += b.count
                framesToDevice[to, default: 0] += 1
            }
            target.deliver(.recv(from: "mac", sid: sid, b: b))
        case .push(let id, _, _, _, _):
            pushes.append(message)
            link.deliver(.pushResult(id: id, status: pushStatus, reason: nil))
        case .mboxPut(let to, let slot, let b):
            guard accounts[acct]?.devices[to] != nil else { return }
            var boxes = accounts[acct]?.mailbox[to] ?? [:]
            guard boxes[slot] != nil || boxes.count < 4, b.count <= 512 * 1024 else { return }
            boxes[slot] = (b, now)
            accounts[acct]?.mailbox[to] = boxes
        case .pairOpen(let pairing, let authKey, let expires):
            accounts[acct]?.slot?.link?.closeByRelay(code: 4401, reason: "pairing closed")
            accounts[acct]?.slot = Slot(id: pairing, authKey: authKey, expires: min(expires, now + 300))
        case .pairClose(let pairing):
            guard let slot = accounts[acct]?.slot, slot.id == pairing else { return }
            slot.link?.closeByRelay(code: 4401, reason: "pairing closed")
            accounts[acct]?.slot = nil
        case .deviceAdd(let device, let relayKey):
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: relayKey) else { return }
            accounts[acct]?.devices[device] = key
        case .deviceRemove(let device):
            guard !ignoreDeviceRemoval else { return }
            accounts[acct]?.devices[device] = nil
            accounts[acct]?.apns[device] = nil
            accounts[acct]?.mailbox[device] = nil
            accounts[acct]?.deviceLinks[device]?.closeByRelay(code: 4403, reason: "removed")
            accounts[acct]?.deviceLinks[device] = nil
        case .devices:
            let items = (accounts[acct]?.devices.keys.sorted() ?? []).map { RelayDeviceEntry(id: $0, lastSeen: now) }
            link.deliver(.devices(items: items))
        default:
            link.deliver(.error(reason: "forbidden"))
        }
    }

    /// Relay comprometido: vuelve a entregar a la Mac el último marco que le entregó.
    func redeliverLastToMac(_ acct: String) {
        guard let message = lastToMac[acct] else { return }
        accounts[acct]?.mac?.deliver(message)
    }
}

final class InMemoryRelayLink: RelayLink, @unchecked Sendable {
    enum Role {
        case mac(String)
        case device(String, String)
        case pair(String, String)
    }

    private let relay: InMemoryRelay
    private let credential: RelayCredential
    private let lock = NSLock()
    private var _role: Role?
    private var closed = false
    private let pair = AsyncThrowingStream<RelayMessage, Error>.makeStream()
    private var outbound: AsyncStream<RelayMessage>.Continuation?
    private var pump: Task<Void, Never>?

    init(relay: InMemoryRelay, credential: RelayCredential) {
        self.relay = relay
        self.credential = credential
    }

    var role: Role? {
        get { lock.withLock { _role } }
        set { lock.withLock { _role = newValue } }
    }

    var incoming: AsyncThrowingStream<RelayMessage, Error> { pair.stream }

    func connect() async throws -> RelayReady {
        let nonce = await relay.challenge()
        let ready = try await relay.authenticate(self, try credential.auth(host: relay.host, nonce: nonce), nonce: nonce)
        let (stream, continuation) = AsyncStream<RelayMessage>.makeStream()
        let relay = relay
        let task = Task { [weak self] in
            for await message in stream {
                guard let self else { return }
                await relay.receive(message, from: self)
            }
        }
        lock.withLock {
            outbound = continuation
            pump = task
        }
        return ready
    }

    func send(_ message: RelayMessage) throws {
        guard let outbound = lock.withLock({ closed ? nil : outbound }) else {
            throw RelayClosed(code: nil, reason: "Not connected")
        }
        outbound.yield(message)
    }

    func deliver(_ message: RelayMessage) {
        pair.continuation.yield(message)
    }

    /// El relay corta la conexión con un código.
    func closeByRelay(code: Int, reason: String) {
        let pump = lock.withLock { () -> Task<Void, Never>? in
            closed = true
            outbound?.finish()
            return self.pump
        }
        pump?.cancel()
        pair.continuation.finish(throwing: RelayClosed(code: code, reason: reason))
    }

    func close() async {
        let already = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        if !already {
            lock.withLock { outbound?.finish() }
            await relay.disconnected(self)
        }
        pair.continuation.finish(throwing: RelayClosed(code: 1000, reason: "closed"))
    }
}
