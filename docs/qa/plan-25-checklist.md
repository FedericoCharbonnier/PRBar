# QA manual — Plan 25 (Progreso en vivo)

Hace falta un repo de prueba propio en GitHub, un PR de otra cuenta de prueba que te pida review, un PR propio con
comentarios, otro con un check de Actions fallando y otro con conflictos, y la carpeta local configurada en Settings ›
Repos. Nada de esto se hace con repos reales de nadie. Para la parte de hosts, el host de prueba del Plan 14.

## A. Review
- [ ] Primera review del PR: la fila del popover y la de la ventana principal muestran debajo, en gris y chico,
      "Preparing · Reading the PR on GitHub…", "… · Creating the PR’s folder…", "… · Writing the context for Claude…",
      y después "Reviewing · Claude is starting…", "Reviewing · Reading <archivo>"; el pill sigue diciendo la fase.
- [ ] El tooltip del pill dice el paso ("1 agent · Reading src/… · click to cancel").
- [ ] Review Again después de un commit nuevo: "Updating the PR’s folder to <sha7>…" con el head que muestra la fila.
- [ ] Con una review publicada antes: aparece "Reading the previous reviews…"; Claude lee "the previous reviews" y "the
      changes since the last review" (no las rutas de `.context`).
- [ ] Con hallazgos y el filtro prendido: "Filtering the findings…" antes de la etapa 2.
- [ ] Sin carpeta local: "Creating a temporary folder…".
- [ ] La pestaña Review de la ventana del PR: debajo de la fase, "<paso> · 12 s" que avanza cada segundo.
- [ ] Un archivo con una ruta larguísima se corta en el medio en la fila; el tooltip la muestra entera (hasta 80).
- [ ] Cancel: el paso desaparece en el acto. Una review que falla: no queda paso colgado.
- [ ] Cancelar una review y pedir Review Again enseguida: si la cancelada todavía suelta la carpeta, "Waiting for the
      previous review of this PR…" antes de preparar la carpeta.
- [ ] El texto de Claude (lo que escribe entre herramientas) nunca aparece: solo "Thinking…".

## B. Respond, Fix CI, Resolve Conflicts
- [ ] Respond: "Reading the comments and their threads…", "Reading the PR on GitHub…", "Creating the worktree…",
      "Writing the context for Claude…", después los pasos de Claude; al implementar, "Implementing · Editing <archivo>" y
      "Committing…"; Run Tests: "Testing · Running the tests…"; Push & Reply: "Pushing…" y "Replying on GitHub…".
- [ ] Fix CI: "Reading the failing checks…", "Downloading the CI logs…", "Creating the worktree…", "Fixing · …",
      "Committing…"; Push: "Reading the PR on GitHub…" y "Pushing…".
- [ ] Resolve Conflicts: "Creating the worktree…", "Fetching <base>…", "Merging <base>…", "Resolving · Reading …",
      "Checking for conflict markers…", "Committing the merge…". La pestaña Merge muestra "Resolving the conflicts…" con
      el paso y su tiempo.
- [ ] La pestaña Respond muestra el paso con su tiempo en el análisis, en la tarjeta de "Claude is editing…", en los
      tests y en el push.
- [ ] Con el repo en un host: "Preparing Claude’s plugins on <host>…" (con skills de un plugin), "Creating the worktree
      on <host>…", "Writing the context for Claude on <host>…", "Committing on <host>…", al terminar de implementar
      "Bringing the fixes from <host>…", "Running the tests on <host>…"; "Reading the PR on GitHub…" y "Pushing…" sin
      host.

## C. CLI, web y capturas
- [ ] `prbar review show <pr>` mientras corre: "Now: <paso> (<tiempo>)"; `--json` trae `activity` con `kind`, `text`,
      `startedAt`; terminado, ni la línea ni el campo.
- [ ] `prbar respond show`, `prbar ci show`, `prbar conflicts show`: lo mismo.
- [ ] `prbar review <pr> --wait` en un terminal: una línea por paso nuevo ("Reviewing… · Reading …").
      `prbar review <pr> --wait 2>&1 | cat`: igual, sin dos líneas idénticas seguidas.
- [ ] iPhone (web app): la review que corre muestra "<paso> · 12 s" debajo de "Claude is reviewing this PR…"; un
      Respond que corre lo muestra en la etapa actual. Con una Mac sin este plan, nada se rompe.
- [ ] Capturas (en una máquina con disco para un build release): `Scripts/snapshots.sh docs/screenshots both`; las filas
      "Reviewing…" muestran "Reviewing · Reading src/shop/tax.py". Revertir las PNG que solo cambiaron bytes.
