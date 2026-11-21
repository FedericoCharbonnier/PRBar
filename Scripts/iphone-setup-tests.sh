#!/bin/bash
# Offline tests for Scripts/iphone-setup.sh: argument parsing, the APNs key check (throwaway keys made here), the
# Team ID file and the env-file editing that runs on the server. Nothing leaves this Mac: no ssh, no installs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/iphone-setup.sh"
# shellcheck source=Scripts/iphone-setup.sh
source "$SCRIPT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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
        TEAM_ID="" APNS_KEY="" APNS_KEY_ID="" CHECK_KEY="" DEVICE="" DO_MAC=0 DO_PLATFORM=0 DO_IPHONE=0
        parse_args "$@" || exit $?
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$TEAM_ID" "$APNS_KEY" "$APNS_KEY_ID" "$CHECK_KEY" "$DEVICE" \
            "$DO_MAC" "$DO_PLATFORM" "$DO_IPHONE"
    )
}

echo "arguments"
same "no arguments" "|||||0|0|0" "$(parsed)"
same "team id" "QWERT12345|||||0|0|0" "$(parsed --team-id QWERT12345)"
same "apns key and id" "|/k/AuthKey_ABC123DEFG.p8|ABC123DEFG|||0|0|0" \
    "$(parsed --apns-key /k/AuthKey_ABC123DEFG.p8 --apns-key-id ABC123DEFG)"
same "every step" "QWERT12345||||00008110-0001|1|1|1" \
    "$(parsed --install-iphone --team-id QWERT12345 --install-mac --ios-platform --device 00008110-0001)"
same "check a key" "|||/k/a.p8||0|0|0" "$(parsed --check-apns-key /k/a.p8)"
refuse "unknown option" parsed --team QWERT12345
refuse "the example's placeholder team" parsed --team-id ABCDE12345
refuse "lowercase team id" parsed --team-id abcde12345
refuse "short team id" parsed --team-id ABC
refuse "team id missing its value" parsed --team-id
refuse "value that is another option" parsed --team-id --install-mac
refuse "key without its id" parsed --apns-key /k/a.p8
refuse "id without its key" parsed --apns-key-id ABC123DEFG
refuse "bad key id" parsed --apns-key /k/a.p8 --apns-key-id abc
refuse "device without --install-iphone" parsed --device 00008110-0001
same "help exits 0" "0" "$(
    "$SCRIPT" --help >/dev/null 2>&1
    echo $?
)"
same "bad option exits 2" "2" "$(
    "$SCRIPT" --bogus >/dev/null 2>&1 || echo $?
)"

echo "APNs key"
# Named curves, as Apple's keys have them (LibreSSL would write explicit parameters otherwise).
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve \
    -out "$TMP/AuthKey_ABC123DEFG.p8" 2>/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -pkeyopt ec_param_enc:named_curve \
    -out "$TMP/p384.p8" 2>/dev/null
# RSA instead of Ed25519: LibreSSL (macOS's /usr/bin/openssl) has no Ed25519.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/rsa.p8" 2>/dev/null
openssl ec -in "$TMP/AuthKey_ABC123DEFG.p8" -out "$TMP/sec1.pem" 2>/dev/null # "BEGIN EC PRIVATE KEY"
openssl pkcs8 -topk8 -in "$TMP/AuthKey_ABC123DEFG.p8" -out "$TMP/encrypted.p8" -passout pass:x 2>/dev/null
printf -- '-----BEGIN PRIVATE KEY-----\nbm90IGEga2V5\n-----END PRIVATE KEY-----\n' >"$TMP/garbage.p8"
: >"$TMP/empty.p8"
expect "P-256 PKCS#8 key" check_p8 "$TMP/AuthKey_ABC123DEFG.p8"
tr -d '\r' <"$TMP/AuthKey_ABC123DEFG.p8" | sed 's/$/\r/' >"$TMP/crlf.p8"
expect "P-256 key with CRLF line ends" check_p8 "$TMP/crlf.p8"
refuse "P-384 key" check_p8 "$TMP/p384.p8"
refuse "RSA key" check_p8 "$TMP/rsa.p8"
refuse "SEC1 (EC PRIVATE KEY) instead of PKCS#8" check_p8 "$TMP/sec1.pem"
refuse "encrypted PKCS#8" check_p8 "$TMP/encrypted.p8"
refuse "PEM block that isn't a key" check_p8 "$TMP/garbage.p8"
refuse "empty file" check_p8 "$TMP/empty.p8"
refuse "missing file" check_p8 "$TMP/nope.p8"
# Nothing of the key may show up in what the check prints, valid or not.
body="$(grep -v -- '-----' "$TMP/AuthKey_ABC123DEFG.p8" | tr -d '\n')"
output="$(check_p8 "$TMP/AuthKey_ABC123DEFG.p8" 2>&1; check_p8 "$TMP/p384.p8" 2>&1 || true)"
output+="$("$SCRIPT" --check-apns-key "$TMP/AuthKey_ABC123DEFG.p8" 2>&1)"
if [[ "$output" == *"${body:0:24}"* || "$output" == *"PRIVATE KEY-----"* || "$output" == *"priv:"* ]]; then
    bad "the check never prints the key"
else
    ok "the check never prints the key"
fi
same "--check-apns-key on a good key" "OK: a P-256 PKCS#8 key." "$("$SCRIPT" --check-apns-key "$TMP/AuthKey_ABC123DEFG.p8")"
refuse "--check-apns-key on a bad key exits non-zero" "$SCRIPT" --check-apns-key "$TMP/p384.p8"
same "key id from Apple's file name" "ABC123DEFG" "$(key_id_from_name "$TMP/AuthKey_ABC123DEFG.p8")"
refuse "no key id in another name" key_id_from_name "$TMP/p384.p8"

echo "env file"
cat >"$TMP/relay.env" <<'EOF'
# Copiar a /root/stack/env/prbar-relay.env (modo 600) en el VPS y completar ahí. Nunca al repo.
RELAY_PUBLIC_HOST=relay.example.com
# 32 bytes al azar, generados en el server: openssl rand -hex 32
RELAY_ENROLL_TOKEN=0123456789abcdef
RELAY_MAX_ACCOUNTS=4
APNS_KEY_ID=
# APNS_TEAM_ID=commented out stays
APNS_TEAM_ID=OLDTEAM123
APNS_TEAM_ID=DUPLICATE1
EOF
chmod 644 "$TMP/relay.env"
env_set_keys "$TMP/relay.env" APNS_KEY_ID=ABC123DEFG APNS_TEAM_ID=QWERT12345 APNS_TOPIC=com.federico.prbar.ios
same "only those keys change, missing ones are appended" "$(
    cat <<'EOF'
# Copiar a /root/stack/env/prbar-relay.env (modo 600) en el VPS y completar ahí. Nunca al repo.
RELAY_PUBLIC_HOST=relay.example.com
# 32 bytes al azar, generados en el server: openssl rand -hex 32
RELAY_ENROLL_TOKEN=0123456789abcdef
RELAY_MAX_ACCOUNTS=4
APNS_KEY_ID=ABC123DEFG
# APNS_TEAM_ID=commented out stays
APNS_TEAM_ID=QWERT12345
APNS_TOPIC=com.federico.prbar.ios
EOF
)" "$(cat "$TMP/relay.env")"
same "mode 600 afterwards" "600" "$(stat -f '%Lp' "$TMP/relay.env" 2>/dev/null || stat -c '%a' "$TMP/relay.env")"
before="$(cat "$TMP/relay.env")"
env_set_keys "$TMP/relay.env" APNS_KEY_ID=ABC123DEFG APNS_TEAM_ID=QWERT12345 APNS_TOPIC=com.federico.prbar.ios
same "running it again changes nothing" "$before" "$(cat "$TMP/relay.env")"
printf 'NO_NEWLINE_AT_END=1' >"$TMP/short.env"
env_set_keys "$TMP/short.env" APNS_TOPIC=com.federico.prbar.ios
same "a last line without newline" "$(printf 'NO_NEWLINE_AT_END=1\nAPNS_TOPIC=com.federico.prbar.ios')" "$(cat "$TMP/short.env")"
refuse "a value with shell characters" env_set_keys "$TMP/relay.env" 'APNS_TOPIC=x;rm -rf /'
refuse "a value with spaces" env_set_keys "$TMP/relay.env" 'APNS_TOPIC=a b'
refuse "no file" env_set_keys "$TMP/none.env" APNS_TOPIC=x
refuse "nothing to set" env_set_keys "$TMP/relay.env"
same "refused edits leave the file alone" "$before" "$(cat "$TMP/relay.env")"
same "no temporary files left" "relay.env short.env" "$(cd "$TMP" && ls ./*.env | sed 's|./||' | tr '\n' ' ' | sed 's/ $//')"
# The server gets the function through `declare -f` and runs it with bash -s, as do_apns does (here locally).
cp "$TMP/relay.env" "$TMP/remote.env"
{
    declare -f env_set_keys
    # shellcheck disable=SC2016
    printf '%s\n' 'cp -p "$1" "$1.bak" && chmod 600 "$1.bak" && env_set_keys "$@"'
} | bash -s -- "$TMP/remote.env" APNS_KEY_ID=ZZZ999YYYY
same "shipped with declare -f it edits the same way" "APNS_KEY_ID=ZZZ999YYYY" "$(grep '^APNS_KEY_ID=' "$TMP/remote.env")"
same "and keeps a backup" "$before" "$(cat "$TMP/remote.env.bak")"

echo "Team ID and bundle id"
write_team_id QWERT12345 "$TMP/Local.xcconfig" >/dev/null
same "writes a new Local.xcconfig" "QWERT12345" "$(current_team_id "$TMP/Local.xcconfig")"
printf '// mine\nOTHER = 1\nDEVELOPMENT_TEAM = QWERT12345\n' >"$TMP/Local.xcconfig"
write_team_id ZYXWV98765 "$TMP/Local.xcconfig" >/dev/null
same "replaces the team, keeps the rest" "$(printf '// mine\nOTHER = 1\nDEVELOPMENT_TEAM = ZYXWV98765')" "$(cat "$TMP/Local.xcconfig")"
same "same team again: no change" "ios/Config/Local.xcconfig already has DEVELOPMENT_TEAM = ZYXWV98765." \
    "$(write_team_id ZYXWV98765 "$TMP/Local.xcconfig")"
cp "$HERE/../ios/Config/Local.xcconfig.example" "$TMP/example.xcconfig"
refuse "the example's placeholder isn't a team" current_team_id "$TMP/example.xcconfig"
refuse "no file, no team" current_team_id "$TMP/none.xcconfig"
same "APNs topic from project.yml" "com.federico.prbar.ios" "$(bundle_id)"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
