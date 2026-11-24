import Foundation

public enum PRBarError: Error, Equatable, Codable, Sendable, LocalizedError {
    case toolNotFound(String)
    case commandFailed(command: String, status: Int32, stderr: String)
    case unauthorized
    case rateLimited(resetAt: Date)
    case http(status: Int, message: String)
    case graphQL(String)
    case invalidResponse(String)
    case timedOut(command: String)
    case network(String)
    case slack(String)
    case keychain(Int32)
    case stateNotSaved(String)
    case emptyReview
    /// A configured skill (`skill`, `plugin:…`) needs a Claude Code plugin that isn't installed.
    case claudePluginMissing(plugin: String, skill: String)
    /// Responder el feedback de un PR propio no puede seguir; el texto ya está listo para mostrar.
    case respond(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            "Couldn't find `\(tool)`. Install it or set its path in Settings → General."
        case .commandFailed(let command, let status, let stderr):
            "`\(command)` failed (code \(status)): \(stderr)"
        case .unauthorized:
            "GitHub rejected the token. Run `gh auth login --hostname github.com`."
        case .rateLimited(let resetAt):
            "GitHub API rate limit reached. Retrying at \(resetAt.formatted(date: .omitted, time: .shortened))."
        case .http(let status, let message):
            "GitHub responded \(status): \(message)"
        case .graphQL(let message):
            "GitHub error: \(message)"
        case .invalidResponse(let message):
            "Unexpected response from GitHub: \(message)"
        case .timedOut(let command):
            "`\(command)` took too long and was canceled."
        case .network(let message):
            "Couldn't connect to GitHub: \(message)"
        case .slack(let code):
            switch code {
            case "not_in_channel": "You're not a member of the channel. Join it to post there."
            case "invalid_name": "That emoji doesn't exist in this workspace."
            case "channel_not_found": "Couldn't find the configured channel. Choose it again in Settings → Repos."
            case "invalid_auth", "token_revoked", "not_authed", "account_inactive":
                "The Slack token isn't valid. Check it in Settings → Slack."
            case "missing_token": "The Slack user token is missing. Paste it in Settings → Slack."
            case "bot_token_rejected": "That token posts as an app (xoxb-…). Paste the User OAuth Token (xoxp-…)."
            case "invalid_user_token": "That doesn't look like a Slack User OAuth Token. It starts with xoxp-."
            case "missing_scope":
                "Your Slack token is missing a scope (needs chat:write, reactions:write, channels:history, groups:history, channels:read and groups:read)."
            case "connector_mismatch":
                "Claude's Slack connector didn't do exactly what PRBar asked, so it wasn't marked as done. Details in slack-connector.log."
            case "connector_unavailable":
                "Claude's Slack connector isn't available. Connect Slack in claude.ai → Settings → Connectors, and check that `claude` is signed in."
            case "connector_error": "Claude's Slack connector returned an error. Details in slack-connector.log."
            case "connector_no_ts":
                "Slack said the message was posted, but Claude's Slack connector didn't return its timestamp. PRBar checks the channel before trying again."
            case "connector_uncertain":
                "PRBar couldn't tell whether Claude's Slack connector did it. It checks Slack before trying again, so nothing is posted twice. Details in slack-connector.log."
            case "connector_invalid_output": "Claude's Slack connector returned a result PRBar couldn't read."
            default: "Slack error: \(code)"
            }
        case .keychain(let status):
            "Couldn't access the Keychain (code \(status))."
        case .emptyReview:
            "Select at least one comment or write a general one."
        case .claudePluginMissing(let plugin, let skill):
            "The skill \"\(skill)\" needs the Claude Code plugin \"\(plugin)\", which isn't installed. Install it from Claude Code with `/plugin install \(plugin)` (add `@marketplace` if it's not unique) and try again, or choose another skill in Settings → Claude."
        case .respond(let message):
            message
        case .stateNotSaved(let message):
            "Couldn't save the Slack state (slack-state.json): \(message). A restart could repeat messages."
        }
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AppPaths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRBar", isDirectory: true)
    }
    public static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    /// Los iPhones emparejados (spec P.2): solo claves públicas, 0600 en una carpeta 0700.
    public static var remoteDir: URL { appSupport.appendingPathComponent("remote", isDirectory: true) }
    /// El id de esta instalación de PRBar (su subcarpeta en la carpeta remota de cada host). Aparte de la config:
    /// si se copia la config a otra Mac, el id no viaja.
    public static var installationIDFile: URL { appSupport.appendingPathComponent("installation-id") }
    /// Socket de `prbar` (spec C.2). La carpeta queda en 0700 (`CommandServer.secure`).
    public static var socketFile: URL { appSupport.appendingPathComponent("prbar.sock") }
    public static var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    public static var slackStateFile: URL { appSupport.appendingPathComponent("slack-state.json") }
    /// The folders kept for "Open in Terminal" (spec T.3).
    public static var retainedWorktreesFile: URL { appSupport.appendingPathComponent("retained-worktrees.json") }
    /// The `.command` scripts that open a Claude session in a terminal (spec T.5); the ones older than a day go.
    public static var terminalDir: URL { appSupport.appendingPathComponent("terminal", isDirectory: true) }
    /// Registros y logs de las reviews.
    public static var historyDir: URL { appSupport.appendingPathComponent("history", isDirectory: true) }
    /// Clon propio del repo de PRBar del que se compilan las actualizaciones (spec D.3). Nunca es el checkout de
    /// desarrollo del usuario.
    public static var updateSourceDir: URL { appSupport.appendingPathComponent("source", isDirectory: true) }
    /// Donde se arma el `.app` nuevo: misma unidad que `~/Applications`, así reemplazarlo es un rename.
    public static var updateStagingDir: URL { appSupport.appendingPathComponent("update-staging", isDirectory: true) }
    /// La versión recién instalada; la lee la versión nueva al arrancar para mostrar "Updated to …".
    public static var pendingUpdateFile: URL { appSupport.appendingPathComponent("update-installed.json") }
    /// Log de la última actualización ("Show Log").
    public static var updateLog: URL { logFile.deletingLastPathComponent().appendingPathComponent("update.log") }
    /// Worktrees y carpetas temporales de las reviews (y las carpetas de contexto de "Responder"). Se vacía al
    /// arrancar. Está en la carpeta temporal del usuario y no en `~/Library`, porque Claude tiene `~/Library/**`
    /// negado (`ClaudeRunner.deniedPaths`) y ahí no podría leer el código.
    public static var worktreesDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/worktrees", isDirectory: true)
    }
    /// Donde estaban los worktrees hasta que se negó `~/Library` a Claude. Se sigue vaciando al arrancar.
    public static var legacyWorktreesDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRBar/worktrees", isDirectory: true)
    }
    /// Log de las corridas de Claude con el conector de Slack (spec §17.5).
    public static var slackConnectorLog: URL {
        logFile.deletingLastPathComponent().appendingPathComponent("slack-connector.log")
    }
    /// cwd vacío de esas corridas: Claude no tiene herramientas de archivos, pero no arranca en ninguna carpeta real.
    public static var slackConnectorDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/slack-connector", isDirectory: true)
    }
    public static var logFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PRBar/prbar.log")
    }
    /// Rules, decisions about suggestions and the instructions chat (spec E.1).
    public static var instructionsFile: URL { appSupport.appendingPathComponent("instructions.json") }
    /// The findings the user discarded when posting, for the suggestions (spec E.4).
    public static var discardStatsFile: URL { appSupport.appendingPathComponent("discard-stats.json") }
    /// El libro de uso de Claude (spec O): una entrada por corrida.
    public static var usageFile: URL { appSupport.appendingPathComponent("usage.json") }
    /// The instructions chat's cwd: an empty folder, always the same so `--resume` finds the session (spec E.2).
    public static var instructionsChatDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/instructions-chat", isDirectory: true)
    }
    public static var instructionsChatLog: URL {
        logFile.deletingLastPathComponent().appendingPathComponent("instructions-chat.log")
    }
}

/// Log de texto plano. Las escrituras se serializan en una cola propia porque llegan desde el main actor
/// y desde tareas en segundo plano. The file stays open between lines and rolls at `RollingLogFile.defaultLimit`.
public enum AppLog {
    private static let queue = DispatchQueue(label: "PRBar.AppLog")
    /// Solo se accede desde `queue`.
    nonisolated(unsafe) private static var file: RollingLogFile? = RollingLogFile(url: AppPaths.logFile)
    /// Solo se accede desde `queue` (a formatter per line was most of a write's cost).
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    /// Cambia el archivo de log; `nil` lo desactiva. Pensado para los tests.
    public static func setDestination(_ url: URL?) {
        queue.sync {
            file?.close()
            file = url.map { RollingLogFile(url: $0) }
        }
    }

    public static func write(_ message: String) {
        let now = Date()
        queue.sync {
            guard let file else { return }
            let line = "[\(formatter.string(from: now))] \(message)\n"
            do {
                try file.append(Data(line.utf8))
            } catch {
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }
}

/// An append-only log file kept open between writes. Opened with `O_APPEND`, so several writers of the same file
/// (two runners sharing a run log) never overwrite each other. When it passes `limit` bytes it's renamed to
/// `<name>.1` (replacing the previous one) and a new file starts: at most about twice the limit on disk.
public final class RollingLogFile: @unchecked Sendable {
    public static let defaultLimit = 5 << 20

    public let url: URL
    public let limit: Int
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(url: URL, limit: Int = RollingLogFile.defaultLimit) {
        self.url = url
        self.limit = limit
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    /// `prbar.log` → `prbar.log.1`.
    public static func rolledURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1")
    }

    public func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let fd = try openIfNeeded()
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size >= limit { roll(fd, info) }
    }

    /// Closes the file; the next `append` opens it again.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
    }

    private func openIfNeeded() throws -> Int32 {
        if descriptor >= 0 {
            // Deleted or rolled by someone else (another writer, a cleanup): start writing to the path again.
            var open = stat(), path = stat()
            if fstat(descriptor, &open) == 0, lstat(url.path, &path) == 0, open.st_ino == path.st_ino, open.st_dev == path.st_dev {
                return descriptor
            }
            Darwin.close(descriptor)
            descriptor = -1
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        descriptor = fd
        return fd
    }

    private func roll(_ fd: Int32, _ info: stat) {
        // Only the file at `url` rolls: if another writer already moved it, this one just follows the path.
        var path = stat()
        if lstat(url.path, &path) == 0, path.st_ino == info.st_ino, path.st_dev == info.st_dev {
            let rolled = Self.rolledURL(for: url)
            _ = Darwin.rename(url.path, rolled.path)
        }
        Darwin.close(fd)
        descriptor = -1
    }
}
