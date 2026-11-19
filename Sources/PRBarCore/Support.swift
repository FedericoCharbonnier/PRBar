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
    public static var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    public static var slackStateFile: URL { appSupport.appendingPathComponent("slack-state.json") }
    /// Registros y logs de las reviews.
    public static var historyDir: URL { appSupport.appendingPathComponent("history", isDirectory: true) }
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
}

/// Log de texto plano. Las escrituras se serializan en una cola propia porque llegan desde el main actor
/// y desde tareas en segundo plano.
public enum AppLog {
    private static let queue = DispatchQueue(label: "PRBar.AppLog")
    /// Solo se accede desde `queue`.
    nonisolated(unsafe) private static var destination: URL? = AppPaths.logFile

    /// Cambia el archivo de log; `nil` lo desactiva. Pensado para los tests.
    public static func setDestination(_ url: URL?) {
        queue.sync { destination = url }
    }

    public static func write(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        queue.sync {
            guard let url = destination else { return }
            append(Data(line.utf8), to: url)
        }
    }

    private static func append(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            FileHandle.standardError.write(data)
        }
    }
}
