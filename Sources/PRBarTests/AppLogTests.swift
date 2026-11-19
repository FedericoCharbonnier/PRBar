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
    ]
}
