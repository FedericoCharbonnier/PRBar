#!/bin/bash
# Enlaza `prbar` en el PATH: <link-dir>/prbar → <target> (el helper de PRBar.app).
# Uso: Scripts/link-cli.sh <target> <link-dir>
# Solo crea el link o reemplaza uno que ya apunta al helper de algún PRBar.app; cualquier otra cosa llamada `prbar`
# (un archivo, una carpeta o un link a otro lado) queda como está, con un aviso.
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
    echo "Usage: Scripts/link-cli.sh <target> <link-dir>" >&2
    exit 2
fi
TARGET="$1"
LINK_DIR="$2"
LINK="$LINK_DIR/prbar"

mkdir -p "$LINK_DIR"
if [[ -L "$LINK" ]]; then
    CURRENT="$(readlink "$LINK")"
    if [[ "$CURRENT" != *PRBar.app/Contents/Helpers/prbar ]]; then
        echo "Warning: $LINK isn’t a link to PRBar (it points to $CURRENT): left as is. Remove it and run this again to link prbar." >&2
        exit 0
    fi
elif [[ -e "$LINK" ]]; then
    echo "Warning: $LINK exists and isn’t a link to PRBar: left as is. Remove it and run this again to link prbar." >&2
    exit 0
fi
# -n: si el link apunta a una carpeta, se reemplaza el link (no se crea otro adentro).
ln -sfn "$TARGET" "$LINK"
echo "CLI: $LINK"
