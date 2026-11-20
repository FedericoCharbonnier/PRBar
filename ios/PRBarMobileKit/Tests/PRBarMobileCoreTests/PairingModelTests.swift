import CryptoKit
import Foundation
import Testing
import PRBarRemoteKit
@testable import PRBarMobileCore

@MainActor @Suite struct PairingModelTests {
    final class Permission: NotificationPermission, @unchecked Sendable {
        var asked = 0
        func request() async -> Bool { asked += 1; return true }
    }

    static let qr = PairingQR(relayHost: "relay.example.com", accountId: String(repeating: "a", count: 26),
                              pairingId: String(repeating: "b", count: 16), secret: Data(repeating: 1, count: 32),
                              macStatic: Data(repeating: 2, count: 32), macName: Sample.macName)
    static let mac = StoredPairedMac(accountId: qr.accountId, deviceId: "dev", relayHost: qr.relayHost,
                                     macName: Sample.macName, macStatic: qr.macStatic, macSealKey: Data(count: 32),
                                     pairedAt: Sample.now)

    struct Harness {
        let model: PairingModel
        let service: FakePairingService
        let keychain: DeviceKeychain
        let backend: InMemoryKeychain
        let permission: Permission
        let paired: () -> StoredPairedMac?
    }

    func harness(_ script: [Result<PairingProgress, PairingFailure>], hold: Bool = false) -> Harness {
        let service = FakePairingService(script: script, holdBeforeLast: hold)
        let backend = InMemoryKeychain()
        let keychain = DeviceKeychain(backend: backend, accessGroup: nil)
        let permission = Permission()
        var result: StoredPairedMac?
        let presence = P256.Signing.PrivateKey()
        let model = PairingModel(service: service, keychain: keychain,
                                 makePresenceKey: { (presence.rawRepresentation, presence.publicKey.x963Representation) },
                                 notifications: permission) { result = $0 }
        return Harness(model: model, service: service, keychain: keychain, backend: backend, permission: permission,
                       paired: { result })
    }

    @Test func validQRJoinsShowsTheCodeAndPairsAfterTheMacConfirms() async throws {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))], hold: true)
        h.model.startScanning()
        #expect(h.model.step == .scanning)
        h.model.scanned(Self.qr.url)
        #expect(h.model.step == .joining(macName: Sample.macName))
        for _ in 0..<200 where h.model.step == .joining(macName: Sample.macName) { await Task.yield() }
        #expect(h.model.step == .confirmCode(code: "123 456", macName: Sample.macName))
        #expect(h.permission.asked == 0)
        h.model.codesMatch()
        #expect(h.model.step == .waitingForMac(code: "123 456", macName: Sample.macName))
        h.service.release()
        await h.model.settle()
        #expect(h.model.step == .paired(macName: Sample.macName))
        // Notifications are asked for only after pairing.
        #expect(h.permission.asked == 1)
        #expect(h.paired() == Self.mac)
        #expect(try h.keychain.loadMac() == Self.mac)
        #expect(try h.keychain.loadKeys() != nil)
        #expect(h.service.joinedQR == Self.qr)
        #expect(h.service.presenceKey?.count == 65)
    }

    @Test func anInvalidQRStaysOnTheScanner() {
        let h = harness([])
        h.model.startScanning()
        h.model.scanned("https://example.com")
        #expect(h.model.step == .scanning)
        #expect(h.model.scanError == PairingModel.invalidQRMessage)
    }

    @Test func expiredGoesBackToWelcomeWithTheMessageAndNoKeys() async {
        let h = harness([.success(.joining), .failure(.expired)])
        h.model.startScanning()
        h.model.scanned(Self.qr.url)
        await h.model.settle()
        #expect(h.model.step == .welcome)
        #expect(h.model.message == PairingModel.expiredMessage)
        #expect(h.backend.isEmpty)
        #expect(h.permission.asked == 0)
    }

    @Test func cancelledOnTheMacGoesBackToWelcome() async {
        let h = harness([.success(.joining), .success(.code("123 456")), .failure(.cancelled)])
        h.model.startScanning()
        h.model.scanned(Self.qr.url)
        await h.model.settle()
        #expect(h.model.step == .welcome)
        #expect(h.model.message == PairingModel.cancelledMessage)
    }

    @Test func codesDontMatchCancelsTheSlot() async {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))], hold: true)
        h.model.startScanning()
        h.model.scanned(Self.qr.url)
        for _ in 0..<200 where h.model.code == nil { await Task.yield() }
        await h.model.codesDontMatch()
        #expect(h.service.cancelled)
        #expect(h.model.step == .welcome)
        #expect(h.model.message == PairingModel.mismatchMessage)
        #expect(h.paired() == nil)
    }

    @Test func aCameraLinkGoesStraightToJoining() async {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))], hold: true)
        h.model.open(URL(string: Self.qr.url)!)
        #expect(h.model.step == .joining(macName: Sample.macName))
        h.model.cancelScanning()
        #expect(h.model.step == .welcome)
    }
}
