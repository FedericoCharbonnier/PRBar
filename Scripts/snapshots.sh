#!/bin/bash
# Renders PRBar's screens with fictional sample data into PNGs (for presentations) and lists them.
# Builds the bundle without installing it and runs it in snapshot mode: nothing real starts (no refresh,
# gh, git, claude, Slack or notifications) and nothing is written outside the output folder.
# Usage: Scripts/snapshots.sh [output-dir] [light|dark|both]   (defaults: docs/screenshots, both)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/screenshots}"
APPEARANCE="${2:-both}"

Scripts/bundle.sh
build/PRBar.app/Contents/MacOS/PRBar --snapshots "$OUT" --appearance "$APPEARANCE"
echo
ls -l "$OUT"/*.png
