# PRBar para Mac: una sola ventana (Mac v2)

Fecha: 2026-11-22. Diseño visual: proyecto de Claude Design "PRBar", archivo `PRBar Mac v2.dc.html` (importa `MacMain`,
`MacReview`, `MacRespond`, `MacMerge`, `MacHistory`, `MacActivity`, `MacPopover`, `NavDiagram`). Las medidas, colores,
textos y estados de este spec salen de ahí; si algo no está acá, manda el boceto. Plan: `2026-11-22-prbar-plan-21-mac-main-window.md`.

## Decisiones del usuario (2026-11-22, no se reabren)

1. PRBar sigue en la barra de menú y suma **una ventana principal** con barra lateral. Las ventanas sueltas de Review,
   Respond/Fix CI, Merge, History, Activity y Update desaparecen: su contenido vive en la ventana principal.
2. Alcance: **todo el diseño menos Handoff** (la app del iPhone es una web y Handoff necesita una app nativa).
3. Las decisiones del boceto se toman como están: Settings sigue como ventana aparte (⌘,); ícono en el Dock solo mientras
   la ventana principal (o una ventana de PR) está abierta, con la opción "Always show in Dock"; una sola ventana
   principal más ventanas de PR opcionales (⇧⌘O); cada notificación abre el PR en la pestaña de esa acción.
4. Se reusan los componentes actuales (filas de PR, pills, tarjetas de findings, secciones de Merge, tiles de Activity,
   chat, diff). Se reorganiza la navegación; cada pantalla se ajusta al boceto pero no se reescribe desde cero.

---

## M.1 Estructura de la ventana principal

- `NavigationSplitView` de tres columnas: **barra lateral** (236 pt, vidrio), **lista** (32 % del ancho, entre 280 y
  340 pt) y **detalle**. Toolbar unificada de 52 pt: botón de barra lateral, título + subtítulo (columna de 220 pt),
  pestañas centradas (segmentado de vidrio), grupo de botones Refresh · Open in New Window · Open on GitHub, y búsqueda
  (170 pt, "Search ⌘F").
- Tamaño por defecto 1280×800, **mínimo 960×600**. Se guarda el frame (`autosaveName: "MainWindow"`).
- Una sola instancia (`WindowPresenter` id `"main"`). Cerrarla (⌘W) deja PRBar en la barra de menú; no cancela nada.
- Modo claro y oscuro con los colores del sistema; los acentos del boceto (`--accent #2D4EFF`, violeta para Claude,
  verde/naranja/rojo de estado) salen de `Theme.swift`, que ya los tiene o los suma.

### Barra lateral

| Grupo | Filas | Notas |
|---|---|---|
| Pull Requests | To Review (`tray`, ⌘1) · My PRs (`prbar`, ⌘2) | Contador a la derecha cuando hay datos. |
| `Claude · N running` | Una fila por PR con tarea de Claude: `repo#N` + subtítulo de etapa y tiempo ("Reviewing · 1:12", "Fix CI · ready to push", "Review ready · 4 findings") | Spinner violeta mientras corre, check verde cuando está lista. Ícono de iPhone si la tarea la pidió el iPhone. El grupo no aparece si no hay tareas. Tocar la fila abre ese PR en la pestaña de la tarea. |
| (sin título) | History (`clock.arrow.circlepath`, ⌘3) · Activity (`gauge`, ⌘4) | |
| Pie | Aviso de actualización (si hay: "PRBar X available · What's new · Install", abre la hoja de Update) · fila del iPhone (nombre del dispositivo y punto verde si está en línea; solo si hay uno vinculado) · engranaje (Settings) | |

"Tarea lista" = una review lista sin publicar, un Respond o Fix CI terminado sin pushear. Sale de la lista cuando se
publica, se pushea o se descarta.

### Lista

- To Review: secciones **To Review** y **Updated Since My Review**. My PRs: **With Feedback**, **CI Failing**,
  **Ready to Merge**, **Waiting for Review**. Secciones plegables con contador; las vacías quedan plegadas.
- Fila (de `PRRowView`, versión ancha): avatar con iniciales (PR ajeno) o ícono de estado (PR propio), título en dos
  líneas, edad, `repo#N · base`, CI + `+adds −dels`, y el **pill** de acción a la derecha (Review, N findings, Queued,
  Reviewing…, Responding…, Ready to push, Merge…). Fila seleccionada: fondo acento, texto blanco.
- ↑ ↓ mueven la selección; ↩ ejecuta la acción del pill; doble clic abre el PR en una ventana aparte.
- Vacío: "All caught up" con el sello verde y "N drafts hidden · Show in Settings" si aplica. Cargando: cinco filas
  esqueleto y spinner en Refresh. Sin selección, el detalle dice "No PR Selected / Pick a PR from the list, or press ↓ to
  select the first one." con la línea de atajos.
- **Búsqueda** (⌘F): filtra la lista actual por título, `repo#N`, autor y rama, sin distinguir mayúsculas ni acentos. En
  History filtra la lista de History.

### Detalle del PR: pestañas

| PR | Pestañas (⌥⌘1…) | Pestaña inicial |
|---|---|---|
| De otra persona | Review · Details | Review |
| Propio | Merge · Respond · Fix CI | cambios pedidos → Respond; CI roto → Fix CI; si no, Merge |

- Respond y Fix CI quedan **deshabilitadas** si no hay nada que responder / ningún check fallando, salvo que ya tengan
  una tarea (entonces siempre están habilitadas).
- Indicadores en la pestaña: spinner violeta mientras Claude trabaja, punto verde si hay algo listo.
- La pestaña elegida se recuerda por PR mientras la app está abierta. Cambiar de PR y volver la mantiene.
- **Review**: cabecera (`owner/repo #N`, Open on GitHub, título 20 pt, autor, ramas, `+/−`, archivos), resumen de Claude
  (caja violeta con agentes · tiempo · costo), "Findings · N of M included" con All/None, tarjetas de findings
  (checkbox, severidad, archivo, texto, "Show full comment" que despliega el comentario editable), "Discarded by the
  filter (N)" plegado, y barra inferior: comentario general, decisión (Approve / Comment / Request Changes) y
  **Post Review ⌘↩**. Antes de que haya review: el estado del PR y **Start Review** (o el progreso si está corriendo o en
  cola). Después de publicada: la review publicada (como hoy).
- **Details**: las secciones de Merge en solo lectura (descripción, reviews, checks, conversaciones, archivos), sin el
  bloque de merge.
- **Merge**: dos columnas. Izquierda: Description, Conversations, Files changed. Derecha (240 pt): Reviews, Checks
  ("Show N more"), y el bloque de merge (método Squash/Merge/Rebase con la nota de qué hace, "Delete branch after merge",
  "Post in #canal" si hay Slack, botón **Squash and Merge ⇧⌘M**). Badge de estado arriba a la derecha.
- **Respond / Fix CI**: cabecera con estado (cambios pedidos por X / N checks fallaron), tarjeta de progreso (título,
  worktree, tiempo · costo, y tres etapas: Analyzing · Implementing · Running tests, cada una con subtítulo y tiempo),
  en Fix CI la lista de checks "falla en GitHub → pasa local", segmentado **Diff · Tests · Log** con chips de archivos,
  el diff (con "Claude is editing" mientras escribe) y barra inferior: Undo, Stop ⌘. (corriendo) o Discard, texto de
  ayuda, y **Push & Reply** / **Push** ⌘↩ (habilitado cuando pasan los tests). Sin tarea: qué hay para responder o qué
  checks fallan y el botón **Start** (Respond / Fix CI).

### Modo foco y chat

- El chat es un **inspector** de 300 pt a la derecha del detalle (⌥⌘I lo muestra u oculta). Tiene el feedback del PR, los
  mensajes y las tarjetas de cambios de Claude con Undo, como el `ChatPanel` actual.
- Mientras Claude trabaja en Respond o Fix CI del PR seleccionado, la vista entra en **modo foco**: se oculta la lista y
  se abre el chat. Al terminar vuelve la lista y el chat se cierra (salvo que el usuario lo haya abierto o cerrado a mano
  durante la tarea: entonces se respeta su elección).
- Review y Merge también tienen chat (como hoy), en el mismo inspector, cerrado por defecto.

### History y Activity

- **History**: la lista de History reemplaza la de PRs, agrupada por día (Today, Yesterday, fecha), con chip de tipo
  (Review violeta, Respond naranja, Fix CI rojo, Merge acento), `repo#N`, hora, ícono de iPhone si se hizo desde el
  teléfono, título y resultado. Pestañas de la toolbar: All · Reviews · Responds · Merges. El detalle es el de hoy
  (`HistoryDetailView`, `RespondHistoryDetailView`, `MergeHistoryDetailView`) con la cabecera del boceto y la barra
  inferior View Claude Log · Open on GitHub.
- **Activity**: vista completa, sin lista. Cuatro tiles (CPU, Memory, Disk, Claude), tabla **Claude tasks** (tarea, PR,
  worktree, tiempo, costo, Stop o estado), caja **Claude this month** (total estimado, barra y desglose Reviews · Fixes ·
  Chat) y tabla **Worktrees** con Clean Up Finished y Clean Up por fila. Todo sale de lo que hoy muestra
  `ActivityWindow`.

## M.2 Ventanas fuera de la principal

- **Ventana de PR** (⇧⌘O, doble clic en una fila, botón de la toolbar): solo el detalle del PR, sin barra lateral ni
  lista, con sus pestañas y su chat. Una por PR (id `pr-<prID>`), agrupables como pestañas nativas
  (`tabbingIdentifier: "PRBar.pr"`). Abrir un PR que ya tiene ventana la trae al frente.
- **Settings**: igual que hoy (ventana aparte, ⌘,). En General se suma **Always show in Dock** (apagado por defecto).
- **Update**: deja de ser ventana; es una **hoja** sobre la ventana principal (abre la ventana si estaba cerrada) con el
  contenido de hoy de `UpdateWindow`.

## M.3 Popover

Mismas filas y pills. Cambios:

- Cabecera: "PRBar · updated N min ago" y botones Open PRBar window (`macwindow`), Refresh, Settings.
- Selector To Review · N / My PRs · N (como hoy).
- **Franja de Claude** (si hay tareas): "Claude · N running · M ready ›", lleva al primer PR con tarea.
- Tocar una fila abre o enfoca la ventana principal en ese PR; tocar el pill abre la pestaña de esa acción y, si la
  acción es iniciar algo (Review, Start Fix CI…), además la inicia, como hoy.
- Pie: línea de recursos (CPU · RAM · worktrees · costo del mes) que abre Activity; aviso de actualización con botón
  Update; **Open PRBar ⌘0**; **Settings… ⌘,**.
- El popover se cierra al abrir la ventana.

## M.4 Navegación y rutas

Un solo destino tipado describe a dónde ir:

```swift
enum MainDestination: Hashable {
    case list(MainSection)                // .toReview, .myPRs
    case pr(prID: String, tab: PRTab?)    // tab nil = pestaña inicial según estado
    case history(recordID: UUID?)
    case activity
}
enum PRTab: String { case review, details, merge, respond, fixCI }
```

- `AppModel.navigate(to:)` abre o enfoca la ventana principal, cierra el popover, selecciona la sección y el PR y elige
  la pestaña. Empuja el lugar anterior en una pila de **Back** (⌘[ y el botón de la toolbar, hasta 20 lugares).
- Las funciones de hoy (`openReview`, `openRespond`, `openMerge`/`openMergeWindow`, `openHistory`, `openActivityWindow`,
  `openUpdateWindow`) quedan como envoltorios de `navigate(to:)` para no tocar los comandos (`prbar`, CLI, iPhone).
- **Notificaciones → destino**: review listo → `.pr(tab: .review)`; nuevo PR para revisar → `.pr(tab: .review)`;
  cambios pedidos → `.respond`; CI roto → `.fixCI`; Claude terminó Respond/Fix CI → esa pestaña; listo para mergear →
  `.merge`; actualización → hoja de Update.
- **Pedidos del iPhone** no navegan ni roban el foco en la Mac: la tarea aparece en el grupo Claude con el ícono de
  iPhone. Para eso cada tarea guarda su `CommandOrigin` al empezar.
- **Links `prbar://`** (`CFBundleURLTypes`): `prbar://pr/<owner>/<repo>/<number>[/<tab>]`, `prbar://review`,
  `prbar://mine`, `prbar://history`, `prbar://activity`. Uno que no se entiende abre la ventana sin moverse.
- La lógica pura (pestañas disponibles e inicial según el PR, notificación → destino, parseo de `prbar://`, filas del
  grupo Claude, pila de Back, filtro de búsqueda) vive en `PRBarCore` y se prueba con `PRBarTests`.

## M.5 Dock y activación

- La app pasa a `.regular` mientras haya una ventana principal o de PR abierta (también Settings, como hoy), y vuelve a
  `.accessory` al cerrarse la última, salvo con **Always show in Dock**: entonces queda siempre `.regular`.
- Clic en el ícono del Dock sin ventanas abiertas (`applicationShouldHandleReopen`) abre la ventana principal.
- Se mantiene lo de `WindowSpaces`: abrir desde la barra de menú sobre una app en pantalla completa no cambia de Space.

## M.6 Atajos (menú de la app)

| Atajo | Acción |
|---|---|
| ⌘0 | Abrir o enfocar la ventana principal (también en el popover) |
| ⌘1 · ⌘2 · ⌘3 · ⌘4 | To Review · My PRs · History · Activity |
| ⌥⌘1–3 | Pestañas del PR |
| ↑ ↓ · ↩ | Moverse por la lista · acción del pill |
| ⌘↩ | Post Review · Push · Push & Reply (según la pestaña) |
| ⇧⌘M | Merge |
| ⌘. | Detener a Claude |
| ⌘Z | Deshacer el último cambio de Claude (solo si el foco no está en un campo de texto: ahí es el deshacer del texto) |
| ⌥⌘I | Mostrar u ocultar el chat |
| ⌃⌘S | Mostrar u ocultar la barra lateral |
| ⇧⌘O | Abrir el PR en una ventana nueva |
| ⌘R · ⌘F | Refrescar · buscar |
| ⌘[ | Volver |
| ⌘, | Settings |

En el chat, ⌘↩ sigue enviando el mensaje (la acción de la pestaña no se dispara mientras el foco está en el chat).
History pasa de ⌘Y a ⌘3; ⌘Y deja de usarse.

## M.7 Lo que no cambia

- La lógica de reviews, respond, fix CI, merge, cola de trabajos, worktrees, Slack, acceso remoto e historial.
- Settings (salvo el interruptor nuevo), la CLI (`prbar`), el protocolo del iPhone y la web app.
- La confirmación al salir con trabajo en curso o sin pushear, y la de cerrar una review con cambios sin publicar (ahora
  al cambiar de PR o cerrar la ventana con una review editada a medias se conserva lo elegido, como hoy, porque vive en
  el coordinador del draft).

## M.8 Pruebas

- `PRBarTests`: la lógica de M.4 (pestañas, destinos, `prbar://`, grupo Claude, Back, búsqueda) y el Dock (política de
  activación según ventanas abiertas y el interruptor).
- Snapshots (`SnapshotMode`): la ventana principal en los ocho estados del boceto (lista y Review, Respond en modo foco,
  Fix CI listo, Merge, History, Activity, vacío a 960×600, cargando) en claro y oscuro, y el popover nuevo. Se comparan a
  ojo con el boceto.
- QA a mano (`docs/qa/plan-21-checklist.md`): notificaciones de cada tipo, ⌘W y ⌘Q con tareas, Dock con y sin el
  interruptor, pantalla completa, ventana de PR y pestañas nativas, todos los atajos, VoiceOver en barra lateral, lista y
  pestañas.

## M.9 Decisiones de implementación (Plan 21)

Las del plan (`docs/superpowers/plans/2026-11-22-prbar-plan-21-mac-main-window.md`) y las que salieron al implementar.

**Bocetos.** No se pudieron bajar al repo (Task 0): no había herramienta para el proyecto de Claude Design. Se siguió
este spec; donde el spec no decía algo, se eligió lo más parecido al resto de la app y quedó anotado en el plan.

**Estructura**

1. Dos columnas nativas (barra lateral | contenido) y la lista propia dentro del contenido, en vez de tres columnas de
   `NavigationSplitView`: así Activity ocupa todo el ancho y el modo foco oculta solo la lista. Se ve igual que tres
   columnas.
2. El chat no es un `.inspector` dentro del detalle (desarmaba el layout): en la ventana principal se aplica a toda la
   columna de contenido (queda a la derecha de lista + detalle; con el chat abierto la lista toma su mínimo). En la
   ventana de PR va al lado del detalle en un `HStack` de 300 pt, porque un `.inspector` sin `NavigationSplitView`
   dejaba la cabecera del pane debajo de la toolbar.
3. Las pestañas del PR van en `.principal` y quedan centradas en la columna de contenido (no en la ventana entera).
   History pone ahí sus filtros All · Reviews · Responds · Merges (`HistoryFilterBar`, con el mismo aspecto que las
   pestañas: un `Picker` segmentado en la toolbar no mostraba la opción elegida).

**Lista y pestañas**

4. "CI Failing" no existía como sección: son los PRs míos de categoría `.other` con CI roto. Un PR con feedback y CI
   roto queda en With Feedback.
5. To Review suma la sección callada "Other" (plegada), como el popover. El aviso del vacío dice "N drafts hidden ·
   Show" y despliega "Other" (no hay ajuste de borradores al que mandar).
6. Pestaña inicial con una tarea abierta pero sin feedback ni CI roto: la de la tarea.
7. Details muestra en el chat la review del PR (si hay); sin review, un texto.
8. Back guarda los lugares a los que se llegó con `navigate(to:)` (barra lateral, ⌘1–4, notificaciones, links, pills);
   moverse con ↑ ↓ no llena la pila.

**Panes**

9. Merge: "Delete branch after merge" (o "Branch is kept after merge") y "Post in #canal" son filas informativas (el
   ajuste del repo y el aviso de Slack): hacerlos interruptores cambiaría la lógica de merge. Merge pasa de ⌘↩ a ⇧⌘M
   (del menú; el botón ya no tiene atajo propio). Debajo de 600 pt de ancho el detalle pasa a una columna.
10. Respond / Fix CI: "Claude is editing" muestra el progreso (fix i de n), no un diff en vivo. Los checks de Fix CI
    dicen "Fails on GitHub → passes/fails locally" con el resultado de los tests locales de la corrida. Push y Push &
    Reply siguen la regla de hoy (`RespondPushGate`). El modo foco no se apaga al desaparecer el pane (el orden contra
    el PR siguiente no está garantizado): lo pone el PR nuevo.
11. History: se fue el `Picker` de repo (la búsqueda lo cubre). Navegar a un registro que el filtro o la búsqueda
    esconden los limpia. Sin registro elegido, se elige el primero. `prbar://history/<uuid>` no se implementa.
12. Activity: tiles · Claude tasks · Claude this month · Worktrees · Recent tasks · Disk. Clean Up por fila solo en
    los worktrees terminados.
13. "Install" en la barra lateral abre la hoja de Update (donde está la política con trabajos en curso), no instala
    directo.

**Popover, menús y atajos**

14. El menú ⚙︎ del popover desaparece (Settings es un botón). Por pedido del usuario el pie conserva "Quit PRBar ⌘Q"
    junto a Open PRBar ⌘0 y Settings… ⌘,.
15. ⌘↩ no está en el menú (lo tomaría antes que el chat); está en Help › Keyboard Shortcuts. ⌘Z es un ítem propio de
    Edit que decide entre el deshacer del texto y "Undo Claude’s Change".
16. El menú Pull Request suma "Open on GitHub" además de lo de M.6; ⌥⌘1–3 llevan el nombre de cada pestaña y marcan la
    elegida. Los botones Stop conservan su ⌘. (el menú, si está habilitado, lo atiende antes).
17. Búsqueda: el campo está en To Review, My PRs y History (en Activity no). SwiftUI no deja fijar su ancho: se le pone
    170 pt al `NSSearchToolbarItem` que crea `.searchable`, y ⌘F (View › Find) usa ese mismo ítem. Buscando, la lista
    muestra solo las secciones con resultados, desplegadas; sin resultados, "No Results". En History busca por título
    y repo/número (los registros no guardan autor ni rama).

**Links, Dock e iPhone**

18. `prbar://` entiende, además de `/<tab>`, el `?screen=` de los links del iPhone. Un link que no se entiende abre la
    ventana sin moverse y el log no guarda el link (puede tener nombres de repos privados).
19. "Always show in Dock" tiene su comando (`prbar config set always-show-in-dock on|off`, regla de paridad),
    denegado al teléfono.

**Limpieza**

20. Se borraron las ventanas viejas y lo que solo ellas usaban: la confirmación de cambios sin guardar de
    `WindowPresenter` (lo editado de una review vive en el coordinador del draft), el agrandado de la ventana al abrir
    el chat (`InspectorSizing`) y `respondWindowTitle`. `MergeWindowModel` pasó a `MergeDetailModel`;
    `UpdateWindowMode` conserva su nombre. Las claves de frame viejas en `UserDefaults` quedan (no molestan).
21. Capturas: la hoja de Update se dibuja encima del contenido (la hoja de una ventana fuera de pantalla no sale) y
    `main-loading` muestra las filas esqueleto sin el spinner de Refresh (el modo de capturas no arranca un refresh).
    Fuera de pantalla el campo de búsqueda no dibuja su fondo, así que su ancho no se ve en las capturas. Los PNG de
    `docs/screenshots` no se regeneraron en el plan 21 (siguen siendo los de las ventanas viejas).
22. Los textos de la CLI, Settings › Claude ("Chat with Claude in the Review, Respond and Merge tabs") y los docs
    hablan de pestañas de la ventana de PRBar en vez de ventanas sueltas.
