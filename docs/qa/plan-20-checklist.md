# QA manual — Plan 20 (PRBar en el celular como web app)

En un iPhone real con iOS 16.4 o más nuevo, Safari, Face ID configurado. Antes de empezar:

```
PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --deploy-relay   # relay + web app + clave VAPID
PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --install-mac    # PRBar de esta rama + acceso prendido
Scripts/iphone-setup.sh                                                # todo en [x]
```

La suite automática (`cd web && npm test`, `Scripts/web-e2e.sh`, `cd relay && go test ./...`, `swift run PRBarTests`) no
reemplaza esto: Face ID real, Web Push de Apple y el almacenamiento de iOS solo se prueban en el teléfono.

## A. Instalar
- [ ] Settings › iPhone en la Mac muestra "Open PRBar on your phone" con el QR y `https://<relay host>/`; con la hoja
      de emparejar abierta el QR queda oculto ("Hidden while pairing").
- [ ] Escanear el QR con la Cámara del iPhone abre Safari en la pantalla `install` (ícono, "Add PRBar to your Home
      Screen", los 3 pasos). En Safari nunca se ofrece emparejar.
- [ ] Compartir › Agregar a inicio: el ícono de PRBar (no una captura de la página) y el nombre "PRBar".
- [ ] Abrir desde el ícono: pantalla completa (sin barra de Safari), `pair:welcome`, colores del modo del sistema.
- [ ] Modo avión y abrir desde el ícono: la app abre igual (shell en caché), muestra que no hay conexión.

## B. Emparejar y SAS
- [ ] En la Mac `prbar remote pair` (o Pair iPhone…): QR con cuenta regresiva de 5 min.
- [ ] En el teléfono: nombre del dispositivo, "Scan QR on your Mac", permiso de cámara, escanear. "Paste code" con el
      texto que imprime `prbar remote pair` también funciona.
- [ ] "Pair": iOS ofrece guardar una passkey para el host del relay; aceptar con Face ID.
- [ ] Los dos muestran el mismo código de 6 dígitos. Confirmar en la Mac → `pair:paired` en el teléfono, y la Mac lo
      lista en Settings › iPhone con Face ID requerido.
- [ ] Otra vez con "Codes Don't Match" en el teléfono: no queda emparejado en ninguno de los dos.
- [ ] Escanear el QR de emparejamiento con la Cámara (no con la app): abre la página de instalación, no empareja.
- [ ] El mismo QR una segunda vez, o después de 5 min: falla con un mensaje claro.

## C. Listas en vivo y sin conexión
- [ ] `home` (To Review) y `home:mine` (My PRs) con los mismos PRs que la Mac; un cambio en la Mac (PR nuevo, review
      lista, CI) aparece en el teléfono sin recargar.
- [ ] Cerrar PRBar en la Mac (o apagar el acceso): `home:offline` con "Last updated" del buzón; al volver la Mac, se
      reconecta sola.
- [ ] Modo avión con la app abierta: muestra la última lista y el estado sin conexión; al volver la red, se reconecta.
- [ ] Buzón apagado (`prbar remote mailbox off`) con la Mac cerrada: no aparece estado viejo.

## D. Review, respond y merge con Face ID
- [ ] Abrir un PR con review lista, sacar un hallazgo, editar otro, "Post": pide Face ID, se publica en GitHub igual
      que desde la Mac.
- [ ] Respond: elegir comentarios, "Tests" pide Face ID y corre en la Mac; push con Face ID.
- [ ] Fix CI y chat con Claude: funcionan sin Face ID (no ejecutan nada en la Mac hasta el push).
- [ ] Merge: pide Face ID, mergea, `merge:merged`.
- [ ] Approve: pide Face ID.
- [ ] Cancelar Face ID (o fallar 2 veces y cancelar el código): nada se ejecuta en la Mac, el teléfono vuelve a la
      pantalla anterior sin error raro.
- [ ] Apagar "Require Face ID" desde el teléfono (pide Face ID para apagarlo): merge ya no lo pide. Prenderlo desde la
      Mac: el teléfono conectado lo vuelve a pedir enseguida.

## E. Notificaciones
- [ ] Después de `pair:paired`, el botón de permitir notificaciones muestra el diálogo de iOS; aceptar.
- [ ] Con el iPhone bloqueado y PRBar cerrada: una review lista en la Mac llega como notificación con el título y el
      texto reales (no "New activity on your Mac").
- [ ] Con el iPhone desbloqueado y PRBar en primer plano: la notificación aparece (o la lista se actualiza) sin
      duplicados.
- [ ] Tocar la notificación abre PRBar en la pantalla del PR (deep link), desde cerrada y desde segundo plano.
- [ ] El número del ícono sigue al de la Mac.
- [ ] Un switch de notificaciones en Settings del teléfono cambia el de la Mac.

## F. Revocar y desemparejar
- [ ] Revoke… en la Mac (o `prbar remote revoke <teléfono>`): el teléfono pierde la conexión y vuelve a `pair:welcome`
      al abrirlo; no llegan más notificaciones con contenido.
- [ ] Emparejar de nuevo y "Unpair This Mac" en Settings del teléfono: la Mac lo saca de la lista.

## G. Volver a emparejar después de borrar los datos
- [ ] Ajustes › Apps › Safari › Borrar historial y datos (o borrar el ícono y volver a agregarlo): al abrir, "This
      device lost its pairing. Pair it again from your Mac."
- [ ] Revocar la entrada vieja en la Mac, emparejar de nuevo (B): todo funciona, incluidas Face ID y notificaciones.

## H. Android (humo)
- [ ] Chrome en Android: la página ofrece "Install"; instalada, abre en pantalla completa.
- [ ] Emparejar con SAS, ver la lista, recibir una notificación y tocarla.
- [ ] Merge con la huella o el bloqueo de pantalla (passkey de Google): la Mac lo acepta.
