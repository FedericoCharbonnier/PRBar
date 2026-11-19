# PRBar — Plan 5: Slack con la cuenta del usuario y reacciones

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PRBar deja de usar un bot y pasa a usar la cuenta de Slack del usuario:
- publica, lee y reacciona como el usuario;
- sigue anunciando sus PRs y publicando "Updated" en el hilo;
- en los PRs de otros: busca el mensaje del PR en el canal del repo, reacciona con 👀 al empezar la review, con 💬 en la primera ronda de comentarios y con `:approved:` al aprobar, y publica "commented xN" en el hilo a partir de la segunda ronda.

**Spec:** §17 (reemplaza al bot de §15). Base: rama `feat/slack-user-account` desde `main` (458 tests, UI en inglés).

**Architecture:**
- Se extiende lo existente:
  - `SlackClient`: `conversations.history`, `reactions.add` y `auth.test` con user token;
  - `SlackState`: referencias a mensajes y estado de reacciones por PR;
  - `SlackPlanner`: acciones nuevas, en forma pura;
  - `SlackAnnouncer`: ejecución, búsqueda de mensajes y evento "review started".
- La regla de rondas por `commitOID` vive en una función pura.
- `AppModel.startReview` dispara 👀.

**Convenciones:**
- Tests: `swift run PRBarTests`. Los helpers `expect`/`expectEqual` no aceptan `await` adentro: primero va a una variable local.
- Nunca llamar a Slack ni a GitHub reales; usar `FakeTransport`, `FakeSlackAPI` y `FakeSecrets`.
- Commits en inglés, sin `Co-Authored-By` ni atribución. Sin push.
- UI en inglés.

---

### Task 1: Config, token de usuario y migración
- `SlackSettings` agrega, con decodificación tolerante y defaults:
  - toggles: `announceNewPRs`, `postUpdated`, `reactOnReviewStart`, `reactOnFirstComment`, `postRoundMessages` y `reactOnApprove` (todos `true` por defecto);
  - `reviewReactionsEnabledAt: Date?`, seteado al activar `reactOnReviewStart`, `reactOnFirstComment`, `postRoundMessages` o `reactOnApprove` desde apagado;
  - `eyesEmoji` = "eyes", `commentEmoji` = "speech_balloon" y `approvedEmoji` = "approved";
  - `roundTemplate` = "commented x{n}" y `searchDays` = 30.

  Los existentes (`enabled`, `newPRTemplate`, `updateTemplate`, `enabledAt`) se mantienen.
- **Nombres de emoji:** se normalizan (sin `:` alrededor, en minúsculas, solo `[a-z0-9_+'-]`). Si quedan vacíos, se usa el default.
- **`SlackTemplate.render`:** acepta `{n}`.
- **Token:** la clave del Llavero pasa a `user-token`. En la migración se borra `bot-token` si existía. En ese caso `SlackAnnouncer` expone `needsUserToken = true`, y la UI muestra "Slack now posts as you. Paste your user token." El estado guardado de anuncios se conserva.
- **Validación:** `saveToken` rechaza tokens que no empiecen con `xoxp-`, con el error "This is a bot token. Paste the User OAuth Token (xoxp-…)" para `xoxb-` y un error genérico para los demás.
- Tests: defaults, JSON viejo, normalización de emojis, `{n}`, migración del token y validación del prefijo.

### Task 2: API de Slack
- `SlackAPI` agrega:
  - `history(channel:oldest:token:) async throws -> [SlackMessage]`: `conversations.history` con `oldest`, `limit=200`, paginando por cursor hasta 1000 mensajes. Devuelve solo mensajes raíz (sin `thread_ts`, o con `thread_ts == ts`). `SlackMessage` tiene `ts`, `text`, `attachments[].from_url/title_link` y las URLs encontradas en `blocks`.
  - `addReaction(channel:ts:name:token:) async throws`: `reactions.add`. `already_reacted` no es un error.
  - `authTest` devuelve también `userID`, para filtrar y para mostrar "Connected as @user on Team".
- `FakeSlackAPI` registra las llamadas.
- Tests con `FakeTransport`:
  - paginación y límite;
  - el filtro de mensajes raíz;
  - `already_reacted` → ok;
  - `invalid_name`, `missing_scope` y `not_in_channel` → `.slack(code)`;
  - 429 → `rateLimited`.

### Task 3: Lógica pura (búsqueda, rondas y planificador)
- **`PRLinkMatcher.matches(_ message: SlackMessage, prURL: URL) -> Bool`:**
  - normaliza `<url|texto>`, `<url>`, http y https, `www.`, mayúsculas en owner y repo, barra final, sufijos `/files`, `/commits` y `/checks`, y fragmentos `#...`;
  - no matchea `pull/12` contra `pull/123`.
- **`ReviewRounds.compute(reviews: [PRReview], me: String, since: Date) -> (commentRounds: Int, approved: Bool, firstReviewAt: Date?)`:**
  - una ronda es un `commitOID` distinto entre mis reviews `COMMENTED` o `CHANGES_REQUESTED` con `submittedAt >= since`, ordenadas por fecha;
  - una review sin `commitOID` cuenta como ronda propia;
  - `approved` es true si existe una review `APPROVED` mía con fecha ≥ `since`.
- **Estado (`SlackState`, decodificación tolerante):** `reviewTracking: [prID: ReviewTracking]` con:
  - `message: SlackMessageRef?` (`channelID`, `ts`);
  - `lastSearchAt: Date?`;
  - `reacted: Set<String>`, con los valores `"eyes"`, `"comment"` y `"approved"`;
  - `roundsPosted: Int`.
- **`SlackPlanner.plan`** agrega, para PRs **de otros** en repos con canal y scope fresco:
  - `.findMessage(prID, channelID, prURL)`, si no hay `message` y `lastSearchAt` es nil o tiene más de 10 minutos;
  - con `message`, según `ReviewRounds` y los toggles:
    - `.react(prID, ref, emoji, kind: .eyes)` si hay una primera review (o un `reviewStarted` pendiente) y `"eyes"` no está en `reacted`;
    - `.react(..., kind: .comment)` si `commentRounds ≥ 1` y `"comment"` no está en `reacted`;
    - `.reply(prID, ref, text: "commented x{n}")` para cada `n` en `max(2, roundsPosted+1)...commentRounds`;
    - `.react(..., kind: .approved)` si `approved` y `"approved"` no está en `reacted`.
  - `since = settings.reviewReactionsEnabledAt`. Si es nil, no hay reacciones.
  - Los anuncios y "Updated" de mis PRs siguen igual, respetando `announceNewPRs` y `postUpdated`.
- Tests:
  - el matcher con unos 12 casos;
  - las rondas: mismo commit = 1 ronda, commit nuevo = 2, sin oid y el filtro por `since`;
  - el planificador:
    - sin mensaje busca;
    - la búsqueda reciente no se repite;
    - las reacciones en orden;
    - la ronda 3 recién descubierta publica x2 y x3;
    - un toggle apagado no genera la acción;
    - las reviews anteriores a `since` se ignoran;
    - mis propios PRs no reaccionan.

### Task 4: Ejecución (`SlackAnnouncer`)
- **Acciones:**
  - `.findMessage`: `history(oldest: now - searchDays)` y `PRLinkMatcher`. Si encuentra el mensaje, guarda la referencia; siempre guarda `lastSearchAt`.
  - `.react` / `.reply`: ejecuta y después actualiza `reacted` o `roundsPosted`.
  - El estado se guarda después de cada acción.
- **Orden:** después de un `findMessage` exitoso, se vuelve a planificar en el mismo ciclo, así la reacción sale enseguida.
- **`reviewStarted(item: ClassifiedPR, config:)`:** lo llama `AppModel.startReview`. Marca `pendingEyes[prID] = true` (persistido), busca el mensaje si hace falta y reacciona con 👀 si `reactOnReviewStart` está activo. No bloquea el review y los errores solo van a `issues`.
- **Errores:** `issues` con pistas nuevas en `RefreshIssue.message`:
  - `invalid_name`: "Emoji :x: doesn't exist in this workspace";
  - `missing_scope`: "Your Slack token is missing a scope (needs …)";
  - `not_in_channel`: "Join #channel to post there".

  Un `rateLimited` corta el ciclo.
- Tests con `FakeSlackAPI`:
  - el ciclo completo con búsqueda, 👀, 💬, x2 y approved, sin duplicar en el ciclo siguiente;
  - un reinicio con el mismo store no duplica;
  - `reviewStarted` reacciona y persiste;
  - un emoji inválido genera un issue y no se reintenta en cada ciclo para el mismo PR y kind (se reintenta solo si cambia la configuración del emoji);
  - el estado se guarda tras cada acción.

### Task 5: UI y cableado
- **Pestaña Slack:**
  - "User token" (`SecureField`, prompt `xoxp-…`);
  - "Test connection" → "Connected as @user on Team";
  - el banner de migración si `needsUserToken`;
  - sección **My PRs**: toggles de anunciar y "Updated", con sus plantillas;
  - sección **Reviews of other PRs**: toggles 👀, 💬, "commented xN" y Approved, cada uno con el campo de su emoji (o la plantilla `commented x{n}`), y "Search last N days" (`Stepper`, 7–90);
  - la guía de configuración actualizada con los **User Token Scopes** y "Install to Workspace → copy the *User OAuth Token*".
  - Nota: "Messages and reactions are posted as you."
- **Repos:** el selector de canal sigue igual. El texto "the bot isn't in this channel" cambia a "you're not a member" cuando aplica (`is_member` refleja al usuario).
- **`AppModel.startReview`** llama a `slack.reviewStarted(...)`.
- **Popover:** muestra los issues de Slack como hasta ahora.
- Compilar, correr los tests e instalar (`Scripts/bundle.sh --install`).

### Task 6: QA y docs
- Actualizar `docs/qa/plan-4-checklist.md`: reemplazarlo o agregar `plan-5-checklist.md` con:
  - el token de usuario;
  - anunciar un PR propio;
  - abrir Review en un PR de otro cuyo link está en el canal → 👀;
  - publicar un comentario → 💬;
  - revisar un commit nuevo con comentarios → "commented x2" en el hilo;
  - aprobar → `:approved:`;
  - un emoji inexistente → error visible;
  - reiniciar → sin duplicados;
  - apagar cada toggle.
