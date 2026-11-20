# PRBar — Plan 15: Fix CI y costo de Claude por tarea

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (o subagent-driven-development) para
> implementar este plan tarea por tarea. Los pasos usan checkbox (`- [ ]`).

**Goal:** (K) un botón manual **Fix CI** en mis PRs con checks fallidos que reusa todo el camino de Respond (worktree,
Claude aislado, guardián, chat, Undo, tests, push desde la Mac, hosts remotos), con los logs bajados en la Mac,
saneados y delimitados; (O) duración, tokens y costo estimado de cada `claude -p`, por tarea en Activity y en el
historial, el total del mes y `prbar usage`.

**Spec:** `docs/superpowers/specs/2026-11-20-prbar-ci-fix-and-cost-design.md` (partes K y O, con sus decisiones
K.6 y O.4). Se apoya en B (chat), C (CLI y paridad), E (reglas, prompts editables, `PromptFence`/`UntrustedText`),
I (Activity) y J (hosts remotos).

## Convenciones

- Build por producto: `swift build --product PRBar|PRBarCLI|PRBarTests` (sin warnings nuevos).
- Tests: `swift run PRBarTests [filtro]`; archivos nuevos al final de `allTests` en `Sources/PRBarTests/main.swift`.
- Nunca GitHub, Slack, Claude ni ssh de verdad: transportes y runners falsos (`Fakes.swift`, `FakeSSH.swift`).
- La CLI solo con `PRBAR_SOCKET` en una ruta temporal.
- `CommandProtocol.version` 5 → 6.
- Capturas: `Scripts/snapshots.sh docs/screenshots both`, mirar las nuevas y revertir los PNG que solo cambian bytes.
- Commits chicos en inglés, sin atribución.

## Estructura de archivos

```
Sources/PRBarCore/
  ClaudeUsage.swift        (nuevo) ClaudeUsage, ClaudeRunUsage, ClaudeUsageSink (@TaskLocal), ClaudeUsageCenter,
                                   ClaudeUsageEntry, UsageLedger (usage.json), UsageSummary, UsageFormat
  CIChecks.swift           (nuevo) CICheckFailure, CIChecksAPI (REST check-runs/statuses/logs), CILogSanitizer,
                                   CIFixContext, CIFixPrompt
  ClaudeStream.swift       (mod) ClaudeResult.usage
  ClaudeRunner.swift       (mod) medir cada intento y reportarlo
  JobScheduler.swift       (mod) id de trabajo y sink vivo
  ProcessActivity.swift    (mod) Kind.ciFix, .ciFix(prID)
  RespondModels.swift      (mod) RespondDraft.mode/ci, FeedbackItem.Kind.ciChecks, defaults sin respuesta
  RespondPipeline.swift    (mod) análisis CI, verificación del CI al pushear
  RespondQueue.swift       (mod) modo por PR, auto-implementación, uso por registro
  RespondPublisher.swift   (mod) saltear ítems CI
  FixImplementer.swift     (mod) prompt CI
  StagePrompts.swift, ClaudeOptions.swift (mod) etapa ciFix
  ReviewQueue.swift, ReviewModels.swift, ChatModels.swift, ChatCoordinator.swift (mod) uso
  AppCommand*.swift, CommandResults.swift, CommandDispatcher.swift, CommandActions.swift, CommandProtocol.swift (mod)
  NotificationPlanner.swift (mod) eventos de Fix CI
Sources/PRBarCLIKit/
  CICommands.swift, UsageCommands.swift (nuevos); CLIRouter.swift, StatusCommands.swift, Render.swift (mod)
Sources/PRBar/
  AppModel+CIFix.swift, AppModel+Usage.swift (nuevos); PRRowView, RespondButton, RespondWindow, ActivityWindow,
  HistoryWindow/HistoryDetailView/RespondHistoryDetailView, Snapshots (mod)
```

---

### Task 1: Uso de cada corrida (`ClaudeUsage`, parser, `ClaudeRunner`)

- [ ] Tests (`ClaudeUsageTests`): el parser lee `usage` y `total_cost_usd` de la línea `result`; sin `usage` →
  desconocido; suma de usos (costo `nil` si ninguno lo trae; `unknownRuns`); `ClaudeRunner` con un runner falso
  reporta a un `ClaudeUsageSink` del TaskLocal: una entrada por intento (también el reintento), con la duración y la
  etapa; un proceso sin `result` reporta solo la duración; los sinks anidados suman en el padre.
- [ ] `ClaudeUsage` (Codable, tolerante), `ClaudeUsageSink` (lock, padre), `ClaudeUsageCenter.shared` (observador
  opcional que pone la app; registra trabajos vivos).
- [ ] `ClaudeResult.usage`, `ClaudeRunner.attempt` mide y reporta (también si lanza).
- [ ] Commit: "Capture Claude's usage and cost for every run".

### Task 2: Trabajos, libro y totales por registro

- [ ] Tests: `JobScheduler` pone el id del trabajo y lo saca de los vivos al terminar o cancelar; `UsageLedger`
  guarda, recorta a 400 días, tolera JSON roto (`.bak`), suma un mes y arma las tareas recientes (una por trabajo);
  `ReviewDraft.usage`, `RespondRecord.usage`, `ChatSession.usage` se decodifican de JSON viejo como `nil`;
  `RespondQueue` suma el uso de análisis + implementación en el registro; `ReviewQueue` lo pone en el draft;
  `ChatCoordinator` lo suma a la sesión.
- [ ] Commit: "Keep a usage ledger and per-record Claude totals".

### Task 3: Modelo de Fix CI

- [ ] Tests (`CIFixTests`): `RespondDraft` viejo → `mode == .feedback`; `FeedbackItem.Kind.ciChecks` round-trip;
  defaults de un ítem CI = implementar sin responder; `postReplies` saltea ítems CI; `CILogSanitizer` (ANSI, control,
  bidi, prefijo de hora, tokens por formato, cola por líneas y caracteres, tope total); `CIChecksAPI` con transporte
  falso (paginado, fallidos, statuses, el 302 se sigue **sin** `Authorization` y solo a `https`); ítem armado de los
  checks.
- [ ] Commit: "Model Fix CI as a Respond run in CI mode".

### Task 4: Prompt CI y etapa editable

- [ ] Tests: `PromptStage.ciFix` (variables, sin obligatorias, título, `ruleStage == .respond`); el prompt de un ítem CI
  usa el cuerpo de `ciFix`, tiene la línea de seguridad de logs, los logs delimitados con el nonce y neutralizados
  (un log que imita `CI_LOG_…>>>` o "User rules" queda neutralizado), las reglas Fixes y el formato de un fix;
  `chatPrompts.ciFix` tolerante; `claude prompt` de la CLI acepta `ci-fix`.
- [ ] Commit: "Add the CI fix stage prompt".

### Task 5: Pipeline y cola

- [ ] Tests (`RespondQueue` con pipeline falso): `analyze(…, mode: .ciFix)` → al terminar arranca la implementación
  sola; `modes[prID] == .ciFix`; si la implementación no puede arrancar queda en `ready`; `dismiss` limpia el modo.
  `RespondPipeline` (repo git temporal + transporte falso): arma el draft CI en el head que falló, falla si el PR
  cambió de head mientras bajaba los logs, falla si no hay checks fallidos; `push` de un draft CI se niega si el head
  en GitHub cambió y si el CI ya pasa (salvo `anyway`).
- [ ] Commit: "Fetch failing checks and run Fix CI through the Respond pipeline".

### Task 6: Protocolo y CLI

- [ ] `AppCommand.ciFix(pr:wait:)`, `.ciList`, `.usage(month:)`; `respondPush`/`respondPushAnyway` cubren `ci push`.
  `CIListResult`, `UsageResult`; `usage` en `HistoryEntryInfo`, `HistoryDetail`, `RespondInfo`, `ReviewInfo`,
  `ResourcesInfo`. `CommandProtocol.version = 6`.
- [ ] CLI: `prbar ci list|fix|show|diff|test|push|cancel|dismiss`, `prbar usage [--month] [--json]`,
  `history --kind ci-fix`. Tests de parseo, render y paridad (`CLIParityTests`, `UIActionInventory`).
- [ ] Commit(s): "Add prbar ci and prbar usage".

### Task 7: App

- [ ] `AppModel`: `startCIFix`, `ciFixUnavailableReason`, `CIFixActions`, `UsageActions`, notificaciones, observador
  del libro, Stop de Activity para `.ciFix`.
- [ ] UI: botón **Fix CI** en la fila y el menú contextual; `RespondButton` con textos de CI; `RespondWindow` en modo CI
  (checks fallidos, sin respuestas, "Push", "Push Anyway" con CI en verde); Activity (tile, columna Cost, sección
  Claude usage); History (tiempo, tokens, costo).
- [ ] Commit(s).

### Task 8: Capturas, docs y QA

- [ ] Fixtures: fila con CI fallido y Fix CI, ventana de Fix CI lista para pushear, Activity con costos, History con
  costos. `Scripts/snapshots.sh docs/screenshots both`; mirar; revertir PNG solo de bytes.
- [ ] `docs/cli.md`, `docs/screenshots/README.md`, `docs/qa/plan-15-checklist.md`.
- [ ] `swift run PRBarTests` dos veces en verde; builds sin warnings.
