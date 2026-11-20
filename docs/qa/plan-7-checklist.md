# Plan 7 — CLI: verificación manual

Con `Scripts/bundle.sh --install` y `~/.local/bin` en el PATH.

## Instalación y conexión
- [ ] `which prbar` → `~/.local/bin/prbar`; `ls -l` muestra el link a `~/Applications/PRBar.app/Contents/Helpers/prbar`.
- [ ] `prbar doctor` todo ✓; `prbar version` muestra las dos versiones.
- [ ] Quit PRBar; `prbar status` la abre en segundo plano (sin traerla al frente) y contesta en < 10 s.
- [ ] `ls -la ~/Library/Application\ Support/PRBar/` → la carpeta `drwx------`, `prbar.sock` `srw-------`.
- [ ] Otro usuario del Mac (o `sudo -u nobody prbar status`) → exit 3, "Only the user running PRBar…".

## Review (PR ajeno)
- [ ] `prbar review <pr> --wait`: progreso en stderr, tabla de findings con #N igual a la ventana.
- [ ] Con la ventana abierta: `prbar review exclude <pr> 2`, `review edit <pr> 1 --editor`, `review comment <pr> --text …` se ven al instante.
- [ ] `prbar review publish <pr> --comment`: lista con casillas; `e` abre `$EDITOR`; `q` cancela (130); ↩ y "n" cancela; "y" publica. La ventana pasa a "Posted".
- [ ] `prbar review publish <pr> --approve < /dev/null` → exit 4.
- [ ] Ctrl-C en `prbar review <pr> --wait` cancela el review en la app (exit 130).

## Respond (PR propio)
- [ ] `respond <pr> --wait`, `respond select … --skip`, `respond implement --wait`, `respond diff`, `respond test --wait`, `respond push` (muestra diff stat y pregunta).
- [ ] `respond reply-only` en un análisis sin fixes; `respond dismiss` borra el worktree.

## Ready to Merge (plan 10)
- [ ] `prbar prs --list ready-to-merge` lista los PRs de la sección "Ready to Merge".
- [ ] `prbar merge <pr>` en la terminal pregunta "Squash and Merge …?" (o con el método por defecto); "y" mergea, la fila pasa a "Merged" y desaparece con el refresh. Con `< /dev/null` sale con 4 sin mergear.
- [ ] `prbar merge <pr> --method rebase --yes` mergea con rebase; un método que el repo no permite → exit 6 con el motivo.
- [ ] Con un error de merge en la fila, `prbar merge <pr> --dismiss` lo saca.
- [ ] `prbar config set confirm-merge off`, `prbar repo set <repo> --merge-method squash|default`, `prbar notify set ready-to-merge off`, `prbar slack set merged off`, `prbar slack template set myPR.merged "…"` cambian lo mismo que Settings.

## Settings
- [ ] Cada fila de la tabla de `docs/cli.md` de Settings cambia lo mismo que la UI (con Settings abierta se ve al instante).
- [ ] `prbar app settings slack` abre (o cambia a) la pestaña Slack; `prbar app settings instructions` la de Instructions.
- [ ] `prbar app logs --slack` y `prbar app logs --update` abren esos logs (o salen con 5 si todavía no hay).
- [ ] `echo xoxp-… | prbar slack token set --stdin`; `prbar slack token clear` pregunta en la terminal.

## Scripts
- [ ] `prbar prs --json | jq '.data[0].id'`; `prbar history --json | jq .schemaVersion` → 1.
- [ ] Códigos: PR inexistente → 5; `review publish` sin review → 6; opción inválida → 2.
