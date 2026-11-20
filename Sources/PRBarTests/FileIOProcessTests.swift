import Foundation
import PRBarCore

enum FileIOProcessTests {
    static let cases: [TestCase] = [
        TestCase("file io: stdin desde un archivo") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.txt")
            try Data("hola\nchau's $HOME\n".utf8).write(to: input)
            let result = try await SystemProcessRunner().runWithFiles("/bin/cat", [], environment: nil, currentDirectory: nil,
                                                                      timeout: 10, standardInput: input, standardOutput: nil, onStdoutLine: nil)
            try expectEqual(result.stdout, "hola\nchau's $HOME\n")
        },
        TestCase("file io: stdout binario a un archivo 0600, sin pasar por String") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.bin")
            let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            try bytes.write(to: input)
            let output = dir.appendingPathComponent("out.bin")
            let result = try await SystemProcessRunner().runWithFiles("/bin/cat", [], environment: nil, currentDirectory: nil, timeout: 10,
                                                                      standardInput: input, standardOutput: output, onStdoutLine: nil)
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout, "")
            try expectEqual(try Data(contentsOf: output), bytes)
            let mode = (try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int) ?? 0
            try expectEqual(mode, 0o600)
        },
        TestCase("file io: el timeout sigue cortando") {
            let start = Date()
            let error = try await expectThrows {
                _ = try await SystemProcessRunner(killGracePeriod: 0.2).runWithFiles("/bin/sleep", ["5"], environment: nil, currentDirectory: nil,
                                                                                    timeout: 0.3, standardInput: nil, standardOutput: nil, onStdoutLine: nil)
            }
            try expect(error as? PRBarError == .timedOut(command: "sleep 5"), "\(error)")
            try expect(Date().timeIntervalSince(start) < 3)
        },
    ]
}
