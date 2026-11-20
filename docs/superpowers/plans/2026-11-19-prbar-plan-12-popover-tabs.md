# PRBar — Plan 12: Pestañas en el popover (To Review / My PRs)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** El popover muestra, debajo de la cabecera, un control segmentado nativo con dos pestañas — **To Review N** y **My PRs N** — que reparte las secciones de hoy (más "Other" y una sección nueva "Waiting for Review", las dos colapsadas), recuerda la pestaña elegida, cambia con ⌘1/⌘2, la elige sola cuando se hace clic en una notificación de un PR, y tiene su equivalente en la CLI (`prbar prs --tab`, totales por pestaña en `prbar status`, `prbar app popover --tab`).

**Spec:** `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`, parte **H** (H.1–H.3). Mientras otro agente la integra al spec, el texto está en el scratchpad (`spec-part-H.md`, sección H); la Task 8 agrega **H.4 Decisiones de implementación (Plan 12)** al spec principal. Se apoya en:
- §7 del spec base (`ActionClassifier`, `PRCategory`): este plan **no** cambia la clasificación; solo agrupa categorías.
- C (CLI): `AppCommand`, `CommandProtocol.version`, `CLIRouter`, `UIActionInventory` y los tests de paridad (C.7).
- F.8 (Plan 10): `PRCategory.readyToMerge`, `countsForBadge`.

**Orden de ejecución:** 11 → **12** → 13 → 14. Este plan va **después del Plan 11** (`docs/superpowers/plans/2026-11-19-prbar-plan-11-merge-window.md`), que otro agente está implementando en `main`.

## Qué asume del Plan 11

| Artefacto del Plan 11 | Cómo lo usa este plan |
|---|---|
| `CommandProtocol.version = 3` (Task 3 del Plan 11) | Este plan la sube a **4** (cambia `listPRs` y agrega `openPopover`). Si al empezar no es 3, sumar 1 a la que haya y decirlo en el commit. |
| `PlannedNotification.mergePRID` y `NotificationDelivery.onOpenMerge` (Task 6 del Plan 11) | No se tocan. La selección de pestaña se engancha **antes** de esas ramas, con el `prID` que ya tiene toda notificación de un PR (`PlannedNotification.prID`). |
| `MergeButton` con "Merge…" y `MergeConfirmView.swift` borrado (Task 6) | No se tocan; `PRRowView` sigue igual. Las entradas de `UIActionInventory` de `Popover/PRRowView.swift` y `Popover/MergeButton.swift` quedan como las dejó el Plan 11. |
| `SnapshotMode.mergeWindows(model:)` en lugar de `mergeConfirmation` (Task 9) | Las capturas nuevas del popover van **antes** de `reviewWindows`, lejos de las del Plan 11. |
| `AppModelServices.mergeHistory` (Task 6) | `popoverDefaults` se agrega **al final** de `AppModelServices`, después de lo que haya. |
| `HistoryKind.merge`, `OpenTarget.merge` | Sin relación; no se tocan. |

**Si algo no está** (p. ej. el Plan 11 todavía no terminó): agregar lo de este plan al final de la lista/enum/`switch` correspondiente y seguir; nada de este plan depende del contenido del Plan 11 salvo el número de versión del protocolo.

## Archivos compartidos con otros planes

- `Sources/PRBarCore/AppCommand.swift`: un caso nuevo (`openPopover`) en "Ventanas / app" y una línea **nueva al final** de `Name` (`case openPopover`), para no chocar con los planes 13 y 14, que agregan sus propias líneas al final.
- `Sources/PRBarCore/CommandResults.swift`: `PopoverInfo` va en un archivo propio (`PopoverTabs.swift`); en `PRInfo` y `StatusInfo` solo se agregan propiedades **opcionales** al final.
- `Sources/PRBar/Popover/PopoverView.swift`: el Plan 13 agrega el pie de recursos debajo de `content` (después de este plan). Este plan deja `body` con un hueco claro para eso.
- `Sources/PRBarTests/UIActionInventory.swift`: entradas nuevas en el bloque "// Popover".

## Convenciones

- Build **por producto**: `swift build --product PRBar`, `swift build --product PRBarCLI`, `swift build --product PRBarTests`. Un `swift build` pelado falla por el plugin de argument-parser. Sin warnings nuevos.
- Tests: `swift run PRBarTests [filtro]` (runner propio; sale ≠ 0 si algo falla). Cada archivo de tests nuevo se registra en `Sources/PRBarTests/main.swift`, **al final** de `allTests`. `expect`/`expectEqual` toman autoclosures **sin** `await`: primero el valor a una variable local.
- **Nunca** correr la CLI (`swift run PRBarCLI …` o `prbar …`) sin `PRBAR_SOCKET` apuntando a un socket de prueba: hablaría con la PRBar real del usuario.
- Los tests **nunca** llaman a GitHub, Slack, Claude ni a hosts por ssh de verdad (`FakeTransport`, `FakeAPI`, `FakeActions`).
- Capturas: `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both` y **mirar** con Read los PNG nuevos o cambiados; para el repo, `Scripts/snapshots.sh docs/screenshots both` y revertir con `git checkout --` los PNG ajenos que solo cambiaron bytes.
- Commits en inglés, **sin** `Co-Authored-By` ni ninguna atribución a Claude/Anthropic. Sin push. Se trabaja en `main`.
- UI en inglés. Comentarios de código en español (o en inglés si el archivo ya está en inglés).
- Las líneas citadas son orientativas: buscar por el nombre del símbolo.

## Decisiones donde el spec era ambiguo (van a H.4 en la Task 8)

1. **"Mío"** = el autor del PR es la cuenta desde la que se ve (`pr.author` == `item.account`, sin distinguir mayúsculas). `ClassifiedPR` ya viene desduplicado desde la cuenta autora (`SnapshotBuilder.dedupeAndSort`).
2. **Asignación:** `toReview`, `updatedSinceMyReview` → To Review; `myFeedback`, `readyToMerge` → My PRs; `other` → My PRs si es mío ("Waiting for Review"), si no To Review ("Other"). No hay categoría nueva en `PRCategory`: "Waiting for Review" es una **sección** (`PopoverSection.waitingForReview`) y la clasificación de §7 no cambia.
3. **Contador N** de cada pestaña = PRs con `category.countsForBadge` en esa pestaña. Las dos suman exactamente `Snapshot.badgeCount` (hay un test). Other y Waiting for Review no cuentan.
4. **Punto de acento:** el control segmentado nativo de macOS ignora colores en sus etiquetas, así que el "punto" es un carácter: la pestaña **no** elegida con N > 0 dice `My PRs 2 •`. VoiceOver: "My PRs, 2 need your action".
5. **Estado vacío:** si una pestaña no tiene PRs accionables se ve su mensaje ("Nothing to review 🎉" / "No PRs of yours need anything"), y debajo, si tiene, su sección colapsada (Other / Waiting for Review), como hoy con "All Caught Up".
6. **El control** se muestra solo cuando hay lista (hay snapshot, una cuenta activa y `gh`); con los mensajes de "Set Up an Account", "GitHub CLI not found", "Offline" o "Loading PRs…" no aparece.
7. **Notificaciones:** hoy ninguna notificación abre el popover (abren GitHub o una ventana). El clic en cualquier notificación de **un** PR (las que tienen `PlannedNotification.prID`) deja elegida la pestaña de ese PR, así la próxima vez que se abra el popover está ahí; la acción de la notificación no cambia. Las agrupadas no tocan la pestaña.
8. **`prbar app popover [--tab]`** elige la pestaña (y la guarda) y abre el popover haciendo clic en el botón de la barra de menú (`NSStatusBarButton.performClick`); si ya está abierto, solo trae la app al frente. Si no encuentra el botón (API privada de AppKit que puede cambiar), igual elige la pestaña y responde `shown: false`; la CLI dice "Selected My PRs. Click PRBar in the menu bar to see it."
9. **`prbar prs --tab`** se combina con `--list`; una sección que no es de esa pestaña es error de uso (`--list mine isn’t in the To Review tab.`). `--list other --tab mine` = Waiting for Review. La columna "Section" de `prbar prs` muestra el título de la sección del popover (`Waiting for Review` en vez de `other` para mis PRs).
10. **Protocolo 4:** `listPRs` lleva la pestaña. Una app vieja ignoraría el filtro sin avisar (devolvería todo), así que se sube la versión. `PRInfo.tab`/`section` y `StatusInfo.tabCounts` son opcionales para leer respuestas viejas.
11. **UserDefaults** `popoverTab` guarda `to-review` o `mine`; un valor desconocido vuelve a To Review. El modo de capturas usa un `UserDefaults` propio (no toca el del usuario).

---

## Estructura de archivos

```
Sources/PRBarCore/
  PopoverTabs.swift          (nuevo) PopoverTab, PopoverSection, PopoverTabs, PopoverTabState, PopoverInfo
  AppCommand.swift           (modificar) listPRs(…, tab:), openPopover(tab:), Name.openPopover
  CommandActions.swift       (modificar) StatusActions.listPRs(…, tab:), openPopover(tab:)
  CommandDispatcher.swift    (modificar) despacho
  CommandProtocol.swift      (modificar) version = 4
  CommandResults.swift       (modificar) PRInfo.tab/section, StatusInfo.tabCounts
Sources/PRBarCLIKit/
  StatusCommands.swift       (modificar) prs --tab, status (totales por pestaña), app popover
  CLISupport.swift           (modificar) PopoverTab: ExpressibleByArgument
  CLIRouter.swift            (modificar) "app popover", ejemplo de prs --tab
Sources/PRBar/
  AppModel.swift             (modificar) popoverTab, popoverWindow, notificación → pestaña
  AppModel+Popover.swift     (nuevo) openPopover, selectTab(forNotificationPR:)
  AppModel+Commands.swift    (modificar) status (tabCounts), listPRs (tab)
  NotificationDelivery.swift (modificar) userInfo["prID"], onSelectPR
  PRBarApp.swift             (modificar) PopoverView(tabs:)
  Popover/PopoverView.swift  (modificar) control segmentado, ⌘1/⌘2, secciones por pestaña, estados vacíos
  Popover/StatusItemPopover.swift (nuevo) abrir el popover desde la CLI
  Popover/WindowAccessor.swift    (nuevo) la ventana del popover (para saber si está abierto)
  Snapshots/SnapshotMode.swift    (modificar) capturas por pestaña
Sources/PRBarTests/
  PopoverTabsTests.swift     (nuevo)
  CLIParsingTests.swift, AppCommandTests.swift, CommandDispatcherTests.swift, CommandProtocolTests.swift,
  CommandResultsTests.swift, FakeActions.swift, UIActionInventory.swift, main.swift (modificar)
docs/cli.md, docs/screenshots/README.md, docs/qa/plan-12-checklist.md, spec (H.4)
```

---

### Task 1: Core — pestañas y secciones (`PopoverTab`, `PopoverSection`, `PopoverTabs`)

**Files:**
- Create: `Sources/PRBarCore/PopoverTabs.swift`
- Test: `Sources/PRBarTests/PopoverTabsTests.swift` (+ `main.swift`)

- [ ] **Step 1: Test que falla.** Crear `Sources/PRBarTests/PopoverTabsTests.swift`:

```swift
import Foundation
import PRBarCore

private func item(_ category: PRCategory, author: String = "ana", account: String = "me", number: Int = 1) -> ClassifiedPR {
    ClassifiedPR(pr: makePR(number: number, author: author), category: category, account: account)
}

private let mixed = Snapshot(items: [
    item(.toReview, number: 1),
    item(.updatedSinceMyReview, number: 2),
    item(.myFeedback, author: "me", number: 3),
    item(.readyToMerge, author: "me", number: 4),
    item(.other, number: 5),
    item(.other, author: "Me", number: 6),
], fetchedAt: t0)

enum PopoverTabsTests {
    static let cases: [TestCase] = [
        TestCase("popover tabs: cada categoría va a su pestaña; Other mío es Waiting for Review") {
            try expectEqual(PopoverTabs.tab(of: item(.toReview)), .toReview)
            try expectEqual(PopoverTabs.tab(of: item(.updatedSinceMyReview)), .toReview)
            try expectEqual(PopoverTabs.tab(of: item(.myFeedback, author: "me")), .mine)
            try expectEqual(PopoverTabs.tab(of: item(.readyToMerge, author: "me")), .mine)
            try expectEqual(PopoverTabs.tab(of: item(.other)), .toReview)
            try expectEqual(PopoverTabs.tab(of: item(.other, author: "ME")), .mine)
            try expectEqual(PopoverTabs.section(of: item(.other)), .otherToReview)
            try expectEqual(PopoverTabs.section(of: item(.other, author: "me")), .waitingForReview)
            try expectEqual(PopoverTabs.section(of: item(.readyToMerge, author: "me")), .readyToMerge)
        },
        TestCase("popover tabs: secciones de cada pestaña, en orden, con las calladas al final") {
            try expectEqual(PopoverTabs.sections(.toReview), [.toReview, .updatedSinceMyReview, .otherToReview])
            try expectEqual(PopoverTabs.sections(.mine), [.myFeedback, .readyToMerge, .waitingForReview])
            try expect(PopoverSection.otherToReview.isQuiet && PopoverSection.waitingForReview.isQuiet)
            try expect(!PopoverSection.readyToMerge.isQuiet)
            try expectEqual(PopoverSection.waitingForReview.title, "Waiting for Review")
            try expectEqual(PopoverSection.otherToReview.title, "Other")
            for section in PopoverSection.allCases { try expect(PopoverTabs.sections(section.tab).contains(section)) }
        },
        TestCase("popover tabs: items por sección") {
            try expectEqual(PopoverTabs.items(.waitingForReview, in: mixed).map(\.pr.number), [6])
            try expectEqual(PopoverTabs.items(.otherToReview, in: mixed).map(\.pr.number), [5])
            try expectEqual(PopoverTabs.items(.myFeedback, in: mixed).map(\.pr.number), [3])
            try expectEqual(PopoverTabs.items(.toReview, in: mixed).map(\.pr.number), [1])
        },
        TestCase("popover tabs: los contadores suman el badge y no cuentan Other ni Waiting") {
            try expectEqual(PopoverTabs.count(.toReview, in: mixed), 2)
            try expectEqual(PopoverTabs.count(.mine, in: mixed), 2)
            try expectEqual(PopoverTabs.count(.toReview, in: mixed) + PopoverTabs.count(.mine, in: mixed), mixed.badgeCount)
            try expectEqual(PopoverTabs.counts(in: mixed), [.toReview: 2, .mine: 2])
            try expectEqual(PopoverTabs.counts(in: nil), [.toReview: 0, .mine: 0])
            let quiet = Snapshot(items: [item(.other, number: 5), item(.other, author: "me", number: 6)], fetchedAt: t0)
            try expectEqual(PopoverTabs.counts(in: quiet), [.toReview: 0, .mine: 0])
        },
        TestCase("popover tabs: estados vacíos y etiquetas del control") {
            try expectEqual(PopoverTabs.emptyState(.toReview).title, "Nothing to review 🎉")
            try expectEqual(PopoverTabs.emptyState(.mine).title, "No PRs of yours need anything")
            try expectEqual(PopoverTabs.label(.mine, count: 2, selected: false), "My PRs 2 •")
            try expectEqual(PopoverTabs.label(.mine, count: 2, selected: true), "My PRs 2")
            try expectEqual(PopoverTabs.label(.toReview, count: 0, selected: false), "To Review 0")
            try expectEqual(PopoverTabs.accessibilityLabel(.mine, count: 1), "My PRs, 1 needs your action")
            try expectEqual(PopoverTabs.accessibilityLabel(.toReview, count: 3), "To Review, 3 need your action")
        },
    ]
}
```

Y en `Sources/PRBarTests/main.swift`, al final de `allTests`: `+ PopoverTabsTests.cases`.

- [ ] **Step 2: Correr y ver que falla.**

Run: `swift build --product PRBarTests 2>&1 | tail -5`
Expected: error de compilación, `cannot find 'PopoverTabs' in scope`.

- [ ] **Step 3: Implementación.** Crear `Sources/PRBarCore/PopoverTabs.swift`:

```swift
import Combine
import Foundation

/// Las dos pestañas del popover (spec H.1). El `rawValue` es el de la CLI (`--tab`) y el de `UserDefaults`.
public enum PopoverTab: String, Codable, CaseIterable, Sendable, Identifiable {
    case toReview = "to-review"
    case mine

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .toReview: "To Review"
        case .mine: "My PRs"
        }
    }
}

/// Una sección del popover. Las de siempre (una por `PRCategory` accionable) más las dos "calladas": Other (PRs
/// ajenos sin nada que hacer) y Waiting for Review (mis PRs sin nada que hacer). Spec H.1.
public enum PopoverSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case toReview
    case updatedSinceMyReview
    case otherToReview = "other"
    case myFeedback
    case readyToMerge
    case waitingForReview = "waiting"

    public var id: String { rawValue }

    public var category: PRCategory {
        switch self {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .otherToReview, .waitingForReview: .other
        case .myFeedback: .myFeedback
        case .readyToMerge: .readyToMerge
        }
    }

    public var tab: PopoverTab {
        switch self {
        case .toReview, .updatedSinceMyReview, .otherToReview: .toReview
        case .myFeedback, .readyToMerge, .waitingForReview: .mine
        }
    }

    public var title: String {
        switch self {
        case .otherToReview: "Other"
        case .waitingForReview: "Waiting for Review"
        default: category.title
        }
    }

    public var subtitle: String? {
        switch self {
        case .otherToReview: "drafts and nothing to do"
        case .waitingForReview: "no new feedback, not ready to merge"
        default: nil
        }
    }

    /// Colapsada al abrir, atenuada y sin contar en el badge ni en el contador de la pestaña.
    public var isQuiet: Bool { self == .otherToReview || self == .waitingForReview }
}

/// Reparto de los PRs del snapshot entre pestañas y secciones. No clasifica: usa la categoría de §7.
public enum PopoverTabs {
    /// El PR es de la cuenta desde la que se ve (sin distinguir mayúsculas, como GitHub).
    public static func isMine(_ item: ClassifiedPR) -> Bool {
        item.pr.author.caseInsensitiveCompare(item.account) == .orderedSame
    }

    public static func section(of item: ClassifiedPR) -> PopoverSection {
        switch item.category {
        case .toReview: .toReview
        case .updatedSinceMyReview: .updatedSinceMyReview
        case .myFeedback: .myFeedback
        case .readyToMerge: .readyToMerge
        case .other: isMine(item) ? .waitingForReview : .otherToReview
        }
    }

    public static func tab(of item: ClassifiedPR) -> PopoverTab { section(of: item).tab }

    /// En el orden en que se muestran: primero las accionables, la callada al final.
    public static func sections(_ tab: PopoverTab) -> [PopoverSection] {
        PopoverSection.allCases.filter { $0.tab == tab }
    }

    public static func items(_ section: PopoverSection, in snapshot: Snapshot) -> [ClassifiedPR] {
        snapshot.items(in: section.category).filter { self.section(of: $0) == section }
    }

    /// PRs accionables de la pestaña (lo que suma el badge).
    public static func count(_ tab: PopoverTab, in snapshot: Snapshot) -> Int {
        snapshot.items.filter { $0.category.countsForBadge && self.tab(of: $0) == tab }.count
    }

    public static func counts(in snapshot: Snapshot?) -> [PopoverTab: Int] {
        Dictionary(uniqueKeysWithValues: PopoverTab.allCases.map { tab in (tab, snapshot.map { count(tab, in: $0) } ?? 0) })
    }

    public static func emptyState(_ tab: PopoverTab) -> (title: String, text: String) {
        switch tab {
        case .toReview: ("Nothing to review 🎉", "No PRs are waiting for your review.")
        case .mine: ("No PRs of yours need anything", "No new feedback and nothing ready to merge.")
        }
    }

    /// Etiqueta del control segmentado: el control nativo ignora colores, así que el "punto de acento" es `•`
    /// (spec H.1: pestaña no elegida con algo pendiente).
    public static func label(_ tab: PopoverTab, count: Int, selected: Bool) -> String {
        "\(tab.title) \(count)" + (!selected && count > 0 ? " •" : "")
    }

    public static func accessibilityLabel(_ tab: PopoverTab, count: Int) -> String {
        "\(tab.title), \(count) \(count == 1 ? "needs" : "need") your action"
    }
}
```

- [ ] **Step 4: Correr y ver que pasa.**

Run: `swift build --product PRBarTests && swift run PRBarTests "popover tabs"`
Expected: `5/5 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/PopoverTabs.swift Sources/PRBarTests/PopoverTabsTests.swift Sources/PRBarTests/main.swift
git commit -m "Split the popover's sections into To Review and My PRs tabs (Core)"
```

---

### Task 2: Core — la pestaña elegida se recuerda (`PopoverTabState`)

**Files:**
- Modify: `Sources/PRBarCore/PopoverTabs.swift`
- Test: `Sources/PRBarTests/PopoverTabsTests.swift`

- [ ] **Step 1: Tests que fallan.** Agregar al final de `PopoverTabsTests.cases`:

```swift
        TestCase("popover tabs: la pestaña elegida se guarda en UserDefaults (popoverTab)") {
            let suite = "prbar-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try await MainActor.run {
                let first = PopoverTabState(defaults: defaults)
                try expectEqual(first.selected, .toReview)
                first.selected = .mine
                try expectEqual(defaults.string(forKey: "popoverTab"), "mine")
                let second = PopoverTabState(defaults: defaults)
                try expectEqual(second.selected, .mine)
            }
        },
        TestCase("popover tabs: un valor guardado desconocido vuelve a To Review") {
            let suite = "prbar-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("everything", forKey: PopoverTabState.defaultsKey)
            try await MainActor.run {
                try expectEqual(PopoverTabState(defaults: defaults).selected, .toReview)
            }
        },
```

- [ ] **Step 2:** `swift build --product PRBarTests 2>&1 | tail -3` → `cannot find 'PopoverTabState' in scope`.

- [ ] **Step 3: Implementación.** Al final de `Sources/PRBarCore/PopoverTabs.swift`:

```swift
/// La pestaña elegida del popover; se recuerda entre aperturas y reinicios (`UserDefaults`, clave `popoverTab`).
/// La cambian el control segmentado, ⌘1/⌘2, `prbar app popover --tab` y el clic en una notificación de un PR.
@MainActor
public final class PopoverTabState: ObservableObject {
    public static let defaultsKey = "popoverTab"

    private let defaults: UserDefaults

    @Published public var selected: PopoverTab {
        didSet { defaults.set(selected.rawValue, forKey: Self.defaultsKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.defaultsKey).flatMap(PopoverTab.init(rawValue:)) ?? .toReview
    }
}
```

- [ ] **Step 4:** `swift build --product PRBarTests && swift run PRBarTests "popover tabs"` → `7/7 passed`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore/PopoverTabs.swift Sources/PRBarTests/PopoverTabsTests.swift
git commit -m "Remember the popover's tab"
```

---

### Task 3: Protocolo — `listPRs(tab:)`, `openPopover`, totales por pestaña (versión 4)

**Files:**
- Modify: `Sources/PRBarCore/PopoverTabs.swift` (`PopoverInfo`), `AppCommand.swift`, `CommandActions.swift`, `CommandDispatcher.swift`, `CommandProtocol.swift`, `CommandResults.swift`
- Modify tests: `Sources/PRBarTests/FakeActions.swift`, `CommandDispatcherTests.swift`, `AppCommandTests.swift`, `CommandProtocolTests.swift`, `CommandResultsTests.swift`

- [ ] **Step 1: Tests que fallan.**

En `CommandDispatcherTests.swift`, en `dispatchSamples`, después de `(.listPRs(list: .mine, account: nil), "listPRs"),` agregar:

```swift
    (.listPRs(list: nil, account: nil, tab: .mine), "listPRs"),
```

y después de `(.quit, "quit"),`:

```swift
    (.openPopover(tab: .mine), "openPopover"),
```

En la función `arguments()` del mismo archivo (`@MainActor private static func arguments()`), antes de `let result = await run(.reviewCancel…`, agregar:

```swift
        _ = await run(.listPRs(list: .other, account: "me", tab: .mine), fake)
        try expectEqual(fake.calls.last, "listPRs other me mine")
        _ = await run(.openPopover(tab: nil), fake)
        try expectEqual(fake.calls.last, "openPopover -")
```

En `AppCommandTests.swift`, agregar un caso:

```swift
        TestCase("app command: listPRs con pestaña y openPopover van y vuelven; un listPRs viejo no trae pestaña") {
            for command: AppCommand in [.listPRs(list: .other, account: nil, tab: .mine), .openPopover(tab: nil), .openPopover(tab: .toReview)] {
                let line = try CommandProtocol.line(CommandRequest(id: 1, command: command))
                let back = try CommandProtocol.decode(CommandRequest.self, line: line)
                try expectEqual(back.command, command)
            }
            let old = try JSONDecoder().decode(AppCommand.self, from: Data(#"{"listPRs":{"list":"mine"}}"#.utf8))
            try expectEqual(old, .listPRs(list: .mine, account: nil, tab: nil))
            try expectEqual(AppCommand.openPopover(tab: nil).name, .openPopover)
        },
```

En `CommandProtocolTests.swift`, si hay una aserción sobre `CommandProtocol.version` (hoy no la hay: los tests usan versiones literales en los mensajes), cambiarla a `4`.

En `CommandResultsTests.swift`, agregar:

```swift
        TestCase("results: PRInfo trae pestaña y sección; StatusInfo viejo se lee sin totales por pestaña") {
            let mine = ClassifiedPR(pr: makePR(number: 6, author: "me"), category: .other, account: "me")
            let info = PRInfo(item: mine, review: nil, respond: nil)
            try expectEqual(info.tab, .mine)
            try expectEqual(info.section, .waitingForReview)
            let old = #"{"appVersion":"1.0.0","refreshing":false,"offline":false,"badgeCount":0,"counts":{},"issues":[],"slackIssues":[],"jobs":[],"accounts":[],"tools":[]}"#
            let status = try CommandProtocol.decoder.decode(StatusInfo.self, from: Data(old.utf8))
            try expectEqual(status.tabCounts, nil)
        },
```

- [ ] **Step 2:** `swift build --product PRBarTests 2>&1 | grep error: | head` → errores (`extra argument 'tab'`, `openPopover`).

- [ ] **Step 3: Implementación.**

`Sources/PRBarCore/PopoverTabs.swift`, al final:

```swift
/// Respuesta de `prbar app popover`.
public struct PopoverInfo: Codable, Equatable, Sendable {
    public var tab: PopoverTab
    /// `false` si no se pudo abrir el popover (la pestaña igual quedó elegida).
    public var shown: Bool

    public init(tab: PopoverTab, shown: Bool) {
        self.tab = tab
        self.shown = shown
    }
}
```

`Sources/PRBarCore/AppCommand.swift`:
- `case listPRs(list: PRListFilter?, account: String?)` → `case listPRs(list: PRListFilter?, account: String?, tab: PopoverTab? = nil)`.
- En "// Ventanas / app", después de `case quit`:

```swift
    /// Abre el popover (spec H.2), en `tab` si viene (y la deja elegida).
    case openPopover(tab: PopoverTab?)
```

- En `Name`, una línea nueva **al final** de la lista de casos: `case openPopover`.
- En `name`: `case .openPopover: .openPopover` (después de `case .quit: .quit`).

`Sources/PRBarCore/CommandActions.swift`, en `StatusActions`:

```swift
    func listPRs(list: PRListFilter?, account: String?, tab: PopoverTab?) throws -> [PRInfo]
```
(reemplaza la de dos parámetros) y, después de `func quit()`:

```swift
    func openPopover(tab: PopoverTab?) -> PopoverInfo
```

`Sources/PRBarCore/CommandDispatcher.swift`:

```swift
        case .listPRs(let list, let account, let tab):
            return try encode(actions.listPRs(list: list, account: account, tab: tab))
```
y en "// Ventanas / app":

```swift
        case .openPopover(let tab):
            return try encode(actions.openPopover(tab: tab))
```

`Sources/PRBarCore/CommandProtocol.swift`: `public static let version = 4` y agregar al comentario de la versión la línea `/// 4: `listPRs` lleva la pestaña del popover (`--tab`) y existe `openPopover`.`

`Sources/PRBarCore/CommandResults.swift`:
- En `PRInfo`, al final de las propiedades:

```swift
    /// Pestaña y sección del popover (spec H). Opcionales: una app con protocolo 3 no las manda.
    public var tab: PopoverTab?
    public var section: PopoverSection?
```
  y al final de su `init(item:review:respond:merge:)`:

```swift
        tab = PopoverTabs.tab(of: item)
        section = PopoverTabs.section(of: item)
```
- En `StatusInfo`, al final de las propiedades:

```swift
    /// PRs accionables por pestaña (`PopoverTab.rawValue`). Opcional: una app vieja no lo manda.
    public var tabCounts: [String: Int]?
```
  agregar el parámetro `tabCounts: [String: Int]? = nil` **al final** del `init` y `self.tabCounts = tabCounts`.

`Sources/PRBarTests/FakeActions.swift`:

```swift
    func listPRs(list: PRListFilter?, account: String?, tab: PopoverTab?) throws -> [PRInfo] {
        try record("listPRs \(list?.rawValue ?? "-") \(account ?? "-") \(tab?.rawValue ?? "-")"); return []
    }
```
(reemplaza la anterior) y después de `quit()`:

```swift
    func openPopover(tab: PopoverTab?) -> PopoverInfo {
        calls.append("openPopover \(tab?.rawValue ?? "-")"); return PopoverInfo(tab: tab ?? .toReview, shown: true)
    }
```

Buscar otros usos con `grep -rn "listPRs(list:" Sources/PRBarTests Sources/PRBar` y agregarles `tab:` solo donde haga falta para compilar (los que construyen el caso no lo necesitan: tiene default). `AppModel.listPRs` se arregla en la Task 5; mientras tanto el producto `PRBar` no compila: está bien, esta task solo construye `PRBarTests`.

- [ ] **Step 4:**

Run: `swift build --product PRBarTests && swift run PRBarTests dispatcher && swift run PRBarTests "app command" && swift run PRBarTests results && swift run PRBarTests protocol`
Expected: todos `passed`. (El test de paridad de la CLI falla hasta la Task 4: `openPopover` no tiene comando.)

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCore Sources/PRBarTests
git commit -m "Add the popover tab to listPRs and an openPopover command (protocol 4)"
```

---

### Task 4: CLI — `prbar prs --tab`, `prbar status` por pestaña, `prbar app popover`

**Files:**
- Modify: `Sources/PRBarCLIKit/StatusCommands.swift`, `CLISupport.swift`, `CLIRouter.swift`
- Modify: `docs/cli.md`
- Test: `Sources/PRBarTests/CLIParsingTests.swift`

- [ ] **Step 1: Tests que fallan.** En `CLIParsingTests`, en "cli parse: prs, refresh, open e historial", agregar:

```swift
                try expectEqual(try parsed(["prs", "--tab", "mine"]), .listPRs(list: nil, account: nil, tab: .mine))
                try expectEqual(try parsed(["prs", "--tab", "to-review", "--list", "other"]), .listPRs(list: .other, account: nil, tab: .toReview))
                try expectEqual(try parsed(["prs", "--tab", "mine", "--list", "ready-to-merge"]), .listPRs(list: .readyToMerge, account: nil, tab: .mine))
                try expect(rejects(["prs", "--tab", "mine", "--list", "to-review"]))
                try expect(rejects(["prs", "--tab", "to-review", "--list", "mine"]))
                try expect(rejects(["prs", "--tab", "everything"]))
```

y en "cli parse: app":

```swift
                try expectEqual(try parsed(["app", "popover"]), .openPopover(tab: nil))
                try expectEqual(try parsed(["app", "popover", "--tab", "mine"]), .openPopover(tab: .mine))
                try expect(rejects(["app", "popover", "--tab", "x"]))
```

- [ ] **Step 2:** `swift build --product PRBarTests && swift run PRBarTests "cli parse"` → falla (`Unknown option '--tab'`, `popover` desconocido).

- [ ] **Step 3: Implementación.**

`Sources/PRBarCLIKit/CLISupport.swift`, junto a las otras conformidades: `extension PopoverTab: ExpressibleByArgument {}`.

`Sources/PRBarCLIKit/StatusCommands.swift`, `PRsCommand` queda:

```swift
struct PRsCommand: RemoteCommand {
    static let configuration = CommandConfiguration(commandName: "prs", abstract: "The PRs in the menu bar.")
    @Option(help: "Only one section: to-review, updated, mine (my PRs with feedback), ready-to-merge or other.") var list: PRListFilter?
    @Option(help: "Only one of the popover’s tabs: to-review or mine (⌘1 / ⌘2). With --list other, mine is Waiting for Review.")
    var tab: PopoverTab?
    @Option(help: "Only this account’s PRs.") var account: String?
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let tab, let list, !PopoverTabs.sections(tab).contains(where: { $0.category == list.category }) {
            throw ValidationError("--list \(list.rawValue) isn’t in the \(tab.title) tab.")
        }
    }

    func appCommand(confirmed: Bool) -> AppCommand { .listPRs(list: list, account: account, tab: tab) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let prs: [PRInfo] = try result.decode()
        guard !prs.isEmpty else { return output.line("No PRs.") }
        output.table(["PR", "Title", "Author", "Section", "CI", "PRBar"], prs.map { pr in
            let prbar = [pr.review.map { "review: \($0)" }, pr.respond.map { "respond: \($0)" },
                         pr.merge.map { "merge: \($0)" }].compactMap { $0 }
            return [pr.id, Render.truncate(pr.title, 50), pr.author, pr.section?.title ?? pr.category, pr.ci,
                    prbar.joined(separator: ", ")]
        })
        for pr in prs {
            if let error = pr.mergeError { output.line(output.paint("! \(pr.id): \(error)", .red)) }
        }
    }
}
```

> Si el Plan 11 cambió el `render` de `PRsCommand`, conservar su versión y cambiar solo `pr.category` → `pr.section?.title ?? pr.category`.

En `StatusCommand.render`, después de `output.line(output.paint(header, .bold))`:

```swift
        if let tabs = status.tabCounts {
            output.line(PopoverTab.allCases.map { "\($0.title) \(tabs[$0.rawValue] ?? 0)" }.joined(separator: " · "))
        }
```

`AppGroup.configuration.subcommands`: agregar `AppPopover.self` después de `AppQuit.self`, y el comando, después de `AppQuit`:

```swift
struct AppPopover: RemoteCommand {
    static let configuration = CommandConfiguration(
        commandName: "popover", abstract: "Show the menu bar popover, optionally on a tab (⌘1 / ⌘2).")
    @Option(help: "to-review or mine. The popover remembers it.") var tab: PopoverTab?
    @OptionGroup var global: GlobalOptions

    func appCommand(confirmed: Bool) -> AppCommand { .openPopover(tab: tab) }

    func render(_ result: JSONValue, _ output: Output) throws {
        let info: PopoverInfo = try result.decode()
        output.line(info.shown ? "Showing \(info.tab.title)."
                               : "Selected \(info.tab.title). Click PRBar in the menu bar to see it.")
    }
}
```

`Sources/PRBarCLIKit/CLIRouter.swift`:
- `.init("prs", [.listPRs], ["prs", "--list", "mine"]),` → `.init("prs", [.listPRs], ["prs", "--list", "mine"], ["prs", "--tab", "to-review"]),`
- después de `.init("app quit", …)`: `.init("app popover", [.openPopover], ["app", "popover", "--tab", "mine"]),`

`docs/cli.md`: en la sección de estado, documentar `prbar prs --tab to-review|mine` (combinable con `--list`; `--list other --tab mine` = Waiting for Review) y que `prbar status` muestra "To Review N · My PRs N"; en la de ventanas/app, `prbar app popover [--tab to-review|mine]` ("abre el popover; si no puede, deja elegida la pestaña"). Mencionar protocolo 4.

- [ ] **Step 4:**

Run: `swift build --product PRBarTests && swift run PRBarTests "cli parse" && swift run PRBarTests paridad`
Expected: `cli parse` pasa. En `paridad`, los de la CLI pasan; "paridad UI" todavía pasa (no cambió la UI).

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBarCLIKit Sources/PRBarTests/CLIParsingTests.swift docs/cli.md
git commit -m "Add prbar prs --tab, tab totals in prbar status and prbar app popover"
```

---

### Task 5: App — estado de la pestaña, comandos y notificaciones

**Files:**
- Create: `Sources/PRBar/AppModel+Popover.swift`, `Sources/PRBar/Popover/StatusItemPopover.swift`, `Sources/PRBar/Popover/WindowAccessor.swift`
- Modify: `Sources/PRBar/AppModel.swift`, `Sources/PRBar/AppModel+Commands.swift`, `Sources/PRBar/NotificationDelivery.swift`

- [ ] **Step 1: `AppModelServices` y `AppModel`.** En `AppModelServices`, al final de las propiedades:

```swift
    /// Dónde se guarda la pestaña del popover (spec H.1). `nil`: `UserDefaults.standard`. El modo de capturas usa uno
    /// propio para no tocar el del usuario.
    var popoverDefaults: UserDefaults? = nil
```

En `AppModel`, junto a las otras propiedades `let`:

```swift
    /// La pestaña elegida del popover (spec H).
    let popoverTab: PopoverTabState
    /// La ventana del popover cuando está en pantalla (la pone `WindowAccessor`): `prbar app popover` no la vuelve a
    /// abrir (un clic en el botón la cerraría).
    weak var popoverWindow: NSWindow?
```

y en `init(services:runner:startsServices:)`, junto a las otras asignaciones (antes de `self.prStore = …`):

```swift
        self.popoverTab = PopoverTabState(defaults: services.popoverDefaults ?? .standard)
```

Después de `notifications?.onOpenUpdate = …`:

```swift
        notifications?.onSelectPR = { [weak self] prID in self?.selectTab(forNotificationPR: prID) }
```

- [ ] **Step 2: `AppModel+Popover.swift`:**

```swift
import AppKit
import PRBarCore

// MARK: - Pestañas del popover (spec H)

extension AppModel {
    /// `prbar app popover [--tab]`: elige la pestaña (si viene) y abre el popover.
    func openPopover(tab: PopoverTab?) -> PopoverInfo {
        if let tab { popoverTab.selected = tab }
        let shown = StatusItemPopover.show(popoverWindow: popoverWindow)
        return PopoverInfo(tab: popoverTab.selected, shown: shown)
    }

    /// Clic en la notificación de un PR: la próxima vez que se abra el popover está en la pestaña de ese PR.
    func selectTab(forNotificationPR prID: String) {
        guard let item = prStore.snapshot?.items.first(where: { $0.id == prID }) else { return }
        popoverTab.selected = PopoverTabs.tab(of: item)
    }
}
```

- [ ] **Step 3: `Popover/StatusItemPopover.swift`:**

```swift
import AppKit
import PRBarCore

/// Abre el popover del `MenuBarExtra` desde código (`prbar app popover`). SwiftUI no tiene una API para eso: se
/// busca el botón de la barra de menú (`NSStatusBarButton`, en la ventana privada `NSStatusBarWindow`) y se le hace
/// clic. Si AppKit cambia y no se encuentra, devuelve `false` y la pestaña queda elegida igual (decisión H.4.8).
@MainActor
enum StatusItemPopover {
    static func show(popoverWindow: NSWindow?) -> Bool {
        if let popoverWindow, popoverWindow.isVisible {
            NSApp.activate()
            popoverWindow.makeKeyAndOrderFront(nil)
            return true
        }
        guard let button = statusButton() else {
            AppLog.write("Couldn't find PRBar’s menu bar button to open the popover.")
            return false
        }
        button.performClick(nil)
        return true
    }

    private static func statusButton() -> NSStatusBarButton? {
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let button = find(in: window.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}
```

- [ ] **Step 4: `Popover/WindowAccessor.swift`** (lo reusa el Plan 13 para saber si el popover está en pantalla):

```swift
import AppKit
import SwiftUI

/// Avisa en qué ventana quedó una vista (y `nil` cuando sale de ella). Se usa de `.background`.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
```

- [ ] **Step 5: Comandos.** En `AppModel+Commands.swift`:
  - `status()`: antes del `return StatusInfo(`:

```swift
        let tabs = PopoverTabs.counts(in: snapshot)
```
    y agregar el argumento final `tabCounts: Dictionary(uniqueKeysWithValues: tabs.map { ($0.key.rawValue, $0.value) })` en la llamada a `StatusInfo(…)`.
  - `listPRs`: firma `func listPRs(list: PRListFilter?, account: String?, tab: PopoverTab?) throws -> [PRInfo]` y, después del filtro de `list`:

```swift
            .filter { item in tab.map { PopoverTabs.tab(of: item) == $0 } ?? true }
```

- [ ] **Step 6: Notificaciones.** En `NotificationDelivery`:
  - propiedad: `/// Clic en una notificación de un PR (antes de su acción): elige la pestaña del popover (spec H.1). var onSelectPR: ((String) -> Void)?`
  - en `deliver`, después de `if let version = notification.updateVersion { … }`: `if let prID = notification.prID { userInfo["prID"] = prID }`
  - en `userNotificationCenter(_:didReceive:…)`, justo después de `let userInfo = response.notification.request.content.userInfo`:

```swift
        if let prID = userInfo["prID"] as? String {
            Task { @MainActor in self.onSelectPR?(prID) }
        }
```

- [ ] **Step 7: Build.**

Run: `swift build --product PRBar 2>&1 | grep -E "error|warning: " | head`
Expected: solo el error de `PopoverView(…)` sin `tabs:` si ya se tocó; si no, sin errores. (La vista se cambia en la Task 6.)

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBar
git commit -m "Keep the popover tab in the app, open the popover from prbar and pick the tab from notifications"
```

---

### Task 6: App — control segmentado, ⌘1/⌘2 y secciones por pestaña

**Files:**
- Modify: `Sources/PRBar/Popover/PopoverView.swift`, `Sources/PRBar/PRBarApp.swift`, `Sources/PRBar/Snapshots/SnapshotMode.swift` (solo la llamada a `PopoverView`)
- Modify: `Sources/PRBarTests/UIActionInventory.swift`

- [ ] **Step 1: Propiedades y `body`.** En `PopoverView`:

```swift
    @ObservedObject var model: AppModel
    @ObservedObject var prStore: PRStore
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var slack: SlackAnnouncer
    @ObservedObject var tabs: PopoverTabState
    @State private var collapsed: Set<PopoverSection> = [.otherToReview, .waitingForReview]
```
(se borra `private let actionable`). `body`:

```swift
    var body: some View {
        VStack(spacing: 0) {
            header
            if showsTabs {
                tabPicker
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            Divider().padding(.bottom, 4)
            content
            UpdateRow(updates: model.updates) { model.openUpdateWindow() }
        }
        .frame(width: Theme.popoverWidth)
        .background(WindowAccessor { window in model.popoverWindow = window })
    }
```

- [ ] **Step 2: El control y los atajos.** Agregar en "// MARK: Header":

```swift
    /// El control solo tiene sentido con la lista de PRs (decisión H.4.6).
    private var showsTabs: Bool {
        prStore.snapshot != nil && configStore.config.accounts.contains(where: \.enabled)
            && !(model.toolsResolved && model.tools.gh == nil)
    }

    private var tabPicker: some View {
        let counts = PopoverTabs.counts(in: prStore.snapshot)
        return Picker("Tab", selection: $tabs.selected) {
            ForEach(PopoverTab.allCases) { tab in
                Text(PopoverTabs.label(tab, count: counts[tab] ?? 0, selected: tab == tabs.selected))
                    .accessibilityLabel(PopoverTabs.accessibilityLabel(tab, count: counts[tab] ?? 0))
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("⌘1 To Review · ⌘2 My PRs")
    }
```

En `keyboardShortcuts`, dentro del `ZStack`, después de "Quit PRBar":

```swift
            Button("To Review") { tabs.selected = .toReview }
                .keyboardShortcut("1", modifiers: .command)
            Button("My PRs") { tabs.selected = .mine }
                .keyboardShortcut("2", modifiers: .command)
```

- [ ] **Step 3: La lista por pestaña.** Reemplazar `list(_:)` y `section(_:items:dimmed:)` por:

```swift
    private func list(_ snapshot: Snapshot) -> some View {
        let tab = tabs.selected
        let sections = PopoverTabs.sections(tab).filter { !PopoverTabs.items($0, in: snapshot).isEmpty }
        let loud = sections.filter { !$0.isQuiet }
        let quiet = sections.filter(\.isQuiet)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.failedCompletely {
                    ErrorBanner(messages: ["Offline. Showing data from \(RelativeAge.short(from: snapshot.fetchedAt)) ago."])
                }
                if !snapshot.issues.isEmpty {
                    IssuesBanner(groups: snapshot.issuesByAccount)
                }
                if !slack.issues.isEmpty {
                    IssuesBanner(groups: [(account: "Slack", issues: slack.issues)])
                }
                if loud.isEmpty {
                    let empty = PopoverTabs.emptyState(tab)
                    MessageView(icon: "checkmark.seal", iconColor: Theme.green, title: empty.title, text: empty.text)
                }
                ForEach(loud) { section in
                    self.section(section, items: PopoverTabs.items(section, in: snapshot))
                }
                ForEach(quiet) { section in
                    Divider().padding(.vertical, 4)
                    self.section(section, items: PopoverTabs.items(section, in: snapshot))
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: Theme.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func section(_ section: PopoverSection, items: [ClassifiedPR]) -> some View {
        SectionHeader(
            title: section.title,
            subtitle: section.subtitle,
            count: items.count,
            collapsed: collapsed.contains(section),
            dimmed: section.isQuiet
        ) {
            if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        }
        if !collapsed.contains(section) {
            ForEach(items) { item in
                PRRowView(item: item, dimmed: section.isQuiet, model: model, reviews: model.reviews, respond: model.respond,
                          merges: model.merges, updateSession: model.updates.session)
            }
        }
    }
```

> Si el Plan 11 cambió los argumentos de `PRRowView(…)`, copiar la llamada tal como quedó en `main` y cambiar solo `dimmed:`.

- [ ] **Step 4: Llamadas.** `PRBarApp.swift`: `PopoverView(model: model, prStore: model.prStore, configStore: model.configStore, slack: model.slack, tabs: model.popoverTab)`. Igual en `SnapshotMode.popover(_:model:)`.

- [ ] **Step 5: Build.**

Run: `swift build --product PRBar 2>&1 | grep -E "error|warning: " | head`
Expected: nada.

- [ ] **Step 6: Inventario de UI.** Correr `swift build --product PRBarTests && swift run PRBarTests "paridad UI"`. Espera "NUEVO, sin entrada" para el `Picker "Tab"`, los botones "To Review" y "My PRs" y `Component:WindowAccessor`. Agregar en el bloque "// Popover" de `UIActionInventory.entries`:

```swift
        .init("Popover/PopoverView.swift", "Picker", "Tab", 1, .cli(["app popover", "prs"])),   // --tab
        .init("Popover/PopoverView.swift", "Button", "To Review", 1, .cli(["app popover"])),   // ⌘1
        .init("Popover/PopoverView.swift", "Button", "My PRs", 1, .cli(["app popover"])),   // ⌘2
        .init("Popover/PopoverView.swift", "Component:WindowAccessor", "-", 1, .viewOnly("tracks the popover’s window")),
```

y, si el escáner lo pide, la de `Popover/WindowAccessor.swift` que reporte (p. ej. un `Component` interno): usar `.viewOnly(generic)`. Si el conteo de `Component:SectionHeader` cambió (ahora hay una sola llamada a `SectionHeader`, igual que antes), dejar el número que diga el test.

Run: `swift run PRBarTests paridad`
Expected: todo `passed`.

- [ ] **Step 7: Suite completa.**

Run: `swift run PRBarTests`
Expected: `N/N passed`.

- [ ] **Step 8: Commit.**

```bash
git add Sources/PRBar Sources/PRBarTests/UIActionInventory.swift
git commit -m "Show To Review and My PRs as tabs in the popover"
```

---

### Task 7: Capturas — popover en cada pestaña y estados vacíos

**Files:**
- Modify: `Sources/PRBar/Snapshots/SnapshotMode.swift`
- Modify: `docs/screenshots/README.md` y `docs/screenshots/*.png`

- [ ] **Step 1: Defaults propios en `makeModel`.** En `SnapshotMode.makeModel(_:snapshot:)`, antes de `let services = AppModelServices(`:

```swift
        // La pestaña del popover vive en UserDefaults: un dominio propio por modelo, vacío, para no tocar el del usuario.
        let defaultsSuite = "PRBar.snapshots.\(name)"
        let popoverDefaults = UserDefaults(suiteName: defaultsSuite)!
        popoverDefaults.removePersistentDomain(forName: defaultsSuite)
```

y pasar `popoverDefaults: popoverDefaults` como último argumento de `AppModelServices(…)`.

- [ ] **Step 2: Capturas.** En `renderAll()`, reemplazar las dos llamadas al popover por:

```swift
        try await popover("popover", model: main)
        main.popoverTab.selected = .mine
        try await popover("popover-mine", model: main)
        main.popoverTab.selected = .toReview
        main.reviews.cancelAll()

        let empty = try makeModel("empty", snapshot: fixtures.caughtUpSnapshot)
        try await popover("popover-empty", model: empty)
        empty.popoverTab.selected = .mine
        try await popover("popover-empty-mine", model: empty)
```

(la línea `main.reviews.cancelAll()` que ya estaba va después de las dos capturas de `main`).

- [ ] **Step 3: Generar y mirar.**

Run: `swift build --product PRBar && Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both`
Expected: la lista incluye `popover-mine-{light,dark}.png` y `popover-empty-mine-{light,dark}.png`. Abrir con Read:
- `popover-light.png`: el control "To Review 3 | My PRs 3 •" debajo de la cabecera, To Review elegido; secciones To Review y Updated Since My Review; "Other 1" colapsada al final (mobile#96).
- `popover-mine-light.png`: "My PRs" elegido y "To Review 3 •"; My PRs with Feedback (csv export), Ready to Merge (2) y "Waiting for Review 1" colapsada (api#309).
- `popover-empty-light.png`: "Nothing to review 🎉" y "Other 1" colapsada; `popover-empty-mine-light.png`: "No PRs of yours need anything" y "Waiting for Review 1".
- Las versiones `-dark` igual. Nada cortado (el `•` entra en el segmento).

> Los números dependen de los fixtures que haya dejado el Plan 11; verificar que N de cada pestaña coincide con lo que se ve.

- [ ] **Step 4: Capturas del repo.** En `docs/screenshots/README.md`: la fila de `popover` dice "To Review tab (…)"; agregar después:

```markdown
| `popover-mine` | The My PRs tab: My PRs with Feedback, Ready to Merge and Waiting for Review (collapsed) |
| `popover-empty-mine` | The My PRs tab with nothing to do |
```

Run: `Scripts/snapshots.sh docs/screenshots both`, después `git status docs/screenshots` y `git checkout --` de los PNG ajenos que solo cambiaron bytes (mirar con Read antes de decidir).

- [ ] **Step 5: Commit.**

```bash
git add Sources/PRBar/Snapshots/SnapshotMode.swift docs/screenshots
git commit -m "Capture the popover's two tabs and their empty states"
```

---

### Task 8: Spec H.4, QA y verificación final

**Files:**
- Modify: `docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md`
- Create: `docs/qa/plan-12-checklist.md`

- [ ] **Step 1: Spec.** La parte H tiene que estar en el spec principal (la integra otro agente). Si está, agregar después de H.3 la sección `### H.4 Decisiones de implementación (Plan 12)` con las 11 decisiones de "Decisiones donde el spec era ambiguo" de este plan, tal como están. Si la parte H todavía no está, **no** inventarla: dejar el Step pendiente y avisarlo en el resumen del trabajo.

- [ ] **Step 2: Checklist.** Crear `docs/qa/plan-12-checklist.md`:

```markdown
# QA manual — Plan 12 (pestañas del popover)

Con PRBar instalada (`Scripts/bundle.sh --install`) y al menos una cuenta con PRs para revisar y PRs propios.

## A. Control y contenido
- [ ] Debajo de la cabecera hay un control segmentado "To Review N | My PRs N"; los N coinciden con lo que se ve en cada pestaña y su suma es el número del ícono de la barra.
- [ ] To Review muestra To Review, Updated Since My Review y "Other" colapsada al final; My PRs muestra My PRs with Feedback, Ready to Merge y "Waiting for Review" colapsada.
- [ ] Un PR tuyo abierto, sin feedback nuevo y sin aprobar aparece en Waiting for Review (no en Other).
- [ ] Un PR draft ajeno aparece en Other de To Review.
- [ ] Con algo pendiente en la pestaña no elegida, su etiqueta termina en "•"; al elegirla, el punto desaparece.
- [ ] Sin nada para revisar: "Nothing to review 🎉" (y Other debajo si hay). Sin nada en mis PRs: "No PRs of yours need anything".
- [ ] Sin cuenta configurada, sin `gh` u offline sin datos: el control no aparece.
- [ ] VoiceOver lee "My PRs, 2 need your action".

## B. Recordar y teclado
- [ ] Elegir My PRs, cerrar y abrir el popover: sigue en My PRs. Salir de PRBar y volver a abrirla: sigue en My PRs (`defaults read <bundle id> popoverTab` dice `mine`).
- [ ] Con el popover abierto, ⌘1 va a To Review y ⌘2 a My PRs.
- [ ] Colapsar/expandir Other y Waiting for Review funciona en cada pestaña.

## C. Notificaciones
- [ ] Con To Review elegida, hacer clic en una notificación de un PR propio (p. ej. "ready to merge" o "Responder"): hace lo de siempre (abre la ventana o GitHub) y, al abrir el popover, está en My PRs.
- [ ] Una notificación agrupada ("3 PRs to review") no cambia la pestaña.

## D. CLI (con `PRBAR_SOCKET` de la PRBar instalada; nunca contra otra)
- [ ] `prbar prs --tab mine` lista solo mis PRs; la columna Section dice "Waiting for Review" para los que esperan review.
- [ ] `prbar prs --tab to-review --list mine` sale con error de uso ("--list mine isn’t in the To Review tab.").
- [ ] `prbar status` muestra "To Review N · My PRs N".
- [ ] `prbar app popover --tab mine` abre el popover en My PRs. Con el popover ya abierto, no lo cierra.
- [ ] `prbar` de antes de este plan contra la app nueva (o al revés) dice que hay que actualizar (protocolo 4).

## E. Capturas
- [ ] `Scripts/snapshots.sh "$TMPDIR/s" both` incluye `popover-mine-*` y `popover-empty-mine-*`, sin textos cortados.
```

- [ ] **Step 3: Verificación final.**

Run: `swift build --product PRBar && swift build --product PRBarCLI && swift build --product PRBarTests && swift run PRBarTests`
Expected: los tres builds sin warnings nuevos; `N/N passed` (los de antes + 11 nuevos: 7 de `PopoverTabsTests`, 1 de `AppCommandTests`, 1 de `CommandResultsTests` y las aserciones nuevas en tests existentes).

- [ ] **Step 4: Commit.**

```bash
git add docs/superpowers/specs/2026-11-19-prbar-chat-cli-updates-design.md docs/qa/plan-12-checklist.md
git commit -m "docs: popover tabs implementation decisions and QA checklist"
```

---

## Self-review

- **Cobertura del spec:** H.1 control segmentado (Task 6), contenido de cada pestaña y secciones colapsadas (Tasks 1 y 6), secciones vacías ocultas (Task 6, `filter`), estado vacío propio (Tasks 1 y 6), `UserDefaults` `popoverTab` (Task 2), ⌘1/⌘2 (Task 6), badge sin cambios (no se toca `MenuBarLabel`; test de la suma en Task 1), notificaciones (Task 5). H.2 `prs --tab`, `status` por pestaña, `app popover --tab`, inventario (Tasks 3, 4, 6). H.3 tests de asignación, contadores y vacíos (Tasks 1–2), capturas por pestaña claro/oscuro y vacías (Task 7).
- **Placeholders:** ninguno; los "si el Plan 11 cambió…" dicen exactamente qué conservar.
- **Tipos:** `PopoverTab`, `PopoverSection`, `PopoverTabs`, `PopoverTabState`, `PopoverInfo` (Tasks 1–3) se usan con esos nombres en Tasks 4–7. `AppModel.popoverTab`/`popoverWindow` (Task 5) en Tasks 6–7. `WindowAccessor` (Task 5) lo reusa el Plan 13.
