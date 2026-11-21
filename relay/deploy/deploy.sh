#!/usr/bin/env bash
# Sube el código del relay y de la web app al VPS, construye la imagen allí y levanta el contenedor (spec P.10 y W.7).
# Requiere OK explícito del usuario: toca el server. El .env ya tiene que estar en /root/stack/env/ (este script no lo
# crea ni lo copia); lo único que le agrega, la primera vez, es la clave VAPID de Web Push (spec W.6), generada en el
# server y nunca impresa.
set -euo pipefail

SERVER="${PRBAR_RELAY_SERVER:?set PRBAR_RELAY_SERVER=root@your-vps}"
REMOTE=/root/stack/prbar-relay
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

read -r -p "Deploy prbar-relay to ${SERVER}:${REMOTE}? Type 'deploy' to continue: " answer
[ "$answer" = "deploy" ] || { echo "Cancelled."; exit 1; }

ssh "$SERVER" "test -f /root/stack/env/prbar-relay.env" \
  || { echo "Missing /root/stack/env/prbar-relay.env on the server."; exit 1; }

# Clave VAPID: si falta, se genera en el server (P-256 con openssl) y se guarda el escalar d (32 bytes) en base64url
# sin relleno. Una clave válida no se reemplaza nunca: cambiarla invalidaría las suscripciones de los teléfonos.
ssh "$SERVER" 'bash -s' <<'REMOTE_SCRIPT'
set -euo pipefail
env_file=/root/stack/env/prbar-relay.env
if grep -Eq '^VAPID_PRIVATE_KEY=[A-Za-z0-9_-]{43}$' "$env_file"; then
  echo "VAPID key: present."
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
sed -i '/^VAPID_PRIVATE_KEY=/d' "$env_file"
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
ssh "$SERVER" "cd ${REMOTE} && docker build -f src/relay/Dockerfile -t prbar-relay:vps src && docker compose up -d && docker image prune -f"
echo "Deployed. Check: curl -sI https://prbar.fcharbonnier.duckdns.org/healthz"
