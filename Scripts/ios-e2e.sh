#!/bin/bash
# The iPhone app end to end on this Mac, without a simulator: builds the Go relay into a temporary folder, runs it on
# 127.0.0.1 (from the tests) and drives the phone's view models over LiveTransport against a real RemoteAccessService
# with fixture PRs. Never touches the deployed relay. Needs Go (brew install go).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd relay && go build -o "$tmp/prbar-relay" ./cmd/prbar-relay)
cd ios/PRBarMobileKit
PRBAR_RELAY_BIN="$tmp/prbar-relay" swift test --filter PRBarMobileEndToEndTests "$@"
