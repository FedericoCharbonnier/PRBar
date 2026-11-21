#!/bin/bash
# The iPhone app end to end on this Mac, without a simulator: builds the Go relay into a temporary folder, runs it on
# 127.0.0.1 (from the tests) and drives the phone's view models over LiveTransport against a real RemoteAccessService
# with fixture PRs. Never touches the deployed relay. Needs Go (brew install go).
set -euo pipefail
# Launched from an x86_64 process (an Intel Homebrew `timeout` or bash in /usr/local), this script and every universal
# tool it starts run under Rosetta: SwiftPM still builds the tests for arm64, so `xctest` (x86_64) can't load the bundle
# and `swift test` fails even when every test passes. Run natively instead.
if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
    exec arch -arm64 /bin/bash "$0" "$@"
fi
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd relay && go build -o "$tmp/prbar-relay" ./cmd/prbar-relay)
cd ios/PRBarMobileKit
PRBAR_RELAY_BIN="$tmp/prbar-relay" swift test --filter PRBarMobileEndToEndTests "$@"
