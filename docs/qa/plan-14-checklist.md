# QA manual — Plan 14 (Claude en un servidor por SSH)

Hace falta un host de prueba propio (una VM Linux o una Mac de laboratorio) con: tu clave en `~/.ssh/authorized_keys`,
el host en `~/.ssh/known_hosts` de la Mac, git ≥ 2.31, Perl, Claude Code instalado y logueado (`claude` una vez), acceso
de lectura al repo de prueba (clave de deploy o `gh auth login` **en el host**) y los plugins de los skills elegidos
(`/plugin install …` en el host). Nada de esto se hace con repos reales.

## A. Destinos
- [ ] Settings › Claude › Run On › Add SSH Host…: el picker lista los `Host` de `~/.ssh/config`. Agregar el host: se verifica solo y muestra SO, git, claude y "logged in".
- [ ] `user@host:2222` a mano también funciona; `-oProxyCommand=…` o `a b` no se pueden agregar.
- [ ] Test Connection con Claude deslogueado en el host: "Claude isn’t signed in on …".
- [ ] Una carpeta remota que ya existe con archivos tuyos: "…already exists and isn’t PRBar’s"; no se toca nada.
- [ ] Un host que no está en `known_hosts`: falla (no se agrega la clave sola) salvo que tu ssh config diga `StrictHostKeyChecking accept-new`.
- [ ] `ls -ld /private/tmp/prbar-ssh-$(id -u)` → `drwx------` tuyo.
- [ ] Con `login shell = fish` en el host: Test Connection dice que el shell cambió el texto de prueba.

## B. Review remoto
- [ ] Repo con "Run Claude on: <host>": Review with Claude → la fila dice "on <host>"; en el host aparece `~/.prbar/installs/<id>/work/<repo>-<N>-…` mientras corre y desaparece al terminar.
- [ ] `ps -ef` en el host durante el review: `claude -p` **sin** el prompt en los argumentos; `cat /proc/<pid>/environ | tr '\0' '\n'` no tiene `GH_TOKEN`, `SSH_AUTH_SOCK` de la Mac ni nada fuera de la lista blanca.
- [ ] Un PR de prueba con un symlink a `/etc/passwd`: en el worktree remoto es un archivo de texto "[symlink to /etc/passwd omitted by PRBar]".
- [ ] Un PR con rama `feat/$(touch PWNED)`: el review corre y no aparece `PWNED` en ningún lado del host.
- [ ] Stop durante el review: en el host no queda ningún `claude` ni `node` de PRBar (`ps -ef | grep claude`) a los ~5 s.
- [ ] La ventana Activity (Plan 13) lista "Review <repo>#N · ssh … on <host>" con "—" en CPU/RAM; Stop la corta.
- [ ] **Verificar que `claude -p` lee el prompt de stdin** con la versión instalada en el host (`printf 'Reply ok' | claude -p --output-format text`): si no, anotarlo como bloqueante.

## C. Fallback
- [ ] Apagar el host (o `sudo ifconfig` / cortar la red): un review cae a esta Mac con "Ran on this Mac — <host> unreachable" y Settings › Repos muestra "Last job ran on this Mac — <host> was unreachable (fallback)."
- [ ] Con el fallback apagado (`prbar runners set <host> --fallback off`): el review falla con el error del host.
- [ ] Repo que el host no puede fetchear (sin acceso): "<host> can't fetch <owner>/<repo> — set up git access on the server", y con fallback corre en la Mac.

## D. Respond remoto
- [ ] Respond en un PR propio: el análisis corre en el host (aun sin carpeta local del repo).
- [ ] Implementar 1 fix: el diff que muestra la ventana coincide con `git -C <clone> diff <start>..refs/prbar/remote-<N>-<id>` en la Mac.
- [ ] Antes de pushear, hacer un commit a mano en el worktree remoto (`~/.prbar/installs/<id>/work/<…>-respond-<…>`): Push and Reply → "The commits from the server don’t match what you reviewed… Nothing was pushed."
- [ ] Sin tocar nada: Push and Reply pushea desde la Mac (con tu pre-push hook si el repo tiene `localPath`); en GitHub el commit es el revisado.
- [ ] Sin `localPath`: el push sale de `$TMPDIR/PRBar/push/<id>` con el token de la cuenta (no aparece en `ps`), y la carpeta se borra al terminar.
- [ ] Run Tests corre `sh -lc <testCommand>` en el host.

## E. Limpieza
- [ ] Salir de PRBar con un review a medias y volver a abrirla: en el host, los trabajos muertos de `~/.prbar/installs/<id>/work`, `jobs` y `tmp` se limpian (los de más de 12 h); `~/.prbar/installs/<id>/repos` sigue.
- [ ] Remove… del destino: los repos que lo usaban dicen "Default"; `~/.prbar` sigue en el host (borrarlo a mano).

## F. CLI (con `PRBAR_SOCKET` de la PRBar instalada)
- [ ] `prbar runners add <host>`, `list`, `test <host>` (exit ≠ 0 si hay problemas), `set <host> --dir ~/prbar2`, `default <host>`, `default local`, `remove <host>`.
- [ ] `prbar repo set <owner/repo> --run-on <host>|local|default`.
- [ ] Una `prbar` del protocolo 4 contra esta app (o al revés) pide actualizar.
- [ ] Stop cuando el host se cuelga y PRBar no puede confirmar el kill: el mensaje dice "Claude may still be running on <host>; PRBar won’t touch that worktree" y el worktree queda.
