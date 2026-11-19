import Foundation

/// Repos de git descartables en una carpeta temporal, para probar `WorktreeManager` con git de verdad.
/// Nunca toca los repos del usuario: `origin` y `local` se crean de cero y se borran al final.
///
/// `origin` tiene `main` (con `README.md`) y un PR #7 (`refs/pull/7/head`) que agrega `feature.txt` y los
/// archivos que pase `prFiles`; `local` es un clone de `origin`. `root` es la raíz de worktrees de PRBar.
struct TempGitRepo {
    static let git = "/usr/bin/git"

    let base: URL
    var origin: URL { base.appendingPathComponent("origin", isDirectory: true) }
    var local: URL { base.appendingPathComponent("local", isDirectory: true) }
    var root: URL { base.appendingPathComponent("worktrees", isDirectory: true) }
    /// SHA del commit del PR #7.
    let prSHA: String

    /// `prSetup` corre dentro de `origin`, en la rama del PR, antes del commit (p. ej. para crear symlinks).
    static func make(prSetup: (URL) throws -> Void = { _ in }) throws -> TempGitRepo {
        let base = try temporaryDirectory()
        let origin = base.appendingPathComponent("origin", isDirectory: true)
        try run(base, ["init", "-q", "-b", "main", origin.path])
        try Data("hola\n".utf8).write(to: origin.appendingPathComponent("README.md"))
        try run(origin, ["add", "-A"])
        try run(origin, ["commit", "-q", "-m", "base"])
        try run(origin, ["checkout", "-q", "-b", "feature"])
        try Data("nuevo\n".utf8).write(to: origin.appendingPathComponent("feature.txt"))
        try prSetup(origin)
        try run(origin, ["add", "-A"])
        try run(origin, ["commit", "-q", "-m", "pr"])
        let sha = try run(origin, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try run(origin, ["update-ref", "refs/pull/7/head", "HEAD"])
        try run(origin, ["checkout", "-q", "main"])
        try run(base, ["clone", "-q", origin.path, base.appendingPathComponent("local").path])
        return TempGitRepo(base: base, prSHA: sha)
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// `git -C <directory> <args>` con una configuración aislada (sin la global ni la del sistema).
    @discardableResult
    static func run(_ directory: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory.path, "-c", "user.name=PRBar Tests", "-c", "user.email=tests@prbar.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestFailure(description: "git \(arguments.joined(separator: " ")) falló: \(String(decoding: stderr, as: UTF8.self))")
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    /// Los nombres (última componente) de los worktrees que git tiene registrados en `local`.
    func worktreeNames() throws -> [String] {
        try Self.run(local, ["worktree", "list", "--porcelain"])
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { URL(fileURLWithPath: String($0.dropFirst(9))).lastPathComponent }
    }

    /// Las refs bajo `refs/prbar/` de `local`.
    func prbarRefs() throws -> [String] {
        try Self.run(local, ["for-each-ref", "--format=%(refname)", "refs/prbar/"])
            .split(separator: "\n").map(String.init)
    }
}
