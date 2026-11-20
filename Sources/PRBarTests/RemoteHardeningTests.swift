import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit

/// Una compuerta que los tests abren a mano (handlers que se quedan esperando).
actor RemoteGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func wait() async {
        entered += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Los arreglos de la revisión de cifrado del Plan 17 (spec P.14, "Revisión de seguridad") y los límites de la Mac.
enum RemoteHardeningTests {
    static let cases: [TestCase] = [
        TestCase("remote hardening: un undeliverable falso a pair:<id> después de emparejar no borra el dispositivo (M1)") {
            let h = try await RemoteHarness.make()
            let client = h.client()
            let qr = try await h.openPairing()
            async let join = h.nextJoin()
            _ = try await client.startPairing(qr: qr, presenceKey: h.presence.publicKey)
            _ = try await join
            try await h.host.confirmPairing(true)
            _ = try await within { try await client.finishPairing() }
            try await client.connect()
            await h.relay.injectToMac(h.account, .undeliverable(to: "pair:\(qr.pairingId)", sid: "0123456789abcdef"))
            try await Task.sleep(for: .milliseconds(200))
            let devices = await h.host.pairedDevices
            try expectEqual(devices.count, 1)
            let response = try await client.run(.status)
            try expectEqual(response.ok, true)
        },
        TestCase("remote hardening: sin el acuse del teléfono la Mac no guarda el dispositivo (M1)") {
            let h = try await RemoteHarness.make(pairingAckTimeout: .milliseconds(500))
            // El relay deja pasar el handshake y el `confirm`, pero no el acuse del resultado.
            await h.relay.setPairForwardLimit(2)
            let client = h.client()
            let qr = try await h.openPairing()
            async let join = h.nextJoin()
            _ = try await client.startPairing(qr: qr, presenceKey: h.presence.publicKey)
            _ = try await join
            do {
                try await h.host.confirmPairing(true)
                throw TestFailure(description: "guardó un dispositivo sin acuse")
            } catch let failure as CommandFailure {
                try expectEqual(failure.code, .failed)
            }
            let devices = await h.host.pairedDevices
            try expect(devices.isEmpty)
            let mac = try await within { try await client.finishPairing() }
            try await eventually(3, "baja en el relay") { await !h.relay.hasDevice(h.account, mac.deviceId) }
        },
        TestCase("remote hardening: el estado y las respuestas grandes no se comprimen (M2)") {
            let big = String(repeating: "a", count: 100_000)
            let h = try await RemoteHarness.make(handler: { _, _ in .success(.string(big)) })
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            let before = await h.relay.bytesToDevice[paired.deviceId, default: 0]
            await h.host.publish(topic: "home", data: .string(big))
            try await client.subscribe(["home"])
            let states = client.states
            _ = try await within { for await update in states { return update }; throw TestFailure(description: "sin estado") }
            let afterState = await h.relay.bytesToDevice[paired.deviceId, default: 0]
            try expect(afterState - before >= 100_000, "el estado viajó comprimido (\(afterState - before) bytes)")
            _ = try await client.run(.status)
            let afterResult = await h.relay.bytesToDevice[paired.deviceId, default: 0]
            try expect(afterResult - afterState >= 100_000, "la respuesta viajó comprimida")
        },
        TestCase("remote hardening: un 4403 del relay sin bye de la Mac no revoca ni borra el emparejamiento (M3)") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            await h.relay.closeDevice(h.account, paired.deviceId, code: 4403)
            try await eventually(3, "relayRejected") { await client.status == .relayRejected }
            let keys = await client.keys
            try expect(keys != nil)
            // El dispositivo sigue registrado en el relay: la próxima operación reconecta.
            let response = try await client.run(.status)
            try expectEqual(response.ok, true)
        },
        TestCase("remote hardening: un 4401 al conectar no es una revocación (M3)") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            let keys = await client.keys!
            await h.relay.forgetDevice(h.account, paired.deviceId)
            let again = h.client(paired: paired, keys: keys)
            do {
                try await again.connect()
                throw TestFailure(description: "conectó")
            } catch RemoteError.relayRejected {}
            let status = await again.status
            try expectEqual(status, .relayRejected)
            let stillPaired = await again.paired
            try expect(stillPaired != nil)
        },
        TestCase("remote hardening: después de reiniciar la Mac el teléfono acepta el rev 1 de nuevo (L1)") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            try await client.subscribe(["home"])
            let states = client.states
            for n in 1...3 {
                await h.host.publish(topic: "home", data: .int(n))
                _ = try await within { for await update in states { return update }; throw TestFailure(description: "sin estado") }
            }
            let devices = await h.host.pairedDevices
            await h.host.disconnect()
            let restarted = RemoteHost(
                configuration: .init(accountId: h.account, relayHost: h.relay.host, macName: "Federico’s Mac",
                                     appVersion: "1.2.0", keys: h.macKeys, backoff: { _ in .milliseconds(50) }),
                devices: devices, linkFactory: h.factory, clock: h.clock.function, handler: { _, _ in .success(.ok) })
            try await restarted.connect()
            await restarted.publish(topic: "home", data: .int(42))
            try await eventually(3, "mac online") {
                if case .macOffline = await client.status { return false }
                return true
            }
            try await client.subscribe(["home"])
            let update = try await within { for await update in states { return update }; throw TestFailure(description: "sin estado") }
            try expectEqual(update.data, .int(42))
            try expectEqual(update.rev, 1)
        },
        TestCase("remote hardening: un primer mensaje de KK repetido no reemplaza la sesión viva (L2)") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            let paired = await client.paired!
            let delivered = await h.relay.deliveredToMac
            guard case .recv(_, _, let first)? = delivered.first(where: {
                if case .recv(let from, _, _) = $0 { return from == paired.deviceId }
                return false
            }) else { throw TestFailure(description: "sin handshake") }
            await h.relay.injectToMac(h.account, .recv(from: paired.deviceId, sid: "00112233445566ff", b: first))
            try await Task.sleep(for: .milliseconds(200))
            let response = try await within(3) { try await client.run(.status) }
            try expectEqual(response.ok, true)
        },
        TestCase("remote hardening: la Mac no ejecuta un pedido pasado el plazo del teléfono (L3)") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            try await client.connect()
            // El teléfono espera 30 s; el pedido llega 40 s después (dentro de los 120 s de antes, pero ya vencido).
            let late = RemoteClient(configuration: .init(appVersion: "1.2.0", deviceName: "x", model: "y",
                                                         handshakeTimeout: .seconds(3), requestTimeout: .seconds(30)),
                                    paired: await client.paired, keys: await client.keys, linkFactory: h.factory,
                                    clock: { h.clock.now.addingTimeInterval(-40) })
            let response = try await late.run(.status)
            try expectEqual(response.error, CommandFailure(.invalidState, "This request expired. Try again."))
            let commands = await h.recorder.commands
            try expect(commands.isEmpty)
        },
        TestCase("remote hardening: tope de pedidos en curso por sesión") {
            let gate = RemoteGate()
            var limits = RemoteLimits.standard
            limits.maxConcurrentRequests = 3
            let h = try await RemoteHarness.make(limits: limits, handler: { _, _ in
                await gate.wait()
                return .success(.ok)
            })
            let client = try await h.pairedClient()
            try await client.connect()
            var streams: [AsyncThrowingStream<CommandResponse, Error>] = []
            for _ in 0..<3 { streams.append(try await client.send(.refresh)) }
            try await eventually(3, "tres en curso") { await gate.entered == 3 }
            let fourth = try await client.run(.status)
            try expectEqual(fourth.error?.code, .invalidState)
            try expect(fourth.error?.message.contains("Too many requests") == true)
            await gate.release()
            for stream in streams {
                for try await response in stream where response.event == nil { try expectEqual(response.ok, true) }
            }
            let after = try await client.run(.status)
            try expectEqual(after.ok, true)
        },
        TestCase("remote hardening: tope de pedidos por segundo por dispositivo") {
            var limits = RemoteLimits.standard
            limits.requestBurst = 5
            limits.requestsPerSecond = 1
            let h = try await RemoteHarness.make(limits: limits)
            let client = try await h.pairedClient()
            try await client.connect()
            for _ in 0..<5 {
                let response = try await client.run(.status)
                try expectEqual(response.ok, true)
            }
            let limited = try await client.run(.status)
            try expect(limited.error?.message.contains("Too many requests") == true, "\(limited)")
            h.clock.advance(3)
            let later = try await client.run(.status)
            try expectEqual(later.ok, true)
        },
        TestCase("remote hardening: tope de handshakes por dispositivo (un relay que repite el primer mensaje)") {
            var limits = RemoteLimits.standard
            limits.handshakeBurst = 3
            limits.handshakesPerMinute = 3
            let h = try await RemoteHarness.make(limits: limits)
            let client = try await h.pairedClient()
            try await client.connect()                                     // 1 handshake
            let paired = await client.paired!
            let delivered = await h.relay.deliveredToMac
            guard case .recv(_, _, let first)? = delivered.first(where: {
                if case .recv(let from, _, _) = $0 { return from == paired.deviceId }
                return false
            }) else { throw TestFailure(description: "sin handshake") }
            let before = await h.relay.framesToDevice[paired.deviceId, default: 0]
            for index in 0..<10 {
                let sid = String(format: "%016x", 0xabc000 + index)
                await h.relay.injectToMac(h.account, .recv(from: paired.deviceId, sid: sid, b: first))
            }
            try await Task.sleep(for: .milliseconds(300))
            let replies = await h.relay.framesToDevice[paired.deviceId, default: 0] - before
            // Solo 2 más (3 en total): el resto ni siquiera hace Diffie-Hellman. Las respuestas a un sid desconocido
            // las descarta el teléfono.
            try expectEqual(replies, 2)
            let response = try await client.run(.status)
            try expectEqual(response.ok, true)
        },
        TestCase("remote host: el handler recibe el dispositivo; tópicos suscritos y chatDelta solo a pr:<id>") {
            let seen = CommandRecorder()
            let clock = RemoteTestClock()
            let relay = InMemoryRelay(clock: clock.function)
            let keys = MacKeys()
            let account = await relay.enroll(macKey: keys.relay.publicKey)
            actor Names { var names: [String] = []; func add(_ n: String) { names.append(n) } }
            let names = Names()
            let host = RemoteHost(
                configuration: .init(accountId: account, relayHost: relay.host, macName: "Mac", appVersion: "1.2.0",
                                     keys: keys, backoff: { _ in .milliseconds(50) }),
                devices: [], linkFactory: relay.factory(), clock: clock.function,
                deviceHandler: { command, device, _ in
                    await seen.record(command)
                    await names.add(device.name)
                    return .success(.ok)
                })
            try await host.connect()
            let h = RemoteHarness(relay: relay, clock: clock, macKeys: keys, account: account, host: host,
                                  recorder: seen, factory: relay.factory())
            let client = try await h.pairedClient()
            try await client.connect()
            _ = try await client.run(.status)
            let called = await names.names
            try expectEqual(called, ["Federico’s iPhone"])
            let events = host.events
            try await client.subscribe(["home", "pr:acme/api#1"])
            let topics = try await within {
                for await event in events { if case .subscriptionsChanged(let topics) = event { return topics } }
                throw TestFailure(description: "sin evento")
            }
            try expectEqual(topics, ["home", "pr:acme/api#1"])
            let subscribed = await host.subscribedTopics
            try expectEqual(subscribed, ["home", "pr:acme/api#1"])
            let deltas = client.chatDeltas
            await host.sendChatDelta(pr: "acme/api#2", text: "nope")
            await host.sendChatDelta(pr: "acme/api#1", text: "hola")
            let delta = try await within { for await delta in deltas { return delta }; throw TestFailure(description: "sin delta") }
            try expectEqual(delta, RemoteChatDelta(pr: "acme/api#1", text: "hola"))
        },
    ]
}
