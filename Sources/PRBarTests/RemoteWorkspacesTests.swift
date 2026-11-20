import Foundation
import PRBarCore

func remoteWorkspaces(_ host: SSHHost, _ info: RunnerHostInfo, _ root: RemoteRoot, origin: URL,
                      extraURLs: [String] = []) -> RemoteWorkspaces {
    RemoteWorkspaces(host: host, root: root, gitPath: info.gitPath!,
                     runner: RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories),
                     fs: RemoteWorkspaceFS.ssh(host: host, home: (root.path as NSString).deletingLastPathComponent),
                     gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                      "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
                                      "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid"],
                     remoteURLs: { _ in extraURLs + [origin.path] }, originMatches: { _, _ in true })
}

enum RemoteWorkspacesTests {
    static let cases: [TestCase] = [
        TestCase("remote workspaces: mirror propio, worktree del PR con refs propias, symlinks neutralizados, contexto subido; limpieza") {
            let repo = try TempGitRepo.make { origin in
                try FileManager.default.createSymbolicLink(atPath: origin.appendingPathComponent("evil").path, withDestinationPath: "/etc/passwd")
            }
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
                                          fs: RemoteWorkspaceFS.ssh(host: host, home: ssh.home.path),
                                          remoteURLs: { _ in ["/nonexistent/repo.git"] }, originMatches: { _, _ in true })
            let error = try await expectThrows {
                let bare = try await spaces.mirror(RepoRef(owner: "acme", name: "api"))
                _ = try await spaces.prepare(repo: RepoRef(owner: "acme", name: "api"), number: 1, baseRef: "main", localPath: bare,
                                             name: nil, pinnedHeadOid: nil)
            }
            try expectEqual(error.localizedDescription, "devbox can't fetch acme/api — set up git access on the server.")
        },
        TestCase("remote workspaces: al arrancar se limpian huérfanos solo dentro de la raíz; los mirrors quedan") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            let workspace = try await spaces.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: bare,
                                                     name: nil, pinnedHeadOid: nil)
            let outside = ssh.home.appendingPathComponent("my-own-stuff")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: root.tmp).appendingPathComponent("leftover.stdin"))
            await spaces.cleanupOrphans()
            try expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.tmp), [])
            try expect(FileManager.default.fileExists(atPath: bare) && FileManager.default.fileExists(atPath: outside.path))
            let worktrees = try TempGitRepo.run(URL(fileURLWithPath: bare), ["worktree", "list", "--porcelain"])
            try expect(!worktrees.contains(root.work), worktrees)
        },
    ]
}
