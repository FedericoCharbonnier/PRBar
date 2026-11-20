import Foundation
import PRBarCore

enum SSHHostTests {
    static let cases: [TestCase] = [
        TestCase("ssh host: corre el script remoto con las opciones fijas; el texto hostil llega intacto") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let result = try await host.run(RemoteExec(argv: ["/bin/echo", "it's $HOME `x`"], environment: [.literal("PATH", "/bin")]), timeout: 10)
            try expectEqual(result.stdout, "it's $HOME `x`\n")
            let args = try expectNotNil(ssh.invocations().last)
            try expect(args.contains("BatchMode=yes") && args.contains("ForwardAgent=no") && args.contains("StrictHostKeyChecking=yes"))
            try expectEqual(Array(args.suffix(3).prefix(2)), ["--", "devbox"])
            try expect(args.last!.hasPrefix("/bin/sh -c '"), args.last!)
        },
        TestCase("ssh host: un host caído es unreachable") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let error = try await expectThrows {
                _ = try await ssh.host(unreachable: true).run(RemoteExec(argv: ["/bin/true"], environment: []), timeout: 10)
            }
            guard case .unreachable(let name, let detail)? = error as? RemoteRunnerError else { throw TestFailure(description: "\(error)") }
            try expectEqual(name, "devbox")
            try expect(detail.contains("Connection refused"))
        },
        TestCase("ssh host: subir y bajar binarios; nada fuera de la raíz") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let rootPath = ssh.home.appendingPathComponent(".prbar")
            try FileManager.default.createDirectory(at: rootPath.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            try Data().write(to: rootPath.appendingPathComponent(RemoteRoot.marker))
            let root = try RemoteRoot(verified: rootPath.path)
            let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
            let remote = try root.child(["tmp", "blob.bin"])
            try await host.upload(bytes, to: remote, root: root)
            try expectEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), bytes)
            let local = ssh.base.appendingPathComponent("down.bin")
            try await host.download(remote, to: local, root: root)
            try expectEqual(try Data(contentsOf: local), bytes)
            let before = ssh.invocations().count
            _ = try await expectThrows { try await host.upload(bytes, to: ssh.home.appendingPathComponent("x").path, root: root) }
            try expectEqual(ssh.invocations().count, before)
        },
        TestCase("ssh host: borrar exige la marca, estar adentro y dos niveles abajo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let rootURL = ssh.home.appendingPathComponent(".prbar")
            let victim = rootURL.appendingPathComponent("work/old-run")
            try FileManager.default.createDirectory(at: victim.appendingPathComponent("deep"), withIntermediateDirectories: true)
            let root = try RemoteRoot(verified: rootURL.path)
            let unmarked = try await expectThrows { try await host.removeTree(victim.path, root: root) }
            try expect(unmarked is RemoteRunnerError)
            try expect(FileManager.default.fileExists(atPath: victim.path))
            try Data().write(to: rootURL.appendingPathComponent(RemoteRoot.marker))
            try await host.removeTree(victim.path, root: root)
            try expect(!FileManager.default.fileExists(atPath: victim.path))
            for refused in [rootURL.appendingPathComponent("work").path, rootURL.path, ssh.home.path, rootURL.path + "/work/../.."] {
                _ = try await expectThrows { try await host.removeTree(refused, root: root) }
            }
            try expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("work").path))
        },
    ]
}

func expectNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) expected a value, got nil") }
    return value
}
