#!/bin/bash
# The steps left to run PRBar on your iPhone (plan 19, docs/iphone.md). Each step is idempotent and asks before doing
# anything outside this repo (the server, ~/Applications, Xcode downloads, the iPhone).
#
#   Scripts/iphone-setup.sh                          what's done and what's left (changes nothing)
#   Scripts/iphone-setup.sh --team-id ABCDE12345     writes ios/Config/Local.xcconfig (signing)
#   PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --apns-key ~/Downloads/AuthKey_ABC123DEFG.p8 --apns-key-id ABC123DEFG
#                                                    the APNs key to the relay (push notifications)
#   PRBAR_RELAY_SERVER=root@<vps> Scripts/iphone-setup.sh --install-mac
#                                                    this branch's PRBar on the Mac + iPhone access on
#   Scripts/iphone-setup.sh --ios-platform           Xcode's iOS platform (~10 GB download)
#   Scripts/iphone-setup.sh --install-iphone [--device <UDID>]
#                                                    builds, signs and installs the app on the iPhone (cable)
#   Scripts/iphone-setup.sh --check-apns-key <file>  only validates a .p8 (offline)
#
# Several steps in one run go in this order: team, iOS platform, APNs key, Mac, iPhone.
# PRBAR_RELAY_SERVER: ssh destination of the relay's server (never in the repo). PRBAR_RELAY_HOST: the relay's public
# host (default prbar.fcharbonnier.duckdns.org). Tests: Scripts/iphone-setup-tests.sh (offline).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_HOST="${PRBAR_RELAY_HOST:-prbar.fcharbonnier.duckdns.org}"
REMOTE_ENV=/root/stack/env/prbar-relay.env
REMOTE_P8=/root/stack/env/prbar-relay.p8
REMOTE_DIR=/root/stack/prbar-relay
RELAY_CONTAINER=prbar-relay
# The relay's image runs as distroless "nonroot"; the .p8 is mounted as a compose secret (a bind mount, owner kept).
RELAY_UID=65532
LOCAL_XCCONFIG="$ROOT/ios/Config/Local.xcconfig"
NEEDED_GB=10

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
# Validation (pure: tested offline by Scripts/iphone-setup-tests.sh)

# Apple Team IDs and Key IDs: 10 uppercase letters or digits.
is_apple_id() { [[ "$1" =~ ^[A-Z0-9]{10}$ ]]; }

# A Team ID, and not the placeholder of ios/Config/Local.xcconfig.example.
is_team_id() { is_apple_id "$1" && [[ "$1" != "ABCDE12345" ]]; }

# PRODUCT_BUNDLE_IDENTIFIER of the app target in ios/project.yml (the APNs topic).
bundle_id() {
    local file="${1:-$ROOT/ios/project.yml}" id
    id="$(awk '/^  PRBarMobile:/{t=1; next} /^  [A-Za-z]/{t=0} t && /PRODUCT_BUNDLE_IDENTIFIER:/{print $2; exit}' "$file")"
    [[ "$id" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    printf '%s\n' "$id"
}

# DEVELOPMENT_TEAM from Local.xcconfig, if set to a valid Team ID.
current_team_id() {
    local file="${1:-$LOCAL_XCCONFIG}" team
    [[ -f "$file" ]] || return 1
    team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\)[[:space:]]*$/\1/p' "$file" | tail -n 1)"
    is_team_id "$team" || return 1
    printf '%s\n' "$team"
}

# Writes DEVELOPMENT_TEAM into Local.xcconfig, keeping anything else in it. Prints what it did.
write_team_id() {
    local team="$1" file="${2:-$LOCAL_XCCONFIG}"
    is_team_id "$team" || die "'$team' isn't a Team ID (10 letters or digits, developer.apple.com > Membership)."
    if [[ "$(current_team_id "$file" || true)" == "$team" ]]; then
        say "ios/Config/Local.xcconfig already has DEVELOPMENT_TEAM = $team."
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    if [[ -f "$file" ]] && grep -q '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=' "$file"; then
        local tmp
        tmp="$(mktemp "$file.XXXXXX")"
        sed "s/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=.*/DEVELOPMENT_TEAM = $team/" "$file" >"$tmp"
        mv "$tmp" "$file"
    else
        {
            [[ -f "$file" ]] || say "// Signing for PRBar on iPhone (not in git). Written by Scripts/iphone-setup.sh --team-id."
            say "DEVELOPMENT_TEAM = $team"
        } >>"$file"
    fi
    say "Wrote DEVELOPMENT_TEAM = $team to ios/Config/Local.xcconfig."
}

# The APNs key: a P-256 private key in unencrypted PKCS#8 PEM ("BEGIN PRIVATE KEY"), as Apple hands it out. Nothing of
# the key is printed: openssl's output goes to /dev/null or through grep.
check_p8() {
    local file="$1" first last
    [[ -f "$file" ]] || {
        say "No file at $file."
        return 1
    }
    [[ -s "$file" && $(wc -c <"$file") -lt 4096 ]] || {
        say "$file isn't an APNs key (empty or too large)."
        return 1
    }
    first="$(grep -v '^[[:space:]]*$' "$file" | head -n 1 | tr -d '\r')"
    last="$(grep -v '^[[:space:]]*$' "$file" | tail -n 1 | tr -d '\r')"
    if [[ "$first" != "-----BEGIN PRIVATE KEY-----" || "$last" != "-----END PRIVATE KEY-----" ]]; then
        say "$file isn't an unencrypted PKCS#8 key (expected the -----BEGIN PRIVATE KEY----- block Apple gives you)."
        return 1
    fi
    command -v openssl >/dev/null || {
        say "openssl is missing."
        return 1
    }
    if ! openssl pkey -in "$file" -noout >/dev/null 2>&1; then
        say "openssl can't read the key in $file."
        return 1
    fi
    # The algorithm and the named curve, from the key's ASN.1 (grep -q: the dump, which has the key, isn't shown).
    local objects
    objects="$(openssl asn1parse -in "$file" 2>/dev/null | grep -Eo ':(id-ecPublicKey|prime256v1)$' | sort -u | tr -d '\n')"
    if [[ "$objects" != ":id-ecPublicKey:prime256v1" ]]; then
        say "The key in $file isn't an EC key on the P-256 curve (APNs keys are)."
        return 1
    fi
    return 0
}

# The Key ID that Apple puts in the file name (AuthKey_<KEYID>.p8), if any.
key_id_from_name() {
    local name
    name="$(basename "$1")"
    [[ "$name" =~ ^AuthKey_([A-Z0-9]{10})\.p8$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Sets KEY=VALUE lines in an env file: replaces each key's first line (and drops repeats of it), appends keys that
# aren't there, and leaves every other line (comments, other keys like RELAY_ENROLL_TOKEN) as it was. Mode 600.
# It runs locally in the tests and on the server through `declare -f` (bash and awk only, GNU or BSD).
env_set_keys() {
    local file="$1"
    shift
    [[ $# -gt 0 ]] || return 1
    [[ -f "$file" ]] || {
        printf 'env_set_keys: no file %s\n' "$file" >&2
        return 1
    }
    local pair
    for pair in "$@"; do
        [[ "$pair" =~ ^[A-Z_][A-Z0-9_]*=[A-Za-z0-9._-]*$ ]] || {
            printf 'env_set_keys: refusing %s\n' "${pair%%=*}" >&2
            return 1
        }
    done
    local tmp
    tmp="$(mktemp "$file.XXXXXX")"
    printf '%s\n' "$@" | awk '
        NR == FNR { key = substr($0, 1, index($0, "=") - 1); value[key] = $0; order[++n] = key; next }
        {
            key = $0
            if (match(key, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
                key = substr(key, 1, RLENGTH - 1)
                if (key in value) {
                    if (!(key in done)) { print value[key]; done[key] = 1 }
                    next
                }
            }
            print
        }
        END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print value[order[i]] }
    ' - "$file" >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

# Bytes free where Xcode puts platforms (the system volume's data side).
free_gb() { df -k "${1:-$HOME}" | awk 'NR == 2 { printf "%d\n", $4 / 1024 / 1024 }'; }

ios_platform_installed() {
    xcrun simctl list runtimes 2>/dev/null | grep -Eq '^iOS (2[6-9]|[3-9][0-9])'
}

# ---------------------------------------------------------------------------------------------------------------------
# Arguments

TEAM_ID=""
APNS_KEY=""
APNS_KEY_ID=""
CHECK_KEY=""
DEVICE=""
DO_MAC=0
DO_PLATFORM=0
DO_IPHONE=0

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Fills the variables above; returns 2 (with a message) on anything it doesn't understand.
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --team-id | --apns-key | --apns-key-id | --device | --check-apns-key)
                if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                    printf 'error: %s needs a value.\n' "$1" >&2
                    return 2
                fi
                case "$1" in
                    --team-id) TEAM_ID="$2" ;;
                    --apns-key) APNS_KEY="$2" ;;
                    --apns-key-id) APNS_KEY_ID="$2" ;;
                    --device) DEVICE="$2" ;;
                    --check-apns-key) CHECK_KEY="$2" ;;
                esac
                shift 2
                ;;
            --install-mac) DO_MAC=1 && shift ;;
            --ios-platform) DO_PLATFORM=1 && shift ;;
            --install-iphone) DO_IPHONE=1 && shift ;;
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
    if [[ -n "$TEAM_ID" ]] && ! is_team_id "$TEAM_ID"; then
        printf "error: '%s' isn't a Team ID (10 uppercase letters or digits).\n" "$TEAM_ID" >&2
        return 2
    fi
    if [[ -n "$APNS_KEY" && -z "$APNS_KEY_ID" ]] || [[ -z "$APNS_KEY" && -n "$APNS_KEY_ID" ]]; then
        printf 'error: --apns-key and --apns-key-id go together.\n' >&2
        return 2
    fi
    if [[ -n "$APNS_KEY_ID" ]] && ! is_apple_id "$APNS_KEY_ID"; then
        printf "error: '%s' isn't a Key ID (10 uppercase letters or digits).\n" "$APNS_KEY_ID" >&2
        return 2
    fi
    if [[ -n "$DEVICE" && $DO_IPHONE == 0 ]]; then
        printf 'error: --device goes with --install-iphone.\n' >&2
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

do_team() {
    step "Signing team"
    write_team_id "$TEAM_ID"
    say "Next builds for the iPhone are signed with team $TEAM_ID (Xcode > Settings > Accounts must have it)."
}

do_platform() {
    step "Xcode's iOS platform"
    if ios_platform_installed; then
        say "Already installed: $(xcrun simctl list runtimes | grep -E '^iOS' | tail -n 1)"
        return 0
    fi
    local free
    free="$(free_gb "$HOME")"
    say "Free disk: ${free} GB (the download needs about ${NEEDED_GB} GB)."
    if [[ "$free" -lt "$NEEDED_GB" ]]; then
        die "not enough free disk. Free up $((NEEDED_GB - free)) GB or more and run this again."
    fi
    confirm "Download and install Xcode's iOS platform now (xcodebuild -downloadPlatform iOS, several GB)?" || return 0
    xcodebuild -downloadPlatform iOS
    if ! ios_platform_installed; then die "xcodebuild finished but no iOS runtime shows up."; fi
    say "iOS platform installed."
}

do_apns() {
    step "APNs key on the relay"
    need_server
    check_p8 "$APNS_KEY" || die "not a usable APNs key."
    say "The key is a P-256 PKCS#8 key."
    local from_name team topic
    if from_name="$(key_id_from_name "$APNS_KEY")" && [[ "$from_name" != "$APNS_KEY_ID" ]]; then
        say "The file name says Key ID $from_name, but --apns-key-id is $APNS_KEY_ID."
        confirm "Use $APNS_KEY_ID anyway?" || exit 1
    fi
    team="${TEAM_ID:-$(current_team_id || true)}"
    [[ -n "$team" ]] || die "no Team ID: pass --team-id (or run --team-id first)."
    topic="$(bundle_id)" || die "couldn't read the app's bundle id from ios/project.yml."
    say "Server: $PRBAR_RELAY_SERVER"
    say "  $REMOTE_P8 <- this key (owner $RELAY_UID, mode 400)"
    say "  $REMOTE_ENV: APNS_KEY_ID=$APNS_KEY_ID APNS_TEAM_ID=$team APNS_TOPIC=$topic (other lines untouched)"
    say "  then: docker compose up -d --force-recreate in $REMOTE_DIR"
    confirm "Copy the key and update the relay's settings on $PRBAR_RELAY_SERVER?" || return 0

    ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" "test -f $REMOTE_ENV && test -d $REMOTE_DIR" ||
        die "the server has no $REMOTE_ENV or $REMOTE_DIR (deploy the relay first: relay/deploy/deploy.sh)."
    # Through a temporary name next to the real one, so a failed copy never leaves half a key in place.
    local source="$APNS_KEY"
    [[ "$source" == /* ]] || source="./$source" # a relative name with ":" would read as a host
    scp -q "$source" "$PRBAR_RELAY_SERVER:$REMOTE_P8.new"
    # shellcheck disable=SC2029 # expanded locally on purpose: fixed paths and the uid
    ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" \
        "chown $RELAY_UID:$RELAY_UID $REMOTE_P8.new && chmod 400 $REMOTE_P8.new && mv -f $REMOTE_P8.new $REMOTE_P8"
    say "Key copied."
    {
        declare -f env_set_keys
        # shellcheck disable=SC2016 # runs on the server
        printf '%s\n' 'cp -p "$1" "$1.bak" && chmod 600 "$1.bak" && env_set_keys "$@"'
    } | ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" bash -s -- "$REMOTE_ENV" \
        "APNS_KEY_ID=$APNS_KEY_ID" "APNS_TEAM_ID=$team" "APNS_TOPIC=$topic"
    say "Settings updated (previous copy: $REMOTE_ENV.bak)."

    confirm "Restart the relay now (connected Macs and iPhones reconnect by themselves)?" || return 0
    local since
    since="$(ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" date +%s)"
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" "cd $REMOTE_DIR && docker compose up -d --force-recreate"
    local ok=0 _
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 5 "https://$RELAY_HOST/healthz" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    [[ $ok == 1 ]] || die "https://$RELAY_HOST/healthz doesn't answer. Look at: ssh $PRBAR_RELAY_SERVER docker logs $RELAY_CONTAINER"
    say "https://$RELAY_HOST/healthz answers."
    # shellcheck disable=SC2029
    if ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" "docker logs --since $since $RELAY_CONTAINER 2>&1" | grep -q 'push disabled'; then
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" "docker logs --since $since $RELAY_CONTAINER 2>&1" | grep 'push disabled' >&2
        die "the relay still says push disabled (see the reason above)."
    fi
    say "Push is on: the relay no longer logs \"push disabled\"."
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

    step "iPhone access on this Mac"
    local _ status=""
    for _ in $(seq 1 30); do
        if status="$(prbar_cli remote status --json 2>/dev/null)"; then break; fi
        sleep 1
    done
    [[ -n "$status" ]] || die "PRBar doesn't answer (is it running? open ~/Applications/PRBar.app)."
    if printf '%s' "$status" | grep -q '"enabled" *: *true' &&
        printf '%s' "$status" | grep -q "\"relayHost\" *: *\"$RELAY_HOST\""; then
        say "Already on with $RELAY_HOST."
        prbar_cli remote status
        return 0
    fi
    need_server
    say "PRBar creates this Mac's account on $RELAY_HOST with the relay's enrollment token. The token goes from"
    say "$PRBAR_RELAY_SERVER straight into prbar (ssh into stdin): it isn't shown, saved or kept by PRBar."
    confirm "Turn on iPhone access with $RELAY_HOST now?" || return 0
    # The token never touches a variable, the terminal or the disk.
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes "$PRBAR_RELAY_SERVER" "sed -n 's/^RELAY_ENROLL_TOKEN=//p' $REMOTE_ENV | head -n 1" |
        prbar_cli remote enable --relay "$RELAY_HOST" --enroll-token-stdin
    say "Pair the iPhone with: prbar remote pair (or PRBar > Settings > iPhone > Pair iPhone...)."
}

# Picks the connected iPhone: prints "<udid> <name>" or explains what's wrong.
find_iphone() {
    local json
    json="$(mktemp -t prbar-devices)"
    if ! xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1; then
        rm -f "$json"
        die "xcrun devicectl can't list devices (Xcode 15 or newer needed)."
    fi
    local result
    result="$(python3 -I - "$json" "$DEVICE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
wanted = sys.argv[2]
phones = []
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") != "iOS":
        continue
    cp = d.get("connectionProperties", {})
    dp = d.get("deviceProperties", {})
    udid = hw.get("udid") or d.get("identifier", "")
    phones.append({
        "udid": udid, "id": d.get("identifier", ""), "name": dp.get("name", "iPhone"),
        "dev": dp.get("developerModeStatus", ""), "paired": cp.get("pairingState", ""),
        "connected": cp.get("tunnelState", "") != "unavailable" and cp.get("transportType") is not None,
    })
if wanted:
    phones = [p for p in phones if wanted in (p["udid"], p["id"])]
    if not phones:
        print("ERR No device with id " + wanted + " (xcrun devicectl list devices)."); sys.exit()
connected = [p for p in phones if p["connected"]]
if not connected:
    print("ERR No iPhone connected. Plug it in with a cable, unlock it and tap Trust This Computer."); sys.exit()
if len(connected) > 1 and not wanted:
    print("ERR More than one iPhone: pass --device <UDID> (" + ", ".join(p["udid"] + " " + p["name"] for p in connected) + ")."); sys.exit()
p = connected[0]
if p["paired"] and p["paired"] != "paired":
    print("ERR " + p["name"] + " isn't paired with this Mac: unlock it and tap Trust This Computer."); sys.exit()
if p["dev"] and p["dev"] != "enabled":
    print("ERR Developer Mode is off on " + p["name"] + ": Settings > Privacy & Security > Developer Mode, then restart it."); sys.exit()
print("OK " + p["udid"] + " " + p["name"])
PY
)"
    rm -f "$json"
    case "$result" in
        OK\ *) printf '%s\n' "${result#OK }" ;;
        ERR\ *) die "${result#ERR }" ;;
        *) die "couldn't read the device list." ;;
    esac
}

do_iphone() {
    step "PRBar on the iPhone"
    local team
    team="$(current_team_id || true)"
    [[ -n "$team" ]] || die "no Team ID in ios/Config/Local.xcconfig: run with --team-id first."
    command -v xcodegen >/dev/null || die "xcodegen is missing: brew install xcodegen"
    ios_platform_installed || die "Xcode's iOS platform isn't installed: run with --ios-platform first."
    local device udid name
    device="$(find_iphone)"
    udid="${device%% *}"
    name="${device#* }"
    say "iPhone: $name ($udid), team $team."
    say "Builds the Debug app signed for this iPhone (Xcode creates the App IDs, App Group and profile on the first"
    say "build: -allowProvisioningUpdates) and installs it with xcrun devicectl."
    confirm "Build and install PRBar on $name now?" || return 0
    (cd "$ROOT" && Scripts/ios-generate.sh)
    local derived="$ROOT/ios/.build-xcode/device"
    if ! xcodebuild -project "$ROOT/ios/PRBarMobile.xcodeproj" -scheme PRBarMobile -configuration Debug \
        -destination "platform=iOS,id=$udid" -derivedDataPath "$derived" -allowProvisioningUpdates build \
        >"$derived.log" 2>&1; then
        grep -E 'error:' "$derived.log" | sort -u >&2 || true
        say "Signing problems: Xcode > Settings > Accounts needs your Apple Developer account for team $team." >&2
        die "the build failed (full log: $derived.log)."
    fi
    local app="$derived/Build/Products/Debug-iphoneos/PRBarMobile.app"
    [[ -d "$app" ]] || die "no app at $app."
    xcrun devicectl device install app --device "$udid" "$app"
    say "Installed. Open PRBar on the iPhone and scan the QR from: prbar remote pair"
}

status() {
    step "Status (nothing changed)"
    local team
    if team="$(current_team_id)"; then say "[x] Team ID: $team"; else say "[ ] Team ID: --team-id <ID>"; fi
    if command -v xcodegen >/dev/null; then say "[x] xcodegen"; else say "[ ] xcodegen: brew install xcodegen"; fi
    if ios_platform_installed; then
        say "[x] Xcode's iOS platform"
    else
        say "[ ] Xcode's iOS platform: --ios-platform (free: $(free_gb "$HOME") GB, needs ~${NEEDED_GB} GB)"
    fi
    if [[ -x "$HOME/Applications/PRBar.app/Contents/Helpers/prbar" ]]; then
        say "[x] PRBar in ~/Applications (--install-mac installs this branch's build)"
    else
        say "[ ] PRBar in ~/Applications: --install-mac"
    fi
    say "[?] APNs key on the relay: --apns-key <AuthKey_XXXXXXXXXX.p8> --apns-key-id <XXXXXXXXXX> (needs PRBAR_RELAY_SERVER)"
    say "[?] App on the iPhone: --install-iphone (cable, Developer Mode on)"
    say "Bundle id / APNs topic: $(bundle_id || echo '?'). Relay: $RELAY_HOST."
}

main() {
    parse_args "$@" || exit 2
    if [[ -n "$CHECK_KEY" ]]; then
        if check_p8 "$CHECK_KEY"; then say "OK: a P-256 PKCS#8 key."; else exit 1; fi
        [[ -z "$TEAM_ID$APNS_KEY" && $DO_MAC == 0 && $DO_PLATFORM == 0 && $DO_IPHONE == 0 ]] && return 0
    fi
    if [[ -z "$TEAM_ID$APNS_KEY$CHECK_KEY" && $DO_MAC == 0 && $DO_PLATFORM == 0 && $DO_IPHONE == 0 ]]; then
        status
        return 0
    fi
    [[ -z "$TEAM_ID" ]] || do_team
    [[ $DO_PLATFORM == 0 ]] || do_platform
    [[ -z "$APNS_KEY" ]] || do_apns
    [[ $DO_MAC == 0 ]] || do_mac
    [[ $DO_IPHONE == 0 ]] || do_iphone
    return 0
}

# Sourced by the tests: only the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
