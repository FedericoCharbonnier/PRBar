import Foundation
import os

/// Which Claude Code conversation a run belongs to (the chat, spec B.4). Sessions are stored per cwd: a `resume`
/// has to run in the same directory as the run that started it.
public enum ClaudeSessionFlag: Equatable, Sendable {
    /// `--session-id <uuid>`: a new conversation with this id.
    case start(UUID)
    /// `--resume <uuid>`: continue that conversation.
    case resume(UUID)

    public var id: UUID {
        switch self {
        case .start(let id), .resume(let id): id
        }
    }
}

/// Una corrida de `claude -p` aislada: qué pedirle, con qué herramientas y dónde.
public struct ClaudeInvocation: Sendable {
    public var prompt: String
    /// JSON Schema de la salida estructurada (`--json-schema`).
    public var schema: String
    /// Las únicas herramientas disponibles (`--tools`), p. ej. `["Read","Grep","Glob","Skill","Agent"]` o esas
    /// más `["Edit","Write"]`. Nunca `Bash`. Las de archivos se permiten solo dentro del cwd (ver `allowedRules`).
    public var tools: [String]
    /// El cwd de Claude.
    public var workingDirectory: URL
    /// Carpetas extra que Claude puede leer, nunca escribir (`--add-dir`).
    public var additionalDirectories: [URL]
    public var timeout: TimeInterval
    /// Encabezado de la corrida en el log, p. ej. `"=== etapa 1 ==="`.
    public var logHeader: String
    /// The conversation (only the chat uses one). `nil` = a one-off run, as in the review and the fixes.
    public var session: ClaudeSessionFlag?

    public init(prompt: String, schema: String, tools: [String], workingDirectory: URL,
                additionalDirectories: [URL] = [], timeout: TimeInterval, logHeader: String,
                session: ClaudeSessionFlag? = nil) {
        self.prompt = prompt
        self.schema = schema
        self.tools = tools
        self.workingDirectory = workingDirectory
        self.additionalDirectories = additionalDirectories
        self.timeout = timeout
        self.logHeader = logHeader
        self.session = session
    }
}

/// Errores de programación: `ClaudeRunner` se niega a correr una invocación insegura, antes de lanzar nada.
public enum ClaudeRunnerError: Error, Equatable, LocalizedError {
    /// La invocación pidió una herramienta que Claude nunca puede tener (shell, red o notebooks).
    case forbiddenTool(String)
    /// El entorno de Claude traía un token (en el valor de una variable permitida).
    case secretInEnvironment(variable: String)
    /// El cwd o una carpeta extra está dentro de una ruta que Claude tiene negada (`ClaudeRunner.deniedPaths`):
    /// no podría leer nada.
    case deniedDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .forbiddenTool(let tool): "Internal error: Claude can't use the \(tool) tool."
        case .secretInEnvironment(let variable): "Internal error: Claude's environment contained a token (\(variable))."
        case .deniedDirectory(let path):
            "Claude can't work in \(path): it's inside a protected folder (~/.ssh, ~/.aws, ~/.config, ~/Library or ~/.gnupg). Use another folder for the clone or the worktrees."
        }
    }
}

/// Corre Claude Code aislado (spec §8.3), con streaming, un reintento si la salida es inválida, log y redacción.
///
/// - Sin la configuración del usuario ni la del repo (`--setting-sources ""`): los plugins van con `--plugin-dir`.
/// - Sin MCP (ni servidores ni conectores: `mcp__*` negado), en modo `dontAsk` y solo con las herramientas de la
///   invocación. Nunca shell ni red.
/// - Archivos: solo dentro del cwd y de las carpetas extra. Un `Read` o `Edit` suelto en `--allowedTools`
///   permitiría cualquier ruta del disco (p. ej. `~/.ssh`), así que se permiten con ruta (`Read(./**)`,
///   `Edit(./**)`), y `--settings` además bloquea toda lectura y escritura fuera de las carpetas de trabajo y niega
///   las carpetas de secretos (`deniedPaths`). Verificado con el CLI real (spec §8.3).
/// - El entorno es una lista blanca (`environmentAllowlist`) y el proceso no hereda el de la app; los `secrets`
///   se tachan (`***`) del log, de la salida y de los errores.
public struct ClaudeRunner: Sendable {
    /// Lo que va siempre en el PATH de Claude, detrás de las carpetas de las herramientas.
    static let basePath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// Herramientas que nunca se ofrecen: una invocación que las pida es rechazada, y además se niegan
    /// explícitamente en `--disallowedTools` (defensa en profundidad).
    public static let alwaysDisallowedTools = ["Bash", "NotebookEdit", "WebFetch", "WebSearch"]
    /// Se niegan explícitamente salvo que la invocación las pida.
    public static let writeTools = ["Edit", "Write"]
    /// Herramientas de lectura de archivos: se permiten solo con ruta (`Read(./**)`; Grep y Glob se rigen por las
    /// reglas de `Read`).
    static let readTools = ["Read", "Grep", "Glob"]
    /// Herramientas de MCP (servidores y conectores de claude.ai): siempre negadas.
    static let mcpTools = "mcp__*"
    /// Rutas que Claude nunca puede leer ni editar, aunque estén dentro de una carpeta de trabajo. Formato de
    /// reglas de permisos de Claude Code: `~/` es el home y `//` la raíz del disco.
    public static let deniedPaths = ["~/.ssh/**", "~/.aws/**", "~/.config/**", "~/Library/**", "~/.gnupg/**", "//**/.env*"]
    /// Files Claude can read but never write, anywhere (Edit rules also govern Write): git's own files and the ones
    /// that change how git reads and writes the tree. Verified with the real CLI (2.1.318, spec B.11): without these
    /// rules `.gitattributes` and `.lfsconfig` were writable; `.git` (folder or worktree file) was already protected.
    public static let writeDeniedPaths = ["//**/.git", "//**/.git/**", "//**/.gitattributes", "//**/.lfsconfig"]
    /// Las únicas variables de entorno que recibe Claude. `SHELL` siempre es `/bin/zsh`.
    public static let environmentAllowlist = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"]

    private let runner: StreamingProcessRunning
    private let claudePath: String
    private let pluginDirs: [String]
    private let model: ClaudeModel?
    private let environment: [String: String]
    private let secrets: [String]
    private let log: ClaudeLogWriter

    /// `pluginDirs`: los de `ClaudePlugins.locate(skills:)`. `environment`: el entorno completo de Claude (ver
    /// `environment(toolPaths:)`); las variables fuera de `environmentAllowlist` se descartan. `secrets`: se tachan
    /// del log, de la salida y de los errores. `model`: `--model` (`nil` = el del CLI).
    public init(runner: StreamingProcessRunning, claudePath: String, pluginDirs: [String],
                environment: [String: String], logURL: URL, redacting secrets: [String], model: ClaudeModel? = nil) {
        self.runner = runner
        self.claudePath = claudePath
        self.pluginDirs = pluginDirs
        self.model = model
        self.environment = environment.filter { Self.environmentAllowlist.contains($0.key) }
        self.secrets = secrets
        self.log = ClaudeLogWriter(url: logURL, secrets: secrets)
    }

    /// La lista blanca, y nada más: PATH (las carpetas de las herramientas, sin repetir, delante de las del
    /// sistema; nunca el PATH de la app), HOME, USER y LOGNAME (de `inherited` o averiguados), TMPDIR, LANG y
    /// LC_ALL (si están en `inherited`) y SHELL=/bin/zsh. Ningún token, ni `SSH_AUTH_SOCK`, ni `DYLD_*`.
    public static func environment(toolPaths: [String],
                                   inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var dirs: [String] = []
        for dir in toolPaths.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().path }) + basePath where !dirs.contains(dir) {
            dirs.append(dir)
        }
        var environment = [
            "PATH": dirs.joined(separator: ":"),
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "USER": inherited["USER"] ?? NSUserName(),
            "LOGNAME": inherited["LOGNAME"] ?? inherited["USER"] ?? NSUserName(),
            "SHELL": "/bin/zsh",
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL"] { environment[key] = inherited[key] }
        return environment
    }

    // MARK: - Argumentos

    public static func arguments(for invocation: ClaudeInvocation, pluginDirs: [String], model: ClaudeModel? = nil) -> [String] {
        let tools = invocation.tools.joined(separator: ",")
        let disallowed = disallowedTools(for: invocation.tools)
        var arguments = ["-p", invocation.prompt]
        if let model { arguments += ["--model", model.rawValue] }
        switch invocation.session {
        case .start(let id)?: arguments += ["--session-id", id.uuidString.lowercased()]
        case .resume(let id)?: arguments += ["--resume", id.uuidString.lowercased()]
        case nil: break
        }
        arguments += [
            "--output-format", "stream-json",
            "--verbose",
            "--json-schema", invocation.schema,
            // Ni ~/.claude/settings.json ni el .claude/ del repo: sin hooks, permisos ni MCP heredados.
            "--setting-sources", "",
            // Las únicas settings: las de PRBar (bloqueos de rutas, reglas de negación, sin shell en los skills).
            "--settings", settings(additionalDirectories: invocation.additionalDirectories),
        ]
        for dir in pluginDirs { arguments += ["--plugin-dir", dir] }
        arguments += [
            "--permission-mode", "dontAsk",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--tools", tools,
            "--allowedTools", allowedRules(for: invocation.tools).joined(separator: ","),
            "--disallowedTools", disallowed.joined(separator: ","),
        ]
        for dir in invocation.additionalDirectories { arguments += ["--add-dir", dir.path] }
        return arguments
    }

    /// Lo que va en `--allowedTools`: `Read(./**)` en vez de `Read`, `Grep` y `Glob` sueltos; `Edit(./**)` (que también
    /// rige a `Write`) si la invocación edita; y el resto de las herramientas (`Skill`, `Agent`) tal cual.
    /// `./` es el cwd de Claude. Ninguna regla lleva espacios ni comas (el flag los usa de separador).
    static func allowedRules(for tools: [String]) -> [String] {
        var rules: [String] = []
        if tools.contains(where: readTools.contains) { rules.append("Read(./**)") }
        if tools.contains(where: writeTools.contains) { rules.append("Edit(./**)") }
        return rules + tools.filter { !readTools.contains($0) && !writeTools.contains($0) }
    }

    /// El JSON de `--settings` (claves ordenadas): lecturas y escrituras de las herramientas de archivos
    /// bloqueadas fuera de las carpetas de trabajo (cwd y `--add-dir`), `Read` y `Edit` negados en `deniedPaths`,
    /// lectura explícita de cada carpeta extra, sin `bypassPermissions` y sin shell en línea en los skills.
    public static func settings(additionalDirectories: [URL]) -> String {
        let deny = deniedPaths.flatMap { ["Read(\($0))", "Edit(\($0))"] } + writeDeniedPaths.map { "Edit(\($0))" }
        let settings: [String: Any] = [
            "disableSkillShellExecution": true,
            "permissions": [
                "allow": additionalDirectories.map { "Read(/\($0.path)/**)" },
                "blockReadsOutsideWorkingDirectories": true,
                "blockWritesOutsideWorkingDirectories": true,
                "deny": deny,
                "disableBypassPermissionsMode": "disable",
            ] as [String: Any],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `Bash,NotebookEdit,WebFetch,WebSearch,mcp__*` siempre; `Edit` y `Write` si la invocación no los pide.
    /// En el orden `Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*`.
    static func disallowedTools(for tools: [String]) -> [String] {
        ["Bash"] + writeTools.filter { !tools.contains($0) } + alwaysDisallowedTools.filter { $0 != "Bash" } + [mcpTools]
    }

    /// Las carpetas absolutas de `deniedPaths` que cuelgan del home (`~/.ssh`, `~/Library`, …).
    static func deniedDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        deniedPaths.compactMap { path -> String? in
            guard path.hasPrefix("~/"), path.hasSuffix("/**") else { return nil }
            return home.appendingPathComponent(String(path.dropFirst(2).dropLast(3))).standardizedFileURL.path
        }
    }

    /// `path` (con symlinks resueltos) está dentro de una carpeta negada.
    static func isInsideDeniedDirectory(_ url: URL) -> Bool {
        let paths = Set([url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path])
        let denied = deniedDirectories() + deniedDirectories(home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath())
        return paths.contains { path in denied.contains { path == $0 || path.hasPrefix($0 + "/") } }
    }

    static func retryPrompt(_ prompt: String, detail: String) -> String {
        prompt + "\n\nThe previous attempt returned an invalid result (\(detail)). Reply only with the requested structured output."
    }

    /// `"=== stage 1 ==="` → `"=== stage 1 (retry) ==="`.
    static func retryHeader(_ header: String) -> String {
        header.hasSuffix(" ===") ? String(header.dropLast(4)) + " (retry) ===" : header + " (retry)"
    }

    // MARK: - Corrida

    /// One run with one retry if the output is invalid or missing. Returns the decoded JSON (already redacted).
    /// `onAgent` is called, in order and from any thread, with 0 when each attempt starts and with the subagent
    /// total each time one starts.
    public func run<T: Decodable>(_ invocation: ClaudeInvocation, as type: T.Type,
                                  onAgent: @escaping @Sendable (Int) -> Void) async throws -> T {
        try await run(invocation, as: type, onEvent: { event in
            if case .agentStarted(let total) = event { onAgent(total) }
        })
    }

    /// Like `run(_:as:onAgent:)`, with every stream event: `agentStarted(0)` when each attempt starts, then the
    /// text, the tool calls and the subagents as they come (`ClaudeStreamParser.consumeAll`).
    public func run<T: Decodable>(_ invocation: ClaudeInvocation, as type: T.Type,
                                  onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> T {
        try validate(invocation)
        do {
            return try await attempt(invocation, as: type, onEvent: onEvent)
        } catch let error as ClaudeError {
            let detail: String
            switch error {
            case .invalidOutput(let message): detail = message
            case .noResult: detail = "there was no result"
            case .failed: throw error
            }
            log.append("--- invalid result: \(detail); retrying ---\n")
            return try await attempt(Self.retryInvocation(invocation, detail: detail), as: type, onEvent: onEvent)
        }
    }

    /// The retry of an invalid output. Without a session it repeats the prompt with a note (as always). With one,
    /// the first attempt already started (or continued) the conversation: the retry continues it (`--resume`)
    /// with just the correction, so the conversation doesn't get the prompt twice.
    static func retryInvocation(_ invocation: ClaudeInvocation, detail: String) -> ClaudeInvocation {
        var retry = invocation
        retry.logHeader = retryHeader(invocation.logHeader)
        if let session = invocation.session {
            retry.session = .resume(session.id)
            retry.prompt = "Your previous answer was invalid (\(detail)). Reply only with the requested structured output."
        } else {
            retry.prompt = retryPrompt(invocation.prompt, detail: detail)
        }
        return retry
    }

    /// Las garantías de aislamiento que no dependen de los flags: se chequean antes de lanzar nada.
    private func validate(_ invocation: ClaudeInvocation) throws {
        for tool in invocation.tools {
            // `contains`: también `Bash(git:*)`, `BashOutput`, etc.
            if tool.contains("Bash") || Self.alwaysDisallowedTools.contains(tool) {
                throw ClaudeRunnerError.forbiddenTool(tool)
            }
        }
        for directory in [invocation.workingDirectory] + invocation.additionalDirectories where Self.isInsideDeniedDirectory(directory) {
            throw ClaudeRunnerError.deniedDirectory(directory.path)
        }
        for (variable, value) in environment.sorted(by: { $0.key < $1.key }) {
            let leaksSecret = secrets.contains { secret in
                let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && value.contains(trimmed)
            }
            if SystemProcessRunner.unheritedVariables.contains(variable) || leaksSecret {
                throw ClaudeRunnerError.secretInEnvironment(variable: variable)
            }
        }
    }

    private func redact(_ text: String) -> String { Redactor.redact(text, secrets: secrets) }

    /// Agrega texto al log de las corridas (con los secretos tachados), p. ej. la salida del testCommand.
    public func appendLog(_ text: String) {
        log.append(text)
    }

    private func attempt<T: Decodable>(_ invocation: ClaudeInvocation, as type: T.Type,
                                       onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> T {
        log.append(invocation.logHeader + "\n")
        onEvent(.agentStarted(total: 0))

        let parser = OSAllocatedUnfairLock(initialState: ClaudeStreamParser())
        let log = self.log
        let secrets = self.secrets
        let result: ProcessResult
        do {
            // Exact environment: Claude doesn't inherit the app's (it can have tokens, `SSH_AUTH_SOCK`, `DYLD_*`, …).
            result = try await runner.runStreamingIsolated(
                claudePath, Self.arguments(for: invocation, pluginDirs: pluginDirs, model: model),
                environment: environment, currentDirectory: invocation.workingDirectory, timeout: invocation.timeout
            ) { line in
                // Redacted before parsing: the decoded output and the errors don't carry the token either.
                let line = Redactor.redact(line, secrets: secrets)
                log.append(line + "\n")
                for event in parser.withLock({ $0.consumeAll(line) }) { onEvent(event) }
            }
        } catch {
            log.append("--- \(error) ---\n")
            throw error
        }

        if !result.stderr.isEmpty { log.append("--- stderr ---\n" + result.stderr + (result.stderr.hasSuffix("\n") ? "" : "\n")) }
        let finalParser = parser.withLock { $0 }
        if finalParser.result == nil, result.status != 0 {
            throw PRBarError.commandFailed(
                command: "claude", status: result.status,
                stderr: redact(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        return try finalParser.decodeResult(T.self)
    }
}

/// Entrega en orden al main actor valores que llegan desde cualquier hilo (p. ej. el progreso de Claude, que
/// llega en el hilo lector del proceso). `finish()` espera a que se hayan entregado todos.
public struct MainActorRelay<Value: Sendable>: Sendable {
    private let sink: AsyncStream<Value>.Continuation
    private let consumer: Task<Void, Never>

    public init(_ handler: @escaping @MainActor @Sendable (Value) -> Void) {
        let (stream, sink) = AsyncStream<Value>.makeStream()
        self.sink = sink
        consumer = Task { @MainActor in
            for await value in stream { handler(value) }
        }
    }

    public func send(_ value: Value) { sink.yield(value) }

    public func finish() async {
        sink.finish()
        await consumer.value
    }
}

/// Tacha secretos (el token de la cuenta) de lo que se guarda o se muestra.
public enum Redactor {
    public static let mask = "***"

    /// Reemplaza cada secreto no vacío por `***`.
    public static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { text, secret in
            secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? text : text.replacingOccurrences(of: secret, with: mask)
        }
    }
}

/// Agrega texto al log de una corrida de Claude, con los secretos tachados. Se llama desde el hilo lector del
/// proceso; nunca lanza.
final class ClaudeLogWriter: @unchecked Sendable {
    private let url: URL
    private let secrets: [String]
    private let lock = NSLock()

    init(url: URL, secrets: [String] = []) {
        self.url = url
        self.secrets = secrets
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data(Redactor.redact(text, secrets: secrets).utf8)
        do {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        } catch {
            AppLog.write("Could not write Claude's log \(url.path): \(error)")
        }
    }
}
