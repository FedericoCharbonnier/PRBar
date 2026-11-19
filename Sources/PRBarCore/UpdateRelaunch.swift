import Foundation

/// Reinicio después de instalar (spec D.3, paso 6): un `/bin/sh` desacoplado espera a que termine este proceso y abre
/// el `.app` (reintenta si LaunchServices devuelve -600 justo después del reemplazo). La ruta va como `$0`, nunca
/// dentro del script, así espacios o comillas no se interpretan.
public enum Relauncher {
    public static func arguments(waitingFor pid: Int32, appPath: String, openCommand: String = "/usr/bin/open") -> [String] {
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + "for attempt in 1 2 3 4 5; do \(openCommand) \"$0\" && exit 0; sleep 1; done; exit 1"
        return ["-c", script, appPath]
    }

    /// Lanza el `/bin/sh` y vuelve enseguida; el proceso sigue vivo cuando la app termina.
    public static func launch(waitingFor pid: Int32, appPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(waitingFor: pid, appPath: appPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// La versión recién instalada, para que la nueva muestre "Updated to X" con las notas al arrancar.
public struct PendingUpdate: Codable, Equatable, Sendable {
    public var version: String
    public var notes: String
    public var installedAt: Date

    public init(version: String, notes: String, installedAt: Date) {
        self.version = version
        self.notes = notes
        self.installedAt = installedAt
    }

    public static func save(_ update: PendingUpdate, to url: URL = AppPaths.pendingUpdateFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(update).write(to: url, options: .atomic)
    }

    /// Lee y borra el archivo. Devuelve la actualización solo si es la versión que está corriendo (si no, la
    /// instalación no llegó a arrancar o es de otra vez).
    public static func take(currentVersion: String, from url: URL = AppPaths.pendingUpdateFile) -> PendingUpdate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let update = try? JSONCoding.decoder.decode(PendingUpdate.self, from: data),
              let version = SemanticVersion(update.version), version == SemanticVersion(currentVersion) else { return nil }
        return update
    }
}
