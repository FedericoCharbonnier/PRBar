import Foundation
import PRBarCore

struct InstallBoom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
enum UpdateSessionTests {
    static func makeSession(jobs: Box<Int> = Box(0), cancels: Box<Int> = Box(0)) -> UpdateInstallSession {
        UpdateInstallSession(
            activeJobs: { jobs.value },
            cancelJobs: { cancels.value += 1; jobs.value = 0 },
            pollInterval: .milliseconds(5)
        )
    }

    static let cases: [TestCase] = [
        TestCase("update session: begin pasa a instalando en el acto y un segundo begin falla") { @MainActor in
            let session = makeSession()
            try expectEqual(session.state, .idle)
            try expectEqual(session.blockedReason, nil)
            try session.begin()
            try expectEqual(session.state, .running(.fetching))
            try expect(session.isInstalling)
            try expect(session.blockedReason != nil)
            let error = try await expectThrows { try session.begin() }
            try expectEqual(error as? UpdateError, .alreadyInstalling)
        },
        TestCase("update session: un error en la instalación deja failed y se relanza") { @MainActor in
            let session = makeSession()
            try session.begin()
            let error = try await expectThrows {
                try await session.run(.wait, onEvent: { _ in }) { _ in throw InstallBoom() }
            }
            try expect(error is InstallBoom, "\(error)")
            try expectEqual(session.state, .failed("boom"))
            try expectEqual(session.blockedReason, nil)
            // Después de fallar se puede volver a empezar.
            try session.begin()
        },
        TestCase("update session: cancelar deja idle y se relanza") { @MainActor in
            let session = makeSession()
            try session.begin()
            let error = try await expectThrows {
                try await session.run(.wait, onEvent: { _ in }) { _ in throw CancellationError() }
            }
            try expect(error is CancellationError, "\(error)")
            try expectEqual(session.state, .idle)
        },
        TestCase("update session: run sin begin falla sin correr nada") { @MainActor in
            let session = makeSession()
            let ran = Box(false)
            _ = try await expectThrows {
                try await session.run(.wait, onEvent: { _ in }) { _ in ran.value = true }
            }
            try expect(!ran.value)
            try expectEqual(session.state, .idle)
        },
        TestCase("update session: cancelJobs cancela al empezar; beforeReplace solo espera, no cancela") { @MainActor in
            let jobs = Box(2)
            let cancels = Box(0)
            let session = makeSession(jobs: jobs, cancels: cancels)
            let events = Box<[UpdateEvent]>([])
            try session.begin()
            try await session.run(.cancelJobs, onEvent: { events.value.append($0) }) { beforeReplace in
                try expectEqual(cancels.value, 1)
                // Algo que arrancó durante el build (p. ej. una publicación) se espera, no se cancela.
                jobs.value = 1
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(30))
                    jobs.value = 0
                }
                try await beforeReplace()
                try expectEqual(jobs.value, 0)
            }
            try expectEqual(cancels.value, 1)
            try expect(events.value.contains(.phase(.waitingForJobs)))
        },
        TestCase("update session: con wait no cancela nada y espera a que terminen") { @MainActor in
            let jobs = Box(1)
            let cancels = Box(0)
            let session = makeSession(jobs: jobs, cancels: cancels)
            try session.begin()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                jobs.value = 0
            }
            let started = Box(false)
            try await session.run(.wait, onEvent: { _ in }) { _ in
                try expectEqual(jobs.value, 0)
                started.value = true
            }
            try expect(started.value)
            try expectEqual(cancels.value, 0)
        },
        TestCase("update session: enter cambia la etapa solo mientras instala") { @MainActor in
            let session = makeSession()
            session.enter(.building)
            try expectEqual(session.state, .idle)
            try session.begin()
            session.enter(.building)
            try expectEqual(session.state, .running(.building))
        },
    ]
}
