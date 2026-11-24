import Foundation

/// Los argumentos del `ssh` del sistema (spec J.1, J.5). Nunca hay contraseñas (`BatchMode`), nunca se reenvía el
/// agent ni X11 ni variables de entorno, nunca corre un `LocalCommand`, y el host va después de `--` (no se puede
/// leer como opción). Necesita OpenSSH 8.7 o más nuevo (`SessionType`, `ForkAfterAuthentication`, `StdinNull`).
public enum SSHCommandBuilder {
    public static let fixedOptions = [
        "BatchMode=yes", "ConnectTimeout=10", "ControlMaster=auto", "ControlPersist=60s", "ForwardAgent=no", "ForwardX11=no",
        "ClearAllForwardings=yes", "PermitLocalCommand=no", "RequestTTY=no", "ServerAliveInterval=15", "ServerAliveCountMax=4",
        "LogLevel=ERROR",
        // Ninguna variable local viaja (aunque la config del usuario diga `SendEnv`), sin túneles, sin quedar en
        // segundo plano y una sesión normal con el stdin que da PRBar. Un `RemoteCommand` de la config (p. ej.
        // `tmux attach`) haría fallar cada comando ("Cannot execute command-line and remote command"): se anula.
        "SendEnv=-*", "Tunnel=no", "SessionType=default", "ForkAfterAuthentication=no", "StdinNull=no", "RemoteCommand=none",
    ]

    private static func target(_ destination: RunnerDestination) -> [String] {
        var args: [String] = []
        if let port = destination.endpoint.port { args += ["-p", String(port)] }
        if let user = destination.endpoint.user { args += ["-l", user] }
        return args
    }

    /// `remoteCommand` es **un** argumento (`/bin/sh -c '<script>'`): ssh lo manda tal cual al shell de login.
    public static func arguments(_ destination: RunnerDestination, controlDirectory: String, enforceHostKey: Bool,
                                 remoteCommand: String) -> [String] {
        var args: [String] = []
        for option in fixedOptions { args += ["-o", option] }
        args += ["-o", "ControlPath=\(controlDirectory)/%C"]
        if enforceHostKey { args += ["-o", "StrictHostKeyChecking=yes"] }
        args += target(destination)
        args += ["-T", "--", destination.endpoint.host, remoteCommand]
        return args
    }

    /// The connection options of `fixedOptions` that also make sense for a person at a terminal (spec T.5): no agent,
    /// X11, forwardings, local commands, sent variables or `RemoteCommand`. Without `BatchMode` (ssh may ask for a
    /// passphrase or a new host key) and with a TTY.
    public static let interactiveOptions = [
        "ConnectTimeout=10", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes", "PermitLocalCommand=no",
        "ServerAliveInterval=15", "ServerAliveCountMax=4", "LogLevel=ERROR", "SendEnv=-*", "Tunnel=no",
        "SessionType=default", "ForkAfterAuthentication=no", "StdinNull=no", "RemoteCommand=none",
    ]

    /// `ssh -t` for Claude's session on a runner: `remoteCommand` is **one** argument, run by the login shell.
    public static func interactiveArguments(_ destination: RunnerDestination, remoteCommand: String) -> [String] {
        var args: [String] = []
        for option in interactiveOptions { args += ["-o", option] }
        args += target(destination)
        args += ["-t", "--", destination.endpoint.host, remoteCommand]
        return args
    }

    /// `ssh -G`: la config efectiva del usuario para ese host (no conecta).
    public static func configArguments(_ destination: RunnerDestination) -> [String] {
        ["-G"] + target(destination) + ["--", destination.endpoint.host]
    }

    /// Cierra la conexión maestra (al sacar un destino).
    public static func exitArguments(_ destination: RunnerDestination, controlDirectory: String) -> [String] {
        ["-o", "ControlPath=\(controlDirectory)/%C", "-O", "exit"] + target(destination) + ["--", destination.endpoint.host]
    }

    /// `true` si la config deja `StrictHostKeyChecking` en el default (`ask`, o no lo dice): PRBar fuerza `yes`.
    /// Si el usuario eligió otra cosa (`accept-new`, `no`, `yes`), se respeta (spec J.5).
    public static func enforcesHostKey(fromConfig output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "stricthostkeychecking" {
                return parts[1].trimmingCharacters(in: .whitespaces).lowercased() == "ask"
            }
        }
        return true
    }
}

/// La carpeta de los sockets de `ControlMaster` (decisión J.7.4): 0700, del usuario y nunca un symlink.
public enum ControlSocketDirectory {
    public static var defaultPath: String { "/private/tmp/prbar-ssh-\(getuid())" }

    public static func ensure(_ path: String = defaultPath) throws -> String {
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw RemoteRunnerError.unsafeControlDirectory(path, String(cString: strerror(errno)))
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw RemoteRunnerError.unsafeControlDirectory(path, String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw RemoteRunnerError.unsafeControlDirectory(path, "it isn’t a folder (a symlink?)")
        }
        guard info.st_uid == getuid() else {
            throw RemoteRunnerError.unsafeControlDirectory(path, "it belongs to another user")
        }
        let mode = info.st_mode & 0o777
        guard mode == 0o700 else {
            throw RemoteRunnerError.unsafeControlDirectory(path, "its permissions are \(String(mode, radix: 8)), not 700")
        }
        return path
    }
}

/// La versión de OpenSSH de un `ssh` (`ssh -V`). Las opciones de `SSHCommandBuilder` necesitan 8.7 o más nuevo: el
/// `/usr/bin/ssh` de las macOS que soporta PRBar lo cumple; un `ssh` propio se verifica antes de usarlo.
public enum OpenSSHVersion {
    public static let minimum = (8, 7)
    public static let systemPath = "/usr/bin/ssh"

    /// `OpenSSH_10.2p1, LibreSSL 3.3.6` → (10, 2). `nil` si no es OpenSSH.
    public static func parse(_ text: String) -> (Int, Int)? {
        guard let start = text.range(of: "OpenSSH_") else { return nil }
        let rest = text[start.upperBound...]
        guard let firstDigit = rest.firstIndex(where: \.isNumber) else { return nil }
        // Entre "OpenSSH_" y el número solo puede haber un prefijo de letras y "_" (`OpenSSH_for_Windows_8.1p1`).
        guard rest[..<firstDigit].allSatisfy({ $0.isLetter || $0 == "_" }) else { return nil }
        let numbers = rest[firstDigit...].prefix { $0.isNumber || $0 == "." }.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    /// Lanza `RemoteRunnerError.sshTooOld` si `sshPath` no es OpenSSH 8.7 o más nuevo (o no se pudo correr).
    public static func require(sshPath: String, environment: [String: String] = [:]) async throws {
        let result = try? await SystemProcessRunner().run(sshPath, ["-V"], environment: environment, currentDirectory: nil, timeout: 10)
        // `ssh -V` escribe en stderr; algunas compilaciones, en stdout.
        let output = result.map { $0.stderr + "\n" + $0.stdout } ?? ""
        let line = output.split(whereSeparator: \.isNewline).first { $0.contains("OpenSSH_") }.map(String.init)
        guard let result, result.status == 0, let line, let version = parse(line) else {
            throw RemoteRunnerError.sshTooOld(path: sshPath, version: line.flatMap(versionToken))
        }
        guard version >= minimum else {
            throw RemoteRunnerError.sshTooOld(path: sshPath, version: versionToken(line))
        }
    }

    /// `OpenSSH_8.6p1, OpenSSL …` → `OpenSSH_8.6p1` (para el mensaje; nunca más de 40 caracteres).
    static func versionToken(_ line: String) -> String? {
        guard let start = line.range(of: "OpenSSH_") else { return nil }
        let token = line[start.lowerBound...].prefix { !$0.isWhitespace && $0 != "," }
        return token.isEmpty ? nil : String(token.prefix(40))
    }
}
