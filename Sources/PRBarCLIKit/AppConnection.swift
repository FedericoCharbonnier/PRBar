import Foundation
import PRBarCore

/// La app no está corriendo y no se pudo abrir (exit 3).
public struct AppUnavailable: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Conexión con PRBar.app. Si la app no está corriendo, `open` la abre en segundo plano y reintenta hasta 10 s
/// (spec C.2).
public final class AppConnection {
    private let client: CommandClient
    public var appVersion: String { client.appVersion }

    init(client: CommandClient) {
        self.client = client
    }

    /// `PRBAR_SOCKET` cambia la ruta (desarrollo y tests).
    public static var socketOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment["PRBAR_SOCKET"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static var defaultSocketURL: URL { socketOverride ?? AppPaths.socketFile }

    public static var cliVersion: String { AppVersion.forExecutable(AppLauncher.executableURL()) }

    /// Solo conecta: sin app, `AppUnavailable`; con versiones de protocolo distintas, `CommandFailure`.
    public static func connect(socketURL: URL = defaultSocketURL) throws -> AppConnection {
        do {
            return AppConnection(client: try CommandClient.connect(socketURL: socketURL, clientVersion: cliVersion))
        } catch CommandClient.ConnectError.unavailable(let reason) {
            throw AppUnavailable("PRBar isn’t running (\(reason)).")
        }
    }

    /// Con `PRBAR_SOCKET` no abre nada: la app que abriría escucha en el socket de siempre, no en ese (y los tests
    /// nunca tienen que abrir la PRBar instalada).
    public static func open(socketURL: URL = defaultSocketURL, timeout: TimeInterval = 10,
                            launches: Bool = socketOverride == nil) throws -> AppConnection {
        do {
            return try connect(socketURL: socketURL)
        } catch let unavailable as AppUnavailable {
            guard launches else { throw unavailable }
            try AppLauncher.launch()
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            do {
                return try connect(socketURL: socketURL)
            } catch is AppUnavailable {
                continue
            }
        } while Date() < deadline
        throw AppUnavailable("PRBar didn’t start within \(Int(timeout)) seconds. Open it from ~/Applications or run `prbar doctor`.")
    }

    public func run(_ command: AppCommand, onEvent: (CommandEvent) -> Void = { _ in }) throws -> JSONValue {
        do {
            return try client.send(command, onEvent: onEvent)
        } catch CommandClient.ConnectError.unavailable(let reason) {
            throw AppUnavailable("Lost the connection to PRBar (\(reason)).")
        }
    }

    public func close() {
        client.close()
    }
}

public enum AppLauncher {
    public static let bundleID = "com.federico.prbar"

    public static func executableURL() -> URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// El `PRBar.app` que contiene a este `prbar` (`Contents/Helpers/prbar`, resolviendo links) o, si no,
    /// `~/Applications/PRBar.app` si existe.
    public static func appBundle(executable: URL = executableURL(),
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let helpers = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        if helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", app.pathExtension == "app" {
            return app
        }
        let installed = home.appendingPathComponent("Applications/PRBar.app")
        return FileManager.default.fileExists(atPath: installed.path) ? installed : nil
    }

    /// `open -g`: la abre sin traerla al frente.
    public static func launch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = appBundle() {
            process.arguments = ["-g", "-a", app.path]
        } else {
            process.arguments = ["-g", "-b", bundleID]
        }
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUnavailable("Couldn’t open PRBar.app. Install it with `Scripts/bundle.sh --install` or run `prbar doctor`.")
        }
    }
}
