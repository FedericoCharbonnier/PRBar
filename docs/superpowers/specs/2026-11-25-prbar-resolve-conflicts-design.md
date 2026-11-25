# PRBar: Resolve Conflicts (Claude resuelve los conflictos de mis PRs)

Fecha: 2026-11-25. Aprobado por el usuario ("ok"; estrategia: "lo que recomiendes vos" → merge; dónde: "Todos con
conflictos").

## Problema

Un PR mío con conflictos con su rama base no se puede mergear hasta resolverlos. Desde 1.5.1 PRBar lo muestra (Ready to
Merge con "This branch has conflicts" si está aprobado), pero resolverlos sigue siendo a mano: clonar, mergear la base,
editar los marcadores, commitear y pushear.

## C.1 Qué hace

Un botón **Resolve Conflicts** le pide a Claude que resuelva los conflictos de un PR mío con su rama base, en un worktree
aislado. Es un tercer modo de Respond (`RespondMode.conflicts`) junto a `feedback` y `ciFix`: misma cola, mismo
worktree (local o en el host del repo, J), mismo guardián de integridad (`FixImplementer`), mismo chat, Run Tests y push
desde la Mac. No se publica ningún comentario en el PR.

**Estrategia: merge, no rebase.** PRBar mergea la base (`baseRef` del PR, no `main` fijo) en la rama del PR. Push normal,
sin reescribir los commits ya revisados, una sola resolución. Rebase queda fuera de alcance.

## C.2 Dónde aparece

- En cualquier PR mío (`PopoverTabs.isMine`) con `pr.merge.hasConflicts` (`CONFLICTING` o `DIRTY`), sin un Respond / Fix
  CI / Resolve Conflicts abierto en el mismo PR (`openRunConflict`, un solo trabajo de Respond por PR). Nunca arranca
  solo. También en drafts.
- Fila del popover y de la ventana principal: en Ready to Merge, el botón reemplaza al Merge deshabilitado. En las demás
  secciones (With Feedback, Waiting for Review, CI Failing) aparece donde iría Fix CI (si el PR tiene CI fallando y
  conflictos, prima Resolve Conflicts: con conflictos GitHub no corre el CI del merge). La línea de estado de la fila
  muestra "This branch has conflicts" en naranja (`MergeStatusLabel` con `MergePolicy.conflicts`) también fuera de Ready
  to Merge.
- Menú contextual de la fila, pestaña Merge de la ventana del PR (al lado del motivo deshabilitado) y menú Pull Request.
- `PRPrimaryAction`: un PR mío con conflictos y sin corrida → `.startConflicts`; con corrida → `.openConflicts` (abre la
  pestaña de Respond en modo conflictos).

## C.3 Flujo

1. **Preparación (sin Claude).** Token → `reviewFeedback` (fork → error de Respond, como siempre; head y `headRefName`) y
   `pullRequestDetails` (`baseRef`). Worktree propio en el head (`prepareWorktree`, como Fix CI). Si el head cambió
   mientras se leía, se borra el worktree y error ("The PR got new commits…").
2. **Merge.** PRBar corre en el worktree, con `GitHardening`: `fetch origin <baseRef>` (refspec explícito a
   `refs/prbar/conflicts/<n>/base`, sin tocar ramas locales) y `merge --no-ff --no-commit <ese ref>`. Lista los archivos
   en conflicto (`diff --name-only --diff-filter=U`).
   - Sin conflictos (GitHub tenía un dato viejo o ya se resolvió): PRBar commitea el merge y el draft queda directo en
     "listo para pushear", sin Claude.
   - Conflictos que no son de contenido (borrado/modificado, renombres, binarios, submódulos): el draft lista esos
     archivos como "resolve by hand" y Claude no los toca; si **todos** son de ese tipo, error claro y se borra el
     worktree.
3. **Claude resuelve.** Una sola corrida (etapa **Conflicts**), herramientas de la implementación (`Read, Grep, Glob,
   Edit, Write, Skill, Agent`; nunca shell). Contexto: los archivos en conflicto, la descripción del PR (texto no
   confiable, neutralizado), los commits de la base que entran (`log --oneline` merge-base..base, hasta 50) y el diff del
   PR respecto de la merge-base (recortado como en las reviews). Instrucción: resolver cada conflicto respetando la
   intención de los dos lados; no cambiar nada fuera de los conflictos salvo lo mínimo para que compile; un resumen por
   archivo.
4. **Verificación y commit (PRBar).** Ningún archivo trackeado del worktree puede tener líneas de marcador
   (`^<<<<<<< `, `^=======$`, `^>>>>>>> `, `^\|\|\|\|\|\|\| `) que no estaban en el head del PR ni en la base; si quedan,
   falla con la lista. Guardián de integridad igual que los fixes. `add -A` y `commit --no-verify -m "Merge <baseRef>
   into <headRef>"` cierra el merge (dos padres: head del PR y base).
5. **Revisión.** La pestaña Respond en modo conflictos: archivos resueltos (y los "resolve by hand"), resumen de Claude
   por archivo, y el diff **de la resolución**: el combined diff del merge (`diff-tree --cc` / `show --cc` del commit de
   merge, recortado con `capDiff`), no todo lo que trajo la base. El chat (editar, deshacer) y Run Tests funcionan igual;
   un turno de chat que deja marcadores se rechaza igual que en el paso 4.
6. **Push.** Además de las verificaciones de Respond (HEAD revisado, integridad, desciende de `startHeadOid`, sin
   `--force`, `--force-with-lease` en `startHeadOid`), PRBar re-verifica en GitHub que el PR sigue abierto y que su head
   sigue siendo `startHeadOid`. El HEAD a pushear tiene que descender también de la base mergeada. La confirmación
   avisa: "If the repo dismisses stale approvals, pushing removes the current approval."

## C.4 Prompt

- Etapa editable nueva **Conflicts** (Settings › Claude › Prompts y `prbar claude prompt show|edit|reset conflicts`).
  Variables: `{pr}`, `{repo}`, `{title}`, `{base}`, `{files}`, `{rules}`. Ninguna obligatoria.
- Parte fija (E.6): reglas de seguridad de PRBar, el contexto delimitado con nonce y neutralizado (`UntrustedText`), las
  reglas del usuario de la etapa Fixes (`respond`), los ajustes de fixes (E.5) y el formato de salida de un fix.

## C.5 CLI

```
prbar conflicts list [--json]            # mis PRs con conflictos y su Resolve Conflicts
prbar conflicts resolve <pr> [--wait]
prbar conflicts show <pr> [--json]       # = respond show
prbar conflicts diff <pr>                # el combined diff de la resolución
prbar conflicts test <pr> [--wait]       # = respond test
prbar conflicts push <pr> [--yes] [--wait]
prbar conflicts cancel|dismiss <pr>
```

Sube la versión del protocolo si un comando nuevo lo necesita (como Fix CI).

## C.6 Notificaciones, historial y costo

- Sin notificación propia al aparecer conflictos (la fila ya lo muestra). Al terminar la resolución, el aviso de
  "listo para pushear" de Respond, con el texto de este modo.
- History: tipo "Resolved conflicts" (como "Fixed CI"). Costo de Claude: tarea "Conflicts" en `usage`.
- Sesión de Claude registrada para el botón Terminal (plan 22), como Fix CI.
- Una corrida `done` de conflictos se descarta sola cuando el PR vuelve a tener conflictos después de `finishedAt`
  (como R.1 con el feedback nuevo), así el botón vuelve a aparecer.

## C.7 Fuera de alcance

PRs de forks, rebase, PRs de otros, resolver conflictos de merge queue o de ramas que no son la base del PR.

## C.8 Pruebas

- Merge con conflictos → draft con los archivos; sin conflictos → commit de merge y listo para pushear sin Claude.
- Solo conflictos no de contenido → error y worktree borrado.
- Claude deja un marcador → falla con la lista; un marcador que ya estaba en el head no cuenta.
- Commit final con dos padres (head y base); el combined diff muestra solo la resolución.
- Head cambiado antes del push → no pushea.
- `PRPrimaryAction`/botones: solo en PRs míos con conflictos; prima sobre Fix CI; un solo trabajo por PR.
- CLI (`conflicts list|resolve|show|diff|push`), prompt de la etapa, UIActionInventory.

## C.9 Decisiones de implementación (Plan 23)

1. **La ref de la base** es `refs/prbar/respond-<N>-<runID>-base` (no `refs/prbar/conflicts/<n>/base`): cuelga de la ref
   de la corrida, así `cleanup` la borra con el worktree, `cleanupOrphans` la conserva mientras su worktree exista y en un
   host la limpieza de refs viejas del mirror la alcanza igual. Se trae en el clone del usuario (o en el mirror del host)
   con `fetch --no-write-fetch-head origin +refs/heads/<baseRef>:<ref>` endurecido, después de validar `baseRef` como
   nombre de rama.
2. **`baseRef`** sale de `pullRequestDetails`, que suma `PRDetails.baseRef` (`base.ref` del REST); si GitHub no lo dice,
   el `baseRef` del último refresco. Antes del push también se verifica que la base del PR no cambió.
3. **"Resolve by hand"**: todo conflicto que no tenga las etapas 2 y 3 de un archivo de texto normal (borrado/modificado,
   agregado/agregado de un lado solo, renombres, binarios, symlinks, submódulos) más `.gitattributes`, `.lfsconfig` y
   `.gitmodules` (Claude cambiándolos cortaría el guardián). Antes de Claude, PRBar deja **la versión del PR** (la etapa
   2; si el PR no tiene el archivo, lo saca) y la pone en el índice. El draft los lista como "Kept the PR’s version —
   resolve by hand", el prompt le dice a Claude que no los toque, PRBar verifica que sus entradas del índice no cambiaron
   y la confirmación del push los nombra. Si **todos** los conflictos son de este tipo, error y se borra el worktree
   (C.3.2). Más de 50 archivos de contenido también es error ("too many conflicts for one run").
4. **Marcadores** (C.3.4): con `git grep -I -c` sobre el índice (después de `add -A`), el head del PR, la base y la
   merge-base; patrones `^<<<<<<<( |$)`, `^>>>>>>>( |$)`, `^\|{7}( |$)`, `^=======[[:space:]]*$` (tolera CRLF). Un
   archivo falla si tiene más líneas así que `max(head, base, head + base − mergeBase)`: un título Markdown subrayado con
   `=======` que ya estaba (o que agregó un solo lado) no cuenta. Corre con git en el worktree, así sirve igual en un host.
5. **Un solo commit de merge**: un turno del chat no apila un commit: rehace el de merge (`write-tree` + `commit-tree`
   con los mismos dos padres y el mismo mensaje, `update-ref` con compare-and-swap), y Undo vuelve al anterior igual que
   hoy. Por eso HEAD siempre es un merge de `startHeadOid` y `baseOid`, el diff que se revisa es siempre
   `diff-tree --cc HEAD` (recortado con `capDiff`), los commits son solo ese merge (`log --first-parent`) y los archivos
   sensibles, las dependencias y el `--stat` se calculan sobre los archivos que difieren de los dos padres
   (`diff-tree -c --name-only`), no sobre todo lo que trajo la base.
6. Si el head del PR **ya contiene** la base, no hay nada que mergear: error sin Claude ("GitHub may not have updated
   yet"). Historias sin merge-base: error.
7. Si Claude falla, responde `failed`/`skipped` o deja marcadores, **la corrida falla** (sin commit parcial). El worktree
   queda a mitad del merge y cuenta como trabajo sin pushear: "Resolve Conflicts Again" pregunta antes de descartarlo.
8. **Sin pestaña nueva**: la corrida se ve en la pestaña Respond (como dice C.2). Se arranca desde la fila, el menú
   contextual, la pestaña Merge o Pull Request › Resolve Conflicts. En With Feedback la acción principal (↩) sigue siendo
   Respond; Resolve Conflicts va al lado, donde iría Fix CI. En Ready to Merge y en las demás secciones
   `PRPrimaryAction` es `.startConflicts`.
9. **Protocolo 9**: `conflictsList` y `conflictsResolve`, `HistoryKind.conflicts`, `RespondMode.conflicts` y
   `RespondInfo.conflicts`. Los dos comandos nuevos son solo de la Mac (`RemotePolicy` los niega al teléfono). Un Resolve
   Conflicts solo se pushea pidiéndolo con su modo (`prbar conflicts push` o la Mac); `respondPush` sin modo (la web, una
   CLI vieja) se niega. `minimumRemoteVersion` queda en 8.
10. **Descartar uno terminado** (C.6): un `done` de conflictos se descarta cuando el PR tiene conflictos otra vez después
    de haberse visto sin conflictos, o cuando tiene conflictos y su head ya no es el que se pusheó.
11. **En un host**: el import trae `baseOid` a la Mac (como `startHeadOid`) y el bundle sale de `HEAD ^startHeadOid
    ^baseOid`, así no viaja todo lo que trajo la base. El push verifica el mismo combined diff.
12. El mensaje del commit es fijo, "Merge <baseRef> into <headRef>" (Claude no lo propone). La etapa **Conflicts** se
    guarda como la de Fix CI (`chatPrompts.conflicts`), su nombre en la CLI es `conflicts` y sus variables nuevas son
    `{base}` y `{files}`.
13. **Contexto del prompt**, cada parte en su bloque con el nonce y neutralizada: la descripción (hasta 20 000
    caracteres, `PR_DESCRIPTION`), los asuntos de los commits que entran (hasta 50, una línea cada uno, `BASE_COMMITS`) y
    el diff del PR contra la merge-base (hasta 3 000 líneas y 200 KB, `PR_DIFF`). Las rutas van saneadas en una línea.
    El contenido de los archivos lo lee Claude con Read; la parte fija dice que también es texto no confiable.
14. El merge corre con `GitHardening`, `GIT_LFS_SKIP_SMUDGE=1`, `-c merge.conflictStyle=merge` y
    `-c rerere.enabled=false` (un rerere del usuario no resuelve nada a escondidas).
15. Notificaciones: "Conflicts Resolved" (con cuántos quedan a mano), "Resolution Pushed" y "Couldn’t Resolve Conflicts";
    abren la pestaña Respond.
16. **Cambios fuera de los conflictos**: el combined diff (`diff-tree --cc`) esconde un archivo cuyo resultado es igual a
    la versión de uno de los padres (p. ej. Claude devuelve a la versión del PR un archivo que la base cambió sin
    conflicto). Después del merge y antes de Claude, PRBar guarda lo que dejó el merge automático en cada ruta que no
    es un archivo de contenido en conflicto (`ConflictsContext.automaticMerge`: modo y blob de etapa 0, de
    `diff-index --cached --raw <startHeadOid>`, solo las rutas que difieren del head; las demás quedaron como en el
    head). Después de Claude y de cada turno del chat, PRBar compara HEAD con ese registro en esas rutas (cambiadas,
    agregadas o borradas): cada diferencia es "un cambio fuera de los conflictos". Se lista en
    `RespondResult.outsideConflicts` (la UI y la confirmación del push la muestran, plan 23 Task 12), entra en el
    `--stat`, los archivos sensibles y las dependencias, y si el combined diff no la muestra se agrega al final del diff
    revisado un `diff --git` del merge automático a HEAD. En un host el registro viaja en el draft y la Mac recalcula
    lo mismo al importar y al pushear; si el blob del merge automático no está en la Mac (un archivo que mergeó git),
    ese archivo va solo con el encabezado.
