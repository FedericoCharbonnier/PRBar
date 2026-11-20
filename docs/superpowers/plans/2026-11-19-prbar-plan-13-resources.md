# PRBar — Plan 13: Recursos que consume PRBar (pie del popover y ventana Activity)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Una línea fija al pie del popover muestra la CPU, la RAM (de la app y todos sus procesos hijos) y el disco que ocupa PRBar; un clic abre la ventana **PRBar Activity** con cada proceso vivo y su tarea (con Stop por tarea) y el disco por categoría y por repo, con **Clean Up** seguro. Hay un aviso opcional cuando el disco pasa un umbral, y la CLI tiene `prbar resources` y `prbar cleanup`.

**Spec:** `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`, parte **I** (mientras otro agente la integra, el texto está en el scratchpad, `spec-part-H.md`, sección I). La Task 12 agrega **I.1 Decisiones de implementación (Plan 13)**. Se apoya en:
- Spec base §8.2 (raíz de worktrees `$TMPDIR/PRBar/worktrees`, nombres con id de corrida), **§8.5** (limpieza segura: `git worktree remove --force` del worktree propio, nunca `git worktree prune`), §14.2 (worktrees de Responder en `worktreeDir`, refs `refs/prbar/respond-*`).
- B.11 (Plan 6): los chats usan `JobScheduler` compartido y worktrees `chat-<repo>-<N>-<sesión>`.
- D (actualizaciones): clon `source/`, `update-staging/`, cancelación con `UpdateController.cancelInstall()`.
- C (CLI): `AppCommand`, `CLIRouter`, `UIActionInventory`, paridad.

**Orden de ejecución:** 11 → 12 → **13** → 14.

## Qué asume de los planes 11 y 12

| Plan | Artefacto | Cómo lo usa este plan |
|---|---|---|
| 11 | `CommandProtocol.version` (3) | **No** se sube: este plan solo agrega comandos nuevos (una app vieja contesta `unknownCommand`, que ya dice "Restart PRBar") y propiedades opcionales en resultados nuevos. |
| 11 | `history/merge/` (`MergeHistory`) | Cuenta como historial en el disco y entra en la limpieza de "más de N días" (Task 5 recorre todo `history/`). |
| 11 | `ChatSession.Kind.merge`, chats de merge que usan el `JobScheduler` de chats | Se etiquetan con `ProcessActivity.chat(prID)` como los otros (Task 9). |
| 11 | `AppConfig` sin `merge` (Task 3 del Plan 11) | `resources` va **al final** de `AppConfig` y en una línea `case resources` propia de `CodingKeys`. |
| 12 | `WindowAccessor` (`Sources/PRBar/Popover/WindowAccessor.swift`), `PopoverView.body` con `tabPicker`, `AppModel.popoverWindow` | El pie va dentro de `body`, después de `content` y antes de `UpdateRow`. La visibilidad del popover se toma de la ventana que ya informa `WindowAccessor`. |
| 12 | Entradas de `UIActionInventory` del bloque "// Popover" | Se agregan las del pie al final de ese bloque. |
| 12 | `AppModelServices.popoverDefaults` | Las propiedades nuevas de `AppModelServices` van después. |

**Si algo no está:** agregar al final de la lista/enum/`switch` y seguir; nada depende del contenido de esos planes salvo `WindowAccessor` (si el Plan 12 no está, crear ese archivo con el código de su Task 5 Step 4).

## Archivos compartidos con otros planes

- `Sources/PRBarCore/ProcessRunner.swift`: solo se agrega el registro de procesos en `execute` (el Plan 14 agrega entrada/salida por archivo en el mismo `execute`, después de este plan).
- `Sources/PRBarCore/JobScheduler.swift`: un parámetro nuevo con default.
- `Sources/PRBarCore/AppCommand.swift`: casos en una sección nueva "// Recursos (spec I)" y una línea nueva al final de `Name`.
- `Sources/PRBarCore/WorktreeManager.swift` / `WorktreeResolver.swift`: una línea de registro al preparar y otra al limpiar (el Plan 14 refactoriza estos archivos después: mantener las llamadas a `WorkspaceRegistry`).
- El Plan 14 usa `ProcessActivity.host` (creado acá) para marcar los trabajos remotos.

## Convenciones

- Build **por producto**: `swift build --product PRBar`, `swift build --product PRBarCLI`, `swift build --product PRBarTests` (un `swift build` pelado falla por el plugin de argument-parser). Sin warnings nuevos.
- Tests: `swift run PRBarTests [filtro]`. Archivos de tests nuevos al **final** de `allTests` en `Sources/PRBarTests/main.swift`. `expect`/`expectEqual` toman autoclosures **sin** `await`: hoistear a una variable local.
- **Nunca** correr la CLI sin `PRBAR_SOCKET` apuntando a un socket de prueba.
- Los tests **nunca** llaman a GitHub, Slack, Claude ni a hosts ssh de verdad. Los de procesos lanzan solo `/bin/sleep` y `/usr/bin/git` locales; los de disco usan carpetas temporales propias.
- Capturas: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y **mirar** con Read; para el repo `Scripts/snapshots.sh docs/screenshots both` y revertir PNG ajenos sin cambios reales.
- Commits en inglés, **sin** `Co-Authored-By` ni atribución a Claude/Anthropic. Sin push. En `main`.
- UI en inglés; comentarios en español (o inglés si el archivo ya lo está).

## Decisiones donde el spec era ambiguo (van a I.1 en la Task 12)

1. **Dónde está el disco de PRBar de verdad.** El spec habla de `~/Library/Application Support/PRBar` "(worktrees, …)", pero los worktrees de review/chat y las carpetas de contexto viven en `$TMPDIR/PRBar/worktrees` (§8.2: `~/Library` está negado a Claude) y los logs en `~/Library/Logs/PRBar`. Se mide: `Application Support/PRBar` (historial, clon y staging del updater, config/estado), `$TMPDIR/PRBar/worktrees` (+ la raíz vieja `~/Library/Caches/PRBar/worktrees`), `~/Library/Logs/PRBar` y los worktrees de Responder dentro de cada `worktreeDir` (por defecto `<localPath>-worktrees`), solo los que tienen nombre de PRBar.
2. **Categorías:** Worktrees (activos / huérfanos, por repo), Updater (clon `source/`, su `.build/` = "builds", `update-staging/`), History (`history/`, incluye logs de Claude y los registros de merge), Logs (`~/Library/Logs/PRBar`), App data (lo demás de Application Support). Los tamaños son **asignados en disco** (`totalFileAllocatedSize`), sin seguir symlinks.
3. **Activo vs. huérfano.** Activo = está en `WorkspaceRegistry` (lo anotan `WorktreeManager.prepare` y `WorktreeResolver.prepare` **antes** de crear la carpeta y lo borran sus `cleanup`), o es un worktree de Responder de un draft que la app tiene (aunque haya fallado: §14.2 los deja para revisar). Huérfano = tiene nombre de PRBar, no es activo y no se modificó en los últimos 5 minutos (margen para una corrida que está arrancando).
4. **Clean Up nunca toca** un worktree activo, ni uno de Responder con cambios sin commitear o con commits que no están en ninguna rama, remoto, tag ni `refs/prbar/*` (`git rev-list --count HEAD --not --branches --remotes --tags --glob=refs/prbar/*` ≠ 0): esos salen en "Skipped" con el motivo. Saca worktrees con `WorktreeManager.cleanup`/`WorktreeResolver.cleanup` (§8.5: `worktree remove --force` de ese worktree; nunca `git worktree prune`); las refs de corridas viejas no se tocan (las borra la limpieza del arranque).
5. **Updater:** `update-staging/` y `source/.build/` se borran solo si no hay una actualización en curso (`UpdateController` en `idle`/`failed`); el clon `source/` no se borra (la próxima actualización lo necesitaría entero).
6. **"Logs/historial de más de N días"**: archivos regulares de `history/` (registros y logs de Claude, de review, respond y merge) y de `~/Library/Logs/PRBar` cuya fecha de modificación es anterior a N días. Opcional: en la UI un toggle "Also delete history and logs older than [30] days"; en la CLI `--older-than 30d`. El log en uso (`prbar.log`) nunca se borra.
7. **Muestreo:** cada 2 s mientras el popover **o** la ventana Activity están en pantalla (contador de "consumidores"); se para en cuanto los dos se cierran. CPU = suma de `ri_user_time + ri_system_time` (`proc_pid_rusage`, convertidos con `mach_timebase_info`) de la app y su árbol de hijos (`proc_listchildpids`), dividida por el tiempo entre muestras: % de **un** núcleo, como Activity Monitor (puede pasar 100 %). RAM = suma de `ri_phys_footprint` (la "Memory" de Activity Monitor). Un proceso que nació entre muestras aporta todo su tiempo de CPU.
8. **Disco**: se calcula en segundo plano al abrir el popover o la ventana si el cálculo tiene más de 60 s, y otra vez al terminar un trabajo (review, respond, chat, update) si alguna de las dos está abierta. Nunca más de uno a la vez.
9. **Tarea de cada proceso:** `SystemProcessRunner` anota cada proceso que lanza con la `ProcessActivity` de la tarea (un `@TaskLocal` que ponen `JobScheduler` y los demás puntos de entrada). Los nietos (subagentes de Claude, `git` de un hook) heredan la del ancestro más cercano anotado. Sin anotación: "PRBar · <nombre>". La fila de la app misma es "PRBar".
10. **Stop por tarea:** Review → `cancelReview(prID:)`; Respond → `cancelRespond(prID:)`; Chat → `stop()` del coordinador de ese PR; Instructions chat → `instructionsChat.stop()`; Update build → `updates.cancelInstall()` (solo antes de reemplazar la app; después el botón queda deshabilitado con "Can’t stop while PRBar is being replaced"); Slack → sin Stop (es un post corto).
11. **Umbral:** Settings › General › "Warn when PRBar uses more than [N] GB" (apagado por defecto; 1–100 GB). Avisa con una notificación (`NotificationKind.diskUsage`, título "PRBar Is Using a Lot of Disk") **una vez** cada vez que el total cruza el umbral hacia arriba (no se repite hasta que baje y vuelva a subir). Clic → ventana Activity. CLI: `prbar config set disk-warning <GB|off>`.
12. **CLI:** `prbar resources` toma dos muestras con 1 s de diferencia si no hay una de menos de 3 s, y calcula el disco si el cálculo tiene más de 60 s. `prbar cleanup` muestra el plan (lo que borraría, lo que saltea y el total) y pide confirmación (sin terminal, `--yes`); al confirmar, la app **vuelve a armar** el plan y re-verifica cada ítem justo antes de borrarlo. Sin nada para limpiar: "Nothing to clean up." y exit 0.
13. **Protocolo:** sin cambio de versión (decisión de la tabla de arriba). Los comandos nuevos contra una app vieja dan el error de `unknownCommand`.

---

## Estructura de archivos

```
Sources/PRBarCore/
  ProcessActivity.swift      (nuevo) ProcessActivity (@TaskLocal), RegisteredProcess, ProcessRegistry
  ProcessSampling.swift      (nuevo) ProcessInfoProviding, ProcessStat, ProcessSample, ProcessTree, ProcessSampler,
                                     ResourceMeter, ResourceUsage, ProcessUsage, LiveProcessInfoProvider
  DiskUsage.swift            (nuevo) DiskCategoryKind, DiskItemState, DiskItem, DiskUsage, DiskScanInput, DiskScanner,
                                     WorkspaceRegistry
  DiskCleanup.swift          (nuevo) CleanupKind, CleanupCandidate, CleanupPlan, CleanupResult, DiskCleanup (plan),
                                     DiskCleanupExecutor
  ResourceMonitor.swift      (nuevo) ResourceMonitor (@MainActor), umbral
  ProcessRunner.swift        (modificar) registrar cada proceso lanzado
  JobScheduler.swift         (modificar) enqueue(…, activity:)
  WorktreeManager.swift, WorktreeResolver.swift (modificar) WorkspaceRegistry
  Config.swift               (modificar) ResourceSettings, AppConfig.resources
  NotificationPlanner.swift  (modificar) NotificationKind.diskUsage, diskWarning(…)
  AppCommand.swift, AppCommandTypes.swift, CommandActions.swift, CommandDispatcher.swift,
  CommandResults.swift       (modificar) resources, cleanupPreview, cleanup, setDiskWarning, ResourceActions, ResourcesInfo
  ReviewQueue.swift, RespondQueue.swift, ChatCoordinator.swift, InstructionsChatCoordinator.swift,
  SlackAnnouncer.swift       (modificar) etiquetas de tarea
Sources/PRBarCLIKit/
  ResourceCommands.swift     (nuevo) resources, cleanup
  ConfigCommands.swift, CLIRouter.swift, PRBarCLIKit.swift (modificar)
Sources/PRBar/
  AppModel+Resources.swift   (nuevo) monitor, acciones, Stop, Clean Up, umbral, ventana
  Activity/ActivityWindow.swift (nuevo) la ventana PRBar Activity
  Popover/ResourceFooter.swift  (nuevo) la línea del pie
  Popover/PopoverView.swift  (modificar) pie y visibilidad
  Settings/GeneralTab.swift  (modificar) umbral
  Update/UpdateController.swift (modificar) etiqueta "Update build"
  NotificationDelivery.swift (modificar) clic → Activity
  AppModel.swift             (modificar) resources
  Snapshots/*                (modificar) pie y ventana Activity con datos fijos
Sources/PRBarTests/
  ProcessActivityTests.swift, ProcessSamplingTests.swift, DiskUsageTests.swift, DiskCleanupTests.swift,
  ResourceMonitorTests.swift (nuevos); FakeActions, CommandDispatcherTests, CLIParsingTests, NotificationPlannerTests,
  ConfigTests, UIActionInventory, main.swift (modificar)
docs/cli.md, docs/screenshots/README.md, docs/qa/plan-13-checklist.md, spec (I.1)
```

---

### Task 1: Cada proceso lanzado sabe de qué tarea es (`ProcessActivity`, `ProcessRegistry`)

**Files:**
- Create: `Sources/PRBarCore/ProcessActivity.swift`
- Modify: `Sources/PRBarCore/ProcessRunner.swift`, `Sources/PRBarCore/JobScheduler.swift`
- Test: `Sources/PRBarTests/ProcessActivityTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.** `Sources/PRBarTests/ProcessActivityTests.swift`:

```swift
import Foundation
import PRBarCore

enum ProcessActivityTests {
    static let cases: [TestCase] = [
        TestCase("activity: títulos y PR corto") {
            try expectEqual(ProcessActivity.review("acme/api#317").title, "Review api#317")
            try expectEqual(ProcessActivity.respond("acme/web#2").title, "Respond web#2")
            try expectEqual(ProcessActivity.chat("acme/api#4").title, "Chat api#4")
            try expectEqual(ProcessActivity.update.title, "Update build")
            try expectEqual(ProcessActivity.review("acme/api#1").on(host: "devbox").host, "devbox")
        },
        TestCase("activity: el runner anota el proceso con la tarea mientras corre y lo borra al terminar") {
            let registry = ProcessRegistry()
            let runner = SystemProcessRunner(registry: registry)
            let task = Task {
                try await ProcessActivity.$current.withValue(.review("acme/api#9")) {
                    try await runner.run("/bin/sleep", ["1"], timeout: 10)
                }
            }
            var seen: RegisteredProcess?
            for _ in 0..<40 where seen == nil {
                try await Task.sleep(for: .milliseconds(25))
                seen = registry.all().first
            }
            try expectEqual(seen?.executable, "sleep")
            try expectEqual(seen?.activity, .review("acme/api#9"))
            _ = try await task.value
            let after = registry.all()
            try expect(after.isEmpty, "quedó anotado: \(after)")
        },
        TestCase("activity: un proceso sin tarea queda anotado sin actividad") {
            let registry = ProcessRegistry()
            let runner = SystemProcessRunner(registry: registry)
            let task = Task { try await runner.run("/bin/sleep", ["1"], timeout: 10) }
            var seen: RegisteredProcess?
            for _ in 0..<40 where seen == nil {
                try await Task.sleep(for: .milliseconds(25))
                seen = registry.all().first
            }
            try expect(seen != nil)
            try expectEqual(seen?.activity, nil)
            _ = try await task.value
        },
        TestCase("activity: JobScheduler corre el trabajo con su actividad") { @MainActor in
            let scheduler = JobScheduler<String>(maxConcurrent: 1)
            let seen = JobOutcomeProbe()
            let done = AsyncStream<Void>.makeStream()
            scheduler.enqueue("k", activity: .chat("acme/api#1"), onStart: {}, work: {
                seen.set(ProcessActivity.current)
            }, onComplete: { _ in done.continuation.finish() })
            for await _ in done.stream {}
            try expectEqual(seen.get(), .chat("acme/api#1"))
        },
    ]
}

/// Guarda un valor escrito desde la tarea del trabajo.
final class JobOutcomeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ProcessActivity?
    func set(_ new: ProcessActivity?) { lock.withLock { value = new } }
    func get() -> ProcessActivity? { lock.withLock { value } }
}
```

En `main.swift`, al final de `allTests`: `+ ProcessActivityTests.cases`.

- [ ] **Step 2:** `swift build --product PRBarTests 2>&1 | grep error: | head -3` → `cannot find 'ProcessActivity'`.

- [ ] **Step 3: `Sources/PRBarCore/ProcessActivity.swift`:**

```swift
import Foundation
import os

/// La tarea de PRBar a la que pertenece un proceso (spec I: "Review api#317 · claude"). Se propaga con un
/// `@TaskLocal`: quien arranca una tarea (`JobScheduler`, el updater, Slack) la pone y `SystemProcessRunner` la anota
/// junto al pid de cada proceso que lanza.
public struct ProcessActivity: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case review, respond, chat, instructions, update, slack
    }

    public var kind: Kind
    public var prID: String?
    public var title: String
    /// El host remoto donde corre el trabajo (Plan 14); `nil` = esta Mac.
    public var host: String?

    public init(kind: Kind, prID: String? = nil, title: String, host: String? = nil) {
        self.kind = kind
        self.prID = prID
        self.title = title
        self.host = host
    }

    @TaskLocal public static var current: ProcessActivity?

    public static func review(_ prID: String) -> ProcessActivity { .init(kind: .review, prID: prID, title: "Review \(shortPR(prID))") }
    public static func respond(_ prID: String) -> ProcessActivity { .init(kind: .respond, prID: prID, title: "Respond \(shortPR(prID))") }
    public static func chat(_ prID: String) -> ProcessActivity { .init(kind: .chat, prID: prID, title: "Chat \(shortPR(prID))") }
    public static let instructions = ProcessActivity(kind: .instructions, title: "Instructions chat")
    public static let update = ProcessActivity(kind: .update, title: "Update build")
    public static let slack = ProcessActivity(kind: .slack, title: "Slack")

    /// `acme/api#317` → `api#317`.
    public static func shortPR(_ prID: String) -> String {
        prID.split(separator: "/").last.map(String.init) ?? prID
    }

    public func on(host: String?) -> ProcessActivity {
        var copy = self
        copy.host = host
        return copy
    }
}

/// Un proceso que lanzó PRBar y sigue vivo.
public struct RegisteredProcess: Equatable, Sendable {
    public var pid: Int32
    public var executable: String
    public var activity: ProcessActivity?
    public var startedAt: Date

    public init(pid: Int32, executable: String, activity: ProcessActivity?, startedAt: Date) {
        self.pid = pid
        self.executable = executable
        self.activity = activity
        self.startedAt = startedAt
    }
}

/// Los procesos vivos que lanzó `SystemProcessRunner`, con su tarea. Seguro entre hilos.
public final class ProcessRegistry: Sendable {
    public static let shared = ProcessRegistry()

    private let state = OSAllocatedUnfairLock(initialState: [Int32: RegisteredProcess]())

    public init() {}

    public func register(_ process: RegisteredProcess) { state.withLock { $0[process.pid] = process } }
    public func unregister(pid: Int32) { _ = state.withLock { $0.removeValue(forKey: pid) } }
    public func all() -> [RegisteredProcess] { state.withLock { Array($0.values) }.sorted { $0.pid < $1.pid } }
    public func byPID() -> [Int32: RegisteredProcess] { state.withLock { $0 } }
}
```

- [ ] **Step 4: `SystemProcessRunner`.** En `Sources/PRBarCore/ProcessRunner.swift`:
  - propiedad y `init`:

```swift
    /// Dónde se anotan los procesos lanzados y su tarea (ventana Activity, spec I).
    public let registry: ProcessRegistry

    public init(killGracePeriod: TimeInterval = 2, registry: ProcessRegistry = .shared) {
        self.killGracePeriod = killGracePeriod
        self.registry = registry
    }
```
  - en `execute`, antes de `return try await withTaskCancellationHandler {`:

```swift
        let activity = ProcessActivity.current
        let registry = self.registry
        let executableName = URL(fileURLWithPath: executable).lastPathComponent
```
  - después de `control.markLaunched(pid: process.processIdentifier)`:

```swift
                let pid = process.processIdentifier
                registry.register(RegisteredProcess(pid: pid, executable: executableName, activity: activity, startedAt: Date()))
```
  - dentro del `DispatchQueue.global().async { … }`, justo después de `control.waitUntilExited()`: `registry.unregister(pid: pid)`.

- [ ] **Step 5: `JobScheduler`.** En `Pending` agregar `let activity: ProcessActivity?`. `enqueue` gana el parámetro `activity: ProcessActivity? = nil` **antes** de `onStart:` y lo guarda en `Pending(…)`. En `start(_:)`: `let activity = job.activity` y, dentro del `Task`, `try await work()` pasa a:

```swift
                try await ProcessActivity.$current.withValue(activity) { try await work() }
```

- [ ] **Step 6:** `swift build --product PRBarTests && swift run PRBarTests activity` → `4/4 passed`. Correr también `swift run PRBarTests "job scheduler"` y `swift run PRBarTests process` (los de antes siguen pasando).

- [ ] **Step 7: Commit.**

```bash
git add Sources/PRBarCore/ProcessActivity.swift Sources/PRBarCore/ProcessRunner.swift Sources/PRBarCore/JobScheduler.swift Sources/PRBarTests/ProcessActivityTests.swift Sources/PRBarTests/main.swift
git commit -m "Tag every process PRBar launches with its task"
```

---

### Task 2: Árbol de procesos y CPU/RAM (`ProcessSampler`, `ResourceMeter`)

**Files:**
- Create: `Sources/PRBarCore/ProcessSampling.swift`
- Test: `Sources/PRBarTests/ProcessSamplingTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan** (con un proveedor falso; ningún proceso real):

```swift
import Foundation
import PRBarCore

/// Árbol y contadores escritos a mano.
final class FakeProcessInfo: ProcessInfoProviding, @unchecked Sendable {
    private let lock = NSLock()
    var children: [Int32: [Int32]] = [:]
    var stats: [Int32: ProcessStat] = [:]
    private(set) var statCalls = 0

    func children(of pid: Int32) -> [Int32] { lock.withLock { children[pid] ?? [] } }
    func stat(of pid: Int32) -> ProcessStat? { lock.withLock { statCalls += 1; return stats[pid] } }
    func set(_ pid: Int32, cpu: UInt64, memory: UInt64, name: String = "x") {
        lock.withLock { stats[pid] = ProcessStat(pid: pid, name: name, cpuNanos: cpu, memoryBytes: memory, startedAt: t0) }
    }
}

enum ProcessSamplingTests {
    static let cases: [TestCase] = [
        TestCase("sampling: el árbol junta hijos y nietos sin repetir ni colgarse con un ciclo") {
            let info = FakeProcessInfo()
            info.children = [1: [2, 3], 2: [4], 4: [2]]   // 4 → 2: un ciclo (pid reusado)
            let tree = ProcessTree.descendants(of: 1, provider: info)
            try expectEqual(Set(tree.keys), [1, 2, 3, 4])
            try expectEqual(tree[4], 2)
            try expectEqual(tree[1], 0)
        },
        TestCase("sampling: CPU = delta de tiempo de CPU sobre el tiempo entre muestras, sumado; RAM sumada") {
            let info = FakeProcessInfo()
            info.children = [1: [2]]
            info.set(1, cpu: 1_000_000_000, memory: 100, name: "PRBar")
            info.set(2, cpu: 2_000_000_000, memory: 300, name: "claude")
            let sampler = ProcessSampler(provider: info, root: 1)
            let first = sampler.sample(at: t0)
            info.set(1, cpu: 1_100_000_000, memory: 120, name: "PRBar")      // +0,1 s en 2 s = 5 %
            info.set(2, cpu: 3_000_000_000, memory: 500, name: "claude")     // +1 s en 2 s = 50 %
            let second = sampler.sample(at: t0.addingTimeInterval(2))
            let registered = [Int32(2): RegisteredProcess(pid: 2, executable: "claude", activity: .review("acme/api#317"), startedAt: t0)]
            let usage = ResourceMeter.usage(previous: first, current: second, registered: registered)
            try expect(abs(usage.cpuPercent - 55) < 0.001, "cpu \(usage.cpuPercent)")
            try expectEqual(usage.memoryBytes, 620)
            let claude = usage.processes.first { $0.pid == 2 }
            try expectEqual(claude?.label, "Review api#317 · claude")
            try expectEqual(usage.processes.first { $0.pid == 1 }?.label, "PRBar")
        },
        TestCase("sampling: un nieto hereda la tarea del ancestro anotado; uno sin tarea es PRBar · nombre") {
            let info = FakeProcessInfo()
            info.children = [1: [2, 5], 2: [3]]
            for pid: Int32 in [1, 2, 3, 5] { info.set(pid, cpu: 0, memory: 1, name: pid == 5 ? "git" : "node") }
            let sample = ProcessSampler(provider: info, root: 1).sample(at: t0)
            let registered = [Int32(2): RegisteredProcess(pid: 2, executable: "claude", activity: .respond("acme/web#2"), startedAt: t0)]
            let usage = ResourceMeter.usage(previous: nil, current: sample, registered: registered)
            try expectEqual(usage.processes.first { $0.pid == 3 }?.activity, .respond("acme/web#2"))
            try expectEqual(usage.processes.first { $0.pid == 5 }?.label, "PRBar · git")
        },
        TestCase("sampling: un proceso que nació entre muestras aporta todo su tiempo; uno remoto no suma") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 10)
            let sampler = ProcessSampler(provider: info, root: 1)
            let first = sampler.sample(at: t0)
            info.children = [1: [7, 8]]
            info.set(7, cpu: 500_000_000, memory: 40, name: "git")
            info.set(8, cpu: 900_000_000, memory: 30, name: "ssh")
            let second = sampler.sample(at: t0.addingTimeInterval(1))
            let registered = [Int32(8): RegisteredProcess(pid: 8, executable: "ssh", activity: ProcessActivity.review("acme/api#1").on(host: "devbox"), startedAt: t0)]
            let usage = ResourceMeter.usage(previous: first, current: second, registered: registered)
            try expect(abs(usage.cpuPercent - 50) < 0.001, "cpu \(usage.cpuPercent)")
            try expectEqual(usage.memoryBytes, 50)
            let remote = usage.processes.first { $0.pid == 8 }
            try expectEqual(remote?.remoteHost, "devbox")
            try expectEqual(remote?.cpuPercent, 0)
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find type 'ProcessInfoProviding'`.

- [ ] **Step 3: `Sources/PRBarCore/ProcessSampling.swift`** (la parte sin libproc; `LiveProcessInfoProvider` va en la Task 3):

```swift
import Foundation

/// Lo que se lee de un proceso.
public struct ProcessStat: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    /// Tiempo de CPU acumulado (usuario + sistema), en nanosegundos.
    public var cpuNanos: UInt64
    /// `ri_phys_footprint` (la "Memory" de Activity Monitor).
    public var memoryBytes: UInt64
    public var startedAt: Date?

    public init(pid: Int32, name: String, cpuNanos: UInt64, memoryBytes: UInt64, startedAt: Date?) {
        self.pid = pid
        self.name = name
        self.cpuNanos = cpuNanos
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
    }
}

public protocol ProcessInfoProviding: Sendable {
    func children(of pid: Int32) -> [Int32]
    func stat(of pid: Int32) -> ProcessStat?
}

/// La app y sus descendientes: pid → pid del padre (0 para la raíz).
public enum ProcessTree {
    public static func descendants(of root: Int32, provider: ProcessInfoProviding, limit: Int = 2048) -> [Int32: Int32] {
        var parents: [Int32: Int32] = [root: 0]
        var queue = [root]
        while !queue.isEmpty, parents.count < limit {
            let pid = queue.removeFirst()
            for child in provider.children(of: pid) where child > 0 && parents[child] == nil {
                parents[child] = pid
                queue.append(child)
            }
        }
        return parents
    }
}

public struct ProcessSample: Sendable {
    public var date: Date
    public var parents: [Int32: Int32]
    public var stats: [Int32: ProcessStat]
}

public struct ProcessSampler: Sendable {
    let provider: ProcessInfoProviding
    let root: Int32

    public init(provider: ProcessInfoProviding, root: Int32 = getpid()) {
        self.provider = provider
        self.root = root
    }

    public func sample(at date: Date = Date()) -> ProcessSample {
        let parents = ProcessTree.descendants(of: root, provider: provider)
        var stats: [Int32: ProcessStat] = [:]
        for pid in parents.keys { stats[pid] = provider.stat(of: pid) }
        return ProcessSample(date: date, parents: parents, stats: stats)
    }
}

public struct ProcessUsage: Codable, Equatable, Sendable, Identifiable {
    public var pid: Int32
    public var name: String
    public var activity: ProcessActivity?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var startedAt: Date?
    public var isApp: Bool

    public var id: Int32 { pid }
    /// Los trabajos remotos (Plan 14) se muestran "on <host>" y sin CPU/RAM locales.
    public var remoteHost: String? { activity?.host }
    public var label: String { isApp ? "PRBar" : "\(activity?.title ?? "PRBar") · \(name)" }
}

public struct ResourceUsage: Codable, Equatable, Sendable {
    /// % de un núcleo (como Activity Monitor; puede pasar 100).
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var processes: [ProcessUsage]
    public var sampledAt: Date

    public init(cpuPercent: Double, memoryBytes: UInt64, processes: [ProcessUsage], sampledAt: Date) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processes = processes
        self.sampledAt = sampledAt
    }
}

public enum ResourceMeter {
    /// `previous == nil`: CPU 0 (no hay con qué comparar). Los procesos de un trabajo remoto no suman.
    public static func usage(previous: ProcessSample?, current: ProcessSample,
                             registered: [Int32: RegisteredProcess]) -> ResourceUsage {
        let elapsed = previous.map { current.date.timeIntervalSince($0.date) } ?? 0
        var rows: [ProcessUsage] = []
        for (pid, stat) in current.stats {
            let activity = activity(of: pid, parents: current.parents, registered: registered)
            var cpu = 0.0
            if let previous, elapsed > 0 {
                let before = previous.stats[pid].map(\.cpuNanos) ?? 0
                let delta = stat.cpuNanos >= before ? stat.cpuNanos - before : 0
                cpu = Double(delta) / (elapsed * 1_000_000_000) * 100
            }
            let remote = activity?.host != nil
            rows.append(ProcessUsage(pid: pid, name: stat.name, activity: activity, cpuPercent: remote ? 0 : cpu,
                                     memoryBytes: remote ? 0 : stat.memoryBytes, startedAt: stat.startedAt,
                                     isApp: current.parents[pid] == 0))
        }
        rows.sort { ($0.isApp ? 0 : 1, $0.activity?.title ?? "~", $0.pid) < ($1.isApp ? 0 : 1, $1.activity?.title ?? "~", $1.pid) }
        return ResourceUsage(cpuPercent: rows.map(\.cpuPercent).reduce(0, +), memoryBytes: rows.map(\.memoryBytes).reduce(0, +),
                             processes: rows, sampledAt: current.date)
    }

    /// La del propio proceso o la del ancestro anotado más cercano.
    static func activity(of pid: Int32, parents: [Int32: Int32], registered: [Int32: RegisteredProcess]) -> ProcessActivity? {
        var current = pid
        var steps = 0
        while current > 0, steps < 64 {
            if let activity = registered[current]?.activity { return activity }
            current = parents[current] ?? 0
            steps += 1
        }
        return nil
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests sampling` → `4/4 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/ProcessSampling.swift Sources/PRBarTests/ProcessSamplingTests.swift Sources/PRBarTests/main.swift
git commit -m "Sum CPU and memory over PRBar's process tree"
```

---

### Task 3: Lectura real de procesos con `libproc` (`LiveProcessInfoProvider`)

**Files:**
- Modify: `Sources/PRBarCore/ProcessSampling.swift`
- Test: `Sources/PRBarTests/ProcessSamplingTests.swift`

- [ ] **Step 1: Test que falla** (lanza un `sleep` local, nada más):

```swift
        TestCase("sampling: libproc ve a un hijo de verdad con su nombre, CPU y memoria") {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sleep")
            child.arguments = ["5"]
            try child.run()
            defer { child.terminate() }
            let provider = LiveProcessInfoProvider()
            let children = provider.children(of: getpid())
            try expect(children.contains(child.processIdentifier), "hijos: \(children)")
            let stat = provider.stat(of: child.processIdentifier)
            try expectEqual(stat?.name, "sleep")
            try expect((stat?.memoryBytes ?? 0) > 0)
            try expect(stat?.startedAt != nil)
            let me = provider.stat(of: getpid())
            try expect((me?.cpuNanos ?? 0) > 0)
            try expectEqual(provider.stat(of: 999_999), nil)
        },
```

- [ ] **Step 2:** build → `cannot find 'LiveProcessInfoProvider'`.

- [ ] **Step 3: Implementación** (al final de `ProcessSampling.swift`):

```swift
import Darwin

/// `proc_listchildpids`, `proc_pid_rusage` y `proc_pidinfo` (sin `ps`). Los tiempos de `rusage_info` vienen en
/// unidades de `mach_absolute_time` (en Apple Silicon no son nanosegundos): se convierten con `mach_timebase_info`.
public struct LiveProcessInfoProvider: ProcessInfoProviding {
    public init() {}

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let base = timebase
        guard base.denom != 0 else { return ticks }
        return ticks / UInt64(base.denom) * UInt64(base.numer) + ticks % UInt64(base.denom) * UInt64(base.numer) / UInt64(base.denom)
    }

    public func children(of pid: Int32) -> [Int32] {
        var capacity = 256
        while capacity <= 65_536 {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            if count < 0 { return [] }
            if Int(count) < capacity { return buffer.prefix(Int(count)).filter { $0 > 0 } }
            capacity *= 2
        }
        return []
    }

    public func stat(of pid: Int32) -> ProcessStat? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return nil }
        var name = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &name, UInt32(name.count))
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let started: Date? = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size
            ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
            : nil
        return ProcessStat(pid: pid, name: length > 0 ? String(cString: name) : "?",
                           cpuNanos: Self.nanoseconds(usage.ri_user_time &+ usage.ri_system_time),
                           memoryBytes: usage.ri_phys_footprint, startedAt: started)
    }
}
```

(mover el `import Darwin` arriba del archivo, junto a `import Foundation`).

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests sampling` → `5/5 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/ProcessSampling.swift Sources/PRBarTests/ProcessSamplingTests.swift
git commit -m "Read process CPU and memory with libproc"
```

---

### Task 4: Disco por categoría y worktrees activos (`DiskScanner`, `WorkspaceRegistry`)

**Files:**
- Create: `Sources/PRBarCore/DiskUsage.swift`
- Modify: `Sources/PRBarCore/WorktreeManager.swift`, `Sources/PRBarCore/WorktreeResolver.swift`
- Test: `Sources/PRBarTests/DiskUsageTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

private func write(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x61, count: bytes).write(to: url)
}

/// Carpetas como las de PRBar, en un temporal.
private struct Layout {
    let base: URL
    var appSupport: URL { base.appendingPathComponent("AppSupport") }
    var worktrees: URL { base.appendingPathComponent("tmp/PRBar/worktrees") }
    var logs: URL { base.appendingPathComponent("Logs/PRBar") }
    var respondDir: URL { base.appendingPathComponent("code/web-worktrees") }

    func input(active: Set<String> = []) -> DiskScanInput {
        DiskScanInput(appSupport: appSupport, worktreeRoots: [worktrees], logsDir: logs,
                      respondDirs: [DiskScanInput.RespondDir(repo: "acme/web", path: respondDir.path, localPath: base.appendingPathComponent("code/web").path)],
                      activePaths: active, now: Date().addingTimeInterval(3600))
    }
}

enum DiskUsageTests {
    static let cases: [TestCase] = [
        TestCase("disk: categorías, activos y huérfanos, y nada fuera de las carpetas de PRBar") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let layout = Layout(base: base)
            try write(layout.appSupport.appendingPathComponent("history/review/a.json"), bytes: 10_000)
            try write(layout.appSupport.appendingPathComponent("source/.build/x.o"), bytes: 20_000)
            try write(layout.appSupport.appendingPathComponent("source/Package.swift"), bytes: 1_000)
            try write(layout.appSupport.appendingPathComponent("update-staging/PRBar.app/bin"), bytes: 5_000)
            try write(layout.appSupport.appendingPathComponent("config.json"), bytes: 500)
            try write(layout.logs.appendingPathComponent("prbar.log"), bytes: 3_000)
            let active = layout.worktrees.appendingPathComponent("api-317-1800000000-1a2b3c4d")
            let orphan = layout.worktrees.appendingPathComponent("api-300-1700000000-deadbeef")
            try write(active.appendingPathComponent("f.txt"), bytes: 4_000)
            try write(orphan.appendingPathComponent("f.txt"), bytes: 8_000)
            try write(layout.worktrees.appendingPathComponent("notes.txt"), bytes: 100)   // no es de PRBar
            try write(layout.respondDir.appendingPathComponent("web-2-respond-0a0b0c0d/f.txt"), bytes: 6_000)
            try write(layout.respondDir.appendingPathComponent("my-own-worktree/f.txt"), bytes: 9_000)   // del usuario
            let usage = DiskScanner.scan(layout.input(active: [active.path]))
            func item(_ path: URL) -> DiskItem? { usage.items.first { $0.path == path.standardizedFileURL.path } }
            try expectEqual(item(active)?.state, .active)
            try expectEqual(item(orphan)?.state, .orphan)
            try expectEqual(item(layout.respondDir.appendingPathComponent("web-2-respond-0a0b0c0d"))?.repo, "acme/web")
            try expect(usage.items.allSatisfy { !$0.path.hasSuffix("my-own-worktree") && !$0.path.hasSuffix("notes.txt") })
            try expect(usage.bytes(.history) >= 10_000)
            try expect(usage.bytes(.updater) >= 26_000)
            try expect(usage.bytes(.logs) >= 3_000)
            try expect(usage.bytes(.appData) >= 500 && usage.bytes(.appData) < 10_000, "app data \(usage.bytes(.appData))")
            try expectEqual(usage.total, DiskCategoryKind.allCases.map { usage.bytes($0) }.reduce(0, +))
            try expect(item(layout.appSupport.appendingPathComponent("source/.build"))?.state == .cache)
        },
        TestCase("disk: no sigue symlinks") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let big = base.appendingPathComponent("outside/big.bin")
            try write(big, bytes: 2_000_000)
            let dir = base.appendingPathComponent("inside")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("outside"))
            try expect(DiskScanner.allocatedSize(dir) < 100_000)
        },
        TestCase("disk: un worktree recién creado (menos de 5 min) no es huérfano") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let layout = Layout(base: base)
            let fresh = layout.worktrees.appendingPathComponent("api-1-1800000000-0f0f0f0f")
            try write(fresh.appendingPathComponent("f"), bytes: 10)
            var input = layout.input()
            input.now = Date()
            try expectEqual(DiskScanner.scan(input).items.first { $0.path == fresh.standardizedFileURL.path }?.state, .active)
        },
        TestCase("disk: el registro de workspaces anota y borra") {
            let registry = WorkspaceRegistry()
            registry.insert("/tmp/x/../a")
            try expect(registry.contains("/tmp/a"))
            registry.remove("/tmp/a")
            try expect(!registry.contains("/tmp/a"))
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'DiskScanner'`.

- [ ] **Step 3: `Sources/PRBarCore/DiskUsage.swift`:**

```swift
import Foundation
import os

public enum DiskCategoryKind: String, Codable, CaseIterable, Sendable {
    case worktrees, updater, history, logs, appData

    public var title: String {
        switch self {
        case .worktrees: "Worktrees"
        case .updater: "Updater"
        case .history: "History"
        case .logs: "Logs"
        case .appData: "App data"
        }
    }
}

public enum DiskItemState: String, Codable, Sendable {
    /// Un worktree o carpeta de una corrida en curso (o de un draft que la app tiene).
    case active
    /// Con nombre de PRBar y sin corrida: Clean Up lo puede borrar.
    case orphan
    /// Reconstruible (staging y builds del updater).
    case cache
    /// Datos (historial, logs, config): solo se borra lo viejo, a pedido.
    case data
}

public struct DiskItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var kind: DiskCategoryKind
    public var state: DiskItemState
    public var repo: String?
    /// El clone del usuario al que pertenece el worktree (para sacarlo con git).
    public var clone: String?
    public var title: String

    public var id: String { path }
}

public struct DiskUsage: Codable, Equatable, Sendable {
    public var items: [DiskItem]
    public var scannedAt: Date

    public var total: Int64 { items.map(\.bytes).reduce(0, +) }
    public func bytes(_ kind: DiskCategoryKind) -> Int64 { items.filter { $0.kind == kind }.map(\.bytes).reduce(0, +) }
    /// Worktrees por repo ("Other" sin repo conocido).
    public var worktreesByRepo: [(repo: String, bytes: Int64)] {
        Dictionary(grouping: items.filter { $0.kind == .worktrees }, by: { $0.repo ?? "Other" })
            .map { ($0.key, $0.value.map(\.bytes).reduce(0, +)) }
            .sorted { $0.bytes > $1.bytes }
    }
}

public struct DiskScanInput: Sendable {
    public struct RespondDir: Sendable {
        public var repo: String
        public var path: String
        public var localPath: String?
        public init(repo: String, path: String, localPath: String?) {
            self.repo = repo
            self.path = path
            self.localPath = localPath
        }
    }

    public var appSupport: URL
    /// `$TMPDIR/PRBar/worktrees` y la raíz vieja de `~/Library/Caches`.
    public var worktreeRoots: [URL]
    public var logsDir: URL
    public var respondDirs: [RespondDir]
    /// `WorkspaceRegistry` + los worktrees de los drafts de Responder que tiene la app.
    public var activePaths: Set<String>
    /// clone → `owner/repo`, para poner el repo en los worktrees de la raíz temporal.
    public var repoByClone: [String: String]
    public var now: Date

    public init(appSupport: URL, worktreeRoots: [URL], logsDir: URL, respondDirs: [RespondDir], activePaths: Set<String>,
                repoByClone: [String: String] = [:], now: Date = Date()) {
        self.appSupport = appSupport
        self.worktreeRoots = worktreeRoots
        self.logsDir = logsDir
        self.respondDirs = respondDirs
        self.activePaths = activePaths
        self.repoByClone = repoByClone
        self.now = now
    }

    public static func live(respondDirs: [RespondDir], activePaths: Set<String>, repoByClone: [String: String]) -> DiskScanInput {
        DiskScanInput(appSupport: AppPaths.appSupport, worktreeRoots: [AppPaths.worktreesDir, AppPaths.legacyWorktreesDir],
                      logsDir: AppPaths.logFile.deletingLastPathComponent(), respondDirs: respondDirs,
                      activePaths: activePaths, repoByClone: repoByClone)
    }
}

public enum DiskScanner {
    /// Margen para una corrida que está arrancando (decisión I.1.3).
    public static let freshInterval: TimeInterval = 5 * 60

    /// Bytes asignados de `url` y todo lo de adentro, sin seguir symlinks.
    public static func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey, .isDirectoryKey]
        func size(_ item: URL) -> Int64 {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total = size(url)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else {
            return total
        }
        for case let item as URL in enumerator { total += size(item) }
        return total
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// El clone de un worktree, del archivo `.git` (`gitdir: <clone>/.git/worktrees/<nombre>`). Lee a lo sumo 4 KB y
    /// solo si `.git` es un archivo regular (no sigue symlinks).
    public static func cloneOfWorktree(_ directory: URL) -> String? {
        let dotGit = directory.appendingPathComponent(".git")
        var info = stat()
        guard lstat(dotGit.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096,
              let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
        let gitdir = String(line.dropFirst("gitdir: ".count))
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }

    public static func scan(_ input: DiskScanInput) -> DiskUsage {
        var items: [DiskItem] = []
        let files = FileManager.default
        let active = Set(input.activePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })

        func state(_ url: URL) -> DiskItemState {
            if active.contains(url.standardizedFileURL.path) { return .active }
            if let date = modified(url), input.now.timeIntervalSince(date) < freshInterval { return .active }
            return .orphan
        }

        // Worktrees y carpetas de contexto de review/chat (raíz temporal).
        for root in input.worktreeRoots {
            for entry in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let name = entry.lastPathComponent
                guard WorktreeManager.isWorkspaceName(name) else { continue }
                let clone = cloneOfWorktree(entry)
                items.append(DiskItem(path: entry.standardizedFileURL.path, bytes: allocatedSize(entry), kind: .worktrees,
                                      state: state(entry), repo: clone.flatMap { input.repoByClone[$0] }, clone: clone, title: name))
            }
        }
        // Worktrees de Responder (solo los que tienen nombre de PRBar).
        for dir in input.respondDirs {
            let url = URL(fileURLWithPath: dir.path)
            for entry in (try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            where WorktreeResolver.isRespondWorktreeName(entry.lastPathComponent) {
                items.append(DiskItem(path: entry.standardizedFileURL.path, bytes: allocatedSize(entry), kind: .worktrees,
                                      state: state(entry), repo: dir.repo, clone: dir.localPath, title: entry.lastPathComponent))
            }
        }
        // Application Support.
        let support = input.appSupport
        let source = support.appendingPathComponent("source")
        let build = source.appendingPathComponent(".build")
        let staging = support.appendingPathComponent("update-staging")
        let history = support.appendingPathComponent("history")
        let buildBytes = allocatedSize(build)
        if buildBytes > 0 {
            items.append(DiskItem(path: build.standardizedFileURL.path, bytes: buildBytes, kind: .updater, state: .cache, title: "Updater builds"))
        }
        let sourceBytes = allocatedSize(source) - buildBytes
        if sourceBytes > 0 {
            items.append(DiskItem(path: source.standardizedFileURL.path, bytes: sourceBytes, kind: .updater, state: .data, title: "Updater clone"))
        }
        let stagingBytes = allocatedSize(staging)
        if stagingBytes > 0 {
            items.append(DiskItem(path: staging.standardizedFileURL.path, bytes: stagingBytes, kind: .updater, state: .cache, title: "Update staging"))
        }
        let historyBytes = allocatedSize(history)
        if historyBytes > 0 {
            items.append(DiskItem(path: history.standardizedFileURL.path, bytes: historyBytes, kind: .history, state: .data, title: "History"))
        }
        let rest = allocatedSize(support) - allocatedSize(source) - stagingBytes - historyBytes
        if rest > 0 {
            items.append(DiskItem(path: support.standardizedFileURL.path, bytes: rest, kind: .appData, state: .data, title: "Settings and state"))
        }
        let logBytes = allocatedSize(input.logsDir)
        if logBytes > 0 {
            items.append(DiskItem(path: input.logsDir.standardizedFileURL.path, bytes: logBytes, kind: .logs, state: .data, title: "Logs"))
        }
        return DiskUsage(items: items, scannedAt: input.now)
    }
}

/// Las carpetas de worktrees y de contexto que tiene una corrida en curso (spec I: Clean Up nunca las toca). Las
/// anotan `WorktreeManager.prepare`/`WorktreeResolver.prepare` antes de crearlas y las borran sus `cleanup`.
public final class WorkspaceRegistry: Sendable {
    public static let shared = WorkspaceRegistry()

    private let paths = OSAllocatedUnfairLock(initialState: Set<String>())

    public init() {}

    private static func key(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    public func insert(_ path: String) { _ = paths.withLock { $0.insert(Self.key(path)) } }
    public func remove(_ path: String) { _ = paths.withLock { $0.remove(Self.key(path)) } }
    public func contains(_ path: String) -> Bool { paths.withLock { $0.contains(Self.key(path)) } }
    public func all() -> Set<String> { paths.withLock { $0 } }
}
```

> `WorktreeManager.isWorkspaceName` (público) ya acepta los nombres de review, chat (`chat-…`), `-diff`, `.context` y `.respond-context`.

- [ ] **Step 4: Registro en `WorktreeManager` y `WorktreeResolver`.**
  - `WorktreeManager.prepare`: después de calcular `directory` (en las dos ramas: `-diff` y con clone) y **antes** de crear nada: `WorkspaceRegistry.shared.insert(directory.path)` y `WorkspaceRegistry.shared.insert(directory.path + ".context")`.
  - `WorktreeManager.cleanup(_:localPath:)`: al final, `WorkspaceRegistry.shared.remove(workspace.directory.path)` y `WorkspaceRegistry.shared.remove(workspace.contextDirectory.path)`.
  - `WorktreeResolver.prepare`: antes del `fetch`, `WorkspaceRegistry.shared.insert(target)`; `cleanup(_:)`: al final, `WorkspaceRegistry.shared.remove(worktree.path)`.
  - `RespondPipeline.analyze(item:…)` crea `contextDir` (`*.respond-context`): `WorkspaceRegistry.shared.insert(contextDir.path)` antes de `analyzer.analyze` y `remove` en el mismo `defer` que borra la carpeta.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests disk && swift run PRBarTests worktree` → todo `passed`.

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore/DiskUsage.swift Sources/PRBarCore/WorktreeManager.swift Sources/PRBarCore/WorktreeResolver.swift Sources/PRBarCore/RespondPipeline.swift Sources/PRBarTests/DiskUsageTests.swift Sources/PRBarTests/main.swift
git commit -m "Measure PRBar's disk usage and track active worktrees"
```

---

### Task 5: Clean Up seguro (`DiskCleanup`, `DiskCleanupExecutor`)

**Files:**
- Create: `Sources/PRBarCore/DiskCleanup.swift`
- Test: `Sources/PRBarTests/DiskCleanupTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

private func item(_ path: String, _ state: DiskItemState, kind: DiskCategoryKind = .worktrees, bytes: Int64 = 100,
                  clone: String? = nil, title: String? = nil) -> DiskItem {
    DiskItem(path: path, bytes: bytes, kind: kind, state: state, repo: nil, clone: clone,
             title: title ?? URL(fileURLWithPath: path).lastPathComponent)
}

enum DiskCleanupTests {
    static let cases: [TestCase] = [
        TestCase("cleanup: el plan solo trae huérfanos y caché del updater; nunca activos ni datos") {
            let usage = DiskUsage(items: [
                item("/w/api-1-1-aaaaaaaa", .active),
                item("/w/api-2-1-bbbbbbbb", .orphan),
                item("/s/source/.build", .cache, kind: .updater, title: "Updater builds"),
                item("/s/update-staging", .cache, kind: .updater, title: "Update staging"),
                item("/s/history", .data, kind: .history),
            ], scannedAt: t0)
            let plan = DiskCleanup.plan(usage: usage, oldFiles: [], updateInProgress: false)
            try expectEqual(plan.candidates.map(\.path), ["/w/api-2-1-bbbbbbbb", "/s/source/.build", "/s/update-staging"])
            try expectEqual(plan.totalBytes, 300)
            let busy = DiskCleanup.plan(usage: usage, oldFiles: [], updateInProgress: true)
            try expectEqual(busy.candidates.map(\.path), ["/w/api-2-1-bbbbbbbb"])
        },
        TestCase("cleanup: archivos viejos solo si se piden, nunca prbar.log") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let old = base.appendingPathComponent("history/review/old.json")
            let new = base.appendingPathComponent("history/review/new.json")
            let log = base.appendingPathComponent("Logs/prbar.log")
            for url in [old, new, log] {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            let longAgo = Date().addingTimeInterval(-40 * 86_400)
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: log.path)
            let files = DiskCleanup.oldFiles(in: [base.appendingPathComponent("history"), base.appendingPathComponent("Logs")],
                                             olderThanDays: 30, now: Date())
            try expectEqual(files.map(\.path), [old.standardizedFileURL.path])
        },
        TestCase("cleanup: el ejecutor saca un worktree de Responder limpio y saltea uno con commits sin pushear") {
            let repo = try TempGitRepo.make()
            defer { repo.remove() }
            let dir = repo.base.appendingPathComponent("local-worktrees")
            let clean = dir.appendingPathComponent("local-7-respond-0a0a0a0a")
            let dirty = dir.appendingPathComponent("local-7-respond-0b0b0b0b")
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", clean.path, "HEAD"])
            try TempGitRepo.run(repo.local, ["worktree", "add", "--detach", dirty.path, "HEAD"])
            try Data("fix\n".utf8).write(to: dirty.appendingPathComponent("fix.txt"))
            try TempGitRepo.run(dirty, ["add", "-A"])
            try TempGitRepo.run(dirty, ["commit", "-q", "-m", "unpushed fix"])
            let plan = CleanupPlan(candidates: [
                CleanupCandidate(path: clean.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "clean"),
                CleanupCandidate(path: dirty.path, bytes: 1, kind: .respondWorktree, clone: repo.local.path, title: "dirty"),
            ])
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: TempGitRepo.git,
                                               worktreeRoots: [repo.root], gitEnvironment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                                               registry: WorkspaceRegistry())
            let result = await executor.run(plan)
            try expectEqual(result.removed, [clean.path])
            try expectEqual(result.skipped.count, 1)
            try expect(result.skipped[0].contains("unpushed"), result.skipped[0])
            try expect(FileManager.default.fileExists(atPath: dirty.path))
            try expect(!FileManager.default.fileExists(atPath: clean.path))
            try expectEqual(try repo.worktreeNames().sorted(), ["local", "local-7-respond-0b0b0b0b"])
        },
        TestCase("cleanup: el ejecutor re-verifica y no toca algo que pasó a estar activo ni algo fuera de las raíces") {
            let base = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: base) }
            let root = base.appendingPathComponent("worktrees")
            let busy = root.appendingPathComponent("api-1-1700000000-cccccccc-diff")
            let outside = base.appendingPathComponent("elsewhere/api-1-1700000000-dddddddd-diff")
            for url in [busy, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            let registry = WorkspaceRegistry()
            registry.insert(busy.path)
            let executor = DiskCleanupExecutor(runner: SystemProcessRunner(), gitPath: "/usr/bin/git", worktreeRoots: [root],
                                               gitEnvironment: [:], registry: registry)
            let result = await executor.run(CleanupPlan(candidates: [
                CleanupCandidate(path: busy.path, bytes: 1, kind: .workspace, clone: nil, title: "busy"),
                CleanupCandidate(path: outside.path, bytes: 1, kind: .workspace, clone: nil, title: "outside"),
            ]))
            try expectEqual(result.removed, [])
            try expect(FileManager.default.fileExists(atPath: busy.path) && FileManager.default.fileExists(atPath: outside.path))
            try expectEqual(result.skipped.count, 2)
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'DiskCleanup'`.

- [ ] **Step 3: `Sources/PRBarCore/DiskCleanup.swift`:**

```swift
import Foundation

public enum CleanupKind: String, Codable, Sendable {
    /// Worktree o carpeta de review/chat (raíz temporal de PRBar).
    case workspace
    /// Worktree de Responder en el `worktreeDir` de un repo.
    case respondWorktree
    case updaterBuild, updaterStaging
    case oldFile
}

public struct CleanupCandidate: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var bytes: Int64
    public var kind: CleanupKind
    public var clone: String?
    public var title: String
    public var id: String { path }

    public init(path: String, bytes: Int64, kind: CleanupKind, clone: String?, title: String) {
        self.path = path
        self.bytes = bytes
        self.kind = kind
        self.clone = clone
        self.title = title
    }
}

public struct CleanupPlan: Codable, Equatable, Sendable {
    public var candidates: [CleanupCandidate]
    public var totalBytes: Int64 { candidates.map(\.bytes).reduce(0, +) }
    public var isEmpty: Bool { candidates.isEmpty }

    public init(candidates: [CleanupCandidate]) { self.candidates = candidates }
}

public struct CleanupResult: Codable, Equatable, Sendable {
    public var removed: [String] = []
    public var freedBytes: Int64 = 0
    /// "<título>: <motivo>".
    public var skipped: [String] = []
    public var failed: [String] = []

    public init() {}
}

public enum DiskCleanup {
    /// Lo que se puede borrar: huérfanos, y caché del updater si no hay una actualización en curso (decisiones I.1.4–6).
    public static func plan(usage: DiskUsage, oldFiles: [CleanupCandidate], updateInProgress: Bool) -> CleanupPlan {
        var candidates: [CleanupCandidate] = []
        for item in usage.items {
            switch (item.kind, item.state) {
            case (.worktrees, .orphan):
                let kind: CleanupKind = WorktreeResolver.isRespondWorktreeName(item.title) ? .respondWorktree : .workspace
                candidates.append(CleanupCandidate(path: item.path, bytes: item.bytes, kind: kind, clone: item.clone, title: item.title))
            case (.updater, .cache) where !updateInProgress:
                let kind: CleanupKind = item.path.hasSuffix("/.build") ? .updaterBuild : .updaterStaging
                candidates.append(CleanupCandidate(path: item.path, bytes: item.bytes, kind: kind, clone: nil, title: item.title))
            default:
                continue
            }
        }
        return CleanupPlan(candidates: candidates + oldFiles)
    }

    /// Archivos regulares de `directories` (recursivo, sin seguir symlinks) modificados hace más de `olderThanDays`.
    /// `prbar.log` (el log en uso) nunca.
    public static func oldFiles(in directories: [URL], olderThanDays days: Int, now: Date = Date()) -> [CleanupCandidate] {
        let limit = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        var found: [CleanupCandidate] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let date = values.contentModificationDate, date < limit,
                      url.lastPathComponent != AppPaths.logFile.lastPathComponent else { continue }
                found.append(CleanupCandidate(path: url.standardizedFileURL.path, bytes: Int64(values.totalFileAllocatedSize ?? 0),
                                              kind: .oldFile, clone: nil, title: url.lastPathComponent))
            }
        }
        return found.sorted { $0.path < $1.path }
    }
}

/// Borra lo de un plan, re-verificando cada ítem justo antes (decisión I.1.12). Worktrees con el mecanismo de §8.5
/// (`WorktreeManager.cleanup` / `WorktreeResolver.cleanup`: `worktree remove --force` de ese worktree, nunca
/// `git worktree prune`). Nunca lanza.
public struct DiskCleanupExecutor: Sendable {
    let runner: ProcessRunning
    let gitPath: String
    let worktreeRoots: [URL]
    let gitEnvironment: [String: String]
    let registry: WorkspaceRegistry
    let updaterDirectories: [URL]
    let oldFileRoots: [URL]

    public init(runner: ProcessRunning, gitPath: String, worktreeRoots: [URL], gitEnvironment: [String: String] = [:],
                registry: WorkspaceRegistry = .shared,
                updaterDirectories: [URL] = [AppPaths.updateSourceDir.appendingPathComponent(".build"), AppPaths.updateStagingDir],
                oldFileRoots: [URL] = [AppPaths.historyDir, AppPaths.logFile.deletingLastPathComponent()]) {
        self.runner = runner
        self.gitPath = gitPath
        self.worktreeRoots = worktreeRoots.map(\.standardizedFileURL)
        self.gitEnvironment = gitEnvironment
        self.registry = registry
        self.updaterDirectories = updaterDirectories.map(\.standardizedFileURL)
        self.oldFileRoots = oldFileRoots.map(\.standardizedFileURL)
    }

    public func run(_ plan: CleanupPlan) async -> CleanupResult {
        var result = CleanupResult()
        for candidate in plan.candidates {
            let url = URL(fileURLWithPath: candidate.path).standardizedFileURL
            if registry.contains(url.path) {
                result.skipped.append("\(candidate.title): in use")
                continue
            }
            switch candidate.kind {
            case .workspace:
                guard let root = worktreeRoots.first(where: { url.deletingLastPathComponent().path == $0.path }),
                      WorktreeManager.isWorkspaceName(url.lastPathComponent) else {
                    result.skipped.append("\(candidate.title): not in PRBar’s worktrees folder")
                    continue
                }
                let manager = WorktreeManager(runner: runner, gitPath: gitPath, root: root)
                let clone = DiskScanner.cloneOfWorktree(url)
                await manager.cleanup(ReviewWorkspace(directory: url, baseRef: nil, isDiffOnly: clone == nil), localPath: clone)
                if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            case .respondWorktree:
                guard WorktreeResolver.isRespondWorktreeName(url.lastPathComponent), let clone = candidate.clone else {
                    result.skipped.append("\(candidate.title): not a PRBar Respond worktree")
                    continue
                }
                if let reason = await unpushedWork(url) {
                    result.skipped.append("\(candidate.title): \(reason)")
                    continue
                }
                let resolver = WorktreeResolver(runner: runner, gitPath: gitPath, environment: gitEnvironment)
                await resolver.cleanup(ResolvedWorktree(path: url.path, origin: .dedicated, localPath: clone, ref: nil))
            case .updaterBuild, .updaterStaging:
                guard updaterDirectories.contains(where: { $0.path == url.path }) else {
                    result.skipped.append("\(candidate.title): not the updater’s folder")
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            case .oldFile:
                var info = stat()
                guard oldFileRoots.contains(where: { url.path.hasPrefix($0.path + "/") }),
                      lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    result.skipped.append("\(candidate.title): not an old history or log file")
                    continue
                }
                try? FileManager.default.removeItem(at: url)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                result.failed.append(candidate.title)
            } else {
                result.removed.append(candidate.path)
                result.freedBytes += candidate.bytes
            }
        }
        return result
    }

    /// `nil` si se puede borrar; si no, el motivo. Cambios sin commitear, o commits que no están en ninguna rama,
    /// remoto, tag ni `refs/prbar/*` (decisión I.1.4). Si git falla, no se borra.
    func unpushedWork(_ worktree: URL) async -> String? {
        func git(_ arguments: [String]) async -> String? {
            let result = try? await runner.run(gitPath, ["-C", worktree.path] + GitHardening.arguments + arguments,
                                               environment: gitEnvironment.merging(GitHardening.environment) { a, _ in a },
                                               currentDirectory: nil, timeout: ProcessTimeouts.standard)
            guard let result, result.status == 0 else { return nil }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let status = await git(["status", GitHardening.ignoreSubmodules, "--porcelain", "--untracked-files=all"]) else {
            return "couldn’t check it with git"
        }
        if !status.isEmpty { return "has uncommitted changes" }
        guard let count = await git(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes", "--tags", "--glob=refs/prbar/*"]),
              let commits = Int(count) else { return "couldn’t check it with git" }
        return commits == 0 ? nil : "has \(commits) unpushed commit\(commits == 1 ? "" : "s")"
    }
}
```

> `ResolvedWorktree(path:origin:localPath:ref:)` y `ReviewWorkspace(directory:baseRef:isDiffOnly:)` son los `init` públicos que ya existen (ver `RespondModels.swift` y `WorktreeManager.swift`). Si `WorktreeManager.cleanup` con `isDiffOnly: false` y la carpeta fuera de `root` loguea y no borra, está bien: el ejecutor ya filtró por raíz.

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests cleanup` → `4/4 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/DiskCleanup.swift Sources/PRBarTests/DiskCleanupTests.swift Sources/PRBarTests/main.swift
git commit -m "Plan and run a safe disk clean up"
```

---

### Task 6: Muestreo solo con la UI abierta (`ResourceMonitor`)

**Files:**
- Create: `Sources/PRBarCore/ResourceMonitor.swift`
- Test: `Sources/PRBarTests/ResourceMonitorTests.swift` (+ `main.swift`)

- [ ] **Step 1: Tests que fallan.**

```swift
import Foundation
import PRBarCore

private func monitor(_ info: FakeProcessInfo, scans: ScanCounter, interval: Duration = .milliseconds(20)) async -> ResourceMonitor {
    await MainActor.run {
        ResourceMonitor(sampler: ProcessSampler(provider: info, root: 1), registry: ProcessRegistry(), interval: interval,
                        diskScan: { scans.bump(); return DiskUsage(items: [], scannedAt: Date()) })
    }
}

final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

enum ResourceMonitorTests {
    static let cases: [TestCase] = [
        TestCase("resources: no muestrea si no hay nada abierto; sí mientras algo está abierto; para al cerrarse") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 1)
            let scans = ScanCounter()
            let monitor = await monitor(info, scans: scans)
            try await Task.sleep(for: .milliseconds(100))
            let idleCalls = info.statCalls
            try expectEqual(idleCalls, 0)
            await MainActor.run { monitor.setVisible("popover", true) }
            try await Task.sleep(for: .milliseconds(150))
            let sampling = await MainActor.run { monitor.isSampling }
            try expect(sampling)
            let open = info.statCalls
            try expect(open >= 3, "llamadas \(open)")
            await MainActor.run { monitor.setVisible("activity", true); monitor.setVisible("popover", false) }
            let stillSampling = await MainActor.run { monitor.isSampling }
            try expect(stillSampling)
            await MainActor.run { monitor.setVisible("activity", false) }
            let stopped = await MainActor.run { monitor.isSampling }
            try expect(!stopped)
            let atStop = info.statCalls
            try await Task.sleep(for: .milliseconds(100))
            let later = info.statCalls
            try expect(later - atStop <= 1, "siguió muestreando: \(atStop) → \(later)")
        },
        TestCase("resources: el disco se calcula al abrir, a lo sumo cada 60 s, y otra vez al terminar un trabajo") {
            let info = FakeProcessInfo()
            info.children = [1: []]
            info.set(1, cpu: 0, memory: 1)
            let scans = ScanCounter()
            let monitor = await monitor(info, scans: scans, interval: .seconds(5))
            await MainActor.run { monitor.setVisible("popover", true) }
            try await Task.sleep(for: .milliseconds(100))
            await MainActor.run { monitor.setVisible("popover", false); monitor.setVisible("popover", true) }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 1)
            await MainActor.run { monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 2)
            await MainActor.run { monitor.setVisible("popover", false); monitor.jobFinished() }
            try await Task.sleep(for: .milliseconds(100))
            try expectEqual(scans.count, 2)
        },
        TestCase("resources: el umbral avisa una vez al cruzarlo hacia arriba") {
            var crossing = DiskWarningState()
            let gb: Int64 = 1_000_000_000
            try expectEqual(crossing.update(total: 4 * gb, limitGB: 5), false)
            try expectEqual(crossing.update(total: 6 * gb, limitGB: 5), true)
            try expectEqual(crossing.update(total: 7 * gb, limitGB: 5), false)
            try expectEqual(crossing.update(total: 3 * gb, limitGB: 5), false)
            try expectEqual(crossing.update(total: 6 * gb, limitGB: 5), true)
            try expectEqual(crossing.update(total: 60 * gb, limitGB: nil), false)
        },
    ]
}
```

- [ ] **Step 2:** build → `cannot find 'ResourceMonitor'`.

- [ ] **Step 3: `Sources/PRBarCore/ResourceMonitor.swift`:**

```swift
import Combine
import Foundation

/// CPU/RAM cada `interval` (2 s) **solo** mientras haya una vista que los muestra (el popover o la ventana Activity),
/// y el disco en segundo plano, a lo sumo cada 60 s y al terminar un trabajo (spec I, decisiones I.1.7–8).
@MainActor
public final class ResourceMonitor: ObservableObject {
    public static let diskMinInterval: TimeInterval = 60

    @Published public private(set) var usage: ResourceUsage?
    @Published public private(set) var disk: DiskUsage?
    @Published public private(set) var scanningDisk = false

    private let sampler: ProcessSampler
    private let registry: ProcessRegistry
    private let interval: Duration
    private let diskScan: @Sendable () async -> DiskUsage
    /// Después de cada cálculo de disco (el umbral, en la app).
    public var onDisk: ((DiskUsage) -> Void)?

    private var consumers: Set<String> = []
    private var samplingTask: Task<Void, Never>?
    private var previous: ProcessSample?
    private var diskTask: Task<Void, Never>?

    public init(sampler: ProcessSampler, registry: ProcessRegistry = .shared, interval: Duration = .seconds(2),
                diskScan: @escaping @Sendable () async -> DiskUsage) {
        self.sampler = sampler
        self.registry = registry
        self.interval = interval
        self.diskScan = diskScan
    }

    public var isSampling: Bool { samplingTask != nil }

    /// `consumer`: "popover" o "activity".
    public func setVisible(_ consumer: String, _ visible: Bool) {
        if visible { consumers.insert(consumer) } else { consumers.remove(consumer) }
        if consumers.isEmpty {
            samplingTask?.cancel()
            samplingTask = nil
            previous = nil
        } else {
            if samplingTask == nil { startSampling() }
            refreshDisk(force: false)
        }
    }

    /// Un trabajo terminó: el disco cambió. Solo recalcula si alguien lo está mirando.
    public func jobFinished() {
        guard !consumers.isEmpty else {
            disk?.scannedAt = .distantPast
            return
        }
        refreshDisk(force: true)
    }

    public func refreshDisk(force: Bool) {
        guard diskTask == nil else { return }
        if !force, let disk, Date().timeIntervalSince(disk.scannedAt) < Self.diskMinInterval { return }
        scanningDisk = true
        let scan = diskScan
        diskTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { await scan() }.value
            guard let self else { return }
            self.disk = result
            self.scanningDisk = false
            self.diskTask = nil
            self.onDisk?(result)
        }
    }

    /// Para `prbar resources`: una muestra de menos de 3 s, o dos nuevas separadas por 1 s.
    public func freshUsage() async -> ResourceUsage {
        if let usage, Date().timeIntervalSince(usage.sampledAt) < 3 { return usage }
        let sampler = self.sampler
        let first = await Task.detached { sampler.sample() }.value
        try? await Task.sleep(for: .seconds(1))
        let second = await Task.detached { sampler.sample() }.value
        return ResourceMeter.usage(previous: first, current: second, registered: registry.byPID())
    }

    /// Para `prbar resources`: el disco si tiene menos de 60 s; si no, lo calcula ahora.
    public func freshDisk() async -> DiskUsage {
        if let disk, Date().timeIntervalSince(disk.scannedAt) < Self.diskMinInterval { return disk }
        let scan = diskScan
        let result = await Task.detached(priority: .utility) { await scan() }.value
        disk = result
        onDisk?(result)
        return result
    }

    private func startSampling() {
        let sampler = self.sampler
        let interval = self.interval
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) { sampler.sample() }.value
                guard let self, !Task.isCancelled else { return }
                self.usage = ResourceMeter.usage(previous: self.previous, current: sample, registered: self.registry.byPID())
                self.previous = sample
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// Avisa una vez cada vez que el total cruza el umbral hacia arriba (decisión I.1.11).
public struct DiskWarningState: Equatable, Sendable {
    private var above = false

    public init() {}

    /// `true` = hay que avisar ahora.
    public mutating func update(total: Int64, limitGB: Int?) -> Bool {
        guard let limitGB else {
            above = false
            return false
        }
        let isAbove = total > Int64(limitGB) * 1_000_000_000
        defer { above = isAbove }
        return isAbove && !above
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests resources` → `3/3 passed`. Correrlo 3 veces (son tests con tiempos cortos: no tienen que fallar de a ratos; si lo hacen, subir los `sleep` del test, nunca bajar las aserciones).

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/ResourceMonitor.swift Sources/PRBarTests/ResourceMonitorTests.swift Sources/PRBarTests/main.swift
git commit -m "Sample resources only while the popover or the Activity window is open"
```

---

### Task 7: Configuración del umbral y la notificación `diskUsage`

**Files:**
- Modify: `Sources/PRBarCore/Config.swift`, `Sources/PRBarCore/NotificationPlanner.swift`
- Test: `Sources/PRBarTests/ConfigTests.swift`, `Sources/PRBarTests/NotificationPlannerTests.swift`

- [ ] **Step 1: Tests que fallan.** En `ConfigTests`:

```swift
        TestCase("config: el umbral de disco está apagado por defecto, se guarda y se acota a 1–100 GB") {
            try expectEqual(AppConfig().resources.diskWarningGB, nil)
            var config = AppConfig()
            config.resources.setDiskWarning(gigabytes: 500)
            try expectEqual(config.resources.diskWarningGB, 100)
            config.resources.setDiskWarning(gigabytes: 5)
            let back = try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config))
            try expectEqual(back.resources.diskWarningGB, 5)
            let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"refreshIntervalMinutes":5}"#.utf8))
            try expectEqual(old.resources.diskWarningGB, nil)
        },
```

En `NotificationPlannerTests`:

```swift
        TestCase("notificaciones: aviso de disco con el total y el umbral") {
            let planned = NotificationPlanner.diskWarning(totalBytes: 6_400_000_000, limitGB: 5, settings: NotificationSettings())
            try expectEqual(planned?.kind, .diskUsage)
            try expectEqual(planned?.title, "PRBar Is Using a Lot of Disk")
            try expectEqual(planned?.body, "PRBar is using 6.4 GB (your limit is 5 GB). Open PRBar Activity to clean up.")
            var off = NotificationSettings()
            off.enabled = false
            try expectEqual(NotificationPlanner.diskWarning(totalBytes: 6_400_000_000, limitGB: 5, settings: off), nil)
        },
```

- [ ] **Step 2:** build → errores (`resources`, `diskWarning`).

- [ ] **Step 3: Implementación.**

`Config.swift`, antes de `public struct AppConfig`:

```swift
/// Settings › General › "Warn when PRBar uses more than N GB" (spec I). `nil` = apagado.
public struct ResourceSettings: Hashable, Codable, Sendable {
    public var diskWarningGB: Int?

    public init(diskWarningGB: Int? = nil) { self.diskWarningGB = diskWarningGB }

    public static let gigabyteRange = 1...100

    public mutating func setDiskWarning(gigabytes: Int?) {
        diskWarningGB = gigabytes.map { min(max($0, Self.gigabyteRange.lowerBound), Self.gigabyteRange.upperBound) }
    }
}
```

En `AppConfig`: propiedad `public var resources = ResourceSettings()` al final; en `CodingKeys` una línea nueva `case resources`; en `init(from:)`: `resources = (try? c.decodeIfPresent(ResourceSettings.self, forKey: .resources)) ?? ResourceSettings()`.

`NotificationPlanner.swift`:
- `NotificationKind`: después de `case readyToMerge`, `/// PRBar pasó el umbral de disco (spec I). Solo depende del interruptor general. case diskUsage`.
- En `NotificationSettings.isOn` (o donde esté el `switch` con `case .updateAvailable: return true`): `case .diskUsage: return true`.
- En `title(for:)`: `case .diskUsage: "PRBar Is Using a Lot of Disk"`; en `groupTitle(for:count:)`: `case .diskUsage: "PRBar disk usage"`.
- Agregar:

```swift
    /// El total pasó el umbral de Settings › General (spec I). El clic abre la ventana Activity (`event: "disk"`).
    public static func diskWarning(totalBytes: Int64, limitGB: Int, settings: NotificationSettings) -> PlannedNotification? {
        guard settings.isOn(.diskUsage) else { return nil }
        // Formato fijo (no `ByteCountFormatter`): el texto no depende del locale de quien corre los tests.
        let used = String(format: "%.1f GB", locale: Locale(identifier: "en_US_POSIX"), Double(totalBytes) / 1_000_000_000)
        return PlannedNotification(kind: .diskUsage, title: "PRBar Is Using a Lot of Disk",
                                   body: "PRBar is using \(used) (your limit is \(limitGB) GB). Open PRBar Activity to clean up.",
                                   url: nil, event: "disk")
    }
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests config && swift run PRBarTests notificaciones` → `passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/Config.swift Sources/PRBarCore/NotificationPlanner.swift Sources/PRBarTests/ConfigTests.swift Sources/PRBarTests/NotificationPlannerTests.swift
git commit -m "Add an optional disk usage warning"
```

---

### Task 8: Protocolo y CLI — `prbar resources`, `prbar cleanup`, `config set disk-warning`

**Files:**
- Modify: `Sources/PRBarCore/AppCommand.swift`, `AppCommandTypes.swift`, `CommandActions.swift`, `CommandDispatcher.swift`, `CommandResults.swift`
- Create: `Sources/PRBarCLIKit/ResourceCommands.swift`
- Modify: `Sources/PRBarCLIKit/ConfigCommands.swift`, `CLIRouter.swift`, `PRBarCLIKit.swift` (lista de subcomandos de `PRBarCommand`)
- Modify tests: `FakeActions.swift`, `CommandDispatcherTests.swift`, `CLIParsingTests.swift`
- Modify: `docs/cli.md`

- [ ] **Step 1: Tests que fallan.**

`CommandDispatcherTests.dispatchSamples`, al final:

```swift
    (.resources, "resources"),
    (.cleanupPreview(olderThanDays: 30), "cleanupPreview"),
    (.cleanup(olderThanDays: nil, confirmed: true), "cleanup"),
    (.setDiskWarning(gigabytes: 5), "setDiskWarning"),
```

`CLIParsingTests`, un caso nuevo:

```swift
            TestCase("cli parse: resources, cleanup y disk-warning") {
                try expectEqual(try parsed(["resources"]), .resources)
                try expectEqual(try parsed(["resources", "--json"]), .resources)
                try expectEqual(try parsed(["cleanup"]), .cleanup(olderThanDays: nil, confirmed: true))
                try expectEqual(try parsed(["cleanup", "--older-than", "30d"]), .cleanup(olderThanDays: 30, confirmed: true))
                try expectEqual(try parsed(["cleanup", "--older-than", "7"]), .cleanup(olderThanDays: 7, confirmed: true))
                try expectEqual(try parsed(["cleanup"], confirmed: false), .cleanup(olderThanDays: nil, confirmed: false))
                try expect(rejects(["cleanup", "--older-than", "0d"]))
                try expect(rejects(["cleanup", "--older-than", "a week"]))
                try expectEqual(try parsed(["config", "set", "disk-warning", "5"]), .setDiskWarning(gigabytes: 5))
                try expectEqual(try parsed(["config", "set", "disk-warning", "off"]), .setDiskWarning(gigabytes: nil))
                try expect(rejects(["config", "set", "disk-warning", "0"]))
                try expect(rejects(["config", "set", "disk-warning", "101"]))
            },
```

- [ ] **Step 2:** build → errores.

- [ ] **Step 3: Core.**

`AppCommand.swift`, sección nueva antes de `// Configuración`:

```swift
    // Recursos (spec I)
    /// CPU, RAM, disco por categoría y procesos (`prbar resources`).
    case resources
    /// Lo que borraría Clean Up, sin borrar. `olderThanDays`: también historial y logs más viejos.
    case cleanupPreview(olderThanDays: Int?)
    /// Clean Up. Con algo para borrar exige `confirmed` (lo verifica la app).
    case cleanup(olderThanDays: Int?, confirmed: Bool)
```

y en "// Configuración": `/// Settings › General › umbral de disco; nil = apagado. case setDiskWarning(gigabytes: Int?)`.
`Name`: una línea nueva al final `case resources, cleanupPreview, cleanup, setDiskWarning`; `name`: los cuatro casos.

`CommandResults.swift`, al final:

```swift
/// `prbar resources`.
public struct ResourcesInfo: Codable, Equatable, Sendable {
    public var usage: ResourceUsage
    public var disk: DiskUsage

    public init(usage: ResourceUsage, disk: DiskUsage) {
        self.usage = usage
        self.disk = disk
    }
}
```

`CommandActions.swift`:

```swift
/// Recursos y limpieza (spec I).
@MainActor
public protocol ResourceActions: AnyObject {
    func resources() async -> ResourcesInfo
    func cleanupPreview(olderThanDays: Int?) async -> CleanupPlan
    /// Arma el plan de nuevo; vacío → resultado vacío sin pedir confirmación; si no, exige `confirmed`.
    func cleanup(olderThanDays: Int?, confirmed: Bool) async throws -> CleanupResult
    func configSetDiskWarning(gigabytes: Int?) throws
}
```
y sumar `& ResourceActions` al `typealias PRBarActions`.

`CommandDispatcher.swift`:

```swift
        // Recursos (spec I)
        case .resources:
            return try encode(await actions.resources())
        case .cleanupPreview(let days):
            return try encode(await actions.cleanupPreview(olderThanDays: days))
        case .cleanup(let days, let confirmed):
            return try encode(try await actions.cleanup(olderThanDays: days, confirmed: confirmed))
        case .setDiskWarning(let gigabytes):
            try actions.configSetDiskWarning(gigabytes: gigabytes)
            return .ok
```

`FakeActions` gana `ResourceActions`:

```swift
    // MARK: ResourceActions
    func resources() async -> ResourcesInfo {
        calls.append("resources")
        return ResourcesInfo(usage: ResourceUsage(cpuPercent: 0, memoryBytes: 0, processes: [], sampledAt: t0),
                             disk: DiskUsage(items: [], scannedAt: t0))
    }
    func cleanupPreview(olderThanDays: Int?) async -> CleanupPlan { calls.append("cleanupPreview \(olderThanDays ?? 0)"); return CleanupPlan(candidates: []) }
    func cleanup(olderThanDays: Int?, confirmed: Bool) async throws -> CleanupResult {
        try record("cleanup \(olderThanDays ?? 0) confirmed=\(confirmed)"); return CleanupResult()
    }
    func configSetDiskWarning(gigabytes: Int?) throws { try record("setDiskWarning \(gigabytes ?? 0)") }
```
(agregar `ResourceActions` a la lista de protocolos de la clase).

- [ ] **Step 4: CLI.** `Sources/PRBarCLIKit/ResourceCommands.swift`:

```swift
import ArgumentParser
import Foundation
import PRBarCore

enum Bytes {
    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }
    static func text(_ bytes: UInt64) -> String { text(Int64(clamping: bytes)) }
}

struct ResourcesCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "resources", abstract: "CPU, memory and disk PRBar is using (the popover’s footer and PRBar Activity).")
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .resources }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: ResourcesInfo = try result.decode()
        output.line(output.paint(String(format: "CPU %.0f%%  ·  RAM %@  ·  Disk %@", info.usage.cpuPercent,
                                        Bytes.text(info.usage.memoryBytes), Bytes.text(info.disk.total)), .bold))
        output.line()
        output.table(["Process", "PID", "CPU", "RAM", "Running"], info.usage.processes.map { process in
            let cpu = process.remoteHost.map { "on \($0)" } ?? String(format: "%.0f%%", process.cpuPercent)
            let ram = process.remoteHost == nil ? Bytes.text(process.memoryBytes) : "—"
            return [process.label, String(process.pid), cpu, ram, process.startedAt.map { RelativeAge.short(from: $0) } ?? "—"]
        })
        output.line()
        output.table(["Disk", "Size"], DiskCategoryKind.allCases.map { [$0.title, Bytes.text(info.disk.bytes($0))] })
        let orphans = info.disk.items.filter { $0.state == .orphan }
        if !orphans.isEmpty {
            output.line(output.paint("\(orphans.count) leftover worktree\(orphans.count == 1 ? "" : "s") (\(Bytes.text(orphans.map(\.bytes).reduce(0, +)))). Run `prbar cleanup`.", .yellow))
        }
    }
}

/// `30d` o `30`: días (1…3650).
struct DayCount: ExpressibleByArgument {
    let days: Int

    init?(argument: String) {
        let digits = argument.hasSuffix("d") ? String(argument.dropLast()) : argument
        guard let days = Int(digits), (1...3650).contains(days) else { return nil }
        self.days = days
    }
}

struct CleanupCommand: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup", abstract: "Delete leftover worktrees and the updater’s builds (Clean Up in PRBar Activity).",
        discussion: "Never touches running jobs or worktrees with unpushed fixes. Without a terminal it needs --yes.")
    @Option(help: "Also delete history and logs older than this (e.g. 30d).") var olderThan: DayCount?
    @Flag(help: "Only show what would be deleted.") var preview = false
    @OptionGroup var global: GlobalOptions

    func confirmation(_ connection: AppConnection, _ output: Output) throws -> String? {
        guard !preview else { return nil }
        let plan: CleanupPlan = try connection.run(.cleanupPreview(olderThanDays: olderThan?.days)).decode()
        guard !plan.isEmpty else { return nil }
        if !output.json {
            output.table(["Delete", "Size"], plan.candidates.map { [$0.title, Bytes.text($0.bytes)] })
        }
        return "Delete \(plan.candidates.count) item\(plan.candidates.count == 1 ? "" : "s") and free \(Bytes.text(plan.totalBytes))?"
    }

    func appCommand(confirmed: Bool) -> AppCommand {
        preview ? .cleanupPreview(olderThanDays: olderThan?.days) : .cleanup(olderThanDays: olderThan?.days, confirmed: confirmed)
    }

    func render(_ result: JSONValue, _ output: Output) throws {
        if preview {
            let plan: CleanupPlan = try result.decode()
            guard !plan.isEmpty else { return output.line("Nothing to clean up.") }
            output.table(["Delete", "Size"], plan.candidates.map { [$0.title, Bytes.text($0.bytes)] })
            return output.line("Would free \(Bytes.text(plan.totalBytes)).")
        }
        let done: CleanupResult = try result.decode()
        if done.removed.isEmpty && done.skipped.isEmpty && done.failed.isEmpty { return output.line("Nothing to clean up.") }
        output.line("Freed \(Bytes.text(done.freedBytes)) (\(done.removed.count) item\(done.removed.count == 1 ? "" : "s")).")
        for skipped in done.skipped { output.line(output.paint("Skipped \(skipped)", .yellow)) }
        for failed in done.failed { output.line(output.paint("Couldn’t delete \(failed)", .red)) }
    }
}
```

> `RelativeAge.short(from:)` devuelve "40 min"/"3 h" (ver `Formatting.swift`).

Registrar `ResourcesCommand.self` y `CleanupCommand.self` en los subcomandos de `PRBarCommand` (en `PRBarCLIKit.swift`, después de `StatusCommand.self`/`PRsCommand.self`).

`ConfigCommands.swift`: `ConfigKey` gana `case diskWarning = "disk-warning"`; el `discussion` de `ConfigSet` agrega `· disk-warning 1…100|off (GB)`; en `appCommand`:

```swift
        case .diskWarning:
            if value == "off" { return .setDiskWarning(gigabytes: nil) }
            guard let gigabytes = Int(value), ResourceSettings.gigabyteRange.contains(gigabytes) else {
                throw ValidationError("disk-warning takes gigabytes (1–100) or off.")
            }
            return .setDiskWarning(gigabytes: gigabytes)
```

`CLIRouter.swift`:
- `"config set"`: sumar `.setDiskWarning` a `produces` y el ejemplo `["config", "set", "disk-warning", "off"]`.
- En "// Estado…", después de `refresh`:

```swift
        .init("resources", [.resources], ["resources"]),
        .init("cleanup", [.cleanup, .cleanupPreview], ["cleanup", "--older-than", "30d", "--yes"], ["cleanup", "--preview"]),
```

(El test de paridad exige que cada nombre de `produces` salga del `appCommand` de algún ejemplo: por eso `--preview` produce `cleanupPreview`, además de que la pregunta interactiva lo use.) En `CLIParsingTests` sumar `try expectEqual(try parsed(["cleanup", "--preview"]), .cleanupPreview(olderThanDays: nil))`.

`docs/cli.md`: secciones `prbar resources [--json]`, `prbar cleanup [--older-than 30d] [--preview] [--yes]` y `prbar config set disk-warning <GB|off>`.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests "cli parse" && swift run PRBarTests dispatcher && swift run PRBarTests paridad` → `passed` (la paridad de UI sigue igual).

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore Sources/PRBarCLIKit Sources/PRBarTests docs/cli.md
git commit -m "Add prbar resources, prbar cleanup and the disk-warning setting"
```

---

### Task 9: App — etiquetas de tarea, monitor, acciones y Stop

**Files:**
- Modify: `Sources/PRBarCore/ReviewQueue.swift`, `RespondQueue.swift`, `ChatCoordinator.swift`, `InstructionsChatCoordinator.swift`, `SlackAnnouncer.swift`
- Modify: `Sources/PRBar/Update/UpdateController.swift`, `Sources/PRBar/AppModel.swift`, `Sources/PRBar/NotificationDelivery.swift`
- Create: `Sources/PRBar/AppModel+Resources.swift`

- [ ] **Step 1: Etiquetas.**
  - `ReviewQueue.enqueue`: `scheduler.enqueue(prID, activity: .review(prID), onStart: …`.
  - `RespondQueue.start(_:kind:…)`: `scheduler.enqueue(prID, activity: .respond(prID), onStart: …`.
  - `ChatCoordinator`: en las dos llamadas a `scheduler.enqueue(key, …)` (turno y undo): `activity: .chat(session.prID)`.
  - `InstructionsChatCoordinator`: `scheduler.enqueue(Self.key, activity: .instructions, onStart: …`.
  - `SlackAnnouncer.run(snapshot:config:)`: envolver el cuerpo en `await ProcessActivity.$current.withValue(.slack) { … }` (solo lanza `claude` con el conector; con token no lanza procesos).
  - `UpdateController.install(_:whenBusy:onEvent:)`: `let task = Task { try await ProcessActivity.$current.withValue(.update) { try await self.runInstall(release, whenBusy: whenBusy, onEvent: onEvent) } }`. Y en `startInstall`, si arma su propia `Task` que llama a `install`, no hace falta nada más (la toma `install`).

- [ ] **Step 2: `AppModel`.** Propiedad (junto a `merges`):

```swift
    /// CPU/RAM/disco de PRBar (spec I). `lazy` porque su escaneo de disco lee la config y los drafts de `self`.
    private(set) lazy var resources: ResourceMonitor = makeResourceMonitor()
    /// Para avisar una vez por cruce del umbral (spec I).
    var diskWarning = DiskWarningState()
```

En `startsServices` (después de `notifications?.onSelectPR = …` del Plan 12): `notifications?.onOpenActivity = { [weak self] in self?.openActivityWindow() }`.

En `NotificationDelivery`: `var onOpenActivity: (() -> Void)?`; en `deliver`, `if notification.kind == .diskUsage { userInfo["activity"] = "1" }`; en `didReceive`, antes de la cadena `if userInfo["updateVersion"] …`: `if userInfo["activity"] != nil { Task { @MainActor in self.onOpenActivity?() }; completionHandler(); return }`.

Al terminar cada trabajo, `resources.jobFinished()`: en `reviewFinished(_:_:)`, en `respondEvent(prID:phase:)` cuando la fase no es activa (`!phase.isActive`), en el `onMerged`/`mergeFinished` y al terminar un turno de chat si `AppModel` tiene un hook (si no, no hace falta: el chat de Review no cambia el disco de forma apreciable).

- [ ] **Step 3: `Sources/PRBar/AppModel+Resources.swift`:**

```swift
import AppKit
import PRBarCore
import SwiftUI

extension AppModel: ResourceActions {
    static let activityWindowID = "activity"

    func makeResourceMonitor() -> ResourceMonitor {
        let monitor = ResourceMonitor(sampler: ProcessSampler(provider: LiveProcessInfoProvider()),
                                      diskScan: { [weak self] in
                                          let input = await MainActor.run { self?.diskScanInput() }
                                          guard let input else { return DiskUsage(items: [], scannedAt: Date()) }
                                          return DiskScanner.scan(input)
                                      })
        monitor.onDisk = { [weak self] disk in self?.checkDiskWarning(disk) }
        return monitor
    }

    /// Las carpetas a medir y lo que está en uso, leído en el main actor.
    func diskScanInput() -> DiskScanInput {
        var respondDirs: [DiskScanInput.RespondDir] = []
        var repoByClone: [String: String] = [:]
        for account in configStore.config.accounts {
            for repo in account.repos {
                guard let localPath = repo.localPath else { continue }
                repoByClone[localPath] = repo.id
                respondDirs.append(.init(repo: repo.id, path: repo.worktreeDir ?? WorktreeResolver.defaultWorktreeDir(localPath: localPath),
                                         localPath: localPath))
            }
        }
        var active = WorkspaceRegistry.shared.all()
        for record in respond.records.values { active.insert(record.draft.worktree.path) }
        return .live(respondDirs: respondDirs, activePaths: active, repoByClone: repoByClone)
    }

    func checkDiskWarning(_ disk: DiskUsage) {
        let limit = configStore.config.resources.diskWarningGB
        guard diskWarning.update(total: disk.total, limitGB: limit), let limit,
              let planned = NotificationPlanner.diskWarning(totalBytes: disk.total, limitGB: limit,
                                                            settings: configStore.config.notifications) else { return }
        notifications?.deliver([planned])
    }

    func openActivityWindow() {
        WindowPresenter.shared.show(
            id: Self.activityWindowID, title: "PRBar Activity", size: ActivityWindow.size,
            options: WindowOptions(autosaveName: "ActivityWindow", miniaturizable: true, resizable: true, allowsTabbing: false),
            contentID: "activity"
        ) {
            ActivityWindow(model: self, monitor: self.resources)
        }
    }

    /// Stop de una tarea de la ventana Activity (decisión I.1.10). `nil` = no se puede parar.
    func stopAction(for activity: ProcessActivity) -> (() -> Void)? {
        switch activity.kind {
        case .review: activity.prID.map { prID in { self.cancelReview(prID: prID) } }
        case .respond: activity.prID.map { prID in { self.cancelRespond(prID: prID) } }
        case .chat: activity.prID.flatMap { prID in self.chatCoordinator(forPR: prID).map { chat in { chat.stop() } } }
        case .instructions: { self.instructionsChat.stop() }
        case .update: updates.canCancelInstall ? { self.updates.cancelInstall() } : nil
        case .slack: nil
        }
    }

    // MARK: ResourceActions (CLI)

    func resources() async -> ResourcesInfo {
        let usage = await resources.freshUsage()
        let disk = await resources.freshDisk()
        return ResourcesInfo(usage: usage, disk: disk)
    }

    func cleanupPreview(olderThanDays: Int?) async -> CleanupPlan {
        let input = diskScanInput()
        let disk = await Task.detached(priority: .utility) { DiskScanner.scan(input) }.value
        let old = olderThanDays.map { DiskCleanup.oldFiles(in: [AppPaths.historyDir, AppPaths.logFile.deletingLastPathComponent()],
                                                            olderThanDays: $0) } ?? []
        return DiskCleanup.plan(usage: disk, oldFiles: old, updateInProgress: updates.session.state.isBusy)
    }

    func cleanup(olderThanDays: Int?, confirmed: Bool) async throws -> CleanupResult {
        let plan = await cleanupPreview(olderThanDays: olderThanDays)
        guard !plan.isEmpty else { return CleanupResult() }
        guard confirmed else { throw CommandFailure(.confirmationRequired, "Clean Up needs confirmation: run it again with --yes.") }
        guard let git = tools.git else { throw CommandFailure(.failed, PRBarError.toolNotFound("git").localizedDescription) }
        let executor = DiskCleanupExecutor(runner: runner, gitPath: git,
                                           worktreeRoots: [AppPaths.worktreesDir, AppPaths.legacyWorktreesDir])
        let result = await executor.run(plan)
        AppLog.write("Clean Up freed \(result.freedBytes) bytes; skipped \(result.skipped.count); failed \(result.failed.count)")
        resources.jobFinished()
        return result
    }

    func configSetDiskWarning(gigabytes: Int?) throws {
        try configStore.update { $0.resources.setDiskWarning(gigabytes: gigabytes) }
    }
}
```

Ajustes que este código necesita (buscar por nombre y adaptar, sin cambiar la lógica):
- `chatCoordinator(forPR:)`: el coordinador de chat del PR, si hay uno (en `AppModel+Chat.swift` existe uno parecido para la CLI, p. ej. `chatCoordinator(_:)`; usar ese).
- `updates.canCancelInstall`: agregar en `UpdateController` `var canCancelInstall: Bool { installTask != nil || requestedInstall != nil }` **y** que sea falso en las fases que reemplazan la app (si `session.state` tiene `installing`/`relaunching`, devolver `false` en esos casos).
- `updates.session.state.isBusy`: si no existe, agregar en el tipo de estado una propiedad `isBusy` (verdadera mientras se baja, compila, verifica o instala).
- `configStore.update { }`: es el mismo que usa `configSetRefreshInterval` (ver `AppModel+Settings.swift`).

- [ ] **Step 4: Build.** `swift build --product PRBar 2>&1 | grep -E "error|warning: " | head` → solo falta `ActivityWindow` (Task 10). Para compilar ya, crear `Sources/PRBar/Activity/ActivityWindow.swift` con `struct ActivityWindow: View { static let size = NSSize(width: 720, height: 560); @ObservedObject var model: AppModel; @ObservedObject var monitor: ResourceMonitor; var body: some View { Text("Activity") } }` y reemplazarlo en la Task 10.

- [ ] **Step 5:** `swift build --product PRBarTests && swift run PRBarTests` → todo `passed`.

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore Sources/PRBar
git commit -m "Track tasks, resources and clean up in the app"
```

---

### Task 10: UI — pie del popover, ventana PRBar Activity y umbral en Settings

**Files:**
- Create: `Sources/PRBar/Popover/ResourceFooter.swift`
- Rewrite: `Sources/PRBar/Activity/ActivityWindow.swift`
- Modify: `Sources/PRBar/Popover/PopoverView.swift`, `Sources/PRBar/Settings/GeneralTab.swift`
- Modify: `Sources/PRBarTests/UIActionInventory.swift`

- [ ] **Step 1: `Popover/ResourceFooter.swift`:**

```swift
import PRBarCore
import SwiftUI

/// `◔ CPU 12%  ▤ RAM 640 MB  ⛁ Disk 2.3 GB  ›` (spec I). Clic → PRBar Activity.
struct ResourceFooter: View {
    @ObservedObject var monitor: ResourceMonitor
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                metric("gauge.with.dots.needle.33percent", "CPU", monitor.usage.map { String(format: "%.0f%%", $0.cpuPercent) })
                metric("memorychip", "RAM", monitor.usage.map { Self.bytes(Int64(clamping: $0.memoryBytes)) })
                metric("internaldrive", "Disk", monitor.disk.map { Self.bytes($0.total) })
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
        .help("PRBar Activity: processes, disk and Clean Up")
        .accessibilityLabel(accessibility)
    }

    private func metric(_ symbol: String, _ title: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text("\(title) \(value ?? "–")")
        }
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .memory) }

    private var accessibility: String {
        let cpu = monitor.usage.map { String(format: "%.0f percent", $0.cpuPercent) } ?? "unknown"
        let ram = monitor.usage.map { Self.bytes(Int64(clamping: $0.memoryBytes)) } ?? "unknown"
        let disk = monitor.disk.map { Self.bytes($0.total) } ?? "unknown"
        return "PRBar Activity. CPU \(cpu), memory \(ram), disk \(disk)"
    }
}
```

> `hoverHighlight(cornerRadius:)` es el modificador que ya usa `PopoverView` para el menú ⚙︎.

- [ ] **Step 2: Pie y visibilidad en `PopoverView`.** En `body`, entre `content` y `UpdateRow(…)`:

```swift
            if showsTabs {
                Divider()
                ResourceFooter(monitor: model.resources) { model.openActivityWindow() }
            }
```

y reemplazar el `.background(WindowAccessor { … })` del Plan 12 por:

```swift
        .background(WindowAccessor { window in
            model.popoverWindow = window
            model.resources.setVisible("popover", window != nil)
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window = note.object as? NSWindow, window === model.popoverWindow else { return }
            model.resources.setVisible("popover", window.occlusionState.contains(.visible))
        }
```

(El `MenuBarExtra` deja la ventana creada al cerrarse; su `occlusionState` dice si está en pantalla.)

- [ ] **Step 3: `Activity/ActivityWindow.swift`:**

```swift
import AppKit
import PRBarCore
import SwiftUI

/// PRBar Activity (spec I): los procesos vivos por tarea, con Stop, y el disco por categoría y por repo, con Clean Up.
struct ActivityWindow: View {
    static let size = NSSize(width: 720, height: 600)

    @ObservedObject var model: AppModel
    @ObservedObject var monitor: ResourceMonitor
    @State private var deleteOld = false
    @State private var olderThanDays = 30
    @State private var lastResult: CleanupResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                now
                disk
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(WindowAccessor { window in monitor.setVisible("activity", window != nil) })
        .onDisappear { monitor.setVisible("activity", false) }
    }

    // MARK: Ahora

    private var groups: [(activity: ProcessActivity?, rows: [ProcessUsage])] {
        let rows = monitor.usage?.processes ?? []
        let grouped = Dictionary(grouping: rows.filter { !$0.isApp }, by: { $0.activity })
        return grouped.map { ($0.key, $0.value) }.sorted { ($0.activity?.title ?? "~") < ($1.activity?.title ?? "~") }
    }

    private var now: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Now").font(.headline)
            if let usage = monitor.usage {
                Text(String(format: "CPU %.0f%% · RAM %@", usage.cpuPercent, ResourceFooter.bytes(Int64(clamping: usage.memoryBytes))))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if groups.isEmpty {
                    Text("Nothing is running.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.activity) { group in
                    taskCard(group.activity, group.rows)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func taskCard(_ activity: ProcessActivity?, _ rows: [ProcessUsage]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(activity?.title ?? "PRBar").font(.body.weight(.semibold))
                if let host = activity?.host {
                    Text("on \(host)").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.tint(Theme.blue)))
                }
                Spacer()
                if let activity, let stop = model.stopAction(for: activity) {
                    Button("Stop", action: stop).controlSize(.small)
                } else if activity?.kind == .update {
                    Button("Stop") {}.controlSize(.small).disabled(true).help("Can’t stop while PRBar is being replaced")
                }
            }
            ForEach(rows) { row in
                HStack {
                    Text(row.name).font(.callout.monospaced())
                    Text("\(row.pid)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    if row.remoteHost == nil {
                        Text(String(format: "%.0f%%", row.cpuPercent)).frame(width: 50, alignment: .trailing)
                        Text(ResourceFooter.bytes(Int64(clamping: row.memoryBytes))).frame(width: 80, alignment: .trailing)
                    } else {
                        Text("—").frame(width: 130, alignment: .trailing)
                    }
                    Text(row.startedAt.map { RelativeAge.short(from: $0) } ?? "—").frame(width: 60, alignment: .trailing)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.primary.opacity(0.04)))
    }

    // MARK: Disco

    private var disk: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Disk").font(.headline)
                if monitor.scanningDisk { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { monitor.refreshDisk(force: true) }.controlSize(.small)
            }
            if let usage = monitor.disk {
                Text("Total \(ResourceFooter.bytes(usage.total))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                ForEach(DiskCategoryKind.allCases, id: \.self) { kind in
                    HStack {
                        Text(kind.title)
                        Spacer()
                        Text(ResourceFooter.bytes(usage.bytes(kind))).monospacedDigit()
                    }
                }
                let worktrees = usage.items.filter { $0.kind == .worktrees }
                if !worktrees.isEmpty {
                    Divider()
                    ForEach(usage.worktreesByRepo, id: \.repo) { entry in
                        let items = worktrees.filter { ($0.repo ?? "Other") == entry.repo }
                        let orphans = items.filter { $0.state == .orphan }.count
                        HStack {
                            Text(entry.repo).font(.callout)
                            Text("\(items.count - orphans) active · \(orphans) leftover").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(ResourceFooter.bytes(entry.bytes)).monospacedDigit()
                        }
                    }
                }
                Divider()
                HStack {
                    Toggle("Also delete history and logs older than", isOn: $deleteOld)
                    Stepper("\(olderThanDays) days", value: $olderThanDays, in: 1...365).disabled(!deleteOld)
                }
                HStack {
                    Button("Clean Up…") { Task { await confirmCleanUp() } }
                    if let lastResult { Text(resultText(lastResult)).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func confirmCleanUp() async {
        let days = deleteOld ? olderThanDays : nil
        let plan = await model.cleanupPreview(olderThanDays: days)
        guard !plan.isEmpty else {
            lastResult = CleanupResult()
            return
        }
        let list = plan.candidates.prefix(8).map { "• \($0.title) (\(ResourceFooter.bytes($0.bytes)))" }.joined(separator: "\n")
        let more = plan.candidates.count > 8 ? "\n…and \(plan.candidates.count - 8) more" : ""
        ConfirmAlert.present(
            title: "Free \(ResourceFooter.bytes(plan.totalBytes))?",
            message: "PRBar will delete:\n\(list)\(more)\n\nRunning jobs and worktrees with unpushed fixes are never touched.",
            action: "Clean Up"
        ) {
            Task { lastResult = try? await model.cleanup(olderThanDays: days, confirmed: true) }
        }
    }

    private func resultText(_ result: CleanupResult) -> String {
        if result.removed.isEmpty && result.skipped.isEmpty && result.failed.isEmpty { return "Nothing to clean up." }
        var parts = ["Freed \(ResourceFooter.bytes(result.freedBytes))"]
        if !result.skipped.isEmpty { parts.append("skipped \(result.skipped.count)") }
        if !result.failed.isEmpty { parts.append("\(result.failed.count) failed") }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Settings › General.** En `GeneralTab`, una sección nueva **antes** de `UpdatesSection(…)`:

```swift
            Section {
                Toggle("Warn when PRBar uses more than", isOn: Binding(
                    get: { configStore.config.resources.diskWarningGB != nil },
                    set: { on in try? model.configSetDiskWarning(gigabytes: on ? 5 : nil) }
                ))
                if let limit = configStore.config.resources.diskWarningGB {
                    Stepper("\(limit) GB", value: Binding(get: { limit }, set: { try? model.configSetDiskWarning(gigabytes: $0) }),
                            in: ResourceSettings.gigabyteRange)
                }
            } header: {
                Text("Disk")
            } footer: {
                Text("A notification when PRBar’s worktrees, history and logs pass this size. See them in PRBar Activity.")
            }
```

> Usar el mismo patrón de `Binding`/errores que las otras secciones de `GeneralTab` (si guardan con `model.updateConfig { … }`, usar eso).

- [ ] **Step 5: Build y mirar.** `swift build --product PRBar` sin warnings.

- [ ] **Step 6: Inventario.** `swift build --product PRBarTests && swift run PRBarTests "paridad UI"` y agregar lo que pida, con estas entradas (los conteos, los que diga el test):

```swift
        .init("Popover/ResourceFooter.swift", "Button", "-", 1, .cli(["resources"])),
        .init("Popover/PopoverView.swift", "Component:ResourceFooter", "-", 1, .cli(["resources"])),
        .init("Activity/ActivityWindow.swift", "Button", "Stop", 2, .cli(["review cancel", "respond cancel", "chat", "rules chat", "update"])),   // por tarea; el de update deshabilitado
        .init("Activity/ActivityWindow.swift", "Button", "Refresh", 1, .cli(["resources"])),
        .init("Activity/ActivityWindow.swift", "Toggle", "Also delete history and logs older than", 1, .cli(["cleanup"])),   // --older-than
        .init("Activity/ActivityWindow.swift", "Stepper", #"\(olderThanDays) days"#, 1, .cli(["cleanup"])),
        .init("Activity/ActivityWindow.swift", "Button", "Clean Up…", 1, .cli(["cleanup"])),
        .init("Activity/ActivityWindow.swift", "ConfirmAlert", "-", 1, .cli(["cleanup"])),   // --yes
        .init("Activity/ActivityWindow.swift", "Component:WindowAccessor", "-", 1, .viewOnly("tracks the window")),
        .init("Settings/GeneralTab.swift", "Toggle", "Warn when PRBar uses more than", 1, .cli(["config set"])),   // disk-warning
        .init("Settings/GeneralTab.swift", "Stepper", #"\(limit) GB"#, 1, .cli(["config set"])),
```

> `prbar chat <pr> --stop`, `prbar rules chat --stop` y `prbar update --cancel` son los Stop de chat, instrucciones y update. Si el escáner no ve `ConfirmAlert` con título literal (el título es interpolado), la clave puede salir con otro label: copiar la que imprime el test.

Run: `swift run PRBarTests paridad` → `passed`.

- [ ] **Step 7: Suite.** `swift run PRBarTests` → `N/N passed`.

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBar Sources/PRBarTests/UIActionInventory.swift
git commit -m "Show PRBar's resources in the popover and the PRBar Activity window"
```

---

### Task 11: Capturas — pie del popover y ventana Activity

**Files:**
- Modify: `Sources/PRBar/Snapshots/SnapshotMode.swift`, `SnapshotFixtures.swift`, `Sources/PRBarCore/ResourceMonitor.swift` (un `applySnapshotState` para datos fijos)
- Modify: `docs/screenshots/README.md` y PNG

- [ ] **Step 1: Datos fijos.** En `ResourceMonitor`:

```swift
    /// Modo de capturas: números fijos, sin muestrear ni escanear.
    public func applySnapshotState(usage: ResourceUsage, disk: DiskUsage) {
        self.usage = usage
        self.disk = disk
    }
```

En `SnapshotFixtures` (extensión al final): `resourceUsage` con CPU 12 %, RAM 640 MB y filas: "PRBar" (pid 501, 2 %, 180 MB), "Review api#317 · claude" (pid 9123, 9 %, 410 MB, empezó hace 3 min), "Review api#317 · git" (pid 9188, 1 %, 50 MB); y `diskUsage` de 2,3 GB: worktrees 1,1 GB (`acme/api` activo 640 MB, `acme/web-app` huérfano 460 MB), updater 900 MB, history 210 MB, logs 60 MB, app data 30 MB. Con `scannedAt: now`.

- [ ] **Step 2:** en `makeModel`, después de `applySnapshotState(tools:…)`: `model.resources.applySnapshotState(usage: fixtures.resourceUsage, disk: fixtures.diskUsage)`. En `renderAll()`, después de `updateWindow()`:

```swift
        let activity = try makeModel("activity", snapshot: fixtures.snapshot)
        try await window("activity", title: "PRBar Activity", size: NSSize(width: 720, height: 640)) {
            ActivityWindow(model: activity, monitor: activity.resources)
        }
```

(`window(_:title:size:content:)` es el helper que ya usan las otras capturas.)

- [ ] **Step 3:** `swift build --product PRBar && Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y mirar con Read: `popover-*` con el pie "CPU 12% RAM 640 MB Disk 2.3 GB ›"; `activity-{light,dark}.png` con "Now" (una tarjeta "Review api#317" con Stop y dos procesos) y "Disk" (cinco categorías, `acme/api 1 active · 0 leftover`, `acme/web-app 0 active · 1 leftover`, el toggle y "Clean Up…"). Nada cortado.

- [ ] **Step 4:** `docs/screenshots/README.md`: la fila de `popover` menciona el pie; fila nueva `| \`activity\` | PRBar Activity: processes by task with Stop, disk by category and repo, Clean Up |`. `Scripts/snapshots.sh docs/screenshots both`; revertir PNG ajenos sin cambios reales.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBar/Snapshots Sources/PRBarCore/ResourceMonitor.swift docs/screenshots
git commit -m "Capture the resources footer and PRBar Activity"
```

---

### Task 12: Spec I.1, QA y verificación final

**Files:**
- Modify: `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`
- Create: `docs/qa/plan-13-checklist.md`

- [ ] **Step 1: Spec.** Si la parte I ya está en el spec principal, agregar al final de I `### I.1 Decisiones de implementación (Plan 13)` con las 13 decisiones de este plan. Si no está, dejarlo pendiente y avisarlo.

- [ ] **Step 2: Checklist** `docs/qa/plan-13-checklist.md`:

```markdown
# QA manual — Plan 13 (recursos)

PRBar instalada, con un repo con `localPath`. Abrir Activity Monitor al lado para comparar.

## A. Pie del popover
- [ ] El pie muestra "CPU N% RAM N MB Disk N GB ›" en las dos pestañas.
- [ ] Con el popover abierto, los números cambian cada ~2 s; con el popover cerrado, `sample PRBar` / Activity Monitor no muestra trabajo periódico de PRBar.
- [ ] Durante un review, CPU y RAM suben y se parecen a la suma de PRBar + claude + node en Activity Monitor (± lo que cambie en 2 s).
- [ ] Clic en el pie abre "PRBar Activity".

## B. Ventana Activity
- [ ] "Now" lista "Review <repo>#N" con sus procesos (claude, git…), CPU, RAM y tiempo corriendo.
- [ ] Stop en un review lo cancela (la fila del popover vuelve a "Review with Claude") y sus procesos desaparecen.
- [ ] Stop en Respond, en un chat y en el chat de Instructions los paran.
- [ ] Durante una actualización, "Update build · swift" aparece; Stop la cancela mientras compila; mientras reemplaza la app, Stop está deshabilitado.
- [ ] "Disk" muestra las cinco categorías y los worktrees por repo.

## C. Clean Up
- [ ] Dejar un worktree huérfano a mano (copiar uno de `$TMPDIR/PRBar/worktrees` con otro id y fecha vieja: `touch -t 202601010000`). Clean Up… lo lista y lo borra; el clone del usuario no pierde ningún worktree suyo (`git worktree list`).
- [ ] Con un review corriendo, Clean Up no toca su worktree.
- [ ] Un worktree de Responder con un fix sin pushear aparece en "skipped … unpushed commit".
- [ ] "Also delete history and logs older than 30 days": borra solo registros viejos; `prbar.log` sigue.
- [ ] Durante una actualización, el staging del updater no se ofrece.

## D. Umbral
- [ ] Settings › General › Disk: "Warn when PRBar uses more than 1 GB" con más de 1 GB usado → llega "PRBar Is Using a Lot of Disk" una sola vez; clic abre Activity.
- [ ] Apagarlo: no vuelve a llegar.

## E. CLI (con `PRBAR_SOCKET` de la PRBar instalada)
- [ ] `prbar resources` muestra totales, procesos y disco; `--json` trae `usage` y `disk`.
- [ ] `prbar cleanup --preview` lista lo que borraría; `prbar cleanup` pregunta; `prbar cleanup --yes` borra; sin nada: "Nothing to clean up."
- [ ] `echo | prbar cleanup` (sin terminal) con algo para borrar sale con "needs confirmation".
- [ ] `prbar config set disk-warning 5` / `off` cambian Settings.
```

- [ ] **Step 3: Verificación final.** `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests && swift run PRBarTests` → sin warnings nuevos, `N/N passed` (3 veces seguidas: hay tests con tiempos).

- [ ] **Step 4: Commit.**

```bash
git add docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md docs/qa/plan-13-checklist.md
git commit -m "docs: resources implementation decisions and QA checklist"
```

---

## Self-review

- **Cobertura del spec I:** línea al pie con CPU/RAM/Disk (Tasks 2, 3, 10); CPU y RAM de la app y sus hijos sumados, cada 2 s solo con el popover o la ventana abiertos, con libproc y sin `ps` (Tasks 2, 3, 6, 10); CPU en % de un núcleo (decisión 7); disco de Application Support + worktrees dentro de los clones, en segundo plano, cacheado 60 s y al terminar un trabajo (Tasks 4, 6, 9); ventana Activity con procesos y tarea, CPU, RAM, tiempo y Stop (Tasks 1, 9, 10); disco por categoría y repo con activos/huérfanos (Task 4) y Clean Up seguro con confirmación y total (Tasks 5, 10), nunca `git worktree prune` ni worktrees activos/con fixes sin pushear (Task 5); remotos "on <host>" sin CPU/RAM (Task 2, `ProcessActivity.host`, que llena el Plan 14); umbral opcional (Tasks 6, 7, 10); CLI `resources` y `cleanup` (Task 8); tests de árbol, disco, Clean Up y muestreo (Tasks 1–6).
- **Placeholders:** los "buscar por nombre y adaptar" de la Task 9 nombran el símbolo y el comportamiento exacto que hace falta.
- **Tipos:** `ProcessActivity`, `ProcessRegistry`, `ProcessSampler`, `ResourceMeter`, `ResourceUsage`, `ProcessUsage`, `DiskUsage`, `DiskItem`, `DiskScanner`, `DiskScanInput`, `WorkspaceRegistry`, `CleanupPlan`, `CleanupCandidate`, `CleanupResult`, `DiskCleanup`, `DiskCleanupExecutor`, `ResourceMonitor`, `DiskWarningState`, `ResourceSettings`, `ResourcesInfo`, `ResourceActions` se definen antes de usarse con esos nombres.
