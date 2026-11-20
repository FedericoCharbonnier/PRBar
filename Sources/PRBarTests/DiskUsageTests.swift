import Foundation
import PRBarCore

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x61, count: bytes).write(to: url)
}

/// Carpetas como las de PRBar, en un temporal.
private struct Layout {
    let base: URL
    var appSupport: URL { base.appendingPathComponent("AppSupport") }
    var worktrees: URL { base.appendingPathComponent("tmp/PRBar/worktrees") }
    var logs: URL { base.appendingPathComponent("Logs/PRBar") }
    var respondDir: URL { base.appendingPathComponent("code/web-worktrees") }

    func input(active: Set<String> = []) -> DiskScanInput {
        DiskScanInput(appSupport: appSupport, worktreeRoots: [worktrees], logsDir: logs,
                      respondDirs: [DiskScanInput.RespondDir(repo: "acme/web", path: respondDir.path, localPath: base.appendingPathComponent("code/web").path)],
                      activePaths: active, now: Date().addingTimeInterval(3600))
    }
}

enum DiskUsageTests {
    static let cases: [TestCase] = [
        TestCase("disk: categorías, activos y huérfanos, y nada fuera de las carpetas de PRBar") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let layout = Layout(base: base)
            try write(layout.appSupport.appendingPathComponent("history/review/a.json"), bytes: 10_000)
            try write(layout.appSupport.appendingPathComponent("source/.build/x.o"), bytes: 20_000)
            try write(layout.appSupport.appendingPathComponent("source/Package.swift"), bytes: 1_000)
            try write(layout.appSupport.appendingPathComponent("update-staging/PRBar.app/bin"), bytes: 5_000)
            try write(layout.appSupport.appendingPathComponent("config.json"), bytes: 500)
            try write(layout.logs.appendingPathComponent("prbar.log"), bytes: 3_000)
            let active = layout.worktrees.appendingPathComponent("api-317-1800000000-1a2b3c4d")
            let orphan = layout.worktrees.appendingPathComponent("api-300-1700000000-deadbeef")
            try write(active.appendingPathComponent("f.txt"), bytes: 4_000)
            try write(orphan.appendingPathComponent("f.txt"), bytes: 8_000)
            try write(layout.worktrees.appendingPathComponent("notes.txt"), bytes: 100)   // no es de PRBar
            try write(layout.respondDir.appendingPathComponent("web-2-respond-0a0b0c0d/f.txt"), bytes: 6_000)
            try write(layout.respondDir.appendingPathComponent("my-own-worktree/f.txt"), bytes: 9_000)   // del usuario
            let usage = DiskScanner.scan(layout.input(active: [active.path]))
            func item(_ path: URL) -> DiskItem? { usage.items.first { $0.path == CanonicalPath.of(path.path) } }
            try expectEqual(item(active)?.state, .active)
            try expectEqual(item(orphan)?.state, .orphan)
            try expectEqual(item(layout.respondDir.appendingPathComponent("web-2-respond-0a0b0c0d"))?.repo, "acme/web")
            try expect(usage.items.allSatisfy { !$0.path.hasSuffix("my-own-worktree") && !$0.path.hasSuffix("notes.txt") })
            try expect(usage.bytes(.history) >= 10_000)
            try expect(usage.bytes(.updater) >= 26_000)
            try expect(usage.bytes(.logs) >= 3_000)
            try expect(usage.bytes(.appData) >= 500 && usage.bytes(.appData) < 10_000, "app data \(usage.bytes(.appData))")
            try expectEqual(usage.total, DiskCategoryKind.allCases.map { usage.bytes($0) }.reduce(0, +))
            try expect(item(layout.appSupport.appendingPathComponent("source/.build"))?.state == .cache)
        },
        TestCase("disk: una sola pasada reparte los bytes por carpeta (la más profunda gana) y el resto") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            try write(base.appendingPathComponent("source/.build/x.o"), bytes: 20_000)
            try write(base.appendingPathComponent("source/Package.swift"), bytes: 1_000)
            try write(base.appendingPathComponent("history/a.json"), bytes: 10_000)
            try write(base.appendingPathComponent("config.json"), bytes: 500)
            let sizes = DiskScanner.allocatedSizes(base, buckets: ["source/.build", "source", "history", "update-staging"])
            let build = DiskScanner.allocatedSize(base.appendingPathComponent("source/.build"))
            try expectEqual(sizes.buckets["source/.build"], build)
            try expectEqual(sizes.buckets["source"], DiskScanner.allocatedSize(base.appendingPathComponent("source")) - build)
            try expectEqual(sizes.buckets["history"], DiskScanner.allocatedSize(base.appendingPathComponent("history")))
            try expectEqual(sizes.buckets["update-staging"] ?? 0, 0)
            try expectEqual(sizes.buckets.values.reduce(0, +) + sizes.rest, DiskScanner.allocatedSize(base))
        },
        TestCase("disk: dos repos con el mismo worktreeDir (o uno por un symlink) no cuentan dos veces sus worktrees") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let shared = base.appendingPathComponent("worktrees")
            try write(shared.appendingPathComponent("web-2-respond-0a0b0c0d/f.txt"), bytes: 1_000)
            try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("alias"), withDestinationURL: shared)
            let input = DiskScanInput(appSupport: base.appendingPathComponent("AppSupport"), worktreeRoots: [], logsDir: base.appendingPathComponent("Logs"),
                                      respondDirs: [DiskScanInput.RespondDir(repo: "acme/web", path: shared.path, localPath: "/c/web"),
                                                    DiskScanInput.RespondDir(repo: "acme/api", path: shared.path + "/", localPath: "/c/api"),
                                                    DiskScanInput.RespondDir(repo: "acme/app", path: base.appendingPathComponent("alias").path, localPath: "/c/app")],
                                      activePaths: [], now: Date().addingTimeInterval(3600))
            try expectEqual(DiskScanner.scan(input).items.filter { $0.kind == .worktrees }.count, 1)
        },
        TestCase("disk: no sigue symlinks") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let big = base.appendingPathComponent("outside/big.bin")
            try write(big, bytes: 2_000_000)
            let dir = base.appendingPathComponent("inside")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("outside"))
            try expect(DiskScanner.allocatedSize(dir) < 100_000)
        },
        TestCase("disk: un worktree recién creado (menos de 5 min) no es huérfano") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let layout = Layout(base: base)
            let fresh = layout.worktrees.appendingPathComponent("api-1-1800000000-0f0f0f0f")
            try write(fresh.appendingPathComponent("f"), bytes: 10)
            var input = layout.input()
            input.now = Date()
            try expectEqual(DiskScanner.scan(input).items.first { $0.path == CanonicalPath.of(fresh.path) }?.state, .active)
        },
        TestCase("disk: el registro de workspaces anota y borra") {
            let registry = WorkspaceRegistry()
            registry.insert("/tmp/x/../a")
            try expect(registry.contains("/tmp/a"))
            registry.remove("/tmp/a")
            try expect(!registry.contains("/tmp/a"))
        },
    ]
}
