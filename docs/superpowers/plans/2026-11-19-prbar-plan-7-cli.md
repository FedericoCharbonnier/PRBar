# PRBar — Plan 7: CLI `prbar` (control remoto de la app)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un ejecutable `prbar` que maneja PRBar.app por un socket Unix privado y permite hacer desde la terminal **todo** lo que se hace en la app (popover, ventanas de Review, Respond e Historial, todas las pestañas de Configuración, menús y menús contextuales), con un test de paridad que falla si se agrega una acción a la UI sin su comando.

**Spec:** `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`, **parte C** (más C.4 "Chat" y D.4). Base: `2026-11-18-prbar-design.md`.

**Orden:** 6 (chat, A+B) → 8 (actualizaciones, D) → 9 (instrucciones, E) → **7 (este)**. Este plan usa lo que dejaron:
- plan 6: `ReviewEdits` (estado editable de la ventana de Review, numeración `#N`), `ChatCoordinator` por draft con `reviewEdits`/`selections`, `AppModel.reviewChat(for:)`/`respondChat(for:)`/`discardChat` (Tasks 5, 6, 9, 10, 11);
- plan 8: `AppVersion` y `PRBarCore.version`, `AppModel.appVersion`, `Scripts/bundle.sh --output` (Tasks 13, 14, 23).

Las **Tasks 26, 27 y 28** agregan los comandos de chat (C.4), actualizaciones (D.4) e instrucciones/opciones/prompts (E.7) y dicen al principio qué APIs de los planes 6, 8 y 9 asumen. Los planes 6 y 8 estaban escritos cuando se escribió este y los nombres están alineados; el 9 no, y la Task 28 empieza con una tabla para alinear sus nombres.

**Architecture:**
- **La app es el único actor.** `prbar` nunca escribe `config.json`, ni corre Claude, ni publica: arma un `AppCommand` (Core, `Codable`) y lo manda por `~/Library/Application Support/PRBar/prbar.sock`. En la app, `CommandServer` (Core) lo recibe y `CommandDispatcher` (Core) llama al método correspondiente de los protocolos `*Actions` (Core), que implementa `AppModel` llamando a los mismos métodos que usa la UI.
- **Estado compartido UI ↔ CLI:** el plan 6 ya sacó la selección y los textos del review (`ReviewEdits`) y las decisiones de Respond a un `ChatCoordinator` por draft que vive en `AppModel`. La CLI lee y cambia ese mismo estado; publicar, implementar, responder y pushear suben a métodos de `AppModel` que usan la ventana y la CLI.
- **Protocolo:** una línea JSON por mensaje. Primero `{"hello":{"protocolVersion":1,"version":"…"}}` en los dos sentidos; después `{"id":1,"command":{…}}` → eventos `{"id":1,"event":{…}}` (progreso, texto del chat) y una respuesta final `{"id":1,"ok":true,"result":…}` o `{"id":1,"ok":false,"error":{"code":"…","message":"…"}}`.
- **Seguridad:** socket con `umask 077` (0600) en una carpeta 0700 del usuario, `getpeereid` en cada conexión (otro uid → rechazado), handshake con versión de protocolo, nada de red, tokens solo en el sentido CLI → app (`slack token set`).
- **CLI:** target `PRBarCLIKit` (librería con los comandos de swift-argument-parser, testeable) + target ejecutable `PRBarCLI` (solo `main.swift`). `Scripts/bundle.sh` copia el binario a `PRBar.app/Contents/Helpers/prbar` y, con `--install`, lo enlaza en `~/.local/bin/prbar`.
- **Paridad:** (1) `AppCommand.Name.allCases` ⊆ lo que producen los comandos de `CLIRouter.commands` (verificado parseando un ejemplo de cada comando); (2) un escáner de `Sources/PRBar/**` encuentra cada control de la UI (`Button`, `Toggle`, `Picker`, menús, links, `onPick:`…) y lo compara con `UIActionInventory`, la lista explícita que dice a qué comando corresponde cada uno. Un botón nuevo sin entrada rompe el test.

**Tech Stack:** Swift 5.10 (tools-version 5.10, compilador 6.x), SwiftUI/AppKit, Darwin sockets (`socket`/`bind`/`getpeereid`), `DispatchSource`, swift-argument-parser **1.6.2** (exacta), runner de tests propio (`swift run PRBarTests`).

**Base:** rama `feat/plan-7-cli` desde `main`, con los planes 6 y 8 ya mergeados.

**Convenciones:**
- Tests: `swift run PRBarTests [filtro]`. `expect`/`expectEqual` reciben autoclosures **no** async: primero el `await` a una variable local. Los tests que tocan `@MainActor` van en funciones `@MainActor` que el `TestCase` llama con `try await`.
- **Nunca** bloquear el hilo principal en un test que necesita al `MainActor` (p. ej. la CLI esperando al servidor): esa parte va en `Task.detached`.
- Sockets de test en `/tmp/prbar-<8 hex>/s.sock`: `sun_path` admite 104 bytes y `$TMPDIR` es demasiado largo.
- Commits en inglés, **sin** `Co-Authored-By` ni ninguna atribución a Claude. Sin push.
- UI y mensajes de la CLI en inglés (spec base). Prosa de este plan y comentarios de código en español, como el resto del repo.
- Nunca llamar a GitHub, Slack ni `claude` reales desde los tests.
- Si un paso no compila por un detalle del entorno (firma de una API de Foundation, un nombre que cambió en los planes 6/8), corregir lo mínimo y seguir; no cambiar el diseño.

---

## Decisiones (ambigüedades del spec resueltas)

1. **Binario `PRBarCLI`, instalado como `prbar`.** Un producto `prbar` chocaría con `PRBar` en `.build/` (APFS no distingue mayúsculas). El target se llama `PRBarCLI`; `bundle.sh` lo copia como `Contents/Helpers/prbar`.
2. **Carpeta del socket.** El spec pide el socket en `~/Library/Application Support/PRBar/prbar.sock` y "una carpeta 0700": `CommandServer` pone esa carpeta (la de la app) en 0700 y verifica que sea del usuario. Para desarrollo y tests, `PRBAR_SOCKET` cambia la ruta en la CLI.
3. **El estado de edición sobrevive a la ventana.** Con el plan 6, la selección/textos del review y las decisiones de Respond viven en el coordinador del draft (en `AppModel`) hasta publicar, descartar o volver a analizar, y la CLI puede cambiarlos sin ventana abierta. Por eso las ventanas de Review y Respond **ya no piden confirmación al cerrarse** (no se pierde nada); la confirmación al **reemplazar** el contenido (re-review con cambios) se mantiene.
4. **Numeración de hallazgos.** `<n>` es la del plan 6: la posición en `draft.items + edits.added` desde 1 (incluye los descartados por el filtro y los que agregó el chat), la misma de la ventana y del chat. Los comentarios de Respond se numeran por su posición en el análisis.
5. **`review edit --title`.** El título editado se ve en la ventana y en `review show`; a GitHub va solo el cuerpo (como hoy: `ReviewPublisher` no usa el título).
6. **`--only`** publica esos hallazgos (números o ids) en vez de la selección, sin cambiar la selección guardada.
7. **Confirmaciones.** Exigen `--yes` sin TTY (exit 4): `review publish` (cualquier tipo), `respond push` (también `--anyway`), `respond reply-only`, `slack test` (publica en tu DM) y `update` (reinstala y reinicia la app). `chat --undo` pide confirmación solo si la app avisa que se perderían ediciones manuales (B.6). Las acciones destructivas de configuración que la UI confirma (`repo remove`, `slack token clear`) preguntan en TTY y **no** exigen `--yes` fuera de una terminal. Rechazar una confirmación en la terminal sale con 130 ("Canceled.").
8. **Comandos agregados al listado de C.4** porque la UI los tiene: `history reopen <id>` ("Open to Post"), `history --search`, `review include|exclude --all` (Select All/None), `review publish --no-comments` ("Approve Without Comments…") y `--all-in-body` ("Post Everything in the Review Body"), `respond select --reset` ("Reset to Claude’s Suggestions") y `--no-reply`/`--plan`, `open --posted|--worktree|--copy`, `account reload`, `repo available`, `repo branches`, `repo open`, `follow suggestions`, `notify system-settings`, `claude reset`, `tools list|reset`, `slack check` (Test Connection; `slack test` es el mensaje de prueba al DM, como dice el spec), `slack search-days`, `slack channels`, `slack set rounds` (el toggle "commented xN" que faltaba en la lista del spec), `app logs --slack`, `chat --stop` (botón Stop del chat), `update --skip|--cancel`, `config set update-interval`, `app logs --update`, y de la parte E: `rules chat --undo|--show|--stop`, `rules proposal save|dismiss` (tarjetas "Save as rule"), `respond push --anyway` ("Push Anyway"), `--unignore`, `claude respond set --commit-template|--reply-template`.
9. **`<pr>` se resuelve en la app** (conoce repos, snapshot y colas). Un PR que no está en la lista de PRBar da exit 5 con "Run `prbar prs`".
10. **Salida `--json`:** `{"schemaVersion": 1, "data": …}` con claves ordenadas y fechas ISO 8601. `data` es el DTO del comando (Task 6) documentado en `docs/cli.md`.
11. **Eventos:** el progreso va a stderr (no ensucia `--json`); el texto parcial del chat va a stdout.
12. **Ctrl-C con `--wait`** manda el comando de cancelar por una conexión nueva y sale con 130. Si la CLI se desconecta, el servidor cancela solo las *esperas*; una publicación en curso no se corta (corre en una `Task` aparte).

---

## Estructura de archivos

```
Package.swift                                   (modificar) dependencia swift-argument-parser 1.6.2, targets PRBarCLIKit y PRBarCLI
Package.resolved                                (nuevo, generado)
Scripts/bundle.sh                               (modificar) Contents/Helpers/prbar, firma, link en ~/.local/bin
docs/cli.md                                     (nuevo) referencia de la CLI
docs/qa/plan-7-checklist.md                     (nuevo) verificación manual

Sources/PRBarCore/
  PRReference.swift          owner/repo#N, repo#N, URL → id de PR
  JSONValue.swift            JSON genérico para los resultados
  CommandProtocol.swift      Hello, CommandRequest/Response/Event/Failure, codificación de líneas
  AppCommand.swift           el enum con un caso por acción + AppCommand.Name
  AppCommandTypes.swift      enums y structs de los argumentos (PRListFilter, RepoChanges, …)
  ReviewEdits+CLI.swift      #N/id → hallazgo, setBody/setTitle, Select All, --only; RespondItemReference
  CommandResults.swift       DTOs de las respuestas (ReviewInfo, RespondInfo, …) y sus constructores
  CommandActions.swift       protocolos StatusActions/ReviewActions/RespondActions/ConfigActions/SlackActions
  CommandDispatcher.swift    AppCommand → método del protocolo
  UnixSocket.swift           socket/bind/connect/getpeereid + LineConnection
  CommandServer.swift        servidor (app) y CommandClient (CLI)
  AppVersion+Executable.swift versión del PRBar.app que contiene a prbar (AppVersion es del plan 8)
  Config.swift               (modificar) AppConfig.setBaseBranches
  Support.swift              (modificar) AppPaths.socketFile

Sources/PRBar/
  AppModel.swift             (modificar) publishReview, publishedReviews, acciones de Respond, server, helpers internos
  AppModel+Commands.swift    (nuevo) StatusActions, ReviewActions, RespondActions
  AppModel+Settings.swift    (nuevo) ConfigActions, SlackActions
  AppModel+CommandServer.swift (nuevo) arranque/parada del socket
  AppModel+Chat.swift        (Task 26) ChatCommandActions
  AppModel+UpdateCommands.swift (Task 27) UpdateCommandActions
  AppModel+InstructionCommands.swift (Task 28) InstructionCommandActions
  Review/ReviewWindow.swift  (modificar) publica por AppModel.publishReview
  Respond/RespondWindow.swift (modificar) implementa/responde/pushea por AppModel
  Settings/SettingsView.swift (modificar) SettingsWindow.select(_:)

Sources/PRBarCLIKit/
  PRBarCLIKit.swift          raíz PRBarCommand + PRBarCLIMain
  CLISupport.swift           CLIExit, Terminal, Output, Table, JSONOutput, Style
  AppConnection.swift        conexión, AppLauncher, AppUnavailable
  CLIRunner.swift            RemoteCommand, GlobalOptions, CLIRunner, CLIEnvironment, InterruptHandler
  Interactive.swift          Prompt, Editor, CheckboxList, CheckboxPicker, RawTerminal, Pasteboard, LocalOpen
  Render.swift               helpers de texto
  StatusCommands.swift       status, prs, refresh, open, history, app, version, doctor, completion
  ReviewCommands.swift       review …
  RespondCommands.swift      respond …
  ConfigCommands.swift       config, account, repo, follow, notify, claude, tools
  SlackCommands.swift        slack …
  CLIRouter.swift            tabla comando → AppCommand.Name (paridad)
  ChatCommands.swift         (Task 26) chat …
  UpdateCommands.swift       (Task 27) update …
  RulesCommands.swift        (Task 28) rules …

Sources/PRBarCLI/main.swift  await PRBarCLIMain.run()

Sources/PRBarTests/
  PRReferenceTests.swift, CommandProtocolTests.swift, AppCommandTests.swift, ReviewEditsCLITests.swift,
  CommandResultsTests.swift, CommandDispatcherTests.swift (+ FakeActions), CommandServerTests.swift,
  CLISupportTests.swift, CLIParsingTests.swift, CLIParityTests.swift, UIActionScanner.swift,
  UIActionInventory.swift, UIParityTests.swift, CLIIntegrationTests.swift
```

---

## Inventario: acciones de la UI → comando

Salida del escáner (Task 21) sobre el código actual (antes de los planes 6 y 8), agrupada. Es la lista que codifica `UIActionInventory`; los controles genéricos (componentes) se inventarían donde se usan.

| Lugar | Acción en la UI | Comando |
|---|---|---|
| Barra de menú / popover | Refresh (⌘R), "Try Again" | `prbar refresh` |
| | ⚙︎ History… (⌘Y) | `prbar app history [id]` |
| | ⚙︎ Settings… (⌘,), "Open Settings" | `prbar app settings [tab]` |
| | ⚙︎ Quit PRBar (⌘Q) | `prbar app quit` |
| | Colapsar/expandir sección | (vista; `prbar prs --list …`) |
| | Ver la lista y los avisos | `prbar status`, `prbar prs` |
| Fila de PR | Click en la fila / "Open on GitHub" | `prbar open <pr>` |
| | "Copy Link" | `prbar open <pr> --copy` |
| | Review / "Review with Claude" / Retry | `prbar review <pr> [--wait]` |
| | Píldora en curso (cancelar) / "Cancel Review" | `prbar review cancel <pr>` |
| | "N comments" / "View Review" | `prbar open <pr> --review` (o `prbar review show <pr>`) |
| | "Posted" | `prbar open <pr> --posted` |
| | Error → Show Log | `prbar history show <id> --open-log` |
| | Error → Dismiss | `prbar review dismiss <pr>` |
| | Respond / "Respond with Claude" / Retry | `prbar respond <pr> [--wait]` (con fixes hechos: `prbar respond push`) |
| | Píldora en curso / "Cancel" | `prbar respond cancel <pr>` |
| | "N to review" / "Ready to push" / "Responded" / "View Response" / Error → Open | `prbar open <pr> --respond` (o `prbar respond show <pr>`) |
| | Error → Dismiss | `prbar respond dismiss <pr>` |
| Notificación | "Open" / click | `prbar open <pr> --review|--respond`, `prbar history show <id>` |
| Ventana Review | Casilla de un hallazgo, "Include Anyway"/"Remove" | `prbar review include|exclude <pr> <n>…` |
| | Select All / Select None | `prbar review include|exclude <pr> --all` |
| | Editar el comentario de un hallazgo | `prbar review edit <pr> <n> --body …|--body-file F|--editor` (`--title` también) |
| | Comentario general | `prbar review comment <pr> --text …|--editor` |
| | Comment (⌘↩) / Request Changes | `prbar review publish <pr> --comment|--request-changes [--only 1,3] [--yes]` |
| | Approve (con comentarios) / "Approve Without Comments…" | `prbar review publish <pr> --approve [--no-comments] [--yes]` |
| | "Post Everything in the Review Body" | `prbar review publish … --all-in-body` |
| | "Review Again" (PR cambió) | `prbar review <pr>` |
| | "Open on GitHub", "View on GitHub" (publicado) | `prbar open <pr>`, `prbar open <pr> --posted` |
| | Show full comment, Discarded (N), Close | (vista; `prbar review show <pr> --full`) |
| Ventana Respond | Casillas "Implement fix"/"Reply", plan y respuesta | `prbar respond select <pr> <n>… --implement|--reply-only|--skip [--no-reply] [--reply T] [--plan T]` |
| | "Reset to Claude’s Suggestions" | `prbar respond select <pr> --reset` |
| | "Implement N Fixes" | `prbar respond implement <pr> [--wait]` |
| | "Analyze Again" | `prbar respond <pr>` |
| | "Post N Replies" / "Retry Pending Replies" (sin fixes) | `prbar respond reply-only <pr> [--yes]` |
| | "Push and Reply" / "Retry Pending Replies" (con fixes) | `prbar respond push <pr> [--yes]` |
| | Cancel (cola, análisis, implementación, tests) | `prbar respond cancel <pr>` |
| | "Run Tests" / "Run Again" | `prbar respond test <pr> [--wait]` |
| | Diff, commits, archivos sensibles, salida de tests | `prbar respond diff <pr> [--stat]`, `prbar respond show <pr> --full` |
| | Carpeta (Show Worktree in Finder) | `prbar open <pr> --worktree` |
| | "Open New Analysis" | `prbar open <pr> --respond` |
| | Links a comentarios, commits y respuestas | `prbar respond show <pr>` (imprime las URLs) |
| Historial | Lista, búsqueda, filtro por repo, elegir registro | `prbar history [--repo R] [--kind K] [--search Q] [--limit N]`, `prbar history show <id>` |
| | "Open to Post" | `prbar history reopen <id>` |
| | "Show Response" | `prbar open <pr> --respond` |
| | Show (Claude) Log (in Finder) | `prbar history show <id> --open-log|--reveal-log` |
| | Open PR / View Review on GitHub / Copy PR Link | `prbar open <pr> [--posted|--copy]` |
| Settings › General | Refresh every | `prbar config set refresh-interval 1|2|5|10` |
| | Open at login | `prbar config set launch-at-login on|off` |
| | gh/git/claude: Choose… / Use Automatic | `prbar tools set <tool> <path>`, `prbar tools reset <tool>`, `prbar tools list` |
| | Show notifications | `prbar notify enable|disable` |
| | Cada tipo de notificación | `prbar notify set <kind> on|off`, `prbar notify list` |
| | "Open System Settings…" | `prbar notify system-settings` |
| Settings › Claude | Review skill / Filter findings / Filter skill / Respond skill / Model / Custom… | `prbar claude set --review-skill S --filter on|off --filter-skill S --respond-skill S --model M` |
| | Lista de skills (búsqueda) | `prbar claude skills` |
| | Reset to Defaults | `prbar claude reset` |
| Settings › Accounts | Interruptor por cuenta | `prbar account enable|disable <login>` |
| | Reload / Reload Accounts | `prbar account reload` |
| Settings › Repos | Selector de cuenta / lista de repos | `--account`, `prbar repo list` |
| | Add Repo… (buscar, recargar, reintentar) | `prbar repo available [--reload]`, `prbar repo add <owner/repo>` |
| | Remove… / Remove Repo… / ⌫ | `prbar repo remove <owner/repo>` |
| | Open on GitHub (repo) | `prbar repo open <owner/repo>` |
| | Base branches (elegir, quitar chip, reintentar) | `prbar repo branches <repo> [--reload]`, `prbar repo set <repo> --branches a,b|--add-branch b|--remove-branch b` |
| | People to follow (agregar, escribir login, quitar ✕) | `prbar follow suggestions <repo>`, `prbar follow add|remove <repo> <users…>`, `prbar follow list` |
| | Local folder (Choose…/Remove) | `prbar repo set <repo> --path P|none` |
| | Worktrees (Choose…/Use Default) | `prbar repo set <repo> --worktrees P|default` |
| | Test command | `prbar repo set <repo> --test-command C` (`""` = ninguno) |
| | Slack channel (elegir, recargar) | `prbar slack channels [--reload]`, `prbar repo set <repo> --channel #name|ID|none` |
| Settings › Slack | Use Slack | `prbar slack enable|disable` |
| | Connect with | `prbar slack provider connector|token` |
| | Test Connection | `prbar slack check` |
| | User token / Save and Test | `prbar slack token set [--stdin]` |
| | Delete Token… | `prbar slack token clear` |
| | Send Test to My DM… | `prbar slack test [--yes]` |
| | Show Log | `prbar app logs --slack` |
| | Toggles (announce, Updated, 👀, 💬, rondas, approved) | `prbar slack set <toggle> on|off` |
| | Emoji de cada reacción | `prbar slack emoji eyes|comment|approved <name>` |
| | Search the last N days | `prbar slack search-days <n>` |
| | Plantillas (editar, Insert Variable, Reset to Default) | `prbar slack template list|show|set|reset` |
| | Guía "How to get a user token", link a api.slack.com | (vista; está en `docs/cli.md`) |
| Menú de la app (con ventana) | About PRBar | `prbar version` |
| | Settings… / Quit PRBar | `prbar app settings` / `prbar app quit` |
| | Hide/Show, Edit (Undo…Select All), Window (Minimize, Close) | (vista) |
| Plan 6 (chat) | Chat (⌘⇧C), mensaje, ↩, Stop, Undo | `prbar chat <pr> ["msg"]` (REPL sin mensaje), `--stop`, `--undo`, `--show` |
| | Show Log de un mensaje con error | `prbar history show <id> --open-log` |
| | Settings › Claude › Chat (switch, modelo) | `prbar claude set --chat on|off --chat-model M|same` |
| Plan 8 (updates) | Check for Updates, "Update…", Update / Update When Done / Cancel Jobs and Update / Skip This Version / Cancel / Show Log | `prbar update --check`, `prbar update [--yes] [--cancel-jobs]`, `prbar update --skip`, `prbar update --cancel`, `prbar app logs --update` |
| | Check automatically / intervalo | `prbar config set update-interval <horas>` (0 = solo manual) |
| Plan 9 (instrucciones) | Settings › Instructions (reglas: texto, chips, switch, borrar, agregar), su chat, "Save as rule" en el chat del PR, sugerencias (Create Rule / Not Now / Never) | `prbar rules list|add|edit|remove|enable|disable`, `prbar rules chat`, `prbar rules proposal save|dismiss`, `prbar rules suggestions accept|dismiss|never` |
| | Opciones de review y fixes, prompts por etapa, globs por repo, "Push Anyway" | `prbar claude review set`, `prbar claude respond set`, `prbar claude stage`, `prbar claude prompt show|edit|reset`, `prbar repo set --ignore`, `prbar respond push --anyway` |
| Sin app | — | `prbar doctor`, `prbar version`, `prbar completion zsh|bash|fish`, `prbar app start`, `prbar app logs`, `prbar repo open`, `prbar notify system-settings` |

---

### Task 1: Dependencia swift-argument-parser y targets de la CLI

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PRBarCLIKit/PRBarCLIKit.swift`, `Sources/PRBarCLI/main.swift`, `Sources/PRBarTests/CLISmokeTests.swift`
- Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Test que falla**

`Sources/PRBarTests/CLISmokeTests.swift`:

```swift
import Foundation
import PRBarCLIKit

enum CLISmokeTests {
    static let cases: [TestCase] = [
        TestCase("cli: el kit compila y se llama prbar") {
            try expectEqual(PRBarCLIKit.commandName, "prbar")
        },
    ]
}
```

En `Sources/PRBarTests/main.swift`, agregar `+ CLISmokeTests.cases` al final de `allTests` (después de `SnapshotOptionsTests.cases` o de lo último que hayan agregado los planes 6 y 8).

- [ ] **Step 2: Correr y ver que falla**

Run: `swift build --product PRBarTests 2>&1 | tail -3`
Expected: error `no such module 'PRBarCLIKit'`.

- [ ] **Step 3: Package.swift**

Reemplazar `Package.swift` por (si el plan 8 agregó algo —recursos, otro target—, conservarlo y sumar solo lo de abajo):

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PRBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PRBar", targets: ["PRBar"]),
        // Se instala como `prbar` (Contents/Helpers/prbar): un producto `prbar` chocaría con `PRBar` en .build/
        // porque APFS no distingue mayúsculas.
        .executable(name: "PRBarCLI", targets: ["PRBarCLI"]),
    ],
    dependencies: [
        // Primera y única dependencia externa (spec C.3). Versión exacta: subirla es un cambio explícito.
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.2"),
    ],
    targets: [
        .target(name: "PRBarCore"),
        .executableTarget(name: "PRBar", dependencies: ["PRBarCore"]),
        .target(name: "PRBarCLIKit", dependencies: [
            "PRBarCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "PRBarCLI", dependencies: ["PRBarCLIKit"]),
        .executableTarget(name: "PRBarTests", dependencies: ["PRBarCore", "PRBarCLIKit"]),
    ]
)
```

`Sources/PRBarCLIKit/PRBarCLIKit.swift`:

```swift
/// Comandos de `prbar` (spec C). El ejecutable `PRBarCLI` solo llama a `PRBarCLIMain.run()` (Task 14).
public enum PRBarCLIKit {
    public static let commandName = "prbar"
}
```

`Sources/PRBarCLI/main.swift` (provisorio hasta la Task 14):

```swift
import PRBarCLIKit

print(PRBarCLIKit.commandName)
```

- [ ] **Step 4: Compilar y correr**

Run: `swift build 2>&1 | tail -3 && swift run PRBarTests cli: && swift run PRBarCLI`
Expected: resuelve `swift-argument-parser` 1.6.2, `1/1 passed` y la CLI imprime `prbar`. Verificar que `Package.resolved` dice `"version" : "1.6.2"`.

Run: `swift run PRBarTests`
Expected: todos pasan.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources/PRBarCLIKit Sources/PRBarCLI Sources/PRBarTests/CLISmokeTests.swift Sources/PRBarTests/main.swift
git commit -m "Add swift-argument-parser and the PRBarCLI targets"
```

---

### Task 2: Referencias de PR (`PRReference`)

**Files:**
- Create: `Sources/PRBarCore/PRReference.swift`, `Sources/PRBarTests/PRReferenceTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ PRReferenceTests.cases`)

- [ ] **Step 1: Tests**

```swift
import Foundation
import PRBarCore

enum PRReferenceTests {
    static let cases: [TestCase] = [
        TestCase("pr ref: owner/repo#N, repo#N y URL") {
            try expectEqual(PRReference.parse("acme/api#12"), .full(owner: "acme", repo: "api", number: 12))
            try expectEqual(PRReference.parse("api#12"), .short(repo: "api", number: 12))
            try expectEqual(PRReference.parse("https://github.com/acme/api/pull/12"), .full(owner: "acme", repo: "api", number: 12))
            try expectEqual(PRReference.parse("https://github.com/acme/api/pull/12/files#diff-1"),
                            .full(owner: "acme", repo: "api", number: 12))
            try expectEqual(PRReference.parse(" acme/my.repo_2#3 "), .full(owner: "acme", repo: "my.repo_2", number: 3))
        },
        TestCase("pr ref: rechaza lo que no es un PR") {
            let invalid = ["", "acme/api", "api#", "api#0", "api#-1", "a/b/c#1", "#4", "ac me/api#1",
                           "https://github.com/acme/api/issues/3", "https://example.com/acme/api/pull/3"]
            for text in invalid {
                try expect(PRReference.parse(text) == nil, text)
            }
        },
        TestCase("pr ref: resolve sin distinguir mayúsculas y con repo corto único") {
            let ids = ["acme/api#12", "acme/web#12", "other/api#3"]
            try expectEqual(PRReference.full(owner: "ACME", repo: "Api", number: 12).resolve(among: ids), .success("acme/api#12"))
            try expectEqual(PRReference.short(repo: "web", number: 12).resolve(among: ids), .success("acme/web#12"))
            try expectEqual(PRReference.short(repo: "api", number: 9).resolve(among: ids), .failure(.notFound))
            try expectEqual(PRReference.full(owner: "acme", repo: "api", number: 3).resolve(among: ids), .failure(.notFound))
        },
        TestCase("pr ref: repo corto ambiguo") {
            let ids = ["other/api#3", "acme/api#3"]
            try expectEqual(PRReference.short(repo: "api", number: 3).resolve(among: ids),
                            .failure(.ambiguous(["acme/api#3", "other/api#3"])))
        },
        TestCase("pr ref: URL de GitHub a partir del id") {
            try expectEqual(PRReference.githubURL(prID: "acme/api#12")?.absoluteString, "https://github.com/acme/api/pull/12")
            try expectEqual(PRReference.githubURL(prID: "nope"), nil)
        },
    ]
}
```

- [ ] **Step 2: Registrar en `main.swift` y ver que falla**

Run: `swift run PRBarTests "pr ref"`
Expected: no compila (`cannot find 'PRReference'`).

- [ ] **Step 3: Implementar `Sources/PRBarCore/PRReference.swift`**

```swift
import Foundation

/// Cómo la CLI nombra un PR (spec C.4): `owner/repo#N`, `repo#N` (si es único) o la URL del PR.
public enum PRReference: Equatable, Sendable {
    case full(owner: String, repo: String, number: Int)
    case short(repo: String, number: Int)

    public enum ResolveError: Error, Equatable, Sendable {
        case notFound
        /// Varios PRs con el mismo `repo#N` en owners distintos (ordenados).
        case ambiguous([String])
    }

    public static func parse(_ text: String) -> PRReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let host = url.host?.lowercased() {
            guard host == "github.com" || host == "www.github.com" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]), number > 0,
                  isValidName(parts[0]), isValidName(parts[1]) else { return nil }
            return .full(owner: parts[0], repo: parts[1], number: number)
        }
        guard let hash = trimmed.lastIndex(of: "#"), let number = Int(trimmed[trimmed.index(after: hash)...]),
              number > 0 else { return nil }
        let pieces = trimmed[..<hash].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if pieces.count == 1, isValidName(pieces[0]) { return .short(repo: pieces[0], number: number) }
        if pieces.count == 2, isValidName(pieces[0]), isValidName(pieces[1]) {
            return .full(owner: pieces[0], repo: pieces[1], number: number)
        }
        return nil
    }

    /// Nombre de owner o repo de GitHub: letras, números, `-`, `_` y `.`.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// El id (`owner/repo#N`) entre `candidates`, sin distinguir mayúsculas.
    public func resolve(among candidates: [String]) -> Result<String, ResolveError> {
        let unique = Array(Set(candidates))
        switch self {
        case .full(let owner, let repo, let number):
            let wanted = "\(owner)/\(repo)#\(number)".lowercased()
            if let match = unique.first(where: { $0.lowercased() == wanted }) { return .success(match) }
            return .failure(.notFound)
        case .short(let repo, let number):
            let suffix = "/\(repo)#\(number)".lowercased()
            let matches = unique.filter { $0.lowercased().hasSuffix(suffix) }.sorted()
            switch matches.count {
            case 0: return .failure(.notFound)
            case 1: return .success(matches[0])
            default: return .failure(.ambiguous(matches))
            }
        }
    }

    /// `owner/repo#N` → `https://github.com/owner/repo/pull/N`.
    public static func githubURL(prID: String) -> URL? {
        guard case .full(let owner, let repo, let number)? = parse(prID) else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)/pull/\(number)")
    }
}
```

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests "pr ref"`
Expected: `5/5 passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/PRReference.swift Sources/PRBarTests/PRReferenceTests.swift Sources/PRBarTests/main.swift
git commit -m "Add PRReference: parse and resolve PR references for the CLI"
```

---

### Task 3: `JSONValue` y mensajes del protocolo

**Files:**
- Create: `Sources/PRBarCore/JSONValue.swift`, `Sources/PRBarCore/CommandProtocol.swift`, `Sources/PRBarTests/CommandProtocolTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ CommandProtocolTests.cases`)

- [ ] **Step 1: Tests**

```swift
import Foundation
import PRBarCore

private struct Sample: Codable, Equatable {
    let name: String
    let count: Int
    let when: Date
}

enum CommandProtocolTests {
    static let cases: [TestCase] = [
        TestCase("protocolo: JSONValue distingue bool, int, double, null, array y object") {
            let line = #"{"a":1,"b":[true,null,"x",1.5],"c":{"d":false}}"#
            let value = try CommandProtocol.decode(JSONValue.self, line: line)
            try expectEqual(value, .object([
                "a": .int(1), "b": .array([.bool(true), .null, .string("x"), .double(1.5)]), "c": .object(["d": .bool(false)]),
            ]))
            try expectEqual(try CommandProtocol.line(value), line)
        },
        TestCase("protocolo: JSONValue ida y vuelta de un Codable (fechas ISO 8601)") {
            let sample = Sample(name: "x", count: 3, when: t0)
            let value = try JSONValue(encoding: sample)
            try expectEqual(value, .object(["name": .string("x"), "count": .int(3), "when": .string("2027-01-15T08:00:00Z")]))
            try expectEqual(try value.decode(Sample.self), sample)
        },
        TestCase("protocolo: líneas estables de respuesta, error, evento y hello") {
            try expectEqual(try CommandProtocol.line(CommandResponse.success(id: 1, .object(["ok": .bool(true)]))),
                            #"{"id":1,"ok":true,"result":{"ok":true}}"#)
            try expectEqual(try CommandProtocol.line(CommandResponse.failure(id: 2, CommandFailure(.notFound, "No PR"))),
                            #"{"error":{"code":"notFound","message":"No PR"},"id":2,"ok":false}"#)
            try expectEqual(try CommandProtocol.line(CommandResponse.event(id: 3, .progress(message: "Reviewing…"))),
                            #"{"event":{"progress":{"message":"Reviewing…"}},"id":3}"#)
            try expectEqual(try CommandProtocol.line(HelloMessage(hello: Hello(protocolVersion: 1, version: "1.0.0"))),
                            #"{"hello":{"protocolVersion":1,"version":"1.0.0"}}"#)
        },
        TestCase("protocolo: la línea nunca tiene saltos (el texto con \\n va escapado)") {
            let line = try CommandProtocol.line(CommandResponse.event(id: 1, .text(delta: "a\nb")))
            try expect(!line.contains("\n"), line)
        },
        TestCase("protocolo: mensaje de versiones incompatibles") {
            try expectEqual(CommandFailure.protocolMismatch(cli: "1.3.0", app: "1.2.0").message,
                            "prbar 1.3.0 can't talk to PRBar 1.2.0 — run `prbar update` or reinstall")
        },
    ]
}
```

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests protocolo`
Expected: no compila (`cannot find 'CommandProtocol'`).

- [ ] **Step 3: Implementar**

`Sources/PRBarCore/JSONValue.swift`:

```swift
import Foundation

/// Un valor JSON cualquiera: el `result` de una respuesta (cada comando devuelve su DTO, ver `CommandResults`).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// `{"ok": true}`: la respuesta de los comandos que no devuelven nada.
    public static let ok = JSONValue.object(["ok": .bool(true)])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// El JSON de `value` (con la codificación del protocolo: fechas ISO 8601).
    public init<T: Encodable>(encoding value: T) throws {
        self = try CommandProtocol.decoder.decode(JSONValue.self, from: CommandProtocol.encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try CommandProtocol.decoder.decode(T.self, from: CommandProtocol.encoder.encode(self))
    }
}
```

`Sources/PRBarCore/CommandProtocol.swift`:

```swift
import Foundation

/// Protocolo entre `prbar` y PRBar.app por el socket (spec C.2): una línea JSON por mensaje.
///
/// 1. La CLI manda `HelloMessage` con su versión de protocolo; la app contesta con la suya o con un error
///    `protocolMismatch` y cierra.
/// 2. Cada pedido es un `CommandRequest`; la app manda cero o más `CommandResponse` con `event` y una final con
///    `ok` + `result` o `error`.
public enum CommandProtocol {
    /// Sube cuando un cambio rompe la compatibilidad entre la CLI y la app.
    public static let version = 1

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sin `.prettyPrinted`: la línea nunca tiene `\n`.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func line<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: String) throws -> T {
        try decoder.decode(T.self, from: Data(line.utf8))
    }
}

public struct Hello: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// Versión de quien manda el mensaje (`prbar` o PRBar.app), para los mensajes de error.
    public var version: String

    public init(protocolVersion: Int, version: String) {
        self.protocolVersion = protocolVersion
        self.version = version
    }
}

public struct HelloMessage: Codable, Equatable, Sendable {
    public var hello: Hello

    public init(hello: Hello) {
        self.hello = hello
    }
}

/// Error de un comando. `code` decide el exit code de la CLI (`CLIExit`); `message` es el texto de la UI más el
/// comando sugerido cuando aplica (spec C.6).
public struct CommandFailure: Error, Codable, Equatable, Sendable, LocalizedError {
    public enum Code: String, Codable, Sendable {
        case invalidUsage, notFound, invalidState, confirmationRequired, failed, cancelled, protocolMismatch, unauthorized
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func protocolMismatch(cli: String, app: String) -> CommandFailure {
        CommandFailure(.protocolMismatch, "prbar \(cli) can't talk to PRBar \(app) — run `prbar update` or reinstall")
    }
}

/// Lo que manda la app mientras corre un comando largo (`--wait`, chat, update).
public enum CommandEvent: Codable, Equatable, Sendable {
    /// Una línea de progreso ("Reviewing (2 agents)…").
    case progress(message: String)
    /// Texto parcial (la respuesta del chat en streaming).
    case text(delta: String)
}

public typealias CommandEventSink = @Sendable (CommandEvent) -> Void

public struct CommandResponse: Codable, Equatable, Sendable {
    public var id: Int
    /// `nil` en los eventos.
    public var ok: Bool?
    public var result: JSONValue?
    public var error: CommandFailure?
    public var event: CommandEvent?

    public init(id: Int, ok: Bool? = nil, result: JSONValue? = nil, error: CommandFailure? = nil, event: CommandEvent? = nil) {
        self.id = id
        self.ok = ok
        self.result = result
        self.error = error
        self.event = event
    }

    public static func success(id: Int, _ result: JSONValue) -> CommandResponse {
        CommandResponse(id: id, ok: true, result: result)
    }

    public static func failure(id: Int, _ error: CommandFailure) -> CommandResponse {
        CommandResponse(id: id, ok: false, error: error)
    }

    public static func event(id: Int, _ event: CommandEvent) -> CommandResponse {
        CommandResponse(id: id, event: event)
    }
}
```

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests protocolo`
Expected: `5/5 passed`. Si el primer test falla porque el decodificador de Foundation lee `1` como `Bool`, invertir el orden (probar `Int` antes que `Bool`) y volver a correr.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/JSONValue.swift Sources/PRBarCore/CommandProtocol.swift Sources/PRBarTests/CommandProtocolTests.swift Sources/PRBarTests/main.swift
git commit -m "Add the CLI wire protocol: JSONValue, hello, responses, events and failures"
```

---

### Task 4: `AppCommand`

Un caso por acción de la app (spec C.2/C.4), **sin** chat ni updates (Tasks 26 y 27). `AppCommand.Name` (`CaseIterable`) es la lista que recorre el test de paridad.

**Files:**
- Create: `Sources/PRBarCore/AppCommandTypes.swift`, `Sources/PRBarCore/AppCommand.swift`, `Sources/PRBarTests/AppCommandTests.swift`
- Modify: `Sources/PRBarCore/CommandProtocol.swift` (agregar `CommandRequest`), `Sources/PRBarTests/main.swift` (`+ AppCommandTests.cases`)

- [ ] **Step 1: Tests**

```swift
import Foundation
import PRBarCore

enum AppCommandTests {
    static let cases: [TestCase] = [
        TestCase("app command: JSON estable con etiquetas") {
            try expectEqual(try CommandProtocol.line(AppCommand.reviewStart(pr: "acme/api#1", wait: true)),
                            #"{"reviewStart":{"pr":"acme/api#1","wait":true}}"#)
            try expectEqual(try CommandProtocol.line(AppCommand.status), #"{"status":{}}"#)
            try expectEqual(try CommandProtocol.line(CommandRequest(id: 7, command: .refresh)),
                            #"{"command":{"refresh":{}},"id":7}"#)
            try expectEqual(try CommandProtocol.line(AppCommand.repoSet(repo: "acme/api", account: nil,
                                                                         changes: RepoChanges(localPath: .clear))),
                            #"{"repoSet":{"changes":{"addBranches":[],"localPath":{"clear":{}},"removeBranches":[]},"repo":"acme/api"}}"#)
        },
        TestCase("app command: ida y vuelta de comandos variados") {
            let commands: [AppCommand] = [
                .listPRs(list: .toReview, account: "me"),
                .history(repo: "acme/api", kind: .respond, limit: 5, search: "login"),
                .open(pr: "api#3", target: .posted),
                .reviewPublish(pr: "acme/api#1", event: .approve, only: ["1", "f3"], withComments: true, allInBody: false,
                               confirmed: true),
                .respondSelect(pr: "acme/web#2", items: ["1"], change: RespondSelectionChange(implement: true, replyText: "Done")),
                .claudeSet(changes: ClaudeChanges(filterEnabled: false, model: .set(value: "sonnet"))),
                .slackSetToggle(toggle: .reactStart, enabled: false),
                .slackTemplateSet(template: .newPR, text: "{link}"),
                .toolsSet(tool: .gh, path: nil),
            ]
            for command in commands {
                let decoded = try CommandProtocol.decode(AppCommand.self, line: try CommandProtocol.line(command))
                try expectEqual(decoded, command)
            }
        },
        TestCase("app command: Name tiene un caso por comando") {
            try expectEqual(AppCommand.Name.allCases.count, 69)
            try expectEqual(AppCommand.slackTokenSet(token: "xoxp-secret").name, .slackTokenSet)
            try expectEqual(AppCommand.reviewCancel(pr: "x").name.rawValue, "reviewCancel")
        },
        TestCase("app command: RespondSelectionChange aplica en orden") {
            var selection = RespondSelection(implement: true, fixPlan: "p", reply: false, replyText: "")
            RespondSelectionChange(implement: false, reply: true).apply(to: &selection)
            try expectEqual(selection, RespondSelection(implement: false, fixPlan: "p", reply: true, replyText: ""))
            RespondSelectionChange(replyText: "Thanks", fixPlan: "new plan").apply(to: &selection)
            try expectEqual(selection, RespondSelection(implement: false, fixPlan: "new plan", reply: true, replyText: "Thanks"))
            RespondSelectionChange(reply: false, replyText: "x").apply(to: &selection)
            try expectEqual(selection.reply, false)
        },
        TestCase("app command: nombres de toggles, notificaciones, emojis y plantillas cubren los de la config") {
            try expectEqual(Set(SlackToggleName.allCases.map(\.toggle)).count, SlackToggle.allCases.count)
            try expectEqual(Set(SlackTemplateName.allCases.map(\.kind)).count, SlackTemplateKind.allCases.count)
            try expectEqual(NotificationSettingName.allCases.count, 5)
            var settings = NotificationSettings()
            for kind in NotificationSettingName.allCases { settings[keyPath: kind.keyPath] = false }
            try expect(!settings.newToReview && !settings.reviewedPRUpdated && !settings.myPRFeedback
                       && !settings.reviewFinished && !settings.myPRApprovedOrCIFailed)
            try expectEqual(PRListFilter.mine.category, .myFeedback)
        },
    ]
}
```

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests "app command"`
Expected: no compila.

- [ ] **Step 3: Implementar**

`Sources/PRBarCore/AppCommandTypes.swift`:

```swift
import Foundation

/// `prbar prs --list`.
public enum PRListFilter: String, Codable, CaseIterable, Sendable {
    case toReview = "to-review", updated, mine, other

    public var category: PRCategory {
        switch self {
        case .toReview: .toReview
        case .updated: .updatedSinceMyReview
        case .mine: .myFeedback
        case .other: .other
        }
    }
}

public enum HistoryKind: String, Codable, CaseIterable, Sendable {
    case review, respond
}

/// `prbar open <pr> --…`.
public enum OpenTarget: String, Codable, CaseIterable, Sendable {
    /// El PR en el navegador.
    case browser
    /// Ventana de Review (listo o publicado).
    case review
    /// Ventana de Responder.
    case respond
    /// La review publicada, en el navegador.
    case posted
    /// El worktree de Responder, en Finder.
    case worktree
}

public enum SettingsTabName: String, Codable, CaseIterable, Sendable {
    case general, claude, accounts, repos, slack
}

public enum NotificationSettingName: String, Codable, CaseIterable, Sendable {
    case newToReview = "new-to-review"
    case reviewedUpdated = "reviewed-updated"
    case myFeedback = "my-feedback"
    case reviewFinished = "review-finished"
    case approvedOrCI = "approved-or-ci"

    public var keyPath: WritableKeyPath<NotificationSettings, Bool> {
        switch self {
        case .newToReview: \.newToReview
        case .reviewedUpdated: \.reviewedPRUpdated
        case .myFeedback: \.myPRFeedback
        case .reviewFinished: \.reviewFinished
        case .approvedOrCI: \.myPRApprovedOrCIFailed
        }
    }
}

public enum ToolName: String, Codable, CaseIterable, Sendable {
    case gh, git, claude

    public var keyPath: WritableKeyPath<ToolPaths, String?> {
        switch self {
        case .gh: \.gh
        case .git: \.git
        case .claude: \.claude
        }
    }
}

/// `prbar slack set <toggle>`: los interruptores de la pestaña Slack.
public enum SlackToggleName: String, Codable, CaseIterable, Sendable {
    case announce, updated
    case reactStart = "react-start"
    case reactComment = "react-comment"
    case rounds
    case reactApprove = "react-approve"

    public var toggle: SlackToggle {
        switch self {
        case .announce: .announceNewPRs
        case .updated: .postUpdated
        case .reactStart: .reactOnReviewStart
        case .reactComment: .reactOnFirstComment
        case .rounds: .postRoundMessages
        case .reactApprove: .reactOnApprove
        }
    }
}

public enum SlackEmojiKind: String, Codable, CaseIterable, Sendable {
    case eyes, comment, approved

    public var keyPath: WritableKeyPath<SlackSettings, String> {
        switch self {
        case .eyes: \.eyesEmoji
        case .comment: \.commentEmoji
        case .approved: \.approvedEmoji
        }
    }
}

public enum SlackTemplateName: String, Codable, CaseIterable, Sendable {
    case newPR = "new-pr", update, round

    public var kind: SlackTemplateKind {
        switch self {
        case .newPR: .newPR
        case .update: .update
        case .round: .round
        }
    }
}

/// Cambiar un valor opcional: ponerle uno o sacarlo (`--path none`, `--model default`).
public enum ValueChange: Codable, Equatable, Sendable {
    case set(value: String)
    case clear

    public var value: String? {
        if case .set(let value) = self { return value }
        return nil
    }
}

/// `prbar repo set`. `nil` = no se toca.
public struct RepoChanges: Codable, Equatable, Sendable {
    public var localPath: ValueChange?
    public var worktreeDir: ValueChange?
    public var testCommand: ValueChange?
    /// Reemplaza la lista entera (`--branches a,b`; vacía = la rama por defecto).
    public var baseBranches: [String]?
    public var addBranches: [String]
    public var removeBranches: [String]
    /// `#nombre` o id del canal; `.clear` = sin anuncios.
    public var channel: ValueChange?

    public init(localPath: ValueChange? = nil, worktreeDir: ValueChange? = nil, testCommand: ValueChange? = nil,
                baseBranches: [String]? = nil, addBranches: [String] = [], removeBranches: [String] = [],
                channel: ValueChange? = nil) {
        self.localPath = localPath
        self.worktreeDir = worktreeDir
        self.testCommand = testCommand
        self.baseBranches = baseBranches
        self.addBranches = addBranches
        self.removeBranches = removeBranches
        self.channel = channel
    }

    public var isEmpty: Bool { self == RepoChanges() }
    public var changesBranches: Bool { baseBranches != nil || !addBranches.isEmpty || !removeBranches.isEmpty }
}

/// `prbar claude set`. `nil` = no se toca; `model: .clear` = el modelo por defecto de Claude Code.
public struct ClaudeChanges: Codable, Equatable, Sendable {
    public var reviewSkill: String?
    public var filterEnabled: Bool?
    public var filterSkill: String?
    public var respondSkill: String?
    public var model: ValueChange?

    public init(reviewSkill: String? = nil, filterEnabled: Bool? = nil, filterSkill: String? = nil,
                respondSkill: String? = nil, model: ValueChange? = nil) {
        self.reviewSkill = reviewSkill
        self.filterEnabled = filterEnabled
        self.filterSkill = filterSkill
        self.respondSkill = respondSkill
        self.model = model
    }

    public var isEmpty: Bool { self == ClaudeChanges() }
}

/// `prbar respond select`: qué cambiar de la decisión de cada comentario. Se aplica en este orden: `implement`,
/// `reply`, `replyText` (que enciende "Reply", salvo que `reply` sea `false`) y `fixPlan`.
public struct RespondSelectionChange: Codable, Equatable, Sendable {
    public var implement: Bool?
    public var reply: Bool?
    public var replyText: String?
    public var fixPlan: String?

    public init(implement: Bool? = nil, reply: Bool? = nil, replyText: String? = nil, fixPlan: String? = nil) {
        self.implement = implement
        self.reply = reply
        self.replyText = replyText
        self.fixPlan = fixPlan
    }

    public var isEmpty: Bool { self == RespondSelectionChange() }

    public func apply(to selection: inout RespondSelection) {
        if let implement { selection.implement = implement }
        if let reply { selection.reply = reply }
        if let replyText {
            selection.replyText = replyText
            if reply != false { selection.reply = true }
        }
        if let fixPlan { selection.fixPlan = fixPlan }
    }
}
```

`Sources/PRBarCore/AppCommand.swift`:

```swift
import Foundation

/// Una acción de PRBar, tal como la manda `prbar` (spec C.2). Cada caso corresponde a un método de los protocolos
/// `*Actions` (`CommandDispatcher`) y a uno o más comandos de la CLI (`CLIRouter`). `<pr>` va tal cual lo escribió
/// el usuario: lo resuelve la app (`PRReference`).
public enum AppCommand: Codable, Equatable, Sendable {
    // Estado
    case status
    case listPRs(list: PRListFilter?, account: String?)
    case resolvePR(pr: String)
    case history(repo: String?, kind: HistoryKind?, limit: Int?, search: String?)
    case historyShow(id: String)
    case historyReopen(id: String)
    case refresh
    // Ventanas / app
    case open(pr: String, target: OpenTarget)
    case openSettings(tab: SettingsTabName?)
    case openHistory(id: String?)
    case quit
    // Review (PR ajeno)
    case reviewStart(pr: String, wait: Bool)
    case reviewShow(pr: String)
    case reviewEdit(pr: String, finding: String, title: String?, body: String?)
    case reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool)
    case reviewSetComment(pr: String, text: String)
    case reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool, allInBody: Bool, confirmed: Bool)
    case reviewCancel(pr: String)
    case reviewDismiss(pr: String)
    // Respond (mi PR)
    case respondStart(pr: String, wait: Bool)
    case respondShow(pr: String)
    case respondSelect(pr: String, items: [String], change: RespondSelectionChange)
    case respondReset(pr: String)
    case respondImplement(pr: String, wait: Bool)
    case respondTest(pr: String, wait: Bool)
    case respondDiff(pr: String)
    case respondPush(pr: String, confirmed: Bool, wait: Bool)
    case respondReplyOnly(pr: String, confirmed: Bool, wait: Bool)
    case respondCancel(pr: String)
    case respondDismiss(pr: String)
    // Configuración
    case configShow
    case setRefreshInterval(minutes: Int)
    case setLaunchAtLogin(enabled: Bool)
    case accountList
    case accountSetEnabled(login: String, enabled: Bool)
    case accountReload
    case repoList(account: String?)
    case repoAvailable(account: String?, reload: Bool)
    case repoAdd(repo: String, account: String?)
    case repoRemove(repo: String, account: String?)
    case repoSet(repo: String, account: String?, changes: RepoChanges)
    case repoBranches(repo: String, account: String?, reload: Bool)
    case followList(repo: String?, account: String?)
    case followAdd(repo: String, users: [String], account: String?)
    case followRemove(repo: String, users: [String], account: String?)
    case followSuggestions(repo: String, account: String?)
    case notifyList
    case notifySet(kind: NotificationSettingName, enabled: Bool)
    case notifySetEnabled(enabled: Bool)
    case claudeShow
    case claudeSet(changes: ClaudeChanges)
    case claudeReset
    case claudeSkills
    case toolsList
    case toolsSet(tool: ToolName, path: String?)
    // Slack
    case slackShow
    case slackSetEnabled(enabled: Bool)
    case slackSetProvider(provider: SlackProvider)
    case slackTokenSet(token: String)
    case slackTokenClear
    case slackSetToggle(toggle: SlackToggleName, enabled: Bool)
    case slackSetEmoji(kind: SlackEmojiKind, name: String)
    case slackSetSearchDays(days: Int)
    case slackTemplateList
    case slackTemplateSet(template: SlackTemplateName, text: String)
    case slackTemplateReset(template: SlackTemplateName)
    case slackCheck
    case slackSelfTest(confirmed: Bool)
    case slackChannels(reload: Bool)

    /// Un nombre por caso, sin argumentos: lo recorre el test de paridad y es lo único que se loguea (nunca los
    /// argumentos: `slackTokenSet` lleva un token).
    public enum Name: String, CaseIterable, Sendable {
        case status, listPRs, resolvePR, history, historyShow, historyReopen, refresh
        case open, openSettings, openHistory, quit
        case reviewStart, reviewShow, reviewEdit, reviewSetIncluded, reviewSetComment, reviewPublish, reviewCancel
        case reviewDismiss
        case respondStart, respondShow, respondSelect, respondReset, respondImplement, respondTest, respondDiff
        case respondPush, respondReplyOnly, respondCancel, respondDismiss
        case configShow, setRefreshInterval, setLaunchAtLogin, accountList, accountSetEnabled, accountReload
        case repoList, repoAvailable, repoAdd, repoRemove, repoSet, repoBranches
        case followList, followAdd, followRemove, followSuggestions
        case notifyList, notifySet, notifySetEnabled
        case claudeShow, claudeSet, claudeReset, claudeSkills, toolsList, toolsSet
        case slackShow, slackSetEnabled, slackSetProvider, slackTokenSet, slackTokenClear, slackSetToggle, slackSetEmoji
        case slackSetSearchDays, slackTemplateList, slackTemplateSet, slackTemplateReset, slackCheck, slackSelfTest
        case slackChannels
    }

    public var name: Name {
        switch self {
        case .status: .status
        case .listPRs: .listPRs
        case .resolvePR: .resolvePR
        case .history: .history
        case .historyShow: .historyShow
        case .historyReopen: .historyReopen
        case .refresh: .refresh
        case .open: .open
        case .openSettings: .openSettings
        case .openHistory: .openHistory
        case .quit: .quit
        case .reviewStart: .reviewStart
        case .reviewShow: .reviewShow
        case .reviewEdit: .reviewEdit
        case .reviewSetIncluded: .reviewSetIncluded
        case .reviewSetComment: .reviewSetComment
        case .reviewPublish: .reviewPublish
        case .reviewCancel: .reviewCancel
        case .reviewDismiss: .reviewDismiss
        case .respondStart: .respondStart
        case .respondShow: .respondShow
        case .respondSelect: .respondSelect
        case .respondReset: .respondReset
        case .respondImplement: .respondImplement
        case .respondTest: .respondTest
        case .respondDiff: .respondDiff
        case .respondPush: .respondPush
        case .respondReplyOnly: .respondReplyOnly
        case .respondCancel: .respondCancel
        case .respondDismiss: .respondDismiss
        case .configShow: .configShow
        case .setRefreshInterval: .setRefreshInterval
        case .setLaunchAtLogin: .setLaunchAtLogin
        case .accountList: .accountList
        case .accountSetEnabled: .accountSetEnabled
        case .accountReload: .accountReload
        case .repoList: .repoList
        case .repoAvailable: .repoAvailable
        case .repoAdd: .repoAdd
        case .repoRemove: .repoRemove
        case .repoSet: .repoSet
        case .repoBranches: .repoBranches
        case .followList: .followList
        case .followAdd: .followAdd
        case .followRemove: .followRemove
        case .followSuggestions: .followSuggestions
        case .notifyList: .notifyList
        case .notifySet: .notifySet
        case .notifySetEnabled: .notifySetEnabled
        case .claudeShow: .claudeShow
        case .claudeSet: .claudeSet
        case .claudeReset: .claudeReset
        case .claudeSkills: .claudeSkills
        case .toolsList: .toolsList
        case .toolsSet: .toolsSet
        case .slackShow: .slackShow
        case .slackSetEnabled: .slackSetEnabled
        case .slackSetProvider: .slackSetProvider
        case .slackTokenSet: .slackTokenSet
        case .slackTokenClear: .slackTokenClear
        case .slackSetToggle: .slackSetToggle
        case .slackSetEmoji: .slackSetEmoji
        case .slackSetSearchDays: .slackSetSearchDays
        case .slackTemplateList: .slackTemplateList
        case .slackTemplateSet: .slackTemplateSet
        case .slackTemplateReset: .slackTemplateReset
        case .slackCheck: .slackCheck
        case .slackSelfTest: .slackSelfTest
        case .slackChannels: .slackChannels
        }
    }
}
```

Agregar al final de `Sources/PRBarCore/CommandProtocol.swift`:

```swift
public struct CommandRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var command: AppCommand

    public init(id: Int, command: AppCommand) {
        self.id = id
        self.command = command
    }
}
```

`SlackProvider` y `ReviewEvent` ya son `Codable` (raw values `userToken`/`claudeConnector` y `COMMENT`/`REQUEST_CHANGES`/`APPROVE`). `SlackToggle` y `SlackTemplateKind` son enums sin valores asociados, así que son `Hashable` (lo usa el último test).

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests "app command"`
Expected: `5/5 passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/AppCommand.swift Sources/PRBarCore/AppCommandTypes.swift Sources/PRBarCore/CommandProtocol.swift Sources/PRBarTests/AppCommandTests.swift Sources/PRBarTests/main.swift
git commit -m "Add AppCommand: one Codable case per app action"
```

---

### Task 5: Ayudas de la CLI sobre `ReviewEdits` y las decisiones de Respond

El plan 6 ya sacó el estado editable de las ventanas a `ChatCoordinator` (`reviewEdits: ReviewEdits` en Review, `selections: [String: RespondSelection]` en Respond), uno por draft, guardado en `AppModel` (`reviewChat(for:)`, `respondChat(for:)`). La CLI usa ese mismo estado; esta task solo agrega lo que le falta para referirse a hallazgos y comentarios por número y para publicar con `--only`.

> **Antes de empezar:** abrir `Sources/PRBarCore/ChatModels.swift` y verificar los nombres de `ReviewEdits` (`selected`, `bodies`, `titles`, `added`, `generalComment`, `items(of:)`, `number(of:in:)`, `body(of:)`, `isEdited(_:)`, `selectedComments(of:)`). Si alguno cambió al implementar el plan 6, usar el nombre real en esta task y en las siguientes.

**Files:**
- Create: `Sources/PRBarCore/ReviewEdits+CLI.swift`, `Sources/PRBarTests/ReviewEditsCLITests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ ReviewEditsCLITests.cases`)

- [ ] **Step 1: Tests**

```swift
import Foundation
import PRBarCore

private func finding(_ id: String, title: String = "Title", body: String = "Body") -> ReviewFinding {
    ReviewFinding(id: id, severity: .medium, file: "src/a.ts", line: 3, title: title, body: body)
}

/// f1 (se mantiene), f2 (descartado por el filtro), f3 (se mantiene). Lo usan también los tests de las Tasks 6 y 7.
func editDraft() -> ReviewDraft {
    let pr = makePR(number: 4)
    return ReviewDraft(prID: pr.id, repo: pr.repo, number: 4, title: pr.title, url: pr.url, author: pr.author,
                       headOid: pr.headOid, account: "me", summary: "s", items: [
                           ReviewItem(finding: finding("f1", body: "one"), keep: true, reason: nil),
                           ReviewItem(finding: finding("f2", body: "two"), keep: false, reason: "not real"),
                           ReviewItem(finding: finding("f3", body: "three"), keep: true, reason: nil),
                       ])
}

/// Dos comentarios: uno de código (Claude propone fix) y uno general (Claude propone responder).
func cliRespondDraft() -> RespondDraft {
    let pr = makePR(number: 9, author: "me")
    let comment = FeedbackComment(databaseID: 1, author: "ana", isBot: false, body: "Fix", createdAt: t0,
                                  url: URL(string: "https://github.com/o/r/pull/9#discussion_r1")!)
    let code = FeedbackItem(id: "thread:A", kind: .thread, path: "a.swift", line: 2, isOutdated: false, comments: [comment])
    let general = FeedbackItem(id: "review:B", kind: .reviewBody, path: nil, line: nil, isOutdated: false, comments: [comment])
    return RespondDraft(prID: pr.id, repo: pr.repo, number: 9, title: pr.title, url: pr.url, headRef: pr.headRef, account: "me",
                        worktree: ResolvedWorktree(path: "/wt", origin: .dedicated), startHeadOid: "abc", items: [
                            RespondItem(feedback: code, assessment: "ok", action: .fix, fixPlan: "plan", reply: ""),
                            RespondItem(feedback: general, assessment: "no", action: .reply, fixPlan: "", reply: "Thanks"),
                        ])
}

enum ReviewEditsCLITests {
    static let cases: [TestCase] = [
        TestCase("review edits cli: un hallazgo por #N o por id, incluidos los que agregó el chat") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.added = [ReviewItem(finding: finding("c1"), keep: true, reason: nil)]
            try expectEqual(edits.item("2", in: draft)?.id, "f2")
            try expectEqual(edits.item("4", in: draft)?.id, "c1")
            try expectEqual(edits.item("f3", in: draft)?.id, "f3")
            try expectEqual(edits.item("c1", in: draft)?.id, "c1")
            try expectEqual(edits.item("9", in: draft)?.id, nil)
            try expectEqual(edits.item("zz", in: draft)?.id, nil)
        },
        TestCase("review edits cli: texto o título igual al original no cuenta como editado") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.setBody("one", for: "f1", in: draft)
            edits.setTitle("Title", for: "f1", in: draft)
            try expectEqual(edits.bodies, [:])
            try expectEqual(edits.titles, [:])
            edits.setBody("uno", for: "f1", in: draft)
            edits.setTitle("Better", for: "f1", in: draft)
            try expectEqual(edits.bodies, ["f1": "uno"])
            try expectEqual(edits.items(of: draft)[0].finding.title, "Better")
        },
        TestCase("review edits cli: Select All, --only y comentarios") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.added = [ReviewItem(finding: finding("c1"), keep: true, reason: nil)]
            edits.selected = ["f2"]
            edits.selectAllKept(in: draft)
            try expectEqual(edits.selected, ["f1", "f2", "f3", "c1"])
            try expectEqual(edits.comments(of: draft, only: ["f3", "f1"]).map(\.finding.id), ["f1", "f3"])
            try expectEqual(edits.comments(of: draft, only: nil).map(\.finding.id), ["f1", "f2", "f3", "c1"])
        },
        TestCase("respond cli: un comentario por número o por id") {
            let draft = cliRespondDraft()
            try expectEqual(RespondItemReference.itemID("1", in: draft), "thread:A")
            try expectEqual(RespondItemReference.itemID("review:B", in: draft), "review:B")
            try expectEqual(RespondItemReference.itemID("3", in: draft), nil)
            try expectEqual(RespondItemReference.itemID("thread:Z", in: draft), nil)
        },
    ]
}
```

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests "cli:"`
Expected: no compila (`value of type 'ReviewEdits' has no member 'item'`).

- [ ] **Step 3: Implementar `Sources/PRBarCore/ReviewEdits+CLI.swift`**

```swift
import Foundation

/// Lo que la CLI necesita del estado de la ventana de Review (`ReviewEdits`, plan 6): referirse a un hallazgo por
/// `#N` o por id, editar sin marcar como editado un texto igual al original, "Select All" y publicar con `--only`.
extension ReviewEdits {
    /// `"3"` (#N, la numeración de la ventana y del chat) o el id (`"f2"`, `"c1"`) → el ítem con el título editado.
    public func item(_ reference: String, in draft: ReviewDraft) -> ReviewItem? {
        let items = items(of: draft)
        if let number = Int(reference) {
            return items.indices.contains(number - 1) ? items[number - 1] : nil
        }
        return items.first { $0.id == reference }
    }

    /// El ítem tal como vino (sin el título editado): el draft o lo que agregó el chat.
    private func original(_ id: String, in draft: ReviewDraft) -> ReviewItem? {
        (draft.items + added).first { $0.id == id }
    }

    public mutating func setBody(_ text: String, for id: String, in draft: ReviewDraft) {
        guard let item = original(id, in: draft) else { return }
        bodies[id] = text == item.finding.body ? nil : text
    }

    public mutating func setTitle(_ text: String, for id: String, in draft: ReviewDraft) {
        guard let item = original(id, in: draft) else { return }
        titles[id] = text == item.finding.title ? nil : text
    }

    /// "Select All" de la ventana: suma los que mantuvo el filtro (y los que agregó el chat); los descartados que ya
    /// estaban elegidos siguen elegidos.
    public mutating func selectAllKept(in draft: ReviewDraft) {
        selected.formUnion(items(of: draft).filter(\.keep).map(\.id))
    }

    /// Lo que se publica: con `only`, esos ids (en el orden de la ventana) en vez de la selección.
    public func comments(of draft: ReviewDraft, only: Set<String>?) -> [SelectedComment] {
        guard let only else { return selectedComments(of: draft) }
        return items(of: draft).filter { only.contains($0.id) }.map { SelectedComment(finding: $0.finding, body: body(of: $0)) }
    }
}

/// `prbar respond select <pr> <n|id>`: un comentario del análisis por su posición (desde 1, la de la ventana y del
/// chat) o por su id (`thread:…`, `review:…`).
public enum RespondItemReference {
    public static func itemID(_ reference: String, in draft: RespondDraft) -> String? {
        if let number = Int(reference) {
            return draft.items.indices.contains(number - 1) ? draft.items[number - 1].id : nil
        }
        return draft.items.first { $0.id == reference }?.id
    }
}
```

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests "cli:"`
Expected: `4/4 passed` (más el smoke de la Task 1).

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/ReviewEdits+CLI.swift Sources/PRBarTests/ReviewEditsCLITests.swift Sources/PRBarTests/main.swift
git commit -m "Add CLI helpers for review edits and respond item references"
```

---

### Task 6: Resultados de los comandos (DTOs)

Lo que devuelve cada comando y lo que imprime `--json` en `data`. Todos con `init` público (los arma la app y los tests).

**Files:**
- Create: `Sources/PRBarCore/CommandResults.swift`, `Sources/PRBarTests/CommandResultsTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ CommandResultsTests.cases`)

- [ ] **Step 1: Tests**

```swift
import Foundation
import PRBarCore

enum CommandResultsTests {
    static let cases: [TestCase] = [
        TestCase("resultados: PRInfo con JSON estable") {
            let item = ClassifiedPR(pr: makePR(number: 1), category: .toReview, account: "fede")
            let info = PRInfo(item: item, review: nil, respond: nil)
            try expectEqual(try CommandProtocol.line(info), #"{"account":"fede","additions":10,"author":"juan","baseRef":"develop","category":"toReview","ci":"success","deletions":2,"headRef":"feature/1","id":"o/r#1","isDraft":false,"number":1,"repo":"o/r","title":"PR 1","updatedAt":"2027-01-15T08:00:00Z","url":"https://github.com/o/r/pull/1"}"#)
            let reviewing = PRInfo(item: item, review: .reviewing(agents: 2), respond: nil)
            try expectEqual(reviewing.review, "reviewing")
        },
        TestCase("resultados: ReviewInfo de un review listo, con números, selección y ediciones") {
            let draft = editDraft()
            var edits = ReviewEdits.initial(for: draft)
            edits.selected.insert("f2")
            edits.setBody("uno", for: "f1", in: draft)
            edits.generalComment = "LGTM"
            let info = ReviewInfo(prID: draft.prID, phase: .ready(draft), edits: edits, outdated: true)
            try expectEqual(info.phase, "ready")
            try expectEqual(info.findings.map(\.id), ["f1", "f2", "f3"])
            try expectEqual(info.findings.map(\.number), [1, 2, 3])
            try expectEqual(info.findings.map(\.included), [true, true, true])
            try expectEqual(info.findings[0].body, "uno")
            try expectEqual(info.findings[0].edited, true)
            try expectEqual(info.findings[1].keptByFilter, false)
            try expectEqual(info.findings[1].filterReason, "not real")
            try expectEqual(info.generalComment, "LGTM")
            try expectEqual(info.account, "me")
            try expect(info.outdated)
        },
        TestCase("resultados: ReviewInfo de fallido, publicado y sin review") {
            let failed = ReviewInfo(prID: "o/r#1", phase: .failed("boom", logURL: URL(fileURLWithPath: "/tmp/x.log")))
            try expectEqual(failed.phase, "failed")
            try expectEqual(failed.detail, "boom")
            try expectEqual(failed.logPath, "/tmp/x.log")
            let posted = ReviewInfo(prID: "o/r#1", phase: .published(URL(string: "https://github.com/o/r/pull/1#r")!))
            try expectEqual(posted.reviewURL?.absoluteString, "https://github.com/o/r/pull/1#r")
            try expectEqual(ReviewInfo(prID: "o/r#1", phase: nil).phase, "none")
        },
        TestCase("resultados: HistoryEntryInfo busca como la ventana de Historial") {
            let record = ReviewRecord(draft: editDraft(), startedAt: t0, status: .ready)
            let entry = HistoryEntryInfo(review: record)
            try expectEqual(entry.kind, .review)
            try expectEqual(entry.status, "ready")
            try expect(entry.matches("#4"))
            try expect(entry.matches("o/r"))
            try expect(entry.matches("pr 4"))
            try expect(!entry.matches("#5"))
        },
        TestCase("resultados: fases con nombre para la CLI") {
            try expectEqual(ReviewPhase.reviewing(agents: 1).cliDetail, "1 agent")
            try expectEqual(RespondPhase.implementing(done: 1, total: 3).cliName, "implementing")
            try expectEqual(RespondPhase.implementing(done: 1, total: 3).cliDetail, "1/3")
        },
    ]
}
```

`ReviewRecord(draft:startedAt:status:)`: si el `init` de `ReviewRecord` pide otros argumentos sin valor por defecto, completarlos con los mismos valores que usa `ReviewHistoryTests`.

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests resultados`
Expected: no compila.

- [ ] **Step 3: Implementar `Sources/PRBarCore/CommandResults.swift`**

```swift
import Foundation

// Resultados de los comandos (`result` de la respuesta y `data` de `--json`, ver docs/cli.md). Las claves son
// estables: agregar campos opcionales está bien; renombrar o quitar sube `JSONOutput.schemaVersion`.

// MARK: - Fases

extension ReviewPhase {
    public var cliName: String {
        switch self {
        case .queued: "queued"
        case .preparing: "preparing"
        case .reviewing: "reviewing"
        case .filtering: "filtering"
        case .ready: "ready"
        case .failed: "failed"
        case .published: "published"
        }
    }

    public var cliDetail: String? {
        switch self {
        case .reviewing(let agents): agents == 1 ? "1 agent" : "\(agents) agents"
        case .failed(let message, _): message
        case .published(let url): url.absoluteString
        default: nil
        }
    }
}

extension RespondPhase {
    public var cliName: String {
        switch self {
        case .queued: "queued"
        case .preparing: "preparing"
        case .analyzing: "analyzing"
        case .ready: "ready"
        case .implementing: "implementing"
        case .readyToPush: "readyToPush"
        case .pushing: "pushing"
        case .done: "done"
        case .failed: "failed"
        }
    }

    public var cliDetail: String? {
        switch self {
        case .analyzing(let agents) where agents > 0: agents == 1 ? "1 agent" : "\(agents) agents"
        case .implementing(let done, let total): "\(done)/\(total)"
        case .failed(let message, _): message
        default: nil
        }
    }
}

extension FeedbackItem {
    /// `path:line`, `path` o "General comment" (como `RespondItemHeader`).
    public var cliLocation: String {
        guard let path else { return "General comment" }
        return line.map { "\(path):\($0)" } ?? path
    }
}

// MARK: - Estado y PRs

public struct ToolInfo: Codable, Equatable, Sendable {
    public var name: String
    /// La ruta encontrada; `nil` = no se encontró.
    public var path: String?
    /// Hay una ruta elegida a mano (Settings › General).
    public var custom: Bool

    public init(name: String, path: String?, custom: Bool) {
        self.name = name
        self.path = path
        self.custom = custom
    }
}

public struct JobInfo: Codable, Equatable, Sendable {
    public var pr: String
    public var kind: String
    public var phase: String

    public init(pr: String, kind: String, phase: String) {
        self.pr = pr
        self.kind = kind
        self.phase = phase
    }
}

public struct StatusInfo: Codable, Equatable, Sendable {
    public var appVersion: String
    public var refreshing: Bool
    public var fetchedAt: Date?
    public var offline: Bool
    public var rateLimitedUntil: Date?
    public var badgeCount: Int
    /// Por `PRCategory.rawValue`.
    public var counts: [String: Int]
    public var issues: [String]
    public var slackIssues: [String]
    public var jobs: [JobInfo]
    public var accounts: [String]
    public var tools: [ToolInfo]

    public init(appVersion: String, refreshing: Bool = false, fetchedAt: Date? = nil, offline: Bool = false,
                rateLimitedUntil: Date? = nil, badgeCount: Int = 0, counts: [String: Int] = [:], issues: [String] = [],
                slackIssues: [String] = [], jobs: [JobInfo] = [], accounts: [String] = [], tools: [ToolInfo] = []) {
        self.appVersion = appVersion
        self.refreshing = refreshing
        self.fetchedAt = fetchedAt
        self.offline = offline
        self.rateLimitedUntil = rateLimitedUntil
        self.badgeCount = badgeCount
        self.counts = counts
        self.issues = issues
        self.slackIssues = slackIssues
        self.jobs = jobs
        self.accounts = accounts
        self.tools = tools
    }
}

public struct PRInfo: Codable, Equatable, Sendable {
    public var id: String
    public var repo: String
    public var number: Int
    public var title: String
    public var url: URL
    public var author: String
    public var account: String
    public var category: String
    public var baseRef: String
    public var headRef: String
    public var isDraft: Bool
    public var ci: String
    public var additions: Int
    public var deletions: Int
    public var updatedAt: Date
    /// Fase del review de PRBar (`ReviewPhase.cliName`), si hay.
    public var review: String?
    /// Fase de Responder (`RespondPhase.cliName`), si hay.
    public var respond: String?

    public init(item: ClassifiedPR, review: ReviewPhase?, respond: RespondPhase?) {
        let pr = item.pr
        id = item.id
        repo = pr.repo.fullName
        number = pr.number
        title = pr.title
        url = pr.url
        author = pr.author
        account = item.account
        category = item.category.rawValue
        baseRef = pr.baseRef
        headRef = pr.headRef
        isDraft = pr.isDraft
        ci = pr.ciState.rawValue
        additions = pr.additions
        deletions = pr.deletions
        updatedAt = pr.updatedAt
        self.review = review?.cliName
        self.respond = respond?.cliName
    }
}

public struct PRLink: Codable, Equatable, Sendable {
    public var pr: String
    public var url: URL

    public init(pr: String, url: URL) {
        self.pr = pr
        self.url = url
    }
}

// MARK: - Review

public struct FindingInfo: Codable, Equatable, Sendable {
    public var number: Int
    public var id: String
    public var severity: Severity
    public var location: String
    public var title: String
    public var body: String
    public var keptByFilter: Bool
    public var filterReason: String?
    public var included: Bool
    public var edited: Bool

    public init(number: Int, id: String, severity: Severity, location: String, title: String, body: String,
                keptByFilter: Bool, filterReason: String?, included: Bool, edited: Bool) {
        self.number = number
        self.id = id
        self.severity = severity
        self.location = location
        self.title = title
        self.body = body
        self.keptByFilter = keptByFilter
        self.filterReason = filterReason
        self.included = included
        self.edited = edited
    }

    /// `item` como lo da `ReviewEdits.items(of:)` (con el título editado).
    public init(number: Int, item: ReviewItem, edits: ReviewEdits) {
        self.init(number: number, id: item.id, severity: item.finding.severity, location: item.finding.location,
                  title: item.finding.title, body: edits.body(of: item), keptByFilter: item.keep,
                  filterReason: item.reason, included: edits.selected.contains(item.id), edited: edits.isEdited(item))
    }
}

public struct ReviewInfo: Codable, Equatable, Sendable {
    public var pr: String
    /// `ReviewPhase.cliName` o `"none"`.
    public var phase: String
    public var detail: String?
    public var title: String?
    public var summary: String?
    public var language: String?
    public var account: String?
    /// El PR recibió commits después del review: todo va al cuerpo de la review.
    public var outdated: Bool
    public var findings: [FindingInfo]
    public var generalComment: String?
    public var reviewURL: URL?
    public var logPath: String?

    public init(prID: String, phase: ReviewPhase?, edits: ReviewEdits? = nil, outdated: Bool = false) {
        pr = prID
        self.phase = phase?.cliName ?? "none"
        detail = phase?.cliDetail
        self.outdated = outdated
        findings = []
        switch phase {
        case .failed(_, let logURL)?:
            logPath = logURL?.path
        case .published(let url)?:
            reviewURL = url
        case .ready(let draft)?:
            let edits = edits ?? ReviewEdits.initial(for: draft)
            title = draft.title
            summary = draft.summary
            language = draft.language.displayName
            account = draft.account
            // #N = posición en `draft.items + edits.added` (plan 6), la misma de la ventana y del chat.
            findings = edits.items(of: draft).enumerated().map { FindingInfo(number: $0.offset + 1, item: $0.element, edits: edits) }
            generalComment = edits.generalComment.isEmpty ? nil : edits.generalComment
        default:
            break
        }
    }
}

public struct PublishedReviewInfo: Codable, Equatable, Sendable {
    public var pr: String
    public var url: URL
    /// `ReviewRecord.Action.rawValue`: approve, requestChanges, comment.
    public var action: String
    public var comments: Int
    public var publishedAt: Date

    public init(pr: String, url: URL, action: String, comments: Int, publishedAt: Date) {
        self.pr = pr
        self.url = url
        self.action = action
        self.comments = comments
        self.publishedAt = publishedAt
    }
}

// MARK: - Respond

public struct RespondItemInfo: Codable, Equatable, Sendable {
    public var number: Int
    public var id: String
    public var reviewer: String
    public var location: String
    public var outdated: Bool
    /// "autor: texto" de cada comentario del hilo.
    public var thread: [String]
    public var commentURL: URL?
    public var assessment: String
    /// Lo que propuso Claude (`FeedbackAction.rawValue`).
    public var suggested: String
    public var implement: Bool
    public var fixPlan: String
    public var reply: Bool
    public var replyText: String
    public var postedURL: URL?

    public init(number: Int, item: RespondItem, selection: RespondSelection, posted: URL?) {
        self.number = number
        id = item.id
        reviewer = item.feedback.reviewer
        location = item.feedback.cliLocation
        outdated = item.feedback.isOutdated
        thread = item.feedback.comments.map { "\($0.author): \($0.body)" }
        commentURL = item.feedback.comments.last?.url
        assessment = item.assessment
        suggested = item.action.rawValue
        implement = selection.implement
        fixPlan = selection.fixPlan
        reply = selection.reply
        replyText = selection.replyText
        postedURL = posted
    }
}

public struct CommitDTO: Codable, Equatable, Sendable {
    public var item: String
    public var status: String
    public var sha: String?
    public var summary: String

    public init(item: String, status: String, sha: String?, summary: String) {
        self.item = item
        self.status = status
        self.sha = sha
        self.summary = summary
    }
}

public struct TestInfo: Codable, Equatable, Sendable {
    public var command: String
    public var passed: Bool
    public var outputTail: String

    public init(command: String, passed: Bool, outputTail: String) {
        self.command = command
        self.passed = passed
        self.outputTail = outputTail
    }
}

public struct RespondInfo: Codable, Equatable, Sendable {
    public var pr: String
    /// `RespondPhase.cliName` o `"none"`.
    public var phase: String
    public var detail: String?
    public var runningTests: Bool
    public var title: String?
    public var account: String?
    public var headRef: String?
    public var worktree: String?
    public var language: String?
    public var items: [RespondItemInfo]
    /// Fixes y respuestas que saldrían con lo elegido.
    public var fixes: Int
    public var replies: Int
    public var commits: [CommitDTO]
    public var diffStat: String?
    public var sensitiveChanges: [String]
    public var tests: TestInfo?
    public var pushed: Bool
    public var pendingReplies: Int
    public var testCommand: String?
    public var errorMessage: String?
    public var logPath: String?

    public init(prID: String, phase: RespondPhase?, record: RespondRecord?, selections: [String: RespondSelection],
                runningTests: Bool, testCommand: String?, logPath: String? = nil) {
        pr = prID
        self.phase = phase?.cliName ?? "none"
        detail = phase?.cliDetail
        self.runningTests = runningTests
        self.testCommand = testCommand
        self.logPath = logPath
        items = []
        fixes = 0
        replies = 0
        commits = []
        sensitiveChanges = []
        pushed = false
        pendingReplies = 0
        guard let record else { return }
        let draft = record.draft
        title = draft.title
        account = draft.account
        headRef = draft.headRef
        worktree = draft.worktree.path
        language = draft.language.displayName
        items = draft.items.enumerated().map { index, item in
            RespondItemInfo(number: index + 1, item: item,
                            selection: selections[item.id] ?? RespondSelection.defaults(for: item),
                            posted: record.posted[item.id]?.url)
        }
        fixes = RespondCounts.fixes(draft, selections)
        replies = RespondCounts.plannedReplies(draft, selections)
        if let result = record.result {
            commits = result.items.map { CommitDTO(item: $0.id, status: $0.status.rawValue, sha: $0.commit, summary: $0.summary) }
            diffStat = result.diffStat
            sensitiveChanges = result.sensitiveChanges
            tests = result.tests.map { TestInfo(command: $0.command, passed: $0.passed, outputTail: $0.outputTail) }
        }
        pushed = record.pushed
        pendingReplies = RespondCounts.pendingReplies(record)
        errorMessage = record.errorMessage
    }
}

public struct RespondDiff: Codable, Equatable, Sendable {
    public var pr: String
    public var diffStat: String
    /// El diff completo (`startHeadOid..HEAD`); `nil` en resultados viejos.
    public var diff: String?
    public var truncated: Bool
    public var sensitiveChanges: [String]

    public init(pr: String, diffStat: String, diff: String?, truncated: Bool, sensitiveChanges: [String]) {
        self.pr = pr
        self.diffStat = diffStat
        self.diff = diff
        self.truncated = truncated
        self.sensitiveChanges = sensitiveChanges
    }
}

// MARK: - Historial

public struct HistoryEntryInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: HistoryKind
    public var pr: String
    public var repo: String
    public var number: Int
    public var title: String
    public var status: String
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: UUID, kind: HistoryKind, pr: String, repo: String, number: Int, title: String, status: String,
                startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.pr = pr
        self.repo = repo
        self.number = number
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public init(review record: ReviewRecord) {
        self.init(id: record.id, kind: .review, pr: record.draft.prID, repo: record.draft.repo.fullName,
                  number: record.draft.number, title: record.draft.title, status: record.status.rawValue,
                  startedAt: record.startedAt, finishedAt: record.finishedAt)
    }

    public init(respond record: RespondRecord) {
        let status = if record.errorMessage != nil {
            "failed"
        } else if record.pushed || !record.posted.isEmpty {
            "done"
        } else if record.result != nil {
            "readyToPush"
        } else {
            "ready"
        }
        self.init(id: record.id, kind: .respond, pr: record.draft.prID, repo: record.draft.repo.fullName,
                  number: record.draft.number, title: record.draft.title, status: status,
                  startedAt: record.startedAt, finishedAt: record.finishedAt)
    }

    /// Búsqueda de la ventana de Historial: título, repo o número ("482" o "#482"). `query` ya en minúsculas.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if title.lowercased().contains(query) || repo.lowercased().contains(query) { return true }
        let number = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return !number.isEmpty && String(self.number).hasPrefix(number)
            || pr.lowercased().contains(query)
    }
}

public struct PostedReplyInfo: Codable, Equatable, Sendable {
    public var item: String
    public var location: String
    public var url: URL

    public init(item: String, location: String, url: URL) {
        self.item = item
        self.location = location
        self.url = url
    }
}

public struct HistoryDetail: Codable, Equatable, Sendable {
    public var entry: HistoryEntryInfo
    public var prURL: URL
    public var summary: String?
    public var errorMessage: String?
    /// Review: cada hallazgo; `included` = se publicó, con el texto publicado.
    public var findings: [FindingInfo]
    public var generalComment: String?
    public var action: String?
    public var reviewURL: URL?
    public var replies: [PostedReplyInfo]
    public var pushed: Bool
    public var logPath: String?
    /// "Open to Post" (`prbar history reopen`).
    public var canReopen: Bool
    /// "Show Response" (`prbar open <pr> --respond`).
    public var canOpen: Bool

    public init(entry: HistoryEntryInfo, prURL: URL, summary: String? = nil, errorMessage: String? = nil,
                findings: [FindingInfo] = [], generalComment: String? = nil, action: String? = nil, reviewURL: URL? = nil,
                replies: [PostedReplyInfo] = [], pushed: Bool = false, logPath: String? = nil, canReopen: Bool = false,
                canOpen: Bool = false) {
        self.entry = entry
        self.prURL = prURL
        self.summary = summary
        self.errorMessage = errorMessage
        self.findings = findings
        self.generalComment = generalComment
        self.action = action
        self.reviewURL = reviewURL
        self.replies = replies
        self.pushed = pushed
        self.logPath = logPath
        self.canReopen = canReopen
        self.canOpen = canOpen
    }

    public init(review record: ReviewRecord, logPath: String?, canReopen: Bool) {
        let edits = record.draft.edits ?? ReviewEdits.initial(for: record.draft)
        let findings = edits.items(of: record.draft).enumerated().map { index, item -> FindingInfo in
            let finding = item.finding
            let published = record.published[item.id]
            return FindingInfo(number: index + 1, id: item.id, severity: finding.severity, location: finding.location,
                               title: finding.title, body: published ?? edits.body(of: item), keptByFilter: item.keep,
                               filterReason: item.reason, included: published != nil, edited: edits.isEdited(item))
        }
        self.init(entry: HistoryEntryInfo(review: record), prURL: record.draft.url, summary: record.draft.summary,
                  errorMessage: record.errorMessage, findings: findings, generalComment: record.generalComment,
                  action: record.status == .published ? record.action.rawValue : nil, reviewURL: record.reviewURL,
                  logPath: logPath, canReopen: canReopen)
    }

    public init(respond record: RespondRecord, logPath: String?, canOpen: Bool) {
        let replies = record.draft.items.compactMap { item in
            record.posted[item.id].map { PostedReplyInfo(item: item.id, location: item.feedback.cliLocation, url: $0.url) }
        }
        self.init(entry: HistoryEntryInfo(respond: record), prURL: record.draft.url, errorMessage: record.errorMessage,
                  replies: replies, pushed: record.pushed, logPath: logPath, canOpen: canOpen)
    }
}

// MARK: - Configuración

public struct AccountInfo: Codable, Equatable, Sendable {
    public var login: String
    public var enabled: Bool
    /// Hay sesión de `gh` para esta cuenta.
    public var inGh: Bool
    /// Es la cuenta activa de `gh`.
    public var active: Bool

    public init(login: String, enabled: Bool, inGh: Bool, active: Bool) {
        self.login = login
        self.enabled = enabled
        self.inGh = inGh
        self.active = active
    }
}

public struct RepoInfo: Codable, Equatable, Sendable {
    public var id: String
    public var account: String
    public var localPath: String?
    public var worktreeDir: String?
    public var testCommand: String?
    public var baseBranches: [String]
    public var watchedUsers: [String]
    public var slackChannel: String?

    public init(config: RepoConfig, account: String) {
        id = config.id
        self.account = account
        localPath = config.localPath
        worktreeDir = config.worktreeDir
        testCommand = config.testCommand
        baseBranches = config.baseBranches
        watchedUsers = config.watchedUsers
        slackChannel = config.slackChannelName ?? config.slackChannelID
    }
}

public struct BranchesInfo: Codable, Equatable, Sendable {
    public var repo: String
    public var defaultBranch: String?
    public var branches: [String]
    /// Las ramas base elegidas (vacío = la rama por defecto).
    public var selected: [String]

    public init(repo: String, defaultBranch: String?, branches: [String], selected: [String]) {
        self.repo = repo
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.selected = selected
    }
}

public struct FollowInfo: Codable, Equatable, Sendable {
    public var repo: String
    public var account: String
    public var users: [String]

    public init(repo: String, account: String, users: [String]) {
        self.repo = repo
        self.account = account
        self.users = users
    }
}

public struct UserSuggestionInfo: Codable, Equatable, Sendable {
    public var login: String
    public var name: String?
    public var openPRs: Int

    public init(login: String, name: String?, openPRs: Int) {
        self.login = login
        self.name = name
        self.openPRs = openPRs
    }
}

public struct NotificationsInfo: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Por `NotificationSettingName.rawValue`.
    public var kinds: [String: Bool]
    /// Las notificaciones de PRBar están apagadas en Ajustes del Sistema.
    public var deniedInMacOS: Bool

    public init(settings: NotificationSettings, deniedInMacOS: Bool) {
        enabled = settings.enabled
        kinds = Dictionary(uniqueKeysWithValues: NotificationSettingName.allCases.map { ($0.rawValue, settings[keyPath: $0.keyPath]) })
        self.deniedInMacOS = deniedInMacOS
    }
}

public struct SkillInfo: Codable, Equatable, Sendable {
    public var id: String
    /// `plugin:<nombre>` o `user`.
    public var source: String
    public var description: String?
    public var available: Bool
    public var reason: String?

    public init(id: String, source: String, description: String?, available: Bool, reason: String?) {
        self.id = id
        self.source = source
        self.description = description
        self.available = available
        self.reason = reason
    }

    public init(entry: ClaudeSkillEntry) {
        let source = switch entry.source {
        case .plugin(let name, _): "plugin:\(name)"
        case .user: "user"
        }
        let reason: String? = switch entry.availability {
        case .available: nil
        case .checking: "Checking whether it loads in isolated runs…"
        case .unavailable(let reason): reason
        }
        self.init(id: entry.id, source: source, description: entry.description, available: entry.isAvailable, reason: reason)
    }
}

// MARK: - Slack

public struct SlackInfo: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: SlackProvider
    public var connected: Bool
    public var hasToken: Bool
    public var needsUserToken: Bool
    /// Por `SlackToggleName.rawValue`.
    public var toggles: [String: Bool]
    /// Por `SlackEmojiKind.rawValue`.
    public var emojis: [String: String]
    public var searchDays: Int
    public var issues: [String]

    public init(settings: SlackSettings, connected: Bool, hasToken: Bool, needsUserToken: Bool, issues: [String]) {
        enabled = settings.enabled
        provider = settings.provider
        self.connected = connected
        self.hasToken = hasToken
        self.needsUserToken = needsUserToken
        toggles = Dictionary(uniqueKeysWithValues: SlackToggleName.allCases.map { ($0.rawValue, settings[keyPath: $0.toggle.keyPath]) })
        emojis = Dictionary(uniqueKeysWithValues: SlackEmojiKind.allCases.map { ($0.rawValue, settings[keyPath: $0.keyPath]) })
        searchDays = settings.effectiveSearchDays
        self.issues = issues
    }
}

public struct SlackCheckInfo: Codable, Equatable, Sendable {
    public var user: String
    public var team: String
    public var provider: SlackProvider

    public init(user: String, team: String, provider: SlackProvider) {
        self.user = user
        self.team = team
        self.provider = provider
    }
}

public struct SelfTestStepInfo: Codable, Equatable, Sendable {
    public var title: String
    /// ok, failed o skipped.
    public var status: String
    public var detail: String

    public init(step: SlackSelfTestStep) {
        title = step.title
        status = switch step.status {
        case .ok: "ok"
        case .failed: "failed"
        case .skipped: "skipped"
        }
        detail = step.detail
    }
}

public struct TemplateInfo: Codable, Equatable, Sendable {
    public var name: String
    public var text: String
    public var isDefault: Bool
    public var defaultText: String
    public var variables: [String]

    public init(name: SlackTemplateName, settings: SlackSettings) {
        self.name = name.rawValue
        text = settings[keyPath: name.kind.keyPath]
        isDefault = name.kind.isDefault(text)
        defaultText = name.kind.defaultTemplate
        variables = name.kind.variables.map(\.token)
    }
}

public struct ChannelInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isPrivate: Bool
    public var isMember: Bool

    public init(channel: SlackChannel) {
        id = channel.id
        name = channel.name
        isPrivate = channel.isPrivate
        isMember = channel.isMember
    }
}
```

`ItemResult.status` es un enum `String` (`committed`, `noChanges`, `failed`). `ClaudeSkillEntry.isAvailable` ya existe (lo usa `ClaudeTab`).

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests resultados`
Expected: `5/5 passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/CommandResults.swift Sources/PRBarTests/CommandResultsTests.swift Sources/PRBarTests/main.swift
git commit -m "Add the CLI result DTOs with stable JSON"
```

---

### Task 7: Protocolos de acciones y `CommandDispatcher`

Los protocolos son la lista de lo que la app sabe hacer; `AppModel` los implementa (Tasks 11–12) y los tests usan un falso. El dispatcher es el único `switch` sobre `AppCommand`: agregar un caso sin despacharlo no compila.

**Files:**
- Create: `Sources/PRBarCore/CommandActions.swift`, `Sources/PRBarCore/CommandDispatcher.swift`, `Sources/PRBarTests/FakeActions.swift`, `Sources/PRBarTests/CommandDispatcherTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ CommandDispatcherTests.cases`)

- [ ] **Step 1: El falso y los tests**

`Sources/PRBarTests/FakeActions.swift`:

```swift
import Foundation
import PRBarCore

/// `AppModel` de mentira: anota qué método se llamó (con los argumentos que importan) y devuelve algo mínimo.
@MainActor
final class FakeActions: StatusActions, ReviewActions, RespondActions, ConfigActions, SlackActions {
    var calls: [String] = []
    /// Si no es nil, los métodos que pueden fallar la lanzan.
    var failure: Error?
    /// Eventos que mandan los comandos con `wait`.
    var waitEvents: [CommandEvent] = []

    private let link = PRLink(pr: "acme/api#1", url: URL(string: "https://github.com/acme/api/pull/1")!)

    private func record(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    private func emit(_ events: CommandEventSink) { waitEvents.forEach(events) }

    // MARK: StatusActions
    func status() async throws -> StatusInfo { try record("status"); return StatusInfo(appVersion: "test") }
    func listPRs(list: PRListFilter?, account: String?) throws -> [PRInfo] {
        try record("listPRs \(list?.rawValue ?? "-") \(account ?? "-")"); return []
    }
    func resolvePR(_ pr: String) throws -> PRLink { try record("resolvePR \(pr)"); return link }
    func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo] {
        calls.append("historyList"); return []
    }
    func historyShow(id: String) throws -> HistoryDetail {
        try record("historyShow \(id)")
        return HistoryDetail(entry: HistoryEntryInfo(id: UUID(), kind: .review, pr: "acme/api#1", repo: "acme/api", number: 1,
                                                     title: "T", status: "ready", startedAt: t0), prURL: link.url)
    }
    func historyReopen(id: String) throws { try record("historyReopen \(id)") }
    func refresh() async { calls.append("refresh") }
    func open(pr: String, target: OpenTarget) throws -> PRLink { try record("open \(pr) \(target.rawValue)"); return link }
    func openSettings(tab: SettingsTabName?) { calls.append("openSettings \(tab?.rawValue ?? "-")") }
    func openHistory(id: String?) throws { try record("openHistory \(id ?? "-")") }
    func quit() { calls.append("quit") }

    // MARK: ReviewActions
    func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo {
        try record("reviewStart \(pr) wait=\(wait)"); if wait { emit(events) }; return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewShow(pr: String) throws -> ReviewInfo { try record("reviewShow \(pr)"); return ReviewInfo(prID: pr, phase: nil) }
    func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo {
        try record("reviewEdit \(pr) \(finding) title=\(title ?? "-") body=\(body ?? "-")"); return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo {
        try record("reviewSetIncluded \(pr) \(findings) all=\(all) included=\(included)"); return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewSetComment(pr: String, text: String) throws -> ReviewInfo {
        try record("reviewSetComment \(pr) \(text)"); return ReviewInfo(prID: pr, phase: nil)
    }
    func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool, allInBody: Bool) async throws -> PublishedReviewInfo {
        try record("reviewPublish \(pr) \(event.rawValue) only=\(only ?? []) comments=\(withComments) body=\(allInBody)")
        return PublishedReviewInfo(pr: pr, url: link.url, action: "approve", comments: 0, publishedAt: t0)
    }
    func reviewCancel(pr: String) throws { try record("reviewCancel \(pr)") }
    func reviewDismiss(pr: String) throws { try record("reviewDismiss \(pr)") }

    // MARK: RespondActions
    private func respondInfo(_ pr: String) -> RespondInfo {
        RespondInfo(prID: pr, phase: nil, record: nil, selections: [:], runningTests: false, testCommand: nil)
    }
    func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondStart \(pr) wait=\(wait)"); if wait { emit(events) }; return respondInfo(pr)
    }
    func respondShow(pr: String) throws -> RespondInfo { try record("respondShow \(pr)"); return respondInfo(pr) }
    func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo {
        try record("respondSelect \(pr) \(items) implement=\(change.implement.map(String.init) ?? "-") reply=\(change.reply.map(String.init) ?? "-") text=\(change.replyText ?? "-") plan=\(change.fixPlan ?? "-")")
        return respondInfo(pr)
    }
    func respondReset(pr: String) throws -> RespondInfo { try record("respondReset \(pr)"); return respondInfo(pr) }
    func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondImplement \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondTest \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondDiff(pr: String) throws -> RespondDiff {
        try record("respondDiff \(pr)"); return RespondDiff(pr: pr, diffStat: "", diff: nil, truncated: false, sensitiveChanges: [])
    }
    func respondPush(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondPush \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        try record("respondReplyOnly \(pr) wait=\(wait)"); return respondInfo(pr)
    }
    func respondCancel(pr: String) throws { try record("respondCancel \(pr)") }
    func respondDismiss(pr: String) throws { try record("respondDismiss \(pr)") }

    // MARK: ConfigActions
    private let repoInfo = RepoInfo(config: RepoConfig(owner: "acme", name: "api"), account: "me")
    func configShow() -> AppConfig { calls.append("configShow"); return AppConfig() }
    func configSetRefreshInterval(minutes: Int) throws { try record("configSetRefreshInterval \(minutes)") }
    func configSetLaunchAtLogin(enabled: Bool) throws { try record("configSetLaunchAtLogin \(enabled)") }
    func accountList() -> [AccountInfo] { calls.append("accountList"); return [] }
    func accountSetEnabled(login: String, enabled: Bool) throws { try record("accountSetEnabled \(login) \(enabled)") }
    func accountReload() async throws -> [AccountInfo] { try record("accountReload"); return [] }
    func repoList(account: String?) throws -> [RepoInfo] { try record("repoList \(account ?? "-")"); return [] }
    func repoAvailable(account: String?, reload: Bool) async throws -> [String] { try record("repoAvailable reload=\(reload)"); return [] }
    func repoAdd(repo: String, account: String?) async throws -> RepoInfo { try record("repoAdd \(repo)"); return repoInfo }
    func repoRemove(repo: String, account: String?) throws { try record("repoRemove \(repo)") }
    func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo {
        try record("repoSet \(repo) path=\(changes.localPath?.value ?? "-") add=\(changes.addBranches)"); return repoInfo
    }
    func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo {
        try record("repoBranches \(repo)"); return BranchesInfo(repo: repo, defaultBranch: "main", branches: [], selected: [])
    }
    func followList(repo: String?, account: String?) throws -> [FollowInfo] { try record("followList"); return [] }
    func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo {
        try record("followAdd \(repo) \(users)"); return FollowInfo(repo: repo, account: "me", users: users)
    }
    func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo {
        try record("followRemove \(repo) \(users)"); return FollowInfo(repo: repo, account: "me", users: [])
    }
    func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo] {
        try record("followSuggestions \(repo)"); return []
    }
    func notifyList() async -> NotificationsInfo {
        calls.append("notifyList"); return NotificationsInfo(settings: NotificationSettings(), deniedInMacOS: false)
    }
    func notifySet(kind: NotificationSettingName, enabled: Bool) throws { try record("notifySet \(kind.rawValue) \(enabled)") }
    func notifySetEnabled(enabled: Bool) throws { try record("notifySetEnabled \(enabled)") }
    func claudeShow() -> ClaudeSettings { calls.append("claudeShow"); return ClaudeSettings() }
    func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings {
        try record("claudeSet filter=\(changes.filterEnabled.map(String.init) ?? "-")"); return ClaudeSettings()
    }
    func claudeReset() throws -> ClaudeSettings { try record("claudeReset"); return ClaudeSettings() }
    func claudeSkillList() async -> [SkillInfo] { calls.append("claudeSkillList"); return [] }
    func toolsList() -> [ToolInfo] { calls.append("toolsList"); return [] }
    func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo] {
        try record("toolsSet \(tool.rawValue) \(path ?? "auto")"); return []
    }

    // MARK: SlackActions
    private let check = SlackCheckInfo(user: "me", team: "Acme", provider: .userToken)
    func slackShow() -> SlackInfo {
        calls.append("slackShow")
        return SlackInfo(settings: SlackSettings(), connected: false, hasToken: false, needsUserToken: false, issues: [])
    }
    func slackSetEnabled(enabled: Bool) throws { try record("slackSetEnabled \(enabled)") }
    func slackSetProvider(provider: SlackProvider) throws { try record("slackSetProvider \(provider.rawValue)") }
    func slackTokenSet(token: String) async throws -> SlackCheckInfo { try record("slackTokenSet \(token.count)"); return check }
    func slackTokenClear() throws { try record("slackTokenClear") }
    func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws { try record("slackSetToggle \(toggle.rawValue) \(enabled)") }
    func slackSetEmoji(kind: SlackEmojiKind, name: String) throws { try record("slackSetEmoji \(kind.rawValue) \(name)") }
    func slackSetSearchDays(days: Int) throws { try record("slackSetSearchDays \(days)") }
    func slackTemplateList() -> [TemplateInfo] { calls.append("slackTemplateList"); return [] }
    func slackTemplateSet(template: SlackTemplateName, text: String) throws { try record("slackTemplateSet \(template.rawValue)") }
    func slackTemplateReset(template: SlackTemplateName) throws { try record("slackTemplateReset \(template.rawValue)") }
    func slackCheck() async throws -> SlackCheckInfo { try record("slackCheck"); return check }
    func slackSelfTest() async throws -> [SelfTestStepInfo] { try record("slackSelfTest"); return [] }
    func slackChannels(reload: Bool) async throws -> [ChannelInfo] { try record("slackChannels reload=\(reload)"); return [] }
}
```

`Sources/PRBarTests/CommandDispatcherTests.swift`:

```swift
import Foundation
import PRBarCore

/// Un ejemplo de cada comando y el método que tiene que llamar (el primer token de lo que anota `FakeActions`).
let dispatchSamples: [(command: AppCommand, call: String)] = [
    (.status, "status"),
    (.listPRs(list: .mine, account: nil), "listPRs"),
    (.resolvePR(pr: "api#1"), "resolvePR"),
    (.history(repo: nil, kind: .review, limit: 3, search: nil), "historyList"),
    (.historyShow(id: "abcd"), "historyShow"),
    (.historyReopen(id: "abcd"), "historyReopen"),
    (.refresh, "refresh"),
    (.open(pr: "api#1", target: .review), "open"),
    (.openSettings(tab: .slack), "openSettings"),
    (.openHistory(id: nil), "openHistory"),
    (.quit, "quit"),
    (.reviewStart(pr: "api#1", wait: false), "reviewStart"),
    (.reviewShow(pr: "api#1"), "reviewShow"),
    (.reviewEdit(pr: "api#1", finding: "2", title: nil, body: "b"), "reviewEdit"),
    (.reviewSetIncluded(pr: "api#1", findings: ["1"], all: false, included: true), "reviewSetIncluded"),
    (.reviewSetComment(pr: "api#1", text: "LGTM"), "reviewSetComment"),
    (.reviewPublish(pr: "api#1", event: .comment, only: nil, withComments: true, allInBody: false, confirmed: true), "reviewPublish"),
    (.reviewCancel(pr: "api#1"), "reviewCancel"),
    (.reviewDismiss(pr: "api#1"), "reviewDismiss"),
    (.respondStart(pr: "web#2", wait: false), "respondStart"),
    (.respondShow(pr: "web#2"), "respondShow"),
    (.respondSelect(pr: "web#2", items: ["1"], change: RespondSelectionChange(implement: true)), "respondSelect"),
    (.respondReset(pr: "web#2"), "respondReset"),
    (.respondImplement(pr: "web#2", wait: false), "respondImplement"),
    (.respondTest(pr: "web#2", wait: false), "respondTest"),
    (.respondDiff(pr: "web#2"), "respondDiff"),
    (.respondPush(pr: "web#2", confirmed: true, wait: false), "respondPush"),
    (.respondReplyOnly(pr: "web#2", confirmed: true, wait: false), "respondReplyOnly"),
    (.respondCancel(pr: "web#2"), "respondCancel"),
    (.respondDismiss(pr: "web#2"), "respondDismiss"),
    (.configShow, "configShow"),
    (.setRefreshInterval(minutes: 5), "configSetRefreshInterval"),
    (.setLaunchAtLogin(enabled: true), "configSetLaunchAtLogin"),
    (.accountList, "accountList"),
    (.accountSetEnabled(login: "me", enabled: false), "accountSetEnabled"),
    (.accountReload, "accountReload"),
    (.repoList(account: nil), "repoList"),
    (.repoAvailable(account: nil, reload: true), "repoAvailable"),
    (.repoAdd(repo: "acme/api", account: nil), "repoAdd"),
    (.repoRemove(repo: "acme/api", account: nil), "repoRemove"),
    (.repoSet(repo: "acme/api", account: nil, changes: RepoChanges(addBranches: ["main"])), "repoSet"),
    (.repoBranches(repo: "acme/api", account: nil, reload: false), "repoBranches"),
    (.followList(repo: nil, account: nil), "followList"),
    (.followAdd(repo: "acme/api", users: ["ana"], account: nil), "followAdd"),
    (.followRemove(repo: "acme/api", users: ["ana"], account: nil), "followRemove"),
    (.followSuggestions(repo: "acme/api", account: nil), "followSuggestions"),
    (.notifyList, "notifyList"),
    (.notifySet(kind: .myFeedback, enabled: false), "notifySet"),
    (.notifySetEnabled(enabled: false), "notifySetEnabled"),
    (.claudeShow, "claudeShow"),
    (.claudeSet(changes: ClaudeChanges(filterEnabled: false)), "claudeSet"),
    (.claudeReset, "claudeReset"),
    (.claudeSkills, "claudeSkillList"),
    (.toolsList, "toolsList"),
    (.toolsSet(tool: .git, path: "/usr/bin/git"), "toolsSet"),
    (.slackShow, "slackShow"),
    (.slackSetEnabled(enabled: true), "slackSetEnabled"),
    (.slackSetProvider(provider: .claudeConnector), "slackSetProvider"),
    (.slackTokenSet(token: "xoxp-1"), "slackTokenSet"),
    (.slackTokenClear, "slackTokenClear"),
    (.slackSetToggle(toggle: .rounds, enabled: false), "slackSetToggle"),
    (.slackSetEmoji(kind: .eyes, name: "eyes"), "slackSetEmoji"),
    (.slackSetSearchDays(days: 30), "slackSetSearchDays"),
    (.slackTemplateList, "slackTemplateList"),
    (.slackTemplateSet(template: .round, text: "x{n}"), "slackTemplateSet"),
    (.slackTemplateReset(template: .round), "slackTemplateReset"),
    (.slackCheck, "slackCheck"),
    (.slackSelfTest(confirmed: true), "slackSelfTest"),
    (.slackChannels(reload: false), "slackChannels"),
]

enum CommandDispatcherTests {
    static let cases: [TestCase] = [
        TestCase("dispatcher: cada comando llama a su método") { try await everyCommand() },
        TestCase("dispatcher: los argumentos llegan") { try await arguments() },
        TestCase("dispatcher: publicar, pushear y la prueba de Slack exigen confirmación") { try await confirmations() },
        TestCase("dispatcher: errores → CommandFailure") { try await errors() },
        TestCase("dispatcher: los eventos de una espera llegan al sink") { try await events() },
    ]

    @MainActor
    private static func run(_ command: AppCommand, _ fake: FakeActions,
                            events: @escaping CommandEventSink = { _ in }) async -> Result<JSONValue, CommandFailure> {
        await CommandDispatcher.run(command, on: fake, events: events)
    }

    @MainActor
    private static func everyCommand() async throws {
        try expectEqual(Set(dispatchSamples.map(\.command.name)), Set(AppCommand.Name.allCases))
        for sample in dispatchSamples {
            let fake = FakeActions()
            let result = await run(sample.command, fake)
            if case .failure(let error) = result { throw TestFailure(description: "\(sample.command.name): \(error.message)") }
            let call = fake.calls.last?.split(separator: " ").first.map(String.init)
            try expectEqual(call, sample.call)
        }
    }

    @MainActor
    private static func arguments() async throws {
        let fake = FakeActions()
        _ = await run(.reviewPublish(pr: "acme/api#3", event: .approve, only: ["1", "f2"], withComments: false,
                                     allInBody: true, confirmed: true), fake)
        try expectEqual(fake.calls.last, #"reviewPublish acme/api#3 APPROVE only=["1", "f2"] comments=false body=true"#)
        _ = await run(.respondSelect(pr: "web#2", items: ["1", "2"],
                                     change: RespondSelectionChange(implement: false, replyText: "Thanks")), fake)
        try expectEqual(fake.calls.last, #"respondSelect web#2 ["1", "2"] implement=false reply=- text=Thanks plan=-"#)
        let result = await run(.reviewCancel(pr: "x"), fake)
        try expectEqual(result, .success(.ok))
    }

    @MainActor
    private static func confirmations() async throws {
        let unconfirmed: [AppCommand] = [
            .reviewPublish(pr: "a#1", event: .comment, only: nil, withComments: true, allInBody: false, confirmed: false),
            .respondPush(pr: "a#1", confirmed: false, wait: false),
            .respondReplyOnly(pr: "a#1", confirmed: false, wait: false),
            .slackSelfTest(confirmed: false),
        ]
        for command in unconfirmed {
            let fake = FakeActions()
            let result = await run(command, fake)
            guard case .failure(let failure) = result else { throw TestFailure(description: "\(command.name) no pidió --yes") }
            try expectEqual(failure.code, .confirmationRequired)
            try expectEqual(fake.calls, [])
        }
    }

    @MainActor
    private static func errors() async throws {
        let fake = FakeActions()
        fake.failure = CommandFailure(.notFound, "No PR")
        let notFound = await run(.reviewShow(pr: "x"), fake)
        try expectEqual(notFound, .failure(CommandFailure(.notFound, "No PR")))
        fake.failure = PRBarError.toolNotFound("gh")
        let failed = await run(.reviewShow(pr: "x"), fake)
        try expectEqual(failed, .failure(CommandFailure(.failed, PRBarError.toolNotFound("gh").localizedDescription)))
        fake.failure = CancellationError()
        let cancelled = await run(.reviewShow(pr: "x"), fake)
        try expectEqual(cancelled, .failure(CommandFailure(.cancelled, "Canceled.")))
    }

    @MainActor
    private static func events() async throws {
        let fake = FakeActions()
        fake.waitEvents = [.progress(message: "Queued"), .progress(message: "Reviewing…")]
        let box = EventBox()
        _ = await run(.reviewStart(pr: "x", wait: true), fake) { event in box.append(event) }
        try expectEqual(box.events, fake.waitEvents)
    }
}

/// Junta eventos desde un closure `@Sendable`.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CommandEvent] = []

    func append(_ event: CommandEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [CommandEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
```

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests dispatcher`
Expected: no compila (`cannot find type 'StatusActions'`).

- [ ] **Step 3: Implementar los protocolos (`Sources/PRBarCore/CommandActions.swift`)**

```swift
import Foundation

// Lo que la app sabe hacer, agrupado como sus pantallas. `AppModel` implementa todo (Tasks 11–12) llamando a los
// mismos métodos que usa la UI; `CommandDispatcher` traduce cada `AppCommand` a uno de estos métodos.
// Los métodos lanzan `CommandFailure` con el texto de la UI y el comando sugerido (spec C.6).

@MainActor
public protocol StatusActions: AnyObject {
    func status() async throws -> StatusInfo
    func listPRs(list: PRListFilter?, account: String?) throws -> [PRInfo]
    func resolvePR(_ pr: String) throws -> PRLink
    func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo]
    func historyShow(id: String) throws -> HistoryDetail
    func historyReopen(id: String) throws
    func refresh() async
    func open(pr: String, target: OpenTarget) throws -> PRLink
    func openSettings(tab: SettingsTabName?)
    func openHistory(id: String?) throws
    func quit()
}

@MainActor
public protocol ReviewActions: AnyObject {
    func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo
    func reviewShow(pr: String) throws -> ReviewInfo
    func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo
    func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo
    func reviewSetComment(pr: String, text: String) throws -> ReviewInfo
    func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool, allInBody: Bool) async throws -> PublishedReviewInfo
    func reviewCancel(pr: String) throws
    func reviewDismiss(pr: String) throws
}

@MainActor
public protocol RespondActions: AnyObject {
    func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondShow(pr: String) throws -> RespondInfo
    func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo
    func respondReset(pr: String) throws -> RespondInfo
    func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondDiff(pr: String) throws -> RespondDiff
    func respondPush(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
    func respondCancel(pr: String) throws
    func respondDismiss(pr: String) throws
}

@MainActor
public protocol ConfigActions: AnyObject {
    func configShow() -> AppConfig
    func configSetRefreshInterval(minutes: Int) throws
    func configSetLaunchAtLogin(enabled: Bool) throws
    func accountList() -> [AccountInfo]
    func accountSetEnabled(login: String, enabled: Bool) throws
    func accountReload() async throws -> [AccountInfo]
    func repoList(account: String?) throws -> [RepoInfo]
    func repoAvailable(account: String?, reload: Bool) async throws -> [String]
    func repoAdd(repo: String, account: String?) async throws -> RepoInfo
    func repoRemove(repo: String, account: String?) throws
    func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo
    func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo
    func followList(repo: String?, account: String?) throws -> [FollowInfo]
    func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo
    func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo
    func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo]
    func notifyList() async -> NotificationsInfo
    func notifySet(kind: NotificationSettingName, enabled: Bool) throws
    func notifySetEnabled(enabled: Bool) throws
    func claudeShow() -> ClaudeSettings
    func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings
    func claudeReset() throws -> ClaudeSettings
    func claudeSkillList() async -> [SkillInfo]
    func toolsList() -> [ToolInfo]
    func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo]
}

@MainActor
public protocol SlackActions: AnyObject {
    func slackShow() -> SlackInfo
    func slackSetEnabled(enabled: Bool) throws
    func slackSetProvider(provider: SlackProvider) throws
    func slackTokenSet(token: String) async throws -> SlackCheckInfo
    func slackTokenClear() throws
    func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws
    func slackSetEmoji(kind: SlackEmojiKind, name: String) throws
    func slackSetSearchDays(days: Int) throws
    func slackTemplateList() -> [TemplateInfo]
    func slackTemplateSet(template: SlackTemplateName, text: String) throws
    func slackTemplateReset(template: SlackTemplateName) throws
    func slackCheck() async throws -> SlackCheckInfo
    func slackSelfTest() async throws -> [SelfTestStepInfo]
    func slackChannels(reload: Bool) async throws -> [ChannelInfo]
}

/// Todo lo que la CLI puede pedirle a la app.
public typealias PRBarActions = StatusActions & ReviewActions & RespondActions & ConfigActions & SlackActions
```

Los nombres de los métodos no pisan propiedades de `AppModel` (`history`, `claudeSkills`, `tools`): por eso `historyList`, `claudeSkillList`, `toolsList`.

- [ ] **Step 4: Implementar el dispatcher (`Sources/PRBarCore/CommandDispatcher.swift`)**

```swift
import Foundation

/// `AppCommand` → método de `PRBarActions`. Es el único `switch` sobre los comandos: un caso nuevo sin despachar
/// no compila. Publicar, pushear, aprobar y la prueba de Slack exigen `confirmed` (la CLI lo manda con `--yes` o
/// después de preguntar en la terminal); acá se vuelve a verificar por si otro cliente se lo salteó.
public enum CommandDispatcher {
    @MainActor
    public static func run(_ command: AppCommand, on actions: any PRBarActions,
                           events: @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure> {
        do {
            return .success(try await perform(command, actions, events))
        } catch let failure as CommandFailure {
            return .failure(failure)
        } catch is CancellationError {
            return .failure(CommandFailure(.cancelled, "Canceled."))
        } catch {
            return .failure(CommandFailure(.failed, error.localizedDescription))
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(encoding: value)
    }

    private static func requireConfirmation(_ confirmed: Bool, _ what: String) throws {
        guard confirmed else {
            throw CommandFailure(.confirmationRequired, "\(what) needs confirmation: run it again with --yes.")
        }
    }

    @MainActor
    private static func perform(_ command: AppCommand, _ actions: any PRBarActions,
                                _ events: @escaping CommandEventSink) async throws -> JSONValue {
        switch command {
        // Estado
        case .status:
            return try encode(await actions.status())
        case .listPRs(let list, let account):
            return try encode(actions.listPRs(list: list, account: account))
        case .resolvePR(let pr):
            return try encode(actions.resolvePR(pr))
        case .history(let repo, let kind, let limit, let search):
            return try encode(actions.historyList(repo: repo, kind: kind, limit: limit, search: search))
        case .historyShow(let id):
            return try encode(actions.historyShow(id: id))
        case .historyReopen(let id):
            try actions.historyReopen(id: id)
            return .ok
        case .refresh:
            await actions.refresh()
            return .ok
        // Ventanas / app
        case .open(let pr, let target):
            return try encode(actions.open(pr: pr, target: target))
        case .openSettings(let tab):
            actions.openSettings(tab: tab)
            return .ok
        case .openHistory(let id):
            try actions.openHistory(id: id)
            return .ok
        case .quit:
            actions.quit()
            return .ok
        // Review
        case .reviewStart(let pr, let wait):
            return try encode(await actions.reviewStart(pr: pr, wait: wait, events: events))
        case .reviewShow(let pr):
            return try encode(actions.reviewShow(pr: pr))
        case .reviewEdit(let pr, let finding, let title, let body):
            return try encode(actions.reviewEdit(pr: pr, finding: finding, title: title, body: body))
        case .reviewSetIncluded(let pr, let findings, let all, let included):
            return try encode(actions.reviewSetIncluded(pr: pr, findings: findings, all: all, included: included))
        case .reviewSetComment(let pr, let text):
            return try encode(actions.reviewSetComment(pr: pr, text: text))
        case .reviewPublish(let pr, let event, let only, let withComments, let allInBody, let confirmed):
            try requireConfirmation(confirmed, "Posting a review")
            return try encode(await actions.reviewPublish(pr: pr, event: event, only: only, withComments: withComments,
                                                          allInBody: allInBody))
        case .reviewCancel(let pr):
            try actions.reviewCancel(pr: pr)
            return .ok
        case .reviewDismiss(let pr):
            try actions.reviewDismiss(pr: pr)
            return .ok
        // Respond
        case .respondStart(let pr, let wait):
            return try encode(await actions.respondStart(pr: pr, wait: wait, events: events))
        case .respondShow(let pr):
            return try encode(actions.respondShow(pr: pr))
        case .respondSelect(let pr, let items, let change):
            return try encode(actions.respondSelect(pr: pr, items: items, change: change))
        case .respondReset(let pr):
            return try encode(actions.respondReset(pr: pr))
        case .respondImplement(let pr, let wait):
            return try encode(await actions.respondImplement(pr: pr, wait: wait, events: events))
        case .respondTest(let pr, let wait):
            return try encode(await actions.respondTest(pr: pr, wait: wait, events: events))
        case .respondDiff(let pr):
            return try encode(actions.respondDiff(pr: pr))
        case .respondPush(let pr, let confirmed, let wait):
            try requireConfirmation(confirmed, "Pushing and posting replies")
            return try encode(await actions.respondPush(pr: pr, wait: wait, events: events))
        case .respondReplyOnly(let pr, let confirmed, let wait):
            try requireConfirmation(confirmed, "Posting replies")
            return try encode(await actions.respondReplyOnly(pr: pr, wait: wait, events: events))
        case .respondCancel(let pr):
            try actions.respondCancel(pr: pr)
            return .ok
        case .respondDismiss(let pr):
            try actions.respondDismiss(pr: pr)
            return .ok
        // Configuración
        case .configShow:
            return try encode(actions.configShow())
        case .setRefreshInterval(let minutes):
            try actions.configSetRefreshInterval(minutes: minutes)
            return .ok
        case .setLaunchAtLogin(let enabled):
            try actions.configSetLaunchAtLogin(enabled: enabled)
            return .ok
        case .accountList:
            return try encode(actions.accountList())
        case .accountSetEnabled(let login, let enabled):
            try actions.accountSetEnabled(login: login, enabled: enabled)
            return .ok
        case .accountReload:
            return try encode(await actions.accountReload())
        case .repoList(let account):
            return try encode(actions.repoList(account: account))
        case .repoAvailable(let account, let reload):
            return try encode(await actions.repoAvailable(account: account, reload: reload))
        case .repoAdd(let repo, let account):
            return try encode(await actions.repoAdd(repo: repo, account: account))
        case .repoRemove(let repo, let account):
            try actions.repoRemove(repo: repo, account: account)
            return .ok
        case .repoSet(let repo, let account, let changes):
            return try encode(await actions.repoSet(repo: repo, account: account, changes: changes))
        case .repoBranches(let repo, let account, let reload):
            return try encode(await actions.repoBranches(repo: repo, account: account, reload: reload))
        case .followList(let repo, let account):
            return try encode(actions.followList(repo: repo, account: account))
        case .followAdd(let repo, let users, let account):
            return try encode(await actions.followAdd(repo: repo, users: users, account: account))
        case .followRemove(let repo, let users, let account):
            return try encode(actions.followRemove(repo: repo, users: users, account: account))
        case .followSuggestions(let repo, let account):
            return try encode(await actions.followSuggestions(repo: repo, account: account))
        case .notifyList:
            return try encode(await actions.notifyList())
        case .notifySet(let kind, let enabled):
            try actions.notifySet(kind: kind, enabled: enabled)
            return .ok
        case .notifySetEnabled(let enabled):
            try actions.notifySetEnabled(enabled: enabled)
            return .ok
        case .claudeShow:
            return try encode(actions.claudeShow())
        case .claudeSet(let changes):
            return try encode(actions.claudeSet(changes: changes))
        case .claudeReset:
            return try encode(actions.claudeReset())
        case .claudeSkills:
            return try encode(await actions.claudeSkillList())
        case .toolsList:
            return try encode(actions.toolsList())
        case .toolsSet(let tool, let path):
            return try encode(await actions.toolsSet(tool: tool, path: path))
        // Slack
        case .slackShow:
            return try encode(actions.slackShow())
        case .slackSetEnabled(let enabled):
            try actions.slackSetEnabled(enabled: enabled)
            return .ok
        case .slackSetProvider(let provider):
            try actions.slackSetProvider(provider: provider)
            return .ok
        case .slackTokenSet(let token):
            return try encode(await actions.slackTokenSet(token: token))
        case .slackTokenClear:
            try actions.slackTokenClear()
            return .ok
        case .slackSetToggle(let toggle, let enabled):
            try actions.slackSetToggle(toggle: toggle, enabled: enabled)
            return .ok
        case .slackSetEmoji(let kind, let name):
            try actions.slackSetEmoji(kind: kind, name: name)
            return .ok
        case .slackSetSearchDays(let days):
            try actions.slackSetSearchDays(days: days)
            return .ok
        case .slackTemplateList:
            return try encode(actions.slackTemplateList())
        case .slackTemplateSet(let template, let text):
            try actions.slackTemplateSet(template: template, text: text)
            return .ok
        case .slackTemplateReset(let template):
            try actions.slackTemplateReset(template: template)
            return .ok
        case .slackCheck:
            return try encode(await actions.slackCheck())
        case .slackSelfTest(let confirmed):
            try requireConfirmation(confirmed, "Sending a test message to your Slack DM")
            return try encode(await actions.slackSelfTest())
        case .slackChannels(let reload):
            return try encode(await actions.slackChannels(reload: reload))
        }
    }
}
```

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests dispatcher`
Expected: `5/5 passed`.

Run: `swift run PRBarTests`
Expected: todos pasan.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/CommandActions.swift Sources/PRBarCore/CommandDispatcher.swift Sources/PRBarTests/FakeActions.swift Sources/PRBarTests/CommandDispatcherTests.swift Sources/PRBarTests/main.swift
git commit -m "Add the action protocols and CommandDispatcher"
```

---

### Task 8: Socket Unix, `CommandServer` y `CommandClient`

**Files:**
- Create: `Sources/PRBarCore/UnixSocket.swift`, `Sources/PRBarCore/CommandServer.swift`, `Sources/PRBarTests/CommandServerTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ CommandServerTests.cases`)

- [ ] **Step 1: Tests (socket real en una carpeta temporal corta)**

```swift
import Foundation
import PRBarCore

/// `/tmp/prbar-<8 hex>/s.sock`: `sun_path` admite 104 bytes y `$TMPDIR` es demasiado largo.
func shortSocketURL() throws -> URL {
    let dir = URL(fileURLWithPath: "/tmp/prbar-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("s.sock")
}

private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func echoServer(_ url: URL, allowedUID: uid_t = getuid(), events: [CommandEvent] = []) throws -> CommandServer {
    let server = CommandServer(socketURL: url, appVersion: "9.9.9", allowedUID: allowedUID) { command, sink in
        events.forEach(sink)
        return .success(.object(["echo": .string(command.name.rawValue)]))
    }
    try server.start()
    return server
}

/// La CLI bloquea su hilo: en los tests corre fuera del hilo principal.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached { try body() }.value
}

enum CommandServerTests {
    static let cases: [TestCase] = [
        TestCase("socket: carpeta 0700 y socket 0600") {
            let url = try shortSocketURL()
            let server = try echoServer(url)
            defer { server.stop() }
            try expectEqual(try permissions(url.deletingLastPathComponent()), 0o700)
            try expectEqual(try permissions(url), 0o600)
        },
        TestCase("socket: hello, pedido y respuesta") {
            let url = try shortSocketURL()
            let server = try echoServer(url)
            defer { server.stop() }
            let (version, result) = try await offMain { () -> (String, JSONValue) in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                return (client.appVersion, try client.send(.refresh))
            }
            try expectEqual(version, "9.9.9")
            try expectEqual(result, .object(["echo": .string("refresh")]))
        },
        TestCase("socket: varios pedidos por la misma conexión y eventos antes de la respuesta") {
            let url = try shortSocketURL()
            let server = try echoServer(url, events: [.progress(message: "a"), .text(delta: "b")])
            defer { server.stop() }
            let (events, second) = try await offMain { () -> ([CommandEvent], JSONValue) in
                let client = try CommandClient.connect(socketURL: url, clientVersion: "1.0.0")
                defer { client.close() }
                var events: [CommandEvent] = []
                _ = try client.send(.status) { events.append($0) }
                return (events, try client.send(.quit))
            }
            try expectEqual(events, [.progress(message: "a"), .text(delta: "b")])
            try expectEqual(second, .object(["echo": .string("quit")]))
        },
        TestCase("socket: versión de protocolo distinta → protocolMismatch") {
            let url = try shortSocketURL()
            let server = try echoServer(url)
            defer { server.stop() }
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "2.0.0", protocolVersion: 99) }
            }
            try expectEqual(error as? CommandFailure, .protocolMismatch(cli: "2.0.0", app: "9.9.9"))
        },
        TestCase("socket: otro usuario → unauthorized") {
            let url = try shortSocketURL()
            let server = try echoServer(url, allowedUID: getuid() + 1)
            defer { server.stop() }
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            }
            try expectEqual((error as? CommandFailure)?.code, .unauthorized)
        },
        TestCase("socket: sin app → ConnectError.unavailable") {
            let url = try shortSocketURL()
            let error = try await expectThrows {
                _ = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            }
            guard case .unavailable? = error as? CommandClient.ConnectError else {
                throw TestFailure(description: "esperaba unavailable, fue \(error)")
            }
        },
        TestCase("socket: si el cliente se va, se cancela lo que esperaba") {
            let url = try shortSocketURL()
            let cancelled = Flag()
            let server = CommandServer(socketURL: url, appVersion: "9.9.9") { _, _ in
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                cancelled.set()
                return .failure(CommandFailure(.cancelled, "Canceled."))
            }
            try server.start()
            defer { server.stop() }
            let client = try await offMain { try CommandClient.connect(socketURL: url, clientVersion: "1.0.0") }
            let sending = Task.detached { _ = try? client.send(.reviewStart(pr: "a#1", wait: true)) }
            try await Task.sleep(for: .milliseconds(200))
            client.close()
            _ = await sending.value
            for _ in 0..<100 where !cancelled.isSet { try await Task.sleep(for: .milliseconds(20)) }
            try expect(cancelled.isSet)
        },
        TestCase("socket: stop borra el socket") {
            let url = try shortSocketURL()
            let server = try echoServer(url)
            server.stop()
            try expect(!FileManager.default.fileExists(atPath: url.path))
        },
    ]
}
```

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests socket`
Expected: no compila (`cannot find 'CommandServer'`).

- [ ] **Step 3: Implementar `Sources/PRBarCore/UnixSocket.swift`**

```swift
import Darwin
import Foundation

public struct SocketError: Error, Equatable, LocalizedError {
    public let operation: String
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    static func last(_ operation: String) -> SocketError {
        SocketError(operation: operation, code: errno)
    }

    public var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

/// Lo mínimo de sockets Unix (`AF_UNIX`, `SOCK_STREAM`) que usan `CommandServer` y `CommandClient`.
enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var result = sockaddr_un()
        result.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: result.sun_path)
        guard bytes.count < capacity else {
            throw SocketError(operation: "socket path too long (\(bytes.count) bytes)", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &result.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return result
    }

    /// Escucha en `path` con permisos 0600 (umask 077 durante el `bind`). Borra un socket viejo en la misma ruta.
    static func listen(path: String) throws -> Int32 {
        var addr = try address(path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0 else {
            let error = SocketError.last("bind")
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let error = SocketError.last("listen")
            close(fd)
            throw error
        }
        return fd
    }

    static func connect(path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = SocketError.last("connect")
            close(fd)
            throw error
        }
        noSigPipe(fd)
        return fd
    }

    /// Escribir en un socket cerrado devuelve EPIPE en vez de matar el proceso.
    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// El uid del proceso del otro lado (spec C.2: solo el del usuario).
    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
}

/// Un extremo del socket que lee y escribe líneas. `readLine` se llama desde un solo hilo; `write` y `close` son
/// seguros desde varios.
final class LineConnection: @unchecked Sendable {
    /// Una línea más larga se considera un error y corta la conexión.
    static let maxLine = 16 * 1024 * 1024

    let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// La próxima línea (sin `\n`), o `nil` si el otro extremo cerró.
    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count <= Self.maxLine else { return nil }
        }
    }

    func write(_ line: String) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written < 0 {
                if errno == EINTR { continue }
                throw SocketError.last("write")
            }
            offset += written
        }
    }

    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
```

- [ ] **Step 4: Implementar `Sources/PRBarCore/CommandServer.swift`**

```swift
import Darwin
import Foundation

/// El socket de la app (spec C.2). Cada conexión: `getpeereid` (solo el uid del usuario), `hello` con la versión
/// del protocolo y después pedidos `CommandRequest`, cada uno en su `Task`. Si el cliente se desconecta se cancelan
/// sus tareas (las esperas de `--wait` terminan; lo que no debe cortarse, como publicar, corre aparte).
public final class CommandServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AppCommand, @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure>

    private let socketURL: URL
    private let appVersion: String
    private let allowedUID: uid_t
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: LineConnection] = [:]

    public init(socketURL: URL, appVersion: String, allowedUID: uid_t = getuid(), handler: @escaping Handler) {
        self.socketURL = socketURL
        self.appVersion = appVersion
        self.allowedUID = allowedUID
        self.handler = handler
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.secure(directory)
        let fd = try UnixSocket.listen(path: socketURL.path)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "PRBar.CommandServer"))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Darwin.close(fd) }
        locked {
            listenFD = fd
            acceptSource = source
        }
        source.resume()
    }

    /// La carpeta del socket tiene que ser del usuario y queda en 0700 (spec C.2).
    static func secure(_ directory: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value, owner != getuid() {
            throw SocketError(operation: "\(directory.path) belongs to another user", code: EPERM)
        }
        guard chmod(directory.path, 0o700) == 0 else { throw SocketError.last("chmod") }
    }

    public func stop() {
        let (source, open) = locked { () -> (DispatchSourceRead?, [LineConnection]) in
            let source = acceptSource
            let open = Array(connections.values)
            acceptSource = nil
            connections = [:]
            return (source, open)
        }
        source?.cancel()
        open.forEach { $0.close() }
        unlink(socketURL.path)
    }

    private func acceptPending() {
        let listening = locked { listenFD }
        while true {
            let fd = accept(listening, nil, nil)
            guard fd >= 0 else { return }
            // Los sockets aceptados heredan O_NONBLOCK: se leen bloqueando, cada uno en su hilo.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            UnixSocket.noSigPipe(fd)
            let connection = LineConnection(fd: fd)
            guard UnixSocket.peerUID(fd) == allowedUID else {
                let failure = CommandFailure(.unauthorized, "Only the user running PRBar can use its socket.")
                try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
                connection.close()
                continue
            }
            locked { connections[ObjectIdentifier(connection)] = connection }
            Thread.detachNewThread { [weak self] in self?.serve(connection) }
        }
    }

    private func serve(_ connection: LineConnection) {
        defer {
            _ = locked { connections.removeValue(forKey: ObjectIdentifier(connection)) }
            connection.close()
        }
        guard let first = connection.readLine(),
              let hello = try? CommandProtocol.decode(HelloMessage.self, line: first) else {
            let failure = CommandFailure(.invalidUsage, "Expected a hello message.")
            try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
            return
        }
        guard hello.hello.protocolVersion == CommandProtocol.version else {
            let failure = CommandFailure.protocolMismatch(cli: hello.hello.version, app: appVersion)
            try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
            return
        }
        let answer = HelloMessage(hello: Hello(protocolVersion: CommandProtocol.version, version: appVersion))
        guard (try? connection.write(CommandProtocol.line(answer))) != nil else { return }

        var tasks: [Task<Void, Never>] = []
        let handler = self.handler
        while let line = connection.readLine() {
            guard let request = try? CommandProtocol.decode(CommandRequest.self, line: line) else {
                let failure = CommandFailure(.invalidUsage, "Couldn't read the request.")
                try? connection.write(CommandProtocol.line(CommandResponse.failure(id: 0, failure)))
                continue
            }
            tasks.append(Task {
                let id = request.id
                let result = await handler(request.command) { event in
                    try? connection.write(CommandProtocol.line(CommandResponse.event(id: id, event)))
                }
                let response: CommandResponse = switch result {
                case .success(let value): .success(id: id, value)
                case .failure(let failure): .failure(id: id, failure)
                }
                try? connection.write(CommandProtocol.line(response))
            })
        }
        tasks.forEach { $0.cancel() }
    }
}

/// El lado de la CLI: conecta, saluda y manda comandos de a uno, bloqueando el hilo que lo llama.
public final class CommandClient {
    public enum ConnectError: Error, Equatable {
        /// No hay nadie escuchando (la app no está corriendo) o cortó la conexión.
        case unavailable(String)
    }

    private let connection: LineConnection
    public let appVersion: String
    private var nextID = 1

    private init(connection: LineConnection, appVersion: String) {
        self.connection = connection
        self.appVersion = appVersion
    }

    /// `protocolVersion` solo cambia en los tests.
    public static func connect(socketURL: URL, clientVersion: String,
                               protocolVersion: Int = CommandProtocol.version) throws -> CommandClient {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: socketURL.path)
        } catch {
            throw ConnectError.unavailable(error.localizedDescription)
        }
        let connection = LineConnection(fd: fd)
        // Si la app ya contestó con un error (uid ajeno), escribir puede fallar: igual se lee su respuesta.
        try? connection.write(CommandProtocol.line(HelloMessage(hello: Hello(protocolVersion: protocolVersion,
                                                                            version: clientVersion))))
        guard let line = connection.readLine() else {
            connection.close()
            throw ConnectError.unavailable("PRBar closed the connection.")
        }
        if let hello = try? CommandProtocol.decode(HelloMessage.self, line: line) {
            return CommandClient(connection: connection, appVersion: hello.hello.version)
        }
        connection.close()
        if let response = try? CommandProtocol.decode(CommandResponse.self, line: line), let error = response.error {
            throw error
        }
        throw ConnectError.unavailable("Unexpected answer from PRBar.")
    }

    /// Manda `command` y espera la respuesta final; los eventos van a `onEvent`. Un error de la app se lanza como
    /// `CommandFailure`.
    public func send(_ command: AppCommand, onEvent: (CommandEvent) -> Void = { _ in }) throws -> JSONValue {
        let id = nextID
        nextID += 1
        do {
            try connection.write(CommandProtocol.line(CommandRequest(id: id, command: command)))
        } catch {
            throw ConnectError.unavailable(error.localizedDescription)
        }
        while let line = connection.readLine() {
            guard let response = try? CommandProtocol.decode(CommandResponse.self, line: line), response.id == id else {
                continue
            }
            if let event = response.event {
                onEvent(event)
                continue
            }
            if let error = response.error { throw error }
            return response.result ?? .null
        }
        throw ConnectError.unavailable("PRBar closed the connection.")
    }

    public func close() {
        connection.close()
    }
}
```

`CommandClient` no es `Sendable`: en el test de cancelación se usa desde dos tareas a propósito (una bloqueada leyendo, otra cerrando). Si el compilador marca el `Task.detached` que lo captura, envolverlo en una clase `@unchecked Sendable` dentro del test.

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests socket`
Expected: `8/8 passed` (sin colgarse: si un test queda esperando, revisar que la parte que bloquea esté en `offMain`).

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/UnixSocket.swift Sources/PRBarCore/CommandServer.swift Sources/PRBarTests/CommandServerTests.swift Sources/PRBarTests/main.swift
git commit -m "Add the private Unix socket server and client with uid and protocol checks"
```

---

### Task 9: Publicar un review sube a `AppModel`

Después del plan 6, la ventana de Review lee y escribe `ChatCoordinator.reviewEdits`, pero **publicar** todavía arma la selección dentro de la ventana. Spec C.2: las acciones de la UI que no son métodos de `AppModel` (justamente "publicar con selección") suben a `AppModel`, para que la ventana y `prbar review publish` compartan el código.

**Files:**
- Modify: `Sources/PRBar/AppModel.swift`, `Sources/PRBar/Review/ReviewWindow.swift`

- [ ] **Step 1: `AppModel`: `publishReview` y `publishedReviews`**

En `Sources/PRBar/AppModel.swift`, junto a las demás propiedades `@Published`:

```swift
    /// Reviews publicados desde la ventana o la CLI, por id de draft: una ventana abierta pasa a "publicado".
    @Published private(set) var publishedReviews: [UUID: PublishedReview] = [:]
```

Después de `publish(draft:selected:general:event:allInBody:)`:

```swift
    /// Publica lo elegido en la ventana de Review (o con `prbar review …`): el `reviewEdits` del coordinador del draft.
    /// `only`: ids de hallazgos a publicar en vez de la selección (sin cambiarla); `withComments: false` publica solo el
    /// veredicto. Mientras publica, el chat queda bloqueado; después, de solo lectura (spec B.2). La publicación corre
    /// en su propia `Task`: si quien la pidió se va (la CLI se desconecta), no se corta a la mitad.
    func publishReview(draft: ReviewDraft, event: ReviewEvent, only: Set<String>? = nil, withComments: Bool = true,
                       allInBody: Bool = false) async throws -> PublishedReview {
        let chat = reviewChat(for: draft)
        let edits = chat.reviewEdits
        let comments = withComments ? edits.comments(of: draft, only: only) : []
        let general = withComments ? edits.generalComment : ""
        chat.setLock("Posting the review…")
        defer { chat.setLock(nil) }
        let result = try await Task { @MainActor in
            try await self.publish(draft: draft, selected: comments, general: general, event: event,
                                   allInBody: allInBody || self.isOutdated(draft))
        }.value
        publishedReviews[draft.id] = result
        chat.markReadOnly()
        return result
    }
```

`dismissReview(prID:)` (que el plan 6 dejó descartando el chat) marca además el review listo como `abandoned`, como hace `startReview` al reemplazarlo, porque ahora la CLI puede descartar uno listo (`prbar review dismiss`):

```swift
    func dismissReview(prID: String) {
        if case .ready(let draft)? = reviews.phases[prID] {
            discardChat(draftID: draft.id)
            do {
                try history.markAbandoned(id: draft.id)
            } catch {
                AppLog.write("History: couldn't mark the review of \(prID) as abandoned: \(error)")
            }
            historyRevision += 1
        }
        reviews.dismiss(prID: prID)
    }
```

En `openReview(prID:)`, las opciones de la ventana quedan sin `closeConfirmation`: lo elegido vive en el coordinador del draft y no se pierde al cerrar (decisión 3):

```swift
            options: WindowOptions(sharedFrameKey: "ReviewWindowFrame"),
```

- [ ] **Step 2: `ReviewWindow` publica por `AppModel` y muestra lo publicado desde la CLI**

En `Sources/PRBar/Review/ReviewWindow.swift`:

1. Agregar, junto a las otras propiedades calculadas:

```swift
    /// Publicado desde esta ventana o desde la CLI (`prbar review publish`).
    private var shownResult: PublishedReview? { result ?? model.publishedReviews[draft.id] }
```

2. En `body`, `if let result {` pasa a `if let result = shownResult {`; en `hasUnsavedChanges`, `result == nil` pasa a `shownResult == nil`; y el `.onChange(of: result != nil, …)` que agregó el plan 6 pasa a `.onChange(of: shownResult != nil, initial: true) { _, posted in if posted { chat.markReadOnly() } }`.

3. `publish(_:allInBody:withComments:)` queda:

```swift
    /// Si falla, el error se muestra y la selección y lo editado quedan como estaban (spec §8.7).
    /// `withComments: false` publica solo el veredicto y deja la selección y los textos como están.
    private func publish(_ event: ReviewEvent, allInBody: Bool = false, withComments: Bool = true) {
        guard !publishing else { return }
        publishing = true
        error = nil
        inlineRejected = nil
        Task { @MainActor in
            do {
                result = try await model.publishReview(draft: draft, event: event, withComments: withComments,
                                                       allInBody: allInBody)
            } catch {
                self.error = error.localizedDescription
                if error is InlineCommentsRejected { inlineRejected = event }
            }
            publishing = false
        }
    }
```

(`AppModel.publishReview` ya suma `isOutdated`, así que la ventana no lo pasa.)

No agregar ni quitar controles (`Button`, `TextField`…): el inventario de la Task 21 los cuenta.

- [ ] **Step 3: Compilar, tests y capturas**

Run: `swift build 2>&1 | grep error ; swift run PRBarTests`
Expected: sin errores; todo pasa.

Run: `swift run PRBar --snapshots /tmp/prbar-snap-t9 --appearance light`
Expected: `review-window-light.png` y `review-published-light.png` iguales a las que dejó el plan 6.

- [ ] **Step 4: Verificación manual**

`Scripts/bundle.sh --install`. Revisar un PR, abrir su ventana, destildar un hallazgo, editar un texto, **cerrar** la ventana (no pide confirmación) y reabrirla desde la fila: todo sigue. Publicar "Comment" en un PR de prueba: la ventana pasa a "Posted" y el chat queda de solo lectura.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBar/AppModel.swift Sources/PRBar/Review/ReviewWindow.swift
git commit -m "Move posting a review with the window's selection to AppModel"
```

---

### Task 10: Las acciones de Respond pasan por `AppModel`

Lo mismo para Respond: elegir, implementar, publicar respuestas y pushear pasan a métodos de `AppModel` que leen `ChatCoordinator.selections`, y la ventana los llama.

**Files:**
- Modify: `Sources/PRBar/AppModel.swift`, `Sources/PRBar/Respond/RespondWindow.swift`

- [ ] **Step 1: `AppModel`**

En la sección `// MARK: Responder`, agregar:

```swift
    /// Lo elegido para el análisis `draft` (ventana, chat o CLI): las `selections` de su coordinador.
    func respondSelections(for draft: RespondDraft) -> [String: RespondSelection] {
        respondChat(for: draft).selections
    }

    func updateRespondSelection(_ draft: RespondDraft, itemID: String, _ mutate: (inout RespondSelection) -> Void) {
        guard let item = draft.items.first(where: { $0.id == itemID }) else { return }
        let chat = respondChat(for: draft)
        var selection = chat.selections[itemID] ?? RespondSelection.defaults(for: item)
        mutate(&selection)
        chat.selections[itemID] = selection
    }

    /// "Reset to Claude’s Suggestions".
    func resetRespondSelections(_ draft: RespondDraft) {
        respondChat(for: draft).selections = Dictionary(uniqueKeysWithValues: draft.items.map {
            ($0.id, RespondSelection.defaults(for: $0))
        })
    }

    /// "Implement N Fixes" (ventana) o `prbar respond implement`.
    func implementRespond(prID: String) {
        guard let draft = respond.records[prID]?.draft else { return }
        respond.implement(prID: prID, selections: respondSelections(for: draft))
    }

    /// "Post N Replies" sin fixes (ventana) o `prbar respond reply-only`.
    func publishRespondReplies(prID: String) {
        guard let draft = respond.records[prID]?.draft else { return }
        respond.publishRepliesOnly(prID: prID, selections: respondSelections(for: draft))
    }

    /// "Push and Reply" / "Retry Pending Replies" con fixes (ventana) o `prbar respond push`.
    func pushRespond(prID: String) {
        respond.publish(prID: prID)
    }
```

En `openRespond(prID:)`, las opciones quedan sin `closeConfirmation`:

```swift
            options: WindowOptions(sharedFrameKey: "RespondWindowFrame"),
```

- [ ] **Step 2: `RespondWindow`**

En `Sources/PRBar/Respond/RespondWindow.swift`, con el código que dejó el plan 6:
- "Reset to Claude’s Suggestions": la acción pasa a `{ model.resetRespondSelections(draft) }`.
- "Implement N Fixes": `queue.implement(prID: prID, selections: chat.selections)` pasa a `model.implementRespond(prID: prID)`.
- Publicar solo respuestas: el closure de `ConfirmAlert.present` pasa a `{ model.publishRespondReplies(prID: prID) }` (borrar el `let selections = chat.selections` de antes, si quedó sin uso).
- En `confirmPublish(…)`, la acción de la confirmación pasa a `{ model.pushRespond(prID: prID) }`.

Las casillas y textos siguen escribiendo en `chat.selections` (es lo mismo que `AppModel.updateRespondSelection`). No agregar ni quitar controles.

- [ ] **Step 3: Compilar, tests y capturas**

Run: `swift build 2>&1 | grep error ; swift run PRBarTests`
Expected: sin errores; todo pasa.

Run: `swift run PRBar --snapshots /tmp/prbar-snap-t10 --appearance light`
Expected: `respond-choose-light.png` y `respond-ready-to-push-light.png` iguales a las del plan 6.

- [ ] **Step 4: Verificación manual**

Con la app instalada, en un PR propio con feedback: Respond, cambiar una casilla, cerrar la ventana (sin confirmación) y reabrirla: la casilla sigue. "Reset to Claude’s Suggestions" vuelve a lo de Claude. "Implement 1 Fix" sigue funcionando.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBar/AppModel.swift Sources/PRBar/Respond/RespondWindow.swift
git commit -m "Route respond choices, implement, replies and push through AppModel"
```

---

### Task 11: `AppModel` implementa estado, ventanas, historial, Review y Respond

Cada método hace lo mismo que el botón de la UI correspondiente (mismas guardas y mismos textos de error, más el comando sugerido). No hay tests unitarios de `AppModel` (el target de tests no ve la app): lo cubren el dispatcher (Task 7), la integración (Task 22) y la verificación manual de la Task 25.

**Files:**
- Create: `Sources/PRBar/AppModel+Commands.swift`
- Modify: `Sources/PRBar/AppModel.swift` (visibilidad), `Sources/PRBar/Settings/SettingsView.swift` (`SettingsWindow.select`)

- [ ] **Step 1: Visibilidad y pestaña de Settings**

En `AppModel.swift`, `localPath(for:)` y `repoConfig(account:repo:)` pasan de `private` a internos (sin modificador): los usa la extensión de otro archivo.

En `Sources/PRBar/Settings/SettingsView.swift`, dentro de `enum SettingsWindow`, agregar:

```swift
    /// La ventana de Settings abierta (para cambiar de pestaña desde la CLI).
    @MainActor private static weak var current: NSTabViewController?

    /// Elige `tab`: la recuerda para la próxima vez y, si la ventana está abierta, cambia a esa pestaña.
    @MainActor
    static func select(_ tab: Tab) {
        UserDefaults.standard.set(tab.rawValue, forKey: selectedTabKey)
        current?.selectedTabViewItemIndex = Tab.allCases.firstIndex(of: tab) ?? 0
    }
```

y en `makeController(model:tab:)`, justo antes de `tabs.onSelect = { … }` (o sea, solo en la app, no en el modo de capturas):

```swift
        current = tabs
```

- [ ] **Step 2: Crear `Sources/PRBar/AppModel+Commands.swift`**

```swift
import AppKit
import PRBarCore

// MARK: - Ayudas comunes de los comandos

// `appVersion` ya existe: lo definió el plan 8 en `AppModel+Updates.swift`.
extension AppModel {
    /// `owner/repo#N`, `repo#N` o la URL → id del PR entre los que conoce la app (snapshot, reviews y respuestas).
    func resolvePRID(_ text: String) throws -> String {
        guard let reference = PRReference.parse(text) else {
            throw CommandFailure(.invalidUsage, "“\(text)” isn’t a PR. Use owner/repo#N, repo#N or the PR’s URL.")
        }
        let known = (prStore.snapshot?.items.map(\.id) ?? []) + Array(reviews.phases.keys) + Array(respond.records.keys)
        switch reference.resolve(among: known) {
        case .success(let id):
            return id
        case .failure(.notFound):
            throw CommandFailure(.notFound, "\(text) isn’t in PRBar’s list. Run `prbar prs` to see the PRs.")
        case .failure(.ambiguous(let ids)):
            throw CommandFailure(.invalidUsage, "\(text) matches \(ids.joined(separator: ", ")). Use owner/repo#N.")
        }
    }

    func classifiedPR(_ prID: String) throws -> ClassifiedPR {
        guard let item = prStore.snapshot?.items.first(where: { $0.id == prID }) else {
            throw CommandFailure(.notFound, "\(prID) isn’t in the PR list anymore (merged or closed?). Run `prbar refresh`.")
        }
        return item
    }

    /// gh, git y claude: la ruta encontrada y si es una elegida a mano (Settings › General). También es
    /// `ConfigActions.toolsList` (Task 12).
    func toolsList() -> [ToolInfo] {
        ToolName.allCases.map { tool in
            let path = switch tool {
            case .gh: tools.gh
            case .git: tools.git
            case .claude: tools.claude
            }
            return ToolInfo(name: tool.rawValue, path: path, custom: configStore.config.toolPaths[keyPath: tool.keyPath] != nil)
        }
    }

    /// Espera (consultando cada 0,3 s) a que `isDone` sea verdad y avisa cada cambio de `describe`. Si la CLI se va
    /// (Ctrl-C), `Task.sleep` lanza `CancellationError` y la espera termina; el job sigue (o la CLI lo cancela aparte).
    func waitUntil(_ isDone: () -> Bool, describe: () -> String, events: CommandEventSink) async throws {
        var last = ""
        while !isDone() {
            let text = describe()
            if text != last {
                events(.progress(message: text))
                last = text
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

// MARK: - Estado, ventanas e historial

extension AppModel: StatusActions {
    func status() async throws -> StatusInfo {
        let snapshot = prStore.snapshot
        var counts: [String: Int] = [:]
        for category in PRCategory.allCases { counts[category.rawValue] = snapshot?.items(in: category).count ?? 0 }
        let reviewJobs = reviews.phases.filter { $0.value.isActive }
            .map { JobInfo(pr: $0.key, kind: "review", phase: $0.value.cliName) }
        let respondJobs = respond.phases.filter { $0.value.isActive || respond.runningTests.contains($0.key) }
            .map { JobInfo(pr: $0.key, kind: "respond", phase: respond.runningTests.contains($0.key) ? "testing" : $0.value.cliName) }
        return StatusInfo(
            appVersion: appVersion, refreshing: prStore.isRefreshing, fetchedAt: snapshot?.fetchedAt,
            offline: snapshot?.failedCompletely ?? false, rateLimitedUntil: snapshot?.rateLimitedUntil,
            badgeCount: snapshot?.badgeCount ?? 0, counts: counts,
            issues: snapshot?.issues.map(\.message) ?? [], slackIssues: slack.issues.map(\.message),
            jobs: (reviewJobs + respondJobs).sorted { $0.pr < $1.pr },
            accounts: configStore.config.accounts.filter(\.enabled).map(\.login), tools: toolsList()
        )
    }

    func listPRs(list: PRListFilter?, account: String?) throws -> [PRInfo] {
        guard let snapshot = prStore.snapshot else {
            throw CommandFailure(.invalidState, "PRBar hasn’t loaded the PRs yet. Try again in a few seconds.")
        }
        if let account, !configStore.config.accounts.contains(where: { $0.login.caseInsensitiveCompare(account) == .orderedSame }) {
            throw CommandFailure(.notFound, "There’s no account \(account). Run `prbar account list`.")
        }
        return snapshot.items
            .filter { item in list.map { item.category == $0.category } ?? true }
            .filter { item in account.map { item.account.caseInsensitiveCompare($0) == .orderedSame } ?? true }
            .map { PRInfo(item: $0, review: reviews.phases[$0.id], respond: respond.phases[$0.id]) }
    }

    func resolvePR(_ pr: String) throws -> PRLink {
        let id = try resolvePRID(pr)
        return PRLink(pr: id, url: try prURL(id))
    }

    private func prURL(_ prID: String) throws -> URL {
        if let url = prStore.snapshot?.items.first(where: { $0.id == prID })?.pr.url ?? PRReference.githubURL(prID: prID) {
            return url
        }
        throw CommandFailure(.notFound, "No URL for \(prID).")
    }

    func historyList(repo: String?, kind: HistoryKind?, limit: Int?, search: String?) -> [HistoryEntryInfo] {
        var entries: [HistoryEntryInfo] = []
        if kind != .respond { entries += history.all().map(HistoryEntryInfo.init(review:)) }
        if kind != .review { entries += respondHistory.all().map(HistoryEntryInfo.init(respond:)) }
        let filtered = entries
            .filter { entry in repo.map { entry.repo.caseInsensitiveCompare($0) == .orderedSame } ?? true }
            .filter { $0.matches(search ?? "") }
            .sorted { $0.startedAt > $1.startedAt }
        return Array(filtered.prefix(max(limit ?? 50, 1)))
    }

    private enum HistoryHit {
        case review(ReviewRecord)
        case respond(RespondRecord)
    }

    /// Un registro por su id completo o por un prefijo único (de al menos 4 caracteres).
    private func historyRecord(_ text: String) throws -> HistoryHit {
        let needle = text.lowercased()
        let reviewHits = history.all().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        let respondHits = respondHistory.all().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        let total = reviewHits.count + respondHits.count
        guard needle.count >= 4, total > 0 else {
            throw CommandFailure(.notFound, "There’s no history record \(text). Run `prbar history`.")
        }
        guard total == 1 else {
            throw CommandFailure(.invalidUsage, "\(text) matches \(total) records: use more characters of the id.")
        }
        if let record = reviewHits.first { return .review(record) }
        return .respond(respondHits[0])
    }

    private func canReopen(_ record: ReviewRecord) -> Bool {
        ReviewHistory.canReopen(
            record, among: history.all(),
            currentHeadOid: prStore.snapshot?.items.first(where: { $0.id == record.draft.prID })?.pr.headOid,
            reviewActive: reviews.phases[record.draft.prID]?.isActive == true
        )
    }

    private func existingPath(_ url: URL) -> String? {
        FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    func historyShow(id: String) throws -> HistoryDetail {
        switch try historyRecord(id) {
        case .review(let record):
            return HistoryDetail(review: record, logPath: existingPath(history.logURL(for: record.id)),
                                 canReopen: canReopen(record))
        case .respond(let record):
            return HistoryDetail(respond: record, logPath: existingPath(respondHistory.logURL(for: record.id)),
                                 canOpen: respond.records[record.draft.prID]?.id == record.id)
        }
    }

    /// "Open to Post": vuelve a dejar listo un review del historial y abre su ventana.
    func historyReopen(id: String) throws {
        guard case .review(let record) = try historyRecord(id) else {
            throw CommandFailure(.invalidUsage, "Only reviews can be reopened. For a response use `prbar open <pr> --respond`.")
        }
        guard canReopen(record) else {
            throw CommandFailure(.invalidState, "This review can’t be posted anymore: the PR changed, it was already posted, or a review is running.")
        }
        reopenFromHistory(record.draft)
    }

    func refresh() async {
        await prStore.refresh()
    }

    func open(pr: String, target: OpenTarget) throws -> PRLink {
        let id = try resolvePRID(pr)
        switch target {
        case .browser:
            NSWorkspace.shared.open(try prURL(id))
        case .review:
            switch reviews.phases[id] {
            case .ready?, .published?: openReview(prID: id)
            default: throw CommandFailure(.invalidState, "There’s no finished review of \(id). Run `prbar review \(id)`.")
            }
        case .respond:
            guard respond.records[id] != nil else {
                throw CommandFailure(.invalidState, "There’s no analysis of \(id)’s feedback. Run `prbar respond \(id)`.")
            }
            openRespond(prID: id)
        case .posted:
            guard let url = postedReviewURL(id) else {
                throw CommandFailure(.notFound, "There’s no posted review of \(id).")
            }
            NSWorkspace.shared.open(url)
            return PRLink(pr: id, url: url)
        case .worktree:
            guard let record = respond.records[id] else {
                throw CommandFailure(.invalidState, "There’s no analysis of \(id)’s feedback, so there’s no worktree.")
            }
            let folder = URL(fileURLWithPath: record.draft.worktree.path, isDirectory: true)
            NSWorkspace.shared.open(folder)
            return PRLink(pr: id, url: folder)
        }
        return PRLink(pr: id, url: try prURL(id))
    }

    private func postedReviewURL(_ prID: String) -> URL? {
        if case .published(let url)? = reviews.phases[prID] { return url }
        return history.all()
            .filter { $0.draft.prID == prID && $0.status == .published }
            .max { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }?
            .reviewURL
    }

    func openSettings(tab: SettingsTabName?) {
        if let tab, let settingsTab = SettingsWindow.Tab(rawValue: tab.rawValue) { SettingsWindow.select(settingsTab) }
        openSettings()
    }

    func openHistory(id: String?) throws {
        guard let id else {
            openHistory()
            return
        }
        switch try historyRecord(id) {
        case .review(let record): openHistory(selecting: record.id)
        case .respond(let record): openHistory(selecting: record.id)
        }
    }

    /// Contesta antes de salir.
    func quit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}

// MARK: - Review

extension AppModel: ReviewActions {
    func readyReviewDraft(_ prID: String) throws -> ReviewDraft {
        guard case .ready(let draft)? = reviews.phases[prID] else {
            throw CommandFailure(.invalidState, "There’s no review ready to post for \(prID). Run `prbar review \(prID)` first.")
        }
        return draft
    }

    func reviewInfo(_ prID: String) -> ReviewInfo {
        let phase = reviews.phases[prID]
        guard case .ready(let draft)? = phase else { return ReviewInfo(prID: prID, phase: phase) }
        return ReviewInfo(prID: prID, phase: phase, edits: reviewChat(for: draft).reviewEdits, outdated: isOutdated(draft))
    }

    private func reviewProgress(_ prID: String) -> String {
        switch reviews.phases[prID] {
        case .queued?: "Queued"
        case .preparing?: "Preparing the worktree…"
        case .reviewing(let agents)?: agents > 0 ? "Reviewing (\(agents) agent\(agents == 1 ? "" : "s"))…" : "Reviewing…"
        case .filtering?: "Filtering the findings…"
        default: "Finishing…"
        }
    }

    private func reviewItem(_ reference: String, in draft: ReviewDraft) throws -> ReviewItem {
        guard let item = reviewChat(for: draft).reviewEdits.item(reference, in: draft) else {
            throw CommandFailure(.notFound, "There’s no finding \(reference) in this review. Run `prbar review show \(draft.prID)`.")
        }
        return item
    }

    func reviewStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> ReviewInfo {
        let item = try classifiedPR(try resolvePRID(pr))
        switch item.category {
        case .toReview, .updatedSinceMyReview: break
        case .myFeedback: throw CommandFailure(.invalidState, "\(item.id) is your PR: use `prbar respond \(item.id)`.")
        case .other: throw CommandFailure(.invalidState, "PRBar reviews PRs in “To Review” and “Updated Since My Review”; \(item.id) isn’t in either.")
        }
        if reviews.phases[item.id]?.isActive == true {
            throw CommandFailure(.invalidState, "\(item.id) is already being reviewed.")
        }
        startReview(item)
        guard wait else { return reviewInfo(item.id) }
        try await waitUntil({ reviews.phases[item.id]?.isActive != true },
                            describe: { reviewProgress(item.id) }, events: events)
        if case .failed(let message, _)? = reviews.phases[item.id] { throw CommandFailure(.failed, message) }
        return reviewInfo(item.id)
    }

    func reviewShow(pr: String) throws -> ReviewInfo {
        reviewInfo(try resolvePRID(pr))
    }

    func reviewEdit(pr: String, finding: String, title: String?, body: String?) throws -> ReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        let item = try reviewItem(finding, in: draft)
        guard title != nil || body != nil else {
            throw CommandFailure(.invalidUsage, "Nothing to change: pass --title, --body, --body-file or --editor.")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CommandFailure(.invalidUsage, "The title can’t be empty.")
        }
        let chat = reviewChat(for: draft)
        if let title { chat.reviewEdits.setTitle(title, for: item.id, in: draft) }
        if let body { chat.reviewEdits.setBody(body, for: item.id, in: draft) }
        return reviewInfo(id)
    }

    func reviewSetIncluded(pr: String, findings: [String], all: Bool, included: Bool) throws -> ReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        if all {
            let chat = reviewChat(for: draft)
            if included { chat.reviewEdits.selectAllKept(in: draft) } else { chat.reviewEdits.selected.removeAll() }
            return reviewInfo(id)
        }
        guard !findings.isEmpty else { throw CommandFailure(.invalidUsage, "Name the findings (numbers or ids) or pass --all.") }
        let items = try findings.map { try reviewItem($0, in: draft) }
        let chat = reviewChat(for: draft)
        for item in items {
            if included { chat.reviewEdits.selected.insert(item.id) } else { chat.reviewEdits.selected.remove(item.id) }
        }
        return reviewInfo(id)
    }

    func reviewSetComment(pr: String, text: String) throws -> ReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        reviewChat(for: draft).reviewEdits.generalComment = text
        return reviewInfo(id)
    }

    func reviewPublish(pr: String, event: ReviewEvent, only: [String]?, withComments: Bool,
                       allInBody: Bool) async throws -> PublishedReviewInfo {
        let id = try resolvePRID(pr)
        let draft = try readyReviewDraft(id)
        let onlyIDs = try only.map { references in Set(try references.map { try reviewItem($0, in: draft).id }) }
        if event != .approve {
            // Comentar y Pedir cambios sin nada que publicar no se puede (como en la ventana).
            let edits = reviewChat(for: draft).reviewEdits
            let comments = withComments ? edits.comments(of: draft, only: onlyIDs) : []
            let general = withComments ? edits.generalComment.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !comments.isEmpty || !general.isEmpty else {
                throw CommandFailure(.invalidState, "Nothing to post: include findings (`prbar review include`) or write a general comment (`prbar review comment`).")
            }
        }
        do {
            let result = try await publishReview(draft: draft, event: event, only: onlyIDs, withComments: withComments,
                                                 allInBody: allInBody)
            return PublishedReviewInfo(pr: id, url: result.url, action: result.action.rawValue,
                                       comments: result.commentCount, publishedAt: result.publishedAt)
        } catch let error as InlineCommentsRejected {
            throw CommandFailure(.failed, "\(error.localizedDescription) Run it again with --all-in-body.")
        }
    }

    func reviewCancel(pr: String) throws {
        let id = try resolvePRID(pr)
        guard reviews.phases[id]?.isActive == true else {
            throw CommandFailure(.invalidState, "There’s no review of \(id) running.")
        }
        cancelReview(prID: id)
    }

    func reviewDismiss(pr: String) throws {
        let id = try resolvePRID(pr)
        guard let phase = reviews.phases[id] else { throw CommandFailure(.invalidState, "There’s no review of \(id) to dismiss.") }
        guard !phase.isActive else { throw CommandFailure(.invalidState, "The review is running: cancel it with `prbar review cancel \(id)`.") }
        dismissReview(prID: id)
    }
}

// MARK: - Respond

extension AppModel: RespondActions {
    func respondRecord(_ prID: String) throws -> RespondRecord {
        guard let record = respond.records[prID] else {
            throw CommandFailure(.invalidState, "There’s no analysis of \(prID)’s feedback. Run `prbar respond \(prID)` first.")
        }
        return record
    }

    func respondInfo(_ prID: String) -> RespondInfo {
        let record = respond.records[prID]
        var logPath: String?
        if case .failed(_, let log)? = respond.phases[prID] { logPath = log?.path }
        if logPath == nil, let record { logPath = existingPath(respondHistory.logURL(for: record.id)) }
        return RespondInfo(prID: prID, phase: respond.phases[prID], record: record,
                           selections: record.map { respondSelections(for: $0.draft) } ?? [:],
                           runningTests: respond.runningTests.contains(prID),
                           testCommand: record.flatMap { testCommand(for: $0.draft) }, logPath: logPath)
    }

    private func respondProgress(_ prID: String) -> String {
        if respond.runningTests.contains(prID) { return "Running tests…" }
        return switch respond.phases[prID] {
        case .queued?: "Queued…"
        case .preparing?: "Preparing the worktree…"
        case .analyzing?: "Claude is analyzing the comments…"
        case .implementing(let done, let total)?: "Implementing \(min(done + 1, max(total, 1))) of \(max(total, 1))…"
        case .pushing?: "Pushing and posting the replies…"
        default: "Finishing…"
        }
    }

    private func throwIfRespondFailed(_ prID: String) throws {
        if case .failed(let message, _)? = respond.phases[prID] { throw CommandFailure(.failed, message) }
    }

    private func waitForRespond(_ prID: String, events: CommandEventSink) async throws {
        try await waitUntil({ respond.phases[prID]?.isActive != true && !respond.runningTests.contains(prID) },
                            describe: { respondProgress(prID) }, events: events)
        try throwIfRespondFailed(prID)
    }

    /// El análisis listo de este PR, para elegir (también después de un fallo sin fixes, como en la ventana).
    private func choosableDraft(_ prID: String) throws -> RespondDraft {
        let record = try respondRecord(prID)
        switch respond.phases[prID] {
        case .ready(let draft)? where draft.id == record.draft.id:
            return draft
        case .failed? where record.result == nil:
            return record.draft
        default:
            throw CommandFailure(.invalidState, "\(prID) isn’t waiting for your choices (\(respond.phases[prID]?.cliName ?? "none")).")
        }
    }

    private func respondItemID(_ reference: String, in draft: RespondDraft) throws -> String {
        guard let id = RespondItemReference.itemID(reference, in: draft) else {
            throw CommandFailure(.notFound, "There’s no comment \(reference) in this analysis. Run `prbar respond show \(draft.prID)`.")
        }
        return id
    }

    func respondStart(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let item = try classifiedPR(try resolvePRID(pr))
        guard item.category == .myFeedback else {
            throw CommandFailure(.invalidState, "\(item.id) isn’t one of your PRs with feedback.")
        }
        if let reason = respondUnavailableReason(item) {
            throw CommandFailure(.invalidState, "\(reason) Or run `prbar repo set \(item.pr.repo.fullName) --path …`.")
        }
        let phase = respond.phases[item.id]
        if phase?.isActive == true || respond.runningTests.contains(item.id) {
            throw CommandFailure(.invalidState, "\(item.id) is already being worked on: wait or cancel it (`prbar respond cancel \(item.id)`).")
        }
        if case .readyToPush? = phase {
            throw CommandFailure(.invalidState, "\(item.id) has fixes that weren’t pushed: push them (`prbar respond push \(item.id)`) or dismiss them first.")
        }
        if case .failed? = phase, respond.records[item.id]?.result != nil {
            throw CommandFailure(.invalidState, "\(item.id) already has fixes: retry with `prbar respond push \(item.id)`.")
        }
        startRespond(item)
        guard wait else { return respondInfo(item.id) }
        try await waitForRespond(item.id, events: events)
        return respondInfo(item.id)
    }

    func respondShow(pr: String) throws -> RespondInfo {
        respondInfo(try resolvePRID(pr))
    }

    func respondSelect(pr: String, items: [String], change: RespondSelectionChange) throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let draft = try choosableDraft(id)
        guard !change.isEmpty else {
            throw CommandFailure(.invalidUsage, "Nothing to change: pass --implement, --reply-only, --skip, --no-reply, --reply or --plan.")
        }
        guard !items.isEmpty else { throw CommandFailure(.invalidUsage, "Name at least one comment (its number or id).") }
        let ids = try items.map { try respondItemID($0, in: draft) }
        for itemID in ids {
            updateRespondSelection(draft, itemID: itemID) { change.apply(to: &$0) }
        }
        return respondInfo(id)
    }

    func respondReset(pr: String) throws -> RespondInfo {
        let id = try resolvePRID(pr)
        resetRespondSelections(try choosableDraft(id))
        return respondInfo(id)
    }

    func respondImplement(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let record = try respondRecord(id)
        guard case .ready(let draft)? = respond.phases[id], draft.id == record.draft.id else {
            throw CommandFailure(.invalidState, "\(id) isn’t ready to implement fixes (\(respond.phases[id]?.cliName ?? "none")).")
        }
        guard RespondCounts.fixes(draft, respondSelections(for: draft)) > 0 else {
            throw CommandFailure(.invalidState, "No fixes selected. Use `prbar respond select \(id) <n> --implement`, or post only the replies with `prbar respond reply-only \(id)`.")
        }
        implementRespond(prID: id)
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func respondTest(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        guard case .readyToPush(let draft, _)? = respond.phases[id] else {
            throw CommandFailure(.invalidState, "Tests run after the fixes are implemented (`prbar respond implement \(id)`).")
        }
        guard testCommand(for: draft) != nil else {
            throw CommandFailure(.invalidState, "There’s no test command for \(draft.repo.fullName). Set it with `prbar repo set \(draft.repo.fullName) --test-command …`.")
        }
        guard !respond.runningTests.contains(id) else { throw CommandFailure(.invalidState, "The tests are already running.") }
        runRespondTests(prID: id)
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func respondDiff(pr: String) throws -> RespondDiff {
        let id = try resolvePRID(pr)
        guard let result = try respondRecord(id).result else {
            throw CommandFailure(.invalidState, "\(id) has no implemented fixes yet.")
        }
        return RespondDiff(pr: id, diffStat: result.diffStat, diff: result.diff, truncated: result.diffTruncated ?? false,
                           sensitiveChanges: result.sensitiveChanges)
    }

    func respondPush(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let record = try respondRecord(id)
        guard record.result != nil else {
            throw CommandFailure(.invalidState, "Nothing to push: \(id) has no implemented fixes. To post only replies use `prbar respond reply-only \(id)`.")
        }
        switch respond.phases[id] {
        case .readyToPush?, .failed?: break
        default: throw CommandFailure(.invalidState, "\(id) can’t be pushed now (\(respond.phases[id]?.cliName ?? "none")).")
        }
        guard !respond.runningTests.contains(id) else { throw CommandFailure(.invalidState, "Wait for the tests to finish.") }
        if record.pushed && RespondCounts.pendingReplies(record) == 0 {
            throw CommandFailure(.invalidState, "Everything was already pushed and posted.")
        }
        pushRespond(prID: id)
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func respondReplyOnly(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo {
        let id = try resolvePRID(pr)
        let record = try respondRecord(id)
        guard record.result == nil else {
            throw CommandFailure(.invalidState, "\(id) has implemented fixes: use `prbar respond push \(id)` (it pushes and posts the replies).")
        }
        switch respond.phases[id] {
        case .ready?, .failed?: break
        default: throw CommandFailure(.invalidState, "\(id) can’t post replies now (\(respond.phases[id]?.cliName ?? "none")).")
        }
        guard RespondCounts.plannedReplies(record.draft, respondSelections(for: record.draft)) > 0 else {
            throw CommandFailure(.invalidState, "No replies to post. Use `prbar respond select \(id) <n> --reply …`.")
        }
        publishRespondReplies(prID: id)
        guard wait else { return respondInfo(id) }
        try await waitForRespond(id, events: events)
        return respondInfo(id)
    }

    func respondCancel(pr: String) throws {
        let id = try resolvePRID(pr)
        if case .pushing? = respond.phases[id] {
            throw CommandFailure(.invalidState, "Pushing and posting can’t be canceled.")
        }
        guard respond.phases[id]?.isActive == true || respond.runningTests.contains(id) else {
            throw CommandFailure(.invalidState, "There’s nothing running for \(id).")
        }
        cancelRespond(prID: id)
    }

    func respondDismiss(pr: String) throws {
        let id = try resolvePRID(pr)
        guard respond.phases[id] != nil || respond.records[id] != nil else {
            throw CommandFailure(.invalidState, "There’s nothing to dismiss for \(id).")
        }
        guard respond.phases[id]?.isActive != true, !respond.runningTests.contains(id) else {
            throw CommandFailure(.invalidState, "It’s running: cancel it first (`prbar respond cancel \(id)`).")
        }
        dismissRespond(prID: id)
    }
}
```

- [ ] **Step 3: Compilar y correr**

Run: `swift build 2>&1 | grep error ; swift run PRBarTests`
Expected: sin errores (con `StatusActions`, `ReviewActions` y `RespondActions` conformados; `ConfigActions`/`SlackActions` todavía no se exigen) y todo pasa.

- [ ] **Step 4: Commit**

```bash
git add Sources/PRBar/AppModel.swift Sources/PRBar/AppModel+Commands.swift Sources/PRBar/Settings/SettingsView.swift
git commit -m "Implement status, history, window, review and respond actions in AppModel"
```

---

### Task 12: `AppModel` implementa configuración y Slack

**Files:**
- Modify: `Sources/PRBarCore/Config.swift` (`setBaseBranches`), `Sources/PRBarTests/ConfigTests.swift`
- Create: `Sources/PRBar/AppModel+Settings.swift`

- [ ] **Step 1: Test del mutador nuevo**

Agregar a `ConfigTests.cases`:

```swift
        TestCase("config: setBaseBranches reemplaza la lista sin duplicados") {
            var config = AppConfig()
            config.setAccountEnabled("me", true)
            config.addRepo(RepoRef(owner: "o", name: "r"), to: "me")
            config.setBaseBranches(["main", "develop", "main", " "], repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].baseBranches, ["main", "develop"])
            config.setBaseBranches([], repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].baseBranches, [])
        },
```

Run: `swift run PRBarTests setBaseBranches`
Expected: no compila.

- [ ] **Step 2: Implementar el mutador**

En `Sources/PRBarCore/Config.swift`, junto a `toggleBaseBranch`:

```swift
    /// `prbar repo set --branches/--add-branch/--remove-branch`: la lista final (sin vacíos ni repetidos; vacía = la
    /// rama por defecto del repo).
    public mutating func setBaseBranches(_ branches: [String], repoID: String, login: String) {
        var unique: [String] = []
        for branch in branches.map({ $0.trimmingCharacters(in: .whitespaces) }) where !branch.isEmpty && !unique.contains(branch) {
            unique.append(branch)
        }
        withRepo(repoID, login: login) { $0.baseBranches = unique }
    }
```

Run: `swift run PRBarTests setBaseBranches`
Expected: `1/1 passed`.

- [ ] **Step 3: Crear `Sources/PRBar/AppModel+Settings.swift`**

```swift
import AppKit
import PRBarCore

// MARK: - Ayudas

extension AppModel {
    /// Guarda un cambio de configuración como lo hace Settings; si no se pudo guardar, error para la CLI (la UI lo
    /// muestra en el banner de Settings). `slack: true` vuelve a planificar Slack (como la pestaña Slack).
    func applyConfig(refresh: Bool = false, slack: Bool = false, _ mutate: (inout AppConfig) -> Void) throws {
        if slack {
            updateSlackConfig(mutate)
        } else {
            updateConfig(refresh: refresh, mutate)
        }
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    /// La cuenta de un comando: la pedida (tiene que estar encendida), la que tiene configurado `repo`, o la única
    /// encendida.
    func commandAccount(_ login: String?, repo: String? = nil) throws -> String {
        let enabled = configStore.config.accounts.filter(\.enabled)
        if let login {
            guard let account = enabled.first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }) else {
                throw CommandFailure(.notFound, "There’s no enabled account \(login). Run `prbar account list`.")
            }
            return account.login
        }
        if let repo {
            let owners = enabled.filter { $0.repos.contains { $0.id.caseInsensitiveCompare(repo) == .orderedSame } }
            if owners.count == 1 { return owners[0].login }
            if owners.count > 1 {
                throw CommandFailure(.invalidUsage, "\(repo) is configured in \(owners.map(\.login).joined(separator: " and ")): use --account.")
            }
        }
        guard enabled.count == 1 else {
            if enabled.isEmpty {
                throw CommandFailure(.invalidState, "No account is enabled. Run `prbar account enable <login>`.")
            }
            throw CommandFailure(.invalidUsage, "Several accounts are enabled (\(enabled.map(\.login).joined(separator: ", "))): use --account.")
        }
        return enabled[0].login
    }

    func configuredRepo(_ repo: String, account: String?) throws -> (login: String, repo: RepoConfig) {
        _ = try Self.parseRepo(repo)
        let login = try commandAccount(account, repo: repo)
        guard let config = configStore.config.accounts.first(where: { $0.login == login })?
            .repos.first(where: { $0.id.caseInsensitiveCompare(repo) == .orderedSame }) else {
            throw CommandFailure(.notFound, "\(repo) isn’t configured for @\(login). Run `prbar repo add \(repo)`.")
        }
        return (login, config)
    }

    static func parseRepo(_ text: String) throws -> RepoRef {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(PRReference.isValidName) else {
            throw CommandFailure(.invalidUsage, "“\(text)” isn’t a repo: use owner/repo.")
        }
        return RepoRef(owner: parts[0], name: parts[1])
    }

    /// `~` y rutas relativas (la CLI ya manda rutas absolutas; esto es por si otro cliente no).
    static func expandPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    private func repoInfo(login: String, repoID: String) throws -> RepoInfo {
        guard let config = configStore.config.accounts.first(where: { $0.login == login })?.repos.first(where: { $0.id == repoID }) else {
            throw CommandFailure(.notFound, "\(repoID) isn’t configured for @\(login).")
        }
        return RepoInfo(config: config, account: login)
    }

    /// Un canal de Slack por id o por nombre (`#nombre` o `nombre`), como el selector de la pestaña Repos.
    private func slackChannel(_ text: String) async throws -> SlackChannel {
        guard configStore.config.slack.enabled, slack.isConnected else {
            throw CommandFailure(.invalidState, "Turn on Slack and connect it first (`prbar slack enable`, `prbar slack check`).")
        }
        let channels = try await slack.channels(reload: false).channels
        let name = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if let channel = channels.first(where: { $0.id == text }) ?? channels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return channel
        }
        throw CommandFailure(.notFound, "There’s no channel \(text). Run `prbar slack channels`.")
    }
}

// MARK: - Configuración

extension AppModel: ConfigActions {
    func configShow() -> AppConfig {
        configStore.config
    }

    func configSetRefreshInterval(minutes: Int) throws {
        // Los mismos valores que ofrece Settings › General.
        guard [1, 2, 5, 10].contains(minutes) else {
            throw CommandFailure(.invalidUsage, "The refresh interval is 1, 2, 5 or 10 minutes.")
        }
        try applyConfig { $0.refreshIntervalMinutes = minutes }
    }

    func configSetLaunchAtLogin(enabled: Bool) throws {
        setLaunchAtLogin(enabled)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    func accountList() -> [AccountInfo] {
        let configured = configStore.config.accounts
        var infos = ghAccounts.map { account in
            AccountInfo(login: account.login,
                        enabled: configured.first { $0.login == account.login }?.enabled ?? false,
                        inGh: true, active: account.isActive)
        }
        for account in configured where !ghAccounts.contains(where: { $0.login == account.login }) {
            infos.append(AccountInfo(login: account.login, enabled: account.enabled, inGh: false, active: false))
        }
        return infos
    }

    func accountSetEnabled(login: String, enabled: Bool) throws {
        guard let account = ghAccounts.first(where: { $0.login.caseInsensitiveCompare(login) == .orderedSame }) else {
            throw CommandFailure(.notFound, "\(login) isn’t signed in to gh. Run `gh auth login --hostname github.com`, then `prbar account reload`.")
        }
        try applyConfig(refresh: true) { $0.setAccountEnabled(account.login, enabled) }
    }

    func accountReload() async throws -> [AccountInfo] {
        await reloadAccounts()
        if let accountsError { throw CommandFailure(.failed, accountsError) }
        return accountList()
    }

    func repoList(account: String?) throws -> [RepoInfo] {
        let logins = try account.map { [try commandAccount($0)] } ?? configStore.config.accounts.filter(\.enabled).map(\.login)
        return configStore.config.accounts
            .filter { logins.contains($0.login) }
            .flatMap { account in account.repos.map { RepoInfo(config: $0, account: account.login) } }
    }

    func repoAvailable(account: String?, reload: Bool) async throws -> [String] {
        let login = try commandAccount(account)
        await catalog.loadRepos(for: login, force: reload)
        let entry = catalog.repos(for: login)
        if case .failed(let message) = entry.state { throw CommandFailure(.failed, message) }
        return entry.value.map(\.fullName).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func repoAdd(repo: String, account: String?) async throws -> RepoInfo {
        _ = try Self.parseRepo(repo)
        let login = try commandAccount(account)
        if configStore.config.accounts.first(where: { $0.login == login })?.repos
            .contains(where: { $0.id.caseInsensitiveCompare(repo) == .orderedSame }) == true {
            throw CommandFailure(.invalidState, "\(repo) is already configured for @\(login).")
        }
        // Como "Add Repo…": solo repos que la cuenta ve en GitHub, con el nombre exacto.
        let available = try await repoAvailable(account: login, reload: false)
        guard let fullName = available.first(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) else {
            throw CommandFailure(.notFound, "@\(login) can’t see \(repo) on GitHub. Run `prbar repo available` to list them.")
        }
        let ref = try Self.parseRepo(fullName)
        try applyConfig(refresh: true) { $0.addRepo(ref, to: login) }
        return try repoInfo(login: login, repoID: ref.fullName)
    }

    func repoRemove(repo: String, account: String?) throws {
        let (login, config) = try configuredRepo(repo, account: account)
        try applyConfig(refresh: true) { $0.removeRepo(config.id, from: login) }
    }

    func repoSet(repo: String, account: String?, changes: RepoChanges) async throws -> RepoInfo {
        let (login, current) = try configuredRepo(repo, account: account)
        guard !changes.isEmpty else { throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar repo set --help`.") }
        // Primero se valida todo; si algo falla no se guarda nada.
        var localPath: String??
        if let change = changes.localPath {
            switch change {
            case .clear:
                localPath = .some(nil)
            case .set(let raw):
                let path = Self.expandPath(raw)
                if let error = await validateRepoPath(path, repo: current.repo) { throw CommandFailure(.invalidUsage, error) }
                localPath = .some(path)
            }
        }
        var channel: SlackChannel??
        if let change = changes.channel {
            switch change {
            case .clear: channel = .some(nil)
            case .set(let raw): channel = .some(try await slackChannel(raw))
            }
        }
        var branches = changes.baseBranches ?? current.baseBranches
        for branch in changes.addBranches where !branches.contains(branch) { branches.append(branch) }
        branches.removeAll { changes.removeBranches.contains($0) }

        try applyConfig(refresh: changes.changesBranches || localPath != nil) { config in
            if let localPath { config.setLocalPath(localPath, repoID: current.id, login: login) }
            if let change = changes.worktreeDir {
                config.setWorktreeDir(change.value.map(Self.expandPath), repoID: current.id, login: login)
            }
            if let change = changes.testCommand { config.setTestCommand(change.value, repoID: current.id, login: login) }
            if changes.changesBranches { config.setBaseBranches(branches, repoID: current.id, login: login) }
            if let channel {
                config.setSlackChannel(id: channel?.id, name: channel?.name, repoID: current.id, login: login)
            }
        }
        if channel != nil { reprocessSlack() }
        return try repoInfo(login: login, repoID: current.id)
    }

    func repoBranches(repo: String, account: String?, reload: Bool) async throws -> BranchesInfo {
        let (login, config) = try configuredRepo(repo, account: account)
        await catalog.loadBranches(for: login, repo: config.repo, force: reload)
        let entry = catalog.branches(for: login, repo: config.repo)
        if case .failed(let message) = entry.state { throw CommandFailure(.failed, message) }
        return BranchesInfo(repo: config.id, defaultBranch: entry.value.defaultBranch, branches: entry.value.names,
                            selected: config.baseBranches)
    }

    func followList(repo: String?, account: String?) throws -> [FollowInfo] {
        if let repo {
            let (login, config) = try configuredRepo(repo, account: account)
            return [FollowInfo(repo: config.id, account: login, users: config.watchedUsers)]
        }
        return try repoList(account: account).map { FollowInfo(repo: $0.id, account: $0.account, users: $0.watchedUsers) }
    }

    func followAdd(repo: String, users: [String], account: String?) async throws -> FollowInfo {
        let (login, config) = try configuredRepo(repo, account: account)
        guard !users.isEmpty else { throw CommandFailure(.invalidUsage, "Name at least one GitHub user.") }
        // Como el campo "Add User…": cada login se valida contra GitHub y se guarda con su nombre exacto.
        let token = try await accounts.token(for: login)
        var logins: [String] = []
        for raw in users {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard let user = try await api.user(login: name, token: token) else {
                throw CommandFailure(.notFound, "There’s no GitHub user named \(name).")
            }
            logins.append(user.login)
        }
        try applyConfig(refresh: true) { appConfig in
            for user in logins { appConfig.addWatchedUser(user, repoID: config.id, login: login) }
        }
        return try followList(repo: config.id, account: login)[0]
    }

    func followRemove(repo: String, users: [String], account: String?) throws -> FollowInfo {
        let (login, config) = try configuredRepo(repo, account: account)
        let names = users.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }
        if let unknown = names.first(where: { name in !config.watchedUsers.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }) {
            throw CommandFailure(.notFound, "\(unknown) isn’t followed in \(config.id). Run `prbar follow list \(config.id)`.")
        }
        try applyConfig(refresh: true) { appConfig in
            for user in names { appConfig.removeWatchedUser(user, repoID: config.id, login: login) }
        }
        return try followList(repo: config.id, account: login)[0]
    }

    func followSuggestions(repo: String, account: String?) async throws -> [UserSuggestionInfo] {
        let (login, config) = try configuredRepo(repo, account: account)
        await catalog.loadAssignableUsers(for: login, repo: config.repo)
        let entry = catalog.assignableUsers(for: login, repo: config.repo)
        if case .failed(let message) = entry.state { throw CommandFailure(.failed, message) }
        let prs = prStore.snapshot?.items.map(\.pr).filter { $0.repo == config.repo } ?? []
        return UserSuggestion.build(assignable: entry.value, snapshotPRs: prs, me: login, watched: config.watchedUsers)
            .map { UserSuggestionInfo(login: $0.user.login, name: $0.user.name, openPRs: $0.openPRs) }
    }

    func notifyList() async -> NotificationsInfo {
        await refreshNotificationPermission()
        return NotificationsInfo(settings: configStore.config.notifications, deniedInMacOS: notificationsDenied)
    }

    func notifySet(kind: NotificationSettingName, enabled: Bool) throws {
        try applyConfig { $0.notifications[keyPath: kind.keyPath] = enabled }
    }

    func notifySetEnabled(enabled: Bool) throws {
        try applyConfig { $0.notifications.enabled = enabled }
    }

    func claudeShow() -> ClaudeSettings {
        configStore.config.claude
    }

    func claudeSet(changes: ClaudeChanges) throws -> ClaudeSettings {
        guard !changes.isEmpty else { throw CommandFailure(.invalidUsage, "Nothing to change. See `prbar claude set --help`.") }
        for skill in [changes.reviewSkill, changes.filterSkill, changes.respondSkill].compactMap({ $0 })
        where !ClaudeSettings.isValidSkill(skill) {
            throw CommandFailure(.invalidUsage, "“\(skill)” isn’t a valid skill: use plugin:skill or skill. See `prbar claude skills`.")
        }
        var model: ClaudeModel??
        if let change = changes.model {
            switch change {
            case .clear:
                model = .some(nil)
            case .set(let name):
                guard let parsed = ClaudeModel(rawValue: name.lowercased()) else {
                    throw CommandFailure(.invalidUsage, "Unknown model \(name): use opus, sonnet, haiku or default.")
                }
                model = .some(parsed)
            }
        }
        try applyConfig { config in
            if let skill = changes.reviewSkill { config.claude.reviewSkill = skill }
            if let on = changes.filterEnabled { config.claude.filterEnabled = on }
            if let skill = changes.filterSkill { config.claude.filterSkill = skill }
            if let skill = changes.respondSkill { config.claude.respondSkill = skill }
            if let model { config.claude.model = model }
        }
        return configStore.config.claude
    }

    func claudeReset() throws -> ClaudeSettings {
        try applyConfig { $0.claude = ClaudeSettings() }
        return configStore.config.claude
    }

    func claudeSkillList() async -> [SkillInfo] {
        await claudeSkills.refresh(claudePath: tools.claude, toolsResolved: toolsResolved, settings: configStore.config.claude)
        return claudeSkills.entries.map(SkillInfo.init(entry:))
    }

    func toolsSet(tool: ToolName, path: String?) async throws -> [ToolInfo] {
        await setToolPath(path.map(Self.expandPath) ?? "", for: tool.keyPath)
        let list = toolsList()
        if path != nil, list.first(where: { $0.name == tool.rawValue })?.path == nil {
            throw CommandFailure(.failed, "\(tool.rawValue) not found at this path. `prbar tools reset \(tool.rawValue)` goes back to the automatic one.")
        }
        return list
    }
}

// MARK: - Slack

extension AppModel: SlackActions {
    func slackShow() -> SlackInfo {
        SlackInfo(settings: configStore.config.slack, connected: slack.isConnected, hasToken: slack.hasToken,
                  needsUserToken: slack.needsUserToken, issues: slack.issues.map(\.message))
    }

    func slackSetEnabled(enabled: Bool) throws {
        setSlackEnabled(enabled)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    func slackSetProvider(provider: SlackProvider) throws {
        setSlackProvider(provider)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    /// "Save and Test".
    func slackTokenSet(token: String) async throws -> SlackCheckInfo {
        do {
            try saveSlackToken(token)
        } catch {
            throw CommandFailure(.invalidUsage, error.localizedDescription)
        }
        return try await slackCheck()
    }

    /// "Delete Token…".
    func slackTokenClear() throws {
        guard slack.hasToken else { throw CommandFailure(.invalidState, "There’s no Slack token saved.") }
        try saveSlackToken(nil)
    }

    func slackSetToggle(toggle: SlackToggleName, enabled: Bool) throws {
        setSlackToggle(toggle.toggle, enabled)
        if let settingsError { throw CommandFailure(.failed, settingsError) }
    }

    func slackSetEmoji(kind: SlackEmojiKind, name: String) throws {
        guard SlackSettings.normalizedEmoji(name) != nil else {
            throw CommandFailure(.invalidUsage, "“\(name)” isn’t an emoji name (letters, numbers, _ + ' -, without colons).")
        }
        try applyConfig(slack: true) { $0.slack[keyPath: kind.keyPath] = name }
    }

    func slackSetSearchDays(days: Int) throws {
        // Lo que permite el stepper de la pestaña Slack.
        guard (7...90).contains(days) else { throw CommandFailure(.invalidUsage, "Search 7 to 90 days.") }
        try applyConfig(slack: true) { $0.slack.searchDays = days }
    }

    func slackTemplateList() -> [TemplateInfo] {
        SlackTemplateName.allCases.map { TemplateInfo(name: $0, settings: configStore.config.slack) }
    }

    func slackTemplateSet(template: SlackTemplateName, text: String) throws {
        try applyConfig(slack: true) { $0.slack[keyPath: template.kind.keyPath] = text }
    }

    func slackTemplateReset(template: SlackTemplateName) throws {
        try applyConfig(slack: true) { $0.slack[keyPath: template.kind.keyPath] = template.kind.defaultTemplate }
    }

    /// "Test Connection".
    func slackCheck() async throws -> SlackCheckInfo {
        let provider = configStore.config.slack.provider
        if provider == .userToken && !slack.hasToken {
            throw CommandFailure(.invalidState, "There’s no Slack token. Run `prbar slack token set`.")
        }
        let identity = try await slack.testConnection()
        return SlackCheckInfo(user: identity.user, team: identity.team, provider: provider)
    }

    /// "Send Test to My DM…".
    func slackSelfTest() async throws -> [SelfTestStepInfo] {
        if configStore.config.slack.provider == .userToken && !slack.hasToken {
            throw CommandFailure(.invalidState, "There’s no Slack token. Run `prbar slack token set`.")
        }
        return await slack.sendSelfTest(logURL: AppPaths.slackConnectorLog).map(SelfTestStepInfo.init(step:))
    }

    func slackChannels(reload: Bool) async throws -> [ChannelInfo] {
        guard configStore.config.slack.enabled, slack.isConnected else {
            throw CommandFailure(.invalidState, "Turn on Slack and connect it first (`prbar slack enable`).")
        }
        return try await slack.channels(reload: reload).channels.map(ChannelInfo.init(channel:))
    }
}
```

`UserSuggestion` está en `Settings/WatchedUsersSection.swift` (mismo target): se usa tal cual.

- [ ] **Step 4: Compilar y correr**

Run: `swift build 2>&1 | grep error ; swift run PRBarTests`
Expected: sin errores; todo pasa. `AppModel` ya conforma `PRBarActions` completo: verificarlo agregando temporalmente `let _: any PRBarActions = self` dentro de cualquier método de `AppModel`, compilar, y borrarlo.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/Config.swift Sources/PRBarTests/ConfigTests.swift Sources/PRBar/AppModel+Settings.swift
git commit -m "Implement settings and Slack actions in AppModel"
```

---

### Task 13: El socket arranca con la app

**Files:**
- Modify: `Sources/PRBarCore/Support.swift` (`AppPaths.socketFile`), `Sources/PRBar/AppModel.swift`
- Create: `Sources/PRBar/AppModel+CommandServer.swift`

- [ ] **Step 1: Ruta del socket**

En `AppPaths` (`Sources/PRBarCore/Support.swift`):

```swift
    /// Socket de `prbar` (spec C.2). La carpeta queda en 0700 (`CommandServer.secure`).
    public static var socketFile: URL { appSupport.appendingPathComponent("prbar.sock") }
```

- [ ] **Step 2: Arranque y parada**

`Sources/PRBar/AppModel+CommandServer.swift`:

```swift
import PRBarCore

extension AppModel {
    /// Abre el socket de `prbar`. Cada comando corre en el main actor con los mismos métodos que usa la UI.
    func startCommandServer() {
        let server = CommandServer(socketURL: AppPaths.socketFile, appVersion: appVersion) { [weak self] command, events in
            guard let self else { return .failure(CommandFailure(.failed, "PRBar is quitting.")) }
            return await self.handleCommand(command, events: events)
        }
        do {
            try server.start()
            commandServer = server
        } catch {
            AppLog.write("Couldn’t open the prbar socket: \(error.localizedDescription)")
        }
    }

    func handleCommand(_ command: AppCommand, events: @escaping CommandEventSink) async -> Result<JSONValue, CommandFailure> {
        // Solo el nombre: los argumentos pueden llevar un token (`slack token set`).
        AppLog.write("prbar: \(command.name.rawValue)")
        return await CommandDispatcher.run(command, on: self, events: events)
    }

    func stopCommandServer() {
        commandServer?.stop()
        commandServer = nil
    }
}
```

En `AppModel.swift`:
- agregar la propiedad (junto a `terminationObserver`): `var commandServer: CommandServer?`
- en `init(services:runner:startsServices:)`, después del `guard startsServices else { return }` y antes de `WindowPresenter.shared.openSettings = …`: `startCommandServer()`
- en el observador de `willTerminateNotification`, dentro del `MainActor.assumeIsolated { … }`, agregar `self?.stopCommandServer()`.

El modo de capturas (`startsServices == false`) no abre el socket.

- [ ] **Step 3: Compilar y tests**

Run: `swift build 2>&1 | grep error ; swift run PRBarTests`
Expected: sin errores; todo pasa.

- [ ] **Step 4: Verificación manual con `nc`**

Cerrar la PRBar instalada (menú ⚙︎ → Quit) y correr la de desarrollo:

```bash
swift run PRBar &
sleep 5
ls -la "$HOME/Library/Application Support/PRBar/" | grep -E "prbar.sock| \.$"
printf '%s\n%s\n' '{"hello":{"protocolVersion":1,"version":"dev"}}' '{"id":1,"command":{"status":{}}}' \
  | nc -U "$HOME/Library/Application Support/PRBar/prbar.sock"
```

Expected: la carpeta `.` aparece como `drwx------`, el socket como `srw-------`; `nc` imprime `{"hello":{"protocolVersion":1,"version":"dev"}}` y una línea `{"id":1,"ok":true,"result":{"appVersion":"dev",…}}`. Con `"protocolVersion":2` la respuesta es `{"error":{"code":"protocolMismatch",…},"id":0,"ok":false}`. Cerrar con `kill %1`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/Support.swift Sources/PRBar/AppModel.swift Sources/PRBar/AppModel+CommandServer.swift
git commit -m "Open the prbar socket when the app starts"
```

---

### Task 14: Base de la CLI (salida, conexión, ejecución, interactivo) y `prbar status`

**Files:**
- Create: `Sources/PRBarCore/AppVersion+Executable.swift`, `Sources/PRBarCLIKit/CLISupport.swift`, `Sources/PRBarCLIKit/AppConnection.swift`, `Sources/PRBarCLIKit/CLIRunner.swift`, `Sources/PRBarCLIKit/Interactive.swift`, `Sources/PRBarCLIKit/Render.swift`, `Sources/PRBarCLIKit/StatusCommands.swift`, `Sources/PRBarTests/CLISupportTests.swift`, `Sources/PRBarTests/CLIParsingTests.swift`
- Modify: `Sources/PRBarCLIKit/PRBarCLIKit.swift`, `Sources/PRBarCLI/main.swift`, `Sources/PRBarTests/main.swift` (`+ CLISupportTests.cases + CLIParsingTests.cases`)

- [ ] **Step 1: Tests**

`Sources/PRBarTests/CLISupportTests.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

enum CLISupportTests {
    static let cases: [TestCase] = [
        TestCase("cli soporte: exit codes del spec C.5") {
            try expectEqual(CLIExit.code(for: CommandFailure(.invalidUsage, "")), 2)
            try expectEqual(CLIExit.code(for: CommandFailure(.protocolMismatch, "")), 3)
            try expectEqual(CLIExit.code(for: CommandFailure(.confirmationRequired, "")), 4)
            try expectEqual(CLIExit.code(for: CommandFailure(.notFound, "")), 5)
            try expectEqual(CLIExit.code(for: CommandFailure(.invalidState, "")), 6)
            try expectEqual(CLIExit.code(for: CommandFailure(.cancelled, "")), 130)
            try expectEqual(CLIExit.code(for: CommandFailure(.failed, "")), 1)
        },
        TestCase("cli soporte: color solo en terminal y sin NO_COLOR") {
            try expect(Terminal.colorsEnabled(isTTY: true, environment: [:]))
            try expect(!Terminal.colorsEnabled(isTTY: false, environment: [:]))
            try expect(!Terminal.colorsEnabled(isTTY: true, environment: ["NO_COLOR": "1"]))
            try expect(!Terminal.colorsEnabled(isTTY: true, environment: ["TERM": "dumb"]))
        },
        TestCase("cli soporte: tablas alineadas") {
            try expectEqual(Table.render(headers: ["PR", "Title"], rows: [["a/b#1", "Fix"], ["a/b#10", "Add"]]),
                            ["PR      Title", "a/b#1   Fix", "a/b#10  Add"])
        },
        TestCase("cli soporte: --json con schemaVersion y data") {
            let data = try JSONOutput.encode(JSONValue.object(["a": .int(1)]))
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            try expectEqual(decoded["schemaVersion"], .int(1))
            try expectEqual(decoded["data"], .object(["a": .int(1)]))
        },
        TestCase("cli soporte: Output sin color y errores a stderr") {
            var out = "", err = ""
            let output = Output(terminal: .plain, json: false, out: { out += $0 }, err: { err += $0 })
            output.line(output.paint("hi", .bold))
            output.error("boom")
            output.event(.progress(message: "Reviewing…"))
            output.event(.text(delta: "abc"))
            try expectEqual(out, "hi\nabc")
            try expectEqual(err, "Error: boom\nReviewing…\n")
        },
        TestCase("cli soporte: lista con casillas") {
            var list = CheckboxList(rows: [.init(label: "a", checked: true), .init(label: "b", checked: false)])
            try expectEqual(CheckboxList.key(from: [0x1B, 0x5B, 0x42]), .down)
            try expectEqual(CheckboxList.key(from: [0x20]), .toggle)
            try expectEqual(CheckboxList.key(from: [0x0D]), .done)
            try expectEqual(CheckboxList.key(from: [0x03]), .cancel)
            try expectEqual(list.handle(.down), .keepGoing)
            try expectEqual(list.handle(.toggle), .keepGoing)
            try expectEqual(list.rows.map(\.checked), [true, true])
            try expectEqual(list.handle(.selectNone), .keepGoing)
            try expectEqual(list.rows.map(\.checked), [false, false])
            try expectEqual(list.handle(.edit), .edit(1))
            try expectEqual(list.handle(.down), .keepGoing)
            try expectEqual(list.cursor, 1)
            try expectEqual(list.render(colors: false), "  [ ] a\n› [ ] b\n")
            try expectEqual(list.handle(.done), .done)
        },
        TestCase("cli soporte: encuentra el PRBar.app que contiene a prbar") {
            let root = try temporaryDirectory()
            let helpers = root.appendingPathComponent("Apps/PRBar.app/Contents/Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let binary = helpers.appendingPathComponent("prbar")
            try Data().write(to: binary)
            let link = root.appendingPathComponent("bin-prbar")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            let found = AppLauncher.appBundle(executable: link, home: root)
            try expectEqual(found?.resolvingSymlinksInPath().path,
                            root.appendingPathComponent("Apps/PRBar.app").resolvingSymlinksInPath().path)
            try expectEqual(AppLauncher.appBundle(executable: root.appendingPathComponent("loose"), home: root), nil)
        },
    ]
}
```

`Sources/PRBarTests/CLIParsingTests.swift` (las Tasks 15–19 le agregan casos):

```swift
import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Parsea `arguments` como en la terminal y devuelve el `AppCommand` que mandaría (confirmado).
func parsed(_ arguments: [String], confirmed: Bool = true) throws -> AppCommand {
    let command = try PRBarCommand.parseAsRoot(arguments)
    guard let remote = command as? any RemoteCommand else {
        throw TestFailure(description: "\(arguments) no es un comando remoto")
    }
    return try remote.appCommand(confirmed: confirmed)
}

/// `true` si parsear `arguments` falla (uso inválido → exit 2).
func rejects(_ arguments: [String]) -> Bool {
    (try? PRBarCommand.parseAsRoot(arguments)) == nil
}

enum CLIParsingTests {
    static var cases: [TestCase] {
        [
            TestCase("cli parse: status") {
                try expectEqual(try parsed(["status"]), .status)
                try expectEqual(try parsed(["status", "--json"]), .status)
            },
        ]
    }
}
```

- [ ] **Step 2: Registrar y ver que falla**

Run: `swift run PRBarTests "cli "`
Expected: no compila.

- [ ] **Step 3: `Sources/PRBarCLIKit/CLISupport.swift`**

```swift
import ArgumentParser
import Darwin
import Foundation
import PRBarCore

/// Códigos de salida de `prbar` (spec C.5 y D.4).
public enum CLIExit {
    public static let ok: Int32 = 0
    public static let generalError: Int32 = 1
    public static let usage: Int32 = 2
    public static let appUnavailable: Int32 = 3
    public static let confirmationRequired: Int32 = 4
    public static let notFound: Int32 = 5
    public static let invalidState: Int32 = 6
    public static let updateAvailable: Int32 = 10
    public static let cancelled: Int32 = 130

    public static func code(for failure: CommandFailure) -> Int32 {
        switch failure.code {
        case .invalidUsage: usage
        case .notFound: notFound
        case .invalidState: invalidState
        case .confirmationRequired: confirmationRequired
        case .cancelled: cancelled
        case .protocolMismatch, .unauthorized: appUnavailable
        case .failed: generalError
        }
    }
}

/// Lo que importa de la terminal: si hay TTY (prompts) y si se usan colores.
public struct Terminal: Sendable {
    public var stdinIsTTY: Bool
    public var stdoutIsTTY: Bool
    public var colors: Bool

    public init(stdinIsTTY: Bool, stdoutIsTTY: Bool, colors: Bool) {
        self.stdinIsTTY = stdinIsTTY
        self.stdoutIsTTY = stdoutIsTTY
        self.colors = colors
    }

    /// Preguntar solo si hay alguien del otro lado (spec C.5).
    public var isInteractive: Bool { stdinIsTTY && stdoutIsTTY }

    /// Sin terminal ni color (scripts y tests).
    public static let plain = Terminal(stdinIsTTY: false, stdoutIsTTY: false, colors: false)

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Terminal {
        let stdoutTTY = isatty(STDOUT_FILENO) == 1
        return Terminal(stdinIsTTY: isatty(STDIN_FILENO) == 1, stdoutIsTTY: stdoutTTY,
                        colors: colorsEnabled(isTTY: stdoutTTY, environment: environment))
    }

    /// Color solo en una terminal, sin `NO_COLOR` (https://no-color.org) y con un `TERM` que no sea `dumb`.
    public static func colorsEnabled(isTTY: Bool, environment: [String: String]) -> Bool {
        isTTY && (environment["NO_COLOR"] ?? "").isEmpty && environment["TERM"] != "dumb"
    }
}

public enum Style: String {
    case bold = "1", dim = "2", red = "31", green = "32", yellow = "33", violet = "35", cyan = "36"
}

public enum Table {
    /// Columnas separadas por dos espacios y alineadas (la última sin relleno).
    public static func render(headers: [String], rows: [[String]]) -> [String] {
        let all = [headers] + rows
        let widths = headers.indices.map { column in all.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0 }
        return all.map { row in
            headers.indices.map { column -> String in
                let cell = row.indices.contains(column) ? row[column] : ""
                guard column < headers.count - 1 else { return cell }
                return cell + String(repeating: " ", count: widths[column] - cell.count)
            }.joined(separator: "  ")
        }
    }
}

/// `--json`: `{"schemaVersion": 1, "data": …}`, claves ordenadas, fechas ISO 8601 (docs/cli.md).
public enum JSONOutput {
    public static let schemaVersion = 1

    private struct Envelope<T: Encodable>: Encodable {
        let schemaVersion: Int
        let data: T
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(schemaVersion: schemaVersion, data: value))
    }
}

/// La salida de un comando: texto (con color si corresponde), JSON, errores y eventos (progreso a stderr; el texto
/// del chat a stdout).
public final class Output {
    public let terminal: Terminal
    public let json: Bool
    private let out: (String) -> Void
    private let err: (String) -> Void

    public static let standardOut: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    public static let standardError: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }

    public init(terminal: Terminal, json: Bool, out: @escaping (String) -> Void = Output.standardOut,
                err: @escaping (String) -> Void = Output.standardError) {
        self.terminal = terminal
        self.json = json
        self.out = out
        self.err = err
    }

    public func write(_ text: String) { out(text) }
    public func line(_ text: String = "") { out(text + "\n") }
    public func error(_ message: String) { err(paint("Error: ", .red, .bold) + message + "\n") }
    public func note(_ message: String) { err(paint(message, .dim) + "\n") }

    public func paint(_ text: String, _ styles: Style...) -> String {
        guard terminal.colors, !styles.isEmpty else { return text }
        return "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m\(text)\u{1B}[0m"
    }

    public func table(_ headers: [String], _ rows: [[String]]) {
        let lines = Table.render(headers: headers, rows: rows)
        guard let header = lines.first else { return }
        line(paint(header, .bold))
        lines.dropFirst().forEach { line($0) }
    }

    public func printJSON<T: Encodable>(_ value: T) throws {
        line(String(decoding: try JSONOutput.encode(value), as: UTF8.self))
    }

    public func event(_ event: CommandEvent) {
        switch event {
        case .progress(let message): note(message)
        case .text(let delta): if !json { write(delta) }
        }
    }
}

/// `on`/`off` en la línea de comandos.
public enum OnOff: String, ExpressibleByArgument, CaseIterable {
    case on, off

    public var isOn: Bool { self == .on }
}

extension PRListFilter: @retroactive ExpressibleByArgument {}
extension HistoryKind: @retroactive ExpressibleByArgument {}
extension SettingsTabName: @retroactive ExpressibleByArgument {}
extension NotificationSettingName: @retroactive ExpressibleByArgument {}
extension ToolName: @retroactive ExpressibleByArgument {}
extension SlackToggleName: @retroactive ExpressibleByArgument {}
extension SlackEmojiKind: @retroactive ExpressibleByArgument {}
extension SlackTemplateName: @retroactive ExpressibleByArgument {}

/// Ayuda del argumento `<pr>`.
let prHelp: ArgumentHelp = "owner/repo#N, repo#N or the PR’s URL."

/// Una ruta de la línea de comandos → absoluta (la app no tiene el mismo directorio actual).
func absolutePath(_ raw: String) -> String {
    let expanded = NSString(string: raw).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
}
```

Si el compilador no acepta `@retroactive`, quitarlo (queda un warning).

- [ ] **Step 4: `Sources/PRBarCLIKit/AppConnection.swift`**

```swift
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
    public static var defaultSocketURL: URL {
        if let path = ProcessInfo.processInfo.environment["PRBAR_SOCKET"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return AppPaths.socketFile
    }

    public static var cliVersion: String { AppVersion.forExecutable(AppLauncher.executableURL()) }

    /// Solo conecta: sin app, `AppUnavailable`; con versiones de protocolo distintas, `CommandFailure`.
    public static func connect(socketURL: URL = defaultSocketURL) throws -> AppConnection {
        do {
            return AppConnection(client: try CommandClient.connect(socketURL: socketURL, clientVersion: cliVersion))
        } catch CommandClient.ConnectError.unavailable(let reason) {
            throw AppUnavailable("PRBar isn’t running (\(reason)).")
        }
    }

    public static func open(socketURL: URL = defaultSocketURL, timeout: TimeInterval = 10) throws -> AppConnection {
        do {
            return try connect(socketURL: socketURL)
        } catch is AppUnavailable {
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
```

La versión de `prbar` es la del `PRBar.app` que lo contiene. El plan 8 creó `AppVersion` (Core); agregarle, en `Sources/PRBarCore/AppVersion+Executable.swift`:

```swift
import Foundation

extension AppVersion {
    /// La del `PRBar.app` que contiene a `executable` (`…/PRBar.app/Contents/Helpers/prbar`, resolviendo el link de
    /// `~/.local/bin/prbar`); fuera de un bundle (`swift run PRBarCLI`), `PRBarCore.version`, como `current()`.
    public static func forExecutable(_ executable: URL) -> String {
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents",
              let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return PRBarCore.version }
        return version
    }
}
```

y su test en `CLISupportTests.cases`:

```swift
        TestCase("cli soporte: versión del bundle que contiene a prbar, resolviendo el link") {
            let root = try temporaryDirectory()
            let helpers = root.appendingPathComponent("PRBar.app/Contents/Helpers", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.4.0"],
                                                           format: .xml, options: 0)
            try plist.write(to: root.appendingPathComponent("PRBar.app/Contents/Info.plist"))
            let binary = helpers.appendingPathComponent("prbar")
            try Data().write(to: binary)
            let link = root.appendingPathComponent("prbar-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
            try expectEqual(AppVersion.forExecutable(link), "1.4.0")
            try expectEqual(AppVersion.forExecutable(root.appendingPathComponent("loose")), PRBarCore.version)
        },
```

- [ ] **Step 5: `Sources/PRBarCLIKit/CLIRunner.swift`**

```swift
import ArgumentParser
import Darwin
import Foundation
import PRBarCore

/// Opciones de todos los comandos remotos.
public struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Machine-readable output ({\"schemaVersion\": 1, \"data\": …}, see docs/cli.md).")
    public var json = false

    @Flag(name: [.short, .long], help: "Don’t ask: confirm actions that post, push or approve.")
    public var yes = false

    public init() {}
}

public enum ConfirmationPolicy {
    /// Sin terminal hace falta `--yes` (publicar, pushear, aprobar, mensaje de prueba de Slack).
    case always
    /// Pregunta en la terminal; en scripts sigue sin preguntar (lo que la UI confirma pero no publica nada).
    case interactiveOnly
}

/// Un comando que ejecuta la app: arma el `AppCommand`, lo manda y muestra el resultado.
public protocol RemoteCommand: ParsableCommand {
    var global: GlobalOptions { get }
    /// `confirmed`: el usuario confirmó (`--yes` o la pregunta de la terminal).
    func appCommand(confirmed: Bool) throws -> AppCommand
    /// Antes de armar el comando (p. ej. abrir `$EDITOR` con el texto actual).
    mutating func prepare(_ connection: AppConnection, _ output: Output) throws
    /// La pregunta de confirmación (`nil` = no hace falta). Puede mostrar un resumen o una lista interactiva.
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String?
    var confirmationPolicy: ConfirmationPolicy { get }
    /// Lo que cancela el job si el usuario aprieta Ctrl-C mientras espera (`--wait`).
    var cancelCommand: AppCommand? { get }
    func render(_ result: JSONValue, _ output: Output) throws
}

extension RemoteCommand {
    public mutating func prepare(_ connection: AppConnection, _ output: Output) throws {}
    public func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? { nil }
    public var confirmationPolicy: ConfirmationPolicy { .always }
    public var cancelCommand: AppCommand? { nil }
    public func render(_ result: JSONValue, _ output: Output) throws { output.line("Done.") }

    public mutating func run() throws {
        try CLIRunner.run(self)
    }
}

/// Lo que usa `CLIRunner` del mundo exterior (los tests lo reemplazan).
public struct CLIEnvironment {
    public var terminal: Terminal
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var connect: () throws -> AppConnection
    public var ask: (String) -> Bool

    public init(terminal: Terminal, out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                connect: @escaping () throws -> AppConnection, ask: @escaping (String) -> Bool) {
        self.terminal = terminal
        self.out = out
        self.err = err
        self.connect = connect
        self.ask = ask
    }

    public static var live: CLIEnvironment {
        CLIEnvironment(terminal: .current(), out: Output.standardOut, err: Output.standardError,
                       connect: { try AppConnection.open() }, ask: Prompt.confirm)
    }
}

public enum CLIRunner {
    public static func run<C: RemoteCommand>(_ command: C, environment: CLIEnvironment = .live) throws {
        var command = command
        let output = Output(terminal: environment.terminal, json: command.global.json, out: environment.out,
                            err: environment.err)
        do {
            let connection = try environment.connect()
            defer { connection.close() }
            try command.prepare(connection, output)
            var confirmed = command.global.yes
            if !confirmed, let question = try command.confirmation(connection, output) {
                if output.terminal.isInteractive && !output.json {
                    guard environment.ask(question) else { throw CommandFailure(.cancelled, "Canceled.") }
                    confirmed = true
                } else if command.confirmationPolicy == .always {
                    throw CommandFailure(.confirmationRequired, "\(question) Run it again with --yes to confirm.")
                } else {
                    confirmed = true
                }
            }
            let request = try command.appCommand(confirmed: confirmed)
            let interrupt = command.cancelCommand.map {
                InterruptHandler(cancel: $0, connect: environment.connect, err: environment.err)
            }
            defer { interrupt?.remove() }
            let result = try connection.run(request) { output.event($0) }
            if output.json {
                try output.printJSON(result)
            } else {
                try command.render(result, output)
            }
        } catch let failure as CommandFailure {
            output.error(failure.message)
            throw ExitCode(CLIExit.code(for: failure))
        } catch let unavailable as AppUnavailable {
            output.error(unavailable.message)
            throw ExitCode(CLIExit.appUnavailable)
        }
    }
}

/// Ctrl-C mientras se espera (`--wait`, chat): cancela el job en la app y sale con 130 (spec C.5).
final class InterruptHandler {
    private let source: DispatchSourceSignal

    init(cancel: AppCommand, connect: @escaping () throws -> AppConnection, err: @escaping (String) -> Void) {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            if let connection = try? connect() {
                _ = try? connection.run(cancel)
                connection.close()
            }
            err("\nCanceled.\n")
            exit(CLIExit.cancelled)
        }
        source.resume()
    }

    func remove() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
```

- [ ] **Step 6: `Sources/PRBarCLIKit/Interactive.swift`**

```swift
import Darwin
import Foundation
import PRBarCore

public enum Prompt {
    /// `pregunta [y/N]`: solo "y"/"yes" confirma (Return cancela, como en la app).
    public static func confirm(_ question: String) -> Bool {
        FileHandle.standardOutput.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine() else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Lee un secreto sin eco (el token de Slack).
    public static func secret(_ prompt: String) -> String? {
        guard let pointer = getpass(prompt) else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }
}

public enum Editor {
    /// Abre `text` en `$VISUAL`/`$EDITOR` (`vi` si no hay) y devuelve lo guardado.
    public static func edit(_ text: String, suffix: String = ".md") throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("prbar-\(UUID().uuidString)\(suffix)")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let environment = ProcessInfo.processInfo.environment
        let editor = environment["VISUAL"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["EDITOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(editor) \"$1\"", "prbar-editor", file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(.cancelled, "The editor exited with an error; nothing changed.")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }
}

/// Lista con casillas (lógica pura; la dibuja `CheckboxPicker`).
public struct CheckboxList: Equatable {
    public struct Row: Equatable {
        public var label: String
        public var checked: Bool

        public init(label: String, checked: Bool) {
            self.label = label
            self.checked = checked
        }
    }

    public enum Key: Equatable { case up, down, toggle, selectAll, selectNone, edit, done, cancel, other }
    public enum Outcome: Equatable { case keepGoing, edit(Int), done, cancel }

    public var rows: [Row]
    public var cursor = 0

    public init(rows: [Row]) {
        self.rows = rows
    }

    /// ↑↓ (o k/j), espacio, a = todos, n = ninguno, e = editar, ↩ = listo, q/Esc/Ctrl-C = cancelar.
    public static func key(from bytes: [UInt8]) -> Key {
        switch bytes {
        case [0x1B, 0x5B, 0x41], [0x6B]: .up
        case [0x1B, 0x5B, 0x42], [0x6A]: .down
        case [0x20]: .toggle
        case [0x61]: .selectAll
        case [0x6E]: .selectNone
        case [0x65]: .edit
        case [0x0D], [0x0A]: .done
        case [0x71], [0x1B], [0x03]: .cancel
        default: .other
        }
    }

    public mutating func handle(_ key: Key) -> Outcome {
        guard !rows.isEmpty else { return key == .cancel ? .cancel : key == .done ? .done : .keepGoing }
        switch key {
        case .up: cursor = max(cursor - 1, 0)
        case .down: cursor = min(cursor + 1, rows.count - 1)
        case .toggle: rows[cursor].checked.toggle()
        case .selectAll: for index in rows.indices { rows[index].checked = true }
        case .selectNone: for index in rows.indices { rows[index].checked = false }
        case .edit: return .edit(cursor)
        case .done: return .done
        case .cancel: return .cancel
        case .other: break
        }
        return .keepGoing
    }

    public func render(colors: Bool) -> String {
        rows.enumerated().map { index, row in
            let pointer = index == cursor ? "›" : " "
            let line = "\(pointer) [\(row.checked ? "x" : " ")] \(row.label)"
            return colors && index == cursor ? "\u{1B}[1m\(line)\u{1B}[0m" : line
        }.joined(separator: "\n") + "\n"
    }
}

enum RawTerminal {
    private static var original = termios()

    /// Lee teclas sin eco ni búfer de línea mientras corre `body` (Ctrl-C llega como tecla).
    static func withRawMode<T>(_ body: () throws -> T) rethrows -> T {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        return try body()
    }

    /// Vuelve al modo normal un rato (para abrir `$EDITOR`).
    static func withCookedMode<T>(_ body: () throws -> T) rethrows -> T {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) }
        return try body()
    }

    static func readKey() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        return count > 0 ? Array(buffer.prefix(count)) : [0x03]
    }
}

public enum CheckboxPicker {
    /// Dibuja `list` y la maneja con el teclado. `onEdit(i)` edita la fila `i` y devuelve su nueva etiqueta.
    /// Devuelve la lista final, o `nil` si se canceló.
    public static func run(title: String, list: CheckboxList, output: Output,
                           onEdit: (Int) throws -> String?) throws -> CheckboxList? {
        var list = list
        var drawn = 0
        output.line(output.paint(title, .dim))
        func draw() {
            if drawn > 0 { output.write("\u{1B}[\(drawn)A\u{1B}[J") }
            output.write(list.render(colors: output.terminal.colors))
            drawn = list.rows.count
        }
        return try RawTerminal.withRawMode {
            draw()
            while true {
                switch list.handle(CheckboxList.key(from: RawTerminal.readKey())) {
                case .keepGoing:
                    draw()
                case .done:
                    return list
                case .cancel:
                    return nil
                case .edit(let index):
                    try RawTerminal.withCookedMode {
                        if let label = try onEdit(index) { list.rows[index].label = label }
                    }
                    drawn = 0
                    draw()
                }
            }
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

enum LocalOpen {
    /// `open` (con `reveal`, `open -R`: lo muestra en Finder).
    static func open(_ target: String, reveal: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (reveal ? ["-R"] : []) + [target]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CommandFailure(.failed, "Couldn’t open \(target).") }
    }
}
```

- [ ] **Step 7: `Sources/PRBarCLIKit/Render.swift`**

```swift
import Foundation
import PRBarCore

/// Ayudas de texto de los comandos.
enum Render {
    static func age(_ date: Date) -> String {
        let short = RelativeAge.short(from: date)
        return short == "now" ? "just now" : "\(short) ago"
    }

    /// Una línea, cortada con "…".
    static func truncate(_ text: String, _ limit: Int) -> String {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return single.count <= limit ? single : String(single.prefix(max(limit - 1, 0))) + "…"
    }

    static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// `clave: valor` con las claves alineadas.
    static func pairs(_ pairs: [(String, String)], _ output: Output) {
        let width = pairs.map(\.0.count).max() ?? 0
        for (key, value) in pairs {
            output.line(output.paint(key + ":", .dim) + String(repeating: " ", count: width - key.count + 1) + value)
        }
    }

    static func indent(_ text: String, _ prefix: String = "    ") -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }
}
```

- [ ] **Step 8: `prbar status` y la raíz**

`Sources/PRBarCLIKit/StatusCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCore

struct StatusCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "What PRBar shows in the menu bar.")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .status }

    func render(_ result: JSONValue, _ output: Output) throws {
        let status: StatusInfo = try result.decode()
        var header = "PRBar \(status.appVersion)"
        if status.refreshing {
            header += " · updating…"
        } else if status.offline {
            header += " · offline"
        } else if let fetchedAt = status.fetchedAt {
            header += " · updated \(Render.age(fetchedAt))"
        }
        if let until = status.rateLimitedUntil, until > Date() { header += " · GitHub rate limit until \(ClockTime.hhmm(until))" }
        output.line(output.paint(header, .bold))
        output.table(["Section", "PRs"], PRCategory.allCases.map { [$0.title, String(status.counts[$0.rawValue] ?? 0)] })
        if !status.jobs.isEmpty {
            output.line()
            output.table(["Running", "Kind", "Phase"], status.jobs.map { [$0.pr, $0.kind, $0.phase] })
        }
        for issue in status.issues + status.slackIssues { output.line(output.paint("! " + issue, .red)) }
        let missing = status.tools.filter { $0.path == nil }.map(\.name)
        if !missing.isEmpty {
            output.line(output.paint("Missing tools: \(missing.joined(separator: ", ")). Run `prbar doctor`.", .yellow))
        }
    }
}
```

Reemplazar `Sources/PRBarCLIKit/PRBarCLIKit.swift`:

```swift
import ArgumentParser
import Darwin
import Foundation
import PRBarCore

public enum PRBarCLIKit {
    public static let commandName = "prbar"
}

/// `prbar`: todo lo que se hace en la app, desde la terminal (spec C). Ver docs/cli.md.
public struct PRBarCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: PRBarCLIKit.commandName,
        abstract: "Control PRBar from the terminal.",
        discussion: "Everything you can do in PRBar’s menu bar and windows. PRs: owner/repo#N, repo#N or the PR’s URL. See docs/cli.md.",
        version: AppConnection.cliVersion,
        subcommands: [
            StatusCommand.self,
        ]
    )

    public init() {}
}

public enum PRBarCLIMain {
    /// Parsea, corre y sale con los códigos de `CLIExit` (uso inválido = 2, no el 64 de ArgumentParser).
    public static func run() async -> Never {
        signal(SIGPIPE, SIG_IGN)
        do {
            var command = try PRBarCommand.parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            exit(CLIExit.ok)
        } catch {
            if PRBarCommand.exitCode(for: error).rawValue == ExitCode.validationFailure.rawValue {
                FileHandle.standardError.write(Data((PRBarCommand.fullMessage(for: error) + "\n").utf8))
                exit(CLIExit.usage)
            }
            PRBarCommand.exit(withError: error)
        }
    }
}
```

`Sources/PRBarCLI/main.swift`:

```swift
import PRBarCLIKit

await PRBarCLIMain.run()
```

- [ ] **Step 9: Correr**

Run: `swift run PRBarTests "cli "`
Expected: `8/8` (soporte) + `1/1` (parse) pasan.

Run (con la app de la Task 13 corriendo): `swift run PRBarCLI status ; echo "exit $?"` y `swift run PRBarCLI status --json | head -5`
Expected: la tabla de secciones y `exit 0`; el JSON empieza con `{` y tiene `"schemaVersion" : 1`. Con la app cerrada y `PRBAR_SOCKET=/tmp/nope.sock swift run PRBarCLI status`: intenta abrir la app; si no hay `PRBar.app` instalada sale con `exit 3` y "Couldn’t open PRBar.app…".

Run: `swift run PRBarCLI status --nope ; echo "exit $?"`
Expected: el error de uso de ArgumentParser y `exit 2`.

- [ ] **Step 10: Commit**

```bash
git add Sources/PRBarCore/AppVersion+Executable.swift Sources/PRBarCLIKit Sources/PRBarCLI/main.swift Sources/PRBarTests/CLISupportTests.swift Sources/PRBarTests/CLIParsingTests.swift Sources/PRBarTests/main.swift
git commit -m "Add the CLI foundation: output, connection, runner, prompts and prbar status"
```

---

### Task 15: Comandos de estado, PRs, historial, ventanas, app y los que andan sin app

**Files:**
- Modify: `Sources/PRBarCLIKit/StatusCommands.swift`, `Sources/PRBarCLIKit/PRBarCLIKit.swift` (subcomandos), `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Tests de parseo**

Agregar a `CLIParsingTests.cases`:

```swift
            TestCase("cli parse: prs, refresh, open e historial") {
                try expectEqual(try parsed(["prs", "--list", "to-review", "--account", "me"]), .listPRs(list: .toReview, account: "me"))
                try expectEqual(try parsed(["prs"]), .listPRs(list: nil, account: nil))
                try expectEqual(try parsed(["refresh"]), .refresh)
                try expectEqual(try parsed(["open", "api#3"]), .open(pr: "api#3", target: .browser))
                try expectEqual(try parsed(["open", "api#3", "--review"]), .open(pr: "api#3", target: .review))
                try expectEqual(try parsed(["open", "api#3", "--worktree"]), .open(pr: "api#3", target: .worktree))
                try expectEqual(try parsed(["open", "api#3", "--copy"]), .resolvePR(pr: "api#3"))
                try expect(rejects(["open", "api#3", "--review", "--respond"]))
                try expectEqual(try parsed(["history", "--repo", "acme/api", "--kind", "review", "--limit", "5", "--search", "login"]),
                                .history(repo: "acme/api", kind: .review, limit: 5, search: "login"))
                try expectEqual(try parsed(["history"]), .history(repo: nil, kind: nil, limit: nil, search: nil))
                try expectEqual(try parsed(["history", "show", "1a2b3c4d"]), .historyShow(id: "1a2b3c4d"))
                try expectEqual(try parsed(["history", "reopen", "1a2b3c4d"]), .historyReopen(id: "1a2b3c4d"))
            },
            TestCase("cli parse: app") {
                try expectEqual(try parsed(["app", "quit"]), .quit)
                try expectEqual(try parsed(["app", "settings", "slack"]), .openSettings(tab: .slack))
                try expectEqual(try parsed(["app", "settings"]), .openSettings(tab: nil))
                try expectEqual(try parsed(["app", "history", "1a2b"]), .openHistory(id: "1a2b"))
                try expect(rejects(["app", "settings", "nope"]))
                for local in [["app", "start"], ["app", "logs", "--slack"], ["doctor"], ["version"], ["completion", "zsh"]] {
                    let command = try PRBarCommand.parseAsRoot(local)
                    try expect(command is any LocalCommand, "\(local)")
                }
            },
```

Run: `swift run PRBarTests "cli parse"`
Expected: no compila.

- [ ] **Step 2: Implementar (agregar a `StatusCommands.swift`)**

```swift
/// Comandos que no necesitan la app (spec C.2): `doctor`, `version`, `completion`, `app start`, `app logs`,
/// `repo open`, `notify system-settings`.
public protocol LocalCommand: ParsableCommand {}

struct PRsCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "prs", abstract: "The PRs in the menu bar.")
    @Option(help: "Only one section: to-review, updated, mine (my PRs with feedback) or other.") var list: PRListFilter?
    @Option(help: "Only this account’s PRs.") var account: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .listPRs(list: list, account: account) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let prs: [PRInfo] = try result.decode()
        guard !prs.isEmpty else { return output.line("No PRs.") }
        output.table(["PR", "Title", "Author", "Section", "CI", "PRBar"], prs.map { pr in
            let prbar = [pr.review.map { "review: \($0)" }, pr.respond.map { "respond: \($0)" }].compactMap { $0 }
            return [pr.id, Render.truncate(pr.title, 50), pr.author, pr.category, pr.ci, prbar.joined(separator: ", ")]
        })
    }
}

struct RefreshCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "refresh", abstract: "Refresh the PRs now (⌘R).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .refresh }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Refreshed.") }
}

enum OpenTargetFlag: String, EnumerableFlag {
    case browser, review, respond, posted, worktree

    var target: OpenTarget { OpenTarget(rawValue: rawValue) ?? .browser }

    static func help(for value: OpenTargetFlag) -> ArgumentHelp? {
        switch value {
        case .browser: "The PR on GitHub (default)."
        case .review: "Its Review window."
        case .respond: "Its Respond window."
        case .posted: "The posted review on GitHub."
        case .worktree: "The Respond worktree in Finder."
        }
    }
}

struct OpenCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a PR on GitHub, or its window in PRBar.")
    @Argument(help: prHelp) var pr: String
    @Flag var target: OpenTargetFlag = .browser
    @Flag(help: "Copy the PR’s link instead of opening it.") var copy = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { copy ? .resolvePR(pr: pr) : .open(pr: pr, target: target.target) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let link: PRLink = try result.decode()
        if copy {
            try Pasteboard.copy(link.url.absoluteString)
            output.line("Copied \(link.url.absoluteString)")
        } else {
            output.line(link.url.isFileURL ? link.url.path : link.url.absoluteString)
        }
    }
}

struct HistoryGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "Claude’s reviews and feedback responses.",
        subcommands: [HistoryList.self, HistoryShow.self, HistoryReopen.self], defaultSubcommand: HistoryList.self)
}

struct HistoryList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the history (also: prbar history).")
    @Option(help: "Only this repo (owner/repo).") var repo: String?
    @Option(help: "review or respond.") var kind: HistoryKind?
    @Option(help: "Title, repo or number (like the window’s search).") var search: String?
    @Option(help: "At most this many records (default 50).") var limit: Int?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .history(repo: repo, kind: kind, limit: limit, search: search) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let entries: [HistoryEntryInfo] = try result.decode()
        guard !entries.isEmpty else { return output.line("No history.") }
        output.table(["ID", "Kind", "PR", "Title", "Status", "Started"], entries.map {
            [String($0.id.uuidString.prefix(8)).lowercased(), $0.kind.rawValue, $0.pr, Render.truncate($0.title, 40), $0.status,
             Render.date($0.startedAt)]
        })
    }
}

struct HistoryShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One record (id or its first characters).")
    @Argument(help: "The record’s id (at least 4 characters).") var id: String
    @Flag(help: "Open Claude’s log of the run.") var openLog = false
    @Flag(help: "Show Claude’s log in Finder.") var revealLog = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .historyShow(id: id) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let detail: HistoryDetail = try result.decode()
        let entry = detail.entry
        output.line(output.paint("\(entry.pr) · \(entry.kind.rawValue) · \(entry.status)", .bold))
        output.line(entry.title)
        var pairs: [(String, String)] = [("PR", detail.prURL.absoluteString), ("Started", Render.date(entry.startedAt))]
        if let action = detail.action { pairs.append(("Action", action)) }
        if let url = detail.reviewURL { pairs.append(("Review", url.absoluteString)) }
        if let error = detail.errorMessage { pairs.append(("Error", error)) }
        if let log = detail.logPath { pairs.append(("Log", log)) }
        if detail.canReopen { pairs.append(("Open to post", "prbar history reopen \(id)")) }
        if detail.canOpen { pairs.append(("Response", "prbar open \(entry.pr) --respond")) }
        Render.pairs(pairs, output)
        if let summary = detail.summary, !summary.isEmpty { output.line(); output.line(summary) }
        for finding in detail.findings {
            output.line("\(finding.included ? "✓" : "·") #\(finding.number) \(finding.severity.rawValue) \(finding.location) — \(finding.title)")
        }
        if let general = detail.generalComment { output.line("General comment: \(general)") }
        for reply in detail.replies { output.line("↩ \(reply.location) \(reply.url.absoluteString)") }
        if openLog || revealLog {
            guard let log = detail.logPath else { throw CommandFailure(.notFound, "This record has no log.") }
            try LocalOpen.open(log, reveal: revealLog)
        }
    }
}

struct HistoryReopen: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reopen", abstract: "Open a ready review from the history to post it (“Open to Post”).")
    @Argument(help: "The record’s id.") var id: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .historyReopen(id: id) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Opened the review window.") }
}

struct AppGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app", abstract: "PRBar.app itself.",
        subcommands: [AppStart.self, AppQuit.self, AppSettings.self, AppHistory.self, AppLogs.self])
}

struct AppStart: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Open PRBar in the background.")

    func run() throws {
        do {
            let connection = try AppConnection.open()
            print("PRBar \(connection.appVersion) is running.")
            connection.close()
        } catch let unavailable as AppUnavailable {
            FileHandle.standardError.write(Data("Error: \(unavailable.message)\n".utf8))
            throw ExitCode(CLIExit.appUnavailable)
        }
    }
}

struct AppQuit: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "quit", abstract: "Quit PRBar (⌘Q).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .quit }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("PRBar is quitting.") }
}

struct AppSettings: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "settings", abstract: "Open Settings (⌘,), optionally on a tab.")
    @Argument(help: "general, claude, accounts, repos or slack.") var tab: SettingsTabName?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .openSettings(tab: tab) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Opened Settings.") }
}

struct AppHistory: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "history", abstract: "Open the History window (⌘Y), optionally on a record.")
    @Argument(help: "A record’s id.") var id: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .openHistory(id: id) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Opened History.") }
}

struct AppLogs: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "logs", abstract: "Open PRBar’s log (works without the app).")
    @Flag(help: "The Slack connector’s log (Settings › Slack › Show Log).") var slack = false
    @Flag(help: "Only print the path.") var path = false

    func run() throws {
        let url = slack ? AppPaths.slackConnectorLog : AppPaths.logFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("Error: There’s no log yet at \(url.path).\n".utf8))
            throw ExitCode(CLIExit.notFound)
        }
        if path { print(url.path) } else { try LocalOpen.open(url.path) }
    }
}

struct VersionCommand: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "prbar’s and PRBar.app’s versions (About PRBar).")
    @Flag(help: "Machine-readable output.") var json = false

    struct Versions: Codable { let cli: String; let app: String? }

    func run() throws {
        let app = try? AppConnection.connect()
        let versions = Versions(cli: AppConnection.cliVersion, app: app?.appVersion)
        app?.close()
        let output = Output(terminal: .current(), json: json)
        if json { return try output.printJSON(versions) }
        output.line("prbar \(versions.cli)")
        output.line(versions.app.map { "PRBar.app \($0) (running)" } ?? "PRBar.app isn’t running")
    }
}

enum Shell: String, ExpressibleByArgument, CaseIterable { case zsh, bash, fish }

struct CompletionCommand: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Print the shell completion script.",
                                                    discussion: "zsh: prbar completion zsh > ~/.zfunc/_prbar")
    @Argument(help: "zsh, bash or fish.") var shell: Shell

    func run() throws {
        guard let completion = CompletionShell(rawValue: shell.rawValue) else { throw ExitCode(CLIExit.usage) }
        print(PRBarCommand.completionScript(for: completion))
    }
}

struct DoctorCheck: Codable {
    let name: String
    let ok: Bool
    let detail: String
}

struct DoctorCommand: AsyncParsableCommand, LocalCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check PRBar’s installation (works without the app).")
    @Flag(help: "Machine-readable output.") var json = false

    func run() async throws {
        var checks: [DoctorCheck] = []
        let app = AppLauncher.appBundle()
        checks.append(DoctorCheck(name: "PRBar.app", ok: app != nil,
                                  detail: app?.path ?? "Not found. Install it with Scripts/bundle.sh --install."))
        do {
            let connection = try AppConnection.connect()
            checks.append(DoctorCheck(name: "App", ok: true, detail: "Running, PRBar \(connection.appVersion)"))
            connection.close()
        } catch let failure as CommandFailure {
            checks.append(DoctorCheck(name: "App", ok: false, detail: failure.message))
        } catch {
            checks.append(DoctorCheck(name: "App", ok: true, detail: "Not running (prbar opens it when needed)."))
        }
        checks.append(Self.linkCheck())
        let config = try? JSONCoding.decoder.decode(AppConfig.self, from: Data(contentsOf: AppPaths.configFile))
        checks.append(DoctorCheck(name: "config.json", ok: config != nil,
                                  detail: config != nil ? AppPaths.configFile.path : "Missing or unreadable: \(AppPaths.configFile.path)"))
        let locator = ToolLocator(runner: SystemProcessRunner())
        for tool in ToolName.allCases {
            let path = await locator.locate(tool.rawValue, override: config?.toolPaths[keyPath: tool.keyPath])
            checks.append(DoctorCheck(name: tool.rawValue, ok: path != nil, detail: path ?? Self.installHint(tool)))
        }
        let output = Output(terminal: .current(), json: json)
        if json {
            try output.printJSON(checks)
        } else {
            for check in checks {
                output.line("\(check.ok ? output.paint("✓", .green) : output.paint("✗", .red)) \(check.name): \(check.detail)")
            }
        }
        if checks.contains(where: { !$0.ok }) { throw ExitCode(CLIExit.generalError) }
    }

    /// `~/.local/bin/prbar` (o `$PRBAR_BIN_DIR/prbar`) existe y su carpeta está en el PATH.
    static func linkCheck(environment: [String: String] = ProcessInfo.processInfo.environment) -> DoctorCheck {
        let dir = environment["PRBAR_BIN_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.local/bin"
        let link = dir + "/prbar"
        guard FileManager.default.fileExists(atPath: link) else {
            return DoctorCheck(name: "prbar in PATH", ok: false, detail: "No \(link). Run Scripts/bundle.sh --install.")
        }
        let inPath = (environment["PATH"] ?? "").split(separator: ":").contains { $0 == dir }
        return DoctorCheck(name: "prbar in PATH", ok: inPath,
                           detail: inPath ? link : "\(dir) isn’t in your PATH: add `export PATH=\"\(dir):$PATH\"` to ~/.zshrc.")
    }

    static func installHint(_ tool: ToolName) -> String {
        switch tool {
        case .gh: "Not found. Install it with `brew install gh`, then `gh auth login --hostname github.com`."
        case .git: "Not found. Install the Command Line Tools: `xcode-select --install`."
        case .claude: "Not found. Install Claude Code (https://claude.com/claude-code) and sign in."
        }
    }
}
```

En `PRBarCommand.configuration.subcommands`, después de `StatusCommand.self`:

```swift
            PRsCommand.self, RefreshCommand.self, OpenCommand.self, HistoryGroup.self, AppGroup.self,
            VersionCommand.self, DoctorCommand.self, CompletionCommand.self,
```

`CompletionShell(rawValue:)`: si en 1.6.2 no es failable, usar `CompletionShell(rawValue: shell.rawValue)` sin `guard`.

- [ ] **Step 3: Correr**

Run: `swift run PRBarTests "cli parse"`
Expected: `3/3 passed`.

Run: `swift run PRBarCLI doctor ; echo "exit $?"` y `swift run PRBarCLI completion zsh | head -3`
Expected: una línea ✓/✗ por chequeo (sin app instalada, `✗ PRBar.app`) y el script de zsh (`#compdef prbar`).

Run (con la app corriendo): `swift run PRBarCLI prs`, `swift run PRBarCLI history`, `swift run PRBarCLI app settings repos`
Expected: la tabla de PRs, la del historial, y Settings se abre en la pestaña Repos.

- [ ] **Step 4: Commit**

```bash
git add Sources/PRBarCLIKit/StatusCommands.swift Sources/PRBarCLIKit/PRBarCLIKit.swift Sources/PRBarTests/CLIParsingTests.swift
git commit -m "Add status, prs, history, open, app, version, doctor and completion commands"
```

---

### Task 16: `prbar review …`

**Files:**
- Create: `Sources/PRBarCLIKit/ReviewCommands.swift`
- Modify: `Sources/PRBarCLIKit/PRBarCLIKit.swift` (`ReviewGroup.self`), `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Tests**

Agregar a `CLIParsingTests.cases`:

```swift
            TestCase("cli parse: review") {
                try expectEqual(try parsed(["review", "acme/api#1"]), .reviewStart(pr: "acme/api#1", wait: false))
                try expectEqual(try parsed(["review", "acme/api#1", "--wait"]), .reviewStart(pr: "acme/api#1", wait: true))
                try expectEqual(try parsed(["review", "show", "api#1"]), .reviewShow(pr: "api#1"))
                try expectEqual(try parsed(["review", "edit", "api#1", "2", "--title", "T", "--body", "B"]),
                                .reviewEdit(pr: "api#1", finding: "2", title: "T", body: "B"))
                try expect(rejects(["review", "edit", "api#1", "2", "--body", "B", "--editor"]))
                try expectEqual(try parsed(["review", "include", "api#1", "1", "3"]),
                                .reviewSetIncluded(pr: "api#1", findings: ["1", "3"], all: false, included: true))
                try expectEqual(try parsed(["review", "exclude", "api#1", "--all"]),
                                .reviewSetIncluded(pr: "api#1", findings: [], all: true, included: false))
                try expect(rejects(["review", "include", "api#1"]))
                try expectEqual(try parsed(["review", "comment", "api#1", "--text", "LGTM"]), .reviewSetComment(pr: "api#1", text: "LGTM"))
                try expectEqual(try parsed(["review", "publish", "api#1", "--approve", "--only", "1,3", "--yes"]),
                                .reviewPublish(pr: "api#1", event: .approve, only: ["1", "3"], withComments: true, allInBody: false, confirmed: true))
                try expectEqual(try parsed(["review", "publish", "api#1", "--request-changes", "--all-in-body"], confirmed: false),
                                .reviewPublish(pr: "api#1", event: .requestChanges, only: nil, withComments: true, allInBody: true, confirmed: false))
                try expectEqual(try parsed(["review", "publish", "api#1", "--approve", "--no-comments"]),
                                .reviewPublish(pr: "api#1", event: .approve, only: nil, withComments: false, allInBody: false, confirmed: true))
                try expect(rejects(["review", "publish", "api#1"]))
                try expect(rejects(["review", "publish", "api#1", "--comment", "--no-comments"]))
                try expectEqual(try parsed(["review", "cancel", "api#1"]), .reviewCancel(pr: "api#1"))
                try expectEqual(try parsed(["review", "dismiss", "api#1"]), .reviewDismiss(pr: "api#1"))
            },
            TestCase("cli: pregunta de confirmación de la review") {
                try expectEqual(ReviewQuestion.text(event: .approve, pr: "acme/api#1", account: "me", comments: 2, general: true),
                                "Approve acme/api#1 as @me with 2 comments and a general comment?")
                try expectEqual(ReviewQuestion.text(event: .comment, pr: "acme/api#1", account: "me", comments: 1, general: false),
                                "Comment on acme/api#1 as @me with 1 comment?")
                try expectEqual(ReviewQuestion.text(event: .approve, pr: "acme/api#1", account: "me", comments: 0, general: false),
                                "Approve acme/api#1 as @me without comments?")
            },
```

`parsed(…, confirmed: false)` arma el comando como si no se hubiera confirmado (sin `--yes` y sin preguntar).

Run: `swift run PRBarTests "cli"`
Expected: no compila.

- [ ] **Step 2: Implementar `Sources/PRBarCLIKit/ReviewCommands.swift`**

```swift
import ArgumentParser
import Foundation
import PRBarCore

struct ReviewGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review", abstract: "Review other people’s PRs with Claude.",
        discussion: "prbar review <pr> starts a review. Findings are numbered like in the window (#N).",
        subcommands: [ReviewStart.self, ReviewShow.self, ReviewEdit.self, ReviewInclude.self, ReviewExclude.self,
                      ReviewComment.self, ReviewPublish.self, ReviewCancel.self, ReviewDismiss.self],
        defaultSubcommand: ReviewStart.self)
}

enum ReviewRender {
    static func info(_ info: ReviewInfo, _ output: Output, full: Bool = false) {
        var header = "\(info.pr) · \(info.phase)"
        if let detail = info.detail, info.phase != "failed" { header += " (\(detail))" }
        output.line(output.paint(header, .bold))
        if info.phase == "failed", let detail = info.detail { output.line(output.paint(detail, .red)) }
        if let log = info.logPath { output.line("Log: \(log)") }
        if let url = info.reviewURL { output.line("Posted: \(url.absoluteString)") }
        guard info.phase == "ready" else { return }
        if let title = info.title { output.line(title) }
        if info.outdated { output.line(output.paint("The PR changed since the review: comments will go in the review body.", .yellow)) }
        if let summary = info.summary, !summary.isEmpty { output.line(); output.line(summary) }
        output.line()
        let selected = info.findings.filter(\.included).count
        output.line("\(selected) of \(info.findings.count) selected · posting as @\(info.account ?? "?") in \(info.language ?? "English")")
        output.table(["#", "", "Severity", "Location", "Title"], info.findings.map { finding in
            ["\(finding.number)", finding.included ? "✓" : "·", finding.severity.rawValue, finding.location,
             Render.truncate(finding.title, 60) + (finding.edited ? " (edited)" : "") + (finding.keptByFilter ? "" : " [discarded by the filter]")]
        })
        if full {
            for finding in info.findings {
                output.line()
                output.line(output.paint("#\(finding.number) \(finding.title)", .bold))
                if let reason = finding.filterReason { output.line(output.paint("Filter: \(reason)", .dim)) }
                output.line(Render.indent(finding.body))
            }
        }
        if let general = info.generalComment { output.line(); output.line("General comment: \(general)") }
    }
}

/// La pregunta antes de publicar (pública para los tests).
public enum ReviewQuestion {
    public static func text(event: ReviewEvent, pr: String, account: String, comments: Int, general: Bool) -> String {
        let verb = switch event {
        case .approve: "Approve \(pr)"
        case .requestChanges: "Request changes on \(pr)"
        case .comment: "Comment on \(pr)"
        }
        var parts: [String] = []
        if comments > 0 { parts.append(comments == 1 ? "1 comment" : "\(comments) comments") }
        if general { parts.append("a general comment") }
        let what = parts.isEmpty ? "without comments" : "with " + parts.joined(separator: " and ")
        return "\(verb) as @\(account) \(what)?"
    }
}

struct ReviewStart: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Review a PR with Claude (also: prbar review <pr>).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until the review is ready and print it (Ctrl-C cancels the review).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewStart(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .reviewCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The review’s findings, selection and texts.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Also print each finding’s comment.") var full = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewShow(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output, full: full) }
}

struct ReviewEdit: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Edit a finding’s title or comment.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "The finding’s number (#N) or id.") var finding: String
    @Option(help: "New title.") var title: String?
    @Option(help: "New comment (Markdown).") var body: String?
    @Option(help: "Read the comment from a file (- = stdin).") var bodyFile: String?
    @Flag(help: "Edit the comment in $EDITOR.") var editor = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [body != nil, bodyFile != nil, editor].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use only one of --body, --body-file and --editor.")
        }
        guard title != nil || body != nil || bodyFile != nil || editor else {
            throw ValidationError("Pass --title, --body, --body-file or --editor.")
        }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        if let bodyFile {
            body = bodyFile == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                : try String(contentsOfFile: absolutePath(bodyFile), encoding: .utf8)
        } else if editor {
            let info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
            guard let current = info.findings.first(where: { String($0.number) == finding || $0.id == finding }) else {
                throw CommandFailure(.notFound, "There’s no finding \(finding). Run `prbar review show \(pr)`.")
            }
            body = try Editor.edit(current.body)
        }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewEdit(pr: pr, finding: finding, title: title, body: body) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewInclude: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "include", abstract: "Post these findings (checkbox on; --all = Select All).")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "Findings: numbers (#N) or ids.") var findings: [String] = []
    @Flag(help: "Every finding the filter kept (Select All).") var all = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard all != !findings.isEmpty else { throw ValidationError("Name the findings or pass --all (not both).") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewSetIncluded(pr: pr, findings: findings, all: all, included: true) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewExclude: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "exclude", abstract: "Don’t post these findings (checkbox off; --all = Select None).")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "Findings: numbers (#N) or ids.") var findings: [String] = []
    @Flag(help: "All of them (Select None).") var all = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard all != !findings.isEmpty else { throw ValidationError("Name the findings or pass --all (not both).") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewSetIncluded(pr: pr, findings: findings, all: all, included: false) }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

struct ReviewComment: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "comment", abstract: "The review’s general comment (empty = none).")
    @Argument(help: prHelp) var pr: String
    @Option(help: "The text.") var text: String?
    @Flag(help: "Edit it in $EDITOR.") var editor = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard (text != nil) != editor else { throw ValidationError("Pass --text or --editor.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard editor else { return }
        let info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
        text = try Editor.edit(info.generalComment ?? "")
    }

    func appCommand(confirmed: Bool) -> AppCommand { .reviewSetComment(pr: pr, text: text ?? "") }
    func render(_ result: JSONValue, _ output: Output) throws { ReviewRender.info(try result.decode(), output) }
}

enum PublishEvent: String, EnumerableFlag {
    case comment, requestChanges, approve

    var event: ReviewEvent {
        switch self {
        case .comment: .comment
        case .requestChanges: .requestChanges
        case .approve: .approve
        }
    }
}

struct ReviewPublish: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish", abstract: "Post the review to GitHub.",
        discussion: "In a terminal, without --only, you choose the comments in a list (space, e = edit in $EDITOR, ↩) and confirm. Without a terminal it needs --yes.")
    @Argument(help: prHelp) var pr: String
    @Flag var event: PublishEvent
    @Option(help: "Post only these findings (numbers or ids, comma-separated) instead of the selection.") var only: String?
    @Flag(help: "Post only the verdict (Approve Without Comments).") var noComments = false
    @Flag(help: "Put every comment in the review body (if GitHub rejected the inline ones).") var allInBody = false
    @OptionGroup var global: GlobalOptions

    private var onlyList: [String]? {
        only.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }

    func validate() throws {
        if noComments && event != .approve { throw ValidationError("--no-comments only goes with --approve.") }
        if noComments && only != nil { throw ValidationError("--no-comments and --only don’t go together.") }
    }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        var info: ReviewInfo = try connection.run(.reviewShow(pr: pr)).decode()
        guard info.phase == "ready" else {
            throw CommandFailure(.invalidState, "There’s no review ready to post for \(info.pr). Run `prbar review \(info.pr)` first.")
        }
        if output.terminal.isInteractive, !output.json, only == nil, !noComments {
            guard let chosen = try ReviewPicker.run(info: info, connection: connection, output: output) else {
                throw CommandFailure(.cancelled, "Canceled.")
            }
            info = chosen
        }
        let comments = noComments ? 0 : onlyList?.count ?? info.findings.filter(\.included).count
        let general = !noComments && !(info.generalComment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ReviewQuestion.text(event: event.event, pr: info.pr, account: info.account ?? "?", comments: comments, general: general)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        .reviewPublish(pr: pr, event: event.event, only: onlyList, withComments: !noComments, allInBody: allInBody, confirmed: confirmed)
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        let posted: PublishedReviewInfo = try result.decode()
        output.line("Posted (\(posted.action), \(posted.comments) comment\(posted.comments == 1 ? "" : "s")): \(posted.url.absoluteString)")
    }
}

/// La lista con casillas de `review publish` en la terminal. Lo que se elige y edita se aplica en la app
/// (`include`/`exclude`/`edit`), así la ventana muestra lo mismo.
enum ReviewPicker {
    static func label(_ finding: FindingInfo) -> String {
        "#\(finding.number) \(finding.severity.rawValue) \(finding.location) — \(Render.truncate(finding.title, 60))\(finding.edited ? " (edited)" : "")"
    }

    static func run(info: ReviewInfo, connection: AppConnection, output: Output) throws -> ReviewInfo? {
        var current = info
        let list = CheckboxList(rows: info.findings.map { .init(label: label($0), checked: $0.included) })
        let title = "Choose the comments to post — space: toggle · e: edit · a/n: all/none · ↩: done · q: cancel"
        let final = try CheckboxPicker.run(title: title, list: list, output: output) { index in
            let finding = current.findings[index]
            let edited = try Editor.edit(finding.body)
            guard edited != finding.body else { return nil }
            current = try connection.run(.reviewEdit(pr: info.pr, finding: String(finding.number), title: nil, body: edited)).decode()
            return label(current.findings[index])
        }
        guard let final else { return nil }
        let numbers = current.findings.map { String($0.number) }
        let include = final.rows.indices.filter { final.rows[$0].checked }.map { numbers[$0] }
        let exclude = final.rows.indices.filter { !final.rows[$0].checked }.map { numbers[$0] }
        if !include.isEmpty {
            current = try connection.run(.reviewSetIncluded(pr: info.pr, findings: include, all: false, included: true)).decode()
        }
        if !exclude.isEmpty {
            current = try connection.run(.reviewSetIncluded(pr: info.pr, findings: exclude, all: false, included: false)).decode()
        }
        return current
    }
}

struct ReviewCancel: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel a running review.")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewCancel(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Canceled the review of \(pr).") }
}

struct ReviewDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss a finished review (it stays in History).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .reviewDismiss(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed the review of \(pr).") }
}
```

Agregar `ReviewGroup.self` a los subcomandos de `PRBarCommand`.

- [ ] **Step 3: Correr**

Run: `swift run PRBarTests "cli"`
Expected: todos los `cli …` pasan.

- [ ] **Step 4: Verificación manual (con la app corriendo y un PR para revisar)**

```bash
swift run PRBarCLI review acme/api#12 --wait      # progreso en stderr; al final la tabla de findings
swift run PRBarCLI review exclude acme/api#12 2   # en la ventana abierta, #2 se destilda al instante
swift run PRBarCLI review publish acme/api#12 --comment < /dev/null ; echo "exit $?"   # sin TTY → exit 4
swift run PRBarCLI review publish acme/api#12 --comment                               # TTY: lista con casillas + pregunta
```

Ctrl-C durante `--wait` cancela el review (la fila vuelve a "Review") y sale con 130.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCLIKit/ReviewCommands.swift Sources/PRBarCLIKit/PRBarCLIKit.swift Sources/PRBarTests/CLIParsingTests.swift
git commit -m "Add prbar review commands with the interactive publish picker"
```

---

### Task 17: `prbar respond …`

**Files:**
- Create: `Sources/PRBarCLIKit/RespondCommands.swift`
- Modify: `Sources/PRBarCLIKit/PRBarCLIKit.swift` (`RespondGroup.self`), `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Tests**

```swift
            TestCase("cli parse: respond") {
                try expectEqual(try parsed(["respond", "web#2", "--wait"]), .respondStart(pr: "web#2", wait: true))
                try expectEqual(try parsed(["respond", "show", "web#2"]), .respondShow(pr: "web#2"))
                try expectEqual(try parsed(["respond", "select", "web#2", "1", "2", "--implement"]),
                                .respondSelect(pr: "web#2", items: ["1", "2"], change: RespondSelectionChange(implement: true)))
                try expectEqual(try parsed(["respond", "select", "web#2", "1", "--reply-only", "--reply", "Thanks!"]),
                                .respondSelect(pr: "web#2", items: ["1"], change: RespondSelectionChange(implement: false, reply: true, replyText: "Thanks!")))
                try expectEqual(try parsed(["respond", "select", "web#2", "thread:A", "--skip"]),
                                .respondSelect(pr: "web#2", items: ["thread:A"], change: RespondSelectionChange(implement: false, reply: false)))
                try expectEqual(try parsed(["respond", "select", "web#2", "1", "--implement", "--no-reply", "--plan", "Do X"]),
                                .respondSelect(pr: "web#2", items: ["1"], change: RespondSelectionChange(implement: true, reply: false, fixPlan: "Do X")))
                try expectEqual(try parsed(["respond", "select", "web#2", "--reset"]), .respondReset(pr: "web#2"))
                try expect(rejects(["respond", "select", "web#2", "--reset", "--skip"]))
                try expect(rejects(["respond", "select", "web#2", "1", "--skip", "--reply", "x"]))
                try expect(rejects(["respond", "select", "web#2", "--implement"]))
                try expectEqual(try parsed(["respond", "implement", "web#2"]), .respondImplement(pr: "web#2", wait: false))
                try expectEqual(try parsed(["respond", "test", "web#2", "--wait"]), .respondTest(pr: "web#2", wait: true))
                try expectEqual(try parsed(["respond", "diff", "web#2", "--stat"]), .respondDiff(pr: "web#2"))
                try expectEqual(try parsed(["respond", "push", "web#2", "--yes"]), .respondPush(pr: "web#2", confirmed: true, wait: false))
                try expectEqual(try parsed(["respond", "reply-only", "web#2"], confirmed: false),
                                .respondReplyOnly(pr: "web#2", confirmed: false, wait: false))
                try expectEqual(try parsed(["respond", "cancel", "web#2"]), .respondCancel(pr: "web#2"))
                try expectEqual(try parsed(["respond", "dismiss", "web#2"]), .respondDismiss(pr: "web#2"))
            },
            TestCase("cli: preguntas de push y respuestas (como la ventana)") {
                var info = RespondInfo(prID: "acme/web#2", phase: nil, record: nil, selections: [:], runningTests: false, testCommand: nil)
                info.account = "me"
                info.headRef = "feature/x"
                info.pendingReplies = 2
                info.commits = [CommitDTO(item: "a", status: "committed", sha: "abc", summary: "s")]
                try expectEqual(RespondQuestion.push(info), "Push 1 commit to feature/x and post 2 replies as @me?")
                info.pushed = true
                try expectEqual(RespondQuestion.push(info), "Post 2 pending replies as @me?")
                info.replies = 1
                try expectEqual(RespondQuestion.replyOnly(info), "Post 1 reply to acme/web#2 as @me? Nothing is pushed.")
            },
```

Run: `swift run PRBarTests cli`
Expected: no compila.

- [ ] **Step 2: Implementar `Sources/PRBarCLIKit/RespondCommands.swift`**

```swift
import ArgumentParser
import Foundation
import PRBarCore

struct RespondGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "respond", abstract: "Respond to the feedback on your PRs with Claude.",
        discussion: "prbar respond <pr> analyzes the unresolved comments. Comments are numbered like in the window.",
        subcommands: [RespondStart.self, RespondShow.self, RespondSelect.self, RespondImplement.self, RespondTest.self,
                      RespondDiffCommand.self, RespondPush.self, RespondReplyOnly.self, RespondCancel.self, RespondDismiss.self],
        defaultSubcommand: RespondStart.self)
}

enum RespondRender {
    static func info(_ info: RespondInfo, _ output: Output, full: Bool = false) {
        var header = "\(info.pr) · \(info.runningTests ? "running tests" : info.phase)"
        if let detail = info.detail, info.phase != "failed" { header += " (\(detail))" }
        output.line(output.paint(header, .bold))
        if info.phase == "failed", let detail = info.detail { output.line(output.paint(detail, .red)) }
        if let title = info.title { output.line(title) }
        var pairs: [(String, String)] = []
        if let account = info.account, let head = info.headRef { pairs.append(("Branch", "\(head) as @\(account)")) }
        if let worktree = info.worktree { pairs.append(("Worktree", worktree)) }
        if let log = info.logPath { pairs.append(("Log", log)) }
        Render.pairs(pairs, output)
        guard !info.items.isEmpty else { return }
        output.line()
        output.line("\(info.fixes) fix\(info.fixes == 1 ? "" : "es") · \(info.replies) repl\(info.replies == 1 ? "y" : "ies") in \(info.language ?? "English")")
        output.table(["#", "Fix", "Reply", "Reviewer", "Location", "Claude"], info.items.map { item in
            ["\(item.number)", item.implement ? "✓" : "·", item.postedURL != nil ? "posted" : item.reply ? "✓" : "·",
             item.reviewer, item.location + (item.outdated ? " (outdated)" : ""), Render.truncate(item.assessment, 50)]
        })
        if full {
            for item in info.items {
                output.line()
                output.line(output.paint("#\(item.number) \(item.reviewer) · \(item.location) · \(item.id)", .bold))
                item.thread.forEach { output.line(Render.indent($0)) }
                if let url = item.commentURL { output.line("    \(url.absoluteString)") }
                output.line(output.paint("Claude: \(item.assessment)", .violet))
                if item.implement { output.line("Fix plan: \(item.fixPlan)") }
                if item.reply { output.line("Reply: \(item.replyText.isEmpty ? "(only “Fixed in …”)" : item.replyText)") }
                if let url = item.postedURL { output.line("Posted: \(url.absoluteString)") }
            }
        }
        if !info.commits.isEmpty {
            output.line()
            output.table(["Commit", "Status", "Comment", "Summary"], info.commits.map {
                [String(($0.sha ?? "").prefix(7)), $0.status, $0.item, Render.truncate($0.summary, 60)]
            })
        }
        if let stat = info.diffStat, !stat.isEmpty { output.line(); output.line(stat) }
        if !info.sensitiveChanges.isEmpty {
            output.line(output.paint("Claude changed files that can run code: \(info.sensitiveChanges.joined(separator: ", ")). Review them before running tests or pushing.", .red, .bold))
        }
        if let tests = info.tests {
            output.line(tests.passed ? output.paint("Tests passed (\(tests.command)).", .green)
                                     : output.paint("Tests failed (\(tests.command)). This doesn’t block the push.", .yellow))
            if full, !tests.outputTail.isEmpty { output.line(Render.indent(tests.outputTail)) }
        }
        if let error = info.errorMessage, info.phase != "failed" { output.line(output.paint(error, .red)) }
    }
}

/// Las preguntas de confirmación, con los mismos textos que la ventana (públicas para los tests).
public enum RespondQuestion {
    public static func push(_ info: RespondInfo) -> String {
        let commits = info.commits.filter { $0.status == "committed" && $0.sha != nil }.count
        let pending = info.pendingReplies
        let account = info.account ?? "?"
        let replies = pending == 1 ? "1 reply" : "\(pending) replies"
        if info.pushed { return "Post \(pending == 1 ? "1 pending reply" : "\(pending) pending replies") as @\(account)?" }
        if commits == 0 { return "Post \(replies) as @\(account)?" }
        return "Push \(commits) commit\(commits == 1 ? "" : "s") to \(info.headRef ?? "?") and post \(replies) as @\(account)?"
    }

    public static func replyOnly(_ info: RespondInfo) -> String {
        "Post \(info.replies == 1 ? "1 reply" : "\(info.replies) replies") to \(info.pr) as @\(info.account ?? "?")? Nothing is pushed."
    }
}

struct RespondStart: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Analyze the PR’s unresolved feedback (also: prbar respond <pr>).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the analysis and print it (Ctrl-C cancels it).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondStart(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The analysis, your choices and the fixes.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Also print the threads, plans, replies and test output.") var full = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondShow(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output, full: full) }
}

enum SelectMode: String, EnumerableFlag {
    case implement, replyOnly, skip

    static func help(for value: SelectMode) -> ArgumentHelp? {
        switch value {
        case .implement: "Implement the fix (Reply stays as it is)."
        case .replyOnly: "Only reply, no fix."
        case .skip: "Neither fix nor reply."
        }
    }
}

struct RespondSelect: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "select", abstract: "Choose what to fix and what to reply to.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "Comments: numbers or ids (thread:…).") var items: [String] = []
    @Flag var mode: SelectMode?
    @Flag(help: "Don’t reply.") var noReply = false
    @Option(help: "The reply’s text (turns Reply on).") var reply: String?
    @Option(help: "The fix plan Claude follows.") var plan: String?
    @Flag(help: "Back to Claude’s suggestions for every comment.") var reset = false
    @OptionGroup var global: GlobalOptions

    private var change: RespondSelectionChange {
        var change = RespondSelectionChange(replyText: reply, fixPlan: plan)
        switch mode {
        case .implement?: change.implement = true
        case .replyOnly?: change.implement = false; change.reply = true
        case .skip?: change.implement = false; change.reply = false
        case nil: break
        }
        if noReply { change.reply = false }
        return change
    }

    func validate() throws {
        if reset {
            guard items.isEmpty, mode == nil, !noReply, reply == nil, plan == nil else {
                throw ValidationError("--reset goes alone.")
            }
            return
        }
        guard !items.isEmpty else { throw ValidationError("Name the comments (numbers or ids), or pass --reset.") }
        guard !change.isEmpty else { throw ValidationError("Pass --implement, --reply-only, --skip, --no-reply, --reply or --plan.") }
        if reply != nil && (mode == .skip || noReply) { throw ValidationError("--reply doesn’t go with --skip or --no-reply.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        reset ? .respondReset(pr: pr) : .respondSelect(pr: pr, items: items, change: change)
    }

    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondImplement: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "implement", abstract: "Claude implements the chosen fixes (one commit each, nothing pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the fixes (Ctrl-C cancels).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondImplement(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondTest: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Run the repo’s test command in the worktree (look at `prbar respond diff` first).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait for the tests (Ctrl-C cancels).") var wait = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondTest(pr: pr, wait: wait) }
    var cancelCommand: AppCommand? { wait ? .respondCancel(pr: pr) : nil }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output, full: true) }
}

struct RespondDiffCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "diff", abstract: "The full diff of the fixes (what would be pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Only the summary (files and lines).") var stat = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondDiff(pr: pr) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let diff: RespondDiff = try result.decode()
        if !diff.sensitiveChanges.isEmpty {
            output.line(output.paint("Files that can run code: \(diff.sensitiveChanges.joined(separator: ", "))", .red, .bold))
        }
        guard !stat, let text = diff.diff else { return output.line(diff.diffStat) }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff --git") { output.line(output.paint(line, .bold)) }
            else if line.hasPrefix("@@") { output.line(output.paint(line, .cyan)) }
            else if line.hasPrefix("+") { output.line(output.paint(line, .green)) }
            else if line.hasPrefix("-") { output.line(output.paint(line, .red)) }
            else { output.line(line) }
        }
        if diff.truncated { output.line(output.paint(RespondCopy.diffTruncatedNote, .yellow)) }
    }
}

struct RespondPush: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "push", abstract: "Push the fixes and post the replies (or retry the pending replies).",
        discussion: "Runs your pre-push hooks in PRBar’s worktree. Asks for confirmation; without a terminal it needs --yes.")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until it’s pushed and posted.") var wait = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        let info: RespondInfo = try connection.run(.respondShow(pr: pr)).decode()
        guard info.phase == "readyToPush" || info.phase == "failed" else {
            throw CommandFailure(.invalidState, "\(info.pr) has no fixes ready to push (\(info.phase)).")
        }
        if output.terminal.isInteractive && !output.json {
            if let stat = info.diffStat, !stat.isEmpty { output.line(stat) }
            if !info.sensitiveChanges.isEmpty {
                output.line(output.paint("Claude changed files that can run code: \(info.sensitiveChanges.joined(separator: ", "))", .red, .bold))
            }
            if let tests = info.tests { output.line(tests.passed ? "Tests passed." : output.paint("Tests failed (this doesn’t block the push).", .yellow)) }
        }
        return RespondQuestion.push(info)
    }

    func appCommand(confirmed: Bool) -> AppCommand { .respondPush(pr: pr, confirmed: confirmed, wait: wait) }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondReplyOnly: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reply-only", abstract: "Post only the replies (no fixes, nothing pushed).")
    @Argument(help: prHelp) var pr: String
    @Flag(help: "Wait until they’re posted.") var wait = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        let info: RespondInfo = try connection.run(.respondShow(pr: pr)).decode()
        guard info.phase == "ready" || info.phase == "failed" else {
            throw CommandFailure(.invalidState, "\(info.pr) has no replies ready to post (\(info.phase)).")
        }
        return RespondQuestion.replyOnly(info)
    }

    func appCommand(confirmed: Bool) -> AppCommand { .respondReplyOnly(pr: pr, confirmed: confirmed, wait: wait) }
    func render(_ result: JSONValue, _ output: Output) throws { RespondRender.info(try result.decode(), output) }
}

struct RespondCancel: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "cancel", abstract: "Cancel what’s running (analysis, fixes or tests; not a push).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondCancel(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Canceled.") }
}

struct RespondDismiss: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "dismiss", abstract: "Dismiss the analysis and delete PRBar’s worktree (it stays in History).")
    @Argument(help: prHelp) var pr: String
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .respondDismiss(pr: pr) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Dismissed.") }
}
```

`RespondInfo` tiene propiedades `var` públicas: el test las cambia directamente. `RespondCopy.diffTruncatedNote` ya existe en Core.

Agregar `RespondGroup.self` a los subcomandos de `PRBarCommand`.

- [ ] **Step 3: Correr**

Run: `swift run PRBarTests cli`
Expected: todo pasa.

- [ ] **Step 4: Verificación manual (PR propio con feedback, app corriendo)**

`prbar respond <pr> --wait` → tabla de comentarios; `prbar respond select <pr> 1 --skip` → la casilla cambia en la ventana abierta; `prbar respond implement <pr> --wait`; `prbar respond diff <pr>`; `prbar respond push <pr>` en la terminal muestra el diff stat y pregunta; con `< /dev/null` sale con 4.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCLIKit/RespondCommands.swift Sources/PRBarCLIKit/PRBarCLIKit.swift Sources/PRBarTests/CLIParsingTests.swift
git commit -m "Add prbar respond commands"
```

---

### Task 18: Configuración: `config`, `account`, `repo`, `follow`, `notify`, `claude`, `tools`

**Files:**
- Create: `Sources/PRBarCLIKit/ConfigCommands.swift`
- Modify: `Sources/PRBarCLIKit/PRBarCLIKit.swift`, `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Tests**

```swift
            TestCase("cli parse: config, account, notify y tools") {
                try expectEqual(try parsed(["config", "show"]), .configShow)
                try expectEqual(try parsed(["config", "set", "refresh-interval", "5"]), .setRefreshInterval(minutes: 5))
                try expectEqual(try parsed(["config", "set", "launch-at-login", "on"]), .setLaunchAtLogin(enabled: true))
                try expect(rejects(["config", "set", "launch-at-login", "maybe"]))
                try expect(rejects(["config", "set", "refresh-interval", "x"]))
                try expectEqual(try parsed(["account", "list"]), .accountList)
                try expectEqual(try parsed(["account", "enable", "me"]), .accountSetEnabled(login: "me", enabled: true))
                try expectEqual(try parsed(["account", "disable", "me"]), .accountSetEnabled(login: "me", enabled: false))
                try expectEqual(try parsed(["account", "reload"]), .accountReload)
                try expectEqual(try parsed(["notify", "list"]), .notifyList)
                try expectEqual(try parsed(["notify", "set", "my-feedback", "off"]), .notifySet(kind: .myFeedback, enabled: false))
                try expectEqual(try parsed(["notify", "enable"]), .notifySetEnabled(enabled: true))
                try expectEqual(try parsed(["notify", "disable"]), .notifySetEnabled(enabled: false))
                try expectEqual(try parsed(["tools", "list"]), .toolsList)
                try expectEqual(try parsed(["tools", "reset", "gh"]), .toolsSet(tool: .gh, path: nil))
                try expect(try PRBarCommand.parseAsRoot(["notify", "system-settings"]) is any LocalCommand)
            },
            TestCase("cli parse: repo y follow") {
                try expectEqual(try parsed(["repo", "list", "--account", "me"]), .repoList(account: "me"))
                try expectEqual(try parsed(["repo", "available", "--reload"]), .repoAvailable(account: nil, reload: true))
                try expectEqual(try parsed(["repo", "add", "acme/api"]), .repoAdd(repo: "acme/api", account: nil))
                try expectEqual(try parsed(["repo", "remove", "acme/api"]), .repoRemove(repo: "acme/api", account: nil))
                try expectEqual(try parsed(["repo", "branches", "acme/api", "--reload"]), .repoBranches(repo: "acme/api", account: nil, reload: true))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--path", "none", "--worktrees", "default", "--test-command", "",
                                            "--add-branch", "main", "--add-branch", "dev", "--remove-branch", "old", "--channel", "#eng"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(
                                    localPath: .clear, worktreeDir: .clear, testCommand: .clear,
                                    addBranches: ["main", "dev"], removeBranches: ["old"], channel: .set(value: "#eng"))))
                try expectEqual(try parsed(["repo", "set", "acme/api", "--branches", "main,develop", "--channel", "none"]),
                                .repoSet(repo: "acme/api", account: nil, changes: RepoChanges(baseBranches: ["main", "develop"], channel: .clear)))
                guard case .repoSet(_, _, let changes) = try parsed(["repo", "set", "acme/api", "--path", "~/code/api"]),
                      case .set(let path)? = changes.localPath else { throw TestFailure(description: "sin --path") }
                try expect(path.hasPrefix("/") && path.hasSuffix("/code/api"), path)
                try expect(rejects(["repo", "set", "acme/api"]))
                try expect(try PRBarCommand.parseAsRoot(["repo", "open", "acme/api"]) is any LocalCommand)
                try expectEqual(try parsed(["follow", "list"]), .followList(repo: nil, account: nil))
                try expectEqual(try parsed(["follow", "add", "acme/api", "ana", "@bob"]), .followAdd(repo: "acme/api", users: ["ana", "@bob"], account: nil))
                try expectEqual(try parsed(["follow", "remove", "acme/api", "ana"]), .followRemove(repo: "acme/api", users: ["ana"], account: nil))
                try expectEqual(try parsed(["follow", "suggestions", "acme/api"]), .followSuggestions(repo: "acme/api", account: nil))
            },
            TestCase("cli parse: claude") {
                try expectEqual(try parsed(["claude", "show"]), .claudeShow)
                try expectEqual(try parsed(["claude", "reset"]), .claudeReset)
                try expectEqual(try parsed(["claude", "skills"]), .claudeSkills)
                try expectEqual(try parsed(["claude", "set", "--review-skill", "a:b", "--filter", "off", "--model", "default"]),
                                .claudeSet(changes: ClaudeChanges(reviewSkill: "a:b", filterEnabled: false, model: .clear)))
                try expectEqual(try parsed(["claude", "set", "--model", "sonnet", "--respond-skill", "x"]),
                                .claudeSet(changes: ClaudeChanges(respondSkill: "x", model: .set(value: "sonnet"))))
                try expect(rejects(["claude", "set"]))
            },
```

Run: `swift run PRBarTests cli`
Expected: no compila.

- [ ] **Step 2: Implementar `Sources/PRBarCLIKit/ConfigCommands.swift`**

```swift
import ArgumentParser
import Foundation
import PRBarCore

// MARK: - config

struct ConfigGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "General settings.",
                                                    subcommands: [ConfigShow.self, ConfigSet.self])
}

struct ConfigShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The whole configuration (config.json, no secrets).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .configShow }

    func render(_ result: JSONValue, _ output: Output) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        output.line(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}

enum ConfigKey: String, ExpressibleByArgument, CaseIterable {
    case refreshInterval = "refresh-interval"
    case launchAtLogin = "launch-at-login"
}

struct ConfigSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change a general setting.",
        discussion: "refresh-interval 1|2|5|10 (minutes) · launch-at-login on|off")
    @Argument(help: "The setting.") var key: ConfigKey
    @Argument(help: "Its value.") var value: String
    @OptionGroup var global: GlobalOptions

    func validate() throws { _ = try appCommand(confirmed: false) }

    func appCommand(confirmed: Bool) throws -> AppCommand {
        switch key {
        case .refreshInterval:
            guard let minutes = Int(value) else { throw ValidationError("refresh-interval takes minutes: 1, 2, 5 or 10.") }
            return .setRefreshInterval(minutes: minutes)
        case .launchAtLogin:
            guard let on = OnOff(rawValue: value) else { throw ValidationError("launch-at-login takes on or off.") }
            return .setLaunchAtLogin(enabled: on.isOn)
        }
    }

    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

// MARK: - account

struct AccountGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "account", abstract: "GitHub accounts (from gh).",
                                                    subcommands: [AccountList.self, AccountEnable.self, AccountDisable.self, AccountReload.self])
}

enum AccountRender {
    static func list(_ result: JSONValue, _ output: Output) throws {
        let accounts: [AccountInfo] = try result.decode()
        guard !accounts.isEmpty else {
            return output.line("No GitHub accounts in gh. Run `gh auth login --hostname github.com`, then `prbar account reload`.")
        }
        output.table(["Login", "Enabled", "gh"], accounts.map {
            [$0.login, Render.onOff($0.enabled), $0.inGh ? ($0.active ? "active" : "signed in") : "not signed in"]
        })
    }
}

struct AccountList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Accounts signed in to gh and whether PRBar uses them.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountList }
    func render(_ result: JSONValue, _ output: Output) throws { try AccountRender.list(result, output) }
}

struct AccountEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Use this account.")
    @Argument var login: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountSetEnabled(login: login, enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Enabled \(login).") }
}

struct AccountDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop using this account.")
    @Argument var login: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountSetEnabled(login: login, enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Disabled \(login).") }
}

struct AccountReload: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reload", abstract: "Read the accounts from gh again (Reload Accounts).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .accountReload }
    func render(_ result: JSONValue, _ output: Output) throws { try AccountRender.list(result, output) }
}

// MARK: - repo

struct RepoGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repo", abstract: "The repos PRBar follows (Settings › Repos).",
        subcommands: [RepoList.self, RepoAvailable.self, RepoAdd.self, RepoRemove.self, RepoSet.self, RepoBranches.self, RepoOpen.self])
}

enum RepoRender {
    static func one(_ repo: RepoInfo, _ output: Output) {
        output.line(output.paint("\(repo.id) (@\(repo.account))", .bold))
        Render.pairs([
            ("Base branches", repo.baseBranches.isEmpty ? "default branch" : repo.baseBranches.joined(separator: ", ")),
            ("People", repo.watchedUsers.isEmpty ? "none" : repo.watchedUsers.joined(separator: ", ")),
            ("Local folder", repo.localPath ?? "none (reviews use only the diff)"),
            ("Worktrees", repo.worktreeDir ?? "default (next to the local folder)"),
            ("Test command", repo.testCommand ?? "none"),
            ("Slack channel", repo.slackChannel ?? "no announcements"),
        ], output)
    }
}

struct RepoList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The configured repos.")
    @Option(help: "Only this account.") var account: String?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .repoList(account: account) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let repos: [RepoInfo] = try result.decode()
        guard !repos.isEmpty else { return output.line("No repos yet. Add one with `prbar repo add owner/repo`.") }
        output.table(["Repo", "Account", "Branches", "People", "Local folder", "Channel"], repos.map {
            [$0.id, $0.account, $0.baseBranches.isEmpty ? "default" : $0.baseBranches.joined(separator: ","),
             "\($0.watchedUsers.count)", $0.localPath ?? "—", $0.slackChannel ?? "—"]
        })
    }
}

struct RepoAvailable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "available", abstract: "Your GitHub repos that can be added (Add Repo…).")
    @Option(help: "The account (if several are enabled).") var account: String?
    @Flag(help: "Ask GitHub again.") var reload = false
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .repoAvailable(account: account, reload: reload) }
    func render(_ result: JSONValue, _ output: Output) throws { (try result.decode() as [String]).forEach { output.line($0) } }
}

struct RepoAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Follow a repo.")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account (if several are enabled).") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .repoAdd(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { RepoRender.one(try result.decode(), output) }
}

struct RepoRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Stop following a repo (its branches, people, folder and channel are lost).")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    var confirmationPolicy: ConfirmationPolicy { .interactiveOnly }
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        "Remove \(repo)? Its PRs will stop showing up, and its branches, people, local folder, and Slack channel will be lost."
    }
    func appCommand(confirmed: Bool) -> AppCommand { .repoRemove(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Removed \(repo).") }
}

struct RepoSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change a repo’s settings.")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @Option(help: "Local folder (a clone of the repo), or none.") var path: String?
    @Option(help: "Folder for Respond’s worktrees, or default.") var worktrees: String?
    @Option(help: "Test command run on request after the fixes (\"\" = none).") var testCommand: String?
    @Option(help: "Base branches, comma-separated (\"\" = the default branch).") var branches: String?
    @Option(help: "Add a base branch.") var addBranch: [String] = []
    @Option(help: "Remove a base branch.") var removeBranch: [String] = []
    @Option(help: "Slack channel: #name, its ID, or none.") var channel: String?
    @OptionGroup var global: GlobalOptions

    var changes: RepoChanges {
        RepoChanges(
            localPath: path.map { $0 == "none" ? .clear : .set(value: absolutePath($0)) },
            worktreeDir: worktrees.map { $0 == "default" ? .clear : .set(value: absolutePath($0)) },
            testCommand: testCommand.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? .clear : .set(value: $0) },
            baseBranches: branches.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } },
            addBranches: addBranch, removeBranches: removeBranch,
            channel: channel.map { $0 == "none" ? .clear : .set(value: $0) }
        )
    }

    func validate() throws {
        guard !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar repo set --help`.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .repoSet(repo: repo, account: account, changes: changes) }
    func render(_ result: JSONValue, _ output: Output) throws { RepoRender.one(try result.decode(), output) }
}

struct RepoBranches: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "branches", abstract: "The repo’s branches and which are base branches.")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @Flag(help: "Ask GitHub again.") var reload = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .repoBranches(repo: repo, account: account, reload: reload) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: BranchesInfo = try result.decode()
        for branch in info.branches {
            let mark = info.selected.contains(branch) ? "✓" : " "
            output.line("\(mark) \(branch)\(branch == info.defaultBranch ? " (default)" : "")")
        }
    }
}

struct RepoOpen: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open the repo on GitHub.")
    @Argument(help: "owner/repo") var repo: String

    func run() throws {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2, parts.allSatisfy(PRReference.isValidName) else {
            throw ValidationError("“\(repo)” isn’t a repo: use owner/repo.")
        }
        try LocalOpen.open("https://github.com/\(repo)")
    }
}

// MARK: - follow

struct FollowGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "follow", abstract: "People whose PRs show up in “To Review”, per repo.",
        subcommands: [FollowList.self, FollowAdd.self, FollowRemove.self, FollowSuggestions.self])
}

enum FollowRender {
    static func show(_ follows: [FollowInfo], _ output: Output) {
        for follow in follows {
            output.line("\(output.paint(follow.repo, .bold)): \(follow.users.isEmpty ? "nobody" : follow.users.joined(separator: ", "))")
        }
    }
}

struct FollowList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Who you follow in each repo.")
    @Argument(help: "owner/repo (default: all)") var repo: String?
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followList(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { FollowRender.show(try result.decode(), output) }
}

struct FollowAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Follow people in a repo (checked on GitHub).")
    @Argument(help: "owner/repo") var repo: String
    @Argument(help: "GitHub logins.") var users: [String]
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followAdd(repo: repo, users: users, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { FollowRender.show([try result.decode()], output) }
}

struct FollowRemove: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Unfollow people in a repo.")
    @Argument(help: "owner/repo") var repo: String
    @Argument(help: "GitHub logins.") var users: [String]
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followRemove(repo: repo, users: users, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws { FollowRender.show([try result.decode()], output) }
}

struct FollowSuggestions: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "suggestions", abstract: "People you could follow (like Add User…).")
    @Argument(help: "owner/repo") var repo: String
    @Option(help: "The account.") var account: String?
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .followSuggestions(repo: repo, account: account) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let users: [UserSuggestionInfo] = try result.decode()
        output.table(["Login", "Name", "Open PRs"], users.map { [$0.login, $0.name ?? "", "\($0.openPRs)"] })
    }
}

// MARK: - notify

struct NotifyGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify", abstract: "Notifications (Settings › General).",
        subcommands: [NotifyList.self, NotifySet.self, NotifyEnable.self, NotifyDisable.self, NotifySystemSettings.self])
}

struct NotifyList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Which notifications are on.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifyList }
    func render(_ result: JSONValue, _ output: Output) throws {
        let info: NotificationsInfo = try result.decode()
        output.line("Notifications: \(Render.onOff(info.enabled))")
        output.table(["Kind", "On"], NotificationSettingName.allCases.map { [$0.rawValue, Render.onOff(info.kinds[$0.rawValue] ?? false)] })
        if info.deniedInMacOS {
            output.line(output.paint("Notifications for PRBar are turned off in macOS: `prbar notify system-settings`.", .yellow))
        }
    }
}

struct NotifySet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Turn one kind of notification on or off.")
    @Argument(help: "new-to-review, reviewed-updated, my-feedback, review-finished or approved-or-ci.") var kind: NotificationSettingName
    @Argument var value: OnOff
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifySet(kind: kind, enabled: value.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct NotifyEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Show notifications.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifySetEnabled(enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Notifications on.") }
}

struct NotifyDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Don’t show notifications.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .notifySetEnabled(enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Notifications off.") }
}

struct NotifySystemSettings: LocalCommand {
    static let configuration = CommandConfiguration(commandName: "system-settings", abstract: "Open macOS’s notification settings.")
    func run() throws { try LocalOpen.open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
}

// MARK: - claude

struct ClaudeGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude", abstract: "Skills and model of the reviews and responses (Settings › Claude).",
        subcommands: [ClaudeShow.self, ClaudeSet.self, ClaudeReset.self, ClaudeSkillsCommand.self])
}

enum ClaudeRender {
    static func settings(_ result: JSONValue, _ output: Output) throws {
        let settings: ClaudeSettings = try result.decode()
        Render.pairs([
            ("Review skill", settings.effectiveReviewSkill),
            ("Filter findings", Render.onOff(settings.filterEnabled)),
            ("Filter skill", settings.effectiveFilterSkill),
            ("Respond skill", settings.effectiveRespondSkill),
            ("Model", settings.model?.rawValue ?? "default"),
        ], output)
    }
}

struct ClaudeShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "The current Claude settings.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudeShow }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change the skills or the model.")
    @Option(help: "plugin:skill or skill.") var reviewSkill: String?
    @Option(help: "on or off.") var filter: OnOff?
    @Option(help: "plugin:skill or skill.") var filterSkill: String?
    @Option(help: "plugin:skill or skill.") var respondSkill: String?
    @Option(help: "opus, sonnet, haiku or default.") var model: String?
    @OptionGroup var global: GlobalOptions

    var changes: ClaudeChanges {
        ClaudeChanges(reviewSkill: reviewSkill, filterEnabled: filter?.isOn, filterSkill: filterSkill, respondSkill: respondSkill,
                      model: model.map { $0.lowercased() == "default" ? .clear : .set(value: $0) })
    }

    func validate() throws {
        guard !changes.isEmpty else { throw ValidationError("Nothing to change. See `prbar claude set --help`.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .claudeSet(changes: changes) }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Back to the default skills and model.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudeReset }
    func render(_ result: JSONValue, _ output: Output) throws { try ClaudeRender.settings(result, output) }
}

struct ClaudeSkillsCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "skills", abstract: "The installed skills PRBar can use.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .claudeSkills }
    func render(_ result: JSONValue, _ output: Output) throws {
        let skills: [SkillInfo] = try result.decode()
        output.table(["Skill", "Source", "Available", "Description"], skills.map {
            [$0.id, $0.source, $0.available ? "yes" : "no", Render.truncate($0.reason ?? $0.description ?? "", 60)]
        })
    }
}

// MARK: - tools

struct ToolsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tools", abstract: "Where gh, git and claude are (Settings › General).",
                                                    subcommands: [ToolsList.self, ToolsSet.self, ToolsReset.self])
}

enum ToolsRender {
    static func list(_ result: JSONValue, _ output: Output) throws {
        let tools: [ToolInfo] = try result.decode()
        output.table(["Tool", "Path", "Source"], tools.map { [$0.name, $0.path ?? "not found", $0.custom ? "custom" : "automatic"] })
    }
}

struct ToolsList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The paths PRBar uses.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .toolsList }
    func render(_ result: JSONValue, _ output: Output) throws { try ToolsRender.list(result, output) }
}

struct ToolsSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Use this copy of a tool (Choose…).")
    @Argument(help: "gh, git or claude.") var tool: ToolName
    @Argument(help: "The executable.") var path: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .toolsSet(tool: tool, path: absolutePath(path)) }
    func render(_ result: JSONValue, _ output: Output) throws { try ToolsRender.list(result, output) }
}

struct ToolsReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Find the tool automatically again (Use Automatic).")
    @Argument(help: "gh, git or claude.") var tool: ToolName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .toolsSet(tool: tool, path: nil) }
    func render(_ result: JSONValue, _ output: Output) throws { try ToolsRender.list(result, output) }
}
```

Agregar a los subcomandos de `PRBarCommand`: `ConfigGroup.self, AccountGroup.self, RepoGroup.self, FollowGroup.self, NotifyGroup.self, ClaudeGroup.self, ToolsGroup.self`.

- [ ] **Step 3: Correr**

Run: `swift run PRBarTests cli`
Expected: todo pasa.

- [ ] **Step 4: Verificación manual**

Con la app corriendo y Settings abierta: `prbar config set refresh-interval 5` (el selector cambia), `prbar repo set <repo> --add-branch develop` (aparece el chip), `prbar follow add <repo> <login>`, `prbar claude set --filter off` (el switch se apaga), `prbar tools list`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCLIKit/ConfigCommands.swift Sources/PRBarCLIKit/PRBarCLIKit.swift Sources/PRBarTests/CLIParsingTests.swift
git commit -m "Add config, account, repo, follow, notify, claude and tools commands"
```

---

### Task 19: `prbar slack …`

**Files:**
- Create: `Sources/PRBarCLIKit/SlackCommands.swift`
- Modify: `Sources/PRBarCLIKit/PRBarCLIKit.swift` (`SlackGroup.self`), `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Tests**

```swift
            TestCase("cli parse: slack") {
                try expectEqual(try parsed(["slack", "show"]), .slackShow)
                try expectEqual(try parsed(["slack", "enable"]), .slackSetEnabled(enabled: true))
                try expectEqual(try parsed(["slack", "disable"]), .slackSetEnabled(enabled: false))
                try expectEqual(try parsed(["slack", "provider", "connector"]), .slackSetProvider(provider: .claudeConnector))
                try expectEqual(try parsed(["slack", "provider", "token"]), .slackSetProvider(provider: .userToken))
                SlackTokenInput.read = { _ in "xoxp-test" }
                try expectEqual(try parsed(["slack", "token", "set", "--stdin"]), .slackTokenSet(token: "xoxp-test"))
                try expectEqual(try parsed(["slack", "token", "clear"]), .slackTokenClear)
                try expectEqual(try parsed(["slack", "set", "react-start", "off"]), .slackSetToggle(toggle: .reactStart, enabled: false))
                try expectEqual(try parsed(["slack", "set", "rounds", "on"]), .slackSetToggle(toggle: .rounds, enabled: true))
                try expectEqual(try parsed(["slack", "emoji", "eyes", "eyes"]), .slackSetEmoji(kind: .eyes, name: "eyes"))
                try expectEqual(try parsed(["slack", "search-days", "30"]), .slackSetSearchDays(days: 30))
                try expectEqual(try parsed(["slack", "template", "list"]), .slackTemplateList)
                try expectEqual(try parsed(["slack", "template", "show", "new-pr"]), .slackTemplateList)
                try expectEqual(try parsed(["slack", "template", "set", "round", "commented x{n}"]),
                                .slackTemplateSet(template: .round, text: "commented x{n}"))
                try expectEqual(try parsed(["slack", "template", "reset", "update"]), .slackTemplateReset(template: .update))
                try expectEqual(try parsed(["slack", "check"]), .slackCheck)
                try expectEqual(try parsed(["slack", "test", "--yes"]), .slackSelfTest(confirmed: true))
                try expectEqual(try parsed(["slack", "channels", "--reload"]), .slackChannels(reload: true))
                try expect(rejects(["slack", "provider", "bot"]))
            },
```

Run: `swift run PRBarTests cli`
Expected: no compila.

- [ ] **Step 2: Implementar `Sources/PRBarCLIKit/SlackCommands.swift`**

```swift
import ArgumentParser
import Foundation
import PRBarCore

struct SlackGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack", abstract: "Slack announcements and reactions (Settings › Slack).",
        subcommands: [SlackShow.self, SlackEnable.self, SlackDisable.self, SlackProviderCommand.self, SlackTokenGroup.self,
                      SlackSet.self, SlackEmoji.self, SlackSearchDays.self, SlackTemplateGroup.self, SlackCheck.self,
                      SlackTest.self, SlackChannels.self])
}

struct SlackShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Slack’s settings and connection (never the token).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackShow }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: SlackInfo = try result.decode()
        Render.pairs([
            ("Slack", Render.onOff(info.enabled)),
            ("Connect with", info.provider == .claudeConnector ? "Claude’s Slack connector" : "Slack user token"),
            ("Connected", info.connected ? "yes" : "no"),
            ("Token saved", info.hasToken ? "yes" : "no"),
            ("Search days", "\(info.searchDays)"),
        ], output)
        output.table(["Toggle", "On"], SlackToggleName.allCases.map { [$0.rawValue, Render.onOff(info.toggles[$0.rawValue] ?? false)] })
        output.table(["Emoji", "Name"], SlackEmojiKind.allCases.map { [$0.rawValue, info.emojis[$0.rawValue] ?? ""] })
        if info.needsUserToken { output.line(output.paint("PRBar now posts as you: run `prbar slack token set`.", .red)) }
        for issue in info.issues { output.line(output.paint("! " + issue, .red)) }
    }
}

struct SlackEnable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Use Slack.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetEnabled(enabled: true) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Slack on.") }
}

struct SlackDisable: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop using Slack.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetEnabled(enabled: false) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Slack off.") }
}

enum ProviderName: String, ExpressibleByArgument, CaseIterable {
    case connector, token

    var provider: SlackProvider { self == .connector ? .claudeConnector : .userToken }
}

struct SlackProviderCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "provider", abstract: "Connect with Claude’s Slack connector or a user token.")
    @Argument(help: "connector or token.") var provider: ProviderName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetProvider(provider: provider.provider) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackTokenGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "token", abstract: "The Slack user token (Keychain).",
                                                    subcommands: [SlackTokenSet.self, SlackTokenClear.self])
}

/// Cómo `prbar slack token set` lee el token (público para que los tests lo reemplacen). `true` = de stdin.
public enum SlackTokenInput {
    nonisolated(unsafe) public static var read: (Bool) throws -> String = { fromStdin in
        let raw: String?
        if fromStdin {
            raw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else if isatty(STDIN_FILENO) == 1 {
            raw = Prompt.secret("Slack user token (xoxp-…): ")
        } else {
            throw CommandFailure(.invalidUsage, "Pass the token on stdin with --stdin.")
        }
        guard let token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw CommandFailure(.invalidUsage, "No token.")
        }
        return token
    }

}

struct SlackTokenSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Save a User OAuth Token (xoxp-…) and test it (Save and Test).",
        discussion: "Asks for it without echo, or reads it from stdin with --stdin. It never goes on the command line.")
    @Flag(help: "Read the token from stdin.") var stdin = false
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) throws -> AppCommand { .slackTokenSet(token: try SlackTokenInput.read(stdin)) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let check: SlackCheckInfo = try result.decode()
        output.line("Saved. Connected as @\(check.user) on \(check.team).")
    }
}

struct SlackTokenClear: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "clear", abstract: "Delete the token from Keychain (Delete Token…).")
    @OptionGroup var global: GlobalOptions
    var confirmationPolicy: ConfirmationPolicy { .interactiveOnly }
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        "Delete the Slack token? PRBar stops posting in Slack until you save a new one."
    }
    func appCommand(confirmed: Bool) -> AppCommand { .slackTokenClear }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Token deleted.") }
}

struct SlackSet: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Turn an announcement or reaction on or off.",
        discussion: "announce, updated, react-start (👀), react-comment (💬), rounds (commented xN), react-approve")
    @Argument var toggle: SlackToggleName
    @Argument var value: OnOff
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetToggle(toggle: toggle, enabled: value.isOn) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackEmoji: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "emoji", abstract: "The emoji of a reaction (name without colons).")
    @Argument(help: "eyes, comment or approved.") var kind: SlackEmojiKind
    @Argument(help: "The emoji’s name in your workspace.") var name: String
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetEmoji(kind: kind, name: name) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackSearchDays: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "search-days", abstract: "How many days back to look for the PR’s message (7–90).")
    @Argument var days: Int
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackSetSearchDays(days: days) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackTemplateGroup: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template", abstract: "Message templates (new-pr, update, round).",
                                                    subcommands: [SlackTemplateList.self, SlackTemplateShow.self, SlackTemplateSet.self, SlackTemplateReset.self])
}

struct SlackTemplateList: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The three templates.")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateList }
    func render(_ result: JSONValue, _ output: Output) throws {
        let templates: [TemplateInfo] = try result.decode()
        output.table(["Name", "Text", "Default"], templates.map { [$0.name, Render.truncate($0.text, 60), $0.isDefault ? "yes" : "no"] })
    }
}

struct SlackTemplateShow: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One template and its variables.")
    @Argument var name: SlackTemplateName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateList }
    func render(_ result: JSONValue, _ output: Output) throws {
        let templates: [TemplateInfo] = try result.decode()
        guard let template = templates.first(where: { $0.name == name.rawValue }) else { return }
        output.line(template.text)
        output.line(output.paint("Variables: \(template.variables.joined(separator: " ")) · default: \(template.defaultText)", .dim))
    }
}

struct SlackTemplateSet: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change a template.")
    @Argument var name: SlackTemplateName
    @Argument(help: "The text (or --editor).") var text: String?
    @Flag(help: "Edit it in $EDITOR.") var editor = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard (text != nil) != editor else { throw ValidationError("Pass the text or --editor.") }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard editor else { return }
        let templates: [TemplateInfo] = try connection.run(.slackTemplateList).decode()
        text = try Editor.edit(templates.first { $0.name == name.rawValue }?.text ?? "", suffix: ".txt")
            .trimmingCharacters(in: .newlines)
    }

    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateSet(template: name, text: text ?? "") }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Saved.") }
}

struct SlackTemplateReset: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "reset", abstract: "Back to the default template.")
    @Argument var name: SlackTemplateName
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackTemplateReset(template: name) }
    func render(_ result: JSONValue, _ output: Output) throws { output.line("Reset.") }
}

struct SlackCheck: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "check", abstract: "Test the connection (Test Connection).")
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackCheck }
    func render(_ result: JSONValue, _ output: Output) throws {
        let check: SlackCheckInfo = try result.decode()
        output.line(check.provider == .claudeConnector ? "Connected as @\(check.user) via Claude"
                                                       : "Connected as @\(check.user) on \(check.team)")
    }
}

struct SlackTest: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "test", abstract: "Send a test message to your own DM (Send Test to My DM…).",
        discussion: "Posts one message, reacts, replies in its thread and reads it back. Needs --yes without a terminal.")
    @OptionGroup var global: GlobalOptions
    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? { "Send a test to your Slack DM?" }
    func appCommand(confirmed: Bool) -> AppCommand { .slackSelfTest(confirmed: confirmed) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let steps: [SelfTestStepInfo] = try result.decode()
        for step in steps {
            let mark = step.status == "ok" ? output.paint("✓", .green) : step.status == "failed" ? output.paint("✗", .red) : "–"
            output.line("\(mark) \(step.title): \(step.detail)")
        }
    }
}

struct SlackChannels: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "channels", abstract: "The channels you can pick for a repo.")
    @Flag(help: "Ask Slack again (Reload Channels).") var reload = false
    @OptionGroup var global: GlobalOptions
    func appCommand(confirmed: Bool) -> AppCommand { .slackChannels(reload: reload) }
    func render(_ result: JSONValue, _ output: Output) throws {
        let channels: [ChannelInfo] = try result.decode()
        output.table(["Channel", "ID", "Private", "Member"], channels.map {
            ["#\($0.name)", $0.id, $0.isPrivate ? "yes" : "no", $0.isMember ? "yes" : "no"]
        })
    }
}
```

`nonisolated(unsafe) static var`: si el compilador en modo Swift 5 no lo acepta, quitar `nonisolated(unsafe)`.

Agregar `SlackGroup.self` a los subcomandos de `PRBarCommand`.

- [ ] **Step 3: Correr**

Run: `swift run PRBarTests cli`
Expected: todo pasa.

- [ ] **Step 4: Verificación manual**

`prbar slack show`, `prbar slack set rounds off` (el switch se apaga en Settings › Slack), `echo xoxp-… | prbar slack token set --stdin` con un token de prueba, `prbar slack test` (pregunta), `prbar slack test < /dev/null` → exit 4.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCLIKit/SlackCommands.swift Sources/PRBarCLIKit/PRBarCLIKit.swift Sources/PRBarTests/CLIParsingTests.swift
git commit -m "Add prbar slack commands"
```

---

### Task 20: `CLIRouter` y el test de paridad `AppCommand` ↔ CLI

La tabla dice qué casos de `AppCommand` produce cada comando de la CLI, con ejemplos que el test parsea de verdad. El test falla si (1) un caso de `AppCommand.Name` no lo produce ningún comando, (2) un comando de la tabla no produce lo que dice, o (3) un subcomando de `PRBarCommand` no está en la tabla (o la tabla nombra uno que no existe).

**Files:**
- Create: `Sources/PRBarCLIKit/CLIRouter.swift`, `Sources/PRBarTests/CLIParityTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ CLIParityTests.cases`)

- [ ] **Step 1: El test**

```swift
import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

enum CLIParityTests {
    static let cases: [TestCase] = [
        TestCase("paridad: cada AppCommand lo produce algún comando de la CLI") {
            let produced = Set(CLIRouter.commands.flatMap(\.produces))
            let missing = AppCommand.Name.allCases.filter { !produced.contains($0) }
            try expect(missing.isEmpty, "Sin comando de CLI: \(missing.map(\.rawValue))")
        },
        TestCase("paridad: los ejemplos de la tabla producen lo que dicen") {
            SlackTokenInput.read = { _ in "xoxp-test" }
            for spec in CLIRouter.commands {
                try expect(!spec.samples.isEmpty, "\(spec.path) sin ejemplos")
                var names: Set<AppCommand.Name> = []
                for sample in spec.samples {
                    let command = try PRBarCommand.parseAsRoot(sample)
                    if spec.produces.isEmpty {
                        try expect(command is any LocalCommand, "\(sample) debería ser local")
                        continue
                    }
                    guard let remote = command as? any RemoteCommand else {
                        throw TestFailure(description: "\(sample) no es un comando remoto")
                    }
                    names.insert(try remote.appCommand(confirmed: true).name)
                }
                if !spec.produces.isEmpty {
                    try expectEqual(names, Set(spec.produces))
                }
            }
        },
        TestCase("paridad: la tabla tiene exactamente los subcomandos de prbar") {
            let leaves = Set(CLIRouter.leafPaths())
            let table = Set(CLIRouter.commands.map(\.path))
            try expect(leaves.subtracting(table).isEmpty, "Comandos sin entrada en CLIRouter: \(leaves.subtracting(table).sorted())")
            try expect(table.subtracting(leaves).isEmpty, "Entradas de CLIRouter que no existen: \(table.subtracting(leaves).sorted())")
        },
    ]
}
```

Run: `swift run PRBarTests paridad`
Expected: no compila (`cannot find 'CLIRouter'`).

- [ ] **Step 2: Implementar `Sources/PRBarCLIKit/CLIRouter.swift`**

```swift
import ArgumentParser
import PRBarCore

/// Un comando de la CLI (su ruta, p. ej. `review publish`), qué `AppCommand` produce (vacío = local, no necesita la
/// app) y ejemplos de argumentos que el test de paridad parsea.
public struct CLICommandSpec: Sendable {
    public let path: String
    public let produces: [AppCommand.Name]
    public let samples: [[String]]

    init(_ path: String, _ produces: [AppCommand.Name], _ samples: [String]...) {
        self.path = path
        self.produces = produces
        self.samples = samples
    }
}

/// La tabla de la paridad (spec C.7). Agregar un caso a `AppCommand` obliga a agregar acá el comando que lo produce;
/// agregar un subcomando obliga a agregarlo acá.
public enum CLIRouter {
    public static let commands: [CLICommandSpec] = [
        // Estado, historial, ventanas y app
        .init("status", [.status], ["status"]),
        .init("prs", [.listPRs], ["prs", "--list", "mine"]),
        .init("refresh", [.refresh], ["refresh"]),
        .init("open", [.open, .resolvePR], ["open", "api#1", "--posted"], ["open", "api#1", "--copy"]),
        .init("history list", [.history], ["history", "--kind", "respond"], ["history", "list"]),
        .init("history show", [.historyShow], ["history", "show", "1a2b3c4d"]),
        .init("history reopen", [.historyReopen], ["history", "reopen", "1a2b3c4d"]),
        .init("app start", [], ["app", "start"]),
        .init("app quit", [.quit], ["app", "quit"]),
        .init("app settings", [.openSettings], ["app", "settings", "claude"]),
        .init("app history", [.openHistory], ["app", "history"]),
        .init("app logs", [], ["app", "logs", "--slack"]),
        .init("version", [], ["version"]),
        .init("doctor", [], ["doctor"]),
        .init("completion", [], ["completion", "fish"]),
        // Review
        .init("review start", [.reviewStart], ["review", "api#1", "--wait"]),
        .init("review show", [.reviewShow], ["review", "show", "api#1"]),
        .init("review edit", [.reviewEdit], ["review", "edit", "api#1", "1", "--title", "T"]),
        .init("review include", [.reviewSetIncluded], ["review", "include", "api#1", "1"]),
        .init("review exclude", [.reviewSetIncluded], ["review", "exclude", "api#1", "--all"]),
        .init("review comment", [.reviewSetComment], ["review", "comment", "api#1", "--text", "LGTM"]),
        .init("review publish", [.reviewPublish], ["review", "publish", "api#1", "--comment", "--yes"]),
        .init("review cancel", [.reviewCancel], ["review", "cancel", "api#1"]),
        .init("review dismiss", [.reviewDismiss], ["review", "dismiss", "api#1"]),
        // Respond
        .init("respond start", [.respondStart], ["respond", "web#2"]),
        .init("respond show", [.respondShow], ["respond", "show", "web#2"]),
        .init("respond select", [.respondSelect, .respondReset],
              ["respond", "select", "web#2", "1", "--skip"], ["respond", "select", "web#2", "--reset"]),
        .init("respond implement", [.respondImplement], ["respond", "implement", "web#2"]),
        .init("respond test", [.respondTest], ["respond", "test", "web#2"]),
        .init("respond diff", [.respondDiff], ["respond", "diff", "web#2"]),
        .init("respond push", [.respondPush], ["respond", "push", "web#2", "--yes"]),
        .init("respond reply-only", [.respondReplyOnly], ["respond", "reply-only", "web#2", "--yes"]),
        .init("respond cancel", [.respondCancel], ["respond", "cancel", "web#2"]),
        .init("respond dismiss", [.respondDismiss], ["respond", "dismiss", "web#2"]),
        // Configuración
        .init("config show", [.configShow], ["config", "show"]),
        .init("config set", [.setRefreshInterval, .setLaunchAtLogin],
              ["config", "set", "refresh-interval", "2"], ["config", "set", "launch-at-login", "off"]),
        .init("account list", [.accountList], ["account", "list"]),
        .init("account enable", [.accountSetEnabled], ["account", "enable", "me"]),
        .init("account disable", [.accountSetEnabled], ["account", "disable", "me"]),
        .init("account reload", [.accountReload], ["account", "reload"]),
        .init("repo list", [.repoList], ["repo", "list"]),
        .init("repo available", [.repoAvailable], ["repo", "available"]),
        .init("repo add", [.repoAdd], ["repo", "add", "acme/api"]),
        .init("repo remove", [.repoRemove], ["repo", "remove", "acme/api"]),
        .init("repo set", [.repoSet], ["repo", "set", "acme/api", "--test-command", "make test"]),
        .init("repo branches", [.repoBranches], ["repo", "branches", "acme/api"]),
        .init("repo open", [], ["repo", "open", "acme/api"]),
        .init("follow list", [.followList], ["follow", "list"]),
        .init("follow add", [.followAdd], ["follow", "add", "acme/api", "ana"]),
        .init("follow remove", [.followRemove], ["follow", "remove", "acme/api", "ana"]),
        .init("follow suggestions", [.followSuggestions], ["follow", "suggestions", "acme/api"]),
        .init("notify list", [.notifyList], ["notify", "list"]),
        .init("notify set", [.notifySet], ["notify", "set", "review-finished", "off"]),
        .init("notify enable", [.notifySetEnabled], ["notify", "enable"]),
        .init("notify disable", [.notifySetEnabled], ["notify", "disable"]),
        .init("notify system-settings", [], ["notify", "system-settings"]),
        .init("claude show", [.claudeShow], ["claude", "show"]),
        .init("claude set", [.claudeSet], ["claude", "set", "--filter", "on"]),
        .init("claude reset", [.claudeReset], ["claude", "reset"]),
        .init("claude skills", [.claudeSkills], ["claude", "skills"]),
        .init("tools list", [.toolsList], ["tools", "list"]),
        .init("tools set", [.toolsSet], ["tools", "set", "git", "/usr/bin/git"]),
        .init("tools reset", [.toolsSet], ["tools", "reset", "git"]),
        // Slack
        .init("slack show", [.slackShow], ["slack", "show"]),
        .init("slack enable", [.slackSetEnabled], ["slack", "enable"]),
        .init("slack disable", [.slackSetEnabled], ["slack", "disable"]),
        .init("slack provider", [.slackSetProvider], ["slack", "provider", "token"]),
        .init("slack token set", [.slackTokenSet], ["slack", "token", "set", "--stdin"]),
        .init("slack token clear", [.slackTokenClear], ["slack", "token", "clear"]),
        .init("slack set", [.slackSetToggle], ["slack", "set", "announce", "off"]),
        .init("slack emoji", [.slackSetEmoji], ["slack", "emoji", "approved", "white_check_mark"]),
        .init("slack search-days", [.slackSetSearchDays], ["slack", "search-days", "14"]),
        .init("slack template list", [.slackTemplateList], ["slack", "template", "list"]),
        .init("slack template show", [.slackTemplateList], ["slack", "template", "show", "round"]),
        .init("slack template set", [.slackTemplateSet], ["slack", "template", "set", "new-pr", "{link}"]),
        .init("slack template reset", [.slackTemplateReset], ["slack", "template", "reset", "new-pr"]),
        .init("slack check", [.slackCheck], ["slack", "check"]),
        .init("slack test", [.slackSelfTest], ["slack", "test", "--yes"]),
        .init("slack channels", [.slackChannels], ["slack", "channels"]),
    ]

    /// Todas las rutas que existen (para el inventario de la UI, Task 21).
    public static var allPaths: Set<String> { Set(commands.map(\.path)) }

    /// Las rutas de los subcomandos hoja de `PRBarCommand` (los que corren algo).
    public static func leafPaths() -> [String] {
        func walk(_ type: ParsableCommand.Type, prefix: [String]) -> [String] {
            let subcommands = type.configuration.subcommands
            guard !subcommands.isEmpty else { return [prefix.joined(separator: " ")] }
            return subcommands.flatMap { walk($0, prefix: prefix + [$0.configuration.commandName ?? "?"]) }
        }
        return PRBarCommand.configuration.subcommands.flatMap { walk($0, prefix: [$0.configuration.commandName ?? "?"]) }
    }
}
```

- [ ] **Step 3: Correr**

Run: `swift run PRBarTests paridad`
Expected: `3/3 passed`. Si falla, el mensaje dice qué falta: agregar la entrada (o el comando) que corresponda, nunca sacar un caso de `AppCommand`.

- [ ] **Step 4: Commit**

```bash
git add Sources/PRBarCLIKit/CLIRouter.swift Sources/PRBarTests/CLIParityTests.swift Sources/PRBarTests/main.swift
git commit -m "Add CLIRouter and the AppCommand-to-CLI parity test"
```

---

### Task 21: Inventario de acciones de la UI (paridad UI → CLI)

Un escáner recorre `Sources/PRBar/**/*.swift` (salvo `Snapshots/`) y encuentra cada control que hace algo: `Button`, `IconButton`, `Toggle`, `Picker`, `Stepper`, `TextField`, `SecureField`, `TextEditor`, `Link`, `ExternalLink`, ítems de menú (`ClosureMenuItem`, `item("…")` de `AppMenu`), las acciones de notificación, `onPick:`/`freeform:`/`onRetry:`/`onReload:`, `.onDeleteCommand`, `.searchable`, `DisclosureGroup`, `.onTapGesture`, `.accessibilityAction(named:)` y `List(selection:)`. Cada uno se identifica por `archivo|tipo|primer texto literal de la línea` y se cuenta. `UIActionInventory` es la lista explícita y revisada: para cada clave, cuántas hay y a qué comando(s) corresponde, o por qué es solo de vista. **Agregar un botón sin entrada (o con otra cantidad) rompe el test**, y una entrada `.cli` que nombra un comando que no existe en `CLIRouter` también.

**Files:**
- Create: `Sources/PRBarTests/UIActionScanner.swift`, `Sources/PRBarTests/UIActionInventory.swift`, `Sources/PRBarTests/UIParityTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ UIParityTests.cases`)

- [ ] **Step 1: El escáner**

`Sources/PRBarTests/UIActionScanner.swift`:

```swift
import Foundation

/// Encuentra los controles de la UI en el código de la app (ver la Task 21 del plan 7).
enum UIActionScanner {
    struct Key: Hashable, Comparable, CustomStringConvertible {
        let file: String
        let kind: String
        let label: String

        static func < (a: Key, b: Key) -> Bool { a.description < b.description }
        var description: String { "\(file)|\(kind)|\(label)" }
    }

    /// `Sources/PRBar`, a partir de este archivo (`Sources/PRBarTests/UIActionScanner.swift`).
    static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PRBar", isDirectory: true)

    private static let patterns: [(kind: String, regex: String)] = [
        ("Button", #"(?<![A-Za-z])Button\s*(\(|\{)"#),
        ("IconButton", #"(?<![A-Za-z])IconButton\s*\("#),
        ("Toggle", #"(?<![A-Za-z])Toggle\s*\("#),
        ("Picker", #"(?<![A-Za-z])Picker\s*\("#),
        ("Stepper", #"(?<![A-Za-z])Stepper\s*\("#),
        ("TextField", #"(?<![A-Za-z])TextField\s*\("#),
        ("SecureField", #"(?<![A-Za-z])SecureField\s*\("#),
        ("TextEditor", #"(?<![A-Za-z])TextEditor\s*\("#),
        ("Link", #"(?<![A-Za-z])Link\s*\("#),
        ("ExternalLink", #"(?<![A-Za-z])ExternalLink\s*\("#),
        ("ClosureMenuItem", #"(?<![A-Za-z])ClosureMenuItem\s*\(title:"#),
        ("MenuItem", #"(?<![A-Za-z.])item\((?=")"#),
        ("onPick", #"(?<![A-Za-z])onPick:"#),
        ("freeform", #"(?<![A-Za-z])freeform:"#),
        ("onRetry", #"(?<![A-Za-z])onRetry:"#),
        ("onReload", #"(?<![A-Za-z])onReload:"#),
        ("onDeleteCommand", #"\.onDeleteCommand"#),
        ("searchable", #"\.searchable\("#),
        ("DisclosureGroup", #"(?<![A-Za-z])DisclosureGroup\s*\("#),
        ("onTapGesture", #"\.onTapGesture"#),
        ("accessibilityAction", #"\.accessibilityAction\(named:"#),
        ("NotificationAction", #"UNNotificationAction\("#),
        ("ListSelection", #"(?<![A-Za-z])List\(selection:"#),
    ]

    /// Declaraciones (p. ej. `struct IconButton`): no son usos. Los parámetros `onPick:`… sí cuentan siempre.
    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(private |fileprivate )?(struct|init|func|enum|class|static func)\b"#)
    private static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    private static let alwaysCounted: Set<String> = ["onPick", "freeform", "onRetry", "onReload"]

    static func scan(root: URL = appSources) throws -> [Key: Int] {
        let compiled = try patterns.map { ($0.kind, try NSRegularExpression(pattern: $0.regex)) }
        var counts: [Key: Int] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Snapshots/") } ?? []
        for file in files {
            let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                let isDeclaration = declaration.firstMatch(in: line, range: range) != nil
                for (kind, regex) in compiled {
                    guard let match = regex.firstMatch(in: line, range: range) else { continue }
                    if isDeclaration && !alwaysCounted.contains(kind) { continue }
                    let restStart = match.range.location + match.range.length
                    let rest = NSRange(location: restStart, length: range.length - restStart)
                    var label = "-"
                    if let found = literal.firstMatch(in: line, range: rest), let text = Range(found.range(at: 1), in: line) {
                        label = String(line[text])
                    }
                    counts[Key(file: relative, kind: kind, label: label), default: 0] += 1
                }
            }
        }
        return counts
    }
}
```

- [ ] **Step 2: El inventario**

`Sources/PRBarTests/UIActionInventory.swift` (las claves y cantidades salen del código **antes** de los planes 6, 8 y 9; el Step 4 reconcilia lo que esos planes agregaron):

```swift
import Foundation

/// A qué comando de `prbar` corresponde cada control de la UI (spec C.1/C.7). Revisada a mano: un control nuevo
/// necesita su entrada. `.cli` nombra rutas de `CLIRouter`; `.viewOnly` explica por qué no hay comando (solo cambia
/// la vista, o es un componente genérico cuyos usos están inventariados donde se usan).
enum UIMapping: Equatable {
    case cli([String])
    case viewOnly(String)
    /// Controles de los planes 6/8/9 cuyo comando agregan las Tasks 26–28. La Task 28 borra este caso.
    case deferred(String)
}

struct UIAction {
    let key: UIActionScanner.Key
    let count: Int
    let mapping: UIMapping

    init(_ file: String, _ kind: String, _ label: String, _ count: Int, _ mapping: UIMapping) {
        key = UIActionScanner.Key(file: file, kind: kind, label: label)
        self.count = count
        self.mapping = mapping
    }
}

enum UIActionInventory {
    static let generic = "generic component: each use is inventoried where it’s used"

    static let entries: [UIAction] = [
        // Menú de la app (AppKit, con una ventana abierta)
        .init("AppMenu.swift", "ClosureMenuItem", "Settings…", 1, .cli(["app settings"])),
        .init("AppMenu.swift", "MenuItem", "About PRBar", 1, .cli(["version"])),
        .init("AppMenu.swift", "MenuItem", "Quit PRBar", 1, .cli(["app quit"])),
        .init("AppMenu.swift", "MenuItem", "Hide PRBar", 1, .viewOnly("hides the app’s windows")),
        .init("AppMenu.swift", "MenuItem", "Hide Others", 1, .viewOnly("hides other apps")),
        .init("AppMenu.swift", "MenuItem", "Show All", 1, .viewOnly("shows other apps")),
        .init("AppMenu.swift", "MenuItem", "Undo", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Redo", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Cut", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Copy", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Paste", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Select All", 1, .viewOnly("text editing")),
        .init("AppMenu.swift", "MenuItem", "Minimize", 1, .viewOnly("window management")),
        .init("AppMenu.swift", "MenuItem", "Close", 1, .viewOnly("window management")),
        // Componentes genéricos
        .init("Components/Chips.swift", "Button", "-", 1, .cli(["repo set"])),   // RemovableChip: quitar una rama base
        .init("Components/PointingHandCursor.swift", "Button", "-", 1, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "Button", "-", 4, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "Button", "Reload", 1, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "Button", "Try Again", 1, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "IconButton", "xmark.circle.fill", 1, .viewOnly("clears the search field")),
        .init("Components/SearchablePickerPopover.swift", "TextField", "-", 1, .viewOnly("search field")),
        .init("Components/SearchablePickerPopover.swift", "freeform", "-", 2, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "onPick", "-", 2, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "onReload", "-", 2, .viewOnly(generic)),
        .init("Components/SearchablePickerPopover.swift", "onRetry", "-", 2, .viewOnly(generic)),
        // Notificaciones
        .init("NotificationDelivery.swift", "NotificationAction", "Open", 1, .cli(["open", "history show"])),
        // Popover
        .init("Popover/Components.swift", "Button", "-", 2, .cli(["app settings", "refresh"])),   // colapsar sección (vista) y la acción de MessageView
        .init("Popover/Components.swift", "IconButton", "checkmark", 1, .viewOnly("copies `gh auth login --hostname github.com`; `prbar doctor` prints it")),
        .init("Popover/PopoverView.swift", "Button", "History…", 2, .cli(["app history"])),
        .init("Popover/PopoverView.swift", "Button", "Settings…", 2, .cli(["app settings"])),
        .init("Popover/PopoverView.swift", "Button", "Quit PRBar", 2, .cli(["app quit"])),
        .init("Popover/PopoverView.swift", "IconButton", "-", 1, .cli(["refresh"])),
        .init("Popover/PRRowView.swift", "Button", "-", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Open on GitHub", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Copy Link", 1, .cli(["open"])),
        .init("Popover/PRRowView.swift", "Button", "Review with Claude", 2, .cli(["review start"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel Review", 1, .cli(["review cancel"])),
        .init("Popover/PRRowView.swift", "Button", "View Review", 1, .cli(["open", "review show"])),
        .init("Popover/PRRowView.swift", "Button", "Cancel", 1, .cli(["respond cancel"])),
        .init("Popover/PRRowView.swift", "Button", "Respond with Claude", 1, .cli(["respond start"])),
        .init("Popover/PRRowView.swift", "Button", "View Response", 1, .cli(["open", "respond show"])),
        // Botones Review / Respond de la fila
        .init("Review/ReviewButton.swift", "Button", "Review", 1, .cli(["review start"])),
        .init("Review/ReviewButton.swift", "Button", "-", 4, .cli(["open", "review cancel", "history show"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Show Log", 1, .cli(["history show"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["review start"])),
        .init("Review/ReviewButton.swift", "ClosureMenuItem", "Dismiss", 1, .cli(["review dismiss"])),
        .init("Review/ReviewButton.swift", "accessibilityAction", "Cancel Review", 1, .cli(["review cancel"])),
        .init("Respond/RespondButton.swift", "Button", "Respond", 1, .cli(["respond start"])),
        .init("Respond/RespondButton.swift", "Button", "-", 5, .cli(["open", "respond cancel", "history show"])),
        .init("Respond/RespondButton.swift", "ClosureMenuItem", "Open", 1, .cli(["open"])),
        .init("Respond/RespondButton.swift", "ClosureMenuItem", "Retry", 1, .cli(["respond start", "respond push"])),
        .init("Respond/RespondButton.swift", "accessibilityAction", "Cancel", 1, .cli(["respond cancel"])),
        // Ventana de Review
        .init("Review/ReviewWindow.swift", "Button", "-", 2, .cli(["review publish", "review show"])),   // Discarded (vista) y "Approve with N comments"
        .init("Review/ReviewWindow.swift", "Button", "Select All", 1, .cli(["review include"])),
        .init("Review/ReviewWindow.swift", "Button", "Select None", 1, .cli(["review exclude"])),
        .init("Review/ReviewWindow.swift", "Button", "Post Everything in the Review Body", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Request Changes", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Approve Without Comments…", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Comment", 1, .cli(["review publish"])),
        .init("Review/ReviewWindow.swift", "Button", "Review Again", 1, .cli(["review start"])),
        .init("Review/ReviewWindow.swift", "TextField", "General comment (optional)", 1, .cli(["review comment"])),
        .init("Review/FindingCard.swift", "Toggle", "-", 2, .cli(["review include", "review exclude"])),
        .init("Review/FindingCard.swift", "Button", "-", 1, .viewOnly("expands the comment; `prbar review show --full` prints it")),
        .init("Review/FindingCard.swift", "Button", "Remove", 1, .cli(["review include", "review exclude"])),
        .init("Review/FindingCard.swift", "TextEditor", "-", 1, .cli(["review edit"])),
        .init("Review/ReviewPublishedView.swift", "Button", "Close", 1, .viewOnly("closes the window")),
        .init("Review/ReviewPublishedView.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Review/ReviewStyle.swift", "ExternalLink", "-", 1, .cli(["open"])),
        .init("Review/ReviewStyle.swift", "Link", "-", 1, .viewOnly(generic)),
        // Ventana de Respond
        .init("Respond/RespondWindow.swift", "Button", "-", 3, .cli(["open", "respond push"])),   // carpeta, Push/Post y "Open New Analysis"
        .init("Respond/RespondWindow.swift", "Button", "Reset to Claude’s Suggestions", 1, .cli(["respond select"])),
        .init("Respond/RespondWindow.swift", "Button", "Implement 1 Fix", 1, .cli(["respond implement"])),
        .init("Respond/RespondWindow.swift", "Button", "Analyze Again", 1, .cli(["respond start"])),
        .init("Respond/RespondWindow.swift", "Button", "Retry Pending Replies", 1, .cli(["respond reply-only"])),
        .init("Respond/RespondWindow.swift", "Button", "Cancel", 3, .cli(["respond cancel"])),
        .init("Respond/RespondWindow.swift", "Button", "Run Tests", 1, .cli(["respond test"])),
        .init("Respond/RespondWindow.swift", "Button", "Close", 2, .viewOnly("closes the window")),
        .init("Respond/RespondWindow.swift", "DisclosureGroup", "-", 1, .viewOnly("test output; `prbar respond show --full` prints it")),
        .init("Respond/RespondWindow.swift", "ExternalLink", "View Reply", 1, .cli(["respond show"])),
        .init("Respond/RespondWindow.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Respond/RespondWindow.swift", "Link", "-", 1, .cli(["respond show"])),   // links a los commits
        .init("Respond/RespondItemCard.swift", "Toggle", "Implement fix", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "Toggle", "Reply", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "TextEditor", "-", 1, .cli(["respond select"])),
        .init("Respond/RespondItemCard.swift", "Button", "-", 1, .viewOnly("expands the thread; `prbar respond show --full` prints it")),
        .init("Respond/RespondItemCard.swift", "ExternalLink", "View on GitHub", 1, .cli(["respond show"])),
        // Historial
        .init("Review/HistoryWindow.swift", "ListSelection", "-", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Picker", "Repo", 1, .cli(["history list"])),
        .init("Review/HistoryWindow.swift", "searchable", "Search by title, repo, or number", 1, .cli(["history list"])),
        .init("Review/HistoryWindow.swift", "Button", "Open PR on GitHub", 2, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "Copy PR Link", 2, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "View Review on GitHub", 1, .cli(["open"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Claude Log in Finder", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Log in Finder", 1, .cli(["history show"])),
        .init("Review/HistoryWindow.swift", "Button", "Open to Post", 1, .cli(["history reopen"])),
        .init("Review/HistoryWindow.swift", "Button", "Show Response", 1, .cli(["open"])),
        .init("Review/HistoryDetailView.swift", "Button", "-", 1, .cli(["history show"])),
        .init("Review/HistoryDetailView.swift", "Button", "Open to Post", 1, .cli(["history reopen"])),
        .init("Review/HistoryDetailView.swift", "ExternalLink", "View on GitHub", 1, .cli(["open"])),
        .init("Respond/RespondHistoryDetailView.swift", "Button", "-", 1, .cli(["history show"])),
        .init("Respond/RespondHistoryDetailView.swift", "Button", "Show Response", 1, .cli(["open"])),
        // Settings › General
        .init("Settings/GeneralTab.swift", "Picker", "Refresh every", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Open at login", 1, .cli(["config set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "-", 1, .cli(["notify enable", "notify disable"])),
        .init("Settings/GeneralTab.swift", "Toggle", "New PR to review", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "A PR I reviewed has new commits", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR got change requests or comments", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "Claude finished a review or a response", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Toggle", "My PR was approved or CI failed", 1, .cli(["notify set"])),
        .init("Settings/GeneralTab.swift", "Button", "Open System Settings…", 1, .cli(["notify system-settings"])),
        .init("Settings/PathRow.swift", "Button", "-", 1, .cli(["tools reset", "repo set"])),
        .init("Settings/PathRow.swift", "Button", "Choose…", 1, .cli(["tools set", "repo set"])),
        // Settings › Claude
        .init("Settings/ClaudeTab.swift", "Button", "-", 2, .cli(["claude set", "claude skills"])),
        .init("Settings/ClaudeTab.swift", "Toggle", "Filter findings", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Picker", "Model", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Button", "Reset to Defaults", 1, .cli(["claude reset"])),
        .init("Settings/ClaudeTab.swift", "TextField", "Search skills", 1, .cli(["claude skills"])),
        .init("Settings/ClaudeTab.swift", "Button", "Custom…", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "TextField", "plugin:skill", 1, .cli(["claude set"])),
        .init("Settings/ClaudeTab.swift", "Button", "Use", 1, .cli(["claude set"])),
        // Settings › Accounts
        .init("Settings/AccountsTab.swift", "Toggle", "-", 1, .cli(["account enable", "account disable"])),
        .init("Settings/AccountsTab.swift", "Button", "Reload", 1, .cli(["account reload"])),
        .init("Settings/AccountsTab.swift", "Button", "Reload Accounts", 1, .cli(["account reload"])),
        // Settings › Repos
        .init("Settings/SettingsView.swift", "Picker", "Account", 1, .viewOnly("chooses which account’s repos are shown; commands take --account")),
        .init("Settings/ReposTab.swift", "ListSelection", "-", 1, .cli(["repo list"])),
        .init("Settings/ReposTab.swift", "onPick", "-", 2, .cli(["repo add", "repo set"])),
        .init("Settings/ReposTab.swift", "onRetry", "-", 2, .cli(["repo available", "repo branches"])),
        .init("Settings/ReposTab.swift", "onReload", "-", 1, .cli(["repo available"])),
        .init("Settings/ReposTab.swift", "Button", "Remove Repo…", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "Button", "Remove…", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "Button", "Remove", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "Button", "Cancel", 1, .viewOnly("cancels the confirmation")),
        .init("Settings/ReposTab.swift", "onDeleteCommand", "-", 1, .cli(["repo remove"])),
        .init("Settings/ReposTab.swift", "IconButton", "arrow.up.right.square", 1, .cli(["repo open"])),
        .init("Settings/ReposTab.swift", "IconButton", "arrow.clockwise", 1, .cli(["slack channels"])),
        .init("Settings/ReposTab.swift", "Picker", "Channel", 1, .cli(["repo set"])),
        .init("Settings/ReposTab.swift", "TextField", "Test command", 1, .cli(["repo set"])),
        .init("Settings/WatchedUsersSection.swift", "onPick", "-", 1, .cli(["follow add"])),
        .init("Settings/WatchedUsersSection.swift", "freeform", #"Add “\($0)”"#, 1, .cli(["follow add"])),
        .init("Settings/WatchedUsersSection.swift", "onRetry", "-", 1, .cli(["follow suggestions"])),
        .init("Settings/WatchedUsersSection.swift", "IconButton", "xmark", 1, .cli(["follow remove"])),
        // Settings › Slack
        .init("Settings/SlackTab.swift", "Toggle", "Use Slack", 1, .cli(["slack enable", "slack disable"])),
        .init("Settings/SlackTab.swift", "Picker", "Connect with", 1, .cli(["slack provider"])),
        .init("Settings/SlackTab.swift", "Button", "Test Connection", 2, .cli(["slack check"])),
        .init("Settings/SlackTab.swift", "SecureField", "-", 1, .cli(["slack token set"])),
        .init("Settings/SlackTab.swift", "Button", "Save and Test", 1, .cli(["slack token set"])),
        .init("Settings/SlackTab.swift", "Button", "Delete Token…", 1, .cli(["slack token clear"])),
        .init("Settings/SlackTab.swift", "Button", "Delete", 1, .cli(["slack token clear"])),
        .init("Settings/SlackTab.swift", "Button", "Cancel", 2, .viewOnly("cancels a confirmation")),
        .init("Settings/SlackTab.swift", "Button", "Send Test to My DM…", 1, .cli(["slack test"])),
        .init("Settings/SlackTab.swift", "Button", "Send Test", 1, .cli(["slack test"])),
        .init("Settings/SlackTab.swift", "Button", "Show Log", 1, .cli(["app logs"])),
        .init("Settings/SlackTab.swift", "DisclosureGroup", "How to get a user token", 1, .viewOnly("setup guide; also in docs/cli.md")),
        .init("Settings/SlackTab.swift", "Link", "Open api.slack.com/apps", 1, .viewOnly("link to Slack’s website")),
        .init("Settings/SlackTab.swift", "Toggle", "-", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Announce new PRs in the channel", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Reply “Updated” in the thread after a review and a new push", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "Toggle", "Reply in the thread on each new round of comments", 1, .cli(["slack set"])),
        .init("Settings/SlackTab.swift", "TextField", "Emoji", 1, .cli(["slack emoji"])),
        .init("Settings/SlackTab.swift", "Stepper", "-", 1, .cli(["slack search-days"])),
        .init("Settings/SlackTemplateEditor.swift", "TextField", "-", 1, .cli(["slack template set"])),
        .init("Settings/SlackTemplateEditor.swift", "Button", "-", 1, .cli(["slack template set"])),   // Insert Variable
        .init("Settings/SlackTemplateEditor.swift", "Button", "Reset to Default", 1, .cli(["slack template reset"])),
    ]
}
```

- [ ] **Step 3: El test**

`Sources/PRBarTests/UIParityTests.swift`:

```swift
import Foundation
import PRBarCLIKit

enum UIParityTests {
    static let cases: [TestCase] = [
        TestCase("paridad UI: cada control de la app tiene su comando (o una razón)") {
            let scanned = try UIActionScanner.scan()
            try expect(!scanned.isEmpty, "el escáner no encontró nada en \(UIActionScanner.appSources.path)")
            var expected: [UIActionScanner.Key: UIAction] = [:]
            for entry in UIActionInventory.entries {
                try expect(expected[entry.key] == nil, "entrada repetida: \(entry.key)")
                expected[entry.key] = entry
            }
            var problems: [String] = []
            for (key, count) in scanned.sorted(by: { $0.key < $1.key }) {
                guard let entry = expected[key] else {
                    problems.append("NUEVO, sin entrada:  .init(\"\(key.file)\", \"\(key.kind)\", \"\(key.label)\", \(count), .cli([\"…\"])),")
                    continue
                }
                if entry.count != count { problems.append("CANTIDAD: \(key) tiene \(count), el inventario dice \(entry.count)") }
            }
            for key in expected.keys.sorted() where scanned[key] == nil {
                problems.append("YA NO EXISTE: \(key) (borrar la entrada)")
            }
            for entry in UIActionInventory.entries {
                if case .cli(let paths) = entry.mapping {
                    for path in paths where !CLIRouter.allPaths.contains(path) {
                        problems.append("COMANDO INEXISTENTE: \(entry.key) → `\(path)`")
                    }
                }
            }
            try expect(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
        },
    ]
}
```

- [ ] **Step 4: Correr y reconciliar con los planes 6, 8 y 9**

Run: `swift run PRBarTests "paridad UI"`
Expected (la primera vez): falla con una lista de líneas `NUEVO, sin entrada: .init(…)`, `CANTIDAD: …` y `YA NO EXISTE: …`, porque los planes 6, 8 y 9 cambiaron la UI. Resolver cada una **mirando el control en el código**:

- Controles que ya tienen comando (p. ej. el `#N` que el plan 6 agregó a `FindingCard` cambia cantidades pero no acciones; una tarjeta nueva de hallazgo agregado por el chat es `review include/exclude/edit`): corregir la cantidad o agregar la entrada con el comando existente.
- Controles del **chat** (plan 6: `Chat/ChatPanel.swift` → `TextField` del mensaje, `Button("Stop")`, el botón de enviar, `Button("Show Log")`, `Button("Undo")`, `DisclosureGroup` de la conversación en el historial; el botón de toolbar `Chat` en `ReviewWindow`/`RespondWindow`; en `Settings/ClaudeTab.swift`, `Toggle("Chat with Claude in Review and Respond windows")` y el segundo `Picker("Model")`): `.deferred("Task 26")`.
- Controles de **actualizaciones** (plan 8: `Popover/UpdateRow.swift`, `Settings/UpdatesSection.swift` → "Check automatically", "Frequency", "Check for Updates", "Update…"; `Update/UpdateWindow.swift` → "Update"/"Try Again", "Update When Done", "Cancel Jobs and Update", "Skip This Version", "Later", "Show Log", "Hide", "Cancel", "OK"): `.deferred("Task 27")`.
- Controles de **instrucciones y configuración completa** (plan 9: pestaña Instructions, chat de instrucciones, tarjetas "Save as rule", sugerencias, opciones de review/fixes, prompts): `.deferred("Task 28")`.
- `YA NO EXISTE`: borrar la entrada solo si el control realmente se fue (o se movió de archivo: mover la entrada).

Volver a correr hasta que pase. Cada entrada nueva lleva un comentario si la clave no se entiende sola (como `"-"`).

Run: `swift run PRBarTests`
Expected: todo pasa.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarTests/UIActionScanner.swift Sources/PRBarTests/UIActionInventory.swift Sources/PRBarTests/UIParityTests.swift Sources/PRBarTests/main.swift
git commit -m "Add the UI action inventory and the UI-to-CLI parity test"
```

---

### Task 22: Integración: CLI real contra un servidor real

**Files:**
- Create: `Sources/PRBarTests/CLIIntegrationTests.swift`
- Modify: `Sources/PRBarTests/main.swift` (`+ CLIIntegrationTests.cases`)

- [ ] **Step 1: Tests**

```swift
import ArgumentParser
import Foundation
import PRBarCLIKit
import PRBarCore

/// Un servidor con `FakeActions` y la CLI conectándose a él por un socket temporal.
@MainActor
private final class Harness {
    let url: URL
    let fake = FakeActions()
    let server: CommandServer

    init() throws {
        url = try shortSocketURL()
        let fake = self.fake
        server = CommandServer(socketURL: url, appVersion: "9.9.9") { command, events in
            await CommandDispatcher.run(command, on: fake, events: events)
        }
        try server.start()
    }
}

private final class Captured: @unchecked Sendable {
    var out = ""
    var err = ""
}

/// Corre `arguments` como la CLI (fuera del hilo principal: la CLI bloquea y el servidor usa el main actor).
/// Devuelve el exit code (0 si no lanzó) y lo que escribió.
private func runCLI(_ arguments: [String], socket: URL, interactive: Bool = false,
                    answer: Bool = true) async throws -> (code: Int32, out: String, err: String) {
    let captured = Captured()
    let code = try await Task.detached { () -> Int32 in
        let command = try PRBarCommand.parseAsRoot(arguments)
        guard let remote = command as? any RemoteCommand else { throw TestFailure(description: "no remoto") }
        let terminal = interactive ? Terminal(stdinIsTTY: true, stdoutIsTTY: true, colors: false) : .plain
        let environment = CLIEnvironment(terminal: terminal, out: { captured.out += $0 }, err: { captured.err += $0 },
                                         connect: { try AppConnection.connect(socketURL: socket) }, ask: { _ in answer })
        do {
            try run(remote, environment)
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        }
    }.value
    return (code, captured.out, captured.err)
}

/// Abre el existencial para llamar al genérico.
private func run<C: RemoteCommand>(_ command: C, _ environment: CLIEnvironment) throws {
    try CLIRunner.run(command, environment: environment)
}

enum CLIIntegrationTests {
    static let cases: [TestCase] = [
        TestCase("integración: --json por el socket real") { try await jsonStatus() },
        TestCase("integración: publicar sin --yes y sin terminal → exit 4, sin llamar a la app") { try await needsYes() },
        TestCase("integración: con terminal pregunta; si dice que no → 130") { try await asks() },
        TestCase("integración: errores de la app → exit codes") { try await errors() },
        TestCase("integración: sin app → exit 3") { try await noApp() },
    ]

    @MainActor
    private static func jsonStatus() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let result = try await runCLI(["status", "--json"], socket: harness.url)
        try expectEqual(result.code, 0)
        let json = try JSONDecoder().decode([String: JSONValue].self, from: Data(result.out.utf8))
        try expectEqual(json["schemaVersion"], .int(1))
        guard case .object(let data)? = json["data"] else { throw TestFailure(description: result.out) }
        try expectEqual(data["appVersion"], .string("test"))
        try expectEqual(harness.fake.calls, ["status"])
    }

    @MainActor
    private static func needsYes() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let result = try await runCLI(["review", "publish", "acme/api#1", "--approve"], socket: harness.url)
        try expectEqual(result.code, 4)
        try expect(result.err.contains("--yes"), result.err)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("reviewPublish") }, "\(harness.fake.calls)")
        let confirmed = try await runCLI(["review", "publish", "acme/api#1", "--approve", "--yes"], socket: harness.url)
        try expectEqual(confirmed.code, 0)
        try expect(harness.fake.calls.contains { $0.hasPrefix("reviewPublish acme/api#1 APPROVE") }, "\(harness.fake.calls)")
    }

    @MainActor
    private static func asks() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        let declined = try await runCLI(["respond", "reply-only", "acme/web#2"], socket: harness.url, interactive: true, answer: false)
        try expectEqual(declined.code, 130)
        try expect(!harness.fake.calls.contains { $0.hasPrefix("respondReplyOnly") })
    }

    @MainActor
    private static func errors() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.failure = CommandFailure(.notFound, "acme/api#9 isn’t in PRBar’s list.")
        let notFound = try await runCLI(["review", "show", "acme/api#9"], socket: harness.url)
        try expectEqual(notFound.code, 5)
        try expect(notFound.err.contains("isn’t in PRBar’s list"), notFound.err)
        harness.fake.failure = CommandFailure(.invalidState, "No review ready.")
        let state = try await runCLI(["review", "show", "acme/api#9"], socket: harness.url)
        try expectEqual(state.code, 6)
    }

    private static func noApp() async throws {
        let socket = try shortSocketURL()
        let result = try await runCLI(["status"], socket: socket)
        try expectEqual(result.code, 3)
    }
}
```

`review publish`, `respond push` y `respond reply-only` primero piden el estado (`reviewShow`/`respondShow`) y, si no está listo, salen con 6 sin preguntar. Para que estos tests lleguen a la pregunta, `FakeActions.respondShow` tiene que devolver un `RespondInfo` en `ready`: agregar a `FakeActions` una propiedad `var respondPhase: RespondPhase?` y usarla en `respondInfo(_:)` (`RespondInfo(prID: pr, phase: respondPhase, …)`); en `asks()`, poner `harness.fake.respondPhase = .ready(cliRespondDraft())` antes de correr. Igual con `reviewShow` para `needsYes()`: `var reviewPhase: ReviewPhase?` en el falso y `harness.fake.reviewPhase = .ready(editDraft())`.

- [ ] **Step 2: Ajustar el falso y correr**

Hacer los dos cambios de `FakeActions` descriptos arriba.

Run: `swift run PRBarTests integración`
Expected: `5/5 passed` sin colgarse.

- [ ] **Step 3: Commit**

```bash
git add Sources/PRBarTests/CLIIntegrationTests.swift Sources/PRBarTests/FakeActions.swift Sources/PRBarTests/main.swift
git commit -m "Add CLI-to-server integration tests over a real socket"
```

---

### Task 23: `bundle.sh`: `Contents/Helpers/prbar` y el link en `~/.local/bin`

Parte del `Scripts/bundle.sh` que dejó el plan 8 (con `--install` y `--output <dir>`). El actualizador del plan 8 arma el `.app` con `--output`, así que el helper viaja dentro del bundle y el link de `~/.local/bin` sigue apuntando a la versión nueva.

**Files:**
- Modify: `Scripts/bundle.sh`, `Sources/PRBarTests/ScriptTests.swift` (del plan 8)

- [ ] **Step 1: Test**

Agregar a `ScriptTests.cases`:

```swift
        TestCase("scripts: bundle.sh copia prbar a Helpers y lo enlaza con --install") {
            let text = try String(contentsOfFile: script("bundle.sh"), encoding: .utf8)
            try expect(text.contains("--product PRBarCLI"))
            try expect(text.contains("Contents/Helpers/prbar"))
            try expect(text.contains("PRBAR_BIN_DIR"))
        },
```

Run: `swift run PRBarTests scripts`
Expected: falla el nuevo.

- [ ] **Step 2: Cambiar `Scripts/bundle.sh`**

1. En el comentario de uso, agregar: `#   (siempre) copia la CLI a PRBar.app/Contents/Helpers/prbar; con --install la enlaza en ~/.local/bin/prbar (o $PRBAR_BIN_DIR)`.
2. Reemplazar las dos líneas de compilación (`swift build -c release --product PRBar` y `BIN="…"`) por:

```bash
swift build -c release --product PRBar
swift build -c release --product PRBarCLI
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/PRBar"
```

3. Reemplazar el bloque desde `mkdir -p "$APP/Contents/MacOS" …` hasta `codesign --force --sign - "$APP"` por:

```bash
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/PRBar"
# La CLI (spec C.3). Se llama `prbar` dentro del bundle; en .build es PRBarCLI (APFS no distingue mayúsculas).
cp "$BIN_DIR/PRBarCLI" "$APP/Contents/Helpers/prbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Primero el helper y después el bundle (que sella lo que tiene adentro).
codesign --force --sign - "$APP/Contents/Helpers/prbar"
codesign --force --sign - "$APP"
```

4. Al final del bloque `if [[ $INSTALL == 1 ]]; then`, antes de su `fi`:

```bash
    # `prbar` en el PATH: un link al helper del bundle instalado (sigue valiendo después de actualizar).
    LINK_DIR="${PRBAR_BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$LINK_DIR"
    ln -sf "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" "$LINK_DIR/prbar"
    echo "CLI: $LINK_DIR/prbar"
    case ":$PATH:" in
        *":$LINK_DIR:"*) ;;
        *) echo "Aviso: $LINK_DIR no está en tu PATH. Agregá a ~/.zshrc: export PATH=\"$LINK_DIR:\$PATH\"" >&2 ;;
    esac
```

- [ ] **Step 3: Correr y probar**

Run: `swift run PRBarTests scripts`
Expected: todos los `scripts:` pasan.

Run:

```bash
Scripts/bundle.sh
codesign --verify --deep --strict build/PRBar.app && echo firmado
build/PRBar.app/Contents/Helpers/prbar --help | head -3
build/PRBar.app/Contents/Helpers/prbar version
```

Expected: `firmado`; la ayuda de `prbar`; `prbar 0.1.0` (o la versión del Info.plist) y el estado de la app.

Run: `PRBAR_BIN_DIR="$TMPDIR/prbar-bin" Scripts/bundle.sh --install && ls -l "$TMPDIR/prbar-bin/prbar" && "$TMPDIR/prbar-bin/prbar" status`
Expected: el link apunta a `~/Applications/PRBar.app/Contents/Helpers/prbar`, el aviso de PATH (esa carpeta no está) y el estado de la app recién abierta. Después correr `Scripts/bundle.sh --install` sin la variable para el link real en `~/.local/bin`.

- [ ] **Step 4: Commit**

```bash
git add Scripts/bundle.sh Sources/PRBarTests/ScriptTests.swift
git commit -m "Bundle the prbar CLI in Contents/Helpers and link it on install"
```

---

### Task 24: `docs/cli.md`

**Files:**
- Create: `docs/cli.md`
- Modify: `README.md` (si existe: una línea "CLI: ver docs/cli.md" en la sección de instalación)

- [ ] **Step 1: Escribir `docs/cli.md`**

````markdown
# prbar — PRBar from the terminal

`prbar` controls PRBar.app: everything you can do in the menu bar, the Review, Respond and History windows and
Settings, you can do from the terminal. The app does the work (it’s the only one that writes the config, runs Claude
and posts); `prbar` asks it over a private socket.

## Install

`Scripts/bundle.sh --install` installs PRBar.app in `~/Applications` and links the CLI at `~/.local/bin/prbar`
(or `$PRBAR_BIN_DIR/prbar`). If that folder isn’t in your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to
`~/.zshrc`. The link points inside the app, so updates (`prbar update`) update the CLI too.

Shell completion: `prbar completion zsh > ~/.zfunc/_prbar` (also `bash` and `fish`).

If PRBar isn’t running, `prbar` opens it in the background and waits up to 10 seconds. `prbar doctor`, `prbar version`,
`prbar completion`, `prbar app start`, `prbar app logs`, `prbar repo open` and `prbar notify system-settings` work
without the app.

## PRs

`owner/repo#N`, `repo#N` (when only one configured repo has that name) or the PR’s URL. The PR has to be in PRBar’s
list (`prbar prs`).

Findings are numbered like in the Review window (`#1`, `#2`…, including the ones discarded by the filter and the ones
the chat added); comments in Respond are numbered like in the Respond window. You can also use their ids (`f2`,
`thread:…`).

## Commands

| Command | Does |
|---|---|
| `prbar status [--json]` | What the menu bar shows: counts, running jobs, issues |
| `prbar prs [--list to-review\|updated\|mine\|other] [--account L]` | The PRs |
| `prbar refresh` | Refresh now |
| `prbar open <pr> [--review\|--respond\|--posted\|--worktree] [--copy]` | Open the PR, its window, the posted review or the worktree; `--copy` copies the link |
| `prbar history [--repo R] [--kind review\|respond] [--search Q] [--limit N]` | History |
| `prbar history show <id> [--open-log\|--reveal-log]` | One record (id or its first 4+ characters) |
| `prbar history reopen <id>` | Open to Post |
| `prbar app start\|quit\|settings [tab]\|history [id]\|logs [--slack]` | The app |
| `prbar doctor [--json]` | Check the installation |
| `prbar version` | prbar’s and the app’s versions |
| `prbar review <pr> [--wait]` | Review with Claude |
| `prbar review show <pr> [--full]` | Findings, selection, texts |
| `prbar review edit <pr> <n> [--title T] [--body B\|--body-file F\|--editor]` | Edit a finding |
| `prbar review include\|exclude <pr> <n>… \| --all` | Choose what to post (Select All / None) |
| `prbar review comment <pr> --text T\|--editor` | General comment |
| `prbar review publish <pr> --comment\|--request-changes\|--approve [--only 1,3] [--no-comments] [--all-in-body] [--yes]` | Post |
| `prbar review cancel\|dismiss <pr>` | Cancel / dismiss |
| `prbar respond <pr> [--wait]` | Analyze the feedback on your PR |
| `prbar respond show <pr> [--full]` | Analysis, choices, fixes |
| `prbar respond select <pr> <n>… --implement\|--reply-only\|--skip [--no-reply] [--reply T] [--plan T]`, `--reset` | Choose |
| `prbar respond implement\|test <pr> [--wait]` | Implement the fixes / run the tests |
| `prbar respond diff <pr> [--stat]` | The diff that would be pushed |
| `prbar respond push <pr> [--wait] [--yes]` | Push and reply |
| `prbar respond reply-only <pr> [--wait] [--yes]` | Only replies |
| `prbar respond cancel\|dismiss <pr>` | Cancel / dismiss |
| `prbar config show`, `prbar config set refresh-interval 1\|2\|5\|10`, `… launch-at-login on\|off` | General |
| `prbar account list\|reload`, `prbar account enable\|disable <login>` | Accounts |
| `prbar repo list\|available\|add\|remove\|branches\|open`, `prbar repo set <repo> [--path P\|none] [--worktrees P\|default] [--test-command C] [--branches a,b] [--add-branch b] [--remove-branch b] [--channel #name\|ID\|none]` | Repos |
| `prbar follow list [repo]`, `prbar follow add\|remove <repo> <users…>`, `prbar follow suggestions <repo>` | People to follow |
| `prbar notify list\|enable\|disable\|system-settings`, `prbar notify set <kind> on\|off` | Notifications (`new-to-review`, `reviewed-updated`, `my-feedback`, `review-finished`, `approved-or-ci`) |
| `prbar claude show\|reset\|skills`, `prbar claude set [--review-skill S] [--filter on\|off] [--filter-skill S] [--respond-skill S] [--model M]` | Claude |
| `prbar tools list`, `prbar tools set <gh\|git\|claude> <path>`, `prbar tools reset <tool>` | Tool paths |
| `prbar slack show\|enable\|disable\|check\|channels [--reload]` | Slack |
| `prbar slack provider connector\|token`, `prbar slack token set [--stdin]\|clear` | Connection |
| `prbar slack set <announce\|updated\|react-start\|react-comment\|rounds\|react-approve> on\|off` | Toggles |
| `prbar slack emoji eyes\|comment\|approved <name>`, `prbar slack search-days <7–90>` | Reactions |
| `prbar slack template list\|show\|set\|reset <new-pr\|update\|round> [text\|--editor]` | Templates |
| `prbar slack test [--yes]` | Test message to your DM |

## Interactive and scripts

In a terminal (stdin and stdout are a TTY, no `--json`): colored tables (`NO_COLOR` turns color off), and:

- `review publish` without `--only`: a checkbox list of the findings (↑↓ or j/k, space toggles, `a`/`n` all/none,
  `e` edits the comment in `$EDITOR`, ↩ done, `q` cancels), then a confirmation with the review type and the number of
  comments. What you choose is applied in the app, so the window shows the same.
- `respond push` / `reply-only`: the summary and the diff stat, then a confirmation.
- `repo remove`, `slack token clear`: a confirmation (only in a terminal).

Without a terminal (a script, a pipe, `--json`) `prbar` never asks. Commands that post, push or approve
(`review publish`, `respond push`, `respond reply-only`, `slack test`) **need `--yes`**; without it they exit with 4.

`--wait` prints progress to stderr. Ctrl-C cancels the job in the app too and exits with 130.

## `--json`

```json
{ "schemaVersion": 1, "data": … }
```

Keys are sorted; dates are ISO 8601. `data` is the command’s result: `StatusInfo`, `[PRInfo]`, `ReviewInfo`,
`RespondInfo`, `[HistoryEntryInfo]`, `HistoryDetail`, … (see `Sources/PRBarCore/CommandResults.swift`). Commands with
nothing to return give `{"ok": true}`. New optional keys may appear; renaming or removing one bumps `schemaVersion`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Error |
| 2 | Invalid usage |
| 3 | PRBar isn’t available (not running and couldn’t start, or an incompatible version) |
| 4 | Confirmation required (`--yes`) |
| 5 | Not found (PR, repo, account, finding, record) |
| 6 | Invalid state (e.g. posting without a ready review) |
| 10 | `prbar update --check`: there’s a new version |
| 130 | Canceled (Ctrl-C, or you said no) |

## Security

The socket is `~/Library/Application Support/PRBar/prbar.sock`, created with permissions 0600 in a 0700 folder. The
app checks each connection’s user (`getpeereid`) and rejects anyone else; there’s no network. The first message is a
handshake with the protocol version: if `prbar` and the app don’t match, you get
“prbar X can’t talk to PRBar Y — run `prbar update` or reinstall”. Tokens never travel from the app to the CLI;
`prbar slack token set` sends the token you type to the app (never on the command line: it asks without echo or reads
`--stdin`).

## Environment

| Variable | |
|---|---|
| `PRBAR_SOCKET` | Another socket path (development) |
| `PRBAR_BIN_DIR` | Where `bundle.sh --install` puts the `prbar` link |
| `NO_COLOR` | No colors |
| `VISUAL`, `EDITOR` | Editor for `--editor` and `e` in the picker |

## Slack user token

At api.slack.com/apps → Create New App → From scratch → OAuth & Permissions → User Token Scopes: `chat:write`,
`reactions:write`, `channels:history`, `groups:history`, `channels:read`, `groups:read` → Install to Workspace → copy
the User OAuth Token (`xoxp-…`) → `prbar slack token set`.
````

- [ ] **Step 2: Revisar contra `prbar --help`**

Run: `swift run PRBarCLI --help` y `swift run PRBarCLI review --help`
Expected: cada subcomando de la ayuda aparece en la tabla de `docs/cli.md`, con las mismas opciones.

- [ ] **Step 3: Commit**

```bash
git add docs/cli.md README.md
git commit -m "Document the prbar CLI"
```

---

### Task 25: Verificación manual (QA)

**Files:**
- Create: `docs/qa/plan-7-checklist.md`

- [ ] **Step 1: Escribir el checklist**

```markdown
# Plan 7 — CLI: verificación manual

Con `Scripts/bundle.sh --install` y `~/.local/bin` en el PATH.

## Instalación y conexión
- [ ] `which prbar` → `~/.local/bin/prbar`; `ls -l` muestra el link a `~/Applications/PRBar.app/Contents/Helpers/prbar`.
- [ ] `prbar doctor` todo ✓; `prbar version` muestra las dos versiones.
- [ ] Quit PRBar; `prbar status` la abre en segundo plano (sin traerla al frente) y contesta en < 10 s.
- [ ] `ls -la ~/Library/Application\ Support/PRBar/` → la carpeta `drwx------`, `prbar.sock` `srw-------`.
- [ ] Otro usuario del Mac (o `sudo -u nobody prbar status`) → exit 3, "Only the user running PRBar…".

## Review (PR ajeno)
- [ ] `prbar review <pr> --wait`: progreso en stderr, tabla de findings con #N igual a la ventana.
- [ ] Con la ventana abierta: `prbar review exclude <pr> 2`, `review edit <pr> 1 --editor`, `review comment <pr> --text …` se ven al instante.
- [ ] `prbar review publish <pr> --comment`: lista con casillas; `e` abre `$EDITOR`; `q` cancela (130); ↩ y "n" cancela; "y" publica. La ventana pasa a "Posted".
- [ ] `prbar review publish <pr> --approve < /dev/null` → exit 4.
- [ ] Ctrl-C en `prbar review <pr> --wait` cancela el review en la app (exit 130).

## Respond (PR propio)
- [ ] `respond <pr> --wait`, `respond select … --skip`, `respond implement --wait`, `respond diff`, `respond test --wait`, `respond push` (muestra diff stat y pregunta).
- [ ] `respond reply-only` en un análisis sin fixes; `respond dismiss` borra el worktree.

## Settings
- [ ] Cada fila de la tabla de `docs/cli.md` de Settings cambia lo mismo que la UI (con Settings abierta se ve al instante).
- [ ] `prbar app settings slack` abre (o cambia a) la pestaña Slack.
- [ ] `echo xoxp-… | prbar slack token set --stdin`; `prbar slack token clear` pregunta en la terminal.

## Scripts
- [ ] `prbar prs --json | jq '.data[0].id'`; `prbar history --json | jq .schemaVersion` → 1.
- [ ] Códigos: PR inexistente → 5; `review publish` sin review → 6; opción inválida → 2.
```

- [ ] **Step 2: Recorrerlo** y marcar cada ítem. Lo que falle se arregla con TDD en la task correspondiente.

- [ ] **Step 3: Commit**

```bash
git add docs/qa/plan-7-checklist.md
git commit -m "Add the plan 7 QA checklist"
```

---

### Task 26: Chat (`prbar chat …`) — asume el plan 6

**APIs del plan 6 que usa esta task** (el plan 6 está escrito y se implementó antes; si al ejecutar algún nombre cambió, usar el real):
- `ChatCoordinator` (Core, `@MainActor ObservableObject`, uno por draft): `session: ChatSession`, `isRunning`, `partialText`, `activity: String?`, `lockReason: String?`, `canSend`, `canUndo`, `send(_:) -> Bool`, `stop()`, `undo(_ id: UUID)`, `undoDiscardsLaterEdits(_ id: UUID) async -> Bool`, `number(of:) -> Int?`.
- `ChatSession`: `kind`, `messages: [ChatMessage]`, `readOnly`, `undoableMessageID`. `ChatMessage`: `id`, `role` (`user`/`assistant`/`error`), `text`, `createdAt`, `changes: [ChatChange]`, `undone`, `notes`.
- `ChatActions.summary(_ changes:number:) -> String` ("edited #2, added #4, changed 2 files").
- `AppModel`: `reviewChat(for: ReviewDraft)`, `respondChat(for: RespondDraft)`, `chatEnabled`, `chatUnavailableReason`.
- `ClaudeSettings.chatEnabled: Bool`, `ClaudeSettings.chatModel: ClaudeModel?` (`nil` = el mismo del review).
- `RespondQueue.chatting` (un turno de chat corriendo bloquea implementar, tests y push).

Ojo: el plan 6 ya tiene un `public enum ChatActions` en Core; por eso el protocolo de esta task se llama `ChatCommandActions`.

**Files:**
- Modify: `Sources/PRBarCore/AppCommand.swift`, `Sources/PRBarCore/AppCommandTypes.swift` (`ClaudeChanges`), `Sources/PRBarCore/CommandResults.swift` (`ChatInfo`), `Sources/PRBarCore/CommandActions.swift`, `Sources/PRBarCore/CommandDispatcher.swift`, `Sources/PRBar/AppModel+Settings.swift` (`claudeSet`), `Sources/PRBarCLIKit/ConfigCommands.swift` (`claude set`), `Sources/PRBarCLIKit/CLIRouter.swift`, `Sources/PRBarCLIKit/PRBarCLIKit.swift`, `Sources/PRBarTests/{AppCommandTests,FakeActions,CommandDispatcherTests,CLIParsingTests,UIActionInventory}.swift`, `docs/cli.md`
- Create: `Sources/PRBar/AppModel+Chat.swift`, `Sources/PRBarCLIKit/ChatCommands.swift`

- [ ] **Step 1: Tests que fallan**

En `AppCommandTests`, el conteo pasa a `73`. En `dispatchSamples` (`CommandDispatcherTests.swift`) agregar:

```swift
    (.chatSend(pr: "api#1", message: "why #2?"), "chatSend"),
    (.chatShow(pr: "api#1"), "chatShow"),
    (.chatUndo(pr: "api#1", confirmed: false), "chatUndo"),
    (.chatStop(pr: "api#1"), "chatStop"),
```

En `CLIParsingTests.cases`:

```swift
            TestCase("cli parse: chat") {
                try expectEqual(try parsed(["chat", "api#1", "why is #2 a bug?"]), .chatSend(pr: "api#1", message: "why is #2 a bug?"))
                try expectEqual(try parsed(["chat", "api#1", "--show"]), .chatShow(pr: "api#1"))
                try expectEqual(try parsed(["chat", "api#1", "--undo", "--yes"]), .chatUndo(pr: "api#1", confirmed: true))
                try expectEqual(try parsed(["chat", "api#1", "--stop"]), .chatStop(pr: "api#1"))
                try expect(rejects(["chat", "api#1", "hi", "--undo"]))
                try expectEqual(try parsed(["claude", "set", "--chat", "off", "--chat-model", "same"]),
                                .claudeSet(changes: ClaudeChanges(chatEnabled: false, chatModel: .clear)))
            },
```

Run: `swift run PRBarTests`
Expected: no compila.

- [ ] **Step 2: Core**

En `AppCommand`, después de `slackChannels`:

```swift
    // Chat (spec B, C.4)
    case chatSend(pr: String, message: String)
    case chatShow(pr: String)
    /// `confirmed`: deshacer aunque se pierdan ediciones manuales posteriores (B.6).
    case chatUndo(pr: String, confirmed: Bool)
    case chatStop(pr: String)
```

En `Name`: `case chatSend, chatShow, chatUndo, chatStop`, y en `name`: `case .chatSend: .chatSend`, `case .chatShow: .chatShow`, `case .chatUndo: .chatUndo`, `case .chatStop: .chatStop`.

En `ClaudeChanges`, agregar las propiedades `public var chatEnabled: Bool?` y `public var chatModel: ValueChange?` (`.clear` = el mismo modelo del review), con parámetros `chatEnabled: Bool? = nil, chatModel: ValueChange? = nil` al final del `init`.

En `CommandResults.swift`:

```swift
// MARK: - Chat

public struct ChatMessageInfo: Codable, Equatable, Sendable {
    public var id: UUID
    /// user, assistant o error.
    public var role: String
    public var text: String
    public var createdAt: Date
    /// "edited #2, added #4" (`nil` si no cambió nada).
    public var changes: String?
    public var undone: Bool
    public var notes: [String]
    /// Es el que ofrece "Undo".
    public var undoable: Bool

    public init(id: UUID, role: String, text: String, createdAt: Date, changes: String?, undone: Bool, notes: [String],
                undoable: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.changes = changes
        self.undone = undone
        self.notes = notes
        self.undoable = undoable
    }
}

public struct ChatInfo: Codable, Equatable, Sendable {
    public var pr: String
    /// review o respond.
    public var kind: String
    public var readOnly: Bool
    public var running: Bool
    public var lockReason: String?
    public var messages: [ChatMessageInfo]
    /// La respuesta ya se mostró en streaming (`chat send`): la CLI no la repite.
    public var streamed: Bool

    public init(pr: String, kind: String, readOnly: Bool, running: Bool, lockReason: String?, messages: [ChatMessageInfo],
                streamed: Bool = false) {
        self.pr = pr
        self.kind = kind
        self.readOnly = readOnly
        self.running = running
        self.lockReason = lockReason
        self.messages = messages
        self.streamed = streamed
    }
}
```

En `CommandActions.swift`:

```swift
@MainActor
public protocol ChatCommandActions: AnyObject {
    func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo
    func chatShow(pr: String) throws -> ChatInfo
    func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo
    func chatStop(pr: String) throws -> ChatInfo
}
```

y la composición pasa a `public typealias PRBarActions = StatusActions & ReviewActions & RespondActions & ConfigActions & SlackActions & ChatCommandActions`.

En `CommandDispatcher.perform`, antes del cierre del `switch`:

```swift
        // Chat
        case .chatSend(let pr, let message):
            return try encode(await actions.chatSend(pr: pr, message: message, events: events))
        case .chatShow(let pr):
            return try encode(actions.chatShow(pr: pr))
        case .chatUndo(let pr, let confirmed):
            return try encode(await actions.chatUndo(pr: pr, confirmed: confirmed))
        case .chatStop(let pr):
            return try encode(actions.chatStop(pr: pr))
```

En `FakeActions`, agregar `ChatCommandActions` a la lista de conformidades y:

```swift
    // MARK: ChatCommandActions
    private func chatInfo(_ pr: String) -> ChatInfo {
        ChatInfo(pr: pr, kind: "review", readOnly: false, running: false, lockReason: nil, messages: [])
    }
    func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo {
        try record("chatSend \(pr) \(message)"); emit(events); return chatInfo(pr)
    }
    func chatShow(pr: String) throws -> ChatInfo { try record("chatShow \(pr)"); return chatInfo(pr) }
    func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo { try record("chatUndo \(pr) \(confirmed)"); return chatInfo(pr) }
    func chatStop(pr: String) throws -> ChatInfo { try record("chatStop \(pr)"); return chatInfo(pr) }
```

- [ ] **Step 3: `Sources/PRBar/AppModel+Chat.swift`**

```swift
import Foundation
import PRBarCore

extension AppModel: ChatCommandActions {
    /// El coordinador del chat del PR: el del review listo (PR ajeno) o el del análisis de Respond (PR propio).
    private func chatCoordinator(_ prID: String) throws -> ChatCoordinator {
        if case .ready(let draft)? = reviews.phases[prID] { return reviewChat(for: draft) }
        if let record = respond.records[prID] { return respondChat(for: record.draft) }
        throw CommandFailure(.invalidState, "There’s no ready review or Respond analysis of \(prID) to chat about. Run `prbar review \(prID)` or `prbar respond \(prID)`.")
    }

    private func chatInfo(_ prID: String, _ chat: ChatCoordinator, streamed: Bool = false) -> ChatInfo {
        let undoable = chat.session.undoableMessageID
        let messages = chat.session.messages.map { message in
            ChatMessageInfo(id: message.id, role: message.role.rawValue, text: message.text, createdAt: message.createdAt,
                            changes: message.changes.isEmpty ? nil : ChatActions.summary(message.changes, number: chat.number(of:)),
                            undone: message.undone, notes: message.notes, undoable: message.id == undoable)
        }
        return ChatInfo(pr: prID, kind: chat.session.kind.rawValue, readOnly: chat.session.readOnly, running: chat.isRunning,
                        lockReason: chat.lockReason, messages: messages, streamed: streamed)
    }

    /// Lo que en la ventana bloquea el chat (el panel lo pone con `setLock`): sin ventana abierta se calcula acá.
    private func chatBusyReason(_ prID: String) -> String? {
        if respond.runningTests.contains(prID) { return "Wait for the tests to finish." }
        if let phase = respond.phases[prID], phase.isActive { return "Wait: PRBar is working on this PR (\(phase.cliName))." }
        return nil
    }

    func chatSend(pr: String, message: String, events: CommandEventSink) async throws -> ChatInfo {
        let id = try resolvePRID(pr)
        guard chatEnabled else { throw CommandFailure(.invalidState, "The chat is off. Turn it on with `prbar claude set --chat on`.") }
        if let reason = chatUnavailableReason { throw CommandFailure(.invalidState, reason) }
        let chat = try chatCoordinator(id)
        if chat.session.readOnly { throw CommandFailure(.invalidState, "This conversation is read only (the review was posted or the fixes pushed).") }
        if chat.isRunning { throw CommandFailure(.invalidState, "Claude is still answering. Wait, or stop it with `prbar chat \(id) --stop`.") }
        if let reason = chat.lockReason ?? chatBusyReason(id) { throw CommandFailure(.invalidState, reason) }
        guard chat.send(message) else { throw CommandFailure(.invalidUsage, "Write a message.") }
        var streamed = ""
        var activity: String?
        while chat.isRunning {
            let partial = chat.partialText
            if partial.count > streamed.count, partial.hasPrefix(streamed) {
                events(.text(delta: String(partial.dropFirst(streamed.count))))
                streamed = partial
            }
            if chat.activity != activity {
                activity = chat.activity
                if let activity { events(.progress(message: activity)) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return chatInfo(id, chat, streamed: !streamed.isEmpty)
    }

    func chatShow(pr: String) throws -> ChatInfo {
        let id = try resolvePRID(pr)
        return chatInfo(id, try chatCoordinator(id))
    }

    func chatUndo(pr: String, confirmed: Bool) async throws -> ChatInfo {
        let id = try resolvePRID(pr)
        let chat = try chatCoordinator(id)
        guard chat.canUndo, let message = chat.session.undoableMessageID else {
            throw CommandFailure(.invalidState, "There’s nothing to undo.")
        }
        if !confirmed, await chat.undoDiscardsLaterEdits(message) {
            throw CommandFailure(.confirmationRequired, "Undo will also discard your manual edits since then.")
        }
        chat.undo(message)
        // En Respond, deshacer archivos corre como un job más.
        while chat.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        return chatInfo(id, chat)
    }

    func chatStop(pr: String) throws -> ChatInfo {
        let id = try resolvePRID(pr)
        let chat = try chatCoordinator(id)
        guard chat.isRunning else { throw CommandFailure(.invalidState, "Claude isn’t answering anything in \(id).") }
        chat.stop()
        return chatInfo(id, chat)
    }
}
```

En `AppModel+Settings.swift`, `claudeSet`: el modelo del chat se valida igual que `model` y se aplica:

```swift
        var chatModel: ClaudeModel??
        if let change = changes.chatModel {
            switch change {
            case .clear:
                chatModel = .some(nil)
            case .set(let name):
                guard let parsed = ClaudeModel(rawValue: name.lowercased()) else {
                    throw CommandFailure(.invalidUsage, "Unknown chat model \(name): use opus, sonnet, haiku or same.")
                }
                chatModel = .some(parsed)
            }
        }
```

y dentro del `applyConfig`: `if let on = changes.chatEnabled { config.claude.chatEnabled = on }` y `if let chatModel { config.claude.chatModel = chatModel }`.

- [ ] **Step 4: CLI**

En `ConfigCommands.swift`, `ClaudeSet` suma:

```swift
    @Option(help: "Chat with Claude in Review and Respond windows: on or off.") var chat: OnOff?
    @Option(help: "Chat model: opus, sonnet, haiku or same (as the review).") var chatModel: String?
```

y en `changes`: `chatEnabled: chat?.isOn, chatModel: chatModel.map { $0.lowercased() == "same" ? .clear : .set(value: $0) }`. `ClaudeRender.settings` agrega `("Chat", Render.onOff(settings.chatEnabled))` y `("Chat model", settings.chatModel?.rawValue ?? "same as review")`.

`Sources/PRBarCLIKit/ChatCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCore

enum ChatRender {
    static func message(_ message: ChatMessageInfo, _ output: Output) {
        switch message.role {
        case "user": output.line(output.paint("you› ", .bold) + message.text)
        case "error": output.line(output.paint("! " + message.text, .red))
        default: output.line(output.paint("claude› ", .violet, .bold) + message.text)
        }
        if let changes = message.changes {
            output.line(output.paint("  \(changes)\(message.undone ? " (undone)" : message.undoable ? " · undo: prbar chat <pr> --undo" : "")", .dim))
        }
        message.notes.forEach { output.line(output.paint("  \($0)", .dim)) }
    }

    static func transcript(_ info: ChatInfo, _ output: Output) {
        if info.messages.isEmpty { output.line(output.paint("No messages yet.", .dim)) }
        info.messages.forEach { message($0, output) }
        if info.readOnly { output.line(output.paint("Read only.", .dim)) }
        if let lock = info.lockReason { output.line(output.paint(lock, .yellow)) }
    }

    /// Después de `chat send`: la respuesta (si no se vio en streaming) y sus cambios.
    static func reply(_ info: ChatInfo, _ output: Output) {
        guard let last = info.messages.last(where: { $0.role != "user" }) else { return }
        if info.streamed && last.role == "assistant" {
            output.line()
            if let changes = last.changes { output.line(output.paint("  \(changes)", .dim)) }
            last.notes.forEach { output.line(output.paint("  \($0)", .dim)) }
        } else {
            message(last, output)
        }
    }
}

struct ChatCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat", abstract: "Chat with Claude about a review or a Respond analysis.",
        discussion: "Without a message, in a terminal: an interactive chat (/undo, /show, /stop, /quit). Without a terminal the message is read from stdin.")
    @Argument(help: prHelp) var pr: String
    @Argument(help: "The message.") var message: String?
    @Flag(help: "Undo the last change Claude made.") var undo = false
    @Flag(help: "Print the conversation.") var show = false
    @Flag(help: "Stop the answer that’s running.") var stop = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [message != nil, undo, show, stop].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use one of: a message, --undo, --show or --stop.")
        }
    }

    mutating func prepare(_ connection: AppConnection, _ output: Output) throws {
        guard message == nil, !undo, !show, !stop else { return }
        message = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if undo { return .chatUndo(pr: pr, confirmed: confirmed) }
        if show { return .chatShow(pr: pr) }
        if stop { return .chatStop(pr: pr) }
        return .chatSend(pr: pr, message: message ?? "")
    }

    var cancelCommand: AppCommand? { message != nil ? .chatStop(pr: pr) : nil }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: ChatInfo = try result.decode()
        if show { ChatRender.transcript(info, output) } else if stop { output.line("Stopped.") } else { ChatRender.reply(info, output) }
    }

    mutating func run() throws {
        let terminal = Terminal.current()
        if message == nil && !undo && !show && !stop && terminal.isInteractive && !global.json {
            return try ChatREPL.run(pr: pr)
        }
        do {
            try CLIRunner.run(self)
        } catch let exit as ExitCode where exit.rawValue == CLIExit.confirmationRequired && undo && terminal.isInteractive {
            // B.6: deshacer pisaría ediciones manuales; la app lo dijo y acá se pregunta.
            guard Prompt.confirm("Undo anyway?") else { throw ExitCode(CLIExit.cancelled) }
            var confirmed = self
            confirmed.global.yes = true
            try CLIRunner.run(confirmed)
        }
    }
}

/// `prbar chat <pr>` en una terminal: la conversación con streaming. Ctrl-C mientras Claude contesta lo detiene
/// (y sale con 130); Ctrl-D o `/quit` salen. Una línea que termina en `\` sigue en la próxima.
enum ChatREPL {
    static func run(pr: String) throws {
        let environment = CLIEnvironment.live
        let output = Output(terminal: environment.terminal, json: false)
        do {
            let connection = try environment.connect()
            defer { connection.close() }
            ChatRender.transcript(try connection.run(.chatShow(pr: pr)).decode(), output)
            output.note("Type a message (end a line with \\ to continue). /undo, /show, /stop, /quit.")
            while true {
                output.write(output.paint("you› ", .bold))
                guard var text = readLine() else { output.line(); return }
                while text.hasSuffix("\\"), let more = readLine() { text = String(text.dropLast()) + "\n" + more }
                switch text.trimmingCharacters(in: .whitespaces) {
                case "":
                    continue
                case "/quit", "/exit":
                    return
                case "/show":
                    ChatRender.transcript(try connection.run(.chatShow(pr: pr)).decode(), output)
                case "/stop":
                    _ = try? connection.run(.chatStop(pr: pr))
                case "/undo":
                    do {
                        ChatRender.transcript(try connection.run(.chatUndo(pr: pr, confirmed: false)).decode(), output)
                    } catch let failure as CommandFailure where failure.code == .confirmationRequired {
                        if Prompt.confirm("\(failure.message) Undo anyway?") {
                            ChatRender.transcript(try connection.run(.chatUndo(pr: pr, confirmed: true)).decode(), output)
                        }
                    } catch let failure as CommandFailure {
                        output.error(failure.message)
                    }
                default:
                    let interrupt = InterruptHandler(cancel: .chatStop(pr: pr), connect: environment.connect, err: environment.err)
                    defer { interrupt.remove() }
                    output.write(output.paint("claude› ", .violet, .bold))
                    do {
                        let info: ChatInfo = try connection.run(.chatSend(pr: pr, message: text)) { output.event($0) }.decode()
                        ChatRender.reply(info, output)
                    } catch let failure as CommandFailure {
                        output.line()
                        output.error(failure.message)
                    }
                }
            }
        } catch let unavailable as AppUnavailable {
            output.error(unavailable.message)
            throw ExitCode(CLIExit.appUnavailable)
        } catch let failure as CommandFailure {
            output.error(failure.message)
            throw ExitCode(CLIExit.code(for: failure))
        }
    }
}
```

`GlobalOptions.yes` es `@Flag public var yes`: asignable (`confirmed.global.yes = true`).

Agregar `ChatCommand.self` a los subcomandos de `PRBarCommand`, y en `CLIRouter.commands`:

```swift
        // Chat (plan 6)
        .init("chat", [.chatSend, .chatShow, .chatUndo, .chatStop],
              ["chat", "api#1", "hi"], ["chat", "api#1", "--show"], ["chat", "api#1", "--undo"], ["chat", "api#1", "--stop"]),
```

`claude set` en la tabla agrega el ejemplo `["claude", "set", "--chat", "on"]` (sigue produciendo `.claudeSet`).

- [ ] **Step 5: Inventario**

En `UIActionInventory.entries`, cambiar cada `.deferred("Task 26")` por su comando: el campo de texto y el botón de enviar → `.cli(["chat"])`; "Stop" → `.cli(["chat"])` (`--stop`); "Undo" → `.cli(["chat"])` (`--undo`); "Show Log" del mensaje de error → `.cli(["history show"])`; el botón de toolbar Chat → `.cli(["chat"])` (`--show` imprime la conversación; mostrar u ocultar el panel es de vista); la conversación del historial (`DisclosureGroup`) → `.cli(["chat"])`; el `Toggle` "Chat with Claude in Review and Respond windows" y el `Picker("Model")` de la sección Chat → `.cli(["claude set"])`.

- [ ] **Step 6: Docs**

En `docs/cli.md`, tabla de comandos:

```markdown
| `prbar chat <pr> ["message"]` | Chat with Claude about the review or the Respond analysis; without a message in a terminal, an interactive chat (`/undo`, `/show`, `/stop`, `/quit`); without a terminal the message comes from stdin |
| `prbar chat <pr> --undo [--yes]\|--show\|--stop` | Undo Claude’s last change (asks if it would discard your manual edits), print the conversation, stop the answer |
| `prbar claude set [--chat on\|off] [--chat-model M\|same]` | The chat’s settings |
```

- [ ] **Step 7: Correr y verificar**

Run: `swift run PRBarTests`
Expected: todo pasa (incluidas las dos paridades).

Manual: con un review listo, `prbar chat <pr> "¿por qué el #2 es un bug?"` muestra la respuesta en streaming y, si cambió algo, "edited #2 · undo: …"; la ventana resalta lo mismo. `prbar chat <pr>` abre el REPL; Ctrl-C mientras contesta lo detiene. `prbar chat <pr> --undo` deshace.

- [ ] **Step 8: Commit**

```bash
git add Sources/PRBarCore Sources/PRBar/AppModel+Chat.swift Sources/PRBar/AppModel+Settings.swift Sources/PRBarCLIKit Sources/PRBarTests docs/cli.md
git commit -m "Add prbar chat commands on top of the chat coordinator"
```

---

### Task 27: Actualizaciones (`prbar update …`, D.4) — asume el plan 8

**APIs del plan 8 que usa esta task** (Task 11 del plan 8, `AppModel+Updates.swift`; si algún nombre cambió al implementarlo, usar el real):
- `AppModel.appVersion: String`, `checkForUpdates() async -> UpdateCheckOutcome` (`.upToDate(installed: SemanticVersion)`, `.available(ReleaseInfo)`, `.failed(String)`), `installUpdate(_ release: ReleaseInfo, whenBusy: UpdateBusyPolicy, onEvent: ((UpdateEvent) -> Void)?) async throws`, `skipUpdate(_ release: ReleaseInfo)`, `updates: UpdateController` (`installState`, `cancelInstall()`, `available`).
- `ReleaseInfo` (`version: SemanticVersion`, `tag`, `title`, `notes`, `url`), `SemanticVersion.description`, `UpdateBusyPolicy` (`.wait`, `.cancelJobs`), `UpdateEvent` (`.phase(UpdatePhase)` con `title`, `.log(String)`).
- `AppConfig.updates: UpdateSettings` (`checkIntervalHours`, `skippedVersion: String?`), `AppPaths.updateLog`.
- La app se reinicia sola al terminar de instalar: la conexión de la CLI se corta y hay que reconectar.

**Files:**
- Modify: `Sources/PRBarCore/AppCommand.swift`, `Sources/PRBarCore/CommandResults.swift` (`UpdateInfo`), `Sources/PRBarCore/CommandActions.swift`, `Sources/PRBarCore/CommandDispatcher.swift`, `Sources/PRBarCLIKit/ConfigCommands.swift` (`config set update-interval`), `Sources/PRBarCLIKit/StatusCommands.swift` (`app logs --update`), `Sources/PRBarCLIKit/CLIRouter.swift`, `Sources/PRBarCLIKit/PRBarCLIKit.swift`, `Sources/PRBarTests/{AppCommandTests,FakeActions,CommandDispatcherTests,CLIParsingTests,UIActionInventory}.swift`, `docs/cli.md`
- Create: `Sources/PRBar/AppModel+UpdateCommands.swift`, `Sources/PRBarCLIKit/UpdateCommands.swift`

- [ ] **Step 1: Tests que fallan**

Conteo de `AppCommand.Name.allCases`: `78`. En `dispatchSamples`:

```swift
    (.updateCheck, "updateCheck"),
    (.updateInstall(confirmed: true, cancelJobs: false), "updateInstall"),
    (.updateCancel, "updateCancel"),
    (.updateSkip(version: nil), "updateSkip"),
    (.setUpdateInterval(hours: 24), "configSetUpdateInterval"),
```

y en `CommandDispatcherTests.confirmations()`, agregar `.updateInstall(confirmed: false, cancelJobs: false)` a `unconfirmed`. En `CLIParsingTests.cases`:

```swift
            TestCase("cli parse: update") {
                try expectEqual(try parsed(["update", "--check"]), .updateCheck)
                try expectEqual(try parsed(["update", "--yes"]), .updateInstall(confirmed: true, cancelJobs: false))
                try expectEqual(try parsed(["update", "--cancel-jobs", "--yes"]), .updateInstall(confirmed: true, cancelJobs: true))
                try expectEqual(try parsed(["update", "--skip"]), .updateSkip(version: nil))
                try expectEqual(try parsed(["update", "--skip", "--skip-version", "1.3.0"]), .updateSkip(version: "1.3.0"))
                try expect(rejects(["update", "--skip-version", "1.3.0"]))
                try expectEqual(try parsed(["update", "--cancel"]), .updateCancel)
                try expect(rejects(["update", "--check", "--skip"]))
                try expectEqual(try parsed(["config", "set", "update-interval", "0"]), .setUpdateInterval(hours: 0))
            },
```

Run: `swift run PRBarTests`
Expected: no compila.

- [ ] **Step 2: Core**

`AppCommand`, después de los del chat:

```swift
    // Actualizaciones (spec D.4)
    case updateCheck
    /// "Update" (o "Cancel Jobs and Update" con `cancelJobs`). Reinicia la app.
    case updateInstall(confirmed: Bool, cancelJobs: Bool)
    case updateCancel
    /// "Skip This Version"; `nil` = la que se ofrece ahora.
    case updateSkip(version: String?)
    /// Settings › General › Updates: 0 = solo manual.
    case setUpdateInterval(hours: Int)
```

con sus `Name` (`updateCheck, updateInstall, updateCancel, updateSkip, setUpdateInterval`) y los `case` de `name`.

`CommandResults.swift`:

```swift
// MARK: - Actualizaciones

public struct UpdateInfo: Codable, Equatable, Sendable {
    public var installed: String
    /// La versión nueva, si hay.
    public var latest: String?
    public var title: String?
    public var notes: String?
    public var url: URL?
    public var skipped: Bool

    public init(installed: String, latest: String? = nil, title: String? = nil, notes: String? = nil, url: URL? = nil,
                skipped: Bool = false) {
        self.installed = installed
        self.latest = latest
        self.title = title
        self.notes = notes
        self.url = url
        self.skipped = skipped
    }

    public var isAvailable: Bool { latest != nil }
}
```

`CommandActions.swift`:

```swift
@MainActor
public protocol UpdateCommandActions: AnyObject {
    func updateCheck() async throws -> UpdateInfo
    func updateInstall(cancelJobs: Bool, events: CommandEventSink) async throws -> UpdateInfo
    func updateCancel() throws
    func updateSkip(version: String?) async throws -> UpdateInfo
    func configSetUpdateInterval(hours: Int) throws
}
```

y `PRBarActions` suma `& UpdateCommandActions`. En el dispatcher:

```swift
        // Actualizaciones
        case .updateCheck:
            return try encode(await actions.updateCheck())
        case .updateInstall(let confirmed, let cancelJobs):
            try requireConfirmation(confirmed, "Updating PRBar")
            return try encode(await actions.updateInstall(cancelJobs: cancelJobs, events: events))
        case .updateCancel:
            try actions.updateCancel()
            return .ok
        case .updateSkip(let version):
            return try encode(await actions.updateSkip(version: version))
        case .setUpdateInterval(let hours):
            try actions.configSetUpdateInterval(hours: hours)
            return .ok
```

En `FakeActions` (sumar `UpdateCommandActions` a las conformidades):

```swift
    // MARK: UpdateCommandActions
    func updateCheck() async throws -> UpdateInfo { try record("updateCheck"); return UpdateInfo(installed: "1.0.0") }
    func updateInstall(cancelJobs: Bool, events: CommandEventSink) async throws -> UpdateInfo {
        try record("updateInstall \(cancelJobs)"); return UpdateInfo(installed: "1.0.0")
    }
    func updateCancel() throws { try record("updateCancel") }
    func updateSkip(version: String?) async throws -> UpdateInfo { try record("updateSkip \(version ?? "-")"); return UpdateInfo(installed: "1.0.0") }
    func configSetUpdateInterval(hours: Int) throws { try record("configSetUpdateInterval \(hours)") }
```

- [ ] **Step 3: `Sources/PRBar/AppModel+UpdateCommands.swift`**

```swift
import Foundation
import PRBarCore

extension AppModel: UpdateCommandActions {
    private func updateInfo(_ outcome: UpdateCheckOutcome) throws -> UpdateInfo {
        switch outcome {
        case .upToDate(let installed):
            return UpdateInfo(installed: installed.description)
        case .available(let release):
            return UpdateInfo(installed: appVersion, latest: release.version.description, title: release.title,
                              notes: release.notes, url: release.url,
                              skipped: configStore.config.updates.skippedVersion == release.version.description)
        case .failed(let message):
            throw CommandFailure(.failed, message)
        }
    }

    /// "Check for Updates".
    func updateCheck() async throws -> UpdateInfo {
        try updateInfo(await checkForUpdates())
    }

    /// "Update" / "Cancel Jobs and Update". Si sale bien la app se reinicia (la CLI pierde la conexión y reconecta).
    func updateInstall(cancelJobs: Bool, events: CommandEventSink) async throws -> UpdateInfo {
        guard case .available(let release) = await checkForUpdates() else {
            throw CommandFailure(.invalidState, "PRBar is up to date (\(appVersion)).")
        }
        let sink = events
        try await installUpdate(release, whenBusy: cancelJobs ? .cancelJobs : .wait) { event in
            switch event {
            case .phase(let phase): sink(.progress(message: phase.title))
            case .log(let line): sink(.progress(message: line))
            }
        }
        return UpdateInfo(installed: appVersion, latest: release.version.description, title: release.title)
    }

    /// "Cancel" en la ventana de actualización.
    func updateCancel() throws {
        guard case .running = updates.installState else {
            throw CommandFailure(.invalidState, "No update is being installed.")
        }
        updates.cancelInstall()
    }

    /// "Skip This Version".
    func updateSkip(version: String?) async throws -> UpdateInfo {
        guard case .available(let release) = await checkForUpdates() else {
            throw CommandFailure(.invalidState, "There’s no new version to skip.")
        }
        if let version, version.trimmingCharacters(in: CharacterSet(charactersIn: "v")) != release.version.description {
            throw CommandFailure(.notFound, "The available version is \(release.version.description), not \(version).")
        }
        skipUpdate(release)
        return try updateInfo(.available(release))
    }

    /// "Check automatically" + "Frequency": 0 (apagado), 6, 12, 24 (diario) o 168 (semanal).
    func configSetUpdateInterval(hours: Int) throws {
        guard [0, 6, 12, 24, 168].contains(hours) else {
            throw CommandFailure(.invalidUsage, "The update interval is 0 (manual only), 6, 12, 24 or 168 hours.")
        }
        try applyConfig { $0.updates.checkIntervalHours = hours }
    }
}
```

Si en el plan 8 `UpdateController.InstallState` no es accesible desde la extensión (es interno de la app, debería serlo), ajustar el `guard`.

- [ ] **Step 4: CLI**

En `ConfigKey` agregar `case updateInterval = "update-interval"`, en `ConfigSet.appCommand`:

```swift
        case .updateInterval:
            guard let hours = Int(value) else { throw ValidationError("update-interval takes hours: 0 (manual only), 6, 12, 24 or 168.") }
            return .setUpdateInterval(hours: hours)
```

y en su `discussion`: `· update-interval 0|6|12|24|168 (hours; 0 = manual only)`.

En `AppLogs`, agregar `@Flag(help: "The last update’s log.") var update = false` y `let url = update ? AppPaths.updateLog : slack ? AppPaths.slackConnectorLog : AppPaths.logFile`.

`Sources/PRBarCLIKit/UpdateCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCore

struct UpdateCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update PRBar (and prbar) from the repo’s releases.",
        discussion: "--check exits with 0 if up to date and 10 if there’s a new version. Updating builds the new version (1–2 minutes) and restarts PRBar; without a terminal it needs --yes.")
    @Flag(help: "Only check.") var check = false
    @Flag(help: "Skip the version offered now (Skip This Version).") var skip = false
    @Option(name: .customLong("skip-version"), help: "With --skip: the version to skip (it must be the one offered).") var version: String?
    @Flag(help: "Cancel the update being installed.") var cancel = false
    @Flag(help: "Cancel running reviews and responses instead of waiting for them.") var cancelJobs = false
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        guard [check, skip, cancel].filter({ $0 }).count <= 1 else {
            throw ValidationError("Use only one of --check, --skip and --cancel.")
        }
        if version != nil && !skip { throw ValidationError("--skip-version goes with --skip.") }
    }

    private var installs: Bool { !check && !skip && !cancel }

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard installs else { return nil }
        let info: UpdateInfo = try connection.run(.updateCheck).decode()
        guard let latest = info.latest else { throw CommandFailure(.invalidState, "PRBar is up to date (\(info.installed)).") }
        if output.terminal.isInteractive && !output.json, let notes = info.notes, !notes.isEmpty {
            output.line(output.paint(info.title ?? "PRBar \(latest)", .bold))
            output.line(notes)
        }
        return "Update PRBar from \(info.installed) to \(latest)? It restarts PRBar."
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        if check { return .updateCheck }
        if cancel { return .updateCancel }
        if skip { return .updateSkip(version: version) }
        return .updateInstall(confirmed: confirmed, cancelJobs: cancelJobs)
    }

    var cancelCommand: AppCommand? { installs ? .updateCancel : nil }

    func render(_ result: JSONValue, _ output: Output) throws {
        if cancel { return output.line("Canceled the update.") }
        let info: UpdateInfo = try result.decode()
        if check {
            if let latest = info.latest {
                output.line("PRBar \(latest) is available (installed: \(info.installed))\(info.skipped ? " — skipped" : "").")
                if let notes = info.notes, !notes.isEmpty { output.line(notes) }
                throw ExitCode(CLIExit.updateAvailable)
            }
            return output.line("PRBar is up to date (\(info.installed)).")
        }
        if skip { return output.line("Skipped \(info.latest ?? "it"). PRBar will offer the next one.") }
        output.line("Installed \(info.latest ?? "the update"). PRBar is restarting…")
    }

    mutating func run() throws {
        do {
            try CLIRunner.run(self)
        } catch let exit as ExitCode where exit.rawValue == CLIExit.appUnavailable && installs {
            // Al terminar de instalar la app se reinicia y corta la conexión: esperar a la versión nueva.
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
                if let connection = try? AppConnection.connect() {
                    print("PRBar \(connection.appVersion) is running.")
                    connection.close()
                    return
                }
            }
            throw exit
        }
    }
}
```

Agregar `UpdateCommand.self` a `PRBarCommand` y a `CLIRouter.commands`:

```swift
        // Actualizaciones (plan 8)
        .init("update", [.updateCheck, .updateInstall, .updateCancel, .updateSkip],
              ["update", "--check"], ["update", "--yes"], ["update", "--cancel"], ["update", "--skip"]),
```

y el ejemplo `["config", "set", "update-interval", "24"]` en `config set` con `.setUpdateInterval` en su `produces`.

- [ ] **Step 5: Inventario**

Cambiar los `.deferred("Task 27")`: "Check for Updates" → `.cli(["update"])` (`--check`); "Check automatically" y "Frequency" → `.cli(["config set"])`; la fila del popover y "Update…" → `.cli(["update"])`; en la ventana "Update"/"Try Again", "Update When Done", "Cancel Jobs and Update" → `.cli(["update"])`; "Skip This Version" → `.cli(["update"])` (`--skip`); "Cancel" → `.cli(["update"])` (`--cancel`); "Show Log" → `.cli(["app logs"])` (`--update`); "Later", "Hide" y "OK" → `.viewOnly("closes the window")`.

- [ ] **Step 6: Docs**

En `docs/cli.md`, tabla de comandos:

```markdown
| `prbar update --check` | Exit 0 if up to date, 10 if there’s a new version (prints it and its notes) |
| `prbar update [--yes] [--cancel-jobs]` | Download, build and install the new version, then restart PRBar (progress in the terminal; Ctrl-C cancels) |
| `prbar update --skip [--skip-version V]` / `--cancel` | Skip This Version / cancel the update being installed |
| `prbar config set update-interval 0\|6\|12\|24\|168` | Check automatically (0 = manual only) |
| `prbar app logs --update` | The last update’s log |
```

y en "Interactive and scripts", `update` entre los que exigen `--yes` sin terminal.

- [ ] **Step 7: Correr y verificar**

Run: `swift run PRBarTests`
Expected: todo pasa.

Manual: `prbar update --check; echo $?` → 0 (o 10 con una versión publicada más nueva). Con una release de prueba (ver el QA del plan 8), `prbar update` muestra las notas, pregunta, imprime las etapas y, cuando la app se reinicia, "PRBar X is running.".

- [ ] **Step 8: Commit**

```bash
git add Sources/PRBarCore Sources/PRBar/AppModel+UpdateCommands.swift Sources/PRBarCLIKit Sources/PRBarTests docs/cli.md
git commit -m "Add prbar update commands"
```

---

### Task 28: Instrucciones, opciones de review/fixes y prompts (E.7) — asume el plan 9

> **Primero:** abrir `docs/superpowers/plans/2026-11-19-prbar-plan-9-instructions.md` y el código que dejó (Settings › Instructions, `instructions.json`, `ClaudeSettings.review`/`.respond`, prompts). Cuando se escribió este plan, el plan 9 todavía no existía: los nombres de abajo salen del spec (parte E). **Antes de escribir código, completar esta tabla con los nombres reales** y usarlos en el Step 3; el resto de la task (Core, CLI, router, inventario, docs) no depende de ellos.

| Lo que se necesita (spec E) | Nombre asumido | Nombre real (plan 9) |
|---|---|---|
| Una regla (E.1): `id`, `scope` (global / repo), `appliesTo` (`review`, `respond`), `text`, `source`, `enabled`, `createdAt`, `updatedAt` | `InstructionRule` | |
| Lista y cambios de reglas (validan, redactan tokens, guardan `instructions.json`) | `AppModel.instructions` con `rules`, `add(_:)`, `update(_:)`, `remove(id:)`, `setEnabled(id:_:)` | |
| Chat de instrucciones (E.2), mismo patrón que `ChatCoordinator` | `AppModel.instructionsChat` (`send`, `stop`, `undo`, `undoDiscardsLaterEdits`, `session`, `isRunning`, `partialText`) | |
| Tarjeta "Save as rule" de un mensaje del chat del PR (E.3) | `ChatMessage.proposals` + `AppModel.saveProposedRule(…)` / `dismissProposedRule(…)` | |
| Sugerencias (E.4): Create Rule / Not Now / Never | `AppModel.ruleSuggestions`, `accept(_:text:)`, `notNow(_:)`, `never(_:)` | |
| Opciones de review (E.5) | `ClaudeSettings.review` (`minSeverity`, `maxFindings`, `ignorePaths`, `categories`, `tone`, `stage1`, `filter`) | |
| Opciones de fixes (E.5) | `ClaudeSettings.respond` (`runTestsBeforePush`, `commitMode`, `commitMessageTemplate`, `allowNewTests`, `allowNewDependencies`, `replyTemplate`, `analysis`, `implementation`) | |
| Ignorados por repo (E.5) | `RepoConfig.ignorePaths` | |
| Prompts (E.6): por etapa, por defecto / propio, validación de variables | `PromptStage` + `ClaudeSettings.prompt(for:)`, `PromptTemplates.defaultPrompt(_:)`, `PromptTemplates.validate(_:stage:)` | |
| "Push Anyway" cuando los tests antes del push fallan (E.5) | `RespondQueue.publish(prID:ignoringFailedTests:)` | |

Comandos (spec E.7, más lo que la UI de E tiene y E.7 no lista: `rules chat --undo|--show|--stop`, `rules proposal save|dismiss` para las tarjetas "Save as rule", `respond push --anyway`, `claude respond set --commit-template/--reply-template`, `claude review set --uncategory`/`--unignore`, `repo set --unignore`):

```
prbar rules list [--repo R]
prbar rules add "text" [--repo R] [--review] [--fixes]
prbar rules edit <id> [--text T] [--repo R|--global] [--review|--no-review] [--fixes|--no-fixes]
prbar rules remove|enable|disable <id>
prbar rules chat ["message"] | --undo [--yes] | --show | --stop
prbar rules suggestions | accept <id> [--text T] | dismiss <id> | never <id>
prbar rules proposal save <pr> <n> [--text T] | dismiss <pr> <n>
prbar claude review set [--min-severity S] [--max-findings N|none] [--ignore G]… [--unignore G]… [--category C=on|off]… [--tone T]
prbar claude respond set [--tests-before-push on|off] [--commit-mode single|per-comment] [--commit-template T]
                         [--allow-tests on|off] [--allow-deps on|off] [--reply-template T|default]
prbar claude stage <review|filter|analysis|implementation> --skill S | --prompt-file F | --default
prbar claude prompt show|edit|reset <stage>          # + chat-review, chat-respond, chat-instructions
prbar repo set <repo> --ignore G… --unignore G…
prbar respond push <pr> --anyway [--yes]
```

**Files:**
- Modify: `Sources/PRBarCore/{AppCommand,AppCommandTypes,CommandResults,CommandActions,CommandDispatcher}.swift`, `Sources/PRBarCLIKit/{ConfigCommands,RespondCommands,CLIRouter,PRBarCLIKit}.swift`, `Sources/PRBar/AppModel+Settings.swift` (`repoSet`: ignorados), `Sources/PRBarTests/{AppCommandTests,FakeActions,CommandDispatcherTests,CLIParsingTests,UIActionInventory}.swift`, `docs/cli.md`
- Create: `Sources/PRBar/AppModel+InstructionCommands.swift`, `Sources/PRBarCLIKit/RulesCommands.swift`

- [ ] **Step 1: Tests que fallan**

Conteo de `AppCommand.Name.allCases`: `97`. En `dispatchSamples`:

```swift
    (.rulesList(repo: nil), "rulesList"),
    (.rulesAdd(text: "No style comments", repo: nil, appliesTo: [.review]), "rulesAdd"),
    (.rulesEdit(id: "r1", text: "x", scope: nil, appliesTo: nil), "rulesEdit"),
    (.rulesRemove(id: "r1"), "rulesRemove"),
    (.rulesSetEnabled(id: "r1", enabled: false), "rulesSetEnabled"),
    (.rulesChatSend(message: "forget the console.log one"), "rulesChatSend"),
    (.rulesChatShow, "rulesChatShow"),
    (.rulesChatUndo(confirmed: false), "rulesChatUndo"),
    (.rulesChatStop, "rulesChatStop"),
    (.rulesSuggestions, "rulesSuggestions"),
    (.rulesSuggestionAct(id: "s1", action: .accept, text: nil), "rulesSuggestionAct"),
    (.chatProposal(pr: "api#1", number: 1, save: true, text: nil), "chatProposal"),
    (.claudeReviewSet(changes: ReviewOptionChanges(minSeverity: "medium")), "claudeReviewSet"),
    (.claudeRespondSet(changes: RespondOptionChanges(commitMode: "perComment")), "claudeRespondSet"),
    (.claudeStageSet(stage: .review, change: .useDefault), "claudeStageSet"),
    (.claudePromptShow(stage: .filter), "claudePromptShow"),
    (.claudePromptSet(stage: .filter, text: "…"), "claudePromptSet"),
    (.claudePromptReset(stage: .filter), "claudePromptReset"),
    (.respondPushAnyway(pr: "web#2", confirmed: true, wait: false), "respondPushAnyway"),
```

y `.respondPushAnyway(pr: "a#1", confirmed: false, wait: false)` en `unconfirmed`. En `CLIParsingTests.cases`:

```swift
            TestCase("cli parse: rules, opciones y prompts") {
                try expectEqual(try parsed(["rules", "list", "--repo", "acme/web"]), .rulesList(repo: "acme/web"))
                try expectEqual(try parsed(["rules", "add", "Use React Query", "--repo", "acme/web", "--fixes"]),
                                .rulesAdd(text: "Use React Query", repo: "acme/web", appliesTo: [.respond]))
                try expectEqual(try parsed(["rules", "add", "No style comments"]),
                                .rulesAdd(text: "No style comments", repo: nil, appliesTo: [.review, .respond]))
                try expectEqual(try parsed(["rules", "edit", "r1", "--global", "--no-fixes"]),
                                .rulesEdit(id: "r1", text: nil, scope: .global, appliesTo: [.review]))
                try expectEqual(try parsed(["rules", "disable", "r1"]), .rulesSetEnabled(id: "r1", enabled: false))
                try expectEqual(try parsed(["rules", "chat", "forget the console.log one"]), .rulesChatSend(message: "forget the console.log one"))
                try expectEqual(try parsed(["rules", "chat", "--undo", "--yes"]), .rulesChatUndo(confirmed: true))
                try expectEqual(try parsed(["rules", "suggestions"]), .rulesSuggestions)
                try expectEqual(try parsed(["rules", "suggestions", "never", "s1"]), .rulesSuggestionAct(id: "s1", action: .never, text: nil))
                try expectEqual(try parsed(["rules", "proposal", "save", "api#1", "1", "--text", "Edited"]),
                                .chatProposal(pr: "api#1", number: 1, save: true, text: "Edited"))
                try expectEqual(try parsed(["claude", "review", "set", "--min-severity", "medium", "--max-findings", "10",
                                            "--ignore", "generated/**", "--category", "style=off", "--tone", "friendly"]),
                                .claudeReviewSet(changes: ReviewOptionChanges(minSeverity: "medium", maxFindings: .set(value: "10"),
                                                                              addIgnore: ["generated/**"], categories: ["style": false],
                                                                              tone: "friendly")))
                try expectEqual(try parsed(["claude", "respond", "set", "--tests-before-push", "on", "--commit-mode", "per-comment", "--allow-deps", "off"]),
                                .claudeRespondSet(changes: RespondOptionChanges(runTestsBeforePush: true, commitMode: "perComment",
                                                                                allowNewDependencies: false)))
                try expectEqual(try parsed(["claude", "stage", "filter", "--default"]), .claudeStageSet(stage: .filter, change: .useDefault))
                try expectEqual(try parsed(["claude", "stage", "review", "--skill", "a:b"]), .claudeStageSet(stage: .review, change: .skill(name: "a:b")))
                try expectEqual(try parsed(["claude", "prompt", "reset", "chat-review"]), .claudePromptReset(stage: .chatReview))
                try expect(rejects(["claude", "stage", "filter", "--default", "--skill", "x"]))
                guard case .repoSet(_, _, let changes) = try parsed(["repo", "set", "acme/web", "--ignore", "dist/**", "--unignore", "gen/**"]) else {
                    throw TestFailure(description: "repo set")
                }
                try expectEqual(changes.addIgnore, ["dist/**"])
                try expectEqual(changes.removeIgnore, ["gen/**"])
                try expectEqual(try parsed(["respond", "push", "web#2", "--anyway", "--yes"]), .respondPushAnyway(pr: "web#2", confirmed: true, wait: false))
            },
```

Run: `swift run PRBarTests`
Expected: no compila.

- [ ] **Step 2: Core**

`AppCommandTypes.swift`:

```swift
/// A qué etapas se aplica una regla (E.1): `review` (review, filtro y chat de review) y `respond` (análisis, fixes y
/// chat de respond; en la CLI, `--fixes`).
public enum RuleStage: String, Codable, CaseIterable, Sendable { case review, respond }

public enum RuleScopeChange: Codable, Equatable, Sendable {
    case global
    case repo(name: String)
}

public enum SuggestionAction: String, Codable, CaseIterable, Sendable {
    /// Create Rule.
    case accept
    /// Not Now.
    case dismiss
    /// Never.
    case never
}

/// Etapas con prompt editable (E.6). Las cuatro primeras también eligen skill o prompt (`claude stage`).
public enum PromptStageName: String, Codable, CaseIterable, Sendable {
    case review, filter, analysis, implementation
    case chatReview = "chat-review", chatRespond = "chat-respond", chatInstructions = "chat-instructions"

    public var hasSkill: Bool { [.review, .filter, .analysis, .implementation].contains(self) }
}

public enum StageChange: Codable, Equatable, Sendable {
    case skill(name: String)
    case prompt(text: String)
    case useDefault
}

/// `prbar claude review set` (E.5). `nil` = no se toca. Severidad y tono como texto: los valida la app.
public struct ReviewOptionChanges: Codable, Equatable, Sendable {
    public var minSeverity: String?
    /// `.clear` = sin máximo.
    public var maxFindings: ValueChange?
    public var addIgnore: [String]
    public var removeIgnore: [String]
    public var categories: [String: Bool]
    public var tone: String?

    public init(minSeverity: String? = nil, maxFindings: ValueChange? = nil, addIgnore: [String] = [],
                removeIgnore: [String] = [], categories: [String: Bool] = [:], tone: String? = nil) {
        self.minSeverity = minSeverity
        self.maxFindings = maxFindings
        self.addIgnore = addIgnore
        self.removeIgnore = removeIgnore
        self.categories = categories
        self.tone = tone
    }

    public var isEmpty: Bool { self == ReviewOptionChanges() }
}

/// `prbar claude respond set` (E.5).
public struct RespondOptionChanges: Codable, Equatable, Sendable {
    public var runTestsBeforePush: Bool?
    /// `single` o `perComment`.
    public var commitMode: String?
    public var commitMessageTemplate: String?
    public var allowNewTests: Bool?
    public var allowNewDependencies: Bool?
    /// `.clear` = el "Fixed in …" por defecto.
    public var replyTemplate: ValueChange?

    public init(runTestsBeforePush: Bool? = nil, commitMode: String? = nil, commitMessageTemplate: String? = nil,
                allowNewTests: Bool? = nil, allowNewDependencies: Bool? = nil, replyTemplate: ValueChange? = nil) {
        self.runTestsBeforePush = runTestsBeforePush
        self.commitMode = commitMode
        self.commitMessageTemplate = commitMessageTemplate
        self.allowNewTests = allowNewTests
        self.allowNewDependencies = allowNewDependencies
        self.replyTemplate = replyTemplate
    }

    public var isEmpty: Bool { self == RespondOptionChanges() }
}
```

En `RepoChanges`, agregar `public var addIgnore: [String]` y `public var removeIgnore: [String]` (parámetros `addIgnore: [String] = [], removeIgnore: [String] = []` al final del `init`). El JSON del primer test de `AppCommandTests` gana `"addIgnore":[]` y `"removeIgnore":[]`: actualizar ese literal.

`AppCommand` (con sus `Name` y los `case` de `name`):

```swift
    // Instrucciones, opciones y prompts (spec E.7)
    case rulesList(repo: String?)
    case rulesAdd(text: String, repo: String?, appliesTo: [RuleStage])
    case rulesEdit(id: String, text: String?, scope: RuleScopeChange?, appliesTo: [RuleStage]?)
    case rulesRemove(id: String)
    case rulesSetEnabled(id: String, enabled: Bool)
    case rulesChatSend(message: String)
    case rulesChatShow
    case rulesChatUndo(confirmed: Bool)
    case rulesChatStop
    case rulesSuggestions
    case rulesSuggestionAct(id: String, action: SuggestionAction, text: String?)
    /// La tarjeta "Save as rule" número `number` (desde 1, entre las pendientes del chat del PR).
    case chatProposal(pr: String, number: Int, save: Bool, text: String?)
    case claudeReviewSet(changes: ReviewOptionChanges)
    case claudeRespondSet(changes: RespondOptionChanges)
    case claudeStageSet(stage: PromptStageName, change: StageChange)
    case claudePromptShow(stage: PromptStageName)
    case claudePromptSet(stage: PromptStageName, text: String)
    case claudePromptReset(stage: PromptStageName)
    /// "Push Anyway": los tests antes del push fallaron y el usuario pushea igual.
    case respondPushAnyway(pr: String, confirmed: Bool, wait: Bool)
```

`CommandResults.swift`:

```swift
// MARK: - Instrucciones

public struct RuleInfo: Codable, Equatable, Sendable {
    public var id: String
    /// `global` o `owner/repo`.
    public var scope: String
    public var appliesTo: [RuleStage]
    public var text: String
    /// manual, settingsChat, prChat o suggestion.
    public var source: String
    public var enabled: Bool
    public var updatedAt: Date

    public init(id: String, scope: String, appliesTo: [RuleStage], text: String, source: String, enabled: Bool, updatedAt: Date) {
        self.id = id
        self.scope = scope
        self.appliesTo = appliesTo
        self.text = text
        self.source = source
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

public struct RuleSuggestionInfo: Codable, Equatable, Sendable {
    public var id: String
    public var scope: String
    public var category: String
    /// "You usually discard style comments in acme/web-app."
    public var reason: String
    public var proposedText: String

    public init(id: String, scope: String, category: String, reason: String, proposedText: String) {
        self.id = id
        self.scope = scope
        self.category = category
        self.reason = reason
        self.proposedText = proposedText
    }
}

public struct PromptInfo: Codable, Equatable, Sendable {
    public var stage: PromptStageName
    public var text: String
    public var isDefault: Bool
    /// Variables que tiene que usar (`{diff_path}`, …).
    public var requiredVariables: [String]

    public init(stage: PromptStageName, text: String, isDefault: Bool, requiredVariables: [String]) {
        self.stage = stage
        self.text = text
        self.isDefault = isDefault
        self.requiredVariables = requiredVariables
    }
}
```

`CommandActions.swift`:

```swift
@MainActor
public protocol InstructionCommandActions: AnyObject {
    func rulesList(repo: String?) throws -> [RuleInfo]
    func rulesAdd(text: String, repo: String?, appliesTo: [RuleStage]) throws -> RuleInfo
    func rulesEdit(id: String, text: String?, scope: RuleScopeChange?, appliesTo: [RuleStage]?) throws -> RuleInfo
    func rulesRemove(id: String) throws
    func rulesSetEnabled(id: String, enabled: Bool) throws
    func rulesChatSend(message: String, events: CommandEventSink) async throws -> ChatInfo
    func rulesChatShow() -> ChatInfo
    func rulesChatUndo(confirmed: Bool) async throws -> ChatInfo
    func rulesChatStop() throws -> ChatInfo
    func rulesSuggestions() -> [RuleSuggestionInfo]
    func rulesSuggestionAct(id: String, action: SuggestionAction, text: String?) throws -> [RuleInfo]
    func chatProposal(pr: String, number: Int, save: Bool, text: String?) throws -> ChatInfo
    func claudeReviewSet(changes: ReviewOptionChanges) throws -> ClaudeSettings
    func claudeRespondSet(changes: RespondOptionChanges) throws -> ClaudeSettings
    func claudeStageSet(stage: PromptStageName, change: StageChange) throws -> ClaudeSettings
    func claudePromptShow(stage: PromptStageName) -> PromptInfo
    func claudePromptSet(stage: PromptStageName, text: String) throws -> PromptInfo
    func claudePromptReset(stage: PromptStageName) throws -> PromptInfo
    func respondPushAnyway(pr: String, wait: Bool, events: CommandEventSink) async throws -> RespondInfo
}
```

`PRBarActions` suma `& InstructionCommandActions`. En el dispatcher, un `case` por comando, como los anteriores (los que no devuelven nada contestan `.ok`; `respondPushAnyway` hace antes `try requireConfirmation(confirmed, "Pushing despite failed tests")`):

```swift
        // Instrucciones, opciones y prompts
        case .rulesList(let repo): return try encode(actions.rulesList(repo: repo))
        case .rulesAdd(let text, let repo, let stages): return try encode(actions.rulesAdd(text: text, repo: repo, appliesTo: stages))
        case .rulesEdit(let id, let text, let scope, let stages):
            return try encode(actions.rulesEdit(id: id, text: text, scope: scope, appliesTo: stages))
        case .rulesRemove(let id): try actions.rulesRemove(id: id); return .ok
        case .rulesSetEnabled(let id, let enabled): try actions.rulesSetEnabled(id: id, enabled: enabled); return .ok
        case .rulesChatSend(let message): return try encode(await actions.rulesChatSend(message: message, events: events))
        case .rulesChatShow: return try encode(actions.rulesChatShow())
        case .rulesChatUndo(let confirmed): return try encode(await actions.rulesChatUndo(confirmed: confirmed))
        case .rulesChatStop: return try encode(actions.rulesChatStop())
        case .rulesSuggestions: return try encode(actions.rulesSuggestions())
        case .rulesSuggestionAct(let id, let action, let text):
            return try encode(actions.rulesSuggestionAct(id: id, action: action, text: text))
        case .chatProposal(let pr, let number, let save, let text):
            return try encode(actions.chatProposal(pr: pr, number: number, save: save, text: text))
        case .claudeReviewSet(let changes): return try encode(actions.claudeReviewSet(changes: changes))
        case .claudeRespondSet(let changes): return try encode(actions.claudeRespondSet(changes: changes))
        case .claudeStageSet(let stage, let change): return try encode(actions.claudeStageSet(stage: stage, change: change))
        case .claudePromptShow(let stage): return try encode(actions.claudePromptShow(stage: stage))
        case .claudePromptSet(let stage, let text): return try encode(actions.claudePromptSet(stage: stage, text: text))
        case .claudePromptReset(let stage): return try encode(actions.claudePromptReset(stage: stage))
        case .respondPushAnyway(let pr, let confirmed, let wait):
            try requireConfirmation(confirmed, "Pushing despite failed tests")
            return try encode(await actions.respondPushAnyway(pr: pr, wait: wait, events: events))
```

`FakeActions` suma `InstructionCommandActions` con un método por requisito que anota su nombre (`try record("rulesList")`, …) y devuelve `[]`, `RuleInfo(id: "r1", scope: "global", appliesTo: [.review], text: "x", source: "manual", enabled: true, updatedAt: t0)`, `ClaudeSettings()`, `PromptInfo(stage: stage, text: "", isDefault: true, requiredVariables: [])`, `ChatInfo(pr: "", kind: "instructions", readOnly: false, running: false, lockReason: nil, messages: [])` o `respondInfo(pr)` según el tipo.

- [ ] **Step 3: `AppModel+InstructionCommands.swift`**

Implementar `InstructionCommandActions` en `AppModel` con los nombres reales de la tabla de arriba. Reglas de cada método (mismas guardas y textos que la UI del plan 9, más el comando sugerido):

- `rulesList(repo:)`: las reglas (globales + las del repo si se pide `--repo`, que tiene que estar configurado: si no, `notFound` con "Run `prbar repo list`"), convertidas a `RuleInfo` (`scope` = `"global"` o el `owner/repo`).
- `rulesAdd`: `text` no vacío y ≤ 1 000 caracteres (`invalidUsage`), repo configurado; `source = manual`; devuelve la regla creada.
- `rulesEdit`: id existente (acepta el id completo o un prefijo único de ≥ 4 caracteres, como `history show`); cambia solo lo pedido; `appliesTo` no puede quedar vacío.
- `rulesRemove` / `rulesSetEnabled`: id existente.
- `rulesChat*`: igual que `chatSend`/`chatShow`/`chatUndo`/`chatStop` de la Task 26 (copiar esos cuerpos cambiando el coordinador por el del chat de instrucciones; `kind` del `ChatInfo` = `"instructions"`, `pr` = `""`).
- `rulesSuggestions`: las sugerencias activas → `RuleSuggestionInfo`. `rulesSuggestionAct`: `accept` crea la regla (con `text` si vino, si no el propuesto; `source = suggestion`), `dismiss` = Not Now, `never` = Never; devuelve `rulesList(repo: nil)`.
- `chatProposal(pr:number:save:text:)`: el coordinador del PR (`chatCoordinator(_:)` de la Task 26, que pasa a ser interno), las propuestas pendientes de sus mensajes numeradas desde 1; `save` guarda (con `text` si vino; `source = prChat`), si no la descarta. Número inexistente → `notFound` "Run `prbar chat <pr> --show`".
- `claudeReviewSet`: valida `minSeverity` (`high`/`medium`/`low`), `maxFindings` (entero ≥ 1 o `.clear`), categorías conocidas (las de E.4: `bug`, `security`, `performance`, `tests`, `style`, `docs`, `other`), `tone` (`direct`/`friendly`/`withSuggestions`); globs no vacíos; aplica con `applyConfig { … }` sobre `config.claude.review`; devuelve `configStore.config.claude`.
- `claudeRespondSet`: valida `commitMode` (`single`/`perComment`) y que las plantillas usen solo las variables de E.5 (`{n}`, `{pr}`, `{title}`, `{comment}`, `{commit}`, `{summary}`); aplica sobre `config.claude.respond`.
- `claudeStageSet`: `stage.hasSkill` (si no, `invalidUsage` "Chat prompts have no skill: use `prbar claude prompt edit`"); `.skill` valida con `ClaudeSettings.isValidSkill`; `.prompt` valida las variables obligatorias de la etapa (el mismo validador que usa Settings › Claude › Prompts) y deja `mode = prompt`; `.useDefault` vuelve a skill por defecto y prompt por defecto.
- `claudePromptShow/Set/Reset`: el prompt de la etapa (el propio o el por defecto), con `isDefault` y las variables obligatorias; `Set` valida igual que `.prompt`.
- `respondPushAnyway`: como `respondPush` (Task 11), pero solo si el último push quedó bloqueado por los tests que fallaron (si no, `invalidState` "Nothing is blocked by failed tests: use `prbar respond push`"), y llama a la variante "Push Anyway" de la cola.

En `AppModel+Settings.swift`, `repoSet` aplica `changes.addIgnore`/`removeIgnore` sobre `RepoConfig.ignorePaths` (globs no vacíos) y cuenta como cambio de configuración que refresca.

- [ ] **Step 4: CLI**

`Sources/PRBarCLIKit/RulesCommands.swift`: `RulesGroup` (`rules`) con `list`, `add`, `edit`, `remove`, `enable`, `disable`, `chat`, `suggestions` (grupo con `list` por defecto, `accept`, `dismiss`, `never`) y `proposal` (grupo con `save`, `dismiss`), siguiendo el patrón de las Tasks 16–19:

```swift
struct RulesAdd: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a rule Claude follows in your reviews and fixes.")
    @Argument(help: "The rule.") var text: String
    @Option(help: "Only this repo (owner/repo); default: global.") var repo: String?
    @Flag(help: "Applies to reviews.") var review = false
    @Flag(help: "Applies to responses and fixes.") var fixes = false
    @OptionGroup var global: GlobalOptions

    /// Sin --review ni --fixes: las dos.
    var stages: [RuleStage] { review == fixes ? [.review, .respond] : review ? [.review] : [.respond] }

    func appCommand(confirmed: Bool) -> AppCommand { .rulesAdd(text: text, repo: repo, appliesTo: stages) }
    func render(_ result: JSONValue, _ output: Output) throws { RulesRender.list([try result.decode()], output) }
}

struct RulesEdit: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a rule.")
    @Argument(help: "The rule’s id (or its first 4+ characters).") var id: String
    @Option(help: "New text.") var text: String?
    @Option(help: "Move it to this repo.") var repo: String?
    @Flag(help: "Make it global.") var global_ = false
    @Flag(inversion: .prefixedNo, help: "Applies to reviews.") var review: Bool?
    @Flag(inversion: .prefixedNo, help: "Applies to responses and fixes.") var fixes: Bool?
    @OptionGroup var global: GlobalOptions

    var scope: RuleScopeChange? { global_ ? .global : repo.map { .repo(name: $0) } }

    /// Con --review/--no-review o --fixes/--no-fixes: la lista final (lo no nombrado se deja como está en la app,
    /// que recibe `nil` si no se nombró ninguno).
    var stages: [RuleStage]? {
        guard review != nil || fixes != nil else { return nil }
        return [review == false ? nil : RuleStage.review, fixes == false ? nil : RuleStage.respond].compactMap { $0 }
    }

    func validate() throws {
        if global_ && repo != nil { throw ValidationError("Use --repo or --global, not both.") }
        guard text != nil || scope != nil || stages != nil else { throw ValidationError("Nothing to change.") }
        if stages?.isEmpty == true { throw ValidationError("A rule applies to reviews, fixes or both.") }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .rulesEdit(id: id, text: text, scope: scope, appliesTo: stages) }
    func render(_ result: JSONValue, _ output: Output) throws { RulesRender.list([try result.decode()], output) }
}
```

(`global_` es el flag `--global`: declararlo con `@Flag(name: .customLong("global"))` para que no choque con `@OptionGroup var global`.) Ojo con `stages` de `RulesEdit`: `--no-fixes` solo, sin `--review`, da `[.review]` (lo que espera el test); si el plan 9 permite combinar con lo que ya tiene la regla, mandar solo lo nombrado y resolver en la app.

`RulesChat` copia `ChatCommand` (Task 26) con `.rulesChatSend/Show/Undo/Stop` y un `RulesChatREPL` igual a `ChatREPL`. `RulesRender.list` imprime una tabla `ID` (8 caracteres) · `Scope` · `Applies to` (`review`, `fixes`) · `On` · `Source` · `Text` (truncado a 60).

En `ConfigCommands.swift`: `ClaudeGroup` suma `ClaudeReviewGroup` (`review set`), `ClaudeRespondGroup` (`respond set`), `ClaudeStage` y `ClaudePromptGroup` (`show`, `edit` con `$EDITOR` en `prepare` como `review edit --editor`, `reset`). Las opciones `--category style=off` se parsean como `[String]` y se convierten a `[String: Bool]` (formato inválido → `ValidationError`); `--commit-mode per-comment` → `"perComment"`; `--max-findings none` → `.clear`; `--reply-template default` → `.clear`. `ClaudeStage`: `--skill S` / `--prompt-file F` (se lee en `appCommand`, ruta con `absolutePath`) / `--default`, exactamente uno. `RepoSet` suma `@Option var ignore: [String] = []` y `@Option var unignore: [String] = []` (y los incluye en `changes`).

En `RespondCommands.swift`, `RespondPush` suma `@Flag(help: "Push even though the tests before the push failed (Push Anyway).") var anyway = false`; `appCommand` devuelve `.respondPushAnyway(…)` con `anyway`, y la pregunta de confirmación agrega "The tests failed." cuando corresponde.

En `CLIRouter.commands`, una entrada por subcomando nuevo con su ejemplo (las rutas: `rules list`, `rules add`, `rules edit`, `rules remove`, `rules enable`, `rules disable`, `rules chat`, `rules suggestions list`, `rules suggestions accept`, `rules suggestions dismiss`, `rules suggestions never`, `rules proposal save`, `rules proposal dismiss`, `claude review set`, `claude respond set`, `claude stage`, `claude prompt show`, `claude prompt edit`, `claude prompt reset`); `respond push` pasa a producir `[.respondPush, .respondPushAnyway]` con el ejemplo `["respond", "push", "web#2", "--anyway", "--yes"]`. El test "la tabla tiene exactamente los subcomandos" avisa cualquier ruta que falte.

- [ ] **Step 5: Inventario y fin de `.deferred`**

Cambiar los `.deferred("Task 28")` por sus comandos: la pestaña Instructions (texto en línea → `rules edit`, chips Review/Fixes → `rules edit`, switch → `rules enable`/`rules disable`, borrar → `rules remove`, agregar → `rules add`), su chat (campo, enviar, Stop, Undo → `rules chat`), las tarjetas "Save as rule" (Save, el texto editable, Dismiss → `rules proposal save|dismiss`), las sugerencias (Create Rule, Not Now, Never → `rules suggestions accept|dismiss|never`), las opciones de review y fixes (→ `claude review set` / `claude respond set`; "Hidden by your settings" → `review include` porque esos hallazgos tienen número), los prompts (editor, "Reset to Default" → `claude prompt edit|reset`; skill/prompt por etapa → `claude stage`), los globs por repo (→ `repo set`) y "Push Anyway" (→ `respond push`).

Después, **borrar el caso `.deferred` de `UIMapping`**: ya no queda ninguno, y así un control futuro no puede quedar "para después".

Run: `swift run PRBarTests "paridad"`
Expected: pasan las cuatro paridades (si el escáner encuentra controles del plan 9 no previstos arriba, mapearlos igual).

- [ ] **Step 6: Docs**

En `docs/cli.md`, una sección "Rules, review options and prompts" con la lista de comandos de arriba (en inglés) y una línea por comando, más: "Rules are injected in every Claude prompt in a delimited section; PR content is never treated as instructions" y "Editing a prompt never changes Claude’s tools, permissions or output schema".

- [ ] **Step 7: Correr y verificar**

Run: `swift run PRBarTests`
Expected: todo pasa.

Manual: `prbar rules add "No style comments" --review` aparece en Settings › Instructions; `prbar rules chat "en web-app usá React Query"` agrega la regla con Undo; `prbar claude review set --min-severity medium` cambia el selector; `prbar claude prompt edit filter` abre `$EDITOR` y rechaza un prompt sin las variables obligatorias.

- [ ] **Step 8: Commit**

```bash
git add Sources/PRBarCore Sources/PRBar Sources/PRBarCLIKit Sources/PRBarTests docs/cli.md
git commit -m "Add prbar rules, review/fix options and prompt commands"
```

---

### Task 29: Verificación final

- [ ] **Step 1:** `swift build -c release 2>&1 | grep -E "warning|error"` — sin errores; revisar los warnings nuevos de los archivos de este plan.
- [ ] **Step 2:** `swift run PRBarTests` — todo pasa (incluidas las paridades AppCommand ↔ CLI y UI → CLI).
- [ ] **Step 3:** `Scripts/bundle.sh --install`, recorrer `docs/qa/plan-7-checklist.md` completo (agregarle los ítems de chat, update y rules de las Tasks 26–28).
- [ ] **Step 4:** `prbar --help` y cada `prbar <grupo> --help` coinciden con `docs/cli.md`.
- [ ] **Step 5:** `git log --format=%B -n 40 | grep -ci "co-authored-by\|generated with"` → `0` (ningún commit con atribución).
