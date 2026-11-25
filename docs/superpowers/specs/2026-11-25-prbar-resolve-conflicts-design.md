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
