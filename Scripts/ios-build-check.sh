#!/bin/bash
# Compiles the iPhone app for the simulator and for the device SDK (unsigned), plus the test bundle, without a run
# destination. Use it when Xcode has no iOS 26 platform/simulator installed (xcodebuild then finds no destination for
# the scheme, and the asset catalog can't compile without a matching simulator runtime, so it is left out here).
# With the iOS platform installed, prefer the scheme commands in docs/ios.md.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/ios-generate.sh >/dev/null
OUT="$PWD/ios/.build-xcode"
COMMON=(-project ios/PRBarMobile.xcodeproj -configuration Debug ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
        EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets SYMROOT="$OUT/Build" OBJROOT="$OUT/Obj")

mkdir -p "$OUT"
run() {
    echo "== $*"
    local log="$OUT/last-build.log"
    if xcodebuild "${COMMON[@]}" "$@" build >"$log" 2>&1; then
        grep -E "warning: .*\.swift" "$log" | sort -u || true
        echo "BUILD SUCCEEDED"
    else
        grep -E "error:" "$log" | sort -u
        echo "BUILD FAILED (full log: $log)"
        exit 1
    fi
}

run -target PRBarMobile -sdk iphonesimulator
run -target PRBarMobile -sdk iphoneos CODE_SIGNING_ALLOWED=NO
run -target PRBarMobileTests -sdk iphonesimulator
