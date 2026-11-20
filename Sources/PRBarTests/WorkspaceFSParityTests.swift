import Foundation
import PRBarCore

/// Un worktree con todo lo que mira el guardián: archivos, carpetas, nombre NFD, metadatos de macOS, symlinks, `.git`
/// anidados (carpeta y archivo), y un `.git` de arriba con config, hooks, info y módulos.
private func makeTree() throws -> URL {
    let root = try temporaryDirectory().resolvingSymlinksInPath().appendingPathComponent("wt")
    let files = FileManager.default
    func put(_ path: String, _ text: String, mode: Int = 0o644) throws {
        let url = root.appendingPathComponent(path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    try put("a.txt", "a\n")
    try put("dir/b.txt", "bb\n")
    try put("e\u{0301}.txt", "nfd\n")
    try put(".DS_Store", "x")
    try put("dir/._b.txt", "x")
    try put("._evil", "x")
    try put("._x/.git/config", "[core]\n\tfsmonitor = touch PWNED\n")
    try put(".git/modules/._m/config", "[core]\n")
    try put(".git/hooks/._h/pre-commit", "#!/bin/sh\n", mode: 0o755)
    try put("sub/.git/config", "[core]\n")
    try put("sub2/.git", "gitdir: /elsewhere\n")
    try put(".git/config", "[include]\n\tpath = extra.conf\n")
    try put(".git/extra.conf", "[user]\n")
    try put(".git/hooks/pre-commit", "#!/bin/sh\n", mode: 0o755)
    try put(".git/info/exclude", "*.log\n")
    try put(".git/modules/m/config", "[core]\n")
    try put(".git/modules/m/hooks/h", "#!/bin/sh\n", mode: 0o755)
    try put(".git/modules/m/objects/x", "obj")
    try files.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "../outside/secret")
    try files.createSymbolicLink(atPath: root.appendingPathComponent("dir/inner").path, withDestinationPath: "b.txt")
    return root
}

enum WorkspaceFSParityTests {
    static let cases: [TestCase] = [
        TestCase("guardián perl = guardián local: snapshot, .git anidados, describe, árboles, módulos y lectura") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let local = LocalWorkspaceFS()
            let perl = RemoteWorkspaceFS.local()
            let a = try await local.snapshot(root.path)
            let b = try await perl.snapshot(root.path)
            try expectEqual(Set(a.entries.keys), Set(b.entries.keys))
            for (key, entry) in a.entries {
                let other = b.entries[key]!
                try expect(entry.type == other.type && entry.size == other.size && entry.inode == other.inode, key)
                try expect(abs(entry.modified - other.modified) < 2_000, "\(key): \(entry.modified) vs \(other.modified)")
            }
            // Los nombres `._*` se ven (FileManager los esconde; los recorridos usan readdir).
            for key in ["._evil", "._x/.git/config", "dir/._b.txt"] { try expect(a.entries[key] != nil, key) }
            let nestedLocal = try await local.nestedGitEntries(root.path)
            let nestedPerl = try await perl.nestedGitEntries(root.path)
            try expectEqual(nestedPerl, nestedLocal)
            try expect(nestedLocal.contains("._x/.git"), "\(nestedLocal)")
            let git = root.appendingPathComponent(".git").path
            let paths = [git, git + "/config", git + "/missing", root.appendingPathComponent("link").path, root.path]
            let describeLocal = try await local.describe(paths)
            let describePerl = try await perl.describe(paths)
            try expectEqual(describePerl, describeLocal)
            let treesLocal = try await local.describeTrees([git + "/hooks", git + "/info"])
            let treesPerl = try await perl.describeTrees([git + "/hooks", git + "/info"])
            try expectEqual(treesPerl, treesLocal)
            let modulesLocal = try await local.modules(git + "/modules")
            let modulesPerl = try await perl.modules(git + "/modules")
            try expectEqual(modulesPerl.entries, modulesLocal.entries)
            try expectEqual(modulesPerl.configs.sorted(), modulesLocal.configs.sorted())
            try expect(modulesLocal.configs.contains(git + "/modules/._m/config"), "\(modulesLocal.configs)")
            try expect(treesLocal[git + "/hooks/._h/pre-commit"] != nil, "\(treesLocal.keys)")
            let textLocal = try await local.readText(git + "/config", limit: 1 << 20)
            let textPerl = try await perl.readText(git + "/config", limit: 1 << 20)
            try expectEqual(textPerl, textLocal)
            let noneLocal = try await local.readText(git + "/nope", limit: 1 << 20)
            let nonePerl = try await perl.readText(git + "/nope", limit: 1 << 20)
            try expectEqual(nonePerl, noneLocal)
        },
        TestCase("guardián perl = guardián local: neutralizar symlinks y borrar lo que creó Claude, confinado") {
            let one = try makeTree()
            let two = try makeTree()
            defer {
                try? FileManager.default.removeItem(at: one.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: two.deletingLastPathComponent())
            }
            try await LocalWorkspaceFS().neutralizeSymlinks(["link", "dir/inner", "missing"], in: one.path)
            try await RemoteWorkspaceFS.local().neutralizeSymlinks(["link", "dir/inner", "missing"], in: two.path)
            for path in ["link", "dir/inner"] {
                let left = try String(contentsOf: one.appendingPathComponent(path), encoding: .utf8)
                let right = try String(contentsOf: two.appendingPathComponent(path), encoding: .utf8)
                try expectEqual(right, left)
                try expect(left.hasPrefix("[symlink to "))
            }
            for fs: any WorkspaceFS in [LocalWorkspaceFS(), RemoteWorkspaceFS.local()] {
                let tree = fs is LocalWorkspaceFS ? one : two
                try Data("new".utf8).write(to: tree.appendingPathComponent("dir/created.tmp"))
                try await fs.removeCreatedFile("dir/created.tmp", in: tree.path)
                try expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("dir/created.tmp").path))
                for evil in ["../outside", "/etc/hosts", "dir/../../x", "", "dir//x"] {
                    _ = try await expectThrows { try await fs.removeCreatedFile(evil, in: tree.path) }
                }
                _ = try await expectThrows { try await fs.neutralizeSymlinks(["../escape"], in: tree.path) }
            }
        },
        TestCase("guardián perl: rutas en bytes; NFC solo para comparar; dos nombres que se normalizan igual cortan") {
            func fs(_ records: [(String, String, String)]) -> RemoteWorkspaceFS {
                let out = (["V\0prbar-guard\01\0"] + records.map { [$0.0, $0.1, $0.2].joined(separator: "\0") + "\0" }).joined()
                return RemoteWorkspaceFS(home: "/home/u", label: "devbox") { _ in ProcessResult(status: 0, stdout: out, stderr: "") }
            }
            func hex(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
            let nfd = "dir/e\u{0301}.txt"
            let one = try await fs([("S", hex(nfd), "32768 1 2 3"), ("S", hex("a.txt"), "32768 1 2 4")]).snapshot("/w")
            try expectEqual(Set(one.entries.keys.map { Array($0.utf8) }), [Array("dir/\u{e9}.txt".utf8), Array("a.txt".utf8)])
            try expectEqual(Array(one.rawPath("dir/\u{e9}.txt").utf8), Array(nfd.utf8))
            try expectEqual(one.rawPath("a.txt"), "a.txt")
            let clash = try await expectThrows {
                _ = try await fs([("S", hex(nfd), "32768 1 2 3"), ("S", hex("dir/\u{e9}.txt"), "32768 1 2 4")]).snapshot("/w")
            }
            guard case .guardFailed? = clash as? RemoteRunnerError else { throw TestFailure(description: "\(clash)") }
            let nested = try await fs([("N", hex("x/e\u{0301}/.git"), "")]).nestedGitEntries("/w")
            try expectEqual(nested.map { Array($0.utf8) }, [Array("x/\u{e9}/.git".utf8)])
            let bad = try await expectThrows { _ = try await fs([("S", "ff", "32768 1 2 3")]).snapshot("/w") }
            try expect(bad is RemoteRunnerError, "\(bad)")
            _ = try await expectThrows { _ = try await fs([("Z", hex("a.txt"), "")]).snapshot("/w") }
            let headlessOutput = "S\0\(hex("a.txt"))\032768 1 2 3\0"
            let headless = RemoteWorkspaceFS(home: "/home/u", label: "devbox") { _ in
                ProcessResult(status: 0, stdout: headlessOutput, stderr: "")
            }
            _ = try await expectThrows { _ = try await headless.snapshot("/w") }
        },
        TestCase("guardián perl = guardián local: borrar un archivo creado que ya no existe es un error") {
            let one = try makeTree()
            defer { try? FileManager.default.removeItem(at: one.deletingLastPathComponent()) }
            for fs: any WorkspaceFS in [LocalWorkspaceFS(), RemoteWorkspaceFS.local()] {
                _ = try await expectThrows { try await fs.removeCreatedFile("dir/gone.tmp", in: one.path) }
                _ = try await expectThrows { try await fs.removeCreatedFile("nodir/gone.tmp", in: one.path) }
            }
        },
        TestCase("guardián perl: los archivos temporales (el índice del chat) quedan en la carpeta temporal de esa máquina") {
            let tmp = try temporaryDirectory().appendingPathComponent("remote-tmp")
            defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let fs = RemoteWorkspaceFS.local(temporaryDirectory: tmp.path)
            let path = try fs.temporaryFilePath("chat-index")
            try expect(path.hasPrefix(tmp.path + "/chat-index-"), path)
            try Data("x".utf8).write(to: URL(fileURLWithPath: path))
            await fs.removeTemporaryFile(path)
            try expect(!FileManager.default.fileExists(atPath: path))
            let local = try LocalWorkspaceFS().temporaryFilePath("chat-index")
            try expect(local.hasPrefix(FileManager.default.temporaryDirectory.path), local)
        },
    ]
}
