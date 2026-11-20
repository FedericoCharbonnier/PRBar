import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

/// La Mac de punta a punta contra el relay en Go (con `PRBAR_RELAY_BIN`; sin la variable, se saltea): el
/// `RemoteAccessService` real (inscripción por HTTP, WebSocket, emparejamiento, puente) y un `RemoteClient` haciendo de
/// iPhone. Nunca contra el relay desplegado.
enum RemoteMacIntegrationTests {
    static let cases: [TestCase] = [
        TestCase("remote mac integration: habilitar con token, emparejar, status, eventos, merge con Face ID y revocar") {
            guard let binary = ProcessInfo.processInfo.environment["PRBAR_RELAY_BIN"] else {
                print("    skipped: PRBAR_RELAY_BIN not set")
                return
            }
            try await run(binary: binary)
        },
    ]

    @MainActor
    static func run(binary: String) async throws {
        let relay = try RelayIntegrationTests.RelayProcess(binary: binary)
        defer { relay.stop() }
        try await relay.waitUntilHealthy()
        let settings = MemoryRemoteSettings()
        let env = RemoteServiceEnvironment(
            keys: RemoteKeyStore(secrets: FakeSecrets()),
            devices: RemoteDeviceStore(directory: try temporaryDirectory().appendingPathComponent("remote")),
            enroller: URLSessionRelayEnroller(allowInsecureForTests: true),
            linkFactory: { host in WebSocketRelayLink.factory(host: host, allowInsecureTransportForTests: true) },
            macName: "Integration Mac", appVersion: "1.3.0",
            tune: { config in
                config.backoff = { _ in .milliseconds(200) }
                config.pushTimeout = .seconds(5)
            },
            connectBackoff: { _ in .milliseconds(200) }, mailboxInterval: .seconds(3600),
            feedDebounce: .milliseconds(50), allowInsecureForTests: true)
        let service = RemoteAccessService(settings: settings, environment: env)
        let actions = FakeActions()
        service.actions = actions
        defer { Task { await service.stop() } }

        // Un token equivocado: 403 con el texto de la UI.
        do {
            _ = try await service.enable(relay: relay.host, enrollToken: "wrong")
            throw TestFailure(description: "aceptó un token equivocado")
        } catch let failure as CommandFailure {
            try expectEqual(failure.message, "The relay refused the enrollment token.")
        }
        _ = try await service.enable(relay: relay.host, enrollToken: relay.token)
        try await eventually(10, "connected") { await service.state == .connected }

        // Emparejar con el QR y el código.
        let presence = SoftwarePresenceSigner()
        let client = RemoteClient(configuration: .init(appVersion: "1.3.0", deviceName: "Integration iPhone",
                                                       model: "iPhone 17 Pro", handshakeTimeout: .seconds(5),
                                                       requestTimeout: .seconds(20)),
                                  linkFactory: WebSocketRelayLink.factory(host: relay.host, allowInsecureTransportForTests: true))
        let info = try await service.pairStart()
        let qr = try PairingQR(url: info.qr, allowInsecure: true)
        let sas = try await client.startPairing(qr: qr, presenceKey: presence.publicKey)
        let joined = try await service.pairWait(pairing: info.pairing, events: { _ in })
        try expectEqual(joined.code?.replacingOccurrences(of: " ", with: ""), sas)
        let paired = try await service.pairConfirm(pairing: info.pairing, accepted: true)
        try expect(paired.device != nil)
        _ = try await within(10) { try await client.finishPairing() }
        try await client.connect()

        // status, como la CLI.
        let status = try await client.run(.status)
        try expectEqual(status.ok, true)
        try expectEqual(actions.calls.last, "status")

        // Eventos de un reviewStart --wait, en orden.
        actions.waitEvents = [.progress(message: "Queued"), .progress(message: "Reviewing…")]
        var events: [CommandEvent] = []
        for try await response in try await client.send(.reviewStart(pr: "acme/api#1", wait: true)) {
            if let event = response.event { events.append(event) }
        }
        try expectEqual(events, actions.waitEvents)

        // merge: sin Face ID no; con la firma de esta sesión sí.
        let merge = AppCommand.merge(pr: "acme/api#4", method: nil, confirmed: true, expectedHeadOid: "c0ffee")
        let bare = try await client.run(merge)
        try expectEqual(bare.error?.code, .unauthorized)
        let signed = try await client.run(merge, presence: presence)
        try expectEqual(signed.ok, true)
        try expectEqual(actions.calls.last, "merge acme/api#4 default head=c0ffee")

        // Un comando denegado no llega a la app.
        let before = actions.calls.count
        let denied = try await client.run(.toolsSet(tool: .git, path: "/tmp/git"))
        try expectEqual(denied.error?.code, .unauthorized)
        try expectEqual(actions.calls.count, before)

        // El estado en vivo llega cifrado.
        let states = client.states
        try await client.subscribe(["home"])
        let home = try await within(10) {
            for await update in states where update.topic == "home" { return update }
            throw TestFailure(description: "sin home")
        }
        try expect(home.rev >= 1)

        // Revocar: la Mac lo da de baja y el teléfono se entera por la sesión.
        let id = await client.paired!.deviceId
        _ = try await service.revoke(id)
        try await eventually(10, "revocado") { await client.status == .revoked }
        try expect(service.devices.isEmpty)
    }
}

/// QA manual (docs/qa/plan-18-checklist.md): un iPhone simulado contra un relay de verdad. Solo corre con
/// `PRBAR_PAIR_URL` (el link que muestra `prbar remote pair` o la hoja de Settings); en la suite se saltea.
enum RemoteSmokeTests {
    static let cases: [TestCase] = [
        TestCase("remote smoke: un iPhone simulado empareja, pide status y espera a que lo revoquen") {
            guard let link = ProcessInfo.processInfo.environment["PRBAR_PAIR_URL"] else {
                print("    skipped: PRBAR_PAIR_URL not set")
                return
            }
            let qr = try PairingQR(url: link)
            let presence = SoftwarePresenceSigner()
            let client = RemoteClient(
                configuration: .init(appVersion: "smoke", deviceName: "Simulated iPhone", model: "PRBarTests"),
                linkFactory: WebSocketRelayLink.factory(host: qr.relayHost))
            let sas = try await client.startPairing(qr: qr, presenceKey: presence.publicKey)
            print("    The Mac should show \(sas.prefix(3)) \(sas.suffix(3)). Choose Codes Match (5 min).")
            _ = try await within(300) { try await client.finishPairing() }
            try await client.connect()
            let status = try await client.run(.status)
            print("    status: \(status.ok == true ? "ok" : "\(String(describing: status.error))")")
            print("    Paired. Revoke “Simulated iPhone” on the Mac within 5 minutes to finish.")
            try await eventually(300, "revoked") { await client.status == .revoked }
        },
    ]
}
