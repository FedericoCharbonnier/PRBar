# QA manual — Plan 6 (dropdown de repos y chat con Claude)

## A. Add Repo
- [ ] Settings › Repos › Add Repo…: el popover mide 440 × 480; los nombres largos se cortan al medio. El de ramas y el de usuarios no cambiaron.

## Flags del CLI (una vez, con haiku y una carpeta temporal)
- [x] `claude -p "say hi" --session-id <uuid> --output-format stream-json --verbose --setting-sources ""` y después `claude -p "what did I say?" --resume <uuid> …` en el mismo cwd: la segunda recuerda la primera. (2026-11-19, CLI 2.1.318, haiku, argumentos exactos de `ClaudeRunner.arguments`.)
- [x] `--resume <uuid inexistente>` sale con código 1 y una línea `result` con `is_error: true`, `errors: ["No conversation found with session ID: …"]` y sin `result`. El mismo texto sale en stderr. PRBar reconstruye solo con ese error (spec B.11.12).
- [x] Con `--json-schema`, la herramienta de la salida estructurada se llama `StructuredOutput`.
- [x] Reglas de `--settings`: `Edit`/`Write` sobre `.git` (archivo del worktree), `.git/**`, `.gitattributes` y `.lfsconfig` quedan negados, en la raíz y en subcarpetas. `Edit` en un archivo normal sigue funcionando. Sin las reglas, `.gitattributes` y `.lfsconfig` se podían escribir.
- [ ] En la app: con una sesión de chat cuyo archivo `~/.claude/projects/…` se borró, el próximo mensaje muestra "Context rebuilt". Con una API key inválida, en cambio, muestra el error después de una sola corrida.

## Review
- [ ] En un review listo, ⇧⌘C abre el panel; el botón Chat de la toolbar también. El ancho se recuerda.
- [ ] "¿#2 es correcto?": la respuesta llega en español, con "Claude is working… · Reading …" mientras corre; los findings tienen `#N`.
- [ ] "Reescribí #1 más corto": #1 cambia y queda resaltado 3 s; el mensaje dice "Edited #1" con Undo; Undo lo vuelve atrás.
- [ ] "Agregá un finding en <archivo del diff>": aparece #N nuevo, elegido. Pedir uno en un archivo fuera del diff: no se agrega y queda la nota.
- [ ] Editar a mano después de un cambio de Claude y tocar Undo: pide confirmación ("Undo will also discard your manual edits since then").
- [ ] `ps` durante un mensaje: `claude` con `--resume`/`--session-id`, `--tools Read,Grep,Glob,Skill,Agent`, ningún `bash` hijo. El worktree `chat-<repo>-<N>-<uuid>` existe en `$TMPDIR/PRBar/worktrees`.
- [ ] Stop corta el mensaje ("Stopped.").
- [ ] Publicar: el panel queda de solo lectura y el worktree del chat desaparece.
- [ ] Historial: "Chat (N messages)" con la conversación; los findings agregados aparecen; Show Claude Log tiene los `=== chat N ===`.
- [ ] Cerrar la app con un mensaje corriendo y reabrir el review desde el historial: el mensaje queda como "Interrupted".

## Respond
- [ ] Antes de implementar: "contestale a X que …" redacta la respuesta (resaltada); "no implementes el fix de Y" destilda Implementar.
- [ ] Con fixes listos (readyToPush): "cambiá el fix para …" → nuevo commit "Address review feedback", el diff y los commits se actualizan, los tests anteriores desaparecen. Undo vuelve el commit y el diff.
- [ ] Un chat empezado antes de implementar, después de implementar: "cambiá el fix para …" edita el código. El log muestra la nota "PRBar implemented the fixes since your last answer…".
- [ ] Agregar a mano un hook en el clone (`.git/hooks/pre-push`) después de implementar: el próximo mensaje del chat y su Undo fallan con "Git configuration or hooks changed since the fixes were implemented", y Push también se niega.
- [ ] Mientras implementa, corren los tests o pushea, el campo dice por qué está deshabilitado. Mientras el chat corre, Implement/Run Tests/Push están deshabilitados.
- [ ] Pushear: el chat queda de solo lectura; las respuestas publicadas son las que dejó el chat.
- [ ] Settings › Claude › Chat apagado: no hay botón Chat. Modelo "Haiku": `--model haiku` en el log.
- [ ] Dos chats corriendo en dos PRs y un tercero: el tercero espera ("Waiting for another chat to finish…").
