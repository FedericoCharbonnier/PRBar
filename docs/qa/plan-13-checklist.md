# QA manual — Plan 13 (recursos)

PRBar instalada, con un repo con `localPath`. Abrir Activity Monitor al lado para comparar.

## A. Pie del popover
- [ ] El pie muestra "CPU N% RAM N MB Disk N GB ›" en las dos pestañas.
- [ ] Con el popover abierto, los números cambian cada ~2 s; con el popover cerrado, `sample PRBar` / Activity Monitor no muestra trabajo periódico de PRBar.
- [ ] Durante un review, CPU y RAM suben y se parecen a la suma de PRBar + claude + node en Activity Monitor (± lo que cambie en 2 s).
- [ ] Clic en el pie abre "PRBar Activity".

## B. Ventana Activity
- [ ] Tres tiles (CPU, RAM, Disk) arriba; "Running now" lista "Review <repo>#N" con sus procesos (claude, git…) debajo, CPU, RAM, tiempo corriendo y Stop.
- [ ] Stop en un review lo cancela (la fila del popover vuelve a "Review with Claude") y sus procesos desaparecen.
- [ ] Stop en Respond, en un chat y en el chat de Instructions los paran.
- [ ] Durante una actualización, "Update build · swift" aparece; Stop la cancela mientras compila; mientras reemplaza la app, Stop está deshabilitado.
- [ ] "Disk" muestra Active worktrees, Orphaned worktrees "(can be cleaned)" (con el desglose por repo), Update clone and builds, Logs and history, Settings and state y Total; "Clean Up… (frees X)" y la nota de seguridad.

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
