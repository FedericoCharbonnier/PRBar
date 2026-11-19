# PRBar — Diseño

**Fecha:** 2026-11-18
**Estado:** borrador para revisión
**Diseño visual:** `docs/design/` (Claude Design), ver §13

## 1. Qué es

PRBar es una app nativa de macOS (SwiftUI) que vive solo en la barra de menú, sin ícono en el Dock. Sirve para:

1. Mostrar en el ícono un **badge** con la cantidad de PRs que requieren tu acción.
2. Listar los PRs relevantes, cada uno con un botón **Review** que lanza a Claude Code en modo headless para revisarlo (por defecto con `pr-review-toolkit:review-pr`) y después filtrar los hallazgos (por defecto con `superpowers:receiving-code-review`). Los skills se eligen en Configuración → Claude (§8).
3. Elegir qué comentarios publicar, editarlos y **aprobar, pedir cambios o comentar** desde la app.
4. Mandar **notificaciones push** de macOS, configurables.
5. Guardar un **historial** de todas las reviews.
6. En **tus** PRs con feedback, un botón **Responder**: Claude analiza los comentarios recibidos, vos elegís qué arreglar y qué responder, Claude implementa los fixes en un worktree y la app pushea y responde en cada hilo (§14).
7. Un **bot de Slack** opcional que anuncia tus PRs nuevos y sus actualizaciones en el canal configurado para cada repo (§15).

**Orden de implementación:** Plan 1 (barra de menú, §2–§7, §9, §11–§13) → Plan 4 (Slack, §15) → Plan 2 (review con Claude, §8, §10) → Plan 3 (responder feedback, §14).

Fuera de alcance (v1): ver el diff completo dentro de la app, comentar líneas a mano sin pasar por Claude, soporte de GitHub Enterprise Server y mergear PRs desde la app.

## 2. Plataforma y build

- **macOS 14+**, Swift 5.10, SwiftUI `MenuBarExtra` con estilo `.window`.
- **La interfaz está en inglés** (convenciones de Apple: "Settings…" ⌘,, menús en title case, etiquetas en sentence case), con `CFBundleDevelopmentRegion = en`. Las fechas usan el formato de la región del usuario (`Locale.current`) con palabras en inglés. Lo que PRBar publica en GitHub va en el idioma del PR (§16).
- **Sin Xcode completo:** el proyecto es un Swift Package con tres targets:
  - `PRBarCore` (library): toda la lógica, sin UI. Es testeable.
  - `PRBar` (executable): la app SwiftUI, que depende de `PRBarCore`.
  - `PRBarTests` (executable): un runner de tests propio, porque las Command Line Tools no traen XCTest. Se corre con `swift run PRBarTests` y sale con código ≠ 0 si algún test falla.
- `Scripts/bundle.sh`: compila en release, arma `PRBar.app` (Info.plist con `LSUIElement = YES` y bundle id `com.federico.prbar`), firma ad-hoc (`codesign -s -`) y lo copia a `~/Applications`. El bundle firmado hace falta para que funcionen las notificaciones y el inicio de sesión.
- **Abrir al iniciar sesión:** `SMAppService.mainApp`.

## 3. Dependencias externas (en runtime)

| Herramienta | Uso |
|---|---|
| `gh` | Listar cuentas (`gh auth status`) y obtener tokens (`gh auth token --user <login>`). La app **nunca guarda tokens**: los pide en cada ciclo de refresco y los mantiene solo en memoria. |
| API de GitHub | GraphQL (`https://api.github.com/graphql`) para leer; REST para publicar reviews. |
| `git` | Fetch y worktrees sobre los clones locales. |
| `claude` | Claude Code CLI (`claude -p`), con instalados los plugins de los skills elegidos (por defecto `pr-review-toolkit` y `superpowers`). |

Las rutas a `gh`, `git` y `claude` se detectan al arrancar con un login shell (`zsh -lc 'command -v X'`), porque las apps de GUI no heredan el `PATH` del usuario (por ejemplo, el de `nvm`). Se pueden sobrescribir en Configuración.

## 4. Arquitectura

```
PRBar (SwiftUI)
 ├─ MenuBarExtra: ícono + badge → PopoverView
 ├─ ReviewWindow (una por PR)
 ├─ HistoryWindow
 └─ SettingsWindow
        │
PRBarCore
 ├─ ConfigStore        config.json (lectura y escritura, publica los cambios)
 ├─ AccountProvider    cuentas y tokens vía `gh`
 ├─ GitHubClient       protocolo + impl. GraphQL/REST
 ├─ ActionClassifier   función pura: PR → categoría
 ├─ PRStore            poll → fetch → clasificar → publicar estado y badge
 ├─ Notifier           diff entre snapshots → notificaciones
 ├─ ReviewRunner       cola (máx. 2) + worktree + 2 etapas de claude
 ├─ ClaudeOutputParser parseo de stream-json y extracción del JSON final
 ├─ ReviewPublisher    arma y envía la review a GitHub
 ├─ ReviewHistory      persistencia de reviews y logs
 └─ ProcessRunner      protocolo para correr procesos (fakeable en tests)
```

Cada unidad depende de protocolos (`GitHubClient`, `ProcessRunner`, `Clock`), no de implementaciones concretas, para poder testearla con fakes.

## 5. Configuración

Archivo: `~/Library/Application Support/PRBar/config.json`

```json
{
  "accounts": [
    {
      "login": "dev-sam",
      "enabled": true,
      "repos": [
        {
          "owner": "acme",
          "name": "web-app",
          "localPath": "/Users/me/Code/web-app",
          "baseBranches": ["develop"],
          "watchedUsers": ["juan", "maria"]
        }
      ]
    }
  ],
  "refreshIntervalMinutes": 2,
  "launchAtLogin": true,
  "notifications": {
    "enabled": true,
    "newToReview": true,
    "reviewedPRUpdated": true,
    "myPRFeedback": true,
    "reviewFinished": true,
    "myPRApprovedOrCIFailed": true
  },
  "toolPaths": { "gh": null, "git": null, "claude": null },
  "claude": {
    "reviewSkill": "pr-review-toolkit:review-pr",
    "filterEnabled": true,
    "filterSkill": "superpowers:receiving-code-review",
    "respondSkill": "superpowers:receiving-code-review",
    "model": null
  }
}
```

- `localPath` es opcional. Si falta, la review corre solo con el diff (ver §8.2).
- Si `baseBranches` está vacío, se usa la rama por defecto del repo.
- `watchedUsers` es **por repo**: seguir a un usuario en un repo no hace que sus PRs de otros repos aparezcan. En Configuración se eligen en el detalle de cada repo (sección "Usuarios a seguir"), con sugerencias de los `assignableUsers` del repo y de los autores de sus PRs abiertos.
- Migración: un `config.json` viejo con `watchedUsers` a nivel cuenta copia esa lista a cada repo de la cuenta que no tenga lista propia, la quita de la cuenta y se guarda migrado al cargar.
- `claude` (`ClaudeSettings`, ver §8.0) se decodifica con tolerancia: una clave que falta, un tipo equivocado o un modelo desconocido vuelven al valor por defecto. Un skill vacío o inválido usa el de por defecto. Los valores por defecto reproducen el comportamiento de antes.
- Al elegir `localPath`, se valida que sea un repo git y que algún `remote` apunte a `github.com/<owner>/<name>`.

## 6. Datos que se traen de GitHub

Por cada cuenta habilitada y por cada repo configurado, una consulta GraphQL trae los PRs abiertos con:

- `number`, `title`, `url`, `isDraft`, `author.login`, `baseRefName`, `headRefName`, `headRefOid`, `additions`, `deletions`, `updatedAt`, `reviewDecision`;
- el último commit: `committedDate` y el estado del CI (`statusCheckRollup.state`);
- `reviews(last: 50)`: autor, estado, `submittedAt` y `commit.oid`;
- `reviewRequests`: los usuarios pedidos como reviewers;
- comentarios del PR (`comments(last: 50)`, autor y `createdAt`). Solo se traen los comentarios generales del PR (issue comments); los comentarios inline de una review no se piden aparte: llegan como una review en estado `COMMENTED` dentro de `reviews`.

El selector de repos de Configuración usa `viewer.repositories` con `affiliations` y `ownerAffiliations` en `[OWNER, COLLABORATOR, ORGANIZATION_MEMBER]`, para incluir repos a los que se accede por una org o un equipo.

**"Último push"** se aproxima con el `committedDate` del último commit. *Limitación conocida:* un rebase sin cambios de fecha puede no detectarse como push nuevo. Se acepta para la v1.

## 7. Reglas de clasificación (`ActionClassifier`)

`yo` = el login de la cuenta. Solo se consideran PRs abiertos de repos configurados cuya rama base esté en `baseBranches`.

**PRs de otros** (el autor ≠ `yo`), relevantes si el autor está en los `watchedUsers` **de ese repo** **o** si `yo` está en `reviewRequests`:

| Condición | Categoría | Suma al badge |
|---|---|---|
| `isDraft` | Otros | No |
| No tengo ninguna review enviada | **Para revisar** | Sí |
| Mi última review es `CHANGES_REQUESTED` o `COMMENTED` y el último commit es posterior a esa review | **Actualizado desde mi review** | Sí |
| Cualquier otro caso (por ejemplo, ya aprobé y no hay cambios) | Otros | No |

> Decisión explícita: si me piden review de forma formal, el PR aparece aunque el autor no esté en los `watchedUsers` del repo, para no ignorar pedidos directos.

**PRs míos** (el autor = `yo`):

| Condición | Categoría | Suma al badge |
|---|---|---|
| Existe una review `CHANGES_REQUESTED` o `COMMENTED`, o un comentario de otra persona, posterior a mi último commit | **Mis PRs con feedback** | Sí |
| Cualquier otro caso | Otros | No |

**Badge** = cantidad de PRs en *Para revisar* + *Actualizado desde mi review* + *Mis PRs con feedback*, sumando todas las cuentas. Si un mismo PR aparece en dos cuentas, cuenta una sola vez (se deduplica por `owner/repo#number`; si el autor es una de mis cuentas gana el item de esa cuenta, si no la categoría más urgente).

## 8. Flujo de review con Claude

### 8.0 Skills configurables (Configuración → Claude)

Los skills de Claude Code que usan la review y "Responder" se eligen en la pestaña **Claude** de Configuración (después de General) y se guardan en `config.claude` (§5):

| Campo | Por defecto | Uso |
|---|---|---|
| `reviewSkill` | `pr-review-toolkit:review-pr` | Etapa 1 de la review (§8.3). |
| `filterEnabled` | `true` | Si está apagado, no corre la etapa 2: se quedan todos los hallazgos (`keep`, motivo "Filter disabled") y hay una sola corrida de Claude. |
| `filterSkill` | `superpowers:receiving-code-review` | Etapa 2, el filtrado (§8.4). |
| `respondSkill` | `superpowers:receiving-code-review` | Análisis de "Responder" (§14.4). |
| `model` | `null` (el del CLI) | `--model opus\|sonnet\|haiku` en todas las corridas de review y de "Responder" (análisis y fixes). |

- Un skill es `plugin:skill` o un nombre suelto (un skill integrado o del usuario). Cada parte solo lleva `[A-Za-z0-9._-]`, no está vacía y no empieza con `.`: el plugin es un nombre de carpeta y el skill va entre backticks en el prompt.
- **Plugins:** cada corrida pasa `--plugin-dir` solo para los plugins de los skills que usa (el prefijo `plugin:`, sin repetir): la review, los de `reviewSkill` y, si el filtro está prendido, `filterSkill`; "Responder", el de `respondSkill`. Si el plugin de un skill elegido no está instalado, la corrida falla antes de preparar nada con un error que nombra el skill y dice cómo instalar el plugin (`/plugin install <plugin>`) o elegir otro skill. Los argumentos de aislamiento de §8.3 no cambian.
- **Catálogo** (`ClaudeSkillCatalog`): el selector lista los skills (`skills/*/SKILL.md`, con el nombre del `name:` del frontmatter o de la carpeta) y los comandos (`commands/*.md`) de la instalación más reciente de cada plugin en `~/.claude/plugins/cache/*/*/`, como `plugin:skill` con la `description` del frontmatter. Es un menú con búsqueda, más "Custom…" para escribir cualquier nombre.
- **Skills del usuario** (`~/.claude/skills/*/SKILL.md`): solo se pueden elegir si cargan en las corridas aisladas. Para saberlo, `ClaudeSkillProbe` corre una vez por sesión (solo si hay skills del usuario) un `claude -p "Reply ok" --model haiku` de solo lectura con el mismo aislamiento (`--setting-sources ""`, `--settings`, `--plugin-dir` de los skills elegidos, `dontAsk`, sin MCP, `--tools ""`) y lee `skills` y `slash_commands` del evento `init`. Los que no aparecen se muestran deshabilitados con "Not available in isolated runs". Verificado con claude 2.1.318: con `--setting-sources ""` los skills de `~/.claude/skills` **no** cargan (sí los de los `--plugin-dir` y los integrados del CLI).
- La pestaña tiene "Reset to Defaults" y aclara que las reviews corren aisladas: solo se cargan los plugins de los skills elegidos, sin shell, sin MCP y de solo lectura.

### 8.1 Estados del botón

`idle` → `queued` → `preparing` → `reviewing` → `filtering` → `ready(n)` | `failed(msg)` | `cancelled`

- Hay como máximo **2 reviews en paralelo**; el resto queda en cola FIFO.
- Mientras una review está en curso se puede **cancelar**: se mata el proceso con todo su grupo (SIGTERM y, a los 5 s, SIGKILL al grupo de procesos, así no quedan vivos los subagentes de Claude ni un `git`/`gh` hijo) y se limpia el worktree. Al salir de la app se cancelan todos los reviews en curso o en cola (los worktrees que queden los borra la limpieza de huérfanos del próximo arranque).
- Si la ventana de Review de un PR tiene cambios sin publicar (selección, textos editados o comentario general) y se abre un draft nuevo del mismo PR, se pregunta "Hay cambios sin publicar en la review anterior. ¿Reemplazar?" (Reemplazar / Mantener la anterior) en vez de reemplazarla en silencio.
- Si el PR recibe commits nuevos mientras hay un resultado `ready`, la ventana de Review muestra el aviso "El PR cambió: los comentarios se publican en el cuerpo de la review" y ofrece volver a correrla. Si se publica igual, todos los hallazgos van al `body` (las líneas del diff de ahora no son las que vio Claude).

### 8.2 Preparación

Con `localPath`:
```
git <GitHardening> -C <localPath> fetch --no-write-fetch-head origin +pull/<N>/head:refs/prbar/pr-<N>-<id> +refs/heads/<base>:refs/prbar/base-<N>-<id>
git <GitHardening> -C <localPath> worktree add --detach $TMPDIR/PRBar/worktrees/<repo>-<N>-<ts>-<id> refs/prbar/pr-<N>-<id>
```
Se usan refs propias (`refs/prbar/*`), así que **nunca se tocan las ramas ni el working copy del usuario**.

`<id>` es un id de corrida: 8 caracteres hexadecimales de un UUID nuevo en cada review. Va en las dos refs, en el nombre del worktree y, por lo tanto, en el de su carpeta de contexto (`<repo>-<N>-<ts>-<id>.context`) y en el de la carpeta del modo solo diff (`<repo>-<N>-<ts>-<id>-diff`). Así, si se cancela una review y se vuelve a pedir enseguida, la limpieza de la corrida vieja (que borra sus refs y su carpeta) nunca toca las de la nueva.

Entre el fetch y el `worktree add`, PRBar corre `git rev-parse --verify refs/prbar/pr-<N>-<id>^{commit}`: ese SHA es **el commit que se revisa**, el que va en `pr.md` y el `headOid` del draft (el `commit_id` con el que se publica). El `headRefOid` del snapshot puede ser más viejo si el PR recibió commits después del último refresco.

La raíz de los worktrees es `$TMPDIR/PRBar/worktrees` (la carpeta temporal del usuario), no `~/Library/Caches`: Claude tiene `~/Library/**` negado (§8.3) y no podría leer el código. La raíz vieja (`~/Library/Caches/PRBar/worktrees`) se sigue vaciando al arrancar.

Todos los `git` que PRBar corre para una review (estos, el `git diff` del contexto y los de la limpieza) llevan `GitHardening`: `-c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false -c core.untrackedCache=false` y el entorno `GIT_LFS_SKIP_SMUDGE=1` y `GIT_TERMINAL_PROMPT=0`; `status` y `diff` además llevan `--ignore-submodules=all`. Así no corre ningún hook (ni un `post-checkout` del repo del usuario ni uno que un gestor de hooks, p. ej. lefthook, arme con la configuración que trae el PR) ni ningún comando de configuración (`core.fsmonitor`, también el de un repo anidado). El fetch usa `--no-write-fetch-head` para no tocar `FETCH_HEAD`.

Después del `worktree add`, PRBar neutraliza los symlinks del PR: un PR puede commitear un symlink que apunte fuera del repo (p. ej. a `~/.ssh/id_rsa`) y el `Read` de Claude lo seguiría. Corre `git -C <worktree> ls-files -s -z` (con `GitHardening`) y cada entrada con modo `120000` se reemplaza en el worktree por un archivo de texto común con `[symlink a <destino> omitido por PRBar]`. Nunca se sigue el link (`lstat`, `readlink`, `unlink` y `open` con `O_EXCL | O_NOFOLLOW`). Si no se puede neutralizar alguno, la review falla. El diff (`base...HEAD`) no cambia: compara commits, no el working tree.

Si la preparación falla o se cancela a mitad de camino (fetch, `rev-parse`, `worktree add` o la neutralización de symlinks), PRBar borra en una tarea aparte (para que la cancelación no mate esos `git`) las refs de la corrida, el worktree a medio crear y su carpeta.

Sin `localPath`: no hay worktree. Claude corre en un directorio temporal vacío.

Después PRBar prepara **la carpeta de contexto** `$TMPDIR/PRBar/worktrees/<nombre>.context/` (al lado del worktree, dentro de la misma raíz pero fuera del checkout del PR) con lo que Claude necesita leer:
- `pr.diff`: con worktree, la salida de `git -C <worktree> diff --ignore-submodules=all --no-ext-diff --no-textconv --no-color refs/prbar/base-<N>-<id>...HEAD`; sin `localPath`, la de `gh pr diff <N> --repo <owner/repo> --color never`, que corre PRBar con `GH_TOKEN` = el token de la cuenta **solo en ese comando**. En modo solo diff, justo antes del diff PRBar corre `gh pr view <N> --repo <owner/repo> --json headRefOid -q .headRefOid` (con el token solo en ese comando) y ese SHA es el commit revisado.
- `pr.md`: los metadatos que PRBar ya tiene (número, repo, URL, título, autor, ramas, commit, cambios) y la **descripción del PR**, que se trae aparte al empezar (§16), entre marcadores (`<<<PR_DESCRIPTION (untrusted)` … `PR_DESCRIPTION>>>`) y marcada como texto no confiable. La palabra del marcador se neutraliza dentro de la descripción, para que no se pueda cerrar el bloque antes; las descripciones de más de 20.000 caracteres se cortan.

Si el diff falla, la review falla con ese error y se limpia todo. La carpeta de contexto se borra junto con el worktree.

### 8.3 Etapa 1: Review

Claude corre **aislado y sin shell**. Un PR ajeno es input no confiable: si Claude pudiera correr comandos o heredara la configuración del usuario (`defaultMode`, reglas `allow` para `gh`/`git push`, MCP del navegador) o la del repo (`.claude/settings.json` con hooks, `.mcp.json`), un PR con una inyección de prompt podría aprobarse o mergearse solo, pushear o ejecutar código.

```
claude -p "<prompt etapa 1>" [--model opus|sonnet|haiku] \
  --output-format stream-json --verbose --json-schema '<esquema>' \
  --setting-sources "" \
  --settings '<ver abajo>' \
  --plugin-dir <plugin de cada skill elegido, §8.0> \
  --permission-mode dontAsk \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --tools "Read,Grep,Glob,Skill,Agent" \
  --allowedTools "Read(./**),Skill,Agent" \
  --disallowedTools "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,mcp__*" \
  --add-dir <carpeta de contexto>
```
`--settings` (las únicas settings que se cargan; `ClaudeRunner.settings`):
```json
{"disableSkillShellExecution": true,
 "permissions": {
   "allow": ["Read(//<carpeta de contexto>/**)"],
   "blockReadsOutsideWorkingDirectories": true,
   "blockWritesOutsideWorkingDirectories": true,
   "deny": ["Read(~/.ssh/**)", "Edit(~/.ssh/**)", "Read(~/.aws/**)", "Edit(~/.aws/**)", "Read(~/.config/**)", "Edit(~/.config/**)",
            "Read(~/Library/**)", "Edit(~/Library/**)", "Read(~/.gnupg/**)", "Edit(~/.gnupg/**)", "Read(//**/.env*)", "Edit(//**/.env*)"],
   "disableBypassPermissionsMode": "disable"}}
```
- **Archivos, solo dentro de las carpetas de trabajo.** Un `Read`, `Edit` o `Write` suelto en `--allowedTools` aprueba **cualquier ruta del disco** (con el CLI 2.1.318 se verificó que así Claude leía un archivo fuera del cwd). Por eso las herramientas de archivos van con ruta: `Read(./**)` (que también rige a Grep y Glob, que nunca van sueltos) y, en Responder, `Edit(./**)` (que también rige a Write). Las carpetas extra (`--add-dir`) se pueden leer pero no editar. Además `blockReads/WritesOutsideWorkingDirectories` hace que las herramientas de archivos rechacen cualquier ruta fuera del cwd y de las carpetas extra, en cualquier modo, y las reglas `deny` niegan las carpetas de secretos aunque estuvieran adentro. `disableSkillShellExecution` impide que un skill corra shell en línea. Si el cwd o una carpeta extra cae dentro de una ruta negada, `ClaudeRunner` falla antes de lanzar nada con un mensaje que lo explica.
- **Verificación empírica** (claude 2.1.318, `--model haiku`, carpetas temporales y archivos canario): con estos argumentos exactos, `Read`, `Grep` y `Glob` de un canario en una carpeta hermana se rechazan ("is outside … working directories"), un `Write` fuera del cwd se rechaza y el archivo no se crea, un `Write` en la carpeta de contexto se rechaza, un `Write` a `.env.local` dentro del cwd se rechaza por la regla `deny`, y dentro del cwd `Read`, `Grep`, `Edit` y `Write` funcionan. Un subagente (`Agent`) hereda las mismas restricciones y los skills de los plugins siguen funcionando. Con los argumentos anteriores (herramientas sueltas, sin `--settings`) el canario se leía.
- `--setting-sources ""`: no carga `~/.claude/settings.json` ni el `.claude/` del worktree (hooks, permisos, MCP del PR). `--bare` no sirve porque desactiva el login OAuth. `--settings` sí se aplica con `--setting-sources ""` (verificado).
- **MCP:** `--strict-mcp-config` con una config vacía no carga servidores, pero los conectores de claude.ai (`mcp__claude_ai_*`) los trae Claude Code solo: por eso `mcp__*` va siempre en `--disallowedTools`.
- **Subagentes:** en esta versión del CLI la herramienta se llama `Agent` (el evento `init` la lista como `Task`, pero el `tool_use` dice `Agent`; los dos nombres funcionan en `--tools`). El parser cuenta los dos.
- Los plugins se pasan con `--plugin-dir`: solo los de los skills elegidos (§8.0). `ClaudePlugins` toma, para cada uno, el subdirectorio modificado más recientemente de `~/.claude/plugins/cache/<marketplace>/<plugin>/` (en cualquier marketplace) que tenga `.claude-plugin`, `skills`, `commands` o `agents`. Si falta alguno, la review falla con un mensaje que nombra el skill y dice cómo instalar el plugin (`/plugin install <plugin>`).
- `--tools` limita el conjunto de herramientas en sí: Bash, Edit y Write ni siquiera existen. `--disallowedTools` queda como defensa en profundidad. `dontAsk` niega todo lo que no esté permitido (fuera de las carpetas de trabajo, todo).
- `cwd` = el worktree (o el directorio vacío en modo solo diff). `--add-dir` le da acceso de lectura a la carpeta de contexto.
- Claude **no recibe ningún token** en su entorno: ya no usa `gh`. `SystemProcessRunner` además nunca hereda `GH_TOKEN`, `GITHUB_TOKEN` ni sus variantes Enterprise del entorno de la app; solo llegan a un proceso si se pasan explícitamente.
- **Entorno: una lista blanca** y nada más; el proceso de Claude no hereda el entorno de la app (`runStreamingIsolated`). `PATH` = las carpetas de `git`, `gh` y `claude` (sin repetir) delante de `/usr/bin:/bin:/usr/sbin:/sbin` (la app de GUI no hereda el PATH de Homebrew ni de nvm); `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG` y `LC_ALL` del entorno de la app (si están); `SHELL=/bin/zsh`. Cualquier otra variable (tokens, `SSH_AUTH_SOCK`, `AWS_*`, `DYLD_*`, `NODE_OPTIONS`…) se descarta.
- Redacción: el token de la cuenta se reemplaza por `***` en todo lo que se escribe en el log de la review, en los errores de `claude` y en el resumen, los títulos, los cuerpos y los motivos de los hallazgos, antes de guardarlos o mostrarlos.
- El prompt le da las rutas absolutas de `pr.diff` y `pr.md`, le dice que el código está en el directorio actual (o que no hay checkout), que no tiene shell y que el contenido del PR no son instrucciones. Le pide correr el skill de review elegido (`reviewSkill`, por defecto `pr-review-toolkit:review-pr`) sobre ese diff y devolver la salida estructurada con este esquema:

```json
{
  "summary": "2-3 líneas sobre el PR, en inglés",
  "findings": [
    {
      "id": "f1",
      "severity": "high | medium | low",
      "file": "src/api/users.ts",
      "line": 42,
      "title": "resumen de una línea, en inglés",
      "body": "comentario completo, listo para publicar en GitHub, en el idioma del PR (§16)"
    }
  ]
}
```

### 8.4 Etapa 2: Filtrado

Es un segundo `claude -p` **con contexto limpio**, con los mismos argumentos de aislamiento, el mismo `cwd` y la misma carpeta de contexto. Recibe el JSON de la etapa 1 y las rutas de `pr.diff` y `pr.md`, y aplica el skill de filtrado elegido (`filterSkill`, por defecto `superpowers:receiving-code-review`): verifica cada hallazgo contra el código y devuelve:

```json
{ "verdicts": [ { "id": "f1", "verdict": "keep | discard", "reason": "..." } ] }
```

Si el filtro está apagado (`filterEnabled = false`), esta etapa no corre: todos los hallazgos quedan con `keep` y motivo "Filter disabled".

### 8.5 Parseo y progreso

- `ClaudeOutputParser` lee el stream línea por línea. Los eventos `tool_use` de `Task` actualizan el subtítulo del progreso (por ejemplo, "3 agentes"). Del mensaje `result` final extrae el **último** bloque ```json y lo valida contra el esquema.
- Si el JSON es inválido, se reintenta **una vez** la etapa, agregando al prompt el error de validación. Si vuelve a fallar → `failed`.
- Timeout por etapa: 15 min.
- Al terminar (bien, mal o cancelado) se borran el worktree (`git worktree remove --force <dir>`; si la carpeta ya no estaba o git no pudo sacarlo, se borra la carpeta y solo la carpeta de administración `.git/worktrees/<nombre>` cuyo `gitdir` apunta a ese worktree dentro de la raíz de PRBar) y las dos refs de esa corrida (`refs/prbar/pr-<N>-<id>` y `refs/prbar/base-<N>-<id>`). PRBar **nunca corre `git worktree prune`**: podaría todos los worktrees "perdidos" del repo del usuario, incluidos los suyos en un disco desmontado.

### 8.6 Ventana de Review

- Muestra el `summary`, las tarjetas de los hallazgos `keep` (tildadas) y una sección colapsada "Descartados por el filtro" (sin tildar, con su `reason`).
- Cada tarjeta muestra severidad, `file:line` y `title`. Al expandirla aparece `body` en un editor de texto.
- También hay un campo opcional de comentario general y los botones **Comentar**, **Pedir cambios** y **Aprobar**.

### 8.7 Publicación (`ReviewPublisher`)

`POST /repos/{owner}/{repo}/pulls/{n}/reviews` con:
- `commit_id` = el `headRefOid` con el que se hizo la review;
- `event` = `COMMENT`, `REQUEST_CHANGES` o `APPROVE`;
- `body` = el comentario general + los hallazgos que no se pueden anclar a una línea;
- `comments` = `[{ path, line, side: "RIGHT", body }]`, solo para las líneas que están en el diff.

Antes de enviar se parsea el diff (`GET .../pulls/{n}/files`, campo `patch`) para saber qué líneas son comentables: dentro de cada hunk, las agregadas (`+`) y las de contexto (que empiezan con un espacio); se ignora lo anterior al primer `@@` y no cuentan las `-`, las `\ No newline at end of file` ni las vacías. Un archivo renombrado se busca por su nombre nuevo; uno borrado no tiene líneas comentables. Las rutas de los hallazgos se normalizan (sin `./` adelante y sin el prefijo absoluto del worktree, si Claude lo devolvió). Los hallazgos con líneas fuera del diff se mueven al `body` como `**archivo:línea** — texto`.

Si el PR cambió desde la review (el `headRefOid` del último snapshot no es el `headOid` del draft), no se pide el diff: todos los hallazgos van al `body`.

Si GitHub responde con un error, se muestra el mensaje en la ventana y **no se pierde la selección ni lo editado**. Si el error es un 422 y la review tenía comentarios inline (casi siempre, una línea que ya no está en el diff), la ventana ofrece **"Publicar todo en el cuerpo"**: un reintento de un click con todos los hallazgos en el `body`.

Cualquier respuesta 2xx cuenta como publicada. Si no trae `html_url` (o no se puede leer), se usa la URL del PR: tratarla como error invitaría a publicar de nuevo y duplicar la review.

## 9. Notificaciones (`Notifier`)

- Después de cada refresco se compara el snapshot nuevo con el anterior. El snapshot anterior se persiste en `state.json`, así que reiniciar la app no repite avisos.
- **En la primera ejecución no se notifica nada**: solo se guarda el estado como línea base. Lo mismo si el refresco anterior falló por completo.
- Cada snapshot guarda `fetchedScopes`: los pares `"login|owner/repo"` que se consultaron bien. Un PR solo puede notificar si su scope (cuenta del item + repo) estaba en los `fetchedScopes` del snapshot anterior. Así, un repo o una cuenta recién agregados, o un repo que se recupera de un error, no disparan una ráfaga de avisos: su primer refresco bueno es la línea base. Un `state.json` viejo sin `fetchedScopes` se lee vacío (el primer refresco después de actualizar no notifica).

| Toggle | Dispara cuando |
|---|---|
| `newToReview` | un PR entra a *Para revisar* |
| `reviewedPRUpdated` | un PR entra a *Actualizado desde mi review* |
| `myPRFeedback` | un PR mío entra a *Mis PRs con feedback* |
| `reviewFinished` | una review de Claude llega a `ready` o `failed` |
| `myPRApprovedOrCIFailed` | en un PR mío, `reviewDecision` pasa a `APPROVED`, o el estado del CI pasa a `FAILURE`/`ERROR` |

- Un PR que aparece en varias de mis cuentas queda con una sola cuenta (§7). Si lo escribió una de ellas, se conserva la perspectiva de esa cuenta ("mi PR"), nunca un *Para revisar* desde otra cuenta mía; así los avisos de "tu PR" (aprobado, CI) usan la cuenta autora.
- `enabled = false` silencia todo.
- Al hacer click en una notificación se abre la ventana de Review (para `reviewFinished` de un review listo), el Historial con ese registro elegido (para "Falló el review") o el PR en el navegador (para el resto).
- Si se refresca y entran más de 5 eventos a la vez, se agrupan en un solo aviso ("7 PRs nuevos para revisar").

## 10. Historial (`ReviewHistory`)

- `~/Library/Application Support/PRBar/history/<uuid>.json`: PR (owner, repo, número, título, `headRefOid`), cuenta, fechas de inicio y fin, estado final, `summary`, todos los hallazgos con su veredicto, cuáles se publicaron (con el texto final editado), la acción (`APPROVE`/`REQUEST_CHANGES`/`COMMENT`/`none`) y la URL de la review publicada.
- `.../history/logs/<uuid>.jsonl`: el stream completo de Claude de las dos etapas.
- La ventana de Historial tiene una lista con búsqueda y filtro por repo, y un detalle de solo lectura con links al PR y al log.
- Si el usuario cierra la ventana sin publicar, la review queda en el historial con acción `none` y se puede reabrir para publicar después, mientras el PR no haya cambiado, no haya un review en curso del PR y no se haya publicado después otra review del mismo PR y el mismo commit (evita duplicarla).
- Si se pide un review nuevo de un PR que tenía uno `ready` sin publicar, el registro viejo pasa a `abandoned` y ya no se puede reabrir.
- Un review cancelado no deja registro.

## 11. Errores

Ningún error falla en silencio: todos se muestran en la UI y se registran en `~/Library/Logs/PRBar/prbar.log`.

| Caso | Comportamiento |
|---|---|
| Sin red o API caída | Ícono `⚠︎`, el popover muestra "Último refresco hace X · error" y un botón para reintentar. Se mantiene la última lista conocida. |
| Token inválido o cuenta deslogueada | Aviso por cuenta en el popover, con el comando `gh auth login --hostname github.com` para copiar. |
| Rate limit | Se detecta por 403/429 sin cupo (`X-RateLimit-Reset`), por 403/429 con `Retry-After` (límite secundario) y por GraphQL 200 con `errors[].type == "RATE_LIMITED"` (sin header de reset: 60 s). Al primer rate limit el refresco deja de consultar los repos restantes y conserva lo anterior. Se avisa "Reintento a las HH:MM" y no se puede refrescar hasta esa hora. |
| `gh`, `git` o `claude` no encontrados | Aviso en el popover y en Configuración, con un campo para la ruta. |
| `localPath` inválido o con el remote incorrecto | Error en Configuración. La review cae al modo solo diff y lo indica. |
| Worktrees huérfanos | Al arrancar, en cada `localPath` se lee `git worktree list --porcelain` y se sacan **solo** los worktrees que están dentro de `~/Library/Caches/PRBar/worktrees/` con nombre de PRBar (`git worktree remove --force`; si la carpeta ya no existe, se borra su `.git/worktrees/<nombre>`), y se borran las refs `refs/prbar/*`. Después se borra lo que quede en `~/Library/Caches/PRBar/worktrees/*`. Nunca se corre `git worktree prune`. Si git no estaba al arrancar y el usuario configura su ruta después, la limpieza corre apenas se resuelve. |
| Una review falla | El botón pasa a `⚠️`. Al hacer click se ve un menú con el error (primer ítem, deshabilitado), "Ver log", "Reintentar" y "Descartar". La notificación "Falló el review" abre el Historial con ese registro elegido. |

## 12. Testing

Con el runner propio `PRBarTests` (`swift run PRBarTests`):

- **`ActionClassifier`**: cada fila de las tablas de §7, incluidos drafts, review pedida a un autor que no sigo, aprobado sin cambios, commit anterior y posterior a la review, feedback mío vs. de otros, y deduplicación entre cuentas.
- **`Notifier`**: la primera ejecución no notifica, solo avisa de transiciones nuevas, respeta los toggles y agrupa más de 5 eventos.
- **`ClaudeOutputParser`**: streams reales grabados como fixtures, JSON inválido, varios bloques json (gana el último) y ningún bloque.
- **`ReviewPublisher`**: el mapeo de líneas del diff decide inline vs. body, y el payload queda bien armado.
- **`ReviewRunner`**: con un `ProcessRunner` falso, la máquina de estados, la cola de 2, la cancelación, el reintento por JSON inválido y la limpieza del worktree en todos los caminos.
- **`ConfigStore`**: carga, guardado, defaults y migración de un config vacío.

La UI se prueba manualmente con una checklist en el plan de implementación.

## 13. Diseño visual

**Fuente de verdad:** `docs/design/`, exportado de Claude Design. `PRBar.dc.html` es el índice con los 15 artboards, en claro y oscuro. Cada pantalla es un componente (`Popover`, `ReviewWindow`, `HistoryWindow`, `SettingsWindow`, `MenuBar`, `IconStates`, `ReviewButtons` y `Notifications`), y `StyleGuide.dc.html` tiene los tokens para SwiftUI. Las fuentes PP Neue Montreal del zip solo se usan en la presentación del canvas, no en la app; no se versionan.

**Tokens principales:**
- **Tipografía:** la del sistema (SF Pro y SF Mono) en todos lados.
  - Título de ventana: 17 Semibold.
  - Filas: 13 Medium.
  - Metadatos: 11 Regular.
  - `archivo:línea`: 11 SF Mono.
  - Badge: 10.5 Bold, con dígitos monoespaciados.
- **Color de acento:** PRBar Blue, `#2D4EFF` en claro y `#4D6BFF` en oscuro.
- **Colores de estado (claro / oscuro):**

  | Estado | Claro | Oscuro |
  |---|---|---|
  | Verde | `#1A9E46` | `#32D35A` |
  | Naranja | `#D46B00` | `#FF9F0A` |
  | Rojo | `#D92D20` | `#FF5A50` |
  | Violeta (Claude) | `#8B3FD9` | `#C88BFF` |
  | Azul (severidad Baja) | `#0A72E8` | `#47A0FF` |

  Los fondos tintados de cada estado usan el mismo color con opacidad 0.14 en claro y 0.2 en oscuro.
- **Espaciado:** 2, 4, 6, 8, 12, 14 (padding horizontal del popover) y 20 (márgenes de ventana).
- **Radios:**

  | Elemento | Radio |
  |---|---|
  | Popover | 12 |
  | Ventana | 10 |
  | Tarjeta | 8 |
  | Fila | 7 |
  | Botón | 6 |
  | Checkbox | 4 |
  | Badge | cápsula |
- **Medidas:**
  - Popover: 380 de ancho, hasta 640 de alto.
  - Fila: ≈46 de alto; avatar de 22.
  - Botón Review: 20 de alto.
  - Ventanas: Review 720×640, Historial 760×520 (sidebar de 290), Configuración 620 de ancho.
- **Ícono de la app:** `arrow.triangle.pull` como imagen template, con un badge en cápsula.
- **Notas SwiftUI** (de la guía):
  - Barra y popover: `MenuBarExtra(.window)` con `.regularMaterial`; `DisclosureGroup` por sección; hover con `.onHover`.
  - Botón Review: `.bordered` en idle y fondo tintado en los estados de progreso; spinner con `ProgressView().controlSize(.mini)`.
  - Ventanas: Review con footer en `.safeAreaInset(edge: .bottom)`; Historial con `NavigationSplitView` + `.searchable`.
  - Configuración: `Settings` con `TabView` y `Form(.grouped)`.

**Diferencias con el diseño (decididas):**
- El diseño muestra una cuenta de GitHub Enterprise en Configuración. Queda **fuera de alcance** en la v1 (§1): solo se listan cuentas de `github.com`.
- En el mock de Review, dos hallazgos `keep` aparecen sin tildar. La regla sigue siendo la de §8.6: **todos los `keep` vienen tildados**.
- Los PRs de "Mis PRs con feedback" no tienen botón Review. En su lugar muestran la etiqueta del feedback ("Cambios pedidos" o "N comentarios"), como en el diseño.

## 14. Responder el feedback de mis PRs (Plan 3)

Reutiliza la cola, los estados del botón, el `ProcessRunner` con timeout y cancelación, el parser de `stream-json` y el historial del Plan 2 (§8, §10).

### 14.1 Botón y estados

Las filas de *Mis PRs con feedback* tienen un botón **Responder**. Sus estados son `idle → queued → preparing → analyzing → ready(n) | failed | cancelled`, y después `implementing → readyToPush → pushing → done`. La cola de 2 trabajos en paralelo es la misma del Plan 2.

### 14.2 Worktree

`WorktreeResolver` necesita `localPath` (§5); sin carpeta local, el botón aparece deshabilitado con un tooltip que lo explica.

**PRBar usa siempre su propio worktree; después del push, hacé `git pull` en tu clone.** Nunca usa el clone principal ni los worktrees del usuario, ni crea, mueve o adelanta ramas: el usuario puede tener cambios sin commitear, commits sin pushear o la rama en otro lado, y nada de eso se toca ni se mezcla con lo que escribe Claude. En cada análisis:

1. Valida `headRef` (`git check-ref-format --branch`, sin `-…`, `..`, `@{`, espacios ni `HEAD`) y que `git remote get-url origin` sea `github.com/<owner>/<repo>` (`https://github.com/…`, `git@github.com:…` o `ssh://git@github.com/…`, con o sin `.git`).
2. `git <GitHardening> -C <localPath> fetch --no-write-fetch-head origin +refs/heads/<headRef>:refs/prbar/respond-<N>-<runID>`. Ese commit es `startHeadOid`: la base de los fixes y del diff que revisa el usuario.
3. `git <GitHardening> -C <localPath> worktree add --detach <worktreeDir>/<repo>-<N>-respond-<runID> <sha>`, con `worktreeDir` configurable por repo (por defecto `<localPath>-worktrees`). Si la carpeta ya existe (aunque sea un symlink roto), se frena sin tocarla.

Si algo falla después del fetch, o el análisis falla o se cancela, se borran el worktree y la ref. Si el PR viene de un fork (`headRepository` distinto del repo), se frena antes.

El worktree y su ref se borran al terminar (`done`) y al descartar; **después de un fallo quedan** para que el usuario los revise. Al arrancar, la limpieza de huérfanos saca los worktrees de Responder que quedaron (solo los separados, con nombre `<repo>-<N>-respond-<runID>` y dentro de `worktreeDir`), borra las refs `refs/prbar/*` y las carpetas de contexto (`*.respond-context`).

### 14.3 Datos de feedback

Una query GraphQL dedicada (no la del refresco) trae:
- `reviewThreads(first: 100)` con `id`, `isResolved`, `isOutdated`, `path`, `line` y `comments(first: 30) { databaseId author { login } body createdAt url }`;
- los cuerpos de las reviews `CHANGES_REQUESTED` o `COMMENTED` de otras personas (comentarios generales).

Solo se analizan los hilos **no resueltos** cuyo último comentario no es mío, y los cuerpos de review no vacíos posteriores a mi último commit.

### 14.4 Etapa de análisis

`claude -p` corre con las mismas herramientas de solo lectura y el mismo aislamiento que §8.3 (`Read(./**)`, `--settings`, entorno en lista blanca), con `cwd` en el worktree y `--add-dir` en la carpeta de contexto (`$TMPDIR/PRBar/worktrees/<owner>-<repo>-<N>-<id>.respond-context`, que se borra al terminar el análisis). El prompt incluye los ítems como JSON y le pide aplicar el skill de responder elegido (`respondSkill`, por defecto `superpowers:receiving-code-review`, §8.0) a cada uno. El análisis y los fixes cargan solo el plugin de ese skill y usan el modelo elegido. La respuesta tiene que terminar con:

```json
{ "items": [ {
  "id": "thread:<id> | review:<id>",
  "assessment": "1-2 líneas: ¿tiene razón el reviewer?",
  "action": "fix | reply | fixAndReply",
  "fixPlan": "qué cambiar (si aplica)",
  "reply": "borrador de respuesta en el idioma del PR (si aplica)"
} ] }
```

La validación y el reintento son los de §8.5.

### 14.5 Ventana "Responder feedback"

Hay una tarjeta por ítem con:
- el comentario original (autor, `archivo:línea`, texto) y la evaluación de Claude;
- el checkbox **Implementar fix**, con `fixPlan` editable;
- el checkbox **Responder**, con `reply` editable.

Los checkboxes vienen marcados según `action`. Abajo hay un botón **Implementar (N fixes)**. Si no se marcó ningún fix, ese botón pasa directo a **Publicar respuestas**.

### 14.6 Etapa de implementación

**Regla:** nada que escribió Claude se ejecuta antes de que el usuario vea el diff completo.

Cada fix elegido es una corrida de `claude -p` aislada (§8.3) en el worktree de PRBar, en orden:
- **Herramientas:** solo `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Skill` y `Agent`, con `--allowedTools "Read(./**),Edit(./**),Skill,Agent"`: Claude solo puede leer y escribir dentro del worktree (ver la verificación de §8.3). Sin Bash, git ni red, y sin token en el entorno. El texto de los comentarios va marcado como no confiable.
- **git endurecido:** todos los git de esta etapa llevan `GitHardening` (`-c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false -c core.untrackedCache=false`) y `status`/`diff` además `--ignore-submodules=all`. Un hook (de `.git/hooks` o de un `core.hooksPath` dentro del repo, como husky) o la config de un repo anidado podrían ejecutar código que Claude acaba de escribir.
- **Antes de cada fix:** `git status --porcelain --untracked-files=all` tiene que estar vacío, y ningún archivo de `git config --list --show-origin` puede estar dentro del worktree (fuera de su `.git`; p. ej. un `include.path` que apunta al árbol). Después se toman la huella del `.git`, la lista de `.git` anidados y un snapshot de todos los archivos del worktree salvo el `.git` de arriba (ruta, tamaño, fecha de modificación, inodo).
- **Después de cada corrida de Claude, antes de cualquier git:**
  1. el `.git` del worktree, la config y los hooks tienen que estar iguales. Es una lista de permitidos (contenido, modo y destino de los symlinks), porque el common dir es el `.git` del clone del usuario y ahí cambian cosas sin que Claude pueda tocarlas (Finder, fetch, checkout, gc, otros worktrees): en el common dir `config`, `config.worktree`, `hooks/`, `info/attributes`, `info/exclude`, `info/sparse-checkout`, `commondir`, `objects/info/alternates` y los `config`/`hooks/` de `modules/`; en el admin dir del worktree de PRBar `config.worktree`, `commondir`, `gitdir`, `HEAD`, `info/` y `hooks/`; el `.git` del worktree; y lo que esas configs incluyan (`include.path`, `includeIf`) dentro de esas carpetas. Se ignoran los metadatos de macOS (`.DS_Store`, `._*`, `Icon\r`) y todo lo demás (`FETCH_HEAD`, `ORIG_HEAD`, el `HEAD` del clone, `packed-refs`, `index`, `objects`, `refs`, `logs`, `lfs`, `rr-cache`, otros worktrees, `gc.log`, `COMMIT_EDITMSG`, locks);
  2. no puede haber aparecido ninguna entrada llamada `.git` (archivo o carpeta) en ningún nivel: convertiría una carpeta en un repo cuya config (`core.fsmonitor`) correría en el próximo `git status` (reproducción C2, que es un test);
  3. si cambió un `.gitattributes` o un `.lfsconfig` en cualquier nivel, se corta antes del `git add`.
  Si algo de esto falla, se corta toda la corrida sin correr git y el worktree queda para revisarlo.
- **Cambios invisibles:** se compara el snapshot con el de antes y con `git status --porcelain -z --untracked-files=all --ignored=matching`. Los metadatos de macOS (`.DS_Store`, `._*`, `Icon\r`) que git ignora no cuentan (los crea Finder); uno que git no ignora va al diff como cualquier archivo. Un archivo nuevo que git no muestra (ignorado) se borra y el fix se descarta (`failed`). Si Claude modificó o borró un archivo ignorado que ya existía (p. ej. `node_modules/.bin/x`), se restaura lo trackeado y se corta toda la corrida: ese cambio no aparece en el diff y no se puede deshacer.
- **Commit de PRBar:** si hay cambios, `git add -A`; si `git diff --cached --raw` muestra un gitlink (`160000`) o un symlink (`120000`), se corta antes del commit; si no, `git commit --no-verify -m <asunto>`. El mensaje que propone Claude se sanea y **solo queda el asunto** (la primera línea no vacía, sin caracteres de control ni de formato, hasta 72 caracteres): nunca un cuerpo que el usuario no vea.
- **Fix fallido:** si Claude devuelve `failed` o `skipped`, o su corrida falla (timeout, crash, cancelación), se descartan sus cambios con `git checkout -- .` + `git clean -fd` (sin `-x`) más los archivos ignorados nuevos. Es seguro porque el árbol estaba limpio.
- **Verificación:** cada commit tiene que descender de `startHeadOid`.
- **Al terminar:** el resultado guarda el `--stat`, el diff completo (`git diff --text --no-textconv --no-ext-diff <startHeadOid>..HEAD`, endurecido, hasta 5000 líneas o 1 MB), los commits con su mensaje, el HEAD (`headOid`, lo que se va a pushear) y una huella SHA-256 de la config, los hooks y los `.git` (`gitIntegrity`).
- **Sin tests:** esta etapa no corre el `testCommand`.

Timeout: 15 minutos por fix.

### 14.7 Revisión, tests, push y respuestas

La ventana muestra los commits nuevos con su mensaje completo, el `--stat` y **el diff completo** en una vista con scroll, monoespaciada, con `+`/`-` en color; si se cortó, avisa "diff truncado; revisalo en el worktree". Todo eso va arriba de "Correr tests" y del push.

**Archivos sensibles:** si Claude cambió archivos que pueden ejecutar código o cambiar cómo se comportan git, las herramientas o los agentes, se listan en rojo con un banner. Entran hooks (`.husky/`, `.githooks/`, `.pre-commit-config.yaml`, `lefthook*.yml`, `.lefthook*`), git (`.gitattributes`, `.lfsconfig`, `.gitmodules`), manifiestos y builds (`package.json`, `.npmrc`, `.yarnrc*`, `.yarn/`, `Gemfile*`, `*.gemspec`, `Makefile`, `Rakefile`, `Package.swift`, `pyproject.toml`, `setup.py`, `setup.cfg`, `conftest.py`, `build.rs`, `*.gradle*`, `Podfile`, `Dockerfile*`), configs de herramientas (`*.config.js`, `*.config.ts`, `*.config.mjs`, `*.config.cjs`), editores y contenedores (`.vscode/`, `.idea/`, `.devcontainer/`), CI (`.github/`, `.circleci/`), scripts (`*.sh`, `bin/`, `scripts/`), entorno (`.envrc`, `.tool-versions`) e instrucciones para agentes (`CLAUDE.md`, `AGENTS.md`), en cualquier nivel del repo.

**Correr tests** (si el repo tiene `testCommand`): solo cuando el usuario toca el botón, después de ver el diff. PRBar corre `/bin/zsh -lc <testCommand>` en el worktree (20 minutos), guarda el output en el log y muestra las últimas 80 líneas. Si fallan, aparece una advertencia (no bloquea).

**Confirmaciones:** pushear, publicar respuestas (y aprobar un PR, §8.7) piden confirmación en un `NSAlert` donde **Return cancela**; la acción no tiene atajo y necesita un clic.

**Pushear y responder:**
1. Justo antes del push, sin correr git hasta el segundo paso: ningún `.git` anidado; la huella de git es la de `gitIntegrity`; ninguna config de git viene de dentro del worktree; `origin` es el repo del PR; HEAD sigue siendo `headOid` (el sha que vio el usuario); y desciende de `startHeadOid`. Si algo no da, no se pushea.
2. `git -c core.fsmonitor=false -c submodule.recurse=false -c core.untrackedCache=false push origin <headOid>:refs/heads/<headRef>`: el sha explícito, sin `--force` y **con los hooks del usuario** (pre-push). Los hooks corren en el worktree de PRBar sobre el código que escribió Claude: es aceptable solo porque el usuario ya vio el diff completo y confirmó, y la ventana y la confirmación lo dicen. Si es rechazado (porque el remoto avanzó o un hook falló), se informa el error y no se publica nada.
3. Cada respuesta se publica en su hilo con `POST /repos/{o}/{r}/pulls/{n}/comments/{databaseId del primer comentario}/replies`. Las respuestas a comentarios generales de review van como comentario del PR (`POST /repos/{o}/{r}/issues/{n}/comments`) citando al reviewer. Si el ítem tiene commit, la respuesta empieza con "Fixed in <link al commit>." en el idioma del PR (§16; p. ej. `Arreglado en …`).
4. **No se resuelven hilos.**

Si algún post falla, los que ya se publicaron quedan marcados como publicados y se ofrece **Reintentar** solo para los que faltan.

### 14.8 Historial

Cada ejecución se guarda en el historial (§10) con `kind: "respond"`: ítems, decisiones, commits, respuestas publicadas y el log de Claude.

## 15. Bot de Slack (Plan 4)

### 15.1 Configuración

En Configuración hay una pestaña nueva, **Slack**, con:
- el interruptor general;
- el campo del **bot token** (`xoxb-…`), guardado en el Llavero (servicio `com.federico.prbar.slack`) y nunca en `config.json`;
- un botón **Probar conexión** (`auth.test`);
- las plantillas `newPRTemplate` (por defecto `{link}`) y `updateTemplate` (por defecto `Updated {link}`), con las variables `{link}`, `{title}`, `{number}`, `{repo}` y `{author}`;
- una guía para crear la app de Slack: scopes de bot `chat:write`, `channels:read`, `groups:read`; instalar en el workspace; invitar al bot al canal con `/invite @<bot>`.

En Configuración → Repos, cada repo tiene un selector de **canal de Slack** (lista de `conversations.list`, públicos y privados donde está el bot). Se guarda `slackChannelID`, `slackChannelName` y `slackEnabledAt` (la fecha en que se eligió el canal). Varios repos pueden compartir canal.

`slack.enabledAt` guarda cuándo se encendió el interruptor general o se guardó un token donde no había. Así, reactivar Slack no anuncia lo acumulado: solo PRs creados desde ese momento.

### 15.2 Cuándo se manda

`SlackPlanner` es una función pura, igual que `NotificationPlanner`. Corre después de cada refresco sobre los PRs **míos** (autor = la cuenta que los ve) de repos con canal configurado:

| Evento | Condición | Acción |
|---|---|---|
| **PR nuevo** | No draft, no anunciado todavía, y `createdAt ≥ corte` o la app lo vio como draft desde el corte, con corte = máx(`slackEnabledAt`, `baselineAt`, `slack.enabledAt`) | `chat.postMessage` al canal con `newPRTemplate`. Se guarda `channel` + `ts`. |
| **Updated** | Ya anunciado; alguna review de otra persona (no bot; APPROVED, CHANGES_REQUESTED o COMMENTED) con `submittedAt` > `lastHandledReviewAt` (o > la fecha del anuncio) se hizo sobre un commit (`commit.oid`) distinto del `headOid` actual. No se usan relojes ni fechas de commit; un "Update branch" de GitHub cuenta como update. | `chat.postMessage` con `thread_ts = ts` y `updateTemplate`. Se guarda `lastHandledReviewAt` = el `submittedAt` más reciente entre todas esas reviews sin manejar (no `now`). |

Los mensajes no cambian el unfurl de links: se usa el comportamiento por defecto de Slack.

Resultado: **un "Updated" por ronda de review**. Los PRs que ya existían al configurar el canal no se anuncian.

### 15.3 Estado

`~/Library/Application Support/PRBar/slack-state.json` guarda `baselineAt` y, por `owner/repo#n`: `channelID`, `ts`, `announcedAt`, `lastHandledReviewAt` (los archivos viejos con `lastUpdatePostedAt` se leen como tal); además `seenAsDraft` (PR → fecha en que se vio como draft).

El estado se escribe **después** de cada post exitoso, así que un reinicio no duplica mensajes. Si la app estaba cerrada, se anuncia en el siguiente refresco.

Si el archivo no existe o es ilegible (este último se mueve a `slack-state.json.bak`), se crea un estado nuevo con `baselineAt = now` y se guarda enseguida. El planner exige `createdAt ≥ baselineAt`, así que perder el estado nunca vuelve a anunciar PRs que ya existían. El archivo se lee de forma tolerante (campos faltantes toman su valor por defecto). Si no se puede guardar, aparece un issue de Slack.

### 15.4 Errores

Los errores de la API de Slack (`not_in_channel`, `invalid_auth`, `channel_not_found`, `ratelimited` con `Retry-After`) se agregan como `RefreshIssue` con `account: "slack"`. El popover muestra la indicación para resolverlos con texto de Slack, no de GitHub (por ejemplo, "Invitá al bot al canal #x con /invite @<bot>" o "Slack limitó los envíos · reintento a las HH:MM"); el nombre del canal viaja en `RefreshIssue.detail`. El post se reintenta en el siguiente refresco. Nunca se loguea el token.

## 16. Idioma de lo que se publica

La interfaz de PRBar está en inglés, y lo que solo ve el usuario dentro de la app también: el `summary` y los `title` de los hallazgos, el `reason` de la etapa 2, y el `assessment`, el `fixPlan` y el `summary` de los fixes de Responder. Los prompts de Claude están en inglés y mantienen todas las reglas de seguridad.

Lo que se **publica en GitHub** va en el idioma del PR, detectado de su descripción:

- **Descripción a pedido.** El refresco de cada 2 minutos no trae la descripción. `GitHubAPI.pullRequestDetails` (`GET /repos/{o}/{r}/pulls/{n}`: título, `body` y `head.sha`) se llama al empezar una review (§8) y el análisis de Responder (§14.4). Si falla, la corrida sigue: el idioma sale del título y se loguea el error.
- **Detección** (`PRLanguage.detect(description:title:)`, con `NLLanguageRecognizer`):
  - antes se sacan los comentarios HTML (plantillas de PR), los bloques y fragmentos de código, las URLs, las imágenes, los ítems de checklist, los títulos de Markdown, las menciones, las referencias `#123` y la puntuación de Markdown; de los links queda el texto;
  - si a la descripción le quedan al menos 40 letras se usa sola; si no, se le suma el título;
  - con menos de 12 letras en total, o si la confianza del idioma dominante es menor a 0,5, se usa inglés.
- **Resultado:** un código BCP-47 (`"es"`) con su nombre en inglés (`Spanish`). Se guarda en `ReviewDraft.language` y `RespondDraft.language` (en JSON, el código como string). Los registros viejos sin ese campo se leen como inglés.
- **Prompts.** Claude recibe el idioma exacto (nombre y código) para el `body` de cada hallazgo (el comentario inline) y para el `reply` de Responder; el resto de los campos va en inglés.
- **Frases fijas de PRBar** (`PublishedPhrases`):
  - "Fixed in <link del commit>." según el idioma: `es` "Arreglado en …", `pt` "Corrigido em …", `fr` "Corrigé dans …", `de` "Behoben in …", `it` "Corretto in …"; cualquier otro, inglés;
  - los hallazgos sin línea en el diff van al body como `**archivo:línea** — texto` y las respuestas a cuerpos de review como `@reviewer`, la cita y el texto: formatos neutros, sin palabras.
- **UI.** El pie de la ventana de Review dice "Comments will be posted in <idioma>" y la ventana de Responder, "Replies will be posted in <idioma>".
- El comentario general que escribe el usuario no se traduce: se publica tal cual.

## 17. Slack con la cuenta del usuario y reacciones a reviews (Plan 5)

Reemplaza al bot de §15: PRBar publica, lee y reacciona **como el usuario**. Por defecto lo hace con el **conector de Slack de la cuenta de Claude** del usuario (sin app de Slack, §17.5); como alternativa, con su User OAuth Token (`xoxp-…`) guardado en el Llavero (`com.federico.prbar.slack`, cuenta `user-token`). El token de bot existente se borra al migrar. Scopes de usuario (solo modo token): `chat:write`, `reactions:write`, `channels:history`, `groups:history`, `channels:read`, `groups:read`.

### 17.1 Mis PRs (igual que §15.2, publicado como el usuario)
Anuncio del PR nuevo y "Updated" en el hilo una vez por ronda de review (regla por commit de §15.2).

### 17.2 PRs de otros: reacciones
Solo para repos con canal configurado y PRs presentes en el snapshot (relevantes por usuarios seguidos o review pedida).

1. **Localizar el mensaje del PR**: `conversations.history` del canal del repo, ventana `searchDays` (30 por defecto), paginando hasta 1000 mensajes. Se toma el **mensaje raíz más antiguo** cuyo `text` (o `attachments[].from_url`/`blocks`) contiene la URL del PR (`https://github.com/<o>/<r>/pull/<n>`), normalizando `<url|texto>`, `<url>`, barra final, `/files`, `/commits` y `#…`. El resultado (`channelID`, `ts`) se guarda; si no se encuentra, se reintenta como máximo cada 10 minutos por PR.
2. **👀 (`eyesEmoji`, default `eyes`)**: al apretar Review en PRBar, o al detectar la primera review mía en GitHub si todavía no se reaccionó.
3. **Rondas de comentarios**: una ronda = el conjunto de mis reviews `COMMENTED`/`CHANGES_REQUESTED` sobre un mismo `commitOID` (responder varios hilos sobre el mismo commit no suma). Ronda 1 → reacción 💬 (`commentEmoji`, default `speech_balloon`). Ronda n ≥ 2 → mensaje en el hilo con `roundTemplate` (default `commented x{n}`).
4. **Aprobado**: mi review `APPROVED` → reacción `approvedEmoji` (default `approved`; si no existe en el workspace, error visible `invalid_name`).
5. **Sin retroactividad**: solo cuentan reviews con `submittedAt ≥ reviewReactionsEnabledAt` (fecha en que se activó la función); las rondas se numeran contando solo esas.
6. **Idempotencia**: `already_reacted` se ignora; el estado (`messageRef`, reacciones hechas, última ronda publicada) se guarda tras cada envío.

### 17.3 Configuración
"Connect with" elige el provider (`slack.provider`, §17.5), en este orden: **Claude's Slack connector** y **Slack user token**. Sin `provider` en `config.json` el default es el conector, salvo que ya haya un token de usuario en el Llavero (comprobado solo por atributos, sin leer el secreto): entonces se queda con `userToken`. La elección se guarda al arrancar y no corta el backlog. Cambiar de provider a mano cuenta como credencial nueva (`enabledAt = now`, como guardar un token). Toggles independientes: anunciar PRs, "Updated", 👀, 💬, "commented xN", aprobado. Emojis y plantillas editables (`{link}`, `{title}`, `{number}`, `{repo}`, `{author}`, `{n}`), `searchDays` (7–90 en la UI). Con el token: campo `xoxp-…`, banner de migración y guía de creación de la app con User Token Scopes. Con el conector: el texto "Uses your Claude account's Slack connector — no Slack app needed. Messages and reactions are posted as you. Each action takes a few seconds and uses a little of your Claude usage." y el botón "Test Connection" ("Connected as @user via Claude"). En los dos modos: **"Send Test to My DM…"** (§17.5, punto 9) y "Show Log".

### 17.4 Errores
Como §15.4, con pistas nuevas: `missing_scope` (indicar scope), `invalid_name` (emoji inexistente), `not_in_channel` (para canales privados, el usuario debe ser miembro), `ratelimited`.

### 17.5 Provider: conector de Slack de Claude o token de usuario
El usuario elige cómo habla PRBar con Slack. En los dos casos los mensajes y las reacciones salen **como el usuario**, y el planner, el estado y los errores son los mismos (`SlackAPI`).

- **`claudeConnector`** (default): sin token ni app de Slack. `ClaudeConnectorSlackAPI` corre `claude -p` (headless) con el conector de Slack de la cuenta de claude.ai del usuario. Cada acción tarda unos segundos (≈5 s; listar canales ≈12 s) y consume Claude (≈US$0,001–0,003 por acción con `haiku`; la primera corrida, ≈US$0,02, carga todos los servidores MCP).
- **`userToken`**: la Web API de Slack directa (`SlackClient`) con el `xoxp-…` del Llavero. Instantáneo y sin costo; requiere una app de Slack (a veces aprobada por un admin).

**Modelo de seguridad del conector** (verificado con `claude` 2.1.318 y login OAuth; los conectores de claude.ai **solo cargan con `--setting-sources user`**: con `""`, `project`, `local`, `--restricted`, `--safe-mode` o `--strict-mcp-config` no aparecen):

1. **Flags fijos**: `--model haiku --output-format stream-json --verbose --json-schema <schema> --system-prompt <propio> --setting-sources user --settings <json> --disable-slash-commands --no-chrome --no-session-persistence --permission-mode dontAsk --tools "" --allowedTools <una herramienta de Slack> --disallowedTools <lista>`.
   - `--tools ""`: ninguna herramienta propia (ni Bash, ni archivos, ni red, ni agentes). El `init` muestra solo `StructuredOutput` y la herramienta de Slack de la operación.
   - `--permission-mode dontAsk` pisa el `defaultMode: auto` del usuario (verificado en `init.permissionMode`); con `--allowedTools` reducido a la herramienta exacta, cualquier otra llamada se niega (`permission_denied`, `decision_reason_type: mode`), incluso otra herramienta de Slack.
   - `--disallowedTools`: las herramientas propias, las otras 26 herramientas de Slack y `mcp__<servidor>` de cada servidor que no es Slack (la regla por servidor los saca del contexto).
   - `--settings`: `disableAllHooks` (los hooks del usuario y de los plugins no corren), `deniedMcpServers` y `permissions.deny` con esos servidores (no se conectan), `disableBypassPermissionsMode`. `allowedMcpServers` no sirve: deja afuera también al conector de Slack.
   - Entorno: la lista blanca de `ClaudeRunner` más `MCP_CONNECTION_NONBLOCKING=0` (si no, el primer turno puede arrancar antes de que el conector termine de conectar y el modelo no lo ve). cwd: una carpeta temporal vacía. Timeout 60 s, sin reintentos.
2. **Servidores a negar**: no hay comodín, así que se aprenden de `init.mcp_servers` de cada corrida (todo lo que no es `claude.ai Slack`) y se guardan en `slack-connector-servers.json`; `claude-in-chrome` va siempre (el usuario lo tiene en `allow`). Un servidor nuevo, la primera vez, solo está bloqueado por `dontAsk` + `--allowedTools`.
3. **Operaciones deterministas**: PRBar arma los argumentos exactos y Claude hace una sola llamada: `postMessage` → `slack_send_message {channel_id, message[, thread_ts]}`; `addReaction` → `slack_add_reaction {channel_id, message_ts, emoji}`; `history` → `slack_read_channel {channel_id, oldest, limit: 100}` (una página, una vez por canal por ciclo); `threadReplies` → `slack_read_thread {channel_id, message_ts, limit: 100}`; `channels` → `slack_list_user_channels {types, exclude_archived, limit: 200}`; `authTest` → `slack_read_user_profile {}`.
4. **Verificación**: PRBar lee los `tool_use` del stream: tiene que haber exactamente una llamada (sin contar `StructuredOutput`), a la herramienta esperada, con exactamente los argumentos esperados (mismas claves y valores), y ninguna negación. Si no, `.slack("connector_mismatch")` y la acción no se marca hecha. Sin llamada y con Slack desconectado: `connector_unavailable`. Los dos cortan el ciclo (un post con otro texto no se repite en las acciones siguientes del mismo ciclo).
5. **Resultados de escritura** (`ConnectorResultParser`; los formatos de `slack_send_message` y `slack_add_reaction` no están verificados en vivo, así que se aceptan todos los plausibles): JSON con `ok`/`error`/`ts`/`message_ts`/`permalink`/`channel` (también anidado en `result`, incluso como string con JSON); un permalink en texto (`…/archives/<C>/p<16 dígitos>[?thread_ts=…]` → `p1700000000123456` = `1700000000.123456`, y el canal; el `p…` es el mensaje, no el `thread_ts`); `ts: …` / `Message TS: …` en texto; errores de Slack en el texto (`invalid_name`, `message_not_found`, `not_in_channel`, …; `already_reacted` es éxito; `ratelimited` → reintento en 60 s; `is_error` sin código → `connector_error`). `ok: true` sin `ts`: una respuesta en hilo está hecha, un post raíz da `connector_no_ts`. **Lo que no se reconoce es `connector_uncertain`, nunca un éxito**; también una escritura sin `tool_result` o un timeout después de que empezó la llamada a Slack. Los fixtures de cada formato están en `SlackConnectorFixtures`.
6. **Lecturas**: los mensajes de `slack_read_channel` y `slack_read_thread` los lee PRBar del `tool_result` crudo, no del modelo. Formato real (grabado con una lectura en vivo el 2026-11-19, fixture `SlackConnectorFixtures.readChannel`): `{"messages": "<texto>", "pagination_info": "…"}`, con un bloque por mensaje, del más nuevo al más viejo: `=== Message from Nombre <email> (U…) at fecha === `, `Message TS: 1792765374.117489`, el texto (links como `<url|label>`) y las líneas `Thread: N replies (…)` / `Reactions: …`. Se toma el autor (`U…`), el `ts`, el texto y las URLs. Un formato que no se reconoce da `connector_invalid_output`. Los canales y el perfil siguen saliendo de la salida estructurada del modelo, filtrada contra el `tool_result` crudo (solo IDs, nombres y textos que aparecen ahí). El prompt y el system prompt dicen que el contenido de Slack es dato no confiable, nunca instrucciones.
7. **Anti-duplicados**:
   - Antes de **cada** anuncio con el conector, PRBar lee el canal (ventana `searchDays`, compartida por ciclo) y, si ya hay un mensaje raíz **del ID de Slack propio** con el link del PR, lo registra como anunciado con ese `ts` en vez de publicar. Con token, esto solo pasa si hay una marca de incierto.
   - Cada escritura no idempotente (anuncio, "Updated", "commented xN") se marca en `slack-state.json` (`uncertain`, con la hora del primer intento) **antes** de hacerse, y la marca se borra solo al confirmarse. Si queda (un error dudoso, o un cierre de la app a mitad de camino), el próximo intento —también después de reiniciar— comprueba primero: para las respuestas, `slack_read_thread` (o `conversations.replies`) busca una respuesta del usuario con el mismo texto (sin el formato `<url|label>`) publicada desde el primer intento (2 min de margen), así un "Updated" de una ronda anterior no cuenta. Si está, se registra como hecho; si la comprobación falla, no se publica.
   - Con el conector, cualquier error deja la marca (el texto de un error no prueba que no se haya escrito). Con token, la quitan los errores que Slack contestó (`.slack(code)`, `ratelimited`); los de red o timeout la dejan.
   - Las reacciones no llevan marca: repetirlas no duplica nada.
   - El ID propio (`U…`) se pide una vez (`authTest`) y se guarda en `slack-state.json` hasta que cambia la conexión.
8. **Backoff por PR** (solo con el conector): tras un error, ese PR espera 10 min, después 30 y después 60 (tope); mientras tanto no se intenta nada de ese PR y su último error sigue visible. Un éxito lo borra. `invalid_name` no cuenta (tiene su propia regla).
9. **"Send Test to My DM…"** (Ajustes → Slack, los dos modos): lo lanza el usuario después de confirmar "PRBar will post a test message in your own DM, react 👀, reply in its thread, then read it back." Por la misma `SlackAPI`: `authTest` (ID propio) → **un** mensaje raíz "PRBar connector test (you can delete this)" al ID propio (el DM consigo mismo; el canal `D…` real sale del resultado si lo trae) → `:eyes:` en ese mensaje → **una** respuesta "PRBar connector test reply" en su hilo → lectura del hilo, que tiene que tener los dos. Sin reintentos: el primer paso que falla corta el resto. Cada paso se muestra con ✓/✗ y el `ts` interpretado o el error, y se escribe en el log junto al `tool_result` crudo; "Show Log" abre el log.
10. **Log**: `~/Library/Logs/PRBar/slack-connector.log` con el stream de cada corrida, el `tool_result` crudo (recortado a 600 caracteres), cómo se interpretó, el motivo de cada rechazo y los pasos de la prueba.

