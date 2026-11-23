import Foundation
import PRBarCore

enum AppLogTests {
    static let cases: [TestCase] = [
        TestCase("log: escrituras concurrentes no pierden líneas") {
            let url = try temporaryDirectory().appendingPathComponent("prbar.log")
            AppLog.setDestination(url)
            defer { AppLog.setDestination(TestEnvironment.logFile) }

            await withTaskGroup(of: Void.self) { group in
                for burst in ["a", "b"] {
                    group.addTask {
                        DispatchQueue.concurrentPerform(iterations: 500) { i in AppLog.write("\(burst)-\(i)") }
                    }
                }
            }
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            try expectEqual(lines.count, 1000)
            let messages = Set(lines.compactMap { $0.split(separator: " ").last.map(String.init) })
            try expectEqual(messages.count, 1000)
        },
        TestCase("log: destino nil desactiva el log") {
            let url = try temporaryDirectory().appendingPathComponent("prbar.log")
            AppLog.setDestination(nil)
            AppLog.write("nada")
            AppLog.setDestination(TestEnvironment.logFile)
            try expect(!FileManager.default.fileExists(atPath: url.path))
        },
        TestCase("log: a rolling file rolls at its limit, keeping one previous file") {
            let dir = try temporaryDirectory()
            let url = dir.appendingPathComponent("run.log")
            let file = RollingLogFile(url: url, limit: 100)
            for i in 0..<30 { try file.append(Data("line \(i)\n".utf8)) }
            let rolled = RollingLogFile.rolledURL(for: url)
            try expectEqual(rolled.lastPathComponent, "run.log.1")
            let current = try String(contentsOf: url, encoding: .utf8)
            let previous = try String(contentsOf: rolled, encoding: .utf8)
            try expect(current.utf8.count < 100, current)
            try expect(previous.utf8.count >= 100, previous)
            try expect(current.hasSuffix("line 29\n"), current)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            try expectEqual(files, ["run.log", "run.log.1"])
            // The newest lines are all there, in order, across the two files.
            let lines = (previous + current).split(separator: "\n")
            try expectEqual(lines.last.map(String.init), "line 29")
            try expect(zip(lines, lines.dropFirst()).allSatisfy { a, b in
                Int(a.split(separator: " ")[1])! + 1 == Int(b.split(separator: " ")[1])!
            })
        },
        TestCase("log: two writers of the same file append without overwriting; a deleted file is recreated") {
            let url = try temporaryDirectory().appendingPathComponent("shared.log")
            let a = RollingLogFile(url: url), b = RollingLogFile(url: url)
            try a.append(Data("a1\n".utf8))
            try b.append(Data("b1\n".utf8))
            try a.append(Data("a2\n".utf8))
            try expectEqual(try String(contentsOf: url, encoding: .utf8), "a1\nb1\na2\n")
            try FileManager.default.removeItem(at: url)
            try a.append(Data("again\n".utf8))
            try expectEqual(try String(contentsOf: url, encoding: .utf8), "again\n")
        },
        TestCase("log: old-file cleanup offers a rolled log but never the log in use") {
            let dir = try temporaryDirectory()
            let current = dir.appendingPathComponent(AppPaths.logFile.lastPathComponent)
            let rolled = RollingLogFile.rolledURL(for: current)
            for url in [current, rolled] {
                try Data("x".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)],
                                                      ofItemAtPath: url.path)
            }
            let found = DiskCleanup.oldFiles(in: [dir], olderThanDays: 30).map(\.title)
            try expectEqual(found, [rolled.lastPathComponent])
        },
    ]
}
