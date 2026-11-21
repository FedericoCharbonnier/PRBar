#!/bin/bash
# The steps left to use PRBar on your phone, the web app the relay serves (plan 20, docs/iphone.md). Each step is
# idempotent and asks before doing anything outside this repo (the server, ~/Applications, PRBar's settings).
#
#   Scripts/iphone-setup.sh                          what's done and what's left (changes nothing)
#   PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --deploy-relay
#                                                    deploys the relay and the web app (relay/deploy/deploy.sh; the
#                                                    first time it also makes the Web Push key on the server)
#   PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --install-mac
#                                                    this branch's PRBar on the Mac + phone access on
#
# Both steps in one run go in this order: relay, Mac. Then it prints what to do on the phone.
# PRBAR_RELAY_SERVER: ssh destination of the relay's server (never in the repo). PRBAR_RELAY_HOST: the relay's public
# host (default prbar.fcharbonnier.duckdns.org). Tests: Scripts/iphone-setup-tests.sh (offline).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_HOST="${PRBAR_RELAY_HOST:-prbar.fcharbonnier.duckdns.org}"
REMOTE_ENV=/root/stack/env/prbar-relay.env
RELAY_CONTAINER=prbar-relay

# ---------------------------------------------------------------------------------------------------------------------
# Output and questions

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# Asks on the terminal (never reads the answer from a pipe). Only "y" or "yes" goes ahead.
confirm() {
    local answer=""
    if [[ ! -r /dev/tty ]]; then
        die "needs a terminal to ask: $1"
    fi
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r answer </dev/tty || answer=""
    case "$answer" in
        y | Y | yes | YES | Yes) return 0 ;;
        *)
            say "Skipped."
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------------------------------------------------
# Checks on what the relay answers (pure: tested offline by Scripts/iphone-setup-tests.sh)

# A relay host: a DNS name, no scheme, port, path or user.
is_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# Body of GET /healthz.
health_ok() { [[ "$(printf '%s' "$1" | tr -d '\r\n')" == "ok" ]]; }

# Body of GET /v1/vapid: {"publicKey":"<65-byte uncompressed P-256 point in base64url, 87 chars, starts with 04>"}.
vapid_ok() {
    local key
    key="$(printf '%s' "$1" | sed -n 's/.*"publicKey"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | head -n 1)"
    [[ ${#key} -eq 87 && "$key" == B* ]]
}

# Headers and body of GET /: 200, an HTML page, and the web app's CSP (spec W.7).
webapp_ok() {
    local headers="$1" body="$2" first
    first="$(printf '%s\n' "$headers" | head -n 1 | tr -d '\r')"
    [[ "$first" =~ ^HTTP/[0-9.]+\ 200 ]] || return 1
    printf '%s\n' "$headers" | tr -d '\r' | grep -Eiq "^content-type:[[:space:]]*text/html" || return 1
    printf '%s\n' "$headers" | tr -d '\r' |
        grep -Eiq "^content-security-policy:.*default-src 'self'.*frame-ancestors 'none'" || return 1
    printf '%s' "$body" | grep -iq '<html' || return 1
}

# Output of `prbar remote status --json`: phone access on, with this relay.
remote_on() {
    local status="$1" host="$2"
    printf '%s' "$status" | grep -q '"enabled" *: *true' &&
        printf '%s' "$status" | grep -q "\"relayHost\" *: *\"$host\""
}

# ---------------------------------------------------------------------------------------------------------------------
# Talking to the relay (read-only HTTPS)

fetch() { curl -fsS --max-time 10 "https://$RELAY_HOST$1" 2>/dev/null; }

relay_healthy() { health_ok "$(fetch /healthz || true)"; }
relay_push_on() { vapid_ok "$(fetch /v1/vapid || true)"; }
relay_serves_webapp() {
    local headers body
    headers="$(curl -sS --max-time 10 -D - -o /dev/null "https://$RELAY_HOST/" 2>/dev/null || true)"
    body="$(fetch / || true)"
    webapp_ok "$headers" "$body"
}

# ---------------------------------------------------------------------------------------------------------------------
# Arguments

DO_RELAY=0
DO_MAC=0

usage() {
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Fills the variables above; returns 2 (with a message) on anything it doesn't understand.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --deploy-relay) DO_RELAY=1 && shift ;;
            --install-mac) DO_MAC=1 && shift ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                printf 'error: unknown option %s (see --help).\n' "$1" >&2
                return 2
                ;;
        esac
    done
    if ! is_host "$RELAY_HOST"; then
        printf "error: PRBAR_RELAY_HOST '%s' isn't a host name.\n" "$RELAY_HOST" >&2
        return 2
    fi
    return 0
}

need_server() {
    [[ -n "${PRBAR_RELAY_SERVER:-}" ]] ||
        die "set PRBAR_RELAY_SERVER to the relay server's ssh destination (e.g. PRBAR_RELAY_SERVER=root@your-vps)."
    [[ "$PRBAR_RELAY_SERVER" != -* ]] || die "PRBAR_RELAY_SERVER can't start with '-'."
}

# ---------------------------------------------------------------------------------------------------------------------
# Steps

do_relay() {
    step "Relay and web app on the server"
    need_server
    say "relay/deploy/deploy.sh copies relay/ and web/ to $PRBAR_RELAY_SERVER, builds the image there (the web app"
    say "included) and restarts the relay. The first time it also makes the Web Push (VAPID) key in the relay's"
    say "settings on the server; it's never shown and never replaced once there. Connected Macs and phones reconnect"
    say "by themselves. It asks you to type 'deploy' before touching the server."
    PRBAR_RELAY_SERVER="$PRBAR_RELAY_SERVER" "$ROOT/relay/deploy/deploy.sh" || die "the deploy didn't finish."

    local ok=0 _
    for _ in $(seq 1 30); do
        if relay_healthy; then
            ok=1
            break
        fi
        sleep 1
    done
    [[ $ok == 1 ]] || die "https://$RELAY_HOST/healthz doesn't answer. Look at: ssh $PRBAR_RELAY_SERVER docker logs $RELAY_CONTAINER"
    say "https://$RELAY_HOST/healthz answers."
    relay_push_on || die "https://$RELAY_HOST/v1/vapid has no key: push is off (ssh $PRBAR_RELAY_SERVER docker logs $RELAY_CONTAINER)."
    say "Push is on (https://$RELAY_HOST/v1/vapid has the key)."
    relay_serves_webapp || die "https://$RELAY_HOST/ doesn't serve the web app with its security headers."
    say "The web app is served at https://$RELAY_HOST/."
}

prbar_cli() { "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" "$@"; }

do_mac() {
    step "PRBar on this Mac"
    say "This builds this branch (release) and installs it as ~/Applications/PRBar.app with Scripts/bundle.sh --install."
    say "It replaces the PRBar you have installed (quits it first) and links prbar in ~/.local/bin."
    if confirm "Build and install this branch's PRBar now?"; then
        (cd "$ROOT" && Scripts/bundle.sh --install)
    fi
    [[ -x "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" ]] || die "no PRBar in ~/Applications."

    step "Phone access on this Mac"
    local _ status=""
    for _ in $(seq 1 30); do
        if status="$(prbar_cli remote status --json 2>/dev/null)"; then break; fi
        sleep 1
    done
    [[ -n "$status" ]] || die "PRBar doesn't answer (is it running? open ~/Applications/PRBar.app)."
    if remote_on "$status" "$RELAY_HOST"; then
        say "Already on with $RELAY_HOST."
        prbar_cli remote status
        return 0
    fi
    need_server
    say "PRBar creates this Mac's account on $RELAY_HOST with the relay's enrollment token. The token goes from"
    say "$PRBAR_RELAY_SERVER straight into prbar (ssh into stdin): it isn't shown, saved or kept by PRBar."
    confirm "Turn on phone access with $RELAY_HOST now?" || return 0
    # The token never touches a variable, the terminal or the disk.
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" "sed -n 's/^RELAY_ENROLL_TOKEN=//p' $REMOTE_ENV | head -n 1" |
        prbar_cli remote enable --relay "$RELAY_HOST" --enroll-token-stdin
}

phone_steps() {
    step "On the phone (iOS 16.4 or newer)"
    say "1. On the Mac: PRBar > Settings > iPhone shows \"Open PRBar on your phone\". Scan that QR with the iPhone's"
    say "   Camera (or open https://$RELAY_HOST/ in Safari)."
    say "2. In Safari: Share > Add to Home Screen."
    say "3. Open PRBar from the new icon on the Home Screen (not from Safari)."
    say "4. Tap Pair. On the Mac run: prbar remote pair (or Settings > iPhone > Pair iPhone...), and scan its QR."
    say "5. Check that the 6-digit code is the same on both screens and confirm it on both."
    say "6. Allow notifications when PRBar asks."
}

status() {
    step "Status (nothing changed)"
    if relay_healthy; then
        say "[x] Relay at https://$RELAY_HOST/healthz"
    else
        say "[ ] Relay at https://$RELAY_HOST/healthz doesn't answer: --deploy-relay (needs PRBAR_RELAY_SERVER)"
    fi
    if relay_push_on; then
        say "[x] Push on (/v1/vapid has the key)"
    else
        say "[ ] Push off (no key at /v1/vapid): --deploy-relay makes it"
    fi
    if relay_serves_webapp; then
        say "[x] Web app served at https://$RELAY_HOST/ (with its CSP)"
    else
        say "[ ] Web app not served at https://$RELAY_HOST/ (or without its CSP): --deploy-relay"
    fi
    if [[ -x "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" ]]; then
        say "[x] PRBar in ~/Applications (--install-mac installs this branch's build)"
        local status=""
        status="$(prbar_cli remote status --json 2>/dev/null || true)"
        if [[ -z "$status" ]]; then
            say "[?] Phone access: PRBar doesn't answer (is it running?)"
        elif remote_on "$status" "$RELAY_HOST"; then
            say "[x] Phone access on with $RELAY_HOST"
        else
            say "[ ] Phone access off (or with another relay): --install-mac turns it on (needs PRBAR_RELAY_SERVER)"
        fi
    else
        say "[ ] PRBar in ~/Applications: --install-mac"
        say "[ ] Phone access: --install-mac"
    fi
}

main() {
    parse_args "$@" || exit 2
    if [[ $DO_RELAY == 0 && $DO_MAC == 0 ]]; then
        status
    fi
    [[ $DO_RELAY == 0 ]] || do_relay
    [[ $DO_MAC == 0 ]] || do_mac
    phone_steps
    return 0
}

# Sourced by the tests: only the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
