#!/bin/bash
# Compila en release, arma PRBar.app, firma ad-hoc y opcionalmente lo instala en ~/Applications.
# Uso: Scripts/bundle.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product PRBar
BIN="$(swift build -c release --show-bin-path)/PRBar"
APP="build/PRBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PRBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Bundle listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x PRBar || true
    # Esperar (hasta ~5 s) a que el proceso viejo salga; si no, `open` falla con LSOpen -600.
    for _ in $(seq 1 50); do
        pgrep -x PRBar >/dev/null || break
        sleep 0.1
    done
    if pgrep -x PRBar >/dev/null; then
        echo "PRBar sigue corriendo; se fuerza el cierre." >&2
        pkill -9 -x PRBar || true
        sleep 0.5
    fi
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/PRBar.app"
    cp -R "$APP" "$HOME/Applications/PRBar.app"
    # LaunchServices a veces devuelve -600 justo después de reemplazar el bundle: reintentar.
    for attempt in 1 2 3 4 5; do
        if open "$HOME/Applications/PRBar.app" 2>/dev/null; then break; fi
        if [[ $attempt == 5 ]]; then echo "No se pudo abrir PRBar.app (LSOpen)." >&2; exit 1; fi
        sleep 1
    done
    echo "Instalado y abierto: ~/Applications/PRBar.app"
fi
