import Foundation
import PRBarCore

func remoteWorkspaces(_ host: SSHHost, _ info: RunnerHostInfo, _ root: RemoteRoot, origin: URL,
                      extraURLs: [String] = []) -> RemoteWorkspaces {
    RemoteWorkspaces(host: host, root: root, gitPath: info.gitPath!,
                     runner: RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories),
                     fs: RemoteWorkspaceFS.ssh(host: host, home: (root.path as NSString).deletingLastPathComponent, root: root),
                     gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                      "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
                                      "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid"],
                     remoteURLs: { _ in extraURLs + [origin.path] }, originMatches: { _, _ in true })
}

enum RemoteWorkspacesTests {
    static let cases: [TestCase] = [
        TestCase("remote workspaces: mirror propio, worktree del PR con refs propias, symlinks neutralizados, contexto subido; limpieza") {
            let repo = try TempGitRepo.make(prSetup: { origin in
                try FileManager.default.createSymbolicLink(atPath: origin.appendingPathComponent("evil").path, withDestinationPath: "/etc/passwd")
            })
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin, extraURLs: ["/nonexistent/first-url-fails"])
            let gitHubRepo = RepoRef(owner: "o", name: "r")
            let bare = try await spaces.mirror(gitHubRepo)
            try expectEqual(bare, try root.child(["repos", "o", "r.git"]))
            let workspace = try await spaces.prepare(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare, name: nil, pinnedHeadOid: nil)
            try expectEqual(workspace.headOid, repo.prSHA)
            try expect(root.contains(workspace.directory.path) && workspace.directory.path.hasPrefix(root.work + "/"))
            let evil = try String(contentsOf: workspace.directory.appendingPathComponent("evil"), encoding: .utf8)
            try expect(evil.hasPrefix("[symlink to /etc/passwd omitted by PRBar]"), evil)
            let writer = ReviewContextWriter(runner: spaces.runner, gitPath: info.gitPath!, ghPath: nil, files: spaces.contextFiles)
            let pr = makePR(repo: gitHubRepo, number: 7, base: "main")
            _ = try await writer.write(pr: pr, workspace: workspace, token: "ghp_never_sent", description: "Desc")
            let diff = try String(contentsOf: workspace.diffFile, encoding: .utf8)
            try expect(diff.contains("feature.txt"))
            let invocationsText = ssh.invocations().flatMap { $0 }.joined(separator: " ")
            try expect(!invocationsText.contains("ghp_never_sent"))
            await spaces.cleanup(workspace, localPath: bare)
            try expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
            try expect(!FileManager.default.fileExists(atPath: workspace.contextDirectory.path))
            let refs = try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "refs/prbar/"])
            try expectEqual(refs, "")
            try expect(FileManager.default.fileExists(atPath: bare))
        },
        TestCase("remote workspaces: worktree de Respond desde la rama y limpieza; nombre de rama hostil rechazado") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            let (worktree, start) = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7,
                                                                    headRef: "feature", worktreeDir: nil, runID: "0a0b0c0d")
            try expectEqual(start, repo.prSHA)
            try expectEqual(worktree.path, try root.child(["work", "r-7-respond-0a0b0c0d"]))
            try expectEqual(worktree.localPath, bare)
            for hostile in ["$(touch PWNED)", "-x", "a..b", "a b"] {
                _ = try await expectThrows {
                    _ = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7, headRef: hostile,
                                                        worktreeDir: nil, runID: "0e0e0e0e")
                }
            }
            try expect(!FileManager.default.fileExists(atPath: ssh.home.appendingPathComponent("PWNED").path))
            await spaces.cleanupRespond(worktree)
            try expect(!FileManager.default.fileExists(atPath: worktree.path))
        },
        TestCase("remote workspaces: si el host no puede fetchear, el error lo dice") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = RemoteWorkspaces(host: host, root: root, gitPath: info.gitPath!,
                                          runner: RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories),
                                          fs: RemoteWorkspaceFS.ssh(host: host, home: ssh.home.path, root: root),
                                          remoteURLs: { _ in ["/nonexistent/repo.git"] }, originMatches: { _, _ in true })
            let error = try await expectThrows {
                let bare = try await spaces.mirror(RepoRef(owner: "acme", name: "api"))
                _ = try await spaces.prepare(repo: RepoRef(owner: "acme", name: "api"), number: 1, baseRef: "main", localPath: bare,
                                             name: nil, pinnedHeadOid: nil)
            }
            try expectEqual(error.localizedDescription, "devbox can't fetch acme/api — set up git access on the server.")
        },
        TestCase("remote workspaces: al arrancar se limpian huérfanos viejos solo dentro de la raíz; lo reciente y los mirrors quedan") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            let old = try await spaces.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: bare,
                                               name: nil, pinnedHeadOid: nil)
            let outside = ssh.home.appendingPathComponent("my-own-stuff")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let tmp = URL(fileURLWithPath: root.tmp)
            try Data().write(to: tmp.appendingPathComponent("leftover.stdin"))
            try Data().write(to: tmp.appendingPathComponent("fresh.stdin"))
            try makeOld(old.directory)
            try makeOld(URL(fileURLWithPath: bare + "/refs/prbar"))
            try makeOld(tmp.appendingPathComponent("leftover.stdin"))
            await spaces.cleanupOrphans(keeping: [])
            try expect(!FileManager.default.fileExists(atPath: old.directory.path))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.tmp), ["fresh.stdin"])
            try expect(FileManager.default.fileExists(atPath: bare) && FileManager.default.fileExists(atPath: outside.path))
            let worktrees = try TempGitRepo.run(URL(fileURLWithPath: bare), ["worktree", "list", "--porcelain"])
            try expect(!worktrees.contains(root.work), worktrees)
            try expectEqual(try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "refs/prbar/"]), "")
        },
        TestCase("remote workspaces: huérfanos con dos instalaciones en la misma carpeta, trabajos vivos y el candado") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            // La otra Mac (otra instalación) con la misma carpeta remota.
            let otherHost = try ssh.host(installationID: "00000000-0000-4000-8000-0000000000b2")
            let otherInfo = try await RunnerProbe.check(otherHost)
            let otherRoot = try RemoteRoot(verified: otherInfo.root!)
            try expect(otherRoot != root)
            let other = remoteWorkspaces(otherHost, otherInfo, otherRoot, origin: repo.origin)
            let otherBare = try await other.mirror(RepoRef(owner: "o", name: "r"))
            let otherWork = try await other.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: otherBare,
                                                    name: nil, pinnedHeadOid: nil)
            try makeOld(otherWork.directory)
            try Data("\(getpgrp())\n".utf8).write(to: URL(fileURLWithPath: otherRoot.jobs).appendingPathComponent("x.pid"))

            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            let fresh = try await spaces.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: bare,
                                                 name: nil, pinnedHeadOid: nil)
            let jobs = URL(fileURLWithPath: root.jobs)
            try Data("\(getpgrp())\n".utf8).write(to: jobs.appendingPathComponent("live.pid"))
            try Data("999999\n".utf8).write(to: jobs.appendingPathComponent("dead.pid"))
            try Data().write(to: jobs.appendingPathComponent("dead.cancel"))

            // Otro proceso de esta instalación limpiando (el candado está tomado): no se toca nada.
            let lock = URL(fileURLWithPath: try root.child(["cleanup.lock"]))
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            try makeOld(fresh.directory)
            await spaces.cleanupOrphans(keeping: [])
            try expect(FileManager.default.fileExists(atPath: fresh.directory.path) && FileManager.default.fileExists(atPath: jobs.appendingPathComponent("dead.pid").path))
            try FileManager.default.removeItem(at: lock)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fresh.directory.appendingPathComponent("README.md").path)

            await spaces.cleanupOrphans(keeping: [])
            // Lo de esta instalación: el worktree con cambios recientes queda (con sus refs), el trabajo vivo queda,
            // el muerto se va con su lápida.
            try expect(FileManager.default.fileExists(atPath: fresh.directory.path))
            try expect(!(try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "refs/prbar/"])).isEmpty)
            try expectEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.jobs)), ["live.pid"])
            try expect(!FileManager.default.fileExists(atPath: lock.path))
            // Lo de la otra instalación no se toca, aunque sea viejo.
            try expect(FileManager.default.fileExists(atPath: otherWork.directory.path))
            try expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: otherRoot.jobs).appendingPathComponent("x.pid").path))
            try expect(!(try TempGitRepo.run(URL(fileURLWithPath: otherBare), ["for-each-ref", "refs/prbar/"])).isEmpty)
        },
        TestCase("remote workspaces: leer un archivo de contexto trae a lo sumo el tope (nunca uno enorme ni un symlink infinito)") {
            let (ssh, host, _, root) = try await verifiedFake()
            defer { ssh.remove() }
            let files = RemoteContextFiles(host: host, root: root)
            let dir = URL(fileURLWithPath: try root.child(["work", "r-1-1700000000-0a0b0c0d.context"]))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 65, count: 1000).write(to: dir.appendingPathComponent("exact.diff"))
            try Data(repeating: 65, count: 1001).write(to: dir.appendingPathComponent("big.diff"))
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("zero.diff").path, withDestinationPath: "/dev/zero")
            let exact = await files.read(dir.appendingPathComponent("exact.diff").path, limit: 1000)
            try expectEqual(exact?.count, 1000)
            let big = await files.read(dir.appendingPathComponent("big.diff").path, limit: 1000)
            try expectEqual(big, nil)
            let zero = await files.read(dir.appendingPathComponent("zero.diff").path, limit: 1000)
            try expectEqual(zero, nil)
            let missing = await files.read(dir.appendingPathComponent("missing.diff").path, limit: 1000)
            try expectEqual(missing, nil)
        },
        TestCase("remote workspaces: la limpieza de huérfanos no pisa un trabajo que arranca mientras limpia (refs y worktree nuevos)") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let realGit = info.gitPath!
            let plain = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await plain.mirror(RepoRef(owner: "o", name: "r"))
            // Un `git` que, la próxima vez que la limpieza lista los worktrees, corre antes `race.sh`: un trabajo nuevo
            // que arrancó después de que la limpieza miró `work/`.
            let trigger = ssh.home.appendingPathComponent("race-trigger").path
            let hook = ssh.home.appendingPathComponent("race.sh").path
            try ssh.installTool("racegit", """
            #!/bin/sh
            case "$*" in *"worktree list"*) if [ -f '\(trigger)' ]; then rm -f '\(trigger)'; /bin/sh '\(hook)'; fi ;; esac
            exec '\(realGit)' "$@"
            """)
            let spaces = RemoteWorkspaces(host: host, root: root, gitPath: ssh.home.appendingPathComponent("bin/racegit").path,
                                          runner: plain.runner, fs: plain.fs,
                                          gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                          remoteURLs: { _ in [repo.origin.path] }, originMatches: { _, _ in true })
            func race(_ script: String) throws {
                try Data(script.utf8).write(to: URL(fileURLWithPath: hook))
                try Data().write(to: URL(fileURLWithPath: trigger))
            }
            let refs = { try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "--format=%(refname)", "refs/prbar/"]) }

            // 1. Un huérfano viejo (worktree y refs) y un trabajo que recién fetcheó sus refs (todavía sin worktree).
            let old = try await plain.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: bare,
                                              name: nil, pinnedHeadOid: nil)
            try makeOld(old.directory)
            try makeOld(URL(fileURLWithPath: bare + "/refs/prbar"))
            try race("'\(realGit)' -C '\(bare)' update-ref refs/prbar/pr-10-fetchonly \(repo.prSHA)\n")
            await spaces.cleanupOrphans(keeping: [])
            try expect(!FileManager.default.fileExists(atPath: old.directory.path))
            try expectEqual(try refs().trimmingCharacters(in: .whitespacesAndNewlines), "refs/prbar/pr-10-fetchonly")

            // 2. Un trabajo que agregó su worktree después de que la limpieza miró `work/`.
            let fresh = try root.child(["work", "r-9-1700000000-0a0b0c0d"])
            try race("""
            '\(realGit)' -C '\(bare)' update-ref refs/prbar/pr-9-0a0b0c0d \(repo.prSHA)
            '\(realGit)' -C '\(bare)' worktree add -q --detach '\(fresh)' refs/prbar/pr-9-0a0b0c0d
            """)
            await spaces.cleanupOrphans(keeping: [])
            try expect(FileManager.default.fileExists(atPath: fresh + "/README.md"), "the new worktree was removed")
            let worktrees = try TempGitRepo.run(URL(fileURLWithPath: bare), ["worktree", "list", "--porcelain"])
            try expect(worktrees.contains(fresh), worktrees)
            try expect(try refs().contains("refs/prbar/pr-9-0a0b0c0d"))
        },
        TestCase("remote workspaces: la limpieza de huérfanos deja un worktree viejo con trabajo sin pushear o con un proceso adentro") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            func prepare() async throws -> ReviewWorkspace {
                try await spaces.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: bare,
                                         name: nil, pinnedHeadOid: nil)
            }
            let dirty = try await prepare()
            let busy = try await prepare()
            let clean = try await prepare()
            try Data("wip\n".utf8).write(to: dirty.directory.appendingPathComponent("wip.txt"))
            for workspace in [dirty, busy, clean] { try makeOld(workspace.directory) }
            // A `claude --resume` left open in the folder: its cwd is inside.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            process.currentDirectoryURL = busy.directory
            try process.run()
            defer { process.terminate() }

            await spaces.cleanupOrphans(keeping: [])
            try expect(FileManager.default.fileExists(atPath: dirty.directory.appendingPathComponent("wip.txt").path))
            try expect(FileManager.default.fileExists(atPath: busy.directory.path))
            try expect(!FileManager.default.fileExists(atPath: clean.directory.path))
            let worktrees = try TempGitRepo.run(URL(fileURLWithPath: bare), ["worktree", "list", "--porcelain"])
            try expect(worktrees.contains(dirty.directory.path) && worktrees.contains(busy.directory.path), worktrees)
            // Their refs stay too (a worktree is left in the mirror).
            try expect(!(try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "refs/prbar/"])).isEmpty)
        },
        TestCase("remote workspaces: la review de un PR usa work/<repo>-<N>-review y la reusa en el head nuevo") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let gitHubRepo = RepoRef(owner: "o", name: "r")
            let bare = try await spaces.mirror(gitHubRepo)
            let first = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
            try expectEqual(first.directory.path, try root.child(["work", "r-7-review"]))
            try expectEqual(first.prRef, "refs/prbar/pr-7-review")
            try expectEqual(first.headOid, repo.prSHA)
            let second = try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }

            let again = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
            try expectEqual(again.directory, first.directory)
            try expectEqual(again.headOid, second)
            try expect(FileManager.default.fileExists(atPath: again.directory.appendingPathComponent("second.txt").path))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.work), ["r-7-review"])
            // Con trabajo del usuario (un archivo nuevo) no se toca: la review usa una carpeta propia.
            let mine = again.directory.appendingPathComponent("suelto.txt")
            try Data("mío\n".utf8).write(to: mine)
            let third = try repo.advancePR { try Data("tres\n".utf8).write(to: $0.appendingPathComponent("third.txt")) }
            let fallback = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
            try expect(fallback.directory != again.directory, fallback.directory.path)
            try expectEqual(fallback.headOid, third)
            try expect(FileManager.default.fileExists(atPath: mine.path))
            try expect(!FileManager.default.fileExists(atPath: again.directory.appendingPathComponent("third.txt").path))
            await spaces.cleanup(fallback, localPath: bare)
            try FileManager.default.removeItem(at: mine)
            // Un fetch que falla no la borra.
            let away = repo.base.appendingPathComponent("origin-away")
            try FileManager.default.moveItem(at: repo.origin, to: away)
            do {
                _ = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
                throw TestFailure(description: "el fetch tenía que fallar")
            } catch is RemoteRunnerError {}
            try FileManager.default.moveItem(at: away, to: repo.origin)
            try expect(FileManager.default.fileExists(atPath: again.directory.appendingPathComponent("second.txt").path))
            // Rota (sin worktree registrado): se recrea.
            try TempGitRepo.run(URL(fileURLWithPath: bare), ["worktree", "remove", "--force", again.directory.path])
            try FileManager.default.createDirectory(at: again.directory, withIntermediateDirectories: true)
            let recreated = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
            try expect(FileManager.default.fileExists(atPath: recreated.directory.appendingPathComponent("second.txt").path))
            await spaces.cleanup(recreated, localPath: bare)
            try expectEqual(try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "refs/prbar/"]), "")
        },
        TestCase("remote workspaces: la carpeta del PR ajena (symlink, repo entero, gitdir de otro lado) o con Claude corriendo no se toca") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let gitHubRepo = RepoRef(owner: "o", name: "r")
            let bare = try await spaces.mirror(gitHubRepo)
            let folder = URL(fileURLWithPath: try root.child(["work", "r-7-review"]), isDirectory: true)
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fresh = { () async throws -> ReviewWorkspace in
                let ws = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
                try expect(ws.directory != folder, ws.directory.path)
                await spaces.cleanup(ws, localPath: bare)
                return ws
            }
            // Un symlink a una carpeta de afuera.
            let target = ssh.base.appendingPathComponent("mía", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: target.appendingPathComponent("dato.txt"))
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)
            _ = try await fresh()
            try expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("dato.txt").path))
            try FileManager.default.removeItem(at: folder)
            // Un repo entero (.git carpeta).
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("dato.txt"))
            _ = try await fresh()
            try expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("dato.txt").path))
            try FileManager.default.removeItem(at: folder.appendingPathComponent(".git"))
            // Un .git cuyo gitdir (relativo, o de un mirror que no está) no es de este mirror.
            for gitdir in ["../../repos/x/y.git/worktrees/r-7-review", "/no/existe/y.git/worktrees/r-7-review"] {
                try Data("gitdir: \(gitdir)\n".utf8).write(to: folder.appendingPathComponent(".git"))
                let state = await spaces.reviewFolderState(folder.path, bare: bare)
                try expectEqual(state, .foreign)
                _ = try await fresh()
                try expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("dato.txt").path))
            }
            try FileManager.default.removeItem(at: folder)
            // La carpeta del PR de verdad, con Claude quizás corriendo todavía.
            let first = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare)
            try expectEqual(first.directory.path, folder.path)
            RemoteUnstoppedJobs.shared.insert(host: host.name, path: folder.path)
            try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }
            _ = try await fresh()
            try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("second.txt").path))
            try expectEqual(try TempGitRepo.run(folder, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), repo.prSHA)
        },
    ]
}

/// Lleva la fecha de modificación de `url` (y de todo lo de adentro) 13 horas atrás.
private func makeOld(_ url: URL) throws {
    let date = Date().addingTimeInterval(-13 * 3600)
    var paths = [url.path]
    if let enumerator = FileManager.default.enumerator(atPath: url.path) {
        for case let relative as String in enumerator { paths.append(url.path + "/" + relative) }
    }
    for path in paths.reversed() {
        var times = [timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0), timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)]
        guard utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw TestFailure(description: "utimensat \(path)") }
    }
}
