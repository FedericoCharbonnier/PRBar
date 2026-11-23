#!/bin/bash
# Compila en release y arma PRBar.app, firmado con un certificado local de esta Mac (ad-hoc si no se puede).
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
# --force-resolved-versions: exactamente lo de Package.resolved (el actualizador nunca resuelve otra versión).
swift build -c release --force-resolved-versions --product PRBar
swift build -c release --force-resolved-versions --product PRBarCLI
BIN_DIR="$(swift build -c release --force-resolved-versions --show-bin-path)"
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
# Firma. Ad-hoc, macOS reconoce la app por el hash de esta compilación: cada versión nueva parece otra app y vuelve a
# pedir los permisos (llavero, carpetas, notificaciones). Con un certificado propio de esta Mac (autofirmado, en el
# llavero de login, se crea la primera vez) la app sigue siendo la misma entre versiones. Si no se puede, ad-hoc.
# PRBAR_SIGN_IDENTITY: otra identidad (nombre o SHA-1); "-" fuerza ad-hoc.
SIGN_NAME="PRBar Local Signing"

# SHA-1 de la identidad (certificado + clave) local, o nada.
local_identity() {
    security find-identity -p codesigning 2>/dev/null |
        awk -v name="\"$SIGN_NAME\"" 'index($0, name) { print $2; exit }'
}

create_local_identity() {
    local keychain tmp pass
    keychain="$(security login-keychain 2>/dev/null | tr -d ' "')"
    [[ -n "$keychain" ]] || return 1
    tmp="$(mktemp -d)"
    pass="$(/usr/bin/openssl rand -hex 16)"
    cat > "$tmp/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$SIGN_NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
    # /usr/bin/openssl (LibreSSL): el PKCS#12 de OpenSSL 3 (Homebrew) no lo importa `security` ("MAC verification failed").
    if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$tmp/cfg" \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 &&
        /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_NAME" \
            -out "$tmp/id.p12" -passout "pass:$pass" >/dev/null 2>&1 &&
        security import "$tmp/id.p12" -k "$keychain" -P "$pass" -T /usr/bin/codesign >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

sign_with() {
    # Primero el helper y después el bundle (que sella lo que tiene adentro).
    codesign --force --sign "$1" "$APP/Contents/Helpers/prbar" &&
        codesign --force --sign "$1" "$APP" &&
        codesign --verify --strict "$APP"
}

IDENTITY="${PRBAR_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(local_identity)"
    if [[ -z "$IDENTITY" ]]; then
        echo "Creando el certificado \"$SIGN_NAME\" en el llavero (una sola vez)…"
        create_local_identity && IDENTITY="$(local_identity)"
    fi
fi
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] && sign_with "$IDENTITY"; then
    echo "Firmado con $SIGN_NAME ($IDENTITY)"
else
    [[ "$IDENTITY" == "-" ]] || echo "Aviso: no se pudo firmar con un certificado local; se firma ad-hoc (macOS va a volver a pedir permisos)." >&2
    sign_with -
fi
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
    # No pisa un `prbar` que no sea un link a PRBar (otra herramienta con el mismo nombre).
    LINK_DIR="${PRBAR_BIN_DIR:-$HOME/.local/bin}"
    Scripts/link-cli.sh "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" "$LINK_DIR"
    case ":$PATH:" in
        *":$LINK_DIR:"*) ;;
        *) echo "Aviso: $LINK_DIR no está en tu PATH. Agregá a ~/.zshrc: export PATH=\"$LINK_DIR:\$PATH\"" >&2 ;;
    esac
fi
