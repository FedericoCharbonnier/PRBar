import Foundation
import PRBarRemoteKit
import PRBarRemoteMac

/// Un link que no termina de conectar hasta `release()` (un relay lento) y anota si lo cerraron.
private final class GatedLink: RelayLink, @unchecked Sendable {
    private let inner: RelayLink
    private let lock = NSLock()
    private var released = false
    private var closedFlag = false

    init(_ inner: RelayLink) { self.inner = inner }

    var incoming: AsyncThrowingStream<RelayMessage, Error> { inner.incoming }
    var closed: Bool { lock.withLock { closedFlag } }
    func release() { lock.withLock { released = true } }

    func connect() async throws -> RelayReady {
        while !lock.withLock({ released }) { try? await Task.sleep(for: .milliseconds(5)) }
        return try await inner.connect()
    }

    func send(_ message: RelayMessage) throws { try inner.send(message) }

    func close() async {
        lock.withLock { closedFlag = true }
        await inner.close()
    }
}

private final class LinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [GatedLink] = []
    func add(_ link: GatedLink) { lock.withLock { all.append(link) } }
    var links: [GatedLink] { lock.withLock { all } }
}

/// Revisión final de la Mac: H4 (apagar mientras conecta) y M7 (dos Macs con la misma cuenta).
enum RemoteConnectionTests {
    static let cases: [TestCase] = [
        TestCase("remote host: disconnect mientras conecta cierra el link nuevo y no queda conectado (H4)") {
            let box = LinkBox()
            let h = try await RemoteHarness.make(relayFactory: { relay in
                let real = relay.factory()
                return { credential in
                    let link = GatedLink(real(credential))
                    box.add(link)
                    // El primero (el de `make`) conecta enseguida; los siguientes esperan.
                    if box.links.count == 1 { link.release() }
                    return link
                }
            })
            await h.host.disconnect()
            let host = h.host
            let connecting = Task { try await host.connect() }
            try await eventually(3, "link nuevo") { box.links.count == 2 }
            await host.disconnect()
            box.links[1].release()
            let outcome = await connecting.result
            try expect((try? outcome.get()) == nil, "connect debería fallar")
            let connected = await host.isConnected
            try expect(!connected, "quedó conectado después de disconnect")
            try await eventually(3, "link cerrado") { box.links[1].closed }
            let relay = h.relay, account = h.account
            try await eventually(3, "la Mac no sigue en el relay") { await relay.macLink(account) == nil }
        },
        TestCase("remote service: otra Mac con la misma cuenta la reemplaza; esta no reconecta y lo dice (M7)") { @MainActor in
            let h = try await ServiceHarness.make()
            let keys = try RemoteKeyStore(secrets: h.secrets).loadOrCreate()
            let other = h.relay.factory()(.signed(account: h.account, client: "mac", key: keys.relay))
            _ = try await other.connect()
            let service = h.service
            try await eventually(3, "failed") { await service.state == .failed(RemoteAccessService.replacedMessage) }
            // No vuelve a sacarle el lugar a la otra (ni sola ni al despertar).
            try await Task.sleep(for: .milliseconds(300))
            await h.service.retryNow()
            try await Task.sleep(for: .milliseconds(200))
            let relay = h.relay, account = h.account
            let current = await relay.macLink(account)
            try expect(current === (other as AnyObject), "la Mac reemplazada volvió a conectarse")
            try expectEqual(h.service.state, .failed(RemoteAccessService.replacedMessage))
            // Volver a habilitar la conecta de nuevo (ahora la otra es la reemplazada).
            _ = try await h.service.disable()
            try expectEqual(h.service.state, .disabled)
            _ = try await h.service.enable(relay: h.relay.host, enrollToken: "")
            try await h.waitConnected()
            await other.close()
        },
        TestCase("remote service: al reconectar vuelve a escribir el buzón aunque home no haya cambiado (M8)") { @MainActor in
            let h = try await ServiceHarness.make()
            _ = try await h.pair()
            await h.service.recomputeState()
            let first = await h.service.flushMailbox()
            try expect(first)
            let again = await h.service.flushMailbox()
            try expect(!again, "sin cambios no se reescribe")
            await h.relay.closeMac(h.account)
            let service = h.service
            try await eventually(3, "offline") {
                if case .offline = await service.state { return true }
                return false
            }
            try await h.waitConnected()
            let afterReconnect = await h.service.flushMailbox()
            try expect(afterReconnect, "lo que se escribió sin conexión no llegó al relay")
        },
        TestCase("remote service: apagar mientras conecta deja Disabled y nada conectado (H4)") { @MainActor in
            let h = try await ServiceHarness.make()
            _ = try await h.service.disable()
            try await h.store(enabled: true)
            h.service.start()
            _ = try await h.service.disable()
            try await Task.sleep(for: .milliseconds(300))
            try expectEqual(h.service.state, .disabled)
            let relay = h.relay, account = h.account
            let mac = await relay.macLink(account)
            try expect(mac == nil, "quedó una conexión sin dueño")
        },
    ]
}
