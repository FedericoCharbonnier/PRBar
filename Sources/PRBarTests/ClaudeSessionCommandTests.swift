import Foundation
import PRBarCore

private let id = "0D5B2F4E-8C1A-4E3B-9F6D-2A7C1B3E4F50"

private func session(_ directory: String, id: String = id, runner: String? = nil) -> ClaudeSessionRef {
    ClaudeSessionRef(id: id, label: "Review · stage 1", kind: .review, directory: directory, runner: runner, startedAt: t0)
}

enum ClaudeSessionCommandTests {
    static let cases: [TestCase] = [
        TestCase("session command: esta Mac, con espacios y comillas en la carpeta y en claude") {
            let command = try ClaudeSessionCommand.local(session: session("/Users/me/PR Bar/it's"), claudePath: "/opt/claude code/claude")
            try expectEqual(command, #"cd '/Users/me/PR Bar/it'\''s' && '/opt/claude code/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"#)
        },
        TestCase("session command: $, backticks y saltos de línea en la carpeta no se interpretan") {
            let directory = "/tmp/a $HOME `id` $(id)\nb'c"
            let command = try ClaudeSessionCommand.local(session: session(directory), claudePath: "/usr/local/bin/claude")
            try expectEqual(command, "cd '/tmp/a $HOME `id` $(id)\nb'\\''c' && '/usr/local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50")
            // El shell devuelve la carpeta tal cual (solo se imprime, nada se ejecuta ni se abre).
            let result = try await SystemProcessRunner().run("/bin/sh", ["-c", "printf %s \(try ShellQuote.posix(directory))"],
                                                             environment: nil, currentDirectory: nil, timeout: 10)
            try expectEqual(result.stdout, directory)
        },
        TestCase("session command: un ID que no es UUID se rechaza") {
            let error = try await expectThrows {
                _ = try ClaudeSessionCommand.local(session: session("/wt", id: "abc; rm -rf ~"), claudePath: "/usr/local/bin/claude")
            }
            try expectEqual(error as? ClaudeSessionCommand.Failure, .invalidSessionID("abc; rm -rf ~"))
            let remote = try await expectThrows {
                _ = try ClaudeSessionCommand.remote(session: session("/wt", id: "$(id)", runner: "devbox"),
                                                    destination: RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox")),
                                                    claudePath: "claude")
            }
            try expectEqual(remote as? ClaudeSessionCommand.Failure, .invalidSessionID("$(id)"))
        },
        TestCase("session command: runner, ssh -t con las opciones de conexión de PRBar y el comando entre comillas") {
            let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(user: "fede", host: "devbox.local", port: 2222))
            let command = try ClaudeSessionCommand.remote(session: session("/srv/prbar/work/api 7", runner: "devbox"),
                                                          destination: devbox, claudePath: "/home/fede/.local/bin/claude")
            let inner = "cd '/srv/prbar/work/api 7' && '/home/fede/.local/bin/claude' --resume 0d5b2f4e-8c1a-4e3b-9f6d-2a7c1b3e4f50"
            let arguments = SSHCommandBuilder.interactiveArguments(devbox, remoteCommand: inner)
            try expectEqual(command, try ShellQuote.command(["/usr/bin/ssh"] + arguments))
            try expectEqual(Array(arguments.suffix(4)), ["-t", "--", "devbox.local", inner])
            try expect(arguments.contains("-p") && arguments.contains("2222") && arguments.contains("-l") && arguments.contains("fede"))
            try expect(!arguments.contains("BatchMode=yes") && !arguments.contains("RequestTTY=no"), "\(arguments)")
            try expect(arguments.contains("ForwardAgent=no") && arguments.contains("RemoteCommand=none"), "\(arguments)")
        },
    ]
}
