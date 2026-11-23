import Foundation
import PRBarCore

/// Un `ssh` de mentira para los tests: nunca conecta a nada. Anota cada invocación (argumentos separados por 0x1F,
/// invocaciones por 0x1E: los scripts remotos tienen saltos de línea) en `log`; con `-G` imprime una config; con
/// `-O` no hace nada; si no, corre el comando remoto con `/bin/sh -c` en `home`, con un entorno mínimo (`env -i`) y en una sesión nueva (`setsid` desde Perl), y devuelve su exit code.
/// `FAKE_SSH_SHELL` es el shell de login del "host" (`/bin/sh`, `/bin/bash`, `/bin/zsh`: interpreta el comando
/// como lo haría sshd) y `FAKE_SSH_NOISE_FILE` lo que imprime su rc antes del comando.
/// `-V` imprime `FAKE_SSH_VERSION` (por defecto un OpenSSH 9.6) en stderr, como el `ssh` de verdad.
/// `FAKE_SSH_UNREACHABLE=1` simula un host caído (exit 255). Si existe el archivo `dropNext`, la próxima invocación
/// cuyo comando contiene su texto deja el comando corriendo en el "host" y sale con 255 (se cayó la conexión); si además
/// existe `dropNext` + `.lock`, la carpeta que nombra queda de solo lectura en ese momento.
struct FakeSSH {
    let base: URL
    var executable: URL { base.appendingPathComponent("bin/ssh") }
    var home: URL { base.appendingPathComponent("remote-home") }
    var log: URL { base.appendingPathComponent("ssh.log") }
    var controlDirectory: String { base.appendingPathComponent("sock").path }
    var dropNext: URL { base.appendingPathComponent("drop-next") }

    static let script = #"""
    #!/bin/sh
    { for a in "$@"; do printf '%s\037' "$a"; done; printf '\036'; } >> "$FAKE_SSH_LOG"
    mode=run; cmd=""; host=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|-p|-l|-F) shift 2 ;;
        -O) mode=ctl; shift 2 ;;
        -G) mode=config; shift ;;
        -V) echo "${FAKE_SSH_VERSION:-OpenSSH_9.6p1, LibreSSL 3.3.6}" >&2; exit 0 ;;
        -T) shift ;;
        --) shift; host="$1"; shift; cmd="$*"; break ;;
        *) host="$1"; shift; cmd="$*"; break ;;
      esac
    done
    if [ -n "$FAKE_SSH_UNREACHABLE" ]; then echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255; fi
    case "$mode" in
      config) printf 'hostname %s\nstricthostkeychecking %s\n' "$host" "${FAKE_SSH_STRICT:-ask}"; exit 0 ;;
      ctl) exit 0 ;;
    esac
    cd "$FAKE_SSH_HOME" || exit 255
    # Lo que imprime un rc del shell de login (p. ej. `.bashrc`) antes del comando.
    [ -n "$FAKE_SSH_NOISE_FILE" ] && cat "$FAKE_SSH_NOISE_FILE"
    login="${FAKE_SSH_SHELL:-/bin/sh}"
    if [ -n "$FAKE_SSH_DROP" ] && [ -f "$FAKE_SSH_DROP" ] && case "$cmd" in *"$(cat "$FAKE_SSH_DROP")"*) true;; *) false;; esac; then
      # Se cae la conexión: el comando remoto sigue corriendo, el ssh local sale con 255.
      rm -f "$FAKE_SSH_DROP"
      /usr/bin/perl -e 'use POSIX (); my $pid = fork(); die "fork" unless defined $pid;
        if ($pid == 0) { POSIX::setsid(); exec @ARGV or exit 127 } waitpid($pid, 0); exit($? >> 8)' -- \
        /usr/bin/env -i HOME="$FAKE_SSH_HOME" USER=tester LOGNAME=tester LANG=en_US.UTF-8 SHELL=/bin/sh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        SSH_AUTH_SOCK=/remote/agent.sock "$login" -c "$cmd" < /dev/null > /dev/null 2>&1 &
      sleep 1
      # `<drop>.lock`: una carpeta que queda de solo lectura al caerse (p. ej. `jobs/`, para que Stop no se confirme).
      if [ -f "$FAKE_SSH_DROP.lock" ]; then chmod 500 "$(cat "$FAKE_SSH_DROP.lock")"; rm -f "$FAKE_SSH_DROP.lock"; fi
      echo "Connection to $host closed by remote host." >&2
      exit 255
    fi
    exec /usr/bin/perl -e 'use POSIX (); my $pid = fork(); die "fork" unless defined $pid;
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or exit 127 } waitpid($pid, 0); exit($? >> 8)' -- \
      /usr/bin/env -i HOME="$FAKE_SSH_HOME" USER=tester LOGNAME=tester LANG=en_US.UTF-8 SHELL=/bin/sh PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      SSH_AUTH_SOCK=/remote/agent.sock "$login" -c "$cmd"
    """#

    static func make() throws -> FakeSSH {
        // `realpath` y no `resolvingSymlinksInPath`: esa le saca el `/private` a `/private/var/…`, y la raíz que
        // informa el host (`pwd -P`) lo tiene.
        let temporary = try temporaryDirectory()
        guard let resolved = realpath(temporary.path, nil) else { throw TestFailure(description: "realpath \(temporary.path)") }
        defer { free(resolved) }
        let base = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let fake = FakeSSH(base: base)
        try FileManager.default.createDirectory(at: fake.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fake.home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: fake.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.executable.path)
        // Un `sh -l` del "host" encuentra `~/bin` (como un `claude` instalado con npm o el instalador).
        try Data("PATH=\"$HOME/bin:$PATH\"; export PATH\n".utf8).write(to: fake.home.appendingPathComponent(".profile"))
        return fake
    }

    func remove() { try? FileManager.default.removeItem(at: base) }

    /// Entorno del `ssh` local (no global: cada test tiene el suyo).
    func environment(unreachable: Bool = false, strict: String = "ask", shell: String = "/bin/sh", noise: Data? = nil,
                     version: String? = nil) -> [String: String] {
        var env = ["FAKE_SSH_LOG": log.path, "FAKE_SSH_HOME": home.path, "FAKE_SSH_STRICT": strict, "FAKE_SSH_DROP": dropNext.path,
                   "FAKE_SSH_SHELL": shell]
        if let version { env["FAKE_SSH_VERSION"] = version }
        if unreachable { env["FAKE_SSH_UNREACHABLE"] = "1" }
        if let noise {
            let file = base.appendingPathComponent("noise-\(UUID().uuidString)")
            try? noise.write(to: file)
            env["FAKE_SSH_NOISE_FILE"] = file.path
        }
        return env
    }

    /// Un programa en `~/bin` del "host".
    func installTool(_ name: String, _ script: String) throws {
        let url = home.appendingPathComponent("bin/\(name)")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Un `claude` de mentira: `--version` imprime una versión; con `-p`, guarda el prompt (stdin), los argumentos y el
    /// cwd en `~/claude-calls/<n>/`, corre `~/claude-edit-<n>.sh` (si existe) en el cwd e imprime `~/claude-stream-<n>.jsonl`.
    func installFakeClaude(version: String = "2.1.400 (Claude Code)") throws {
        try installTool("claude", """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo '\(version)'; exit 0; fi
        n=$(cat "$HOME/claude-count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$HOME/claude-count"
        d="$HOME/claude-calls/$n"; mkdir -p "$d"
        cat > "$d/prompt.txt"; pwd > "$d/cwd.txt"
        for a in "$@"; do printf '%s\\0' "$a"; done > "$d/args.bin"
        env > "$d/env.txt"
        [ -f "$HOME/claude-edit-$n.sh" ] && /bin/sh "$HOME/claude-edit-$n.sh"
        if [ -f "$HOME/claude-stream-$n.jsonl" ]; then cat "$HOME/claude-stream-$n.jsonl"; else cat "$HOME/claude-stream.jsonl" 2>/dev/null; fi
        """)
    }

    /// Cada invocación del `ssh` local, con sus argumentos.
    func invocations() -> [[String]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\u{1E}").map { line in line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).dropLast().map { $0 } }
    }

    static let installationID = "00000000-0000-4000-8000-0000000000a1"

    func host(name: String = "devbox", remoteDir: String = "~/.prbar", unreachable: Bool = false,
              killGracePeriod: TimeInterval = 1, installationID: String = FakeSSH.installationID, shell: String = "/bin/sh",
              noise: Data? = nil) throws -> SSHHost {
        _ = try ControlSocketDirectory.ensure(controlDirectory)
        return SSHHost(destination: RunnerDestination(name: name, endpoint: SSHEndpoint(host: name), remoteDir: remoteDir),
                       installationID: installationID,
                       sshPath: executable.path, controlDirectory: controlDirectory, enforceHostKey: true,
                       sshEnvironment: environment(unreachable: unreachable, shell: shell, noise: noise), killGracePeriod: killGracePeriod)
    }
}
