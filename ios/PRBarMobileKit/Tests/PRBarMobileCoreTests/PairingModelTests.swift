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
    static let mac = PairedMac(accountId: qr.accountId, deviceId: "dev", relayHost: qr.relayHost,
                                     macName: Sample.macName, macStatic: qr.macStatic, macSeal: Data(count: 32))

    struct Harness {
        let model: PairingModel
        let service: FakePairingService
        let keychain: DeviceKeychain
        let backend: InMemoryKeychain
        let permission: Permission
        let paired: () -> PairedMac?
    }

    func harness(_ script: [Result<PairingProgress, PairingFailure>], hold: Bool = false) -> Harness {
        let service = FakePairingService(script: script, holdBeforeLast: hold)
        let backend = InMemoryKeychain()
        let keychain = DeviceKeychain(backend: backend, accessGroup: nil)
        let permission = Permission()
        var result: PairedMac?
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
        #expect(h.model.step == .confirmLink(macName: Sample.macName, relayHost: "relay.example.com", replacing: nil))
        #expect(h.service.joinedQR == nil)
        h.model.confirmPairing()
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

    /// Review L5: the Mac's confirmation before the user compared the codes is held in memory; nothing is stored (and
    /// no existing pairing is replaced) until "Codes Match" here.
    @Test func aMacConfirmationBeforeCodesMatchIsStoredOnlyOnTheTap() async throws {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))])
        h.model.startScanning()
        h.model.scanned(Self.qr.url)
        h.model.confirmPairing()
        await h.model.settle()
        #expect(h.model.step == .confirmCode(code: "123 456", macName: Sample.macName))
        #expect(try h.keychain.loadMac() == nil)
        #expect(h.paired() == nil)
        h.model.codesMatch()
        for _ in 0..<500 where h.paired() == nil { await Task.yield() }
        #expect(h.model.step == .paired(macName: Sample.macName))
        #expect(try h.keychain.loadMac() == Self.mac)
        #expect(h.paired() == Self.mac)
    }

    @Test func codesDontMatchAfterTheMacConfirmedStoresNothing() async throws {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))])
        h.model.startScanning()
        h.model.scanned(Self.qr.url)
        h.model.confirmPairing()
        await h.model.settle()
        await h.model.codesDontMatch()
        #expect(h.model.message == PairingModel.mismatchMessage)
        #expect(try h.keychain.loadMac() == nil)
        #expect(try h.keychain.loadKeys() == nil)
        #expect(h.paired() == nil)
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
        h.model.confirmPairing()
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
        h.model.confirmPairing()
        await h.model.settle()
        #expect(h.model.step == .welcome)
        #expect(h.model.message == PairingModel.cancelledMessage)
    }

    @Test func codesDontMatchCancelsTheSlot() async {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))], hold: true)
        h.model.startScanning()
        h.model.scanned(Self.qr.url)
        h.model.confirmPairing()
        for _ in 0..<200 where h.model.code == nil { await Task.yield() }
        await h.model.codesDontMatch()
        #expect(h.service.cancelled)
        #expect(h.model.step == .welcome)
        #expect(h.model.message == PairingModel.mismatchMessage)
        #expect(h.paired() == nil)
    }

    @Test func aLinkAsksBeforeJoiningAndWarnsWhenItReplacesAPairing() async {
        let h = harness([.success(.joining), .success(.code("123 456")), .success(.paired(Self.mac))], hold: true)
        h.model.open(URL(string: Self.qr.url)!, replacing: "Studio Mac")
        #expect(h.model.step == .confirmLink(macName: Sample.macName, relayHost: "relay.example.com",
                                             replacing: "Studio Mac"))
        #expect(PairingModel.replaceWarning("Studio Mac") == "This replaces your pairing with Studio Mac.")
        #expect(h.service.joinedQR == nil)
        h.model.cancelScanning()
        #expect(h.model.step == .welcome)
        #expect(h.service.joinedQR == nil)
        #expect(!h.service.cancelled)
    }

    @Test func aFailedReplacementKeepsTheExistingPairing() async throws {
        let h = harness([.success(.joining), .failure(.expired)])
        let existing = PairedMac(accountId: "old", deviceId: "old", relayHost: "relay.example.com",
                                       macName: "Studio Mac", macStatic: Data(count: 32), macSeal: Data(count: 32))
        let keys = StoredDeviceKeys.generate(presenceKey: Data([9]))
        try h.keychain.save(mac: existing)
        try h.keychain.save(keys: keys)
        h.model.open(URL(string: Self.qr.url)!, replacing: "Studio Mac")
        h.model.confirmPairing()
        await h.model.settle()
        #expect(h.model.message == PairingModel.expiredMessage)
        #expect(try h.keychain.loadMac() == existing)
        #expect(try h.keychain.loadKeys() == keys)
    }
}
