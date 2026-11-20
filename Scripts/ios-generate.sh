#!/bin/bash
# Generates ios/PRBarMobile.xcodeproj from ios/project.yml (plan 19). The project file is not versioned.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen is missing: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate --spec ios/project.yml --project ios --quiet

if [ ! -f ios/Config/Local.xcconfig ]; then
    echo "note: ios/Config/Local.xcconfig is missing. Simulator builds work without it; to build for an iPhone run" >&2
    echo "  cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig" >&2
    echo "and set DEVELOPMENT_TEAM to your Team ID." >&2
fi
echo "Generated ios/PRBarMobile.xcodeproj"
