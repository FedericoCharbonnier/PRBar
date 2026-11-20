import Foundation

/// Los argumentos del `ssh` del sistema (spec J.1, J.5). Nunca hay contraseñas (`BatchMode`), nunca se reenvía el
/// agent ni X11, nunca corre un `LocalCommand`, y el host va después de `--` (no se puede leer como opción).
public enum SSHCommandBuilder {
    public static let fixedOptions = [
        "BatchMode=yes", "ConnectTimeout=10", "ControlMaster=auto", "ControlPersist=60s", "ForwardAgent=no", "ForwardX11=no",
        "ClearAllForwardings=yes", "PermitLocalCommand=no", "RequestTTY=no", "ServerAliveInterval=15", "ServerAliveCountMax=4",
        "LogLevel=ERROR",
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
