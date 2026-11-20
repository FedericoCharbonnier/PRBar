import Foundation

/// `--plugin-dir` del host (decisión J.7.20): para cada plugin de los skills elegidos, el subdirectorio modificado
/// más recientemente de `~/.claude/plugins/cache/<marketplace>/<plugin>/` (en cualquier marketplace) que tenga
/// `.claude-plugin`, `skills`, `commands` o `agents` — la misma regla que `ClaudePlugins` en la Mac.
public enum RemotePlugins {
    public static func locate(skills: [String], host: SSHHost) async throws -> [String] {
        var plugins: [(plugin: String, skill: String)] = []
        for skill in skills {
            guard let plugin = ClaudeSettings.plugin(of: skill), !plugins.contains(where: { $0.plugin == plugin }) else { continue }
            // La gramática de §8.0 (`[A-Za-z0-9._-]`, sin empezar con `.`): el nombre arma una ruta en el host.
            guard ClaudeSettings.isValidSkill(skill) else {
                throw RemoteRunnerError.pluginMissing(host: host.name, plugin: plugin, skill: skill)
            }
            plugins.append((plugin, skill))
        }
        guard !plugins.isEmpty else { return [] }
        let names = try plugins.map { try ShellQuote.posix($0.plugin) }.joined(separator: " ")
        let script = """
        for p in \(names); do
          best=""; bestm=0
          for d in "$HOME"/.claude/plugins/cache/*/"$p"/*/; do
            [ -d "$d" ] || continue
            if [ -e "$d.claude-plugin" ] || [ -d "${d}skills" ] || [ -d "${d}commands" ] || [ -d "${d}agents" ]; then
              m=$(/usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin perl -e 'print((lstat($ARGV[0]))[9])' "${d%/}")
              case $m in ''|*[!0-9]*) continue;; esac
              if [ "$m" -gt "$bestm" ]; then best="${d%/}"; bestm=$m; fi
            fi
          done
          printf '%s\\t%s\\n' "$p" "$best"
        done
        """
        let output = try host.checked(try await host.runScript(script, timeout: 30), "plugin lookup").stdout
        var found: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].hasPrefix("/") else { continue }
            found[String(parts[0])] = String(parts[1])
        }
        return try plugins.map { plugin, skill in
            guard let dir = found[plugin] else { throw RemoteRunnerError.pluginMissing(host: host.name, plugin: plugin, skill: skill) }
            return dir
        }
    }
}
