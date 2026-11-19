# PRBar — Plan 10: Ready to Merge (PRs aprobados y botón Merge)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mis PRs aprobados y sin nada que responder aparecen en una sección nueva del popover, **Ready to Merge (N)**, con un botón **Merge** (y un menú para elegir otro método) que mergea por GraphQL con `expectedHeadOid`, pide confirmación si está configurado, responde "Merged" en el hilo de Slack si PRBar había anunciado el PR y avisa con una notificación nueva cuando un PR entra a la categoría.

**Spec:** `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`, parte F (F.1–F.5 y F.7). **F.6 (CLI) no va acá:** es del Plan 7. Este plan deja las APIs de Core y de `AppModel` que esos comandos van a llamar; están al final ("APIs para la CLI"). Se apoya en el spec base `2026-11-18-prbar-design.md`:
- §7: reglas de clasificación (`ActionClassifier`);
- §9: notificaciones (`NotificationPlanner`, scopes ya consultados, agrupado);
- §15 y §17: anuncio en Slack y respuesta "Updated" en el hilo (provider, marcas `uncertain`, búsqueda en el hilo antes de reintentar, backoff del conector).

**Orden:** se ejecuta **después** de los planes 8 (actualizaciones) y 9 (instrucciones), que están escritos pero todavía no implementados. El Plan 6 (chat) ya está en `main`. Ver "Qué asume de los planes 8 y 9".

**Architecture:**
- **Core, datos:** `MergeModels.swift` define `MergeMethod`, `MergeableState`, `MergeStateStatus`, `PRMergeState` (por PR: node ID, mergeable, estado, `viewerCanUpdate`, cantidad de commits), `RepoMergeSettings` (por repo y cuenta: métodos permitidos, método por defecto de la cuenta, borrar rama, permiso) y `MergeSettings` (`config.json › merge`). `PullRequest.merge` y `Snapshot.repoMergeSettings` se leen en forma tolerante: un `state.json` viejo da "desconocido".
- **Core, GitHub:** la query de PRs abiertos pide los campos nuevos; `GitHubAPI.mergePullRequest(id:method:expectedHeadOid:token:)` corre la mutación y traduce los errores a `MergeError` (head cambiado, sin permiso, no mergeable).
- **Core, reglas:** `ActionClassifier` agrega `PRCategory.readyToMerge`; `MergePolicy` decide métodos permitidos, método por defecto y si el botón está habilitado según `mergeStateStatus`; `NotificationPlanner` agrega `readyToMerge` y evita el aviso doble con "approved".
- **Core, ejecución:** `MergeQueue` (`@MainActor`) guarda la fase de cada fila (Merging… / Merged / error) y llama a la API con el token de la cuenta (nunca pasa por Claude).
- **Core, Slack:** "Merged" es una escritura más del ciclo de Slack. `SlackAnnouncer.prMerged` deja pendiente un `MergedReply` en `SlackState`; `SlackPlanner` lo convierte en `SlackAction.merged`; `SlackAnnouncer.run` lo publica con las mismas protecciones que "Updated" (marca `uncertain`, búsqueda en el hilo antes de reintentar, backoff del conector).
- **App:** `AppModel+Merge.swift` es el único punto de entrada (UI y, después, CLI). Popover: sección Ready to Merge con `MergeButton` y una línea de estado; menú contextual "Merge" / "Merge With…". Diálogo de confirmación `MergeConfirmView` en una ventana chica de `WindowPresenter`. Settings: General (confirmar y notificación), Repos (método del repo) y Slack (interruptor y plantilla).

**Tech Stack:** Swift 5.10 (compilador 6.x), SwiftUI/AppKit (macOS 14), GitHub GraphQL API v4.

**Base:** rama `feat/plan-10-merge` desde `main`, con los planes 6, 8 y 9 ya integrados.

**Convenciones:**
- Tests: `swift run PRBarTests [filtro]` (runner propio; sale con código ≠ 0 si algo falla). Cada archivo de tests nuevo se registra en `Sources/PRBarTests/main.swift`, **al final** de `allTests`. `expect`/`expectEqual` toman autoclosures que **no** pueden tener `await`: primero el valor va a una variable local.
- Build: `swift build`. Capturas: `Scripts/snapshots.sh <dir> both` (o `swift run PRBar --snapshots <dir>`).
- Las fechas de los JSON van con `JSONCoding` (ISO 8601 sin fracciones): en los tests de ida y vuelta, fechas enteras (`t0`, `at(n)`).
- Commits en inglés, **sin** `Co-Authored-By` ni ninguna atribución a Claude/Anthropic. Sin push.
- UI en inglés. Comentarios de código en español, como el resto del repo.
- **Nunca** llamar a GitHub ni a Slack de verdad desde los tests: `FakeTransport`, `FakeAPI`, `FakeSlackAPI`.
- Las líneas que se citan son orientativas: los planes 8 y 9 movieron código. Buscar por el nombre del símbolo.

## Qué asume de los planes 8 y 9

Este plan se escribió contra `main` con el Plan 6, leyendo los planes 8 y 9. Asume que ya existen:

| Del plan | Artefacto | Cómo lo usa este plan |
|---|---|---|
| 8 | `NotificationKind.updateAvailable` (línea propia después de `case newToReview, …, myPRApprovedOrCIFailed`) | `case readyToMerge` va en una línea nueva **después** de `case updateAvailable`. |
| 8 | `PlannedNotification.updateVersion` y el `init` con `updateVersion: String? = nil` | No se toca; las notificaciones nuevas no lo pasan. |
| 8 | `NotificationSettings.isOn` con `case .updateAvailable: return true`; `title(for:)`/`groupTitle(for:count:)` con `.updateAvailable` | Se agrega `.readyToMerge` al final de cada `switch`. |
| 8 | `AppConfig.updates` y `CodingKeys` `case accounts, …, claude, updates` | `merge` se agrega como propiedad **después** de `updates` y con una línea `case merge` aparte en `CodingKeys`. |
| 8 | `UpdatesSection` como última sección de `GeneralTab` | La sección "Merging" va **antes** de la de Notifications, lejos de la del Plan 8. |
| 8 | `PopoverView.body` con `UpdateRow` | No se toca `body`; solo `actionable` y `section(_:)`. |
| 8 | Capturas: `.general` de Settings en 940 pt y `updateWindow()` después de `notification()` | Se suma al alto actual; la captura nueva va después de `respondWindows`. |
| 9 | `RepoConfig.ignorePaths` (última propiedad; último parámetro del `init`; `case worktreeDir, testCommand, ignorePaths`) | `mergeMethod` va **después** de `ignorePaths`, con una línea `case mergeMethod` aparte. |
| 9 | `AppConfig.setIgnorePaths` después de `setTestCommand` | `setMergeMethod` va después de `removeWatchedUser`, no en el mismo lugar. |
| 9 | Sección de rutas ignoradas en `ReposTab`, antes de `respondSection(repo)` | La sección nueva va **después** de `slackSection(repo)`. |
| 9 | `AppModelServices`/`AppModel` con servicios nuevos al final | Este plan no agrega servicios: solo una propiedad `lazy` (`merges`) antes de `orphanCleanup`. |

**Si alguno no está** (p. ej. se cambió el orden de los planes): agregar lo de este plan al final de la lista correspondiente (después del último `case`, de la última propiedad o del último parámetro) y seguir; nada de este plan depende del contenido de los planes 8 y 9.

## Archivos compartidos con otros planes

Para que el merge sea limpio:
- `Sources/PRBarCore/Config.swift`: `RepoConfig` (propiedad, parámetro y `CodingKeys` al final), `AppConfig` (propiedad y `CodingKeys` al final), `SlackSettings` (claves nuevas en una línea aparte de `CodingKeys`), `SlackToggle` (caso nuevo al final). Los tipos nuevos (`MergeSettings`, etc.) van en un archivo propio, `MergeModels.swift`.
- `Sources/PRBarCore/NotificationPlanner.swift`: casos nuevos al final de cada `switch`.
- `Sources/PRBar/AppModel.swift`: una sola propiedad nueva; todo lo demás va en `AppModel+Merge.swift` (mismo patrón que `AppModel+Updates.swift` del Plan 8).
- `Sources/PRBar/Settings/{GeneralTab,ReposTab,SlackTab}.swift`: secciones y filas nuevas en lugares que los planes 8 y 9 no tocan.
- `Sources/PRBar/Snapshots/{SnapshotMode,SnapshotFixtures,SnapshotFakes}.swift`: captura nueva en su propia función, fixtures en un `extension` al final, un método nuevo en `SnapshotGitHubAPI`.
- **Plan 7 (CLI), que va después:** su test de paridad recorre `PRCategory`, `SlackToggle`, `SlackTemplateKind` y los controles de la UI. Ver "APIs para la CLI" al final: hay que sumar `ready-to-merge`, `merged`, el comando `merge` y los controles nuevos a `UIActionInventory`.

## API de GitHub verificada

Con la referencia pública de GraphQL (`docs.github.com/en/graphql/reference/pulls` y `/repos`, consultada el 2026-11-19):
- `PullRequest`: `id: ID!`, `mergeable: MergeableState!` (`MERGEABLE`, `CONFLICTING`, `UNKNOWN` — "Mergeability is still being calculated"), `mergeStateStatus: MergeStateStatus!`, `viewerCanUpdate: Boolean!`, `reviewDecision: PullRequestReviewDecision` (nullable), `headRefOid: GitObjectID!`. `PullRequestCommitConnection.totalCount: Int!`.
- `MergeStateStatus`: `BEHIND`, `BLOCKED`, `CLEAN`, `DIRTY`, `DRAFT` (deprecado: "use `isDraft`"), `HAS_HOOKS`, `UNKNOWN`, `UNSTABLE`. El campo `mergeStateStatus` **ya no** tiene aviso de preview (antes pedía el header `merge-info-preview`): no se manda ningún `Accept` especial.
- `Repository`: `squashMergeAllowed: Boolean!`, `mergeCommitAllowed: Boolean!`, `rebaseMergeAllowed: Boolean!`, `viewerDefaultMergeMethod: PullRequestMergeMethod!`, `deleteBranchOnMerge: Boolean!`, `viewerPermission: RepositoryPermission` (nullable; `ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, `READ`).
- `PullRequestMergeMethod`: `MERGE`, `REBASE`, `SQUASH`.
- Mutación `mergePullRequest(input: MergePullRequestInput!)`: `pullRequestId: ID!`, `mergeMethod: PullRequestMergeMethod`, `expectedHeadOid: GitObjectID` ("OID that the pull request head ref must match to allow merge; if omitted, no check is performed"), `commitHeadline`, `commitBody`, `authorEmail`, `clientMutationId`. Devuelve `pullRequest` (se piden `merged` y `mergedAt`).
- La referencia hoy **recomienda** la API REST asíncrona de merge en lugar de esta mutación y aclara que la mutación no soporta PRs apilados. El spec pide la mutación con `expectedHeadOid`, que es exactamente lo que necesitamos (PRBar no apila PRs), así que se usa la mutación. Queda anotado en el spec (Task 15).
- GitHub no documenta los textos de error de la mutación. Se clasifican por `type` (`FORBIDDEN`, `UNPROCESSABLE`) y por frases conocidas ("Head branch was modified"); el QA confirma el texto real del head cambiado.

## Decisiones donde el spec era ambiguo

1. **Dónde viven los datos de merge.** Los del PR van en `PullRequest.merge` (`PRMergeState`). Los del repo dependen de la cuenta (`viewerDefaultMergeMethod`, `viewerPermission`), así que van en `Snapshot.repoMergeSettings`, con la misma clave que `fetchedScopes` (`"login|owner/repo"`). Un repo que falla en un refresco conserva los ajustes anteriores, igual que sus PRs.
2. **"Aprobación vigente" sin `reviewDecision`.** Por cada autor (que no sea yo) cuenta su **última** review entre `APPROVED`, `CHANGES_REQUESTED` y `DISMISSED`; un `COMMENTED` posterior no anula una aprobación. Hace falta al menos una `APPROVED` vigente y ninguna `CHANGES_REQUESTED` vigente. Las aprobaciones de bots cuentan (hay bots de aprobación).
3. **Conflictos.** Quedan afuera tanto `mergeable == CONFLICTING` como `mergeStateStatus == DIRTY`. Un `UNKNOWN` (GitHub todavía calcula) **sí** entra, con el botón en "Checking…".
4. **Permiso.** `viewerCanUpdate` se pide (lo dice el spec) pero no decide nada: para el autor del PR siempre es `true`. El botón se deshabilita con `viewerPermission` `READ` o `TRIAGE` ("You don’t have permission to merge in acme/api"); `viewerPermission` es un campo que el spec no menciona.
5. **Sin datos del repo** (refresco viejo o respuesta sin los campos): se ofrecen los tres métodos; si el repo no permite el elegido, GitHub lo rechaza y la fila muestra el error.
6. **Método por defecto:** `RepoConfig.mergeMethod` si está permitido; si no, `viewerDefaultMergeMethod` si está permitido; si no, el primero permitido en el orden squash, merge, rebase.
7. **Textos de habilitación:** `BEHIND` dice "Branch is behind \<base>" con la rama base real (el spec dice "main" como ejemplo). Sin node ID también es "Checking…".
8. **Botón:** siempre dice "Merge"; el método está en el tooltip ("Squash and Merge into main"), en el menú del chevron (con ✓ en el de por defecto) y en el diálogo.
9. **Diálogo de confirmación:** es una ventana chica (`WindowPresenter`, 440 × 230, no redimensionable), no un `.alert`: el popover es un `MenuBarExtra` y una alerta adentro se cierra con él. Muestra el título, `owner/repo · N commits · head → base`, un popup con los métodos permitidos, la nota de `UNSTABLE` y, si el repo borra la rama al mergear, "GitHub will delete the branch (repo setting)".
10. **Después del merge:** la fila muestra "Merged" 2 s y después PRBar refresca; la fila desaparece con ese refresco. Las fases de PRs que ya no están en el snapshot se descartan (`MergeQueue.prune`).
11. **Retry:** refresca primero (el error más común es que el PR cambió) y vuelve a pedir el merge con el mismo método; con `merge.confirm` encendido, se vuelve a confirmar.
12. **Slack "Merged":** queda pendiente en `SlackState.mergedReplies` (persistido) y sale por el ciclo normal del announcer como `SlackAction.merged`: mismo provider, marca `uncertain` `merged:<prID>`, búsqueda de la respuesta en el hilo antes de reintentar un intento dudoso, backoff del conector. Si falla, se reintenta en cada ciclo durante 24 h (`SlackPlanner.mergedReplyWindow`) y el error va a los issues de Slack y al log; el merge ya está hecho. Pedir "Merged" dos veces para el mismo PR no hace nada.
13. **`{method}`:** vale `squash`, `merge` o `rebase` (el valor de `config.json`). Solo existe en la plantilla "Merged".
14. **Notificación:** título "acme/api#42 is ready to merge" y cuerpo el título del PR. Si en el mismo refresco aplican "approved" y `readyToMerge`, solo sale `readyToMerge`; si la de `readyToMerge` está apagada, sale la de "approved" como antes.
15. **Clave de la plantilla para la CLI:** el spec dice `myPR.merged`, pero el Plan 7 nombra las plantillas `new-pr`, `update` y `round`. Se recomienda `merged` (y aceptar `myPR.merged` como alias). Ver "APIs para la CLI".

---

## Estructura de archivos

```
Sources/PRBarCore/
  MergeModels.swift          (nuevo) MergeMethod, MergeableState, MergeStateStatus, PRMergeState, RepoMergeSettings, MergeSettings
  MergePolicy.swift          (nuevo) MergeAvailability, MergeOptions, MergePolicy
  MergeError.swift           (nuevo) MergeError (+ clasificación de errores de GraphQL)
  MergeQueue.swift           (nuevo) MergeCompletion, MergePhase, MergeQueue
  Models.swift               (modificar) PullRequest.merge (+ decodificación tolerante), PRCategory.readyToMerge
  Snapshot.swift             (modificar) Snapshot.repoMergeSettings, SnapshotBuilder guarda y conserva los ajustes
  Config.swift               (modificar) RepoConfig.mergeMethod, AppConfig.merge, setMergeMethod,
                                         NotificationSettings.readyToMerge, SlackSettings.postMerged/mergedTemplate,
                                         SlackToggle.postMerged
  GraphQLModels.swift        (modificar) query con campos de merge, mutación, MergeMutationData
  GitHubClient.swift         (modificar) RepoPRs.mergeSettings, GitHubAPI.mergePullRequest, graphQLEnvelope
  ActionClassifier.swift     (modificar) readyToMerge, isReadyToMerge, hasCurrentApproval
  NotificationPlanner.swift  (modificar) NotificationKind.readyToMerge, dedupe con "approved"
  SlackTemplate.swift        (modificar) {method}
  SlackTemplatePreview.swift (modificar) SlackTemplateVariable.method, SlackTemplateKind.merged
  SlackState.swift           (modificar) MergedReply, SlackState.mergedReplies, uncertainKey(.merged)
  SlackPlanner.swift         (modificar) SlackAction.merged, acciones pendientes de "Merged"
  SlackAnnouncer.swift       (modificar) ejecuta .merged, prMerged(_:method:config:)
Sources/PRBar/
  AppModel.swift             (modificar) lazy var merges
  AppModel+Merge.swift       (nuevo) API de merge para la UI y la CLI, diálogo
  Popover/MergeButton.swift  (nuevo) MergeButton, MergeButtonActions, MergeStatusLabel
  Popover/MergeConfirmView.swift (nuevo) diálogo de confirmación
  Popover/PRRowView.swift    (modificar) botón, línea de estado, menú contextual, VoiceOver
  Popover/PopoverView.swift  (modificar) sección Ready to Merge
  Settings/GeneralTab.swift  (modificar) "Confirm before merging", notificación
  Settings/ReposTab.swift    (modificar) método de merge del repo
  Settings/SlackTab.swift    (modificar) "Reply “Merged”…" y su plantilla
  Snapshots/SnapshotFakes.swift    (modificar) SnapshotGitHubAPI.mergePullRequest
  Snapshots/SnapshotFixtures.swift (modificar) PRs listos para mergear y ajustes de repo
  Snapshots/SnapshotMode.swift     (modificar) captura merge-confirm, altos de Settings
Sources/PRBarTests/
  Fixtures.swift             (modificar) makePR(merge:)
  Fakes.swift                (modificar) FakeAPI/FakeFeedbackAPI.mergePullRequest
  ModelsTests.swift          (modificar) orden de categorías
  ClassifierTests.swift      (modificar) "una aprobación no es feedback" ahora es Ready to Merge
  SlackPlannerTests.swift    (modificar) helper text(_:) con .merged
  MergeModelsTests.swift, MergeConfigTests.swift, MergeDataTests.swift, ReadyToMergeTests.swift,
  ReadyToMergeNotificationTests.swift, MergePolicyTests.swift, MergeMutationTests.swift, MergeQueueTests.swift,
  SlackMergedTemplateTests.swift, SlackMergedReplyTests.swift   (nuevos)
  main.swift                 (modificar) registra los archivos nuevos
docs/qa/plan-10-checklist.md (nuevo)
docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md (modificar) F.8 decisiones
```

---

### Task 1: Modelos de merge, `PullRequest.merge` y `Snapshot.repoMergeSettings`

**Files:**
- Create: `Sources/PRBarCore/MergeModels.swift`
- Modify: `Sources/PRBarCore/Models.swift` (`PullRequest`), `Sources/PRBarCore/Snapshot.swift` (`Snapshot`)
- Modify: `Sources/PRBarTests/Fixtures.swift` (`makePR`)
- Test: `Sources/PRBarTests/MergeModelsTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/MergeModelsTests.swift`:

```swift
import Foundation
import PRBarCore

enum MergeModelsTests {
    static let cases: [TestCase] = [
        TestCase("merge models: método en minúsculas en config y en mayúsculas en GraphQL") {
            try expectEqual(MergeMethod.allCases.map(\.rawValue), ["squash", "merge", "rebase"])
            try expectEqual(MergeMethod.squash.graphQLValue, "SQUASH")
            try expectEqual(MergeMethod(graphQL: "REBASE"), .rebase)
            try expectEqual(MergeMethod(graphQL: "FAST_FORWARD"), nil)
            try expectEqual(MergeMethod(graphQL: nil), nil)
            try expectEqual(MergeMethod.allCases.map(\.actionTitle), ["Squash and Merge", "Merge", "Rebase and Merge"])
            try expectEqual(MergeMethod.allCases.map(\.title), ["Squash", "Merge", "Rebase"])
        },
        TestCase("merge models: estados de GitHub; los desconocidos → unknown") {
            try expectEqual(MergeableState(graphQL: "CONFLICTING"), .conflicting)
            try expectEqual(MergeableState(graphQL: "MERGEABLE"), .mergeable)
            try expectEqual(MergeableState(graphQL: nil), .unknown)
            try expectEqual(MergeStateStatus(graphQL: "CLEAN"), .clean)
            try expectEqual(MergeStateStatus(graphQL: "HAS_HOOKS"), .hasHooks)
            try expectEqual(MergeStateStatus(graphQL: "UNSTABLE"), .unstable)
            try expectEqual(MergeStateStatus(graphQL: "BLOCKED"), .blocked)
            try expectEqual(MergeStateStatus(graphQL: "BEHIND"), .behind)
            try expectEqual(MergeStateStatus(graphQL: "DIRTY"), .dirty)
            try expectEqual(MergeStateStatus(graphQL: "DRAFT"), .draft)
            try expectEqual(MergeStateStatus(graphQL: "SOMETHING_NEW"), .unknown)
        },
        TestCase("merge models: un PR de un state.json viejo (sin merge) se lee con .unknown") {
            let pr = makePR()
            var object = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(pr)) as? [String: Any] ?? [:]
            try expect(object["merge"] != nil)
            object["merge"] = nil
            let decoded = try JSONCoding.decoder.decode(PullRequest.self, from: JSONSerialization.data(withJSONObject: object))
            try expectEqual(decoded.merge, .unknown)
            try expectEqual(decoded, pr)
        },
        TestCase("merge models: PR con datos de merge sobrevive un round-trip; valores raros no rompen") {
            let pr = makePR(merge: PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .clean, viewerCanUpdate: true, commitCount: 3))
            let data = try JSONCoding.encoder.encode(pr)
            try expectEqual(try JSONCoding.decoder.decode(PullRequest.self, from: data), pr)
            let odd = try JSONCoding.decoder.decode(PRMergeState.self, from: Data(#"{"nodeID":"PR_1","mergeable":"maybe","status":42}"#.utf8))
            try expectEqual(odd, PRMergeState(nodeID: "PR_1"))
        },
        TestCase("merge models: métodos permitidos y permiso del repo") {
            let settings = RepoMergeSettings(
                squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .rebase,
                deleteBranchOnMerge: true, viewerPermission: "WRITE")
            try expectEqual(settings.allowedMethods, [.squash, .rebase])
            try expectEqual(settings.viewerCanMerge, true)
            try expectEqual(RepoMergeSettings(viewerPermission: "MAINTAIN").viewerCanMerge, true)
            try expectEqual(RepoMergeSettings(viewerPermission: "TRIAGE").viewerCanMerge, false)
            try expectEqual(RepoMergeSettings(viewerPermission: "READ").viewerCanMerge, false)
            try expectEqual(RepoMergeSettings().viewerCanMerge, nil)
            let partial = try JSONCoding.decoder.decode(
                RepoMergeSettings.self, from: Data(#"{"rebaseAllowed":false,"viewerDefault":"octopus"}"#.utf8))
            try expectEqual(partial.allowedMethods, [.squash, .merge])
            try expectEqual(partial.viewerDefault, nil)
            try expectEqual(partial.deleteBranchOnMerge, false)
        },
        TestCase("merge models: Snapshot viejo sin repoMergeSettings; uno nuevo sobrevive un round-trip") {
            let old = try JSONCoding.decoder.decode(Snapshot.self, from: Data(#"{"items":[],"fetchedAt":"2027-01-15T08:00:00Z"}"#.utf8))
            try expectEqual(old.repoMergeSettings, [:])
            let snapshot = Snapshot(items: [], fetchedAt: t0, repoMergeSettings: ["me|o/r": RepoMergeSettings(viewerDefault: .squash)])
            try expectEqual(try JSONCoding.decoder.decode(Snapshot.self, from: JSONCoding.encoder.encode(snapshot)), snapshot)
        },
    ]
}
```

Registrarlo en `Sources/PRBarTests/main.swift`, al final de `allTests`:

```swift
    + MergeModelsTests.cases
```

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "merge models"`
Expected: error de compilación (`cannot find 'MergeMethod' in scope`, `extra argument 'merge' in call`).

- [ ] **Step 3: Crear `Sources/PRBarCore/MergeModels.swift`.**

```swift
import Foundation

/// Cómo se mergea un PR (spec F.3). En `config.json` va en minúsculas (`"squash"`); en GraphQL, en mayúsculas.
public enum MergeMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case squash, merge, rebase

    public var id: String { rawValue }

    /// `PullRequestMergeMethod` de GraphQL.
    public var graphQLValue: String { rawValue.uppercased() }

    public init?(graphQL: String?) {
        guard let graphQL, let method = MergeMethod(rawValue: graphQL.lowercased()) else { return nil }
        self = method
    }

    /// Botón por defecto del diálogo y los ítems de "Merge With…".
    public var actionTitle: String {
        switch self {
        case .squash: "Squash and Merge"
        case .merge: "Merge"
        case .rebase: "Rebase and Merge"
        }
    }

    /// Nombre corto (Settings › Repos).
    public var title: String {
        switch self {
        case .squash: "Squash"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }
}

/// `MergeableState` de GitHub. `UNKNOWN` = GitHub todavía lo está calculando.
public enum MergeableState: String, Codable, Sendable {
    case mergeable, conflicting, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "MERGEABLE": self = .mergeable
        case "CONFLICTING": self = .conflicting
        default: self = .unknown
        }
    }
}

/// `MergeStateStatus` de GitHub. `DRAFT` está deprecado en la API (se usa `isDraft`), pero todavía puede llegar.
public enum MergeStateStatus: String, Codable, Sendable {
    case clean, hasHooks, unstable, blocked, behind, dirty, draft, unknown

    public init(graphQL: String?) {
        switch graphQL {
        case "CLEAN": self = .clean
        case "HAS_HOOKS": self = .hasHooks
        case "UNSTABLE": self = .unstable
        case "BLOCKED": self = .blocked
        case "BEHIND": self = .behind
        case "DIRTY": self = .dirty
        case "DRAFT": self = .draft
        default: self = .unknown
        }
    }
}

/// Lo que dice GitHub de un PR para mergearlo (spec F.2). Todo es opcional o `unknown`: un `state.json` viejo o una
/// respuesta sin estos campos se leen como "todavía no se sabe".
public struct PRMergeState: Hashable, Codable, Sendable {
    /// `PullRequest.id` (node ID), el que pide `mergePullRequest`.
    public var nodeID: String?
    public var mergeable: MergeableState
    public var status: MergeStateStatus
    public var viewerCanUpdate: Bool?
    /// Commits del PR (`commits.totalCount`), para el diálogo de confirmación.
    public var commitCount: Int?

    public static let unknown = PRMergeState()

    public init(
        nodeID: String? = nil, mergeable: MergeableState = .unknown, status: MergeStateStatus = .unknown,
        viewerCanUpdate: Bool? = nil, commitCount: Int? = nil
    ) {
        self.nodeID = nodeID
        self.mergeable = mergeable
        self.status = status
        self.viewerCanUpdate = viewerCanUpdate
        self.commitCount = commitCount
    }

    private enum CodingKeys: String, CodingKey { case nodeID, mergeable, status, viewerCanUpdate, commitCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeID = try? c.decodeIfPresent(String.self, forKey: .nodeID)
        mergeable = (try? c.decodeIfPresent(MergeableState.self, forKey: .mergeable)) ?? .unknown
        status = (try? c.decodeIfPresent(MergeStateStatus.self, forKey: .status)) ?? .unknown
        viewerCanUpdate = try? c.decodeIfPresent(Bool.self, forKey: .viewerCanUpdate)
        commitCount = try? c.decodeIfPresent(Int.self, forKey: .commitCount)
    }
}

/// Ajustes de merge de un repo vistos desde una cuenta (spec F.2). Se guardan en `Snapshot.repoMergeSettings`.
public struct RepoMergeSettings: Hashable, Codable, Sendable {
    public var squashAllowed: Bool
    public var mergeCommitAllowed: Bool
    public var rebaseAllowed: Bool
    /// `viewerDefaultMergeMethod`: el método que GitHub propone a esta cuenta en este repo.
    public var viewerDefault: MergeMethod?
    public var deleteBranchOnMerge: Bool
    /// `viewerPermission` (`ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, `READ`); `nil` si GitHub no lo dijo.
    public var viewerPermission: String?

    public init(
        squashAllowed: Bool = true, mergeCommitAllowed: Bool = true, rebaseAllowed: Bool = true,
        viewerDefault: MergeMethod? = nil, deleteBranchOnMerge: Bool = false, viewerPermission: String? = nil
    ) {
        self.squashAllowed = squashAllowed
        self.mergeCommitAllowed = mergeCommitAllowed
        self.rebaseAllowed = rebaseAllowed
        self.viewerDefault = viewerDefault
        self.deleteBranchOnMerge = deleteBranchOnMerge
        self.viewerPermission = viewerPermission
    }

    /// Los métodos que el repo permite, en el orden squash, merge, rebase.
    public var allowedMethods: [MergeMethod] {
        MergeMethod.allCases.filter { method in
            switch method {
            case .squash: squashAllowed
            case .merge: mergeCommitAllowed
            case .rebase: rebaseAllowed
            }
        }
    }

    /// `false` solo si GitHub dijo que la cuenta no puede escribir en el repo; `nil` si no se sabe.
    public var viewerCanMerge: Bool? {
        viewerPermission.map { ["ADMIN", "MAINTAIN", "WRITE"].contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case squashAllowed, mergeCommitAllowed, rebaseAllowed, viewerDefault, deleteBranchOnMerge, viewerPermission
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        squashAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .squashAllowed)) ?? true
        mergeCommitAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .mergeCommitAllowed)) ?? true
        rebaseAllowed = (try? c.decodeIfPresent(Bool.self, forKey: .rebaseAllowed)) ?? true
        viewerDefault = try? c.decodeIfPresent(MergeMethod.self, forKey: .viewerDefault)
        deleteBranchOnMerge = (try? c.decodeIfPresent(Bool.self, forKey: .deleteBranchOnMerge)) ?? false
        viewerPermission = try? c.decodeIfPresent(String.self, forKey: .viewerPermission)
    }
}

/// `config.json › merge` (spec F.5).
public struct MergeSettings: Hashable, Codable, Sendable {
    /// Pedir confirmación antes de mergear.
    public var confirm = true

    public init() {}

    enum CodingKeys: String, CodingKey { case confirm }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirm = (try? c.decodeIfPresent(Bool.self, forKey: .confirm)) ?? true
    }
}
```

- [ ] **Step 4: `PullRequest.merge` en `Sources/PRBarCore/Models.swift`.** En `struct PullRequest`:
  - después de `public let requestedReviewers: [String]`:

```swift
    /// Si se puede mergear (spec F.2). `.unknown` en `state.json` viejos.
    public let merge: PRMergeState
```

  - en el `init`, el último parámetro pasa a ser `requestedReviewers: [String], merge: PRMergeState = .unknown` y, al final del cuerpo, `self.merge = merge`;
  - después de `public var id: String { "\(repo.fullName)#\(number)" }`, agregar:

```swift
    private enum CodingKeys: String, CodingKey {
        case repo, number, title, url, isDraft, author, authorAvatarURL, baseRef, headRef, headOid, additions, deletions
        case createdAt, updatedAt, lastCommitAt, ciState, reviewDecision, reviews, comments, requestedReviewers, merge
    }

    /// Los `state.json` de antes de Ready to Merge no tienen `merge`: se leen con `.unknown`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(RepoRef.self, forKey: .repo)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        author = try c.decode(String.self, forKey: .author)
        authorAvatarURL = try c.decodeIfPresent(URL.self, forKey: .authorAvatarURL)
        baseRef = try c.decode(String.self, forKey: .baseRef)
        headRef = try c.decode(String.self, forKey: .headRef)
        headOid = try c.decode(String.self, forKey: .headOid)
        additions = try c.decode(Int.self, forKey: .additions)
        deletions = try c.decode(Int.self, forKey: .deletions)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        lastCommitAt = try c.decode(Date.self, forKey: .lastCommitAt)
        ciState = try c.decode(CIState.self, forKey: .ciState)
        reviewDecision = try c.decode(ReviewDecision.self, forKey: .reviewDecision)
        reviews = try c.decode([PRReview].self, forKey: .reviews)
        comments = try c.decode([PRComment].self, forKey: .comments)
        requestedReviewers = try c.decode([String].self, forKey: .requestedReviewers)
        merge = (try? c.decodeIfPresent(PRMergeState.self, forKey: .merge)) ?? .unknown
    }
```

`encode(to:)` lo sigue sintetizando Swift con esas `CodingKeys`.

- [ ] **Step 5: `Snapshot.repoMergeSettings` en `Sources/PRBarCore/Snapshot.swift`.** En `struct Snapshot`:
  - después de `public var fetchedScopes: Set<String>`:

```swift
    /// Ajustes de merge de cada repo consultado, por scope (`Snapshot.scope(account:repo:)`): dependen de la cuenta
    /// (método por defecto, permiso). Spec F.2.
    public var repoMergeSettings: [String: RepoMergeSettings]
```

  - el `init` agrega el parámetro final `repoMergeSettings: [String: RepoMergeSettings] = [:]` (después de `fetchedScopes: Set<String> = []`) y `self.repoMergeSettings = repoMergeSettings`;
  - `CodingKeys` pasa a `case items, fetchedAt, issues, failedCompletely, rateLimitedUntil, fetchedScopes, repoMergeSettings`;
  - al final de `init(from:)`:

```swift
        repoMergeSettings = (try? container.decodeIfPresent([String: RepoMergeSettings].self, forKey: .repoMergeSettings)) ?? [:]
```

- [ ] **Step 6: `makePR(merge:)` en `Sources/PRBarTests/Fixtures.swift`.** Agregar el parámetro `merge: PRMergeState = .unknown` al final de `makePR` (después de `updated: Int = 0`) y pasarlo en la llamada a `PullRequest(…)`: la última línea queda `reviews: reviews, comments: comments, requestedReviewers: requested, merge: merge`.

- [ ] **Step 7: Correr los tests.**

Run: `swift run PRBarTests "merge models"`
Expected: 6 `✓`.

Run: `swift build && swift run PRBarTests`
Expected: `Build complete!` y `N/N passed` (los `models:` y `snapshot:` de antes siguen pasando).

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBarCore/MergeModels.swift Sources/PRBarCore/Models.swift Sources/PRBarCore/Snapshot.swift \
        Sources/PRBarTests/Fixtures.swift Sources/PRBarTests/MergeModelsTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): add merge state to pull requests and snapshots"
```

---

### Task 2: Configuración: `RepoConfig.mergeMethod` y `AppConfig.merge`

**Files:**
- Modify: `Sources/PRBarCore/Config.swift` (`RepoConfig`, `AppConfig`, `extension AppConfig`)
- Test: `Sources/PRBarTests/MergeConfigTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/MergeConfigTests.swift`:

```swift
import Foundation
import PRBarCore

enum MergeConfigTests {
    static let cases: [TestCase] = [
        TestCase("merge config: por defecto confirma y ningún repo fija método") {
            try expect(AppConfig().merge.confirm)
            try expectEqual(RepoConfig(owner: "o", name: "r").mergeMethod, nil)
        },
        TestCase("merge config: un config viejo sin merge ni mergeMethod") {
            let json = #"{"accounts":[{"login":"me","repos":[{"owner":"o","name":"r"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expect(config.merge.confirm)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
        },
        TestCase("merge config: lee merge.confirm y mergeMethod") {
            let json = #"{"merge":{"confirm":false},"accounts":[{"login":"me","repos":[{"owner":"o","name":"r","mergeMethod":"rebase"}]}]}"#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expect(!config.merge.confirm)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, .rebase)
        },
        TestCase("merge config: valores inválidos caen en el default sin perder el resto") {
            let json = #"""
            {"merge":"yes","refreshIntervalMinutes":5,
             "accounts":[{"login":"me","repos":[{"owner":"o","name":"r","mergeMethod":"octopus","testCommand":"make test"}]}]}
            """#
            let config = try JSONCoding.decoder.decode(AppConfig.self, from: Data(json.utf8))
            try expect(config.merge.confirm)
            try expectEqual(config.refreshIntervalMinutes, 5)
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
            try expectEqual(config.accounts[0].repos[0].testCommand, "make test")
        },
        TestCase("merge config: setMergeMethod y round-trip") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me", repos: [RepoConfig(owner: "o", name: "r")])]
            config.setMergeMethod(.squash, repoID: "o/r", login: "me")
            config.merge.confirm = false
            try expectEqual(config.accounts[0].repos[0].mergeMethod, .squash)
            let decoded = try JSONCoding.decoder.decode(AppConfig.self, from: JSONCoding.encoder.encode(config))
            try expectEqual(decoded, config)
            config.setMergeMethod(nil, repoID: "o/r", login: "me")
            try expectEqual(config.accounts[0].repos[0].mergeMethod, nil)
            config.setMergeMethod(.merge, repoID: "o/otro", login: "me")
            try expectEqual(config.accounts[0].repos.map(\.mergeMethod), [nil])
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ MergeConfigTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "merge config"`
Expected: error de compilación `value of type 'AppConfig' has no member 'merge'`.

- [ ] **Step 3: `RepoConfig.mergeMethod`.** En `Sources/PRBarCore/Config.swift`, dentro de `RepoConfig`:
  - después de la última propiedad (`public var ignorePaths: [String]`, del Plan 9):

```swift
    /// Método de merge fijado para el repo (spec F.5); `nil` = el de GitHub (`viewerDefaultMergeMethod`).
    public var mergeMethod: MergeMethod?
```

  - en el `init`, agregar el parámetro `mergeMethod: MergeMethod? = nil` al final (después de `ignorePaths: [String] = []`) y `self.mergeMethod = mergeMethod` al final del cuerpo;
  - en `CodingKeys`, una línea nueva al final del enum: `case mergeMethod`;
  - al final de `init(from:)`:

```swift
        // Un valor desconocido (p. ej. de una versión más nueva) cuenta como "el de GitHub".
        mergeMethod = try? c.decodeIfPresent(MergeMethod.self, forKey: .mergeMethod)
```

- [ ] **Step 4: `AppConfig.merge`.** En `struct AppConfig`:
  - después de `public var updates = UpdateSettings()` (Plan 8):

```swift
    public var merge = MergeSettings()
```

  - en `CodingKeys`, una línea nueva al final del enum: `case merge`;
  - al final de `init(from:)`:

```swift
        merge = (try? c.decodeIfPresent(MergeSettings.self, forKey: .merge)) ?? MergeSettings()
```

- [ ] **Step 5: `setMergeMethod`.** En `extension AppConfig` (mutaciones), después de `removeWatchedUser(_:repoID:login:)` y antes de `private mutating func withAccount`:

```swift
    /// `nil` = el método por defecto de GitHub para el repo.
    public mutating func setMergeMethod(_ method: MergeMethod?, repoID: String, login: String) {
        withRepo(repoID, login: login) { $0.mergeMethod = method }
    }
```

- [ ] **Step 6: Correr los tests.**

Run: `swift run PRBarTests "merge config"`
Expected: 5 `✓`.

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 7: Commit.**

```bash
git add Sources/PRBarCore/Config.swift Sources/PRBarTests/MergeConfigTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): add merge settings to the config"
```

---

### Task 3: GraphQL: campos de merge y ajustes del repo en el snapshot

**Files:**
- Modify: `Sources/PRBarCore/GraphQLModels.swift` (`Queries.openPullRequests`, `PRQueryData`, `PRNode`)
- Modify: `Sources/PRBarCore/GitHubClient.swift` (`RepoPRs`, `openPullRequests`)
- Modify: `Sources/PRBarCore/Snapshot.swift` (`SnapshotBuilder.build`)
- Test: `Sources/PRBarTests/MergeDataTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/MergeDataTests.swift`:

```swift
import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

private let mergePage = """
{"data":{"repository":{"defaultBranchRef":{"name":"main"},
 "squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":true,
 "viewerDefaultMergeMethod":"REBASE","deleteBranchOnMerge":true,"viewerPermission":"WRITE",
 "pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"id":"PR_kwDOA","number":42,"title":"Ship it","url":"https://github.com/o/r/pull/42","isDraft":false,
  "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-18T09:00:00Z","additions":3,"deletions":1,
  "baseRefName":"main","headRefName":"feat/x","headRefOid":"cafe42","reviewDecision":"APPROVED",
  "mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","viewerCanUpdate":true,
  "author":{"login":"me","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"comments":{"nodes":[]},
  "commits":{"totalCount":3,"nodes":[{"commit":{"committedDate":"2026-11-18T08:00:00Z","statusCheckRollup":{"state":"FAILURE"}}}]}}
]}}}}
"""

/// Una respuesta sin ninguno de los campos nuevos (p. ej. de antes de este plan).
private let bareNode = """
{"data":{"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
 {"number":1,"title":"PR 1","url":"https://github.com/o/r/pull/1","isDraft":false,
  "createdAt":"2026-11-17T10:00:00Z","updatedAt":"2026-11-17T10:00:00Z","additions":1,"deletions":1,
  "baseRefName":"main","headRefName":"f","headRefOid":"x","reviewDecision":null,
  "author":{"login":"juan","__typename":"User"},
  "reviewRequests":{"nodes":[]},"reviews":{"nodes":[]},"comments":{"nodes":[]},"commits":{"nodes":[]}}
]}}}}
"""

private let settings = RepoMergeSettings(
    squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .rebase,
    deleteBranchOnMerge: true, viewerPermission: "WRITE")

private func builder(_ api: FakeAPI, tokens: FakeTokens = FakeTokens()) -> SnapshotBuilder {
    SnapshotBuilder(api: api, tokens: tokens, now: { t0 })
}

enum MergeDataTests {
    static let cases: [TestCase] = [
        TestCase("merge data: mapea node id, mergeable, mergeStateStatus, commits y ajustes del repo") {
            let transport = FakeTransport([(200, [:], mergePage)])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.pullRequests.count, 1)
            try expectEqual(result.pullRequests[0].merge, PRMergeState(
                nodeID: "PR_kwDOA", mergeable: .mergeable, status: .unstable, viewerCanUpdate: true, commitCount: 3))
            try expectEqual(result.pullRequests[0].reviewDecision, .approved)
            try expectEqual(result.mergeSettings, settings)
        },
        TestCase("merge data: la query pide los campos de merge") {
            let transport = FakeTransport([(200, [:], mergePage)])
            _ = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            let body = transport.bodyString(0)
            for field in ["mergeable", "mergeStateStatus", "viewerCanUpdate", "totalCount", "squashMergeAllowed",
                          "mergeCommitAllowed", "rebaseMergeAllowed", "viewerDefaultMergeMethod", "deleteBranchOnMerge",
                          "viewerPermission"] {
                try expect(body.contains(field), "missing \(field)")
            }
        },
        TestCase("merge data: una respuesta sin los campos nuevos → desconocido y sin ajustes") {
            let transport = FakeTransport([(200, [:], bareNode)])
            let result = try await GitHubClient(transport: transport).openPullRequests(in: repo, token: "tok")
            try expectEqual(result.pullRequests[0].merge, .unknown)
            try expectEqual(result.mergeSettings, nil)
        },
        TestCase("merge data: el snapshot guarda los ajustes por cuenta y repo") {
            let api = FakeAPI(prs: ["o/r": .success(RepoPRs(defaultBranch: "develop", pullRequests: [], mergeSettings: settings))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: nil)
            try expectEqual(snapshot.repoMergeSettings, ["me|o/r": settings])
        },
        TestCase("merge data: un repo que falla conserva los ajustes anteriores") {
            let previous = Snapshot(items: [], fetchedAt: t0, fetchedScopes: ["me|o/r"], repoMergeSettings: ["me|o/r": settings])
            let api = FakeAPI(prs: ["o/r": .failure(.http(status: 502, message: "Bad Gateway"))])
            let snapshot = await builder(api).build(config: config(account("me")), previous: previous)
            try expectEqual(snapshot.repoMergeSettings, ["me|o/r": settings])
        },
        TestCase("merge data: una cuenta sin token conserva solo sus ajustes") {
            let previous = Snapshot(items: [], fetchedAt: t0, fetchedScopes: ["me|o/r", "otra|o/r"],
                                    repoMergeSettings: ["me|o/r": settings, "otra|o/r": RepoMergeSettings()])
            let api = FakeAPI(prs: ["o/r": .success(RepoPRs(defaultBranch: "develop", pullRequests: []))])
            let snapshot = await builder(api, tokens: FakeTokens(failing: ["me"]))
                .build(config: config(account("me"), account("otra")), previous: previous)
            // "otra" se consultó bien y la respuesta no trajo ajustes; "me" no se pudo consultar y queda como estaba.
            try expectEqual(snapshot.repoMergeSettings, ["me|o/r": settings])
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ MergeDataTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "merge data"`
Expected: error de compilación (`extra argument 'mergeSettings' in call`, `value of type 'RepoPRs' has no member 'mergeSettings'`).

- [ ] **Step 3: La query.** En `Sources/PRBarCore/GraphQLModels.swift`, reemplazar `Queries.openPullRequests` completo por:

```swift
    static let openPullRequests = """
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed viewerDefaultMergeMethod deleteBranchOnMerge viewerPermission
        pullRequests(states: OPEN, first: 50, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id number title url isDraft createdAt updatedAt additions deletions
            baseRefName headRefName headRefOid reviewDecision mergeable mergeStateStatus viewerCanUpdate
            author { login avatarUrl __typename }
            reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } } } }
            reviews(last: 50) { nodes { author { login __typename } state submittedAt commit { oid } } }
            comments(last: 50) { nodes { author { login __typename } createdAt } }
            commits(last: 1) { totalCount nodes { commit { committedDate statusCheckRollup { state } } } }
          }
        }
      }
    }
    """
```

- [ ] **Step 4: Decodificar los campos.** En `PRQueryData.Repository`, después de `let pullRequests: Connection`:

```swift
        // Ajustes de merge (spec F.2). Opcionales: si faltan, no se sabe.
        let squashMergeAllowed: Bool?
        let mergeCommitAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let viewerDefaultMergeMethod: String?
        let deleteBranchOnMerge: Bool?
        let viewerPermission: String?

        /// `nil` si la respuesta no trae ninguno de los métodos (una respuesta vieja o recortada).
        var mergeSettings: RepoMergeSettings? {
            guard squashMergeAllowed != nil || mergeCommitAllowed != nil || rebaseMergeAllowed != nil else { return nil }
            return RepoMergeSettings(
                squashAllowed: squashMergeAllowed ?? false, mergeCommitAllowed: mergeCommitAllowed ?? false,
                rebaseAllowed: rebaseMergeAllowed ?? false, viewerDefault: MergeMethod(graphQL: viewerDefaultMergeMethod),
                deleteBranchOnMerge: deleteBranchOnMerge ?? false, viewerPermission: viewerPermission
            )
        }
```

En `struct PRNode`:
  - después de `struct CommitWrapper { … }`, agregar:

```swift
    struct CommitConnection: Decodable {
        let totalCount: Int?
        let nodes: [CommitWrapper?]
    }
```

  - antes de `let number: Int`, agregar `let id: String?`;
  - después de `let reviewDecision: String?`, agregar:

```swift
    let mergeable: String?
    let mergeStateStatus: String?
    let viewerCanUpdate: Bool?
```

  - `let commits: Nodes<CommitWrapper>` pasa a `let commits: CommitConnection`;
  - en `toPullRequest(repo:)`, la última línea del `PullRequest(…)` (`requestedReviewers: reviewRequests.nodes.compactMap { $0?.requestedReviewer?.login }`) pasa a:

```swift
            requestedReviewers: reviewRequests.nodes.compactMap { $0?.requestedReviewer?.login },
            merge: PRMergeState(
                nodeID: id, mergeable: MergeableState(graphQL: mergeable), status: MergeStateStatus(graphQL: mergeStateStatus),
                viewerCanUpdate: viewerCanUpdate, commitCount: commits.totalCount
            )
```

- [ ] **Step 5: `RepoPRs.mergeSettings`.** En `Sources/PRBarCore/GitHubClient.swift`, `RepoPRs` pasa a:

```swift
public struct RepoPRs: Equatable, Sendable {
    public let defaultBranch: String
    public let pullRequests: [PullRequest]
    /// Métodos permitidos y método por defecto de la cuenta (spec F.2); `nil` si la respuesta no los trajo.
    public let mergeSettings: RepoMergeSettings?

    public init(defaultBranch: String, pullRequests: [PullRequest], mergeSettings: RepoMergeSettings? = nil) {
        self.defaultBranch = defaultBranch
        self.pullRequests = pullRequests
        self.mergeSettings = mergeSettings
    }
}
```

En `openPullRequests(in:token:)`:
  - después de `var defaultBranch = "main"`: `var mergeSettings: RepoMergeSettings?`;
  - después de `defaultBranch = repository.defaultBranchRef?.name ?? defaultBranch`: `mergeSettings = mergeSettings ?? repository.mergeSettings`;
  - el `return` pasa a `return RepoPRs(defaultBranch: defaultBranch, pullRequests: pullRequests, mergeSettings: mergeSettings)`.

- [ ] **Step 6: `SnapshotBuilder` guarda y conserva los ajustes.** En `Sources/PRBarCore/Snapshot.swift`, reemplazar `public func build(config:previous:)` completo por:

```swift
    public func build(config: AppConfig, previous: Snapshot?) async -> Snapshot {
        var collected: [ClassifiedPR] = []
        var issues: [RefreshIssue] = []
        var attempts = 0
        var successes = 0
        var rateLimitedUntil: Date?
        var fetchedScopes: Set<String> = []
        var mergeSettings: [String: RepoMergeSettings] = [:]

        func record(_ error: Error, account: String, repo: RepoRef?) {
            let prbarError: PRBarError = switch error {
            case let error as PRBarError: error
            case let error as URLError: .network(error.localizedDescription)
            default: .invalidResponse(error.localizedDescription)
            }
            issues.append(RefreshIssue(account: account, repo: repo, error: prbarError))
            AppLog.write("Error refreshing \(repo.map { "\($0.fullName) (\(account))" } ?? account): \(error)")
            if case PRBarError.rateLimited(let reset) = error {
                rateLimitedUntil = max(rateLimitedUntil ?? reset, reset)
            }
        }

        /// Lo de un scope que no se pudo consultar queda como estaba: sus PRs y sus ajustes de merge.
        func carry(account: String, repo: RepoRef?) {
            collected += carryOver(previous, account: account, repo: repo)
            for (scope, settings) in previous?.repoMergeSettings ?? [:] where scope.hasPrefix("\(account)|") {
                if let repo, scope != Snapshot.scope(account: account, repo: repo) { continue }
                mergeSettings[scope] = settings
            }
        }

        // Cada repo es una consulta; una cuenta sin repos cuenta como una sola, que se resuelve con el token.
        // Solo es "falla total" si hubo consultas y ninguna salió bien.
        for account in config.accounts where account.enabled {
            // Con el rate limit encima, no se gastan más consultas en este ciclo: se conserva lo anterior.
            if rateLimitedUntil != nil {
                carry(account: account.login, repo: nil)
                continue
            }
            let token: String
            do {
                token = try await tokens.token(for: account.login)
            } catch {
                attempts += 1
                record(error, account: account.login, repo: nil)
                carry(account: account.login, repo: nil)
                continue
            }
            if account.repos.isEmpty {
                attempts += 1
                successes += 1
            }
            for repoConfig in account.repos {
                if rateLimitedUntil != nil {
                    carry(account: account.login, repo: repoConfig.repo)
                    continue
                }
                attempts += 1
                do {
                    let result = try await api.openPullRequests(in: repoConfig.repo, token: token)
                    successes += 1
                    let scope = Snapshot.scope(account: account.login, repo: repoConfig.repo)
                    fetchedScopes.insert(scope)
                    if let settings = result.mergeSettings { mergeSettings[scope] = settings }
                    let bases = Set(repoConfig.baseBranches.isEmpty ? [result.defaultBranch] : repoConfig.baseBranches)
                    for pr in result.pullRequests where bases.contains(pr.baseRef) {
                        if let category = ActionClassifier.classify(pr, me: account.login, watchedUsers: Set(repoConfig.watchedUsers)) {
                            collected.append(ClassifiedPR(pr: pr, category: category, account: account.login))
                        }
                    }
                } catch {
                    record(error, account: account.login, repo: repoConfig.repo)
                    carry(account: account.login, repo: repoConfig.repo)
                }
            }
        }

        let failedCompletely = attempts > 0 && successes == 0
        return Snapshot(
            items: Self.dedupeAndSort(collected),
            fetchedAt: failedCompletely ? (previous?.fetchedAt ?? now()) : now(),
            issues: issues,
            failedCompletely: failedCompletely,
            rateLimitedUntil: rateLimitedUntil,
            fetchedScopes: fetchedScopes,
            repoMergeSettings: mergeSettings
        )
    }
```

(Es el mismo cuerpo de antes: cambian las cuatro llamadas a `carryOver`, que pasan por `carry`, y se guardan los ajustes de cada repo consultado.)

- [ ] **Step 7: Correr los tests.**

Run: `swift run PRBarTests "merge data"`
Expected: 6 `✓`.

Run: `swift run PRBarTests github` y `swift run PRBarTests snapshot`
Expected: todos `✓` (los fixtures viejos no traen los campos nuevos y se leen igual).

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBarCore/GraphQLModels.swift Sources/PRBarCore/GitHubClient.swift Sources/PRBarCore/Snapshot.swift \
        Sources/PRBarTests/MergeDataTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): fetch mergeability and repo merge settings"
```

---

### Task 4: `ActionClassifier`: categoría Ready to Merge

**Files:**
- Modify: `Sources/PRBarCore/Models.swift` (`PRCategory`), `Sources/PRBarCore/ActionClassifier.swift`
- Modify: `Sources/PRBarCore/NotificationPlanner.swift` (`kind(for:)`, para que compile), `Sources/PRBar/Popover/PopoverView.swift` (`actionable`)
- Modify: `Sources/PRBarTests/ModelsTests.swift`
- Test: `Sources/PRBarTests/ReadyToMergeTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/ReadyToMergeTests.swift`:

```swift
import Foundation
import PRBarCore

private func classify(_ pr: PullRequest) -> PRCategory? {
    ActionClassifier.classify(pr, me: "me", watchedUsers: ["juan"])
}

private let clean = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .clean)

/// Mi PR, con el último commit en el minuto 10 (las reviews antes de eso no son feedback nuevo).
private func mine(
    isDraft: Bool = false, ci: CIState = .success, decision: ReviewDecision, reviews: [PRReview] = [],
    comments: [PRComment] = [], merge: PRMergeState = clean
) -> PullRequest {
    makePR(author: "me", isDraft: isDraft, lastCommit: 10, ci: ci, decision: decision, reviews: reviews, comments: comments, merge: merge)
}

enum ReadyToMergeTests {
    static let cases: [TestCase] = [
        TestCase("ready to merge: mi PR aprobado sin feedback nuevo → readyToMerge") {
            try expectEqual(classify(mine(decision: .approved, reviews: [review("ana", .approved, at: 5)])), .readyToMerge)
        },
        TestCase("ready to merge: aprobado pero con feedback nuevo → sigue en myFeedback") {
            let pr = mine(decision: .approved, reviews: [review("ana", .approved, at: 5)], comments: [comment("leo", at: 20)])
            try expectEqual(classify(pr), .myFeedback)
        },
        TestCase("ready to merge: con conflictos → other") {
            let conflicting = PRMergeState(nodeID: "PR_1", mergeable: .conflicting, status: .unknown)
            try expectEqual(classify(mine(decision: .approved, merge: conflicting)), .other)
            let dirty = PRMergeState(nodeID: "PR_1", mergeable: .unknown, status: .dirty)
            try expectEqual(classify(mine(decision: .approved, merge: dirty)), .other)
        },
        TestCase("ready to merge: draft aprobado → other") {
            try expectEqual(classify(mine(isDraft: true, decision: .approved)), .other)
        },
        TestCase("ready to merge: falta la aprobación requerida o hay cambios pedidos viejos → other") {
            try expectEqual(classify(mine(decision: .reviewRequired)), .other)
            try expectEqual(classify(mine(decision: .changesRequested, reviews: [review("ana", .changesRequested, at: 5)])), .other)
        },
        TestCase("ready to merge: mergeabilidad todavía desconocida → entra igual") {
            try expectEqual(classify(mine(decision: .approved, merge: .unknown)), .readyToMerge)
        },
        TestCase("ready to merge: CI fallando, checks pendientes o bloqueado no lo sacan") {
            let unstable = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .unstable)
            try expectEqual(classify(mine(ci: .failure, decision: .approved, merge: unstable)), .readyToMerge)
            let blocked = PRMergeState(nodeID: "PR_1", mergeable: .mergeable, status: .blocked)
            try expectEqual(classify(mine(ci: .pending, decision: .approved, merge: blocked)), .readyToMerge)
        },
        TestCase("ready to merge: repo sin reviews requeridas y aprobación vigente → readyToMerge") {
            try expectEqual(classify(mine(decision: .none, reviews: [review("ana", .approved, at: 5)])), .readyToMerge)
        },
        TestCase("ready to merge: repo sin reviews requeridas y la misma persona pide cambios después → other") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 2), review("ana", .changesRequested, at: 5)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: repo sin reviews requeridas y otra persona pide cambios → other") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 5), review("leo", .changesRequested, at: 6)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: aprobación descartada → other") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 2), review("ana", .dismissed, at: 5)])
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: un comentario después de aprobar no anula la aprobación") {
            let pr = mine(decision: .none, reviews: [review("ana", .approved, at: 2), review("ana", .commented, at: 5)])
            try expectEqual(classify(pr), .readyToMerge)
        },
        TestCase("ready to merge: sin reviews, o solo la mía, no alcanza") {
            try expectEqual(classify(mine(decision: .none)), .other)
            try expectEqual(classify(mine(decision: .none, reviews: [review("me", .approved, at: 5)])), .other)
        },
        TestCase("ready to merge: un PR ajeno aprobado no es Ready to Merge") {
            let pr = makePR(author: "juan", decision: .approved, reviews: [review("me", .approved, at: 5)], merge: clean)
            try expectEqual(classify(pr), .other)
        },
        TestCase("ready to merge: cuenta para el badge y va después de My PRs with Feedback") {
            try expect(PRCategory.readyToMerge.countsForBadge)
            try expectEqual(PRCategory.readyToMerge.title, "Ready to Merge")
            try expect(PRCategory.myFeedback < .readyToMerge && PRCategory.readyToMerge < .other)
            let snapshot = Snapshot(items: [ClassifiedPR(pr: mine(decision: .approved), category: .readyToMerge, account: "me")], fetchedAt: t0)
            try expectEqual(snapshot.badgeCount, 1)
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ ReadyToMergeTests.cases`.

En `Sources/PRBarTests/ModelsTests.swift`, el primer test pasa a esperar el orden nuevo:

```swift
            try expectEqual(PRCategory.allCases.shuffled().sorted(), [.toReview, .updatedSinceMyReview, .myFeedback, .readyToMerge, .other])
```

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "ready to merge"`
Expected: error de compilación `type 'PRCategory' has no member 'readyToMerge'`.

- [ ] **Step 3: `PRCategory`.** En `Sources/PRBarCore/Models.swift`:

```swift
public enum PRCategory: String, Codable, Sendable, CaseIterable, Comparable, Identifiable {
    case toReview, updatedSinceMyReview, myFeedback, readyToMerge, other

    public var id: String { rawValue }
    public var countsForBadge: Bool { self != .other }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .updatedSinceMyReview: "Updated Since My Review"
        case .myFeedback: "My PRs with Feedback"
        case .readyToMerge: "Ready to Merge"
        case .other: "Other"
        }
    }
```

(el resto del enum no cambia).

- [ ] **Step 4: El clasificador.** En `Sources/PRBarCore/ActionClassifier.swift`, dentro de `classify`, la rama de mis PRs pasa a:

```swift
        if author == me {
            // Ready to Merge es lo que queda cuando ya no hay nada que responder (spec F.1).
            if !newFeedback(pr, me: me).isEmpty { return .myFeedback }
            return isReadyToMerge(pr, me: me) ? .readyToMerge : .other
        }
```

Y al final del `enum ActionClassifier` (después de `newFeedback`):

```swift
    /// Mi PR está aprobado, no es draft y no tiene conflictos (spec F.1). El CI no cuenta: se ve en la fila.
    /// Una mergeabilidad todavía desconocida (`UNKNOWN`) no lo saca: el botón dice "Checking…".
    public static func isReadyToMerge(_ pr: PullRequest, me: String) -> Bool {
        guard !pr.isDraft, pr.merge.mergeable != .conflicting, pr.merge.status != .dirty else { return false }
        switch pr.reviewDecision {
        case .approved: return true
        case .none: return hasCurrentApproval(pr, me: me.lowercased())
        case .changesRequested, .reviewRequired: return false
        }
    }

    /// Sin `reviewDecision` (el repo no exige reviews): la última review de cada persona entre aprobar, pedir cambios
    /// y descartada. Hace falta al menos una aprobación vigente y ningún pedido de cambios vigente.
    static func hasCurrentApproval(_ pr: PullRequest, me: String) -> Bool {
        var latest: [String: PRReview] = [:]
        for review in pr.reviews where review.author.lowercased() != me
            && [.approved, .changesRequested, .dismissed].contains(review.state) {
            let key = review.author.lowercased()
            if let current = latest[key], current.submittedAt >= review.submittedAt { continue }
            latest[key] = review
        }
        let states = latest.values.map(\.state)
        return states.contains(.approved) && !states.contains(.changesRequested)
    }
```

- [ ] **Step 5: Que compile el resto.** En `Sources/PRBarCore/NotificationPlanner.swift`, `kind(for:)` agrega un caso (la Task 5 lo cambia):

```swift
        case .readyToMerge: nil
```

En `Sources/PRBar/Popover/PopoverView.swift`, la sección se muestra desde ya (sin botón hasta la Task 12):

```swift
    private let actionable: [PRCategory] = [.toReview, .updatedSinceMyReview, .myFeedback, .readyToMerge]
```

- [ ] **Step 6: Correr los tests.**

Run: `swift run PRBarTests "ready to merge"`
Expected: 15 `✓`.

Run: `swift run PRBarTests classifier`
Expected: un solo `✗`, `classifier: una aprobación no es feedback` (`expected other, got readyToMerge`). Es correcto que cambie: `makePR` deja `reviewDecision = .none` y la aprobación de ana es una aprobación vigente. Se arregla en el Step 7.

- [ ] **Step 7: Ajustar el test viejo que cambia de categoría.** El test `classifier: una aprobación no es feedback` de `ClassifierTests.swift` arma `makePR(author: "me", lastCommit: 0, reviews: [review("ana", .approved, at: 5)])`: con este plan ese PR **es** Ready to Merge (repo sin reviews requeridas y una aprobación vigente). Lo que el test quiere probar es que una aprobación no es feedback; pasa a:

```swift
        TestCase("classifier: una aprobación no es feedback") {
            let pr = makePR(author: "me", lastCommit: 0, reviews: [review("ana", .approved, at: 5)])
            try expect(ActionClassifier.newFeedback(pr, me: "me").isEmpty)
            try expectEqual(classify(pr), .readyToMerge)
        },
```

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`. Si algún otro test de Slack o de snapshot falla porque un PR propio aprobado ahora es `.readyToMerge`, revisar que el test arme el snapshot a mano (`slackSnap` usa `.other` fijo y no clasifica: no debería cambiar).

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBarCore/Models.swift Sources/PRBarCore/ActionClassifier.swift Sources/PRBarCore/NotificationPlanner.swift \
        Sources/PRBar/Popover/PopoverView.swift Sources/PRBarTests/ModelsTests.swift Sources/PRBarTests/ClassifierTests.swift \
        Sources/PRBarTests/ReadyToMergeTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): classify approved PRs without new feedback as ready to merge"
```

---

### Task 5: Notificación `readyToMerge` y deduplicación con "approved"

**Files:**
- Modify: `Sources/PRBarCore/NotificationPlanner.swift`, `Sources/PRBarCore/Config.swift` (`NotificationSettings`)
- Test: `Sources/PRBarTests/ReadyToMergeNotificationTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/ReadyToMergeNotificationTests.swift`:

```swift
import Foundation
import PRBarCore

private func snap(_ items: ClassifiedPR...) -> Snapshot {
    Snapshot(items: items, fetchedAt: t0, fetchedScopes: ["me|o/r"])
}

private func mine(_ category: PRCategory, decision: ReviewDecision, ci: CIState = .success) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: 7, author: "me", ci: ci, decision: decision), category: category, account: "me")
}

enum ReadyToMergeNotificationTests {
    static let cases: [TestCase] = [
        TestCase("ready notif: aprobado y listo en el mismo refresco → solo readyToMerge") {
            let planned = NotificationPlanner.plan(
                previous: snap(mine(.other, decision: .reviewRequired)), current: snap(mine(.readyToMerge, decision: .approved)),
                settings: NotificationSettings())
            try expectEqual(planned.map(\.kind), [.readyToMerge])
            try expectEqual(planned[0].title, "o/r#7 is ready to merge")
            try expectEqual(planned[0].body, "PR 7")
            try expectEqual(planned[0].url?.absoluteString, "https://github.com/o/r/pull/7")
            try expectEqual(planned[0].identifier, "readyToMerge:o/r#7")
        },
        TestCase("ready notif: ya aprobado que pasa de feedback a listo → readyToMerge") {
            let planned = NotificationPlanner.plan(
                previous: snap(mine(.myFeedback, decision: .approved)), current: snap(mine(.readyToMerge, decision: .approved)),
                settings: NotificationSettings())
            try expectEqual(planned.map(\.kind), [.readyToMerge])
        },
        TestCase("ready notif: con readyToMerge apagado sale el aviso de aprobado") {
            var settings = NotificationSettings()
            settings.readyToMerge = false
            let planned = NotificationPlanner.plan(
                previous: snap(mine(.other, decision: .reviewRequired)), current: snap(mine(.readyToMerge, decision: .approved)),
                settings: settings)
            try expectEqual(planned.map(\.kind), [.myPRApprovedOrCIFailed])
            try expectEqual(planned[0].title, "Your PR Was Approved")
        },
        TestCase("ready notif: si sigue listo no repite; un CI que falla igual avisa") {
            let ready = snap(mine(.readyToMerge, decision: .approved))
            try expectEqual(NotificationPlanner.plan(previous: ready, current: ready, settings: NotificationSettings()), [])
            let failing = snap(mine(.readyToMerge, decision: .approved, ci: .failure))
            let planned = NotificationPlanner.plan(previous: ready, current: failing, settings: NotificationSettings())
            try expectEqual(planned.map(\.title), ["CI Failed on Your PR"])
        },
        TestCase("ready notif: config vieja sin la clave → encendida; respeta el interruptor general") {
            let old = try JSONCoding.decoder.decode(NotificationSettings.self, from: Data(#"{"enabled":true}"#.utf8))
            try expect(old.readyToMerge)
            try expect(old.isOn(.readyToMerge))
            var off = NotificationSettings()
            off.enabled = false
            try expect(!off.isOn(.readyToMerge))
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ ReadyToMergeNotificationTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "ready notif"`
Expected: error de compilación `type 'NotificationKind' has no member 'readyToMerge'`.

- [ ] **Step 3: `NotificationSettings.readyToMerge`.** En `Sources/PRBarCore/Config.swift`, `struct NotificationSettings`:
  - después de `public var myPRApprovedOrCIFailed = true`: `public var readyToMerge = true`;
  - `CodingKeys` agrega una línea al final del enum: `case readyToMerge`;
  - al final de `init(from:)`:

```swift
        readyToMerge = (try? c.decodeIfPresent(Bool.self, forKey: .readyToMerge)) ?? true
```

- [ ] **Step 4: `NotificationKind` y el planner.** En `Sources/PRBarCore/NotificationPlanner.swift`:
  - en `NotificationKind`, después de `case updateAvailable` (Plan 8):

```swift
    /// Un PR mío entró a Ready to Merge (spec F.5).
    case readyToMerge
```

  - en `NotificationSettings.isOn`, al final del `switch`: `case .readyToMerge: return readyToMerge`;
  - en `kind(for:)`: `case .readyToMerge: .readyToMerge` (reemplaza el `nil` de la Task 4);
  - en `title(for:)`, al final: `case .readyToMerge: "Ready to Merge"`;
  - en `groupTitle(for:count:)`, al final: `case .readyToMerge: "\(count) of your PRs are ready to merge"`;
  - dentro de `plan(previous:current:settings:)`, el cuerpo del `for item in current.items …` pasa a:

```swift
            let old = before[item.id]
            let pr = item.pr
            let body = "\(pr.repo.name)#\(pr.number) · \(pr.author): \(pr.title)"

            var notifiedReady = false
            if item.category.countsForBadge, old?.category != item.category,
               let kind = kind(for: item.category), settings.isOn(kind) {
                if kind == .readyToMerge {
                    planned.append(PlannedNotification(
                        kind: kind, title: "\(pr.repo.fullName)#\(pr.number) is ready to merge", body: pr.title, url: pr.url,
                        prID: item.id
                    ))
                    notifiedReady = true
                } else {
                    planned.append(PlannedNotification(kind: kind, title: title(for: kind), body: body, url: pr.url, prID: item.id))
                }
            }

            let isMine = pr.author.lowercased() == item.account.lowercased()
            if isMine, let old, settings.isOn(.myPRApprovedOrCIFailed) {
                // Si el PR acaba de quedar listo para mergear, ese aviso ya dice que se aprobó (spec F.5).
                if !notifiedReady && old.pr.reviewDecision != .approved && pr.reviewDecision == .approved {
                    planned.append(PlannedNotification(
                        kind: .myPRApprovedOrCIFailed, title: "Your PR Was Approved", body: body, url: pr.url,
                        prID: item.id, event: "approved"
                    ))
                }
                if old.pr.ciState != .failure && pr.ciState == .failure {
                    planned.append(PlannedNotification(
                        kind: .myPRApprovedOrCIFailed, title: "CI Failed on Your PR", body: body, url: pr.url,
                        prID: item.id, event: "ciFailed"
                    ))
                }
            }
```

- [ ] **Step 5: Correr los tests.**

Run: `swift run PRBarTests "ready notif"`
Expected: 5 `✓`.

Run: `swift run PRBarTests notif`
Expected: todos `✓` (los de antes no cambian).

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBarCore/NotificationPlanner.swift Sources/PRBarCore/Config.swift \
        Sources/PRBarTests/ReadyToMergeNotificationTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): notify when a PR of mine is ready to merge"
```

---

### Task 6: `MergePolicy`: métodos, método por defecto y habilitación

**Files:**
- Create: `Sources/PRBarCore/MergePolicy.swift`
- Test: `Sources/PRBarTests/MergePolicyTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/MergePolicyTests.swift`:

```swift
import Foundation
import PRBarCore

private func pr(status: MergeStateStatus = .clean, mergeable: MergeableState = .mergeable, nodeID: String? = "PR_1",
                base: String = "main") -> PullRequest {
    makePR(author: "me", base: base, decision: .approved, merge: PRMergeState(nodeID: nodeID, mergeable: mergeable, status: status))
}

private func availability(_ pr: PullRequest, _ settings: RepoMergeSettings? = nil) -> MergeAvailability {
    MergePolicy.availability(pr, settings: settings)
}

enum MergePolicyTests {
    static let cases: [TestCase] = [
        TestCase("merge policy: CLEAN y HAS_HOOKS → habilitado sin nota") {
            try expectEqual(availability(pr(status: .clean)), .enabled(note: nil))
            try expectEqual(availability(pr(status: .hasHooks)), .enabled(note: nil))
        },
        TestCase("merge policy: UNSTABLE → habilitado con nota") {
            let result = availability(pr(status: .unstable))
            try expectEqual(result, .enabled(note: "Some checks that aren’t required are failing"))
            try expect(result.isEnabled)
            try expectEqual(result.note, "Some checks that aren’t required are failing")
        },
        TestCase("merge policy: BLOCKED, BEHIND, UNKNOWN y DRAFT → deshabilitado con el motivo") {
            try expectEqual(availability(pr(status: .blocked)), .disabled(reason: "Blocked by branch protection or required checks"))
            try expectEqual(availability(pr(status: .behind, base: "develop")), .disabled(reason: "Branch is behind develop"))
            try expectEqual(availability(pr(status: .unknown)), .disabled(reason: "Checking…"))
            try expectEqual(availability(pr(status: .draft)), .disabled(reason: "Checking…"))
            try expectEqual(availability(pr(nodeID: nil)), .disabled(reason: "Checking…"))
            try expectEqual(availability(pr(status: .blocked)).reason, "Blocked by branch protection or required checks")
        },
        TestCase("merge policy: conflictos → deshabilitado") {
            try expectEqual(availability(pr(status: .dirty)), .disabled(reason: "This branch has conflicts"))
            try expectEqual(availability(pr(status: .unknown, mergeable: .conflicting)), .disabled(reason: "This branch has conflicts"))
        },
        TestCase("merge policy: sin permiso de escritura o sin métodos permitidos → deshabilitado") {
            try expectEqual(availability(pr(), RepoMergeSettings(viewerPermission: "READ")),
                            .disabled(reason: "You don’t have permission to merge in o/r"))
            let none = RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: false)
            try expectEqual(availability(pr(), none), .disabled(reason: "This repo doesn’t allow any merge method"))
            try expectEqual(availability(pr(), RepoMergeSettings(viewerPermission: "WRITE")), .enabled(note: nil))
        },
        TestCase("merge policy: métodos permitidos; sin datos del repo, los tres") {
            try expectEqual(MergePolicy.allowedMethods(nil), [.squash, .merge, .rebase])
            try expectEqual(MergePolicy.allowedMethods(RepoMergeSettings(squashAllowed: false)), [.merge, .rebase])
        },
        TestCase("merge policy: método por defecto (config del repo, default de GitHub, primero permitido)") {
            let settings = RepoMergeSettings(squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .rebase)
            try expectEqual(MergePolicy.defaultMethod(configured: .squash, settings: settings), .squash)
            try expectEqual(MergePolicy.defaultMethod(configured: .merge, settings: settings), .rebase)
            try expectEqual(MergePolicy.defaultMethod(configured: nil, settings: settings), .rebase)
            let mergeDefault = RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .merge)
            try expectEqual(MergePolicy.defaultMethod(configured: nil, settings: mergeDefault), .rebase)
            try expectEqual(MergePolicy.defaultMethod(configured: nil, settings: nil), .squash)
            try expectEqual(MergePolicy.defaultMethod(configured: .rebase, settings: nil), .rebase)
            let none = RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: false)
            try expectEqual(MergePolicy.defaultMethod(configured: .squash, settings: none), nil)
        },
        TestCase("merge policy: options junta la config del repo, el snapshot de la cuenta y el PR") {
            var config = AppConfig()
            config.accounts = [AccountConfig(login: "me", repos: [RepoConfig(owner: "o", name: "r", mergeMethod: .merge)])]
            let item = ClassifiedPR(pr: pr(status: .unstable), category: .readyToMerge, account: "me")
            let snapshot = Snapshot(items: [item], fetchedAt: t0, repoMergeSettings: [
                "me|o/r": RepoMergeSettings(viewerDefault: .squash),
                "otra|o/r": RepoMergeSettings(squashAllowed: false, mergeCommitAllowed: false, rebaseAllowed: false),
            ])
            let options = MergePolicy.options(for: item, snapshot: snapshot, config: config)
            try expectEqual(options, MergeOptions(
                availability: .enabled(note: "Some checks that aren’t required are failing"),
                methods: [.squash, .merge, .rebase], defaultMethod: .merge))
            let noSnapshot = MergePolicy.options(for: item, snapshot: nil, config: AppConfig())
            try expectEqual(noSnapshot.defaultMethod, .squash)
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ MergePolicyTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "merge policy"`
Expected: error de compilación `cannot find 'MergePolicy' in scope`.

- [ ] **Step 3: Crear `Sources/PRBarCore/MergePolicy.swift`.**

```swift
import Foundation

/// Si el botón Merge está habilitado y por qué (spec F.3).
public enum MergeAvailability: Equatable, Sendable {
    /// `note`: aviso que no impide mergear (p. ej. `UNSTABLE`).
    case enabled(note: String?)
    case disabled(reason: String)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    public var note: String? {
        if case .enabled(let note) = self { return note }
        return nil
    }

    public var reason: String? {
        if case .disabled(let reason) = self { return reason }
        return nil
    }
}

/// Lo que necesitan el botón, el menú, el diálogo y la CLI para mergear un PR.
public struct MergeOptions: Equatable, Sendable {
    public let availability: MergeAvailability
    /// Métodos permitidos, en el orden squash, merge, rebase.
    public let methods: [MergeMethod]
    /// `nil` solo si el repo no permite ninguno.
    public let defaultMethod: MergeMethod?

    public init(availability: MergeAvailability, methods: [MergeMethod], defaultMethod: MergeMethod?) {
        self.availability = availability
        self.methods = methods
        self.defaultMethod = defaultMethod
    }
}

/// Reglas puras del botón Merge (spec F.3). No hace red ni disco.
public enum MergePolicy {
    public static let checking = "Checking…"

    /// Sin datos del repo (refresco viejo o respuesta sin los campos) se ofrecen los tres: si el repo no permite el
    /// elegido, GitHub lo rechaza y la fila lo muestra.
    public static func allowedMethods(_ settings: RepoMergeSettings?) -> [MergeMethod] {
        settings?.allowedMethods ?? MergeMethod.allCases
    }

    /// El de `RepoConfig.mergeMethod` si está permitido; si no, `viewerDefaultMergeMethod`; si no, el primero
    /// permitido en el orden squash, merge, rebase.
    public static func defaultMethod(configured: MergeMethod?, settings: RepoMergeSettings?) -> MergeMethod? {
        let allowed = allowedMethods(settings)
        if let configured, allowed.contains(configured) { return configured }
        if let viewerDefault = settings?.viewerDefault, allowed.contains(viewerDefault) { return viewerDefault }
        return allowed.first
    }

    public static func availability(_ pr: PullRequest, settings: RepoMergeSettings?) -> MergeAvailability {
        if allowedMethods(settings).isEmpty { return .disabled(reason: "This repo doesn’t allow any merge method") }
        if settings?.viewerCanMerge == false {
            return .disabled(reason: "You don’t have permission to merge in \(pr.repo.fullName)")
        }
        guard pr.merge.nodeID != nil else { return .disabled(reason: checking) }
        if pr.merge.mergeable == .conflicting { return .disabled(reason: "This branch has conflicts") }
        switch pr.merge.status {
        case .clean, .hasHooks: return .enabled(note: nil)
        case .unstable: return .enabled(note: "Some checks that aren’t required are failing")
        case .blocked: return .disabled(reason: "Blocked by branch protection or required checks")
        case .behind: return .disabled(reason: "Branch is behind \(pr.baseRef)")
        case .dirty: return .disabled(reason: "This branch has conflicts")
        case .draft, .unknown: return .disabled(reason: checking)
        }
    }

    /// Junta los ajustes del repo vistos por la cuenta del PR, el método fijado en la config y el estado del PR.
    public static func options(for item: ClassifiedPR, snapshot: Snapshot?, config: AppConfig) -> MergeOptions {
        let settings = snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
        let configured = config.accounts.first { $0.login == item.account }?
            .repos.first { $0.repo == item.pr.repo }?.mergeMethod
        return MergeOptions(
            availability: availability(item.pr, settings: settings),
            methods: allowedMethods(settings),
            defaultMethod: defaultMethod(configured: configured, settings: settings)
        )
    }
}
```

- [ ] **Step 4: Correr los tests.**

Run: `swift run PRBarTests "merge policy"`
Expected: 8 `✓`.

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/MergePolicy.swift Sources/PRBarTests/MergePolicyTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): decide merge methods and when merging is allowed"
```

---
### Task 7: `mergePullRequest` y `MergeError`

**Files:**
- Create: `Sources/PRBarCore/MergeError.swift`
- Modify: `Sources/PRBarCore/GraphQLModels.swift` (`Mutations`, `MergeMutationData`), `Sources/PRBarCore/GitHubClient.swift` (`GitHubAPI`, `GitHubClient`)
- Modify: `Sources/PRBarTests/Fakes.swift` (`FakeAPI`, `FakeFeedbackAPI`), `Sources/PRBar/Snapshots/SnapshotFakes.swift` (`SnapshotGitHubAPI`)
- Test: `Sources/PRBarTests/MergeMutationTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/MergeMutationTests.swift`:

```swift
import Foundation
import PRBarCore

private let mergedBody = #"{"data":{"mergePullRequest":{"pullRequest":{"merged":true,"mergedAt":"2026-11-19T12:00:00Z"}}}}"#

private func errorBody(_ message: String, type: String) -> String {
    #"{"data":{"mergePullRequest":null},"errors":[{"type":"\#(type)","message":"\#(message)"}]}"#
}

private func merge(_ transport: FakeTransport) async throws -> Date? {
    try await GitHubClient(transport: transport, now: { t0 })
        .mergePullRequest(id: "PR_kwDOA", method: .squash, expectedHeadOid: "cafe42", token: "tok")
}

private func mergeError(_ body: String) async throws -> Error {
    try await expectThrows { _ = try await merge(FakeTransport([(200, [:], body)])) }
}

enum MergeMutationTests {
    static let cases: [TestCase] = [
        TestCase("merge mutation: manda la mutación con las variables exactas y devuelve mergedAt") {
            let transport = FakeTransport([(200, [:], mergedBody)])
            let mergedAt = try await merge(transport)
            try expectEqual(mergedAt, ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z"))
            try expectEqual(transport.requests.count, 1)
            try expectEqual(transport.requests[0].url?.absoluteString, "https://api.github.com/graphql")
            try expectEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "bearer tok")
            let body = try JSONSerialization.jsonObject(with: transport.requests[0].httpBody ?? Data()) as? [String: Any]
            let query = body?["query"] as? String ?? ""
            try expect(query.hasPrefix("mutation("))
            try expect(query.contains("mergePullRequest(input: $input)"))
            let input = (body?["variables"] as? [String: Any])?["input"] as? [String: String]
            try expectEqual(input, ["pullRequestId": "PR_kwDOA", "mergeMethod": "SQUASH", "expectedHeadOid": "cafe42"])
        },
        TestCase("merge mutation: head cambiado → headChanged") {
            let error = try await mergeError(errorBody("Head branch was modified. Review and try the merge again.", type: "UNPROCESSABLE"))
            try expectEqual(error as? MergeError, .headChanged)
            try expectEqual(error.localizedDescription, "The PR changed since you looked at it — refresh and try again.")
        },
        TestCase("merge mutation: sin permiso → forbidden con el texto de GitHub") {
            let message = "Viewer does not have permission to merge this pull request"
            let error = try await mergeError(errorBody(message, type: "FORBIDDEN"))
            try expectEqual(error as? MergeError, .forbidden(message))
        },
        TestCase("merge mutation: no se puede mergear → notMergeable") {
            let error = try await mergeError(errorBody("Pull Request is not mergeable", type: "UNPROCESSABLE"))
            try expectEqual(error as? MergeError, .notMergeable("Pull Request is not mergeable"))
            let notMerged = try await mergeError(#"{"data":{"mergePullRequest":{"pullRequest":{"merged":false,"mergedAt":null}}}}"#)
            try expectEqual(notMerged as? MergeError, .notMergeable("GitHub didn’t merge the PR"))
        },
        TestCase("merge mutation: otro error de GraphQL → other") {
            let error = try await mergeError(errorBody("Something odd", type: "INTERNAL"))
            try expectEqual(error as? MergeError, .other("Something odd"))
        },
        TestCase("merge mutation: rate limit y token inválido siguen siendo PRBarError") {
            let limited = FakeTransport([(200, ["x-ratelimit-reset": "1800000900"], errorBody("API rate limit exceeded", type: "RATE_LIMITED"))])
            let rateError = try await expectThrows { _ = try await merge(limited) }
            try expectEqual(rateError as? PRBarError, .rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_900)))
            let unauthorized = try await expectThrows { _ = try await merge(FakeTransport([(401, [:], #"{"message":"Bad credentials"}"#)])) }
            try expectEqual(unauthorized as? PRBarError, .unauthorized)
        },
        TestCase("merge mutation: MergeError(_:) envuelve cualquier error") {
            try expectEqual(MergeError(PRBarError.unauthorized), .github(.unauthorized))
            try expectEqual(MergeError(MergeError.headChanged), .headChanged)
            try expectEqual(MergeError(URLError(.notConnectedToInternet)), .github(.network(URLError(.notConnectedToInternet).localizedDescription)))
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ MergeMutationTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "merge mutation"`
Expected: error de compilación (`value of type 'GitHubClient' has no member 'mergePullRequest'`, `cannot find 'MergeError' in scope`).

- [ ] **Step 3: Crear `Sources/PRBarCore/MergeError.swift`.**

```swift
import Foundation

/// Por qué no se pudo mergear (spec F.3). Los textos son los que muestra la fila (y la CLI).
public enum MergeError: Error, Equatable, Sendable, LocalizedError {
    /// Alguien pusheó después de lo que se mostró: `expectedHeadOid` no coincide.
    case headChanged
    case forbidden(String)
    case notMergeable(String)
    case alreadyInProgress
    case alreadyMerged
    /// El PR no tiene node ID (un `state.json` viejo): hay que refrescar.
    case missingMergeData
    case github(PRBarError)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .headChanged: "The PR changed since you looked at it — refresh and try again."
        case .forbidden(let message): "GitHub didn’t let you merge this PR: \(message)"
        case .notMergeable(let message): "GitHub can’t merge this PR: \(message)"
        case .alreadyInProgress: "This PR is already being merged."
        case .alreadyMerged: "This PR was already merged."
        case .missingMergeData: "PRBar doesn’t have this PR’s merge data yet — refresh and try again."
        case .github(let error): error.localizedDescription
        case .other(let message): "GitHub error: \(message)"
        }
    }

    /// Cualquier error de un merge, como `MergeError`.
    public init(_ error: Error) {
        switch error {
        case let error as MergeError: self = error
        case let error as PRBarError: self = .github(error)
        case let error as URLError: self = .github(.network(error.localizedDescription))
        default: self = .other(error.localizedDescription)
        }
    }

    /// Los errores de GraphQL de `mergePullRequest`. GitHub no documenta los textos: se reconocen por frases conocidas
    /// y por `type` (`FORBIDDEN`, `UNPROCESSABLE`). El QA confirma el texto real del head cambiado.
    static func classify(messages: [String], types: [String?]) -> MergeError {
        let message = messages.joined(separator: "; ")
        let lower = message.lowercased()
        if ["head branch was modified", "expected head", "expectedheadoid", "head sha"].contains(where: { lower.contains($0) }) {
            return .headChanged
        }
        if types.contains("FORBIDDEN") || lower.contains("permission") || lower.contains("not authorized") {
            return .forbidden(message)
        }
        if types.contains("UNPROCESSABLE") || lower.contains("not mergeable") || lower.contains("not allowed") {
            return .notMergeable(message)
        }
        return .other(message)
    }
}
```

- [ ] **Step 4: La mutación.** Al final de `Sources/PRBarCore/GraphQLModels.swift`:

```swift
enum Mutations {
    /// Mergea solo si el head sigue siendo `expectedHeadOid` (spec F.3).
    static let mergePullRequest = """
    mutation($input: MergePullRequestInput!) {
      mergePullRequest(input: $input) {
        pullRequest { merged mergedAt }
      }
    }
    """
}

struct MergeMutationData: Decodable {
    struct Payload: Decodable { let pullRequest: MergedPR? }
    struct MergedPR: Decodable {
        let merged: Bool
        let mergedAt: Date?
    }
    let mergePullRequest: Payload?
}
```

- [ ] **Step 5: `GitHubAPI` y `GitHubClient`.** En `Sources/PRBarCore/GitHubClient.swift`:
  - al final del protocolo `GitHubAPI`:

```swift
    /// Mergea el PR (`mergePullRequest`) solo si su head sigue siendo `expectedHeadOid`. Devuelve `mergedAt`.
    /// Errores: `MergeError` (head cambiado, sin permiso, no mergeable) o `PRBarError` (red, token, rate limit).
    func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date?
```

  - en `GitHubClient`, después de `addIssueComment(…)`:

```swift
    public func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date? {
        let input: [String: Any] = ["pullRequestId": id, "mergeMethod": method.graphQLValue, "expectedHeadOid": expectedHeadOid]
        let (envelope, response): (GraphQLEnvelope<MergeMutationData>, HTTPURLResponse) = try await graphQLEnvelope(
            Mutations.mergePullRequest, jsonVariables: ["input": input], token: token)
        if let errors = envelope.errors, !errors.isEmpty {
            try throwIfRateLimited(errors, response: response)
            throw MergeError.classify(messages: errors.map(\.message), types: errors.map(\.type))
        }
        guard let pr = envelope.data?.mergePullRequest?.pullRequest else {
            throw MergeError.other("GitHub didn’t return the merged PR")
        }
        guard pr.merged else { throw MergeError.notMergeable("GitHub didn’t merge the PR") }
        return pr.mergedAt
    }
```

  - en `// MARK: - HTTP`, reemplazar `private func graphQL<T: Decodable>(_ query: String, jsonVariables: [String: Any], token: String)` completo por estas tres funciones (la de `variables: [String: String?]` no cambia):

```swift
    private func graphQL<T: Decodable>(_ query: String, jsonVariables: [String: Any], token: String) async throws -> T {
        let (envelope, response): (GraphQLEnvelope<T>, HTTPURLResponse) = try await graphQLEnvelope(
            query, jsonVariables: jsonVariables, token: token)
        if let errors = envelope.errors, !errors.isEmpty {
            try throwIfRateLimited(errors, response: response)
            throw PRBarError.graphQL(errors.map(\.message).joined(separator: "; "))
        }
        guard let payload = envelope.data else { throw PRBarError.invalidResponse("GraphQL without data") }
        return payload
    }

    /// El sobre de GraphQL tal cual (datos y errores), para quien necesita mirar los errores (el merge).
    private func graphQLEnvelope<T: Decodable>(
        _ query: String, jsonVariables: [String: Any], token: String
    ) async throws -> (GraphQLEnvelope<T>, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": jsonVariables])
        let (data, response) = try await perform(request)
        do {
            return (try JSONCoding.decoder.decode(GraphQLEnvelope<T>.self, from: data), response)
        } catch {
            throw PRBarError.invalidResponse("GraphQL: \(error)")
        }
    }

    /// GitHub puede responder 200 con el rate limit de GraphQL como error.
    private func throwIfRateLimited(_ errors: [GraphQLErrorItem], response: HTTPURLResponse) throws {
        guard errors.contains(where: { $0.type == "RATE_LIMITED" }) else { return }
        let reset = Self.header("x-ratelimit-reset", in: response).map { Date(timeIntervalSince1970: $0) }
        throw PRBarError.rateLimited(resetAt: reset ?? now().addingTimeInterval(Self.defaultRateLimitWait))
    }
```

- [ ] **Step 6: Los fakes.** En `Sources/PRBarTests/Fakes.swift`, dentro de `struct FakeAPI`, al final:

```swift
    /// Lo que devuelve (o lanza) `mergePullRequest`.
    var mergeResult: Result<Date?, Error> = .success(nil)
    /// Llamadas a `mergePullRequest`, en orden.
    let mergeCalls = Box<[(id: String, method: MergeMethod, expectedHeadOid: String, token: String)]>([])
    /// Se llama dentro de `mergePullRequest`, antes de devolver (para probar dos merges a la vez).
    var onMerge: (@Sendable () async -> Void)?

    func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date? {
        mergeCalls.value.append((id, method, expectedHeadOid, token))
        if let onMerge { await onMerge() }
        return try mergeResult.get()
    }
```

En `final class FakeFeedbackAPI`, junto a los otros métodos que no usa:

```swift
    func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date? {
        throw PRBarError.http(status: 404, message: "no")
    }
```

En `Sources/PRBar/Snapshots/SnapshotFakes.swift`, dentro de `SnapshotGitHubAPI`, después de `addIssueComment`:

```swift
    func mergePullRequest(id: String, method: MergeMethod, expectedHeadOid: String, token: String) async throws -> Date? {
        throw SnapshotFakes.refused
    }
```

Buscar otros tipos que adopten el protocolo y agregarles el mismo método que lanza:

Run: `grep -rn ": GitHubAPI" Sources`
Expected: solo `FakeAPI`, `FakeFeedbackAPI`, `SnapshotGitHubAPI` y `GitHubClient` (si aparece otro, agregarle el método que lanza `PRBarError.http(status: 404, message: "no")`).

- [ ] **Step 7: Correr los tests.**

Run: `swift run PRBarTests "merge mutation"`
Expected: 7 `✓`.

Run: `swift run PRBarTests github`
Expected: todos `✓` (`graphQL` se comporta igual: rate limit, errores, sin datos).

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBarCore/MergeError.swift Sources/PRBarCore/GraphQLModels.swift Sources/PRBarCore/GitHubClient.swift \
        Sources/PRBarTests/Fakes.swift Sources/PRBar/Snapshots/SnapshotFakes.swift \
        Sources/PRBarTests/MergeMutationTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): merge pull requests through GraphQL with the expected head"
```

---

### Task 8: `MergeQueue`: la fase de cada fila

**Files:**
- Create: `Sources/PRBarCore/MergeQueue.swift`
- Test: `Sources/PRBarTests/MergeQueueTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/MergeQueueTests.swift`:

```swift
import Foundation
import PRBarCore

@MainActor
private func queue(_ api: FakeAPI, tokens: FakeTokens = FakeTokens(), merged: Box<[MergeCompletion]> = Box([])) -> MergeQueue {
    MergeQueue(api: api, tokens: tokens, now: { t0 }, onMerged: { merged.value.append($0) })
}

private func ready(nodeID: String? = "PR_7") -> ClassifiedPR {
    let pr = makePR(number: 7, author: "me", head: "cafe7", decision: .approved,
                    merge: PRMergeState(nodeID: nodeID, mergeable: .mergeable, status: .clean))
    return ClassifiedPR(pr: pr, category: .readyToMerge, account: "me")
}

enum MergeQueueTests {
    static let cases: [TestCase] = [
        TestCase("merge queue: mergea con el head que se mostró, con el token de la cuenta, y avisa") {
            var api = FakeAPI()
            api.mergeResult = .success(at(5))
            let merged = Box<[MergeCompletion]>([])
            let q = await queue(api, merged: merged)
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(try result.get().mergedAt, at(5))
            let calls = api.mergeCalls.value
            try expectEqual(calls.count, 1)
            try expectEqual(calls[0].id, "PR_7")
            try expectEqual(calls[0].method, .squash)
            try expectEqual(calls[0].expectedHeadOid, "cafe7")
            try expectEqual(calls[0].token, "tok-me")
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .merged(.squash))
            try expectEqual(merged.value.map(\.item.id), ["o/r#7"])
            try expectEqual(merged.value.map(\.method), [.squash])
        },
        TestCase("merge queue: sin mergedAt usa la hora actual") {
            let q = await queue(FakeAPI())
            let result = await q.merge(ready(), method: .rebase)
            try expectEqual(try result.get().mergedAt, t0)
        },
        TestCase("merge queue: un error queda en la fila con el texto y no avisa") {
            var api = FakeAPI()
            api.mergeResult = .failure(MergeError.headChanged)
            let merged = Box<[MergeCompletion]>([])
            let q = await queue(api, merged: merged)
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(result, .failure(.headChanged))
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .failed(method: .squash, message: MergeError.headChanged.localizedDescription))
            try expectEqual(merged.value.count, 0)
        },
        TestCase("merge queue: sin token no llama a GitHub") {
            let api = FakeAPI()
            let q = await queue(api, tokens: FakeTokens(failing: ["me"]))
            let result = await q.merge(ready(), method: .squash)
            try expectEqual(result, .failure(.github(.unauthorized)))
            try expectEqual(api.mergeCalls.value.count, 0)
        },
        TestCase("merge queue: sin node id no llama a GitHub") {
            let api = FakeAPI()
            let q = await queue(api)
            let result = await q.merge(ready(nodeID: nil), method: .squash)
            try expectEqual(result, .failure(.missingMergeData))
            try expectEqual(api.mergeCalls.value.count, 0)
            let phases = await q.phases
            try expectEqual(phases["o/r#7"], .failed(method: .squash, message: MergeError.missingMergeData.localizedDescription))
        },
        TestCase("merge queue: un segundo merge mientras corre el primero se rechaza; uno ya mergeado también") {
            let holder = Box<MergeQueue?>(nil)
            let second = Box<Result<MergeCompletion, MergeError>?>(nil)
            var api = FakeAPI()
            api.onMerge = {
                let result = await holder.value?.merge(ready(), method: .merge)
                second.value = result
            }
            let q = await queue(api)
            holder.value = q
            _ = await q.merge(ready(), method: .squash)
            try expectEqual(second.value, .failure(.alreadyInProgress))
            let again = await q.merge(ready(), method: .squash)
            try expectEqual(again, .failure(.alreadyMerged))
            try expectEqual(api.mergeCalls.value.count, 1)
        },
        TestCase("merge queue: dismiss borra un error; prune descarta los PRs que ya no están") {
            var api = FakeAPI()
            api.mergeResult = .failure(MergeError.forbidden("no"))
            let q = await queue(api)
            _ = await q.merge(ready(), method: .squash)
            await q.dismiss(prID: "o/r#7")
            let afterDismiss = await q.phases
            try expectEqual(afterDismiss, [:])
            _ = await q.merge(ready(), method: .squash)
            await q.prune(keeping: ["o/r#7"])
            let kept = await q.phases
            try expectEqual(kept.count, 1)
            await q.prune(keeping: [])
            let pruned = await q.phases
            try expectEqual(pruned, [:])
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ MergeQueueTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "merge queue"`
Expected: error de compilación `cannot find 'MergeQueue' in scope`.

- [ ] **Step 3: Crear `Sources/PRBarCore/MergeQueue.swift`.**

```swift
import Foundation

/// Un merge que salió bien.
public struct MergeCompletion: Equatable, Sendable {
    public let item: ClassifiedPR
    public let method: MergeMethod
    public let mergedAt: Date

    public init(item: ClassifiedPR, method: MergeMethod, mergedAt: Date) {
        self.item = item
        self.method = method
        self.mergedAt = mergedAt
    }
}

/// Estado del botón Merge de una fila (spec F.3).
public enum MergePhase: Equatable, Sendable {
    case merging(MergeMethod)
    /// Hecho: la fila muestra "Merged" hasta que el refresco la saca.
    case merged(MergeMethod)
    /// El texto del error y el método que se intentó (para Retry).
    case failed(method: MergeMethod, message: String)

    public var isActive: Bool {
        if case .merging = self { return true }
        return false
    }
}

/// Merges en curso y su resultado, por PR. Usa el token de la cuenta del PR: nunca pasa por Claude.
/// Lo usan la fila del popover, el diálogo de confirmación y (Plan 7) la CLI, por `AppModel`.
@MainActor
public final class MergeQueue: ObservableObject {
    @Published public private(set) var phases: [String: MergePhase] = [:]

    private let api: GitHubAPI
    private let tokens: TokenProviding
    private let now: () -> Date
    private let onMerged: @MainActor (MergeCompletion) -> Void

    public init(
        api: GitHubAPI, tokens: TokenProviding, now: @escaping () -> Date = { Date() },
        onMerged: @escaping @MainActor (MergeCompletion) -> Void = { _ in }
    ) {
        self.api = api
        self.tokens = tokens
        self.now = now
        self.onMerged = onMerged
    }

    /// Mergea `item` con `method`, con el `headOid` que tiene `item` (el que se mostró): si alguien pusheó después,
    /// GitHub lo rechaza. Un PR que ya se está mergeando o que ya se mergeó no se vuelve a mandar.
    @discardableResult
    public func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        let prID = item.id
        switch phases[prID] {
        case .merging?: return .failure(.alreadyInProgress)
        case .merged?: return .failure(.alreadyMerged)
        default: break
        }
        guard let nodeID = item.pr.merge.nodeID else { return fail(prID, method: method, .missingMergeData) }
        phases[prID] = .merging(method)
        do {
            let token = try await tokens.token(for: item.account)
            let mergedAt = try await api.mergePullRequest(
                id: nodeID, method: method, expectedHeadOid: item.pr.headOid, token: token)
            let completion = MergeCompletion(item: item, method: method, mergedAt: mergedAt ?? now())
            phases[prID] = .merged(method)
            AppLog.write("Merged \(prID) with \(method.rawValue) at \(item.pr.headOid)")
            onMerged(completion)
            return .success(completion)
        } catch {
            return fail(prID, method: method, MergeError(error))
        }
    }

    /// Borra el error de una fila (Dismiss). Un merge en curso no se toca.
    public func dismiss(prID: String) {
        guard phases[prID]?.isActive != true else { return }
        phases[prID] = nil
    }

    /// Descarta las fases de los PRs que ya no están en la lista (después del refresco que saca la fila).
    public func prune(keeping ids: Set<String>) {
        phases = phases.filter { ids.contains($0.key) || $0.value.isActive }
    }

    private func fail(_ prID: String, method: MergeMethod, _ error: MergeError) -> Result<MergeCompletion, MergeError> {
        phases[prID] = .failed(method: method, message: error.localizedDescription)
        AppLog.write("Couldn't merge \(prID): \(error.localizedDescription)")
        return .failure(error)
    }
}
```

- [ ] **Step 4: Correr los tests.**

Run: `swift run PRBarTests "merge queue"`
Expected: 7 `✓`.

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/MergeQueue.swift Sources/PRBarTests/MergeQueueTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): track merges per PR"
```

---

### Task 9: Slack: interruptor "Merged", plantilla y `{method}`

**Files:**
- Modify: `Sources/PRBarCore/Config.swift` (`SlackSettings`, `SlackToggle`)
- Modify: `Sources/PRBarCore/SlackTemplate.swift`, `Sources/PRBarCore/SlackTemplatePreview.swift`
- Test: `Sources/PRBarTests/SlackMergedTemplateTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/SlackMergedTemplateTests.swift`:

```swift
import Foundation
import PRBarCore

enum SlackMergedTemplateTests {
    static let cases: [TestCase] = [
        TestCase("slack merged: por defecto encendido con «Merged :white_check_mark:»") {
            let settings = SlackSettings()
            try expect(settings.postMerged)
            try expectEqual(settings.mergedTemplate, "Merged :white_check_mark:")
            try expectEqual(SlackSettings.defaultMergedTemplate, "Merged :white_check_mark:")
            var blank = settings
            blank.mergedTemplate = "  "
            try expectEqual(blank.effectiveMergedTemplate, "Merged :white_check_mark:")
            try expect(settings.isDefault(\.mergedTemplate))
        },
        TestCase("slack merged: una config vieja sin las claves nuevas") {
            let settings = try JSONCoding.decoder.decode(SlackSettings.self, from: Data(#"{"enabled":true,"postUpdated":false}"#.utf8))
            try expect(settings.postMerged)
            try expectEqual(settings.mergedTemplate, SlackSettings.defaultMergedTemplate)
            try expect(!settings.postUpdated)
        },
        TestCase("slack merged: {method} junto con las demás variables") {
            let text = SlackTemplate.render("Merged {repo}#{number} ({method}) {title}", pr: makePR(number: 42), method: "squash")
            try expectEqual(text, "Merged r#42 (squash) PR 42")
            try expectEqual(SlackTemplate.render("x {method}", pr: makePR()), "x {method}")
        },
        TestCase("slack merged: {method} solo existe en la plantilla de Merged") {
            try expect(SlackTemplateKind.merged.variables.contains(.method))
            try expect(!SlackTemplateKind.update.variables.contains(.method))
            try expectEqual(SlackTemplateVariable.method.token, "{method}")
            try expectEqual(SlackTemplatePreview.text("x {method}", kind: .merged), "x squash")
            try expectEqual(SlackTemplatePreview.text("x {method}", kind: .update), "x {method}")
            try expectEqual(SlackTemplatePreview.text("", kind: .merged), "Merged :white_check_mark:")
        },
        TestCase("slack merged: el interruptor no toca las reacciones a reviews") {
            var config = AppConfig()
            config.setSlackToggle(.postMerged, false, now: t0)
            try expect(!config.slack.postMerged)
            try expectEqual(config.slack.reviewReactionsEnabledAt, nil)
            try expectEqual(SlackToggle.postMerged.keyPath, \SlackSettings.postMerged)
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ SlackMergedTemplateTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "slack merged"`
Expected: error de compilación `value of type 'SlackSettings' has no member 'postMerged'`.

- [ ] **Step 3: `SlackSettings` y `SlackToggle`.** En `Sources/PRBarCore/Config.swift`:
  - en `SlackSettings`, después de `public static let defaultRoundTemplate = "commented x{n}"`:

```swift
    public static let defaultMergedTemplate = "Merged :white_check_mark:"
```

  - después de `public var updateTemplate = Self.defaultUpdateTemplate`:

```swift
    /// Respuesta en el hilo del anuncio cuando mergeo desde PRBar (spec F.4).
    public var mergedTemplate = Self.defaultMergedTemplate
```

  - después de `public var postUpdated = true`:

```swift
    public var postMerged = true
```

  - en `CodingKeys`, una línea nueva al final del enum: `case postMerged, mergedTemplate`;
  - en `init(from:)`, después de la línea de `postUpdated`:

```swift
        postMerged = (try? c.decodeIfPresent(Bool.self, forKey: .postMerged)) ?? true
        mergedTemplate = (try? c.decodeIfPresent(String.self, forKey: .mergedTemplate)) ?? Self.defaultMergedTemplate
```

  - después de `public var effectiveRoundTemplate: String { … }`:

```swift
    public var effectiveMergedTemplate: String { Self.nonEmpty(mergedTemplate) ?? Self.defaultMergedTemplate }
```

  - `SlackToggle`: agregar una línea `case postMerged` después de `case announceNewPRs, postUpdated, …, reactOnApprove`; en `keyPath`, `case .postMerged: \.postMerged`; en `isReviewReaction`, la primera rama pasa a `case .announceNewPRs, .postUpdated, .postMerged: false`.

- [ ] **Step 4: `{method}` en `Sources/PRBarCore/SlackTemplate.swift`.** El comentario del enum suma "y, en «Merged», {method}". La firma y el diccionario pasan a:

```swift
    public static func render(_ template: String, pr: PullRequest, n: Int? = nil, method: String? = nil) -> String {
        var values: [String: String] = [
            "link": pr.url.absoluteString,
            "title": escape(pr.title),
            "number": "\(pr.number)",
            "repo": escape(pr.repo.name),
            "author": escape(pr.author),
        ]
        if let n { values["n"] = "\(n)" }
        if let method { values["method"] = escape(method) }
```

(el resto de la función no cambia).

- [ ] **Step 5: La plantilla en `Sources/PRBarCore/SlackTemplatePreview.swift`.**
  - en `SlackTemplateVariable`, después de `round`:

```swift
    public static let method = SlackTemplateVariable(name: "method", summary: "Merge method (squash, merge or rebase)")
```

  - reemplazar `SlackTemplateKind` por:

```swift
/// Las plantillas editables de la pestaña Slack.
public enum SlackTemplateKind: CaseIterable, Sendable {
    case newPR, update, round, merged

    public var keyPath: WritableKeyPath<SlackSettings, String> {
        switch self {
        case .newPR: \.newPRTemplate
        case .update: \.updateTemplate
        case .round: \.roundTemplate
        case .merged: \.mergedTemplate
        }
    }

    public var defaultTemplate: String {
        switch self {
        case .newPR: SlackSettings.defaultNewPRTemplate
        case .update: SlackSettings.defaultUpdateTemplate
        case .round: SlackSettings.defaultRoundTemplate
        case .merged: SlackSettings.defaultMergedTemplate
        }
    }

    /// Variables disponibles; `{n}` solo en el mensaje de ronda y `{method}` solo en "Merged".
    public var variables: [SlackTemplateVariable] {
        let common: [SlackTemplateVariable] = [.link, .title, .number, .repo, .author]
        switch self {
        case .round: return common + [.round]
        case .merged: return common + [.method]
        case .newPR, .update: return common
        }
    }

    /// Ronda con la que se previsualiza el mensaje de ronda (la segunda: «commented x2»).
    public var sampleRound: Int? { self == .round ? 2 : nil }

    /// Método con el que se previsualiza "Merged".
    public var sampleMethod: String? { self == .merged ? MergeMethod.squash.rawValue : nil }

    public func isDefault(_ template: String) -> Bool { template == defaultTemplate }

    /// Lo que se manda de verdad: una plantilla vacía (o solo espacios) cae en la de por defecto.
    public func effective(_ template: String) -> String {
        SlackSettings.nonEmpty(template) ?? defaultTemplate
    }
}
```

  - en `SlackTemplatePreview.text(_:kind:author:)`, el `render` pasa a:

```swift
        let rendered = SlackTemplate.render(
            kind.effective(template), pr: sample(author: author), n: kind.sampleRound, method: kind.sampleMethod
        )
```

- [ ] **Step 6: Correr los tests.**

Run: `swift run PRBarTests "slack merged"` y `swift run PRBarTests "slack preview"`
Expected: 5 `✓` nuevos; los de vista previa siguen `✓` (recorren `SlackTemplateKind.allCases`, que ahora incluye `merged`).

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 7: Commit.**

```bash
git add Sources/PRBarCore/Config.swift Sources/PRBarCore/SlackTemplate.swift Sources/PRBarCore/SlackTemplatePreview.swift \
        Sources/PRBarTests/SlackMergedTemplateTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): add the Slack merged reply setting and template"
```

---

### Task 10: Slack: responder "Merged" en el hilo

**Files:**
- Modify: `Sources/PRBarCore/SlackState.swift` (`MergedReply`, `SlackState.mergedReplies`, `uncertainKey`)
- Modify: `Sources/PRBarCore/SlackPlanner.swift` (`SlackAction.merged`, `plan`)
- Modify: `Sources/PRBarCore/SlackAnnouncer.swift` (`run`, `issueDetail`, `prMerged`)
- Modify: `Sources/PRBarTests/SlackPlannerTests.swift` (helper `text(_:)`)
- Test: `Sources/PRBarTests/SlackMergedReplyTests.swift`, `Sources/PRBarTests/main.swift`

- [ ] **Step 1: Escribir los tests.** Crear `Sources/PRBarTests/SlackMergedReplyTests.swift`:

```swift
import Foundation
import PRBarCore

private let repo = RepoRef(owner: "o", name: "r")

private func newStore() throws -> SlackStateStore {
    try SlackStateStore(url: temporaryDirectory().appendingPathComponent("slack-state.json"))
}

/// Mi PR #1 anunciado por PRBar en C1 (`ts` 111.1).
private func announcedStore() throws -> SlackStateStore {
    let store = try newStore()
    var state = SlackState(baselineAt: at(-100))
    state.announcements["o/r#1"] = SlackAnnouncement(channelID: "C1", ts: "111.1", announcedAt: at(-80))
    try store.save(state)
    return store
}

@MainActor
private func announcer(_ api: FakeSlackAPI, clock: Box<Date>, store: SlackStateStore) -> SlackAnnouncer {
    SlackAnnouncer(api: api, provider: .userToken, secrets: FakeSecrets(["user-token": "xoxp-1"]), stateStore: store,
                   now: { clock.value })
}

enum SlackMergedReplyTests {
    static let cases: [TestCase] = [
        TestCase("slack merged reply: PR anunciado → «Merged» en el hilo una sola vez") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(api.posts[0].channel, "C1")
            try expectEqual(api.posts[0].threadTS, "111.1")
            try expectEqual(api.posts[0].text, "Merged :white_check_mark:")
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, at(0))
            try expectEqual(store.load().uncertain, [:])
            let issues = await slack.issues
            try expectEqual(issues, [])
        },
        TestCase("slack merged reply: un PR que PRBar no anunció no responde nada") {
            let api = FakeSlackAPI()
            let store = try newStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            try expectEqual(api.posts.count, 0)
            try expectEqual(store.load().mergedReplies, [:])
        },
        TestCase("slack merged reply: con el interruptor o Slack apagados no responde") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            var off = slackConfig()
            off.slack.postMerged = false
            await slack.prMerged(myPR(), method: .squash, config: off)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig(enabled: false))
            try expectEqual(api.posts.count, 0)
            try expectEqual(store.load().mergedReplies, [:])
        },
        TestCase("slack merged reply: plantilla propia con {method} y {title}") {
            let api = FakeSlackAPI()
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            var config = slackConfig()
            config.slack.mergedTemplate = "Merged via {method}: {title}"
            await slack.prMerged(myPR(), method: .rebase, config: config)
            try expectEqual(api.posts.map(\.text), ["Merged via rebase: PR 1"])
        },
        TestCase("slack merged reply: si Slack falla queda el issue y se reintenta en el próximo ciclo") {
            let api = FakeSlackAPI()
            api.results = [.failure(.slack("not_in_channel"))]
            let store = try announcedStore()
            let slack = await announcer(api, clock: Box(at(0)), store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            let firstIssues = await slack.issues
            try expectEqual(firstIssues.map(\.error), [.slack("not_in_channel")])
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, nil)
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(api.posts.count, 2)
            try expectEqual(api.posts[1].threadTS, "111.1")
            try expect(store.load().mergedReplies["o/r#1"]?.postedAt != nil)
            let secondIssues = await slack.issues
            try expectEqual(secondIssues, [])
        },
        TestCase("slack merged reply: un intento dudoso que sí salió no se repite") {
            let api = FakeSlackAPI()
            api.results = [.failure(.network("timeout"))]
            let store = try announcedStore()
            let clock = Box(at(0))
            let slack = await announcer(api, clock: clock, store: store)
            await slack.prMerged(myPR(), method: .squash, config: slackConfig())
            try expectEqual(store.load().uncertain["merged:o/r#1"], at(0))
            // El mensaje sí había salido.
            api.threads["C1/111.1"] = [
                SlackMessage(ts: "111.1", text: "root", user: "U1"),
                SlackMessage(ts: "\(Int(at(0).timeIntervalSince1970)).000200", text: "Merged :white_check_mark:", user: "U1"),
            ]
            clock.value = at(5)
            await slack.process(snapshot: slackSnap(), config: slackConfig())
            try expectEqual(api.posts.count, 1)
            try expectEqual(store.load().mergedReplies["o/r#1"]?.postedAt, at(5))
            try expectEqual(store.load().uncertain, [:])
        },
        TestCase("slack merged reply: el planner reintenta un día como máximo y nunca lo ya publicado") {
            var state = SlackState(baselineAt: .distantPast)
            state.mergedReplies["o/r#1"] = MergedReply(repo: repo, channelID: "C1", threadTS: "111.1", text: "Merged", requestedAt: at(0))
            let action = SlackAction.merged(prID: "o/r#1", repo: repo, channelID: "C1", threadTS: "111.1", text: "Merged")
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: slackConfig(), state: state, now: at(60)).actions, [action])
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: slackConfig(), state: state, now: at(60 * 25)).actions, [])
            var off = slackConfig()
            off.slack.postMerged = false
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: off, state: state, now: at(60)).actions, [])
            state.mergedReplies["o/r#1"]?.postedAt = at(1)
            try expectEqual(SlackPlanner.plan(snapshot: slackSnap(), config: slackConfig(), state: state, now: at(60)).actions, [])
            try expectEqual(SlackState.uncertainKey(for: action), "merged:o/r#1")
        },
        TestCase("slack merged reply: el estado viejo sin mergedReplies se lee vacío") {
            let state = try JSONCoding.decoder.decode(SlackState.self, from: Data(#"{"baselineAt":"2027-01-15T08:00:00Z"}"#.utf8))
            try expectEqual(state.mergedReplies, [:])
        },
    ]
}
```

Registrarlo al final de `allTests`: `+ SlackMergedReplyTests.cases`.

En `Sources/PRBarTests/SlackPlannerTests.swift`, el helper `text(_:)` pasa a:

```swift
private func text(_ action: SlackAction) -> String {
    switch action {
    case .announce(_, _, _, _, let text), .update(_, _, _, _, _, let text, _), .reply(_, _, _, _, let text, _),
         .merged(_, _, _, _, let text): text
    case .findMessage, .react: ""
    }
}
```

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift run PRBarTests "slack merged reply"`
Expected: error de compilación (`type 'SlackAction' has no member 'merged'`, `cannot find 'MergedReply' in scope`).

- [ ] **Step 3: El estado.** En `Sources/PRBarCore/SlackState.swift`:
  - antes de `public struct SlackState`:

```swift
/// "Merged" en el hilo de un PR mío que mergeé desde PRBar (spec F.4): pendiente hasta que se publica.
public struct MergedReply: Codable, Equatable, Sendable {
    public var repo: RepoRef
    public var channelID: String
    /// `ts` del anuncio: la respuesta va en su hilo.
    public var threadTS: String
    /// Texto ya armado con la plantilla (el método solo se conoce al mergear).
    public var text: String
    public var requestedAt: Date
    /// `nil` mientras no se publicó.
    public var postedAt: Date?

    public init(repo: RepoRef, channelID: String, threadTS: String, text: String, requestedAt: Date, postedAt: Date? = nil) {
        self.repo = repo
        self.channelID = channelID
        self.threadTS = threadTS
        self.text = text
        self.requestedAt = requestedAt
        self.postedAt = postedAt
    }
}
```

  - en `SlackState`, después de `public var selfUserID: String?`:

```swift
    /// "Merged" pedidos al mergear desde PRBar. Clave: `owner/repo#número`.
    public var mergedReplies: [String: MergedReply] = [:]
```

  - en `uncertainKey(for:)`, antes de `case .findMessage, .react: nil`: `case .merged(let prID, _, _, _, _): "merged:\(prID)"`;
  - `CodingKeys` agrega una línea al final del enum: `case mergedReplies`;
  - al final de `init(from:)`:

```swift
        mergedReplies = (try? c.decodeIfPresent([String: MergedReply].self, forKey: .mergedReplies)) ?? [:]
```

- [ ] **Step 4: La acción y el planner.** En `Sources/PRBarCore/SlackPlanner.swift`:
  - en `SlackAction`, después de `case reply(…)`:

```swift
    /// "Merged" en el hilo del anuncio de un PR mío que mergeé desde PRBar (spec F.4).
    case merged(prID: String, repo: RepoRef, channelID: String, threadTS: String, text: String)
```

  - en `prID`, agregar `.merged(let prID, _, _, _, _)` a la lista del `case`; en `repo`, `.merged(_, let repo, _, _, _)`; en `channelName`, un caso aparte `case .merged: nil`;
  - en `SlackPlanner`, después de `searchInterval`:

```swift
    /// Un "Merged" que no se pudo publicar se reintenta en cada ciclo durante un día como máximo.
    public static let mergedReplyWindow: TimeInterval = 24 * 60 * 60
```

  - en `plan(snapshot:config:state:now:)`, justo antes de `return plan`:

```swift
        // "Merged" en el hilo de los PRs que mergeé desde PRBar (spec F.4). No depende del snapshot: el PR ya no
        // está abierto.
        if config.slack.postMerged {
            let reference = now ?? snapshot.fetchedAt
            for (prID, reply) in state.mergedReplies.sorted(by: { $0.key < $1.key })
            where reply.postedAt == nil && reference.timeIntervalSince(reply.requestedAt) < mergedReplyWindow {
                plan.actions.append(.merged(
                    prID: prID, repo: reply.repo, channelID: reply.channelID, threadTS: reply.threadTS, text: reply.text
                ))
            }
        }
```

- [ ] **Step 5: Ejecutarla en `Sources/PRBarCore/SlackAnnouncer.swift`.**
  - en `run`, dentro del `switch action`, después del `case .reply(…)` completo:

```swift
                    case .merged(let prID, _, let channelID, let threadTS, let text):
                        // Igual que "Updated": si un intento anterior quedó dudoso, primero se mira el hilo.
                        if let since = uncertainSince,
                           try await existingReply(channelID: channelID, threadTS: threadTS, text: text, since: since, token: token) {
                            AppLog.write("Slack: the “Merged” reply for \(prID) is already in the thread; not posting it again")
                        } else {
                            begin(action)
                            _ = try await api.postMessage(channel: channelID, text: text, threadTS: threadTS, token: token)
                        }
                        state.mergedReplies[prID]?.postedAt = now()
```

  - en `issueDetail(_:for:)`: `case .announce, .update, .reply, .merged: "chat:write"`;
  - después de `reviewStarted(item:config:)`:

```swift
    /// Lo llama `AppModel` después de mergear un PR mío desde PRBar (spec F.4). Si PRBar lo había anunciado, deja
    /// "Merged" pendiente (persistido) y corre un ciclo para publicarlo ya. Pedirlo de nuevo para el mismo PR no hace
    /// nada. Los errores van a `issues` y al log: el merge ya está hecho.
    public func prMerged(_ pr: PullRequest, method: MergeMethod, config: AppConfig) async {
        let settings = config.slack
        guard settings.enabled, settings.postMerged, let announcement = state.announcements[pr.id],
              state.mergedReplies[pr.id] == nil else { return }
        state.mergedReplies[pr.id] = MergedReply(
            repo: pr.repo, channelID: announcement.channelID, threadTS: announcement.ts,
            text: SlackTemplate.render(settings.effectiveMergedTemplate, pr: pr, method: method.rawValue),
            requestedAt: now()
        )
        saveState()
        AppLog.write("Slack: “Merged” queued for \(pr.id)")
        await process(snapshot: pending?.snapshot ?? lastSnapshot ?? Snapshot(items: [], fetchedAt: now()), config: config)
    }
```

- [ ] **Step 6: Correr los tests.**

Run: `swift run PRBarTests "slack merged reply"`
Expected: 8 `✓`.

Run: `swift run PRBarTests slack`
Expected: todos `✓` (planner, announcer, anti-duplicados y reacciones no cambian).

Run: `swift build && swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 7: Commit.**

```bash
git add Sources/PRBarCore/SlackState.swift Sources/PRBarCore/SlackPlanner.swift Sources/PRBarCore/SlackAnnouncer.swift \
        Sources/PRBarTests/SlackPlannerTests.swift Sources/PRBarTests/SlackMergedReplyTests.swift Sources/PRBarTests/main.swift
git commit -m "feat(core): reply Merged in the Slack thread after merging from PRBar"
```

---
### Task 11: App: API de merge en `AppModel` y diálogo de confirmación

**Files:**
- Modify: `Sources/PRBar/AppModel.swift` (una propiedad `lazy`)
- Create: `Sources/PRBar/AppModel+Merge.swift`, `Sources/PRBar/Popover/MergeConfirmView.swift`

`AppModel` es el único punto de entrada: la fila, el menú contextual, el diálogo y (Plan 7) la CLI llaman a estos métodos. No hay tests unitarios del target de la app; se verifica con el build, la suite y las capturas (Task 14).

- [ ] **Step 1: La cola en `Sources/PRBar/AppModel.swift`.** Después de `private(set) lazy var respond = RespondQueue(…)` (justo antes de `/// Limpieza de worktrees huérfanos del arranque; …` y `private var orphanCleanup`):

```swift
    /// Merges de Ready to Merge (spec F.3). `lazy` por lo mismo que `reviews`.
    private(set) lazy var merges = MergeQueue(api: api, tokens: accounts, onMerged: { [weak self] completion in
        self?.mergeFinished(completion)
    })
```

- [ ] **Step 2: Crear `Sources/PRBar/Popover/MergeConfirmView.swift`.**

```swift
import AppKit
import PRBarCore
import SwiftUI

/// "Merge #42 into main?" (spec F.3): el título del PR, repo, commits y ramas, un popup con el método y el botón del
/// método elegido. Lo abre `AppModel.requestMerge` en una ventana chica cuando `merge.confirm` está encendido.
struct MergeConfirmView: View {
    static let size = NSSize(width: 440, height: 230)

    let item: ClassifiedPR
    let methods: [MergeMethod]
    /// Aviso que no impide mergear (p. ej. checks no requeridos fallando).
    let note: String?
    /// El repo borra la rama al mergear (lo hace GitHub; PRBar no la toca).
    let deletesBranch: Bool
    let onMerge: (MergeMethod) -> Void
    let onCancel: () -> Void
    @State private var method: MergeMethod

    init(
        item: ClassifiedPR, methods: [MergeMethod], initialMethod: MergeMethod, note: String?, deletesBranch: Bool,
        onMerge: @escaping (MergeMethod) -> Void, onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.methods = methods
        self.note = note
        self.deletesBranch = deletesBranch
        self.onMerge = onMerge
        self.onCancel = onCancel
        _method = State(initialValue: initialMethod)
    }

    private var pr: PullRequest { item.pr }

    /// `acme/api · 3 commits · feat/x → main`.
    private var details: String {
        var parts = [pr.repo.fullName]
        if let count = pr.merge.commitCount { parts.append(count == 1 ? "1 commit" : "\(count) commits") }
        parts.append("\(pr.headRef) → \(pr.baseRef)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Theme.violet)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Merge #\(pr.number) into \(pr.baseRef)?").font(.headline)
                    Text(pr.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Picker("Method", selection: $method) {
                ForEach(methods) { Text($0.actionTitle).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.orangeText)
            }
            if deletesBranch {
                Label("GitHub will delete the branch (repo setting)", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(method.actionTitle) { onMerge(method) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}
```

- [ ] **Step 3: Crear `Sources/PRBar/AppModel+Merge.swift`.**

```swift
import AppKit
import PRBarCore
import SwiftUI

/// Ready to Merge (spec F). La UI (fila, menú contextual, diálogo) y la CLI (Plan 7) pasan por acá.
extension AppModel {
    /// Métodos permitidos, método por defecto y si se puede mergear ahora.
    func mergeOptions(_ item: ClassifiedPR) -> MergeOptions {
        MergePolicy.options(for: item, snapshot: prStore.snapshot, config: configStore.config)
    }

    /// El botón Merge y el menú contextual. Con `merge.confirm` abre el diálogo; si no, mergea enseguida.
    /// `method == nil` = el método por defecto. No hace nada si el botón estaría deshabilitado.
    func requestMerge(_ item: ClassifiedPR, method: MergeMethod? = nil) {
        let options = mergeOptions(item)
        guard options.availability.isEnabled, let chosen = method ?? options.defaultMethod,
              options.methods.contains(chosen) else { return }
        if configStore.config.merge.confirm {
            openMergeConfirmation(item, method: chosen, options: options)
        } else {
            Task { _ = await merge(item, method: chosen) }
        }
    }

    /// Mergea sin preguntar (el diálogo ya confirmó, o la CLI con `--yes`). Usa el `headOid` de `item`: si alguien
    /// pusheó después, GitHub lo rechaza (`MergeError.headChanged`).
    @discardableResult
    func merge(_ item: ClassifiedPR, method: MergeMethod) async -> Result<MergeCompletion, MergeError> {
        await merges.merge(item, method: method)
    }

    /// Retry de una fila con error: refresca (el PR pudo cambiar) y vuelve a pedir el merge con el mismo método
    /// (con `merge.confirm`, se vuelve a confirmar).
    func retryMerge(prID: String) {
        guard case .failed(let method, _)? = merges.phases[prID] else { return }
        merges.dismiss(prID: prID)
        Task {
            await prStore.refresh()
            guard let item = prStore.snapshot?.items.first(where: { $0.id == prID && $0.category == .readyToMerge }) else { return }
            requestMerge(item, method: method)
        }
    }

    func dismissMergeError(prID: String) {
        merges.dismiss(prID: prID)
    }

    /// Settings › Repos: `nil` = el método por defecto de GitHub.
    func setMergeMethod(_ method: MergeMethod?, repoID: String, login: String) {
        updateConfig(refresh: false) { $0.setMergeMethod(method, repoID: repoID, login: login) }
    }

    /// Settings › General › "Confirm before merging".
    func setConfirmBeforeMerging(_ on: Bool) {
        updateConfig(refresh: false) { $0.merge.confirm = on }
    }

    /// Lo llama `MergeQueue` después de un merge: "Merged" en Slack y, a los 2 s ("Merged" en la fila), un refresco
    /// que saca la fila.
    func mergeFinished(_ completion: MergeCompletion) {
        let config = configStore.config
        let slack = self.slack
        Task { await slack.prMerged(completion.item.pr, method: completion.method, config: config) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await self.prStore.refresh()
            self.merges.prune(keeping: Set(self.prStore.snapshot?.items.map(\.id) ?? []))
        }
    }

    static func mergeWindowID(_ prID: String) -> String { "merge-\(prID)" }

    private func openMergeConfirmation(_ item: ClassifiedPR, method: MergeMethod, options: MergeOptions) {
        let windowID = Self.mergeWindowID(item.id)
        let settings = prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: item.account, repo: item.pr.repo)]
        WindowPresenter.shared.show(
            id: windowID, title: "Merge Pull Request", size: MergeConfirmView.size,
            options: WindowOptions(miniaturizable: false, resizable: false, allowsTabbing: false),
            contentID: "\(item.pr.headOid)|\(method.rawValue)"
        ) {
            MergeConfirmView(
                item: item, methods: options.methods, initialMethod: method, note: options.availability.note,
                deletesBranch: settings?.deleteBranchOnMerge ?? false,
                onMerge: { [weak self] chosen in
                    WindowPresenter.shared.close(id: windowID)
                    Task { _ = await self?.merge(item, method: chosen) }
                },
                onCancel: { WindowPresenter.shared.close(id: windowID) }
            )
        }
    }
}
```

- [ ] **Step 4: Compilar y correr la suite.**

Run: `swift build && swift run PRBarTests`
Expected: `Build complete!` y `N/N passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBar/AppModel.swift Sources/PRBar/AppModel+Merge.swift Sources/PRBar/Popover/MergeConfirmView.swift
git commit -m "feat(app): merge from AppModel with an optional confirmation"
```

---

### Task 12: App: sección Ready to Merge, botón Merge y menú contextual

**Files:**
- Create: `Sources/PRBar/Popover/MergeButton.swift`
- Modify: `Sources/PRBar/Popover/PRRowView.swift`, `Sources/PRBar/Popover/PopoverView.swift` (`section(_:)`)

- [ ] **Step 1: Crear `Sources/PRBar/Popover/MergeButton.swift`.**

```swift
import AppKit
import PRBarCore
import SwiftUI

/// Lo que puede hacer el botón Merge; lo arma `PRRowView` a partir de `AppModel`.
struct MergeButtonActions {
    /// `nil` = el método por defecto.
    var merge: (MergeMethod?) -> Void
    var retry: () -> Void
    var dismiss: () -> Void
}

/// Botón Merge de una fila de Ready to Merge (spec F.3): "Merge" con el método por defecto y un chevron con los
/// métodos permitidos. Mientras mergea, "Merging…"; después, "Merged" hasta que el refresco saca la fila; con error,
/// una pastilla roja con el texto de GitHub, Retry y Dismiss. Mismo estilo que `ReviewButton`.
struct MergeButton: View {
    let phase: MergePhase?
    let options: MergeOptions
    /// Rama base, para el tooltip ("Squash and Merge into main").
    let baseRef: String
    let actions: MergeButtonActions

    var body: some View {
        content.font(.subheadline.weight(.medium))
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case nil:
            HStack(spacing: 2) {
                Button("Merge") { actions.merge(nil) }
                    .help(help)
                    .accessibilityHint(help)
                Button(action: showMethodMenu) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .help("Merge with another method")
                .accessibilityLabel("Merge With…")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!options.availability.isEnabled)
        case .merging?:
            PhasePill(fg: Theme.violet, bg: Theme.tint(Theme.violet)) {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                Text("Merging…")
            }
            .help("Merging on GitHub")
            .accessibilityLabel("Merging")
        case .merged?:
            PhasePill(fg: Theme.greenText, bg: Theme.tint(Theme.green), leading: 6) {
                Image(systemName: "checkmark.circle.fill").font(.callout)
                Text("Merged").fontWeight(.semibold)
            }
            .help("Merged on GitHub")
            .accessibilityLabel("Merged")
        case .failed(_, let message)?:
            Button {
                FailureMenu.show(message: message, logURL: AppPaths.logFile, items: [
                    ClosureMenuItem(title: "Retry", action: actions.retry),
                ], dismiss: actions.dismiss)
            } label: {
                PhasePill(fg: Theme.redText, bg: Theme.tint(Theme.red), leading: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.subheadline)
                    Text("Error")
                }
            }
            .buttonStyle(.plain)
            .help(message)
            .accessibilityLabel("Merge failed: \(message)")
        }
    }

    /// El motivo si está deshabilitado; si no, "Squash and Merge into main" (y la nota de `UNSTABLE`).
    private var help: String {
        if let reason = options.availability.reason { return reason }
        let text = "\(options.defaultMethod?.actionTitle ?? "Merge") into \(baseRef)"
        return options.availability.note.map { "\(text) · \($0)" } ?? text
    }

    /// Los métodos permitidos, con ✓ en el de por defecto. Un `NSMenu` (como `FailureMenu`) para que el botón
    /// conserve su estilo.
    private func showMethodMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for method in options.methods {
            let item = ClosureMenuItem(title: method.actionTitle) { actions.merge(method) }
            item.state = method == options.defaultMethod ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Línea de estado de una fila de Ready to Merge: lista, lista con aviso, o por qué todavía no se puede.
struct MergeStatusLabel: View {
    let availability: MergeAvailability

    static func text(for availability: MergeAvailability) -> String {
        availability.reason ?? availability.note ?? "Approved · ready to merge"
    }

    var body: some View {
        if let reason = availability.reason {
            Label(reason, systemImage: reason == MergePolicy.checking ? "clock" : "lock")
                .foregroundStyle(.secondary)
        } else if let note = availability.note {
            Label(note, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.orangeText)
        } else {
            Label(Self.text(for: availability), systemImage: "checkmark.seal")
                .foregroundStyle(Theme.greenText)
        }
    }
}
```

- [ ] **Step 2: La fila en `Sources/PRBar/Popover/PRRowView.swift`.**
  - después de `@ObservedObject var respond: RespondQueue`:

```swift
    @ObservedObject var merges: MergeQueue
```

  - en `rowContent`, después del bloque `if item.category == .myFeedback { FeedbackLabel(…) … }`:

```swift
                if item.category == .readyToMerge {
                    MergeStatusLabel(availability: model.mergeOptions(item).availability)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
```

  - en `trailingAccessory`, antes de `default: EmptyView()`:

```swift
        case .readyToMerge:
            MergeButton(phase: merges.phases[item.id], options: model.mergeOptions(item), baseRef: pr.baseRef, actions: mergeActions)
```

  - en `contextMenu`, al final (después del bloque de `.myFeedback`):

```swift
        if item.category == .readyToMerge {
            Divider()
            let options = model.mergeOptions(item)
            let canMerge = options.availability.isEnabled && merges.phases[item.id] == nil
            Button("Merge") { model.requestMerge(item) }
                .disabled(!canMerge)
            Menu("Merge With…") {
                ForEach(options.methods) { method in
                    Button(method.actionTitle) { model.requestMerge(item, method: method) }
                }
            }
            .disabled(!canMerge)
        }
```

  - en `accessibilityLabel`, después del bloque de `.myFeedback`:

```swift
        if item.category == .readyToMerge {
            parts.append(MergeStatusLabel.text(for: model.mergeOptions(item).availability))
        }
```

  - después de `reviewActions`:

```swift
    private var mergeActions: MergeButtonActions {
        let model = self.model
        let item = self.item
        return MergeButtonActions(
            merge: { method in model.requestMerge(item, method: method) },
            retry: { model.retryMerge(prID: item.id) },
            dismiss: { model.dismissMergeError(prID: item.id) }
        )
    }
```

- [ ] **Step 3: El popover en `Sources/PRBar/Popover/PopoverView.swift`.** En `section(_:items:dimmed:)`, la fila pasa a:

```swift
                PRRowView(item: item, dimmed: dimmed, model: model, reviews: model.reviews, respond: model.respond,
                          merges: model.merges)
```

(`actionable` ya incluye `.readyToMerge` desde la Task 4; el título sale de `PRCategory.title`.)

- [ ] **Step 4: Compilar, correr la suite e instalar.**

Run: `swift build && swift run PRBarTests && Scripts/bundle.sh --install`
Expected: build sin errores, `N/N passed`, la app instalada y abierta.

- [ ] **Step 5: Mirarlo en la app** (con un PR propio aprobado en un repo de prueba; ver `docs/qa/plan-10-checklist.md`, sección B):
  - el popover muestra **Ready to Merge (1)** después de My PRs with Feedback; la fila dice "Approved · ready to merge" (o el motivo) y tiene **Merge** + chevron;
  - el tooltip de Merge dice "Squash and Merge into main" (o el método del repo);
  - el chevron abre el menú con los métodos permitidos y ✓ en el de por defecto;
  - click derecho: "Merge" y "Merge With…".

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBar/Popover/MergeButton.swift Sources/PRBar/Popover/PRRowView.swift Sources/PRBar/Popover/PopoverView.swift
git commit -m "feat(app): show Ready to Merge with a Merge button in the popover"
```

---

### Task 13: App: Settings (General, Repos, Slack)

**Files:**
- Modify: `Sources/PRBar/Settings/GeneralTab.swift`, `Sources/PRBar/Settings/ReposTab.swift`, `Sources/PRBar/Settings/SlackTab.swift`

- [ ] **Step 1: General.** En `Sources/PRBar/Settings/GeneralTab.swift`:
  - antes de la sección de Notifications (la que empieza con `Toggle(isOn: notification(\.enabled))`), una sección nueva:

```swift
            Section {
                Toggle(isOn: Binding(
                    get: { configStore.config.merge.confirm },
                    set: { model.setConfirmBeforeMerging($0) }
                )) {
                    Text("Confirm before merging")
                    Text("Shows the PR, the merge method and the number of commits first")
                }
            } header: {
                Text("Merging")
            }
```

  - en el `Group` de notificaciones, después de `Toggle("My PR was approved or CI failed", …)`:

```swift
                    Toggle("My PR is ready to merge", isOn: notification(\.readyToMerge))
```

- [ ] **Step 2: Repos.** En `Sources/PRBar/Settings/ReposTab.swift`:
  - en `detail(_:)`, después de `slackSection(repo)`: `mergeSection(repo)`;
  - después de `slackSection(_:)` (la función), agregar:

```swift
    /// Método de merge del repo (spec F.5): solo los que el repo permite según el último refresco de esta cuenta.
    private func mergeSection(_ repo: RepoConfig) -> some View {
        let settings = model.prStore.snapshot?.repoMergeSettings[Snapshot.scope(account: login, repo: repo.repo)]
        let allowed = MergePolicy.allowedMethods(settings)
        return Section {
            Picker("Merge method", selection: Binding(
                get: { repo.mergeMethod },
                set: { model.setMergeMethod($0, repoID: repo.id, login: login) }
            )) {
                Text(settings?.viewerDefault.map { "Repository default (\($0.title))" } ?? "Repository default")
                    .tag(MergeMethod?.none)
                ForEach(allowed) { method in
                    Text(method.title).tag(MergeMethod?.some(method))
                }
                if let current = repo.mergeMethod, !allowed.contains(current) {
                    Text("\(current.title) (not allowed)").tag(MergeMethod?.some(current))
                }
            }
        } header: {
            Text("Ready to Merge")
        } footer: {
            Text(settings == nil
                 ? "PRBar learns which methods this repo allows on the next refresh."
                 : "The Merge button uses this method; the menu next to it offers the others the repo allows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 3: Slack.** En `Sources/PRBar/Settings/SlackTab.swift`, en la sección "My PRs", después del `templateEditor("Reply", kind: .update)` (con su `.padding` y `.disabled`):

```swift
                Toggle("Reply “Merged” in the thread when I merge from PRBar", isOn: toggle(.postMerged))
                templateEditor("Reply", kind: .merged)
                    .padding(.leading, 16)
                    .disabled(!settings.postMerged)
```

- [ ] **Step 4: Compilar, correr la suite e instalar.**

Run: `swift build && swift run PRBarTests && Scripts/bundle.sh --install`
Expected: build sin errores, `N/N passed`.

- [ ] **Step 5: Mirarlo en la app.**
  - Settings › General: sección **Merging** con "Confirm before merging" encendido; Notifications con "My PR is ready to merge". Apagar "Confirm before merging" → `config.json` tiene `"merge" : { "confirm" : false }`.
  - Settings › Repos: sección **Ready to Merge** con "Merge method: Repository default (Squash)" y solo los métodos permitidos. Elegir "Rebase" → `"mergeMethod" : "rebase"` en el repo.
  - Settings › Slack › My PRs: "Reply “Merged” in the thread when I merge from PRBar" y su plantilla; "Insert Variable" ofrece `{method}`; la vista previa de `Merged via {method}` dice "Merged via squash".

- [ ] **Step 6: Commit.**

```bash
git add Sources/PRBar/Settings/GeneralTab.swift Sources/PRBar/Settings/ReposTab.swift Sources/PRBar/Settings/SlackTab.swift
git commit -m "feat(app): add merge settings to General, Repos and Slack"
```

---

### Task 14: Capturas: popover con Ready to Merge y diálogo de confirmación

**Files:**
- Modify: `Sources/PRBar/Snapshots/SnapshotFixtures.swift` (`snapshot` y un `extension` al final)
- Modify: `Sources/PRBar/Snapshots/SnapshotMode.swift` (`renderAll`, función nueva, alturas de `settings()`)
- Modify: `docs/screenshots/README.md`

- [ ] **Step 1: Fixtures.** Al final de `Sources/PRBar/Snapshots/SnapshotFixtures.swift`:

```swift
// MARK: - Ready to Merge (spec F)

extension SnapshotFixtures {
    /// Ready to Merge: aprobado, checks pasando; Merge habilitado (squash por defecto) y la PR del diálogo.
    var idempotencyKeys: ClassifiedPR {
        readyToMerge(
            item(Self.api, 322, "Add idempotency keys to payment retries", author: Self.personal, base: "main",
                 head: "feat/idempotency-keys", ci: .success, adds: 96, dels: 14, updated: -30, category: .readyToMerge,
                 account: Self.personal, lastCommit: -60 * 3,
                 reviews: [PRReview(author: "tomas-r", isBot: false, state: .approved, submittedAt: date(minutes: -40))]),
            status: .clean, commits: 3
        )
    }

    /// Ready to Merge pero bloqueado: un check requerido todavía corre.
    var reportsDarkMode: ClassifiedPR {
        readyToMerge(
            item(Self.webApp, 488, "Dark mode for the reports page", author: Self.personal, base: "develop",
                 head: "feat/reports-dark-mode", ci: .pending, adds: 241, dels: 87, updated: -15, category: .readyToMerge,
                 account: Self.personal, lastCommit: -60,
                 reviews: [PRReview(author: "lucia-m", isBot: false, state: .approved, submittedAt: date(minutes: -20))]),
            status: .blocked, commits: 7
        )
    }

    /// Lo que GitHub dice de cada repo para la cuenta personal.
    static var mergeSettings: [String: RepoMergeSettings] {
        [
            Snapshot.scope(account: personal, repo: api): RepoMergeSettings(
                squashAllowed: true, mergeCommitAllowed: true, rebaseAllowed: false, viewerDefault: .squash,
                deleteBranchOnMerge: true, viewerPermission: "WRITE"),
            Snapshot.scope(account: personal, repo: webApp): RepoMergeSettings(
                squashAllowed: true, mergeCommitAllowed: false, rebaseAllowed: true, viewerDefault: .squash,
                deleteBranchOnMerge: false, viewerPermission: "ADMIN"),
        ]
    }

    /// `base` aprobado y con datos de merge.
    private func readyToMerge(_ base: ClassifiedPR, status: MergeStateStatus, commits: Int) -> ClassifiedPR {
        let pr = base.pr
        let approved = PullRequest(
            repo: pr.repo, number: pr.number, title: pr.title, url: pr.url, isDraft: pr.isDraft, author: pr.author,
            authorAvatarURL: pr.authorAvatarURL, baseRef: pr.baseRef, headRef: pr.headRef, headOid: pr.headOid,
            additions: pr.additions, deletions: pr.deletions, createdAt: pr.createdAt, updatedAt: pr.updatedAt,
            lastCommitAt: pr.lastCommitAt, ciState: pr.ciState, reviewDecision: .approved, reviews: pr.reviews,
            comments: pr.comments, requestedReviewers: pr.requestedReviewers,
            merge: PRMergeState(nodeID: "PR_\(pr.number)", mergeable: .mergeable, status: status, viewerCanUpdate: true,
                                commitCount: commits)
        )
        return ClassifiedPR(pr: approved, category: .readyToMerge, account: base.account)
    }
}
```

Y `var snapshot` pasa a:

```swift
    var snapshot: Snapshot {
        Snapshot(items: [rateLimiting, loginRedirect, reactQuery, csvExport, idempotencyKeys, reportsDarkMode] + others,
                 fetchedAt: now.addingTimeInterval(-50), repoMergeSettings: Self.mergeSettings)
    }
```

(`item(…)` es `private` del struct; un `extension` en el mismo archivo lo puede usar.)

- [ ] **Step 2: Captura `merge-confirm`.** En `Sources/PRBar/Snapshots/SnapshotMode.swift`, en `renderAll()`, después de `try await respondWindows(model: main)`:

```swift
        try await mergeConfirmation(model: main)
```

y en `// MARK: Screens`, después de `respondWindows(model:)`:

```swift
    /// The confirmation before merging (spec F.3), as `WindowPresenter` shows it: titled, fixed size.
    private func mergeConfirmation(model: AppModel) async throws {
        let item = fixtures.idempotencyKeys
        let merge = model.mergeOptions(item)
        for appearance in options.appearances {
            let view = MergeConfirmView(
                item: item, methods: merge.methods, initialMethod: merge.defaultMethod ?? .squash,
                note: merge.availability.note, deletesBranch: true, onMerge: { _ in }, onCancel: {}
            )
            let controller = NSHostingController(rootView: view.environment(\.controlActiveState, .key))
            let window = SnapshotRenderer.makeWindow(
                controller: controller, size: MergeConfirmView.size, style: [.titled, .closable],
                title: "Merge Pull Request", appearance: SnapshotRenderer.appearance(appearance)
            )
            window.setContentSize(MergeConfirmView.size)
            await SnapshotRenderer.settle(window)
            try write(SnapshotRenderer.capture(window, includeFrame: true, cornerRadius: 10), "merge-confirm", appearance)
        }
    }
```

- [ ] **Step 3: Settings más altos.** En `settings()`, en `sizes`, sumar al alto **actual** de cada pestaña (después de los planes 8 y 9): `.general` + 130 (sección Merging y una notificación más; con el Plan 8 queda en 1070), `.repos` + 110 (sección Ready to Merge) y `.slack` + 120 (interruptor y plantilla de Merged; queda en 1300 si no cambió).

- [ ] **Step 4: Generar y mirar.**

Run: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both`
Expected: la lista incluye `merge-confirm-light.png` y `merge-confirm-dark.png`. Abrir:
- `popover-*.png`: después de My PRs with Feedback, **Ready to Merge 2**: "Add idempotency keys to payment retries" con "Approved · ready to merge" y **Merge** + chevron habilitados; "Dark mode for the reports page" con 🔒 "Blocked by branch protection or required checks" y Merge deshabilitado.
- `merge-confirm-*.png`: "Merge #322 into main?", el título, "acme/api · 3 commits · feat/idempotency-keys → main", "Method: Squash and Merge", "GitHub will delete the branch (repo setting)", Cancel y **Squash and Merge** por defecto.
- `settings-general-*`, `settings-repos-*`, `settings-slack-*`: las secciones nuevas completas, sin cortes.

- [ ] **Step 5: Actualizar las capturas del repo.** En `docs/screenshots/README.md`, en la tabla:
  - la fila de `popover` agrega "Ready to Merge (one ready, one blocked)" antes de "Other collapsed";
  - una fila nueva después de `respond-chat`:

```markdown
| `merge-confirm` | The confirmation before merging: PR, commits, merge method popup and "Squash and Merge" |
```

Run: `Scripts/snapshots.sh docs/screenshots both`

```bash
git add Sources/PRBar/Snapshots/SnapshotFixtures.swift Sources/PRBar/Snapshots/SnapshotMode.swift docs/screenshots
git commit -m "feat(snapshots): capture Ready to Merge and the merge confirmation"
```

---

### Task 15: Spec, QA y verificación final

**Files:**
- Modify: `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md` (parte F)
- Create: `docs/qa/plan-10-checklist.md`

- [ ] **Step 1: Spec.** Al final de la parte F (después de F.7), agregar `### F.8 Decisiones de implementación (Plan 10)` con las 15 decisiones de "Decisiones donde el spec era ambiguo" de este plan, tal como están arriba, más:
  - **F.2:** se agregan `viewerPermission` (repo) y `commits.totalCount` (PR); los datos del repo van en `Snapshot.repoMergeSettings` por cuenta y repo.
  - **F.3:** la referencia de GitHub recomienda la API REST asíncrona de merge; se usa la mutación porque soporta `expectedHeadOid` y PRBar no apila PRs.
  - **F.6:** la plantilla se llama `merged` en la CLI (como `new-pr`, `update`, `round`); `myPR.merged` queda como alias.

- [ ] **Step 2: Checklist.** Crear `docs/qa/plan-10-checklist.md`:

```markdown
# QA manual — Plan 10 (Ready to Merge)

Hace falta un repo de prueba propio (p. ej. `<vos>/prbar-merge-sandbox`) agregado en Settings › Repos, con PRs tuyos
que puedas mergear y una segunda cuenta (o un colaborador) que los apruebe. Nada de esto se hace en repos reales.

## A. Datos y clasificación
- [ ] Un PR tuyo aprobado, sin comentarios nuevos: aparece en **Ready to Merge (1)**, después de My PRs with Feedback; el badge lo cuenta.
- [ ] Alguien comenta después de tu último push: el PR pasa a My PRs with Feedback. Pusheás: vuelve a Ready to Merge.
- [ ] Repo sin reviews requeridas: con una aprobación vigente entra; si la misma persona después pide cambios, sale.
- [ ] Un PR con conflictos con la base no aparece en Ready to Merge.
- [ ] Un PR draft aprobado no aparece.
- [ ] Con el CI fallando (check no requerido) sigue en la lista, con ✕ de CI y la línea "Some checks that aren’t required are failing".
- [ ] `~/Library/Application Support/PRBar/state.json` tiene `"merge"` en el PR (`nodeID`, `status`, `commitCount`) y `repoMergeSettings` con `"<cuenta>|<owner>/<repo>"`.
- [ ] Abrir una versión anterior de `state.json` (sin esos campos) no rompe: el primer refresco los completa.

## B. Botón Merge
- [ ] La fila dice "Approved · ready to merge"; el tooltip de Merge dice "<Método> into <base>".
- [ ] Con un check requerido corriendo: Merge deshabilitado con "Blocked by branch protection or required checks".
- [ ] Con la rama atrasada respecto de la base (y "Require branches to be up to date"): "Branch is behind <base>".
- [ ] Recién abierto el PR (GitHub todavía calcula): "Checking…" hasta el próximo refresco.
- [ ] El chevron muestra solo los métodos que el repo permite (cambiarlos en GitHub › Settings › General y refrescar), con ✓ en el de por defecto.
- [ ] Settings › Repos › "Merge method: Rebase" (si está permitido): el ✓ y el botón del diálogo pasan a "Rebase and Merge".
- [ ] Click derecho: "Merge" y "Merge With…" con los mismos métodos.

## C. Confirmación y merge
- [ ] Con "Confirm before merging" encendido: Merge abre "Merge #N into <base>?" con el título, `owner/repo · N commits · head → base`, el popup de métodos y el botón del método. Esc cancela; ↩ mergea.
- [ ] Merge → la fila dice "Merging…", después "Merged" y a los 2 s desaparece (refresco). En GitHub, el PR quedó mergeado con el método elegido.
- [ ] Con "Confirm before merging" apagado, Merge mergea sin diálogo.
- [ ] Con el diálogo abierto, pushear un commit nuevo al PR desde la terminal y confirmar: la fila muestra Error; el menú dice "The PR changed since you looked at it — refresh and try again." **Anotar el texto exacto que devolvió GitHub** (en `~/Library/Logs/PRBar/prbar.log`, "Couldn't merge …") y, si no es "Head branch was modified…", agregar la frase a `MergeError.classify`.
- [ ] Retry refresca y vuelve a abrir el diálogo con el head nuevo; Dismiss borra el error.
- [ ] Con una cuenta sin permiso de escritura (repo ajeno con un PR tuyo desde un fork, si aplica): el botón dice "You don’t have permission to merge in …" o el error de GitHub aparece en la fila.
- [ ] La rama no la borra PRBar: solo se borra si el repo tiene "Automatically delete head branches" (el diálogo lo avisa).

## D. Slack
- [ ] Un PR anunciado por PRBar (token de usuario): al mergear, en el hilo del anuncio aparece "Merged :white_check_mark:" una sola vez.
- [ ] Lo mismo con el conector de Claude (`slack-connector.log` muestra un solo post).
- [ ] Plantilla "Merged via {method}: {title}" → el hilo dice "Merged via squash: <título>".
- [ ] Un PR no anunciado por PRBar: no se responde nada.
- [ ] Apagar "Reply “Merged” in the thread…" → no se responde.
- [ ] Sin red de Slack (o el canal archivado) al mergear: el merge queda hecho, el popover muestra el issue de Slack y `slack-state.json` tiene `mergedReplies` con `postedAt` vacío; al volver la conexión, el próximo refresco lo publica una sola vez.

## E. Notificaciones
- [ ] Cuando un PR tuyo entra a Ready to Merge llega "<owner>/<repo>#N is ready to merge" con el título del PR; no llega además "Your PR Was Approved".
- [ ] Apagando "My PR is ready to merge" llega la de aprobado como antes.
- [ ] Click en la notificación abre el PR en GitHub.

## F. Settings y capturas
- [ ] General › Merging y Notifications; Repos › Ready to Merge; Slack › My PRs: todo se guarda en `config.json` (`merge.confirm`, `mergeMethod`, `slack.postMerged`, `slack.mergedTemplate`).
- [ ] `Scripts/snapshots.sh "$TMPDIR/s" both` incluye `merge-confirm-*` y el popover con Ready to Merge.
```

- [ ] **Step 3: Commit.**

```bash
git add docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md docs/qa/plan-10-checklist.md
git commit -m "docs: Ready to Merge implementation decisions and QA checklist"
```

---

## Verificación final

- [ ] `swift build` sin warnings nuevos.
- [ ] `swift run PRBarTests` → `N/N passed` (los de antes más 72 nuevos: 6 + 5 + 6 + 15 + 5 + 8 + 7 + 7 + 5 + 8), 3 veces seguidas.
- [ ] `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` → las capturas de antes más `merge-confirm-light/dark`.
- [ ] QA manual de `docs/qa/plan-10-checklist.md`.

---

## APIs para la CLI (Plan 7, F.6)

La CLI no está en este plan. Estas son las APIs que sus comandos van a llamar; todas en el main actor y las mismas que usa la UI:

| Comando F.6 | API |
|---|---|
| `prbar prs --list ready-to-merge` | `PRCategory.readyToMerge` (`rawValue` `"readyToMerge"`, `title` "Ready to Merge"); `prStore.snapshot?.items(in: .readyToMerge)`. El Plan 7 tiene que sumar `case readyToMerge = "ready-to-merge"` a `PRListFilter` (con `category: .readyToMerge`). Para `--json`, cada PR trae `pr.merge` (`PRMergeState`, `Codable`) y `AppModel.mergeOptions(_:)` (`MergeOptions`: `availability`, `methods`, `defaultMethod`). |
| `prbar merge <pr> [--method m] [--yes]` | Validar con `MergePolicy.problem(item, method: MergeMethod?, options: AppModel.mergeOptions(item)) -> MergeError?` (`nil` = se puede; si no, exit 6 con `localizedDescription`: no está en Ready to Merge, `availability.reason`, método no permitido); sin `--method`, `defaultMethod`. Mergear con `AppModel.merge(_:method:) async -> Result<MergeCompletion, MergeError>` (sin diálogo: la confirmación es de la CLI; sin TTY exige `--yes`). `AppModel.merge` vuelve a validar contra el snapshot actual (`MergeError.unavailable(_)`, o `.noLongerOpen` si el PR ya no está). Los errores tienen `localizedDescription` (los mismos textos que la fila); `MergeError.headChanged` sugiere `prbar refresh`; `.mergeQueueRequired` = el repo usa merge queue. El estado en vivo: `AppModel.merges.phases[prID]` (`MergePhase`: `.merging(m)`, `.merged(m)`, `.failed(method: MergeMethod?, error: MergeError)`, con `message`); el intento fallido: `AppModel.merges.failure(prID:) -> MergeFailure?`. Slack y el refresco salen solos (`mergeFinished`). `MergeMethod(rawValue:)` parsea `squash|merge|rebase`. |
| `prbar repo set <repo> --merge-method squash\|merge\|rebase\|default` | `AppModel.setMergeMethod(_:repoID:login:)` (`default` = `nil`); permitidos: `MergePolicy.allowedMethods(snapshot.repoMergeSettings[Snapshot.scope(account:repo:)])`. Core: `AppConfig.setMergeMethod(_:repoID:login:)`. |
| `prbar config set confirm-merge on\|off` | `AppModel.setConfirmBeforeMerging(_:)` (`AppConfig.merge.confirm`). |
| `prbar slack set merged on\|off` | `AppModel.setSlackToggle(.postMerged, _:)`. El Plan 7 tiene que mapear el nombre `merged` a `SlackToggle.postMerged`. |
| `prbar slack template set myPR.merged "…"` | `SlackTemplateKind.merged` (`keyPath` `\.mergedTemplate`, `defaultTemplate`, `variables` con `{method}`); `AppModel.updateSlackConfig { $0.slack.mergedTemplate = … }`. Se recomienda el nombre `merged` en `SlackTemplateName` (como `new-pr`, `update`, `round`) con `myPR.merged` como alias. |
| `prbar notify set ready-to-merge on\|off` | `AppModel.updateConfig(refresh: false) { $0.notifications.readyToMerge = … }`; `NotificationKind.readyToMerge`. |

**Paridad de UI (Plan 7, `UIActionInventory`):** controles nuevos que el escáner va a encontrar: el botón "Merge" y el chevron "Merge With…" (`MergeButton`), Retry/Dismiss del error (`FailureMenu`), "Merge" y "Merge With…" del menú contextual (`PRRowView`), "Cancel" y el botón del método y el `Picker("Method")` del diálogo (`MergeConfirmView`), "Confirm before merging" y "My PR is ready to merge" (`GeneralTab`), `Picker("Merge method")` (`ReposTab`), "Reply “Merged” in the thread…" y su `templateEditor` (`SlackTab`). Todos tienen un comando en la tabla de arriba (el `Picker("Method")` y el botón del diálogo son `merge --method`; Retry es `merge` de nuevo; Dismiss no necesita comando: es solo visual).
