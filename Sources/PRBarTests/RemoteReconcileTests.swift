import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

/// Revisión del iPhone M5 (lo que se hizo sin conexión llega al relay), L3 (Cancel durante el acuse), L4 (cuenta
/// inválida al inscribirse) y L6 (despertar y red a la vez).
enum RemoteReconcileTests {
    struct BadEnroller: RelayEnrolling {
        func enroll(host: String, token: String, macRelayKey: Data) async throws -> String { "NOT-BASE32!" }
    }

    static let cases: [TestCase] = [
        TestCase("remote reconcile: un Revoke con el acceso apagado da de baja al iPhone en el relay al volver (M5)") { @MainActor in
            let h = try await ServiceHarness.make()
            let client = try await h.pair()
            let id = await client.paired!.deviceId
            _ = try await h.service.disable()
            _ = try await h.service.revoke(id)
            let stillThere = await h.relay.hasDevice(h.account, id)
            try expect(stillThere, "sin conexión el relay todavía no se enteró")
            _ = try await h.service.enable(relay: h.relay.host, enrollToken: "")
            try await h.waitConnected()
            let relay = h.relay, account = h.account
            try await eventually(3, "baja en el relay") { await !relay.hasDevice(account, id) }
        },
        TestCase("remote reconcile: un device.remove que el relay perdió se manda de nuevo al reconectar (M5)") { @MainActor in
            let h = try await ServiceHarness.make()
            let keep = try await h.pair()
            let gone = try await h.pair(name: "Old iPhone")
            let keepId = await keep.paired!.deviceId, goneId = await gone.paired!.deviceId
            await h.relay.setIgnoreDeviceRemoval(true)
            _ = try await h.service.revoke(goneId)
            await h.relay.setIgnoreDeviceRemoval(false)
            let lost = await h.relay.hasDevice(h.account, goneId)
            try expect(lost)
            await h.relay.closeMac(h.account)
            let relay = h.relay, account = h.account
            try await eventually(5, "baja en el relay") { await !relay.hasDevice(account, goneId) }
            let kept = await relay.hasDevice(account, keepId)
            try expect(kept, "dio de baja a uno que la Mac tiene")
        },
        TestCase("remote reconcile: apagar el buzón sin conexión vacía el slot al volver (M5)") { @MainActor in
            let h = try await ServiceHarness.make()
            let client = try await h.pair()
            await h.service.recomputeState()
            let wrote = await h.service.flushMailbox()
            try expect(wrote)
            let full = try await client.fetchMailbox()
            try expect(full.first?.data.isEmpty == false)
            _ = try await h.service.disable()
            _ = try await h.service.setMailbox(false)
            _ = try await h.service.enable(relay: h.relay.host, enrollToken: "")
            try await h.waitConnected()
            try await eventually(3, "slot vacío") { (try? await client.fetchMailbox())?.first?.data.isEmpty == true }
        },
        TestCase("remote reconcile: Reset sin conexión deja la cuenta vieja sin iPhones en el relay y olvida su clave (M5)") { @MainActor in
            let h = try await ServiceHarness.make()
            let one = try await h.pair()
            let two = try await h.pair(name: "Work iPhone")
            let ids = [await one.paired!.deviceId, await two.paired!.deviceId]
            let oldAccount = h.account
            _ = try await h.service.disable()
            _ = try await h.service.reset()
            let keys = RemoteKeyStore(secrets: h.secrets)
            await h.service.waitForCleanup()
            for id in ids {
                let there = await h.relay.hasDevice(oldAccount, id)
                try expect(!there, "\(id) sigue en el relay")
            }
            try expect(keys.retiredAccounts().isEmpty, "la clave vieja quedó guardada")
            try expectEqual(h.settings.remoteSettings.accountId, nil)
        },
        TestCase("remote reconcile: si el relay no contesta, la cuenta retirada queda para el próximo arranque (M5)") { @MainActor in
            let h = try await ServiceHarness.make()
            let one = try await h.pair()
            let id = await one.paired!.deviceId
            let oldAccount = h.account
            await h.relay.setIgnoreDeviceRemoval(true)
            _ = try await h.service.reset()
            await h.service.waitForCleanup()
            let keys = RemoteKeyStore(secrets: h.secrets)
            try expectEqual(keys.retiredAccounts().map(\.accountId), [oldAccount])
            await h.relay.setIgnoreDeviceRemoval(false)
            h.service.start()
            await h.service.waitForCleanup()
            let there = await h.relay.hasDevice(oldAccount, id)
            try expect(!there)
            try expect(keys.retiredAccounts().isEmpty)
        },
        TestCase("remote pairing: Cancel durante la espera del acuse cierra la ranura y no guarda nada (L3)") { @MainActor in
            let h = try await ServiceHarness.make()
            let client = h.client(name: "Late iPhone")
            let info = try await h.service.pairStart()
            let relay = h.relay, account = h.account
            try await eventually(3, "ranura") { await relay.pairingSlot(account) == info.pairing }
            // El relay deja pasar el handshake y el `confirm`, pero retiene el resultado y el acuse.
            await relay.setPairForwardLimit(2)
            _ = try await client.startPairing(qr: try PairingQR(url: info.qr), presenceKey: h.presence.publicKey)
            _ = try await h.service.pairWait(pairing: info.pairing, events: { _ in })
            let confirming = Task { @MainActor in try await h.service.pairConfirm(pairing: info.pairing, accepted: true) }
            try await Task.sleep(for: .milliseconds(150))
            let cancelled = try await h.service.pairConfirm(pairing: info.pairing, accepted: false)
            try expectEqual(cancelled.device, nil)
            do {
                _ = try await confirming.value
                throw TestFailure(description: "Codes Match terminó después de Cancel")
            } catch is CommandFailure {}
            try expect(h.service.devices.isEmpty)
            let paired = await relay.pairingSlot(account)
            try expectEqual(paired, nil)
        },
        TestCase("remote pairing: cancelar una espera de pairWait no corta las demás (L3)") { @MainActor in
            let h = try await ServiceHarness.make()
            let info = try await h.service.pairStart()
            let cli = Task { @MainActor in try await h.service.pairWait(pairing: info.pairing, events: { _ in }) }
            let sheet = Task { @MainActor in try await h.service.pairWait(pairing: info.pairing, events: { _ in }) }
            try await Task.sleep(for: .milliseconds(100))
            cli.cancel()
            do {
                _ = try await cli.value
                throw TestFailure(description: "no se canceló")
            } catch is CancellationError {}
            let relay = h.relay, account = h.account
            try await eventually(3, "ranura") { await relay.pairingSlot(account) == info.pairing }
            let client = h.client()
            _ = try await client.startPairing(qr: try PairingQR(url: info.qr), presenceKey: h.presence.publicKey)
            let joined = try await within { try await sheet.value }
            try expect(joined.code != nil)
        },
        TestCase("remote service: una cuenta que no es base32 al inscribirse falla y no habilita nada (L4)") { @MainActor in
            let clock = RemoteTestClock()
            let relay = InMemoryRelay(clock: clock.function)
            let settings = MemoryRemoteSettings()
            let env = RemoteServiceEnvironment(
                keys: RemoteKeyStore(secrets: FakeSecrets()), devices: RemoteDeviceStore(directory: try temporaryDirectory()),
                enroller: BadEnroller(), linkFactory: { _ in relay.factory() }, macName: "Mac", appVersion: "1",
                clock: clock.function)
            let service = RemoteAccessService(settings: settings, environment: env)
            do {
                _ = try await service.enable(relay: relay.host, enrollToken: "good-token")
                throw TestFailure(description: "aceptó la cuenta")
            } catch let failure as CommandFailure {
                try expectEqual(failure.message, "The relay answered something PRBar doesn’t understand.")
            }
            try expect(!settings.remoteSettings.enabled)
            try expectEqual(settings.remoteSettings.accountId, nil)
        },
        TestCase("remote service: despertar y volver la red a la vez reconectan una sola vez y quedan conectados (L6)") { @MainActor in
            let h = try await ServiceHarness.make()
            _ = try await h.service.disable()
            try await h.store(enabled: true)
            async let a: Void = h.service.retryNow()
            async let b: Void = h.service.retryNow()
            _ = await (a, b)
            try await h.waitConnected()
            try await Task.sleep(for: .milliseconds(200))
            try expectEqual(h.service.state, .connected)
        },
    ]
}

extension ServiceHarness {
    /// Cambia `enabled` en la config sin pasar por el servicio (como si la app arrancara con eso guardado).
    @MainActor
    func store(enabled: Bool) async throws {
        try settings.updateRemoteSettings { $0.enabled = enabled }
    }
}
