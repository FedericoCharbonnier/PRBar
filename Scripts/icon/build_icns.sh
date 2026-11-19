#!/bin/bash
# Regenera Resources/AppIcon.icns a partir de make_icon.swift (variante clara).
# Cada tamaño se dibuja directamente a su resolución; los de 64 px o menos usan la variante simplificada
# (sin sombras ni destello, glifo más grueso).
set -euo pipefail
cd "$(dirname "$0")/../.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/AppIcon.iconset"
for px in 16 32 64 128 256 512 1024; do
    swift Scripts/icon/make_icon.swift "$TMP/icon_$px.png" light "$px"
done
for s in 16 32 128 256 512; do
    cp "$TMP/icon_$s.png" "$TMP/AppIcon.iconset/icon_${s}x${s}.png"
    cp "$TMP/icon_$((s * 2)).png" "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns actualizado"
