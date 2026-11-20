# PRBar — Plan 14: Dónde corre Claude — esta Mac o un servidor por SSH

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Los trabajos de Claude (review, filtro, análisis de Respond, implementación de fixes y los chats de PR de review, respond y merge) pueden correr en un host propio por SSH en vez de en la Mac: el worktree y `claude -p` viven allá, con el mismo aislamiento, el mismo guardián de integridad y el mismo endurecimiento de git; los fixes vuelven a la Mac como objetos de git verificados y se pushean desde la Mac; GitHub, Slack y todos los tokens nunca salen de la Mac. Cada repo elige el destino (o el global), con fallback opcional a la Mac.

**Spec:** `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`, parte **J** (J.1–J.6, ya integrada al spec en `01b21d9`). La Task 20 agrega **J.7 Decisiones de implementación (Plan 14)**. Se apoya en:
- Spec base **§8** (worktree con refs propias `refs/prbar/*`, `GitHardening`, neutralización de symlinks, carpeta de contexto, aislamiento de §8.3: `--setting-sources ""`, `--settings`, deny rules, `--tools`, `dontAsk`, MCP estricto, `--json-schema`, entorno en lista blanca), **§8.0** (regla de plugins), **§8.5** (limpieza: `worktree remove --force` del worktree propio, nunca `git worktree prune`), **§14** (Respond: worktree separado, guardián de integridad, diff completo antes de pushear, push con el sha explícito y los hooks del usuario).
- B (chat) y **B.11** (Plan 6), E.9 (Plan 9: fences y neutralización del texto del PR), F.8 (Plan 10).
- I (Plan 13): `ProcessActivity.host` ("on <host>" en la ventana Activity) y `WorkspaceRegistry`.
- C (CLI): `AppCommand`, `CommandProtocol.version`, `CLIRouter`, `UIActionInventory`, paridad.

**Orden de ejecución:** 11 → 12 → 13 → **14**. Es el plan más grande y el más sensible en seguridad: cada task cierra con sus tests, y las Tasks 1, 5, 6, 8, 10, 12 y 13 tienen tests de seguridad explícitos (inyección, entorno, confinamiento, guardián, verificación del árbol).

## Qué asume de los planes 11, 12 y 13

| Plan | Artefacto | Cómo lo usa este plan |
|---|---|---|
| 11 | `ChatSession.Kind.merge`, `ChatSubject.merge`, el chat de merge que reusa el worktree del chat de Review (`ChatService`) | El chat de merge corre en el mismo destino que el de Review (Task 14). |
| 11 | `MergeContextWriter` escribiendo `pr.md` del chat de merge en `ChatService.workspace` | Esa escritura pasa por `ContextFiles` (Task 12), como las demás. |
| 12 | `CommandProtocol.version = 4` | Sube a **5** (Task 16). |
| 12 | `AppModelServices.popoverDefaults` | Lo nuevo de `AppModelServices` va después. |
| 13 | `ProcessActivity` (con `host` y `on(host:)`), `ProcessRegistry`, `ResourceMeter` (filas remotas sin CPU/RAM), ventana Activity ("on <host>") | Los pipelines remotos corren con `ProcessActivity.current?.on(host:)` (Task 17). |
| 13 | `SystemProcessRunner(killGracePeriod:registry:)` y el registro de procesos en `execute` | La Task 4 agrega entrada/salida por archivo en el mismo `execute`, sin tocar el registro. |
| 13 | `WorkspaceRegistry`, `DiskScanInput` | Sin cambios: los worktrees remotos no ocupan disco local; los repos locales temporales del push sí, y se anotan (Task 13). |
| 13 | `AppConfig.resources` y `case resources` | `runners` va **después**, con su propia línea `case runners`. |

**Si algo no está:** agregar al final de cada enum/lista/`switch` y seguir. Si el Plan 13 no está, crear `ProcessActivity` con lo mínimo (`kind`, `prID`, `title`, `host`, `@TaskLocal current`, `on(host:)`; ver la Task 1 del Plan 13) y saltear lo de la ventana Activity.

## Archivos compartidos con otros planes

- `Sources/PRBarCore/ProcessRunner.swift`: se agrega un método y dos parámetros a `execute`; `PipeDrainer.drain` acepta stdout opcional.
- `Sources/PRBarCore/ClaudeRunner.swift`: un parámetro nuevo (`promptViaStandardInput`) con default; los argumentos locales no cambian.
- `Sources/PRBarCore/FixImplementer.swift`: el refactor de la Task 11 (todo lo que lee el disco pasa por `WorkspaceFS`); el comportamiento local no cambia (la suite de `FixImplementerTests` es la red).
- `Sources/PRBarCore/ReviewPipeline.swift`, `RespondPipeline.swift`, `ChatService.swift`, `ReviewContext.swift`, `RespondAnalyzer.swift`: parámetros nuevos con default; el camino local queda igual.
- `Sources/PRBarCore/Config.swift`: `RepoConfig.runOn` y `AppConfig.runners` al final, con sus líneas de `CodingKeys`.

## Convenciones

- Build **por producto**: `swift build --product PRBar`, `swift build --product PRBarCLI`, `swift build --product PRBarTests` (un `swift build` pelado falla por el plugin de argument-parser). Sin warnings nuevos.
- Tests: `swift run PRBarTests [filtro]`. Archivos nuevos al **final** de `allTests` en `Sources/PRBarTests/main.swift`. `expect`/`expectEqual` toman autoclosures **sin** `await`: hoistear a una variable local.
- **Nunca** correr la CLI sin `PRBAR_SOCKET` apuntando a un socket de prueba.
- Los tests **nunca** hablan con GitHub, Slack, Claude ni con un host ssh de verdad. Todo lo remoto se prueba con `FakeSSH` (Task 6): un `ssh` de mentira que ejecuta el comando remoto **localmente**, en una carpeta temporal que hace de `$HOME` del host, con `env -i` y en una sesión propia (como `sshd`). El "GitHub" de los tests es el repo `origin` de `TempGitRepo` (una carpeta local). El "claude" remoto es un script de la carpeta temporal.
- Capturas: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y **mirar** con Read; para el repo `Scripts/snapshots.sh docs/screenshots both` y revertir PNG ajenos sin cambios reales.
- Commits en inglés, **sin** `Co-Authored-By` ni atribución a Claude/Anthropic. Sin push. En `main`.
- UI en inglés; comentarios en español (o inglés si el archivo ya lo está).

## Modelo de amenazas (lo que este plan defiende)

1. **El host es de confianza para el usuario pero lo que vuelve de él no** (J.5): stream-json, bundles, diffs y salidas de git se tratan como la salida de Claude local (redacción, guardianes, verificación). Un host comprometido no puede hacer que PRBar pushee algo distinto de lo que el usuario vio: el diff que se muestra se calcula **en la Mac** a partir de los objetos traídos y verificados (decisión 9).
2. **Inyección en la línea de comando remota:** nombres de rama, rutas, prompts y argumentos vienen de PRs ajenos. Nunca se interpola: cada argumento va con comillas simples POSIX (Task 1), con fuzz de valores hostiles corrido de verdad en `sh`, `bash` y `zsh`, y una sonda en cada verificación comprueba que el shell de login del host deja pasar el texto intacto (decisión 1).
3. **Tokens:** ningún token de GitHub ni de Slack se manda al host. El entorno remoto se arma con `env -i` y una lista blanca (Task 5); un token en el entorno de un comando remoto es un error interno que corta antes de lanzar nada.
4. **Borrar fuera de lo propio:** PRBar solo crea y borra dentro de su carpeta remota, y solo si tiene su marca (`.prbar-root`); cada ruta pasa por `RemoteRoot` (Task 5).
5. **El socket de multiplexado** está en una carpeta 0700 propia, verificada sin seguir symlinks (Task 3).
6. **Agent forwarding** apagado siempre: un host comprometido no puede usar las claves del usuario.

## Decisiones donde el spec era ambiguo (van a J.7 en la Task 20)

1. **Comandos remotos:** lo que se manda por ssh es siempre **un** argumento `/bin/sh -c '<script>'`; el script tiene cada argumento con comillas simples POSIX (`'` → `'\''`). El shell de login del host solo tiene que respetar esas comillas: cada verificación manda una cadena hostil y exige recibirla idéntica; si no (fish, csh), el host queda inválido: "devbox’s login shell changed PRBar’s test string — set sh, bash or zsh as the login shell for this user". NUL nunca puede ir en un argumento: se rechaza.
2. **El prompt va por stdin**, subido como archivo (`<raíz>/tmp/<job>.stdin`), con `claude -p` sin el prompt en los argumentos: Linux limita cada argumento a 128 KiB y otros usuarios del host podrían leer los argumentos con `ps`. El resto de los argumentos (`--settings`, `--json-schema`, deny rules) son los de §8.3 tal cual; el script entero tiene un tope de 100 000 bytes.
3. **Opciones de ssh:** `BatchMode=yes`, `ConnectTimeout=10`, `ControlMaster=auto`, `ControlPersist=60s`, `ControlPath=<carpeta>/%C`, `ForwardAgent=no`, `ForwardX11=no`, `ClearAllForwardings=yes`, `PermitLocalCommand=no`, `RequestTTY=no` + `-T`, `ServerAliveInterval=15`, `ServerAliveCountMax=4`, `LogLevel=ERROR`, y `--` antes del host. `StrictHostKeyChecking=yes` **solo** si `ssh -G` dice que la config del usuario lo deja en el default (`ask`); si el usuario configuró otra cosa (`accept-new`, `no`), se respeta (J.5).
4. **Carpeta del socket:** `/private/tmp/prbar-ssh-<uid>`, no Application Support: el `sun_path` de un socket Unix tiene 104 bytes en macOS y `~/Library/Application Support/PRBar/ssh/<40 hex>` + el sufijo temporal de ssh no entra. Se crea 0700; si existe, tiene que ser una carpeta (no un symlink), del usuario y exactamente 0700, o no se usa ningún host ("PRBar’s SSH folder /private/tmp/prbar-ssh-501 isn’t safe: …").
5. **Entorno remoto (`env -i`):** Claude: `PATH` (las carpetas del `claude` y el `git` del host + `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`), `HOME`, `USER`/`LOGNAME`/`LANG`/`LC_ALL` si están, `SHELL=/bin/sh`, `TMPDIR=<raíz>/tmp`. Git: lo mismo (sin `TMPDIR`) más `GIT_TERMINAL_PROMPT=0`, `GIT_LFS_SKIP_SMUDGE=1`, `GIT_SSH_COMMAND=ssh -o BatchMode=yes`, `SSH_AUTH_SOCK` si el host tiene un agent propio (el forwarding está apagado), y la identidad de commit de la Mac (`GIT_AUTHOR_*`/`GIT_COMMITTER_*`, de `git config user.name/email` del clone o global; no es un secreto). El guardián en Perl: `PATH`, `HOME`, `LANG` (sin `PERL5OPT`/`PERL5LIB`). Una variable de `SystemProcessRunner.unheritedVariables` en un comando remoto es un error interno.
6. **Carpeta remota** (por defecto `~/.prbar`): `~/<ruta>` o absoluta con al menos dos componentes, componentes `[A-Za-z0-9._-]`, sin `.`/`..`, nunca dentro de `~/.ssh`, `~/.aws`, `~/.config`, `~/Library` o `~/.gnupg` (Claude las tiene negadas). La primera verificación la crea 0700 con la marca `.prbar-root` y `work/`, `repos/`, `jobs/`, `tmp/`; si ya existe, no está vacía y no tiene la marca, se rechaza ("…already exists and isn’t PRBar’s"). Todo borrado remoto exige la marca, que la ruta esté dentro de la raíz verificada (`pwd -P`) y al menos dos niveles abajo.
7. **Clone remoto:** `<raíz>/repos/<owner>/<name>.git` (bare), `origin` = `https://github.com/<o>/<r>.git` y, si ese fetch falla, `git@github.com:<o>/<r>.git` (queda el que funcionó). Con las credenciales del host. Si ninguno anda: "devbox can't fetch acme/api — set up git access on the server". Los mirrors no se borran nunca (son caché).
8. **Guardián remoto = un script Perl** (Perl con `Digest::SHA` y `Time::HiRes`, que vienen con Perl y que la verificación exige) que se manda **por stdin en cada llamada** (`perl - <sub>`; nada queda instalado en el host para modificar). Recolecta los datos (snapshot con `lstat`, `.git` anidados, descripciones con SHA-256, árboles, módulos, lectura de configs, borrado confinado, neutralización con `O_EXCL|O_NOFOLLOW`); **las decisiones** (qué es un cambio, qué corta) son el mismo código Swift de `FixImplementer`/`WorktreeIntegrity`. Tests de paridad corren el script Perl localmente contra la implementación local sobre el mismo árbol, y la suite de integridad de `FixImplementer` se repite con el guardián Perl.
9. **Los fixes vuelven a la Mac al terminar la implementación** (y después de cada turno de chat que edita), no recién al pushear: `git bundle` en el host (`^<start> HEAD`), se baja, `git bundle verify`/`list-heads` (una sola cabeza = el HEAD remoto informado), `unbundle` y `update-ref refs/prbar/remote-<N>-<run>` en el repo local (el clone del usuario si hay `localPath`; si no, un clone temporal mínimo en `$TMPDIR/PRBar/push/<run>`). El diff, el `--stat`, los commits, los archivos sensibles y las dependencias que ve el usuario se calculan **en la Mac** desde esa ref. Al pushear se verifica: la ref sigue en el sha revisado, su árbol es el guardado, el diff recalculado es idéntico al mostrado, el HEAD remoto sigue siendo ese sha y desciende de `startHeadOid`; recién ahí `push origin <sha>:refs/heads/<rama>` desde la Mac (con `localPath`: el clone del usuario, sus credenciales y sus hooks, como hoy; sin `localPath`: el clone temporal con el token de la cuenta por `GIT_CONFIG_COUNT`/`KEY`/`VALUE` en el entorno, nunca en los argumentos).
10. **Fallback a la Mac** (por destino, prendido por defecto): solo **antes de que arranque Claude** — host inalcanzable, verificación con problemas, o falla de preparación (mirror, fetch, worktree, subir el contexto, plugins). Una vez que Claude arrancó en el host, un error falla el trabajo (no se repite local). Las etapas siguientes de Respond (fixes, chat, tests, push) corren siempre en el host del análisis; si no responde, fallan. La fila y la ventana dicen "Ran on this Mac — devbox unreachable" (o "— devbox couldn’t prepare acme/api"). Respond sin `localPath` solo puede caer a la Mac si hay `localPath`; si no, falla con el error del host.
11. **Verificación:** antes de cada trabajo, cacheada 5 min si salió bien y 60 s si falló. "Test Connection" la fuerza y además prueba el login de Claude (`claude -p` mínimo con `--model haiku`, aislado, por stdin).
12. **Versiones mínimas:** localmente PRBar no exige versiones; el código usa `git rev-parse --path-format=absolute` (git ≥ 2.31), así que el host exige git ≥ 2.31, un `claude` que responda `--version` y Perl con los dos módulos.
13. **Tests de Respond en el host:** `/bin/sh -lc <testCommand>` en el worktree remoto, con el entorno de login del host (como el `zsh -lc` local; es el comando del usuario, que ya vio el diff).
14. **Respond sin `localPath`** se puede usar si el destino del repo es remoto (el worktree sale del mirror del host).
15. **Stop:** se corta el `ssh` local y se manda `kill -TERM -- -<pgid>` y, a los 5 s, `-KILL` al grupo remoto, cuyo pgid el script guardó en `<raíz>/jobs/<job>.pid` antes del `exec`. Lo mismo en un timeout. Si el `ssh` del trabajo ya había terminado no se mata nada (como el `ProcessControl` local con el reuso de PID).
16. **Limpieza:** worktrees, refs y carpetas de contexto remotas se borran al terminar como en local (mecanismo de §8.5 sobre el mirror propio). Al arrancar la app, en segundo plano, para cada destino que responde: `worktree remove --force` de los worktrees de `<raíz>/work`, `update-ref -d` de `refs/prbar/*` en cada mirror y vaciar `work/`, `jobs/` y `tmp/`. Los mirrors quedan.
17. **Sacar un destino** cierra su conexión maestra (`ssh -O exit`), vuelve a "Default" los repos que lo usaban y pone "This Mac" como default si era el default. No borra nada en el host (el QA lo hace a mano).
18. **Un repo que apunta a un destino que ya no existe** se comporta como "Default".
19. **Protocolo 5:** `RepoChanges.runOn` es nuevo y una app vieja lo ignoraría en silencio.
20. **Plugins en el host:** la misma regla de §8.0 sobre `~/.claude/plugins/cache/*/<plugin>/*/` del host; si falta: "devbox doesn’t have the plugin pr-review-toolkit (for pr-review-toolkit:review-pr). Install it there: run `claude` on devbox, then `/plugin install pr-review-toolkit`."

---

## Estructura de archivos

```
Sources/PRBarCore/
  ShellQuote.swift           (nuevo) comillas POSIX
  RunnerSettings.swift       (nuevo) SSHEndpoint, RunnerDestination, RunTarget, RunnerSettings, RunTargetResolver,
                                     RunnerConfigError, mutaciones de AppConfig
  SSHCommand.swift           (nuevo) SSHCommandBuilder, ControlSocketDirectory
  RemoteExec.swift           (nuevo) RemoteExec, RemoteEnv, RemoteEnvironment, RemoteRoot, RemoteRunnerError
  SSHHost.swift              (nuevo) SSHHost (run, upload, download, removeTree, killGroup, closeMaster)
  RunnerProbe.swift          (nuevo) RunnerProbe, RunnerHostInfo, RunnerHealthCache
  RemoteProcessRunner.swift  (nuevo) RemoteProcessRunner, RemoteLoginRunner, StandardInputStreamingRunning
  RemotePlugins.swift        (nuevo) plugins del host
  WorkspaceFS.swift          (nuevo) WorkspaceFS, LocalWorkspaceFS, RemoteWorkspaceFS, RemoteGuard (script Perl)
  RemoteWorkspaces.swift     (nuevo) mirror, workspaces de review/chat, worktrees de Respond, limpieza, ContextFiles
  RemoteFixImport.swift      (nuevo) bundle → Mac, verificación, resumen local, push verificado
  RemotePlacement.swift      (nuevo) RemotePlacement, RemotePreparationFailure, RunnerCoordinator, JobPlacement
  ProcessRunner.swift        (modificar) FileIOProcessRunning (stdin/stdout por archivo)
  ClaudeRunner.swift, ClaudeReviewer.swift (modificar) promptViaStandardInput
  FixImplementer.swift, WorktreeIntegrity.swift, WorktreeManager.swift (modificar) WorkspaceFS
  ReviewContext.swift, RespondAnalyzer.swift (modificar) ContextFiles
  ReviewPipeline.swift, RespondPipeline.swift, ChatService.swift (modificar) placement remoto
  RespondModels.swift        (modificar) RespondDraft.runner, RespondResult.remoteObjects
  RespondPublisher.swift     (modificar) securityDigest(using:)
  Config.swift               (modificar) RepoConfig.runOn, AppConfig.runners
  AppCommand.swift, AppCommandTypes.swift, CommandActions.swift, CommandDispatcher.swift, CommandProtocol.swift,
  CommandResults.swift       (modificar) runners*, RepoChanges.runOn, RunnerInfo, versión 5
Sources/PRBarCLIKit/
  RunnerCommands.swift       (nuevo) prbar runners …
  ConfigCommands.swift (repo set --run-on), CLIRouter.swift, PRBarCLIKit.swift (modificar)
Sources/PRBar/
  AppModel+Runners.swift     (nuevo) coordinador, acciones, limpieza al arrancar, placements
  Settings/RunOnSection.swift (nuevo) Settings › Claude › Run On (+ AddRunnerSheet)
  Settings/ClaudeTab.swift, Settings/ReposTab.swift, Popover/PRRowView.swift, Review/ReviewWindow.swift,
  Respond/RespondWindow.swift, Review/LiveReviewPipeline.swift, Respond/LiveRespondPipeline.swift,
  Chat/LiveChatBackend.swift, AppModel.swift (modificar)
  Snapshots/*                (modificar)
Sources/PRBarTests/
  ShellQuoteTests, RunnerSettingsTests, SSHCommandTests, FileIOProcessTests, RemoteExecTests, FakeSSH (helper),
  SSHHostTests, RunnerProbeTests, RemoteProcessRunnerTests, RemotePluginsTests, WorkspaceFSParityTests,
  RemoteWorkspacesTests, RemoteFixImportTests, RemoteFlowTests, RunnerCoordinatorTests (nuevos);
  FixImplementerTests, CLIParsingTests, CommandDispatcherTests, FakeActions, UIActionInventory, main.swift (modificar)
docs/cli.md, docs/screenshots/README.md, docs/qa/plan-14-checklist.md, spec (J.7)
```

---

### Task 1: Comillas POSIX estrictas (`ShellQuote`) con fuzz en shells reales

**Files:**
- Create: `Sources/PRBarCore/ShellQuote.swift`
- Test: `Sources/PRBarTests/ShellQuoteTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.** `Sources/PRBarTests/ShellQuoteTests.swift`:

```swift
import Foundation
import PRBarCore

enum ShellQuoteTests {
    /// Valores que vienen de PRs ajenos (ramas, rutas, prompts) y que no pueden cambiar ni ejecutar nada.
    static let hostile: [String] = [
        "", " ", "plain", "it's", "'", "''", "\\", "\\'", "'\\''", "$HOME", "${HOME}", "$(touch PWNED)", "`touch PWNED`",
        "; touch PWNED", "&& touch PWNED", "| touch PWNED", "> PWNED", "< /etc/passwd", "*", "?", "[a-z]", "~", "~root",
        "!!", "!$", "#comment", "line1\nline2", "tab\there", "\r\n", "-n", "--", "-e", "%s%n", "é", "日本語", "🙂",
        "a'b\"c\\d$e`f!g*h;i|j&k#l m\tn~o", "'; touch PWNED; '", "\"; touch PWNED; \"", "$'\\x41'", "\\$(touch PWNED)",
        "feature/$(touch PWNED)", "refs/heads/a;b", "x'$(touch PWNED)'y", String(repeating: "x'y", count: 20_000),
    ]

    /// Cadenas pseudoaleatorias (semilla fija) sobre un alfabeto de caracteres especiales del shell.
    static func randomStrings(count: Int, seed: UInt64) -> [String] {
        let alphabet = Array("'\"\\$`!*?;&|<>()[]{}#~ \t\n\r%-=,.:/@^aZ09é🙂")
        var state = seed
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        return (0..<count).map { _ in String((0..<(next() % 40)).map { _ in alphabet[next() % alphabet.count] }) }
    }

    /// `printf '%s\0' <cada valor con comillas>` en `shell`, dentro de `directory`; devuelve lo impreso partido por NUL.
    static func roundTrip(_ values: [String], shell: String, in directory: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "printf '%s\\0' " + (try ShellQuote.command(values))]
        process.currentDirectoryURL = directory
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static let cases: [TestCase] = [
        TestCase("shell quote: forma") {
            try expectEqual(try ShellQuote.posix("a b"), "'a b'")
            try expectEqual(try ShellQuote.posix("it's"), #"'it'\''s'"#)
            try expectEqual(try ShellQuote.posix(""), "''")
            try expectEqual(try ShellQuote.command(["git", "-C", "/w/x y"]), "'git' '-C' '/w/x y'")
            let nul = try await expectThrows { _ = try ShellQuote.posix("a\u{0}b") }
            try expectEqual(nul as? ShellQuote.Failure, .nulByte)
            try expect(ShellQuote.isEnvironmentName("GIT_TERMINAL_PROMPT") && ShellQuote.isEnvironmentName("_X1"))
            try expect(!ShellQuote.isEnvironmentName("1X") && !ShellQuote.isEnvironmentName("A-B") && !ShellQuote.isEnvironmentName("A=B")
                       && !ShellQuote.isEnvironmentName(""))
        },
        TestCase("shell quote: sh, bash y zsh reciben cada valor hostil intacto y no ejecutan nada") {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let values = hostile + randomStrings(count: 400, seed: 42)
            for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
                let back = try roundTrip(values, shell: shell, in: directory)
                try expectEqual(back.count, values.count)
                for (index, value) in values.enumerated() where back[index] != value {
                    throw TestFailure(description: "\(shell) cambió el valor #\(index): \(value.prefix(80).debugDescription) → \(back[index].prefix(80).debugDescription)")
                }
                let pwned = FileManager.default.fileExists(atPath: directory.appendingPathComponent("PWNED").path)
                try expect(!pwned, "\(shell) ejecutó algo")
            }
        },
    ]
}
```

En `main.swift`, al final de `allTests`: `+ ShellQuoteTests.cases`.

- [ ] **Step 2:** `swift build --product PRBarTests 2>&1 | grep error: | head -3` → `cannot find 'ShellQuote'`.

- [ ] **Step 3: `Sources/PRBarCore/ShellQuote.swift`:**

```swift
import Foundation

/// Comillas POSIX estrictas para todo lo que PRBar manda a un host por ssh (spec J.3/J.5). Nunca se interpola texto
/// en un comando: cada argumento va entre comillas simples, y una comilla simple adentro se escribe `'\''`. Dentro de
/// comillas simples POSIX nada es especial (`$`, `` ` ``, `\`, `!`, `*`, saltos de línea), así que el texto llega
/// tal cual. El único byte imposible es NUL (no puede ir en un argumento de `exec`): se rechaza.
public enum ShellQuote {
    public enum Failure: Error, Equatable, LocalizedError {
        case nulByte
        case invalidEnvironmentName(String)
        case invalidExecutable(String)

        public var errorDescription: String? {
            switch self {
            case .nulByte: "Internal error: a remote argument contained a NUL byte."
            case .invalidEnvironmentName(let name): "Internal error: invalid environment variable name \(name.debugDescription)."
            case .invalidExecutable(let path): "Internal error: invalid remote program \(path.debugDescription)."
            }
        }
    }

    public static func posix(_ value: String) throws -> String {
        guard !value.utf8.contains(0) else { throw Failure.nulByte }
        return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public static func command(_ argv: [String]) throws -> String {
        try argv.map(posix).joined(separator: " ")
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`.
    public static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
              first == "_" || CharacterSet.letters.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "shell quote"` → `2/2 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/ShellQuote.swift Sources/PRBarTests/ShellQuoteTests.swift Sources/PRBarTests/main.swift
git commit -m "Quote every remote argument with strict POSIX single quotes"
```

---

### Task 2: Configuración — destinos SSH y "Run Claude on" por repo

**Files:**
- Create: `Sources/PRBarCore/RunnerSettings.swift`
- Modify: `Sources/PRBarCore/Config.swift`
- Test: `Sources/PRBarTests/RunnerSettingsTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

enum RunnerSettingsTests {
    static let cases: [TestCase] = [
        TestCase("runners: endpoints válidos") {
            try expectEqual(try SSHEndpoint.parse("devbox"), SSHEndpoint(host: "devbox"))
            try expectEqual(try SSHEndpoint.parse("fede@devbox.local:2222"), SSHEndpoint(user: "fede", host: "devbox.local", port: 2222))
            try expectEqual(try SSHEndpoint.parse("root@[fe80::1]:22"), SSHEndpoint(user: "root", host: "fe80::1", port: 22))
            try expectEqual(try SSHEndpoint.parse("root@[fe80::1]:22").display, "root@[fe80::1]:22")
        },
        TestCase("runners: endpoints hostiles o inválidos se rechazan") {
            for text in ["", "-oProxyCommand=touch x", "a b", "host;rm", "$(x)", "`x`", "h:0", "h:70000", "h:p", "@h", "u@", "u@-h",
                         "a'b", "h\nx", "[::1", "[zz]", "user@host@x", "h:1:2", "-h", "h/x"] {
                let parsed = try? SSHEndpoint.parse(text)
                try expect(parsed == nil, "aceptó \(text.debugDescription)")
            }
        },
        TestCase("runners: nombres y carpetas remotas") {
            try expect(RunnerDestination.isValidName("devbox") && RunnerDestination.isValidName("gpu-1.lab"))
            for bad in ["", "local", "Default", "-x", "a b", "a/b", String(repeating: "x", count: 41)] {
                try expect(!RunnerDestination.isValidName(bad), "aceptó \(bad)")
            }
            for good in ["~/.prbar", "~/work/prbar", "/srv/prbar", "/home/fede/.prbar"] {
                try expect(RunnerDestination.isValidRemoteDir(good), "rechazó \(good)")
            }
            for bad in ["", "~", "~/", "/", "/srv", "relative", "~/../x", "~/a/./b", "/a//b", "~/a b", "~/$(x)", "~/.ssh/x",
                        "~/.config/prbar", "~/Library/PRBar", "~/.aws", "~/.gnupg/x", "/srv/prbar/"] {
                try expect(!RunnerDestination.isValidRemoteDir(bad), "aceptó \(bad)")
            }
            let destination = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))
            try expectEqual(try destination.remoteDirExpression(), #""$HOME"/'.prbar'"#)
        },
        TestCase("runners: el destino se resuelve repo → global → This Mac; uno borrado cuenta como Default") {
            var settings = RunnerSettings()
            let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))
            let gpu = RunnerDestination(name: "gpu", endpoint: SSHEndpoint(host: "gpu"))
            settings.destinations = [devbox, gpu]
            var repo = RepoConfig(owner: "acme", name: "api")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
            settings.defaultTarget = .runner("devbox")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), devbox)
            repo.runOn = .runner("gpu")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), gpu)
            repo.runOn = .local
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
            repo.runOn = .runner("gone")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), devbox)
            settings.defaultTarget = .runner("gone")
            try expectEqual(RunTargetResolver.destination(for: repo, settings: settings), nil)
        },
        TestCase("runners: config va y vuelve; sacar un destino limpia repos y default") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me")]
            config.addRepo(RepoRef(owner: "acme", name: "api"), to: "me")
            try config.addRunner(RunnerDestination(name: "devbox", endpoint: try SSHEndpoint.parse("fede@devbox:2222"), remoteDir: "/srv/prbar"))
            let duplicate = try await expectThrows { try config.addRunner(RunnerDestination(name: "DEVBOX", endpoint: SSHEndpoint(host: "x"))) }
            try expectEqual(duplicate as? RunnerConfigError, .duplicate("DEVBOX"))
            try config.setDefaultRunTarget(.runner("devbox"))
            config.setRunOn(.runner("devbox"), repoID: "acme/api", login: "me")
            let back = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
            try expectEqual(back.runners, config.runners)
            try expectEqual(back.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "api"))?.runOn, .runner("devbox"))
            let json = String(decoding: try JSONEncoder().encode(config.runners.defaultTarget), as: UTF8.self)
            try expectEqual(json, #""devbox""#)
            try config.removeRunner(named: "devbox")
            try expectEqual(config.runners.destinations, [])
            try expectEqual(config.runners.defaultTarget, .local)
            try expectEqual(config.repoConfig(account: "me", repo: RepoRef(owner: "acme", name: "api"))?.runOn, nil)
            let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes":5}"#.utf8))
            try expectEqual(old.runners, RunnerSettings())
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'SSHEndpoint'`.

- [ ] **Step 3: `Sources/PRBarCore/RunnerSettings.swift`:**

```swift
import Foundation

/// `host`, `user@host`, `user@host:port` o `user@[ipv6]:port` (spec J.1). El host puede ser un `Host` de
/// `~/.ssh/config`. Solo letras, números, `.`, `_` y `-` (nunca empieza con `-`: ssh lo leería como una opción).
public struct SSHEndpoint: Codable, Hashable, Sendable {
    public var user: String?
    public var host: String
    public var port: Int?

    public init(user: String? = nil, host: String, port: Int? = nil) {
        self.user = user
        self.host = host
        self.port = port
    }

    public struct ParseError: Error, Equatable, LocalizedError {
        public let text: String
        public var errorDescription: String? {
            "“\(text)” isn’t an SSH host. Use a Host from ~/.ssh/config or user@host[:port]."
        }
    }

    public static func parse(_ text: String) throws -> SSHEndpoint {
        let raw = text.trimmingCharacters(in: .whitespaces)
        let fail = ParseError(text: text)
        guard !raw.isEmpty, raw.count <= 255, !raw.hasPrefix("-"),
              raw.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else { throw fail }
        var rest = Substring(raw)
        var user: String?
        if let at = rest.firstIndex(of: "@") {
            let name = String(rest[..<at])
            guard isName(name) else { throw fail }
            user = name
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        let host: String
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw fail }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { throw fail }
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = Int(after.dropFirst()), (1...65_535).contains(value) else { throw fail }
                port = value
            }
        } else {
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, isName(String(parts[0])) else { throw fail }
            host = String(parts[0])
            if parts.count == 2 {
                guard let value = Int(parts[1]), (1...65_535).contains(value) else { throw fail }
                port = value
            }
        }
        return SSHEndpoint(user: user, host: host, port: port)
    }

    /// Letras, números, `.`, `_` y `-`, sin empezar con `-`.
    static func isName(_ text: String) -> Bool {
        guard let first = text.first, first != "-" else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    public var display: String {
        (user.map { "\($0)@" } ?? "") + (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "")
    }
}

/// Un host donde puede correr Claude (Settings › Claude › Run On).
public struct RunnerDestination: Codable, Hashable, Sendable, Identifiable {
    public static let defaultRemoteDir = "~/.prbar"
    /// Carpetas que Claude tiene negadas (`ClaudeRunner.deniedPaths`): la carpeta remota no puede estar adentro.
    static let deniedHomeFolders = [".ssh", ".aws", ".config", "Library", ".gnupg"]

    public var name: String
    public var endpoint: SSHEndpoint
    public var remoteDir: String
    public var fallbackToLocal: Bool

    public var id: String { name }

    public init(name: String, endpoint: SSHEndpoint, remoteDir: String = defaultRemoteDir, fallbackToLocal: Bool = true) {
        self.name = name
        self.endpoint = endpoint
        self.remoteDir = remoteDir
        self.fallbackToLocal = fallbackToLocal
    }

    public static func isValidName(_ name: String) -> Bool {
        name.count <= 40 && SSHEndpoint.isName(name) && !["local", "default"].contains(name.lowercased())
    }

    /// `~/<ruta>` o `/<a>/<b>…`; componentes `[A-Za-z0-9._-]`, sin `.` ni `..`; nunca dentro de una carpeta negada.
    public static func isValidRemoteDir(_ dir: String) -> Bool {
        guard dir.count <= 200 else { return false }
        let components: [Substring]
        if dir.hasPrefix("~/") {
            components = dir.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
            guard let first = components.first, !deniedHomeFolders.contains(String(first)) else { return false }
        } else if dir.hasPrefix("/") {
            components = dir.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard components.count >= 2 else { return false }
        } else {
            return false
        }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
                && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
        }
    }

    /// La carpeta como expresión de shell: `"$HOME"/'.prbar'` o `'/srv/prbar'`.
    public func remoteDirExpression() throws -> String {
        guard Self.isValidRemoteDir(remoteDir) else { throw RunnerConfigError.invalidRemoteDir(remoteDir) }
        if remoteDir.hasPrefix("~/") { return #""$HOME"/"# + (try ShellQuote.posix(String(remoteDir.dropFirst(2)))) }
        return try ShellQuote.posix(remoteDir)
    }
}

/// Dónde corre Claude: esta Mac o un destino por nombre. En JSON y en la CLI es `local` o el nombre.
public enum RunTarget: Hashable, Sendable, Codable {
    case local
    case runner(String)

    public init?(cliValue: String) {
        if cliValue == "local" {
            self = .local
        } else if RunnerDestination.isValidName(cliValue) {
            self = .runner(cliValue)
        } else {
            return nil
        }
    }

    public var cliValue: String {
        switch self {
        case .local: "local"
        case .runner(let name): name
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let target = RunTarget(cliValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid run target \(text)"))
        }
        self = target
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cliValue)
    }
}

public struct RunnerSettings: Codable, Hashable, Sendable {
    public var destinations: [RunnerDestination] = []
    public var defaultTarget: RunTarget = .local

    public init() {}

    enum CodingKeys: String, CodingKey { case destinations, defaultTarget }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destinations = (try? c.decodeIfPresent([RunnerDestination].self, forKey: .destinations)) ?? []
        defaultTarget = (try? c.decodeIfPresent(RunTarget.self, forKey: .defaultTarget)) ?? .local
    }

    public func destination(named name: String) -> RunnerDestination? {
        destinations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public enum RunTargetResolver {
    /// Repo → global → This Mac (spec J.1). `nil` = esta Mac. Un nombre que ya no existe cuenta como "Default"; un
    /// default que ya no existe, como This Mac.
    public static func destination(for repo: RepoConfig?, settings: RunnerSettings) -> RunnerDestination? {
        switch repo?.runOn {
        case .local?: return nil
        case .runner(let name)?: if let found = settings.destination(named: name) { return found }
        case nil: break
        }
        if case .runner(let name) = settings.defaultTarget { return settings.destination(named: name) }
        return nil
    }
}

public enum RunnerConfigError: Error, Equatable, LocalizedError {
    case duplicate(String)
    case notFound(String)
    case invalidName(String)
    case invalidRemoteDir(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let name): "There’s already a runner named \(name)."
        case .notFound(let name): "There’s no runner named \(name). Run `prbar runners list`."
        case .invalidName(let name): "“\(name)” can’t be a runner name: use letters, numbers, . _ and - (not “local” or “default”)."
        case .invalidRemoteDir(let dir): "“\(dir)” can’t be the remote folder: use ~/<folder> or an absolute path with at least two parts, outside ~/.ssh, ~/.aws, ~/.config, ~/Library and ~/.gnupg."
        }
    }
}

extension AppConfig {
    public mutating func addRunner(_ destination: RunnerDestination) throws {
        guard RunnerDestination.isValidName(destination.name) else { throw RunnerConfigError.invalidName(destination.name) }
        guard RunnerDestination.isValidRemoteDir(destination.remoteDir) else { throw RunnerConfigError.invalidRemoteDir(destination.remoteDir) }
        guard runners.destination(named: destination.name) == nil else { throw RunnerConfigError.duplicate(destination.name) }
        runners.destinations.append(destination)
    }

    public mutating func updateRunner(named name: String, _ mutate: (inout RunnerDestination) -> Void) throws {
        guard let index = runners.destinations.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw RunnerConfigError.notFound(name)
        }
        var copy = runners.destinations[index]
        mutate(&copy)
        guard RunnerDestination.isValidRemoteDir(copy.remoteDir) else { throw RunnerConfigError.invalidRemoteDir(copy.remoteDir) }
        copy.name = runners.destinations[index].name
        runners.destinations[index] = copy
    }

    /// Saca el destino; los repos que lo usaban vuelven a "Default" y, si era el default, el default es This Mac.
    public mutating func removeRunner(named name: String) throws {
        guard let found = runners.destination(named: name) else { throw RunnerConfigError.notFound(name) }
        runners.destinations.removeAll { $0.name == found.name }
        if runners.defaultTarget == .runner(found.name) { runners.defaultTarget = .local }
        for a in accounts.indices {
            for r in accounts[a].repos.indices where accounts[a].repos[r].runOn == .runner(found.name) {
                accounts[a].repos[r].runOn = nil
            }
        }
    }

    public mutating func setDefaultRunTarget(_ target: RunTarget) throws {
        if case .runner(let name) = target {
            guard let found = runners.destination(named: name) else { throw RunnerConfigError.notFound(name) }
            runners.defaultTarget = .runner(found.name)
        } else {
            runners.defaultTarget = .local
        }
    }

    /// `nil` = "Default".
    public mutating func setRunOn(_ target: RunTarget?, repoID: String, login: String) {
        for a in accounts.indices where accounts[a].login.caseInsensitiveCompare(login) == .orderedSame {
            for r in accounts[a].repos.indices where accounts[a].repos[r].id.caseInsensitiveCompare(repoID) == .orderedSame {
                accounts[a].repos[r].runOn = target
            }
        }
    }
}
```

`Config.swift`:
- `RepoConfig`: propiedad al final `/// Dónde corre Claude para este repo (spec J.1); nil = "Default". public var runOn: RunTarget?`; parámetro `runOn: RunTarget? = nil` al final del `init`; `CodingKeys`: línea nueva `case runOn`; `init(from:)`: `runOn = try? c.decodeIfPresent(RunTarget.self, forKey: .runOn)`. Si `RepoConfig` tiene `encode(to:)` propio, agregar `try c.encodeIfPresent(runOn, forKey: .runOn)`.
- `AppConfig`: `public var runners = RunnerSettings()` al final; `case runners` en una línea propia de `CodingKeys`; `runners = (try? c.decodeIfPresent(RunnerSettings.self, forKey: .runners)) ?? RunnerSettings()`.

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests runners` → `5/5 passed`; `swift run PRBarTests config` sigue verde.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/RunnerSettings.swift Sources/PRBarCore/Config.swift Sources/PRBarTests/RunnerSettingsTests.swift Sources/PRBarTests/main.swift
git commit -m "Add SSH runner destinations and a per-repo Run Claude on setting"
```

---

### Task 3: Argumentos de `ssh` y carpeta del socket de multiplexado

**Files:**
- Create: `Sources/PRBarCore/SSHCommand.swift`
- Test: `Sources/PRBarTests/SSHCommandTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

enum SSHCommandTests {
    static let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(user: "fede", host: "devbox", port: 2222))

    static let cases: [TestCase] = [
        TestCase("ssh: opciones fijas, -- antes del host y el comando como un solo argumento") {
            let args = SSHCommandBuilder.arguments(devbox, controlDirectory: "/private/tmp/prbar-ssh-501", enforceHostKey: true,
                                                   remoteCommand: "/bin/sh -c 'echo hi'")
            func option(_ name: String) -> String? {
                stride(from: 0, to: args.count - 1, by: 1).first { args[$0] == "-o" && args[$0 + 1].hasPrefix(name + "=") }
                    .map { String(args[$0 + 1].dropFirst(name.count + 1)) }
            }
            try expectEqual(option("BatchMode"), "yes")
            try expectEqual(option("ConnectTimeout"), "10")
            try expectEqual(option("ControlMaster"), "auto")
            try expectEqual(option("ControlPersist"), "60s")
            try expectEqual(option("ControlPath"), "/private/tmp/prbar-ssh-501/%C")
            try expectEqual(option("ForwardAgent"), "no")
            try expectEqual(option("ClearAllForwardings"), "yes")
            try expectEqual(option("PermitLocalCommand"), "no")
            try expectEqual(option("StrictHostKeyChecking"), "yes")
            try expectEqual(Array(args.suffix(3)), ["--", "devbox", "/bin/sh -c 'echo hi'"])
            try expect(args.firstIndex(of: "-p")! < args.firstIndex(of: "--")!)
            let relaxed = SSHCommandBuilder.arguments(devbox, controlDirectory: "/x", enforceHostKey: false, remoteCommand: "true")
            try expect(!relaxed.contains("StrictHostKeyChecking=yes"))
        },
        TestCase("ssh: StrictHostKeyChecking solo se fuerza con el default de la config (ask)") {
            try expect(SSHCommandBuilder.enforcesHostKey(fromConfig: "hostname devbox\nstricthostkeychecking ask\n"))
            try expect(!SSHCommandBuilder.enforcesHostKey(fromConfig: "stricthostkeychecking accept-new\n"))
            try expect(!SSHCommandBuilder.enforcesHostKey(fromConfig: "stricthostkeychecking false\n"))
            try expect(!SSHCommandBuilder.enforcesHostKey(fromConfig: "stricthostkeychecking true\n"))
            try expect(SSHCommandBuilder.enforcesHostKey(fromConfig: "hostname devbox\n"))
            try expectEqual(SSHCommandBuilder.configArguments(devbox), ["-G", "-p", "2222", "-l", "fede", "--", "devbox"])
            try expectEqual(SSHCommandBuilder.exitArguments(devbox, controlDirectory: "/x"),
                            ["-o", "ControlPath=/x/%C", "-O", "exit", "-p", "2222", "-l", "fede", "--", "devbox"])
        },
        TestCase("ssh: la carpeta del socket se crea 0700 y se rechaza si es un symlink o tiene otros permisos") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let fresh = base.appendingPathComponent("sock").path
            try expectEqual(try ControlSocketDirectory.ensure(fresh), fresh)
            let mode = (try FileManager.default.attributesOfItem(atPath: fresh)[.posixPermissions] as? Int) ?? 0
            try expectEqual(mode, 0o700)
            let loose = base.appendingPathComponent("loose").path
            try FileManager.default.createDirectory(atPath: loose, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            let looseError = try await expectThrows { _ = try ControlSocketDirectory.ensure(loose) }
            try expect("\(looseError.localizedDescription)".contains("755"), looseError.localizedDescription)
            let link = base.appendingPathComponent("link").path
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fresh)
            _ = try await expectThrows { _ = try ControlSocketDirectory.ensure(link) }
            try expect(ControlSocketDirectory.defaultPath.hasPrefix("/private/tmp/prbar-ssh-"))
            try expect(ControlSocketDirectory.defaultPath.utf8.count + 1 + 40 + 17 < 104)
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'SSHCommandBuilder'`.

- [ ] **Step 3: `Sources/PRBarCore/SSHCommand.swift`:**

```swift
import Foundation

/// Los argumentos del `ssh` del sistema (spec J.1, J.5). Nunca hay contraseñas (`BatchMode`), nunca se reenvía el
/// agent ni X11, nunca corre un `LocalCommand`, y el host va después de `--` (no se puede leer como opción).
public enum SSHCommandBuilder {
    public static let fixedOptions = [
        "BatchMode=yes", "ConnectTimeout=10", "ControlMaster=auto", "ControlPersist=60s", "ForwardAgent=no", "ForwardX11=no",
        "ClearAllForwardings=yes", "PermitLocalCommand=no", "RequestTTY=no", "ServerAliveInterval=15", "ServerAliveCountMax=4",
        "LogLevel=ERROR",
    ]

    private static func target(_ destination: RunnerDestination) -> [String] {
        var args: [String] = []
        if let port = destination.endpoint.port { args += ["-p", String(port)] }
        if let user = destination.endpoint.user { args += ["-l", user] }
        return args
    }

    /// `remoteCommand` es **un** argumento (`/bin/sh -c '<script>'`): ssh lo manda tal cual al shell de login.
    public static func arguments(_ destination: RunnerDestination, controlDirectory: String, enforceHostKey: Bool,
                                 remoteCommand: String) -> [String] {
        var args: [String] = []
        for option in fixedOptions { args += ["-o", option] }
        args += ["-o", "ControlPath=\(controlDirectory)/%C"]
        if enforceHostKey { args += ["-o", "StrictHostKeyChecking=yes"] }
        args += target(destination)
        args += ["-T", "--", destination.endpoint.host, remoteCommand]
        return args
    }

    /// `ssh -G`: la config efectiva del usuario para ese host (no conecta).
    public static func configArguments(_ destination: RunnerDestination) -> [String] {
        ["-G"] + target(destination) + ["--", destination.endpoint.host]
    }

    /// Cierra la conexión maestra (al sacar un destino).
    public static func exitArguments(_ destination: RunnerDestination, controlDirectory: String) -> [String] {
        ["-o", "ControlPath=\(controlDirectory)/%C", "-O", "exit"] + target(destination) + ["--", destination.endpoint.host]
    }

    /// `true` si la config deja `StrictHostKeyChecking` en el default (`ask`, o no lo dice): PRBar fuerza `yes`.
    /// Si el usuario eligió otra cosa (`accept-new`, `no`, `yes`), se respeta (spec J.5).
    public static func enforcesHostKey(fromConfig output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "stricthostkeychecking" {
                return parts[1].trimmingCharacters(in: .whitespaces).lowercased() == "ask"
            }
        }
        return true
    }
}

/// La carpeta de los sockets de `ControlMaster` (decisión J.7.4): 0700, del usuario y nunca un symlink.
public enum ControlSocketDirectory {
    public static var defaultPath: String { "/private/tmp/prbar-ssh-\(getuid())" }

    public static func ensure(_ path: String = defaultPath) throws -> String {
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw RemoteRunnerError.unsafeControlDirectory(path, String(cString: strerror(errno)))
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw RemoteRunnerError.unsafeControlDirectory(path, String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw RemoteRunnerError.unsafeControlDirectory(path, "it isn’t a folder (a symlink?)")
        }
        guard info.st_uid == getuid() else {
            throw RemoteRunnerError.unsafeControlDirectory(path, "it belongs to another user")
        }
        let mode = info.st_mode & 0o777
        guard mode == 0o700 else {
            throw RemoteRunnerError.unsafeControlDirectory(path, "its permissions are \(String(mode, radix: 8)), not 700")
        }
        return path
    }
}
```

`RemoteRunnerError` se define en la Task 5; para compilar ya, crear `Sources/PRBarCore/RemoteExec.swift` con **solo** este tipo (la Task 5 agrega el resto del archivo):

```swift
import Foundation

public enum RemoteRunnerError: Error, Equatable, LocalizedError {
    case unsafeControlDirectory(String, String)
    case unreachable(host: String, detail: String)
    case commandFailed(host: String, command: String, status: Int32, stderr: String)
    case outsideRoot(String)
    case commandTooLong(host: String)
    case secretInEnvironment(String)
    case hostProblems(host: String, problems: [String])
    case cannotFetch(host: String, repo: String)
    case pluginMissing(host: String, plugin: String, skill: String)
    case guardFailed(host: String, detail: String)
    case malformedOutput(host: String, what: String)
    case importMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeControlDirectory(let path, let reason): "PRBar’s SSH folder \(path) isn’t safe: \(reason). Delete it and try again."
        case .unreachable(let host, let detail): "\(host) is unreachable\(detail.isEmpty ? "" : ": \(detail)")"
        case .commandFailed(let host, let command, let status, let stderr):
            "`\(command)` failed on \(host) (exit \(status))\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .outsideRoot(let path): "Internal error: \(path) is outside PRBar’s remote folder."
        case .commandTooLong(let host): "Internal error: the command for \(host) is too long."
        case .secretInEnvironment(let name): "Internal error: \(name) can’t be sent to a remote host."
        case .hostProblems(let host, let problems): "\(host) can’t run Claude for PRBar: " + problems.joined(separator: " ")
        case .cannotFetch(let host, let repo): "\(host) can't fetch \(repo) — set up git access on the server."
        case .pluginMissing(let host, let plugin, let skill):
            "\(host) doesn’t have the plugin \(plugin) (for \(skill)). Install it there: run `claude` on \(host), then `/plugin install \(plugin)`."
        case .guardFailed(let host, let detail): "PRBar’s integrity check failed on \(host): \(detail)"
        case .malformedOutput(let host, let what): "\(host) returned an unexpected \(what)."
        case .importMismatch(let detail): "The commits from the server don’t match what you reviewed: \(detail) Nothing was pushed."
        }
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "ssh:"` → `3/3 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/SSHCommand.swift Sources/PRBarCore/RemoteExec.swift Sources/PRBarTests/SSHCommandTests.swift Sources/PRBarTests/main.swift
git commit -m "Build ssh arguments and a private control socket folder"
```

---

### Task 4: Entrada y salida por archivo en `SystemProcessRunner`

Hace falta para subir datos (`cat > archivo` con stdin) y bajar binarios (bundles) sin pasar por `String`.

**Files:**
- Modify: `Sources/PRBarCore/ProcessRunner.swift`
- Test: `Sources/PRBarTests/FileIOProcessTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

enum FileIOProcessTests {
    static let cases: [TestCase] = [
        TestCase("file io: stdin desde un archivo") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.txt")
            try Data("hola\nchau's $HOME\n".utf8).write(to: input)
            let result = try await SystemProcessRunner().runWithFiles("/bin/cat", [], environment: nil, currentDirectory: nil,
                                                                      timeout: 10, standardInput: input, standardOutput: nil, onStdoutLine: nil)
            try expectEqual(result.stdout, "hola\nchau's $HOME\n")
        },
        TestCase("file io: stdout binario a un archivo 0600, sin pasar por String") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let input = dir.appendingPathComponent("in.bin")
            let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            try bytes.write(to: input)
            let output = dir.appendingPathComponent("out.bin")
            let result = try await SystemProcessRunner().runWithFiles("/bin/cat", [], environment: nil, currentDirectory: nil, timeout: 10,
                                                                      standardInput: input, standardOutput: output, onStdoutLine: nil)
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout, "")
            try expectEqual(try Data(contentsOf: output), bytes)
            let mode = (try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int) ?? 0
            try expectEqual(mode, 0o600)
        },
        TestCase("file io: el timeout sigue cortando") {
            let start = Date()
            let error = try await expectThrows {
                _ = try await SystemProcessRunner(killGracePeriod: 0.2).runWithFiles("/bin/sleep", ["5"], environment: nil, currentDirectory: nil,
                                                                                    timeout: 0.3, standardInput: nil, standardOutput: nil, onStdoutLine: nil)
            }
            try expect(error as? PRBarError == .timedOut(command: "sleep 5"), "\(error)")
            try expect(Date().timeIntervalSince(start) < 3)
        },
    ]
}
```

- [ ] **Step 2:** build → `value of type 'SystemProcessRunner' has no member 'runWithFiles'`.

- [ ] **Step 3: Implementación** en `ProcessRunner.swift`:
  - Protocolo nuevo (después de `StreamingProcessRunning`):

```swift
/// stdin desde un archivo y/o stdout a un archivo (binario). Con `standardOutput`, `ProcessResult.stdout` queda vacío
/// y `onStdoutLine` tiene que ser nil.
public protocol FileIOProcessRunning: Sendable {
    func runWithFiles(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                      timeout: TimeInterval?, standardInput: URL?, standardOutput: URL?,
                      onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ProcessResult
}
```
  - `SystemProcessRunner` lo adopta (`: ProcessRunning, StreamingProcessRunning, FileIOProcessRunning`):

```swift
    public func runWithFiles(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                             timeout: TimeInterval?, standardInput: URL?, standardOutput: URL?,
                             onStdoutLine: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
        precondition(standardOutput == nil || onStdoutLine == nil, "stdout goes to a file or to lines, not both")
        return try await execute(executable, arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout,
                                 onStdoutLine: onStdoutLine, standardInput: standardInput, standardOutput: standardOutput)
    }
```
  - `execute` gana `standardInput: URL? = nil, standardOutput: URL? = nil` al final. Reemplazar el armado de pipes por:

```swift
        let out: Pipe? = standardOutput == nil ? Pipe() : nil
        let err = Pipe()
        var outputHandle: FileHandle?
        if let standardOutput {
            guard FileManager.default.createFile(atPath: standardOutput.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: standardOutput.path])
            }
            outputHandle = try FileHandle(forWritingTo: standardOutput)
            process.standardOutput = outputHandle
        } else {
            process.standardOutput = out
        }
        process.standardError = err
        let inputHandle = try standardInput.map { try FileHandle(forReadingFrom: $0) }
        process.standardInput = inputHandle ?? FileHandle.nullDevice
```
    y en el bloque de lectura: `PipeDrainer.drain(out?.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor, …)`; después de `control.waitUntilExited()`: `try? inputHandle?.close(); try? outputHandle?.close()`; `withExtendedLifetime((out, err)) {}` queda igual.
  - `PipeDrainer.drain(_ outFD: Int32?, _ errFD: Int32, …)`:

```swift
    static func drain(_ outFD: Int32?, _ errFD: Int32, hasExited: () -> Bool, onStdout: ((ArraySlice<UInt8>) -> Void)? = nil) -> (Data, Data) {
        var buffers: [Int32: Data] = [errFD: Data()]
        var open: Set<Int32> = [errFD]
        if let outFD {
            buffers[outFD] = Data()
            open.insert(outFD)
        }
        // … (el resto igual; `if fd == outFD` compara con el opcional) …
        return (outFD.flatMap { buffers[$0] } ?? Data(), buffers[errFD] ?? Data())
    }
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "file io" && swift run PRBarTests process` → todo `passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/ProcessRunner.swift Sources/PRBarTests/FileIOProcessTests.swift Sources/PRBarTests/main.swift
git commit -m "Let processes read stdin from a file and write binary stdout to a file"
```

---

### Task 5: Script remoto con `env -i`, lista blanca y raíz confinada (`RemoteExec`, `RemoteRoot`)

**Files:**
- Modify: `Sources/PRBarCore/RemoteExec.swift`
- Test: `Sources/PRBarTests/RemoteExecTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.** Los scripts se corren **localmente** con `/bin/sh -c`, con un entorno de mentira lleno de cosas que nunca tienen que pasar:

```swift
import Foundation
import PRBarCore

/// Corre `script` con `/bin/sh -c` y exactamente `environment`; devuelve stdout.
func runLocalScript(_ script: String, environment: [String: String], stdin: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    if let stdin { process.standardInput = try FileHandle(forReadingFrom: stdin) }
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private let dirty: [String: String] = [
    "PATH": "/usr/bin:/bin", "HOME": "/remote/home", "USER": "fede", "LANG": "en_US.UTF-8",
    "GH_TOKEN": "ghp_secret", "GITHUB_TOKEN": "ghp_secret2", "SLACK_TOKEN": "xoxp-1", "SSH_AUTH_SOCK": "/tmp/agent",
    "PERL5OPT": "-Mevil", "DYLD_INSERT_LIBRARIES": "/x.dylib", "NODE_OPTIONS": "--require evil", "AWS_SECRET_ACCESS_KEY": "k",
]

enum RemoteExecTests {
    static let cases: [TestCase] = [
        TestCase("remote exec: Claude recibe solo la lista blanca") {
            let root = try RemoteRoot(verified: "/remote/home/.prbar")
            let exec = RemoteExec(argv: ["/usr/bin/env"], environment: RemoteEnvironment.claude(pathDirectories: ["/opt/claude/bin"], root: root))
            let lines = Set(try runLocalScript(try exec.script(), environment: dirty).split(separator: "\n").map(String.init))
            try expectEqual(lines, [
                "PATH=/opt/claude/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/remote/home", "USER=fede",
                "LANG=en_US.UTF-8", "SHELL=/bin/sh", "TMPDIR=/remote/home/.prbar/tmp",
            ])
        },
        TestCase("remote exec: git pasa solo sus variables y el agent del host; un token es un error interno") {
            let root = try RemoteRoot(verified: "/remote/home/.prbar")
            let env = try RemoteEnvironment.git(passing: ["GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Fede", "NODE_OPTIONS": "x"],
                                                pathDirectories: ["/usr/bin"], root: root)
            let lines = Set(try runLocalScript(try RemoteExec(argv: ["/usr/bin/env"], environment: env).script(), environment: dirty)
                .split(separator: "\n").map(String.init))
            try expect(lines.contains("GIT_TERMINAL_PROMPT=0") && lines.contains("GIT_AUTHOR_NAME=Fede"))
            try expect(lines.contains("SSH_AUTH_SOCK=/tmp/agent") && lines.contains("GIT_LFS_SKIP_SMUDGE=1"))
            try expect(!lines.contains { $0.hasPrefix("GH_TOKEN") || $0.hasPrefix("NODE_OPTIONS") || $0.hasPrefix("PERL5OPT") || $0.hasPrefix("AWS_") })
            let leak = try await expectThrows {
                _ = try RemoteEnvironment.git(passing: ["GH_TOKEN": "x"], pathDirectories: [], root: root)
            }
            try expectEqual(leak as? RemoteRunnerError, .secretInEnvironment("GH_TOKEN"))
        },
        TestCase("remote exec: argumentos y cwd hostiles llegan intactos; nada se ejecuta") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let cwd = base.appendingPathComponent("it's a $(touch PWNED) dir")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let values = ShellQuoteTests.hostile.filter { !$0.isEmpty } + [""]
            let exec = RemoteExec(argv: ["/usr/bin/printf", "%s\\0"] + values, cwd: cwd.path, environment: [.literal("PATH", "/usr/bin:/bin")])
            let output = try runLocalScript(try exec.script(), environment: dirty)
            var parts = output.components(separatedBy: "\0")
            parts.removeLast()
            try expectEqual(parts, values)
            try expect(!FileManager.default.fileExists(atPath: cwd.appendingPathComponent("PWNED").path))
            try expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("PWNED").path))
        },
        TestCase("remote exec: pid file con el grupo, stdin de un archivo remoto, umask 077") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let input = base.appendingPathComponent("prompt.txt")
            try Data("Review this PR".utf8).write(to: input)
            let pidFile = base.appendingPathComponent("job.pid").path
            let exec = RemoteExec(argv: ["/bin/sh", "-c", "cat; umask"], environment: [.literal("PATH", "/usr/bin:/bin")],
                                  standardInput: .remoteFile(input.path), pidFile: pidFile)
            let output = try runLocalScript(try exec.script(), environment: dirty)
            try expectEqual(output, "Review this PR0077\n")
            let pid = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try expect(Int(pid).map { $0 > 1 } ?? false, pid)
        },
        TestCase("remote exec: programas y variables inválidos se rechazan") {
            for bad in ["", "rel/path", "a=b", "/x=y", "-x", "/a b/c\n"] {
                let error = try? RemoteExec(argv: [bad], environment: []).script()
                try expect(error == nil, "aceptó \(bad)")
            }
            try expect((try? RemoteExec(argv: ["/bin/true"], environment: [.literal("A-B", "1")]).script()) == nil)
            try expect((try? RemoteExec(argv: ["git"], environment: []).script()) != nil)
        },
        TestCase("remote root: solo rutas absolutas verificadas; hijos confinados") {
            for bad in ["", "/", "/srv", "relative/x", "/a/../b", "/a/./b", "/a//b", "/a/b\n", "/a/b/"] {
                try expect((try? RemoteRoot(verified: bad)) == nil, "aceptó \(bad)")
            }
            let root = try RemoteRoot(verified: "/home/fede/.prbar")
            try expectEqual(try root.child(["work", "api-1-1700000000-abcdef12"]), "/home/fede/.prbar/work/api-1-1700000000-abcdef12")
            for bad in [[".."], ["work", ".."], ["a/b"], [""], ["-rf"], ["x\ny"], ["."]] {
                try expect((try? root.child(bad)) == nil, "aceptó \(bad)")
            }
            try expect(root.contains("/home/fede/.prbar/work/x"))
            try expect(!root.contains("/home/fede/.prbar") && !root.contains("/home/fede/.prbarx/y") && !root.contains("/home/fede/.prbar/../x")
                       && !root.contains("/home/fede/.prbar/work/../../x"))
            try expect(root.isRemovable("/home/fede/.prbar/work/x") && !root.isRemovable("/home/fede/.prbar/work"))
        },
    ]
}
```

- [ ] **Step 2:** build → errores (`RemoteExec`, `RemoteRoot`, `RemoteEnvironment`).

- [ ] **Step 3: Implementación.** Agregar a `Sources/PRBarCore/RemoteExec.swift` (debajo de `RemoteRunnerError`):

```swift
/// Una variable del entorno remoto. `inherit`: la del host (`HOME`); `inheritIfSet`: solo si el host la tiene.
public enum RemoteEnv: Equatable, Sendable {
    case literal(String, String)
    case inherit(String)
    case inheritIfSet(String)

    var name: String {
        switch self {
        case .literal(let name, _), .inherit(let name), .inheritIfSet(let name): name
        }
    }

    func render() throws -> String {
        guard ShellQuote.isEnvironmentName(name) else { throw ShellQuote.Failure.invalidEnvironmentName(name) }
        switch self {
        case .literal(let name, let value): return try ShellQuote.posix("\(name)=\(value)")
        case .inherit(let name): return "\"\(name)=$\(name)\""
        case .inheritIfSet(let name): return "${\(name):+\"\(name)=$\(name)\"}"
        }
    }
}

/// Un comando para el host, armado como script POSIX: `cd`, el pgid a un archivo (para Stop), y `exec env -i <lista
/// blanca> <argv>` con stdin de `/dev/null`, de un archivo remoto o del de ssh. Nada se interpola: todo va con
/// `ShellQuote`.
public struct RemoteExec: Sendable {
    public enum StandardInput: Equatable, Sendable {
        case null
        case remoteFile(String)
        /// El stdin del `ssh` local (subidas y el guardián Perl).
        case passThrough
    }

    public var argv: [String]
    public var cwd: String?
    /// `nil` = el entorno de login del host (solo los tests del usuario, decisión J.7.13).
    public var environment: [RemoteEnv]?
    public var standardInput: StandardInput
    public var pidFile: String?

    public init(argv: [String], cwd: String? = nil, environment: [RemoteEnv]?, standardInput: StandardInput = .null,
                pidFile: String? = nil) {
        self.argv = argv
        self.cwd = cwd
        self.environment = environment
        self.standardInput = standardInput
        self.pidFile = pidFile
    }

    /// Absoluto (`/…`) o un nombre suelto (`git`, `perl`); nunca con `=` (env lo leería como variable), espacios
    /// ni `-` al principio.
    static func isValidExecutable(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("-"), !path.contains("="),
              path.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F }) else { return false }
        if path.hasPrefix("/") { return !path.split(separator: "/").contains { $0 == ".." } }
        return !path.contains("/")
    }

    public func script() throws -> String {
        guard let program = argv.first, Self.isValidExecutable(program) else {
            throw ShellQuote.Failure.invalidExecutable(argv.first ?? "")
        }
        var lines = ["umask 077"]
        if let cwd { lines.append("cd -- \(try ShellQuote.posix(cwd)) || exit 97") }
        if let pidFile {
            lines.append("pgid=$(ps -o pgid= -p $$ | tr -d ' ')")
            lines.append("case $pgid in ''|*[!0-9]*) exit 98;; esac")
            lines.append("printf '%s\\n' \"$pgid\" > \(try ShellQuote.posix(pidFile)) || exit 98")
        }
        var command = "exec "
        if let environment {
            command += "/usr/bin/env -i " + (try environment.map { try $0.render() }.joined(separator: " ")) + " "
        }
        command += try ShellQuote.command(argv)
        switch standardInput {
        case .null: command += " < /dev/null"
        case .remoteFile(let path): command += " < " + (try ShellQuote.posix(path))
        case .passThrough: break
        }
        lines.append(command)
        return lines.joined(separator: "\n")
    }
}

/// Los entornos remotos (decisión J.7.5).
public enum RemoteEnvironment {
    static let systemPath = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// Lo único que se copia del `environment` que pasa quien llama (los tests aíslan la config de git así).
    public static let gitPassthrough: Set<String> = [
        "GIT_TERMINAL_PROMPT", "GIT_LFS_SKIP_SMUDGE", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
        "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
    ]

    static func path(_ directories: [String]) -> RemoteEnv {
        var unique: [String] = []
        for dir in directories + systemPath where !unique.contains(dir) { unique.append(dir) }
        return .literal("PATH", unique.joined(separator: ":"))
    }

    public static func claude(pathDirectories: [String], root: RemoteRoot) -> [RemoteEnv] {
        [path(pathDirectories), .inherit("HOME"), .inheritIfSet("USER"), .inheritIfSet("LOGNAME"), .inheritIfSet("LANG"),
         .inheritIfSet("LC_ALL"), .literal("SHELL", "/bin/sh"), .literal("TMPDIR", root.tmp)]
    }

    public static func git(passing environment: [String: String]?, pathDirectories: [String], root: RemoteRoot) throws -> [RemoteEnv] {
        var result = [path(pathDirectories), .inherit("HOME"), .inheritIfSet("USER"), .inheritIfSet("LOGNAME"), .inheritIfSet("LANG"),
                      .inheritIfSet("LC_ALL"), .inheritIfSet("SSH_AUTH_SOCK"),
                      .literal("GIT_TERMINAL_PROMPT", "0"), .literal("GIT_LFS_SKIP_SMUDGE", "1"),
                      .literal("GIT_SSH_COMMAND", "ssh -o BatchMode=yes")]
        for (name, value) in (environment ?? [:]).sorted(by: { $0.key < $1.key }) {
            if SystemProcessRunner.unheritedVariables.contains(name) || name.hasSuffix("_TOKEN") {
                throw RemoteRunnerError.secretInEnvironment(name)
            }
            guard gitPassthrough.contains(name) else { continue }
            result.removeAll { $0.name == name }
            result.append(.literal(name, value))
        }
        return result
    }

    /// El guardián Perl: sin `PERL5OPT`/`PERL5LIB`.
    public static func perl() -> [RemoteEnv] {
        [path([]), .inherit("HOME"), .inheritIfSet("LANG")]
    }
}

/// La carpeta remota de PRBar, ya verificada (`pwd -P` en el host). Todo lo que PRBar crea o borra en el host pasa por
/// acá (decisión J.7.6).
public struct RemoteRoot: Hashable, Sendable {
    public static let marker = ".prbar-root"
    public let path: String

    public init(verified path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.hasSuffix("/"), path.count <= 400, components.count >= 3,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw RemoteRunnerError.outsideRoot(path)
        }
        self.path = path
    }

    public var work: String { path + "/work" }
    public var repos: String { path + "/repos" }
    public var jobs: String { path + "/jobs" }
    public var tmp: String { path + "/tmp" }
    public var markerPath: String { path + "/" + Self.marker }

    /// Un hijo de la raíz: cada componente `[A-Za-z0-9._-]`, sin `.`/`..` y sin empezar con `-`.
    public func child(_ components: [String]) throws -> String {
        guard !components.isEmpty else { throw RemoteRunnerError.outsideRoot(path) }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.hasPrefix("-"),
                  component.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) else {
                throw RemoteRunnerError.outsideRoot(([path] + components).joined(separator: "/"))
            }
        }
        return ([path] + components).joined(separator: "/")
    }

    /// Estrictamente adentro, sin `.`, `..` ni `//`.
    public func contains(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(path + "/") else { return false }
        let rest = candidate.dropFirst(path.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return !rest.isEmpty && rest.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Se puede borrar: adentro y al menos dos niveles abajo (`work/x`, nunca `work`).
    public func isRemovable(_ candidate: String) -> Bool {
        contains(candidate) && candidate.dropFirst(path.count + 1).split(separator: "/").count >= 2
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "remote exec" && swift run PRBarTests "remote root"` → `6/6 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/RemoteExec.swift Sources/PRBarTests/RemoteExecTests.swift Sources/PRBarTests/main.swift
git commit -m "Build remote commands with env -i, an allowlist and a confined root"
```

---

### Task 6: `FakeSSH` (stub para tests) y `SSHHost`

**Files:**
- Create: `Sources/PRBarTests/FakeSSH.swift`
- Create: `Sources/PRBarCore/SSHHost.swift`
- Test: `Sources/PRBarTests/SSHHostTests.swift` (+ `main.swift`)

- [ ] **Step 1: El stub.** `Sources/PRBarTests/FakeSSH.swift`. Ejecuta el comando remoto **localmente**, en `home` (el `$HOME` del host), con `env -i` y en una **sesión propia** (como `sshd`): si se mata al `ssh` local, el "proceso remoto" sigue vivo, que es lo que hace falta para probar Stop.

```swift
import Foundation
import PRBarCore

/// Un `ssh` de mentira para los tests: nunca conecta a nada. Anota cada invocación (argumentos separados por 0x1F) en
/// `log`; con `-G` imprime una config; con `-O` no hace nada; si no, corre el comando remoto con `/bin/sh -c` en
/// `home`, con un entorno mínimo (`env -i`) y en una sesión nueva (`setsid` desde Perl), y devuelve su exit code.
/// `FAKE_SSH_UNREACHABLE=1` simula un host caído (exit 255).
struct FakeSSH {
    let base: URL
    var executable: URL { base.appendingPathComponent("bin/ssh") }
    var home: URL { base.appendingPathComponent("remote-home") }
    var log: URL { base.appendingPathComponent("ssh.log") }
    var controlDirectory: String { base.appendingPathComponent("sock").path }

    static let script = #"""
    #!/bin/sh
    { for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$FAKE_SSH_LOG"
    mode=run; cmd=""; host=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o|-p|-l|-F) shift 2 ;;
        -O) mode=ctl; shift 2 ;;
        -G) mode=config; shift ;;
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
    exec /usr/bin/perl -e 'use POSIX (); my $pid = fork(); die "fork" unless defined $pid;
      if ($pid == 0) { POSIX::setsid(); exec @ARGV or exit 127 } waitpid($pid, 0); exit($? >> 8)' -- \
      /usr/bin/env -i HOME="$FAKE_SSH_HOME" USER=tester LOGNAME=tester LANG=en_US.UTF-8 PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      SSH_AUTH_SOCK=/remote/agent.sock /bin/sh -c "$cmd"
    """#

    static func make() throws -> FakeSSH {
        let base = try temporaryDirectory().resolvingSymlinksInPath()
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
    func environment(unreachable: Bool = false, strict: String = "ask") -> [String: String] {
        var env = ["FAKE_SSH_LOG": log.path, "FAKE_SSH_HOME": home.path, "FAKE_SSH_STRICT": strict]
        if unreachable { env["FAKE_SSH_UNREACHABLE"] = "1" }
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
        return text.split(separator: "\n").map { line in line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init).dropLast().map { $0 } }
    }

    func host(name: String = "devbox", remoteDir: String = "~/.prbar", unreachable: Bool = false,
              killGracePeriod: TimeInterval = 1) throws -> SSHHost {
        _ = try ControlSocketDirectory.ensure(controlDirectory)
        return SSHHost(destination: RunnerDestination(name: name, endpoint: SSHEndpoint(host: name), remoteDir: remoteDir),
                       sshPath: executable.path, controlDirectory: controlDirectory, enforceHostKey: true,
                       sshEnvironment: environment(unreachable: unreachable), killGracePeriod: killGracePeriod)
    }
}
```

- [ ] **Step 2: Tests que fallan** (`SSHHostTests.swift`):

```swift
import Foundation
import PRBarCore

enum SSHHostTests {
    static let cases: [TestCase] = [
        TestCase("ssh host: corre el script remoto con las opciones fijas; el texto hostil llega intacto") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let result = try await host.run(RemoteExec(argv: ["/bin/echo", "it's $HOME `x`"], environment: [.literal("PATH", "/bin")]), timeout: 10)
            try expectEqual(result.stdout, "it's $HOME `x`\n")
            let args = try expectNotNil(ssh.invocations().last)
            try expect(args.contains("BatchMode=yes") && args.contains("ForwardAgent=no") && args.contains("StrictHostKeyChecking=yes"))
            try expectEqual(Array(args.suffix(3).prefix(2)), ["--", "devbox"])
            try expect(args.last!.hasPrefix("/bin/sh -c '"), args.last!)
        },
        TestCase("ssh host: un host caído es unreachable") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let error = try await expectThrows {
                _ = try await ssh.host(unreachable: true).run(RemoteExec(argv: ["/bin/true"], environment: []), timeout: 10)
            }
            guard case .unreachable(let name, let detail)? = error as? RemoteRunnerError else { throw TestFailure(description: "\(error)") }
            try expectEqual(name, "devbox")
            try expect(detail.contains("Connection refused"))
        },
        TestCase("ssh host: subir y bajar binarios; nada fuera de la raíz") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let rootPath = ssh.home.appendingPathComponent(".prbar")
            try FileManager.default.createDirectory(at: rootPath.appendingPathComponent("tmp"), withIntermediateDirectories: true)
            try Data().write(to: rootPath.appendingPathComponent(RemoteRoot.marker))
            let root = try RemoteRoot(verified: rootPath.path)
            let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
            let remote = try root.child(["tmp", "blob.bin"])
            try await host.upload(bytes, to: remote, root: root)
            try expectEqual(try Data(contentsOf: URL(fileURLWithPath: remote)), bytes)
            let local = ssh.base.appendingPathComponent("down.bin")
            try await host.download(remote, to: local, root: root)
            try expectEqual(try Data(contentsOf: local), bytes)
            let before = ssh.invocations().count
            _ = try await expectThrows { try await host.upload(bytes, to: ssh.home.appendingPathComponent("x").path, root: root) }
            try expectEqual(ssh.invocations().count, before)
        },
        TestCase("ssh host: borrar exige la marca, estar adentro y dos niveles abajo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let host = try ssh.host()
            let rootURL = ssh.home.appendingPathComponent(".prbar")
            let victim = rootURL.appendingPathComponent("work/old-run")
            try FileManager.default.createDirectory(at: victim.appendingPathComponent("deep"), withIntermediateDirectories: true)
            let root = try RemoteRoot(verified: rootURL.path)
            let unmarked = try await expectThrows { try await host.removeTree(victim.path, root: root) }
            try expect(unmarked is RemoteRunnerError)
            try expect(FileManager.default.fileExists(atPath: victim.path))
            try Data().write(to: rootURL.appendingPathComponent(RemoteRoot.marker))
            try await host.removeTree(victim.path, root: root)
            try expect(!FileManager.default.fileExists(atPath: victim.path))
            for refused in [rootURL.appendingPathComponent("work").path, rootURL.path, ssh.home.path, rootURL.path + "/work/../.."] {
                _ = try await expectThrows { try await host.removeTree(refused, root: root) }
            }
            try expect(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("work").path))
        },
    ]
}

func expectNotNil<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else { throw TestFailure(description: "\(file):\(line) expected a value, got nil") }
    return value
}
```

> Si ya existe un `expectNotNil` en `TestKit.swift`, usar ese y no redefinirlo.

- [ ] **Step 3: `Sources/PRBarCore/SSHHost.swift`:**

```swift
import Foundation

/// Un host por ssh (spec J.1/J.3): corre scripts (`/bin/sh -c '<script>'`), sube y baja archivos y borra solo
/// dentro de la raíz de PRBar. Todo pasa por el `ssh` del sistema con `SSHCommandBuilder`.
public struct SSHHost: Sendable {
    /// Linux limita cada argumento a 128 KiB; el script viaja como un solo argumento del shell de login.
    public static let maxScriptBytes = 100_000

    public let destination: RunnerDestination
    public let sshPath: String
    public let controlDirectory: String
    public let enforceHostKey: Bool
    /// Entorno del `ssh` local (además del de la app; los tests pasan el del stub).
    public let sshEnvironment: [String: String]
    public let killGracePeriod: TimeInterval
    let local: SystemProcessRunner

    public init(destination: RunnerDestination, sshPath: String = "/usr/bin/ssh", controlDirectory: String, enforceHostKey: Bool,
                sshEnvironment: [String: String] = [:], killGracePeriod: TimeInterval = 5, local: SystemProcessRunner = SystemProcessRunner()) {
        self.destination = destination
        self.sshPath = sshPath
        self.controlDirectory = controlDirectory
        self.enforceHostKey = enforceHostKey
        self.sshEnvironment = sshEnvironment
        self.killGracePeriod = killGracePeriod
        self.local = local
    }

    public var name: String { destination.name }

    public func run(_ exec: RemoteExec, timeout: TimeInterval?, standardInput: URL? = nil, standardOutput: URL? = nil,
                    onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        try await runScript(try exec.script(), timeout: timeout, standardInput: standardInput, standardOutput: standardOutput,
                            onStdoutLine: onStdoutLine)
    }

    /// `script` ya tiene todo con comillas (`RemoteExec`, `ShellQuote`). Va como `/bin/sh -c '<script>'`.
    public func runScript(_ script: String, timeout: TimeInterval?, standardInput: URL? = nil, standardOutput: URL? = nil,
                          onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let command = "/bin/sh -c " + (try ShellQuote.posix(script))
        guard command.utf8.count <= Self.maxScriptBytes else { throw RemoteRunnerError.commandTooLong(host: name) }
        let args = SSHCommandBuilder.arguments(destination, controlDirectory: controlDirectory, enforceHostKey: enforceHostKey,
                                               remoteCommand: command)
        let result = try await local.runWithFiles(sshPath, args, environment: sshEnvironment, currentDirectory: nil, timeout: timeout,
                                                  standardInput: standardInput, standardOutput: standardOutput, onStdoutLine: onStdoutLine)
        if result.status == 255 {
            throw RemoteRunnerError.unreachable(host: name, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Lanza si salió con error.
    @discardableResult
    func checked(_ result: ProcessResult, _ what: String) throws -> ProcessResult {
        guard result.status == 0 else {
            throw RemoteRunnerError.commandFailed(host: name, command: what, status: result.status,
                                                  stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// Escribe `data` en `path` (dentro de la raíz): a un `.part` y `mv`, con `umask 077`.
    public func upload(_ data: Data, to path: String, root: RemoteRoot, timeout: TimeInterval = 300) async throws {
        guard root.contains(path) else { throw RemoteRunnerError.outsideRoot(path) }
        let localFile = try LocalScratch.file(with: data)
        defer { try? FileManager.default.removeItem(at: localFile) }
        let part = try ShellQuote.posix(path + ".part")
        let script = "umask 077 && cat > \(part) && mv -f -- \(part) \(try ShellQuote.posix(path))"
        try checked(try await runScript(script, timeout: timeout, standardInput: localFile), "upload")
    }

    /// Baja `path` (dentro de la raíz) a `local`, binario.
    public func download(_ path: String, to local: URL, root: RemoteRoot, timeout: TimeInterval = 300) async throws {
        guard root.contains(path) else { throw RemoteRunnerError.outsideRoot(path) }
        try checked(try await runScript("cat -- \(try ShellQuote.posix(path))", timeout: timeout, standardOutput: local), "download")
    }

    /// `rm -rf` de `path`, solo si está dentro de la raíz, dos niveles abajo, y la raíz tiene la marca.
    public func removeTree(_ path: String, root: RemoteRoot) async throws {
        guard root.isRemovable(path) else { throw RemoteRunnerError.outsideRoot(path) }
        let script = "[ -f \(try ShellQuote.posix(root.markerPath)) ] || exit 96\nrm -rf -- \(try ShellQuote.posix(path))"
        try checked(try await runScript(script, timeout: 120), "rm")
    }

    /// Borra archivos sueltos de la raíz (pid, stdin de un trabajo). Nunca lanza.
    public func removeFiles(_ paths: [String], root: RemoteRoot) async {
        let safe = paths.filter(root.isRemovable)
        guard !safe.isEmpty, let quoted = try? safe.map(ShellQuote.posix).joined(separator: " ") else { return }
        _ = try? await runScript("rm -f -- \(quoted)", timeout: 30)
    }

    /// Stop (decisión J.7.15): SIGTERM al grupo remoto guardado en `pidFile`, y SIGKILL a los `killGracePeriod`
    /// segundos. Nunca lanza.
    public func killGroup(pidFile: String, root: RemoteRoot) async {
        guard root.isRemovable(pidFile), let file = try? ShellQuote.posix(pidFile) else { return }
        let grace = max(1, Int(killGracePeriod.rounded(.up)))
        let script = """
        [ -f \(file) ] || exit 0
        pgid=$(cat -- \(file))
        case $pgid in ''|*[!0-9]*) exit 3;; esac
        [ "$pgid" -gt 1 ] || exit 3
        kill -TERM -- "-$pgid" 2>/dev/null
        sleep \(grace)
        kill -KILL -- "-$pgid" 2>/dev/null
        rm -f -- \(file)
        exit 0
        """
        _ = try? await runScript(script, timeout: killGracePeriod + 30)
    }

    /// `ssh -O exit` (al sacar el destino). Nunca lanza.
    public func closeMaster() async {
        _ = try? await local.run(sshPath, SSHCommandBuilder.exitArguments(destination, controlDirectory: controlDirectory),
                                 environment: sshEnvironment, currentDirectory: nil, timeout: 10)
    }

    /// `ssh -G`: si hay que forzar `StrictHostKeyChecking=yes`.
    public static func enforcesHostKey(_ destination: RunnerDestination, sshPath: String = "/usr/bin/ssh",
                                       sshEnvironment: [String: String] = [:]) async -> Bool {
        guard let result = try? await SystemProcessRunner().run(sshPath, SSHCommandBuilder.configArguments(destination),
                                                                environment: sshEnvironment, currentDirectory: nil, timeout: 10),
              result.status == 0 else { return true }
        return SSHCommandBuilder.enforcesHostKey(fromConfig: result.stdout)
    }
}

/// Archivos locales de paso (subidas, bundles), 0600, en `$TMPDIR/PRBar/ssh-io`.
enum LocalScratch {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/ssh-io", isDirectory: true) }

    static func file(with data: Data) throws -> URL {
        let url = try newFile()
        try data.write(to: url)
        return url
    }

    static func newFile() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "ssh host"` → `4/4 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/SSHHost.swift Sources/PRBarTests/FakeSSH.swift Sources/PRBarTests/SSHHostTests.swift Sources/PRBarTests/main.swift
git commit -m "Run, upload, download and confined deletes on an SSH host (with a fake ssh for tests)"
```

---

### Task 7: Verificación del host (`RunnerProbe`) y caché de salud

**Files:**
- Create: `Sources/PRBarCore/RunnerProbe.swift`
- Test: `Sources/PRBarTests/RunnerProbeTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

enum RunnerProbeTests {
    static let cases: [TestCase] = [
        TestCase("probe: SO, git, claude (por sh -l), perl, comillas intactas; crea la raíz con su marca") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let info = try await RunnerProbe.check(try ssh.host())
            try expectEqual(info.problems, [])
            try expectEqual(info.gitPath, "/usr/bin/git")
            try expectEqual(info.claudePath, ssh.home.appendingPathComponent("bin/claude").path)
            try expectEqual(info.claudeVersion, "2.1.400 (Claude Code)")
            try expect(info.quotingOK && info.perl)
            let root = ssh.home.appendingPathComponent(".prbar").path
            try expectEqual(info.root, root)
            for sub in ["work", "repos", "jobs", "tmp", RemoteRoot.marker] {
                try expect(FileManager.default.fileExists(atPath: root + "/" + sub), sub)
            }
        },
        TestCase("probe: una carpeta existente ajena no se usa; sin claude, problema claro") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            let foreign = ssh.home.appendingPathComponent(".prbar")
            try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
            try Data("mine".utf8).write(to: foreign.appendingPathComponent("notes.txt"))
            let info = try await RunnerProbe.check(try ssh.host())
            try expectEqual(info.root, nil)
            try expect(info.problems.contains { $0.contains("already exists and isn’t PRBar’s") }, "\(info.problems)")
            try expect(info.problems.contains { $0.contains("claude isn’t installed") }, "\(info.problems)")
            try expect(FileManager.default.fileExists(atPath: foreign.appendingPathComponent("notes.txt").path))
        },
        TestCase("probe: parseo, git viejo y comillas cambiadas") {
            let output = """
            os=Linux
            arch=x86_64
            gitpath=/usr/bin/git
            git=git version 2.25.1
            claudepath=/home/u/.local/bin/claude
            claude=2.1.400 (Claude Code)
            perl=ok
            quoting=changed
            root=/home/u/.prbar
            """
            let info = RunnerProbe.parse(output, host: "devbox", now: t0)
            try expect(info.problems.contains { $0.contains("git 2.31") }, "\(info.problems)")
            try expect(info.problems.contains { $0.contains("login shell") }, "\(info.problems)")
            try expectEqual(RunnerProbe.gitVersion("git version 2.39.3 (Apple Git-146)").map { [$0.0, $0.1, $0.2] }, [2, 39, 3])
        },
        TestCase("probe: login de Claude con un claude -p mínimo") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try Data(#"ok"#.utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let host = try ssh.host()
            let info = try await RunnerProbe.check(host)
            let loggedIn = try await RunnerProbe.claudeLoggedIn(host, info: info)
            try expect(loggedIn)
            let args = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/args.bin"), encoding: .utf8)
                .split(separator: "\0").map(String.init)
            try expect(args.contains("haiku") && args.contains("--strict-mcp-config") && !args.contains { $0.contains("Reply") })
            let prompt = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/prompt.txt"), encoding: .utf8)
            try expect(prompt.contains("Reply with the single word"))
            try Data("Invalid API key".utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let notLogged = try await RunnerProbe.claudeLoggedIn(host, info: info)
            try expect(!notLogged)
        },
        TestCase("probe: la salud se cachea 5 min si anda y 60 s si no") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let cache = RunnerHealthCache()
            let host = try ssh.host()
            _ = try await cache.info(for: host, now: t0)
            _ = try await cache.info(for: host, now: t0.addingTimeInterval(200))
            let afterTwo = ssh.invocations().count
            _ = try await cache.info(for: host, now: t0.addingTimeInterval(301))
            try expectEqual(ssh.invocations().count, afterTwo + 1)
            let down = try ssh.host(unreachable: true)
            let failCache = RunnerHealthCache()
            _ = try? await failCache.info(for: down, now: t0)
            let afterFail = ssh.invocations().count
            _ = try? await failCache.info(for: down, now: t0.addingTimeInterval(30))
            try expectEqual(ssh.invocations().count, afterFail)
            _ = try? await failCache.info(for: down, now: t0.addingTimeInterval(61))
            try expectEqual(ssh.invocations().count, afterFail + 1)
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'RunnerProbe'`.

- [ ] **Step 3: `Sources/PRBarCore/RunnerProbe.swift`:**

```swift
import Foundation

/// Lo que se sabe de un host después de verificarlo (spec J.3).
public struct RunnerHostInfo: Codable, Equatable, Sendable {
    public var host: String
    public var os: String?
    public var arch: String?
    /// El `HOME` del usuario en el host (para `~/` en los includes de git del guardián).
    public var home: String?
    public var gitPath: String?
    public var gitVersion: String?
    public var claudePath: String?
    public var claudeVersion: String?
    public var perl: Bool
    public var quotingOK: Bool
    /// La raíz verificada (`pwd -P`).
    public var root: String?
    public var problems: [String]
    public var checkedAt: Date
    /// Solo "Test Connection" lo prueba (`nil` = no se probó).
    public var claudeLoggedIn: Bool?

    public init(host: String, os: String? = nil, arch: String? = nil, home: String? = nil, gitPath: String? = nil, gitVersion: String? = nil,
                claudePath: String? = nil, claudeVersion: String? = nil, perl: Bool = false, quotingOK: Bool = false,
                root: String? = nil, problems: [String] = [], checkedAt: Date = Date(), claudeLoggedIn: Bool? = nil) {
        self.host = host
        self.os = os
        self.arch = arch
        self.home = home
        self.gitPath = gitPath
        self.gitVersion = gitVersion
        self.claudePath = claudePath
        self.claudeVersion = claudeVersion
        self.perl = perl
        self.quotingOK = quotingOK
        self.root = root
        self.problems = problems
        self.checkedAt = checkedAt
        self.claudeLoggedIn = claudeLoggedIn
    }

    /// Una verificación que ni siquiera pudo correr (host caído, ssh mal configurado).
    public init(host: String, problem: String) {
        self.init(host: host, problems: [problem])
    }

    public var isUsable: Bool { problems.isEmpty && root != nil && gitPath != nil && claudePath != nil }

    /// Carpetas de `git` y `claude` del host (para el `PATH` remoto).
    public var toolDirectories: [String] {
        [claudePath, gitPath].compactMap { $0 }.map { ($0 as NSString).deletingLastPathComponent }
    }
}

public enum RunnerProbe {
    public static let quotingPayload = "a'b\"c\\d$e`f!g*h;i|j&k#l m\tn~o"
    public static let minimumGit = (2, 31, 0)

    /// `uname; git --version; command -v claude; claude --version` (spec J.3), la sonda de comillas y la raíz.
    public static func script(for destination: RunnerDestination) throws -> String {
        """
        printf 'os=%s\\n' "$(uname -s 2>/dev/null)"
        printf 'arch=%s\\n' "$(uname -m 2>/dev/null)"
        printf 'home=%s\\n' "$HOME"
        g=$(command -v git 2>/dev/null)
        printf 'gitpath=%s\\n' "$g"
        [ -n "$g" ] && printf 'git=%s\\n' "$("$g" --version 2>/dev/null | head -n 1)"
        c=$(command -v claude 2>/dev/null || "${SHELL:-/bin/sh}" -lc 'command -v claude' 2>/dev/null | tail -n 1)
        printf 'claudepath=%s\\n' "$c"
        [ -n "$c" ] && printf 'claude=%s\\n' "$("$c" --version 2>/dev/null | head -n 1)"
        if /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin perl -MDigest::SHA -MTime::HiRes=lstat -e 1 2>/dev/null; then printf 'perl=ok\\n'; fi
        printf 'quoting=%s\\n' \(try ShellQuote.posix(quotingPayload))
        d=\(try destination.remoteDirExpression())
        umask 077
        if mkdir -p -- "$d" 2>/dev/null && cd -- "$d"; then
          if [ ! -e \(RemoteRoot.marker) ] && [ -n "$(ls -A)" ]; then printf 'rootproblem=notempty\\n'
          else : > \(RemoteRoot.marker) && mkdir -p work repos jobs tmp && chmod 700 . work repos jobs tmp && printf 'root=%s\\n' "$(pwd -P)"; fi
        else printf 'rootproblem=mkdir\\n'; fi
        """
    }

    public static func check(_ host: SSHHost, now: Date = Date()) async throws -> RunnerHostInfo {
        let result = try host.checked(try await host.runScript(try script(for: host.destination), timeout: 60), "verification")
        return parse(result.stdout, host: host.name, remoteDir: host.destination.remoteDir, now: now)
    }

    public static func parse(_ output: String, host: String, remoteDir: String = RunnerDestination.defaultRemoteDir, now: Date) -> RunnerHostInfo {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        func absolute(_ key: String) -> String? {
            guard let value = values[key], value.hasPrefix("/"), !value.contains("\n") else { return nil }
            return value
        }
        var info = RunnerHostInfo(host: host, os: values["os"], arch: values["arch"], home: absolute("home"), gitPath: absolute("gitpath"),
                                  gitVersion: values["git"], claudePath: absolute("claudepath"), claudeVersion: values["claude"],
                                  perl: values["perl"] == "ok", quotingOK: values["quoting"] == quotingPayload,
                                  root: absolute("root").flatMap { (try? RemoteRoot(verified: $0))?.path }, problems: [], checkedAt: now)
        if !info.quotingOK {
            info.problems.append("\(host)’s login shell changed PRBar’s test string — set sh, bash or zsh as the login shell for this user.")
        }
        if info.gitPath == nil {
            info.problems.append("git isn’t installed on \(host).")
        } else if let version = info.gitVersion.flatMap(gitVersion), version < minimumGit {
            info.problems.append("\(host) has \(info.gitVersion ?? "an old git"); PRBar needs git 2.31 or later.")
        }
        if info.claudePath == nil || (info.claudeVersion ?? "").isEmpty {
            info.problems.append("claude isn’t installed on \(host) (or isn’t in its PATH). Install Claude Code there.")
        }
        if !info.perl { info.problems.append("\(host) needs Perl with Digest::SHA and Time::HiRes (PRBar’s integrity checks use it).") }
        switch values["rootproblem"] {
        case "notempty"?: info.problems.append("\(remoteDir) on \(host) already exists and isn’t PRBar’s. Choose another folder.")
        case "mkdir"?: info.problems.append("PRBar can’t create \(remoteDir) on \(host).")
        default: if info.root == nil && values["rootproblem"] == nil { info.problems.append("PRBar can’t use \(remoteDir) on \(host).") }
        }
        return info
    }

    /// `git version 2.39.3 (Apple Git-146)` → (2, 39, 3).
    public static func gitVersion(_ text: String) -> (Int, Int, Int)? {
        guard let token = text.split(separator: " ").first(where: { $0.first?.isNumber == true }) else { return nil }
        let numbers = token.split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 0)
    }

    /// "Test Connection": un `claude -p` mínimo con `--model haiku`, aislado y con el prompt por stdin.
    public static func claudeLoggedIn(_ host: SSHHost, info: RunnerHostInfo) async throws -> Bool {
        guard let claude = info.claudePath, let rootPath = info.root else { return false }
        let root = try RemoteRoot(verified: rootPath)
        let promptPath = try root.child(["tmp", "login-check-\(UUID().uuidString.lowercased()).txt"])
        try await host.upload(Data("Reply with the single word: ok".utf8), to: promptPath, root: root)
        defer { Task.detached { await host.removeFiles([promptPath], root: root) } }
        let exec = RemoteExec(
            argv: [claude, "-p", "--model", "haiku", "--output-format", "text", "--setting-sources", "", "--strict-mcp-config",
                   "--mcp-config", #"{"mcpServers":{}}"#, "--tools", "", "--permission-mode", "dontAsk"],
            cwd: root.tmp, environment: RemoteEnvironment.claude(pathDirectories: info.toolDirectories, root: root),
            standardInput: .remoteFile(promptPath))
        let result = try await host.run(exec, timeout: 120)
        return result.status == 0 && result.stdout.lowercased().contains("ok")
    }
}

/// Verificación antes de cada trabajo: 5 min si salió bien, 60 s si falló (decisión J.7.11).
public actor RunnerHealthCache {
    public static let successTTL: TimeInterval = 300
    public static let failureTTL: TimeInterval = 60

    private var entries: [String: (at: Date, result: Result<RunnerHostInfo, Error>)] = [:]

    public init() {}

    public func info(for host: SSHHost, force: Bool = false, now: Date = Date()) async throws -> RunnerHostInfo {
        let key = host.name.lowercased()
        if !force, let entry = entries[key] {
            let ttl = (try? entry.result.get()) != nil ? Self.successTTL : Self.failureTTL
            if now.timeIntervalSince(entry.at) < ttl { return try entry.result.get() }
        }
        let result: Result<RunnerHostInfo, Error>
        do {
            let info = try await RunnerProbe.check(host, now: now)
            result = info.isUsable ? .success(info) : .failure(RemoteRunnerError.hostProblems(host: host.name, problems: info.problems))
        } catch {
            result = .failure(error)
        }
        entries[key] = (now, result)
        return try result.get()
    }

    public func last(_ name: String) -> RunnerHostInfo? { try? entries[name.lowercased()]?.result.get() }
    public func forget(_ name: String) { entries[name.lowercased()] = nil }
}
```

> `(Int, Int, Int) < (Int, Int, Int)`: Swift compara tuplas de hasta 6 elementos `Comparable`.

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests probe` → `5/5 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/RunnerProbe.swift Sources/PRBarTests/RunnerProbeTests.swift Sources/PRBarTests/main.swift
git commit -m "Verify SSH hosts (tools, quoting, root folder) and cache their health"
```

---

### Task 8: Claude y git en el host (`RemoteProcessRunner`), prompt por stdin y Stop

**Files:**
- Create: `Sources/PRBarCore/RemoteProcessRunner.swift`
- Modify: `Sources/PRBarCore/ClaudeRunner.swift`, `Sources/PRBarCore/ClaudeReviewer.swift`
- Test: `Sources/PRBarTests/RemoteProcessRunnerTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

/// Un host de `FakeSSH` ya verificado.
func verifiedFake() async throws -> (FakeSSH, SSHHost, RunnerHostInfo, RemoteRoot) {
    let ssh = try FakeSSH.make()
    try ssh.installFakeClaude()
    let host = try ssh.host()
    let info = try await RunnerProbe.check(host)
    guard let rootPath = info.root else { throw TestFailure(description: "sin raíz: \(info.problems)") }
    return (ssh, host, info, try RemoteRoot(verified: rootPath))
}

private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Looks fine","findings":[]}}"#

enum RemoteProcessRunnerTests {
    static let cases: [TestCase] = [
        TestCase("remote runner: claude corre en el host con los argumentos de §8.3, el prompt por stdin y la lista blanca") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            try Data((resultLine + "\n").utf8).write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
            let log = ssh.base.appendingPathComponent("claude.log")
            let claude = ClaudeRunner(runner: runner, claudePath: info.claudePath!, pluginDirs: ["/home/u/.claude/plugins/cache/m/p/1"],
                                      environment: ["PATH": "/opt/homebrew/bin", "GH_TOKEN": "nope"], logURL: log, redacting: ["ghp_x"],
                                      promptViaStandardInput: true)
            let work = try root.child(["work", "api-1-1700000000-abcdef12"])
            try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
            struct Out: Decodable { let summary: String }
            let invocation = ClaudeInvocation(prompt: "Review it's $(rm -rf ~) safely", schema: #"{"type":"object"}"#,
                                              tools: ["Read", "Grep", "Glob", "Skill", "Agent"], workingDirectory: URL(fileURLWithPath: work),
                                              additionalDirectories: [URL(fileURLWithPath: work + ".context")], timeout: 30, logHeader: "=== stage 1 ===")
            let out = try await claude.run(invocation, as: Out.self, onAgent: { _ in })
            try expectEqual(out.summary, "Looks fine")
            let call = ssh.home.appendingPathComponent("claude-calls/1")
            try expectEqual(try String(contentsOf: call.appendingPathComponent("prompt.txt"), encoding: .utf8), "Review it's $(rm -rf ~) safely")
            try expectEqual(try String(contentsOf: call.appendingPathComponent("cwd.txt"), encoding: .utf8), work + "\n")
            let args = try String(contentsOf: call.appendingPathComponent("args.bin"), encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            try expectEqual(args.first, "-p")
            try expect(!args.contains("Review it's $(rm -rf ~) safely"))
            for flag in ["--setting-sources", "--settings", "--permission-mode", "--strict-mcp-config", "--json-schema", "--disallowedTools"] {
                try expect(args.contains(flag), flag)
            }
            let env = try String(contentsOf: call.appendingPathComponent("env.txt"), encoding: .utf8)
            try expect(!env.contains("GH_TOKEN") && !env.contains("SSH_AUTH_SOCK") && env.contains("TMPDIR=\(root.tmp)"), env)
            var leftovers = ["?"]
            for _ in 0..<30 where !leftovers.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                leftovers = try FileManager.default.contentsOfDirectory(atPath: root.tmp).filter { $0.hasSuffix(".stdin") }
                    + FileManager.default.contentsOfDirectory(atPath: root.jobs)
            }
            try expectEqual(leftovers, [])
        },
        TestCase("remote runner: git con -C y el entorno de git; un token en el entorno no sale") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
            let result = try await runner.run(info.gitPath!, ["--version"], environment: ["GIT_TERMINAL_PROMPT": "0"], currentDirectory: nil, timeout: 30)
            try expect(result.stdout.hasPrefix("git version"))
            _ = try await expectThrows {
                _ = try await runner.run(info.gitPath!, ["--version"], environment: ["GITHUB_TOKEN": "x"], currentDirectory: nil, timeout: 30)
            }
        },
        TestCase("remote runner: cancelar mata al grupo remoto (no solo al ssh local)") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            try ssh.installTool("slow", """
            #!/bin/sh
            printf '%s\\n' "$$" > "$HOME/slow.pid"
            printf '{"type":"system","subtype":"init"}\\n'
            exec sleep 60
            """)
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories + [ssh.home.appendingPathComponent("bin").path])
            let task = Task {
                try await runner.runStreamingIsolated(ssh.home.appendingPathComponent("bin/slow").path, [], environment: [:],
                                                      currentDirectory: URL(fileURLWithPath: root.tmp), timeout: 120) { _ in }
            }
            let pidFile = ssh.home.appendingPathComponent("slow.pid")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(for: .milliseconds(50)) }
            let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            task.cancel()
            _ = try? await task.value
            var alive = true
            for _ in 0..<80 where alive {
                try await Task.sleep(for: .milliseconds(100))
                alive = kill(pid, 0) == 0
            }
            try expect(!alive, "el proceso remoto \(pid) sigue vivo")
        },
        TestCase("remote runner: un timeout también mata al grupo remoto") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            try ssh.installTool("slow", "#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$HOME/slow.pid\"\nexec sleep 60\n")
            let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
            _ = try await expectThrows {
                _ = try await runner.runStreamingIsolated(ssh.home.appendingPathComponent("bin/slow").path, [], environment: [:],
                                                          currentDirectory: nil, timeout: 1.5) { _ in }
            }
            let pid = Int32(try String(contentsOf: ssh.home.appendingPathComponent("slow.pid"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))!
            var alive = true
            for _ in 0..<80 where alive {
                try await Task.sleep(for: .milliseconds(100))
                alive = kill(pid, 0) == 0
            }
            try expect(!alive)
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'RemoteProcessRunner'`, `extra argument 'promptViaStandardInput'`.

- [ ] **Step 3: `Sources/PRBarCore/RemoteProcessRunner.swift`:**

```swift
import Foundation

/// Un runner que además manda datos por stdin (el prompt de Claude en un host remoto, decisión J.7.2).
public protocol StandardInputStreamingRunning: StreamingProcessRunning {
    func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                              timeout: TimeInterval?, standardInput: Data,
                              onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult
}

/// git y Claude en el host. `run`/`runStreaming`: git con el entorno de git (`RemoteEnvironment.git`);
/// `runStreamingIsolated`: Claude con su lista blanca, el pgid en `<raíz>/jobs/<job>.pid` y Stop/timeout que matan al
/// grupo remoto. El `environment` que manda `ClaudeRunner` (rutas de la Mac) se ignora: el remoto se arma acá.
public struct RemoteProcessRunner: ProcessRunning, StandardInputStreamingRunning {
    public let host: SSHHost
    public let root: RemoteRoot
    public let toolDirectories: [String]

    public init(host: SSHHost, root: RemoteRoot, toolDirectories: [String]) {
        self.host = host
        self.root = root
        self.toolDirectories = toolDirectories
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                    timeout: TimeInterval?) async throws -> ProcessResult {
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: try RemoteEnvironment.git(passing: environment, pathDirectories: toolDirectories, root: root))
        return try await host.run(exec, timeout: timeout)
    }

    public func runStreaming(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                             timeout: TimeInterval?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: try RemoteEnvironment.git(passing: environment, pathDirectories: toolDirectories, root: root))
        return try await host.run(exec, timeout: timeout, onStdoutLine: onStdoutLine)
    }

    public func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                                     timeout: TimeInterval?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        try await isolated(executable, arguments, currentDirectory: currentDirectory, timeout: timeout, standardInput: nil, onStdoutLine: onStdoutLine)
    }

    public func runStreamingIsolated(_ executable: String, _ arguments: [String], environment: [String: String], currentDirectory: URL?,
                                     timeout: TimeInterval?, standardInput: Data,
                                     onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        try await isolated(executable, arguments, currentDirectory: currentDirectory, timeout: timeout, standardInput: standardInput,
                           onStdoutLine: onStdoutLine)
    }

    private func isolated(_ executable: String, _ arguments: [String], currentDirectory: URL?, timeout: TimeInterval?,
                          standardInput: Data?, onStdoutLine: @escaping @Sendable (String) -> Void) async throws -> ProcessResult {
        let job = UUID().uuidString.lowercased()
        let pidFile = try root.child(["jobs", job + ".pid"])
        var stdinPath: String?
        if let standardInput {
            let path = try root.child(["tmp", job + ".stdin"])
            try await host.upload(standardInput, to: path, root: root)
            stdinPath = path
        }
        let exec = RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path,
                              environment: RemoteEnvironment.claude(pathDirectories: toolDirectories, root: root),
                              standardInput: stdinPath.map { .remoteFile($0) } ?? .null, pidFile: pidFile)
        let host = self.host
        let root = self.root
        let leftovers = [pidFile] + (stdinPath.map { [$0] } ?? [])
        do {
            let result = try await withTaskCancellationHandler {
                try await host.run(exec, timeout: timeout, onStdoutLine: onStdoutLine)
            } onCancel: {
                Task.detached { await host.killGroup(pidFile: pidFile, root: root) }
            }
            Task.detached { await host.removeFiles(leftovers, root: root) }
            return result
        } catch {
            if let prbar = error as? PRBarError, case .timedOut = prbar {
                await Task.detached { await host.killGroup(pidFile: pidFile, root: root) }.value
            }
            if !(error is CancellationError) { Task.detached { await host.removeFiles(leftovers, root: root) } }
            throw error
        }
    }
}

/// Los tests del usuario en el host (decisión J.7.13): `/bin/sh -lc <cmd>` con el entorno de login, sin `env -i`.
public struct RemoteLoginRunner: ProcessRunning {
    public let host: SSHHost

    public init(host: SSHHost) { self.host = host }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]?, currentDirectory: URL?,
                    timeout: TimeInterval?) async throws -> ProcessResult {
        try await host.run(RemoteExec(argv: [executable] + arguments, cwd: currentDirectory?.path, environment: nil), timeout: timeout)
    }
}
```

> `PRBarError.timedOut(command:)` es el caso que lanza `SystemProcessRunner` al vencer el timeout.

- [ ] **Step 4: `ClaudeRunner`.**
  - propiedad `private let promptViaStandardInput: Bool` e `init(…, model: ClaudeModel? = nil, promptViaStandardInput: Bool = false)`.
  - `arguments(for:pluginDirs:model:)` gana `promptInArguments: Bool = true` y empieza con `var arguments = promptInArguments ? ["-p", invocation.prompt] : ["-p"]`.
  - En `attempt`, reemplazar la llamada a `runner.runStreamingIsolated(…)` por:

```swift
            let arguments = Self.arguments(for: invocation, pluginDirs: pluginDirs, model: model,
                                           promptInArguments: !promptViaStandardInput)
            let onLine: @Sendable (String) -> Void = { line in
                // Redacted before parsing: the decoded output and the errors don't carry the token either.
                let line = Redactor.redact(line, secrets: secrets)
                log.append(line + "\n")
                for event in parser.withLock({ $0.consumeAll(line) }) { onEvent(event) }
            }
            if promptViaStandardInput, let stdinRunner = runner as? StandardInputStreamingRunning {
                result = try await stdinRunner.runStreamingIsolated(
                    claudePath, arguments, environment: environment, currentDirectory: invocation.workingDirectory, timeout: timeout,
                    standardInput: Data(invocation.prompt.utf8), onStdoutLine: onLine)
            } else {
                result = try await runner.runStreamingIsolated(
                    claudePath, arguments, environment: environment, currentDirectory: invocation.workingDirectory, timeout: timeout,
                    onStdoutLine: onLine)
            }
```
  - `ClaudeReviewer.init` gana `promptViaStandardInput: Bool = false` y lo pasa a su `ClaudeRunner`.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests "remote runner" && swift run PRBarTests claude` → todo `passed` (los tests de `ClaudeRunner` existentes no cambian: el default es por argumentos).

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore/RemoteProcessRunner.swift Sources/PRBarCore/ClaudeRunner.swift Sources/PRBarCore/ClaudeReviewer.swift Sources/PRBarTests/RemoteProcessRunnerTests.swift Sources/PRBarTests/main.swift
git commit -m "Run git and isolated Claude on the host, with the prompt on stdin and remote Stop"
```

---

### Task 9: Plugins del host (regla de §8.0)

**Files:**
- Create: `Sources/PRBarCore/RemotePlugins.swift`
- Test: `Sources/PRBarTests/RemotePluginsTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

enum RemotePluginsTests {
    static let cases: [TestCase] = [
        TestCase("remote plugins: la instalación más nueva de cada plugin del host; sin repetir") {
            let (ssh, host, _, _) = try await verifiedFake()
            defer { ssh.remove() }
            let cache = ssh.home.appendingPathComponent(".claude/plugins/cache/claude-plugins-official/pr-review-toolkit")
            for version in ["1.0.0", "2.0.0"] {
                try FileManager.default.createDirectory(at: cache.appendingPathComponent("\(version)/skills"), withIntermediateDirectories: true)
            }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                                  ofItemAtPath: cache.appendingPathComponent("1.0.0").path)
            let empty = ssh.home.appendingPathComponent(".claude/plugins/cache/other/pr-review-toolkit/9.9.9")
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)   // sin skills/commands/agents
            let dirs = try await RemotePlugins.locate(skills: ["pr-review-toolkit:review-pr", "pr-review-toolkit:other", "review"], host: host)
            try expectEqual(dirs, [cache.appendingPathComponent("2.0.0").path])
        },
        TestCase("remote plugins: un plugin que falta da el error con el comando para instalarlo") {
            let (ssh, host, _, _) = try await verifiedFake()
            defer { ssh.remove() }
            let error = try await expectThrows { _ = try await RemotePlugins.locate(skills: ["superpowers:receiving-code-review"], host: host) }
            try expectEqual(error as? RemoteRunnerError, .pluginMissing(host: "devbox", plugin: "superpowers", skill: "superpowers:receiving-code-review"))
            try expect(error.localizedDescription.contains("/plugin install superpowers"))
        },
    ]
}
```

- [ ] **Step 2:** build → falla.

- [ ] **Step 3: `Sources/PRBarCore/RemotePlugins.swift`:**

```swift
import Foundation

/// `--plugin-dir` del host (decisión J.7.20): para cada plugin de los skills elegidos, el subdirectorio modificado
/// más recientemente de `~/.claude/plugins/cache/<marketplace>/<plugin>/` (en cualquier marketplace) que tenga
/// `.claude-plugin`, `skills`, `commands` o `agents` — la misma regla que `ClaudePlugins` en la Mac.
public enum RemotePlugins {
    public static func locate(skills: [String], host: SSHHost) async throws -> [String] {
        var plugins: [(plugin: String, skill: String)] = []
        for skill in skills {
            guard let plugin = ClaudeSettings.plugin(of: skill), !plugins.contains(where: { $0.plugin == plugin }) else { continue }
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
```

> `ClaudeSettings.plugin(of:)` es el helper que usa `ClaudePlugins.locate` (valida la gramática de skills de §8.0: el nombre del plugin solo tiene `[A-Za-z0-9._-]`).

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "remote plugins"` → `2/2 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/RemotePlugins.swift Sources/PRBarTests/RemotePluginsTests.swift Sources/PRBarTests/main.swift
git commit -m "Find Claude plugins on the host with the same rule as on the Mac"
```

---

### Task 10: El guardián en el host — `WorkspaceFS`, script Perl y tests de paridad

**Files:**
- Create: `Sources/PRBarCore/WorkspaceFS.swift`
- Modify: `Sources/PRBarCore/WorktreeIntegrity.swift` (`Snapshot.Entry` público), `Sources/PRBarCore/FixImplementer.swift` (`GitPaths.addTree`/`addModules` y `describe` sin `private`), `Sources/PRBarCore/WorktreeManager.swift` (`neutralizeSymlink` sin `private`)
- Test: `Sources/PRBarTests/WorkspaceFSParityTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests de paridad que fallan.** El mismo árbol, leído por la implementación local y por el script Perl corrido **localmente** (`RemoteWorkspaceFS.local()`), tiene que dar lo mismo:

```swift
import Foundation
import PRBarCore

/// Un worktree con todo lo que mira el guardián: archivos, carpetas, nombre NFD, metadatos de macOS, symlinks, `.git`
/// anidados (carpeta y archivo), y un `.git` de arriba con config, hooks, info y módulos.
private func makeTree() throws -> URL {
    let root = try temporaryDirectory().resolvingSymlinksInPath().appendingPathComponent("wt")
    let files = FileManager.default
    func put(_ path: String, _ text: String, mode: Int = 0o644) throws {
        let url = root.appendingPathComponent(path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
    try put("a.txt", "a\n")
    try put("dir/b.txt", "bb\n")
    try put("e\u{0301}.txt", "nfd\n")
    try put(".DS_Store", "x")
    try put("dir/._b.txt", "x")
    try put("sub/.git/config", "[core]\n")
    try put("sub2/.git", "gitdir: /elsewhere\n")
    try put(".git/config", "[include]\n\tpath = extra.conf\n")
    try put(".git/extra.conf", "[user]\n")
    try put(".git/hooks/pre-commit", "#!/bin/sh\n", mode: 0o755)
    try put(".git/info/exclude", "*.log\n")
    try put(".git/modules/m/config", "[core]\n")
    try put(".git/modules/m/hooks/h", "#!/bin/sh\n", mode: 0o755)
    try put(".git/modules/m/objects/x", "obj")
    try files.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "../outside/secret")
    try files.createSymbolicLink(atPath: root.appendingPathComponent("dir/inner").path, withDestinationPath: "b.txt")
    return root
}

enum WorkspaceFSParityTests {
    static let cases: [TestCase] = [
        TestCase("guardián perl = guardián local: snapshot, .git anidados, describe, árboles, módulos y lectura") {
            let root = try makeTree()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let local = LocalWorkspaceFS()
            let perl = RemoteWorkspaceFS.local()
            let a = try await local.snapshot(root.path)
            let b = try await perl.snapshot(root.path)
            try expectEqual(Set(a.entries.keys), Set(b.entries.keys))
            for (key, entry) in a.entries {
                let other = b.entries[key]!
                try expect(entry.type == other.type && entry.size == other.size && entry.inode == other.inode, key)
                try expect(abs(entry.modified - other.modified) < 2_000, "\(key): \(entry.modified) vs \(other.modified)")
            }
            let nestedLocal = try await local.nestedGitEntries(root.path)
            let nestedPerl = try await perl.nestedGitEntries(root.path)
            try expectEqual(nestedPerl, nestedLocal)
            let git = root.appendingPathComponent(".git").path
            let paths = [git, git + "/config", git + "/missing", root.appendingPathComponent("link").path, root.path]
            let describeLocal = try await local.describe(paths)
            let describePerl = try await perl.describe(paths)
            try expectEqual(describePerl, describeLocal)
            let treesLocal = try await local.describeTrees([git + "/hooks", git + "/info"])
            let treesPerl = try await perl.describeTrees([git + "/hooks", git + "/info"])
            try expectEqual(treesPerl, treesLocal)
            let modulesLocal = try await local.modules(git + "/modules")
            let modulesPerl = try await perl.modules(git + "/modules")
            try expectEqual(modulesPerl.entries, modulesLocal.entries)
            try expectEqual(modulesPerl.configs.sorted(), modulesLocal.configs.sorted())
            let textLocal = try await local.readText(git + "/config", limit: 1 << 20)
            let textPerl = try await perl.readText(git + "/config", limit: 1 << 20)
            try expectEqual(textPerl, textLocal)
            let noneLocal = try await local.readText(git + "/nope", limit: 1 << 20)
            let nonePerl = try await perl.readText(git + "/nope", limit: 1 << 20)
            try expectEqual(nonePerl, noneLocal)
        },
        TestCase("guardián perl = guardián local: neutralizar symlinks y borrar lo que creó Claude, confinado") {
            let one = try makeTree()
            let two = try makeTree()
            defer {
                try? FileManager.default.removeItem(at: one.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: two.deletingLastPathComponent())
            }
            try await LocalWorkspaceFS().neutralizeSymlinks(["link", "dir/inner", "missing"], in: one.path)
            try await RemoteWorkspaceFS.local().neutralizeSymlinks(["link", "dir/inner", "missing"], in: two.path)
            for path in ["link", "dir/inner"] {
                let left = try String(contentsOf: one.appendingPathComponent(path), encoding: .utf8)
                let right = try String(contentsOf: two.appendingPathComponent(path), encoding: .utf8)
                try expectEqual(right, left)
                try expect(left.hasPrefix("[symlink to "))
            }
            for fs: any WorkspaceFS in [LocalWorkspaceFS(), RemoteWorkspaceFS.local()] {
                let tree = fs is LocalWorkspaceFS ? one : two
                try Data("new".utf8).write(to: tree.appendingPathComponent("dir/created.tmp"))
                try await fs.removeCreatedFile("dir/created.tmp", in: tree.path)
                try expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("dir/created.tmp").path))
                for evil in ["../outside", "/etc/hosts", "dir/../../x", "", "dir//x"] {
                    _ = try await expectThrows { try await fs.removeCreatedFile(evil, in: tree.path) }
                }
                _ = try await expectThrows { try await fs.neutralizeSymlinks(["../escape"], in: tree.path) }
            }
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'LocalWorkspaceFS'`.

- [ ] **Step 3: Visibilidad.**
  - `WorktreeIntegrity.Snapshot.Entry`: `public let type`, `public let size`, `public let modified`, `public let inode` y `public init(type: UInt16, size: Int64, modified: Int64, inode: UInt64)`; `Snapshot` gana `public init(entries: [String: Entry])`.
  - `FixImplementer.GitPaths.addTree`/`addModules`/`walk`: `private static` → `static`.
  - `WorktreeManager.neutralizeSymlink(at:in:)`: `private static` → `static`.

- [ ] **Step 4: `Sources/PRBarCore/WorkspaceFS.swift`:**

```swift
import CryptoKit
import Foundation

/// Lo que el guardián de integridad lee o toca del disco donde vive el worktree (§14.6, decisión J.7.8). Las rutas son
/// absolutas en esa máquina. La lógica (qué es un cambio y qué corta) está en `FixImplementer`/`WorktreeIntegrity`,
/// igual para las dos implementaciones.
public protocol WorkspaceFS: Sendable {
    /// El `HOME` de esa máquina (para `~/` en los `include.path` de git).
    var home: String { get }
    func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot
    func nestedGitEntries(_ root: String) async throws -> [String]
    /// `GitPaths.describe` de cada ruta.
    func describe(_ paths: [String]) async throws -> [String: String]
    /// Cada raíz y todo lo de adentro (sin seguir symlinks ni mirar metadatos de macOS), descriptos.
    func describeTrees(_ roots: [String]) async throws -> [String: String]
    /// `GitPaths.addModules`: lo descripto y los `config` encontrados.
    func modules(_ root: String) async throws -> (entries: [String: String], configs: [String])
    /// El texto de un archivo regular de hasta `limit` bytes (sigue symlinks, como `FileManager.contents`), o nil.
    func readText(_ path: String, limit: Int) async throws -> String?
    func removeCreatedFile(_ relative: String, in root: String) async throws
    func neutralizeSymlinks(_ relatives: [String], in root: String) async throws
}

public struct LocalWorkspaceFS: WorkspaceFS {
    public init() {}

    public var home: String { NSHomeDirectory() }

    public func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot {
        .take(URL(fileURLWithPath: root, isDirectory: true))
    }

    public func nestedGitEntries(_ root: String) async throws -> [String] {
        WorktreeIntegrity.nestedGitEntries(in: URL(fileURLWithPath: root, isDirectory: true))
    }

    public func describe(_ paths: [String]) async throws -> [String: String] {
        Dictionary(paths.map { ($0, FixImplementer.GitPaths.describe($0)) }, uniquingKeysWith: { first, _ in first })
    }

    public func describeTrees(_ roots: [String]) async throws -> [String: String] {
        var entries: [String: String] = [:]
        for root in roots { FixImplementer.GitPaths.addTree(root, to: &entries) }
        return entries
    }

    public func modules(_ root: String) async throws -> (entries: [String: String], configs: [String]) {
        var entries: [String: String] = [:]
        var configs: [String] = []
        FixImplementer.GitPaths.addModules(root, to: &entries, configs: &configs)
        return (entries, configs)
    }

    public func readText(_ path: String, limit: Int) async throws -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func removeCreatedFile(_ relative: String, in root: String) async throws {
        try FixImplementer.removeCreatedFile(relative, in: URL(fileURLWithPath: root, isDirectory: true))
    }

    public func neutralizeSymlinks(_ relatives: [String], in root: String) async throws {
        for path in relatives { try WorktreeManager.neutralizeSymlink(at: path, in: URL(fileURLWithPath: root, isDirectory: true)) }
    }
}

/// El guardián en otra máquina: el script Perl de `RemoteGuard` recolecta y este tipo arma los mismos valores que
/// `LocalWorkspaceFS`. Cada registro de la salida son tres campos terminados en NUL: `tipo`, `a`, `b`.
public struct RemoteWorkspaceFS: WorkspaceFS {
    public typealias GuardRunner = @Sendable (_ arguments: [String]) async throws -> ProcessResult

    public let home: String
    let label: String
    let runGuard: GuardRunner

    public init(home: String, label: String, runGuard: @escaping GuardRunner) {
        self.home = home
        self.label = label
        self.runGuard = runGuard
    }

    /// Por ssh: `perl - <args>` con el guardián por stdin y `env -i` (sin `PERL5OPT`).
    public static func ssh(host: SSHHost, home: String) -> RemoteWorkspaceFS {
        RemoteWorkspaceFS(home: home, label: host.name) { arguments in
            let script = try RemoteGuard.localScriptFile()
            return try await host.run(RemoteExec(argv: ["perl", "-"] + arguments, environment: RemoteEnvironment.perl(),
                                                 standardInput: .passThrough), timeout: 300, standardInput: script)
        }
    }

    /// El mismo script corrido en la Mac (tests de paridad).
    public static func local(perl: String = "/usr/bin/perl") -> RemoteWorkspaceFS {
        RemoteWorkspaceFS(home: NSHomeDirectory(), label: "this Mac") { arguments in
            try await SystemProcessRunner().runWithFiles(perl, ["-"] + arguments, environment: ["PERL5OPT": ""], currentDirectory: nil,
                                                         timeout: 300, standardInput: try RemoteGuard.localScriptFile(),
                                                         standardOutput: nil, onStdoutLine: nil)
        }
    }

    func records(_ arguments: [String]) async throws -> [(String, String, String)] {
        let result = try await runGuard(arguments)
        guard result.status == 0 else {
            throw RemoteRunnerError.guardFailed(host: label, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var fields = result.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if fields.last == "" { fields.removeLast() }
        guard fields.count % 3 == 0 else { throw RemoteRunnerError.malformedOutput(host: label, what: "integrity check output") }
        return stride(from: 0, to: fields.count, by: 3).map { (fields[$0], fields[$0 + 1], fields[$0 + 2]) }
    }

    public func snapshot(_ root: String) async throws -> WorktreeIntegrity.Snapshot {
        var entries: [String: WorktreeIntegrity.Snapshot.Entry] = [:]
        for (kind, path, value) in try await records(["snapshot", root]) where kind == "S" {
            let parts = value.split(separator: " ")
            guard parts.count == 4, let type = UInt16(parts[0]), let size = Int64(parts[1]), let modified = Int64(parts[2]),
                  let inode = UInt64(parts[3]) else { throw RemoteRunnerError.malformedOutput(host: label, what: "file snapshot") }
            entries[path.precomposedStringWithCanonicalMapping] = .init(type: type, size: size, modified: modified, inode: inode)
        }
        return WorktreeIntegrity.Snapshot(entries: entries)
    }

    public func nestedGitEntries(_ root: String) async throws -> [String] {
        try await records(["nested", root]).filter { $0.0 == "N" }.map { $0.1.precomposedStringWithCanonicalMapping }.sorted()
    }

    private func pairs(_ arguments: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        for (kind, path, value) in try await records(arguments) where kind == "E" { result[path] = value }
        return result
    }

    public func describe(_ paths: [String]) async throws -> [String: String] {
        paths.isEmpty ? [:] : try await pairs(["describe"] + paths)
    }

    public func describeTrees(_ roots: [String]) async throws -> [String: String] {
        roots.isEmpty ? [:] : try await pairs(["tree"] + roots)
    }

    public func modules(_ root: String) async throws -> (entries: [String: String], configs: [String]) {
        var entries: [String: String] = [:]
        var configs: [String] = []
        for (kind, path, value) in try await records(["modules", root]) {
            if kind == "E" { entries[path] = value }
            if kind == "C" { configs.append(path) }
        }
        return (entries, configs)
    }

    public func readText(_ path: String, limit: Int) async throws -> String? {
        guard let record = try await records(["read", path, String(limit)]).first(where: { $0.0 == "R" }), record.1 == "ok" else { return nil }
        guard let data = Data(hex: record.2) else { throw RemoteRunnerError.malformedOutput(host: label, what: "file contents") }
        return String(decoding: data, as: UTF8.self)
    }

    public func removeCreatedFile(_ relative: String, in root: String) async throws {
        _ = try await records(["rmcreated", root, relative])
    }

    public func neutralizeSymlinks(_ relatives: [String], in root: String) async throws {
        guard !relatives.isEmpty else { return }
        _ = try await records(["neutralize", root, WorktreeManager.symlinkPlaceholder(target: "{target}")] + relatives)
    }
}

extension Data {
    /// Hex en minúscula o mayúscula; `nil` si no es hex.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

/// El guardián en Perl (decisión J.7.8). Solo recolecta; no decide nada. Se manda entero por stdin en cada llamada.
public enum RemoteGuard {
    public static let script = #"""
    use strict;
    use warnings;
    use Fcntl qw(:mode O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
    use Digest::SHA ();
    use Time::HiRes ();
    use Cwd ();
    binmode(STDOUT);

    sub out { print join("\0", $_[0], $_[1], defined $_[2] ? $_[2] : ''), "\0"; }
    sub mac_meta { my ($n) = @_; return $n eq '.DS_Store' || substr($n, 0, 2) eq '._' || $n eq "Icon\r"; }
    sub utf8_ok { my ($s) = @_; my $c = $s; return utf8::decode($c); }
    sub entries {
        my ($dir) = @_;
        opendir(my $h, $dir) or return ();
        my @names = grep { $_ ne '.' && $_ ne '..' } readdir($h);
        closedir($h);
        return @names;
    }
    sub bad_relative {
        my ($rel) = @_;
        return 1 if $rel eq '' || substr($rel, 0, 1) eq '/';
        return scalar(grep { $_ eq '' || $_ eq '.' || $_ eq '..' } split(m{/}, $rel, -1));
    }
    sub describe {
        my ($p) = @_;
        my @st = lstat($p);
        return 'none' unless @st;
        my $mode = sprintf('%o', $st[2] & 07777);
        if (S_ISLNK($st[2])) { my $t = readlink($p); return 'link:' . (defined $t ? $t : '?'); }
        return "dir:$mode" if S_ISDIR($st[2]);
        if (S_ISREG($st[2])) {
            open(my $fh, '<:raw', $p) or return "file:$mode:unreadable:$st[7]";
            my $sha = Digest::SHA->new(256);
            $sha->addfile($fh);
            close($fh);
            return "file:$mode:" . $sha->hexdigest;
        }
        return 'other:' . $st[2];
    }
    sub tree {
        my ($root) = @_;
        out('E', $root, describe($root));
        my @stack = ($root);
        while (@stack) {
            my $dir = pop @stack;
            for my $name (entries($dir)) {
                next if mac_meta($name);
                my $path = "$dir/$name";
                my @st = lstat($path) or next;
                out('E', $path, describe($path));
                push @stack, $path if S_ISDIR($st[2]);
            }
        }
    }
    sub walk_worktree {
        my ($mode, $root) = @_;
        my @stack = ('');
        while (@stack) {
            my $rel = pop @stack;
            my $dir = $rel eq '' ? $root : "$root/$rel";
            for my $name (entries($dir)) {
                next if $rel eq '' && $name eq '.git';
                my $child = $rel eq '' ? $name : "$rel/$name";
                die "a file name isn't valid UTF-8\n" unless utf8_ok($child);
                my @st = Time::HiRes::lstat("$root/$child");
                next unless @st;
                my $is_dir = S_ISDIR($st[2]);
                if ($mode eq 'nested') { out('N', $child, '') if $name eq '.git'; }
                elsif (!$is_dir) { out('S', $child, join(' ', $st[2] & S_IFMT, $st[7], sprintf('%.0f', $st[9] * 1e9), $st[1])); }
                push @stack, $child if $is_dir;
            }
        }
    }
    sub modules {
        my ($root) = @_;
        my %skip = map { $_ => 1 } qw(objects refs logs lfs rr-cache worktrees);
        my @stack = ($root);
        while (@stack) {
            my $dir = pop @stack;
            for my $name (entries($dir)) {
                next if mac_meta($name);
                my $path = "$dir/$name";
                my @st = lstat($path) or next;
                if (S_ISDIR($st[2])) {
                    if ($name eq 'hooks') { tree($path); next; }
                    push @stack, $path unless $skip{$name};
                    next;
                }
                if ($name eq 'config' || $name eq 'config.worktree') { out('E', $path, describe($path)); out('C', $path, ''); }
            }
        }
    }
    sub read_text {
        my ($path, $limit) = @_;
        my @st = stat($path);
        if (!@st || !S_ISREG($st[2]) || $st[7] > $limit) { out('R', 'none', ''); return; }
        open(my $fh, '<:raw', $path) or do { out('R', 'none', ''); return; };
        local $/;
        my $data = <$fh>;
        close($fh);
        out('R', 'ok', unpack('H*', defined $data ? $data : ''));
    }
    sub inside {
        my ($real_root, $rel, $root) = @_;
        my ($parent, $name) = $rel =~ m{^(?:(.*)/)?([^/]+)$} or return ();
        my $real_parent = Cwd::realpath(defined $parent ? "$root/$parent" : $root);
        return ('missing', $name) unless defined $real_parent;
        return () unless $real_parent eq $real_root || index($real_parent, "$real_root/") == 0;
        return ($real_parent, $name);
    }
    sub rm_created {
        my ($root, $rel) = @_;
        die "Invalid path in the worktree: $rel\n" if bad_relative($rel);
        my $real_root = Cwd::realpath($root) // die "can't resolve the worktree\n";
        my ($parent, $name) = inside($real_root, $rel, $root);
        die "$rel is outside the worktree: not deleting it.\n" unless defined $parent;
        return if $parent eq 'missing';
        unlink("$parent/$name") or $!{ENOENT} or die "Couldn't delete $rel, which Claude created: $!\n";
    }
    sub neutralize {
        my ($root, $template, @rels) = @_;
        my $real_root = Cwd::realpath($root) // die "can't resolve the worktree\n";
        for my $rel (@rels) {
            die "invalid path in the PR: $rel\n" if bad_relative($rel);
            my ($parent, $name) = inside($real_root, $rel, $root);
            die "the symlink $rel is outside the worktree\n" unless defined $parent;
            next if $parent eq 'missing' && utf8_ok($rel);
            my $full = "$parent/$name";
            my @st = lstat($full);
            unless (@st) { next if $!{ENOENT} && utf8_ok($rel); die "couldn't read $rel: $!\n"; }
            next unless S_ISLNK($st[2]);
            my $target = readlink($full);
            $target = '?' unless defined $target;
            unlink($full) or die "couldn't delete the symlink $rel: $!\n";
            sysopen(my $fh, $full, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644) or die "couldn't replace the symlink $rel: $!\n";
            my $text = $template;
            my $at = index($text, '{target}');
            substr($text, $at, 8) = $target if $at >= 0;
            binmode($fh);
            print {$fh} $text or die "couldn't write the replacement for $rel\n";
            close($fh) or die "couldn't write the replacement for $rel\n";
            out('X', $rel, '');
        }
    }

    my $cmd = shift(@ARGV) // '';
    my $ok = eval {
        if ($cmd eq 'snapshot' || $cmd eq 'nested') { walk_worktree($cmd, $ARGV[0]); }
        elsif ($cmd eq 'describe') { out('E', $_, describe($_)) for @ARGV; }
        elsif ($cmd eq 'tree') { tree($_) for @ARGV; }
        elsif ($cmd eq 'modules') { modules($ARGV[0]); }
        elsif ($cmd eq 'read') { read_text(@ARGV); }
        elsif ($cmd eq 'rmcreated') { rm_created(@ARGV); }
        elsif ($cmd eq 'neutralize') { neutralize(@ARGV); }
        else { die "unknown command\n"; }
        1;
    };
    unless ($ok) { print STDERR $@; exit 3; }
    exit 0;
    """#

    /// El script en un archivo local 0600 (nombre por su SHA-256), para mandarlo por stdin.
    public static func localScriptFile() throws -> URL {
        let digest = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = LocalScratch.directory.appendingPathComponent("guard-\(digest.prefix(16)).pl")
        if let existing = FileManager.default.contents(atPath: url.path), existing == Data(script.utf8) { return url }
        let temp = try LocalScratch.file(with: Data(script.utf8))
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
        return url
    }
}
```

> Detalles que el test de paridad cubre: el walk de snapshot/nested **no** saltea metadatos de macOS y sí entra en `.git` anidados (como `WorktreeIntegrity.walk`); el de árboles y módulos sí los saltea (como `GitPaths.walk`); `describe` da `other:<st_mode decimal>` y los permisos en octal sin cero adelante; `readText` sigue symlinks (como `FileManager.contents`). Si el test de paridad marca una diferencia, se corrige **el script Perl**, nunca la versión local.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests "guardián perl"` → `2/2 passed`.

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore/WorkspaceFS.swift Sources/PRBarCore/WorktreeIntegrity.swift Sources/PRBarCore/FixImplementer.swift Sources/PRBarCore/WorktreeManager.swift Sources/PRBarTests/WorkspaceFSParityTests.swift Sources/PRBarTests/main.swift
git commit -m "Port the integrity guard's file checks to a Perl collector with parity tests"
```

---

### Task 11: `FixImplementer` usa `WorkspaceFS` (y la suite de integridad corre también con el guardián Perl)

**Files:**
- Modify: `Sources/PRBarCore/FixImplementer.swift`, `Sources/PRBarCore/RespondPublisher.swift`, `Sources/PRBarCore/RespondPipeline.swift`
- Modify: `Sources/PRBarTests/FixImplementerTests.swift`

- [ ] **Step 1: Test que falla.** En `FixImplementerTests.swift`:
  - arriba del archivo: `nonisolated(unsafe) var fixImplementerFS: any WorkspaceFS = LocalWorkspaceFS()`;
  - el helper `implementer(…)` pasa `fs: fixImplementerFS` al `init` de `FixImplementer`;
  - al final de `cases`:

```swift
        TestCase("fix implementer: la suite de integridad pasa igual con el guardián Perl") {
            let integrity = ["C2", "C3", "I4", "I5", "toca .git", "config, hooks, info", "Finder", ".DS_Store", "symlink o un gitlink"]
            let selected = FixImplementerTests.cases.filter { test in
                test.name != "fix implementer: la suite de integridad pasa igual con el guardián Perl"
                    && integrity.contains { test.name.contains($0) }
            }
            try expect(selected.count >= 9, "solo \(selected.count) casos")
            fixImplementerFS = RemoteWorkspaceFS.local()
            defer { fixImplementerFS = LocalWorkspaceFS() }
            for test in selected {
                do { try await test.body() } catch { throw TestFailure(description: "\(test.name) con el guardián Perl: \(error)") }
            }
        },
```

  > `cases` es un `static let`: el caso se refiere a `FixImplementerTests.cases` de forma perezosa dentro de su cuerpo, así que compila. Si el compilador se queja de la autorreferencia, mover la lista a `static var integrityCases: [TestCase]` y que `cases` sea `integrityCases + otros`.

- [ ] **Step 2:** `swift build --product PRBarTests` → falla (`extra argument 'fs'`).

- [ ] **Step 3: Refactor** (el comportamiento local no cambia). En `FixImplementer`:
  - propiedad `private let fs: any WorkspaceFS` y en el `init`, al final, `fs: any WorkspaceFS = LocalWorkspaceFS()`; además `testShell: String = "/bin/zsh"` y `testRunner: ProcessRunning? = nil` (los usa `runTests`: `runner` → `testRunner ?? runner`, `"/bin/zsh"` → `testShell`).
  - `GitPaths.fingerprint()` pasa a:

```swift
        func fingerprint(using fs: any WorkspaceFS) async throws -> [String: String] {
            var files = [dotGit, commonDir] + Self.commonFiles.map { Self.join(commonDir, $0) }
            var trees = Self.commonTrees.map { Self.join(commonDir, $0) }
            if let adminDir {
                files += [adminDir] + Self.adminFiles.map { Self.join(adminDir, $0) }
                trees += Self.adminTrees.map { Self.join(adminDir, $0) }
            }
            var entries = try await fs.describe(files)
            entries.merge(try await fs.describeTrees(trees)) { _, new in new }
            let modules = try await fs.modules(Self.join(commonDir, "modules"))
            entries.merge(modules.entries) { _, new in new }
            var configs = ["config", "config.worktree"].map { Self.join(commonDir, $0) } + modules.configs
            if let adminDir { configs.append(Self.join(adminDir, "config.worktree")) }
            // Los includes que caen dentro de las carpetas de git (y los includes de esos, sin ciclos).
            let roots = [commonDir] + (adminDir.map { [$0] } ?? [])
            var seen = Set(configs)
            while let config = configs.popLast() {
                let text = try await fs.readText(config, limit: 1 << 20)
                for target in Self.includedPaths(text: text, configPath: config, home: fs.home) where !seen.contains(target) {
                    seen.insert(target)
                    guard roots.contains(where: { target.hasPrefix($0 + "/") }) else { continue }
                    entries.merge(try await fs.describe([target])) { _, new in new }
                    configs.append(target)
                }
            }
            return entries
        }

        func securityDigest(using fs: any WorkspaceFS) async throws -> String {
            var entries = try await fingerprint(using: fs)
            if let adminDir { entries[Self.join(adminDir, "HEAD")] = nil }
            let text = entries.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        /// Como antes `includedPaths(ofConfigAt:)`, con el texto ya leído y el `HOME` de esa máquina.
        static func includedPaths(text: String?, configPath: String, home: String) -> [String] {
            guard let text else { return [] }
            let base = (configPath as NSString).deletingLastPathComponent
            return includeValues(in: text).map { value in
                let expanded = value.hasPrefix("~/") ? home + String(value.dropFirst(1)) : value
                return normalize(expanded.hasPrefix("/") ? expanded : join(base, expanded))
            }
        }
```
    (borrar `includedPaths(ofConfigAt:)`; `normalize` y `join` pasan de `private` a internos si hace falta).
  - Reemplazos en `FixImplementer` (todas las llamadas, incluidas las de `chatTurn`/`undoChatTurn`/`chatFilesChangedSince`/`snapshotTree`):
    - `try Self.checkNoNestedGit(worktree, allowed: X)` → `try await checkNoNestedGit(worktree, allowed: X)` con

```swift
    func checkNoNestedGit(_ worktree: URL, allowed: Set<String>) async throws {
        let nested = try await fs.nestedGitEntries(worktree.path).filter { !allowed.contains($0) }
        guard nested.isEmpty else {
            throw PRBarError.respond(
                "A nested .git appeared in the worktree (\(nested.prefix(3).joined(separator: ", "))): "
                + "any git command could run its configuration. Stopped without running git. Check the worktree \(worktree.path).")
        }
    }
```
      (el `static func checkNoNestedGit` queda, para `RespondPublisher`, que es solo local);
    - `Set(WorktreeIntegrity.nestedGitEntries(in: worktree))` → `Set(try await fs.nestedGitEntries(worktree.path))`;
    - `WorktreeIntegrity.Snapshot.take(worktree)` → `try await fs.snapshot(worktree.path)`;
    - `guarded.fingerprint()` → `try await guarded.fingerprint(using: fs)`; `guarded.securityDigest()` → `try await guarded.securityDigest(using: fs)`;
    - `checkGitUntouched(_:before:worktree:)` e `checkIntegrity(_:expected:worktree:)` pasan a `async throws` y usan esas dos;
    - `try Self.removeCreatedFile(path, in: worktree)` → `try await fs.removeCreatedFile(path, in: worktree.path)`.
  - `RespondPublisher.integrity(of:)`: `return try await FixImplementer.GitPaths.parse(output, worktree: worktree).securityDigest(using: LocalWorkspaceFS())`.
  - `RespondPipeline.cancellation(of:)`: `WorktreeIntegrity.nestedGitEntries(in: worktree).isEmpty` → `((try? await fs.nestedGitEntries(worktree.path)) ?? ["?"]).isEmpty`, con `fs` = el del pipeline (`LocalWorkspaceFS()` hasta la Task 14).

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "fix implementer"` → todos `passed`, incluido el nuevo. `swift run PRBarTests respond` sigue verde.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore Sources/PRBarTests/FixImplementerTests.swift
git commit -m "Route the integrity guard's file reads through WorkspaceFS"
```

---

### Task 12: Repos y worktrees en el host (`RemoteWorkspaces`) y contexto subido (`ContextFiles`)

**Files:**
- Create: `Sources/PRBarCore/RemoteWorkspaces.swift`
- Modify: `Sources/PRBarCore/ReviewContext.swift`, `Sources/PRBarCore/RespondAnalyzer.swift`
- Test: `Sources/PRBarTests/RemoteWorkspacesTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.** El "GitHub" es `TempGitRepo.origin` (una carpeta local), así que `remoteURLs` y `originMatches` se reemplazan:

```swift
import Foundation
import PRBarCore

func remoteWorkspaces(_ host: SSHHost, _ info: RunnerHostInfo, _ root: RemoteRoot, origin: URL,
                      extraURLs: [String] = []) -> RemoteWorkspaces {
    RemoteWorkspaces(host: host, root: root, gitPath: info.gitPath!,
                     runner: RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories),
                     fs: RemoteWorkspaceFS.ssh(host: host, home: (root.path as NSString).deletingLastPathComponent),
                     gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                      "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
                                      "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid"],
                     remoteURLs: { _ in extraURLs + [origin.path] }, originMatches: { _, _ in true })
}

enum RemoteWorkspacesTests {
    static let cases: [TestCase] = [
        TestCase("remote workspaces: mirror propio, worktree del PR con refs propias, symlinks neutralizados, contexto subido; limpieza") {
            let repo = try TempGitRepo.make { origin in
                try FileManager.default.createSymbolicLink(atPath: origin.appendingPathComponent("evil").path, withDestinationPath: "/etc/passwd")
            }
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin, extraURLs: ["/nonexistent/first-url-fails"])
            let gitHubRepo = RepoRef(owner: "o", name: "r")
            let bare = try await spaces.mirror(gitHubRepo)
            try expectEqual(bare, try root.child(["repos", "o", "r.git"]))
            let workspace = try await spaces.prepare(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare, name: nil, pinnedHeadOid: nil)
            try expectEqual(workspace.headOid, repo.prSHA)
            try expect(root.contains(workspace.directory.path) && workspace.directory.path.hasPrefix(root.work + "/"))
            let evil = try String(contentsOf: workspace.directory.appendingPathComponent("evil"), encoding: .utf8)
            try expect(evil.hasPrefix("[symlink to /etc/passwd omitted by PRBar]"), evil)
            let writer = ReviewContextWriter(runner: spaces.runner, gitPath: info.gitPath!, ghPath: nil, files: spaces.contextFiles)
            let pr = makePR(repo: gitHubRepo, number: 7, base: "main")
            _ = try await writer.write(pr: pr, workspace: workspace, token: "ghp_never_sent", description: "Desc")
            let diff = try String(contentsOf: workspace.diffFile, encoding: .utf8)
            try expect(diff.contains("feature.txt"))
            let invocationsText = ssh.invocations().flatMap { $0 }.joined(separator: " ")
            try expect(!invocationsText.contains("ghp_never_sent"))
            await spaces.cleanup(workspace, localPath: bare)
            try expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
            try expect(!FileManager.default.fileExists(atPath: workspace.contextDirectory.path))
            let refs = try TempGitRepo.run(URL(fileURLWithPath: bare), ["for-each-ref", "refs/prbar/"])
            try expectEqual(refs, "")
            try expect(FileManager.default.fileExists(atPath: bare))
        },
        TestCase("remote workspaces: worktree de Respond desde la rama y limpieza; nombre de rama hostil rechazado") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            let (worktree, start) = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7,
                                                                    headRef: "feature", worktreeDir: nil, runID: "0a0b0c0d")
            try expectEqual(start, repo.prSHA)
            try expectEqual(worktree.path, try root.child(["work", "r-7-respond-0a0b0c0d"]))
            try expectEqual(worktree.localPath, bare)
            for hostile in ["$(touch PWNED)", "-x", "a..b", "a b"] {
                _ = try await expectThrows {
                    _ = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7, headRef: hostile,
                                                        worktreeDir: nil, runID: "0e0e0e0e")
                }
            }
            try expect(!FileManager.default.fileExists(atPath: ssh.home.appendingPathComponent("PWNED").path))
            await spaces.cleanupRespond(worktree)
            try expect(!FileManager.default.fileExists(atPath: worktree.path))
        },
        TestCase("remote workspaces: si el host no puede fetchear, el error lo dice") {
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = RemoteWorkspaces(host: host, root: root, gitPath: info.gitPath!,
                                          runner: RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories),
                                          fs: RemoteWorkspaceFS.ssh(host: host, home: ssh.home.path),
                                          remoteURLs: { _ in ["/nonexistent/repo.git"] }, originMatches: { _, _ in true })
            let error = try await expectThrows {
                let bare = try await spaces.mirror(RepoRef(owner: "acme", name: "api"))
                _ = try await spaces.prepare(repo: RepoRef(owner: "acme", name: "api"), number: 1, baseRef: "main", localPath: bare,
                                             name: nil, pinnedHeadOid: nil)
            }
            try expectEqual(error.localizedDescription, "devbox can't fetch acme/api — set up git access on the server.")
        },
        TestCase("remote workspaces: al arrancar se limpian huérfanos solo dentro de la raíz; los mirrors quedan") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
            let workspace = try await spaces.prepare(repo: RepoRef(owner: "o", name: "r"), number: 7, baseRef: "main", localPath: bare,
                                                     name: nil, pinnedHeadOid: nil)
            let outside = ssh.home.appendingPathComponent("my-own-stuff")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: root.tmp).appendingPathComponent("leftover.stdin"))
            await spaces.cleanupOrphans()
            try expect(!FileManager.default.fileExists(atPath: workspace.directory.path))
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.tmp), [])
            try expect(FileManager.default.fileExists(atPath: bare) && FileManager.default.fileExists(atPath: outside.path))
            let worktrees = try TempGitRepo.run(URL(fileURLWithPath: bare), ["worktree", "list", "--porcelain"])
            try expect(!worktrees.contains(root.work), worktrees)
        },
    ]
}
```

- [ ] **Step 2:** build → falla.

- [ ] **Step 3: `ContextFiles`** (al principio de `RemoteWorkspaces.swift`) y su uso en `ReviewContextWriter`/`RespondAnalyzer`:

```swift
import Foundation

/// Dónde se escriben la carpeta de contexto y sus archivos (`pr.diff`, `pr.md`, `feedback.json`). PRBar genera el
/// contenido igual que siempre (fences, neutralización); acá solo cambia dónde queda.
public protocol ContextFiles: Sendable {
    func createDirectory(_ path: String) async throws
    func write(_ data: Data, to path: String) async throws
    func removeTree(_ path: String) async
    func exists(_ path: String) async -> Bool
}

public struct LocalContextFiles: ContextFiles {
    public init() {}
    public func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    public func write(_ data: Data, to path: String) async throws { try data.write(to: URL(fileURLWithPath: path)) }
    public func removeTree(_ path: String) async { try? FileManager.default.removeItem(atPath: path) }
    public func exists(_ path: String) async -> Bool { FileManager.default.fileExists(atPath: path) }
}

public struct RemoteContextFiles: ContextFiles {
    let host: SSHHost
    let root: RemoteRoot

    public func createDirectory(_ path: String) async throws {
        guard root.isRemovable(path) else { throw RemoteRunnerError.outsideRoot(path) }
        try host.checked(try await host.runScript("umask 077 && mkdir -p -- \(try ShellQuote.posix(path))", timeout: 30), "mkdir")
    }
    public func write(_ data: Data, to path: String) async throws { try await host.upload(data, to: path, root: root) }
    public func removeTree(_ path: String) async { try? await host.removeTree(path, root: root) }
    public func exists(_ path: String) async -> Bool {
        guard root.contains(path), let quoted = try? ShellQuote.posix(path) else { return false }
        return (try? await host.runScript("[ -e \(quoted) ]", timeout: 30).status) == 0
    }
}
```

  - `ReviewContextWriter`: propiedad `let files: any ContextFiles` y `init(runner:gitPath:ghPath:files: any ContextFiles = LocalContextFiles())`. En `write`: `try FileManager.default.createDirectory(at: workspace.contextDirectory, …)` → `try await files.createDirectory(workspace.contextDirectory.path)`; `try Data(diff.utf8).write(to: workspace.diffFile)` → `try await files.write(Data(diff.utf8), to: workspace.diffFile.path)`; igual para `metadataFile`.
  - `RespondAnalyzer`: `init(claude:settings:rules:files: any ContextFiles = LocalContextFiles())` (y el `init(claude:skill:)` pasa `LocalContextFiles()`); en `analyze`, las tres operaciones de archivos (`createDirectory`, `feedbackFile`, `metadataFile`) pasan por `files`.

- [ ] **Step 4: `RemoteWorkspaces`** (mismo archivo):

```swift
/// Repos y worktrees en el host (spec J.3, decisiones J.7.7 y J.7.16). Los mismos refs (`refs/prbar/*`), el mismo
/// `GitHardening` y la misma neutralización de symlinks que en la Mac; el "clone" es un mirror bare propio de PRBar.
public struct RemoteWorkspaces: Sendable {
    public let host: SSHHost
    public let root: RemoteRoot
    public let gitPath: String
    public let runner: RemoteProcessRunner
    public let fs: RemoteWorkspaceFS
    public let gitEnvironment: [String: String]
    let remoteURLs: @Sendable (RepoRef) -> [String]
    let originMatches: @Sendable (String, RepoRef) -> Bool
    let runID: @Sendable () -> String
    let now: @Sendable () -> Date

    public init(host: SSHHost, root: RemoteRoot, gitPath: String, runner: RemoteProcessRunner, fs: RemoteWorkspaceFS,
                gitEnvironment: [String: String] = [:],
                remoteURLs: @escaping @Sendable (RepoRef) -> [String] = { ["https://github.com/\($0.fullName).git", "git@github.com:\($0.fullName).git"] },
                originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) },
                runID: @escaping @Sendable () -> String = WorktreeManager.newRunID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.host = host
        self.root = root
        self.gitPath = gitPath
        self.runner = runner
        self.fs = fs
        self.gitEnvironment = gitEnvironment.merging(GitHardening.environment) { _, forced in forced }
        self.remoteURLs = remoteURLs
        self.originMatches = originMatches
        self.runID = runID
        self.now = now
    }

    public var contextFiles: RemoteContextFiles { RemoteContextFiles(host: host, root: root) }

    // MARK: Git

    @discardableResult
    func git(_ path: String, _ arguments: [String], timeout: TimeInterval = WorktreeManager.slowTimeout) async throws -> String {
        guard root.contains(path) else { throw RemoteRunnerError.outsideRoot(path) }
        let result = try await runner.run(gitPath, GitHardening.arguments + ["-C", path] + arguments, environment: gitEnvironment,
                                          currentDirectory: nil, timeout: timeout)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "), status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    @discardableResult
    func gitLogged(_ path: String, _ arguments: [String]) async -> String? {
        do { return try await git(path, arguments) } catch {
            AppLog.write("Remote (\(host.name)): `git \(arguments.joined(separator: " "))` failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Mirror

    /// `<raíz>/repos/<owner>/<name>.git`, bare; lo crea la primera vez. El `origin` queda en la primera URL que fetchea.
    public func mirror(_ repo: RepoRef) async throws -> String {
        let bare = try root.child(["repos", repo.owner, repo.name + ".git"])
        let exists = (try? await host.runScript("[ -d \(try ShellQuote.posix(bare + "/objects")) ]", timeout: 30).status) == 0
        if !exists {
            try host.checked(try await host.runScript("umask 077 && mkdir -p -- \(try ShellQuote.posix(bare))", timeout: 30), "mkdir")
            let created = try await runner.run(gitPath, ["init", "--bare", "-q", bare], environment: gitEnvironment, currentDirectory: nil, timeout: 60)
            guard created.status == 0 else { throw RemoteRunnerError.cannotFetch(host: host.name, repo: repo.fullName) }
            try await git(bare, ["remote", "add", "origin", remoteURLs(repo).first ?? ""])
        }
        return bare
    }

    /// `fetch` con la URL de `origin`; si falla, prueba las otras y deja la que anduvo.
    func fetch(_ bare: String, repo: RepoRef, _ refspecs: [String]) async throws {
        let urls = remoteURLs(repo)
        let current = (try? await git(bare, ["remote", "get-url", "origin"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        for url in [current].compactMap({ $0 }) + urls.filter({ $0 != current }) {
            if url != current { try await git(bare, ["remote", "set-url", "origin", url]) }
            if (try? await git(bare, ["fetch", "--no-write-fetch-head", "--no-tags", "origin"] + refspecs)) != nil { return }
        }
        throw RemoteRunnerError.cannotFetch(host: host.name, repo: repo.fullName)
    }

    // MARK: Review y chat

    /// Como `WorktreeManager.prepare`, en el host. `localPath` es el mirror (`mirror(_:)`).
    public func prepare(repo: RepoRef, number: Int, baseRef: String, localPath: String?, name customName: String?,
                        pinnedHeadOid: String?) async throws -> ReviewWorkspace {
        guard let bare = localPath, root.contains(bare) else { throw RemoteRunnerError.outsideRoot(localPath ?? "") }
        if let customName {
            guard WorktreeManager.isChatWorkspaceName(customName), !customName.hasSuffix(".context"), !customName.hasSuffix("-diff") else {
                throw PRBarError.invalidResponse("Invalid chat workspace name: \(customName)")
            }
        }
        if let pinnedHeadOid, CommitSHA.parse(pinnedHeadOid) != pinnedHeadOid {
            throw PRBarError.invalidResponse("Invalid pinned commit: \(pinnedHeadOid.prefix(80))")
        }
        let id = runID()
        let name = customName ?? "\(repo.name)-\(number)-\(Int(now().timeIntervalSince1970))-\(id)"
        let directory = try root.child(["work", name])
        let prRef = WorktreeManager.prRef(number, id)
        let base = WorktreeManager.baseRef(number, id)
        let workspace = ReviewWorkspace(directory: URL(fileURLWithPath: directory, isDirectory: true), baseRef: base, prRef: prRef, isDiffOnly: false)
        do {
            try await fetch(bare, repo: repo, ["+pull/\(number)/head:\(prRef)", "+refs/heads/\(baseRef):\(base)"])
            guard var sha = CommitSHA.parse(try await git(bare, ["rev-parse", "--verify", "--quiet", "\(prRef)^{commit}"])) else {
                throw RemoteRunnerError.malformedOutput(host: host.name, what: "commit id")
            }
            if let pinned = pinnedHeadOid, pinned != sha, (try? await git(bare, ["cat-file", "-e", "\(pinned)^{commit}"])) != nil {
                try await git(bare, ["update-ref", prRef, pinned])
                sha = pinned
            }
            try await git(bare, ["worktree", "add", "--detach", directory, prRef])
            let listing = try await git(directory, ["ls-files", "-s", "-z"])
            try await fs.neutralizeSymlinks(WorktreeManager.symlinkPaths(fromLsFiles: listing), in: directory)
            return ReviewWorkspace(directory: workspace.directory, baseRef: base, prRef: prRef, isDiffOnly: false, headOid: sha)
        } catch {
            let spaces = self
            await Task.detached { await spaces.cleanup(workspace, localPath: bare) }.value
            throw error
        }
    }

    /// §8.5 en el host: `worktree remove --force` de ese worktree, su carpeta y su admin dir en el mirror propio, las dos
    /// refs y la carpeta de contexto. Nunca `git worktree prune`. Nunca lanza.
    public func cleanup(_ workspace: ReviewWorkspace, localPath: String?) async {
        let directory = workspace.directory.path
        try? await host.removeTree(workspace.contextDirectory.path, root: root)
        guard root.isRemovable(directory) else { return }
        if let bare = localPath, root.contains(bare) {
            await gitLogged(bare, ["worktree", "remove", "--force", directory])
            for ref in [workspace.prRef, workspace.baseRef].compactMap({ $0 }) where ref.hasPrefix("refs/prbar/") {
                await gitLogged(bare, ["update-ref", "-d", ref])
            }
            // Si git no pudo sacarlo, su admin dir en el mirror propio (nunca `git worktree prune`).
            let admin = bare + "/worktrees/" + workspace.directory.lastPathComponent
            if root.isRemovable(admin) { try? await host.removeTree(admin, root: root) }
        }
        try? await host.removeTree(directory, root: root)
    }

    // MARK: Respond

    /// Como `WorktreeResolver.prepare`, en el host. `worktreeDir` se ignora (siempre `<raíz>/work`).
    public func prepareRespond(localPath bare: String, repo: RepoRef, number: Int, headRef: String, worktreeDir: String?,
                               runID: String = WorktreeManager.newRunID()) async throws -> (worktree: ResolvedWorktree, headOid: String) {
        guard root.contains(bare) else { throw RemoteRunnerError.outsideRoot(bare) }
        let resolver = WorktreeResolver(runner: runner, gitPath: gitPath, environment: gitEnvironment, originMatches: originMatches)
        try await resolver.validateBranchName(headRef)
        let name = WorktreeResolver.directoryName(repo: repo, number: number, runID: runID)
        let target = try root.child(["work", name])
        let ref = WorktreeResolver.respondRef(number: number, runID: runID)
        let worktree = ResolvedWorktree(path: target, origin: .dedicated, localPath: bare, ref: ref)
        do {
            try await fetch(bare, repo: repo, ["+refs/heads/\(headRef):\(ref)"])
            try await resolver.verifyOrigin(bare, repo: repo)
            guard let sha = CommitSHA.parse(try await git(bare, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])) else {
                throw RemoteRunnerError.malformedOutput(host: host.name, what: "commit id")
            }
            try await git(bare, ["worktree", "add", "--detach", target, sha])
            let real = try host.checked(try await host.runScript("cd -P -- \(try ShellQuote.posix(target)) && pwd -P", timeout: 30), "pwd")
                .stdout.trimmingCharacters(in: .newlines)
            guard real == target else { throw RemoteRunnerError.outsideRoot(real) }
            return (worktree, sha)
        } catch {
            let spaces = self
            await Task.detached { await spaces.cleanupRespond(worktree) }.value
            throw error
        }
    }

    public func cleanupRespond(_ worktree: ResolvedWorktree) async {
        guard worktree.origin == .dedicated, let bare = worktree.localPath, root.contains(bare),
              WorktreeResolver.isRespondWorktreeName((worktree.path as NSString).lastPathComponent) else { return }
        await gitLogged(bare, ["worktree", "remove", "--force", worktree.path])
        if let ref = worktree.ref, ref.hasPrefix("refs/prbar/respond-") { await gitLogged(bare, ["update-ref", "-d", ref]) }
        try? await host.removeTree(worktree.path, root: root)
    }

    // MARK: Huérfanos

    /// Al arrancar (decisión J.7.16). Nunca lanza.
    public func cleanupOrphans() async {
        let listing = "for d in \(try! ShellQuote.posix(root.repos))/*/*.git; do [ -d \"$d/objects\" ] && printf '%s\\n' \"$d\"; done; exit 0"
        let mirrors = ((try? await host.runScript(listing, timeout: 60))?.stdout ?? "")
            .split(separator: "\n").map(String.init).filter(root.contains)
        for bare in mirrors {
            if let list = await gitLogged(bare, ["worktree", "list", "--porcelain"]) {
                for path in WorktreeManager.worktreePaths(fromPorcelain: list) where path.hasPrefix(root.work + "/") {
                    await gitLogged(bare, ["worktree", "remove", "--force", path])
                }
            }
            if let refs = await gitLogged(bare, ["for-each-ref", "--format=%(refname)", "refs/prbar/"]) {
                for ref in refs.split(separator: "\n").map(String.init) where ref.hasPrefix("refs/prbar/") && !ref.contains("..") {
                    await gitLogged(bare, ["update-ref", "-d", ref])
                }
            }
        }
        guard let marker = try? ShellQuote.posix(root.markerPath) else { return }
        for dir in [root.work, root.jobs, root.tmp] {
            guard let quoted = try? ShellQuote.posix(dir) else { continue }
            _ = try? await host.runScript("[ -f \(marker) ] || exit 96\nfind \(quoted) -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +", timeout: 300)
        }
    }
}
```

> `WorktreeManager.isChatWorkspaceName`, `prRef`, `baseRef` y `WorktreeResolver.directoryName`/`respondRef`/`isRespondWorktreeName` ya existen (internos o públicos; mismo módulo). `RemoteWorkspaces` también podría adoptar un protocolo común con `WorktreeManager`, pero la Task 14 solo necesita los métodos con estos nombres.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests "remote workspaces"` → `4/4 passed`; `swift run PRBarTests context` sigue verde.

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore/RemoteWorkspaces.swift Sources/PRBarCore/ReviewContext.swift Sources/PRBarCore/RespondAnalyzer.swift Sources/PRBarTests/RemoteWorkspacesTests.swift Sources/PRBarTests/main.swift
git commit -m "Mirror repos and create hardened worktrees on the host"
```

---

### Task 13: Los fixes vuelven a la Mac verificados y se pushean desde la Mac (`RemoteFixImport`)

**Files:**
- Create: `Sources/PRBarCore/RemoteFixImport.swift`
- Modify: `Sources/PRBarCore/RespondModels.swift` (`RespondDraft.runner`, `RespondResult.remoteObjects`), `Sources/PRBarCore/FixImplementer.swift` (`summarize` reusable sobre una ref)
- Test: `Sources/PRBarTests/RemoteFixImportTests.swift` (+ `main.swift`)

- [ ] **Step 1: Modelos.**
  - `RespondDraft`: `/// Destino remoto donde vive el worktree (spec J); nil = esta Mac. public var runner: String? = nil` y `/// El clone local del repo al analizar (para traer los fixes, J.7.9); nil sin carpeta local. public var localPath: String? = nil`, con parámetros `runner: String? = nil, localPath: String? = nil` al final del `init` y `runner, localPath` en una línea nueva de su `private enum CodingKeys` (la decodificación sintetizada usa `decodeIfPresent` para opcionales: los drafts viejos se leen igual).
  - `RespondResult`: `public var remoteObjects: RemoteObjects? = nil` (+ parámetro `remoteObjects: RemoteObjects? = nil` al final del `init`, y `remoteObjects` en sus `CodingKeys` si los tiene), y:

```swift
/// Los commits de un fix remoto, ya traídos a la Mac (decisión J.7.9).
public struct RemoteObjects: Codable, Equatable, Sendable {
    /// El repo local donde están los objetos: el clone del usuario o un clone temporal de PRBar.
    public var repoPath: String
    /// `true` si `repoPath` es un clone temporal (se borra al terminar).
    public var temporary: Bool
    public var ref: String
    /// El árbol del commit traído (`<sha>^{tree}`): se re-verifica antes del push.
    public var treeOid: String

    public init(repoPath: String, temporary: Bool, ref: String, treeOid: String) {
        self.repoPath = repoPath
        self.temporary = temporary
        self.ref = ref
        self.treeOid = treeOid
    }
}
```
  - `FixImplementer`: extraer de `summarize(_:start:items:integrity:)` una función que no depende de un worktree:

```swift
    /// El resultado de `start..head` en `repository` (un worktree o un repo cualquiera): `--stat`, diff completo
    /// (cortado), commits, sensibles y dependencias. `items`/`integrity` se copian. Todo git endurecido.
    static func summarize(repository: URL, start: String, head: String, items: [ItemResult], integrity: String?,
                          git: (URL, [String]) async throws -> String) async throws -> RespondResult
```
    con el mismo cuerpo que hoy pero con `"\(start)..\(head)"` en lugar de `"\(start)..HEAD"`, `headOid: head`, y `blob(…)` usando `head` en lugar de `HEAD`; `summarize(_:start:items:integrity:)` queda como `try await Self.summarize(repository: worktree, start: start, head: try await head(worktree), items:…, integrity:…, git: { try await self.git($0, $1) })`. El chequeo `checkNoNestedGit` del medio queda en la versión de worktree (antes de llamar a la estática).

- [ ] **Step 2: Tests que fallan.**

```swift
import Foundation
import PRBarCore

private let localGitEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

/// Un worktree de Respond en el host con un commit de "fix", y el import listo para usar.
private func remoteFix() async throws -> (TempGitRepo, FakeSSH, RemoteWorkspaces, ResolvedWorktree, String, RemoteFixImport) {
    let repo = try TempGitRepo.make()
    let (ssh, host, info, root) = try await verifiedFake()
    let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
    let bare = try await spaces.mirror(RepoRef(owner: "o", name: "r"))
    let (worktree, start) = try await spaces.prepareRespond(localPath: bare, repo: RepoRef(owner: "o", name: "r"), number: 7,
                                                            headRef: "feature", worktreeDir: nil, runID: "0a0b0c0d")
    let wt = URL(fileURLWithPath: worktree.path)
    try Data("fixed\n".utf8).write(to: wt.appendingPathComponent("feature.txt"))
    try TempGitRepo.run(wt, ["commit", "-q", "-am", "Fix the thing"])
    let importer = RemoteFixImport(spaces: spaces, localGit: TempGitRepo.git, localRunner: SystemProcessRunner(),
                                   gitEnvironment: localGitEnvironment, tempRoot: repo.base.appendingPathComponent("push"),
                                   originURL: { _ in repo.origin.path }, originMatches: { _, _ in true })
    return (repo, ssh, spaces, worktree, start, importer)
}

private func draft(_ worktree: ResolvedWorktree, start: String) -> RespondDraft {
    RespondDraft(id: UUID(), prID: "o/r#7", repo: RepoRef(owner: "o", name: "r"), number: 7, title: "T",
                 url: URL(string: "https://github.com/o/r/pull/7")!, headRef: "feature", account: "me", worktree: worktree,
                 startHeadOid: start, items: [], language: .english, runner: "devbox")
}

enum RemoteFixImportTests {
    static let cases: [TestCase] = [
        TestCase("remote fixes: el bundle se trae al clone local, se verifica y el diff se calcula en la Mac") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let result = try await importer.importFixes(draft: draft(worktree, start: start), localPath: repo.local.path,
                                                        items: [], integrity: "x")
            let objects = try expectNotNil(result.remoteObjects)
            try expectEqual(objects.repoPath, repo.local.path)
            try expect(!objects.temporary)
            try expect(result.diff?.contains("+fixed") == true, result.diff ?? "")
            try expectEqual(result.commits?.count, 1)
            let local = try TempGitRepo.run(repo.local, ["rev-parse", objects.ref]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(local, result.headOid)
        },
        TestCase("remote fixes: push verificado desde la Mac; el origin queda en el sha revisado") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            try await importer.push(draft: d, result: result, token: nil)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
        },
        TestCase("remote fixes: sin localPath usa un clone temporal mínimo y lo borra") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: nil, items: [], integrity: "x")
            let objects = try expectNotNil(result.remoteObjects)
            try expect(objects.temporary && objects.repoPath.hasPrefix(repo.base.appendingPathComponent("push").path))
            try await importer.push(draft: d, result: result, token: "ghp_test")
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
            await importer.discard(result)
            try expect(!FileManager.default.fileExists(atPath: objects.repoPath))
        },
        TestCase("remote fixes: si el host cambió el commit después de mostrarlo, no se pushea nada") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            let wt = URL(fileURLWithPath: worktree.path)
            try Data("sneaky\n".utf8).write(to: wt.appendingPathComponent("evil.sh"))
            try TempGitRepo.run(wt, ["add", "-A"])
            try TempGitRepo.run(wt, ["commit", "-q", "-m", "sneaky"])
            let error = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            try expect(error.localizedDescription.contains("Nothing was pushed"), error.localizedDescription)
            let origin = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(origin, start)
        },
        TestCase("remote fixes: un diff mostrado que no es el del árbol traído (o una ref movida) frena el push") {
            let (repo, ssh, _, worktree, start, importer) = try await remoteFix()
            defer { repo.remove(); ssh.remove() }
            let d = draft(worktree, start: start)
            let result = try await importer.importFixes(draft: d, localPath: repo.local.path, items: [], integrity: "x")
            var tampered = result
            tampered = RespondResult(items: result.items, diffStat: result.diffStat, tests: nil, sensitiveChanges: result.sensitiveChanges,
                                     headOid: result.headOid, gitIntegrity: result.gitIntegrity, diff: "diff --git a/x b/x\n+benign\n",
                                     diffTruncated: false, commits: result.commits, dependencyChanges: result.dependencyChanges,
                                     remoteObjects: result.remoteObjects)
            let error = try await expectThrows { try await importer.push(draft: d, result: tampered, token: nil) }
            try expect(error.localizedDescription.contains("Nothing was pushed"))
            try TempGitRepo.run(repo.local, ["update-ref", result.remoteObjects!.ref, start])
            _ = try await expectThrows { try await importer.push(draft: d, result: result, token: nil) }
            let origin = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(origin, start)
        },
    ]
}
```

> Ajustar el `init` de `RespondDraft`/`RespondResult` del test a los parámetros reales (ver `RespondModels.swift`); `language: .english` es el caso de `PRLanguage` que usan los otros tests.

- [ ] **Step 3: `Sources/PRBarCore/RemoteFixImport.swift`:**

```swift
import Foundation

/// Trae a la Mac los commits de un fix remoto, los verifica y pushea desde la Mac (decisión J.7.9). Lo que vuelve del
/// host no es de confianza: el diff que ve el usuario se calcula acá desde los objetos traídos, y antes del push se
/// verifica que nada cambió (ni la ref local, ni su árbol, ni el diff, ni el HEAD remoto).
public struct RemoteFixImport: Sendable {
    let spaces: RemoteWorkspaces
    let localGit: String
    let localRunner: FileIOProcessRunning & ProcessRunning
    let gitEnvironment: [String: String]
    let tempRoot: URL
    let originURL: @Sendable (RepoRef) -> String
    let originMatches: @Sendable (String, RepoRef) -> Bool

    public init(spaces: RemoteWorkspaces, localGit: String, localRunner: FileIOProcessRunning & ProcessRunning = SystemProcessRunner(),
                gitEnvironment: [String: String] = [:],
                tempRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PRBar/push", isDirectory: true),
                originURL: @escaping @Sendable (RepoRef) -> String = { "https://github.com/\($0.fullName).git" },
                originMatches: @escaping @Sendable (String, RepoRef) -> Bool = { WorktreeResolver.originMatches($0, repo: $1) }) {
        self.spaces = spaces
        self.localGit = localGit
        self.localRunner = localRunner
        self.gitEnvironment = gitEnvironment.merging(GitHardening.environment) { _, forced in forced }
        self.tempRoot = tempRoot
        self.originURL = originURL
        self.originMatches = originMatches
    }

    static func ref(_ draft: RespondDraft) -> String { "refs/prbar/remote-\(draft.number)-\(draft.id.uuidString.lowercased().prefix(8))" }

    // MARK: Git local

    @discardableResult
    func local(_ repository: String, _ arguments: [String], environment extra: [String: String] = [:],
               hardened: Bool = true, timeout: TimeInterval = WorktreeManager.slowTimeout) async throws -> String {
        let args = ["-C", repository] + (hardened ? GitHardening.arguments : []) + arguments
        let result = try await localRunner.run(localGit, args, environment: gitEnvironment.merging(extra) { _, new in new },
                                               currentDirectory: nil, timeout: timeout)
        guard result.status == 0 else {
            throw PRBarError.commandFailed(command: (["git"] + arguments.prefix(2)).joined(separator: " "), status: result.status,
                                           stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout
    }

    /// El token de la cuenta para un clone temporal: por variables de entorno de git, nunca en los argumentos.
    static func tokenEnvironment(_ token: String?) -> [String: String] {
        guard let token, !token.isEmpty else { return [:] }
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.https://github.com/.extraheader",
                "GIT_CONFIG_VALUE_0": "AUTHORIZATION: basic \(basic)"]
    }

    // MARK: Import

    /// Bundle remoto → Mac → verificación → `refs/prbar/remote-…` → resumen calculado en la Mac.
    public func importFixes(draft: RespondDraft, localPath: String?, items: [ItemResult], integrity: String?,
                            token: String? = nil) async throws -> RespondResult {
        let worktree = draft.worktree.path
        guard spaces.root.isRemovable(worktree), FixImplementer.isFullSHA(draft.startHeadOid) else {
            throw RemoteRunnerError.importMismatch("the worktree or its base isn’t PRBar’s.")
        }
        let remoteHead = try await spaces.git(worktree, ["rev-parse", "--verify", "HEAD^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard FixImplementer.isFullSHA(remoteHead) else { throw RemoteRunnerError.malformedOutput(host: spaces.host.name, what: "HEAD") }

        // El repo local: el clone del usuario (verificando su origin) o uno temporal mínimo.
        let (repository, temporary) = try await localRepository(draft: draft, localPath: localPath)
        do {
            if (try? await local(repository, ["cat-file", "-e", "\(draft.startHeadOid)^{commit}"])) == nil {
                try await local(repository, ["fetch", "--no-write-fetch-head", "--no-tags", "--depth=1", "origin", draft.startHeadOid],
                                environment: temporary ? Self.tokenEnvironment(token) : [:])
            }
            guard remoteHead != draft.startHeadOid else {
                try await local(repository, ["update-ref", Self.ref(draft), remoteHead])
                return try await summary(draft: draft, repository: repository, temporary: temporary, head: remoteHead, items: items, integrity: integrity)
            }
            let remoteBundle = try spaces.root.child(["tmp", "\(draft.id.uuidString.lowercased()).bundle"])
            try await spaces.git(worktree, ["bundle", "create", remoteBundle, "HEAD", "^\(draft.startHeadOid)"])
            let bundle = try LocalScratch.newFile()
            defer { try? FileManager.default.removeItem(at: bundle) }
            try await spaces.host.download(remoteBundle, to: bundle, root: spaces.root)
            await spaces.host.removeFiles([remoteBundle], root: spaces.root)

            try await local(repository, ["bundle", "verify", "-q", bundle.path])
            let heads = try await local(repository, ["bundle", "list-heads", bundle.path])
                .split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
            guard heads.count == 1, heads[0].first == remoteHead else {
                throw RemoteRunnerError.importMismatch("the bundle’s commit isn’t the server’s HEAD.")
            }
            try await local(repository, ["bundle", "unbundle", bundle.path])
            try await local(repository, ["update-ref", Self.ref(draft), remoteHead])
            return try await summary(draft: draft, repository: repository, temporary: temporary, head: remoteHead, items: items, integrity: integrity)
        } catch {
            if temporary { try? FileManager.default.removeItem(atPath: repository) }
            throw error
        }
    }

    private func localRepository(draft: RespondDraft, localPath: String?) async throws -> (String, Bool) {
        if let localPath {
            let url = try await local(localPath, ["remote", "get-url", "origin"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard originMatches(url, draft.repo) else {
                throw PRBarError.respond("The origin remote of \(localPath) is \(url), not github.com/\(draft.repo.fullName): not using it.")
            }
            return (localPath, false)
        }
        let path = tempRoot.appendingPathComponent(draft.id.uuidString.lowercased()).path
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        WorkspaceRegistry.shared.insert(path)
        let initialized = try await localRunner.run(localGit, ["init", "--bare", "-q", path], environment: gitEnvironment,
                                                    currentDirectory: nil, timeout: 60)
        guard initialized.status == 0 else { throw PRBarError.respond("Couldn’t create a temporary clone to push from.") }
        try await local(path, ["remote", "add", "origin", originURL(draft.repo)])
        return (path, true)
    }

    private func summary(draft: RespondDraft, repository: String, temporary: Bool, head: String,
                         items: [ItemResult], integrity: String?) async throws -> RespondResult {
        guard (try? await local(repository, ["merge-base", "--is-ancestor", draft.startHeadOid, head])) != nil else {
            throw RemoteRunnerError.importMismatch("\(head.prefix(12)) doesn’t descend from \(draft.startHeadOid.prefix(12)).")
        }
        let tree = try await local(repository, ["rev-parse", "--verify", "\(head)^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = try await FixImplementer.summarize(repository: URL(fileURLWithPath: repository), start: draft.startHeadOid, head: head,
                                                        items: items, integrity: integrity) { _, arguments in
            try await self.local(repository, arguments)
        }
        result.remoteObjects = RemoteObjects(repoPath: repository, temporary: temporary, ref: Self.ref(draft), treeOid: tree)
        return result
    }

    // MARK: Push

    /// Verifica todo de nuevo y pushea `<sha>:refs/heads/<rama>` desde la Mac (decisión J.7.9).
    public func push(draft: RespondDraft, result: RespondResult, token: String?) async throws {
        guard let objects = result.remoteObjects, let reviewed = result.headOid, FixImplementer.isFullSHA(reviewed) else {
            throw PRBarError.respond("This result can’t be pushed. Analyze the PR again.")
        }
        let repository = objects.repoPath
        func mismatch(_ detail: String) -> Error { RemoteRunnerError.importMismatch(detail) }
        let resolver = WorktreeResolver(runner: localRunner, gitPath: localGit, environment: gitEnvironment, originMatches: originMatches)
        try await resolver.validateBranchName(draft.headRef)
        let atRef = try await local(repository, ["rev-parse", "--verify", "\(objects.ref)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard atRef == reviewed else { throw mismatch("the local copy moved to \(atRef.prefix(12)).") }
        let tree = try await local(repository, ["rev-parse", "--verify", "\(reviewed)^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard tree == objects.treeOid else { throw mismatch("the tree isn’t the one that was imported.") }
        let fullDiff = try await local(repository, ["diff", GitHardening.ignoreSubmodules, "--text", "--no-textconv", "--no-ext-diff",
                                                    "--no-color", "\(draft.startHeadOid)..\(reviewed)"])
        let (diff, truncated) = FixImplementer.capDiff(fullDiff)
        guard diff == result.diff, truncated == (result.diffTruncated ?? false) else { throw mismatch("the diff isn’t the one you reviewed.") }
        let raw = try await local(repository, ["diff", "--raw", "-z", "--no-renames", "--no-abbrev", "\(draft.startHeadOid)..\(reviewed)"])
        guard WorktreeIntegrity.specialStagedPaths(fromRawZ: raw).isEmpty else { throw mismatch("it adds a symlink or a nested repo.") }
        guard (try? await local(repository, ["merge-base", "--is-ancestor", draft.startHeadOid, reviewed])) != nil else {
            throw mismatch("\(reviewed.prefix(12)) doesn’t descend from \(draft.startHeadOid.prefix(12)).")
        }
        let remoteHead = try await spaces.git(draft.worktree.path, ["rev-parse", "--verify", "HEAD^{commit}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteHead == reviewed else { throw mismatch("the server’s worktree is now at \(remoteHead.prefix(12)).") }

        let args = ["-C", repository] + RespondPublisher.pushHardening + ["push", "origin", "\(reviewed):refs/heads/\(draft.headRef)"]
        let pushed = try await localRunner.run(localGit, args,
                                               environment: gitEnvironment.merging(objects.temporary ? Self.tokenEnvironment(token) : [:]) { _, new in new },
                                               currentDirectory: nil, timeout: RespondPublisher.pushTimeout)
        guard pushed.status == 0 else {
            let stderr = [pushed.stderr, pushed.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            throw PRBarError.respond(RespondPublisher.pushFailureMessage(stderr: Redactor.redact(stderr, secrets: [token].compactMap { $0 })))
        }
    }

    /// Borra la ref local (y el clone temporal). Nunca lanza.
    public func discard(_ result: RespondResult) async {
        guard let objects = result.remoteObjects else { return }
        if objects.temporary {
            try? FileManager.default.removeItem(atPath: objects.repoPath)
            WorkspaceRegistry.shared.remove(objects.repoPath)
        } else if objects.ref.hasPrefix("refs/prbar/remote-") {
            _ = try? await local(objects.repoPath, ["update-ref", "-d", objects.ref])
        }
    }
}
```

> `RespondPublisher.pushHardening`, `pushTimeout` y `pushFailureMessage(stderr:)` existen (hacer `pushHardening`/`pushTimeout` `public static` si son internos y hace falta). `ItemResult` es el tipo (público, de `RespondModels.swift`) de los ítems del resultado. Si `WorkspaceRegistry` (Plan 13) no existe, omitir esas dos líneas.

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "remote fixes" && swift run PRBarTests "fix implementer"` → todo `passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/RemoteFixImport.swift Sources/PRBarCore/RespondModels.swift Sources/PRBarCore/FixImplementer.swift Sources/PRBarCore/RespondPublisher.swift Sources/PRBarTests/RemoteFixImportTests.swift Sources/PRBarTests/main.swift
git commit -m "Bring remote fixes back to the Mac, verify them and push from the Mac"
```

---

### Task 14: Los pipelines corren en el host (`RemotePlacement`) — flujo completo contra el host falso

**Files:**
- Create: `Sources/PRBarCore/RemotePlacement.swift`
- Modify: `Sources/PRBarCore/ReviewPipeline.swift`, `Sources/PRBarCore/RespondPipeline.swift`, `Sources/PRBarCore/ChatService.swift`
- Test: `Sources/PRBarTests/RemoteFlowTests.swift` (+ `main.swift`)

- [ ] **Step 1: `RemotePlacement`:**

```swift
import Foundation

/// Todo lo necesario para que un trabajo corra en un host ya verificado.
public struct RemotePlacement: Sendable {
    public let host: SSHHost
    public let root: RemoteRoot
    public let info: RunnerHostInfo
    public let runner: RemoteProcessRunner
    public let workspaces: RemoteWorkspaces
    public let fs: RemoteWorkspaceFS

    public init(host: SSHHost, info: RunnerHostInfo, gitEnvironment: [String: String] = [:],
                remoteURLs: (@Sendable (RepoRef) -> [String])? = nil,
                originMatches: (@Sendable (String, RepoRef) -> Bool)? = nil) throws {
        guard info.isUsable, let rootPath = info.root, let git = info.gitPath else {
            throw RemoteRunnerError.hostProblems(host: host.name, problems: info.problems)
        }
        let root = try RemoteRoot(verified: rootPath)
        let runner = RemoteProcessRunner(host: host, root: root, toolDirectories: info.toolDirectories)
        let fs = RemoteWorkspaceFS.ssh(host: host, home: info.home ?? (rootPath as NSString).deletingLastPathComponent)
        self.host = host
        self.root = root
        self.info = info
        self.runner = runner
        self.fs = fs
        self.workspaces = RemoteWorkspaces(
            host: host, root: root, gitPath: git, runner: runner, fs: fs, gitEnvironment: gitEnvironment,
            remoteURLs: remoteURLs ?? { ["https://github.com/\($0.fullName).git", "git@github.com:\($0.fullName).git"] },
            originMatches: originMatches ?? { WorktreeResolver.originMatches($0, repo: $1) })
    }

    public var name: String { host.name }
    public var gitPath: String { info.gitPath ?? "git" }
    public var claudePath: String { info.claudePath ?? "claude" }

    public func plugins(skills: [String]) async throws -> [String] {
        try await preparing { try await RemotePlugins.locate(skills: skills, host: host) }
    }

    /// Envuelve las fallas de preparación (antes de que arranque Claude): son las que permiten el fallback (J.7.10).
    public func preparing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw RemotePreparationFailure(host: name, underlying: error)
        }
    }

    public func claude(pluginDirs: [String], logURL: URL, secrets: [String], model: ClaudeModel?) -> ClaudeRunner {
        ClaudeRunner(runner: runner, claudePath: claudePath, pluginDirs: pluginDirs, environment: [:], logURL: logURL,
                     redacting: secrets, model: model, promptViaStandardInput: true)
    }
}

/// Una falla del host antes de que arrancara Claude.
public struct RemotePreparationFailure: Error, LocalizedError {
    public let host: String
    public let underlying: Error

    public var errorDescription: String? { underlying.localizedDescription }
    /// Para la fila: "devbox unreachable" o "devbox couldn’t prepare the repo".
    public var shortReason: String {
        if case .unreachable? = underlying as? RemoteRunnerError { return "\(host) unreachable" }
        return "\(host) couldn’t prepare the repo"
    }
}
```

- [ ] **Step 2: `ReviewPipeline`.** `init` gana `placement: RemotePlacement? = nil` (guardado). En `run`, después de `let token = …`, separar los dos caminos con un helper que devuelve las piezas:

```swift
    private struct Parts {
        let prepare: () async throws -> ReviewWorkspace
        let cleanup: @Sendable (ReviewWorkspace) async -> Void
        let context: ReviewContextWriter
        let reviewer: (ReviewWorkspace) throws -> ClaudeReviewer
    }

    private func parts(_ request: ReviewRequest, token: String, logURL: URL) async throws -> Parts {
        let pr = request.item.pr
        guard let remote = placement else {
            let pluginDirs = try ClaudePlugins.locate(skills: settings.reviewSkills, in: pluginCacheDirectory)
            let worktrees = self.worktrees
            return Parts(
                prepare: { try await worktrees.prepare(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: request.localPath) },
                cleanup: { workspace in await worktrees.cleanup(workspace, localPath: request.localPath) },
                context: context,
                reviewer: { _ in ClaudeReviewer(runner: streamingRunner, claudePath: claudePath, pluginDirs: pluginDirs, toolPaths: toolPaths,
                                                redacting: [token], logURL: logURL, settings: settings, rules: rules) })
        }
        let pluginDirs = try await remote.plugins(skills: settings.reviewSkills)
        let bare = try await remote.preparing { try await remote.workspaces.mirror(pr.repo) }
        let spaces = remote.workspaces
        return Parts(
            prepare: { try await remote.preparing {
                try await spaces.prepare(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: bare, name: nil, pinnedHeadOid: nil)
            } },
            cleanup: { workspace in await spaces.cleanup(workspace, localPath: bare) },
            context: ReviewContextWriter(runner: remote.runner, gitPath: remote.gitPath, ghPath: nil, files: spaces.contextFiles),
            reviewer: { _ in ClaudeReviewer(runner: remote.runner, claudePath: remote.claudePath, pluginDirs: pluginDirs, toolPaths: [],
                                            redacting: [token], logURL: logURL, settings: settings, rules: rules,
                                            promptViaStandardInput: true) })
    }
```

    y en `run`: `let parts = try await parts(request, token: token, logURL: logURL)`, `let workspace = try await parts.prepare()`, `headOid = try await (placement == nil ? parts.context.write(…) : placement!.preparing { try await parts.context.write(…) })`, `let reviewer = try parts.reviewer(workspace)`, y las dos llamadas a `cleanup(workspace, request)` pasan a `await Task.detached { await parts.cleanup(workspace) }.value`. El `ClaudePlugins.locate` de antes se borra (va en `parts`).

- [ ] **Step 3: `RespondPipeline`.** `init` gana `placement: RemotePlacement? = nil` y `importer: RemoteFixImport? = nil` (lo arma el placement si es nil: `RemoteFixImport(spaces: placement.workspaces, localGit: gitPath, gitEnvironment: gitEnvironment)`).
  - `analyze`: si hay `placement`: `bare = try await remote.preparing { try await remote.workspaces.mirror(pr.repo) }`, el worktree con `remote.preparing { try await remote.workspaces.prepareRespond(localPath: bare, …) }`, `pluginDirs` con `remote.plugins(skills: settings.respondSkills)`, `contextDir` en `try remote.root.child(["work", "\(owner)-\(name)-\(N)-\(draftID).respond-context"])`, `RespondAnalyzer(claude: remote.claude(…), settings:, rules:, files: remote.workspaces.contextFiles)`, el `defer` que borraba la carpeta pasa a `await remote.workspaces.contextFiles.removeTree(contextDir.path)` (en una `Task.detached` esperada), la limpieza por error usa `remote.workspaces.cleanupRespond(worktree)`, y el draft lleva `runner: remote.name`. **Sin** `localPath` y con placement, el análisis sigue (decisión J.7.14).
  - `implement`: con placement, `FixImplementer(claude: remote.claude(…), runner: remote.runner, gitPath: remote.gitPath, environment: gitEnvironment.merging(identity) { _, new in new }, settings:, rules:, fs: remote.fs, testShell: "/bin/sh", testRunner: RemoteLoginRunner(host: remote.host))`; después de `implementer.implement(…)`, `return try await importer.importFixes(draft: draft, localPath: draft.localPath, items: result.items, integrity: result.gitIntegrity, token: token)`. `identity` = `GIT_AUTHOR_NAME/EMAIL` y `GIT_COMMITTER_NAME/EMAIL` leídos con `git config user.name`/`user.email` en la Mac (en `localPath` si hay; si no, global); si no hay, `[:]`.
  - `runTests`: con placement, el mismo `FixImplementer` remoto (`testShell: "/bin/sh"`, `testRunner: RemoteLoginRunner`).
  - `push`: con placement, `try await importer.push(draft: draft, result: result, token: try await tokens.token(for: draft.account))`.
  - `cleanup`: con placement, `await remote.workspaces.cleanupRespond(draft.worktree)` y `await importer.discard(result)` si hay un resultado.
  - `cancellation(of:)`: con placement, `fs = remote.fs` y `git` por `remote.runner`.
  - `RespondRequest.localPath` pasa de `String` a `String?` (solo un destino remoto acepta `nil`; el camino local lanza `PRBarError.respond("This repo needs a local folder to respond.")` si es `nil`, el mismo texto que el botón). `analyze` guarda `localPath` en el draft (`RespondDraft.localPath`, Task 13) y `importFixes` usa `draft.localPath`.

- [ ] **Step 4: `ChatService`.** `init` gana `placement: RemotePlacement? = nil`. Con placement:
  - `reviewWorkspace(…)`: `WorktreeManager.prepare(…)` → `remote.workspaces.prepare(…, localPath: bare)` (con `bare = mirror`), `ReviewContextWriter(…, files: remote.workspaces.contextFiles)`, y la escritura del `pr.md` de merge (Plan 11, `MergeContextWriter.metadata`) con `remote.workspaces.contextFiles.write`.
  - `existingReviewWorkspace(path:refs:)`: los dos `FileManager.default.fileExists` pasan por `contextFiles.exists` (hacerla `async`).
  - `respondWorkspace(…)`: las escrituras de `feedback.json`, `pr.md` y el diff de fixes pasan por `contextFiles`.
  - `claude(for:logURL:)`: `remote.claude(pluginDirs: [], logURL:, secrets:, model:)` (los chats no cargan plugins).
  - `implementer(logURL:)`: el `FixImplementer` remoto de la Step 3; después de `chatTurn`/`undoChatTurn`, `importer.importFixes(…)` sobre el resultado.
  - `cleanup(session:subject:localPath:)`: con `remote.workspaces.cleanup`/`contextFiles.removeTree`.

- [ ] **Step 5: Tests del flujo completo.** `Sources/PRBarTests/RemoteFlowTests.swift`:

```swift
import Foundation
import PRBarCore

private func line(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func placement(_ ssh: FakeSSH, origin: URL) async throws -> RemotePlacement {
    let host = try ssh.host()
    let info = try await RunnerProbe.check(host)
    return try RemotePlacement(host: host, info: info,
                               gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                                "GIT_AUTHOR_NAME": "PRBar Tests", "GIT_AUTHOR_EMAIL": "tests@prbar.invalid",
                                                "GIT_COMMITTER_NAME": "PRBar Tests", "GIT_COMMITTER_EMAIL": "tests@prbar.invalid"],
                               remoteURLs: { _ in [origin.path] }, originMatches: { _, _ in true })
}

enum RemoteFlowTests {
    static let cases: [TestCase] = [
        TestCase("remote flow: un review corre en el host (worktree, contexto, claude aislado) y limpia todo") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let finding: [String: Any] = ["id": "f1", "severity": "high", "file": "feature.txt", "line": 1, "title": "T", "body": "B"]
            try Data((line(["type": "result", "subtype": "success", "is_error": false, "result": "",
                            "structured_output": ["summary": "One issue", "findings": [finding]]]) + "\n").utf8)
                .write(to: ssh.home.appendingPathComponent("claude-stream.jsonl"))
            let remote = try await placement(ssh, origin: repo.origin)
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            settings.reviewSkill = "review"
            let pipeline = ReviewPipeline(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                          api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                          settings: settings, logURLProvider: { _ in ssh.base.appendingPathComponent("review.log") },
                                          placement: remote)
            let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, base: "main"), category: .toReview, account: "me")
            let draft = try await pipeline.run(ReviewRequest(item: item, localPath: nil, baseRef: "main")) { _ in }
            try expectEqual(draft.headOid, repo.prSHA)
            try expectEqual(draft.summary, "One issue")
            let cwd = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/cwd.txt"), encoding: .utf8)
            try expect(cwd.hasPrefix(remote.root.work + "/"), cwd)
            let args = try String(contentsOf: ssh.home.appendingPathComponent("claude-calls/1/args.bin"), encoding: .utf8).split(separator: "\0").map(String.init)
            try expect(args.contains("--add-dir") && args.contains { $0.hasSuffix(".context") })
            try expectEqual(try FileManager.default.contentsOfDirectory(atPath: remote.root.work), [])
            let sent = ssh.invocations().flatMap { $0 }.joined()
            try expect(!sent.contains("tok-me"), "un token salió de la Mac")
        },
        TestCase("remote flow: Respond analiza e implementa en el host, el diff se calcula en la Mac y se pushea desde la Mac") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            let analysis: [String: Any] = ["items": [["id": "thread:A", "assessment": "Right", "action": "fix", "fixPlan": "Change it", "reply": ""]]]
            try Data((line(["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": analysis]) + "\n").utf8)
                .write(to: ssh.home.appendingPathComponent("claude-stream-1.jsonl"))
            let fix: [String: Any] = ["status": "done", "summary": "Changed", "commitMessage": "Change it"]
            try Data((line(["type": "result", "subtype": "success", "is_error": false, "result": "", "structured_output": fix]) + "\n").utf8)
                .write(to: ssh.home.appendingPathComponent("claude-stream-2.jsonl"))
            try Data("printf 'fixed by claude\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            // El plugin del skill de Respond por defecto, instalado en el "host".
            try FileManager.default.createDirectory(at: ssh.home.appendingPathComponent(".claude/plugins/cache/m/superpowers/1.0.0/skills"),
                                                    withIntermediateDirectories: true)
            let remote = try await placement(ssh, origin: repo.origin)
            let feedback = PRFeedback(
                headRefName: "feature", headRefOid: repo.prSHA, isCrossRepository: false, lastCommitAt: at(-10),
                threads: [FeedbackItem(id: "thread:A", kind: .thread, path: "feature.txt", line: 1, isOutdated: false,
                                       comments: [FeedbackComment(databaseID: 101, author: "ana", isBot: false, body: "Change it", createdAt: t0,
                                                                  url: URL(string: "https://github.com/o/r/pull/7#discussion_r101")!)])],
                reviews: [])
            let pipeline = RespondPipeline(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                           api: FakeFeedbackAPI(feedback: feedback), gitPath: "/usr/bin/git", claudePath: "/nonexistent/claude",
                                           gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                           logURLProvider: { _ in ssh.base.appendingPathComponent("respond.log") },
                                           originMatches: { _, _ in true }, placement: remote,
                                           importer: RemoteFixImport(spaces: remote.workspaces, localGit: "/usr/bin/git",
                                                                     gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                                                     tempRoot: repo.base.appendingPathComponent("push"),
                                                                     originURL: { _ in repo.origin.path }, originMatches: { _, _ in true }))
            let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, author: "me"), category: .myFeedback, account: "me")
            let draft = try await pipeline.analyze(RespondRequest(item: item, localPath: repo.local.path, worktreeDir: nil), draftID: UUID()) { _ in }
            try expectEqual(draft.runner, "devbox")
            try expect(remote.root.contains(draft.worktree.path))
            let result = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: RespondSelection(implement: true, fixPlan: "Change it", reply: false, replyText: "")]) { _, _ in }
            try expect(result.diff?.contains("+fixed by claude") == true, result.diff ?? "")
            try expectEqual(result.remoteObjects?.repoPath, repo.local.path)
            try await pipeline.push(draft: draft, result: result)
            let pushed = try TempGitRepo.run(repo.origin, ["rev-parse", "refs/heads/feature"]).trimmingCharacters(in: .whitespacesAndNewlines)
            try expectEqual(pushed, result.headOid)
            await pipeline.cleanup(draft: draft)
            try expect(!FileManager.default.fileExists(atPath: draft.worktree.path))
        },
    ]
}
```

> `FakeTokens` devuelve `tok-<login>`; `FakeAPI`/`FakeFeedbackAPI`, `FeedbackItem` y `FeedbackComment` se usan igual que en `RespondQueueTests` (su `E2E`). Si algún `init` cambió, copiar la forma de esos tests.

- [ ] **Step 6:** `swift build --product PRBarTests && swift run PRBarTests "remote flow"` → `2/2 passed`. Toda la suite: `swift run PRBarTests` (los pipelines locales no cambiaron).

- [ ] **Step 7: Commit.**

```bash
git add Sources/PRBarCore Sources/PRBarTests/RemoteFlowTests.swift Sources/PRBarTests/main.swift
git commit -m "Run reviews, Respond and PR chats on an SSH host"
```

---

### Task 15: Resolución de destino, salud y fallback (`RunnerCoordinator`)

**Files:**
- Modify: `Sources/PRBarCore/RemotePlacement.swift`
- Test: `Sources/PRBarTests/RunnerCoordinatorTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

private func coordinator(_ ssh: FakeSSH, unreachable: Bool = false) -> RunnerCoordinator {
    RunnerCoordinator(makeHost: { destination in
        SSHHost(destination: destination, sshPath: ssh.executable.path, controlDirectory: ssh.controlDirectory, enforceHostKey: true,
                sshEnvironment: ssh.environment(unreachable: unreachable), killGracePeriod: 1)
    })
}

enum RunnerCoordinatorTests {
    static let cases: [TestCase] = [
        TestCase("coordinator: sin destino es esta Mac; con uno sano, remoto") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let coordinator = coordinator(ssh)
            let local = try await coordinator.choice(for: nil)
            guard case .local = local else { throw TestFailure(description: "\(local)") }
            let devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))
            let remote = try await coordinator.choice(for: devbox)
            guard case .remote(let placement) = remote else { throw TestFailure(description: "\(remote)") }
            try expectEqual(placement.name, "devbox")
        },
        TestCase("coordinator: host caído con fallback → esta Mac con el motivo; sin fallback → error") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let coordinator = coordinator(ssh, unreachable: true)
            var devbox = RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox"))
            let fallback = try await coordinator.choice(for: devbox)
            guard case .fallback(let reason) = fallback else { throw TestFailure(description: "\(fallback)") }
            try expectEqual(reason, "devbox unreachable")
            try expectEqual(JobPlacement.fallback(reason: reason).label, "Ran on this Mac — devbox unreachable")
            devbox.fallbackToLocal = false
            await coordinator.forget("devbox")
            let error = try await expectThrows { _ = try await coordinator.choice(for: devbox) }
            try expect(error is RemoteRunnerError, "\(error)")
        },
        TestCase("coordinator: un host con problemas (sin claude) también cae a esta Mac, con el problema") {
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            _ = try ControlSocketDirectory.ensure(ssh.controlDirectory)
            let fallback = try await coordinator(ssh).choice(for: RunnerDestination(name: "devbox", endpoint: SSHEndpoint(host: "devbox")))
            guard case .fallback(let reason) = fallback else { throw TestFailure(description: "\(fallback)") }
            try expect(reason.hasPrefix("devbox "), reason)
        },
    ]
}
```

- [ ] **Step 2:** build → falla.

- [ ] **Step 3: Implementación** (al final de `RemotePlacement.swift`):

```swift
/// Dónde corrió (o corre) un trabajo, para la fila y la ventana (spec J.4).
public enum JobPlacement: Equatable, Sendable {
    case local
    case remote(host: String)
    case fallback(reason: String)

    public var label: String? {
        switch self {
        case .local: nil
        case .remote(let host): "on \(host)"
        case .fallback(let reason): "Ran on this Mac — \(reason)"
        }
    }
}

/// Elige dónde corre un trabajo: esta Mac, el host (verificado, con caché) o esta Mac por fallback (J.7.10–11).
public actor RunnerCoordinator {
    public enum Choice: Sendable {
        case local
        case remote(RemotePlacement)
        case fallback(reason: String)
    }

    private let health: RunnerHealthCache
    private let makeHost: @Sendable (RunnerDestination) async throws -> SSHHost
    private let gitEnvironment: @Sendable () async -> [String: String]

    public init(health: RunnerHealthCache = RunnerHealthCache(),
                makeHost: @escaping @Sendable (RunnerDestination) async throws -> SSHHost,
                gitEnvironment: @escaping @Sendable () async -> [String: String] = { [:] }) {
        self.health = health
        self.makeHost = makeHost
        self.gitEnvironment = gitEnvironment
    }

    /// El host real: `/usr/bin/ssh`, la carpeta del socket y la política de host key de `ssh -G`.
    public static func liveHost(_ destination: RunnerDestination) async throws -> SSHHost {
        let directory = try ControlSocketDirectory.ensure()
        return SSHHost(destination: destination, controlDirectory: directory,
                       enforceHostKey: await SSHHost.enforcesHostKey(destination))
    }

    public func choice(for destination: RunnerDestination?) async throws -> Choice {
        guard let destination else { return .local }
        do {
            return .remote(try await placement(for: destination))
        } catch let error as CancellationError {
            throw error
        } catch {
            guard destination.fallbackToLocal else { throw error }
            AppLog.write("Runner \(destination.name): \(error.localizedDescription) — running on this Mac")
            if case .unreachable? = error as? RemoteRunnerError { return .fallback(reason: "\(destination.name) unreachable") }
            return .fallback(reason: "\(destination.name) isn’t ready")
        }
    }

    /// Sin fallback: para las etapas siguientes de Respond (siempre el host del análisis) y "Test Connection".
    public func placement(for destination: RunnerDestination, force: Bool = false) async throws -> RemotePlacement {
        let host = try await makeHost(destination)
        let info = try await health.info(for: host, force: force)
        return try RemotePlacement(host: host, info: info, gitEnvironment: await gitEnvironment())
    }

    public func test(_ destination: RunnerDestination) async -> RunnerHostInfo {
        do {
            let host = try await makeHost(destination)
            var info = try await RunnerProbe.check(host)
            if info.isUsable { info.claudeLoggedIn = try await RunnerProbe.claudeLoggedIn(host, info: info) }
            if info.claudeLoggedIn == false {
                info.problems.append("Claude isn’t signed in on \(destination.name): run `claude` there once to log in.")
            }
            await health.forget(destination.name)
            return info
        } catch {
            return RunnerHostInfo(host: destination.name, problem: error.localizedDescription)
        }
    }

    public func lastInfo(_ name: String) async -> RunnerHostInfo? { await health.last(name) }
    public func forget(_ name: String) async { await health.forget(name) }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests coordinator` → `3/3 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/RemotePlacement.swift Sources/PRBarTests/RunnerCoordinatorTests.swift Sources/PRBarTests/main.swift
git commit -m "Choose where each job runs, with health checks and fallback to this Mac"
```

---

### Task 16: Protocolo 5 y CLI — `prbar runners …`, `prbar repo set --run-on`

**Files:**
- Modify: `Sources/PRBarCore/AppCommand.swift`, `AppCommandTypes.swift`, `CommandActions.swift`, `CommandDispatcher.swift`, `CommandProtocol.swift`, `CommandResults.swift`
- Create: `Sources/PRBarCLIKit/RunnerCommands.swift`
- Modify: `Sources/PRBarCLIKit/ConfigCommands.swift`, `CLIRouter.swift`, `PRBarCLIKit.swift`
- Modify tests: `FakeActions.swift`, `CommandDispatcherTests.swift`, `CLIParsingTests.swift`
- Modify: `docs/cli.md`

- [ ] **Step 1: Tests que fallan.**

`CommandDispatcherTests.dispatchSamples`, al final:

```swift
    (.runnersList, "runnersList"),
    (.runnerAdd(host: "fede@devbox:2222", name: "devbox", dir: nil, fallback: true), "runnerAdd"),
    (.runnerSet(name: "devbox", dir: "/srv/prbar", fallback: false), "runnerSet"),
    (.runnerRemove(name: "devbox"), "runnerRemove"),
    (.runnerTest(name: "devbox"), "runnerTest"),
    (.runnerDefault(target: "local"), "runnerDefault"),
```

`CLIParsingTests`:

```swift
            TestCase("cli parse: runners y repo set --run-on") {
                try expectEqual(try parsed(["runners", "list"]), .runnersList)
                try expectEqual(try parsed(["runners"]), .runnersList)
                try expectEqual(try parsed(["runners", "add", "devbox"]), .runnerAdd(host: "devbox", name: nil, dir: nil, fallback: true))
                try expectEqual(try parsed(["runners", "add", "fede@devbox:2222", "--name", "gpu", "--dir", "/srv/prbar", "--no-fallback"]),
                                .runnerAdd(host: "fede@devbox:2222", name: "gpu", dir: "/srv/prbar", fallback: false))
                try expect(rejects(["runners", "add", "-oProxyCommand=x"]))
                try expect(rejects(["runners", "add", "devbox", "--dir", "~/../x"]))
                try expect(rejects(["runners", "add", "devbox", "--name", "local"]))
                try expectEqual(try parsed(["runners", "set", "devbox", "--fallback", "off"]), .runnerSet(name: "devbox", dir: nil, fallback: false))
                try expectEqual(try parsed(["runners", "remove", "devbox"]), .runnerRemove(name: "devbox"))
                try expectEqual(try parsed(["runners", "test", "devbox"]), .runnerTest(name: "devbox"))
                try expectEqual(try parsed(["runners", "default", "local"]), .runnerDefault(target: "local"))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--run-on", "devbox"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .set(value: "devbox"))))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--run-on", "default"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(runOn: .clear)))
                try expect(rejects(["repo", "set", "acme/api", "--run-on", "a b"]))
            },
```

- [ ] **Step 2:** build → falla.

- [ ] **Step 3: Core.**
  - `AppCommand`: sección `// Dónde corre Claude (spec J)`:

```swift
    case runnersList
    /// `host`: alias de ~/.ssh/config o `user@host[:port]`; `name`: por defecto el host; `dir`: por defecto `~/.prbar`.
    case runnerAdd(host: String, name: String?, dir: String?, fallback: Bool)
    case runnerSet(name: String, dir: String?, fallback: Bool?)
    case runnerRemove(name: String)
    /// "Test Connection" (incluye el login de Claude).
    case runnerTest(name: String)
    /// `local` o el nombre de un destino.
    case runnerDefault(target: String)
```
    `Name`: una línea nueva al final `case runnersList, runnerAdd, runnerSet, runnerRemove, runnerTest, runnerDefault`; `name`: los seis.
  - `RepoChanges`: `/// `local`, un destino, o `.clear` = "Default" (spec J.1). public var runOn: ValueChange?` + parámetro `runOn: ValueChange? = nil` al final del `init`.
  - `RepoInfo`: `public var runOn: String?` (`config.runOn?.cliValue`).
  - `CommandResults.swift`:

```swift
/// `prbar runners list|test`.
public struct RunnerInfo: Codable, Equatable, Sendable {
    public var name: String
    public var host: String
    public var dir: String
    public var fallback: Bool
    public var isDefault: Bool
    public var lastCheck: RunnerHostInfo?

    public init(destination: RunnerDestination, isDefault: Bool, lastCheck: RunnerHostInfo?) {
        name = destination.name
        host = destination.endpoint.display
        dir = destination.remoteDir
        fallback = destination.fallbackToLocal
        self.isDefault = isDefault
        self.lastCheck = lastCheck
    }
}
```
  - `CommandActions.swift`:

```swift
/// Destinos SSH (spec J.4).
@MainActor
public protocol RunnerActions: AnyObject {
    func runnersList() async -> [RunnerInfo]
    func runnerAdd(host: String, name: String?, dir: String?, fallback: Bool) async throws -> RunnerInfo
    func runnerSet(name: String, dir: String?, fallback: Bool?) throws -> RunnerInfo
    func runnerRemove(name: String) async throws
    func runnerTest(name: String) async throws -> RunnerInfo
    func runnerDefault(target: String) throws
}
```
    y `& RunnerActions` en `PRBarActions`.
  - `CommandDispatcher`: los seis casos (`encode(await …)` / `.ok`).
  - `CommandProtocol.version = 5`; comentario `/// 5: `RepoChanges.runOn` y los comandos de destinos SSH (`prbar runners`).`
  - `FakeActions` adopta `RunnerActions` (cada método anota su nombre y devuelve un `RunnerInfo` con `RunnerDestination(name: name ?? host, endpoint: SSHEndpoint(host: "devbox"))`).

- [ ] **Step 4: CLI.** `Sources/PRBarCLIKit/RunnerCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCore

struct RunnersGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runners", abstract: "Where Claude runs: this Mac or SSH hosts (Settings › Claude › Run On).",
        subcommands: [RunnersList.self, RunnersAdd.self, RunnersSet.self, RunnersRemove.self, RunnersTest.self, RunnersDefault.self],
        defaultSubcommand: RunnersList.self)
}

enum RunnerRender {
    static func row(_ runner: RunnerInfo) -> [String] {
        let status: String
        if let check = runner.lastCheck {
            status = check.problems.isEmpty ? "ok · \(check.os ?? "?") · \(check.claudeVersion ?? "claude ?")" : "! " + (check.problems.first ?? "")
        } else {
            status = "not checked"
        }
        return [runner.name + (runner.isDefault ? " (default)" : ""), runner.host, runner.dir, runner.fallback ? "on" : "off", status]
    }

    static func table(_ runners: [RunnerInfo], _ output: Output) {
        guard !runners.isEmpty else { return output.line("Claude runs on this Mac. Add a host with `prbar runners add <host>`.") }
        output.table(["Runner", "Host", "Folder", "Fallback", "Last check"], runners.map(row))
    }
}

struct RunnersList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The SSH hosts (also: prbar runners).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .runnersList }
    func render(_ result: JSONValue, _ output: Output) throws { RunnerRender.table(try result.decode(), output) }
}

struct RunnersAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add an SSH host (a Host from ~/.ssh/config or user@host[:port]).",
                                                    discussion: "PRBar never stores passwords: the host needs your SSH key or agent.")
    @Argument(help: "devbox, user@host or user@host:port.") var host: String
    @Option(help: "Its name in PRBar (default: the host).") var name: String?
    @Option(help: "The remote folder PRBar owns (default ~/.prbar).") var dir: String?
    @Flag(help: "Fail instead of running on this Mac when the host is down.") var noFallback = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        _ = try SSHEndpoint.parse(host)
        if let name, !RunnerDestination.isValidName(name) { throw ValidationError(RunnerConfigError.invalidName(name).localizedDescription) }
        if let dir, !RunnerDestination.isValidRemoteDir(dir) { throw ValidationError(RunnerConfigError.invalidRemoteDir(dir).localizedDescription) }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .runnerAdd(host: host, name: name, dir: dir, fallback: !noFallback) }
    func render(_ result: JSONValue, _ output: Output) throws { RunnerRender.table([try result.decode()], output) }
}

struct RunnersSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change an SSH host’s folder or fallback.")
    @Argument(help: "The runner’s name.") var name: String
    @Option(help: "The remote folder.") var dir: String?
    @Option(help: "on: run on this Mac when the host is down; off: fail.") var fallback: OnOff?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let dir, !RunnerDestination.isValidRemoteDir(dir) { throw ValidationError(RunnerConfigError.invalidRemoteDir(dir).localizedDescription) }
        if dir == nil && fallback == nil { throw ValidationError("Nothing to change: use --dir or --fallback.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .runnerSet(name: name, dir: dir, fallback: fallback?.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws { RunnerRender.table([try result.decode()], output) }
}

struct RunnersRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove an SSH host (repos using it go back to Default).")
    @Argument(help: "The runner’s name.") var name: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .runnerRemove(name: name) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Removed \(name). Its folder on the host was left as is.") }
}

struct RunnersTest: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Test Connection: tools, folder and Claude’s login on the host.")
    @Argument(help: "The runner’s name.") var name: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .runnerTest(name: name) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let runner: RunnerInfo = try result.decode()
        guard let check = runner.lastCheck else { return output.line("No result.") }
        Render.pairs([("OS", "\(check.os ?? "?") \(check.arch ?? "")"), ("git", check.gitVersion ?? "missing"),
                      ("claude", check.claudeVersion ?? "missing"), ("Logged in", check.claudeLoggedIn.map { $0 ? "yes" : "no" } ?? "—"),
                      ("Folder", check.root ?? "—")], output)
        for problem in check.problems { output.line(output.paint("! " + problem, .red)) }
    }

    /// Exit ≠ 0 si la verificación encontró problemas (también con `--json`).
    func exitCode(for result: JSONValue) throws -> Int32 {
        let runner: RunnerInfo = try result.decode()
        return (runner.lastCheck?.problems.isEmpty ?? false) ? CLIExit.ok : CLIExit.generalError
    }
}

struct RunnersDefault: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "default", abstract: "Where Claude runs for repos set to Default.")
    @Argument(help: "local or a runner’s name.") var target: String
    @OptionGroup var global: GlobalOptions
    func validate() throws {
        guard RunTarget(cliValue: target) != nil else { throw ValidationError("Use local or a runner’s name.") }
    }
    func appCommand(confirmed: Bool) -> AppCommand { .runnerDefault(target: target) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line(target == "local" ? "Claude runs on this Mac by default." : "Claude runs on \(target) by default.") }
}
```

  - `PRBarCLIKit.swift`: `RunnersGroup.self` en los subcomandos (después de `ClaudeGroup` o el grupo de configuración que corresponda).
  - `ConfigCommands.swift`, `RepoSet`: `@Option(help: "Where Claude runs for this repo: local, a runner’s name, or default.") var runOn: String?`; en `validate`, `runOn` tiene que ser `default` o `RunTarget(cliValue:) != nil`; en `RepoChanges(…)`: `runOn: runOn.map { $0 == "default" ? .clear : .set(value: $0) }`.
  - `CLIRouter.swift`:

```swift
        // Dónde corre Claude (plan 14)
        .init("runners list", [.runnersList], ["runners", "list"], ["runners"]),
        .init("runners add", [.runnerAdd], ["runners", "add", "fede@devbox:2222", "--no-fallback"]),
        .init("runners set", [.runnerSet], ["runners", "set", "devbox", "--fallback", "off"]),
        .init("runners remove", [.runnerRemove], ["runners", "remove", "devbox"]),
        .init("runners test", [.runnerTest], ["runners", "test", "devbox"]),
        .init("runners default", [.runnerDefault], ["runners", "default", "local"]),
```
    y en `"repo set"` el ejemplo `["repo", "set", "acme/api", "--run-on", "devbox"]`.
  - `docs/cli.md`: sección "Dónde corre Claude" con los seis comandos, `repo set --run-on`, el fallback, que no se guardan contraseñas y protocolo 5.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests "cli parse" && swift run PRBarTests dispatcher && swift run PRBarTests paridad` → `passed` (paridad de UI: sin cambios todavía).

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore Sources/PRBarCLIKit Sources/PRBarTests docs/cli.md
git commit -m "Add prbar runners and repo set --run-on (protocol 5)"
```

---

### Task 17: App — destinos, pipelines con fallback, "on devbox", limpieza al arrancar

**Files:**
- Create: `Sources/PRBar/AppModel+Runners.swift`
- Modify: `Sources/PRBar/AppModel.swift`, `Sources/PRBar/Review/LiveReviewPipeline.swift`, `Sources/PRBar/Respond/LiveRespondPipeline.swift`, `Sources/PRBar/Chat/LiveChatBackend.swift`

- [ ] **Step 1: Estado en `AppModel`.**

```swift
    /// Dónde corre Claude (spec J). Un solo coordinador: comparte la caché de salud.
    let runners = RunnerCoordinator(makeHost: { try await RunnerCoordinator.liveHost($0) })
    /// "on devbox" / "Ran on this Mac — …" por PR (filas y ventanas).
    @Published var placements: [String: JobPlacement] = [:]
    /// La última verificación de cada destino (Settings y `prbar runners`).
    @Published var runnerChecks: [String: RunnerHostInfo] = [:]
```

  `ReviewContext` (en `LiveReviewPipeline.swift`) gana `runner: RunnerDestination?` (el destino del repo, `RunTargetResolver.destination(for: repoConfig, settings: config.runners)`), `runnerByName: RunnerDestination?` (para drafts de Respond con `runner`), `coordinator: RunnerCoordinator` y `onPlacement: @MainActor @Sendable (String, JobPlacement) -> Void`. Los tres `context:` de `AppModel` (reviews, respond, chat) los llenan: el destino se resuelve con el repo del pedido, así que el closure pasa a recibir el `RepoRef`: `context: { [weak self] repo in … }` (cambiar la firma en los tres `Live*` y en su uso).

- [ ] **Step 2: `LiveReviewPipeline.run`:**

```swift
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let context = await context(request.item.pr.repo)
        await context.orphanCleanup?.value
        try Task.checkCancellation()
        let prID = request.item.id
        let local = { () async throws -> ReviewDraft in
            guard let git = context.tools.git else { throw ReviewFailure(underlying: PRBarError.toolNotFound("git"), logURL: nil) }
            guard let claude = context.tools.claude else { throw ReviewFailure(underlying: PRBarError.toolNotFound("claude"), logURL: nil) }
            return try await ReviewPipeline(processRunner: runner, streamingRunner: claudeRunner, tokens: tokens, gitPath: git,
                                            ghPath: context.tools.gh, claudePath: claude, settings: context.claude, rules: context.rules,
                                            logURLProvider: logURLProvider).run(request, onPhase: onPhase)
        }
        switch try await context.coordinator.choice(for: context.runner) {
        case .local:
            await context.onPlacement(prID, .local)
            return try await local()
        case .fallback(let reason):
            await context.onPlacement(prID, .fallback(reason: reason))
            return try await local()
        case .remote(let remote):
            await context.onPlacement(prID, .remote(host: remote.name))
            do {
                return try await ProcessActivity.$current.withValue(ProcessActivity.current?.on(host: remote.name)) {
                    try await ReviewPipeline(processRunner: runner, streamingRunner: claudeRunner, tokens: tokens,
                                             gitPath: context.tools.git ?? "git", ghPath: nil, claudePath: remote.claudePath,
                                             settings: context.claude, rules: context.rules, logURLProvider: logURLProvider,
                                             placement: remote).run(request, onPhase: onPhase)
                }
            } catch let failure as ReviewFailure where (failure.underlying as? RemotePreparationFailure) != nil && context.runner?.fallbackToLocal == true {
                let reason = (failure.underlying as! RemotePreparationFailure).shortReason
                await context.onPlacement(prID, .fallback(reason: reason))
                return try await local()
            }
        }
    }
```

> Si el Plan 13 no está, sacar el `ProcessActivity.$current.withValue(…)`.

- [ ] **Step 3: `LiveRespondPipeline`.** `analyze`: igual que el review (local / fallback / remoto, con fallback ante `RemotePreparationFailure` solo si hay `localPath`; si no, se relanza el error del host). Las demás etapas (`implement`, `runTests`, `push`, `cleanup`, `postReplies`): si `draft.runner != nil`, `let remote = try await context.coordinator.placement(for: destination)` con `destination = context.config.runners.destination(named: draft.runner!)` (si ya no existe: `PRBarError.respond("The runner \(name) that has this analysis was removed. Dismiss it and analyze again.")`) y el `RespondPipeline(… placement: remote)`; nunca fallback. `postReplies` corre siempre en la Mac (GitHub). `onPlacement(prID, .remote(host:))` en cada etapa remota.

- [ ] **Step 4: `LiveChatBackend`.** `workspace(_:)`, `send`, `sendEditing`, `undoFiles`, `filesChangedSince` y `cleanup`: el chat de un draft de Respond remoto usa su host (`draft.runner`); el de Review/Merge resuelve el destino del repo como el review (con fallback solo antes del primer mensaje que arma el worktree). El `ChatService` se arma con `placement:`.

- [ ] **Step 5: `AppModel+Runners.swift`:**

```swift
import AppKit
import PRBarCore

extension AppModel: RunnerActions {
    func runnersList() async -> [RunnerInfo] {
        var result: [RunnerInfo] = []
        for destination in configStore.config.runners.destinations {
            let check = runnerChecks[destination.name] ?? (await runners.lastInfo(destination.name))
            result.append(RunnerInfo(destination: destination, isDefault: configStore.config.runners.defaultTarget == .runner(destination.name),
                                     lastCheck: check))
        }
        return result
    }

    func runnerAdd(host: String, name: String?, dir: String?, fallback: Bool) async throws -> RunnerInfo {
        let endpoint = try SSHEndpoint.parse(host)
        let destination = RunnerDestination(name: name ?? endpoint.host, endpoint: endpoint, remoteDir: dir ?? RunnerDestination.defaultRemoteDir,
                                            fallbackToLocal: fallback)
        do { try configStore.update { try $0.addRunner(destination) } } catch {
            throw CommandFailure(.invalidUsage, error.localizedDescription)
        }
        return try await runnerTest(name: destination.name)
    }

    func runnerSet(name: String, dir: String?, fallback: Bool?) throws -> RunnerInfo {
        do {
            try configStore.update { config in
                try config.updateRunner(named: name) { destination in
                    if let dir { destination.remoteDir = dir }
                    if let fallback { destination.fallbackToLocal = fallback }
                }
            }
        } catch let error as RunnerConfigError {
            throw CommandFailure(error == .notFound(name) ? .notFound : .invalidUsage, error.localizedDescription)
        }
        guard let destination = configStore.config.runners.destination(named: name) else { throw CommandFailure(.notFound, "No runner \(name).") }
        Task { await runners.forget(name) }
        return RunnerInfo(destination: destination, isDefault: configStore.config.runners.defaultTarget == .runner(destination.name),
                          lastCheck: runnerChecks[destination.name])
    }

    func runnerRemove(name: String) async throws {
        guard let destination = configStore.config.runners.destination(named: name) else {
            throw CommandFailure(.notFound, RunnerConfigError.notFound(name).localizedDescription)
        }
        try configStore.update { try $0.removeRunner(named: name) }
        runnerChecks[destination.name] = nil
        await runners.forget(destination.name)
        if let host = try? await RunnerCoordinator.liveHost(destination) { await host.closeMaster() }
    }

    func runnerTest(name: String) async throws -> RunnerInfo {
        guard let destination = configStore.config.runners.destination(named: name) else {
            throw CommandFailure(.notFound, RunnerConfigError.notFound(name).localizedDescription)
        }
        let info = await runners.test(destination)
        runnerChecks[destination.name] = info
        return RunnerInfo(destination: destination, isDefault: configStore.config.runners.defaultTarget == .runner(destination.name),
                          lastCheck: info)
    }

    func runnerDefault(target: String) throws {
        guard let parsed = RunTarget(cliValue: target) else { throw CommandFailure(.invalidUsage, "Use local or a runner’s name.") }
        do { try configStore.update { try $0.setDefaultRunTarget(parsed) } } catch {
            throw CommandFailure(.notFound, error.localizedDescription)
        }
    }

    /// Al arrancar (decisión J.7.16): en segundo plano, cada destino que responde limpia sus huérfanos.
    func startRemoteOrphanCleanup() {
        let destinations = configStore.config.runners.destinations
        let runners = self.runners
        Task.detached(priority: .utility) {
            for destination in destinations {
                guard let placement = try? await runners.placement(for: destination) else { continue }
                await placement.workspaces.cleanupOrphans()
            }
        }
    }

    func setPlacement(_ prID: String, _ placement: JobPlacement) { placements[prID] = placement == .local ? nil : placement }
}
```

  En `AppModel.init` (rama `startsServices`, junto a la limpieza de huérfanos local): `startRemoteOrphanCleanup()`. `repoSet` (en `AppModel+Settings`): aplicar `changes.runOn` (`.clear` → `nil`; `.set("local")` → `.local`; `.set(name)` → el destino tiene que existir o `CommandFailure(.notFound, …)`) con `config.setRunOn(_:repoID:login:)`. El `respond` button: donde hoy se exige `localPath` para Responder (buscar el tooltip que lo dice en `RespondButton`/`AppModel`), permitirlo si `RunTargetResolver.destination(for: repoConfig, settings:)` no es nil.

- [ ] **Step 6:** `swift build --product PRBar` sin warnings; `swift build --product PRBarTests && swift run PRBarTests` → verde.

- [ ] **Step 7: Commit.**

```bash
git add Sources/PRBar
git commit -m "Run jobs on the configured host with fallback, and clean the host on startup"
```

---

### Task 18: UI — Settings › Claude › Run On, "Run Claude on" por repo, "on devbox"

**Files:**
- Create: `Sources/PRBar/Settings/RunOnSection.swift`
- Modify: `Sources/PRBar/Settings/ClaudeTab.swift`, `Sources/PRBar/Settings/ReposTab.swift`, `Sources/PRBar/Popover/PRRowView.swift`, `Sources/PRBar/Review/ReviewWindow.swift`, `Sources/PRBar/Respond/RespondWindow.swift`
- Modify: `Sources/PRBarCore/RunnerSettings.swift` (`SSHConfigHosts`), `Sources/PRBarTests/RunnerSettingsTests.swift`, `Sources/PRBarTests/UIActionInventory.swift`

- [ ] **Step 1: Hosts de `~/.ssh/config` (Core, con test).** Test en `RunnerSettingsTests`:

```swift
        TestCase("runners: hosts de ~/.ssh/config sin comodines, con Include de un nivel") {
            let dir = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try Data("Host devbox gpu-1\n  HostName 10.0.0.2\nHost *.internal *\nInclude extra/*.conf\nhost  Lab\n".utf8)
                .write(to: dir.appendingPathComponent("config"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("extra"), withIntermediateDirectories: true)
            try Data("Host build-box\n".utf8).write(to: dir.appendingPathComponent("extra/a.conf"))
            try expectEqual(SSHConfigHosts.hosts(configAt: dir.appendingPathComponent("config")), ["build-box", "devbox", "gpu-1", "Lab"])
        },
```

  Implementación (en `RunnerSettings.swift`):

```swift
/// Los `Host` de `~/.ssh/config` para elegir en "Add SSH Host…" (sin comodines ni negaciones; `Include` relativos a
/// `~/.ssh`, un nivel). Solo para mostrar: lo que se guarda pasa por `SSHEndpoint.parse`.
public enum SSHConfigHosts {
    public static func hosts(configAt url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) -> [String] {
        var found = Set<String>()
        func read(_ file: URL, depth: Int) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: \.isNewline) {
                let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let keyword = parts.first?.lowercased() else { continue }
                if keyword == "host" {
                    for name in parts.dropFirst() where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") && SSHEndpoint.isName(name) {
                        found.insert(name)
                    }
                } else if keyword == "include", depth == 0 {
                    for pattern in parts.dropFirst() {
                        let base = pattern.hasPrefix("/") ? URL(fileURLWithPath: pattern) : url.deletingLastPathComponent().appendingPathComponent(pattern)
                        let directory = base.deletingLastPathComponent()
                        let glob = base.lastPathComponent
                        for entry in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                        where fnmatch(glob, entry.lastPathComponent, 0) == 0 {
                            read(entry, depth: 1)
                        }
                    }
                }
            }
        }
        read(url, depth: 0)
        return found.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
```

- [ ] **Step 2: `Settings/RunOnSection.swift`:**

```swift
import PRBarCore
import SwiftUI

/// Settings › Claude › Run On (spec J.4).
struct RunOnSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var configStore: ConfigStore
    @State private var adding = false
    @State private var testing: Set<String> = []

    private var settings: RunnerSettings { configStore.config.runners }

    var body: some View {
        Section {
            Picker("Run Claude on", selection: Binding(
                get: { settings.defaultTarget },
                set: { target in try? model.runnerDefault(target: target.cliValue) }
            )) {
                Text("This Mac").tag(RunTarget.local)
                ForEach(settings.destinations) { Text($0.name).tag(RunTarget.runner($0.name)) }
            }
            ForEach(settings.destinations) { destination in row(destination) }
            Button("Add SSH Host…") { adding = true }
                .sheet(isPresented: $adding) { AddRunnerSheet(model: model, close: { adding = false }) }
        } header: {
            Text("Run On")
        } footer: {
            Text("Reviews, Respond and PR chats can run on a server over SSH. GitHub and Slack tokens never leave this Mac; the server needs its own git access and Claude login. Each repo can choose in Settings › Repos.")
        }
    }

    private func row(_ destination: RunnerDestination) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(destination.name).font(.body.weight(.semibold))
                Text("\(destination.endpoint.display) · \(destination.remoteDir)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if testing.contains(destination.name) { ProgressView().controlSize(.small) }
                Button("Test Connection") { test(destination.name) }.disabled(testing.contains(destination.name))
                Button("Remove…") {
                    ConfirmAlert.present(title: "Remove \(destination.name)?",
                                         message: "Repos that use it go back to Default. PRBar’s folder on the server isn’t deleted.",
                                         action: "Remove") { Task { try? await model.runnerRemove(name: destination.name) } }
                }
            }
            Toggle("If it’s unreachable, run on this Mac", isOn: Binding(
                get: { destination.fallbackToLocal },
                set: { on in _ = try? model.runnerSet(name: destination.name, dir: nil, fallback: on) }
            ))
            status(model.runnerChecks[destination.name])
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func status(_ check: RunnerHostInfo?) -> some View {
        if let check {
            if check.problems.isEmpty {
                Label("\(check.os ?? "?") · \(check.gitVersion ?? "git ?") · \(check.claudeVersion ?? "claude ?")"
                      + (check.claudeLoggedIn == true ? " · signed in" : ""), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.greenText)
            } else {
                ForEach(check.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.orangeText) }
            }
        } else {
            Text("Not checked yet").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func test(_ name: String) {
        testing.insert(name)
        Task {
            _ = try? await model.runnerTest(name: name)
            testing.remove(name)
        }
    }
}

/// "Add SSH Host…": un `Host` de `~/.ssh/config` o `user@host[:port]`, la carpeta y el fallback.
struct AddRunnerSheet: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var host = ""
    @State private var dir = RunnerDestination.defaultRemoteDir
    @State private var fallback = true
    @State private var error: String?
    @State private var working = false
    private let known = SSHConfigHosts.hosts()

    var body: some View {
        Form {
            if !known.isEmpty {
                Picker("From ~/.ssh/config", selection: $host) {
                    Text("Choose…").tag("")
                    ForEach(known, id: \.self) { Text($0).tag($0) }
                }
            }
            TextField("Host", text: $host, prompt: Text("user@host:port"))
            TextField("Remote folder", text: $dir)
            Toggle("If it’s unreachable, run on this Mac", isOn: $fallback)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.redText) }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction)
                    .disabled(working || (try? SSHEndpoint.parse(host)) == nil || !RunnerDestination.isValidRemoteDir(dir))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        working = true
        Task {
            do {
                _ = try await model.runnerAdd(host: host, name: nil, dir: dir, fallback: fallback)
                close()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
```

  En `ClaudeTab`, una sección `RunOnSection(model: model, configStore: configStore)` **al final** del `Form` (después de "Reset to Defaults" o de la última sección).

- [ ] **Step 3: Repos.** En `ReposTab`, después de `mergeSection(repo)`:

```swift
                Section("Claude") {
                    Picker("Run Claude on", selection: Binding(
                        get: { repo.runOn.map { $0.cliValue } ?? "default" },
                        set: { value in
                            let changes = RepoChanges(runOn: value == "default" ? .clear : .set(value: value))
                            Task { _ = try? await model.repoSet(repo: repo.id, account: login, changes: changes) }
                        }
                    )) {
                        Text("Default (\(configStore.config.runners.defaultTarget == .local ? "This Mac" : configStore.config.runners.defaultTarget.cliValue))").tag("default")
                        Text("This Mac").tag("local")
                        ForEach(configStore.config.runners.destinations) { Text($0.name).tag($0.name) }
                    }
                }
```

- [ ] **Step 4: "on devbox".** En `PRRowView`, junto a la línea de estado de review/respond: `if let label = model.placements[item.id]?.label { Text(label).font(.caption2).foregroundStyle(.secondary) }`. En `ReviewWindow` y `RespondWindow`, debajo del título: el mismo texto para el PR de la ventana.

- [ ] **Step 5: Build e inventario.** `swift build --product PRBar` sin warnings. `swift build --product PRBarTests && swift run PRBarTests "paridad UI"` y agregar lo que pida, con estas entradas (conteos según el test):

```swift
        .init("Settings/RunOnSection.swift", "Picker", "Run Claude on", 1, .cli(["runners default"])),
        .init("Settings/RunOnSection.swift", "Button", "Add SSH Host…", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "Button", "Test Connection", 1, .cli(["runners test"])),
        .init("Settings/RunOnSection.swift", "Button", "Remove…", 1, .cli(["runners remove"])),
        .init("Settings/RunOnSection.swift", "ConfirmAlert", "-", 1, .cli(["runners remove"])),
        .init("Settings/RunOnSection.swift", "Toggle", "If it’s unreachable, run on this Mac", 2, .cli(["runners set", "runners add"])),   // fila y hoja
        .init("Settings/RunOnSection.swift", "Picker", "From ~/.ssh/config", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "TextField", "Host", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "TextField", "Remote folder", 1, .cli(["runners add", "runners set"])),   // --dir
        .init("Settings/RunOnSection.swift", "Button", "Cancel", 1, .viewOnly("closes the sheet")),
        .init("Settings/RunOnSection.swift", "Button", "Add", 1, .cli(["runners add"])),
        .init("Settings/RunOnSection.swift", "Component:AddRunnerSheet", "-", 1, .cli(["runners add"])),
        .init("Settings/ClaudeTab.swift", "Component:RunOnSection", "-", 1, .cli(["runners list"])),
        .init("Settings/ReposTab.swift", "Picker", "Run Claude on", 1, .cli(["repo set"])),   // --run-on
```

  Run: `swift run PRBarTests paridad` → `passed`.

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBar Sources/PRBarCore/RunnerSettings.swift Sources/PRBarTests
git commit -m "Add Settings › Claude › Run On, per-repo Run Claude on and on-host labels"
```

---

### Task 19: Capturas

**Files:**
- Modify: `Sources/PRBar/Snapshots/SnapshotFixtures.swift`, `SnapshotMode.swift`
- Modify: `docs/screenshots/README.md` y PNG

- [ ] **Step 1: Fixtures.** `config.runners` con un destino `devbox` (`fede@devbox.lab`, `~/.prbar`, fallback on) como default, y el repo `acme/api` con `runOn: .runner("devbox")`. `AppModel.applySnapshotState(…)` (o una función nueva `applyRunnerSnapshotState`) llena `runnerChecks["devbox"]` con `RunnerHostInfo(host: "devbox", os: "Linux", arch: "x86_64", gitPath: "/usr/bin/git", gitVersion: "git version 2.43.0", claudePath: "/home/fede/.local/bin/claude", claudeVersion: "2.1.400 (Claude Code)", perl: true, quotingOK: true, root: "/home/fede/.prbar", problems: [], checkedAt: now, claudeLoggedIn: true)` y `placements[loginRedirect.id] = .remote(host: "devbox")`. **Nunca** se conecta nada en el modo de capturas (el coordinador no se usa).
- [ ] **Step 2:** `SnapshotMode.settings()`: subir `.claude` lo que haga falta para la sección Run On (~+220) y `.repos` (~+70).
- [ ] **Step 3:** `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y mirar: `settings-claude-*` (Run On con devbox, "Linux · git version 2.43.0 · 2.1.400 (Claude Code) · signed in", Test Connection, Remove…, el toggle), `settings-repos-*` ("Run Claude on: devbox"), `popover-*` ("on devbox" en la fila del review en curso). Nada cortado.
- [ ] **Step 4:** `docs/screenshots/README.md`: mencionar Run On en `settings-claude` y "on devbox" en `popover`. `Scripts/snapshots.sh docs/screenshots both`, revertir PNG ajenos.
- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBar/Snapshots docs/screenshots
git commit -m "Capture Run On settings and on-host rows"
```

---

### Task 20: Spec J.7, QA y verificación final

**Files:**
- Modify: `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`
- Create: `docs/qa/plan-14-checklist.md`

- [ ] **Step 1: Spec.** Si la parte J ya está en el spec principal, agregar `### J.7 Decisiones de implementación (Plan 14)` con las 20 decisiones y el modelo de amenazas de este plan. Si no está, dejarlo pendiente y avisarlo.

- [ ] **Step 2: Checklist** `docs/qa/plan-14-checklist.md`:

```markdown
# QA manual — Plan 14 (Claude en un servidor por SSH)

Hace falta un host de prueba propio (una VM Linux o una Mac de laboratorio) con: tu clave en `~/.ssh/authorized_keys`,
el host en `~/.ssh/known_hosts` de la Mac, git ≥ 2.31, Perl, Claude Code instalado y logueado (`claude` una vez), acceso
de lectura al repo de prueba (clave de deploy o `gh auth login` **en el host**) y los plugins de los skills elegidos
(`/plugin install …` en el host). Nada de esto se hace con repos reales.

## A. Destinos
- [ ] Settings › Claude › Run On › Add SSH Host…: el picker lista los `Host` de `~/.ssh/config`. Agregar el host: se verifica solo y muestra SO, git, claude y "signed in".
- [ ] `user@host:2222` a mano también funciona; `-oProxyCommand=…` o `a b` no se pueden agregar.
- [ ] Test Connection con Claude deslogueado en el host: "Claude isn’t signed in on …".
- [ ] Una carpeta remota que ya existe con archivos tuyos: "…already exists and isn’t PRBar’s"; no se toca nada.
- [ ] Un host que no está en `known_hosts`: falla (no se agrega la clave sola) salvo que tu ssh config diga `StrictHostKeyChecking accept-new`.
- [ ] `ls -ld /private/tmp/prbar-ssh-$(id -u)` → `drwx------` tuyo.
- [ ] Con `login shell = fish` en el host: Test Connection dice que el shell cambió el texto de prueba.

## B. Review remoto
- [ ] Repo con "Run Claude on: <host>": Review with Claude → la fila dice "on <host>"; en el host aparece `~/.prbar/work/<repo>-<N>-…` mientras corre y desaparece al terminar.
- [ ] `ps -ef` en el host durante el review: `claude -p` **sin** el prompt en los argumentos; `cat /proc/<pid>/environ | tr '\0' '\n'` no tiene `GH_TOKEN`, `SSH_AUTH_SOCK` de la Mac ni nada fuera de la lista blanca.
- [ ] Un PR de prueba con un symlink a `/etc/passwd`: en el worktree remoto es un archivo de texto "[symlink to /etc/passwd omitted by PRBar]".
- [ ] Un PR con rama `feat/$(touch PWNED)`: el review corre y no aparece `PWNED` en ningún lado del host.
- [ ] Stop durante el review: en el host no queda ningún `claude` ni `node` de PRBar (`ps -ef | grep claude`) a los ~5 s.
- [ ] La ventana Activity (Plan 13) lista "Review <repo>#N · ssh … on <host>" sin CPU/RAM.
- [ ] **Verificar que `claude -p` lee el prompt de stdin** con la versión instalada en el host (`printf 'Reply ok' | claude -p --output-format text`): si no, anotarlo como bloqueante.

## C. Fallback
- [ ] Apagar el host (o `sudo ifconfig` / cortar la red): un review cae a esta Mac con "Ran on this Mac — <host> unreachable".
- [ ] Con el fallback apagado (`prbar runners set <host> --fallback off`): el review falla con el error del host.
- [ ] Repo que el host no puede fetchear (sin acceso): "<host> can't fetch <owner>/<repo> — set up git access on the server", y con fallback corre en la Mac.

## D. Respond remoto
- [ ] Respond en un PR propio: el análisis corre en el host (aun sin carpeta local del repo).
- [ ] Implementar 1 fix: el diff que muestra la ventana coincide con `git -C <clone> diff <start>..refs/prbar/remote-<N>-<id>` en la Mac.
- [ ] Antes de pushear, hacer un commit a mano en el worktree remoto (`~/.prbar/work/<…>-respond-<…>`): Push and Reply → "The commits from the server don’t match what you reviewed… Nothing was pushed."
- [ ] Sin tocar nada: Push and Reply pushea desde la Mac (con tu pre-push hook si el repo tiene `localPath`); en GitHub el commit es el revisado.
- [ ] Sin `localPath`: el push sale de `$TMPDIR/PRBar/push/<id>` con el token de la cuenta (no aparece en `ps`), y la carpeta se borra al terminar.
- [ ] Run Tests corre `sh -lc <testCommand>` en el host.

## E. Limpieza
- [ ] Salir de PRBar con un review a medias y volver a abrirla: en el host, `~/.prbar/work`, `jobs` y `tmp` quedan vacíos; `~/.prbar/repos` sigue.
- [ ] Remove… del destino: los repos que lo usaban dicen "Default"; `~/.prbar` sigue en el host (borrarlo a mano).

## F. CLI (con `PRBAR_SOCKET` de la PRBar instalada)
- [ ] `prbar runners add <host>`, `list`, `test <host>` (exit ≠ 0 si hay problemas), `set <host> --dir ~/prbar2`, `default <host>`, `default local`, `remove <host>`.
- [ ] `prbar repo set <owner/repo> --run-on <host>|local|default`.
- [ ] Una `prbar` del protocolo 4 contra esta app (o al revés) pide actualizar.
```

- [ ] **Step 3: Verificación final.**

Run: `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests && swift run PRBarTests`
Expected: sin warnings nuevos; `N/N passed`, tres veces seguidas (hay tests con tiempos: Stop, timeout, caché).

- [ ] **Step 4: Commit.**

```bash
git add docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md docs/qa/plan-14-checklist.md
git commit -m "docs: remote runners implementation decisions and QA checklist"
```

---

## Self-review

- **Cobertura del spec J:**
  - J.1 destinos (This Mac, hosts de `~/.ssh/config` o `user@host[:port]`, carpeta remota, `BatchMode`, `ConnectTimeout=10`, `ControlMaster`/`ControlPersist`, socket 0700, sin contraseñas): Tasks 2, 3, 6, 18. Por repo y global: Tasks 2, 16, 18. Fallback por destino: Tasks 15, 17.
  - J.2 qué corre remoto (review, filtro, análisis, fixes, chats de review/respond/merge) y qué queda local (GitHub, publicar, push, replies, merge, Slack, chat de instrucciones, updater): Tasks 14, 17 (`postReplies` y todo lo de GitHub/Slack siguen en la Mac; el chat de instrucciones y el updater no se tocan).
  - J.3 verificación (y Test Connection con login): Tasks 7, 15; mirror y fetch con credenciales del host + error: Task 12; refs y endurecimiento: Task 12; contexto generado local y subido: Task 12 (`ContextFiles`); Claude remoto con el argv de §8.3 y `env -i` + quoting + test de inyección: Tasks 1, 5, 8; plugins del host: Task 9; stream-json por stdout y Stop: Task 8; fixes con el mismo guardián allá: Tasks 10, 11; bundle → Mac → verificación → push desde la Mac (y clone temporal sin `localPath`): Task 13; limpieza al terminar y huérfanos al arrancar: Tasks 12, 17.
  - J.4 UI y CLI: Tasks 16, 18; Activity: Task 17 (`ProcessActivity.host`).
  - J.5 seguridad: modelo de amenazas arriba; tokens (Tasks 5, 13, 14: test de que ningún token sale), quoting (Task 1), carpeta remota única (Tasks 5, 6, 7), salida del host no confiable (Tasks 10, 13), `known_hosts` (Task 3).
  - J.6 testing: constructor con fuzz (Tasks 1, 3, 5), resolución (Task 2), fallback (Task 15), parseo de la verificación (Task 7), flujo completo contra el `ssh` stub (Task 14) con bundle y verificación (Task 13), Stop y limpieza remota (Tasks 8, 12), errores de fetch y de claude/plugin faltante (Tasks 7, 9, 12).
- **Lo que no es literal al spec** (queda en J.7): el diff que ve el usuario se calcula en la Mac al terminar los fixes (no recién al pushear), el prompt viaja por stdin, el guardián remoto es un recolector en Perl, y los fallbacks solo antes de que arranque Claude.
- **Riesgo conocido:** que `claude -p` lea el prompt de stdin con la versión del host; el QA (B) lo verifica y, si no, el plan cae a pasar el prompt como argumento cuando mide menos de 100 KB (cambiar `promptViaStandardInput` a `false` en `RemotePlacement.claude` y aceptar el límite).
- **Tipos:** `ShellQuote`, `SSHEndpoint`, `RunnerDestination`, `RunTarget`, `RunnerSettings`, `RunTargetResolver`, `SSHCommandBuilder`, `ControlSocketDirectory`, `RemoteRunnerError`, `RemoteExec`, `RemoteEnv`, `RemoteEnvironment`, `RemoteRoot`, `SSHHost`, `RunnerProbe`, `RunnerHostInfo`, `RunnerHealthCache`, `RemoteProcessRunner`, `RemoteLoginRunner`, `StandardInputStreamingRunning`, `RemotePlugins`, `WorkspaceFS`, `LocalWorkspaceFS`, `RemoteWorkspaceFS`, `RemoteGuard`, `ContextFiles`, `RemoteWorkspaces`, `RemoteObjects`, `RemoteFixImport`, `RemotePlacement`, `RemotePreparationFailure`, `JobPlacement`, `RunnerCoordinator`, `RunnerInfo`, `RunnerActions`, `SSHConfigHosts` se definen antes de usarse con esos nombres.
