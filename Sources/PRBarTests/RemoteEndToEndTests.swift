import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit

/// Un reloj que los tests mueven a mano.
final class RemoteTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }

    var function: @Sendable () -> Date { { self.now } }
}

/// Lo que recibió el handler falso.
actor CommandRecorder {
    private(set) var commands: [AppCommand] = []
    func record(_ command: AppCommand) { commands.append(command) }
}

/// Espera hasta `seconds` a que `body` devuelva algo.
func within<T: Sendable>(_ seconds: Double = 5, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TestFailure(description: "timed out after \(seconds) s")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Espera a que `condition` se cumpla (sondeo cada 10 ms).
func eventually(_ seconds: Double = 5, _ what: String = "", _ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure(description: "never happened: \(what)")
}

/// Mac + relay en memoria + teléfono.
struct RemoteHarness {
    let relay: InMemoryRelay
    let clock: RemoteTestClock
    let macKeys: MacKeys
    let account: String
    let host: RemoteHost
    let recorder: CommandRecorder
    let presence = SoftwareWebAuthnAuthenticator(rpId: "relay.test")
    let factory: RelayLinkFactory

    typealias Handler = RemoteHost.Handler

    static func make(minimumRemoteVersion: Int = CommandProtocol.minimumRemoteVersion,
                     relayFactory: ((InMemoryRelay) -> RelayLinkFactory)? = nil,
                     pairingAckTimeout: Duration = .seconds(3), limits: RemoteLimits = .standard,
                     handler: Handler? = nil) async throws -> RemoteHarness {
        let clock = RemoteTestClock()
        let relay = InMemoryRelay(clock: clock.function)
        let keys = MacKeys()
        let account = await relay.enroll(macKey: keys.relay.publicKey)
        let recorder = CommandRecorder()
        let factory = relayFactory?(relay) ?? relay.factory()
        let defaultHandler: Handler = { command, sink in
            await recorder.record(command)
            sink(.progress(message: "uno"))
            sink(.text(delta: "dos"))
            return .success(.object(["ran": .string(command.name.rawValue)]))
        }
        let host = RemoteHost(
            configuration: .init(accountId: account, relayHost: relay.host, macName: "Federico’s Mac", appVersion: "1.2.0",
                                 keys: keys, minimumRemoteVersion: minimumRemoteVersion, pushTimeout: .seconds(2),
                                 pairingAckTimeout: pairingAckTimeout, limits: limits,
                                 backoff: { _ in .milliseconds(50) }),
            devices: [], linkFactory: factory, clock: clock.function, handler: handler ?? defaultHandler)
        try await host.connect()
        return RemoteHarness(relay: relay, clock: clock, macKeys: keys, account: account, host: host, recorder: recorder,
                             factory: factory)
    }

    func client(commandProtocol: Int = CommandProtocol.version, paired: PairedMac? = nil,
                keys: DeviceKeys? = nil, requestTimeout: Duration = .seconds(10)) -> RemoteClient {
        RemoteClient(configuration: .init(appVersion: "1.2.0", deviceName: "Federico’s iPhone", model: "iPhone 17 Pro",
                                          commandProtocol: commandProtocol, handshakeTimeout: .seconds(3),
                                          requestTimeout: requestTimeout),
                     paired: paired, keys: keys, linkFactory: factory, clock: clock.function)
    }

    /// Abre una ranura y espera a que el relay la tenga (en la vida real el QR tarda segundos en escanearse).
    func openPairing() async throws -> PairingQR {
        let qr = try await host.startPairing()
        let relay = relay, account = account
        try await eventually(3, "ranura en el relay") { await relay.pairingSlot(account) == qr.pairingId }
        return qr
    }

    /// El siguiente `pairingJoined` del host.
    func nextJoin() async throws -> (sas: String, name: String, model: String) {
        let events = host.events
        return try await within {
            for await event in events {
                if case .pairingJoined(let sas, let name, let model) = event { return (sas, name, model) }
            }
            throw TestFailure(description: "no join")
        }
    }

    /// Empareja un teléfono nuevo y conecta su sesión.
    func pairedClient(commandProtocol: Int = CommandProtocol.version,
                      requestTimeout: Duration = .seconds(10)) async throws -> RemoteClient {
        let client = client(commandProtocol: commandProtocol, requestTimeout: requestTimeout)
        let qr = try await openPairing()
        async let join = nextJoin()
        let sas = try await client.startPairing(qr: qr, presence: presence.credential)
        let joined = try await join
        try expectEqual(joined.sas, sas)
        try await host.confirmPairing(true)
        _ = try await within { try await client.finishPairing() }
        return client
    }
}

enum RemoteEndToEndTests {
    static func failure(_ response: CommandResponse) -> CommandFailure? { response.error }

    static let cases: [TestCase] = [
        TestCase("remote: emparejar con el mismo código en los dos lados") {
            let h = try await RemoteHarness.make()
            let client = h.client()
            let qr = try await h.openPairing()
            try expect(qr.url.hasPrefix("https://relay.test/#pair?v=1&"), qr.url)
            async let join = h.nextJoin()
            let sas = try await client.startPairing(qr: qr, presence: h.presence.credential)
            let joined = try await join
            try expectEqual(joined.sas, sas)
            try expectEqual(joined.name, "Federico’s iPhone")
            try expectEqual(joined.model, "iPhone 17 Pro")
            let device = try await h.host.confirmPairing(true)
            let mac = try await within { try await client.finishPairing() }
            try expectEqual(mac.deviceId, device?.deviceId)
            try expectEqual(mac.macName, "Federico’s Mac")
            try expectEqual(mac.macSeal, h.macKeys.seal.publicKey.rawRepresentation)
            let devices = await h.host.pairedDevices
            try expectEqual(devices.map(\.deviceId), [mac.deviceId])
            try expectEqual(devices.first?.presence, h.presence.credential)
            let registered = await h.relay.hasDevice(h.account, mac.deviceId)
            try expect(registered)
        },
        TestCase("remote: emparejar cancelado, vencido, ranura ocupada o proof equivocado") {
            let h = try await RemoteHarness.make()
            // Cancelar en la Mac.
            let client = h.client()
            let qr = try await h.openPairing()
            async let join = h.nextJoin()
            _ = try await client.startPairing(qr: qr, presence: h.presence.credential)
            _ = try await join
            try await h.host.confirmPairing(false)
            let cancelled = try await within { () -> RemoteError? in
                do { _ = try await client.finishPairing(); return nil } catch let error as RemoteError { return error }
            }
            try expectEqual(cancelled, .pairingCancelled)
            // QR vencido.
            let late = try await h.openPairing()
            h.clock.advance(301)
            let expired = await { () -> RemoteError? in
                do { _ = try await h.client().startPairing(qr: late, presence: h.presence.credential); return nil }
                catch let error as RemoteError { return error } catch { return nil }
            }()
            try expectEqual(expired, .pairingExpired)
            // Un segundo teléfono en la ranura: rechazado y la ranura queda quemada.
            let busy = try await h.openPairing()
            async let firstJoin = h.nextJoin()
            _ = try await h.client().startPairing(qr: busy, presence: h.presence.credential)
            _ = try await firstJoin
            let events = h.host.events
            let second = await { () -> RemoteError? in
                do { _ = try await h.client().startPairing(qr: busy, presence: h.presence.credential); return nil }
                catch let error as RemoteError { return error } catch { return nil }
            }()
            try expectEqual(second, .pairingExpired)
            _ = try await within {
                for await event in events { if case .pairingEnded = event { return true } }
                return false
            }
            do {
                try await h.host.confirmPairing(true)
                throw TestFailure(description: "confirmó una ranura quemada")
            } catch is CommandFailure {}
            // Tres `proof` malos queman la ranura: el bueno después tampoco entra.
            let good = try await h.openPairing()
            var wrong = good
            wrong.secret = Data(repeating: 1, count: 32)
            for _ in 0..<3 {
                do {
                    _ = try await h.client().startPairing(qr: wrong, presence: h.presence.credential)
                    throw TestFailure(description: "entró con otro secreto")
                } catch RemoteError.pairingExpired {}
            }
            do {
                _ = try await h.client().startPairing(qr: good, presence: h.presence.credential)
                throw TestFailure(description: "la ranura no se quemó")
            } catch RemoteError.pairingExpired {}
        },
        TestCase("remote: sesión KK, comando con eventos en orden y respuesta") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let status = await client.status
            try expectEqual(status, .online)
            let hello = await client.macHello
            try expectEqual(hello?.macName, "Federico’s Mac")
            let policy = await client.presencePolicy
            try expect(policy.requirePresence && policy.gated.contains(.merge))
            var responses: [CommandResponse] = []
            for try await response in try await client.send(.status) { responses.append(response) }
            try expectEqual(responses.map(\.event), [.progress(message: "uno"), .text(delta: "dos"), nil])
            try expectEqual(responses.last?.result, .object(["ran": .string("status")]))
            let commands = await h.recorder.commands
            try expectEqual(commands, [.status])
        },
        TestCase("remote: política — denegado sin llamar al handler; merge pide Face ID de esta sesión") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let denied = try await client.run(.toolsSet(tool: .git, path: "/tmp/git"))
            try expectEqual(denied.error, CommandFailure(.unauthorized, RemotePolicy.deniedMessage))
            let merge = AppCommand.merge(pr: "a/b#1", method: nil, confirmed: true, expectedHeadOid: "abc")
            let bare = try await client.run(merge)
            try expectEqual(bare.error, CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))
            // Otra clave (no la registrada al emparejar).
            let impostor = try await client.run(merge, presence: SoftwareWebAuthnAuthenticator(rpId: "relay.test"))
            try expectEqual(impostor.error?.code, .unauthorized)
            var commands = await h.recorder.commands
            try expect(commands.isEmpty)
            let signed = try await client.run(merge, presence: h.presence)
            try expectEqual(signed.ok, true)
            commands = await h.recorder.commands
            try expectEqual(commands, [merge])
            // approve también, y un comment (todo lo que publica en GitHub como el usuario).
            let approve = AppCommand.reviewPublish(pr: "a/b#1", event: .approve, only: nil, withComments: true,
                                                   allInBody: false, confirmed: true)
            let approved = try await client.run(approve)
            try expectEqual(approved.error?.code, .unauthorized)
            let comment = AppCommand.reviewPublish(pr: "a/b#1", event: .comment, only: nil, withComments: true,
                                                   allInBody: false, confirmed: true)
            let commented = try await client.run(comment)
            try expectEqual(commented.error?.code, .unauthorized)
            let replies = try await client.run(.respondReplyOnly(pr: "a/b#1", confirmed: true, wait: false))
            try expectEqual(replies.error?.code, .unauthorized)
            commands = await h.recorder.commands
            try expectEqual(commands, [merge])
            let signedComment = try await client.run(comment, presence: h.presence)
            try expectEqual(signedComment.ok, true)
        },
        TestCase("remote: una prueba de presencia de otra sesión no sirve") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let merge = AppCommand.merge(pr: "a/b#1", method: nil, confirmed: true, expectedHeadOid: "abc")
            // Una passkey buena que firma el desafío de otra sesión.
            struct OtherSession: WebAuthnAuthenticator {
                let inner: SoftwareWebAuthnAuthenticator
                var credentialId: Data { inner.credentialId }
                func assert(challenge: Data) async throws -> WebAuthnAssertion {
                    var tampered = challenge
                    tampered[tampered.startIndex] ^= 1
                    return try await inner.assert(challenge: tampered)
                }
            }
            let response = try await client.run(merge, presence: OtherSession(inner: h.presence))
            try expectEqual(response.error, CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))
            // Una passkey del sitio equivocado (otro origen) tampoco.
            let wrongOrigin = SoftwareWebAuthnAuthenticator(rpId: "relay.test", key: h.presence.key,
                                                            credentialId: h.presence.credentialId,
                                                            origin: "https://evil.test")
            let evil = try await client.run(merge, presence: wrongOrigin)
            try expectEqual(evil.error, CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage))
            let commands = await h.recorder.commands
            try expect(commands.isEmpty)
        },
        TestCase("remote: emparejado sin passkey, todo lo gated pide volver a emparejar") {
            let h = try await RemoteHarness.make()
            let client = h.client()
            let qr = try await h.openPairing()
            async let join = h.nextJoin()
            _ = try await client.startPairing(qr: qr, presence: nil)
            _ = try await join
            let device = try await h.host.confirmPairing(true)
            try expect(device?.presence == nil)
            try expect(device?.requirePresence == true)
            _ = try await within { try await client.finishPairing() }
            try await client.connect()
            let merge = AppCommand.merge(pr: "a/b#1", method: nil, confirmed: true, expectedHeadOid: "abc")
            let bare = try await client.run(merge)
            try expectEqual(bare.error, CommandFailure(.unauthorized, RemotePolicy.presenceNotSetUpMessage))
            let signed = try await client.run(merge, presence: h.presence)
            try expectEqual(signed.error, CommandFailure(.unauthorized, RemotePolicy.presenceNotSetUpMessage))
            try expectEqual(RemotePolicy.presenceNotSetUpMessage, "Face ID isn't set up on this device. Pair it again.")
            let off = try await client.run(.remoteSetPresenceRequirement(device: "x", enabled: false))
            try expectEqual(off.error?.code, .unauthorized)
            let status = try await client.run(.status)
            try expectEqual(status.ok, true)
            let commands = await h.recorder.commands
            try expectEqual(commands, [.status])
        },
        TestCase("remote: una passkey de otro rpId no empareja") {
            let h = try await RemoteHarness.make()
            let qr = try await h.openPairing()
            let elsewhere = SoftwareWebAuthnAuthenticator(rpId: "evil.test")
            do {
                _ = try await h.client().startPairing(qr: qr, presence: elsewhere.credential)
                throw TestFailure(description: "emparejó con otro rpId")
            } catch let error as RemoteError {
                // La Mac quema la ranura (y se lo avisa al teléfono, o el handshake no llega).
                try expect(error == .pairingCancelled || error == .pairingExpired, "\(error)")
            }
            let devices = await h.host.pairedDevices
            try expect(devices.isEmpty)
        },
        TestCase("remote: un pedido de hace 121 s vence") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            // El teléfono cree que es 121 s antes: el relay "retuvo" el pedido.
            let stale = RemoteClient(configuration: .init(appVersion: "1.2.0", deviceName: "x", model: "y",
                                                          handshakeTimeout: .milliseconds(800)),
                                     paired: await client.paired, keys: await client.keys, linkFactory: h.factory,
                                     clock: { h.clock.now.addingTimeInterval(-121) })
            let response = try await stale.run(.status)
            try expectEqual(response.error, CommandFailure(.invalidState, "This request expired. Try again."))
            let commands = await h.recorder.commands
            try expect(commands.isEmpty)
        },
        TestCase("remote: un marco repetido por el relay cierra la sesión y el cliente sigue") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let first = try await client.run(.status)
            try expectEqual(first.ok, true)
            await h.relay.redeliverLastToMac(h.account)
            // El host cerró la sesión (bye): el cliente lo ve y el próximo comando hace otro handshake.
            let events = h.host.events
            _ = try await within {
                for await event in events { if case .sessionRejected = event { return true } }
                return false
            }
            var ok = false
            for _ in 0..<3 where !ok {
                ok = (try? await client.run(.refresh))?.ok == true
            }
            try expect(ok, "no se recuperó")
            let commands = await h.recorder.commands
            try expectEqual(commands, [.status, .refresh])
        },
        TestCase("remote: revocar cierra con 4403 y la Mac rechaza la estática vieja aunque el relay no obedezca") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            await h.host.revoke(paired.deviceId)
            try await eventually(3, "revoked") { await client.status == .revoked }
            do {
                _ = try await client.run(.status)
                throw TestFailure(description: "siguió andando")
            } catch RemoteError.revoked {}
            // Relay malicioso: no da de baja al dispositivo. El teléfono vuelve a entrar al relay, pero la Mac no
            // completa el KK con una estática que ya no conoce.
            let h2 = try await RemoteHarness.make()
            await h2.relay.setIgnoreDeviceRemoval(true)
            let client2 = try await h2.pairedClient()
            try await client2.connect()
            let paired2 = await client2.paired!
            let keys2 = await client2.keys!
            await h2.host.revoke(paired2.deviceId)
            let again = h2.client(paired: paired2, keys: keys2)
            do {
                try await again.connect()
                throw TestFailure(description: "la Mac aceptó una estática revocada")
            } catch RemoteError.handshakeFailed {}
            let commands = await h2.recorder.commands
            try expect(commands.isEmpty)
        },
        TestCase("remote: Mac offline — el cliente lo ve y send falla sin colgar") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            await h.host.disconnect()
            try await eventually(3, "mac offline") {
                if case .macOffline = await client.status { return true }
                return false
            }
            do {
                _ = try await within(3) { try await client.run(.status) }
                throw TestFailure(description: "mandó con la Mac offline")
            } catch RemoteError.macOffline {}
        },
        TestCase("remote: estado solo a suscritos, rev creciente y sub reemplaza") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let states = client.states
            await h.host.publish(topic: "home", data: .object(["n": .int(1)]))   // nadie suscrito todavía
            try await client.subscribe(["home"])
            // Al suscribirse llega el último valor.
            let initial = try await within {
                for await update in states { return update }
                throw TestFailure(description: "sin estado")
            }
            try expectEqual(initial, RemoteStateUpdate(topic: "home", rev: 1, data: .object(["n": .int(1)])))
            await h.host.publish(topic: "other", data: .int(9))                  // no suscrito: no llega
            await h.host.publish(topic: "home", data: .object(["n": .int(1)]))   // igual: no se manda
            await h.host.publish(topic: "home", data: .object(["n": .int(2)]))
            let received = try await within {
                for await update in states { return update }
                throw TestFailure(description: "sin estado")
            }
            try expectEqual(received, RemoteStateUpdate(topic: "home", rev: 2, data: .object(["n": .int(2)])))
            try await client.subscribe(["other"])
            let next = try await within {
                for await update in states { return update }
                throw TestFailure(description: "sin estado")
            }
            try expectEqual(next.topic, "other")
        },
        TestCase("remote: buzón cifrado; un rev viejo se ignora") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            await h.host.putMailbox(slot: "home", data: Data("v1".utf8))
            try await eventually(3, "buzón") { await h.relay.mailboxItem(h.account, device: paired.deviceId, slot: "home") != nil }
            let old = await h.relay.mailboxItem(h.account, device: paired.deviceId, slot: "home")!
            h.clock.advance(1)
            await h.host.putMailbox(slot: "home", data: Data("v2".utf8))
            try await eventually(3, "buzón v2") {
                await h.relay.mailboxItem(h.account, device: paired.deviceId, slot: "home") != old
            }
            let first = try await client.fetchMailbox()
            try expectEqual(first.map(\.data), [Data("v2".utf8)])
            await h.relay.replaceMailbox(h.account, device: paired.deviceId, slot: "home", b: old)
            let second = try await client.fetchMailbox()
            try expect(second.isEmpty, "aceptó un estado viejo")
            // Lo que no entra en un marco del relay no se guarda.
            let tooBig = await h.host.putMailbox(slot: "home", data: Data(count: 200 * 1024))
            try expectEqual(tooBig, .tooLarge)
            // Sin conexión no se manda nada y lo dice (M8).
            await h.host.disconnect()
            let offline = await h.host.putMailbox(slot: "home", data: Data("v3".utf8))
            try expectEqual(offline, .notConnected)
        },
        TestCase("remote: el teléfono registra su suscripción de Web Push en el relay") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            let p256dh = Data([4]) + Data(repeating: 7, count: 64)
            try await client.registerWebPush(endpoint: "https://web.push.apple.com/QGuQ", p256dh: p256dh,
                                             auth: Data(repeating: 1, count: 16))
            let relay = h.relay, account = h.account
            try await eventually(3, "suscripción") { await relay.subscription(account, paired.deviceId) != nil }
            let stored = await relay.subscription(account, paired.deviceId)
            try expectEqual(stored?.endpoint, "https://web.push.apple.com/QGuQ")
            try expectEqual(stored?.p256dh, p256dh)
            try expectEqual(stored?.auth, Data(repeating: 1, count: 16))
        },
        TestCase("remote: push con colapso e hilo opacos que el teléfono abre") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            let paired = await client.paired!
            let keys = await client.keys!
            let payload = PushPayload(createdAt: h.clock.now, kind: "approved", title: "acme/web#12", body: "Approved",
                                      threadId: "acme/web#12", pr: "acme/web#12", deepLink: "prbar://pr/acme/web/12")
            let status = try await h.host.push(payload, to: paired.deviceId)
            try expectEqual(status, 200)
            let pushes = await h.relay.pushes
            guard case .push(_, let to, let collapse, let thread, let b)? = pushes.first else {
                throw TestFailure(description: "sin push")
            }
            try expectEqual(to, paired.deviceId)
            try expect(collapse.count == 64 && thread.count == 32 && !collapse.contains("acme") && !thread.contains("acme"))
            let ids = try PushIdentifiers(devicePush: keys.push,
                                          macSeal: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: paired.macSeal))
            try expectEqual(collapse, ids.collapse(kind: "approved", pr: "acme/web#12"))
            let opened = try PushPayload.open(pushField: Base64URL.encode(b), by: keys.push,
                                              from: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: paired.macSeal),
                                              info: SealedInfo.push(account: paired.accountId, device: paired.deviceId))
            try expectEqual(opened, payload)
        },
        TestCase("remote: un resultado de 5 MiB vuelve entero") {
            let big = String(repeating: "abcdefghij", count: 5 * 1024 * 1024 / 10)
            let h = try await RemoteHarness.make(handler: { _, _ in .success(.string(big)) })
            let client = try await h.pairedClient()
            try await client.connect()
            let response = try await within(20) { try await client.run(.status) }
            try expectEqual(response.result, .string(big))
        },
        TestCase("remote: versiones fuera de rango") {
            let h = try await RemoteHarness.make(minimumRemoteVersion: CommandProtocol.version)
            let old = try await h.pairedClient(commandProtocol: CommandProtocol.version - 1)
            do {
                try await old.connect()
                throw TestFailure(description: "aceptó un iPhone viejo")
            } catch RemoteError.incompatible(.updateIPhone) {}
            let new = try await h.pairedClient(commandProtocol: CommandProtocol.version + 1)
            do {
                try await new.connect()
                throw TestFailure(description: "aceptó un iPhone más nuevo que la Mac")
            } catch RemoteError.incompatible(.updateMac) {}
        },
    ]
}
