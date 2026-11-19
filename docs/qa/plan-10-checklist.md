# QA manual — Plan 10 (Ready to Merge)

Hace falta un repo de prueba propio (p. ej. `<vos>/prbar-merge-sandbox`) agregado en Settings › Repos, con PRs tuyos
que puedas mergear y una segunda cuenta (o un colaborador) que los apruebe. Nada de esto se hace en repos reales.

## A. Datos y clasificación
- [ ] Un PR tuyo aprobado, sin comentarios nuevos: aparece en **Ready to Merge (1)**, después de My PRs with Feedback; el badge lo cuenta.
- [ ] Alguien comenta después de tu último push: el PR pasa a My PRs with Feedback. Pusheás: vuelve a Ready to Merge.
- [ ] Le respondés con un comentario tuyo en el PR: vuelve a Ready to Merge. Un reviewer comenta "LGTM" y después aprueba: queda en Ready to Merge.
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
- [ ] Mientras se instala una actualización (Settings › General › Update…): Merge y "Merge With…" quedan deshabilitados con el mismo tooltip que Review; un merge que ya estaba corriendo termina antes de que la app se reemplace.

## C. Confirmación y merge
- [ ] Con "Confirm before merging" encendido: Merge abre "Merge #N into <base>?" con el título, `owner/repo · N commits · head → base`, el popup de métodos y el botón del método. Esc cancela; ↩ mergea.
- [ ] Merge → la fila dice "Merging…", después "Merged" y a los 2 s desaparece (refresco). En GitHub, el PR quedó mergeado con el método elegido.
- [ ] Con "Confirm before merging" apagado, Merge mergea sin diálogo.
- [ ] Con el diálogo abierto, pushear un commit nuevo al PR desde la terminal y confirmar: la fila muestra Error; el menú dice "The PR changed since you looked at it — refresh and try again." **Anotar el texto exacto que devolvió GitHub** (en `~/Library/Logs/PRBar/prbar.log`, "Couldn't merge …") y, si no es "Head branch was modified…", agregar la frase a `MergeError.classify`.
- [ ] Después de ese error, Retry refresca y solo borra el error (con o sin "Confirm before merging"): la fila muestra el PR con el head nuevo y no se mergea nada hasta volver a apretar Merge. Dismiss borra el error.
- [ ] Error que no es de head (p. ej. cortar el Wi-Fi justo al mergear): Retry refresca y, si el head es el mismo, vuelve a pedir el merge (con el diálogo si "Confirm before merging" está encendido).
- [ ] Si el merge salió en GitHub pero la respuesta se perdió (red cortada): Retry encuentra el PR mergeado, la fila dice "Merged" y Slack responde "Merged".
- [ ] Con el diálogo abierto, alguien comenta en el PR y el refresco lo pasa a My PRs with Feedback: el diálogo se cierra solo.
- [ ] Repo con merge queue (si hay uno de prueba): el error dice "This repo uses a merge queue — add the PR to the queue on GitHub." **Anotar el texto exacto de GitHub** en el log.
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
- [ ] Recién aprobado con GitHub todavía calculando la mergeabilidad: llega "Your PR Was Approved" y, cuando GitHub termina (sin conflictos), "is ready to merge".
- [ ] Primer arranque después de actualizar desde una versión sin Ready to Merge: los PRs ya aprobados no notifican.
- [ ] Click en la notificación abre el PR en GitHub.

## F. Settings y capturas
- [ ] General › Merging y Notifications; Repos › Ready to Merge; Slack › My PRs: todo se guarda en `config.json` (`merge.confirm`, `mergeMethod`, `slack.postMerged`, `slack.mergedTemplate`).
- [ ] `Scripts/snapshots.sh "$TMPDIR/s" both` incluye `merge-confirm-*` y el popover con Ready to Merge.
