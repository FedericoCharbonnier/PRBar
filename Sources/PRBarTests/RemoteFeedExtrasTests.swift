import CryptoKit
import Foundation
import PRBarCore
import PRBarRemoteKit
import PRBarRemoteMac

/// Lo que el iPhone muestra y ningún comando necesitaba (spec R.7), y el estado de la conexión de `RemoteClient`.
enum RemoteFeedExtrasTests {
    static let cases: [TestCase] = [
        TestCase("feed extras: resumen de tests de Jest, pytest, XCTest, cargo, Mocha y Swift Testing") {
            try expectEqual(TestSummary.extract(from: "Tests:       2 failed, 140 passed, 142 total\nTime: 3 s"),
                            "140 passed, 2 failed")
            try expectEqual(TestSummary.extract(from: "==== 142 passed in 3.21s ===="), "142 passed")
            try expectEqual(TestSummary.extract(from: "Executed 12 tests, with 1 failure (0 unexpected) in 0.2 s"),
                            "11 passed, 1 failed")
            try expectEqual(TestSummary.extract(from: "test result: ok. 31 passed; 0 failed; 0 ignored"), "31 passed")
            try expectEqual(TestSummary.extract(from: "  9 passing (40ms)\n  1 failing"), "9 passed, 1 failed")
            try expectEqual(TestSummary.extract(from: "Test run with 93 tests passed after 0.2 seconds."), "93 passed")
            try expectEqual(TestSummary.extract(from: "Build succeeded"), nil)
        },
        TestCase("feed extras: aprobaciones = revisores cuyo último review que cuenta es un approve") {
            let pr = makePR(author: "juan", reviews: [
                review("ana", .approved, at: 1), review("ana", .commented, at: 2),
                review("luis", .approved, at: 1), review("luis", .changesRequested, at: 3),
                review("eva", .changesRequested, at: 1), review("eva", .approved, at: 4),
                review("bot", .approved, at: 1, bot: true), review("juan", .approved, at: 1),
            ])
            try expectEqual(pr.approvalCount, 2)
            let info = PRInfo(item: ClassifiedPR(pr: makePR(), category: .other, account: "me"),
                              review: nil, respond: nil)
            try expectEqual(info.approvals, nil)
        },
        TestCase("feed extras: el Fix CI guarda duración, cola del log saneada y total de checks") {
            var run = ciRun("build", id: 1)
            run.startedAt = t0
            run.completedAt = t0.addingTimeInterval(72)
            let log = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n\u{1B}[31merror: token ghp_SECRET\u{1B}[0m\n\n"
            let (_, context) = CIFixItem.make(headOid: ciHead, failing: [run, ciRun("lint")], logs: [1: log],
                                              secrets: ["ghp_SECRET"], prURL: URL(string: "https://github.com/a/b/pull/1")!,
                                              total: 9)
            try expectEqual(context.totalChecks, 9)
            try expectEqual(context.checks[0].durationSeconds, 72)
            let excerpt = try expectNotNil(context.checks[0].logExcerpt)
            try expectEqual(excerpt.count, CICheckFailure.logExcerptLines)
            try expect(excerpt.last?.hasPrefix("error: token") == true)
            try expect(!excerpt.joined().contains("ghp_SECRET"), "el secreto quedó en la cola")
            try expect(!excerpt.joined().contains("\u{1B}"))
            try expectEqual(context.checks[1].logExcerpt, nil)
            try expectEqual(context.checks[1].durationSeconds, nil)
        },
        TestCase("feed extras: los trabajos en curso toman la hora del proceso más viejo de su tipo") {
            func process(_ kind: ProcessActivity.Kind, _ pr: String, _ minutes: Int) -> ProcessUsage {
                ProcessUsage(pid: 1, name: "claude", activity: ProcessActivity(kind: kind, prID: pr, title: "x"),
                             cpuPercent: 0, memoryBytes: 0, startedAt: at(minutes), isApp: false)
            }
            let jobs = [JobInfo(pr: "a/b#1", kind: "respond", phase: "implementing"),
                        JobInfo(pr: "a/b#2", kind: "review", phase: "queued")]
            let running = RemoteStateTopics.running(
                jobs, processes: [process(.ciFix, "a/b#1", 5), process(.respond, "a/b#1", 3), process(.review, "a/b#1", 1),
                                  process(.chat, "a/b#2", 0)],
                titles: ["a/b#1": "Fix the build"])
            try expectEqual(running, [
                RunningJobInfo(pr: "a/b#1", kind: "respond", title: "Fix the build", phase: "implementing", startedAt: at(3)),
                RunningJobInfo(pr: "a/b#2", kind: "review", title: "a/b#2", phase: "queued", startedAt: nil),
            ])
        },
        TestCase("feed extras: los totales de la Mac son razonables") {
            let info = try expectNotNil(MacSystemSampler.sample())
            try expect(info.cores >= 1)
            try expect(info.memoryUsedBytes > 0 && info.memoryUsedBytes <= info.memoryTotalBytes)
            try expect(info.diskFreeBytes > 0 && info.diskFreeBytes <= info.diskTotalBytes)
        },
        TestCase("remote client: cada cambio de estado se avisa y el código de cierre del relay queda a la vista") {
            let h = try await RemoteHarness.make()
            let client = try await h.pairedClient()
            let updates = client.statusUpdates
            let seen = Box<[RemoteClientStatus]>([])
            let reader = Task { for await status in updates { seen.value.append(status) } }
            defer { reader.cancel() }
            try await client.connect()
            let paired = await client.paired!
            await h.relay.closeDevice(h.account, paired.deviceId, code: 4403)
            try await eventually(3, "relayRejected") { seen.value.last == .relayRejected }
            try expect(seen.value.contains(.online))
            let code = await client.lastRelayCloseCode
            try expectEqual(code, 4403)
        },
        TestCase("remote client: el emparejamiento usa las claves que le da la app") {
            let h = try await RemoteHarness.make()
            let client = h.client()
            let keys = DeviceKeys()
            let qr = try await h.openPairing()
            async let join = h.nextJoin()
            _ = try await client.startPairing(qr: qr, presence: h.presence.credential, keys: keys)
            _ = try await join
            try await h.host.confirmPairing(true)
            _ = try await within { try await client.finishPairing() }
            let stored = await client.keys
            try expectEqual(stored?.noise.publicKey.rawRepresentation, keys.noise.publicKey.rawRepresentation)
            try expectEqual(stored?.relay.publicKey.rawRepresentation, keys.relay.publicKey.rawRepresentation)
        },
    ]
}
