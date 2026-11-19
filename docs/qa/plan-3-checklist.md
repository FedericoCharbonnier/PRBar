# QA manual — Plan 3 (Responder feedback)

- [ ] En un repo de prueba propio: abrir un PR, dejarle (desde otra cuenta) 2 comentarios inline y 1 comentario general con cambios pedidos.
- [ ] El PR aparece en "Mis PRs con feedback" con el botón Responder; sin carpeta local el botón está deshabilitado con explicación.
- [ ] Responder → Analizando… → "3 para revisar"; la ventana muestra evaluación, plan y borrador por comentario.
- [ ] Con cambios sin commitear o la rama en otro lado en el clone → igual analiza, en `<clone>-worktrees/<repo>-<N>-respond-<id>` (separado); el clone queda exactamente igual.
- [ ] Elegir 2 fixes + 3 respuestas → "Implementando 1/2, 2/2" → 2 commits (solo asunto) y el diff completo en color arriba de "Correr tests" y del push, sin correr tests ni hooks; "Correr tests" (si hay testCommand) los corre recién ahí.
- [ ] En la confirmación del push, Return cancela; pushear necesita un clic. El texto avisa de los hooks en el worktree de PRBar y del `git pull`.
- [ ] `ps` durante la implementación: ningún `bash` hijo de claude; `git log` muestra los commits hechos por PRBar.
- [ ] "Pushear y responder" → la rama en GitHub tiene los commits; cada hilo tiene su respuesta con "Arreglado en <link>"; el comentario general responde con @mención. Ningún hilo quedó resuelto.
- [ ] Si Slack está activo, llega "Updated" en el hilo del PR.
- [ ] Simular push rechazado (pushear otro commit desde otro clone antes) → error claro, ninguna respuesta publicada.
- [ ] Cancelar durante la implementación → mensaje con commits sin pushear, árbol limpio.
- [ ] Historial muestra el registro con commits y respuestas.
- [ ] Al terminar (o al descartar) el worktree de PRBar y `refs/prbar/respond-*` desaparecen; después de un fallo quedan hasta descartar o reiniciar la app.
