#!/usr/bin/env bash
# Sube el código del relay al VPS, construye la imagen allí y levanta el contenedor (spec P.10, plan 17 Task 15).
# Requiere OK explícito del usuario: toca el server. Los secretos (.env y .p8) ya tienen que estar en
# /root/stack/env/ (este script no los crea ni los copia).
set -euo pipefail

SERVER="${PRBAR_RELAY_SERVER:?set PRBAR_RELAY_SERVER=root@your-vps}"
REMOTE=/root/stack/prbar-relay
HERE="$(cd "$(dirname "$0")/.." && pwd)"

read -r -p "Deploy prbar-relay to ${SERVER}:${REMOTE}? Type 'deploy' to continue: " answer
[ "$answer" = "deploy" ] || { echo "Cancelled."; exit 1; }

ssh "$SERVER" "test -f /root/stack/env/prbar-relay.env && test -f /root/stack/env/prbar-relay.p8" \
  || { echo "Missing /root/stack/env/prbar-relay.env or .p8 on the server."; exit 1; }
ssh "$SERVER" "mkdir -p ${REMOTE}/src"
rsync -a --delete --exclude .git --exclude '*.db' --exclude deploy/prbar-relay.env "$HERE/" "$SERVER:${REMOTE}/src/"
scp "$HERE/deploy/docker-compose.yml" "$SERVER:${REMOTE}/docker-compose.yml"
ssh "$SERVER" "cd ${REMOTE} && docker build -t prbar-relay:vps src && docker compose up -d && docker image prune -f"
echo "Deployed. Check: curl -sI https://prbar.fcharbonnier.duckdns.org/healthz"
