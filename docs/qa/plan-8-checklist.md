# QA manual — Plan 8 (actualizaciones desde el repo)

Para probar una actualización real sin publicar nada nuevo: con el release `v1.0.0` ya publicado en
`FedericoCharbonnier/PRBar`, instalar una copia local con una versión menor (sección B).

## A. Versión y scripts
- [ ] `~/Applications/PRBar.app/Contents/MacOS/PRBar --version` → `PRBar <versión instalada>`, código 0, no abre la app.
- [ ] `Scripts/bundle.sh --output /tmp/prbar-out` arma `/tmp/prbar-out/PRBar.app` y no cierra la PRBar abierta.
- [ ] `Scripts/bundle.sh --bogus` → "Usage: …", código 2, sin compilar.
- [ ] `Scripts/release.sh --dry-run 9.9.9` → chequeos, notas, build y tests; cada paso que cambia algo aparece como
      `[dry-run] would run: …`; termina con "Dry run finished…"; `git status` y `git tag` no cambian.
- [ ] `Scripts/release.sh 0.0.1` → "must be greater than the current version", código 2.

## B. Chequeo
- [ ] Preparar: `/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.9.0" Resources/Info.plist`,
      `Scripts/bundle.sh --install`, `git checkout Resources/Info.plist`.
- [ ] Settings › General › Updates: "Installed version 0.9.0". "Check for Updates" → "PRBar 1.0.0 is available" y "Update…".
- [ ] El header del popover muestra, a la izquierda de ↻ y ⚙︎, una cápsula azul "⬇ Update" (texto blanco); tooltip
      "PRBar 1.0.0 is available — Update"; click → ventana "Update PRBar" con las notas. Ya no hay fila al pie del popover.
- [ ] La cápsula está en las dos pestañas (To Review y My PRs) y también con "Set Up an Account", "Offline" sin datos y
      "Loading PRs…"; se lee bien en modo claro y oscuro y con Ajustes › Accesibilidad › "Aumentar contraste" (borde).
- [ ] Con el subtítulo largo ("GitHub rate limit · retrying at …", forzarlo con muchos refrescos o en el snapshot) la
      cápsula pasa a solo el ícono ⬇, sin cortar "PRBar" ni el subtítulo; el tooltip sigue diciendo la versión.
- [ ] Ícono de la barra de menú: punto azul arriba a la derecha del glifo, separado por un anillo transparente, con y sin el
      número de PRs; se ve bien con la barra clara, oscura, sobre un fondo de pantalla claro/oscuro (Tahoe) y con la barra
      que se oculta sola. Al hacer clic el ícono se resalta con el punto encima. Sin actualización, no hay punto.
- [ ] VoiceOver sobre el ícono: "PRBar, 3 PRs need your action, update available" (durante la instalación: "…, updating").
      VoiceOver sobre la cápsula: "PRBar 1.0.0 is available — Update, button".
- [ ] Menú de la app (con una ventana abierta), PRBar › "Update to PRBar 1.0.0…" → ventana "Update PRBar". Sin versión
      ofrecida dice "Check for Updates…": abre Settings › General con "Checking…" y luego "PRBar is up to date" (o abre
      la ventana "Update PRBar" si encontró una).
- [ ] Borrar `lastCheckAt` y `notifiedVersion` de `config.json`, salir y abrir PRBar → llega **una** notificación
      "PRBar 1.0.0 is available" con la primera línea de las notas; click → ventana "Update PRBar". Salir y abrir de
      nuevo → no se repite.
- [ ] Notificaciones apagadas en Settings → no hay notificación (y `notifiedVersion` sigue vacío).
- [ ] "Skip This Version" → la cápsula "Update" del popover y el punto azul del ícono desaparecen; al reabrir PRBar no vuelve. "Check for Updates" a mano la
      muestra de nuevo (sin notificación). Borrar `skippedVersion` para seguir.
- [ ] Sin red (Wi-Fi apagado): "Check for Updates" muestra "Couldn't check for updates: …" en rojo; el chequeo
      automático solo lo deja en `~/Library/Logs/PRBar/prbar.log`.
- [ ] "Check automatically" apagado → `checkIntervalHours: 0`; prendido → 24; "Frequency" cambia el valor.
- [ ] Con `"updates": {"repo": "no/existe"}` → "Check for Updates" dice "PRBar is up to date" (404); con `"repo": "../x"`
      se usa el default (el pie de la sección dice github.com/FedericoCharbonnier/PRBar).

## C. Instalación
- [ ] "Update" → la ventana muestra "Downloading the source", "Building (takes a minute or two)" con el log, "Checking the
      new app", "Installing", "Restarting PRBar". PRBar se cierra y vuelve a abrir sola.
- [ ] Al volver: ventana "PRBar Updated" — "Updated to PRBar 1.0.0" con las notas; `~/Applications/PRBar.app.previous` ya no existe;
      `--version` dice `PRBar 1.0.0`. Config, historial, estado de Slack y token siguen (puede pedir permiso al Llavero una vez).
- [ ] `~/Library/Application Support/PRBar/source` es un clon con `HEAD` detached en el commit de `v1.0.0`
      (`git -C … rev-parse HEAD` = `git rev-parse v1.0.0` en el repo); `.git/hooks` no corrió nada; el checkout de
      desarrollo (`~/Documents/PRBar`) no cambió.
- [ ] `~/Library/Logs/PRBar/update.log` tiene el log completo; "Show Log" lo abre.
- [ ] Con un review corriendo: la ventana ofrece "Cancel Jobs and Update" y "Update When Done". "Update When Done" → "Waiting
      for 1 running job to finish…" y sigue sola al terminar. "Cancel Jobs and Update" → el review se cancela y sigue.
- [ ] Durante "Building", "Cancel" → vuelve a "Update", la app instalada no cambió. "Hide" cierra la ventana y la cápsula del
      popover dice "Updating…" con un spinner (con Reducir movimiento: un reloj de arena quieto) y no responde al clic.
- [ ] Falla de build (simular: `chmod -w ~/Library/Application\ Support/PRBar/source/Scripts` antes de actualizar, o cortar la red
      durante "Downloading") → error en rojo, "Show Log", "Try Again"; la app instalada sigue siendo la misma.
- [ ] PRBar.app copiada en una carpeta sin permiso de escritura → "PRBar can't replace itself in …".
- [ ] Corriendo con `swift run PRBar`: Settings dice que se puede chequear pero no instalar; "Update" está deshabilitado.
