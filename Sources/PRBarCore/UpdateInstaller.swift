import Foundation

/// Etapas de una actualización (ventana "Update PRBar" y eventos de `prbar update`).
public enum UpdatePhase: String, Codable, CaseIterable, Sendable {
    case waitingForJobs, fetching, building, verifying, installing, relaunching

    public var title: String {
        switch self {
        case .waitingForJobs: "Waiting for running jobs"
        case .fetching: "Downloading the source"
        case .building: "Building (takes a minute or two)"
        case .verifying: "Checking the new app"
        case .installing: "Installing"
        case .relaunching: "Restarting PRBar"
        }
    }
}

public enum UpdateEvent: Equatable, Sendable {
    case phase(UpdatePhase)
    /// Una línea del log (git, build).
    case log(String)
}

/// Qué hacer con los trabajos (reviews, responds, chats) que están corriendo al actualizar (spec D.3, paso 1).
public enum UpdateBusyPolicy: String, Codable, Sendable {
    /// Actualizar cuando terminen.
    case wait
    /// Cancelarlos (salvo una publicación o un push en curso, que se espera) y actualizar.
    case cancelJobs
}

/// Instala un release (spec D.3, pasos 2 a 5): fuente → build con `Scripts/bundle.sh --output` (con un entorno
/// mínimo) → el `.app` pasa al lado del instalado (`AppReplacer.candidateURL`, así el reemplazo es un rename en el
/// mismo volumen) → verificación → `beforeReplace` → otra verificación → reemplazo. Si algo falla antes del
/// reemplazo, el `.app` instalado no se toca; el staging (vaciado al empezar) y el candidato siempre se borran. Esperar trabajos y reiniciar quedan para la app (`beforeReplace`, `Relauncher`).
public struct UpdateInstaller: Sendable {
    public static let buildTimeout: TimeInterval = 30 * 60
    /// Lo único del entorno de la app que recibe el build (`bash Scripts/bundle.sh` → `swift build`, `codesign`):
    /// nada de tokens, `DYLD_*` ni variables de SwiftPM.
    public static let buildEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS",
        // El build baja swift-argument-parser (Package.resolved): detrás de un proxy, sin esto no llega.
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
    ]
    static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func buildEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { buildEnvironmentKeys.contains($0.key) && !$0.value.isEmpty }
        if environment["PATH"] == nil { environment["PATH"] = defaultPath }
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        return environment
    }

    private let source: UpdateSource
    private let builder: StreamingProcessRunning
    private let runner: ProcessRunning
    private let stagingRoot: URL
    private let bundleIdentifier: String
    private let replacer: AppReplacer

    public init(
        source: UpdateSource, builder: StreamingProcessRunning, runner: ProcessRunning,
        stagingRoot: URL = AppPaths.updateStagingDir, bundleIdentifier: String, replacer: AppReplacer = AppReplacer()
    ) {
        self.source = source
        self.builder = builder
        self.runner = runner
        self.stagingRoot = stagingRoot
        self.bundleIdentifier = bundleIdentifier
        self.replacer = replacer
    }

    /// `beforeReplace` corre después de verificar y antes de reemplazar (la app vuelve a esperar trabajos ahí).
    /// `onEvent` se llama desde cualquier hilo.
    public func install(
        _ release: ReleaseInfo, replacing installedApp: URL,
        beforeReplace: @escaping @Sendable () async throws -> Void = {},
        onEvent: @escaping @Sendable (UpdateEvent) -> Void
    ) async throws {
        try AppReplacer.checkWritable(installedApp)
        let fileManager = FileManager.default
        // Lo que haya quedado de una instalación anterior (p. ej. si la app se cerró a la mitad).
        try? fileManager.removeItem(at: stagingRoot)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        onEvent(.phase(.fetching))
        let sha = try await source.checkout(tag: release.tag)
        onEvent(.log("\(release.tag) is \(sha)"))

        onEvent(.phase(.building))
        let script = source.directory.appendingPathComponent("Scripts/bundle.sh")
        let build = try await builder.runStreamingIsolated(
            "/bin/bash", [script.path, "--output", staging.path],
            environment: Self.buildEnvironment(), currentDirectory: source.directory, timeout: Self.buildTimeout,
            onStdoutLine: { onEvent(.log($0)) }
        )
        for line in build.stderr.split(whereSeparator: \.isNewline) { onEvent(.log(String(line))) }
        guard build.status == 0 else { throw UpdateError.buildFailed(status: build.status) }

        onEvent(.phase(.verifying))
        // Se copia (si es otro volumen) antes de verificar: lo que se verifica es lo que después se renombra.
        let built = staging.appendingPathComponent("PRBar.app", isDirectory: true)
        let newApp = AppReplacer.candidateURL(for: installedApp)
        defer { try? fileManager.removeItem(at: newApp) }
        do {
            try fileManager.moveItem(at: built, to: newApp)
        } catch {
            guard fileManager.fileExists(atPath: built.path) else { throw UpdateError.appMissing(built.path) }
            throw UpdateError.replaceFailed(
                "Couldn't copy the new app next to the installed one (\(error.localizedDescription)). The installed version wasn't changed."
            )
        }
        try await UpdateVerifier.verify(app: newApp, expectedVersion: release.version, bundleIdentifier: bundleIdentifier, runner: runner)

        try await beforeReplace()
        try Task.checkCancellation()
        // Pudo pasar un rato esperando trabajos: se verifica de nuevo justo antes de reemplazar.
        try await UpdateVerifier.verify(app: newApp, expectedVersion: release.version, bundleIdentifier: bundleIdentifier, runner: runner)
        onEvent(.phase(.installing))
        try replacer.replace(installed: installedApp, with: newApp)
        onEvent(.log("Installed PRBar \(release.version) at \(installedApp.path)"))
    }
}
