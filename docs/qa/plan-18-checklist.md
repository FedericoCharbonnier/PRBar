# QA manual — Plan 18 (acceso desde el iPhone, lado Mac)

Hace falta el relay desplegado (Plan 17, con el OK del usuario) y su `RELAY_ENROLL_TOKEN`. Hasta que exista la app del
iPhone (Plan 19), el "teléfono" es el simulado de los tests (`RemoteClient`). Nada de esto corre contra el relay real
dentro de la suite: la suite usa `InMemoryRelay` y, con `PRBAR_RELAY_BIN`, el binario del relay en `127.0.0.1`.

Antes de empezar, con el relay local:

```
(cd relay && go build -o /tmp/prbar-relay ./cmd/prbar-relay)
PRBAR_RELAY_BIN=/tmp/prbar-relay swift run PRBarTests "integration"
```

## A. Habilitar
- [ ] Settings › iPhone sin link de instalación: "The iPhone app isn’t on TestFlight yet — install it from Xcode (see
      docs/iphone.md)", sin QR. "Allow iPhone remote control" apagado, estado "Disabled", Pair iPhone… deshabilitado.
- [ ] Prender el toggle: hoja con "Relay server" (`prbar.fcharbonnier.duckdns.org` ya escrito) y "Enrollment token"
      (campo seguro). Un token equivocado: "The relay refused the enrollment token." y nada queda habilitado. Cinco
      intentos fallidos: "Too many attempts. Try again in 15 minutes."
- [ ] Con el token bueno: "Connected to prbar.… · 0 iPhones online". `prbar remote status` dice lo mismo.
      `config.json` tiene `remote.accountId` y **no** el token ni ninguna clave (`grep -i token ~/Library/Application\ Support/PRBar/config.json`).
- [ ] Llavero › "PRBar Remote" tiene `mac-relay`, `mac-noise` y `mac-seal` (y nada más).
- [ ] Apagar y prender: no pide el token otra vez. `prbar remote disable` / `prbar remote enable` igual.
- [ ] `prbar remote enable --relay http://algo` → error de host; `--enroll-token-stdin < archivo` funciona sin TTY.

## B. Conexión
- [ ] Cortar el Wi-Fi: "Offline — retrying in N s" con la cuenta regresiva; al volver la red reconecta enseguida (no
      espera el backoff).
- [ ] Dormir la Mac (menú Apple › Dormir): en los logs del relay la conexión de la Mac se cierra al dormir (no 20 s
      después); al despertar reconecta sola.
- [ ] Salir de PRBar: la conexión se cierra; abrir de nuevo: conecta sola si estaba habilitado.
- [ ] `~/Library/Logs/PRBar/prbar.log`: solo nombres de comando y prefijos de 4 caracteres ("iPhone abcd: status"),
      nunca argumentos, PRs, tokens ni contenido.

## C. Emparejar (con el teléfono simulado)
- [ ] `prbar remote pair` en Terminal (tema oscuro **y** claro): el QR se lee con la cámara del iPhone (abre el link
      `prbar://pair?…`; sin la app instalada, iOS dice que no hay app, está bien). Muestra "Waiting for your iPhone…
      (expires in 5:00)". Con el teléfono simulado (copiar el link de respaldo y correr
      `PRBAR_PAIR_URL='prbar://pair?…' swift run PRBarTests "remote smoke"`) aparece "Does your iPhone show 123 456?
      [y/N]" con el mismo código que imprime el test: `y` empareja, `n` cancela y la ranura se cierra. El test pide
      status y espera a que lo revoques desde la Mac.
- [ ] `prbar remote pair | cat` (sin TTY): "Pairing needs a terminal to show the QR code." y sale con 2.
- [ ] Settings › iPhone › Pair iPhone…: QR grande, "Expires in 4:59 · works once" contando. Mientras la hoja está
      abierta, el QR de instalación (si hay link) queda oculto ("Hidden while pairing").
- [ ] Cuando el teléfono se une: el código grande, el nombre y el modelo, **Codes Match** / Cancel. Codes Match →
      aparece en la lista con "Online", Face ID requerido.
- [ ] Esperar 5 min sin escanear: la hoja dice que venció; escanear después no funciona.
- [ ] Un segundo "Pair iPhone…" cancela la ranura anterior.

## D. Dispositivos
- [ ] La lista muestra nombre, modelo, "Paired <fecha>", "Online" / "Last seen 5 min ago", "Require Face ID" y Revoke….
- [ ] Revoke… pide confirmación; después el teléfono simulado recibe "removed" y no puede volver a conectar aunque el
      relay no lo diera de baja. `prbar remote revoke <prefijo>` igual.
- [ ] `prbar remote devices --require-face-id <id> off` destilda el checkbox; el teléfono recibe la política nueva.
- [ ] Reset iPhone Access… (confirmación destructiva): sin dispositivos, sin cuenta, claves nuevas en el llavero; hay
      que habilitar con el token otra vez.

## E. Keep awake, buzón, notificaciones
- [ ] "Keep this Mac awake while charging" prendido y enchufado: `pmset -g assertions | grep PRBar` muestra
      "PRBar: iPhone remote access" (PreventUserIdleSystemSleep). Desenchufar: desaparece. Volver a enchufar: una sola.
      Apagar el acceso: desaparece.
- [ ] Buzón prendido: a los 60 s de un cambio, el relay tiene un blob `home` por teléfono (`mbox.get` desde el teléfono
      simulado lo abre). `prbar remote mailbox off`: el blob queda vacío.
- [ ] Una notificación de la Mac (p. ej. un review que termina) llega al teléfono simulado como push cifrado con el
      mismo título y el deep link correcto (con APNs configurado en el relay).

## F. Get PRBar for iPhone
- [ ] `prbar remote app-link set https://testflight.apple.com/join/XXXX`: Settings › iPhone muestra el QR, "Copy Link"
      copia el link y "Open Link" lo abre en el navegador. Escanear el QR con la cámara abre TestFlight.
- [ ] `prbar remote app-link set http://testflight.apple.com/…` o `https://evil.example.com/…` → error.
      `prbar remote app-link clear` vuelve al texto de Xcode.
