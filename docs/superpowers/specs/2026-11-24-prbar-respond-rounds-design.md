# PRBar: ida y vuelta de correcciones en mis PRs (Respond en varias rondas)

Fecha: 2026-11-24. Aprobado por el usuario ("Si hacelo y subí la versión nueva").

## Problema

Después de corregir un PR propio con Respond (o Fix CI), la corrida quedaba en la pestaña como "Responded" hasta
descartarla a mano. Si llegaban comments nuevos, el PR volvía a With Feedback, pero la pestaña seguía mostrando la
corrida vieja: no se veían los comments nuevos ni había Start Respond. Además, los comments generales del PR (pestaña
Conversation de GitHub) sumaban a "new comments" pero Respond no los leía.

## R.1 La corrida terminada se suelta con feedback nuevo

- En cada refresh, un PR mío cuya corrida de Respond o Fix CI está terminada (`done`) y que tiene una review (cambios
  pedidos o comentarios) o un comment de otra persona (no bot) posterior a su `finishedAt` vuelve a idle
  (`dismissRespond`): la pestaña muestra lo nuevo y Start Respond.
- La corrida queda en History; su carpeta conservada (plan 22, botón Terminal) no se borra.
- Una corrida en curso, lista para elegir, lista para pushear o con trabajo sin pushear no se toca.
- `ActionClassifier.latestFeedbackAt` y `RespondQueue.finishedRunsWithNewFeedback` deciden; `AppModel` lo aplica.

## R.2 La pestaña Respond lista los comments antes de empezar

- Sin corrida (la primera vez y después de R.1): cabecera ("Changes requested · N new comments"), la lista de lo que
  Claude va a analizar y abajo **Start Respond** (⌘↩) y "Previous run: Responded hace X ›" (abre esa corrida en
  History) si hubo una.
- La lista sale de la misma consulta (`reviewFeedback`) y el mismo filtro (`FeedbackFilter.select(_:me:)`) que el
  análisis: lo que se ve es lo que se analiza.
- Cada ítem: autor, `archivo:línea` / "Review" / "Comment", hace cuánto, el texto (más de 4 líneas o 280 caracteres:
  recortado con Show More), ↗ GitHub; en un hilo, el último comment y "N comments in this thread".
- Cargando: una ruedita. Error: el mensaje y Retry (Start Respond sigue disponible). Se recarga cuando cambian el head
  o el número de comments nuevos.
- Fix CI conserva su pantalla de inicio.

## R.3 Comments generales del PR en Respond

- `reviewFeedback` trae también `comments(last: 50)` del PR: `FeedbackItem` de tipo `conversation`
  (`comment:<databaseId>`).
- Se analizan los de otras personas (no bots), con texto, posteriores al último commit y sin un comment general mío
  posterior (ya respondido). Orden: hilos, reviews, comments generales.
- La respuesta se publica como comment del PR con `@autor` y la cita, como la de una review.

## Pruebas

- Filtro: comments generales (bots, míos, vacíos, anteriores al commit, ya respondidos) y el orden de los tres tipos.
- API: el mapeo de `comments` (sin `databaseId` se descarta).
- `latestFeedbackAt`: sin bots, sin míos ni aprobaciones.
- Cola: una corrida `done` con feedback posterior aparece; con feedback anterior, sin feedback o sin pushear, no.
- Paridad UI: Start Respond, Previous run, Retry, Show More y ↗ GitHub.
