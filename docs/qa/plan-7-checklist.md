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

## Chat (plan 6)
- [ ] Con un review listo: `prbar chat <pr> "¿por qué el #2 es un bug?"` muestra la respuesta en streaming y, si cambió algo, "edited #2 · undo: …"; la ventana resalta lo mismo.
- [ ] `prbar chat <pr>` abre el REPL; Ctrl-C mientras contesta lo detiene (130); `/undo`, `/show`, `/quit`.
- [ ] `prbar chat <pr> --undo` deshace; si hay ediciones manuales posteriores pregunta (sin terminal: exit 4).
- [ ] Con un análisis de Respond implementando, `prbar chat <pr> "…"` contesta "Claude is implementing the fixes." (exit 6).
- [ ] `prbar history show <id>` de un review con chat imprime la conversación.

## Actualizaciones (plan 8)
- [ ] `prbar update --check; echo $?` → 0 (o 10 con una release más nueva).
- [ ] Con una release de prueba: `prbar update` muestra las notas, pregunta, imprime las etapas y, al reiniciarse la app, "PRBar X is running."; `prbar update < /dev/null` → exit 4.
- [ ] Durante la instalación (antes de "Installing"), `prbar update --cancel` la cancela (también si la empezó la ventana, y "Cancel" de la ventana cancela una que empezó la CLI).
- [ ] `prbar update --skip`; `prbar config set update-interval 0|24` cambia "Check automatically"/"Frequency"; `prbar app logs --update`.

## Instrucciones y opciones (plan 9)
- [ ] `prbar rules add "No style comments" --review` aparece en Settings › Instructions; `rules edit <id> --no-review --fixes`, `rules disable`, `rules remove` se ven al instante.
- [ ] `prbar rules chat "en web-app usá React Query"` agrega la regla con Undo; `prbar rules chat --undo`; `prbar app logs --instructions`.
- [ ] `prbar rules suggestions` lista lo mismo que la pestaña; `accept|dismiss|never` hacen lo de Create Rule / Not Now / Never.
- [ ] Una tarjeta "Save as rule" del chat del PR: `prbar chat <pr> --show` la numera; `prbar rules proposal save <pr> 1 --this-repo --no-fixes` la guarda así; `… dismiss` la descarta.
- [ ] `prbar claude review set --min-severity medium --category style=off --ignore 'gen/**'` cambia la sección "What the review reports"; `prbar claude respond set --commit-mode single --reply-template default`.
- [ ] `prbar claude stage implementation --skill none`, `prbar claude stage review --default`; `prbar claude prompt edit filter` abre `$EDITOR` y rechaza un prompt sin `{findings_json}`; `prbar claude prompt reset filter`.
- [ ] `prbar repo set <repo> --ignore 'dist/**'` / `--unignore`; `prbar respond push <pr> --anyway` solo cuando los tests de antes del push fallaron.

## Settings
- [ ] Cada fila de la tabla de `docs/cli.md` de Settings cambia lo mismo que la UI (con Settings abierta se ve al instante).
- [ ] `prbar app settings slack` abre (o cambia a) la pestaña Slack; `prbar app settings instructions` la de Instructions.
- [ ] `prbar app logs --slack` y `prbar app logs --update` abren esos logs (o salen con 5 si todavía no hay).
- [ ] `echo xoxp-… | prbar slack token set --stdin`; `prbar slack token clear` pregunta en la terminal.

## Scripts
- [ ] `prbar prs --json | jq '.data[0].id'`; `prbar history --json | jq .schemaVersion` → 1.
- [ ] Códigos: PR inexistente → 5; `review publish` sin review → 6; opción inválida → 2.
