# QA manual — Plan 5 (Slack como el usuario, dos providers)

Reemplaza a `plan-4-checklist.md`. Usar un canal de prueba (ej. `#prbar-test`) del que seas miembro y un repo propio de prueba. Empezar por el conector (el default) y repetir las secciones B a E con **cada provider**.

## A. Conexión

### Conector de Slack de Claude (default)
- [ ] En claude.ai → Settings → Connectors, Slack está conectado; `claude` tiene sesión iniciada.
- [ ] Instalación sin `provider` en `config.json` y sin token en el Llavero → Settings → Slack muestra "Connect with: Claude's Slack connector" (primera opción) y el texto "Uses your Claude account's Slack connector — no Slack app needed. Messages and reactions are posted as you. Each action takes a few seconds and uses a little of your Claude usage."
- [ ] Con un token de usuario ya guardado y sin `provider` en `config.json` → al abrir queda en "Slack user token" (no se pide permiso al Llavero).
- [ ] "Test Connection" → a los ~5 s, "Connected as @<usuario> via Claude".
- [ ] **"Send Test to My DM…"** → la alerta dice "PRBar will post a test message in your own DM, react 👀, reply in its thread, then read it back." → "Send Test". En ~30 s los cinco pasos muestran ✓ con su `ts`. En tu DM contigo mismo hay **un** mensaje "PRBar connector test (you can delete this)" con 👀 y **una** respuesta "PRBar connector test reply" en su hilo. Borrarlos a mano.
- [ ] Si algún paso da ✗: no hay reintentos, los pasos siguientes quedan "Not run"; "Show Log" abre `slack-connector.log` con el `tool_result` crudo de cada paso (`--- tool_result: … ---` y `--- parsed: … ---`). Mandar ese fragmento para ajustar el parser.
- [ ] Desconectar Slack en claude.ai → "Test Connection" muestra "Claude's Slack connector isn't available…"; volver a conectarlo.
- [ ] `~/Library/Logs/PRBar/slack-connector.log`: el `init` de cada corrida lista solo `claude.ai Slack` en `mcp_servers` (después de la primera) y en `tools` solo `StructuredOutput` y la herramienta de la operación; `permissionMode` es `dontAsk`.
- [ ] `~/Library/Application Support/PRBar/slack-connector-servers.json` lista los otros servidores MCP del usuario y no a `claude.ai Slack`.

### Token de usuario
- [ ] Settings → Slack → "Connect with: Slack user token". Se ven el campo "User token" (`xoxp-…`) y la guía con los User Token Scopes (`chat:write`, `reactions:write`, `channels:history`, `groups:history`, `channels:read`, `groups:read`).
- [ ] Pegar un `xoxb-…` → error "That token posts as an app…"; pegar el `xoxp-…` → "Connected as @<usuario> on <equipo>".
- [ ] "Send Test to My DM…" también funciona con el token (mismos cinco pasos).
- [ ] Con una config vieja que tenía token de bot: al abrir, el banner pide el token de usuario; al guardarlo desaparece.
- [ ] El token no aparece en `config.json` ni en `~/Library/Logs/PRBar/prbar.log`.

## B. Repos
- [ ] Repos → "Slack channel": la lista carga en los dos modos (con el conector tarda unos segundos; cambiar de repo no la vuelve a cargar; el botón de recargar sí).
- [ ] Con el token, un canal público del que no sos miembro dice "· you're not a member".
- [ ] Elegir `#prbar-test`.

## C. Mis PRs
- [ ] Crear un PR (no draft) → en el siguiente refresco llega el mensaje, publicado **como vos**.
- [ ] Reiniciar la app → no se repite.
- [ ] Review con comentario de otra persona + push → "Updated <link>" en el hilo, una sola vez.
- [ ] Apagar "Announce new PRs" → un PR nuevo no se anuncia. Apagar "Updated" → no hay "Updated".

## D. Reviews de PRs de otros
- [ ] Alguien publica el link de su PR en `#prbar-test`.
- [ ] Apretar Review en PRBar → 👀 en ese mensaje (como vos).
- [ ] Publicar un comentario de review → 💬.
- [ ] Revisar un commit nuevo con comentarios → "commented x2" en el hilo.
- [ ] Aprobar → `:approved:` (si el emoji no existe en el workspace: error visible "Emoji :approved: doesn't exist…", sin reintentos hasta cambiarlo).
- [ ] Cambiar el emoji a uno inexistente → error visible; volver a uno válido → reacciona.
- [ ] Reiniciar la app → sin reacciones ni mensajes duplicados.
- [ ] Apagar cada toggle (👀, 💬, round, Approved) → esa acción deja de ocurrir; las otras siguen.
- [ ] "Search the last N days": el Stepper va de 7 a 90; un PR anunciado antes de la ventana no se encuentra.

## E. Errores y costos (conector)
- [ ] Con el conector, cada acción tarda unos segundos y no bloquea la UI.
- [ ] Un canal sin acceso → issue en el popover con el canal.
- [ ] En el log no hay ninguna llamada a herramientas que no sean la de la operación; si el modelo hiciera otra cosa, el issue es "didn't do exactly what PRBar asked" y la acción se reintenta en el próximo ciclo.
- [ ] Apagar Slack → no hay más corridas de `claude` para Slack ni issues de Slack.

## F. Anti-duplicados (conector)
- [ ] Antes de cada anuncio, el log muestra un `slack_read_channel` del canal; si ya habías publicado el link del PR a mano, PRBar no lo vuelve a publicar ("is already announced" en `prbar.log`).
- [ ] Un resultado que PRBar no entiende da el issue "PRBar couldn't tell whether…" y `slack-state.json` guarda la marca en `uncertain`; el próximo intento (también tras reiniciar) lee el canal o el hilo antes de publicar y no duplica.
- [ ] Tras un error del conector, ese PR no se reintenta por 10 min, después 30 y después 60 (`backoff` en `slack-state.json`); el error sigue visible mientras tanto.
