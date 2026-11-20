#!/bin/bash
# Compila en release y arma PRBar.app firmado ad-hoc.
# Uso: Scripts/bundle.sh [--install | --output <dir>]
#   (sin opciones)   arma build/PRBar.app
#   --install        además lo instala en ~/Applications y lo abre
#   --output <dir>   arma <dir>/PRBar.app y no instala ni cierra nada (lo usa el actualizador de PRBar)
#   (siempre) copia la CLI a PRBar.app/Contents/Helpers/prbar; con --install la enlaza en ~/.local/bin/prbar (o $PRBAR_BIN_DIR)
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

# Por producto: `swift build` a secas también compila los plugins de swift-argument-parser, que no enlazan con
# algunas Command Line Tools.
swift build -c release --product PRBar
swift build -c release --product PRBarCLI
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/PRBar"
APP="$OUT_DIR/PRBar.app"

mkdir -p "$OUT_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/PRBar"
# La CLI (spec C.3). Se llama `prbar` dentro del bundle; en .build es PRBarCLI (APFS no distingue mayúsculas).
cp "$BIN_DIR/PRBarCLI" "$APP/Contents/Helpers/prbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Primero el helper y después el bundle (que sella lo que tiene adentro).
codesign --force --sign - "$APP/Contents/Helpers/prbar"
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
    # `prbar` en el PATH: un link al helper del bundle instalado (sigue valiendo después de actualizar).
    LINK_DIR="${PRBAR_BIN_DIR:-$HOME/.local/bin}"
    mkdir -p "$LINK_DIR"
    ln -sf "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" "$LINK_DIR/prbar"
    echo "CLI: $LINK_DIR/prbar"
    case ":$PATH:" in
        *":$LINK_DIR:"*) ;;
        *) echo "Aviso: $LINK_DIR no está en tu PATH. Agregá a ~/.zshrc: export PATH=\"$LINK_DIR:\$PATH\"" >&2 ;;
    esac
fi
