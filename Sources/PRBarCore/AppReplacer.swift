import Foundation

/// Revisa el `.app` recién compilado antes de instalarlo (spec D.3, paso 4): existe, su versión es la esperada, su
/// bundle id es el de la app instalada y el binario arranca con `--version`.
public enum UpdateVerifier {
    public static let launchTimeout: TimeInterval = 15

    public static func verify(app: URL, expectedVersion: SemanticVersion, bundleIdentifier: String, runner: ProcessRunning) async throws {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw UpdateError.appMissing(app.path)
        }
        let found = info["CFBundleShortVersionString"] as? String ?? ""
        guard SemanticVersion(found) == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion.description, found: found)
        }
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        guard identifier == bundleIdentifier else {
            throw UpdateError.bundleIdentifierMismatch(expected: bundleIdentifier, found: identifier)
        }
        let name = info["CFBundleExecutable"] as? String ?? ""
        let executable = app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(name)
        guard !name.isEmpty, !name.contains("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.appMissing(executable.path)
        }
        let result = try await runner.run(executable.path, ["--version"], environment: nil, currentDirectory: nil, timeout: launchTimeout)
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, output == AppVersion.versionLine(expectedVersion.description) else {
            let detail = output.isEmpty ? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) : output
            throw UpdateError.launchCheckFailed("exit code \(result.status): \(detail.prefix(200))")
        }
    }
}

/// Reemplazo del `.app` instalado (spec D.3, paso 5): el actual pasa a `PRBar.app.previous` (en la misma carpeta) y
/// el nuevo ocupa su lugar; si el segundo paso falla, el anterior vuelve. Funciona donde esté instalada la app
/// (`Bundle.main.bundleURL`).
public struct AppReplacer: Sendable {
    public typealias Move = @Sendable (URL, URL) throws -> Void

    private let move: Move

    /// `move` se puede reemplazar en los tests para simular fallas.
    public init(move: @escaping Move = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        self.move = move
    }

    public static func previousURL(for installed: URL) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(installed.lastPathComponent + ".previous", isDirectory: true)
    }

    /// Antes de compilar: sin permiso de escritura en la carpeta del `.app` no se puede reemplazar.
    public static func checkWritable(_ installed: URL) throws {
        let folder = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }
    }

    public func replace(installed: URL, with newApp: URL) throws {
        let fileManager = FileManager.default
        let previous = Self.previousURL(for: installed)
        do {
            if fileManager.fileExists(atPath: previous.path) { try fileManager.removeItem(at: previous) }
            try move(installed, previous)
        } catch {
            throw UpdateError.replaceFailed(
                "Couldn't move the installed app aside (\(error.localizedDescription)). The installed version wasn't changed."
            )
        }
        do {
            try move(newApp, installed)
        } catch {
            do {
                try move(previous, installed)
            } catch let restoreError {
                throw UpdateError.replaceFailed(
                    "Couldn't install the new app (\(error.localizedDescription)) or put the previous one back "
                        + "(\(restoreError.localizedDescription)). The previous version is at \(previous.path)."
                )
            }
            throw UpdateError.replaceFailed(
                "Couldn't install the new app (\(error.localizedDescription)). The installed version wasn't changed."
            )
        }
    }

    /// La versión nueva, al arrancar, borra la anterior. Nunca lanza: los errores se loguean.
    public static func removePrevious(nextTo installed: URL) {
        let previous = previousURL(for: installed)
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        do {
            try FileManager.default.removeItem(at: previous)
        } catch {
            AppLog.write("Couldn't delete \(previous.path): \(error.localizedDescription)")
        }
    }
}
