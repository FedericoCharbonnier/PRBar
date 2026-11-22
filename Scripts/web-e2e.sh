#!/bin/bash
# La web app (PWA) punta a punta en esta Mac: compila la web en modo e2e (`npm run build:e2e`), la embebe en una copia
# del relay de Go en una carpeta temporal (el repo no se toca), compila la Mac simulada (`prbar-remote-fixture`) y
# corre Playwright (Chromium con autenticador WebAuthn virtual y WebKit). Cada archivo de pruebas levanta su propio
# relay en modo test en 127.0.0.1 (puerto libre), su servicio de push falso y su Mac simulada. Nunca toca el relay
# desplegado. Necesita Go, Node 24 y los navegadores de Playwright (`npx playwright install chromium webkit`).
#
#   Scripts/web-e2e.sh [argumentos de playwright, p. ej. --project chromium]
set -euo pipefail
# Lanzado desde un proceso x86_64 (un bash o `timeout` de Homebrew en /usr/local), esto y cada herramienta universal
# que arranca corren bajo Rosetta: SwiftPM compilaría para otra arquitectura. Se corre nativo.
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
    exec arch -arm64 /bin/bash "$0" "$@"
fi
cd "$(dirname "$0")/.."
root=$(pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> web (build:e2e)"
# npm ci solo si cambió package-lock.json desde la última instalación (el hash queda en node_modules).
lock_hash=$(shasum -a 256 web/package-lock.json | cut -d' ' -f1)
stamp=web/node_modules/.prbar-lock-sha256
if [[ ! -d web/node_modules || "$(cat "$stamp" 2>/dev/null)" != "$lock_hash" ]]; then
    (cd web && npm ci)
    echo "$lock_hash" > "$stamp"
fi
(cd web && npm run build:e2e >/dev/null)

echo "==> relay (con la web embebida, en $tmp)"
rsync -a --exclude internal/web/dist relay/ "$tmp/relay/"
mkdir -p "$tmp/relay/internal/web/dist"
cp -R web/dist/. "$tmp/relay/internal/web/dist/"
(cd "$tmp/relay" && go build -o "$tmp/prbar-relay" ./cmd/prbar-relay)

echo "==> prbar-remote-fixture"
swift build --product prbar-remote-fixture >/dev/null
fixture="$(swift build --product prbar-remote-fixture --show-bin-path)/prbar-remote-fixture"

echo "==> playwright"
cd web
PRBAR_RELAY_BIN="$tmp/prbar-relay" PRBAR_FIXTURE_BIN="$fixture" PRBAR_E2E_TMP="$tmp" \
    npx playwright test "$@"
