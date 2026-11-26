# PRBar: Progreso en vivo (qué está haciendo PRBar y Claude)

Fecha: 2026-11-26. Aprobado por el usuario ("perfecto").

## Problema

Mientras corre un trabajo, PRBar muestra solo la fase: "Preparing…", "Reviewing…", "Analyzing…" ("Claude is analyzing
the comments…"), "Implementing…". Una fase puede durar minutos con el mismo texto: no se sabe si PRBar está creando el
worktree, bajando logs o si Claude está leyendo archivos. PRBar ya recibe del stream de Claude cada herramienta que usa
(`ClaudeStreamEvent.toolUse(name:detail:)`, `.agentStarted`), pero solo lo usa el chat.

## LP.1 Qué hace

Cada trabajo en curso (Review, Respond, Fix CI, Resolve Conflicts) muestra, además de la fase, **el paso actual**: un
texto corto que cambia en vivo, con lo que hace PRBar (pasos propios) o Claude (sus herramientas). La fase y sus reglas
(`isActive`, cancelar, notificaciones) no cambian.

## LP.2 Modelo

- `JobActivity` (PRBarCore, `Codable`, `Equatable`, `Sendable`): `kind` (`.prbar` / `.claude`), `text` (ya armado, en
  inglés como el resto de la UI), `startedAt` (cuándo empezó este paso).
- Las colas (`ReviewQueue`, `RespondQueue`) guardan `activity[prID]: JobActivity?` junto a la fase. Se limpia cuando el
  trabajo deja de estar activo (ready, failed, done…).
- Los pipelines reciben un callback `onActivity(JobActivity)` además de `onPhase`. Un cambio de fase no borra el paso:
  el pipeline emite el siguiente.
- **Throttle:** como mucho un cambio cada 0,5 s por PR (el último gana; un paso de PRBar siempre se muestra al menos una
  vez). Implementado en un tipo testeable (`ActivityThrottle`) con reloj inyectable.

## LP.3 Pasos de PRBar

Textos fijos, emitidos por los pipelines en el punto donde ocurre cada cosa:

| Trabajo | Pasos |
|---|---|
| Todos | "Reading the PR on GitHub…", "Writing the context for Claude…" |
| Review | "Creating the PR's folder…" / "Updating the PR's folder to <sha7>…" / "Creating a temporary folder…" (modo solo diff o carpeta no reutilizable), "Reading the previous reviews…" (con memoria), "Filtering the findings…" (etapa 2) |
| Respond | "Reading the comments and their threads…", "Creating the worktree…" / "Updating the worktree…", "Running the tests…", "Committing…", "Pushing…", "Replying on GitHub…" |
| Fix CI | "Reading the failing checks…", "Downloading the CI logs…", "Creating the worktree…", "Running the tests…", "Committing…", "Pushing…" |
| Resolve Conflicts | "Creating the worktree…", "Fetching <base>…", "Merging <base>…", "Checking for conflict markers…", "Committing the merge…", "Pushing…" |
| Host remoto (J) | Los mismos, con " on <runner>" al final cuando el paso corre en el host ("Creating the worktree on build-box…"). |

## LP.4 Pasos de Claude

Mientras corre Claude (cualquier etapa), cada evento del stream se traduce con `ClaudeActivityText`:

- `toolUse(Read, path)` → "Reading <path>"; `Grep`/`Glob` → "Searching for <patrón>"; `Edit`/`Write`/`MultiEdit` →
  "Editing <path>"; `Bash` (solo donde Claude tiene shell) → "Running a command"; `Skill` → "Using the <skill> skill";
  `Task`/`Agent` → "Starting a subagent"; otra herramienta → "Using <name>".
- `agentStarted(total:)` → "Running N subagents".
- `text` → "Thinking…" (el texto de Claude **no** se muestra).
- Al arrancar Claude, antes del primer evento: "Claude is starting…".
- **Rutas:** relativas a la carpeta de trabajo (worktree o `.context`); una ruta fuera de ella se muestra solo con su
  nombre de archivo. Los archivos de contexto se nombran por su rol: `pr.diff` → "the PR's diff", `pr.md` → "the PR's
  description", `previous-reviews.md` → "the previous reviews", `since-last-review.diff` → "the changes since the last
  review".
- **Texto no confiable:** `detail` sale de lo que Claude pidió (rutas, patrones que pueden venir del PR). Se pasa por
  `UntrustedText.singleLine`, se corta a 80 caracteres con "…" y nunca se interpreta (texto plano en todas las UIs).
- Con varios subagentes, cada evento pisa al anterior (es el último que llegó); no se muestra un paso por subagente.

## LP.5 Dónde se ve

- **Popover y ventana principal (fila del PR):** la píldora sigue mostrando la fase; el tooltip y una segunda línea
  pequeña, gris, muestran el paso ("Analyzing · Reading src/shop/tax.py"). Si el paso no entra, se trunca en el medio.
- **Pestañas Review / Respond / Merge de la ventana del PR:** debajo del indicador de progreso, el paso con el tiempo que
  lleva ("Reading src/shop/tax.py · 12 s"), actualizado cada segundo.
- **CLI:** `prbar review|respond|ci|conflicts show` suma una línea "Now: <paso> (<tiempo>)" mientras está activo; con
  `--wait` (y en `prbar review/respond … --wait`) se imprime cada paso nuevo en una línea, en un terminal; sin terminal,
  igual pero sin repetir pasos idénticos seguidos. `--json`: campo `activity` opcional (`kind`, `text`, `startedAt`).
- **Web / iPhone:** `activity` opcional en el estado del job del wire (sin subir la versión del protocolo); la web lo
  muestra debajo de la fase.

## LP.6 Errores y límites

- Un paso que falla no deja texto colgado: al pasar a `failed` el paso se borra (el error ya dice qué falló).
- Cancelar borra el paso.
- Si el stream de Claude no trae eventos (versión vieja de Claude Code), queda "Claude is starting…" hasta el fin de la
  etapa: no es un error.
- Sin persistencia: el paso vive solo en memoria; al reiniciar PRBar no hay trabajos activos.

## LP.7 Fuera de alcance

- Mostrar el texto o razonamiento de Claude.
- Un log/timeline de todos los pasos en la UI (el log de la corrida ya existe).
- Barra de progreso con porcentaje.

## LP.8 Pruebas

- `ClaudeActivityText`: cada herramienta, rutas relativas/fuera de la carpeta, archivos de contexto por rol, corte a 80,
  neutralización.
- `ActivityThrottle`: 0,5 s, el último gana, un paso de PRBar se emite aunque llegue otro enseguida.
- Pipelines (con fakes): el orden de los pasos de PRBar en Review (carpeta nueva, reutilizada, solo diff, con memoria),
  Respond, Fix CI y Resolve Conflicts; " on <runner>" en un host; el paso se borra en ready/failed/cancel.
- Colas: `activity[prID]` sigue al callback y se limpia al terminar.
- CLI: línea "Now:" en `show`, pasos con `--wait`, `activity` en `--json`.
- Wire/web: `activity` opcional y decodificación de un estado viejo; la web lo muestra.
