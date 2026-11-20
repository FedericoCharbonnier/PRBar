import Foundation
import PRBarCore

private let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))

private func coordinator(_ ssh: FakeSSH, unreachable: Bool = false, registry: ProcessRegistry = .shared) -> RunnerCoordinator {
    RunnerCoordinator(makeHost: { destination in
        SSHHost(destination: destination, installationID: FakeSSH.installationID, sshPath: ssh.executable.path,
                controlDirectory: ssh.controlDirectory, enforceHostKey: true,
                sshEnvironment: ssh.environment(unreachable: unreachable), killGracePeriod: 1,
                local: SystemProcessRunner(registry: registry))
    })
}

/// Un `ssh` falso con `claude` instalado (host sano).
private func healthyHost() throws -> FakeSSH {
    let ssh = try FakeSSH.make()
    try ssh.installFakeClaude()
    _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
    return ssh
}

/// Dónde corrió cada parte y qué placements se informaron.
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var _placements: [JobPlacement] = []
    private var _ran: [String] = []
    private var _hosts: [String?] = []

    var placements: [JobPlacement] { lock.withLock { _placements } }
    var ran: [String] { lock.withLock { _ran } }
    /// `ProcessActivity.current?.host` dentro de cada parte.
    var hosts: [String?] { lock.withLock { _hosts } }

    func placement(_ placement: JobPlacement) { lock.withLock { _placements.append(placement) } }
    func ran(_ where: String) {
        let host = ProcessActivity.current?.host
        lock.withLock {
            _ran.append(`where`)
            _hosts.append(host)
        }
    }
}

private let preparationFailure = RemotePreparationFailure(
    host: "devbox", underlying: RemoteRunnerError.cannotFetch(host: "devbox", repo: "acme/api"))

enum RunnerDispatchTests {
    static let cases: [TestCase] = [
        TestCase("dispatch: sin destino corre en esta Mac, sin host en la tarea") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let trace = Trace()
            let result = try await ProcessActivity.$current.withValue(.review("acme/api#1")) {
                try await RunnerDispatch.run(destination: nil, coordinator: coordinator(ssh),
                                             onPlacement: { trace.placement($0) },
                                             local: { trace.ran("local"); return 1 },
                                             remote: { _ in trace.ran("remote"); return 2 })
            }
            try expectEqual(result, 1)
            try expectEqual(trace.placements, [.local])
            try expectEqual(trace.hosts, [nil])
            try expectEqual(ssh.invocations().count, 0)
        },
        TestCase("dispatch: con un host sano corre ahí, con la tarea \"on devbox\"") {
            let ssh = try healthyHost()
            defer { ssh.remove() }
            let trace = Trace()
            let result = try await ProcessActivity.$current.withValue(.review("acme/api#1")) {
                try await RunnerDispatch.run(destination: devbox, coordinator: coordinator(ssh),
                                             onPlacement: { trace.placement($0) },
                                             local: { trace.ran("local"); return "local" },
                                             remote: { placement in trace.ran("remote"); return placement.name })
            }
            try expectEqual(result, "devbox")
            try expectEqual(trace.placements, [.remote(host: "devbox")])
            try expectEqual(trace.ran, ["remote"])
            try expectEqual(trace.hosts, ["devbox"])
        },
        TestCase("dispatch: una falla de preparación (también dentro de ReviewFailure) cae a esta Mac con el motivo") {
            let ssh = try healthyHost()
            defer { ssh.remove() }
            for thrown in [preparationFailure as Error, ReviewFailure(underlying: preparationFailure, logURL: nil)] {
                let trace = Trace()
                let result = try await RunnerDispatch.run(
                    destination: devbox, coordinator: coordinator(ssh), onPlacement: { trace.placement($0) },
                    local: { () -> String in trace.ran("local"); return "local" },
                    remote: { _ -> String in trace.ran("remote"); throw thrown })
                try expectEqual(result, "local")
                try expectEqual(trace.ran, ["remote", "local"])
                try expectEqual(trace.placements, [.remote(host: "devbox"), .fallback(preparationFailure.fallback)])
                try expectEqual(trace.placements.last?.label, "Ran on this Mac — devbox couldn’t prepare the repo")
            }
        },
        TestCase("dispatch: sin fallback, sin carpeta local o en un chat, la falla de preparación no cae a esta Mac") {
            let ssh = try healthyHost()
            defer { ssh.remove() }
            var noFallback = devbox
            noFallback.fallbackToLocal = false
            let variants: [(RunnerDestination, Bool, Bool)] = [(noFallback, true, true), (devbox, false, true), (devbox, true, false)]
            for (destination, canRunLocally, onPreparation) in variants {
                let trace = Trace()
                let error = try await expectThrows {
                    _ = try await RunnerDispatch.run(
                        destination: destination, coordinator: coordinator(ssh), fallbackOnPreparation: onPreparation,
                        canRunLocally: canRunLocally, onPlacement: { trace.placement($0) },
                        local: { () -> Int in trace.ran("local"); return 0 },
                        remote: { _ -> Int in trace.ran("remote"); throw preparationFailure })
                }
                try expect(error is RemotePreparationFailure, "\(error)")
                try expectEqual(trace.ran, ["remote"])
                try expectEqual(trace.placements, [.remote(host: "devbox")])
            }
        },
        TestCase("dispatch: una vez que arrancó Claude no hay fallback (Claude puede seguir en el host)") {
            let ssh = try healthyHost()
            defer { ssh.remove() }
            let trace = Trace()
            let error = try await expectThrows {
                _ = try await RunnerDispatch.run(
                    destination: devbox, coordinator: coordinator(ssh), onPlacement: { trace.placement($0) },
                    local: { () -> Int in trace.ran("local"); return 0 },
                    remote: { _ -> Int in trace.ran("remote"); throw ReviewFailure(underlying: RemoteRunnerError.jobNotStopped(host: "devbox"), logURL: nil) })
            }
            try expect(RemoteUnstoppedJobs.isNotStopped(error), "\(error)")
            try expectEqual(trace.ran, ["remote"])
        },
        TestCase("dispatch: host caído → esta Mac con el motivo; sin carpeta local, el error del host") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let down = coordinator(ssh, unreachable: true)
            let trace = Trace()
            let result = try await RunnerDispatch.run(destination: devbox, coordinator: down, onPlacement: { trace.placement($0) },
                                                      local: { trace.ran("local"); return "local" },
                                                      remote: { _ in trace.ran("remote"); return "remote" })
            try expectEqual(result, "local")
            guard case .fallback(let fallback)? = trace.placements.first, trace.placements.count == 1 else {
                throw TestFailure(description: "\(trace.placements)")
            }
            try expectEqual(fallback.cause, .unreachable)
            try expectEqual(fallback.repoWarning, "Last job ran on this Mac — devbox was unreachable (fallback).")
            await down.forget("devbox")
            let strict = Trace()
            let error = try await expectThrows {
                _ = try await RunnerDispatch.run(destination: devbox, coordinator: down, canRunLocally: false,
                                                 onPlacement: { strict.placement($0) },
                                                 local: { strict.ran("local"); return "local" },
                                                 remote: { _ in strict.ran("remote"); return "remote" })
            }
            try expect(error is RemoteRunnerError, "\(error)")
            try expectEqual(strict.ran, [])
        },
        TestCase("dispatch: lo fijado sigue donde empezó; un host quitado de la configuración es un error claro") {
            let ssh = try healthyHost()
            defer { ssh.remove() }
            var settings = RunnerSettings()
            settings.destinations = [devbox]
            let trace = Trace()
            let local = try await RunnerDispatch.pinned(runner: nil, settings: settings, coordinator: coordinator(ssh),
                                                        onPlacement: { trace.placement($0) },
                                                        local: { trace.ran("local"); return "local" },
                                                        remote: { _ in trace.ran("remote"); return "remote" })
            try expectEqual(local, "local")
            try expectEqual(trace.placements, [])
            let remote = try await ProcessActivity.$current.withValue(.respond("acme/api#1")) {
                try await RunnerDispatch.pinned(runner: "DEVBOX", settings: settings, coordinator: coordinator(ssh),
                                                onPlacement: { trace.placement($0) },
                                                local: { trace.ran("local"); return "local" },
                                                remote: { placement in trace.ran("remote"); return placement.name })
            }
            try expectEqual(remote, "devbox")
            try expectEqual(trace.placements, [.remote(host: "devbox")])
            try expectEqual(trace.hosts, [nil, "devbox"])
            let error = try await expectThrows {
                _ = try await RunnerDispatch.pinned(runner: "gone", settings: settings, coordinator: coordinator(ssh),
                                                    onPlacement: { trace.placement($0) },
                                                    local: { "local" }, remote: { _ in "remote" })
            }
            try expectEqual(error.localizedDescription, "This ran on gone, which isn’t in Settings › Claude › Run On anymore. Start it again.")
        },
        TestCase("dispatch: el chat de Respond usa el host del análisis; Review/Merge el de su worktree o el del repo") {
            let pr = makePR(number: 7)
            let review = ReviewDraft(prID: pr.id, repo: pr.repo, number: 7, title: pr.title, url: pr.url, author: pr.author,
                                     headOid: pr.headOid, account: "fede", summary: "s", items: [])
            var session = ChatSession(prID: pr.id, kind: .review)
            try expectEqual(RunnerDispatch.chatTarget(subject: .review(review), session: session), .repoDestination)
            session.worktreePath = "/tmp/wt/chat"
            try expectEqual(RunnerDispatch.chatTarget(subject: .review(review), session: session), .pinned(nil))
            session.runner = "devbox"
            try expectEqual(RunnerDispatch.chatTarget(subject: .review(review), session: session), .pinned("devbox"))
            // Se guarda con la sesión (y una sesión vieja, sin el campo, es de esta Mac).
            let decoded = try JSONDecoder().decode(ChatSession.self, from: try JSONEncoder().encode(session))
            try expectEqual(decoded.runner, "devbox")
            var respond = RespondDraft(id: UUID(), prID: pr.id, repo: pr.repo, number: 7, title: pr.title, url: pr.url,
                                       headRef: pr.headRef, account: "fede",
                                       worktree: ResolvedWorktree(path: "/w", origin: .dedicated), startHeadOid: "", items: [])
            respond.runner = "devbox"
            try expectEqual(RunnerDispatch.chatTarget(subject: .respond(respond), session: ChatSession(prID: pr.id, kind: .respond)),
                            .pinned("devbox"))
        },
        TestCase("dispatch: la fila dice dónde corrió cada PR; el aviso del repo queda hasta un trabajo que no cae") {
            var book = RunnerPlacements()
            let repo = RepoRef(owner: "acme", name: "api")
            let fallback = RunnerFallback(host: "devbox", cause: .unreachable)
            book.record(.remote(host: "devbox"), prID: "acme/api#1", repo: repo)
            try expectEqual(book.label(prID: "acme/api#1"), "on devbox")
            try expectEqual(book.repoWarning(repo), nil)
            book.record(.fallback(fallback), prID: "acme/api#2", repo: repo)
            try expectEqual(book.label(prID: "acme/api#2"), "Ran on this Mac — devbox unreachable")
            try expectEqual(book.repoWarning(RepoRef(owner: "ACME", name: "API")), "Last job ran on this Mac — devbox was unreachable (fallback).")
            try expectEqual(book.fallback(for: repo), fallback)
            book.record(.local, prID: "acme/api#1", repo: repo)
            try expectEqual(book.placement(prID: "acme/api#1"), nil)
            try expectEqual(book.repoWarning(repo), nil)
            try expectEqual(book.label(prID: "acme/api#2"), "Ran on this Mac — devbox unreachable")
        },
        TestCase("dispatch: el ssh de un trabajo remoto se anota \"on devbox\" y no suma CPU ni RAM locales") {
            let ssh = try healthyHost()
            defer { ssh.remove() }
            let registry = ProcessRegistry()
            let coordinator = coordinator(ssh, registry: registry)
            let seen = Trace()
            let job = Task {
                try await ProcessActivity.$current.withValue(.review("acme/api#9")) {
                    try await RunnerDispatch.run(destination: devbox, coordinator: coordinator, onPlacement: { seen.placement($0) },
                                                 local: { 0 },
                                                 remote: { placement in
                                                     try await placement.host.runScript("sleep 1", timeout: 10).status
                                                 })
                }
            }
            try await waitUntil { registry.all().contains { $0.activity?.host == "devbox" } }
            let rows = registry.all().filter { $0.activity?.host == "devbox" }
            try expectEqual(Set(rows.map(\.activity?.title)), ["Review api#9"])
            try expectEqual(Set(rows.map(\.executable)), ["ssh"])
            _ = try await job.value
            try expect(!registry.all().contains { $0.activity?.host == "devbox" }, "\(registry.all())")
            // El medidor: el ssh y lo que cuelgue de él son el trabajo remoto, sin CPU/RAM de esta Mac.
            let pid = Int32(4242)
            let child = Int32(4243)
            let before = ProcessSample(date: t0, parents: [pid: 1, child: pid],
                                       stats: [pid: ProcessStat(pid: pid, name: "ssh", cpuNanos: 0, memoryBytes: 9_000, startedAt: t0),
                                               child: ProcessStat(pid: child, name: "sh", cpuNanos: 0, memoryBytes: 1_000, startedAt: t0)])
            var after = before
            after.date = t0.addingTimeInterval(1)
            after.stats[pid]?.cpuNanos = 800_000_000
            after.stats[child]?.cpuNanos = 200_000_000
            let registered = [pid: RegisteredProcess(pid: pid, executable: "ssh", activity: ProcessActivity.review("acme/api#9").on(host: "devbox"),
                                                     startedAt: t0)]
            let usage = ResourceMeter.usage(previous: before, current: after, registered: registered)
            try expectEqual(usage.cpuPercent, 0)
            try expectEqual(usage.memoryBytes, 0)
            try expectEqual(Set(usage.processes.map(\.remoteHost)), ["devbox"])
        },
    ]
}
