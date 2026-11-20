import Foundation
import PRBarCore

enum SSHCommandTests {
    static let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(user: "fede", host: "devbox", port: 2222))

    static let cases: [TestCase] = [
        TestCase("ssh: opciones fijas, -- antes del host y el comando como un solo argumento") {
            let args = SSHCommandBuilder.arguments(devbox, controlDirectory: "/private/tmp/prbar-ssh-501", enforceHostKey: true,
                                                   remoteCommand: "/bin/sh -c 'echo hi'")
            func option(_ name: String) -> String? {
                stride(from: 0, to: args.count - 1, by: 1).first { args[$0] == "-o" && args[$0 + 1].hasPrefix(name + "=") }
                    .map { String(args[$0 + 1].dropFirst(name.count + 1)) }
            }
            try expectEqual(option("BatchMode"), "yes")
            try expectEqual(option("ConnectTimeout"), "10")
            try expectEqual(option("ControlMaster"), "auto")
            try expectEqual(option("ControlPersist"), "60s")
            try expectEqual(option("ControlPath"), "/private/tmp/prbar-ssh-501/%C")
            try expectEqual(option("ForwardAgent"), "no")
            try expectEqual(option("ClearAllForwardings"), "yes")
            try expectEqual(option("PermitLocalCommand"), "no")
            try expectEqual(option("StrictHostKeyChecking"), "yes")
            try expectEqual(Array(args.suffix(3)), ["--", "devbox", "/bin/sh -c 'echo hi'"])
            try expect(args.firstIndex(of: "-p")! < args.firstIndex(of: "--")!)
            let relaxed = SSHCommandBuilder.arguments(devbox, controlDirectory: "/x", enforceHostKey: false, remoteCommand: "true")
            try expect(!relaxed.contains("StrictHostKeyChecking=yes"))
        },
        TestCase("ssh: StrictHostKeyChecking solo se fuerza con el default de la config (ask)") {
            try expect(SSHCommandBuilder.enforcesHostKey(fromConfig: "hostname devbox\nstricthostkeychecking ask\n"))
            try expect(!SSHCommandBuilder.enforcesHostKey(fromConfig: "stricthostkeychecking accept-new\n"))
            try expect(!SSHCommandBuilder.enforcesHostKey(fromConfig: "stricthostkeychecking false\n"))
            try expect(!SSHCommandBuilder.enforcesHostKey(fromConfig: "stricthostkeychecking true\n"))
            try expect(SSHCommandBuilder.enforcesHostKey(fromConfig: "hostname devbox\n"))
            try expectEqual(SSHCommandBuilder.configArguments(devbox), ["-G", "-p", "2222", "-l", "fede", "--", "devbox"])
            try expectEqual(SSHCommandBuilder.exitArguments(devbox, controlDirectory: "/x"),
                            ["-o", "ControlPath=/x/%C", "-O", "exit", "-p", "2222", "-l", "fede", "--", "devbox"])
        },
        TestCase("ssh: la carpeta del socket se crea 0700 y se rechaza si es un symlink o tiene otros permisos") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let fresh = base.appendingPathComponent("sock").path
            try expectEqual(try ControlSocketDirectory.ensure(fresh), fresh)
            let mode = (try FileManager.default.attributesOfItem(atPath: fresh)[.posixPermissions] as? Int) ?? 0
            try expectEqual(mode, 0o700)
            let loose = base.appendingPathComponent("loose").path
            try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            let looseError = try await expectThrows { _ = try ControlSocketDirectory.ensure(loose) }
            try expect("\(looseError.localizedDescription)".contains("755"), looseError.localizedDescription)
            let link = base.appendingPathComponent("link").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fresh)
            _ = try await expectThrows { _ = try ControlSocketDirectory.ensure(link) }
            try expect(ControlSocketDirectory.defaultPath.hasPrefix("/private/tmp/prbar-ssh-"))
            try expect(ControlSocketDirectory.defaultPath.utf8.count + 1 + 40 + 17 < 104)
        },
    ]
}
