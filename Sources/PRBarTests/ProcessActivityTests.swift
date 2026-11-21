import Foundation
import PRBarCore

enum ProcessActivityTests {
    static let cases: [TestCase] = [
        TestCase("activity: títulos y PR corto") {
            try expectEqual(ProcessActivity.review("acme/api#317").title, "Review api#317")
            try expectEqual(ProcessActivity.respond("acme/web#2").title, "Respond web#2")
            try expectEqual(ProcessActivity.chat("acme/api#4").title, "Chat api#4")
            try expectEqual(ProcessActivity.update.title, "Update build")
            try expectEqual(ProcessActivity.review("acme/api#1").on(host: "devbox").host, "devbox")
        },
        TestCase("activity: el runner anota el proceso con la tarea mientras corre y lo borra al terminar") {
            let registry = ProcessRegistry()
            let runner = SystemProcessRunner(registry: registry)
            let task = Task {
                try await ProcessActivity.$current.withValue(.review("acme/api#9")) {
                    try await runner.run("/bin/sleep", ["1"], timeout: 10)
                }
            }
            var seen: RegisteredProcess?
            for _ in 0..<40 where seen == nil {
                try await Task.sleep(for: .milliseconds(25))
                seen = registry.all().first
            }
            try expectEqual(seen?.executable, "sleep")
            try expectEqual(seen?.activity, .review("acme/api#9"))
            _ = try await task.value
            let after = registry.all()
            try expect(after.isEmpty, "quedó anotado: \(after)")
        },
        TestCase("activity: al salir, SIGTERM a todo lo que sigue vivo y SIGKILL a lo que lo ignora (M4)") {
            let registry = ProcessRegistry()
            // Sin el SIGKILL propio del runner: solo el de `ProcessShutdown`.
            let runner = SystemProcessRunner(killGracePeriod: 60, registry: registry)
            let polite = Task { try await runner.run("/bin/sleep", ["30"], timeout: nil) }
            let stubborn = Task { try await runner.run("/bin/sh", ["-c", "trap '' TERM; /bin/sleep 30"], timeout: nil) }
            for _ in 0..<80 where registry.all().count < 2 { try await Task.sleep(for: .milliseconds(25)) }
            try expectEqual(registry.all().count, 2)
            let started = Date()
            await ProcessShutdown.terminateAll(registry: registry, grace: 1)
            try expect(registry.all().isEmpty, "quedaron vivos: \(registry.all())")
            try expect(Date().timeIntervalSince(started) < 5)
            _ = try? await polite.value
            _ = try? await stubborn.value
        },
        TestCase("activity: sacar un proceso que terminó no borra al que reusó su pid") {
            let registry = ProcessRegistry()
            let old = RegisteredProcess(pid: 7, executable: "git", activity: .review("acme/api#1"), startedAt: t0)
            let reused = RegisteredProcess(pid: 7, executable: "claude", activity: .respond("acme/api#2"), startedAt: t0.addingTimeInterval(1))
            registry.register(old)
            registry.register(reused)
            registry.unregister(old)
            try expectEqual(registry.all(), [reused])
            registry.unregister(reused)
            try expectEqual(registry.all(), [])
        },
        TestCase("activity: un proceso sin tarea queda anotado sin actividad") {
            let registry = ProcessRegistry()
            let runner = SystemProcessRunner(registry: registry)
            let task = Task { try await runner.run("/bin/sleep", ["1"], timeout: 10) }
            var seen: RegisteredProcess?
            for _ in 0..<40 where seen == nil {
                try await Task.sleep(for: .milliseconds(25))
                seen = registry.all().first
            }
            try expect(seen != nil)
            try expectEqual(seen?.activity, nil)
            _ = try await task.value
        },
        TestCase("activity: JobScheduler corre el trabajo con su actividad") { @MainActor in
            let scheduler = JobScheduler<String>(maxConcurrent: 1)
            let seen = JobOutcomeProbe()
            let done = AsyncStream<Void>.makeStream()
            scheduler.enqueue("k", activity: .chat("acme/api#1"), onStart: {}, work: {
                seen.set(ProcessActivity.current)
            }, onComplete: { _ in done.continuation.finish() })
            for await _ in done.stream {}
            try expectEqual(seen.get(), .chat("acme/api#1"))
        },
    ]
}

/// Guarda un valor escrito desde la tarea del trabajo.
final class JobOutcomeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProcessActivity?
    func set(_ new: ProcessActivity?) { lock.withLock { value = new } }
    func get() -> ProcessActivity? { lock.withLock { value } }
}
