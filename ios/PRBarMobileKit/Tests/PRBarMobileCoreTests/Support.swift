import Foundation
import Testing
import PRBarRemoteKit
import PRBarWire
@testable import PRBarMobileCore

/// A connected phone over a `FakeTransport`, with the design's sample data in the store.
@MainActor
struct TestEnv {
    let transport: FakeTransport
    let store: AppStore
    let connection: RemoteConnection
    let keychain: DeviceKeychain
    let keychainBackend: InMemoryKeychain
    let authorizer: SoftwarePresenceAuthorizer
    let runner: ActionRunner

    init(online: Bool = true, home: RemoteHome? = Sample.home, details: [String: RemotePRDetail] = Sample.details,
         cache: Cache? = nil) async {
        transport = FakeTransport()
        store = cache.map { AppStore(cache: $0, now: { Sample.now }) } ?? AppStore(cache: nil, now: { Sample.now })
        keychainBackend = InMemoryKeychain()
        keychain = DeviceKeychain(backend: keychainBackend, accessGroup: "TEAMID.com.federico.prbar.ios.shared")
        connection = RemoteConnection(transport: transport, store: store, credentials: keychain, paired: true,
                                      macName: Sample.macName, sleep: { _ in })
        authorizer = SoftwarePresenceAuthorizer()
        runner = ActionRunner(connection: connection, authorizer: authorizer)
        if online { await connection.handle(.link(.online)) }
        var rev = 1
        if let home {
            store.apply(RemoteStateUpdate(topic: Topic.home, rev: rev, data: try! JSONValue(encoding: home)))
            rev += 1
        }
        for (id, detail) in details {
            store.apply(RemoteStateUpdate(topic: Topic.pr(id), rev: rev, data: try! JSONValue(encoding: detail)))
            rev += 1
        }
    }

    /// Checks a sent proof the way the Mac does (spec P.8).
    func verify(_ sent: FakeTransport.Sent) throws {
        let proof = try #require(sent.presence)
        try PresenceVerifier.verify(proof, publicKey: authorizer.publicKey, sessionHash: transport.sessionHash,
                                    reqId: sent.reqId, commandBytes: sent.commandBytes, now: Date())
    }
}

func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("prbar-mobile-tests-\(UUID().uuidString)")
}

extension RemoteCommand {
    var app: AppCommand? {
        if case .app(let command) = self { return command }
        return nil
    }
}
