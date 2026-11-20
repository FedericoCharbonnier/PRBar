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
