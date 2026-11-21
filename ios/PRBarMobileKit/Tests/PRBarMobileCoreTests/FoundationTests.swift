import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

@Suite struct AppCommandPolicyTests {
    @Test func approveIsGatedAndCommentIsNot() {
        let approve = AppCommand.reviewPublish(pr: "acme/api#12", event: .approve, only: nil, withComments: true,
                                               allInBody: false, confirmed: true)
        let comment = AppCommand.reviewPublish(pr: "acme/api#12", event: .comment, only: nil, withComments: true,
                                               allInBody: false, confirmed: true)
        #expect(approve.needsPresence)
        #expect(!comment.needsPresence)
        #expect(AppCommand.merge(pr: "a/b#1", method: nil, confirmed: true, expectedHeadOid: "x").needsPresence)
        #expect(AppCommand.respondPush(pr: "a/b#1", confirmed: true, wait: false).needsPresence)
        #expect(!AppCommand.respondReplyOnly(pr: "a/b#1", confirmed: true, wait: false).needsPresence)
    }

    @Test func turningFaceIDOffIsGatedButOnIsNot() {
        #expect(AppCommand.presenceRequirement(enabled: false).needsPresence)
        #expect(!AppCommand.presenceRequirement(enabled: true).needsPresence)
        #expect(!AppCommand.ciFix(pr: "a/b#1", wait: false).needsPresence)
    }

    @Test func commandsEncodeWithTheWireEncoder() throws {
        let bytes = try AppCommand.ciFix(pr: "acme/web-app#488", wait: false).commandBytes()
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"ciFix":{"pr":"acme/web-app#488","wait":false}}"#)
        let presence = try AppCommand.presenceRequirement(enabled: true).commandBytes()
        #expect(try CommandProtocol.decoder.decode(AppCommand.self, from: presence)
                == .remoteSetPresenceRequirement(device: "", enabled: true))
    }
}

@Suite struct DeepLinkTests {
    @Test func parsesPRLinks() {
        #expect(DeepLink(URL(string: "prbar://pr/acme/api/317?screen=review")!) == .pr(id: "acme/api#317", screen: .review))
        #expect(DeepLink(URL(string: "prbar://pr/acme/web-app/475")!) == .pr(id: "acme/web-app#475", screen: nil))
        #expect(DeepLink(URL(string: "prbar://pr/acme/api/x")!) == nil)
        #expect(DeepLink(URL(string: "https://pr/acme/api/1")!) == nil)
    }

    @Test func pairLinksGoToPairing() {
        let url = URL(string: "prbar://pair?v=1")!
        #expect(DeepLink(url) == .pair(url))
    }
}

@Suite struct FormatTests {
    let now = Sample.now

    @Test func ages() {
        #expect(Format.age(now.addingTimeInterval(-30), now: now) == "now")
        #expect(Format.age(now.addingTimeInterval(-12 * 60), now: now) == "12 min")
        #expect(Format.age(now.addingTimeInterval(-2 * 3600), now: now) == "2h")
        #expect(Format.age(now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
        #expect(Format.ago(now.addingTimeInterval(-4 * 60), now: now) == "4m ago")
    }

    @Test func refs() {
        #expect(Format.shortRef("acme/web-app#491") == "web-app#491")
        #expect(Format.headerRef("acme/api#317") == "acme/api #317")
    }

    @Test func numbers() {
        #expect(Format.money(48.2) == "$48.20")
        #expect(Format.bytes(11_200_000_000) == "11.2 GB")
        #expect(Format.bytes(212_000_000_000) == "212 GB")
        #expect(Format.clock(252) == "4:12")
        #expect(Format.duration(220) == "3m 40s")
        #expect(Format.count(1, "comment") == "1 comment")
        #expect(Format.count(4, "comment") == "4 comments")
    }

    @Test func timesInAFixedLocale() {
        let tz = TimeZone(identifier: "America/Montevideo")!
        let locale = Locale(identifier: "en_US")
        let seen = now.addingTimeInterval(-86 * 60)
        // Foundation puts a narrow no-break space before AM.
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(plain(Format.time(seen, locale: locale, timeZone: tz)) == "8:12 AM")
        #expect(plain(Format.dayAndTime(seen, now: now, locale: locale, timeZone: tz)) == "today at 8:12 AM")
    }

    @Test func initialsAndAvatarColors() {
        #expect(Format.initials("Laura Méndez") == "LM")
        #expect(Format.initials("ana-pereira") == "AP")
        #expect(Format.initials("diego") == "DI")
        #expect(Format.avatarIndex("lmendez", count: 8) == Format.avatarIndex("LMendez", count: 8))
    }
}

@Suite struct UnifiedDiffTests {
    @Test func splitsFilesAndNumbersLines() throws {
        let files = UnifiedDiff.parse(Sample.diff475.diff!, sensitive: ["src/reports/export.test.ts"])
        #expect(files.map(\.name) == ["export.ts", "export.test.ts"])
        let export = files[0]
        #expect(export.additions == 9)
        #expect(export.deletions == 4)
        #expect(export.lines.first?.kind == .hunk)
        #expect(export.lines[1].number == 52)
        #expect(files[1].isSensitive)
        #expect(!export.isSensitive)
    }
}

@Suite struct KeychainTests {
    /// Review L6: an existing item is updated in place; a failed update never falls back to delete + add.
    @Test func systemKeychainUpdatesBeforeAdding() {
        var calls: [String] = []
        #expect(SystemKeychain.write(update: { calls.append("update"); return errSecSuccess },
                                     add: { calls.append("add"); return errSecSuccess }) == errSecSuccess)
        #expect(calls == ["update"])
        calls = []
        #expect(SystemKeychain.write(update: { calls.append("update"); return errSecItemNotFound },
                                     add: { calls.append("add"); return errSecSuccess }) == errSecSuccess)
        #expect(calls == ["update", "add"])
        calls = []
        #expect(SystemKeychain.write(update: { calls.append("update"); return errSecInteractionNotAllowed },
                                     add: { calls.append("add"); return errSecSuccess }) == errSecInteractionNotAllowed)
        #expect(calls == ["update"])
    }

    @Test func storesReadsAndWipes() throws {
        let backend = InMemoryKeychain()
        let keychain = DeviceKeychain(backend: backend, accessGroup: "TEAMID.com.federico.prbar.ios.shared")
        let keys = StoredDeviceKeys.generate(presenceKey: Data([1, 2, 3]))
        let mac = PairedMac(accountId: "a", deviceId: "d", relayHost: "relay.example.com", macName: Sample.macName,
                                  macStatic: Data(count: 32), macSeal: Data(count: 32))
        try keychain.save(keys: keys)
        try keychain.save(mac: mac)
        #expect(try keychain.loadKeys() == keys)
        #expect(try keychain.loadMac() == mac)
        try keychain.wipe()
        #expect(try keychain.loadKeys() == nil)
        #expect(backend.isEmpty)
    }

    @Test func itemsAreThisDeviceOnlyUnsyncedAndShared() throws {
        let backend = InMemoryKeychain()
        let keychain = DeviceKeychain(backend: backend, accessGroup: "TEAMID.com.federico.prbar.ios.shared")
        try keychain.save(keys: .generate(presenceKey: Data()))
        let attributes = try #require(backend.attributes(account: "device-keys"))
        #expect(attributes[kSecAttrAccessible as String] == .string(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        #expect(attributes[kSecAttrAccessGroup as String] == .string("TEAMID.com.federico.prbar.ios.shared"))
        #expect(attributes[kSecAttrSynchronizable as String] == .bool(false))
    }

    @Test func keysAreDistinctPerUse() {
        let keys = StoredDeviceKeys.generate(presenceKey: Data())
        #expect(keys.staticKey != keys.pushKey)
        #expect(keys.relayKey.count == 32)
    }
}

@Suite struct PresenceTests {
    @Test func laErrorsMapToTheScreensStates() {
        #expect(PresenceFailure.from(laErrorCode: -2, message: "") == .cancelled) // userCancel
        #expect(PresenceFailure.from(laErrorCode: -8, message: "Locked") == .unavailable("Locked")) // biometryLockout
    }

    @Test func softwareSignerSignsVerifiably() async throws {
        let authorizer = SoftwarePresenceAuthorizer()
        let proof = try await PresenceProof.make(signer: authorizer.signer(reason: "Merge acme/api#12"),
                                                 sessionHash: Data(count: 32), reqId: 7, commandBytes: Data("x".utf8))
        try PresenceVerifier.verify(proof, publicKey: authorizer.publicKey, sessionHash: Data(count: 32), reqId: 7,
                                    commandBytes: Data("x".utf8), now: Date())
        #expect(authorizer.reasons == ["Merge acme/api#12"])
    }
}
