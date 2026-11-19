# QA manual — Plan 4 (Slack)

- [ ] Crear la app de Slack según la guía de Configuración → Slack e invitar el bot a un canal de prueba (ej. #prbar-test).
- [ ] Pegar el token → "Guardar y probar" muestra "Conectado a <equipo> como @<bot>".
- [ ] macOS puede pedir permiso de Llavero tras reinstalar la app (firma ad-hoc): elegir "Permitir siempre".
- [ ] Repos → elegir #prbar-test en un repo propio de prueba (ej. FedericoCharbonnier/PRBar).
- [ ] Crear un PR (no draft) en ese repo → en el siguiente refresco llega un mensaje con solo el link.
- [ ] Reiniciar la app → no se repite el mensaje.
- [ ] Crear un PR draft → no se anuncia; marcarlo Ready → se anuncia.
- [ ] Pedir a alguien (o desde otra cuenta) una review con comentario → pushear un commit → llega "Updated <link>" en el hilo.
- [ ] Pushear otro commit sin review nueva → no llega otro "Updated".
- [ ] Sacar al bot del canal → el popover muestra "Slack · <repo>: El bot no está en el canal…".
- [ ] Desactivar Slack → no hay más mensajes ni errores de Slack en el popover.
- [ ] El token no aparece en `config.json` ni en `~/Library/Logs/PRBar/prbar.log`.
