import Foundation

// Marcos del relay (spec P.4): JSON de texto por el WebSocket, claves cortas, el cifrado en base64url sin relleno
// (`b`). El relay en Go (`relay/internal/hub`) habla exactamente esto; `relay/internal/hub/testdata/frames.json` tiene
// los mismos literales que `WireTests`.

public enum RelayCloseCode: Int, Sendable {
    case unauthorized = 4401
    case deviceRemoved = 4403
    case authTimeout = 4408
    case replaced = 4409
    case tooLarge = 4413
    case rateLimited = 4429
}

public struct RelayMailboxItem: Equatable, Sendable {
    public var slot: String
    public var b: Data
    public var at: Int

    public init(slot: String, b: Data, at: Int) {
        self.slot = slot
        self.b = b
        self.at = at
    }
}

public struct RelayDeviceEntry: Codable, Equatable, Sendable {
    public var id: String
    public var lastSeen: Int

    public init(id: String, lastSeen: Int) {
        self.id = id
        self.lastSeen = lastSeen
    }
}

public enum RelayMessage: Equatable, Sendable {
    case challenge(nonce: Data, time: Int)
    /// `client`: `mac`, un `deviceId` o `pair` (con `pairing` y `proof` en vez de `sig`).
    case auth(acct: String, client: String, sig: Data?, pairing: String?, proof: Data?)
    case ready(mac: String, since: Int)
    case send(to: String, sid: String, b: Data)
    case recv(from: String, sid: String, b: Data)
    case undeliverable(to: String, sid: String)
    /// A los teléfonos: `mac` + `since`. A la Mac: `device` + `state`.
    case presence(mac: String?, since: Int?, device: String?, state: String?)
    case push(id: String, to: String, collapse: String, thread: String, b: Data)
    case pushResult(id: String, status: Int, reason: String?)
    case mboxPut(to: String, slot: String, b: Data)
    case mboxGet
    case mbox(items: [RelayMailboxItem])
    /// La suscripción de Web Push del teléfono (spec web W.6). `p256dh` (65 bytes) y `auth` (16) en base64url.
    case webpush(endpoint: String, p256dh: Data, auth: Data)
    case pairOpen(pairing: String, authKey: Data, expires: Int)
    case pairClose(pairing: String)
    case deviceAdd(device: String, relayKey: Data)
    case deviceRemove(device: String)
    /// Pedido de la Mac (sin `items`) y respuesta del relay (con `items`).
    case devices(items: [RelayDeviceEntry]?)
    /// Un pedido rechazado sin cerrar la conexión (p. ej. un teléfono que manda a otro teléfono).
    case error(reason: String)
    case ping
    case pong
    case unknown(String)

    public var type: String {
        switch self {
        case .challenge: "challenge"
        case .auth: "auth"
        case .ready: "ready"
        case .send: "send"
        case .recv: "recv"
        case .undeliverable: "undeliverable"
        case .presence: "presence"
        case .push: "push"
        case .pushResult: "pushResult"
        case .mboxPut: "mbox.put"
        case .mboxGet: "mbox.get"
        case .mbox: "mbox"
        case .webpush: "webpush"
        case .pairOpen: "pair.open"
        case .pairClose: "pair.close"
        case .deviceAdd: "device.add"
        case .deviceRemove: "device.remove"
        case .devices: "devices"
        case .error: "error"
        case .ping: "ping"
        case .pong: "pong"
        case .unknown(let t): t
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// El texto del marco de WebSocket.
    public func text() throws -> String { String(decoding: try Self.encoder.encode(self), as: UTF8.self) }

    public static func decode(_ text: String) throws -> RelayMessage {
        try JSONDecoder().decode(RelayMessage.self, from: Data(text.utf8))
    }
}

extension RelayMessage: Codable {
    private enum Keys: String, CodingKey {
        case t, nonce, time, acct, client, sig, pairing, proof, mac, since, to, sid, b, from, device, state, id, collapse
        case thread, status, reason, slot, items, endpoint, p256dh, auth, authKey, expires, relayKey, at, lastSeen
    }

    private struct MailboxItemDTO: Codable {
        var slot: String
        var b: String
        var at: Int
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func string(_ key: Keys) throws -> String { try c.decode(String.self, forKey: key) }
        func bytes(_ key: Keys) throws -> Data { try Base64URL.decode(try string(key)) }
        func optionalBytes(_ key: Keys) throws -> Data? {
            try c.decodeIfPresent(String.self, forKey: key).map { try Base64URL.decode($0) }
        }
        func int(_ key: Keys) throws -> Int { try c.decode(Int.self, forKey: key) }
        let t = try string(.t)
        switch t {
        case "challenge": self = .challenge(nonce: try bytes(.nonce), time: try int(.time))
        case "auth":
            self = .auth(acct: try string(.acct), client: try string(.client), sig: try optionalBytes(.sig),
                         pairing: try c.decodeIfPresent(String.self, forKey: .pairing), proof: try optionalBytes(.proof))
        case "ready": self = .ready(mac: try string(.mac), since: try int(.since))
        case "send": self = .send(to: try string(.to), sid: try string(.sid), b: try bytes(.b))
        case "recv": self = .recv(from: try string(.from), sid: try string(.sid), b: try bytes(.b))
        case "undeliverable": self = .undeliverable(to: try string(.to), sid: try string(.sid))
        case "presence":
            self = .presence(mac: try c.decodeIfPresent(String.self, forKey: .mac),
                             since: try c.decodeIfPresent(Int.self, forKey: .since),
                             device: try c.decodeIfPresent(String.self, forKey: .device),
                             state: try c.decodeIfPresent(String.self, forKey: .state))
        case "push":
            self = .push(id: try string(.id), to: try string(.to), collapse: try string(.collapse),
                         thread: try string(.thread), b: try bytes(.b))
        case "pushResult":
            self = .pushResult(id: try string(.id), status: try int(.status),
                               reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "mbox.put": self = .mboxPut(to: try string(.to), slot: try string(.slot), b: try bytes(.b))
        case "mbox.get": self = .mboxGet
        case "mbox":
            let items = try c.decode([MailboxItemDTO].self, forKey: .items)
            self = .mbox(items: try items.map { RelayMailboxItem(slot: $0.slot, b: try Base64URL.decode($0.b), at: $0.at) })
        case "webpush":
            self = .webpush(endpoint: try string(.endpoint), p256dh: try bytes(.p256dh), auth: try bytes(.auth))
        case "pair.open":
            self = .pairOpen(pairing: try string(.pairing), authKey: try bytes(.authKey), expires: try int(.expires))
        case "pair.close": self = .pairClose(pairing: try string(.pairing))
        case "device.add": self = .deviceAdd(device: try string(.device), relayKey: try bytes(.relayKey))
        case "device.remove": self = .deviceRemove(device: try string(.device))
        case "devices": self = .devices(items: try c.decodeIfPresent([RelayDeviceEntry].self, forKey: .items))
        case "error": self = .error(reason: try string(.reason))
        case "ping": self = .ping
        case "pong": self = .pong
        default: self = .unknown(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .t)
        func put(_ data: Data, _ key: Keys) throws { try c.encode(Base64URL.encode(data), forKey: key) }
        switch self {
        case .challenge(let nonce, let time):
            try put(nonce, .nonce)
            try c.encode(time, forKey: .time)
        case .auth(let acct, let client, let sig, let pairing, let proof):
            try c.encode(acct, forKey: .acct)
            try c.encode(client, forKey: .client)
            if let sig { try put(sig, .sig) }
            try c.encodeIfPresent(pairing, forKey: .pairing)
            if let proof { try put(proof, .proof) }
        case .ready(let mac, let since):
            try c.encode(mac, forKey: .mac)
            try c.encode(since, forKey: .since)
        case .send(let to, let sid, let b):
            try c.encode(to, forKey: .to)
            try c.encode(sid, forKey: .sid)
            try put(b, .b)
        case .recv(let from, let sid, let b):
            try c.encode(from, forKey: .from)
            try c.encode(sid, forKey: .sid)
            try put(b, .b)
        case .undeliverable(let to, let sid):
            try c.encode(to, forKey: .to)
            try c.encode(sid, forKey: .sid)
        case .presence(let mac, let since, let device, let state):
            try c.encodeIfPresent(mac, forKey: .mac)
            try c.encodeIfPresent(since, forKey: .since)
            try c.encodeIfPresent(device, forKey: .device)
            try c.encodeIfPresent(state, forKey: .state)
        case .push(let id, let to, let collapse, let thread, let b):
            try c.encode(id, forKey: .id)
            try c.encode(to, forKey: .to)
            try c.encode(collapse, forKey: .collapse)
            try c.encode(thread, forKey: .thread)
            try put(b, .b)
        case .pushResult(let id, let status, let reason):
            try c.encode(id, forKey: .id)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .mboxPut(let to, let slot, let b):
            try c.encode(to, forKey: .to)
            try c.encode(slot, forKey: .slot)
            try put(b, .b)
        case .mbox(let items):
            try c.encode(items.map { MailboxItemDTO(slot: $0.slot, b: Base64URL.encode($0.b), at: $0.at) }, forKey: .items)
        case .webpush(let endpoint, let p256dh, let auth):
            try c.encode(endpoint, forKey: .endpoint)
            try put(p256dh, .p256dh)
            try put(auth, .auth)
        case .pairOpen(let pairing, let authKey, let expires):
            try c.encode(pairing, forKey: .pairing)
            try put(authKey, .authKey)
            try c.encode(expires, forKey: .expires)
        case .pairClose(let pairing):
            try c.encode(pairing, forKey: .pairing)
        case .deviceAdd(let device, let relayKey):
            try c.encode(device, forKey: .device)
            try put(relayKey, .relayKey)
        case .deviceRemove(let device):
            try c.encode(device, forKey: .device)
        case .devices(let items):
            try c.encodeIfPresent(items, forKey: .items)
        case .error(let reason):
            try c.encode(reason, forKey: .reason)
        case .mboxGet, .ping, .pong, .unknown:
            break
        }
    }
}

/// Lo que firma el cliente para autenticarse (spec P.4): `"PRBarRelayAuth v1\n" ‖ host ‖ "\n" ‖ acct ‖ "\n" ‖ client ‖
/// "\n" ‖ nonce`. `host` es el host público del relay: una firma no sirve en otro relay.
public enum RelayAuth {
    public static func message(host: String, account: String, client: String, nonce: Data) -> Data {
        Data("PRBarRelayAuth v1\n\(host)\n\(account)\n\(client)\n".utf8) + nonce
    }
}
