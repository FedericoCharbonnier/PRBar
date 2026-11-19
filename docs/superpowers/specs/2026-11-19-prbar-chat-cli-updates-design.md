# PRBar — Chat con Claude, CLI y actualizaciones

Fecha: 2026-11-19. Extiende `2026-11-18-prbar-design.md` (en adelante "spec base"). Cuatro partes independientes, cada una con su plan:

| Parte | Plan |
|---|---|
| A. Dropdown de repos más grande | `2026-11-19-prbar-plan-6-chat.md` (primera tarea) |
| B. Chat con Claude en Review y Respond | `2026-11-19-prbar-plan-6-chat.md` |
| C. CLI `prbar` | `2026-11-19-prbar-plan-7-cli.md` |
| D. Actualizaciones desde el repo | `2026-11-19-prbar-plan-8-updates.md` |

Orden de implementación: A+B → D → C. La CLI va al final porque tiene que cubrir también los comandos del chat y de las actualizaciones.

---

## A. Dropdown de "Add Repo…"

`SearchablePickerPopover` hoy mide 320 pt de ancho (`width: 320` en `ReposTab.addRepoPicker`) y la lista tiene un alto máximo de 320 pt (`maxListHeight`), así que con muchos repos se ven pocos y los nombres largos se cortan.

- `maxListHeight` pasa a ser un parámetro (`maxListHeight: CGFloat = 320`); el de Add Repo usa **440 × 480**.
- Los demás usos (ramas, usuarios, canal de Slack) no cambian.
- El título de cada fila usa `truncationMode(.middle)` para que se vea el final del nombre.

---

## B. Chat con Claude

### B.1 Qué hace

Un panel de chat en la ventana de **Review** (PR ajeno) y en la de **Respond** (mi PR). Una conversación por PR. Sirve para:

| | Review | Respond |
|---|---|---|
| Preguntar y discutir (código, findings, comentarios recibidos) | ✓ | ✓ |
| Ajustar los findings: editar título/cuerpo, agregar, descartar o volver a incluir, editar el comentario general | ✓ | — |
| Redactar respuestas a comentarios recibidos (incluidas las que no llevan código) | — | ✓ |
| Cambiar el código del fix | ✗ (sin herramientas de edición) | ✓ solo en el worktree |

Los cambios se aplican **directo** y se resaltan en la ventana. Cada respuesta de Claude que cambió algo lleva un resumen ("Edité #2, agregué #4, cambié 2 archivos") y **Deshacer**. Publicar, pushear y aprobar siguen siendo acciones del usuario: el chat nunca publica, pushea, aprueba ni elige el tipo de review.

Claude contesta en el idioma en que le escriben. Lo que va a GitHub (findings, respuestas) sigue la regla del spec base §16 (idioma del PR).

### B.2 UI

- Botón de toolbar **Chat** (`bubble.left.and.bubble.right`, ⌘⇧C) en ReviewWindow y RespondWindow. Abre/cierra un panel a la derecha (inspector de SwiftUI, `.inspector(isPresented:)`, ancho 320–480, recordado).
- Lista de mensajes (usuario / Claude), respuesta en streaming con el texto parcial del `stream-json`, indicador "Claude is working…" con el último tool usado ("Reading src/api/users.ts").
- Campo de texto multilínea; ↩ envía, ⇧↩ nueva línea; botón **Stop** mientras corre.
- En cada mensaje de Claude con cambios: lista de cambios y **Undo** (solo en el último mensaje con cambios no deshecho; deshacer es en orden inverso).
- Los findings/respuestas que tocó el último mensaje se resaltan (fondo de acento suave, 3 s).
- Se puede referir a un finding por número ("el #2"): los findings se numeran en la ventana igual que en el chat.
- Deshabilitado (con motivo en el placeholder) mientras corre implementar, tests o push en Respond, o mientras se publica.
- Al publicar/pushear el panel queda de solo lectura con la conversación.
- UI en inglés (spec base: la app está en inglés).

### B.3 Modelo

En `PRBarCore`:

```swift
public struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, error }
    public let id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var changes: [ChatChange]   // vacío si no cambió nada
    public var undone: Bool
}

public enum ChatChange: Codable, Equatable, Sendable {
    case findingEdited(id: String), findingAdded(id: String), findingIncluded(id: String, included: Bool)
    case generalCommentEdited
    case replyDrafted(commentID: String)
    case filesChanged([String])        // rutas relativas al worktree
}

public struct ChatSession: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case review, respond }
    public let id: UUID
    public let prID: String
    public let kind: Kind
    public var claudeSessionID: UUID?  // sesión de Claude Code que se retoma con --resume
    public var worktreePath: String?   // donde corre (mismo cwd para que --resume funcione)
    public var messages: [ChatMessage]
    public var readOnly: Bool          // true después de publicar/pushear
}
```

`ChatSession` se guarda dentro del registro del draft (`ReviewDraft.chat`, `RespondRecord.chat`, opcional, decodificación tolerante) y por lo tanto en History.

### B.4 Cómo corre Claude

Cada mensaje del usuario es un `claude -p` con **los mismos argumentos de aislamiento del spec base §8.3** (`--setting-sources ""`, `--settings` con bloqueo fuera del cwd y `deny` de secretos, `--strict-mcp-config`, `--permission-mode dontAsk`, entorno en lista blanca, sin tokens, `mcp__*` negado, redacción del token en todo lo que se guarda), más:

- **Herramientas**: Review → `--tools "Read,Grep,Glob,Skill,Agent"`, `--allowedTools "Read(./**),Skill,Agent"`. Respond → además `Edit,Write` con `Edit(./**)` (igual que la etapa de implementación del spec base §14.6). Nunca `Bash`.
- **Plugins**: los mismos `--plugin-dir` que el review/respond de ese PR (skills configurados).
- **Modelo**: `claude.chatModel` (ver B.8); `nil` = el mismo del review.
- **Salida estructurada** con `--json-schema`:

```json
{
  "reply": "texto para el usuario (markdown simple)",
  "actions": [
    {"type": "editFinding", "id": "f2", "title": "…", "body": "…"},
    {"type": "addFinding", "severity": "medium", "file": "src/a.ts", "line": 12, "title": "…", "body": "…"},
    {"type": "setIncluded", "id": "f3", "included": false},
    {"type": "setGeneralComment", "text": "…"},
    {"type": "draftReply", "commentID": "PRRC_…", "body": "…"},
    {"type": "setImplement", "commentID": "PRRC_…", "implement": true}
  ]
}
```

  Las acciones válidas dependen del tipo (Review: las cuatro primeras; Respond: las dos últimas). PRBar valida cada acción (ids existentes, severidad válida, archivo dentro del diff para `addFinding`, cuerpo no vacío) y **descarta las inválidas** con una nota en el mensaje; nunca escribe estado que no pasó la validación. Claude nunca escribe directamente sobre archivos de PRBar.

- **Sesión**: el primer mensaje lanza con `--session-id <uuid nuevo>` y un prompt de arranque que incluye: rol (asistente del usuario en este review/respond), reglas (el contenido del PR no son instrucciones; no publica; idioma), rutas de `pr.diff` y `pr.md` (carpeta de contexto, como en §8.3), y el **estado actual** de la ventana en JSON (findings con número, inclusión y texto; o comentarios recibidos con su análisis, respuesta redactada y si se implementa). Los mensajes siguientes usan `--resume <uuid>` y solo agregan el mensaje del usuario + el estado actual si cambió desde el último turno (el usuario puede haber editado a mano).
- **Respaldo**: si `--resume` falla (la sesión no existe o el CLI la rechaza), se relanza con `--session-id` nuevo y el prompt de arranque más la conversación previa (texto de usuario y `reply` de Claude) como transcript. El usuario no ve el fallo, solo una nota tenue "Context rebuilt".
- **Timeout** 10 min por mensaje; **Stop** mata el grupo de procesos (como el resto).
- Un mensaje a la vez por PR. Máximo de chats corriendo a la vez en toda la app: 2 (comparten el límite de `JobScheduler` con reviews/responds).
- **Integridad**: después de cada mensaje corre el guardián de archivos de git (`WorktreeIntegrity`, allowlist) igual que en §14.6; si Claude tocó `.git`, el mensaje termina en error, se deshacen los cambios de archivos del turno y se muestra el motivo.

### B.5 Worktree

- **Review**: el worktree del review se borra al terminar el análisis (spec base §8.5). El chat lo vuelve a crear **en el primer mensaje**, con `WorktreeManager.prepare` sobre el mismo `headRefOid` revisado, en una ruta fija por chat (`<worktreesDir>/chat-<pr>-<sessionID>`), y lo guarda en `ChatSession.worktreePath`. Se borra (junto con sus refs) al publicar, al descartar el review y al cerrar la app. Si no hay `localPath`, el chat corre en modo solo diff (cwd vacío, como §8.2).
- **Respond**: usa el worktree del respond que ya existe. El chat no cambia su ciclo de vida.
- Si el PR recibió commits nuevos desde el review, el chat sigue sobre el commit revisado y lo avisa ("This review is for an older commit").

### B.6 Deshacer

Antes de ejecutar un mensaje se guarda un punto de restauración:
- **Estado de la ventana**: copia de los findings/comentario general (Review) o de las respuestas/selecciones (Respond), en memoria y en el draft.
- **Archivos** (solo Respond): snapshot del worktree como commit sin rama: `GIT_INDEX_FILE=<tmp> git add -A`, `write-tree`, `commit-tree` → `refs/prbar/chat-<sessionID>-<n>`. Deshacer = `git read-tree -u --reset <tree>` con ese índice temporal + borrar los archivos sin trackear creados después del snapshot. Las refs se borran con el worktree.

Deshacer el mensaje N solo se ofrece si es el último con cambios no deshecho, y deshace exactamente su estado y sus archivos. Si el usuario editó a mano después, se confirma antes ("Undo will also discard your manual edits since then").

### B.7 History

`HistoryDetailView` y `RespondHistoryDetailView` muestran la conversación (solo lectura) en una sección colapsable "Chat (N messages)". El log de cada `claude -p` del chat se guarda junto a los demás logs del registro.

### B.8 Configuración

`ClaudeSettings` agrega (decodificación tolerante, por defecto encendido):

```json
"claude": { "chatEnabled": true, "chatModel": null }
```

Settings › Claude: sección **Chat** con switch "Chat with Claude in Review and Respond windows" y picker de modelo ("Same as review", Opus, Sonnet, Haiku).

### B.9 Errores

- Claude devuelve JSON inválido: un reintento con el error de validación (igual que §8.5); si vuelve a fallar, mensaje `error` con "Claude's answer couldn't be read" y "Show Log". Los archivos tocados en ese turno se revierten.
- `claude` no instalado / sin login: el panel muestra el mismo motivo que el botón Review.
- La app se cierra con un mensaje corriendo: el proceso se mata; al reabrir, el mensaje queda como `error` "Interrupted".

### B.10 Testing

- `ChatEngine` (Core) con `ProcessRunner` falso: argumentos exactos (aislamiento, herramientas por tipo, `--session-id` y luego `--resume`), respaldo cuando `--resume` falla, validación y aplicación de cada acción, descarte de acciones inválidas, undo de estado y de archivos (con un repo git temporal), guardián de integridad.
- Decodificación tolerante de `ChatSession` y de `ClaudeSettings`.
- Snapshot mode: capturas nuevas `review-chat-{light,dark}` y `respond-chat-{light,dark}` con conversación ficticia.

---

## C. CLI `prbar`

### C.1 Principio

**Todo lo que se puede hacer en la app se puede hacer desde la CLI**, y viceversa para lo que tenga sentido en una UI. Se garantiza con un test de paridad (C.7).

### C.2 Arquitectura: control remoto de la app

```
prbar (CLI) ──JSON lines──► ~/Library/Application Support/PRBar/prbar.sock ──► PRBar.app (CommandServer)
```

- La app es **el único proceso** que escribe `config.json`, corre reviews/responds/chats y publica. La CLI no importa `ConfigStore` para escribir.
- **`AppCommand`** (Core, `Codable`): un enum con un caso por acción de la app (ver C.4). `CommandServer` (app) lo decodifica y llama a los mismos métodos de `AppModel` que usa la UI. Las acciones de la UI que hoy no son métodos de `AppModel` (p. ej. publicar con selección) se suben a `AppModel` para que ambos caminos compartan código.
- **Protocolo**: una línea JSON por pedido `{"id": 1, "command": {...}}`; respuestas `{"id": 1, "ok": true, "result": {...}}` o `{"id": 1, "ok": false, "error": {"code": "...", "message": "..."}}`. Los comandos de larga duración (`review --wait`, `chat`, `update`) mandan eventos `{"id": 1, "event": {...}}` antes de la respuesta final (progreso, texto parcial del chat).
- **Seguridad del socket**: socket Unix creado con `umask 077` (permisos 0600) en una carpeta 0700; en cada conexión se verifica con `getpeereid` que el uid sea el del usuario; se rechaza cualquier otro. Nada de red. Los tokens nunca viajan por el socket hacia la CLI; `slack token set` sí los envía de la CLI a la app (el usuario los escribe).
- **App cerrada**: la CLI la abre en segundo plano (`open -g -a ~/Applications/PRBar.app` o el bundle que la contiene) y reintenta conectar hasta 10 s. Excepciones que funcionan sin app: `prbar doctor`, `prbar version`, `prbar completion`, `prbar app start`.
- **Versiones**: el primer mensaje es `hello` con la versión del protocolo; si la CLI y la app no coinciden, error claro ("prbar 1.3.0 can't talk to PRBar 1.2.0 — run `prbar update` or reinstall").

### C.3 Binario e instalación

- Nuevo target ejecutable `prbar` (depende de `PRBarCore` y de **swift-argument-parser**, primera dependencia externa; versión fijada).
- `Scripts/bundle.sh` lo copia a `PRBar.app/Contents/Helpers/prbar`. Con `--install`, crea el link `~/.local/bin/prbar` (o `$PRBAR_BIN_DIR`) y avisa si esa carpeta no está en el `PATH`.
- `prbar completion zsh|bash|fish` (de ArgumentParser).

### C.4 Comandos

Formato de PR: `owner/repo#N`, `repo#N` (si es único entre los repos configurados) o la URL del PR.

```
# Estado
prbar status [--json]
prbar prs [--list to-review|updated|mine|other] [--account L] [--json]
prbar history [--repo R] [--kind review|respond] [--limit N] [--json]
prbar history show <id> [--json]
prbar refresh

# Ventanas / app
prbar open <pr>                      # PR en el navegador
prbar open <pr> --review|--respond   # ventana de review/respond
prbar app start|quit|settings [tab]|history|logs
prbar doctor [--json]                # funciona sin la app

# Review (PR ajeno)
prbar review <pr> [--wait]
prbar review show <pr> [--json]
prbar review edit <pr> <n> [--title T] [--body B | --body-file F | --editor]
prbar review include|exclude <pr> <n>...
prbar review comment <pr> [--text T | --editor]           # comentario general
prbar review publish <pr> --comment|--request-changes|--approve [--only 1,3] [--yes]
prbar review cancel|dismiss <pr>

# Respond (mi PR)
prbar respond <pr> [--wait]
prbar respond show <pr> [--json]
prbar respond select <pr> <commentID|n> --implement|--reply-only|--skip [--reply T]
prbar respond implement <pr> [--wait]
prbar respond test <pr> [--wait]
prbar respond diff <pr>
prbar respond push <pr> [--yes]
prbar respond reply-only <pr> [--yes]                      # publicar solo respuestas
prbar respond cancel|dismiss <pr>

# Chat
prbar chat <pr> ["mensaje"]          # sin mensaje: modo interactivo (REPL)
prbar chat <pr> --undo
prbar chat <pr> --show [--json]

# Configuración
prbar config show [--json]
prbar config set refresh-interval 5 | launch-at-login on|off
prbar account list | enable|disable <login>
prbar repo list [--json]
prbar repo add|remove <owner/repo> [--account L]
prbar repo set <owner/repo> [--path P] [--worktrees P] [--test-command C]
                             [--branches a,b] [--add-branch b] [--remove-branch b]
                             [--channel #name|ID|none]
prbar follow list|add|remove <owner/repo> [users...]
prbar notify list | set <kind> on|off | enable|disable
prbar claude show | set [--review-skill S] [--filter on|off] [--filter-skill S]
                        [--respond-skill S] [--model M] [--chat on|off] [--chat-model M]
prbar claude skills [--json]          # skills instalados disponibles
prbar tools set gh|git|claude <path>
prbar slack show | enable|disable | provider connector|token
prbar slack token set [--stdin] | clear
prbar slack set <toggle> on|off       # announce, updated, react-start, react-comment, react-approve
prbar slack emoji eyes|comment|approved <name>
prbar slack template list | show|set|reset <key> [text]
prbar slack test                      # mensaje de prueba a tu DM

# Actualizaciones (parte D)
prbar version
prbar update [--check] [--yes]
```

### C.5 Interactivo y scripts

- **TTY** (stdout y stdin son terminal, sin `--json`): tablas con color (respeta `NO_COLOR`), y prompts:
  - `review publish` sin `--only`: lista con checkboxes (↑↓, espacio, ↩), opción de editar cada uno con `$EDITOR`, y confirmación mostrando tipo de review y cantidad de comentarios.
  - `respond push`/`reply-only`: muestra el resumen y el diff stat y pide confirmación.
  - `chat` sin mensaje: REPL con streaming; `/undo`, `/show`, `/quit`.
- **No interactivo** (sin TTY, o `--json`, o `--yes`): nunca pregunta. Las acciones que publican/pushean/aprueban **exigen `--yes`**; sin él, exit code 4 y mensaje.
- **`--json`**: salida estable y documentada (`docs/cli.md`), con `"schemaVersion": 1`.
- **Exit codes**: 0 ok, 1 error, 2 uso inválido, 3 app no disponible, 4 confirmación requerida, 5 no encontrado (PR/repo/cuenta), 6 estado inválido (p. ej. publicar sin review listo), 130 cancelado (Ctrl-C cancela también el job si se usó `--wait`).

### C.6 Errores

Los mensajes son los mismos textos que la UI (misma fuente) más el comando sugerido cuando aplica ("No local folder for acme/api — run `prbar repo set acme/api --path …`").

### C.7 Testing

- **Paridad**: test que recorre `AppCommand.allCases` (descripción por caso) y verifica que cada caso tiene un comando de CLI que lo produce (tabla `CLIRouter.commands`), y que cada acción de la UI pasa por un método de `AppModel` cubierto por un `AppCommand` (lista explícita revisada en el test: agregar un botón sin comando rompe el test).
- Parseo de cada comando → `AppCommand` (sin socket).
- `CommandServer` con un `AppModel` falso: cada comando llama al método correcto; uid distinto rechazado; versión de protocolo distinta rechazada.
- Codificación JSON estable (snapshots de `--json`).
- Integración: socket real en una carpeta temporal, CLI ↔ servidor.

---

## D. Actualizaciones desde el repo

### D.1 Versiones y releases

- Versión semántica en `CFBundleShortVersionString`; `CFBundleVersion` = número de build creciente. La primera versión pública es **1.0.0**.
- `Scripts/release.sh <version>`: verifica árbol limpio en `main` y al día con `origin`, corre `swift build` y `swift run PRBarTests`, actualiza `Info.plist`, commitea "Release vX.Y.Z", crea el tag anotado `vX.Y.Z`, pushea commit y tag, y crea el GitHub Release con notas generadas desde los commits desde el tag anterior (se abren en `$EDITOR` antes de publicar).

### D.2 Chequeo

- `UpdateChecker` (Core): `GET https://api.github.com/repos/FedericoCharbonnier/PRBar/releases/latest` sin token (repo público). Ignora drafts y prereleases. Compara semver con la versión instalada.
- Repo de origen configurable (`updates.repo`, por defecto `FedericoCharbonnier/PRBar`) para forks.
- Frecuencia: `updates.checkIntervalHours` (por defecto 24; 0 = solo manual). También al abrir la app si pasó el intervalo.
- Si hay versión nueva:
  - Popover: fila al pie "PRBar 1.3.0 is available — Update…" con punto azul.
  - Notificación (una vez por versión; `updates.notifiedVersion`): "PRBar 1.3.0 is available" + primera línea de las notas.
  - Se puede **saltear** una versión (`updates.skippedVersion`): no vuelve a avisar hasta la siguiente.
- Settings › General: sección **Updates** con versión instalada, "Check for Updates" (manual), switch "Check automatically" e intervalo.

Configuración nueva (decodificación tolerante):

```json
"updates": { "repo": "FedericoCharbonnier/PRBar", "checkIntervalHours": 24,
             "lastCheckAt": null, "notifiedVersion": null, "skippedVersion": null }
```

### D.3 Instalación

Ventana "Update PRBar" con las notas del release y **Update** / **Skip This Version** / **Later**. Al apretar Update:

1. **Espera trabajos**: si hay reviews, responds o chats corriendo, ofrece "Wait" (actualiza cuando terminen) o "Cancel Them".
2. **Código**: clon propio en `~/Library/Application Support/PRBar/source` (se crea con `git clone --no-checkout` la primera vez; nunca usa el checkout de desarrollo del usuario). `git fetch --tags --force origin`, verifica que el tag `vX.Y.Z` exista y que su commit sea alcanzable desde `origin/main`, y `git checkout --detach vX.Y.Z`. Todos los git con el endurecimiento del spec base (`core.hooksPath=/dev/null`, `core.fsmonitor=false`, etc.).
3. **Build**: `Scripts/bundle.sh --output <staging>` del tag (compila en release y arma el `.app` en una carpeta temporal, sin instalar). Usa las Command Line Tools ya requeridas. Progreso y log en la ventana (~1–2 min).
4. **Verificación**: el `.app` armado existe, su `CFBundleShortVersionString` es la versión esperada y el binario arranca con `--version`.
5. **Reemplazo atómico**: mueve el `.app` actual a `PRBar.app.previous` (en la misma carpeta), mueve el nuevo a su lugar; si falla, restaura el anterior. Funciona con el `.app` en `~/Applications` o donde esté instalado (`Bundle.main.bundleURL`).
6. **Reinicio**: lanza un proceso desacoplado (`/bin/sh -c 'while kill -0 <pid>; do sleep 0.2; done; open <app>'`) y la app termina. Al arrancar la nueva versión, borra `PRBar.app.previous` y muestra "Updated to 1.3.0" con las notas.

Si cualquier paso falla, la versión instalada queda intacta, la ventana muestra el error y "Show Log", y se puede reintentar. Config, historial, estado de Slack y Keychain no se tocan (mismo bundle id).

### D.4 CLI

`prbar version` (CLI y app), `prbar update --check` (exit 0 si está al día, 10 si hay versión nueva, imprime versión y notas), `prbar update [--yes]` (mismo flujo con progreso en la terminal; pide confirmación sin `--yes`).

### D.5 Testing

- Comparación semver (incluye `v` inicial, prereleases ignoradas).
- `UpdateChecker` con transporte falso: versión nueva, igual, salteada, ya notificada, error de red (silencioso en el chequeo automático, visible en el manual).
- `UpdateInstaller` con `ProcessRunner` falso: argumentos de git endurecidos, rechazo de tag no alcanzable desde `origin/main`, falla de build → no toca el `.app`, reemplazo y rollback en carpetas temporales.
- `release.sh`: modo `--dry-run` que imprime los pasos sin pushear.
