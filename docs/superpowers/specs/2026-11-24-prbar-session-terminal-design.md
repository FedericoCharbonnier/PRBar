# PRBar: abrir en una terminal la sesión de Claude de un PR

Fecha: 2026-11-24. Plan: `2026-11-24-prbar-plan-22-session-terminal.md`.

## Decisiones del usuario (2026-11-24, no se reabren)

1. Un botón **Terminal** al lado de **Chat** abre en una terminal la sesión de Claude Code que hizo la review, los fixes
   (Respond) o el Fix CI de un PR, para **seguir trabajando**: Claude Code interactivo en la carpeta del PR, con la
   configuración normal del usuario (edita, corre comandos, commitea y pushea él).
2. Enfoque **A**: retomar la sesión real (`claude --resume <id>`), no una sesión nueva con un resumen. Si el PR tiene
   varias sesiones, un menú para elegir.
3. La terminal se elige en Settings: Terminal, iTerm, Warp, Ghostty, Orca o un comando propio.
4. PRBar conserva la carpeta (worktree) de la última review y de los últimos fixes de cada PR abierto, aunque ya se haya
   publicado o pusheado.

---

## T.1 Qué sesiones se ofrecen

- Una **sesión** es una corrida de `claude -p` de un trabajo: cada etapa de la review, cada fix de Respond y el Fix CI.
  El chat de PRBar no entra (ya se usa desde el inspector).
- Por PR se ofrecen las del **último** trabajo de cada tipo: la última review y el último de Respond / Fix CI (comparten
  la carpeta del branch del PR, T.3: un Fix CI después de un Respond lo reemplaza, y al revés). Solo las que tienen su
  carpeta conservada (T.3) y su ID de sesión (T.2).
- Nombres: `Review · stage N`, `Fix N: <título del hallazgo, truncado a 50>`, `CI fix`. En el menú, agrupadas bajo
  **Review**, **Fixes** y **CI fix**, en el orden en que corrieron.

## T.2 Guardar el ID de sesión

- `claude -p --output-format stream-json` emite al principio `{"type":"system","subtype":"init","session_id":"…"}`.
  `ClaudeStream` lo lee y `ClaudeRunner` lo devuelve con el resultado de la corrida (también si la corrida falla
  después de arrancar).
- `ClaudeSessionRef` (Codable): `id` (String), `label`, `kind` (`review` | `fix` | `ciFix`), `directory` (ruta de la
  carpeta en la máquina donde corrió), `runner` (`nil` = esta Mac; si no, el nombre del runner de `RunnerSettings`),
  `startedAt`.
- Se guardan en el registro de History del trabajo: `ReviewRecord.sessions` y `RespondRecord.sessions`
  (`[ClaudeSessionRef]`, opcional al decodificar: los registros viejos cargan sin sesiones).
- Las corridas que no son de un trabajo de PR (filtro de skills, chequeos de runner, Instructions) no guardan nada.

## T.3 Conservar las carpetas

- Al **publicar** una review y al **pushear** fixes (Respond o Fix CI), la carpeta ya no se borra: queda registrada como
  **conservada** para `(PR, tipo)` con tipo `review` o `respond` (Respond y Fix CI comparten la carpeta del branch).
  El registro vive en Application Support (`retained-worktrees.json`) y sobrevive a reiniciar PRBar.
- La carpeta de la review hoy se borra apenas termina Claude, antes de publicar. Por eso se conserva **al terminar bien
  la review** (publicada después o no): es la carpeta de la última review del PR. Una review que falla se limpia como
  hoy (sus sesiones quedan en el registro, pero no se ofrecen).
- Al mergear o cerrar el PR también se mira `lsof`: una carpeta con un proceso adentro queda para Clean Up.
- Una carpeta conservada se borra:
  1. cuando el PR se **mergea o se cierra** (la misma pasada que hoy limpia worktrees que sobran);
  2. cuando un trabajo **nuevo del mismo tipo** del mismo PR deja otra carpeta conservada; si en la vieja hay un proceso
     con cwd adentro (`lsof`), no se borra en ese momento y queda para Clean Up;
  3. con **Clean Up** (`prbar cleanup`), que nunca borra una carpeta conservada con cambios sin commitear o commits que
     no están en el remoto: la lista como salteada (como hoy los fixes sin pushear).
- Activity y `prbar resources` ya suman los worktrees en "worktrees"; las conservadas entran ahí.
- Mientras PRBar corre algo en esa carpeta (un trabajo o un turno del chat), el botón está deshabilitado. Un trabajo
  nuevo de PRBar sobre el PR usa **otra** carpeta: nunca pisa lo que el usuario está haciendo en la conservada.

## T.4 El botón y los otros accesos

- **Toolbar del PR** (`PRDetailToolbar`): botón **Terminal** (`terminal`), a la izquierda de **Chat**.
  - Una sesión: la abre. Varias: menú (T.1). Ninguna: deshabilitado, ayuda "No Claude session for this PR yet".
    PRBar trabajando en esa carpeta: deshabilitado, ayuda "Claude is working on it".
  - Ayuda normal: "Open Claude’s session in <Terminal>".
- **Menú Pull Request › Open Claude Session in Terminal** (⌥⌘T): igual que el botón (con varias, abre la más reciente).
- **History**: en el detalle de un registro con sesiones y carpeta conservada, **Open in Terminal** (menú si hay varias).
- **CLI**:
  - `prbar session list <pr> [--json]`: las sesiones ofrecidas (número, nombre, tipo, máquina, carpeta, hora).
  - `prbar session open <pr> [--job review|respond|ci-fix] [--run N]`: abre una (sin opciones, la más reciente).
    Exit 6 si no hay ninguna o si PRBar está trabajando en esa carpeta.
- **iPhone**: no (abre una terminal en la Mac). Va en `RemotePolicy` como no ofrecida.

## T.5 Abrir la terminal

- `ClaudeSessionCommand` arma el comando:
  - Esta Mac: `cd '<carpeta>' && '<claude>' --resume <id>`, con el `claude` de Settings › Tools.
  - Runner: `ssh -t <destino del runner> "cd '<carpeta>' && '<claude del runner>' --resume <id>"`, con un
    subconjunto interactivo de las opciones de `SSHCommand` (`SSHCommandBuilder.interactiveOptions`: sin `BatchMode`,
    con TTY), no exactamente las mismas.
  - Todo valor va entre comillas simples con escape (`ShellQuote`); el ID se valida como UUID.
- `TerminalLauncher` lo abre según la terminal elegida (verificado en esta Mac el 2026-11-24, con una carpeta con
  espacios en la ruta):
  - **Terminal**, **iTerm**, **Warp** y **Ghostty**: un script `.command` ejecutable (`#!/bin/zsh`,
    `cd '<carpeta>' && <comando>` y después `exec /bin/zsh -l`, para que la ventana quede abierta al salir de Claude)
    en Application Support (`terminal/`, modo 755; los de más de un día se borran en cada apertura), abierto con
    `open -a <app>` (`Terminal`, `iTerm`, `Warp`, `Ghostty`). No pide permiso de automatización y Warp no necesita
    una launch configuration. Instaladas según su bundle id: `com.apple.Terminal`, `com.googlecode.iterm2`,
    `dev.warp.Warp-Stable`, `com.mitchellh.ghostty`.
  - **Orca** (`com.stablyai.orca`): `orca terminal create --worktree "path:<carpeta>" --title "<título>"
    --command "<comando>" --focus --json` (el binario está en `/Applications/Orca.app/Contents/Resources/bin/orca`).
    Solo funciona si la carpeta es un worktree de un repo agregado en Orca (`orca repo list`); si no, contesta
    `"ok": false` con `"code": "selector_not_found"` y PRBar avisa "This folder isn’t in Orca. Add the repo in Orca or
    choose another terminal." Para una sesión de un runner, la carpeta es la carpeta local del repo (Settings › Repos) y
    el comando, el de `ssh`.
  - **Custom**: un comando con `{dir}` y `{command}` (ya entre comillas), corrido con `/bin/sh -c`.
- Si la terminal elegida no está instalada o falla al abrir: una alerta con el error y "Open Settings". La CLI sale con
  el mensaje y exit 1.

### Limitaciones conocidas

- Custom y Orca corren desde el entorno de la app (un `PATH` mínimo): un `claude` instalado con npm/nvm puede necesitar
  un shell de login en la plantilla (`/bin/zsh -lc {command}`).
- Con `CLAUDE_CONFIG_DIR` en el shell del usuario: PRBar corre Claude con su propio entorno (`~/.claude`), así que las
  sesiones quedan ahí y `--resume` desde una terminal con otro `CLAUDE_CONFIG_DIR` puede decir "No conversation found".

## T.6 Settings y configuración

- **Settings › General › Terminal**: un picker con las terminales instaladas (por bundle id; Terminal siempre) y
  **Custom…**, que muestra un campo para el comando con la ayuda "{dir} is the PR’s folder, {command} runs Claude".
  Default: Terminal.
- Config: `terminal` (`terminal` | `iterm` | `warp` | `ghostty` | `orca` | `custom`) y `terminalCommand` (String,
  solo para `custom`). Una config vieja sin estos campos queda en Terminal.
- CLI: `prbar config set terminal <valor>` y `prbar config set terminal-command "<comando>"`; `prbar config show` los
  muestra.

## T.7 Pruebas

- `ClaudeStream`: lee el `session_id` del evento `init`; sin `init` no hay ID.
- `ReviewRecord`/`RespondRecord`: un registro sin `sessions` carga; con sesiones, ida y vuelta.
- Carpetas conservadas: se conservan al publicar/pushear; se borran al mergear o cerrar; un trabajo nuevo reemplaza la
  anterior; con un proceso adentro no se borra; Clean Up saltea las que tienen cambios o commits sin pushear.
- `ClaudeSessionCommand`: local y runner, carpetas con espacios y comillas, ID inválido rechazado.
- `TerminalLauncher`: el comando o el archivo que arma para cada terminal (sin abrir nada) y el reemplazo de
  `{dir}`/`{command}` en Custom.
- Paridad UI (`UIActionInventory`): el botón, el ítem del menú, el de History y el picker de Settings, con su comando
  de la CLI.
- Checklist manual (`docs/qa/plan-22-checklist.md`): abrir una sesión de review, de un fix y de Fix CI en cada terminal
  instalada; una de un runner; el botón deshabilitado mientras PRBar trabaja; la carpeta borrada al mergear.
