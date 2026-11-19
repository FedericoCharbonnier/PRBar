import Foundation

public enum RepoPathValidator {
    /// `true` si algún remote de `git remote -v` apunta a github.com/<owner>/<name> (https o ssh).
    public static func remoteMatches(_ remoteOutput: String, repo: RepoRef) -> Bool {
        let target = repo.fullName.lowercased()
        return remoteOutput.lowercased().split(separator: "\n").contains { line in
            for prefix in ["github.com/", "github.com:"] {
                guard let range = line.range(of: prefix) else { continue }
                var path = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if path.hasSuffix(".git") { path.removeLast(4) }
                if path == target { return true }
            }
            return false
        }
    }

    /// Devuelve `nil` si la carpeta es válida o un mensaje de error para mostrar.
    public static func validate(path: String, repo: RepoRef, runner: ProcessRunning, gitPath: String) async -> String? {
        let result: ProcessResult
        do {
            result = try await runner.run(gitPath, ["-C", path, "remote", "-v"])
        } catch {
            return "Couldn't run git: \(error.localizedDescription)"
        }
        guard result.status == 0 else { return "The folder isn't a git repository." }
        return remoteMatches(result.stdout, repo: repo) ? nil : "No remote points to github.com/\(repo.fullName)."
    }
}
