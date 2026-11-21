# QA manual — Plan 19 (PRBar para iPhone, en el iPhone real)

Lo que la suite no puede probar: el iPhone de verdad, Face ID y el Secure Enclave, APNs, la pantalla bloqueada,
Dynamic Type y VoiceOver. La lógica ya está cubierta sin iPhone (`cd ios/PRBarMobileKit && swift test`,
`Scripts/ios-e2e.sh`, `Scripts/ios-build-check.sh`); esto es lo que queda para el aparato.

## 0. Preparación

`Scripts/iphone-setup.sh` sin argumentos dice qué falta. En orden (cada paso pregunta antes de tocar algo fuera del
repo; `PRBAR_RELAY_SERVER` es el destino ssh del VPS, nunca va al repo):

```
Scripts/iphone-setup.sh --team-id <TEAM_ID>
PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --apns-key ~/Downloads/AuthKey_<KEYID>.p8 --apns-key-id <KEYID>
Scripts/iphone-setup.sh --ios-platform
PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --install-mac
Scripts/iphone-setup.sh --install-iphone
```

- [ ] `--apns-key`: termina con "/healthz answers" y "Push is on". En el VPS: `ls -l /root/stack/env/prbar-relay.p8`
      → `-r-------- 65532 65532`; el `.env` conserva `RELAY_ENROLL_TOKEN` y las demás líneas (`.env.bak` es la copia).
- [ ] `--install-mac`: PRBar de esta rama en `~/Applications`, `prbar remote status` → "Connected to prbar.…". El token
      no aparece en la terminal ni en el historial del shell.
- [ ] `--install-iphone`: con el iPhone desconectado, o con Modo de desarrollador apagado, el error lo dice claro. Con
      todo en orden, PRBar queda instalado y abre en `pair:welcome`.
- [ ] Borrar la `.p8` de Descargas una vez que el relay dice "Push is on" (solo vive en el VPS, spec T.2).

## 1. Emparejar

- [ ] `prbar remote pair` (o Settings › iPhone › Pair iPhone…): escanear el QR con la Cámara abre PRBar en la pantalla de
      confirmación (nombre de la Mac y host del relay); escanearlo desde `pair:scan` también.
- [ ] Los dos muestran el mismo código de 6 dígitos. "Codes Match" en el iPhone y en la Mac → el iPhone pasa a `home`;
      la Mac lista el iPhone con nombre y modelo.
- [ ] "Codes Don't Match" en el iPhone: la Mac ve el emparejamiento cancelado; el iPhone vuelve a `pair:welcome` sin
      guardar nada.
- [ ] Un QR vencido (más de 5 min) o ya usado: el iPhone dice que venció; nada cambia.
- [ ] Ya emparejado, abrir otro link `prbar://pair`: aviso "This replaces your pairing with <Mac>" y toque explícito;
      cancelar deja el emparejamiento de antes funcionando (L4).
- [ ] Tras emparejar, iOS pide permiso para notificaciones (una sola vez). Aceptar.

## 2. Pantallas (con datos reales)

Cada una en claro y oscuro, comparada con `ios/snapshots/` (`swift run PRBarMobileSnapshots`) y `ios/DESIGN.md`.

- [ ] `home` (To Review): secciones, contadores, badge de la pestaña; "Waiting for Review" y "Other" colapsadas.
- [ ] `home:mine` (My PRs): "CI Failing" como sección; approvals ("Approved by 2"), archivos ("· 5 files").
- [ ] Cambiar algo en la Mac (marcar visto, pedir un review): el iPhone lo muestra en menos de 2 s.
- [ ] `review`: "Review with Claude", progreso, findings numerados como en la Mac; incluir/excluir; `edit` (editar un
      finding); comentario general; `review:menu` (Comment / Request changes / Approve); `review:posted` con el link.
- [ ] `respond`: ítems implement / reply-only / skip, implementar con progreso, `respond:diff` (colores `+`/`-`/`@@`,
      archivos sensibles destacados, aviso de diff truncado), cronómetro, "2 of 9" checks.
- [ ] `respond:fixci` en un PR con CI roto a propósito: checks fallidos con duración y extracto del log; Fix CI.
- [ ] `chat:review`, `chat:respond`: el texto llega en streaming y una sola vez; Stop; Undo con la confirmación cuando hay
      ediciones manuales. Un chat empezado en la Mac aparece en vivo en el iPhone.
- [ ] `merge`: resumen, checks, conversaciones, método; `merge:merged`; "Posted in #canal" si Slack avisa el merge.
      `chat:merge` es de solo lectura.
- [ ] `activity`: trabajos en curso con Stop (el costo de un trabajo en curso es "—" hasta que termina), costo de Claude
      del mes, CPU / RAM / disco de la Mac.
- [ ] `settings`: la Mac emparejada y "Connected · end-to-end encrypted", interruptores de notificaciones (cambian los
      de la Mac: verificar con `prbar notify list`), versión, "Unpair This Mac".
- [ ] Volver con el gesto desde el borde en cada pantalla empujada.

## 3. Face ID

- [ ] Approve (`review:faceid`): pide Face ID con "Approve <repo>#<n>"; cancelar no manda nada y vuelve a `review:menu`;
      con Face ID se publica. Comment y Request changes **no** piden Face ID.
- [ ] Push y Push Anyway en Respond: piden Face ID; cancelar no pushea.
- [ ] **Tests** en Respond (P.16 H1): el botón muestra el glifo de Face ID; cancelar no corre nada en la Mac (Activity
      sin "testing"); con Face ID corren. Implementar y chatear nunca corren tests solos.
- [ ] Merge (`merge:faceid`): igual; cancelar no mergea.
- [ ] Settings › "Require Face ID for merge, push, approve and tests": apagarlo pide Face ID (cancelar lo deja
      prendido); prenderlo no. Con el ajuste apagado, merge/push/approve/tests no piden Face ID. Volver a prenderlo.
- [ ] Desde la Mac, `prbar remote devices --require-face-id <iphone> off` con el iPhone abierto: el ajuste del iPhone se
      apaga sin reconectar; "Tests" corre sin Face ID. Volver a `on`: se prende solo.
- [ ] Agregar o borrar un rostro en Ajustes › Face ID: la próxima acción gated dice "Face ID changed. Pair this iPhone
      again from your Mac." con "Pair Again"; re-emparejar reemplaza al dispositivo en la Mac (mismo nombre).

## 4. Sin conexión, buzón, revocar, relay

- [ ] Dormir la Mac: el iPhone pasa a `home:offline` con la caché gris y "Last updated" = cuándo escribió la Mac el
      buzón (no cuándo llegó). Las acciones quedan deshabilitadas.
- [ ] Mac apagada y app del iPhone cerrada y reabierta: muestra el último `home` del buzón con la hora de la Mac.
- [ ] `prbar remote mailbox off` con la Mac dormida al rato: el iPhone no muestra estado del buzón (vacío = nada).
- [ ] Despertar la Mac: el iPhone vuelve a "online" solo y vuelve a suscribirse (los datos se actualizan).
- [ ] Cambiar de Wi‑Fi en la Mac con el iPhone abierto en un PR: vuelve a "online" solo y el PR se sigue actualizando
      (sin quedar "online" con pedidos que vencen).
- [ ] Modo avión en el iPhone y volver: "Can't connect to <Mac>" con Try Again; reconecta con backoff.
- [ ] Revoke desde la Mac (Settings › iPhone o `prbar remote revoke <iphone>`) con el iPhone abierto: el iPhone muestra
      que la Mac lo quitó y vuelve a emparejar; la caché y las claves quedan borradas.
- [ ] "Unpair This Mac" en el iPhone: la Mac lo da de baja; el iPhone vuelve a `pair:welcome`.
- [ ] Apagar el acceso en la Mac, Revoke de un iPhone, volver a prenderlo: el relay ya no conoce al iPhone (4403 en el
      iPhone) y el iPhone **no** se desempareja solo por eso (muestra un problema de conexión, M3).
- [ ] Códigos de cierre del relay (4401/4403/4409/4429): siempre "Can't connect" con Try Again, nunca borran claves.
- [ ] Reset iPhone Access… con la Mac sin red: al volver la red (o al reabrir PRBar) la cuenta vieja queda sin iPhones en
      el relay; el log dice "the old relay account … has no iPhones left". El iPhone tiene que emparejar de nuevo.
- [ ] Mac de otra versión (protocolo viejo/nuevo): "Update PRBar on your Mac" / "Update PRBar on this iPhone".

## 5. Notificaciones push

Con el iPhone bloqueado y la app cerrada (deslizada), salvo que se diga otra cosa.

- [ ] Pedir un review desde la Mac y esperar "Review ready": en la pantalla bloqueada se ve el título y el cuerpo de
      la Mac (p. ej. "Review ready · api#317" — "4 comments to choose from"), **nunca** "New activity on your Mac"
      cuando todo está bien.
- [ ] Varias del mismo PR se agrupan; dos del mismo tipo para el mismo PR se reemplazan (collapse).
- [ ] El badge del ícono toma el valor de la Mac; al abrir la app sigue al `home` (llega a 0 cuando no queda nada).
- [ ] Tocar cada tipo abre la pantalla correcta: New PR to review / PR updated → `review`; Changes requested → `respond`;
      Ready to merge → `merge`; Review ready → `review` (o `respond` si era de Respond o Fix CI); Approved / CI failed →
      la pantalla por defecto del PR (como tocar la fila); Update available / disco → Activity.
- [ ] Mantener apretada una notificación: Review / Respond / Merge / "Chat with Claude" según el tipo; cada una abre la
      app en esa pantalla. Merge **no** mergea: abre la hoja con su paso de Face ID.
- [ ] Con la app abierta en ese mismo PR no aparece banner; en otro PR o en Home sí.
- [ ] Con el iPhone recién reiniciado y sin desbloquear nunca: la notificación queda genérica ("PRBar — New activity
      on your Mac"; las claves son "after first unlock"). Después de desbloquear una vez, las siguientes se descifran.
- [ ] Revocar el iPhone desde la Mac: no llegan más pushes de esa Mac (el relay borró el token). Una que llegue sin
      claves queda genérica.
- [ ] Apagar un tipo en Settings del iPhone (p. ej. "Ready to merge"): ese tipo deja de llegar (lo decide la Mac).
- [ ] Notificaciones desactivadas en Ajustes de iOS: la app sigue funcionando; la Mac no se queja.
- [ ] (Opcional) Un push viejo reenviado no aparece con texto: lo cubre `PushOpenerTests` (24 h, ids vistos); en el
      aparato basta con que nada descifrado aparezca dos veces.

## 6. Deep links

- [ ] En Notas o Mensajes, tocar `prbar://pr/<owner>/<repo>/<n>?screen=merge`: abre ese PR en Merge (si está
      emparejado); `?screen=chat` abre el chat; sin `screen` la pantalla por defecto del PR.
- [ ] `prbar://home` y `prbar://activity` abren esas pestañas.
- [ ] Un link a un PR con el iPhone sin emparejar no hace nada (queda en `pair:welcome`).
- [ ] Un link `prbar://pair` por Mensajes nunca empareja solo: siempre la confirmación y el código (L4).

## 7. Accesibilidad y apariencia

- [ ] Dynamic Type al máximo (Ajustes › Accesibilidad › Texto más grande) en `home`, `review`, `respond`, `merge`,
      `settings` y los diálogos de Face ID: nada cortado sin forma de leerlo; los botones siguen alcanzables.
- [ ] VoiceOver: cada fila de PR se lee como una sola frase (repo, número, título, estado); los títulos de pantalla son
      encabezados; los botones de círculo de vidrio tienen un nombre que se entiende; los interruptores dicen su estado.
- [ ] Modo oscuro y claro cambiando en vivo (Centro de control): colores del diseño, sin texto ilegible.
- [ ] Reducir transparencia y Aumentar contraste: la barra y los círculos de vidrio siguen legibles.

## 8. Revisión de seguridad del iPhone (spec P.16)

Movido desde `plan-18-checklist.md` § G (lo que necesita el iPhone real):

- [ ] Un error del Respond que menciona una ruta (p. ej. un clone que no existe) llega al iPhone como "~/…" o el nombre
      de la carpeta, nunca "/Users/<vos>/…". Activity › disco no muestra rutas completas ni el host SSH de un trabajo.
- [ ] Un PR con caracteres bidi (`‮`) en el título: en el iPhone (lista, Merge, Activity y la notificación) se ve
      sin reordenar.
- [ ] Emparejar con un link `prbar://pair` cuyo nombre trae bidi: la pantalla de confirmación lo muestra en una línea sin
      reordenar; si la Mac confirma antes que el iPhone, el iPhone no guarda nada hasta "Codes Match".
- [ ] (Los de Face ID para Tests, `--require-face-id off` en vivo, Wi‑Fi, Revoke con el acceso apagado, Reset sin red y
      el buzón con la Mac apagada están en las secciones 3 y 4.)
