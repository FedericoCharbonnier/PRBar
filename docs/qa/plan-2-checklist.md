# QA manual — Plan 2 (Review con Claude)

- [ ] En un PR ajeno de un repo con carpeta local: Review → En cola/Preparando → Revisando… (tooltip con agentes) → Filtrando… → "N comentarios".
- [ ] `git worktree list` en el clone durante el review muestra el worktree temporal; al terminar ya no está. `git branch` no cambió; `git for-each-ref refs/prbar/` vacío al terminar.
- [ ] Llega la notificación "Review listo"; click abre la ventana.
- [ ] La ventana coincide con docs/design/ReviewWindow.dc.html (claro y oscuro). Editar un comentario, destildar otro, incluir un descartado.
- [ ] Publicar como "Comentar" en un PR de prueba propio de otra cuenta → en GitHub aparece una sola review con comentarios inline y los fuera del diff en el cuerpo.
- [ ] Cortar la red y publicar → error visible, la selección y lo editado se conservan; reconectar y publicar funciona.
- [ ] Cancelar un review en curso → el botón vuelve a "Review"; no quedan procesos `claude` (`pgrep -fl claude`) ni worktrees.
- [ ] Tres reviews a la vez → el tercero queda "En cola" hasta que termina uno.
- [ ] Repo sin carpeta local → el review funciona en modo solo diff.
- [ ] Sin `claude` en el PATH (ruta personalizada inválida en General) → el botón muestra Error con mensaje claro.
- [ ] Historial lista los reviews; el detalle muestra publicados/descartados; "Ver log" abre el .jsonl; uno sin publicar se puede reabrir.
- [ ] Matar la app durante un review y volver a abrirla → los worktrees huérfanos se limpian al arrancar.
