import Foundation
import PRBarCore

private func coordinator(_ ssh: FakeSSH, unreachable: Bool = false) -> RunnerCoordinator {
    RunnerCoordinator(makeHost: { destination in
        SSHHost(destination: destination, installationID: FakeSSH.installationID, sshPath: ssh.executable.path,
                controlDirectory: ssh.controlDirectory, enforceHostKey: true,
                sshEnvironment: ssh.environment(unreachable: unreachable), killGracePeriod: 1)
    })
}

private let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))

/// `SSHHost.live` con el `ssh` de mentira que dice ser `version`.
private func liveHost(_ ssh: FakeSSH, version: String?) async throws -> SSHHost {
    try await SSHHost.live(devbox, sshPath: ssh.executable.path,
                           installationIDFile: ssh.base.appendingPathComponent("support/installation-id"),
                           controlDirectory: ssh.controlDirectory, sshEnvironment: ssh.environment(version: version))
}

enum RunnerCoordinatorTests {
    static let cases: [TestCase] = [
        TestCase("coordinator: sin destino es esta Mac; con uno sano, remoto") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let coordinator = coordinator(ssh)
            let local = try await coordinator.choice(for: nil)
            guard case .local = local else { throw TestFailure(description: "\(local)") }
            try expectEqual(local.jobPlacement, .local)
            let remote = try await coordinator.choice(for: devbox)
            guard case .remote(let placement) = remote else { throw TestFailure(description: "\(remote)") }
            try expectEqual(placement.name, "devbox")
            try expectEqual(remote.jobPlacement, .remote(host: "devbox"))
            try expectEqual(remote.jobPlacement.label, "on devbox")
            let cached = await coordinator.lastInfo("DEVBOX")
            try expect(cached?.isUsable == true, "\(String(describing: cached))")
        },
        TestCase("coordinator: host caído con fallback → esta Mac con el motivo; sin fallback → error") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let coordinator = coordinator(ssh, unreachable: true)
            var destination = devbox
            let choice = try await coordinator.choice(for: destination)
            guard case .fallback(let fallback) = choice else { throw TestFailure(description: "\(choice)") }
            try expectEqual(fallback.host, "devbox")
            try expectEqual(fallback.cause, .unreachable)
            try expectEqual(fallback.reason, "devbox unreachable")
            try expect(fallback.detail.contains("Connection refused"), fallback.detail)
            try expectEqual(choice.jobPlacement.label, "Ran on this Mac — devbox unreachable")
            try expectEqual(fallback.repoWarning, "Last job ran on this Mac — devbox was unreachable (fallback).")
            destination.fallbackToLocal = false
            await coordinator.forget("devbox")
            let error = try await expectThrows { _ = try await coordinator.choice(for: destination) }
            try expect(error is RemoteRunnerError, "\(error)")
        },
        TestCase("coordinator: un host con problemas (sin claude) también cae a esta Mac, con el problema") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let choice = try await coordinator(ssh).choice(for: devbox)
            guard case .fallback(let fallback) = choice else { throw TestFailure(description: "\(choice)") }
            try expect(fallback.reason.hasPrefix("devbox "), fallback.reason)
            try expectEqual(fallback.cause, .notReady)
            try expect(fallback.detail.contains("claude isn’t installed"), fallback.detail)
            try expectEqual(fallback.repoWarning, "Last job ran on this Mac — devbox wasn’t ready (fallback).")
        },
        TestCase("coordinator: la verificación se cachea; placement(force:) la repite") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let coordinator = coordinator(ssh)
            _ = try await coordinator.choice(for: devbox)
            let afterFirst = ssh.invocations().count
            _ = try await coordinator.choice(for: devbox)
            try expectEqual(ssh.invocations().count, afterFirst)
            _ = try await coordinator.placement(for: devbox, force: true)
            try expectEqual(ssh.invocations().count, afterFirst + 1)
        },
        TestCase("coordinator: Test Connection prueba el login de Claude y lo informa") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let coordinator = coordinator(ssh)
            try Data("ok".utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let good = await coordinator.test(devbox)
            try expect(good.isUsable && good.claudeLoggedIn == true, "\(good)")
            try Data("Invalid API key".utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let bad = await coordinator.test(devbox)
            try expectEqual(bad.claudeLoggedIn, false)
            try expect(bad.problems.contains { $0.contains("Claude isn’t signed in on devbox") }, "\(bad.problems)")
            let down = await RunnerCoordinator(makeHost: { destination in
                SSHHost(destination: destination, installationID: FakeSSH.installationID, sshPath: ssh.executable.path,
                        controlDirectory: ssh.controlDirectory, enforceHostKey: true,
                        sshEnvironment: ssh.environment(unreachable: true), killGracePeriod: 1)
            }).test(devbox)
            try expect(!down.isUsable && down.problems.contains { $0.contains("devbox is unreachable") }, "\(down.problems)")
        },
        TestCase("coordinator: una falla de preparación da el mismo tipo de fallback") {
            let failure = RemotePreparationFailure(host: "devbox", underlying: RemoteRunnerError.cannotFetch(host: "devbox", repo: "acme/api"))
            try expectEqual(failure.fallback.cause, .preparation)
            try expectEqual(failure.shortReason, "devbox couldn’t prepare the repo")
            try expectEqual(JobPlacement.fallback(failure.fallback).label, "Ran on this Mac — devbox couldn’t prepare the repo")
            try expectEqual(failure.fallback.repoWarning, "Last job ran on this Mac — devbox couldn’t prepare the repo (fallback).")
            let down = RemotePreparationFailure(host: "devbox", underlying: RemoteRunnerError.unreachable(host: "devbox", detail: ""))
            try expectEqual(down.fallback.cause, .unreachable)
            let data = try JSONEncoder().encode(down.fallback)
            try expectEqual(try JSONDecoder().decode(RunnerFallback.self, from: data), down.fallback)
            try expectEqual(JobPlacement.local.label, nil)
        },
        TestCase("openssh: lee la versión de ssh -V") {
            try expectEqual(OpenSSHVersion.parse("OpenSSH_10.2p1, LibreSSL 3.3.6").map { [$0.0, $0.1] }, [10, 2])
            try expectEqual(OpenSSHVersion.parse("OpenSSH_8.6p1 Ubuntu-4ubuntu0.5, OpenSSL 3.0.2 15 Mar 2022").map { [$0.0, $0.1] }, [8, 6])
            try expectEqual(OpenSSHVersion.parse("OpenSSH_for_Windows_8.1p1, LibreSSL 3.0.2").map { [$0.0, $0.1] }, [8, 1])
            try expectEqual(OpenSSHVersion.parse("Sun_SSH_1.1").map { [$0.0, $0.1] }, nil)
            try expectEqual(OpenSSHVersion.parse("").map { [$0.0, $0.1] }, nil)
            // El ssh del sistema (solo `-V`, no conecta a nada).
            try await OpenSSHVersion.require(sshPath: "/usr/bin/ssh")
        },
        TestCase("openssh: un ssh propio necesita OpenSSH 8.7 o más nuevo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let ok = try await liveHost(ssh, version: "OpenSSH_8.7p1, OpenSSL 1.1.1k")
            try expectEqual(ok.sshPath, ssh.executable.path)
            try expect(ssh.invocations().contains { $0 == ["-V"] }, "\(ssh.invocations())")
            let old = try await expectThrows { _ = try await liveHost(ssh, version: "OpenSSH_8.6p1, OpenSSL 1.1.1k") }
            try expectEqual(old as? RemoteRunnerError, .sshTooOld(path: ssh.executable.path, version: "OpenSSH_8.6p1"))
            try expectEqual((old as? LocalizedError)?.errorDescription,
                            "\(ssh.executable.path) is OpenSSH_8.6p1; PRBar needs OpenSSH 8.7 or later.")
            let unknown = try await expectThrows { _ = try await liveHost(ssh, version: "Dropbear v2022.83") }
            try expectEqual(unknown as? RemoteRunnerError, .sshTooOld(path: ssh.executable.path, version: nil))
            try expect((unknown as? LocalizedError)?.errorDescription?.contains("needs OpenSSH 8.7 or later") == true,
                       "\(unknown)")
            let missing = try await expectThrows {
                _ = try await SSHHost.live(devbox, sshPath: ssh.base.appendingPathComponent("nope/ssh").path,
                                           installationIDFile: ssh.base.appendingPathComponent("support/installation-id"),
                                           controlDirectory: ssh.controlDirectory)
            }
            try expectEqual(missing as? RemoteRunnerError, .sshTooOld(path: ssh.base.appendingPathComponent("nope/ssh").path, version: nil))
        },
        TestCase("openssh: un ssh propio viejo hace caer el trabajo a esta Mac, con el motivo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let coordinator = RunnerCoordinator(makeHost: { _ in try await liveHost(ssh, version: "OpenSSH_8.2p1") })
            let choice = try await coordinator.choice(for: devbox)
            guard case .fallback(let fallback) = choice else { throw TestFailure(description: "\(choice)") }
            try expect(fallback.detail.contains("OpenSSH 8.7"), fallback.detail)
            let info = await coordinator.test(devbox)
            try expect(info.problems.contains { $0.contains("needs OpenSSH 8.7") }, "\(info.problems)")
            // Ningún comando remoto llegó a correr con ese ssh.
            try expect(ssh.invocations().allSatisfy { $0 == ["-V"] }, "\(ssh.invocations())")
        },
    ]
}
