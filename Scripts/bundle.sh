#!/bin/bash
# Compila en release y arma PRBar.app firmado ad-hoc.
# Uso: Scripts/bundle.sh [--install | --output <dir>]
#   (sin opciones)   arma build/PRBar.app
#   --install        además lo instala en ~/Applications y lo abre
#   --output <dir>   arma <dir>/PRBar.app y no instala ni cierra nada (lo usa el actualizador de PRBar)
set -euo pipefail

usage() {
    echo "Usage: Scripts/bundle.sh [--install | --output <dir>]" >&2
    exit 2
}

INSTALL=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)
            INSTALL=1
            shift
            ;;
        --output)
            [[ $# -ge 2 && -n "$2" ]] || usage
            OUT_DIR="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done
if [[ $INSTALL == 1 && -n "$OUT_DIR" ]]; then usage; fi

# Una carpeta relativa en --output es relativa a donde se llamó el script, no a la raíz del repo.
if [[ -n "$OUT_DIR" && "$OUT_DIR" != /* ]]; then OUT_DIR="$PWD/$OUT_DIR"; fi

cd "$(dirname "$0")/.."
OUT_DIR="${OUT_DIR:-build}"

swift build -c release --product PRBar
BIN="$(swift build -c release --show-bin-path)/PRBar"
APP="$OUT_DIR/PRBar.app"

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PRBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Bundle listo: $APP"

if [[ $INSTALL == 1 ]]; then
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
