import CryptoKit
import Foundation
import PRBarRemoteKit

/// Un relay que acepta la conexión (Mac online) y se traga todo: el handshake queda en vuelo hasta que alguien lo corte.
private final class SilentRelayLink: RelayLink, @unchecked Sendable {
    private let sent: SentCounter
    let incoming: AsyncThrowingStream<RelayMessage, Error>
    private let sink: AsyncThrowingStream<RelayMessage, Error>.Continuation

    init(sent: SentCounter) {
        self.sent = sent
        (incoming, sink) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws -> RelayReady { RelayReady(mac: "online", since: 0) }
    func send(_ message: RelayMessage) throws { sent.add() }
    func close() async { sink.finish(throwing: RelayClosed(code: nil, reason: "closed")) }
}

private final class SentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private actor Finished {
    private(set) var count = 0
    func add() { count += 1 }
}

/// Cada espera de RemoteClient se retoma exactamente una vez, también con llamadas concurrentes (una continuación
/// perdida deja la tarea colgada para siempre: "SWIFT TASK CONTINUATION MISUSE"). Las llamadas van en tareas sueltas
/// y se sondea que terminen: un `within` con un grupo de tareas se quedaría esperando a la colgada.
enum RemoteContinuationTests {
    static let cases: [TestCase] = [
        TestCase("remote continuations: dos connect a la vez con el handshake en vuelo terminan los dos al desconectar") {
            let sent = SentCounter()
            let mac = PairedMac(accountId: "acct", deviceId: "dev", relayHost: "relay.test", macName: "Mac",
                                macStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                macSeal: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            // El handshake no vence solo durante el test: lo tiene que cortar el disconnect.
            let client = RemoteClient(configuration: .init(appVersion: "1.0.0", deviceName: "iPhone", model: "iPhone",
                                                           handshakeTimeout: .seconds(120)),
                                      paired: mac, keys: DeviceKeys(), linkFactory: { _ in SilentRelayLink(sent: sent) })
            let finished = Finished()
            for _ in 0..<2 {
                Task {
                    _ = try? await client.connect()
                    await finished.add()
                }
            }
            try await eventually(3, "handshake enviado") { sent.value >= 1 }
            try await Task.sleep(for: .milliseconds(200))
            await client.disconnect()
            try await eventually(3, "los dos connect terminaron") { await finished.count == 2 }
        },
        TestCase("remote continuations: un connect cancelado vuelve enseguida y el otro sigue esperando el intento") {
            let sent = SentCounter()
            let mac = PairedMac(accountId: "acct", deviceId: "dev", relayHost: "relay.test", macName: "Mac",
                                macStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                macSeal: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            let client = RemoteClient(configuration: .init(appVersion: "1.0.0", deviceName: "iPhone", model: "iPhone",
                                                           handshakeTimeout: .seconds(120)),
                                      paired: mac, keys: DeviceKeys(), linkFactory: { _ in SilentRelayLink(sent: sent) })
            let cancelled = Finished()
            let other = Finished()
            let first = Task {
                do { try await client.connect() } catch is CancellationError { await cancelled.add() } catch {}
            }
            try await eventually(3, "handshake enviado") { sent.value >= 1 }
            Task {
                _ = try? await client.connect()
                await other.add()
            }
            try await Task.sleep(for: .milliseconds(100))
            first.cancel()
            // Antes volvía recién al vencer el handshake (120 s acá).
            try await eventually(1, "el connect cancelado volvió con CancellationError") { await cancelled.count == 1 }
            try await Task.sleep(for: .milliseconds(200))
            let stillWaiting = await other.count
            try expectEqual(stillWaiting, 0)
            try expectEqual(sent.value, 1)
            await client.disconnect()
            try await eventually(3, "el otro connect terminó al desconectar") { await other.count == 1 }
        },
        TestCase("remote continuations: un connect ya cancelado no abre nada") {
            let sent = SentCounter()
            let mac = PairedMac(accountId: "acct", deviceId: "dev", relayHost: "relay.test", macName: "Mac",
                                macStatic: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                macSeal: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            let client = RemoteClient(configuration: .init(appVersion: "1.0.0", deviceName: "iPhone", model: "iPhone",
                                                           handshakeTimeout: .seconds(120)),
                                      paired: mac, keys: DeviceKeys(), linkFactory: { _ in SilentRelayLink(sent: sent) })
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do { try await client.connect() } catch is CancellationError { return true } catch {}
                return false
            }
            let gotCancellation = await task.value
            try expectEqual(gotCancellation, true)
            try expectEqual(sent.value, 0)
        },
        TestCase("remote continuations: dos connect a la vez contra una Mac abren una sola sesión y vuelven los dos") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            let finished = Finished()
            let failures = Finished()
            for _ in 0..<2 {
                Task {
                    do { try await client.connect() } catch { await failures.add() }
                    await finished.add()
                }
            }
            // El handshake vence a los 3 s: los dos tienen que volver antes, y bien.
            try await eventually(2, "los dos connect terminaron") { await finished.count == 2 }
            let failed = await failures.count
            try expectEqual(failed, 0)
            let response = try await client.run(.status)
            try expectEqual(response.ok, true)
        },
        TestCase("remote continuations: dos finishPairing a la vez terminan los dos al cancelar") {
            let h = try await RemoteHarness.make()
            let client = h.client()
            let qr = try await h.openPairing()
            async let join = h.nextJoin()
            _ = try await client.startPairing(qr: qr, presence: h.presence.credential)
            _ = try await join
            let finished = Finished()
            for _ in 0..<2 {
                Task {
                    _ = try? await client.finishPairing()
                    await finished.add()
                }
            }
            try await Task.sleep(for: .milliseconds(200))
            await client.cancelPairing()
            try await eventually(3, "los dos finishPairing terminaron") { await finished.count == 2 }
        },
    ]
}
