#!/usr/bin/env bash
# Sube el código del relay y de la web app al VPS, construye la imagen allí y levanta el contenedor (spec P.10 y W.7).
# Requiere OK explícito del usuario: toca el server. El .env ya tiene que estar en /root/stack/env/ (este script no lo
# crea ni lo copia); lo único que le agrega, la primera vez, es la clave VAPID de Web Push (spec W.6), generada en el
# server y nunca impresa. Antes de reiniciar el relay, la imagen nueva valida el .env (prbar-relay -check-config): si
# algo no vale, el relay que está corriendo queda como está.
#
#   PRBAR_RELAY_SERVER=root@your-vps [PRBAR_RELAY_HOST=relay.example.org] relay/deploy/deploy.sh
set -euo pipefail

SERVER="${PRBAR_RELAY_SERVER:?set PRBAR_RELAY_SERVER=root@your-vps}"
RELAY_HOST="${PRBAR_RELAY_HOST:-prbar.fcharbonnier.duckdns.org}"
REMOTE=/root/stack/prbar-relay
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

read -r -p "Deploy prbar-relay to ${SERVER}:${REMOTE}? Type 'deploy' to continue: " answer
[ "$answer" = "deploy" ] || { echo "Cancelled."; exit 1; }

ssh "$SERVER" "test -f /root/stack/env/prbar-relay.env" \
  || { echo "Missing /root/stack/env/prbar-relay.env on the server."; exit 1; }

# Clave VAPID: solo se genera si no hay línea VAPID_PRIVATE_KEY= o si está vacía (como en el .env.example). Una línea
# con un valor no se toca nunca, ni aunque parezca mal escrita: cambiar la clave invalidaría las suscripciones de
# todos los teléfonos. Si el valor no vale, lo dice -check-config más abajo y el deploy frena.
ssh "$SERVER" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail
env_file=/root/stack/env/prbar-relay.env
if grep -Eq '^VAPID_PRIVATE_KEY=.*[^[:space:]]' "$env_file"; then
  echo "VAPID key: present, left as is."
  exit 0
fi
umask 077
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
openssl ecparam -name prime256v1 -genkey -noout -outform DER -out "$tmp" 2>/dev/null
# SEC1 ECPrivateKey en DER: 30 77 02 01 01 04 20 ‖ d (32 bytes) ‖ parámetros y pública.
[ "$(head -c 7 "$tmp" | od -An -tx1 | tr -d ' \n')" = "30770201010420" ] \
  || { echo "VAPID key: unexpected format from openssl, nothing changed."; exit 1; }
key="$(tail -c +8 "$tmp" | head -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')"
[ "${#key}" -eq 43 ] || { echo "VAPID key: couldn't encode it, nothing changed."; exit 1; }
# Solo se borra la línea vacía (si la hay), nunca una con valor.
sed -i '/^VAPID_PRIVATE_KEY=[[:space:]]*$/d' "$env_file"
printf 'VAPID_PRIVATE_KEY=%s\n' "$key" >> "$env_file"
chmod 600 "$env_file"
echo "VAPID key: generated and stored in $env_file."
REMOTE_SCRIPT

# Contexto de build = la raíz del repo, pero solo relay/ y web/ (sin dependencias ni builds locales).
ssh "$SERVER" "mkdir -p ${REMOTE}/src"
rsync -a --delete --delete-excluded \
  --exclude .git --exclude node_modules --exclude .DS_Store --exclude '*.db' \
  --exclude /web/dist --exclude /relay/deploy/prbar-relay.env --exclude /relay/prbar-relay \
  --exclude /relay/wsprobe-state.json \
  --include '/relay/***' --include '/web/***' --exclude '*' \
  "$ROOT/" "$SERVER:${REMOTE}/src/"
scp "$HERE/deploy/docker-compose.yml" "$SERVER:${REMOTE}/docker-compose.yml"
ssh "$SERVER" "cd ${REMOTE} && docker build -f src/relay/Dockerfile -t prbar-relay:vps src"

# El .env pasa por Compose igual que al arrancar (comillas, espacios), y la imagen nueva lo valida con el mismo código
# que el relay. Un contenedor de un solo uso, sin rutas de Traefik.
if ! ssh "$SERVER" "cd ${REMOTE} && docker compose run --rm --no-deps -l traefik.enable=false prbar-relay -check-config"; then
  echo "/root/stack/env/prbar-relay.env on the server isn't valid (see above). Fix it by hand; nothing was restarted."
  exit 1
fi
ssh "$SERVER" "cd ${REMOTE} && docker compose up -d && docker image prune -f"
echo "Deployed. Check: curl -sI https://${RELAY_HOST}/healthz"
