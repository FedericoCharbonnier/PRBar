#!/bin/bash
# Offline tests for Scripts/iphone-setup.sh: argument parsing and the checks on what the relay and prbar answer (fed
# here with sample answers). Nothing leaves this Mac: no ssh, no network, no installs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/iphone-setup.sh"
# shellcheck source=Scripts/iphone-setup.sh
source "$SCRIPT"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
}
expect() { # expect <name> <command...>: the command succeeds
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
refuse() { # refuse <name> <command...>: the command fails
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}
same() { # same <name> <expected> <actual>
    if [[ "$2" == "$3" ]]; then ok "$1"; else
        bad "$1"
        printf '       expected: %q\n       actual:   %q\n' "$2" "$3"
    fi
}

# Runs parse_args in a subshell with fresh variables; prints the variables it set.
parsed() {
    (
        DO_RELAY=0 DO_MAC=0
        parse_args "$@" || exit $?
        printf '%s|%s\n' "$DO_RELAY" "$DO_MAC"
    )
}

echo "arguments"
same "no arguments" "0|0" "$(parsed)"
same "deploy the relay" "1|0" "$(parsed --deploy-relay)"
same "install on the Mac" "0|1" "$(parsed --install-mac)"
same "both, any order" "1|1" "$(parsed --install-mac --deploy-relay)"
refuse "unknown option" parsed --team-id QWERT12345
refuse "the old APNs option" parsed --apns-key /k/a.p8
refuse "the old iPhone install" parsed --install-iphone
same "help exits 0" "0" "$(
    "$SCRIPT" --help >/dev/null 2>&1
    echo $?
)"
same "bad option exits 2" "2" "$(
    "$SCRIPT" --bogus >/dev/null 2>&1 || echo $?
)"
same "a bad PRBAR_RELAY_HOST exits 2" "2" "$(
    PRBAR_RELAY_HOST='evil.example.com/x' "$SCRIPT" --install-mac >/dev/null 2>&1 || echo $?
)"
same "help never mentions Xcode or APNs" "" "$("$SCRIPT" --help | grep -Ei 'xcode|apns|team id' || true)"

echo "relay host"
expect "the default host" is_host prbar.fcharbonnier.duckdns.org
expect "a subdomain with a dash" is_host my-relay.example.com
refuse "with a scheme" is_host https://relay.example.com
refuse "with a port" is_host relay.example.com:443
refuse "with a path" is_host relay.example.com/x
refuse "with a user" is_host root@relay.example.com
refuse "a bare name" is_host localhost
refuse "empty" is_host ""

echo "health"
expect "ok" health_ok "ok"
expect "ok with a newline" health_ok $'ok\n'
refuse "an error page" health_ok "<html>502 Bad Gateway</html>"
refuse "nothing" health_ok ""

echo "Web Push key"
# 65 bytes: 0x04 and the two coordinates (any bytes will do here).
key="$(printf '\004%064d' 0 | head -c 65 | base64 | tr '+/' '-_' | tr -d '=\n')"
same "the sample key is 87 chars" "87" "${#key}"
expect "the relay's answer" vapid_ok "{\"publicKey\":\"$key\"}"
expect "with spaces" vapid_ok "{ \"publicKey\" : \"$key\" }"
refuse "push disabled (404 page)" vapid_ok "404 page not found"
refuse "an empty key" vapid_ok '{"publicKey":""}'
refuse "a short key" vapid_ok "{\"publicKey\":\"${key:0:43}\"}"
refuse "not an uncompressed point" vapid_ok "{\"publicKey\":\"A${key:1}\"}"
refuse "padded base64" vapid_ok "{\"publicKey\":\"$key=\"}"

echo "web app"
csp="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; connect-src 'self' wss://relay.example.com; media-src 'self' blob:; worker-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
headers=$'HTTP/2 200\r\ncontent-type: text/html; charset=utf-8\r\ncontent-security-policy: '"$csp"$'\r\nx-content-type-options: nosniff\r\n'
page='<!doctype html><html lang="en"><head><title>PRBar</title></head><body></body></html>'
expect "page with its CSP" webapp_ok "$headers" "$page"
expect "HTTP/1.1 and mixed-case headers" webapp_ok "${headers/HTTP\/2 200/HTTP/1.1 200 OK}" "$page"
refuse "no CSP" webapp_ok $'HTTP/2 200\r\ncontent-type: text/html\r\n' "$page"
refuse "a weaker CSP" webapp_ok $'HTTP/2 200\r\ncontent-type: text/html\r\ncontent-security-policy: default-src *\r\n' "$page"
refuse "not 200" webapp_ok "${headers/HTTP\/2 200/HTTP/2 404}" "$page"
refuse "not HTML" webapp_ok "${headers/text\/html/application\/json}" "$page"
refuse "an empty body" webapp_ok "$headers" ""
refuse "no answer" webapp_ok "" ""

echo "phone access on the Mac"
expect "on with this relay" remote_on '{"enabled": true, "relayHost": "relay.example.com"}' relay.example.com
expect "compact JSON" remote_on '{"enabled":true,"relayHost":"relay.example.com","devicesOnline":0}' relay.example.com
refuse "off" remote_on '{"enabled": false, "relayHost": "relay.example.com"}' relay.example.com
refuse "another relay" remote_on '{"enabled": true, "relayHost": "other.example.com"}' relay.example.com
refuse "no relay" remote_on '{"enabled": true}' relay.example.com

echo "phone steps"
steps="$(RELAY_HOST=relay.example.com phone_steps)"
for word in "Settings > iPhone" "Add to Home Screen" "from the new icon" "Pair" "prbar remote pair" "6-digit code" \
    "notifications" "https://relay.example.com/"; do
    if [[ "$steps" == *"$word"* ]]; then ok "mentions $word"; else bad "mentions $word"; fi
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
