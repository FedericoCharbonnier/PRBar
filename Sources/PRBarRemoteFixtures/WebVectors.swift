import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteMac
@_spi(Testing) import PRBarRemoteKit
import PRBarWire

/// Vectores cruzados para la web app (spec web W.9): lo que produce la Mac, byte por byte, con claves fijas.
/// `prbar-remote-fixture vectors <dir>` los escribe en `web/test/fixtures/`; los tests de la web tienen que producir y
/// aceptar los mismos bytes. Solo datos ficticios. Los bytes van en hex minúscula salvo que el campo diga otra cosa.
///
/// No son deterministas (CryptoKit no deja fijar el azar): los sobres HPKE (`hpke.json`), las firmas Ed25519
/// (`relay-auth.json`) y la firma ECDSA de la prueba de presencia de muestra (`presence.json`). Siempre son válidos:
/// la web los verifica o los abre en vez de comparar bytes.
public enum WebVectors {
    // MARK: Identidades fijas

    /// 32 bytes derivados de una etiqueta: cada clave de acá es la misma en cada corrida.
    static func seed(_ label: String) -> Data { Data(SHA256.hash(data: Data("PRBar web vectors v1|\(label)".utf8))) }
    static func x25519(_ label: String) -> Curve25519.KeyAgreement.PrivateKey {
        try! .init(rawRepresentation: seed(label))
    }
    static func ed25519(_ label: String) -> Curve25519.Signing.PrivateKey { try! .init(rawRepresentation: seed(label)) }

    public static let relayHost = "prbar.example.org"
    public static let macName = "Federico’s MacBook Pro"
    public static var accountId: String { Base32.encode(seed("account").prefix(16)) }
    public static var deviceId: String { Base32.encode(seed("device").prefix(16)) }
    public static var pairingId: String { Base32.encode(seed("pairing").prefix(10)) }
    static var macKeys: MacKeys { MacKeys(relay: ed25519("mac relay"), noise: x25519("mac noise"), seal: x25519("mac seal")) }
    static var deviceKeys: DeviceKeys {
        DeviceKeys(relay: ed25519("device relay"), noise: x25519("device noise"), push: x25519("device push"))
    }
    static var passkey: SoftwareWebAuthnAuthenticator {
        SoftwareWebAuthnAuthenticator(rpId: relayHost, key: try! P256.Signing.PrivateKey(rawRepresentation: seed("passkey")),
                                      credentialId: seed("credential id").prefix(16))
    }
    static let t0 = Date(timeIntervalSince1970: 1_795_178_280)

    // MARK: Salida

    /// Nombre de archivo → JSON (con sangría y claves ordenadas).
    @MainActor
    public static func files() async throws -> [String: Data] {
        let kk = try noiseKK()
        let ik = try noiseIKpsk2()
        let objects: [String: Any] = [
            "noise-kk.json": [kk],
            "noise-ikpsk2.json": [ik.vector],
            "hpke.json": try hpke(),
            "sas.json": sas(pairingHash: ik.hash),
            "relay-auth.json": try relayAuth(),
            "presence.json": try await presence(),
            "pairing-qr.json": pairingQR(),
            "frames.json": try frames(),
            "app.json": try await app(),
        ]
        return try objects.mapValues {
            var data = try JSONSerialization.data(withJSONObject: $0,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            data.append(0x0A)
            return data
        }
    }

    @MainActor
    public static func write(to directory: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let all = try await files()
        for (name, data) in all { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
        return all.keys.sorted()
    }

    static func hex(_ data: Data) -> String { data.hexString }
    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
    /// Un valor JSON como objeto anidado (para leerlo); los bytes exactos van al lado, en un campo `text`.
    static func object(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }

    // MARK: Noise

    /// Una sesión como la real (spec P.5): el teléfono inicia KK con payloads vacíos en el handshake, después 3 mensajes
    /// de transporte en cada sentido. Cada payload de transporte es un trozo (`FrameChunker`) de un `RemoteFrame` real.
    static func noiseKK() throws -> [String: Any] {
        let device = deviceKeys, mac = macKeys
        let prologue = RemotePrologue.session(account: accountId, device: deviceId)
        let initEphemeral = x25519("kk init ephemeral"), respEphemeral = x25519("kk resp ephemeral")
        var initiator = try NoiseHandshake(pattern: .kk, initiator: true, prologue: prologue, localStatic: device.noise,
                                           remoteStatic: mac.noise.publicKey, psk: nil, fixedEphemeral: initEphemeral)
        var responder = try NoiseHandshake(pattern: .kk, initiator: false, prologue: prologue, localStatic: mac.noise,
                                           remoteStatic: device.noise.publicKey, psk: nil, fixedEphemeral: respEphemeral)
        var messages: [[String: Any]] = []
        let m1 = try initiator.writeMessage()
        _ = try responder.readMessage(m1)
        messages.append(["payload": "", "ciphertext": hex(m1)])
        let m2 = try responder.writeMessage()
        _ = try initiator.readMessage(m2)
        messages.append(["payload": "", "ciphertext": hex(m2)])
        var phone = try initiator.split(), macSide = try responder.split()
        let frames: [RemoteFrame] = try [
            .hello(RemoteHello(appVersion: "web-0.1.0", deviceName: "Federico’s iPhone")),
            .hello(RemoteHello(appVersion: "1.9.0", macName: macName)),
            .req(RemoteRequest(id: 1, sentAt: t0, command: .status)),
            .presencePolicy(requirePresence: true, gated: RemotePolicy.gatedNames),
            .sub(topics: ["home", "pr:acme/api#317"]),
            .state(RemoteStateUpdate(topic: "home", rev: 1, data: .object(["prs": .array([])]))),
        ]
        for (index, frame) in frames.enumerated() {
            let data = try frame.encoded()
            let chunks = try FrameChunker.chunks(for: data, compress: false)
            precondition(chunks.count == 1)
            let ciphertext = index % 2 == 0 ? try phone.send.encrypt(chunks[0]) : try macSide.send.encrypt(chunks[0])
            messages.append(["payload": hex(chunks[0]), "ciphertext": hex(ciphertext), "frame": text(data)])
        }
        precondition(initiator.handshakeHash == responder.handshakeHash)
        return [
            "source": "prbar",
            "protocol_name": "Noise_KK_25519_ChaChaPoly_SHA256",
            "init_prologue": hex(prologue), "resp_prologue": hex(prologue),
            "init_static": hex(device.noise.rawRepresentation), "init_ephemeral": hex(initEphemeral.rawRepresentation),
            "init_remote_static": hex(mac.noise.publicKey.rawRepresentation),
            "resp_static": hex(mac.noise.rawRepresentation), "resp_ephemeral": hex(respEphemeral.rawRepresentation),
            "resp_remote_static": hex(device.noise.publicKey.rawRepresentation),
            "handshake_hash": hex(initiator.handshakeHash),
            "messages": messages,
            "account": accountId, "device": deviceId,
        ]
    }

    /// Emparejamiento (spec P.11 / W.4): el teléfono inicia IKpsk2 con el payload `join`; la Mac contesta con payload
    /// vacío; después `confirm` (teléfono), `result` (Mac) y `ack` (teléfono) como mensajes de transporte.
    static func noiseIKpsk2() throws -> (vector: [String: Any], hash: Data) {
        let device = deviceKeys, mac = macKeys
        let ps = seed("pairing secret")
        let secrets = PairingSecrets(secret: ps)
        let prologue = RemotePrologue.pairing(account: accountId, pairing: pairingId)
        let initEphemeral = x25519("ik init ephemeral"), respEphemeral = x25519("ik resp ephemeral")
        var initiator = try NoiseHandshake(pattern: .ikpsk2, initiator: true, prologue: prologue, localStatic: device.noise,
                                           remoteStatic: mac.noise.publicKey, psk: secrets.psk, fixedEphemeral: initEphemeral)
        var responder = try NoiseHandshake(pattern: .ikpsk2, initiator: false, prologue: prologue, localStatic: mac.noise,
                                           remoteStatic: nil, psk: secrets.psk, fixedEphemeral: respEphemeral)
        let join = try PairingWire.join(deviceName: "Federico’s iPhone", model: "iPhone",
                                        relayKey: device.relay.publicKey.rawRepresentation,
                                        push: device.push.publicKey.rawRepresentation, presence: passkey.credential)
        precondition(PairingWire.isValidJoin(join))
        var messages: [[String: Any]] = []
        let m1 = try initiator.writeMessage(payload: join)
        _ = try responder.readMessage(m1)
        messages.append(["payload": hex(join), "ciphertext": hex(m1), "frame": text(join)])
        let m2 = try responder.writeMessage()
        _ = try initiator.readMessage(m2)
        messages.append(["payload": "", "ciphertext": hex(m2)])
        var phone = try initiator.split(), macSide = try responder.split()
        let transport: [Data] = [
            try PairingWire.confirm(),
            try PairingWire.result(deviceId: deviceId, macName: macName, macSeal: mac.seal.publicKey.rawRepresentation,
                                   relayHost: relayHost),
            try PairingWire.ack(),
        ]
        for (index, payload) in transport.enumerated() {
            let ciphertext = index % 2 == 0 ? try phone.send.encrypt(payload) : try macSide.send.encrypt(payload)
            messages.append(["payload": hex(payload), "ciphertext": hex(ciphertext), "frame": text(payload)])
        }
        let hash = initiator.handshakeHash
        let vector: [String: Any] = [
            "source": "prbar",
            "protocol_name": "Noise_IKpsk2_25519_ChaChaPoly_SHA256",
            "init_prologue": hex(prologue), "resp_prologue": hex(prologue),
            "init_psks": [hex(secrets.psk)], "resp_psks": [hex(secrets.psk)],
            "init_static": hex(device.noise.rawRepresentation), "init_ephemeral": hex(initEphemeral.rawRepresentation),
            "init_remote_static": hex(mac.noise.publicKey.rawRepresentation),
            "resp_static": hex(mac.noise.rawRepresentation), "resp_ephemeral": hex(respEphemeral.rawRepresentation),
            "handshake_hash": hex(hash),
            "messages": messages,
            "account": accountId, "pairing": pairingId, "device": deviceId,
            "ps": hex(ps), "pairAuthKey": hex(secrets.authKey), "sas": SAS.code(handshakeHash: hash),
            "macSeal": hex(mac.seal.publicKey.rawRepresentation),
            "deviceRelayPublic": hex(device.relay.publicKey.rawRepresentation),
            "devicePushPublic": hex(device.push.publicKey.rawRepresentation),
        ]
        return (vector, hash)
    }

    // MARK: HPKE (push y buzón)

    static func hpke() throws -> [[String: Any]] {
        let mac = macKeys, device = deviceKeys
        let push = PushPayload(id: UUID(uuidString: "6F1D8C2E-0B7A-4E55-9C61-3A2B9E0F4D11")!, createdAt: t0,
                               kind: "readyToMerge", title: "Ready to merge", body: "acme/api#322 · Make payment retries idempotent",
                               threadId: "acme/api#322", pr: "acme/api#322", deepLink: "prbar://pr/acme/api/322?screen=merge",
                               badge: 2)
        let pushInfo = SealedInfo.push(account: accountId, device: deviceId)
        let pushPlain = try CommandProtocol.encoder.encode(push)
        let pushEnvelope = try push.sealedForPush(from: mac.seal, to: device.push.publicKey, info: pushInfo)
        let ids = try PushIdentifiers(macSeal: mac.seal, devicePush: device.push.publicKey)

        let blob = MailboxBlob(slot: "home", rev: 1_795_178_280_000, createdAt: t0, data: Data(#"{"prs":[]}"#.utf8))
        let mailboxInfo = SealedInfo.mailbox(account: accountId, device: deviceId, slot: "home")
        let mailboxPlain = try CommandProtocol.encoder.encode(blob)
        let mailboxEnvelope = try blob.seal(from: mac.seal, to: device.push.publicKey, account: accountId, device: deviceId)

        func entry(_ kind: String, info: Data, plain: Data, envelope: Data) -> [String: Any] {
            [
                "kind": kind,
                "info": hex(info), "infoText": text(info),
                "skR": hex(device.push.rawRepresentation), "pkR": hex(device.push.publicKey.rawRepresentation),
                "skS": hex(mac.seal.rawRepresentation), "pkS": hex(mac.seal.publicKey.rawRepresentation),
                "plaintext": hex(plain), "plaintextText": text(plain),
                "padded": hex(Padding.pad(plain, to: SealedEnvelope.paddingBlock)),
                "envelope": hex(envelope), "envelopeB64url": Base64URL.encode(envelope),
            ]
        }
        var pushEntry = entry("push", info: pushInfo, plain: pushPlain, envelope: pushEnvelope)
        pushEntry["collapse"] = ids.collapse(kind: push.kind, pr: push.pr ?? push.threadId)
        pushEntry["thread"] = ids.thread(pr: push.pr ?? push.threadId)
        pushEntry["maxPaddedPlaintext"] = PushPayload.maxPlaintext
        var mailboxEntry = entry("mailbox", info: mailboxInfo, plain: mailboxPlain, envelope: mailboxEnvelope)
        mailboxEntry["slot"] = "home"
        return [pushEntry, mailboxEntry]
    }

    // MARK: SAS, auth del relay, presencia, QR

    static func sas(pairingHash: Data) -> [[String: Any]] {
        [pairingHash, Data(count: 32), Data(repeating: 0xFF, count: 32), seed("sas")].map {
            ["handshakeHash": hex($0), "code": SAS.code(handshakeHash: $0)]
        }
    }

    static func relayAuth() throws -> [[String: Any]] {
        let nonce = seed("relay nonce")
        return try [(deviceKeys.relay, deviceId), (macKeys.relay, "mac")].map { key, client in
            let message = RelayAuth.message(host: relayHost, account: accountId, client: client, nonce: nonce)
            let signature = try key.signature(for: message)
            return [
                "privateKey": hex(key.rawRepresentation), "publicKey": hex(key.publicKey.rawRepresentation),
                "host": relayHost, "acct": accountId, "client": client, "nonce": hex(nonce),
                "nonceB64url": Base64URL.encode(nonce), "message": hex(message), "sig": hex(signature),
                "sigB64url": Base64URL.encode(signature),
            ]
        }
    }

    static func presence() async throws -> [[String: Any]] {
        let session = seed("session hash")
        let merge = try CommandProtocol.encoder.encode(
            AppCommand.merge(pr: "acme/api#322", method: .squash, confirmed: true, expectedHeadOid: "9f3c2a1"))
        let cases: [(UInt64, Data, Int64)] = [(7, merge, 1_795_178_280_123), (0x0001_0203_0405_0607, Data("x".utf8), 1_500)]
        var out: [[String: Any]] = []
        for (index, item) in cases.enumerated() {
            let (reqId, cmd, ts) = item
            var entry: [String: Any] = [
                "sessionHash": hex(session), "reqId": reqId, "cmd": hex(cmd), "cmdText": text(cmd), "ts": ts,
                "preimage": hex(PresenceChallenge.preimage(sessionHash: session, reqId: reqId, commandBytes: cmd, tsMillis: ts)),
                "challenge": hex(PresenceChallenge.make(sessionHash: session, reqId: reqId, commandBytes: cmd, tsMillis: ts)),
            ]
            if index == 0 {
                // Una prueba completa como la arma un navegador: el verificador de la Mac la acepta en `ts`.
                let key = passkey
                let proof = try await PresenceProof.make(authenticator: key, sessionHash: session, reqId: reqId,
                                                         commandBytes: cmd,
                                                         at: Date(timeIntervalSince1970: Double(ts) / 1000))
                let proofJSON = try JSONEncoder().encode(proof)
                entry["rpId"] = relayHost
                entry["origin"] = "https://\(relayHost)"
                entry["credential"] = try object(try JSONEncoder().encode(key.credential))
                entry["privateKey"] = hex(key.key.rawRepresentation)
                entry["authenticatorData"] = hex(proof.authenticatorData)
                entry["clientDataJSON"] = text(proof.clientDataJSON)
                entry["signature"] = hex(proof.signature)
                entry["proof"] = try object(proofJSON)
            }
            out.append(entry)
        }
        return out
    }

    static func pairingQR() -> [String: Any] {
        let mac = macKeys
        let samples = [
            PairingQR(relayHost: relayHost, accountId: accountId, pairingId: pairingId, secret: seed("pairing secret"),
                      macStatic: mac.noise.publicKey.rawRepresentation, macName: macName),
            PairingQR(relayHost: "prbar.example.org:8443", accountId: accountId, pairingId: pairingId,
                      secret: seed("pairing secret 2"), macStatic: mac.noise.publicKey.rawRepresentation,
                      macName: "Work Mac & co = 🚀"),
        ]
        let nonce = seed("pairing nonce")
        let valid: [[String: Any]] = samples.map { qr in
            let secrets = PairingSecrets(secret: qr.secret)
            return [
                "relayHost": qr.relayHost, "accountId": qr.accountId, "pairingId": qr.pairingId,
                "secret": hex(qr.secret), "macStatic": hex(qr.macStatic), "macName": qr.macName, "url": qr.url,
                "authKey": hex(secrets.authKey), "psk": hex(secrets.psk), "nonce": hex(nonce),
                "proof": hex(PairingSecrets.proof(authKey: secrets.authKey, nonce: nonce)),
            ]
        }
        let good = samples[0].url
        let invalid = [
            good.replacingOccurrences(of: "https://\(relayHost)/#pair?", with: "prbar://pair?"),
            good.replacingOccurrences(of: "https://", with: "http://"),
            good.replacingOccurrences(of: "https://\(relayHost)/", with: "https://evil.example.org/"),
            good.replacingOccurrences(of: "v=1", with: "v=2"),
            good + "&v=1",
            good.replacingOccurrences(of: "&k=", with: "&k=AA"),
        ]
        for text in invalid { precondition((try? PairingQR(url: text)) == nil, text) }
        return ["valid": valid, "invalid": invalid]
    }

    // MARK: Marcos

    static func frames() throws -> [String: Any] {
        let bytes = Data([1, 2, 3, 250, 251, 252])
        let relay: [RelayMessage] = [
            .challenge(nonce: seed("relay nonce"), time: 1_795_178_280),
            .auth(acct: accountId, client: deviceId, sig: Data(repeating: 9, count: 64), pairing: nil, proof: nil),
            .auth(acct: accountId, client: "pair", sig: nil, pairing: pairingId, proof: Data(repeating: 8, count: 32)),
            .ready(mac: "online", since: 1_795_178_000),
            .send(to: "mac", sid: "0123456789abcdef", b: bytes),
            .recv(from: "mac", sid: "0123456789abcdef", b: bytes),
            .undeliverable(to: "mac", sid: "0123456789abcdef"),
            .presence(mac: "offline", since: 1_795_178_000, device: nil, state: nil),
            .presence(mac: nil, since: nil, device: deviceId, state: "online"),
            .push(id: "p1", to: deviceId, collapse: String(repeating: "a", count: 64),
                  thread: String(repeating: "b", count: 32), b: bytes),
            .pushResult(id: "p1", status: 410, reason: "Unsubscribed"),
            .mboxPut(to: deviceId, slot: "home", b: bytes),
            .mboxGet,
            .mbox(items: [RelayMailboxItem(slot: "home", b: bytes, at: 1_795_178_280)]),
            .webpush(endpoint: "https://web.push.apple.com/QGuQ", p256dh: Data([4]) + Data(repeating: 7, count: 64),
                     auth: Data(repeating: 1, count: 16)),
            .pairOpen(pairing: pairingId, authKey: Data(repeating: 5, count: 32), expires: 1_795_178_580),
            .pairClose(pairing: pairingId),
            .deviceAdd(device: deviceId, relayKey: Data(repeating: 6, count: 32)),
            .deviceRemove(device: deviceId),
            .devices(items: nil),
            .devices(items: [RelayDeviceEntry(id: deviceId, lastSeen: 1_795_178_280)]),
            .error(reason: "forbidden"),
            .ping,
            .pong,
        ]
        let merge = AppCommand.merge(pr: "acme/api#322", method: .squash, confirmed: true, expectedHeadOid: "9f3c2a1")
        let proof = PresenceProof(tsMillis: 1_795_178_280_123, credentialId: Data(repeating: 3, count: 16),
                                  authenticatorData: Data(repeating: 1, count: 37), clientDataJSON: Data("{}".utf8),
                                  signature: Data([0x30, 0x06, 2, 1, 1, 2, 1, 1]))
        let app: [RemoteFrame] = try [
            .hello(RemoteHello(appVersion: "web-0.1.0", deviceName: "Federico’s iPhone")),
            .hello(RemoteHello(appVersion: "1.9.0", macName: macName)),
            .hello(RemoteHello(appVersion: "1.9.0", macName: macName, incompatible: .updateIPhone)),
            .req(RemoteRequest(id: 1, sentAt: t0, command: .status, deadline: t0.addingTimeInterval(60))),
            .req(RemoteRequest(id: 2, sentAt: t0, command: merge, presence: proof, deadline: t0.addingTimeInterval(60))),
            .res(CommandResponse.success(id: 1, .object(["ok": .bool(true)]))),
            .res(CommandResponse.event(id: 3, .progress(message: "Reviewing…"))),
            .res(CommandResponse.event(id: 3, .text(delta: "Looking "))),
            .res(CommandResponse.failure(id: 2, CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))),
            .sub(topics: ["home", "activity", "pr:acme/api#317"]),
            .state(RemoteStateUpdate(topic: "home", rev: 3, data: .object(["prs": .array([])]))),
            .chatDelta(pr: "acme/api#317", text: "Also, from the Mac."),
            .unpair,
            .presencePolicy(requirePresence: true, gated: RemotePolicy.gatedNames),
            .bye(reason: "revoked"),
            .bye(reason: nil),
        ]
        let chunkSample = try RemoteFrame.hello(RemoteHello(appVersion: "1.9.0", macName: macName)).encoded()
        let pairing: [(String, Data)] = try [
            ("join", PairingWire.join(deviceName: "Federico’s iPhone", model: "iPhone",
                                      relayKey: deviceKeys.relay.publicKey.rawRepresentation,
                                      push: deviceKeys.push.publicKey.rawRepresentation, presence: passkey.credential)),
            ("joinWithoutPasskey", PairingWire.join(deviceName: "Federico’s iPhone", model: "iPhone",
                                                    relayKey: deviceKeys.relay.publicKey.rawRepresentation,
                                                    push: deviceKeys.push.publicKey.rawRepresentation, presence: nil)),
            ("confirm", PairingWire.confirm()),
            ("result", PairingWire.result(deviceId: deviceId, macName: macName,
                                          macSeal: macKeys.seal.publicKey.rawRepresentation, relayHost: relayHost)),
            ("ack", PairingWire.ack()),
            ("cancelled", PairingWire.cancelled()),
        ]
        return [
            "relay": try relay.map { ["type": $0.type, "text": try $0.text()] },
            "app": try app.map { ["type": $0.type, "text": text(try $0.encoded())] },
            "pairing": pairing.map { ["type": $0.0, "text": text($0.1)] },
            "chunks": [[
                "frame": text(chunkSample),
                "chunks": try FrameChunker.chunks(for: chunkSample, compress: false).map(hex),
            ]],
        ]
    }

    // MARK: Comandos, resultados y tópicos

    /// Una muestra de cada comando que puede mandar el teléfono (`RemotePolicy` distinto de `.denied`), en un orden que
    /// además hace que el fixture dé resultados útiles (Fix CI antes de su diff, publicar al final).
    @MainActor
    public static var phoneCommands: [AppCommand] {
        let review = FixtureActions.reviewPR, merge = FixtureActions.mergePR, ci = FixtureActions.ciPR
        return [
            .status,
            .listPRs(list: nil, account: nil, tab: nil),
            .listPRs(list: .toReview, account: nil, tab: .toReview),
            .resolvePR(pr: review),
            .refresh,
            .history(repo: nil, kind: nil, limit: 50, search: nil),
            .historyShow(id: FixtureActions.historyId.uuidString),
            .reviewStart(pr: review, wait: false),
            .reviewShow(pr: review),
            .reviewEdit(pr: review, finding: "f1", title: "Expired refresh tokens retry forever", body: nil),
            .reviewSetIncluded(pr: review, findings: ["f3"], all: false, included: true),
            .reviewSetComment(pr: review, text: "Looks good overall."),
            .chatSend(pr: review, message: "Anything else worth flagging?"),
            .chatShow(pr: review),
            .chatUndo(pr: review, confirmed: true),
            .chatStop(pr: review),
            .ciList,
            .ciFix(pr: ci, wait: false),
            .respondStart(pr: ci, wait: false),
            .respondShow(pr: ci),
            .respondSelect(pr: ci, items: ["c1"], change: RespondSelectionChange(implement: true)),
            .respondReset(pr: ci),
            .respondImplement(pr: ci, wait: false),
            .respondTest(pr: ci, wait: false),
            .respondDiff(pr: ci),
            .respondReplyOnly(pr: ci, confirmed: true, wait: false),
            .respondPushAnyway(pr: ci, confirmed: true, wait: false),
            .respondPush(pr: ci, confirmed: true, wait: false),
            .respondCancel(pr: ci),
            .respondDismiss(pr: ci),
            .mergePreview(pr: merge, method: nil),
            .merge(pr: merge, method: .squash, confirmed: true, expectedHeadOid: FixtureActions.mergeHead),
            .mergeDismiss(pr: merge),
            .resources,
            .usage(month: nil),
            .notifyList,
            .notifySet(kind: .readyToMerge, enabled: false),
            .notifySetEnabled(enabled: true),
            .remoteSetPresenceRequirement(device: deviceId, enabled: true),
            .reviewPublish(pr: review, event: .comment, only: nil, withComments: true, allInBody: false, confirmed: true),
            .reviewPublish(pr: review, event: .approve, only: nil, withComments: true, allInBody: false, confirmed: true),
            .reviewCancel(pr: review),
            .reviewDismiss(pr: review),
        ]
    }

    @MainActor
    static func app() async throws -> [String: Any] {
        let actions = FixtureActions()
        actions.chatReply = ["Looking ", "at the diff."]
        // Primero los tópicos, con el fixture recién creado (lo que ve el teléfono antes de hacer nada).
        var topics: [[String: Any]] = []
        for topic in [RemoteTopic.home, .pr(FixtureActions.reviewPR), .pr(FixtureActions.mergePR), .activity] {
            let value = try await RemoteStateTopics.compute(topic, actions, system: {
                MacSystemInfo(cores: 10, memoryTotalBytes: 32 << 30, memoryUsedBytes: 18 << 30,
                              diskFreeBytes: 200 << 30, diskTotalBytes: 1_000 << 30)
            })
            let data = try CommandProtocol.encoder.encode(value)
            topics.append(["topic": topic.name, "text": text(data), "json": try object(data)])
        }
        var commands: [[String: Any]] = []
        for command in phoneCommands {
            let encoded = try CommandProtocol.encoder.encode(command)
            let collected = EventBox()
            let result = await CommandDispatcher.run(command, on: actions, events: { collected.add($0) })
            var entry: [String: Any] = [
                "name": command.name.rawValue, "policy": "\(RemotePolicy.decide(command))",
                "text": text(encoded), "json": try object(encoded),
            ]
            let response: CommandResponse
            switch result {
            case .success(let value): response = .success(id: 1, value)
            case .failure(let failure): response = .failure(id: 1, failure)
            }
            let responseData = try CommandProtocol.encoder.encode(response)
            entry["response"] = try object(responseData)
            entry["responseText"] = text(responseData)
            let events = try collected.events.map { try object(try CommandProtocol.encoder.encode(CommandResponse.event(id: 1, $0))) }
            if !events.isEmpty { entry["events"] = events }
            commands.append(entry)
        }
        let errors: [CommandFailure] = [
            CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage),
            CommandFailure(.unauthorized, RemotePolicy.presenceNotSetUpMessage),
            CommandFailure(.unauthorized, RemotePolicy.deniedMessage),
            CommandFailure(.protocolMismatch, "Update PRBar on your Mac and iPhone."),
            CommandFailure(.invalidState, "This request expired. Try again."),
            CommandFailure(.invalidState, RemoteLimits.tooManyRequestsMessage),
        ]
        let push = RemotePushPlanner.payloads(for: [
            PlannedNotification(kind: .myPRFeedback, title: "New Feedback", body: "api#7: 2 comments", url: nil,
                                prID: "acme/api#7"),
            PlannedNotification(kind: .readyToMerge, title: "Ready to Merge", body: "api#322", url: nil,
                                prID: FixtureActions.mergePR, mergePRID: FixtureActions.mergePR),
            PlannedNotification(kind: .updateAvailable, title: "PRBar 2.0 is available", body: "", url: nil),
        ], badge: 3, now: t0)
        return [
            "protocolVersion": CommandProtocol.version,
            "minimumRemoteVersion": CommandProtocol.minimumRemoteVersion,
            "gated": RemotePolicy.gatedNames.map(\.rawValue),
            "commands": commands,
            "topics": topics,
            "errors": try errors.map { try object(try CommandProtocol.encoder.encode(CommandResponse.failure(id: 1, $0))) },
            "push": try push.map { payload in
                var copy = payload
                copy.id = UUID(uuidString: "6F1D8C2E-0B7A-4E55-9C61-3A2B9E0F4D11")!
                return try object(try CommandProtocol.encoder.encode(copy))
            },
        ]
    }
}

/// Los eventos de `CommandDispatcher` (pueden llegar desde otra tarea).
private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandEvent] = []
    func add(_ event: CommandEvent) { lock.withLock { items.append(event) } }
    var events: [CommandEvent] { lock.withLock { items } }
}
