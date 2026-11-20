import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

/// `AppConfig.remote` en memoria.
@MainActor
final class MemoryRemoteSettings: RemoteSettingsStore {
    var remoteSettings = RemoteSettings()
    func updateRemoteSettings(_ mutate: (inout RemoteSettings) -> Void) throws { mutate(&remoteSettings) }
}

/// Inscripción contra el relay en memoria: acepta solo `good-token`.
struct FakeEnroller: RelayEnrolling {
    let relay: InMemoryRelay
    func enroll(host: String, token: String, macRelayKey: Data) async throws -> String {
        guard token == "good-token" else { throw URLSessionRelayEnroller.failure(status: 403) }
        return await relay.enroll(macKey: try Curve25519.Signing.PublicKey(rawRepresentation: macRelayKey))
    }
}

final class FakePower: PowerSourceReading {
    var isOnACPower = true
    var onChange: (@MainActor () -> Void)?
    func startObserving(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
}

final class FakeAssertions: SleepAssertionTaking {
    private(set) var taken: [String] = []
    private(set) var held: Set<UInt32> = []
    private var next: UInt32 = 1
    func take(name: String) -> UInt32? {
        taken.append(name)
        defer { next += 1 }
        held.insert(next)
        return next
    }
    func release(_ id: UInt32) { held.remove(id) }
}

/// El servicio de la Mac + relay en memoria + `FakeActions` + teléfonos simulados.
@MainActor
struct ServiceHarness {
    let relay: InMemoryRelay
    let clock: RemoteTestClock
    let settings: MemoryRemoteSettings
    let secrets: FakeSecrets
    let service: RemoteAccessService
    let actions: FakeActions
    let presence = SoftwarePresenceSigner()
    let devicesDir: URL

    static func make(keepAwake: KeepAwake? = nil, enabled: Bool = true) async throws -> ServiceHarness {
        let clock = RemoteTestClock()
        let relay = InMemoryRelay(clock: clock.function)
        let settings = MemoryRemoteSettings()
        let secrets = FakeSecrets()
        let dir = try temporaryDirectory().appendingPathComponent("remote")
        let env = RemoteServiceEnvironment(
            keys: RemoteKeyStore(secrets: secrets), devices: RemoteDeviceStore(directory: dir),
            enroller: FakeEnroller(relay: relay), linkFactory: { _ in relay.factory() }, macName: "Federico’s Mac",
            appVersion: "1.3.0", clock: clock.function,
            tune: { config in
                config.backoff = { _ in .milliseconds(50) }
                config.pushTimeout = .seconds(2)
                config.pairingAckTimeout = .seconds(3)
            },
            keepAwake: keepAwake, connectBackoff: { _ in .milliseconds(50) }, mailboxInterval: .seconds(3600),
            feedDebounce: .milliseconds(50), activityInterval: .milliseconds(200))
        let service = RemoteAccessService(settings: settings, environment: env)
        let actions = FakeActions()
        service.actions = actions
        let harness = ServiceHarness(relay: relay, clock: clock, settings: settings, secrets: secrets, service: service,
                                     actions: actions, devicesDir: dir)
        if enabled {
            _ = try await service.enable(relay: relay.host, enrollToken: "good-token")
            try await harness.waitConnected()
        }
        return harness
    }

    func waitConnected() async throws {
        let service = service
        try await eventually(5, "connected") { await service.state == .connected }
    }

    var account: String { settings.remoteSettings.accountId ?? "" }

    func client(paired: PairedMac? = nil, keys: DeviceKeys? = nil, name: String = "Federico’s iPhone") -> RemoteClient {
        RemoteClient(configuration: .init(appVersion: "1.3.0", deviceName: name, model: "iPhone 17 Pro",
                                          handshakeTimeout: .seconds(3), requestTimeout: .seconds(10)),
                     paired: paired, keys: keys, linkFactory: relay.factory(), clock: clock.function)
    }

    /// Empareja un teléfono por el servicio (QR → código → Codes Match) y conecta su sesión.
    func pair(name: String = "Federico’s iPhone", presence: SoftwarePresenceSigner? = nil) async throws -> RemoteClient {
        let client = client(name: name)
        let info = try await service.pairStart()
        let relay = relay, account = account
        try await eventually(3, "ranura") { await relay.pairingSlot(account) == info.pairing }
        let qr = try PairingQR(url: info.qr)
        let sas = try await client.startPairing(qr: qr, presenceKey: (presence ?? self.presence).publicKey)
        let joined = try await service.pairWait(pairing: info.pairing, events: { _ in })
        try expectEqual(joined.code?.replacingOccurrences(of: " ", with: ""), sas)
        try expectEqual(joined.deviceName, name)
        let result = try await service.pairConfirm(pairing: info.pairing, accepted: true)
        try expect(result.device != nil)
        _ = try await within { try await client.finishPairing() }
        try await client.connect()
        return client
    }
}

enum RemoteBridgeTests {
    static let cases: [TestCase] = [
        TestCase("remote service: habilitar con token → conectado; el relay corta → offline → reconecta; disable no reintenta") {
            try await connection()
        },
        TestCase("remote service: un token rechazado no habilita nada") { try await badToken() },
        TestCase("remote service: emparejar guarda las tres claves con Face ID; Cancel no guarda; un segundo pair cancela el primero") {
            try await pairing()
        },
        TestCase("remote bridge: status por el teléfono = lo de la CLI; reviewStart --wait manda los eventos en orden") {
            try await bridgeSameAsCLI()
        },
        TestCase("remote bridge: cada comando denegado contesta unauthorized sin llamar a la app") { try await bridgeDenied() },
        TestCase("remote bridge: merge pide Face ID; confirmed sigue valiendo; sin requirePresence pasa") { try await bridgeMerge() },
        TestCase("remote bridge: Face ID solo cambia al propio teléfono, apagarlo pide Face ID; el log no tiene argumentos") {
            try await bridgePresence()
        },
        TestCase("remote bridge: re-verifica la política aunque el host se la saltee") { try await bridgeDefense() },
        TestCase("remote bridge: sin Face ID ningún comando del teléfono corre tests ni push en la Mac (H1)") {
            try await bridgeNoTestsWithoutPresence()
        },
        TestCase("remote bridge: ni rutas locales ni herramientas llegan al teléfono") { try await bridgeRedaction() },
        TestCase("remote feed: un cambio durante el tick de activity igual recalcula home (M4)") { try await feedCoalesces() },
        TestCase("remote feed: home al suscribirse, rev nuevo al cambiar la app, nada si no cambió; pr:<id> y activity") {
            try await feed()
        },
        TestCase("remote mailbox: un home por dispositivo, abrible por cada uno; sin cambios nada; apagado vacía el slot") {
            try await mailbox()
        },
        TestCase("remote push: misma notificación cifrada; 410 marca notificaciones apagadas") { try await push() },
        TestCase("remote service: revocar, reset y app link") { try await revokeResetAppLink() },
        TestCase("remote keep awake: en corriente toma una aserción, en batería o al deshabilitar la suelta") { try await keepAwake() },
    ]

    @MainActor
    static func connection() async throws {
        let h = try await ServiceHarness.make()
        try expect(h.settings.remoteSettings.enabled)
        try expectEqual(h.settings.remoteSettings.relayHost, h.relay.host)
        try expect(!h.account.isEmpty)
        try expectEqual(h.service.status().state, "connected")
        await h.relay.closeMac(h.account)
        try await eventually(3, "offline") {
            if case .offline = await h.service.state { return true }
            return false
        }
        try await h.waitConnected()
        _ = try await h.service.disable()
        try expectEqual(h.service.state, .disabled)
        try expect(!h.settings.remoteSettings.enabled)
        try await Task.sleep(for: .milliseconds(300))
        try expectEqual(h.service.state, .disabled)
        // Volver a habilitar el mismo relay no pide el token.
        _ = try await h.service.enable(relay: h.relay.host, enrollToken: "")
        try await h.waitConnected()
    }

    @MainActor
    static func badToken() async throws {
        let h = try await ServiceHarness.make(enabled: false)
        do {
            _ = try await h.service.enable(relay: h.relay.host, enrollToken: "nope")
            throw TestFailure(description: "habilitó")
        } catch let failure as CommandFailure {
            try expectEqual(failure.message, "The relay refused the enrollment token.")
        }
        try expect(!h.settings.remoteSettings.enabled)
        try expectEqual(h.settings.remoteSettings.accountId, nil)
        try expectEqual(h.service.state, .disabled)
        do {
            _ = try await h.service.enable(relay: "http://evil/x", enrollToken: "good-token")
            throw TestFailure(description: "aceptó un host malo")
        } catch let failure as CommandFailure {
            try expectEqual(failure.code, .invalidUsage)
        }
    }

    @MainActor
    static func pairing() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        let paired = await client.paired!
        try expectEqual(h.service.devices.map(\.device.deviceId), [paired.deviceId])
        let stored = h.service.devices[0].device
        try expect(stored.requirePresence)
        try expectEqual(stored.presence, h.presence.publicKey)
        try expect(stored.noise.count == 32 && stored.push.count == 32)
        let registered = await h.relay.hasDevice(h.account, paired.deviceId)
        try expect(registered)
        try expectEqual(RemoteDeviceStore(directory: h.devicesDir).devices.count, 1)
        // Cancel: nada guardado.
        let other = h.client(name: "Old iPhone")
        let info = try await h.service.pairStart()
        let relay = h.relay, account = h.account
        try await eventually(3, "ranura") { await relay.pairingSlot(account) == info.pairing }
        _ = try await other.startPairing(qr: try PairingQR(url: info.qr), presenceKey: h.presence.publicKey)
        _ = try await h.service.pairWait(pairing: info.pairing, events: { _ in })
        let cancelled = try await h.service.pairConfirm(pairing: info.pairing, accepted: false)
        try expectEqual(cancelled.device, nil)
        try expectEqual(h.service.devices.count, 1)
        try expectEqual(h.service.pairing, nil)
        // Un segundo pair cancela el primero (quien esperaba el primero se entera).
        let first = try await h.service.pairStart()
        let waiter = Task { @MainActor in try await h.service.pairWait(pairing: first.pairing, events: { _ in }) }
        try await Task.sleep(for: .milliseconds(50))
        let second = try await h.service.pairStart()
        try expect(second.pairing != first.pairing)
        do {
            _ = try await waiter.value
            throw TestFailure(description: "el primero siguió esperando")
        } catch is CommandFailure {}
        _ = try await h.service.pairConfirm(pairing: second.pairing, accepted: false)
    }

    @MainActor
    static func bridgeSameAsCLI() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        h.actions.calls = []
        let response = try await client.run(.status)
        try expectEqual(h.actions.calls, ["status"])
        let cli = await CommandDispatcher.run(.status, on: FakeActions(), events: { _ in })
        try expectEqual(response.result, try cli.get())
        h.actions.waitEvents = [.progress(message: "Queued"), .progress(message: "Reviewing…")]
        var events: [CommandEvent] = []
        var final: CommandResponse?
        for try await item in try await client.send(.reviewStart(pr: "acme/api#1", wait: true)) {
            if let event = item.event { events.append(event) } else { final = item }
        }
        try expectEqual(events, h.actions.waitEvents)
        try expectEqual(final?.ok, true)
    }

    @MainActor
    static func bridgeDenied() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        h.actions.calls = []
        let denied = dispatchSamples.map(\.command).filter { RemotePolicy.decide($0) == .denied }
        try expect(denied.count > 50)
        for command in denied {
            h.clock.advance(1)      // por debajo del tope de pedidos por segundo
            let response = try await client.run(command)
            try expectEqual(response.error, CommandFailure(.unauthorized, RemotePolicy.deniedMessage))
        }
        try expectEqual(h.actions.calls, [])
    }

    @MainActor
    static func bridgeMerge() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        h.actions.calls = []
        let merge = AppCommand.merge(pr: "acme/api#4", method: nil, confirmed: true, expectedHeadOid: "c0ffee")
        let bare = try await client.run(merge)
        try expectEqual(bare.error, CommandFailure(.unauthorized, "Face ID is required for this on iPhone."))
        try expectEqual(h.actions.calls, [])
        let signed = try await client.run(merge, presence: h.presence)
        try expectEqual(signed.ok, true)
        try expectEqual(h.actions.calls, ["merge acme/api#4 default head=c0ffee"])
        let unconfirmed = AppCommand.merge(pr: "acme/api#4", method: nil, confirmed: false, expectedHeadOid: "c0ffee")
        let needsYes = try await client.run(unconfirmed, presence: h.presence)
        try expectEqual(needsYes.error?.code, .confirmationRequired)
        // Sin Face ID requerido para este teléfono, merge pasa sin prueba.
        let id = await client.paired!.deviceId
        _ = try await h.service.setPresenceRequirement(id, enabled: false)
        h.actions.calls = []
        let plain = try await client.run(merge)
        try expectEqual(plain.ok, true)
        try expectEqual(h.actions.calls.count, 1)
    }

    @MainActor
    static func bridgePresence() async throws {
        let h = try await ServiceHarness.make()
        let mine = try await h.pair()
        let otherSigner = SoftwarePresenceSigner()
        let other = try await h.pair(name: "Work iPhone", presence: otherSigner)
        let mineId = await mine.paired!.deviceId
        let otherId = await other.paired!.deviceId
        // Apagar Face ID es gated: sin prueba no.
        let bare = try await mine.run(.remoteSetPresenceRequirement(device: otherId, enabled: false))
        try expectEqual(bare.error?.code, .unauthorized)
        // Con prueba: llega a la app (como `prbar remote devices --require-face-id`) con SU dispositivo, no el que nombró.
        h.actions.calls = []
        let signed = try await mine.run(.remoteSetPresenceRequirement(device: otherId, enabled: false), presence: h.presence)
        try expectEqual(signed.ok, true)
        try expectEqual(h.actions.calls, ["remoteSetPresenceRequirement \(mineId) false"])
        // Prenderlo no pide Face ID.
        let on = try await mine.run(.remoteSetPresenceRequirement(device: otherId, enabled: true))
        try expectEqual(on.ok, true)
        try expectEqual(h.actions.calls.last, "remoteSetPresenceRequirement \(mineId) true")
        // Lo que hace la app con eso: el servicio guarda y avisa al teléfono (`presencePolicy`).
        _ = try await h.service.setPresenceRequirement(mineId, enabled: false)
        try expectEqual(h.service.devices.first { $0.device.deviceId == mineId }?.device.requirePresence, false)
        try expectEqual(h.service.devices.first { $0.device.deviceId == otherId }?.device.requirePresence, true)
        try await eventually(3, "presencePolicy") { await mine.presencePolicy.requirePresence == false }
        // El log: el nombre del comando con el prefijo del id, nunca el PR ni los argumentos.
        _ = try await mine.run(.reviewShow(pr: "acme/secret-repo#99"))
        let log = (try? String(contentsOf: TestEnvironment.logFile, encoding: .utf8)) ?? ""
        try expect(log.contains("iPhone \(mineId.prefix(4)): reviewShow"), "sin la línea del log")
        try expect(!log.contains("secret-repo"), "el log tiene argumentos")
    }

    @MainActor
    static func bridgeDefense() async throws {
        let h = try await ServiceHarness.make()
        _ = try await h.pair()
        h.actions.calls = []
        let device = h.service.devices[0].device
        let result = await h.service.handleRemote(.toolsSet(tool: .git, path: "/tmp/git"),
                                                  caller: RemoteCaller(device: device, presenceVerified: false), events: { _ in })
        try expectEqual(result, .failure(CommandFailure(.unauthorized, RemotePolicy.deniedMessage)))
        try expectEqual(h.actions.calls, [])
        // Aunque el host la dejara pasar sin prueba: tests y push no llegan a la app (H1).
        for command in [AppCommand.respondTest(pr: "acme/api#4", wait: false), .respondPush(pr: "acme/api#4", confirmed: true, wait: false),
                        .respondPushAnyway(pr: "acme/api#4", confirmed: true, wait: false)] {
            let refused = await h.service.handleRemote(command, caller: RemoteCaller(device: device, presenceVerified: false),
                                                       events: { _ in })
            try expectEqual(refused, .failure(CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage)))
        }
        try expectEqual(h.actions.calls, [])
        _ = await h.service.handleRemote(.respondTest(pr: "acme/api#4", wait: false),
                                         caller: RemoteCaller(device: device, presenceVerified: true), events: { _ in })
        try expect(h.actions.calls.contains("respondTest acme/api#4 wait=false"))
        try expectEqual(h.actions.origins(of: ["respondTest"]), [.phone(device: device.deviceId, mayRunRepoCode: true)])
    }

    /// H1: un teléfono sin Face ID no puede hacer que la Mac corra los tests (ni push) por ningún comando. Todo lo que
    /// puede mandar sin prueba llega a la app como `CommandOrigin.phone(mayRunRepoCode: false)`, y Core no arranca tests
    /// ni push con ese origen (`RespondQueueTests`).
    @MainActor
    static func bridgeNoTestsWithoutPresence() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        let id = await client.paired!.deviceId
        h.actions.calls = []
        // Los que ejecutan código del repo piden Face ID y no llegan a la app sin la prueba.
        for command in [AppCommand.respondTest(pr: "acme/api#4", wait: true), .respondPush(pr: "acme/api#4", confirmed: true, wait: false),
                        .respondPushAnyway(pr: "acme/api#4", confirmed: true, wait: false)] {
            let bare = try await client.run(command)
            try expect(bare.error == CommandFailure(.unauthorized, RemotePolicy.presenceRequiredMessage), "\(command.name)")
        }
        try expectEqual(h.actions.calls, [])
        // Lo que edita el worktree (implementar, chat, undo, Fix CI) pasa sin Face ID, pero marcado: Core no corre nada.
        for command in [AppCommand.respondImplement(pr: "acme/api#4", wait: false),
                        .chatSend(pr: "acme/api#4", message: "change package.json"),
                        .chatUndo(pr: "acme/api#4", confirmed: true), .ciFix(pr: "acme/api#4", wait: false)] {
            _ = try await client.run(command)
        }
        let edits = h.actions.origins(of: ["respondImplement", "chatSend", "chatUndo", "ciFix"])
        try expectEqual(edits.count, 4)
        try expect(edits.allSatisfy { $0 == .phone(device: id, mayRunRepoCode: false) }, "\(edits)")
        try expect(!h.actions.calls.contains { $0.hasPrefix("respondTest") || $0.hasPrefix("respondPush") })
        // Con la prueba, sí (y el origen lo dice).
        let signed = try await client.run(.respondTest(pr: "acme/api#4", wait: false), presence: h.presence)
        try expectEqual(signed.ok, true)
        try expectEqual(h.actions.origins(of: ["respondTest"]), [.phone(device: id, mayRunRepoCode: true)])
        // "Require Face ID" apagado para este iPhone en la Mac: elección del usuario (como merge y push).
        _ = try await h.service.setPresenceRequirement(id, enabled: false)
        h.actions.calls = []
        _ = try await client.run(.respondTest(pr: "acme/api#4", wait: false))
        try expectEqual(h.actions.origins(of: ["respondTest"]), [.phone(device: id, mayRunRepoCode: true)])
    }

    @MainActor
    static func bridgeRedaction() async throws {
        let raw = JSONValue.object([
            "tools": .array([.object(["name": .string("git"), "path": .string("/Users/fede/bin/git")])]),
            "logPath": .string("/Users/fede/Library/Logs/PRBar/review-1.log"),
            "nested": .array([.object(["worktree": .string("/private/tmp/PRBar/worktrees/api-1")])]),
            "title": .string("/not/a/path/key"),
        ])
        let scrubbed = RemoteRedaction.scrub(raw)
        try expectEqual(scrubbed, .object([
            "tools": .array([]),
            "logPath": .string("review-1.log"),
            "nested": .array([.object(["worktree": .string("api-1")])]),
            "title": .string("/not/a/path/key"),
        ]))
        let decoded: StatusInfo = try RemoteRedaction.scrub(try JSONValue(encoding: StatusInfo(
            appVersion: "1", tools: [ToolInfo(name: "git", path: "/usr/bin/git", custom: false)]))).decode()
        try expect(decoded.tools.isEmpty)
    }

    /// M4: un cambio de la app mientras corre el tick de `activity` (lento) igual recalcula `home` y `pr:`.
    @MainActor
    static func feedCoalesces() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        let states = client.states
        try await client.subscribe(["home", "activity"])
        _ = try await within(5) {
            for await update in states where update.topic == "home" { return update }
            throw TestFailure(description: "sin home")
        }
        h.actions.resourcesDelay = .milliseconds(400)
        h.actions.calls = []
        // Espera a que el timer de activity esté adentro de `resources()`.
        let actions = h.actions
        try await eventually(3, "tick de activity") { await actions.calls.contains("resources") }
        h.actions.statusVersion = "during-activity"
        await h.service.recomputeState()
        let next = try await within(5) {
            for await update in states where update.topic == "home" { return update }
            throw TestFailure(description: "sin home")
        }
        try expectEqual((try next.data.decode() as RemoteHome).status.appVersion, "during-activity")
    }

    @MainActor
    static func feed() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        let states = client.states
        try await client.subscribe(["home", "pr:acme/api#1", "activity", "bogus"])
        let seen = try await within(5) { () -> [String: RemoteStateUpdate] in
            var seen: [String: RemoteStateUpdate] = [:]
            for await update in states {
                seen[update.topic] = update
                if seen.count == 3 { return seen }
            }
            throw TestFailure(description: "fin")
        }
        let home: RemoteHome = try seen["home"]!.data.decode()
        try expectEqual(home.status.appVersion, "test")
        try expectEqual(home.ci.first?.pr, "acme/api#12")
        let detail: RemotePRDetail = try seen["pr:acme/api#1"]!.data.decode()
        try expectEqual(detail.review?.pr, "acme/api#1")
        let activity: RemoteActivity = try seen["activity"]!.data.decode()
        try expectEqual(activity.usage?.month.month, "2026-11")
        let homeRev = seen["home"]!.rev
        // Cambia la app → rev nuevo.
        h.actions.statusVersion = "changed"
        h.service.stateChanged()
        let next = try await within(5) {
            for await update in states where update.topic == "home" { return update }
            throw TestFailure(description: "sin home")
        }
        try expect(next.rev > homeRev)
        try expectEqual((try next.data.decode() as RemoteHome).status.appVersion, "changed")
        // Sin cambios: nada de home en 1 s (activity sí puede llegar por su timer, pero igual a la anterior no se manda).
        h.service.stateChanged()
        let quiet = try? await within(1) {
            for await update in states where update.topic == "home" { return update }
            throw TestFailure(description: "fin")
        }
        try expectEqual(quiet, nil)
        // Los tópicos de RemoteTopic.
        try expectEqual(RemoteTopic("pr:acme/api#12"), .pr("acme/api#12"))
        for bad in ["pr:", "pr:acme#1", "pr:acme/api#0", "pr:acme/api#x", "pr:a/b/c#1", "other", "pr:acme/a pi#1"] {
            try expectEqual(RemoteTopic(bad), nil)
        }
        try expectEqual(RemoteTopic.parse((1...30).map { "pr:acme/api#\($0)" }).count, 20)
    }

    @MainActor
    static func mailbox() async throws {
        let h = try await ServiceHarness.make()
        let one = try await h.pair()
        let two = try await h.pair(name: "Work iPhone")
        await h.service.recomputeState()
        let wrote = await h.service.flushMailbox()
        try expect(wrote)
        for client in [one, two] {
            let id = await client.paired!.deviceId
            let relay = h.relay, account = h.account
            try await eventually(3, "buzón") { await relay.mailboxItem(account, device: id, slot: "home") != nil }
            let blobs = try await client.fetchMailbox()
            try expectEqual(blobs.count, 1)
            let home: RemoteHome = try CommandProtocol.decoder.decode(JSONValue.self, from: blobs[0].data).decode()
            try expectEqual(home.status.appVersion, "test")
        }
        // El de uno no lo abre el otro.
        let oneId = await one.paired!.deviceId
        let blob = await h.relay.mailboxItem(h.account, device: oneId, slot: "home")!
        let twoId = await two.paired!.deviceId
        await h.relay.replaceMailbox(h.account, device: twoId, slot: "home", b: blob)
        let stolen = try await two.fetchMailbox()
        try expect(stolen.isEmpty)
        // Sin cambios: nada.
        await h.service.recomputeState()
        let again = await h.service.flushMailbox()
        try expect(!again)
        // Apagado: el slot queda vacío y no se escribe más.
        _ = try await h.service.setMailbox(false)
        try expect(!h.settings.remoteSettings.mailboxEnabled)
        try await eventually(3, "vacío") { (try? await one.fetchMailbox())?.first?.data.isEmpty == true }
        h.actions.statusVersion = "after"
        await h.service.recomputeState()
        let off = await h.service.flushMailbox()
        try expect(!off)
    }

    @MainActor
    static func push() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        let paired = await client.paired!
        let keys = await client.keys!
        let notification = PlannedNotification(kind: .myPRFeedback, title: "New Feedback", body: "api#7: 2 comments",
                                               url: nil, prID: "acme/api#7")
        h.service.push([notification], badge: 3)
        try await eventually(3, "push") { await !h.relay.pushes.isEmpty }
        guard case .push(_, _, _, _, let b)? = await h.relay.pushes.first else { throw TestFailure(description: "sin push") }
        let opened = try PushPayload.open(apnsField: b.base64EncodedString(), by: keys.push,
                                          from: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: paired.macSeal),
                                          info: SealedInfo.push(account: paired.accountId, device: paired.deviceId))
        try expectEqual(opened.title, "New Feedback")
        try expectEqual(opened.body, "api#7: 2 comments")
        try expectEqual(opened.deepLink, "prbar://pr/acme/api/7?screen=respond")
        try expectEqual(opened.badge, 3)
        try expect(h.service.devices[0].notificationsOff == false)
        await h.relay.setPushStatus(410)
        h.service.push([notification], badge: 3)
        try await eventually(3, "notificaciones apagadas") { await h.service.devices.first?.notificationsOff == true }
        try expectEqual(h.service.deviceList().first?.notifications, false)
    }

    @MainActor
    static func revokeResetAppLink() async throws {
        let h = try await ServiceHarness.make()
        let client = try await h.pair()
        let id = await client.paired!.deviceId
        do {
            _ = try await h.service.revoke("zz")
            throw TestFailure(description: "revocó algo que no existe")
        } catch let failure as CommandFailure { try expectEqual(failure.code, .notFound) }
        let revoked = try await h.service.revoke(String(id.prefix(6)))
        try expectEqual(revoked.id, id)
        try expect(h.service.devices.isEmpty)
        try await eventually(3, "revocado") { await client.status == .revoked }
        // App link.
        _ = try h.service.setAppLink("https://testflight.apple.com/join/AbCd1234")
        try expectEqual(h.service.status().appInstallURL?.absoluteString, "https://testflight.apple.com/join/AbCd1234")
        do {
            _ = try h.service.setAppLink("https://evil.example.com/join")
            throw TestFailure(description: "aceptó otro host")
        } catch let failure as CommandFailure { try expectEqual(failure.code, .invalidUsage) }
        _ = try h.service.setAppLink(nil)
        try expectEqual(h.service.status().appInstallURL, nil)
        // Reset: claves y cuenta nuevas, sin dispositivos.
        let before = h.secrets.peek("mac-relay")
        _ = try await h.pair()
        let status = try await h.service.reset()
        try expect(!status.enabled)
        try expectEqual(h.settings.remoteSettings.accountId, nil)
        try expect(h.service.devices.isEmpty)
        try expectEqual(h.secrets.peek("mac-relay") ?? "", "")
        try expect(before != nil)
    }

    @MainActor
    static func keepAwake() async throws {
        let power = FakePower()
        let assertions = FakeAssertions()
        let keep = KeepAwake(power: power, assertions: assertions)
        let h = try await ServiceHarness.make(keepAwake: keep)
        try expect(assertions.held.isEmpty)
        _ = try h.service.setKeepAwake(true)
        try expectEqual(assertions.taken, ["PRBar: iPhone remote access"])
        try expectEqual(assertions.held.count, 1)
        try expect(h.service.status().keepingAwake)
        // A batería: la suelta; de vuelta en corriente: una sola de nuevo.
        power.isOnACPower = false
        power.onChange?()
        try expect(assertions.held.isEmpty)
        power.isOnACPower = true
        power.onChange?()
        power.onChange?()
        try expectEqual(assertions.held.count, 1)
        // Deshabilitar el acceso la suelta aunque el ajuste siga prendido.
        _ = try await h.service.disable()
        try expect(assertions.held.isEmpty)
        try expectEqual(assertions.taken.count, 2)
    }
}
