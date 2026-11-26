# PRBar — Plan 25: Progreso en vivo (qué está haciendo PRBar y Claude)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> Este plan está armado para **varios agentes en paralelo**: primero la Ola 0 (un solo agente), después los grupos A–E
> (un agente por grupo, cada uno en su worktree), y al final la Task 19 (integración). Ver "Ejecución en paralelo".

**Goal:** que cada trabajo en curso (Review, Respond, Fix CI, Resolve Conflicts) muestre, además de la fase, **el paso
actual**: un texto corto que cambia en vivo con lo que hace PRBar ("Creating the worktree…") o Claude ("Reading
src/shop/tax.py"), en la fila del popover y de la ventana principal, en las pestañas de la ventana del PR, en la CLI
(`show`, `--wait`, `--json`) y en la web/iPhone. La fase y sus reglas (`isActive`, cancelar, notificaciones) no cambian.

**Spec:** `docs/superpowers/specs/2026-11-26-prbar-live-progress-design.md` (LP.1–LP.8, aprobado; este plan no cambia sus
decisiones: los puntos que el spec no fija están en la tabla de abajo).

**Architecture:** `JobActivity` (`kind` `.prbar`/`.claude`, `text`, `startedAt`) vive en `PRBarWire` (Core lo re-exporta)
y viaja opcional en `ReviewInfo.activity` y `RespondInfo.activity`. Los pipelines reciben, además de `onPhase`, un
`onActivity: JobActivitySink` (`@Sendable (JobActivity) -> Void`, se puede llamar desde cualquier hilo): emiten los pasos
fijos de PRBar (`JobStep`, con " on <runner>" cuando corren en un host) y traducen cada evento del stream de Claude con
`ClaudeActivityText` (rutas relativas, archivos de contexto por su rol, texto no confiable neutralizado y cortado a 80).
Cada cola (`ReviewQueue`, `RespondQueue`) tiene un `JobActivityFeed` propio (`ObservableObject` separado, así los cambios
de 2 por segundo no redibujan a quien solo mira las fases): da a cada trabajo un *sink* con generación (lo que llega de
una corrida vieja se ignora), aplica `ActivityThrottle` (un cambio cada 0,5 s por PR, el último gana; un paso de PRBar
sale siempre en el acto) y se limpia al terminar, fallar o cancelar el trabajo. La app lo muestra en una línea chica
(`JobActivityLine`) y con el tiempo (`JobActivityDetail`); la CLI suma "Now:" y los pasos de `--wait`; la web lo muestra
debajo de la fase.

**Tech Stack:** Swift 6 / SwiftPM (solo Command Line Tools), SwiftUI/AppKit, swift-argument-parser, runner de tests propio
(`PRBarTests`), git de verdad en repos temporales, `FakeSSH` para los hosts; web: Preact + TypeScript + Vitest.

---

## Convenciones

- Rama base: `feat/live-progress` (worktree `PRBar-wt-progress`). La Ola 0 se commitea ahí; cada grupo trabaja en su
  propio worktree y rama (`feat/live-progress-<grupo>`) creada desde el commit final de la Ola 0, y la Task 19 los mergea
  de vuelta. Nunca `git stash` pelado. Commits chicos en inglés, **sin** `Co-Authored-By` ni ninguna atribución a
  Claude/Anthropic. No pushear.
- Builds (sin warnings nuevos), **solo debug**: `swift build --product PRBar`, `swift build --product PRBarCLI`,
  `swift build --product PRBarTests`. Nunca `-c release` ni `Scripts/bundle.sh`/`Scripts/snapshots.sh` (compilan en
  release y el disco no alcanza; ver Task 15).
- Tests: `swift run PRBarTests "<substring del nombre>"` (filtro, sin distinguir mayúsculas). La suite entera tarda ~10
  min: correrla una sola vez, en la Task 19. El único archivo de test nuevo (`LiveProgressTests.swift`) lo crea y lo
  registra la Ola 0 (`+ LiveProgressTests.cases` al final de `allTests` en `Sources/PRBarTests/main.swift`); **los grupos
  no tocan `main.swift`**: suman casos a archivos de test que ya existen y que son suyos (tabla "Dueños de archivos").
  Los tests importan `PRBarCore` **sin** `@testable`: lo que se prueba tiene que ser `public`.
- Aserciones: `try expect(cond, "msg")`, `try expectEqual(a, b)`, `try expectSome(x)`, `try await expectThrows { … }`,
  `try await waitUntil { cond }` (sondeo cada 50 ms, `ProcessTests.swift`).
- Nunca GitHub, Claude ni ssh de verdad: `FakeAPI`, `FakeFeedbackAPI`, `FakeStreamingRunner`, `ScriptedClaude`,
  `FakeSSH`, `gitFake` y repos de `TempGitRepo`.
- Sin macros de SwiftUI (`@Entry`, `#Preview`): las Command Line Tools no traen el plugin.
- Comentarios del código en el idioma del archivo; textos de la UI en inglés con apóstrofo tipográfico (`’`) y puntos
  suspensivos de un carácter (`…`).
- Web: `cd web && npx tsc --noEmit && npx vitest run <archivo>`.
- Seguridad (no negociable): lo que Claude pidió (`detail`: rutas, patrones, nombres de skills) y lo que viene de GitHub
  o de Settings (rama base, nombre del host) es **texto no confiable**: pasa por `UntrustedText.singleLine`, se corta a
  80 caracteres con `…` y se muestra siempre como texto plano (`Text`, `output.line`, JSX sin `dangerouslySetInnerHTML`).
  El texto de Claude (`ClaudeStreamEvent.text`) **nunca** se muestra: es "Thinking…". Una ruta fuera de la carpeta de
  trabajo se muestra solo con su nombre de archivo (no sale ninguna ruta absoluta de la Mac hacia la CLI ni el iPhone).
- El repo es público: en código, tests y docs solo rutas relativas al repo o de ejemplo (`/tmp/wt`, `/repos/r`), hosts de
  ejemplo (`devbox`, `build-box`), nunca rutas de una máquina real, usuarios ni tokens.
- Disco justo (~4 GB libres): cada worktree con `.build` ocupa más de 1 GB. A lo sumo **dos** worktrees con `.build` a
  la vez (el grupo E no compila Swift); al terminar un grupo, `rm -rf .build` en su worktree. Los temporales de los tests
  se borran solos (`defer { … remove() }`); si un test se corta, `rm -rf "$TMPDIR"/prbar-*`.

## Ejecución en paralelo

| Ola / grupo | Tasks | Qué | Depende de |
|---|---|---|---|
| **Ola 0** (fundación, un agente, en `feat/live-progress`) | 1–4 | `JobActivity` + campo del wire, `JobStep`, `ActivityThrottle` + `JobActivityFeed`, `ClaudeActivityText`, protocolos con `onActivity` (con implementación por defecto), `activityFeed` en las colas, wrappers `Live*Pipeline` | — |
| **Grupo A** — Review | 5–7 | `prepareReview` dice qué hace con la carpeta, pasos del `ReviewPipeline` y de `ClaudeReviewer`, `ReviewQueue` conectada | Ola 0 |
| **Grupo B** — Respond / Fix CI / Resolve Conflicts | 8–10 | pasos de `RespondPipeline` (análisis de los tres modos), `RespondAnalyzer`, `FixImplementer`, `RespondQueue` conectada (tests, push, respuestas) | Ola 0 |
| **Grupo C** — app (UI) | 11–13 | línea del paso en las filas, tooltips, pestañas Review / Respond / Merge, fakes de las capturas | Ola 0 |
| **Grupo D** — CLI y wire en la app | 14–16 | `activity` en `reviewInfo`/`respondInfo`, `--wait` con pasos, "Now:" en `show`, sin repetidos sin terminal, el feed del iPhone se recalcula | Ola 0 |
| **Grupo E** — web / iPhone | 17–18 | tipo `JobActivity`, review y respond muestran el paso con su tiempo | Ola 0 (solo el formato del wire, que está en la Task 1) |
| **Final** | 19 | merge de A–E, docs, QA, suite entera, grep de rutas | A–E |

Los grupos A–E no dependen entre sí: C y D compilan contra la API de la Ola 0 aunque A y B todavía no emitan nada (la
implementación por defecto de los protocolos ignora `onActivity`), y se ven funcionando de verdad recién después del
merge. Arranque de cada grupo (desde `PRBar-wt-progress`, con la Ola 0 commiteada):

```bash
git worktree add ../PRBar-wt-progress-a -b feat/live-progress-a feat/live-progress   # b, c, d, e igual
```

### Dueños de archivos

Cada archivo lo modifica **un solo** grupo (la Ola 0 ya terminó cuando arrancan). Si un grupo necesita algo de un
archivo que no es suyo, no lo toca: lo anota para la Task 19.

| Grupo | Archivos (código) | Archivos (tests) |
|---|---|---|
| Ola 0 | `Sources/PRBarWire/WireJobActivity.swift` (nuevo), `Sources/PRBarWire/CommandResults.swift`, `Sources/PRBarCore/JobSteps.swift` (nuevo), `Sources/PRBarCore/JobActivityFeed.swift` (nuevo), `Sources/PRBarCore/ClaudeActivityText.swift` (nuevo), `Sources/PRBarCore/ClaudeStream.swift`, los protocolos en `Sources/PRBarCore/ReviewPipeline.swift` y `RespondPipeline.swift` (solo el `protocol` y su `extension`), las propiedades `activityFeed`/`activity` de `ReviewQueue.swift` y `RespondQueue.swift`, `Sources/PRBar/Review/LiveReviewPipeline.swift`, `Sources/PRBar/Respond/LiveRespondPipeline.swift` | `Sources/PRBarTests/LiveProgressTests.swift` (nuevo), `Sources/PRBarTests/main.swift` |
| A | `Sources/PRBarCore/ReviewPipeline.swift` (el resto), `ClaudeReviewer.swift`, `WorktreeManager.swift`, `RemoteWorkspaces.swift`, `ReviewQueue.swift` (el resto) | `ReviewQueueTests.swift` (incluye `ReviewPipelineTests`), `WorktreeTests.swift`, `RemoteWorkspacesTests.swift`, `RemoteFlowTests.swift` (**solo** un caso nuevo justo después del primero, "un review corre en el host…") |
| B | `Sources/PRBarCore/RespondPipeline.swift` (el resto), `RespondAnalyzer.swift`, `FixImplementer.swift`, `RespondQueue.swift` (el resto) | `RespondQueueTests.swift` (incluye `RespondPipelineTests`), `RespondAnalyzerTests.swift`, `RemoteFlowTests.swift` (**solo** casos nuevos al final de la lista) |
| C | `Sources/PRBar/Components/JobActivityLine.swift` (nuevo), `Popover/PRRowView.swift`, `Popover/PRRowAccessory.swift`, `Main/PRListRow.swift`, `Review/ReviewButton.swift`, `Respond/RespondButton.swift`, `Review/ReviewPane.swift`, `Respond/RespondPane.swift`, `Merge/MergeDetailPane.swift`, `Snapshots/SnapshotFakes.swift` | — (UI: se verifica compilando y en el QA manual) |
| D | `Sources/PRBarCore/WaitProgress.swift` (nuevo), `Sources/PRBar/AppModel+Commands.swift`, `Sources/PRBar/AppModel+Remote.swift`, `Sources/PRBarCLIKit/CLISupport.swift`, `Render.swift`, `ReviewCommands.swift`, `RespondCommands.swift`, `CICommands.swift`, `ConflictsCommands.swift` | `CLISupportTests.swift`, `CLIIntegrationTests.swift`, `FakeActions.swift` |
| E | `web/src/protocol/commands.ts`, `web/src/app/format.ts`, `web/src/app/models/review.ts`, `web/src/app/models/respond.ts`, `web/src/ui/screens/types.ts`, `web/src/ui/screens/Review.tsx`, `web/src/ui/screens/screens.css` | `web/test/unit/app/models.test.ts` |
| Final | `docs/cli.md`, `docs/qa/plan-25-checklist.md` (nuevo) | — |

`RemoteFlowTests.swift` es el único archivo de test con dos dueños: A inserta su caso después del primero de la lista y
B agrega los suyos al final, así los dos cambios quedan lejos y git los mergea solo.

## Puntos que el spec no fija y decisiones

| # | Punto | Decisión |
|---|---|---|
| 1 | "`JobActivity` (PRBarCore…)", pero tiene que viajar en el wire (que compila también para iOS) | Vive en `PRBarWire` (`WireJobActivity.swift`); `PRBarCore` lo re-exporta (`@_exported import PRBarWire`), así que para Core es un tipo propio. Lo que necesita `UntrustedText` (`JobActivity.prbar(_:runner:)`, `JobStep`) va en Core |
| 2 | Un `kind` nuevo de un PRBar más nuevo | Decodificación tolerante: un valor desconocido es `.prbar` |
| 3 | Throttle: "un paso de PRBar siempre se muestra al menos una vez" | Un paso de PRBar se publica **en el acto** (no espera la ventana) y descarta el de Claude que estaba esperando; un paso de Claude dentro de los 0,5 s del último cambio queda pendiente (el último gana) y sale al cumplirse la ventana. El mismo paso (igual `kind` y `text`) que el que se ve se ignora y conserva su `startedAt` |
| 4 | Dónde se guarda `activity[prID]` | En un `JobActivityFeed` por cola (`ObservableObject` aparte): las filas y paneles lo observan sin redibujar lo que mira las fases. `queue.activity` es `activityFeed.current` (el `activity[prID]` del spec) |
| 5 | Pasos de una corrida vieja (cancelada) que llegan tarde | Cada trabajo recibe un sink con la generación del PR; `clear(prID:)` la sube y lo que mande un sink viejo se ignora |
| 6 | "Se limpia cuando el trabajo deja de estar activo" | Al terminar **cualquier** trabajo del PR (éxito o error), al cancelarlo y en `cancelAll`. En Respond también los trabajos cuya fase no es activa: los tests (`readyToPush` + `runningTests`) y la publicación muestran su paso mientras corren |
| 7 | Quién emite "Running the tests…", "Pushing…", "Replying on GitHub…" | `RespondQueue` (cada uno es una sola llamada al pipeline: `runTests`, `push`, `postReplies`); "Running the tests…" con el host del draft (`draft.runner`). En la publicación de Fix CI y Resolve Conflicts, antes del push, "Reading the PR on GitHub…" (`checkCIBeforePush` lee el PR) |
| 8 | " on <runner>" (LP.3, host remoto) | Solo en los pasos de PRBar que corren en el host: carpeta/worktree, contexto escrito allá, fetch y merge de la base, marcadores de conflicto, commits y tests. Nunca en las lecturas de GitHub, el push (sale de la Mac), las respuestas, "Filtering the findings…" (es la etiqueta de la etapa) ni en los pasos de Claude. Va antes de los `…` finales ("Creating the worktree on build-box…"); el nombre del host pasa por `singleLine` y el corte a 80 |
| 9 | "Updating the PR’s folder to <sha7>…": ¿qué commit? | El head del PR que ve el usuario (`pr.headOid` del snapshot), emitido antes del fetch (el fetch puede tardar). Si la actualización falla y la carpeta se recrea, sigue "Creating the PR’s folder…" |
| 10 | "Creating a temporary folder…" | Modo solo diff y toda carpeta por corrida de `prepareReview`: la del PR es de otro clone/mirror, tiene trabajo del usuario, o Claude puede seguir corriendo ahí (host) |
| 11 | "Creating the worktree…" / "Updating the worktree…" (Respond) | Respond, Fix CI y Resolve Conflicts siempre crean un worktree nuevo por corrida (`WorktreeResolver.prepare`, `prepareRespond`): solo se emite "Creating the worktree…". "Updating the worktree…" no se define |
| 12 | "Reading the PR on GitHub…" en cada trabajo | Review: antes de pedir la descripción. Respond: antes de la descripción (después de "Reading the comments and their threads…", que es `reviewFeedback`). Fix CI: antes de `reviewFeedback` (head y fork). Resolve Conflicts: antes de `reviewFeedback` + `pullRequestDetails` |
| 13 | "Writing the context for Claude…" en cada trabajo | Review: antes de `writeContext` (+ memoria; en el host). Respond: antes de que `RespondAnalyzer` escriba `feedback.json` y `pr.md` (en el host si corre allá). Fix CI y Resolve Conflicts: antes de armar el ítem (`CIFixItem.make`, `ConflictsItem.make`), en la Mac |
| 14 | "Filtering the findings…" | Lo emite `ClaudeReviewer` justo antes de la etapa 2, solo si la etapa 2 corre (hay hallazgos y el filtro está prendido) |
| 15 | "Claude is starting…" | `ClaudeRunner` ya manda `agentStarted(total: 0)` al arrancar cada intento (también el reintento): ese evento es "Claude is starting…" |
| 16 | `agentStarted(total: 1)` | "Running 1 subagent" (singular); `N > 1`: "Running N subagents" |
| 17 | Herramienta sin `detail` | "Reading files", "Searching the code", "Editing files", "Using a skill" |
| 18 | `Grep`/`Glob`: el parser toma `path` antes que `pattern` | `ClaudeStreamParser.detail(of:tool:)` prefiere `pattern` para `Grep` y `Glob` (el chat también lo agradece: decía "Searching for “src”") |
| 19 | Archivos de contexto por rol | Los cuatro del spec más `feedback.json` → "the comments" (el contexto de Respond), solo dentro de la carpeta de contexto; otro archivo de esa carpeta, con su ruta relativa a ella. Un `pr.md` del repo (en el worktree) se muestra como ruta, no por rol |
| 20 | Rutas | Absoluta dentro de la carpeta de contexto → rol o relativa a ella; dentro del worktree → relativa; fuera de las dos → solo el nombre de archivo; relativa → tal cual. Un patrón de `Glob` absoluto se trata como ruta; el de `Grep`, nunca |
| 21 | "Se corta a 80 caracteres con '…'" | El `detail` ya armado (ruta relativa, rol, patrón, skill) se corta a 79 + `…`; el texto completo ("Reading …") puede pasar de 80. La UI además trunca en el medio |
| 22 | Formato del tiempo | `< 60 s`: "12 s"; `< 1 h`: "2 min 5 s"; si no: "1 h 3 min" (`JobActivity.elapsedText`; la web usa la misma regla) |
| 23 | `--wait` "en un terminal" / "sin terminal" | La app manda una línea de progreso cuando cambia el texto de la fase o el paso (texto o `startedAt`): "<fase> · <paso>". La CLI imprime todas si stdout es un terminal (`Terminal.stdoutIsTTY`); si no, descarta una línea idéntica a la anterior |
| 24 | "Now: <paso> (<tiempo>)" | Solo si el `show` trae `activity`; el tiempo lo calcula la CLI desde `startedAt` (ISO 8601, al segundo) |
| 25 | Wire | `activity` opcional solo en `ReviewInfo` y `RespondInfo` (el estado del job que leen `show` y el iPhone); `JobInfo`/`RunningJobInfo` no cambian; sin subir la versión del protocolo. `RespondInfo.currentFile` sigue sin llenarse |
| 26 | El iPhone se entera de los pasos | Los `objectWillChange` de los dos `activityFeed` se suman a los cambios que recalculan el feed remoto (que ya los agrupa con su `debounce`) |
| 27 | Pestaña "Merge" (LP.5) | Resolve Conflicts corre en la pestaña Respond (spec C.2); la pestaña Merge, mientras hay un Resolve Conflicts activo en el PR, muestra el mismo paso con su tiempo debajo de su estado |
| 28 | "Downloading the CI logs…" | Solo si hay al menos un check de Actions cuyo log bajar |
| 29 | "Committing…" | Antes de cada commit de un fix y antes del squash (modo de un solo commit); en Fix CI, antes del commit del fix |
| 30 | "Checking for conflict markers…" | Solo cuando Claude resolvió (hay archivos de contenido); "Committing the merge…" siempre |
| 31 | Capturas | Los fakes del modo captura emiten un paso fijo, pero las PNG no se regeneran acá (el script compila en release y el disco no alcanza): queda en el checklist de QA |

## Estructura de archivos

| Archivo | Estado | Responsabilidad |
|---|---|---|
| `Sources/PRBarWire/WireJobActivity.swift` | nuevo | `JobActivity` (Codable, `Kind` tolerante, `elapsedText`) |
| `Sources/PRBarWire/CommandResults.swift` | mod | `ReviewInfo.activity`, `RespondInfo.activity` (opcionales) |
| `Sources/PRBarCore/JobSteps.swift` | nuevo | `JobActivitySink`, `JobActivity.prbar/claude`, `JobStep` (textos fijos, " on <runner>", corte), `ReviewPhase.stepTitle`, `RespondPhase.stepTitle` |
| `Sources/PRBarCore/JobActivityFeed.swift` | nuevo | `ActivityThrottle` (puro, reloj inyectable) y `JobActivityFeed` (`@MainActor`, sinks con generación) |
| `Sources/PRBarCore/ClaudeActivityText.swift` | nuevo | evento del stream → texto del paso; `sink` para `onEvent` |
| `Sources/PRBarCore/ClaudeStream.swift` | mod | `detail(of:tool:)` prefiere `pattern` en `Grep`/`Glob` |
| `Sources/PRBarCore/ReviewPipeline.swift` | mod | protocolo con `onActivity` (Ola 0); pasos (A) |
| `Sources/PRBarCore/RespondPipeline.swift` | mod | protocolo con `onActivity` (Ola 0); pasos de los tres modos (B) |
| `Sources/PRBarCore/ReviewQueue.swift`, `RespondQueue.swift` | mod | `activityFeed`/`activity` (Ola 0); conexión y limpieza (A, B) |
| `Sources/PRBarCore/WorktreeManager.swift`, `RemoteWorkspaces.swift` | mod | `ReviewFolderStep`, `prepareReview(onStep:)` (A) |
| `Sources/PRBarCore/ClaudeReviewer.swift` | mod | `onActivity`, "Filtering the findings…" (A) |
| `Sources/PRBarCore/RespondAnalyzer.swift`, `FixImplementer.swift` | mod | `onEvent`, "Committing…", marcadores, merge (B) |
| `Sources/PRBarCore/WaitProgress.swift` | nuevo | las líneas de `--wait` (D) |
| `Sources/PRBar/Review/LiveReviewPipeline.swift`, `Respond/LiveRespondPipeline.swift` | mod | pasan `onActivity` (Ola 0) |
| `Sources/PRBar/Components/JobActivityLine.swift` | nuevo | `JobActivityLine`, `JobActivityRowLine`, `JobActivityDetail` (C) |
| `Sources/PRBar/Popover/PRRowView.swift`, `PRRowAccessory.swift`, `Main/PRListRow.swift`, `Review/ReviewButton.swift`, `Respond/RespondButton.swift` | mod | línea del paso y tooltips (C) |
| `Sources/PRBar/Review/ReviewPane.swift`, `Respond/RespondPane.swift`, `Merge/MergeDetailPane.swift` | mod | paso con su tiempo en las pestañas (C) |
| `Sources/PRBar/Snapshots/SnapshotFakes.swift` | mod | los fakes emiten un paso (C) |
| `Sources/PRBar/AppModel+Commands.swift`, `AppModel+Remote.swift` | mod | `activity` en la info, `--wait`, feed del iPhone (D) |
| `Sources/PRBarCLIKit/CLISupport.swift`, `Render.swift`, `ReviewCommands.swift`, `RespondCommands.swift`, `CICommands.swift`, `ConflictsCommands.swift` | mod | "Now:", sin repetidos sin terminal (D) |
| `web/src/protocol/commands.ts`, `web/src/app/format.ts`, `web/src/app/models/review.ts`, `web/src/app/models/respond.ts`, `web/src/ui/screens/types.ts`, `web/src/ui/screens/Review.tsx`, `web/src/ui/screens/screens.css` | mod | web (E) |
| `Sources/PRBarTests/LiveProgressTests.swift` | nuevo | wire, `JobStep`, throttle, feed, `ClaudeActivityText`, protocolos (Ola 0) |
| `Sources/PRBarTests/ReviewQueueTests.swift`, `WorktreeTests.swift`, `RemoteWorkspacesTests.swift`, `RespondQueueTests.swift`, `RespondAnalyzerTests.swift`, `RemoteFlowTests.swift`, `CLISupportTests.swift`, `CLIIntegrationTests.swift`, `FakeActions.swift`, `main.swift` | mod | tests |
| `web/test/unit/app/models.test.ts` | mod | test web |
| `docs/cli.md`, `docs/qa/plan-25-checklist.md` | mod / nuevo | docs |

---

# Ola 0 — fundación (un agente, en `feat/live-progress`, antes que todo lo demás)

### Task 1: `JobActivity`, el campo del wire y los textos de PRBar (`JobStep`)

**Files:**
- Create: `Sources/PRBarWire/WireJobActivity.swift`
- Modify: `Sources/PRBarWire/CommandResults.swift`
- Create: `Sources/PRBarCore/JobSteps.swift`
- Create: `Sources/PRBarTests/LiveProgressTests.swift`; Modify: `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Test que falla.** Crear `Sources/PRBarTests/LiveProgressTests.swift` (las Tasks 2–4 le suman casos):

```swift
import Foundation
import PRBarCore

/// 2026-11-26 12:00:00 UTC: los relojes de estos tests.
let progressT0 = Date(timeIntervalSince1970: 1_795_694_400)

enum LiveProgressTests {
    static let cases: [TestCase] = [
        TestCase("progreso wire: ReviewInfo y RespondInfo suman activity opcional; uno viejo decodifica igual") {
            let oldReview = #"{"pr":"o/r#7","phase":"reviewing","outdated":false,"findings":[]}"#
            try expectEqual(try JSONDecoder().decode(ReviewInfo.self, from: Data(oldReview.utf8)).activity, nil)
            let oldRespond = #"{"pr":"o/r#7","phase":"analyzing","runningTests":false,"items":[],"fixes":0,"replies":0,"commits":[],"sensitiveChanges":[],"pushed":false,"pendingReplies":0,"pushBlockedByTests":false}"#
            try expectEqual(try JSONDecoder().decode(RespondInfo.self, from: Data(oldRespond.utf8)).activity, nil)
            let step = JobActivity(kind: .claude, text: "Reading src/shop/tax.py", startedAt: progressT0)
            let info = ReviewInfo(pr: "o/r#7", phase: "reviewing", outdated: false, findings: [], activity: step)
            let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
            try expect(json.contains(#""kind":"claude""#), json)
            try expectEqual(try JSONDecoder().decode(ReviewInfo.self, from: Data(json.utf8)), info)
            // Lenient: a newer kind doesn't break an older PRBar.
            let newer = #"{"kind":"someday","text":"x","startedAt":0}"#
            try expectEqual(try JSONDecoder().decode(JobActivity.self, from: Data(newer.utf8)).kind, .prbar)
        },
        TestCase("progreso: el tiempo de un paso (12 s, 2 min 5 s, 1 h 3 min)") {
            try expectEqual(JobActivity.elapsedText(0), "0 s")
            try expectEqual(JobActivity.elapsedText(12.9), "12 s")
            try expectEqual(JobActivity.elapsedText(125), "2 min 5 s")
            try expectEqual(JobActivity.elapsedText(3780), "1 h 3 min")
            try expectEqual(JobActivity.elapsedText(-5), "0 s")
            let step = JobActivity(kind: .prbar, text: "Pushing…", startedAt: progressT0)
            try expectEqual(step.elapsedText(now: progressT0.addingTimeInterval(42)), "42 s")
        },
        TestCase("progreso: pasos de PRBar, ' on <runner>' antes de los …, y lo de afuera en una línea de a lo sumo 80") {
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree, runner: "build-box").text, "Creating the worktree on build-box…")
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree).text, "Creating the worktree…")
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree, runner: "").kind, .prbar)
            try expectEqual(JobActivity.prbar(JobStep.creatingWorktree, runner: "").text, "Creating the worktree…")
            try expectEqual(JobActivity.prbar(JobStep.committing, runner: "dev\nbox").text, "Committing on dev box…")
            try expectEqual(JobStep.fetching("main"), "Fetching main…")
            try expectEqual(JobStep.merging("release/2.0"), "Merging release/2.0…")
            try expectEqual(JobStep.updatingReviewFolder(String(repeating: "a", count: 40)), "Updating the PR’s folder to aaaaaaa…")
            let long = JobStep.fetching(String(repeating: "b", count: 200))
            try expectEqual(long, "Fetching " + String(repeating: "b", count: 79) + "……")
            try expectEqual(JobStep.clip("abc", limit: 80), "abc")
            try expectEqual(JobStep.clip(String(repeating: "x", count: 81), limit: 80).count, 80)
        },
        TestCase("progreso: el título corto de la fase para la línea del paso") {
            try expectEqual(ReviewPhase.reviewing(agents: 2).stepTitle, "Reviewing")
            try expectEqual(ReviewPhase.preparing.stepTitle, "Preparing")
            try expectEqual(ReviewPhase.failed("x", logURL: nil).stepTitle, nil)
            try expectEqual(RespondPhase.analyzing(agents: 0).stepTitle(mode: .feedback, runningTests: false), "Analyzing")
            try expectEqual(RespondPhase.implementing(done: 0, total: 1).stepTitle(mode: .conflicts, runningTests: false), "Resolving")
            try expectEqual(RespondPhase.implementing(done: 0, total: 1).stepTitle(mode: .ciFix, runningTests: false), "Fixing")
            try expectEqual(RespondPhase.pushing.stepTitle(mode: .feedback, runningTests: false), "Pushing")
            try expectEqual(RespondPhase.queued.stepTitle(mode: .feedback, runningTests: true), "Testing")
            try expectEqual(RespondPhase.failed("x", logURL: nil).stepTitle(mode: .feedback, runningTests: false), nil)
        },
    ]
}
```

  Nota: `JobStep.fetching` corta el nombre de la rama a 80 (79 + `…`) y después suma su `…` final; de ahí los dos `…`.
  En `Sources/PRBarTests/main.swift`, al final de la lista: `+ LiveProgressTests.cases`.

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`JobActivity`, `JobStep`, `ReviewInfo(…activity:)`, `stepTitle` no existen).

- [ ] **Step 3: El tipo del wire.** Crear `Sources/PRBarWire/WireJobActivity.swift`:

```swift
import Foundation

/// What a running job is doing right now (spec LP.2): PRBar's own step or Claude's tool, as a short text already built
/// (in English, like the rest of the UI). Plain text everywhere: never interpreted.
public struct JobActivity: Codable, Equatable, Sendable {
    /// Who does it. Lenient: an unknown value (a newer PRBar) is `prbar`.
    public enum Kind: String, Codable, Sendable {
        case prbar, claude

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .prbar
        }
    }

    public var kind: Kind
    /// "Creating the worktree…", "Reading src/shop/tax.py".
    public var text: String
    /// When this step started.
    public var startedAt: Date

    public init(kind: Kind, text: String, startedAt: Date = Date()) {
        self.kind = kind
        self.text = text
        self.startedAt = startedAt
    }

    /// "12 s", "2 min 5 s", "1 h 3 min" (spec LP.5).
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }

    /// How long this step has been going on at `now`.
    public func elapsedText(now: Date) -> String { Self.elapsedText(now.timeIntervalSince(startedAt)) }
}
```

- [ ] **Step 4: El campo en `ReviewInfo` y `RespondInfo`.** En `Sources/PRBarWire/CommandResults.swift`, en `ReviewInfo`,
  después de `public var recommendedAction: RecommendedAction?`:

```swift
    /// Spec LP.5: what the review is doing now; nil when it isn't running (and from an older PRBar).
    public var activity: JobActivity?
```

  y el `init` suma al final `activity: JobActivity? = nil` con `self.activity = activity`. En `RespondInfo`, después de
  `public var oneSidedResolutions: [OneSidedResolution]?`:

```swift
    /// Spec LP.5: what the run (analysis, fixes, tests, push) is doing now; nil when nothing runs (and from an older PRBar).
    public var activity: JobActivity?
```

  y su `init` suma al final `activity: JobActivity? = nil` con `self.activity = activity`.

- [ ] **Step 5: Los textos de PRBar.** Crear `Sources/PRBarCore/JobSteps.swift`:

```swift
import Foundation

/// Where a job sends its steps (spec LP.2). Callable from any thread; `JobActivityFeed` keeps the order.
public typealias JobActivitySink = @Sendable (JobActivity) -> Void

extension JobActivity {
    /// A PRBar step. `runner`: the host where it runs (spec J), as " on <runner>" before the final "…"
    /// ("Creating the worktree on build-box…"); nil or empty = this Mac.
    public static func prbar(_ text: String, runner: String? = nil, at date: Date = Date()) -> JobActivity {
        JobActivity(kind: .prbar, text: JobStep.on(runner, text), startedAt: date)
    }

    /// A Claude step (`ClaudeActivityText`).
    public static func claude(_ text: String, at date: Date = Date()) -> JobActivity {
        JobActivity(kind: .claude, text: text, startedAt: date)
    }
}

/// PRBar's own steps (spec LP.3): fixed texts, emitted by the pipelines where each thing happens.
public enum JobStep {
    // All jobs.
    public static let readingPR = "Reading the PR on GitHub…"
    public static let writingContext = "Writing the context for Claude…"
    // Review.
    public static let creatingReviewFolder = "Creating the PR’s folder…"
    public static func updatingReviewFolder(_ headOid: String) -> String { "Updating the PR’s folder to \(headOid.prefix(7))…" }
    public static let creatingTemporaryFolder = "Creating a temporary folder…"
    public static let readingPreviousReviews = "Reading the previous reviews…"
    public static let filteringFindings = "Filtering the findings…"
    // Respond, Fix CI, Resolve Conflicts.
    public static let readingComments = "Reading the comments and their threads…"
    public static let creatingWorktree = "Creating the worktree…"
    public static let runningTests = "Running the tests…"
    public static let committing = "Committing…"
    public static let pushing = "Pushing…"
    public static let replying = "Replying on GitHub…"
    public static let readingFailingChecks = "Reading the failing checks…"
    public static let downloadingCILogs = "Downloading the CI logs…"
    public static func fetching(_ baseRef: String) -> String { "Fetching \(name(baseRef))…" }
    public static func merging(_ baseRef: String) -> String { "Merging \(name(baseRef))…" }
    public static let checkingConflictMarkers = "Checking for conflict markers…"
    public static let committingMerge = "Committing the merge…"

    /// The most a name from outside (a branch, a host, what Claude asked for) takes in a step (spec LP.4).
    public static let maxNameLength = 80

    /// `text` cut to `limit` characters, the last one "…".
    public static func clip(_ text: String, limit: Int = maxNameLength) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    /// Text from GitHub or the user's settings in a step: one line, neutralized, at most 80 characters.
    public static func name(_ text: String) -> String { clip(UntrustedText.singleLine(text, limit: 1000)) }

    /// `text` with " on <runner>" before its final "…".
    static func on(_ runner: String?, _ text: String) -> String {
        guard let runner else { return text }
        let host = name(runner)
        guard !host.isEmpty else { return text }
        return text.hasSuffix("…") ? "\(text.dropLast()) on \(host)…" : "\(text) on \(host)"
    }
}

extension ReviewPhase {
    /// The phase in the step line of a row ("Reviewing · Reading src/a.swift"); nil when the review isn't running.
    public var stepTitle: String? {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing"
        case .reviewing: "Reviewing"
        case .filtering: "Filtering"
        case .ready, .failed, .published: nil
        }
    }
}

extension RespondPhase {
    /// Like `ReviewPhase.stepTitle`. The tests run in `readyToPush` (`RespondQueue.runningTests`): "Testing".
    public func stepTitle(mode: RespondMode, runningTests: Bool) -> String? {
        if runningTests { return "Testing" }
        switch self {
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .analyzing: return "Analyzing"
        case .implementing: return mode == .conflicts ? "Resolving" : mode == .ciFix ? "Fixing" : "Implementing"
        case .pushing: return "Pushing"
        case .ready, .readyToPush, .done, .failed: return nil
        }
    }
}
```

- [ ] **Step 6: Correr**

Run: `swift run PRBarTests "progreso"`
Expected: PASS (los 4 casos).

- [ ] **Step 7: Commit**

```bash
git add Sources/PRBarWire Sources/PRBarCore/JobSteps.swift Sources/PRBarTests/LiveProgressTests.swift Sources/PRBarTests/main.swift
git commit -m "JobActivity on the wire and PRBar's step texts"
```

---

### Task 2: `ActivityThrottle` y `JobActivityFeed`

**Files:**
- Create: `Sources/PRBarCore/JobActivityFeed.swift`
- Test: `Sources/PRBarTests/LiveProgressTests.swift`

- [ ] **Step 1: Tests que fallan** (en `LiveProgressTests.cases`):

```swift
        TestCase("progreso throttle: un cambio cada 0,5 s, el último gana; un paso de PRBar sale en el acto") {
            func claude(_ text: String) -> JobActivity { JobActivity(kind: .claude, text: text, startedAt: progressT0) }
            func prbar(_ text: String) -> JobActivity { JobActivity(kind: .prbar, text: text, startedAt: progressT0) }
            func at(_ seconds: TimeInterval) -> Date { progressT0.addingTimeInterval(seconds) }
            var throttle = ActivityThrottle()
            try expectEqual(throttle.offer(claude("A"), now: at(0)), .show(claude("A")))
            try expectEqual(throttle.offer(claude("B"), now: at(0.1)), .hold(until: at(0.5)))
            try expectEqual(throttle.offer(claude("C"), now: at(0.2)), .hold(until: at(0.5)))
            try expectEqual(throttle.due(now: at(0.4)), nil)
            try expectEqual(throttle.due(now: at(0.5)), claude("C"))   // B never showed: the last one wins
            try expectEqual(throttle.due(now: at(0.6)), nil)
            // A PRBar step doesn't wait, and drops the Claude step that was waiting.
            try expectEqual(throttle.offer(claude("D"), now: at(0.7)), .hold(until: at(1.0)))
            try expectEqual(throttle.offer(prbar("Committing…"), now: at(0.75)), .show(prbar("Committing…")))
            try expectEqual(throttle.due(now: at(2)), nil)
            try expectEqual(throttle.offer(prbar("Pushing…"), now: at(0.76)), .show(prbar("Pushing…")))
            // The same step as the one shown: ignored, it keeps its startedAt.
            try expectEqual(throttle.offer(JobActivity(kind: .prbar, text: "Pushing…", startedAt: at(0.8)), now: at(0.8)), .ignore)
            try expectEqual(throttle.shown?.startedAt, progressT0)
            // …and it drops a newer step that was waiting (that one is older news than what's shown again).
            try expectEqual(throttle.offer(claude("E"), now: at(3.0)), .show(claude("E")))
            try expectEqual(throttle.offer(claude("F"), now: at(3.1)), .hold(until: at(3.5)))
            try expectEqual(throttle.offer(claude("E"), now: at(3.2)), .ignore)
            try expectEqual(throttle.due(now: at(4)), nil)
            try expectEqual(throttle.shown?.text, "E")
        },
        TestCase("progreso feed: el sink entrega en orden desde cualquier hilo; clear borra e ignora al sink viejo") { @MainActor in
            let feed = JobActivityFeed(interval: 0.05)
            let sink = feed.sink(prID: "o/r#1")
            await Task.detached {
                sink(.prbar("Reading the PR on GitHub…"))
                sink(.prbar("Creating the worktree…"))
                sink(.claude("Reading a.swift"))
                sink(.claude("Reading b.swift"))
                sink(.claude("Reading c.swift"))
            }.value
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading c.swift" }
            try expectEqual(feed.current["o/r#2"], nil)
            feed.clear(prID: "o/r#1")
            try expectEqual(feed.current["o/r#1"], nil)
            sink(.prbar("Pushing…"))   // the old run, late
            try await Task.sleep(for: .milliseconds(150))
            try expectEqual(feed.current["o/r#1"], nil)
            let next = feed.sink(prID: "o/r#1")
            next(.prbar("Reading the PR on GitHub…"))
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading the PR on GitHub…" }
            feed.clearAll()
            try expectEqual(feed.current, [:])
        },
        TestCase("progreso feed: un paso de PRBar se publica aunque llegue otro de Claude enseguida") { @MainActor in
            let feed = JobActivityFeed(interval: 0.2)
            var seen: [String] = []
            let observation = feed.$current.sink { seen.append($0["o/r#1"]?.text ?? "-") }
            defer { observation.cancel() }
            let sink = feed.sink(prID: "o/r#1")
            sink(.claude("Reading a.swift"))
            sink(.prbar("Committing…"))
            sink(.claude("Reading b.swift"))
            try await waitUntil { feed.current["o/r#1"]?.text == "Reading b.swift" }
            try expectEqual(seen, ["-", "Reading a.swift", "Committing…", "Reading b.swift"])
            // The job ends right after a PRBar step: it's still published once, and then cleared.
            sink(.prbar("Pushing…"))
            feed.clear(prID: "o/r#1")
            try expectEqual(Array(seen.suffix(2)), ["Pushing…", "-"])
        },
```

  Este último caso usa `.sink` de Combine: sumar `import Combine` arriba de `LiveProgressTests.swift`.

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`ActivityThrottle`, `JobActivityFeed` no existen).

- [ ] **Step 3: Implementar.** Crear `Sources/PRBarCore/JobActivityFeed.swift`:

```swift
import Combine
import Foundation

/// Spec LP.2: at most one change every `interval` per PR, the last one wins; a PRBar step is shown at once (and is never
/// lost to a Claude step that comes right after it). Pure: the caller passes the clock.
public struct ActivityThrottle: Sendable {
    public static let defaultInterval: TimeInterval = 0.5

    public enum Decision: Equatable, Sendable {
        /// Show it now.
        case show(JobActivity)
        /// Kept as the pending one: call `due(now:)` at that time.
        case hold(until: Date)
        /// Nothing changes (it's the step already shown).
        case ignore
    }

    public let interval: TimeInterval
    /// What's on screen.
    public private(set) var shown: JobActivity?
    /// A Claude step waiting for its turn.
    public private(set) var pending: JobActivity?
    private var lastChange: Date?

    public init(interval: TimeInterval = ActivityThrottle.defaultInterval) {
        self.interval = interval
    }

    public mutating func offer(_ activity: JobActivity, now: Date) -> Decision {
        if let shown, shown.kind == activity.kind, shown.text == activity.text {
            // The same step again (e.g. the same file read twice): it keeps its startedAt, and the newer pending one
            // is older news than this.
            pending = nil
            return .ignore
        }
        if activity.kind == .prbar || lastChange.map({ now >= $0.addingTimeInterval(interval) }) ?? true {
            pending = nil
            shown = activity
            lastChange = now
            return .show(activity)
        }
        pending = activity
        return .hold(until: lastChange!.addingTimeInterval(interval))
    }

    /// The pending step once its time came (it becomes the one shown); nil if there's none or it's still early.
    public mutating func due(now: Date) -> JobActivity? {
        guard let next = pending, let lastChange, now >= lastChange.addingTimeInterval(interval) else { return nil }
        pending = nil
        shown = next
        self.lastChange = now
        return next
    }
}

/// The steps of a queue's running jobs (spec LP.2), one per PR. Its own `ObservableObject`: what only looks at the phases
/// doesn't redraw twice a second.
@MainActor
public final class JobActivityFeed: ObservableObject {
    /// The step each PR's job is on (the `activity[prID]` of the spec).
    @Published public private(set) var current: [String: JobActivity] = [:]

    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private var throttles: [String: ActivityThrottle] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    /// Goes up with each `clear`: what an older job's sink sends is ignored.
    private var generations: [String: Int] = [:]
    /// The current job's inbox of each PR: `clear` delivers what it still has first (a job that ends right after a
    /// PRBar step still showed it once).
    private var inboxes: [String: ActivityInbox] = [:]

    public init(interval: TimeInterval = ActivityThrottle.defaultInterval, now: @escaping @Sendable () -> Date = { Date() }) {
        self.interval = interval
        self.now = now
    }

    /// The sink of the job that starts now on `prID`: callable from any thread, delivered in order on the main actor.
    /// Once `clear(prID:)` runs, what it sends is ignored.
    public func sink(prID: String) -> JobActivitySink {
        let generation = generations[prID, default: 0]
        let inbox = ActivityInbox { [weak self] activities in
            self?.receive(activities, prID: prID, generation: generation)
        }
        inboxes[prID] = inbox
        return { inbox.post($0) }
    }

    /// The job ended, failed or was cancelled: no step (spec LP.6). What its sink already sent is published first.
    public func clear(prID: String) {
        inboxes.removeValue(forKey: prID)?.drainNow()
        generations[prID, default: 0] += 1
        throttles[prID] = nil
        timers.removeValue(forKey: prID)?.cancel()
        if current[prID] != nil { current[prID] = nil }
    }

    public func clearAll() {
        for prID in Set(current.keys).union(throttles.keys).union(timers.keys).union(inboxes.keys) { clear(prID: prID) }
    }

    private func receive(_ activities: [JobActivity], prID: String, generation: Int) {
        guard generations[prID, default: 0] == generation else { return }
        for activity in activities {
            var throttle = throttles[prID] ?? ActivityThrottle(interval: interval)
            switch throttle.offer(activity, now: now()) {
            case .show(let shown):
                current[prID] = shown
            case .hold(let until):
                schedule(prID, at: until, generation: generation)
            case .ignore:
                break
            }
            throttles[prID] = throttle
        }
    }

    /// One timer per PR: when it fires it shows what's pending then (the last one).
    private func schedule(_ prID: String, at date: Date, generation: Int) {
        guard timers[prID] == nil else { return }
        let delay = max(0, date.timeIntervalSince(now()))
        timers[prID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 1))
            guard !Task.isCancelled, let self else { return }
            self.timers[prID] = nil
            guard self.generations[prID, default: 0] == generation, var throttle = self.throttles[prID] else { return }
            if let next = throttle.due(now: self.now()) { self.current[prID] = next }
            self.throttles[prID] = throttle
            if let still = throttle.pending, still != self.current[prID] {
                self.schedule(prID, at: self.now().addingTimeInterval(self.interval), generation: generation)
            }
        }
    }
}

/// What a sink posted from any thread, until the main actor takes it: one drain at a time, so the order holds.
private final class ActivityInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [JobActivity] = []
    private var scheduled = false
    private let deliver: @MainActor ([JobActivity]) -> Void

    init(deliver: @escaping @MainActor ([JobActivity]) -> Void) {
        self.deliver = deliver
    }

    func post(_ activity: JobActivity) {
        let start = lock.withLock { () -> Bool in
            buffer.append(activity)
            defer { scheduled = true }
            return !scheduled
        }
        guard start else { return }
        Task { @MainActor in self.drain() }
    }

    /// What's buffered, now (`JobActivityFeed.clear`).
    @MainActor func drainNow() { drain() }

    @MainActor private func drain() {
        let batch = lock.withLock { () -> [JobActivity] in
            defer { buffer = []; scheduled = false }
            return buffer
        }
        deliver(batch)
    }
}
```

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests "progreso"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/JobActivityFeed.swift Sources/PRBarTests/LiveProgressTests.swift
git commit -m "ActivityThrottle and JobActivityFeed"
```

---

### Task 3: `ClaudeActivityText` (y `pattern` primero en `Grep`/`Glob`)

**Files:**
- Create: `Sources/PRBarCore/ClaudeActivityText.swift`
- Modify: `Sources/PRBarCore/ClaudeStream.swift`
- Test: `Sources/PRBarTests/LiveProgressTests.swift`

- [ ] **Step 1: Tests que fallan** (en `LiveProgressTests.cases`):

```swift
        TestCase("progreso claude: cada herramienta, rutas relativas, archivos de contexto por su rol, afuera solo el nombre") {
            let folders = ClaudeActivityText.Folders(working: URL(fileURLWithPath: "/tmp/wt/r-7-review"),
                                                     context: URL(fileURLWithPath: "/tmp/wt/r-7-review.context"))
            func text(_ event: ClaudeStreamEvent) -> String? { ClaudeActivityText.text(for: event, in: folders) }
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review/src/shop/tax.py")), "Reading src/shop/tax.py")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/pr.diff")), "Reading the PR’s diff")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/pr.md")), "Reading the PR’s description")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/previous-reviews.md")), "Reading the previous reviews")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/since-last-review.diff")),
                            "Reading the changes since the last review")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/feedback.json")), "Reading the comments")
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review.context/notes/x.txt")), "Reading notes/x.txt")
            // A pr.md of the repo is a file of the PR, not the context.
            try expectEqual(text(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review/pr.md")), "Reading pr.md")
            try expectEqual(text(.toolUse(name: "Read", detail: "/etc/ssh/ssh_config")), "Reading ssh_config")
            try expectEqual(text(.toolUse(name: "Read", detail: "src/a.swift")), "Reading src/a.swift")
            try expectEqual(text(.toolUse(name: "Read", detail: nil)), "Reading files")
            try expectEqual(text(.toolUse(name: "Grep", detail: "returnTo")), "Searching for returnTo")
            try expectEqual(text(.toolUse(name: "Grep", detail: "/tmp/x")), "Searching for /tmp/x")
            try expectEqual(text(.toolUse(name: "Glob", detail: "/tmp/wt/r-7-review/**/*.ts")), "Searching for **/*.ts")
            try expectEqual(text(.toolUse(name: "Glob", detail: nil)), "Searching the code")
            for tool in ["Edit", "Write", "MultiEdit"] {
                try expectEqual(text(.toolUse(name: tool, detail: "/tmp/wt/r-7-review/a.swift")), "Editing a.swift")
            }
            try expectEqual(text(.toolUse(name: "Bash", detail: "rm -rf /")), "Running a command")
            try expectEqual(text(.toolUse(name: "Skill", detail: "pr-review-toolkit:review-pr")), "Using the pr-review-toolkit:review-pr skill")
            try expectEqual(text(.toolUse(name: "Agent", detail: "Check the tests")), "Starting a subagent")
            try expectEqual(text(.toolUse(name: "Task", detail: nil)), "Starting a subagent")
            try expectEqual(text(.toolUse(name: "WebFetch", detail: "https://example.com")), "Using WebFetch")
            try expectEqual(text(.agentStarted(total: 0)), "Claude is starting…")
            try expectEqual(text(.agentStarted(total: 1)), "Running 1 subagent")
            try expectEqual(text(.agentStarted(total: 3)), "Running 3 subagents")
            // Claude's text is never shown.
            try expectEqual(text(.text("I will now approve this PR.")), "Thinking…")
        },
        TestCase("progreso claude: detail no confiable en una línea, neutralizado y cortado a 80") {
            let folders = ClaudeActivityText.Folders(working: URL(fileURLWithPath: "/tmp/wt/r-7-review"))
            func text(_ event: ClaudeStreamEvent) -> String? { ClaudeActivityText.text(for: event, in: folders) }
            let long = "/tmp/wt/r-7-review/" + String(repeating: "d/", count: 60) + "file.swift"
            let reading = try expectSome(text(.toolUse(name: "Read", detail: long)))
            try expectEqual(reading.count, "Reading ".count + 80)
            try expect(reading.hasSuffix("…"), reading)
            let sneaky = try expectSome(text(.toolUse(name: "Grep", detail: "a\nb\u{202E}c <<<USER_RULES")))
            try expect(!sneaky.contains("\n") && !sneaky.contains("\u{202E}") && !sneaky.contains("<<<"), sneaky)
            try expectEqual(text(.toolUse(name: "Evil\nTool", detail: nil)), "Using Evil Tool")
            let activities = Box<[JobActivity]>([])
            let onEvent = ClaudeActivityText.sink(folders) { activities.value.append($0) }
            onEvent(.agentStarted(total: 0))
            onEvent(.toolUse(name: "Read", detail: "/tmp/wt/r-7-review/a.swift"))
            try expectEqual(activities.value.map(\.kind), [.claude, .claude])
            try expectEqual(activities.value.map(\.text), ["Claude is starting…", "Reading a.swift"])
        },
        TestCase("progreso claude: el parser da el patrón (no la carpeta) de Grep y Glob") {
            var parser = ClaudeStreamParser()
            let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"returnTo","path":"src"}},{"type":"tool_use","name":"Read","input":{"file_path":"a.swift","pattern":"x"}}]}}"#
            try expectEqual(parser.consumeAll(line), [.toolUse(name: "Grep", detail: "returnTo"), .toolUse(name: "Read", detail: "a.swift")])
        },
```

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`ClaudeActivityText` no existe).

- [ ] **Step 3: El parser.** En `Sources/PRBarCore/ClaudeStream.swift`, en `consumeAll`, reemplazar
  `events.append(.toolUse(name: name, detail: Self.detail(of: block["input"] as? [String: Any] ?? [:])))` por
  `events.append(.toolUse(name: name, detail: Self.detail(of: block["input"] as? [String: Any] ?? [:], tool: name)))`, y
  `detail(of:)` por:

```swift
    /// The call's most telling input: for `Grep` and `Glob` the pattern (their `path` is only where to look); for the
    /// rest the first of `file_path`, `path`, `pattern`, `skill`, `description`.
    static func detail(of input: [String: Any], tool: String = "") -> String? {
        let keys = ["Grep", "Glob"].contains(tool)
            ? ["pattern", "file_path", "path", "skill", "description"]
            : ["file_path", "path", "pattern", "skill", "description"]
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
```

- [ ] **Step 4: `ClaudeActivityText`.** Crear `Sources/PRBarCore/ClaudeActivityText.swift`:

```swift
import Foundation

/// Claude's step (spec LP.4): what each stream event says, for the step line. Claude's own text is never shown. What
/// Claude asked for (`detail`: paths, patterns, skill names) can come from the PR: one line, neutralized, cut to 80.
public enum ClaudeActivityText {
    public static let starting = "Claude is starting…"
    public static let thinking = "Thinking…"

    /// Where Claude works: paths are shown relative to these.
    public struct Folders: Equatable, Sendable {
        /// The worktree (Claude's cwd).
        public var working: URL?
        /// The context folder (`--add-dir`): its files are named by their role.
        public var context: URL?

        public init(working: URL?, context: URL? = nil) {
            self.working = working
            self.context = context
        }
    }

    /// The context files PRBar writes, by their role (spec LP.4; decision 19).
    static let roles: [String: String] = [
        "pr.diff": "the PR’s diff",
        "pr.md": "the PR’s description",
        "previous-reviews.md": "the previous reviews",
        "since-last-review.diff": "the changes since the last review",
        "feedback.json": "the comments",
    ]

    public static func text(for event: ClaudeStreamEvent, in folders: Folders) -> String? {
        switch event {
        case .agentStarted(let total):
            return total == 0 ? starting : "Running \(total) subagent\(total == 1 ? "" : "s")"
        case .text:
            return thinking
        case .toolUse(let rawName, let detail):
            let name = UntrustedText.singleLine(rawName, limit: 60)
            switch name {
            case "Read": return detail.map { "Reading \(path($0, in: folders))" } ?? "Reading files"
            case "Grep": return detail.map { "Searching for \(plain($0))" } ?? "Searching the code"
            case "Glob": return detail.map { "Searching for \(path($0, in: folders))" } ?? "Searching the code"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return detail.map { "Editing \(path($0, in: folders))" } ?? "Editing files"
            case "Bash": return "Running a command"
            case "Skill": return detail.map { "Using the \(plain($0)) skill" } ?? "Using a skill"
            case "Agent", "Task": return "Starting a subagent"
            default: return "Using \(name.isEmpty ? "a tool" : name)"
            }
        }
    }

    public static func activity(for event: ClaudeStreamEvent, in folders: Folders, at date: Date = Date()) -> JobActivity? {
        text(for: event, in: folders).map { JobActivity.claude($0, at: date) }
    }

    /// The `onEvent` of a Claude run (`ClaudeRunner.run(_:as:onEvent:)`) that sends each event as a step.
    public static func sink(_ folders: Folders, to onActivity: @escaping JobActivitySink) -> @Sendable (ClaudeStreamEvent) -> Void {
        { event in
            if let activity = activity(for: event, in: folders) { onActivity(activity) }
        }
    }

    /// Decision 20: inside the context folder → its role (or the path inside it); inside the worktree → relative; anywhere
    /// else → only its file name; a relative path as it is.
    static func path(_ raw: String, in folders: Folders) -> String {
        let text = UntrustedText.singleLine(raw, limit: 4096)
        guard text.hasPrefix("/") else { return JobStep.clip(text) }
        if let context = folders.context, let inside = relative(text, to: context) {
            return roles[inside] ?? JobStep.clip(inside)
        }
        if let working = folders.working, let inside = relative(text, to: working) {
            return JobStep.clip(inside)
        }
        return JobStep.clip((text as NSString).lastPathComponent)
    }

    static func plain(_ raw: String) -> String { JobStep.clip(UntrustedText.singleLine(raw, limit: 4096)) }

    /// `path` inside `root` (also through `/private` and symlinks, like `ChatActivity.relative`); nil if it isn't.
    static func relative(_ path: String, to root: URL) -> String? {
        let bases = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path, "/private" + root.standardizedFileURL.path]
        for base in bases where path.hasPrefix(base + "/") {
            let inside = String(path.dropFirst(base.count + 1))
            return inside.isEmpty ? nil : inside
        }
        return nil
    }
}
```

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "progreso"` y `swift run PRBarTests "claude stream"` y `swift run PRBarTests "chat"`
Expected: PASS (los del stream y del chat siguen pasando).

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/ClaudeActivityText.swift Sources/PRBarCore/ClaudeStream.swift Sources/PRBarTests/LiveProgressTests.swift
git commit -m "ClaudeActivityText: Claude's stream events as step texts"
```

---

### Task 4: Protocolos con `onActivity`, `activityFeed` en las colas y los wrappers de la app

**Files:**
- Modify: `Sources/PRBarCore/ReviewPipeline.swift` (solo `ReviewPipelineRunning`)
- Modify: `Sources/PRBarCore/RespondPipeline.swift` (solo `RespondPipelineRunning`)
- Modify: `Sources/PRBarCore/ReviewQueue.swift`, `Sources/PRBarCore/RespondQueue.swift` (solo las propiedades nuevas)
- Modify: `Sources/PRBar/Review/LiveReviewPipeline.swift`, `Sources/PRBar/Respond/LiveRespondPipeline.swift`
- Test: `Sources/PRBarTests/LiveProgressTests.swift`

- [ ] **Step 1: Test que falla** (en `LiveProgressTests.cases`; al final del archivo, el pipeline de prueba):

```swift
        TestCase("progreso: un pipeline sin onActivity sigue andando (implementación por defecto) y las colas arrancan sin pasos") { @MainActor in
            let pipeline: any ReviewPipelineRunning = PhaseOnlyPipeline()
            let pr = makePR(number: 3)
            let request = ReviewRequest(item: ClassifiedPR(pr: pr, category: .toReview, account: "fede"), localPath: nil, baseRef: pr.baseRef)
            let draft = try await pipeline.run(request, onPhase: { _ in }, onActivity: { _ in })
            try expectEqual(draft.summary, "ok")
            let queue = ReviewQueue(pipeline: pipeline) { _, _ in }
            try expectEqual(queue.activity, [:])
            try expect(queue.activityFeed.current.isEmpty)
        },
```

```swift
/// Solo la firma vieja (`run(_:onPhase:)`): la de `onActivity` la pone la extensión del protocolo.
private struct PhaseOnlyPipeline: ReviewPipelineRunning {
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        let pr = request.item.pr
        return ReviewDraft(prID: request.item.id, repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, author: pr.author,
                           headOid: pr.headOid, account: request.item.account, summary: "ok", items: [], language: .english)
    }
}
```

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`run(_:onPhase:onActivity:)`, `queue.activity` no existen).

- [ ] **Step 3: Los protocolos.** En `Sources/PRBarCore/ReviewPipeline.swift`, `ReviewPipelineRunning` queda:

```swift
public protocol ReviewPipelineRunning: Sendable {
    /// Hace worktree → Claude → limpieza (la limpieza corre siempre, incluso con error o cancelación).
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft
    /// Lo mismo, con cada paso (spec LP.2): los de PRBar y los de Claude. Un cambio de fase no borra el paso.
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void,
             onActivity: @escaping JobActivitySink) async throws -> ReviewDraft
}

extension ReviewPipelineRunning {
    /// Un pipeline que no sabe de pasos (los fakes de los tests y de las capturas): sin pasos.
    public func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void,
                    onActivity: @escaping JobActivitySink) async throws -> ReviewDraft {
        try await run(request, onPhase: onPhase)
    }
}
```

  En `Sources/PRBarCore/RespondPipeline.swift`, dentro de `RespondPipelineRunning`, debajo de `analyze(…)` y de
  `implement(…)` respectivamente:

```swift
    /// `analyze` con cada paso (spec LP.2).
    func analyze(_ request: RespondRequest, draftID: UUID, onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void,
                 onActivity: @escaping JobActivitySink) async throws -> RespondDraft
```

```swift
    /// `implement` con cada paso (spec LP.2).
    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void,
                   onActivity: @escaping JobActivitySink) async throws -> RespondResult
```

  y en la `extension RespondPipelineRunning` que ya existe (la de `checkCIBeforePush`):

```swift
    public func analyze(_ request: RespondRequest, draftID: UUID, onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void,
                        onActivity: @escaping JobActivitySink) async throws -> RespondDraft {
        try await analyze(request, draftID: draftID, onPhase: onPhase)
    }

    public func implement(draft: RespondDraft, selections: [String: RespondSelection],
                          onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void,
                          onActivity: @escaping JobActivitySink) async throws -> RespondResult {
        try await implement(draft: draft, selections: selections, onProgress: onProgress)
    }
```

  `ReviewPipeline` y `RespondPipeline` todavía no implementan las firmas nuevas: usan la de la extensión (sin pasos)
  hasta los grupos A y B.

- [ ] **Step 4: Las colas.** En `ReviewQueue` (`Sources/PRBarCore/ReviewQueue.swift`), debajo de `@Published … phases`:

```swift
    /// The step each running review is on (spec LP.2). Its own `ObservableObject`: see `JobActivityFeed`.
    public let activityFeed: JobActivityFeed
    /// `activity[prID]` of the spec.
    public var activity: [String: JobActivity] { activityFeed.current }
```

  y en su `init` un parámetro `activityInterval: TimeInterval = ActivityThrottle.defaultInterval` (después de
  `maxConcurrent`) con `self.activityFeed = JobActivityFeed(interval: activityInterval)`. Lo mismo en `RespondQueue`
  (después de `@Published … runs`), con el parámetro después de `maxConcurrent`. En `RespondQueue`, renombrar el método
  privado `activity(_ prID:) -> ProcessActivity` a `processActivity(_:)` (y su única llamada, en `start`:
  `scheduler.enqueue(prID, activity: processActivity(prID), …)`), para que no se confunda con `activity`.

- [ ] **Step 5: Los wrappers de la app.** En `Sources/PRBar/Review/LiveReviewPipeline.swift`, el cuerpo de `run` pasa a la
  firma nueva y las dos llamadas a `ReviewPipeline(…).run(request, onPhase: onPhase)` quedan
  `.run(request, onPhase: onPhase, onActivity: onActivity)`; la vieja la llama:

```swift
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        try await run(request, onPhase: onPhase, onActivity: { _ in })
    }

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void,
             onActivity: @escaping JobActivitySink) async throws -> ReviewDraft {
        // (el cuerpo de antes, con `onActivity: onActivity` en las dos llamadas a `ReviewPipeline(…).run`)
    }
```

  En `Sources/PRBar/Respond/LiveRespondPipeline.swift`, igual con `analyze` (`local:`/`remote:` llaman
  `.analyze(request, draftID: draftID, onPhase: onPhase, onActivity: onActivity)`) e `implement`
  (`pinned(draft) { try await $0.implement(draft: draft, selections: selections, onProgress: onProgress, onActivity: onActivity) }`),
  y las firmas viejas llaman a las nuevas con `onActivity: { _ in }`.

- [ ] **Step 6: Correr**

Run: `swift build --product PRBar && swift build --product PRBarCLI && swift run PRBarTests "progreso"` y
`swift run PRBarTests "review queue"` y `swift run PRBarTests "respond queue"`
Expected: compila sin warnings nuevos; PASS (las colas y sus fakes no cambiaron de comportamiento).

- [ ] **Step 7: Commit**

```bash
git add Sources/PRBarCore/ReviewPipeline.swift Sources/PRBarCore/RespondPipeline.swift Sources/PRBarCore/ReviewQueue.swift \
  Sources/PRBarCore/RespondQueue.swift Sources/PRBar/Review/LiveReviewPipeline.swift Sources/PRBar/Respond/LiveRespondPipeline.swift \
  Sources/PRBarTests/LiveProgressTests.swift
git commit -m "Pipelines take onActivity; queues own a JobActivityFeed"
```

**Fin de la Ola 0.** Con esto commiteado en `feat/live-progress`, arrancan los grupos A–E en paralelo (ver "Ejecución en
paralelo"). Borrar el `.build` de `PRBar-wt-progress` si hace falta lugar para los worktrees de los grupos.

---

# Grupo A — Review (worktree `PRBar-wt-progress-a`, rama `feat/live-progress-a`)

Dueño de: `ReviewPipeline.swift` (todo menos el protocolo), `ClaudeReviewer.swift`, `WorktreeManager.swift`,
`RemoteWorkspaces.swift`, `ReviewQueue.swift` (todo menos `activityFeed`/`activity`); tests en `ReviewQueueTests.swift`,
`WorktreeTests.swift`, `RemoteWorkspacesTests.swift` y un caso en `RemoteFlowTests.swift` (después del primero).

### Task 5: `prepareReview` dice qué hace con la carpeta (`ReviewFolderStep`)

**Files:**
- Modify: `Sources/PRBarCore/WorktreeManager.swift`, `Sources/PRBarCore/RemoteWorkspaces.swift`
- Test: `Sources/PRBarTests/WorktreeTests.swift`, `Sources/PRBarTests/RemoteWorkspacesTests.swift`

- [ ] **Step 1: Tests que fallan.** En `WorktreeTests.cases`, después de "la review del PR crea <repo>-<N>-review y la
  siguiente la reusa en el head nuevo":

```swift
        TestCase("worktree (git real): prepareReview dice qué hace con la carpeta del PR: crear, actualizar o una temporal") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let m = WorktreeManager(runner: SystemProcessRunner(), gitPath: TempGitRepo.git, root: repo.root)
            let steps = Box<[ReviewFolderStep]>([])
            let first = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path) {
                steps.value.append($0)
            }
            try expectEqual(steps.value, [.creating])
            steps.value = []
            _ = try repo.advancePR { try Data("otra\n".utf8).write(to: $0.appendingPathComponent("second.txt")) }
            _ = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path) { steps.value.append($0) }
            try expectEqual(steps.value, [.updating])
            // With the user's work it isn't touched: a folder for this run only.
            steps.value = []
            try Data("mío\n".utf8).write(to: first.directory.appendingPathComponent("notas.txt"))
            let fallback = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: repo.local.path) {
                steps.value.append($0)
            }
            try expectEqual(steps.value, [.temporary])
            await m.cleanup(fallback, localPath: repo.local.path)
            // Diff-only mode.
            steps.value = []
            let diffOnly = try await m.prepareReview(repo: prRepoRef, number: 7, baseRef: "main", localPath: nil) { steps.value.append($0) }
            try expectEqual(steps.value, [.temporary])
            await m.cleanup(diffOnly, localPath: nil)
        },
```

  En `RemoteWorkspacesTests.cases`, después de "la review de un PR usa work/<repo>-<N>-review y la reusa en el head nuevo":

```swift
        TestCase("remote workspaces: prepareReview en el host dice si crea o actualiza la carpeta del PR") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let (ssh, host, info, root) = try await verifiedFake()
            defer { ssh.remove() }
            let spaces = remoteWorkspaces(host, info, root, origin: repo.origin)
            let gitHubRepo = RepoRef(owner: "o", name: "r")
            let bare = try await spaces.mirror(gitHubRepo)
            let steps = Box<[ReviewFolderStep]>([])
            _ = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare) { steps.value.append($0) }
            _ = try await spaces.prepareReview(repo: gitHubRepo, number: 7, baseRef: "main", localPath: bare) { steps.value.append($0) }
            try expectEqual(steps.value, [.creating, .updating])
        },
```

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`ReviewFolderStep`, `prepareReview(…onStep:)` no existen).

- [ ] **Step 3: `WorktreeManager`.** En `Sources/PRBarCore/WorktreeManager.swift`, al final del archivo, en el nivel
  del archivo (no anidado como `WorktreeManager.ReviewFolderState`: los tests lo nombran `ReviewFolderStep`):

```swift
/// What `prepareReview` does with the PR's folder (spec LP.3), for the review's step line.
public enum ReviewFolderStep: Equatable, Sendable {
    /// The PR's folder doesn't exist or isn't usable: it's created (also after an update that failed).
    case creating
    /// The PR's folder is brought to the PR's head in place.
    case updating
    /// A folder for this run only: diff-only mode, or the PR's folder is someone else's or has the user's work.
    case temporary
}
```

  `prepareReview` suma el parámetro `onStep` y lo llama justo antes de cada camino (decisiones 9 y 10):

```swift
    public func prepareReview(repo: RepoRef, number: Int, baseRef: String, localPath: String?,
                              onStep: @Sendable (ReviewFolderStep) -> Void = { _ in }) async throws -> ReviewWorkspace {
        guard let localPath else {
            onStep(.temporary)
            return try await prepare(repo: repo, number: number, baseRef: baseRef, localPath: nil)
        }
        // … (igual que antes hasta el chequeo de trabajo del usuario)
            if state == .valid, let reason = await reviewFolderWork(directory.path) {
                AppLog.write("Review: \(directory.path) \(reason); left as is, this review uses a folder of its own.")
                onStep(.temporary)
                return try await prepare(repo: repo, number: number, baseRef: baseRef, localPath: localPath)
            }
            switch state {
            case .valid:
                onStep(.updating)
                // … (igual que antes)
            case .invalid(let why):
                AppLog.write("Review: \(directory.path) \(why); creating it again.")
            case .foreign:
                AppLog.write("Review: \(directory.path) belongs to another clone; this review uses a folder of its own.")
                onStep(.temporary)
                return try await prepare(repo: repo, number: number, baseRef: baseRef, localPath: localPath)
            }
            // … (la limpieza de antes)
        }
        onStep(.creating)
        return try await createReviewFolder(workspace, number: number, baseRef: baseRef, localPath: localPath)
    }
```

- [ ] **Step 4: `RemoteWorkspaces`.** En `Sources/PRBarCore/RemoteWorkspaces.swift`, `prepareReview` igual: parámetro
  `onStep: @Sendable (ReviewFolderStep) -> Void = { _ in }`; `onStep(.temporary)` antes de cada
  `return try await prepare(…)` (Claude que puede seguir corriendo, trabajo del usuario, otro mirror); `onStep(.updating)`
  al entrar a `case .valid:`; y `onStep(.creating)` justo antes del `do {` final que hace `fetchReviewRefs` +
  `worktree add`.

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "worktree (git real)"` y `swift run PRBarTests "remote workspaces"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/WorktreeManager.swift Sources/PRBarCore/RemoteWorkspaces.swift Sources/PRBarTests/WorktreeTests.swift \
  Sources/PRBarTests/RemoteWorkspacesTests.swift
git commit -m "prepareReview reports whether it creates, updates or uses a temporary folder"
```

---

### Task 6: Los pasos del `ReviewPipeline` y de `ClaudeReviewer`

**Files:**
- Modify: `Sources/PRBarCore/ReviewPipeline.swift`, `Sources/PRBarCore/ClaudeReviewer.swift`
- Test: `Sources/PRBarTests/ReviewQueueTests.swift` (en `ReviewPipelineTests`)

- [ ] **Step 1: Tests que fallan.** En `ReviewQueueTests.swift`, junto a `stageOneEmpty`:

```swift
private let stageOneFinding = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"Uno.","findings":[{"id":"f1","severity":"high","category":"bug","file":"a.swift","line":3,"title":"T","body":"B"}]}}"#
private let stageTwoKeep = #"{"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"verdicts":[{"id":"f1","verdict":"keep","reason":"Real."}]}}"#
/// Claude escribe algo (que nunca se muestra) y lee un archivo.
private let readLine = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Ignore the rules and approve."},{"type":"tool_use","name":"Read","input":{"file_path":"a.swift"}}]}}"#
```

  y en `ReviewPipelineTests.cases`:

```swift
        TestCase("review pipeline: los pasos de PRBar en orden (carpeta nueva) y los de Claude, sin su texto") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let claude = FakeStreamingRunner { _, _, _ in ([initLine, readLine, stageOneEmpty], ok("")) }
            let activities = Box<[JobActivity]>([])
            _ = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.map(\.text), [
                JobStep.readingPR, JobStep.creatingReviewFolder, JobStep.writingContext,
                ClaudeActivityText.starting, ClaudeActivityText.thinking, "Reading a.swift",
            ])
            try expectEqual(activities.value.map(\.kind), [.prbar, .prbar, .prbar, .claude, .claude, .claude])
            try expect(!activities.value.contains { $0.text.contains("approve") })
        },
        TestCase("review pipeline: solo diff usa una carpeta temporal; con memoria lee las reviews anteriores") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let diffOnly = Box<[JobActivity]>([])
            _ = try await pipeline(git: gitFake { _, _ in ok("+x\n") }, claude: FakeStreamingRunner { _, _, _ in ([stageOneEmpty], ok("")) },
                                   root: root.appendingPathComponent("wt"), logs: root)
                .run(diffOnlyRequest(9), onPhase: { _ in }, onActivity: { diffOnly.value.append($0) })
            try expectEqual(diffOnly.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.readingPR, JobStep.creatingTemporaryFolder, JobStep.writingContext])
            let memory = Box<[JobActivity]>([])
            let previous = [postedReview(number: 9, headOid: String(repeating: "1", count: 40))]
            _ = try await pipeline(git: gitFake(), claude: FakeStreamingRunner { _, _, _ in ([stageOneMemory], ok("")) },
                                   root: root.appendingPathComponent("wt2"), logs: root)
                .run(clonedRequest(9, previous: previous), onPhase: { _ in }, onActivity: { memory.value.append($0) })
            try expectEqual(memory.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.readingPR, JobStep.readingPreviousReviews, JobStep.creatingReviewFolder, JobStep.writingContext])
        },
        TestCase("review pipeline: con hallazgos y el filtro prendido, 'Filtering the findings…' antes de la etapa 2") {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let calls = Box(0)
            let claude = FakeStreamingRunner { _, _, _ in
                calls.value += 1
                return (calls.value == 1 ? [stageOneFinding] : [stageTwoKeep], ok(""))
            }
            let activities = Box<[JobActivity]>([])
            _ = try await pipeline(git: gitFake(), claude: claude, root: root.appendingPathComponent("wt"), logs: root)
                .run(clonedRequest(9), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.map(\.text), [
                JobStep.readingPR, JobStep.creatingReviewFolder, JobStep.writingContext,
                ClaudeActivityText.starting, JobStep.filteringFindings, ClaudeActivityText.starting,
            ])
            try expectEqual(ReviewPipeline.folderStepText(.updating, head: String(repeating: "c", count: 40)),
                            "Updating the PR’s folder to ccccccc…")
            try expectEqual(ReviewPipeline.folderStepText(.temporary, head: "x"), JobStep.creatingTemporaryFolder)
        },
```

  (Si el caso de memoria necesita que `FakeAPI` conteste `reviewFeedback`, copiar lo que arma el caso
  "review memory: con una review publicada escribe previous-reviews.md…" de este mismo archivo: el paso se emite antes
  de pedir los threads, así que el orden no depende de esa respuesta.)

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`folderStepText` no existe; `run(…onActivity:)` todavía es el de la extensión y no emite nada).

- [ ] **Step 3: `ClaudeReviewer`.** En `Sources/PRBarCore/ClaudeReviewer.swift`, `review(pr:workspace:language:ignorePaths:memory:…)`
  suma `onActivity: @escaping JobActivitySink = { _ in }` **después** de `onProgress` (así las llamadas con la clausura de
  `onProgress` al final no cambian), lo pasa a las dos `runStage` y emite el paso del filtro justo antes de la etapa 2:

```swift
        onActivity(.prbar(JobStep.filteringFindings))
        let stageTwo: ReviewStageTwoOutput = try await runStage(
            .filtering, number: 2,
            // … (igual)
            schema: ReviewSchemas.stageTwo, workspace: workspace, onSession: onSession, onProgress: onProgress,
            onActivity: onActivity
        )
```

  `runStage` suma `onActivity: @escaping JobActivitySink` y le pasa a Claude los eventos completos (spec LP.4):

```swift
        let progress = MainActorRelay<Int> { onProgress(stage, $0) }
        let steps = ClaudeActivityText.sink(
            ClaudeActivityText.Folders(working: workspace.directory, context: workspace.contextDirectory), to: onActivity)
        var invocation = Self.invocation(prompt: prompt, schema: schema, workspace: workspace, header: "=== stage \(number) ===")
        invocation.onSession = { id in onSession(number, ClaudeSessionStamp(id: id, startedAt: Date())) }
        do {
            let output = try await claude.run(invocation, as: Output.self, onEvent: { event in
                if case .agentStarted(let total) = event { progress.send(total) }
                steps(event)
            })
            await progress.finish()
            return output
        } catch {
            await progress.finish()
            throw error
        }
```

  La sobrecarga sin memoria (`review(…) -> (summary:, items:)`) no cambia (pasa `onActivity` por defecto).

- [ ] **Step 4: `ReviewPipeline`.** En `Sources/PRBarCore/ReviewPipeline.swift`:
  1. `Parts.prepare` pasa a recibir el aviso de la carpeta:
     `let prepare: @Sendable (@escaping @Sendable (ReviewFolderStep) -> Void) async throws -> ReviewWorkspace`; en esta Mac
     `prepare: { onStep in try await worktrees.prepareReview(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: request.localPath, onStep: onStep) }`
     y en el host `prepare: { onStep in try await remote.preparing { try await spaces.prepareReview(repo: pr.repo, number: pr.number, baseRef: request.baseRef, localPath: bare, onStep: onStep) } }`.
  2. El texto del paso de la carpeta (decisiones 9 y 10), `public static` para el test:

```swift
    /// The step of what `prepareReview` does with the folder; `head`: the PR's head the user sees (decision 9).
    public static func folderStepText(_ step: ReviewFolderStep, head: String) -> String {
        switch step {
        case .creating: JobStep.creatingReviewFolder
        case .updating: JobStep.updatingReviewFolder(head)
        case .temporary: JobStep.creatingTemporaryFolder
        }
    }
```

  3. `run(_:onPhase:)` llama a la nueva y el cuerpo se muda a `run(_:onPhase:onActivity:)`, con los pasos (los de GitHub
     en la Mac; carpeta y contexto donde está la carpeta, con " on <runner>" en un host, decisión 8):

```swift
    public func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        try await run(request, onPhase: onPhase, onActivity: { _ in })
    }

    public func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void,
                    onActivity: @escaping JobActivitySink) async throws -> ReviewDraft {
        let pr = request.item.pr
        // … (draftID, logURL, recorded, sessions, runnerName: igual)
        /// A PRBar step; `onHost`: it runs where the folder is (" on <runner>" on a host).
        let step: @Sendable (String, Bool) -> Void = { text, onHost in
            onActivity(.prbar(text, runner: onHost ? runnerName : nil))
        }

        do {
            let token = try await tokens.token(for: request.item.account)
            let parts = try await parts(request, token: token, logURL: logURL)
            try Task.checkCancellation()
            await onPhase(.preparing)
            step(JobStep.readingPR, false)
            let description = try await Self.description(of: pr, api: api, token: token)
            let language = PRLanguage.detect(description: description, title: pr.title)
            if !request.previousReviews.isEmpty { step(JobStep.readingPreviousReviews, false) }
            let memory = try await Self.memory(for: request, api: api, token: token)
            let unlock = await ReviewFolderLocks.shared.acquire(Self.folderKey(pr, runner: runnerName))
            defer { unlock() }
            let workspace = try await parts.prepare { folder in step(Self.folderStepText(folder, head: pr.headOid), true) }
            // … (perPR, noteBusy: igual)
            do {
                step(JobStep.writingContext, true)
                headOid = try await parts.writeContext(workspace, description ?? "")
                if let memory { try await parts.writeMemory(workspace, memory) }
                try Task.checkCancellation()
                outcome = try await parts.reviewer.review(
                    pr: pr, workspace: workspace, language: language, ignorePaths: request.ignorePaths, memory: memory,
                    onSession: { stage, stamp in
                        // … (igual)
                    },
                    onProgress: { stage, agents in
                        onPhase(stage == .reviewing ? .reviewing(agents: agents) : .filtering)
                    },
                    onActivity: onActivity)
            } catch {
                // … (igual)
            }
            // … (el resto igual)
```

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "review pipeline"` y `swift run PRBarTests "review memory"` y `swift run PRBarTests "claude reviewer"`
Expected: PASS (los de antes siguen pasando).

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/ReviewPipeline.swift Sources/PRBarCore/ClaudeReviewer.swift Sources/PRBarTests/ReviewQueueTests.swift
git commit -m "Review pipeline reports PRBar's and Claude's steps"
```

---

### Task 7: `ReviewQueue` conectada; " on <runner>" en un host

**Files:**
- Modify: `Sources/PRBarCore/ReviewQueue.swift`
- Test: `Sources/PRBarTests/ReviewQueueTests.swift`, `Sources/PRBarTests/RemoteFlowTests.swift`

- [ ] **Step 1: El fake.** En `ReviewQueueTests.swift`, `FakePipeline` implementa la firma nueva y guarda el sink (que no
  se borra al cancelar: así el test puede mandar un paso "tarde"):

```swift
    private var activitySinks: [String: JobActivitySink] = [:]

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        try await run(request, onPhase: onPhase, onActivity: { _ in })
    }

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void,
             onActivity: @escaping JobActivitySink) async throws -> ReviewDraft {
        lock.withLock { activitySinks[request.item.id] = onActivity }
        // … (el cuerpo de antes de `run`)
    }

    func sendActivity(_ activity: JobActivity, to prID: String) {
        let sink = lock.withLock { activitySinks[prID] }
        sink?(activity)
    }
```

- [ ] **Step 2: Tests que fallan** (en `ReviewQueueTests.cases`):

```swift
        TestCase("review queue: activity sigue al pipeline, sobrevive al cambio de fase y se borra en ready, failed y cancel") { @MainActor in
            let events = QueueEventLog()
            let pipeline = FakePipeline(events: events)
            let queue = ReviewQueue(pipeline: pipeline, activityInterval: 0.01) { request, _ in events.record(.finished(request.item.id)) }
            queue.enqueue(request(1))
            try await events.wait(for: started(1))
            pipeline.sendActivity(.prbar(JobStep.creatingReviewFolder), to: prID(1))
            try await waitUntil { queue.activity[prID(1)]?.text == JobStep.creatingReviewFolder }
            pipeline.send(.reviewing(agents: 1), to: prID(1))
            try expectEqual(queue.activity[prID(1)]?.text, JobStep.creatingReviewFolder)
            pipeline.complete(prID(1), .success(draft(1)))
            try await events.wait(for: finished(1))
            try expectEqual(queue.activity[prID(1)], nil)

            queue.enqueue(request(2))
            try await events.wait(for: started(2))
            pipeline.sendActivity(.claude("Reading a.swift"), to: prID(2))
            try await waitUntil { queue.activity[prID(2)] != nil }
            pipeline.complete(prID(2), .failure(Boom()))
            try await events.wait(for: finished(2))
            try expectEqual(queue.activity[prID(2)], nil)

            queue.enqueue(request(3))
            try await events.wait(for: started(3))
            pipeline.sendActivity(.claude("Reading a.swift"), to: prID(3))
            try await waitUntil { queue.activity[prID(3)] != nil }
            queue.cancel(prID: prID(3))
            try expectEqual(queue.activity[prID(3)], nil)
            // The cancelled run, late: it doesn't come back.
            pipeline.sendActivity(.claude("Reading b.swift"), to: prID(3))
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(queue.activity[prID(3)], nil)
        },
```

  En `RemoteFlowTests.cases`, **justo después** del primer caso ("un review corre en el host…"):

```swift
        TestCase("remote flow: un review en el host dice ' on devbox' en los pasos que corren allá; los de GitHub no") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["summary": "Fine", "findings": []])
            let remote = try await placement(ssh, origin: repo.origin)
            var settings = ClaudeSettings()
            settings.filterEnabled = false
            settings.reviewSkill = "review"
            let pipeline = ReviewPipeline(processRunner: SystemProcessRunner(), streamingRunner: SystemProcessRunner(), tokens: FakeTokens(),
                                          api: FakeAPI(), gitPath: "/usr/bin/git", ghPath: nil, claudePath: "/nonexistent/claude",
                                          settings: settings, logURLProvider: { _ in ssh.base.appendingPathComponent("review.log") },
                                          placement: remote)
            let item = ClassifiedPR(pr: makePR(repo: RepoRef(owner: "o", name: "r"), number: 7, base: "main"), category: .toReview, account: "me")
            let activities = Box<[JobActivity]>([])
            _ = try await pipeline.run(ReviewRequest(item: item, localPath: nil, baseRef: "main"), onPhase: { _ in },
                                       onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.readingPR, "Creating the PR’s folder on devbox…", "Writing the context for Claude on devbox…"])
        },
```

- [ ] **Step 3: Ver que falla**

Run: `swift run PRBarTests "review queue: activity"`
Expected: FAIL (la cola todavía no le pasa el sink al pipeline: `waitUntil` se vence).

- [ ] **Step 4: Implementar.** En `Sources/PRBarCore/ReviewQueue.swift`:
  - `enqueue`: antes de `scheduler.enqueue`, `let steps = activityFeed.sink(prID: prID)`, y la llamada al pipeline queda
    `try await pipeline.run(request, onPhase: { [weak self] phase in self?.update(prID, job: jobID, phase: phase) }, onActivity: steps)`.
  - `cancel(prID:)`: después de `phases[prID] = nil`, `activityFeed.clear(prID: prID)`.
  - `cancelAll()`: `activityFeed.clearAll()`.
  - `finish(_:job:result:)`: después de `jobs[prID] = nil`, `activityFeed.clear(prID: prID)` (éxito, error o cancelación:
    LP.6).

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "review queue"` y `swift run PRBarTests "remote flow: un review"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/ReviewQueue.swift Sources/PRBarTests/ReviewQueueTests.swift Sources/PRBarTests/RemoteFlowTests.swift
git commit -m "Review queue keeps each review's step and clears it when the job ends"
```

  Al terminar el grupo: `swift build --product PRBar && swift build --product PRBarCLI` sin warnings nuevos y
  `rm -rf .build` en el worktree.

---

# Grupo B — Respond, Fix CI y Resolve Conflicts (worktree `PRBar-wt-progress-b`, rama `feat/live-progress-b`)

Dueño de: `RespondPipeline.swift` (todo menos el protocolo), `RespondAnalyzer.swift`, `FixImplementer.swift`,
`RespondQueue.swift` (todo menos `activityFeed`/`activity`); tests en `RespondQueueTests.swift` (incluye
`RespondPipelineTests`), `RespondAnalyzerTests.swift` y casos al **final** de `RemoteFlowTests.cases`.

### Task 8: Los pasos del análisis (Respond, Fix CI, Resolve Conflicts)

**Files:**
- Modify: `Sources/PRBarCore/RespondPipeline.swift`, `Sources/PRBarCore/RespondAnalyzer.swift`
- Test: `Sources/PRBarTests/RespondQueueTests.swift` (en `RespondPipelineTests`), `Sources/PRBarTests/RespondAnalyzerTests.swift`

- [ ] **Step 1: Tests que fallan** (en `RespondPipelineTests.cases`):

```swift
        TestCase("respond pipeline: los pasos de PRBar del análisis en orden, antes de los de Claude") {
            let claude = ScriptedClaude { schema, _, _ in schema == RespondSchemas.analysis ? [analysisLine(["thread:A", "thread:B"])] : [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.analyze(e.request, draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.readingComments, JobStep.readingPR, JobStep.creatingWorktree, JobStep.writingContext])
            let firstClaude = try expectSome(activities.value.firstIndex { $0.kind == .claude })
            try expectEqual(activities.value[firstClaude].text, ClaudeActivityText.starting)
            try expectEqual(firstClaude, 4)
        },
        TestCase("fix ci: los pasos del análisis: el PR, los checks, los logs, el worktree y el contexto") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            e.api.checks[e.repo.prSHA] = [ciRun("build", id: 5)]
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .ciFix)
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.analyze(request, draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.map(\.text), [
                JobStep.readingPR, JobStep.readingFailingChecks, JobStep.downloadingCILogs, JobStep.creatingWorktree, JobStep.writingContext,
            ])
            // A check that isn't from Actions has no log to download: no step for it.
            let other = Box<[JobActivity]>([])
            e.api.checks[e.repo.prSHA] = [ciRun("lint", actions: false)]
            _ = try await e.pipeline.analyze(request, draftID: UUID(), onPhase: { _ in }, onActivity: { other.value.append($0) })
            try expect(!other.value.contains { $0.text == JobStep.downloadingCILogs }, "\(other.value.map(\.text))")
        },
        TestCase("resolve conflicts: los pasos: el PR, el worktree, fetch y merge de la base, el contexto") {
            let claude = ScriptedClaude { _, _, _ in [] }
            let (e, _) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.analyze(request, draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.map(\.text),
                            [JobStep.readingPR, JobStep.creatingWorktree, "Fetching main…", "Merging main…", JobStep.writingContext])
        },
```

  (Si el segundo análisis de Fix CI choca con el worktree del primero, hacerlo con otro `E2E`.)

- [ ] **Step 2: Ver que falla**

Run: `swift run PRBarTests "los pasos"`
Expected: FAIL (el pipeline usa la implementación por defecto: no emite nada).

- [ ] **Step 3: `RespondAnalyzer`.** En `Sources/PRBarCore/RespondAnalyzer.swift`, `analyze(…, onAgent:)` pasa a recibir
  todos los eventos (los tests que pasan `{ _ in }` no cambian; si alguno usaba el número, adaptarlo con
  `if case .agentStarted(let n) = $0`):

```swift
    public func analyze(pr: PullRequest, items: [FeedbackItem], worktree: URL, contextDir: URL,
                        description: String, language: PRLanguage,
                        onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> [RespondItem] {
        // … (igual)
        let output = try await claude.run(invocation, as: AnalysisOutput.self, onEvent: onEvent)
        return Self.combine(items: items, output: output.items)
    }
```

- [ ] **Step 4: `RespondPipeline.analyze`.** En `Sources/PRBarCore/RespondPipeline.swift`:
  1. `analyze(_:draftID:onPhase:)` llama a la nueva con `onActivity: { _ in }`; el cuerpo se muda a
     `analyze(_:draftID:onPhase:onActivity:)`, que pasa `onActivity` a `analyzeConflicts`, `analyzeCI` y al `analyze`
     privado, y emite (decisiones 11–13):

```swift
        let token = try await tokens.token(for: item.account)
        onActivity(.prbar(JobStep.readingComments))
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        // … (fork, filtro)
        onActivity(.prbar(JobStep.readingPR))
        let description = try await ReviewPipeline.description(of: pr, api: api, token: token)
        // …
        if let remote = placement {
            pluginDirs = try await remote.plugins(skills: settings.respondSkills)
            try Task.checkCancellation()
            onActivity(.prbar(JobStep.creatingWorktree, runner: remote.name))
            // … (prepareRespond igual)
        } else {
            // … (guard, plugins, checkCancellation igual)
            onActivity(.prbar(JobStep.creatingWorktree))
            // … (resolver.prepare igual)
        }
```

  2. El `analyze` privado (`analyze(item:items:…)`) suma `onActivity: @escaping JobActivitySink`; antes de llamar a
     `analyzer.analyze` emite el contexto (en el host si corre allá) y traduce los eventos de Claude:

```swift
        onActivity(.prbar(JobStep.writingContext, runner: placement?.name))
        let steps = ClaudeActivityText.sink(ClaudeActivityText.Folders(working: worktreeURL, context: contextDir), to: onActivity)
        do {
            analyzed = try await analyzer.analyze(pr: pr, items: items, worktree: worktreeURL, contextDir: contextDir,
                                                 description: description ?? "", language: language) { event in
                if case .agentStarted(let agents) = event { relay.send(agents) }
                steps(event)
            }
        } catch {
            // … (igual)
        }
```

  3. `prepareWorktree(_:headRef:)` suma `onActivity` y emite el worktree donde se arma:

```swift
    private func prepareWorktree(_ request: RespondRequest, headRef: String,
                                 onActivity: @escaping JobActivitySink) async throws -> (ResolvedWorktree, String) {
        let pr = request.item.pr
        if let remote = placement {
            onActivity(.prbar(JobStep.creatingWorktree, runner: remote.name))
            return try await remote.preparing { /* … igual */ }
        }
        guard let localPath = request.localPath, !localPath.isEmpty else { throw PRBarError.respond(Self.needsLocalPathMessage) }
        onActivity(.prbar(JobStep.creatingWorktree))
        return try await resolver.prepare(localPath: localPath, repo: pr.repo, number: pr.number, headRef: headRef,
                                          worktreeDir: request.worktreeDir)
    }
```

  4. `analyzeCI(_:draftID:onActivity:)`:

```swift
        let token = try await tokens.token(for: item.account)
        onActivity(.prbar(JobStep.readingPR))
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        if feedback.isCrossRepository { throw PRBarError.respond(Self.forkMessage) }
        let head = feedback.headRefOid
        onActivity(.prbar(JobStep.readingFailingChecks))
        let runs = try await ciAPI.checkRuns(repo: pr.repo, headOid: head, token: token)
        let failing = CILogs.failing(runs)
        guard !failing.isEmpty else { throw PRBarError.respond(Self.noFailingChecksMessage) }
        var logs: [Int: String] = [:]
        if failing.prefix(CILogs.maxChecks).contains(where: { $0.isActions && $0.id != nil }) {
            onActivity(.prbar(JobStep.downloadingCILogs))
        }
        for run in failing.prefix(CILogs.maxChecks) where run.isActions {
            // … (igual)
        }
        try Task.checkCancellation()
        let (worktree, startHeadOid) = try await prepareWorktree(request, headRef: feedback.headRefName, onActivity: onActivity)
        // … (cancelado, head movido: igual)
        onActivity(.prbar(JobStep.writingContext))
        let (ciItem, context) = CIFixItem.make(/* … igual */)
```

  5. `analyzeConflicts(_:draftID:onActivity:)`:

```swift
        let token = try await tokens.token(for: item.account)
        onActivity(.prbar(JobStep.readingPR))
        let feedback = try await api.reviewFeedback(repo: pr.repo, number: pr.number, token: token)
        // … (fork, detalles, base: igual)
        let (worktree, startHeadOid) = try await prepareWorktree(request, headRef: feedback.headRefName, onActivity: onActivity)
        do {
            // … (cancelación, head: igual)
            onActivity(.prbar(JobStep.fetching(baseRef), runner: placement?.name))
            let baseOid: String
            // … (fetch de la base: igual)
            let merger = await conflictMerger(worktree, localPath: request.localPath)
            onActivity(.prbar(JobStep.merging(baseRef), runner: placement?.name))
            let outcome = try await merger.merge(baseRef: baseRef, baseOid: baseOid, startHeadOid: startHeadOid)
            onActivity(.prbar(JobStep.writingContext))
            let conflictsItem = ConflictsItem.make(/* … igual */)
```

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "los pasos"`, `swift run PRBarTests "respond pipeline"`, `swift run PRBarTests "fix ci"`,
`swift run PRBarTests "resolve conflicts"`, `swift run PRBarTests "respond analyzer"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/RespondPipeline.swift Sources/PRBarCore/RespondAnalyzer.swift Sources/PRBarTests/RespondQueueTests.swift \
  Sources/PRBarTests/RespondAnalyzerTests.swift
git commit -m "Respond, Fix CI and Resolve Conflicts analyses report their steps"
```

---

### Task 9: Los pasos de la implementación (`FixImplementer`)

**Files:**
- Modify: `Sources/PRBarCore/FixImplementer.swift`, `Sources/PRBarCore/RespondPipeline.swift`
- Test: `Sources/PRBarTests/RespondQueueTests.swift` (en `RespondPipelineTests`)

- [ ] **Step 1: Tests que fallan** (en `RespondPipelineTests.cases`):

```swift
        TestCase("respond pipeline: implementar: los pasos de Claude y 'Committing…' antes de cada commit") {
            let claude = ScriptedClaude { schema, _, cwd in
                if schema == RespondSchemas.analysis { return [analysisLine(["thread:A", "thread:B"])] }
                try append("chau\n", to: "README.md", in: cwd)
                return [fixLine("Add farewell")]
            }
            let e = try E2E.make(claude: claude)
            defer { e.repo.remove() }
            let draft = try await e.pipeline.analyze(e.request, draftID: UUID()) { _ in }
            let selections: [String: RespondSelection] = [
                "thread:A": RespondSelection(implement: true, fixPlan: "Arreglalo", reply: false, replyText: ""),
                "thread:B": RespondSelection(implement: false, fixPlan: "", reply: false, replyText: ""),
            ]
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.implement(draft: draft, selections: selections, onProgress: { _, _ in },
                                               onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.first?.text, ClaudeActivityText.starting)
            let prbar = activities.value.filter { $0.kind == .prbar }.map(\.text)
            // One per commit (and one more for the squash in single-commit mode).
            try expect(!prbar.isEmpty && prbar.allSatisfy { $0 == JobStep.committing }, "\(prbar)")
        },
        TestCase("resolve conflicts: implementar: Claude, después los marcadores y el commit del merge") {
            let claude = ScriptedClaude { schema, _, cwd in
                guard schema == RespondSchemas.conflicts else { return [] }
                try Data("hola PR\nhola base\n".utf8).write(to: cwd.appendingPathComponent("README.md"))
                return [conflictsLine()]
            }
            let (e, _) = try conflictingE2E(claude: claude)
            defer { e.repo.remove() }
            let request = RespondRequest(item: classified(7), localPath: e.repo.local.path, worktreeDir: e.worktreeDir.path, mode: .conflicts)
            let draft = try await e.pipeline.analyze(request, draftID: UUID()) { _ in }
            let selections = Dictionary(uniqueKeysWithValues: draft.items.map { ($0.id, RespondSelection.defaults(for: $0)) })
            let activities = Box<[JobActivity]>([])
            _ = try await e.pipeline.implement(draft: draft, selections: selections, onProgress: { _, _ in },
                                               onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.first?.text, ClaudeActivityText.starting)
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text),
                            [JobStep.checkingConflictMarkers, JobStep.committingMerge])
        },
```

  (El `ScriptedClaude` de conflictos es el de "resolve conflicts: Claude resuelve, merge de dos padres…": si ese caso
  escribe otro contenido en `README.md`, usar el mismo.)

- [ ] **Step 2: Ver que falla**

Run: `swift run PRBarTests "implementar"`
Expected: FAIL (sin pasos).

- [ ] **Step 3: `FixImplementer`.** En `Sources/PRBarCore/FixImplementer.swift`:
  - `implement(draft:selections:onProgress:)` suma `onActivity: @escaping JobActivitySink = { _ in }` **después** de
    `onProgress` y lo pasa a `resolveConflicts`, a `implementOne` y a `squash`.
  - `implementOne(…, onActivity:)`: Claude con sus eventos (`working`: el worktree; sin carpeta de contexto) y el paso
    antes del commit, con el host del draft (decisiones 8 y 29):

```swift
            output = try await claude.run(invocation, as: FixOutput.self,
                                          onEvent: ClaudeActivityText.sink(ClaudeActivityText.Folders(working: worktree), to: onActivity))
            // …
            onActivity(.prbar(JobStep.committing, runner: draft.runner))
            try await git(worktree, ["commit", "--no-verify", "-m", message], timeout: Self.fixTimeout)
```

  - `squash(_:draft:worktree:start:onActivity:)`: `onActivity(.prbar(JobStep.committing, runner: draft.runner))` antes de
    su commit.
  - `resolveConflicts(draft:onProgress:onActivity:)` (mismo default) lo pasa a `resolveWithClaude` y emite antes del
    commit del merge:

```swift
        onActivity(.prbar(JobStep.committingMerge, runner: draft.runner))
        let sha = try await commitMerge(worktree, draft: draft, context: context)
```

  - `resolveWithClaude(…, onActivity:)`: Claude con `ClaudeActivityText.sink(ClaudeActivityText.Folders(working: worktree), to: onActivity)`
    como `onEvent`, y antes de `leftoverMarkers`:
    `onActivity(.prbar(JobStep.checkingConflictMarkers, runner: draft.runner))`.

- [ ] **Step 4: `RespondPipeline.implement`.** `implement(draft:selections:onProgress:)` llama a la nueva con
  `onActivity: { _ in }`; el cuerpo se muda a `implement(draft:selections:onProgress:onActivity:)` y la llamada queda
  `try await implementer.implement(draft: draft, selections: selections, onProgress: onProgress, onActivity: onActivity)`.

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "implementar"`, `swift run PRBarTests "fix implementer"`, `swift run PRBarTests "resolve conflicts"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/FixImplementer.swift Sources/PRBarCore/RespondPipeline.swift Sources/PRBarTests/RespondQueueTests.swift
git commit -m "Fixes and conflict resolution report Claude's steps, commits and checks"
```

---

### Task 10: `RespondQueue` conectada (análisis, fixes, tests, push, respuestas); " on <runner>" en un host

**Files:**
- Modify: `Sources/PRBarCore/RespondQueue.swift`
- Test: `Sources/PRBarTests/RespondQueueTests.swift`, `Sources/PRBarTests/RemoteFlowTests.swift`

- [ ] **Step 1: El fake.** En `FakeRespondPipeline`, implementar las firmas nuevas guardando el sink en diccionarios que
  no se vacían al cancelar, y mudar los cuerpos de `analyze`/`implement` a ellas (las viejas llaman a las nuevas con
  `onActivity: { _ in }`):

```swift
    private var analysisSteps: [String: JobActivitySink] = [:]
    private var implementSteps: [String: JobActivitySink] = [:]

    func analyze(_ request: RespondRequest, draftID: UUID, onPhase: @escaping @MainActor @Sendable (RespondPhase) -> Void,
                 onActivity: @escaping JobActivitySink) async throws -> RespondDraft {
        lock.withLock { analysisSteps[request.item.id] = onActivity }
        // … (el cuerpo de antes)
    }

    func implement(draft: RespondDraft, selections: [String: RespondSelection],
                   onProgress: @escaping @MainActor @Sendable (Int, Int) -> Void,
                   onActivity: @escaping JobActivitySink) async throws -> RespondResult {
        lock.withLock { implementSteps[draft.prID] = onActivity }
        // … (el cuerpo de antes)
    }

    func sendAnalysisActivity(_ activity: JobActivity, to prID: String) {
        let sink = lock.withLock { analysisSteps[prID] }
        sink?(activity)
    }

    func sendImplementActivity(_ activity: JobActivity, to prID: String) {
        let sink = lock.withLock { implementSteps[prID] }
        sink?(activity)
    }
```

- [ ] **Step 2: Tests que fallan.** Arriba de `RespondQueueTests.swift`, `import Combine`. En `RespondQueueTests.cases`:

```swift
        TestCase("respond queue: activity sigue al análisis, sobrevive al cambio de fase y se borra en ready; cancelar la borra") { @MainActor in
            let h = try Harness()
            h.queue.analyze(classified(1), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(1))")])
            h.pipeline.sendAnalysisActivity(.prbar(JobStep.creatingWorktree), to: prID(1))
            try await waitUntil { h.queue.activity[prID(1)]?.text == JobStep.creatingWorktree }
            h.pipeline.sendAnalysis(.analyzing(agents: 0), to: prID(1))
            try expectEqual(h.queue.activity[prID(1)]?.text, JobStep.creatingWorktree)
            h.pipeline.completeAnalysis(1)
            try await h.events.wait(for: reached(1, "ready"))
            try expectEqual(h.queue.activity[prID(1)], nil)

            h.queue.analyze(classified(2), localPath: "/repos/r", worktreeDir: nil)
            try await h.events.wait(for: [.started("analyze:\(prID(2))")])
            h.pipeline.sendAnalysisActivity(.claude("Reading a.swift"), to: prID(2))
            try await waitUntil { h.queue.activity[prID(2)] != nil }
            h.queue.cancel(prID: prID(2))
            try expectEqual(h.queue.activity[prID(2)], nil)
            h.pipeline.sendAnalysisActivity(.claude("Reading b.swift"), to: prID(2))   // the old run, late
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(h.queue.activity[prID(2)], nil)
        },
        TestCase("respond queue: los fixes, los tests, el push y las respuestas dicen su paso; al terminar no queda ninguno") { @MainActor in
            let h = try Harness()
            try await h.toReady(1)
            h.queue.implement(prID: prID(1), selections: bothSelected)
            try await h.events.wait(for: [.started("implement:\(prID(1))")])
            h.pipeline.sendImplementActivity(.prbar(JobStep.committing), to: prID(1))
            try await waitUntil { h.queue.activity[prID(1)]?.text == JobStep.committing }
            h.pipeline.completeImplementation(prID(1), .success(fixResult))
            try await h.events.wait(for: reached(1, "readyToPush"))
            try expectEqual(h.queue.activity[prID(1)], nil)

            var seen: [String] = []
            let observation = h.queue.activityFeed.$current.sink { current in
                if let text = current[prID(1)]?.text, seen.last != text { seen.append(text) }
            }
            defer { observation.cancel() }
            h.pipeline.testsPass = true
            try expect(h.queue.runTests(prID: prID(1), testCommand: "make test"))
            try await waitUntil { !h.queue.runningTests.contains(prID(1)) }
            let record = try expectSome(h.queue.records[prID(1)])
            h.queue.publish(prID: prID(1))
            try await h.events.wait(for: reached(1, "done"))
            let replies = RespondCounts.pendingReplies(record) > 0 ? [JobStep.replying] : []
            try expectEqual(seen, [JobStep.runningTests, JobStep.pushing] + replies)
            try expectEqual(h.queue.activity[prID(1)], nil)
        },
```

  (Si `runTests` necesita `CommandOrigin.mayRunRepoCode`, copiar cómo lo arma el caso de tests de este archivo.)

  Al **final** de `RemoteFlowTests.cases`:

```swift
        TestCase("remote flow: Respond en el host: ' on devbox' en el worktree, el contexto y el commit; no en GitHub") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let ssh = try FakeSSH.make()
            defer { ssh.remove() }
            try ssh.installFakeClaude()
            try stream(ssh, ["status": "done", "summary": "Changed", "commitMessage": "Change it"], call: 2)
            try Data("printf 'fixed by claude\\n' > feature.txt\n".utf8).write(to: ssh.home.appendingPathComponent("claude-edit-2.sh"))
            let remote = try await placement(ssh, origin: repo.origin)
            let pipeline = try respondPipeline(repo, ssh, remote)
            let activities = Box<[JobActivity]>([])
            let draft = try await pipeline.analyze(RespondRequest(item: respondItem(), localPath: repo.local.path, worktreeDir: nil),
                                                   draftID: UUID(), onPhase: { _ in }, onActivity: { activities.value.append($0) })
            try expectEqual(activities.value.filter { $0.kind == .prbar }.map(\.text), [
                JobStep.readingComments, JobStep.readingPR, "Creating the worktree on devbox…", "Writing the context for Claude on devbox…",
            ])
            activities.value = []
            _ = try await pipeline.implement(draft: draft, selections: [draft.items[0].id: fixSelection], onProgress: { _, _ in },
                                             onActivity: { activities.value.append($0) })
            try expect(activities.value.contains { $0.kind == .prbar && $0.text == "Committing on devbox…" },
                       "\(activities.value.map(\.text))")
            await pipeline.cleanup(draft: draft)
        },
```

- [ ] **Step 3: Ver que falla**

Run: `swift run PRBarTests "respond queue: activity"`
Expected: FAIL (la cola no pasa el sink).

- [ ] **Step 4: Implementar.** En `Sources/PRBarCore/RespondQueue.swift`:
  1. `start(…)`: `work` pasa a ser `@escaping @Sendable (UUID, JobActivitySink) async throws -> T`. Después del
     `guard canStart(prID)`, `let steps = activityFeed.sink(prID: prID)`; el `work:` del scheduler llama
     `try await work(jobID, steps)`; en `onComplete`, después de `self.jobs[prID] = nil`,
     `self.activityFeed.clear(prID: prID)` (decisión 6: cualquier fin de un trabajo).
  2. `analyze`: `work: { [weak self] jobID, steps in … try await pipeline.analyze(request, draftID: draftID, onPhase: { [weak self] phase in self?.progress(prID, jobID, phase) }, onActivity: steps) … }`.
  3. `implement`: `pipeline.implement(draft: draft, selections: selections, onProgress: { [weak self] done, total in self?.progress(prID, jobID, .implementing(done: done, total: total)) }, onActivity: steps)`.
  4. `startTests`: el paso lo da la cola (decisión 7), con el host del draft:

```swift
        start(prID, kind: .tests, phase: nil, work: { _, steps in
            steps(.prbar(JobStep.runningTests, runner: draft.runner))
            return await pipeline.runTests(draft: draft, testCommand: testCommand)
        }, completion: { … igual … })
```

  5. `startPublish`:

```swift
        start(prID, kind: .publish, phase: .queued, onStart: .pushing, work: { [weak self] _, steps in
            if push && !record.pushed, let result = record.result {
                if draft.implementsAlone {
                    steps(.prbar(JobStep.readingPR))
                    try await pipeline.checkCIBeforePush(draft: draft, result: result, ignoringPassingChecks: ignoringCI)
                }
                steps(.prbar(JobStep.pushing))
                try await pipeline.push(draft: draft, result: result)
                await self?.markPushed(prID, draftID)
            }
            if RespondCounts.pendingReplies(record) > 0 { steps(.prbar(JobStep.replying)) }
            let (posted, error) = await pipeline.postReplies(/* … igual */)
            // … (igual)
        }, completion: { … igual … })
```

  6. `cancel(prID:)`: `activityFeed.clear(prID: prID)` en la rama de "en cola" y antes del `jobs[prID] = nil` final (no
     en `.publish`, que no se cancela). `cancelAll()`: `activityFeed.clearAll()`.

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "respond queue"`, `swift run PRBarTests "remote flow: Respond"`, `swift run PRBarTests "fix ci"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCore/RespondQueue.swift Sources/PRBarTests/RespondQueueTests.swift Sources/PRBarTests/RemoteFlowTests.swift
git commit -m "Respond queue keeps each run's step: analysis, fixes, tests, push and replies"
```

  Al terminar el grupo: `swift build --product PRBar && swift build --product PRBarCLI` sin warnings nuevos y
  `rm -rf .build` en el worktree.

---

# Grupo C — la app (worktree `PRBar-wt-progress-c`, rama `feat/live-progress-c`)

Dueño de: `Sources/PRBar/Components/JobActivityLine.swift` (nuevo), `Popover/PRRowView.swift`, `Popover/PRRowAccessory.swift`,
`Main/PRListRow.swift`, `Review/ReviewButton.swift`, `Respond/RespondButton.swift`, `Review/ReviewPane.swift`,
`Respond/RespondPane.swift`, `Merge/MergeDetailPane.swift`, `Snapshots/SnapshotFakes.swift`. La UI no tiene tests unitarios
(el target `PRBar` es un ejecutable): se verifica compilando, con `swift run PRBarTests "paridad"` (no hay controles nuevos)
y en el QA manual. Mientras A y B no estén mergeados, la app compila pero no muestra pasos (salvo en el modo captura, Task 13).

### Task 11: La línea del paso en las filas y en los tooltips

**Files:**
- Create: `Sources/PRBar/Components/JobActivityLine.swift`
- Modify: `Sources/PRBar/Popover/PRRowView.swift`, `Sources/PRBar/Popover/PRRowAccessory.swift`, `Sources/PRBar/Main/PRListRow.swift`,
  `Sources/PRBar/Review/ReviewButton.swift`, `Sources/PRBar/Respond/RespondButton.swift`

- [ ] **Step 1: Las vistas.** Crear `Sources/PRBar/Components/JobActivityLine.swift`:

```swift
import PRBarCore
import SwiftUI

/// The step a running job is on (spec LP.5), under a PR's row: "Analyzing · Reading src/shop/tax.py", small and gray,
/// truncated in the middle. It observes only the feed: two changes a second don't redraw the rest of the row.
struct JobActivityLine: View {
    @ObservedObject var feed: JobActivityFeed
    let prID: String
    /// "Analyzing" (`ReviewPhase.stepTitle`, `RespondPhase.stepTitle`).
    let phase: String

    var body: some View {
        if let activity = feed.current[prID] {
            Text("\(phase) · \(activity.text)")
                .font(.caption)
                // A plain color, like `PlacementLabel`: `.secondary` drew black under a toolbar in Dark Mode.
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(activity.text)
                .accessibilityLabel("Now: \(activity.text)")
        }
    }
}

/// The step line of a row: its review's (PRs to review) or its Respond slot's (my PRs: Respond, Fix CI, Resolve
/// Conflicts). Nothing while nothing runs.
struct JobActivityRowLine: View {
    let item: ClassifiedPR
    @ObservedObject var reviews: ReviewQueue
    @ObservedObject var respond: RespondQueue

    var body: some View {
        if let title = reviews.phases[item.id]?.stepTitle {
            JobActivityLine(feed: reviews.activityFeed, prID: item.id, phase: title)
        } else if let title = respond.phases[item.id]?.stepTitle(mode: respond.mode(of: item.id),
                                                                runningTests: respond.runningTests.contains(item.id)) {
            JobActivityLine(feed: respond.activityFeed, prID: item.id, phase: title)
        }
    }
}

/// Under the progress indicator of the PR window's tabs (spec LP.5): "Reading src/shop/tax.py · 12 s", every second.
struct JobActivityDetail: View {
    @ObservedObject var feed: JobActivityFeed
    let prID: String

    var body: some View {
        if let activity = feed.current[prID] {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(activity.text) · \(activity.elapsedText(now: context.date))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(activity.text)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
```

- [ ] **Step 2: Las filas.** En `PRRowView.rowContent`, debajo del `if let shownPlacement { … }`:

```swift
            // Spec LP.5: what the running job is doing, as wide as the row.
            JobActivityRowLine(item: item, reviews: reviews, respond: respond)
                .padding(.leading, 22 + 8)
```

  En `PRListRow`, debajo del `ConflictsStatusLabel` (antes del `HStack` de CI y el pill):

```swift
                JobActivityRowLine(item: item, reviews: model.reviews, respond: model.respond)
```

  y su `accessibilityLabel` (la fila es un solo elemento) suma el paso si hay: `+ (step.map { ", now: \($0)" } ?? "")`
  con `let step = model.reviews.activity[item.id]?.text ?? model.respond.activity[item.id]?.text`.

- [ ] **Step 3: Los tooltips.** `ReviewButton` suma `var activity: JobActivity? = nil` y un helper; los tooltips de las
  fases que corren llevan el paso antes de "click to cancel":

```swift
    /// The tooltip of a running phase with its step (spec LP.5): "2 agents · Reading src/a.swift · click to cancel".
    private func running(_ base: String) -> String {
        ([base] + [activity?.text].compactMap { $0 }).joined(separator: " · ") + " · click to cancel"
    }
```

  `case .preparing?` usa `tooltip: running("Preparing the worktree")`, `case .reviewing(let agents)?`
  `running("\(agents) agent\(agents == 1 ? "" : "s")")` y `case .filtering?` `running("Filtering the findings")`. En
  `RespondButton` lo mismo (`var activity: JobActivity? = nil`, el helper, y `running(…)` en `.preparing`, `.analyzing` —
  `analyzingTooltip` pasa a armar su texto con `running` — e `.implementing`; en `.readyToPush` con `runningTests` y en
  `.pushing` el `.help` suma `activity.map { " · \($0.text)" } ?? ""`).

  `PRRowAccessory` observa los dos feeds y se los pasa a los botones:

```swift
    @ObservedObject var reviewSteps: JobActivityFeed
    @ObservedObject var respondSteps: JobActivityFeed
```

  con `activity: respondSteps.current[item.id]` en los tres `RespondButton(…)` y `activity: reviewSteps.current[item.id]`
  en el `ReviewButton(…)`. Las dos llamadas a `PRRowAccessory(…)` (`PRRowView.trailingAccessory` y `PRListRow`) suman
  `reviewSteps: reviews.activityFeed, respondSteps: respond.activityFeed` (en `PRListRow`, `model.reviews.activityFeed` y
  `model.respond.activityFeed`).

- [ ] **Step 4: Compilar**

Run: `swift build --product PRBar && swift run PRBarTests "paridad"`
Expected: compila sin warnings nuevos; PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBar/Components/JobActivityLine.swift Sources/PRBar/Popover Sources/PRBar/Main/PRListRow.swift \
  Sources/PRBar/Review/ReviewButton.swift Sources/PRBar/Respond/RespondButton.swift
git commit -m "Rows show the running job's step; the pill's tooltip too"
```

---

### Task 12: Las pestañas Review / Respond / Merge de la ventana del PR

**Files:**
- Modify: `Sources/PRBar/Review/ReviewPane.swift`, `Sources/PRBar/Respond/RespondPane.swift`, `Sources/PRBar/Merge/MergeDetailPane.swift`

- [ ] **Step 1: Review.** En `ReviewProgressView`, debajo del `TimelineView` de la fase:

```swift
                JobActivityDetail(feed: model.reviews.activityFeed, prID: prID)
```

- [ ] **Step 2: Respond.** En `Sources/PRBar/Respond/RespondPane.swift`, `JobActivityDetail(feed: model.respond.activityFeed, prID: …)`
  debajo de cada indicador de progreso de un trabajo que corre:
  - la vista de preparación/análisis (la que muestra "Reading the failing checks and preparing the worktree…" /
    "Claude is analyzing the comments…"), debajo de ese `Text`, con `prID: prID`;
  - `progress(_:)` (en espera y `.pushing`), debajo del `Text(text)`, con `prID: draft.prID`;
  - la tarjeta de `implementing(done:total:)`, en el `VStack` de "Claude is editing…", debajo del subtítulo
    ("Fix N of M"), con `prID: draft.prID`;
  - el bloque de los tests corriendo (el `ProgressView` de "Run tests" en `readyToPush`), a su lado.

- [ ] **Step 3: Merge (decisión 27).** En `Sources/PRBar/Merge/MergeDetailPane.swift`, una vista chica que observa la cola
  y se muestra debajo de `statusLabel` cuando hay un Resolve Conflicts activo en el PR:

```swift
/// Spec LP.5 (decision 27): a Resolve Conflicts running on the PR (its window is the Respond tab), with its step.
private struct ConflictsRunStep: View {
    @ObservedObject var respond: RespondQueue
    let prID: String

    var body: some View {
        if respond.mode(of: prID) == .conflicts, respond.phases[prID]?.isActive == true {
            VStack(alignment: .leading, spacing: 2) {
                Label("Resolving the conflicts…", systemImage: "arrow.triangle.merge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                JobActivityDetail(feed: respond.activityFeed, prID: prID)
            }
        }
    }
}
```

  y en el `body`, justo debajo de donde va `statusLabel`: `ConflictsRunStep(respond: model.respond, prID: prID)`.

- [ ] **Step 4: Compilar**

Run: `swift build --product PRBar`
Expected: compila sin warnings nuevos.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBar/Review/ReviewPane.swift Sources/PRBar/Respond/RespondPane.swift Sources/PRBar/Merge/MergeDetailPane.swift
git commit -m "PR window tabs show the step with its elapsed time"
```

---

### Task 13: Los fakes del modo captura emiten un paso

**Files:**
- Modify: `Sources/PRBar/Snapshots/SnapshotFakes.swift`

- [ ] **Step 1: Implementar.** `SnapshotReviewPipeline` implementa la firma con `onActivity` (la vieja la llama con
  `{ _ in }`) y, en los PRs que quedan "Reviewing…", emite un paso fijo antes de colgarse:

```swift
    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void) async throws -> ReviewDraft {
        try await run(request, onPhase: onPhase, onActivity: { _ in })
    }

    func run(_ request: ReviewRequest, onPhase: @escaping @MainActor @Sendable (ReviewPhase) -> Void,
             onActivity: @escaping JobActivitySink) async throws -> ReviewDraft {
        let prID = request.item.id
        await onPhase(.reviewing(agents: 3))
        if inProgress.contains(prID) {
            onActivity(.claude("Reading src/shop/tax.py"))
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
        guard let draft = drafts[prID] else { throw SnapshotFakes.refused }
        return draft
    }
```

  `SnapshotRespondPipeline.implement` igual: firma nueva y, con `holdsImplementation`,
  `onActivity(.claude("Editing src/reports/export.ts"))` antes del `sleep`.

- [ ] **Step 2: Compilar**

Run: `swift build --product PRBar`
Expected: compila sin warnings nuevos. **No** correr `Scripts/snapshots.sh` (compila en release; decisión 31): las
capturas quedan en el checklist de QA.

- [ ] **Step 3: Commit**

```bash
git add Sources/PRBar/Snapshots/SnapshotFakes.swift
git commit -m "Snapshot fakes report a step"
```

  Al terminar el grupo: `rm -rf .build` en el worktree.

---

# Grupo D — CLI y el wire en la app (worktree `PRBar-wt-progress-d`, rama `feat/live-progress-d`)

Dueño de: `Sources/PRBarCore/WaitProgress.swift` (nuevo), `Sources/PRBar/AppModel+Commands.swift`,
`Sources/PRBar/AppModel+Remote.swift`, `Sources/PRBarCLIKit/{CLISupport,Render,ReviewCommands,RespondCommands,CICommands,ConflictsCommands}.swift`;
tests en `CLISupportTests.swift`, `CLIIntegrationTests.swift`, `FakeActions.swift`.

### Task 14: Las líneas de `--wait` (`WaitProgress`) y `activity` en la info de la app

**Files:**
- Create: `Sources/PRBarCore/WaitProgress.swift`
- Modify: `Sources/PRBar/AppModel+Commands.swift`
- Test: `Sources/PRBarTests/CLISupportTests.swift`

- [ ] **Step 1: Test que falla** (en `CLISupportTests.cases`):

```swift
        TestCase("cli: --wait manda una línea cuando cambia la fase o el paso; el mismo paso empezado de nuevo es otra línea") {
            var progress = WaitProgress()
            let reading = JobActivity(kind: .claude, text: "Reading a.swift", startedAt: t0)
            try expectEqual(progress.next(phase: "Reviewing…", activity: nil), "Reviewing…")
            try expectEqual(progress.next(phase: "Reviewing…", activity: nil), nil)
            try expectEqual(progress.next(phase: "Reviewing…", activity: reading), "Reviewing… · Reading a.swift")
            try expectEqual(progress.next(phase: "Reviewing…", activity: reading), nil)
            var again = reading
            again.startedAt = t0.addingTimeInterval(5)
            try expectEqual(progress.next(phase: "Reviewing…", activity: again), "Reviewing… · Reading a.swift")
            try expectEqual(progress.next(phase: "Filtering the findings…", activity: again), "Filtering the findings… · Reading a.swift")
            try expectEqual(progress.next(phase: "Filtering the findings…", activity: nil), "Filtering the findings…")
        },
```

- [ ] **Step 2: Ver que falla**

Run: `swift build --product PRBarTests`
Expected: no compila (`WaitProgress` no existe).

- [ ] **Step 3: Implementar.** Crear `Sources/PRBarCore/WaitProgress.swift`:

```swift
import Foundation

/// The progress lines of `--wait` (spec LP.5, decision 23): the phase and, while there is one, the step
/// ("Reviewing… · Reading src/a.swift"). A new line when either changes; the same step started again (another
/// `startedAt`) is a new line too: the CLI drops identical lines in a row when its output isn't a terminal.
public struct WaitProgress: Sendable {
    private var lastPhase: String?
    private var lastActivity: JobActivity?
    private var started = false

    public init() {}

    /// The line to send now, or nil if nothing changed since the last one.
    public mutating func next(phase: String, activity: JobActivity?) -> String? {
        if started, phase == lastPhase, activity == lastActivity { return nil }
        started = true
        lastPhase = phase
        lastActivity = activity
        return activity.map { "\(phase) · \($0.text)" } ?? phase
    }
}
```

  En `Sources/PRBar/AppModel+Commands.swift`:
  - `waitUntil` usa `WaitProgress` y suma el paso:

```swift
    func waitUntil(_ isDone: () -> Bool, describe: () -> String, activity: () -> JobActivity? = { nil },
                   events: CommandEventSink) async throws {
        var progress = WaitProgress()
        while !isDone() {
            if let line = progress.next(phase: describe(), activity: activity()) {
                events(.progress(message: line))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
```

  - `reviewStart`: `try await waitUntil({ … }, describe: { reviewProgress(item.id) }, activity: { reviews.activity[item.id] }, events: events)`.
  - `waitForRespond`: `activity: { respond.activity[prID] }`.
  - `reviewInfo(_:)` y `respondInfo(_:)` llenan el campo:

```swift
    func reviewInfo(_ prID: String) -> ReviewInfo {
        let phase = reviews.phases[prID]
        var info: ReviewInfo
        if case .ready(let draft)? = phase {
            info = ReviewInfo(prID: prID, phase: phase, edits: reviewChat(for: draft).reviewEdits, outdated: isOutdated(draft))
        } else {
            info = ReviewInfo(prID: prID, phase: phase)
        }
        info.activity = reviews.activity[prID]
        return info
    }
```

  y en `respondInfo`, antes del `return info`: `info.activity = respond.activity[prID]`.

- [ ] **Step 4: Correr**

Run: `swift run PRBarTests "cli: --wait"` y `swift build --product PRBar`
Expected: PASS; compila sin warnings nuevos.

- [ ] **Step 5: Commit**

```bash
git add Sources/PRBarCore/WaitProgress.swift Sources/PRBar/AppModel+Commands.swift Sources/PRBarTests/CLISupportTests.swift
git commit -m "--wait prints each new step; review and respond info carry the step"
```

---

### Task 15: La CLI: "Now:" en `show`, `activity` en `--json`, sin repetidos sin terminal

**Files:**
- Modify: `Sources/PRBarCLIKit/CLISupport.swift`, `Sources/PRBarCLIKit/Render.swift`, `Sources/PRBarCLIKit/ReviewCommands.swift`,
  `Sources/PRBarCLIKit/RespondCommands.swift`, `Sources/PRBarCLIKit/CICommands.swift`, `Sources/PRBarCLIKit/ConflictsCommands.swift`
- Test: `Sources/PRBarTests/CLISupportTests.swift`, `Sources/PRBarTests/CLIIntegrationTests.swift`, `Sources/PRBarTests/FakeActions.swift`

- [ ] **Step 1: El fake.** En `FakeActions`, debajo de `respondPhase`:

```swift
    /// El paso que devuelven `reviewShow` y `respondShow` (spec LP.5).
    var reviewActivity: JobActivity?
    var respondActivity: JobActivity?
```

  `reviewShow` arma la info y le pone `info.activity = reviewActivity`; `respondInfo(_:)` le pone
  `info.activity = respondActivity` (lo usan `respond show`, `ci show` y `conflicts show`).

- [ ] **Step 2: Tests que fallan.** En `CLISupportTests.cases`:

```swift
        TestCase("cli: sin terminal no repite una línea de progreso idéntica seguida; en un terminal sí") {
            var err = ""
            let plain = Output(terminal: .plain, json: false, out: { _ in }, err: { err += $0 })
            plain.event(.progress(message: "Reviewing… · Reading a.swift"))
            plain.event(.progress(message: "Reviewing… · Reading a.swift"))
            plain.event(.progress(message: "Reviewing… · Reading b.swift"))
            try expectEqual(err, "Reviewing… · Reading a.swift\nReviewing… · Reading b.swift\n")
            var tty = ""
            let terminal = Output(terminal: Terminal(stdinIsTTY: true, stdoutIsTTY: true, colors: false), json: false,
                                  out: { _ in }, err: { tty += $0 })
            terminal.event(.progress(message: "x"))
            terminal.event(.progress(message: "x"))
            try expectEqual(tty, "x\nx\n")
        },
```

  En `CLIIntegrationTests`: el caso en la lista, `TestCase("integración: show con Now: mientras corre y activity en --json") { try await nowLine() }`,
  y la función:

```swift
    @MainActor
    private static func nowLine() async throws {
        let harness = try Harness()
        defer { harness.server.stop() }
        harness.fake.reviewPhase = .reviewing(agents: 1)
        harness.fake.reviewActivity = JobActivity(kind: .claude, text: "Reading src/a.swift", startedAt: Date().addingTimeInterval(-12))
        let show = try await runCLI(["review", "show", "acme/api#1"], socket: harness.url)
        try expectEqual(show.code, 0)
        try expect(show.out.contains("Now: Reading src/a.swift (1"), show.out)
        let json = try await runCLI(["review", "show", "acme/api#1", "--json"], socket: harness.url)
        try expect(json.out.contains(#""activity""#) && json.out.contains(#""kind":"claude""#), json.out)
        harness.fake.respondPhase = .analyzing(agents: 0)
        harness.fake.respondActivity = JobActivity(kind: .prbar, text: "Creating the worktree…", startedAt: Date())
        for command in [["respond", "show", "acme/web#2"], ["ci", "show", "acme/web#2"], ["conflicts", "show", "acme/web#2"]] {
            let result = try await runCLI(command, socket: harness.url)
            try expect(result.out.contains("Now: Creating the worktree… ("), "\(command): \(result.out)")
        }
        // Nothing running: no line.
        harness.fake.reviewActivity = nil
        let idle = try await runCLI(["review", "show", "acme/api#1"], socket: harness.url)
        try expect(!idle.out.contains("Now:"), idle.out)
    }
```

- [ ] **Step 3: Ver que falla**

Run: `swift run PRBarTests "integración: show con Now"` y `swift run PRBarTests "cli: sin terminal"`
Expected: FAIL (no hay "Now:"; la línea repetida sale dos veces).

- [ ] **Step 4: Implementar.**
  - `Sources/PRBarCLIKit/CLISupport.swift`: `Output` guarda la última línea de progreso (decisión 23):

```swift
/// The last progress line `Output` printed (it's a struct, copied around).
final class ProgressMemory: @unchecked Sendable {
    var last: String?
}
```

    con `private let progressMemory = ProgressMemory()` en `Output`, y en `event`:

```swift
        case .progress(let message):
            // Without a terminal (a log, a script), a line identical to the previous one adds nothing.
            if !terminal.stdoutIsTTY {
                guard progressMemory.last != message else { return }
                progressMemory.last = message
            }
            note(message)
```

  - `Sources/PRBarCLIKit/Render.swift`, en `enum Render`:

```swift
    /// Spec LP.5: "Now: <step> (<time>)" while the job runs.
    static func now(_ activity: JobActivity?, _ output: Output, at date: Date = Date()) {
        guard let activity else { return }
        output.line("Now: \(activity.text) (\(activity.elapsedText(now: date)))")
    }
```

  - En `ReviewRender.info`, `RespondRender.info`, `CIRender.info` y `ConflictsRender.info`, justo después de
    `output.line(output.paint(header, .bold))`: `Render.now(info.activity, output)`. `--json` no necesita nada: imprime
    la info entera, con `activity`.

- [ ] **Step 5: Correr**

Run: `swift run PRBarTests "integración"` y `swift run PRBarTests "cli:"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/PRBarCLIKit Sources/PRBarTests/CLISupportTests.swift Sources/PRBarTests/CLIIntegrationTests.swift \
  Sources/PRBarTests/FakeActions.swift
git commit -m "CLI: Now line in show, activity in --json, no repeated lines without a terminal"
```

---

### Task 16: El iPhone se entera de los pasos

**Files:**
- Modify: `Sources/PRBar/AppModel+Remote.swift`

- [ ] **Step 1: Implementar (decisión 26).** En `startRemoteAccess`, la lista `changes` suma los dos feeds:

```swift
            reviews.activityFeed.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            respond.activityFeed.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
```

  El feed remoto ya agrupa los cambios (`debounce`) y el tópico `pr:<id>` lee `reviewShow`/`respondShow`, que ya llevan
  `activity` (Task 14). `RemoteRedactor` no tiene nada nuevo que tapar: el paso nunca trae una ruta absoluta (decisión 20).

- [ ] **Step 2: Compilar y correr**

Run: `swift build --product PRBar`
Expected: compila sin warnings nuevos (el recálculo del feed se prueba a mano en el QA, sección C).

- [ ] **Step 3: Commit**

```bash
git add Sources/PRBar/AppModel+Remote.swift
git commit -m "The phone's feed recomputes when a job's step changes"
```

  Al terminar el grupo: `rm -rf .build` en el worktree.

---

# Grupo E — web / iPhone (worktree `PRBar-wt-progress-e`, rama `feat/live-progress-e`)

Dueño de: `web/src/protocol/commands.ts`, `web/src/app/format.ts`, `web/src/app/models/review.ts`,
`web/src/app/models/respond.ts`, `web/src/ui/screens/types.ts`, `web/src/ui/screens/Review.tsx`,
`web/src/ui/screens/screens.css`, `web/test/unit/app/models.test.ts`. No compila Swift: solo `npm ci` (si el worktree
no tiene `web/node_modules`) y vitest.

### Task 17: El tipo del wire, el formato y el paso en la review

**Files:**
- Modify: `web/src/protocol/commands.ts`, `web/src/app/format.ts`, `web/src/app/models/review.ts`, `web/src/ui/screens/types.ts`,
  `web/src/ui/screens/Review.tsx`, `web/src/ui/screens/screens.css`
- Test: `web/test/unit/app/models.test.ts`

- [ ] **Step 1: Test que falla** (en `describe("review", …)`; el reloj de `makeApp` arranca en `NOW`):

```ts
  it("mientras corre: el paso de la Mac con su tiempo debajo de la fase; sin activity (una Mac vieja), nada", () => {
    const app = makeApp();
    const model = createReviewModel(app, "acme/api#317");
    model.open();
    const data = topicJSON("pr:acme/api#317");
    data.review = { ...(data.review as Record<string, unknown>), phase: "reviewing",
                    activity: { kind: "claude", text: "Reading src/shop/tax.py", startedAt: new Date(NOW - 12_000).toISOString() } };
    app.transport.setTopic("pr:acme/api#317", data);
    let view = model.view.value;
    if (view.kind !== "review") throw new Error(view.kind);
    expect(view.props.summary.activity).toBe("Reading src/shop/tax.py · 12 s");
    data.review = { ...(data.review as Record<string, unknown>), activity: undefined };
    app.transport.setTopic("pr:acme/api#317", data);
    view = model.view.value;
    if (view.kind !== "review") throw new Error(view.kind);
    expect(view.props.summary.activity).toBeUndefined();
  });
```

  y, en un `describe("format", …)` nuevo al final del archivo (o donde estén los de `format`):

```ts
describe("paso en vivo", () => {
  it("stepElapsed como la Mac", () => {
    expect([0, 12.9, 125, 3780, -5].map(stepElapsed)).toEqual(["0 s", "12 s", "2 min 5 s", "1 h 3 min", "0 s"]);
  });
});
```

  (importar `stepElapsed` de `../../../src/app/format`).

- [ ] **Step 2: Ver que falla**

Run: `cd web && npx vitest run test/unit/app/models.test.ts`
Expected: FAIL (`summary.activity` no existe; `stepElapsed` no existe).

- [ ] **Step 3: Implementar.**
  - `web/src/protocol/commands.ts`, junto a `ReviewInfo`:

```ts
/** Spec LP.2: lo que hace ahora un trabajo en curso. Texto plano (nunca HTML); un `kind` desconocido cuenta como "prbar". */
export interface JobActivity {
  kind: "prbar" | "claude";
  text: string;
  startedAt: ISODate;
}
```

    y en `ReviewInfo` y en `RespondInfo`:
    `/** Spec LP.5: el paso actual mientras corre (opcional, sin subir la versión del protocolo). */ activity?: JobActivity;`
  - `web/src/app/format.ts`:

```ts
/** "12 s", "2 min 5 s", "1 h 3 min": lo mismo que `JobActivity.elapsedText` en la Mac. */
export function stepElapsed(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  if (total < 60) return `${total} s`;
  if (total < 3600) return `${Math.floor(total / 60)} min ${total % 60} s`;
  return `${Math.floor(total / 3600)} h ${Math.floor((total % 3600) / 60)} min`;
}

/** "Reading src/shop/tax.py · 12 s" (spec LP.5); sin una fecha válida, solo el texto. */
export function activityLine(activity: { text: string; startedAt: string }, now: number): string {
  const start = parseDate(activity.startedAt);
  return start === null ? activity.text : `${activity.text} · ${stepElapsed((now - start) / 1000)}`;
}
```

  - `web/src/ui/screens/types.ts`: `summary: { text: string; meta: string; activity?: string | undefined };`
  - `web/src/app/models/review.ts` (importar `activityLine`): en `view`, junto a `summaryText`,

```ts
      // Solo mientras corre (y solo entonces el reloj de segundos la recalcula).
      const activity = running.value && r?.activity ? activityLine(r.activity, store.now.value) : undefined;
```

    y `summary: { text: summaryText, meta: metaParts.join(" · "), activity },`.
  - `web/src/ui/screens/Review.tsx`, debajo de `<p>{summary.text}</p>`:

```tsx
          {summary.activity && <p class="summary-card__activity">{summary.activity}</p>}
```

  - `web/src/ui/screens/screens.css`, debajo de `.summary-card p`: `.summary-card__activity` con el color secundario y el
    tamaño de `.summary-card__meta`, en una línea (`white-space: nowrap; overflow: hidden; text-overflow: ellipsis;`).

- [ ] **Step 4: Correr**

Run: `cd web && npx tsc --noEmit && npx vitest run test/unit/app/models.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add web/src web/test/unit/app/models.test.ts
git commit -m "Web: the review shows the Mac's step with its elapsed time"
```

---

### Task 18: El paso en Respond, Fix CI y Resolve Conflicts

**Files:**
- Modify: `web/src/app/models/respond.ts`
- Test: `web/test/unit/app/models.test.ts`

- [ ] **Step 1: Test que falla** (en `describe("respond y fix CI", …)`):

```ts
  it("mientras corre: la etapa actual muestra el paso de la Mac con su tiempo (en lugar del archivo)", () => {
    const app = makeApp();
    setRespond(app, "acme/web-app#488", {
      phase: "implementing", currentFile: "src/old.ts",
      activity: { kind: "prbar", text: "Committing…", startedAt: new Date(NOW - 125_000).toISOString() },
    });
    const model = createRespondModel(app, "acme/web-app#488", "feedback");
    model.open();
    const view = model.view("main");
    const stages = (view.props as { progress?: { stages: { state: string; detail?: string }[] } }).progress?.stages ?? [];
    expect(stages.find((s) => s.state === "current")?.detail).toBe("Committing… · 2 min 5 s");
  });
```

- [ ] **Step 2: Ver que falla**

Run: `cd web && npx vitest run test/unit/app/models.test.ts`
Expected: FAIL (el detalle es "Editing src/old.ts").

- [ ] **Step 3: Implementar.** En `web/src/app/models/respond.ts` (importar `activityLine`), en `progress()`, dentro del
  `map` de las etapas, después de las dos líneas de `detail` que ya están:

```ts
      // Spec LP.5: lo que hace la Mac ahora, en la etapa que corre (gana sobre el archivo y la salida de los tests).
      if (state === "current" && isRunning.value && r?.activity) detail = activityLine(r.activity, store.now.value);
```

- [ ] **Step 4: Correr**

Run: `cd web && npx tsc --noEmit && npx vitest run`
Expected: PASS (todo el web).

- [ ] **Step 5: Commit**

```bash
git add web/src/app/models/respond.ts web/test/unit/app/models.test.ts
git commit -m "Web: Respond, Fix CI and Resolve Conflicts show the Mac's step"
```

---

# Final

### Task 19: Integración, docs, QA y verificación

**Files:**
- Modify: `docs/cli.md`
- Create: `docs/qa/plan-25-checklist.md`

- [ ] **Step 1: Merge.** En `PRBar-wt-progress` (rama `feat/live-progress`), con los cinco grupos commiteados:

```bash
git merge --no-ff feat/live-progress-a -m "Merge live progress: review"
git merge --no-ff feat/live-progress-b -m "Merge live progress: respond, Fix CI and conflicts"
git merge --no-ff feat/live-progress-c -m "Merge live progress: app"
git merge --no-ff feat/live-progress-d -m "Merge live progress: CLI"
git merge --no-ff feat/live-progress-e -m "Merge live progress: web"
```

  Expected: sin conflictos (archivos disjuntos; en `RemoteFlowTests.swift` A insertó después del primer caso y B al
  final). Si alguno aparece, resolverlo a mano sin perder casos de ningún lado. Después borrar los worktrees de los
  grupos (`git worktree remove ../PRBar-wt-progress-<grupo>`) y sus ramas (`git branch -d feat/live-progress-<grupo>`).

- [ ] **Step 2: `docs/cli.md`.** En la fila de `prbar review show`, agregar al final: "While the review runs: `Now: <step>
  (<time>)`". En `prbar respond show`, igual ("While something runs (analysis, fixes, tests, push): `Now: …`"). Debajo
  de la tabla de review, un párrafo:

```markdown
While a job runs (Review, Respond, Fix CI, Resolve Conflicts), PRBar shows its current step: one of PRBar’s own
(“Creating the worktree…”, “Pushing…”, with “on <host>” when it runs on the repo’s host) or the tool Claude is using
(“Reading src/shop/tax.py”, “Searching for returnTo”). `show` prints it as `Now: <step> (<time>)`, `--wait` prints each
new step on its own line (without a terminal, a line identical to the previous one is skipped), and `--json` has it as
`activity` (`kind`: `prbar` or `claude`, `text`, `startedAt`). Claude’s own text is never shown.
```

- [ ] **Step 3: Checklist manual.** Crear `docs/qa/plan-25-checklist.md`:

```markdown
# QA manual — Plan 25 (Progreso en vivo)

Hace falta un repo de prueba propio en GitHub, un PR de otra cuenta de prueba que te pida review, un PR propio con
comentarios, otro con un check de Actions fallando y otro con conflictos, y la carpeta local configurada en Settings ›
Repos. Nada de esto se hace con repos reales de nadie. Para la parte de hosts, el host de prueba del Plan 14.

## A. Review
- [ ] Primera review del PR: la fila del popover y la de la ventana principal muestran debajo, en gris y chico,
      "Preparing · Reading the PR on GitHub…", "… · Creating the PR’s folder…", "… · Writing the context for Claude…",
      y después "Reviewing · Claude is starting…", "Reviewing · Reading <archivo>"; el pill sigue diciendo la fase.
- [ ] El tooltip del pill dice el paso ("1 agent · Reading src/… · click to cancel").
- [ ] Review Again después de un commit nuevo: "Updating the PR’s folder to <sha7>…" con el head que muestra la fila.
- [ ] Con una review publicada antes: aparece "Reading the previous reviews…"; Claude lee "the previous reviews" y "the
      changes since the last review" (no las rutas de `.context`).
- [ ] Con hallazgos y el filtro prendido: "Filtering the findings…" antes de la etapa 2.
- [ ] Sin carpeta local: "Creating a temporary folder…".
- [ ] La pestaña Review de la ventana del PR: debajo de la fase, "<paso> · 12 s" que avanza cada segundo.
- [ ] Un archivo con una ruta larguísima se corta en el medio en la fila; el tooltip la muestra entera (hasta 80).
- [ ] Cancel: el paso desaparece en el acto. Una review que falla: no queda paso colgado.
- [ ] El texto de Claude (lo que escribe entre herramientas) nunca aparece: solo "Thinking…".

## B. Respond, Fix CI, Resolve Conflicts
- [ ] Respond: "Reading the comments and their threads…", "Reading the PR on GitHub…", "Creating the worktree…",
      "Writing the context for Claude…", después los pasos de Claude; al implementar, "Implementing · Editing <archivo>" y
      "Committing…"; Run Tests: "Testing · Running the tests…"; Push & Reply: "Pushing…" y "Replying on GitHub…".
- [ ] Fix CI: "Reading the failing checks…", "Downloading the CI logs…", "Creating the worktree…", "Fixing · …",
      "Committing…"; Push: "Reading the PR on GitHub…" y "Pushing…".
- [ ] Resolve Conflicts: "Creating the worktree…", "Fetching <base>…", "Merging <base>…", "Resolving · Reading …",
      "Checking for conflict markers…", "Committing the merge…". La pestaña Merge muestra "Resolving the conflicts…" con
      el paso y su tiempo.
- [ ] La pestaña Respond muestra el paso con su tiempo en el análisis, en la tarjeta de "Claude is editing…", en los
      tests y en el push.
- [ ] Con el repo en un host: "Creating the worktree on <host>…", "Writing the context for Claude on <host>…",
      "Committing on <host>…", "Running the tests on <host>…"; "Reading the PR on GitHub…" y "Pushing…" sin host.

## C. CLI, web y capturas
- [ ] `prbar review show <pr>` mientras corre: "Now: <paso> (<tiempo>)"; `--json` trae `activity` con `kind`, `text`,
      `startedAt`; terminado, ni la línea ni el campo.
- [ ] `prbar respond show`, `prbar ci show`, `prbar conflicts show`: lo mismo.
- [ ] `prbar review <pr> --wait` en un terminal: una línea por paso nuevo ("Reviewing… · Reading …").
      `prbar review <pr> --wait 2>&1 | cat`: igual, sin dos líneas idénticas seguidas.
- [ ] iPhone (web app): la review que corre muestra "<paso> · 12 s" debajo de "Claude is reviewing this PR…"; un
      Respond que corre lo muestra en la etapa actual. Con una Mac sin este plan, nada se rompe.
- [ ] Capturas (en una máquina con disco para un build release): `Scripts/snapshots.sh docs/screenshots both`; las filas
      "Reviewing…" muestran "Reviewing · Reading src/shop/tax.py". Revertir las PNG que solo cambiaron bytes.
```

- [ ] **Step 4: Verificación completa**

Run: `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests`
Expected: los tres compilan sin warnings nuevos.

Run: `swift run PRBarTests`
Expected: `N/N passed` (la suite entera, ~10 min). Si algo falla, arreglarlo, correr solo ese filtro y después la suite una
vez más.

Run: `cd web && npx tsc --noEmit && npx vitest run`
Expected: PASS.

Run: `git diff main -- . ':(exclude)docs/superpowers' | grep -n -e "$HOME" -e "ghp_" -e "github_pat_"`
Expected: sin resultados (ninguna ruta de esta máquina, usuario ni token en lo que se commitea).

Run: `rm -rf .build` si hace falta lugar; borrar los temporales que haya dejado un test cortado (`rm -rf "$TMPDIR"/prbar-*`).

- [ ] **Step 5: Commit**

```bash
git add docs/cli.md docs/qa/plan-25-checklist.md
git commit -m "Live progress: docs and QA checklist"
```

---

## Cobertura del spec

| Spec | Tasks |
|---|---|
| LP.1 cada trabajo (Review, Respond, Fix CI, Resolve Conflicts) muestra el paso; la fase y sus reglas no cambian | 6–10 (pipelines y colas), 11–12 (UI); `isActive`, cancelar y notificaciones sin tocar |
| LP.2 `JobActivity` (`kind`, `text`, `startedAt`; Codable, Equatable, Sendable) | 1 (decisiones 1, 2) |
| LP.2 `activity[prID]` en las colas, limpio al dejar de estar activo | 4 (`activityFeed`), 7, 10 (decisiones 4–6) |
| LP.2 `onActivity` además de `onPhase`; un cambio de fase no borra el paso | 4 (protocolos), 6, 8, 9; tests 7, 10 |
| LP.2 throttle 0,5 s por PR, el último gana, un paso de PRBar se muestra al menos una vez; reloj inyectable | 2 (decisión 3; `clear` publica lo pendiente antes de borrar) |
| LP.3 pasos de todos los trabajos ("Reading the PR on GitHub…", "Writing the context for Claude…") | 6, 8, 10 (decisiones 12, 13) |
| LP.3 Review: carpeta nueva / actualizada a `<sha7>` / temporal, reviews anteriores, filtro | 5, 6 (decisiones 9, 10, 14) |
| LP.3 Respond: comentarios, worktree, tests, commit, push, respuestas | 8, 9, 10 (decisiones 7, 11, 29) |
| LP.3 Fix CI: checks, logs, worktree, tests, commit, push | 8, 9, 10 (decisiones 7, 28) |
| LP.3 Resolve Conflicts: worktree, fetch y merge de la base, marcadores, commit del merge, push | 8, 9, 10 (decisión 30) |
| LP.3 host remoto: " on <runner>" | 1 (`JobActivity.prbar(_:runner:)`), 5–10; tests 7 y 10 en `RemoteFlowTests` (decisión 8) |
| LP.4 cada herramienta, `agentStarted`, `text` → "Thinking…", "Claude is starting…" | 3 (decisiones 15–18) |
| LP.4 rutas relativas, fuera de la carpeta solo el nombre, archivos de contexto por su rol | 3 (decisiones 19, 20) |
| LP.4 texto no confiable: `singleLine`, 80 con "…", nunca interpretado | 1 (`JobStep.name`), 3 (decisión 21), 11–12 (`Text`), 15 (`output.line`), 17–18 (JSX) |
| LP.4 varios subagentes: cada evento pisa al anterior | 2 (el último gana), 3 |
| LP.5 popover y ventana principal: segunda línea gris, tooltip, truncado en el medio | 11 |
| LP.5 pestañas Review / Respond / Merge: el paso con su tiempo, cada segundo | 12 (decisiones 22, 27) |
| LP.5 CLI: "Now:" en `show`, `--wait` con cada paso (terminal / sin terminal), `--json` `activity` | 14, 15 (decisiones 23, 24) |
| LP.5 web/iPhone: `activity` opcional sin subir el protocolo; la web lo muestra debajo de la fase | 1, 14, 16, 17, 18 (decisiones 25, 26) |
| LP.6 un paso que falla no queda colgado; cancelar lo borra; sin eventos queda "Claude is starting…"; sin persistencia | 7, 10 (limpieza en todo fin de trabajo), 2 (`clear`), 3; el feed vive solo en memoria |
| LP.7 fuera de alcance (texto de Claude, log/timeline, barra con porcentaje) | Respetado: "Thinking…" (3); solo el paso actual (2); sin barra nueva |
| LP.8 pruebas: `ClaudeActivityText`, `ActivityThrottle`, pipelines, colas, CLI, wire/web | 1–3, 5–10, 14–15, 17–18 |
| Docs (`docs/cli.md`) y QA (`docs/qa/plan-25-checklist.md`) | 19 |
