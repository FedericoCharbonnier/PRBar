# QA manual — Revisión de UI en macOS Tahoe (panel de la barra de menú, ventanas y Spaces, teclado y VoiceOver)

Probar con el `.app` armado (`Scripts/bundle.sh`), en macOS 26 y, si se puede, en macOS 14. Con un review en curso
para las pruebas de "trabajos corriendo" (un PR de prueba, nunca uno real).

## A. Barra de menú que se oculta sola
Ajustes del Sistema › Centro de control › "Ocultar y mostrar automáticamente la barra de menús" = Siempre.
- [ ] Llevar el puntero arriba, clic en el ícono: el panel se abre pegado debajo de la barra. Bajar el puntero al panel: la barra se esconde y el panel **no se mueve** ni queda un hueco raro que cambie.
- [ ] Con el panel abierto y la barra escondida: ⌘R, colapsar/expandir una sección, cambiar de pestaña (⌘1/⌘2). El panel cambia de alto con el borde de arriba fijo; nunca salta ni queda debajo de la barra cuando vuelve a aparecer.
- [ ] El ícono queda resaltado mientras el panel está abierto y se apaga al cerrarlo.
- [ ] `PRBAR_SOCKET=… prbar app popover --tab mine` con la barra escondida: el panel abre debajo de donde descansa la barra y en la pestaña My PRs.

## B. App en pantalla completa
Safari (u otra app) en pantalla completa.
- [ ] Clic en el ícono de PRBar: el panel aparece **sobre** la app en pantalla completa, sin cambiar de Space; la barra de menús de la app no se reemplaza.
- [ ] Desde el panel: Review de un PR listo, Settings (⌘,), History (⌘Y), PRBar Activity. Cada ventana aparece sobre la app en pantalla completa; no hay animación de cambio de Space.
- [ ] Cerrar la última ventana de PRBar: se vuelve a la app en pantalla completa, sin saltar a un escritorio.
- [ ] Salir de ese Space (⌃→) con una ventana de PRBar abierta: aparece el ícono de PRBar en el Dock (la app pasa a regular).
- [ ] En un escritorio normal, una ventana de Review se puede poner en pantalla completa (⌃⌘F o View › Enter Full Screen).
- [ ] Settings abierto en el Escritorio 1; ir al Escritorio 2 y abrir Settings desde el panel: la ventana viene al Escritorio 2 (no se cambia de Space).

## C. Pantalla chica y Dock
Una MacBook Air 13" en "Más espacio" o una resolución baja; Dock abajo y grande.
- [ ] Con muchos PRs, el panel nunca pasa el Dock: la lista se achica y hace scroll; el pie (CPU/RAM) y "Update…" siguen visibles.
- [ ] Con el ícono cerca del borde derecho, el panel queda entero dentro de la pantalla.
- [ ] Review/Respond/Merge de 720–760 pt: ⇧⌘C abre el chat y la ventana se ensancha lo necesario sin salirse de la pantalla (cerca del borde derecho, se corre a la izquierda).
- [ ] Settings › Claude: la ventana se puede agrandar en alto (no en ancho); al cambiar de pestaña vuelve al tamaño de esa pestaña.

## D. Varios monitores
- [ ] Ícono en el monitor secundario (barra de menús en todos los monitores): el panel abre en ese monitor, debajo del ícono.
- [ ] Con el panel abierto, desconectar el monitor o cambiar la disposición: el panel se cierra.
- [ ] Con el panel abierto, otro ícono aparece a la izquierda del de PRBar (o el número del badge cambia de 9 a 10): el panel sigue al ícono en horizontal.

## E. Cerrar el panel
- [ ] Clic en otra app, en el escritorio o en otra ventana de PRBar: se cierra.
- [ ] Esc: se cierra. Clic en el ícono con el panel abierto: se cierra (no se vuelve a abrir).
- [ ] Clic en una fila: se abre el PR en el navegador y el panel se cierra.
- [ ] Cambiar de Space (⌃←/→) o ⌘Tab a otra app: se cierra.
- [ ] Menú ⚙︎, menú contextual de una fila y menú de error de una pastilla: funcionan y el panel no se cierra al elegir un ítem que no abre otra cosa.

## F. Teclado
- [ ] Panel abierto: ↓ selecciona la primera fila, ↑/↓ recorren las filas visibles (se saltean las secciones colapsadas) y la lista hace scroll hasta la elegida; Return abre el PR.
- [ ] Con el mouse sobre una fila, ↓ sigue desde esa fila.
- [ ] ⌘1/⌘2, ⌘R, ⌘Y, ⌘, funcionan con el panel recién abierto **sin** haber hecho clic adentro (el panel no activa la app).
- [ ] ⌘Q con un review corriendo: pregunta "Quit PRBar while a job is running?"; Cancel (Return) no sale. Sin trabajos: sale sin preguntar. `prbar app quit` no pregunta.
- [ ] Menú View con una ventana de Review: "Show Chat ⇧⌘C" (cambia a "Hide Chat"), "Refresh ⌘R", "Enter Full Screen". Sin chat habilitado, Show Chat está deshabilitado. En Merge, Refresh recarga el resumen; en Activity, mide el disco; en Review, refresca la lista de PRs.
- [ ] Menú Window: Minimize, Zoom, Close, History ⌘Y, PRBar Activity, Bring All to Front y la lista de ventanas. Menú Help: buscador del sistema, Keyboard Shortcuts y Show Log.
- [ ] Settings › Claude › Run On: Tab hasta la tabla, ↑/↓ eligen un host, ⌫ pide confirmar y lo quita; Test Connection actúa sobre el elegido; con "This Mac" elegido Test y Remove están deshabilitados.
- [ ] Pastilla "Reviewing…" de una fila: con el mouse encima dice "Cancel" en rojo; clic → popover "Cancel this review?"; Esc o "Keep Running" no cancela; "Cancel Review" cancela. Lo mismo en Respond ("Analyzing…", "Implementing…").

## G. VoiceOver
- [ ] El ícono de la barra dice "PRBar, N PRs need your action" (o "loading", "offline").
- [ ] En el panel, las filas se leen completas; la pastilla de un review en curso dice "Cancel review, Reviewing, 2 agents" y que pregunta antes.
- [ ] Tabla de Run On: se lee como tabla con encabezados; VO-flechas eligen un host; el checkbox de Fallback se lee "Fall back to this Mac".

## H. Entrada CJK
Agregar Japonés (Romaji) o Pinyin en Teclado › Fuentes de entrada.
- [ ] En el chat de un Review: escribir "nihongo", la composición se subraya; Return **confirma** el texto (no envía). Un segundo Return envía.
- [ ] ⇧↩ y ⌥↩ insertan un salto de línea donde está el cursor (probar en el medio del texto, no al final).
- [ ] Lo mismo en Settings › Instructions (chat de reglas).

## I. Preferencia de pestañas
Ajustes del Sistema › Escritorio y Dock › "Preferir pestañas al abrir documentos".
- [ ] "Siempre": abrir dos reviews de PRs distintos → quedan como pestañas de una ventana. Abrir History → ventana aparte (no es pestaña de los reviews). Respond y Merge forman sus propios grupos.
- [ ] "En pantalla completa": con un Review en pantalla completa, abrir otro Review → se abre como pestaña. Sin pantalla completa → ventanas separadas.
- [ ] "Nunca": todas separadas. Settings, Activity y Update nunca son pestañas.
- [ ] Reabrir el review de un PR que ya tiene ventana (o pestaña) trae esa misma, no abre otra.
