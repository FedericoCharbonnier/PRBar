# QA manual — Plan 21 (una sola ventana en la Mac)

Con `Scripts/bundle.sh` y el `.app` instalado (la suite y las capturas no cubren ventanas reales, el Dock, las
notificaciones ni los links). Las capturas de referencia salen de `Scripts/snapshots.sh "$TMPDIR/prbar-snapshots" both`.
Para la CLI, `PRBAR_SOCKET` apuntando al socket de la app instalada.

## A. Ventana
- [ ] ⌘0 desde el popover (con el popover abierto) y desde Window › PRBar: abre o trae al frente la ventana principal.
- [ ] La primera vez sale de 1280×800; no achica de 960×600; al cerrarla y reabrirla (y al relanzar PRBar) conserva el
      frame.
- [ ] ⌘W la cierra y PRBar sigue en la barra de menú sin cancelar nada (una review corriendo sigue en el popover).
- [ ] Reabrirla conserva sección, PR, pestaña y Back.
- [ ] ⌘0 y ⌘Q **desde el popover** (sin ventanas abiertas y con una abierta): ⌘0 abre la ventana y cierra el popover;
      ⌘Q sale (con la confirmación de siempre si hay trabajo). El ítem "Quit PRBar ⌘Q" del pie del popover hace lo mismo.
- [ ] Con una ventana abierta y el popover abierto encima, ⌘1 / ⌘2 cambian la pestaña **del popover** (no la sección
      de la ventana); con el popover cerrado y la ventana al frente, ⌘1 / ⌘2 cambian la sección de la ventana.

## B. Barra lateral
- [ ] Contadores de To Review y My PRs iguales a los del popover.
- [ ] Grupo Claude: aparece con una review (spinner violeta, reloj), pasa a check verde al terminar, sale al publicar.
- [ ] Fila de iPhone con un teléfono emparejado (punto verde en línea).
- [ ] Aviso de update (versión ofrecida): What’s New e Install abren la hoja de Update (no instalan directo).
- [ ] Engranaje → Settings.

## C. Lista
- [ ] Secciones con contador; plegar y desplegar; "Other" plegada al empezar.
- [ ] ↑ ↓ mueven la selección; ↩ en un PR para revisar arranca la review y queda en Review.
- [ ] Doble clic abre la ventana de PR.
- [ ] Vacío: "All caught up" y "N drafts hidden · Show" (despliega Other).
- [ ] Cargando al arrancar sin datos (filas esqueleto).
- [ ] La fila elegida usa el acento del sistema y se lee bien en claro y oscuro (texto, pill, `+/−`).

## D. Pestañas
- [ ] PR ajeno: Review · Details. PR propio con cambios pedidos: abre en Respond; con CI roto: Fix CI; sin nada:
      Merge (Respond y Fix CI deshabilitadas).
- [ ] Indicadores (punto, spinner de Claude) en la pestaña que corresponde.
- [ ] La pestaña elegida se recuerda al volver al PR.
- [ ] Las pestañas quedan centradas en la toolbar con y sin el campo de búsqueda, y en History las de filtro.

## E. Review / Merge / Respond / Fix CI
- [ ] Review de punta a punta: publicar con ⌘↩ (fuera del chat).
- [ ] Merge con ⇧⌘M (Pull Request › Merge…), confirmación incluida.
- [ ] Respond y Fix CI: pushear con ⌘↩; Stop con ⌘. (pregunta antes); Discard.
- [ ] ⌘Z **fuera** de un campo de texto: Edit › "Undo Claude’s Change" deshace el último cambio de Claude del chat de
      la pestaña. ⌘Z **dentro** de un campo de texto (comentario general, chat): deshace el texto, no a Claude.
- [ ] Modo foco: con Claude trabajando la lista se oculta y el chat se abre; cerrar el chat a mano durante la tarea y
      ver que al terminar queda cerrado.

## F. Notificaciones
Cada una abre la ventana en el PR y la pestaña de su acción, y cierra el popover:
- [ ] Nuevo PR para revisar → Review.
- [ ] PR revisado con commits nuevos → Review.
- [ ] Feedback en un PR mío → Respond.
- [ ] Review lista → Review. Review fallida → su registro en History.
- [ ] Respond listo → Respond. Fix CI listo → Fix CI.
- [ ] CI roto → Fix CI.
- [ ] Aprobado / listo para mergear → Merge.
- [ ] Update → la hoja de Update. Disco → Activity.
- [ ] Con el PR **ya mergeado o cerrado** (ya no está en la lista): Respond / Fix CI → su registro en History; Merge →
      GitHub; Review lista → la pestaña igual.

## G. iPhone
- [ ] Un `review` y un `ci fix` pedidos desde la web app no abren ni enfocan la ventana.
- [ ] Aparecen en el grupo Claude con el ícono de iPhone; en History, el ícono en esos registros.

## H. Dock
- [ ] Sin "Always show in Dock": ícono solo con la ventana principal, una de PR o Settings abiertas; al cerrar la última
      se va.
- [ ] Con "Always show in Dock": ícono siempre, también recién arrancada y **después de relanzar** PRBar.
- [ ] Clic en el ícono del Dock sin ventanas abiertas (con el interruptor prendido): abre la ventana principal.
- [ ] `prbar config set always-show-in-dock on|off` hace lo mismo que el interruptor (y Settings lo refleja).

## I. Pantalla completa
- [ ] Con otra app en pantalla completa, ⌘0 desde la barra de menú muestra la ventana encima sin cambiar de Space.
- [ ] La ventana principal entra y sale de pantalla completa (⌃⌘F).

## J. Ventana de PR
- [ ] ⇧⌘O, el botón Open in New Window de la toolbar y el doble clic en una fila la abren.
- [ ] Una por PR: abrir el mismo PR otra vez trae al frente la que ya está.
- [ ] Con "Prefer tabs when opening documents: Always" (Ajustes del Sistema › Escritorio y Dock) se agrupan como
      pestañas nativas (solo entre ventanas de PR).
- [ ] Mergear desde la ventana de PR la cierra.

## K. Atajos
- [ ] ⌘1 ⌘2 ⌘3 ⌘4 → To Review · My PRs · History · Activity. ⌘Y ya no hace nada.
- [ ] ⌥⌘1–3: las pestañas del PR (el menú Pull Request muestra sus nombres y marca la elegida).
- [ ] ⌘. (Stop Claude), ⇧⌘M (Merge), ⇧⌘O (Open in New Window), ⌥⌘I (Show/Hide Chat), ⌃⌘S (Show/Hide Sidebar).
- [ ] ⌘[ vuelve al lugar anterior (después de ⌘1–4, una notificación, un link, un pill); ↑ ↓ en la lista no llenan
      Back.
- [ ] ⌘R refresca (en Activity, mide el disco); ⌘F enfoca el campo de búsqueda (View › Find).
- [ ] ⌘↩ en el chat envía el mensaje y **no** publica/pushea.
- [ ] Help › Keyboard Shortcuts lista todo lo anterior.

## L. Links
- [ ] `open "prbar://pr/<owner>/<repo>/<n>/merge"` abre ese PR en Merge.
- [ ] `open "prbar://review"`, `prbar://mine`, `prbar://history`, `prbar://activity`.
- [ ] Un link que no se entiende (`open "prbar://nope"`) abre la ventana sin moverse; el log dice "Couldn't understand
      a prbar:// link." sin el link.

## M. Búsqueda
- [ ] ⌘F enfoca el campo (a la derecha de los botones, ~170 pt); escribir filtra la lista: sin mayúsculas ni acentos,
      por título, `repo#N`, `#N`, autor y rama.
- [ ] Buscando, las secciones con resultados se ven desplegadas aunque estuvieran plegadas; sin resultados,
      "No Results". Borrar la búsqueda devuelve el plegado de antes.
- [ ] En History filtra la lista de History; en Activity no hay campo; cambiar de sección limpia la búsqueda.

## N. CLI
- [ ] `prbar open <pr> --review|--respond|--merge` navegan en la ventana.
- [ ] `prbar app history <id>` abre History en ese registro (aunque el filtro o la búsqueda lo escondieran).

## O. ⌘Q
- [ ] Con una tarea corriendo y con un fix sin pushear: pregunta como antes.

## P. VoiceOver
- [ ] Barra lateral: grupos, contadores, filas de Claude.
- [ ] Lista: filas, secciones plegables (lee "N PRs").
- [ ] Pestañas: la elegida, las deshabilitadas, "Claude is working".

## Q. Apariencia
- [ ] Claro y oscuro: contraste del texto secundario, chips, pills y badges en lista, detalle, History y Activity.
- [ ] La selección de la lista usa el acento del sistema (probar con otro acento en Ajustes del Sistema).
