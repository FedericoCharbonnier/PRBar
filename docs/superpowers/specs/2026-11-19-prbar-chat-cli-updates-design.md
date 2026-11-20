# PRBar — Chat con Claude, CLI y actualizaciones

Fecha: 2026-11-19. Extiende `2026-11-18-prbar-design.md` (en adelante "spec base"). Seis partes, cada una con su plan:

| Parte | Plan |
|---|---|
| A. Dropdown de repos más grande | `2026-11-19-prbar-plan-6-chat.md` (primera tarea) |
| B. Chat con Claude en Review y Respond | `2026-11-19-prbar-plan-6-chat.md` |
| C. CLI `prbar` | `2026-11-19-prbar-plan-7-cli.md` |
| D. Actualizaciones desde el repo | `2026-11-19-prbar-plan-8-updates.md` |
| E. Instrucciones y configuración completa del proceso | `2026-11-19-prbar-plan-9-instructions.md` |
| F. Ready to Merge: PRs aprobados y botón Merge | `2026-11-19-prbar-plan-10-merge.md` |
| G. Ventana de Merge con resumen del PR | `2026-11-19-prbar-plan-11-merge-window.md` |
| H. Pestañas To Review / My PRs en el popover | `2026-11-19-prbar-plan-12-popover-tabs.md` |
| I. Recursos que consume PRBar | `2026-11-19-prbar-plan-13-resources.md` |
| J. Dónde corre Claude: esta Mac o un servidor por SSH | `2026-11-19-prbar-plan-14-remote-runners.md` |

Orden de implementación: A+B → D → E → F → C. La CLI va al final porque tiene que cubrir también los comandos del chat, de las actualizaciones, de las instrucciones y del merge.

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
    public var notes: [String]         // notas tenues: "Context rebuilt", acciones descartadas…
    public var restore: ChatRestorePoint?  // estado antes/después del turno y snapshot de archivos (B.6)
}

public enum ChatChange: Codable, Equatable, Sendable {
    case findingEdited(id: String), findingAdded(id: String), findingIncluded(id: String, included: Bool)
    case generalCommentEdited
    case replyDrafted(commentID: String)
    case implementSet(commentID: String, implement: Bool)
    case filesChanged([String])        // rutas relativas al worktree
}

public struct ChatSession: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case review, respond }
    public let id: UUID
    public let prID: String
    public let kind: Kind
    public var claudeSessionID: UUID?  // sesión de Claude Code que se retoma con --resume
    public var worktreePath: String?   // donde corre (mismo cwd para que --resume funcione)
    public var worktreeRefs: [String]  // Review: refs de PRBar del worktree del chat, se borran con él
    public var messages: [ChatMessage]
    public var readOnly: Bool          // true después de publicar/pushear
    public var pending: Bool           // un turno corriendo; al reabrir pasa a "Interrupted" (B.9)
    public var lastState: String?      // el estado de la ventana que Claude vio por última vez
}
```

`ChatSession` se guarda dentro del registro del draft (`ReviewDraft.chat`, `RespondRecord.chat`, opcional, decodificación tolerante) y por lo tanto en History. El estado editable de la ventana de Review (`ReviewEdits`: selección, títulos y cuerpos editados, findings agregados y comentario general) se guarda en `ReviewDraft.edits`.

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
- **Integridad**: después de cada mensaje corre el guardián de archivos de git (`WorktreeIntegrity`, allowlist) igual que en §14.6; si Claude cambió la config o los hooks de git (o apareció un `.git` anidado), **no se corre ningún git** (podría ejecutar lo que escribió Claude): el mensaje termina en error con el motivo, no se revierte nada y hay que descartar el Respond, lo que borra el worktree.

### B.5 Worktree

- **Review**: el worktree del review se borra al terminar el análisis (spec base §8.5). El chat lo vuelve a crear **en el primer mensaje**, con `WorktreeManager.prepare` sobre el mismo `headRefOid` revisado, en una ruta fija por chat (`<worktreesDir>/chat-<repo>-<N>-<sessionID>`, más `-diff` sin clone), y lo guarda en `ChatSession.worktreePath`. Se borra (junto con sus refs) al publicar, al descartar el review y al cerrar la app. Si no hay `localPath`, el chat corre en modo solo diff (cwd vacío, como §8.2).
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

### B.11 Decisiones de implementación (Plan 6)

Donde el spec era ambiguo:

1. **Fila del popover (A):** `itemRow` ya usa `.truncationMode(.middle)` en el título. A solo agrega `maxListHeight` como parámetro y el tamaño 440 × 480.
2. **Estado editable de Review:** hoy vive en `@State` de `ReviewWindow` y solo hay cuerpos editados. Pasa a un `ReviewEdits` (Core, `Codable`) con:
   - `selected`;
   - `bodies` y `titles` editados;
   - `added`, los findings agregados por el chat, con ids `c1`, `c2`…;
   - `generalComment`;
   - `addedCount`, un contador que solo crece: el próximo id es `c<addedCount + 1>`. Así un id nunca se reusa después de un Undo (los mensajes viejos lo siguen nombrando). Undo conserva el valor más alto y no cuenta como edición manual.

   Vive en el `ChatCoordinator`. Se guarda en `ReviewDraft.edits` junto con `ReviewDraft.chat`, para que la conversación y sus cambios lleguen juntos al historial.
3. **Numeración:** `#N` es la posición en `draft.items + edits.added`, contando desde 1. Es la misma en la ventana, en el JSON de estado y en el resumen de cambios. Los findings descartados por el filtro también tienen número.
4. **`commentID` de Respond:** es el `RespondItem.id` (`thread:<nodeID>` o `review:<id>`), no un `PRRC_…`.
5. **Acción `setImplement`:** se agrega `ChatChange.implementSet(commentID:implement:)`. El spec lista la acción pero no el cambio.
6. **Cuándo se edita código en Respond:** solo en `readyToPush`, antes del push, con `Edit`/`Write`. PRBar commitea los cambios del turno (`Address review feedback`, sin hooks) y recalcula diff, commits y `headOid`. Así lo que se pushea es lo que el usuario vio. Los tests anteriores se borran, porque cambió el código.

   En `ready` (antes de implementar), el chat es de solo lectura y además ofrece `setImplement`. En cualquier otra fase está bloqueado (implementando, tests, push) o es de solo lectura (`done`).
7. **Snapshot para deshacer (B.6):** se toma como dice el spec, con índice temporal, `write-tree` y `commit-tree` a la ref. El turno exige el árbol limpio al empezar (`ensureClean`, igual que un fix), así que el snapshot es igual a HEAD. Deshacer hace, en este orden: `read-tree -u --reset <tree>` con el índice real (también hay que resetearlo); `update-ref --no-deref HEAD <headBefore> <headAfter>` (compare-and-swap; si falla, el árbol vuelve a `headAfter`); y `clean -fd` (nunca `-x`). Deshacer no depende de la ref: el árbol del snapshot es el de `headBefore`, que sigue alcanzable. La limpieza al arrancar puede borrar la ref sin romper nada.
8. **Contexto del chat de Respond:** el worktree de Respond no tiene la base, así que no hay `pr.diff`. La carpeta de contexto `<owner>-<repo>-<N>-<sesión>.respond-context` lleva:
   - `feedback.json`, como en el análisis;
   - `pr.md`, si el PR sigue en el snapshot;
   - `fixes.diff`, el `RespondResult.diff`.

   El cwd es el worktree. Ese nombre ya lo borra la limpieza de huérfanos.
9. **Worktree del chat de Review:** el nombre es `chat-<repo>-<N>-<sesión>`, más `-diff` en modo solo diff, con su carpeta `.context`. La ruta es fija por sesión, así que `--resume` funciona aun después de reiniciar la app. `isWorkspaceName` lo reconoce y la limpieza de huérfanos lo borra al arrancar. Para "al cerrar la app" se usa el mismo mecanismo que los reviews: cancelar al salir y borrar en el próximo arranque.
10. **Commit revisado:** `WorktreeManager.prepare(…, pinnedHeadOid:)` usa el `headOid` del draft si el objeto existe en el clone (`cat-file -e`). Si no existe, usa el head actual y agrega la nota "Claude sees the PR’s latest commit, not the reviewed one."
11. **Límite de concurrencia:** un `JobScheduler<String>(maxConcurrent: 2)` propio de los chats, en `AppModel`. Reviews y Responds ya tienen cada uno el suyo, y un turno de chat no debe esperar detrás de un review de 15 minutos.
12. **Respaldo de `--resume`:** se activa solo cuando el CLI dice que la sesión no existe: `No conversation found with session ID` (`ChatEngine.isMissingSession`). Cualquier otro error (API key, rate limit, red, crash, timeout, cancelación) se muestra después de una sola corrida, sin pagar otra ni perder la conversación. En un turno con edición, además, no se reconstruye si el árbol cambió. El reintento por JSON inválido de `ClaudeRunner` continúa la misma sesión con `--resume` y un mensaje corto. Todas las corridas de un mismo mensaje (resume, reintento, reconstrucción) comparten un presupuesto de 10 minutos (`ClaudeInvocation.deadline`).
13. **Restore point:** se agrega `ChatMessage.restore: ChatRestorePoint?` (opcional, decodificación tolerante). Guarda el estado de la ventana antes y después del turno, para detectar ediciones manuales, y el snapshot de archivos.
14. **"Interrupted" (B.9):** se agrega `ChatSession.pending` (y `lastState`). Al reabrir, `ChatSession.recovered()` convierte un turno pendiente en el error "Interrupted".
15. **Capacidades de la sesión:** `ChatSession.canEditFiles` guarda si a Claude se le dijo que puede editar. Un chat de Respond que empezó en `ready` (solo lectura) y sigue después de implementar recibe, en el próximo `--resume`, una nota con las herramientas nuevas y las reglas de edición (`ChatPrompts.capabilityNote`). Se eligió la nota antes que una sesión nueva porque conserva la conversación, y `--resume` ya recibe las herramientas nuevas en `--tools`. Las herramientas de edición solo se dan a Respond con resultado, es decir, a turnos que pasan por `FixImplementer.chatTurn`.
16. **Huella de git en el chat:** `chatTurn`, `undoChatTurn` y `chatFilesChangedSince` comparan la huella (`securityDigest`) con la `gitIntegrity` de los fixes antes de cualquier git (salvo el `rev-parse` que ubica las carpetas). La huella se arrastra sin recalcularla, así que un cambio de hooks o config entre turnos nunca pasa a ser la base del push. `checkConfigOrigins` corre antes del `status` de `ensureClean`, porque `status` puede correr filtros de la config.
17. **Escrituras negadas:** `--settings` niega `Edit` (y por lo tanto `Write`) en `//**/.git`, `//**/.git/**`, `//**/.gitattributes` y `//**/.lfsconfig`.
18. **Decodificación:** los mensajes y los cambios se decodifican elemento por elemento. Un elemento roto o de una versión más nueva se saltea sin perder el resto.

**Verificado con el CLI real** (2.1.318, `--model haiku`, con los argumentos exactos de `ClaudeRunner.arguments`, en un repo de prueba en una carpeta temporal; 7 corridas):

- `--session-id <uuid>` y después `--resume <uuid>` funcionan con `--setting-sources ""`: la segunda recordó la palabra de la primera.
- `--resume <uuid inexistente>` sale con código 1. En stderr imprime `No conversation found with session ID: <uuid>`. En stdout manda una línea `result` con `subtype: error_during_execution`, `is_error: true`, `num_turns: 0`, sin `result` y con `errors: ["No conversation found with session ID: <uuid>"]`. Antes, el parser dejaba esa línea como resultado sin texto (`ClaudeError.failed`), así que el respaldo, que esperaba `commandFailed`, nunca se activaba. Ahora el parser usa `errors` como texto.
- Una API key inválida da una línea `result` con `is_error: true`, `api_error_status: 401` y `result: "Invalid API key · Fix external API key"`, y sale con código 1. No reconstruye.
- Con `--json-schema`, la herramienta de la salida estructurada se llama `StructuredOutput`, como supone `ClaudeStreamParser.hiddenTools`.
- Escrituras, con las herramientas de edición:
  - sin las reglas nuevas, `Write`/`Edit` sobre `.gitattributes`, `.lfsconfig` y `sub/.gitattributes` funcionaron;
  - `.git/hooks/pre-push`, `sub/.git/config` y el archivo `.git` de un worktree ya estaban bloqueados por el CLI;
  - con las reglas, en un worktree enlazado, quedaron negados el archivo `.git`, `.gitattributes`, `.lfsconfig`, `sub/.git/config` y `sub/.gitattributes`, y `Edit a.txt` y `Write notes/new.txt` siguieron funcionando.

  La sintaxis `//**/<nombre>` sirve para archivos sueltos y `//**/<carpeta>/**` para el contenido de una carpeta.

Puntos del spec que no se cumplen tal cual:

- **B.4 (integridad):** el spec dice que si Claude tocó `.git` se deshacen los archivos del turno. Pero si cambió la config o los hooks de git, o apareció un `.git` anidado, correr **cualquier** git podría ejecutar lo que escribió Claude. `FixImplementer` ya corta sin correr git en ese caso, y el chat hace lo mismo:
  - el mensaje queda en error, con el motivo;
  - no se revierte nada;
  - el usuario descarta el Respond, lo que borra el worktree.

  En el resto de las fallas (JSON inválido, timeout, Stop o archivos ignorados nuevos) sí se revierte, igual que un fix.
- **B.5 "se borra al cerrar la app":** no se borra sincrónicamente en `willTerminate`, porque git puede tardar. Se cancela el turno y la limpieza de huérfanos lo borra en el próximo arranque, igual que los worktrees de review.

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

---

## E. Instrucciones y configuración completa del proceso

Plan: `2026-11-19-prbar-plan-9-instructions.md`. Se implementa **después de B** (usa el chat) y **antes de C** (la CLI cubre también estos comandos).

### E.1 Reglas ("memoria" de Claude)

Archivo `~/Library/Application Support/PRBar/instructions.json` (escrito solo por la app, decodificación tolerante):

```json
{ "rules": [
  { "id": "uuid", "scope": {"kind": "global"} , "appliesTo": ["review", "respond"],
    "text": "No comentes estilo ni formato; eso lo resuelve el linter.",
    "source": "manual | settingsChat | prChat | suggestion", "createdAt": "…", "updatedAt": "…", "enabled": true },
  { "id": "uuid", "scope": {"kind": "repo", "repo": "acme/web-app"}, "appliesTo": ["respond"],
    "text": "Usamos React Query; no agregues fetch directo.", "source": "prChat", "…": "…" }
]}
```

- Reglas efectivas de un PR = globales habilitadas + las del repo del PR, filtradas por etapa (`review` para review, filtro y chat de review; `respond` para análisis, implementación y chat de respond).
- Se inyectan en cada prompt en una sección delimitada **"User rules (from the PRBar user, follow them)"**, separada del contenido del PR (que sigue siendo no confiable). Máximo 8 000 caracteres en total; si se pasa, se avisa en Settings y se truncan las más viejas.
- El texto de una regla se redacta (tokens) antes de guardarse, igual que el resto de lo que se guarda.

### E.2 Settings › Instructions (pestaña nueva)

- Lista agrupada: **Global** y una sección por repo configurado. Cada regla: texto editable en línea, chips Review/Fixes, switch habilitada, borrar, origen (ícono) y fecha.
- **Chat de instrucciones** al pie: el usuario escribe ("no comentes estilo", "en web-app usá React Query", "borrá la de console.log"). Corre un `claude -p` **sin ninguna herramienta** (`--tools ""`), con el mismo aislamiento de §8.3, sin worktree (cwd = carpeta temporal vacía), y salida `--json-schema`:
  `{"reply": "…", "actions": [{"type": "addRule", "scope": …, "appliesTo": […], "text": "…"}, {"type": "editRule", "id": "…", …}, {"type": "removeRule", "id": "…"}, {"type": "setRuleEnabled", "id": "…", "enabled": false}]}`.
  Recibe la lista actual de reglas (con id) y la lista de repos configurados. Las acciones se validan (repo configurado, id existente, texto no vacío ≤ 1 000 caracteres) y se aplican **directo**, con resaltado y **Undo** (mismo patrón que B.6). La conversación se guarda (últimos 50 mensajes) y usa `--resume` como B.4.

### E.3 "Recordá esto" desde el chat del PR

- Nueva acción del chat de Review y Respond: `{"type": "proposeRule", "scope": "global" | "repo", "appliesTo": [...], "text": "…"}`. Claude la usa cuando el usuario pide recordar algo ("de ahora en más…", "acordate…").
- **No se aplica sola**: se muestra en el mensaje como tarjeta "Save as rule — Global / acme/web-app — Review" con **Save** (editable antes de guardar) y **Dismiss**. Al guardar, `source = prChat`.

### E.4 Sugerencias a partir de lo descartado

- El esquema de findings de la etapa 1 agrega `"category": "bug | security | performance | tests | style | docs | other"` (decodificación tolerante: falta → `other`).
- Al publicar un review se registra cada finding **descartado por el usuario** (no los del filtro): repo, categoría, título, fecha (`discard-stats.json`, últimos 90 días).
- Si una categoría (≠ `other`) se descartó en **≥ 3 PRs distintos en 30 días** (por repo, o en ≥ 2 repos → global) y no hay una regla ni una sugerencia descartada para eso, aparece una sugerencia: en la pantalla de review publicado y en Settings › Instructions ("You usually discard *style* comments in acme/web-app. Create a rule?") con texto propuesto editable, **Create Rule** / **Not Now** / **Never**. Nunca se guarda sola.

### E.5 Opciones concretas

`ClaudeSettings` agrega (todas con valor por defecto que reproduce el comportamiento actual, decodificación tolerante):

```json
"review": { "minSeverity": "low", "maxFindings": null, "ignorePaths": [], "categories": {"style": true, "docs": true, "…": true},
            "tone": "direct | friendly | withSuggestions",
            "stage1": {"mode": "skill | prompt", "skill": "pr-review-toolkit:review-pr", "prompt": null},
            "filter": {"enabled": true, "mode": "skill | prompt", "skill": "superpowers:receiving-code-review", "prompt": null} },
"respond": { "runTestsBeforePush": false, "commitMode": "single | perComment",
             "commitMessageTemplate": "Address review feedback ({n} comments)",
             "allowNewTests": true, "allowNewDependencies": false,
             "replyTemplate": null,
             "analysis": {"mode": "skill | prompt", "skill": "superpowers:receiving-code-review", "prompt": null},
             "implementation": {"mode": "skill | prompt", "skill": null, "prompt": null} }
```

- Los campos existentes (`reviewSkill`, `filterEnabled`, `filterSkill`, `respondSkill`) se migran a esta estructura al cargar.
- **Review**: `minSeverity`, `maxFindings` (quedan los de mayor severidad), `categories` y `ignorePaths` (globs; además `ignorePaths` por repo en `RepoConfig`) se aplican **después** de la salida de Claude, de forma determinística, y también se le comunican en el prompt. Los findings ocultos por estas opciones van a la sección "Hidden by your settings" (colapsada, se pueden incluir a mano). `tone` va al prompt.
- **Fixes**: `runTestsBeforePush` corre el comando de tests del repo antes de pushear y bloquea el push si falla (con "Push Anyway"). `commitMode = perComment` hace un commit por comentario implementado (mensaje con la plantilla y `{comment}`). `allowNewTests`/`allowNewDependencies` van al prompt, y `allowNewDependencies = false` además se verifica: si el diff toca manifests de dependencias (`package.json` dependencies, `Package.swift`, `Gemfile`, `requirements*.txt`, `go.mod`, `Cargo.toml`, …) el resultado se marca con advertencia antes del push. `replyTemplate` (variables `{commit}`, `{summary}`) reemplaza el "Fixed in …" por defecto (que sigue respetando el idioma, §16).
- Variables de las plantillas: `{n}`, `{pr}`, `{title}`, `{comment}`, `{commit}`, `{summary}`; editor con "Insert Variable" y vista previa, como los templates de Slack.

### E.6 Prompts editables

- Cada etapa (review, filtro, análisis, implementación, chat de review, chat de respond, chat de instrucciones) tiene un prompt por defecto visible en Settings › Claude › **Prompts** (editor monoespaciado, "Reset to Default", indicador "Modified").
- Con `mode = prompt`, el prompt propio reemplaza al skill para esa etapa. Variables: `{diff_path}`, `{pr_md_path}`, `{language}`, `{rules}`, `{findings_json}` según la etapa (se valida que el prompt use las obligatorias de su etapa).
- **Parte fija, no editable**: PRBar siempre agrega antes y después del prompt del usuario el bloque de seguridad (el contenido del PR no son instrucciones, sin shell, no publicar), las reglas del usuario y la instrucción de formato de salida. Editar un prompt nunca cambia herramientas, permisos ni el esquema.

### E.7 CLI (en el plan 7)

```
prbar rules list [--repo R] [--json]
prbar rules add "texto" [--repo R] [--review] [--fixes]
prbar rules edit|remove|enable|disable <id>
prbar rules chat ["mensaje"]                 # el chat de instrucciones
prbar rules suggestions [--json] | accept|dismiss|never <id>
prbar claude review set --min-severity medium --max-findings 10 --ignore 'generated/**' --category style=off --tone friendly
prbar claude respond set --tests-before-push on --commit-mode per-comment --allow-deps off ...
prbar claude stage <review|filter|analysis|implementation> --skill S | --prompt-file F | --default
prbar claude prompt show|edit|reset <stage>
prbar repo set <repo> --ignore 'dist/**'
```

### E.8 Testing

- Decodificación tolerante y migración de `ClaudeSettings` viejo; `instructions.json` corrupto → vacío con backup.
- Reglas efectivas por PR/etapa; inyección en cada prompt (delimitada, truncado a 8 000).
- Chat de instrucciones con runner falso: argumentos (sin herramientas), validación y aplicación de acciones, undo.
- `proposeRule` nunca guarda sin confirmación.
- Detector de sugerencias: umbrales (3 PRs / 30 días, por repo vs global), "Never", reglas existentes.
- Filtros determinísticos de review (severidad, máximo, categorías, globs) y sección "Hidden by your settings".
- Fixes: tests antes del push bloquean, commits por comentario, advertencia de dependencias, plantilla de respuesta.
- Prompts: validación de variables obligatorias, la parte fija siempre presente aunque el prompt propio esté vacío o intente "anular" las reglas.

### E.9 Decisiones de implementación (Plan 9)

Donde el spec era ambiguo:

1. **Valores por defecto que reproducen lo actual (E.5):** `commitMode = perComment` (hoy hay un commit por comentario con el mensaje de Claude) y `commitMessageTemplate = nil`. Con `nil`, un commit por comentario usa el mensaje de Claude como hoy, y el commit único usa `Address review feedback ({n} comments)` (el valor del JSON del spec). Con una plantilla, se usa en los dos modos.
2. **`allowNewDependencies` por defecto en `false`**, como dice el JSON del spec, aunque agrega una línea al prompt y una advertencia que antes no había. No bloquea nada. `allowNewTests = true` reproduce el "Update or add tests if appropriate" de hoy y `tone = direct` no agrega nada.
3. **Parte fija (E.6):** el orden es `reglas de PRBar (seguridad) → contexto fijo (archivos, comentario recibido) → cuerpo editable → reglas del usuario → ajustes del usuario → formato de salida → recordatorio final`. Las reglas del usuario se agregan **siempre**. `{rules}` en un prompt propio también las pone en ese lugar: aparecen dos veces, y es inofensivo.
4. **Variables:** además de las del spec (`{diff_path}`, `{pr_md_path}`, `{language}`, `{rules}`, `{findings_json}`) hacen falta otras: `{pr}`, `{repo}`, `{title}`, `{author}`, `{head_ref}`, `{base_ref}`, `{code_location}`, `{skill}`, `{feedback_path}`, `{location}`, `{assessment}`, `{fix_plan}` y `{repos}`. Las obligatorias son `{diff_path}` (review), `{findings_json}` (filtro), `{feedback_path}` (análisis) y `{fix_plan}` (implementación); los chats no tienen. El texto del comentario recibido **no** es una variable: va siempre en el contexto fijo, delimitado y marcado como no confiable.
5. **Prompt propio y modo:** guardar un prompt editado de una etapa con skill la pasa a `mode = prompt`. "Reset to Default" borra el prompt y vuelve a `skill`. El selector de modo de cada etapa permite volver a `skill` sin perder el texto. En modo `prompt` el plugin del skill se carga solo si el prompt usa `{skill}`. Se decide sobre el cuerpo que de verdad corre (`ClaudeSettings.usesSkill`): si el prompt propio falta o no se puede usar, corre el cuerpo por defecto, que nombra el skill, y el plugin se carga.
6. **Prompt propio inválido:** si le falta una variable obligatoria, el editor no deja guardarlo. Si igual llega uno así (editado a mano en `config.json`), corre el prompt por defecto y Settings lo avisa. Una variable desconocida solo avisa: se manda tal cual.
7. **Ocultos por los ajustes (E.5):** una ruta ignorada, una categoría apagada o una severidad menor a la mínima ocultan el finding (`ReviewItem.hiddenBy`). `maxFindings` cuenta solo los que el filtro mantuvo y siguen visibles, y deja los de mayor severidad (a igual severidad, el orden de Claude). Si un finding está oculto y además descartado por el filtro, va a "Hidden by your settings". Los ocultos no arrancan elegidos y no cuentan en `keptCount`. Al reabrir la ventana, "Discarded by the filter" y "Hidden by your settings" arrancan abiertas si tienen findings elegidos para publicar.
8. **Globs:** un patrón sin `/` se compara con el nombre del archivo (`*.lock`) y uno con `/` con la ruta completa (`generated/**`, `src/legacy/*`). `*` también cruza carpetas, y un patrón que termina en `/` vale como `<patrón>**`.
9. **Sugerencias (E.4):** se cuentan PRs distintos (`prID`) con un finding descartado por el usuario de esa categoría en los últimos 30 días. Hay sugerencia global si son 3 o más PRs **en 2 o más repos**, y en ese caso reemplaza a las del repo para esa categoría. Si no, hay una por cada repo con 3 o más PRs. "Not Now" la esconde 30 días y "Never" para siempre, por categoría y alcance. Si la global está escondida ("Never" o "Not Now"), se muestran las de cada repo. Solo los repos configurados tienen sugerencia propia (con el nombre como está configurado); las decisiones y las reglas se comparan sin distinguir mayúsculas.
   Una regla "cubre" la sugerencia solo si se creó desde una sugerencia de esa categoría (`Rule.category`), con el mismo alcance o global, esté o no habilitada. Las reglas escritas a mano no se pueden relacionar con una categoría: para esas está "Never".
10. **Qué es un descarte del usuario:** un finding del draft que el filtro mantuvo, que no estaba oculto y que no se publicó. Solo se registra al publicar **con** comentarios: "Approve Without Comments" no cuenta como opinión sobre los findings. Tampoco cuentan los ocultos, los del filtro ni los que agregó el chat.
11. **Redacción del texto de las reglas (E.1):** los tokens de GitHub se piden a `gh` de forma asíncrona y no están en memoria, así que se tachan por **formato**: `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`, `github_pat_`, `xox?-` de Slack y `sk-ant-`, igual que `Redactor` con la máscara `***`. Se aplica a todo lo que se guarda como regla, incluidas las propuestas de Claude y las del chat de instrucciones, y a los mensajes del usuario en el chat de instrucciones antes de guardarlos, loguearlos o mandarlos.
12. **Tope de 8 000 caracteres (E.1):** se cuenta la suma de los textos de las reglas efectivas de cada prompt. Si se pasa, se dejan afuera las de `updatedAt` más viejo hasta que entren, y Settings › Instructions avisa cuántas quedan afuera.
13. **Reglas en los chats:** van en el prompt de arranque. En los turnos con `--resume` se vuelven a mandar solo si cambiaron desde el último turno (`ChatSession.lastRules`), igual que el estado de la ventana. Las reglas y el estado cuentan como vistos solo si el turno terminó bien: uno detenido (en cola o corriendo) o fallido los vuelve a mandar en el siguiente (también en el chat de instrucciones).
14. **`proposeRule`:** `scope: "repo"` es el repo del PR del chat. Sin `appliesTo` (o vacío), vale la etapa del chat (Review o Fixes). Como mucho 3 propuestas por respuesta. Las propuestas se guardan en el mensaje (`ChatMessage.proposals`, con estado `pending`/`saved`/`dismissed`), así que quedan en el historial. Se pueden guardar aunque la conversación ya sea de solo lectura.
15. **Chat de instrucciones:**
    - `cwd` fijo: `AppPaths.instructionsChatDir`, una carpeta vacía dentro de la carpeta temporal. Es fija para que `--resume` funcione entre turnos y reinicios.
    - Log: `~/Library/Logs/PRBar/instructions-chat.log`.
    - Timeout: 5 min.
    - Comparte el límite de 2 chats a la vez (`AppModel.chatScheduler`) con clave `instructions-chat`.
    - Modelo: `effectiveChatModel`.
    - Sin plugins.
    - Como la lista de herramientas es vacía, sale `--tools ""` y también `--allowedTools ""`. El QA lo verifica con el CLI real.
    - `addRule` sin `appliesTo` vale para las dos etapas. Un repo se puede nombrar por su nombre corto si no hay ambigüedad.
16. **Tests antes del push:** valen solo si hay commits para pushear y el repo tiene comando de tests.
    - Un `TestRun` sirve si es del mismo comando. Un turno del chat que cambió código ya borra `tests` (Plan 6).
    - Si no hay corrida válida, "Push and Reply" primero corre los tests y pushea solo si pasan. Si los tests no pueden arrancar (hay un turno del chat u otro trabajo en ese PR), no se pushea nada y la ventana lo avisa.
    - Si fallan, el PR queda en `readyToPush`, la ventana avisa y ofrece **Push Anyway** con confirmación.
17. **Dependencias:** en `package.json` cuenta solo si cambió alguna sección de dependencias (`dependencies`, `devDependencies`, `peerDependencies`, `optionalDependencies`, `bundledDependencies`). En el resto de los manifiestos y lockfiles (`Package.swift`, `Package.resolved`, `Gemfile*`, `requirements*.txt`, `go.mod`, `go.sum`, `Cargo.*`, `Podfile*`, `pyproject.toml`, `*.gradle`, `*.gradle.kts` (incluye `settings.gradle*`), `*.versions.toml` (catálogos de Gradle), `gradle.lockfile`, `composer.*`, etc.) cuenta cualquier cambio. En `package.json` también cuentan `overrides`, `resolutions` y `pnpm`. Se calcula siempre (`RespondResult.dependencyChanges`, también después de un turno del chat), y la ventana avisa solo con `allowNewDependencies = false`.
18. **Commit único:** se hace un commit por fix como siempre (con los mismos chequeos) y al final PRBar los junta de forma atómica: `git commit-tree <árbol de HEAD> -p <start>` (no corre hooks) y `git update-ref HEAD <nuevo> <último fix>` (compare-and-swap). Si algo falla, HEAD queda en el último fix y el árbol limpio. Todas las respuestas apuntan a ese commit.
19. **`replyTemplate`:** reemplaza solo el prefijo "Fixed in …". Si el usuario escribió una respuesta, se agrega después, como hoy.
    - `{commit}` es el link al commit.
    - `{summary}` es el resumen de una línea del fix. Lo escribe Claude y está en inglés.
    - `{comment}` es la primera línea del comentario, hasta 100 caracteres. En el commit único sale vacío (el commit cubre varios comentarios) y Settings lo avisa.
    - Sin plantilla, la frase por defecto sigue en el idioma del PR (§16).
20. **Prompts de los chats:**
    - Editable: el rol y el estilo de la respuesta.
    - Fijo: los archivos, la seguridad, el idioma de lo que se publica, las acciones y el estado de la ventana. Sin eso el chat no puede funcionar.
21. **Errores de lectura de `instructions.json`:** si el JSON está roto, se copia a `instructions.json.bak` y se arranca vacío, con un aviso en la pestaña. Una regla rota sola (por ejemplo, sin `scope` válido) se descarta y el resto queda. Nunca se convierte una regla de repo en global.
22. **Reintentos del chat de instrucciones:** como el chat del PR (B.11, 12), se reconstruye con el transcript solo si `--resume` dice que la sesión no existe (`ChatEngine.isMissingSession`); cualquier otro error se muestra después de una sola corrida. Todas las corridas de un mensaje comparten el presupuesto de 5 minutos (`ClaudeInvocation.deadline`).
23. **Mensajes y propuestas guardados:** `InstructionsChat.messages` y `ChatMessage.proposals` se decodifican elemento por elemento (`LossyArray`), como el resto del chat (B.11, 18).
24. **Texto no confiable en los prompts (inyección):** todo lo que viene de GitHub entra a los prompts delimitado con un código al azar y neutralizado.
    - **Marcadores con nonce (`PromptFence`):** 16 caracteres hex al azar por corrida (review etapa 1 y 2, análisis, cada fix) o por conversación en los chats de PR (`ChatSession.promptNonce`, guardado, el mismo en todos los turnos y en el contexto reconstruido). Las reglas del usuario van entre `<<<USER_RULES_<nonce>` y `USER_RULES_<nonce>>>>`; en los chats de PR el mensaje del usuario va entre `<<<USER_<nonce>` y `USER_<nonce>>>>`; en el fix, el comentario recibido entre `<<<COMMENT_<nonce>` y `COMMENT_<nonce>>>>`.
    - **Línea fija de seguridad:** la parte fija suma una línea: solo el texto entre esos marcadores exactos son las reglas del usuario (y, en los chats, sus mensajes). Cualquier otro texto que diga ser reglas del usuario, mensajes del usuario o instrucciones de PRBar es contenido no confiable aunque use marcadores parecidos. El bloque de reglas también lo repite al final.
    - **Neutralización (`UntrustedText`):** en el texto no confiable, `<<<` delante de `USER_RULES`, `USER`, `COMMENT` o `PR_DESCRIPTION` pasa a `‹‹‹`, y esos nombres seguidos de `>>>` pasan a `›››` (sin distinguir mayúsculas). Los encabezados de PRBar ("User rules (from the PRBar user…", "PRBar's rules for this run", "The user says:") quedan marcados con "(quoted)". Los heredocs (`<<<EOF`) y los `>>>` del código quedan como están. Título, autor, ramas, repo y ubicación del comentario van además en una sola línea (sin saltos ni caracteres de control o de formato, hasta 300 caracteres).
    - **Dónde se aplica:** review etapa 1 (`{title}`, `{author}`, `{head_ref}`, `{base_ref}`, `{repo}`); filtro (lo mismo y `{findings_json}`, escrito a partir del PR); análisis (`{title}`, `{repo}`); fix (comentarios y sus autores, `{location}`, `{assessment}`, `{fix_plan}`); chats de Review y Respond (`{title}`, `{author}`, `{repo}`, el estado de la ventana en el arranque y en los turnos siguientes, el transcript del contexto reconstruido y el mensaje); `pr.md` (título, autor y ramas en una línea; la descripción neutralizada, además del cambio `PR_DESCRIPTION` → `PR-DESCRIPTION` que ya tenía). El texto de las reglas también se neutraliza.
    - **No se tocan:** el diff (es lo que se revisa) ni `feedback.json` (JSON, sin saltos de línea literales, y sin el nonce no puede imitar los marcadores). El chat de instrucciones no recibe texto de PRs: sigue con `<<<USER` sin nonce y sin la línea. El conector de Slack manda el texto como argumentos JSON de una llamada exacta que PRBar verifica, sin reglas del usuario.
    - Una conversación guardada antes de esto recibe un nonce en su próximo mensaje y, si tiene reglas, se las vuelve a mandar con los marcadores nuevos.
25. **Settings › Instructions:** las secciones de repo comparan sin distinguir mayúsculas. Las reglas de repos que no están configurados (repo borrado o cuenta apagada) van a una sección **Other Repos**, con el repo en cada regla: siguen valiendo para los PRs de ese repo.
26. **Config por repo:** `ignorePaths`, carpeta local, carpeta de worktrees y comando de tests se buscan sin distinguir mayúsculas en la cuenta y el repo.
27. **Volver a una versión anterior:** durante una versión, `ClaudeSettings` también escribe los campos planos de antes (`reviewSkill`, `filterEnabled`, `filterSkill`, `respondSkill`). Al leer, si está la estructura nueva, se ignoran.

Además:

- **E.1:** el JSON de cada regla suma `category` (opcional; solo en las reglas creadas desde una sugerencia).
- **E.2:** `instructions.json` guarda también `suggestionDecisions` y `chat`.
- **E.5:** `commitMessageTemplate` es `null` por defecto (ver decisión 1). El JSON de `ClaudeSettings` suma `chatPrompts` (los prompts propios de los tres chats).

**Verificado con el CLI real** (2.1.318, `--model haiku`, con los argumentos exactos de `ClaudeRunner.arguments` para `InstructionsChatEngine.invocation`, cwd = una carpeta temporal vacía, 1 corrida): `--tools ""` junto con `--allowedTools ""` (y `--disallowedTools Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*`) se aceptan, sale con código 0. La línea `system/init` lista solo `StructuredOutput` como herramienta. Se le pidió leer un archivo fuera del cwd: no corrió ninguna herramienta (el único `tool_use` fue `StructuredOutput`), respondió que no tiene herramientas de archivos y el contenido del archivo no apareció en la salida. La salida estructurada (`InstructionsSchemas.turn`) llegó bien, con una acción `addRule` válida. No hizo falta cambiar los argumentos.

Puntos del spec que no se cumplen tal cual:

- **E.6 "Prompts" en Settings › Claude:** el editor es una hoja con `TextEditor` monoespaciado, "Insert Variable", los problemas de validación, "Reset to Default" y "Modified". La lista de etapas vive en una sección **Prompts** de la misma pestaña, no en una sub-pestaña.
- **E.2 "chips Review/Fixes":** en el modelo y en el JSON la etapa se llama `respond`; en la UI se muestra "Fixes".

---

## F. Ready to Merge

Plan: `2026-11-19-prbar-plan-10-merge.md`. Va después de E y antes de C.

### F.1 Cuándo un PR está "Ready to Merge"

Nueva categoría `readyToMerge` en `ActionClassifier`, para **mis PRs** (autor = la cuenta):
- no draft, abierto;
- `reviewDecision == APPROVED` (o, si el repo no exige reviews y `reviewDecision` es nulo, al menos una review `APPROVED` vigente y ninguna `CHANGES_REQUESTED` vigente);
- `mergeable != CONFLICTING`;
- **sin feedback nuevo**: si `ActionClassifier.newFeedback` reporta algo (cambios pedidos o comentarios sin responder desde el último push), el PR sigue en **My PRs with Feedback**. Ready to Merge es lo que queda cuando ya no hay nada que responder. Para esta decisión no cuenta el feedback ya cerrado: el de un reviewer cuya última review `APPROVED` es posterior a ese feedback, ni los comentarios del PR seguidos por un comentario mío (el autor). Ver F.8.18.

El CI corriendo o fallando **no** saca al PR de la lista: se ve el estado (ícono de CI) y el botón refleja si GitHub permite mergear. Cuenta para el badge (es algo que el usuario tiene que hacer).

Sección nueva en el popover, después de My PRs with Feedback: **Ready to Merge (N)**.

### F.2 Datos

GraphQL agrega por PR: `mergeable`, `mergeStateStatus`, `reviewDecision` (si no estaba), `viewerCanUpdate`; por repo: `squashMergeAllowed`, `mergeCommitAllowed`, `rebaseMergeAllowed`, `viewerDefaultMergeMethod`, `deleteBranchOnMerge`. Decodificación tolerante (campos que faltan → desconocido).

### F.3 Botón Merge

- En la fila: botón **Merge** con menú (chevron) para elegir otro método permitido. Método por defecto: el de `RepoConfig.mergeMethod` si está fijado y permitido; si no, `viewerDefaultMergeMethod`; si no, el primero permitido en el orden squash, merge, rebase.
- Habilitado según `mergeStateStatus`: `CLEAN`, `HAS_HOOKS` y `UNSTABLE` (fallan checks no requeridos) → habilitado (con `UNSTABLE` el texto de ayuda lo dice). `BLOCKED` → deshabilitado, "Blocked by branch protection or required checks". `BEHIND` → deshabilitado, "Branch is behind main". `DIRTY` → no está en la lista (conflictos). `UNKNOWN`/`DRAFT` → deshabilitado con "Checking…" hasta el próximo refresh.
- **Confirmación** (configurable, `merge.confirm`, por defecto encendida): diálogo "Merge #42 into main?" con título, método (popup para cambiarlo) y cantidad de commits. Botón por defecto "Squash and Merge"/"Merge"/"Rebase and Merge".
- **Merge**: mutación GraphQL `mergePullRequest(input: {pullRequestId, mergeMethod, expectedHeadOid})` con el `headRefOid` que se mostró: si alguien pusheó después, GitHub rechaza y PRBar lo dice ("The PR changed since you looked at it — refresh and try again"). Usa el token de la cuenta (nunca pasa por Claude).
- Estados de la fila: Merge → Merging… (spinner) → Merged ✓ (2 s) y la fila desaparece en el siguiente refresh; error → texto de GitHub + Retry.
- No borra la rama (el repo puede tenerlo configurado; se respeta lo que haga GitHub).
- Menú contextual de la fila: "Merge", "Merge With…" (submenú de métodos).

### F.4 Slack

Si el PR fue anunciado por PRBar (`SlackState.announcements`), después del merge se responde en el hilo con el template **`myPR.merged`** (por defecto `Merged :white_check_mark:`; variables `{link}`, `{title}`, `{number}`, `{repo}`, `{author}`, `{method}`), con el mismo provider (conector de Claude o token) y las mismas protecciones anti-duplicado que "Updated". Toggle **"Reply \"Merged\" in the thread when I merge from PRBar"** en Settings › Slack › My PRs (por defecto encendido). Si Slack falla, el merge igual queda hecho y el error va al log de Slack.

### F.5 Notificaciones y configuración

- Notificación nueva `readyToMerge` (por defecto encendida): "acme/api#42 is ready to merge" cuando un PR mío entra a la categoría. La de "approved" existente se mantiene; si las dos aplican en el mismo refresh, se manda solo `readyToMerge`.
- `RepoConfig.mergeMethod: "squash" | "merge" | "rebase" | null` (Settings › Repos: popup "Merge method: Repository default / Squash / Merge / Rebase", solo los permitidos).
- `AppConfig.merge: {"confirm": true}` (Settings › General: switch "Confirm before merging").
- Todo con decodificación tolerante.

### F.6 CLI (en el plan 7)

```
prbar prs --list ready-to-merge
prbar merge <pr> [--method squash|merge|rebase] [--yes]   # sin TTY exige --yes
prbar repo set <repo> --merge-method squash|merge|rebase|default
prbar config set confirm-merge on|off
prbar slack set merged on|off ; prbar slack template set myPR.merged "…"
prbar notify set ready-to-merge on|off
```

### F.7 Testing

- `ActionClassifier`: aprobado sin feedback → readyToMerge; aprobado con feedback nuevo → myFeedback; conflictos → no; draft → no; repo sin reviews requeridas.
- Método por defecto (config del repo, default de GitHub, permitidos) y habilitación por `mergeStateStatus`.
- `mergePullRequest` con transporte falso: variables exactas (incluido `expectedHeadOid`), error de head cambiado, errores de permisos.
- Slack: respuesta "Merged" solo si hubo anuncio, sin duplicar, template con variables.
- Notificación `readyToMerge` y deduplicación con `approved`.
- Snapshots: popover con la sección Ready to Merge y el diálogo de confirmación.

### F.8 Decisiones de implementación (Plan 10)

1. **Dónde viven los datos de merge.** Los del PR van en `PullRequest.merge` (`PRMergeState`). Los del repo dependen de la cuenta (`viewerDefaultMergeMethod`, `viewerPermission`), así que van en `Snapshot.repoMergeSettings`, con la misma clave que `fetchedScopes` (`"login|owner/repo"`). Un repo que falla en un refresco conserva los ajustes anteriores, igual que sus PRs.
2. **"Aprobación vigente" sin `reviewDecision`.** Por cada autor (que no sea yo) cuenta su **última** review entre `APPROVED`, `CHANGES_REQUESTED` y `DISMISSED`; un `COMMENTED` posterior no anula una aprobación. Hace falta al menos una `APPROVED` vigente y ninguna `CHANGES_REQUESTED` vigente. Las aprobaciones de bots cuentan (hay bots de aprobación).
3. **Conflictos.** Quedan afuera tanto `mergeable == CONFLICTING` como `mergeStateStatus == DIRTY`. Un `UNKNOWN` (GitHub todavía calcula) **sí** entra, con el botón en "Checking…".
4. **Permiso.** `viewerCanUpdate` se pide (lo dice el spec) pero no decide nada: para el autor del PR siempre es `true`. El botón se deshabilita con `viewerPermission` `READ` o `TRIAGE` ("You don’t have permission to merge in acme/api"); `viewerPermission` es un campo que el spec no menciona.
5. **Sin datos del repo** (refresco viejo o respuesta sin los campos): se ofrecen los tres métodos; si el repo no permite el elegido, GitHub lo rechaza y la fila muestra el error.
6. **Método por defecto:** `RepoConfig.mergeMethod` si está permitido; si no, `viewerDefaultMergeMethod` si está permitido; si no, el primero permitido en el orden squash, merge, rebase.
7. **Textos de habilitación:** `BEHIND` dice "Branch is behind \<base>" con la rama base real (el spec dice "main" como ejemplo). Sin node ID también es "Checking…".
8. **Botón:** siempre dice "Merge"; el método está en el tooltip ("Squash and Merge into main"), en el menú del chevron (con ✓ en el de por defecto) y en el diálogo.
9. **Diálogo de confirmación:** es una ventana chica (`WindowPresenter`, 440 × 230, no redimensionable), no un `.alert`: el popover es un `MenuBarExtra` y una alerta adentro se cierra con él. Muestra el título, `owner/repo · N commits · head → base`, un popup con los métodos permitidos, la nota de `UNSTABLE` y, si el repo borra la rama al mergear, "GitHub will delete the branch (repo setting)".
10. **Después del merge:** la fila muestra "Merged" 2 s y después PRBar refresca; la fila desaparece con ese refresco. Las fases de PRs que ya no están en el snapshot se descartan (`MergeQueue.prune`) con **cada** snapshot nuevo, no solo con el de después del merge. Ese refresco (y el de Retry) usa `PRStore.refreshNow()`: si hay un refresco en curso (que pudo empezar antes del merge) lo espera y refresca de nuevo, en vez de volver enseguida con el snapshot viejo.
11. **Retry** (`MergeFlow.retry`, puro): refresca primero (`PRStore.refreshNow`) y decide. Si el error fue `headChanged` o el head del PR refrescado no es el que se intentó, **solo limpia el error**: la fila muestra el PR nuevo y el usuario vuelve a apretar Merge (con `merge.confirm` apagado, Retry nunca mergea un head que el usuario no vio). Si es el mismo head, vuelve a pedir el merge con el mismo método por el mismo camino que el botón (`MergeFlow.request`): con `merge.confirm` encendido, se vuelve a confirmar. Si el PR ya no está en la lista, ver 20. `MergePhase.failed` guarda el `MergeError` (no solo el texto) y `MergeQueue.failure(prID:)` el PR tal como se intentó.
12. **Slack "Merged":** queda pendiente en `SlackState.mergedReplies` (persistido) y sale por el ciclo normal del announcer como `SlackAction.merged`: mismo provider, marca `uncertain` `merged:<prID>`, búsqueda de la respuesta en el hilo antes de reintentar un intento dudoso, backoff del conector. Si falla, se reintenta en cada ciclo durante 24 h (`SlackPlanner.mergedReplyWindow`) y el error va a los issues de Slack y al log; el merge ya está hecho. Pedir "Merged" dos veces para el mismo PR no hace nada. El pedido se guarda en el acto (`SlackAnnouncer.queueMergedReply`, sincrónico, desde `AppModel.mergeFinished`, todavía dentro del `postings.track` del merge) y la publicación corre después (`postQueued`): una actualización o un cierre en el medio no lo pierden. Los pedidos se borran de `slack-state.json` a las 48 h (`SlackState.mergedReplyRetention`: el día de reintentos y un día de margen).
13. **`{method}`:** vale `squash`, `merge` o `rebase` (el valor de `config.json`). Solo existe en la plantilla "Merged".
14. **Notificación:** título "acme/api#42 is ready to merge" y cuerpo el título del PR. Si en el mismo refresco aplican "approved" y `readyToMerge`, solo sale `readyToMerge`; si la de `readyToMerge` está apagada, sale la de "approved" como antes. `readyToMerge` sale recién cuando `mergeable` dejó de ser `UNKNOWN` (GitHub lo calcula tarde y el PR puede resultar con conflictos); mientras tanto, si el PR se acaba de aprobar, sale "approved", y `readyToMerge` llega en un refresco posterior. Si el snapshot anterior no tenía datos de merge (`state.json` de antes de Ready to Merge, sin node ID), no sale `readyToMerge`: los PRs ya aprobados no son novedad.
15. **Clave de la plantilla para la CLI:** el spec dice `myPR.merged`, pero el Plan 7 nombra las plantillas `new-pr`, `update` y `round`. Se recomienda `merged` (y aceptar `myPR.merged` como alias). Ver "APIs para la CLI".
16. **Mientras se instala una actualización** (spec D.3) no empieza ningún merge: el botón Merge, su chevron y "Merge" / "Merge With…" del menú contextual se deshabilitan con el mismo tooltip que Review y Respond (`jobsBlockedReason`), y `MergeQueue` rechaza el pedido con `MergeError.blocked` (la fila lo muestra como error). La mutación de merge y la respuesta "Merged" en Slack cuentan en `postings`: una actualización espera a que terminen.
17. El método fijado del repo se busca sin distinguir mayúsculas (`AppConfig.repoConfig(account:repo:)`), como el resto de los ajustes por repo.
18. **Feedback que no bloquea Ready to Merge** (`ActionClassifier.feedbackBlockingMerge`): de lo que cuenta `newFeedback` (reviews `COMMENTED`/`CHANGES_REQUESTED` y comentarios de otros, no bots, posteriores al último commit) se descarta, solo para decidir Ready to Merge, (a) todo lo de un reviewer cuya última `APPROVED` es posterior a ese feedback (un "LGTM" o un nit seguido de la aprobación), y (b) los comentarios del PR (no las reviews) seguidos por un comentario mío. Lo que queda decide: si es vacío y el PR está aprobado, Ready to Merge; si no, My PRs with Feedback como antes (`newFeedback` no cambia). Un comentario posterior a la aprobación sigue bloqueando.
19. **Nunca un pedido de merge silencioso** (`MergeFlow.request`, `MergePolicy.problem`): si el pedido no puede salir (se instala una actualización, el PR ya no está en Ready to Merge, el botón estaría deshabilitado, el método ya no está permitido) la fila muestra el error (`MergeError.blocked` / `.unavailable(motivo)`) en vez de no hacer nada; solo se ignora un pedido para un PR que ya se está mergeando o ya se mergeó. `AppModel.merge` (diálogo y CLI) vuelve a validar contra el PR del snapshot actual antes de llamar a GitHub (`.noLongerOpen` si ya no está).
20. **Retry de un PR que ya no está en la lista** (`MergeQueue.resolveMissing`): pudo mergearse aunque el pedido diera error (la red se cortó después de que GitHub lo mergeó). Se pide `GET /pulls/{n}` (`PRDetails.state`/`mergedAt`): si está mergeado, la fila pasa a "Merged" y se sigue como un merge propio (Slack "Merged" y refresco); si está cerrado, "This PR is no longer open."; si está abierto, "This PR isn’t in PRBar’s list anymore — refresh and try again."; un error de red se muestra tal cual.
21. **Merge queue:** si GitHub contesta con un error que menciona "merge queue", es `MergeError.mergeQueueRequired` ("This repo uses a merge queue — add the PR to the queue on GitHub."). PRBar no encola PRs. Precedencia de `MergeError.classify`: head cambiado, merge queue, permiso, no mergeable, otro.
22. **Diálogo de confirmación vigente:** con cada snapshot nuevo se cierran los diálogos de PRs que ya no están en Ready to Merge (`MergeFlow.confirmationsToClose`). El `contentID` de la ventana (`MergeFlow.confirmationContentID`) incluye todo lo que muestra (head, método, métodos permitidos, nota, borrado de rama, título, ramas, commits): una ventana reusada nunca muestra datos viejos.

Además:
- **F.2:** se agregan `viewerPermission` (repo) y `commits.totalCount` (PR); los datos del repo van en `Snapshot.repoMergeSettings` por cuenta y repo.
- **F.3:** la referencia de GitHub recomienda la API REST asíncrona de merge; se usa la mutación porque soporta `expectedHeadOid` y PRBar no apila PRs.
- **F.6:** la plantilla se llama `merged` en la CLI (como `new-pr`, `update`, `round`); `myPR.merged` queda como alias.

---

## G. Ventana de Merge con resumen del PR

Plan: `2026-11-19-prbar-plan-11-merge-window.md`. Reemplaza el diálogo de confirmación de F.3: **mergear siempre pasa por esta ventana**, que muestra el resumen del PR y recién ahí ofrece el método y el botón Merge.

### G.1 Entrada

- En la fila de Ready to Merge, el botón pasa a ser **"Merge…"** (sin chevron) y abre la ventana `Merge · repo#N` (una por PR, como Review/Respond). Si ya está abierta, la trae al frente.
- Menú contextual de la fila: "Merge…" (se quita "Merge With…": el método se elige en la ventana).
- La notificación `readyToMerge` abre la ventana.
- La opción "Confirm before merging" (`merge.confirm`, F.5) **se elimina**: la ventana es la confirmación. La clave vieja se ignora al decodificar. El comando `prbar config set confirm-merge` se elimina (bump del protocolo de la CLI).

### G.2 Contenido

Arriba, cabecera: `repo#N`, título, autor (avatar), `head → base`, "Open on GitHub". Debajo, secciones:

1. **Descripción** del PR (markdown renderizado; colapsable si es larga; "No description" si está vacía).
2. **Aprobaciones**: cada reviewer con su última review vigente (Approved / Changes requested / Commented), avatar y hace cuánto. Reviews requeridas pendientes, si GitHub lo informa.
3. **Checks del CI**: cada check (nombre, estado con ícono, requerido sí/no, duración) con link a su página. Resumen arriba: "8 passed · 1 failed (not required) · 1 running".
4. **Conversaciones sin resolver**: cantidad de hilos de review sin resolver (con link). Si hay, aviso amarillo.
5. **Archivos cambiados**: lista con ruta, `+N −M` y estado (added/modified/removed/renamed); total de commits y de líneas. Los primeros 100 archivos; si hay más, "and N more on GitHub".

Abajo, barra fija: nota de disponibilidad (la de `MergePolicy`, p. ej. "Some checks failed but aren't required" o el motivo de bloqueo), **popup de método** (solo los permitidos; por defecto el de F.3), el head que se va a mergear (`abc1234`, monoespaciado) y el botón principal **"Squash and Merge" / "Merge" / "Rebase and Merge"** (⌘↩). Mientras mergea: spinner y botones deshabilitados; al terminar: "Merged ✓" y la ventana se cierra a los 2 s. Errores en la barra con Retry (con la semántica de F.8.11/F.8.20: nunca mergea un head que no se mostró).

### G.3 Datos

Al abrir se pide a GitHub (token de la cuenta) una consulta GraphQL del PR: `body`, `files(first: 100)` (path, additions, deletions, changeType), `commits.totalCount`, `latestOpinionatedReviews` (author, state, submittedAt), `reviewDecision`, `reviewRequests`, `reviewThreads` (isResolved, cantidad), `statusCheckRollup.contexts` (CheckRun: name, status, conclusion, detailsUrl, isRequired(pullRequestNumber:), startedAt/completedAt; StatusContext: context, state, targetUrl, isRequired), `headRefOid`, `mergeable`, `mergeStateStatus`. Estado de carga con skeleton; error con Retry. Botón **Refresh** (⌘R) en la toolbar.

**Head fijo**: la ventana guarda el `headRefOid` que mostró. Si un refresh (de la ventana o del popover) trae otro head, aparece un banner "New commits were pushed since you opened this — Reload" y el botón Merge se deshabilita hasta recargar. El merge usa siempre `expectedHeadOid` = el head mostrado.

### G.4 Chat

Botón **Chat** (⇧⌘C) como en Review/Respond: panel lateral con el mismo `ChatCoordinator`, tipo nuevo `merge`, **solo lectura** (Read/Grep/Glob, sin acciones estructuradas salvo `proposeRule`), con el mismo aislamiento de B.4. Contexto: `pr.md` (título, descripción, aprobaciones, checks) y el diff del PR; worktree del head mostrado si el repo tiene `localPath` (mismo mecanismo que el chat de review), si no, solo diff. La conversación se guarda en el historial del merge (nuevo registro `MergeRecord` en History: PR, método, head, fecha, resultado, chat).

### G.5 CLI

- `prbar merge <pr> --preview` muestra el mismo resumen (descripción, aprobaciones, checks, hilos sin resolver, archivos) y `--json` lo devuelve completo.
- `prbar merge <pr>` interactivo muestra ese resumen antes de preguntar.
- `prbar open <pr> --merge` abre la ventana.
- `prbar chat <pr>` en un PR Ready to Merge usa el chat de tipo `merge`.
- Se elimina `config set confirm-merge` y su `AppCommand`; `CommandProtocol.version` sube a 3.
- El inventario de UI y los tests de paridad se actualizan.

### G.6 Otros

- `prbar update`: cuando la conexión se corta **después** de "Restarting PRBar", no se imprime "Error: Lost the connection…"; solo "Restarting PRBar…" y luego "PRBar X is running.".

### G.7 Testing

- Decodificación del query de detalle (con campos faltantes), resumen de checks (requeridos/no requeridos, CheckRun y StatusContext), aprobaciones vigentes, hilos sin resolver.
- Head fijo: refresh con otro head deshabilita Merge; el merge manda el head mostrado.
- Migración: config con `merge.confirm` carga sin error.
- Chat `merge`: herramientas de solo lectura, sin acciones salvo `proposeRule`.
- CLI: preview con el detalle, `open --merge`, paridad.
- Snapshots: ventana de Merge (claro/oscuro), con y sin chat; popover con "Merge…".

### G.8 Decisiones de implementación (Plan 11)

1. **"Merge…" siempre abre la ventana**, aunque `MergePolicy` diga que todavía no se puede mergear: la ventana es también el lugar para ver por qué (checks, reviews). El motivo sigue en la línea de estado de la fila y en la barra de la ventana, con el botón Merge deshabilitado (`MergeFlow.windowProblem`; F.8.19: nunca un silencio). Mientras se instala una actualización, la ventana abre igual; el merge no (`jobsBlockedReason`). Un PR ya mergeado no la abre (`MergeFlow.request`).
2. **La ventana no se cierra sola** si el PR sale de Ready to Merge (reemplaza F.8.22, que cerraba el diálogo): perdería el chat. La barra dice "This PR isn’t ready to merge" o "This PR isn’t in PRBar’s list anymore." y Merge queda deshabilitado. Después de mergear muestra "Merged" y se cierra a los 2 s.
3. **Reviews:** se piden `latestOpinionatedReviews(first: 50)` y `latestReviews(first: 50)`. Por autor, la opinión (Approved / Changes requested / Dismissed) gana sobre un Commented posterior, como F.8.2; quien solo comentó aparece como Commented. Se excluyen las reviews del autor del PR (responder un hilo crea una review `COMMENTED` suya). "Reviews requeridas pendientes" = los `reviewRequests` abiertos (usuario o equipo) y, con `reviewDecision == REVIEW_REQUIRED`, la línea "More approvals are required by branch protection".
4. **Resumen de checks:** "N passed · N failed · N running · N skipped". Los fallidos se califican: todos requeridos → "2 failed"; ninguno → "2 failed (not required)"; mezcla → "3 failed (1 not required)". "running" junta en curso, en cola y pendientes (`EXPECTED` incluido); "skipped" junta skipped, neutral, cancelados y stale; una conclusión desconocida cuenta como fallida. Más de 100 contextos o archivos: "and N more on GitHub".
5. **Refresh (⌘R):** con el mismo head reemplaza el detalle (checks y reviews nuevos). Con otro head **no** reemplaza lo mostrado: guarda el head nuevo, aparece el banner y "Reload" adopta el detalle nuevo (`MergeWindowModel`). Un snapshot del popover con otro head también pone el banner (`noteHead`). El merge manda siempre `expectedHeadOid` = el head mostrado (`ClassifiedPR.pinned(head:)`).
6. **Retry** en la barra de la ventana (F.8.11/F.8.20): refresca la lista (`refreshNow`) y la ventana, y decide con `MergeFlow.retry`: mismo head → vuelve a mergear lo que muestra la ventana; `headChanged` o head distinto → solo limpia el error (la ventana queda con el banner); el PR ya no está → `resolveMissing`. En la fila, el error ofrece **"Merge…"** (abre la ventana) y Dismiss: la ventana es la confirmación.
7. **Sesión de merge** (`MergeSession`, una por PR, en `AppModel`): un `MergeRecord`, el `MergeWindowModel` y el chat. Se crea al abrir la ventana, al mergear desde la CLI o al chatear. El registro se guarda en `history/merge/` solo cuando hay algo que guardar (un mensaje del chat o un intento de merge: `merged` o `failed` con el error). Después de un merge la sesión termina: el chat queda de solo lectura y su worktree se borra. Las sesiones de PRs que ya no están en el snapshot, sin ventana abierta ni merge en curso, se terminan con cada snapshot.
8. **Chat `merge`:** aplican las reglas de `respond` (es un PR propio) y `proposeRule` propone con esa etapa. Sin skills ni plugins. Herramientas de solo lectura (las del chat de Review) aunque el contexto pida edición; toda acción salvo `proposeRule` se descarta con una nota (`ChatActions.applyMerge`). Contexto: el worktree del chat de Review fijado al head mostrado (o solo diff), con un `pr.md` propio (`MergeContextWriter`) que lleva la descripción entre los marcadores de `ReviewContextWriter` (neutralizada) y los nombres de reviewers, checks y archivos en una línea y neutralizados. El estado para Claude (JSON): el head a mergear, el resumen de checks, las conversaciones sin resolver y el `reviewDecision`. Si la ventana recarga otro head, un chat sin mensajes se rehace con ese head; uno con mensajes sigue y el panel avisa "Claude sees an older commit (abc1234)."
9. **`prbar chat <pr>`** en un PR que está en Ready to Merge usa siempre el chat `merge` (aunque quede un análisis de Respond terminado); antes del primer mensaje carga el resumen si la sesión no lo tiene.
10. **`prbar merge --preview` / interactivo:** `mergePreview` (ahora `async`) pide el resumen a GitHub. Si el head de GitHub no es el del snapshot, refresca una vez y, si siguen distintos, no muestra un resumen de otro head (`detailError`: "run `prbar refresh`"); el head que se confirma sigue siendo el del snapshot, que GitHub rechaza si cambió. Si el resumen falla, la vista previa sale igual con `detailError`. `--json` trae `detail` completo.
11. **Historial:** los merges aparecen en la ventana de Historial (ícono `arrow.triangle.merge`, pastilla Merged / Failed / Not merged y un detalle con método, head, resultado y la conversación) y en `prbar history --kind merge` / `history show` (con `mergeMethod` y `headOid`).
12. **Prompt editable:** `PromptStage.mergeChat` ("Merge chat", `chat-merge` en la CLI), en `ClaudeSettings.chatPrompts.merge`; aparece en Settings › Claude › Prompts.
13. **Notificación:** `PlannedNotification.mergePRID`; el click abre la ventana si el PR sigue en la lista, si no el PR en el navegador. Las agrupadas no lo llevan.

Cambios después de la revisión del código del plan 11:

14. **Errores parciales de GraphQL:** `mergeDetail` no usa el `graphQL` genérico (que tira con cualquier error). Si la respuesta trae el PR, se muestra lo que llegó y las secciones con errores (según el `path` del error: reviews, checks, conversations, files o details) quedan en `MergeDetail.incomplete`; la ventana, `prbar merge` y el `pr.md` del chat dicen "Some checks and files couldn’t be loaded from GitHub." Solo el rate limit o la falta del PR son un error. Los errores van al log de la app. `reviewRequests` incluye `Bot` y `Mannequin`.
15. **Conversaciones:** se piden los primeros 100 hilos; si `totalCount` es mayor, `checkedThreads` dice cuántos se miraron y el texto nunca es "All conversations are resolved": "At least N unresolved conversations" o "X of Y conversations are resolved — check the other Z on GitHub" (`MergeDetail.conversationsSummary`, el mismo en la ventana, la CLI y el `pr.md`).
16. **Reabrir la ventana** (estaba cerrada y la sesión seguía) refresca el resumen con el head fijo (`MergeWindowModel.opened(alreadyOpen:)`): un head nuevo da el banner. Si ya está abierta, no pide nada.
17. **Snapshot atrasado** (reemplaza parte de G.8.5): el banner que puso un snapshot lo borra un snapshot posterior con el head mostrado (el que vio GitHub con ⌘R no). Un head de snapshot que una carga desmintió (GitHub trajo el mostrado) no vuelve a poner el banner. Reload también refresca la lista, y una primera carga con otro head que la lista la refresca una vez. Así Merge y Reload no entran en un loop con la lista atrasada.
18. **Chat al recargar** (precisa G.8.8): el chat vacío que mira otro commit (`MergeFlow.rebuildsChat`) se rehace enseguida, con una sesión nueva, después de Reload y después de la primera carga (un chat abierto antes de cargar, o con `prbar chat`, tenía el head del snapshot). El panel abierto ya no se queda en "The chat needs the PR in PRBar’s list."
19. **Botón Merge:** la decisión es `MergeFlow.windowMerge` (PRBarCore, con tests): el PR fijado al head mostrado y el método, o el error (`.blocked` durante una actualización, si no `.unavailable` con el texto de `windowProblem`).
20. **Historial** (precisa G.8.7): un intento queda como `failed` solo si llegó a GitHub (`MergeFlow.recordsAttempt`); los prechecks (`unavailable`, `noLongerOpen`, `blocked`, `missingMergeData`, en curso, ya mergeado) solo se ven en la fila. Un merge confirmado sin sesión (p. ej. `resolveMissing` terminó con la ventana ya cerrada) completa el último registro fallido del PR (`MergeHistory.lastFailed`) en vez de crear otro.
21. **Fin de la sesión con un turno en curso:** `ChatCoordinator.markReadOnly` corta el turno y borra el workspace cuando el turno terminó de verdad (antes lo borraba mientras Claude podía estar leyéndolo). Vale también para Review y Respond.
22. **`prbar merge --preview`** de un PR que todavía no se puede mergear muestra el resumen con "Can’t merge yet: …" (`MergePreviewInfo.problem`, opcional; `MergeFlow.previewCheck`) y sale con 6. `prbar merge` sin `--preview` sigue fallando con el motivo antes de preguntar. Una app vieja no manda `problem` y la vista previa falla como antes.
23. Settings › Claude: el switch dice "Chat with Claude in Review, Respond and Merge windows" (también `prbar claude set --chat`).

**API de GitHub verificada** (referencia pública de GraphQL, `docs.github.com/en/graphql/reference/pulls`, `/checks` y `/commits`, consultada el 2026-11-19): `PullRequest.files` es nullable (`PullRequestChangedFileConnection`, `totalCount`; `PatchStatus`: `ADDED`, `CHANGED`, `COPIED`, `DELETED`, `MODIFIED`, `RENAMED`); `statusCheckRollup` es un campo directo del PR; `StatusCheckRollup.contexts` es `StatusCheckRollupContextConnection!` (con `totalCount`, `checkRunCount`, `statusContextCount`) de la unión `CheckRun | StatusContext`; `CheckRun.isRequired(pullRequestId:, pullRequestNumber:)` y **también** `StatusContext.isRequired(pullRequestId:, pullRequestNumber:)` (el spec lo nombra sin argumentos), ambos `Boolean!`; `latestOpinionatedReviews(writersOnly:)` solo trae opiniones, por eso también `latestReviews`; `ReviewRequest.requestedReviewer` es la unión `Bot | EnterpriseTeam | Mannequin | Team | User`.

Puntos del spec que no se cumplen tal cual:

- **G.2 "markdown renderizado":** se usa el Markdown en línea de SwiftUI (negrita, código, links) respetando los saltos de línea, como el chat y las notas de versión; listas y títulos se ven como texto.
- **F.8.22** queda reemplazado por G.8.2 (la ventana no se cierra sola).

---

## H. Pestañas en el popover: To Review / My PRs

Plan: `2026-11-19-prbar-plan-12-popover-tabs.md`. Va después de G.

### H.1 Diseño (opción A elegida por el usuario)

- Debajo de la cabecera del popover, un **control segmentado nativo** (`Picker(.segmented)`) con dos pestañas: **To Review N** y **My PRs N**, donde N es la cantidad de PRs accionables de esa pestaña (lo mismo que suma el badge). Si una pestaña tiene algo pendiente y no está seleccionada, su número va con un punto de acento.
- **To Review**: secciones To Review y Updated Since My Review, más "Other" (PRs ajenos sin acción: drafts, ya revisados, etc.) colapsada.
- **My PRs**: secciones My PRs with Feedback y Ready to Merge, más **"Waiting for Review"** (mis PRs abiertos sin nada que hacer: sin feedback nuevo y no listos para mergear) colapsada.
- Las secciones vacías no se muestran (como hoy). Si una pestaña queda vacía: estado vacío propio ("Nothing to review 🎉" / "No PRs of yours need anything").
- La pestaña elegida se recuerda entre aperturas (`UserDefaults`, `popoverTab`). ⌘1 / ⌘2 cambian de pestaña con el popover abierto.
- El badge de la barra de menú no cambia (suma las dos pestañas).
- Las notificaciones que abren el popover seleccionan la pestaña del PR (solo para la próxima apertura, sin guardarla: H.4.7).

### H.2 CLI

- `prbar prs --tab to-review|mine` (alias de los filtros por sección existentes) y `prbar status` muestra los totales por pestaña.
- `prbar app popover --tab to-review|mine` (o el equivalente en el comando que abre el popover) para paridad con el control segmentado; el inventario de UI incluye el segmentado.

### H.3 Testing

- Asignación de categorías a pestañas (incluido "Waiting for Review" = mis PRs `.other`), contadores por pestaña, estados vacíos.
- Snapshots: popover en cada pestaña (claro/oscuro), y estados vacíos.

### H.4 Decisiones de implementación (Plan 12)

1. **"Mío"** = el autor del PR es la cuenta desde la que se ve (`pr.author` == `item.account`, sin distinguir mayúsculas). `ClassifiedPR` ya viene desduplicado desde la cuenta autora (`SnapshotBuilder.dedupeAndSort`). Solo se compara con la cuenta que lo ve, no con todas las cuentas del usuario: si un PR de mi otra cuenta llega visto desde esta (p. ej. la cuenta autora está desactivada), es "ajeno" y va a To Review (Other si no hay nada que hacer). Se mantiene así a propósito (revisión del plan); hay un test del caso.
2. **Asignación:** `toReview`, `updatedSinceMyReview` → To Review; `myFeedback`, `readyToMerge` → My PRs; `other` → My PRs si es mío ("Waiting for Review"), si no To Review ("Other"). No hay categoría nueva en `PRCategory`: "Waiting for Review" es una **sección** (`PopoverSection.waitingForReview`) y la clasificación de §7 no cambia.
3. **Contador N** de cada pestaña = PRs con `category.countsForBadge` en esa pestaña. Las dos suman exactamente `Snapshot.badgeCount` (hay un test). Other y Waiting for Review no cuentan.
4. **Punto de acento:** el control segmentado nativo de macOS ignora colores en sus etiquetas, así que el "punto" es un carácter: la pestaña **no** elegida con N > 0 dice `My PRs 2 •`. VoiceOver: cada segmento dice "My PRs, 2 need your action" y, si no está elegido y N > 0, agrega ", has pending items" (el `•` no se lee). Como el segmentado nativo puede ignorar la etiqueta de cada segmento, el `Picker` lleva además un `accessibilityValue` con las dos pestañas: "To Review selected, 3 need your action; My PRs, 2 need your action, has pending items".
5. **Estado vacío:** si una pestaña no tiene PRs accionables se ve su mensaje ("Nothing to review 🎉" / "No PRs of yours need anything"), y debajo, si tiene, su sección colapsada (Other / Waiting for Review), como hoy con "All Caught Up".
6. **El control** se muestra solo cuando hay lista (hay snapshot, una cuenta activa y `gh`); con los mensajes de "Set Up an Account", "GitHub CLI not found", "Offline" o "Loading PRs…" no aparece. ⌘1/⌘2 siguen la misma condición: sin el control no hacen nada.
7. **Notificaciones:** hoy ninguna notificación abre el popover (abren GitHub o una ventana). El clic en cualquier notificación de **un** PR (las que tienen `PlannedNotification.prID`) muestra la pestaña de ese PR **solo en la próxima apertura** del popover (o ya, si está abierto): no se guarda en `UserDefaults` ni pisa la que eligió el usuario, y al cerrarse el popover vuelve la guardada (`PopoverTabState.selectForNextOpening`; la app avisa aperturas y cierres mirando la ventana del popover). Si el usuario cambia de pestaña con el popover abierto, esa sí se guarda. La acción de la notificación no cambia. Las agrupadas no tocan la pestaña.
8. **`prbar app popover [--tab]`** elige la pestaña (y la guarda) y abre el popover haciendo clic en el botón de la barra de menú (`NSStatusBarButton.performClick`), después de `NSApp.activate()` para que ⌘1/⌘2 funcionen. El botón se busca primero en las ventanas `NSStatusBarWindow` (clase privada) y, si no está, en todas las de la app. Si el popover ya está abierto (su ventana está visible, o el botón está resaltado / en `.on`), no hace clic (lo cerraría): solo lo trae al frente. `openPopover` es async: después del clic espera (hasta ~0,5 s) y responde `shown` según la visibilidad real de la ventana del popover. Si no encuentra el botón o el popover no apareció, igual elige la pestaña y responde `shown: false`; la CLI dice "Selected My PRs. Click PRBar in the menu bar to see it."
9. **`prbar prs --tab`** se combina con `--list`; una sección que no es de esa pestaña es error de uso (`--list mine isn’t in the To Review tab.`). `--list other --tab mine` = Waiting for Review. La columna "Section" de `prbar prs` muestra el título de la sección del popover (`Waiting for Review` en vez de `other` para mis PRs).
10. **Protocolo 4:** `listPRs` lleva la pestaña. Una app vieja ignoraría el filtro sin avisar (devolvería todo), así que se sube la versión. `PRInfo.tab`/`section`, `StatusInfo.tabCounts` y `StatusInfo.sectionCounts` son opcionales para leer respuestas viejas. `prbar status` lista las secciones del popover (Other y Waiting for Review por separado) con `sectionCounts`; con una app que no lo manda, vuelve a las categorías. Los valores JSON de `section` son los nombres de `PopoverSection` en camelCase (`toReview`, `updatedSinceMyReview`, `otherToReview`, `myFeedback`, `readyToMerge`, `waitingForReview`); se renombraron (antes `other`/`waiting`) en la revisión del plan, antes de publicar el protocolo 4.
11. **UserDefaults** `popoverTab` guarda `to-review` o `mine`; un valor desconocido vuelve a To Review. El modo de capturas recuerda la pestaña solo en memoria (`AppModelServices.popoverDefaults = nil`, `PopoverTabState(store: nil)`; los tests usan un `PopoverTabStore` en memoria y el único que usa `UserDefaults` solo lee su dominio de registro (escribir en un suite deja un `.plist` que cfprefsd recrea aunque se lo borre)): un dominio propio de `UserDefaults` dejaba un `.plist` en `~/Library/Preferences`, y las capturas no escriben fuera de su carpeta.
12. **Subtítulo de Waiting for Review:** "nothing to do right now" (el del plan, "no new feedback, not ready to merge", quedaba cortado en el ancho del popover; "waiting on reviewers" no era cierto para mis drafts ni para mis PRs con conflictos, que también caen ahí).
13. **El control** no se muestra tampoco con "Offline"/"GitHub Rate Limit" sin datos (snapshot que falló del todo y sin PRs), además de los casos de la decisión 6.
14. **Lugar del pie de recursos (Plan 13):** en `PopoverView.body`, entre `content` y `UpdateRow`, marcado con un comentario.
15. **Commits intermedios en verde:** para que cada commit compile y pase todos los tests, el comando `prbar app popover` (con su línea en `CLIRouter`) y la firma nueva de `AppModel.listPRs` entraron con el protocolo 4 (Task 3), con un `openPopover` provisorio en la app que la Task 5 completó; el test de `AppCommand.Name` pasa de 100 a 101 casos y el JSON estable de `PRInfo` incluye `section` y `tab`.
16. **Capturas:** la selección del control segmentado no se ve en el modo de capturas (pasa igual con los segmentados de Settings: limitación del render fuera de pantalla); el `•` sí marca la pestaña no elegida.

---

## I. Recursos que consume PRBar

Plan: `2026-11-19-prbar-plan-13-resources.md`. Opción A elegida por el usuario: **pie del popover**.

- Línea fija al pie del popover (visible en las dos pestañas): `◔ CPU 12%  ▤ RAM 640 MB  ⛁ Disk 2.3 GB  ›`.
  - **CPU y RAM**: de la app y de todos sus procesos hijos (claude, git, swift build del updater, gh), sumados. Se muestrean cada 2 s **solo mientras el popover o la ventana de detalle están abiertos** (con `proc_pidinfo`/`proc_listchildpids` o `libproc`; sin `ps` en loop). CPU en % de un núcleo como Activity Monitor.
  - **Disco**: lo que PRBar ocupa en `~/Library/Application Support/PRBar` (worktrees, carpetas de contexto, clone del updater, staging, historial, logs) + los worktrees de PRBar que viven dentro de los clones del usuario (`<worktreesDir>`). Se calcula en segundo plano, cacheado, a lo sumo cada 60 s, y al terminar un trabajo.
- Clic en la línea → ventana **"PRBar Activity"**:
  - **Ahora**: cada proceso vivo con su tarea ("Review api#317 · claude", "Update build · swift"), CPU, RAM y tiempo corriendo; botón Stop por tarea (usa el cancel de cada cola).
  - **Disco** por categoría y por repo (worktrees activos vs huérfanos, clone del updater, builds, logs, historial) con **Clean Up**: borra worktrees huérfanos (con el mismo mecanismo seguro de §8.5: nunca `git worktree prune`), el staging del updater y builds viejos, y opcionalmente logs/historial de más de N días (confirmación con el total a liberar). Nunca toca worktrees con trabajo en curso ni con fixes sin pushear.
  - Si hay trabajos corriendo en un servidor remoto (parte J), aparecen con "on <host>" y sin CPU/RAM locales.
- Umbral opcional (Settings › General): avisar si PRBar ocupa más de X GB (por defecto apagado).
- CLI: `prbar resources [--json]` (CPU, RAM, disco por categoría, procesos), `prbar cleanup [--older-than 30d] [--yes]`.
- Tests: suma de árbol de procesos con un proveedor falso, cálculo de disco en carpetas temporales, Clean Up nunca borra worktrees activos/con fixes sin pushear, muestreo solo con la UI abierta.

### I.1 Decisiones de implementación (Plan 13)

1. **Dónde está el disco de PRBar.** Los worktrees de review/chat y las carpetas de contexto viven en `$TMPDIR/PRBar/worktrees` (§8.2: `~/Library` está negado a Claude), no en Application Support. Se mide: `~/Library/Application Support/PRBar` (historial, clon y staging del updater, config/estado), `$TMPDIR/PRBar/worktrees` (+ la raíz vieja `~/Library/Caches/PRBar/worktrees`), `~/Library/Logs/PRBar` y los worktrees de Responder dentro del `worktreeDir` de cada repo (por defecto `<localPath>-worktrees`), solo los que tienen nombre de PRBar.
2. **Categorías:** Worktrees (activos / huérfanos, por repo), Updater (clon `source/`, su `.build/` = builds, `update-staging/`), History (`history/`: registros y logs de Claude, review, respond y merge), Logs (`~/Library/Logs/PRBar`), App data (lo demás de Application Support). Tamaños **asignados en disco** (`totalFileAllocatedSize`), sin seguir symlinks.
3. **Activo vs. huérfano.** Activo = está en `WorkspaceRegistry` (lo anotan `WorktreeManager.prepare`, `WorktreeResolver.prepare` y el análisis de Respond **antes** de crear la carpeta y lo borran sus `cleanup`), o es el worktree de un draft de Responder que la app tiene (aunque haya fallado, §14.2). Huérfano = nombre de PRBar, no activo y sin modificar en los últimos 5 minutos.
4. **Clean Up nunca toca** un worktree activo (se re-verifica justo antes de borrar), ni uno de Responder con cambios sin commitear o commits que no están en ninguna rama, remoto, tag ni `refs/prbar/*` (`git rev-list --count HEAD --not --branches --remotes --tags --glob=refs/prbar/*` ≠ 0): esos salen como "Skipped" con el motivo. Saca worktrees con `WorktreeManager.cleanup`/`WorktreeResolver.cleanup` (§8.5: `worktree remove --force` de ese worktree, nunca `git worktree prune`); solo borra dentro de las raíces de PRBar. Las refs de corridas viejas no se tocan (las borra la limpieza del arranque).
5. **Updater:** `update-staging/` y `source/.build/` se borran solo si no hay una instalación en curso (`UpdateInstallSession.isInstalling`); el clon `source/` no se borra.
6. **Historial y logs de más de N días:** archivos regulares de `history/` y `~/Library/Logs/PRBar` con fecha de modificación anterior a N días. UI: toggle "Also delete history and logs older than [30] days"; CLI: `--older-than 30d` (o `30`, 1–3650). `prbar.log` nunca se borra (se chequea al armar el plan y otra vez al borrar).
7. **Muestreo:** cada 2 s mientras el popover **o** la ventana Activity están en pantalla (consumidores "popover"/"activity"; el popover se sigue con `occlusionState` porque `MenuBarExtra` deja la ventana creada); se para en cuanto los dos se cierran. CPU = suma de `ri_user_time + ri_system_time` (`proc_pid_rusage`, convertidos con `mach_timebase_info`) de la app y su árbol (`proc_listchildpids`) sobre el tiempo entre muestras: % de un núcleo, como Activity Monitor. RAM = suma de `ri_phys_footprint`. Un proceso que nació entre muestras aporta todo su tiempo de CPU.
8. **Disco:** se calcula en segundo plano al abrir el popover o la ventana si el cálculo tiene más de 60 s, y otra vez al terminar un trabajo (review, respond, merge, Clean Up) si alguna de las dos está abierta (si no, el próximo abrir recalcula). Nunca más de uno a la vez. La ventana tiene además "Refresh".
9. **Tarea de cada proceso:** `SystemProcessRunner` anota cada proceso con la `ProcessActivity` de la tarea (un `@TaskLocal` que ponen `JobScheduler` —review, respond, chats, instrucciones—, el updater y Slack). Los nietos heredan la del ancestro anotado más cercano. Sin anotación, el proceso va en la fila "PRBar".
10. **Stop por tarea:** Review → `cancelReview(prID:)`; Respond → `cancelRespond(prID:)`; Chat → `stop()` del coordinador del chat del PR; Instructions chat → `instructionsChat.stop()`; Update build → `updates.cancelInstall()` solo antes de `installing`/`relaunching` (después, deshabilitado con "Can’t stop while PRBar is being replaced"); Slack → sin Stop.
11. **Umbral:** Settings › General › Disk: "Warn when PRBar uses more than [N] GB" (apagado por defecto; 1–100 GB; al encenderlo arranca en 5). Notificación `diskUsage` "PRBar Is Using a Lot of Disk" **una vez** por cruce hacia arriba; clic → ventana Activity. CLI: `prbar config set disk-warning <GB|off>`.
12. **CLI:** `prbar resources` toma dos muestras con 1 s de diferencia si no hay una de menos de 3 s y calcula el disco si tiene más de 60 s. `prbar cleanup` muestra el plan y pide confirmación (sin terminal, `--yes`); `--preview` solo lista; al confirmar, la app **vuelve a armar** el plan y re-verifica cada ítem antes de borrarlo (ver 18: solo ejecuta lo que se confirmó). La vista previa no corre git: lo que se saltea por cambios sin commitear, commits sin pushear o un worktree que git no lista se sabe recién al ejecutar y sale como "Skipped" con el motivo. Sin nada para limpiar: "Nothing to clean up." y exit 0.
13. **Protocolo:** sin cambio de versión (sigue en 4): solo hay comandos nuevos y resultados nuevos; contra una app vieja dan el error de comando desconocido ("Restart PRBar").
14. **Ventana PRBar Activity (mockup aprobado):** tres tiles (CPU "of one core", RAM "PRBar and N processes", Disk "X can be cleaned"); "Running now" como tabla Task / CPU / RAM / Time / Stop con una fila por tarea (los nombres de sus procesos debajo del título; la app y los procesos sin tarea van en la fila "PRBar"; un trabajo remoto muestra "on <host>" y "—" en CPU/RAM); "Disk" como tabla por categoría: Active worktrees y Orphaned worktrees "(can be cleaned)" con el desglose por repo debajo, Update clone and builds, Logs and history, y una fila más, **Settings and state** (App data), que el mockup no tenía, para que las filas sumen el Total; "Clean Up… (frees X)" con X = huérfanos + caché del updater (sin los archivos viejos: el diálogo de confirmación trae el total exacto) y la nota "Clean Up never touches worktrees with a job running or fixes not pushed yet." El resultado (liberado, salteados con motivo, fallidos) queda debajo.
15. **Unidades:** disco en unidades decimales (como Finder: `ByteCountFormatter .file`), RAM en binarias (como Activity Monitor: `.memory`). La CLI usa decimales para las dos.
16. **Rutas canónicas (revisión del plan 13).** Registro, escaneo, `activePaths` y ejecutor comparan con una sola clave, `CanonicalPath.of`: `realpath(3)` de la carpeta que contiene + el nombre (sin seguir un symlink final; `realpath` de Darwin también corrige mayúsculas). El registro guarda esa clave al anotar y `contains` compara además por `(st_dev, st_ino)`. Así un worktree de Responder en curso con un `worktreeDir` que es un symlink (o `/var` vs. `/private/var`, u otras mayúsculas) nunca se ve huérfano. Los ítems del escaneo llevan la ruta canónica, sin repetir (dos repos con el mismo `worktreeDir`).
17. **Nunca a través de un symlink.** El escaneo solo lista entradas que son carpetas de verdad (`lstat` = `S_IFDIR`). El ejecutor re-verifica: carpeta de verdad; `realpath` de la carpeta que la contiene = una raíz de PRBar (`.workspace`) o el `worktreeDir` configurado de un repo (`.respondWorktree`); el clone sale **de la configuración** (nunca del `.git` del worktree, que solo sirve para ponerle el repo en la UI si coincide con un clone configurado), y git lo tiene que listar en `git -C <clone> worktree list --porcelain` antes del `worktree remove --force`. Un `.workspace` que tiene `.git` y que ningún clone configurado lista se saltea ("a git worktree of a repo PRBar doesn’t have set up"); sin `.git` (solo diff, contexto) se borra la carpeta.
18. **Se ejecuta solo lo confirmado.** La ventana y la CLI mandan las rutas de la vista previa que se mostró (`AppCommand.cleanup(…, paths:)`; la CLI la pide en `prepare`, también con `--yes`); la app arma el plan otra vez y ejecuta la intersección (`CleanupPlan.limited(to:)`): nada que apareció después de confirmar se borra. `paths` es opcional (una CLI vieja → todo el plan nuevo, como antes), así que el protocolo sigue en 4.

---

## J. Dónde corre Claude: esta Mac o un servidor por SSH

Plan: `2026-11-19-prbar-plan-14-remote-runners.md`.

### J.1 Destinos

- **This Mac** (por defecto, comportamiento actual).
- **SSH hosts**: el usuario agrega uno o más destinos en Settings › Claude › **Run On** eligiendo un host de `~/.ssh/config` (o `user@host[:port]`), con carpeta de trabajo remota (por defecto `~/.prbar`). PRBar usa el `ssh` del sistema con `BatchMode=yes`, `ConnectTimeout=10`, multiplexado (`ControlMaster=auto`, `ControlPersist=60s`, socket en una carpeta 0700 propia) y **nunca** guarda contraseñas: requiere clave/agent ya configurados.
- **Por repo**: cada repo elige "Default" (el global), "This Mac" o un host. El destino global por defecto es This Mac.
- **Fallback a local** (switch por destino, por defecto encendido): si el host no responde o falla la preparación, el trabajo corre en la Mac y la fila/ventana lo dice ("Ran on this Mac — devbox unreachable"). Si está apagado, el trabajo falla con el error.

### J.2 Qué corre remoto

- **Review, filtro, análisis de respond, implementación de fixes y los chats de PR** (review, respond, merge). Se mueven: el worktree y el `claude -p`.
- **Queda siempre local**: GitHub API (tokens), publicar reviews, push, respuestas en hilos, merge, Slack (incluido el conector de Claude), el chat de instrucciones, el updater.

### J.3 Cómo

- **Verificación del host** ("Test Connection" y antes de cada trabajo, cacheado 5 min): `ssh host 'uname; git --version; command -v claude; claude --version'`; muestra SO, versiones y si claude está logueado (`claude -p` mínimo con `--model haiku`, solo en Test Connection). Las versiones mínimas de git y claude son las mismas que en local.
- **Repo remoto**: clone espejo propio de PRBar en `<carpeta remota>/repos/<owner>/<name>.git` (bare), actualizado con `git fetch` **desde GitHub en el host** usando las credenciales del host (PRBar no envía tokens). Si el host no puede leer el repo, el error lo dice ("devbox can't fetch acme/api — set up git access on the server"). Los worktrees remotos se crean desde ese bare con los mismos refs `refs/prbar/*` y el mismo endurecimiento de git (§8, B, D) por `ssh host -- git -c …`.
- **Contexto** (`pr.diff`, `pr.md`, `feedback.json`, etc.): PRBar los genera local (igual que hoy, con los mismos fences/neutralización) y los copia con `scp`/`ssh 'cat >'` a la carpeta de contexto remota.
- **Claude remoto**: el mismo argv de aislamiento de §8.3/B.4 (settings, deny rules, tools, dontAsk, strict MCP, --json-schema), ejecutado como `ssh host -- env -i <allowlist> claude …` con argumentos escapados (sin interpolar en shell: cada argumento con quoting POSIX estricto y test de inyección). Los `--plugin-dir` apuntan a los plugins **del host** (se resuelven allá con la misma regla de §8.0; si falta un plugin, error con el comando para instalarlo en el server). El `stream-json` vuelve por stdout del ssh y se parsea igual; Stop mata el proceso remoto (`ssh -O` / kill del grupo remoto por PID guardado).
- **Fixes**: la implementación commitea en el worktree remoto (mismo guardián de integridad, corrido allá). Para pushear, PRBar trae los commits a la Mac con `ssh host -- git -C <wt> bundle create - <base>..HEAD` → `git bundle unbundle` en el clone local del usuario bajo `refs/prbar/…`, **verifica** que el árbol traído coincide con el diff que vio el usuario, y pushea **desde la Mac** con el token local, como hoy. Si el repo no tiene `localPath`, el push usa un clone temporal mínimo propio.
- **Limpieza**: los worktrees/refs/carpetas de contexto remotos se borran al terminar como en local; al arrancar, limpieza de huérfanos remotos solo dentro de `<carpeta remota>` de PRBar.

### J.4 UI y CLI

- Settings › Claude › Run On: lista de destinos (host, carpeta, fallback, estado de la última verificación, Test Connection, Remove), destino global por defecto; Settings › Repos: "Run Claude on". Filas y ventanas muestran "on devbox" cuando corre remoto. La ventana de Activity (parte I) lista los trabajos remotos.
- CLI: `prbar runners list|add <host> [--dir D] [--no-fallback]|remove|test|default <name|local>`, `prbar repo set <repo> --run-on <name|local|default>`; inventario de UI y paridad actualizados.

### J.5 Seguridad

- Ningún token de GitHub ni Slack sale de la Mac. El host necesita su propio acceso de lectura al repo y su login de Claude.
- Quoting estricto de todos los argumentos remotos (test con nombres de rama/paths/prompts hostiles). La carpeta remota es la única que PRBar crea o borra en el host.
- Lo que vuelve del host (stream-json, bundles, diffs) se trata como no confiable igual que la salida local de Claude (redacción, guardianes, verificación del árbol antes de pushear).
- `known_hosts` se respeta (`StrictHostKeyChecking=yes` salvo que el usuario haya configurado otra cosa en su ssh config).

### J.6 Testing

- Constructor de comandos ssh con quoting (fuzz de argumentos hostiles), resolución de destino (repo → global → local), fallback, parseo de la verificación del host.
- Flujo remoto completo contra un "host" falso (un `ssh` stub que ejecuta localmente en una carpeta temporal), incluido el bundle de vuelta y la verificación del árbol antes del push.
- Stop y limpieza remota; error claro cuando el host no puede fetchear o falta claude/plugin.
