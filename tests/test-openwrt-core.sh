#!/bin/sh

# Milestone 4 fixture tests: package install, dangerous helper handling
# (disable only, never stop), tailscale-core deployment, first-stage fw4 zone
# transaction, and join (file: auth key, no --reset, multi-Headscale guard).

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
PROJECT_DIR=$(CDPATH= cd "$TEST_DIR/.." 2>/dev/null && pwd -P)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headscale-bootstrap-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

OPENWRT_SCRIPT=$PROJECT_DIR/tailscale-openwrt.sh
OPENWRT_BIN=$TEST_DIR/fixtures/bin-openwrt

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s\n' "$1" | grep -qF -- "$2" || fail "missing: $2"
}

assert_not_contains() {
    if printf '%s\n' "$1" | grep -qF -- "$2"; then fail "unexpected: $2"; fi
}

assert_file_contains() {
    [ -f "$1" ] || fail "file missing: $1"
    grep -qF -- "$2" "$1" || fail "file $1 missing: $2"
}

assert_file_not_contains() {
    [ -f "$1" ] || fail "file missing: $1"
    if grep -qF -- "$2" "$1"; then fail "file $1 unexpectedly contains: $2"; fi
}

log_has() { grep -qF -- "$1" "$LOG"; }
log_not_has() { if grep -qF -- "$1" "$LOG"; then return 1; fi; return 0; }
log_line_of() { grep -nF -- "$1" "$LOG" | head -n 1 | cut -d: -f1; }
log_reset() { : > "$LOG"; }

LOGIN=https://hs.example.com

# A fresh router: dangerous LuCI init+helper present (and the stock service
# enabled), but no tailscale package, no tailscale-core, no identity, and a
# firewall without any tailscale sections.
make_fresh_root() {
    ROOT=$TMP_DIR/$1
    LOG=$TMP_DIR/$1.log
    mkdir -p "$ROOT"
    cp -a "$TEST_DIR/fixtures/openwrt/." "$ROOT/"
    rm -rf "$ROOT/etc/tailscale" "$ROOT/.ts-state" "$ROOT/.opkg-installed" \
        "$ROOT/.opkg-versions" "$ROOT/root/tailscale-bootstrap-backups" \
        "$ROOT/etc/tailscale-bootstrap" "$ROOT/tmp"
    rm -f "$ROOT/etc/init.d/tailscale-core" "$ROOT/etc/rc.d"/*
    # Fresh router: no tailscale package installed (luci-app leftovers remain).
    mkdir -p "$ROOT/.opkg-installed" "$ROOT/.opkg-versions"
    : > "$ROOT/.opkg-installed/luci-app-tailscale"
    printf '1.2.6-r1\n' > "$ROOT/.opkg-versions/luci-app-tailscale"
    # Strip the deployed tailscale zone + forwarding from the fixture firewall.
    awk '
        /^config zone .tailscale.$/ { skipping = 1; next }
        /^config forwarding .ts_to_lan.$/ { skipping = 1; next }
        skipping && /^config / { skipping = 0 }
        !skipping { print }
    ' "$ROOT/etc/config/firewall" > "$ROOT/etc/config/firewall.tmp"
    mv "$ROOT/etc/config/firewall.tmp" "$ROOT/etc/config/firewall"
    # The dangerous stock service is currently enabled at boot.
    ln -sf ../init.d/tailscale "$ROOT/etc/rc.d/S90tailscale"
    # TUN check needs a character device.
    mkdir -p "$ROOT/dev/net"
    if [ "$(id -u)" = 0 ]; then
        mknod "$ROOT/dev/net/tun" c 10 200 2>/dev/null || true
    elif [ -c /dev/net/tun ]; then
        ln -sf /dev/net/tun "$ROOT/dev/net/tun"
    fi
    log_reset
}

run_ow() {
    env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$OPENWRT_BIN:$PATH" \
        "$OPENWRT_SCRIPT" --root "$ROOT" "$@"
}

[ -c /dev/net/tun ] || { printf 'SKIP: /dev/net/tun unavailable\n'; exit 0; }

################################################################
# A. install: package + core, disable-only for the unsafe stock service
################################################################

make_fresh_root ow-a
OUT=$(run_ow --login-server "$LOGIN" install)
assert_contains "$OUT" 'Install complete'
[ -x "$ROOT/etc/init.d/tailscale-core" ] || fail 'tailscale-core not installed'
[ -L "$ROOT/etc/rc.d/S90tailscale-core" ] || fail 'tailscale-core not enabled at boot'
[ ! -e "$ROOT/etc/rc.d/S90tailscale" ] || fail 'unsafe stock service still enabled'
log_has 'opkg install tailscale' || fail 'opkg install not called'
log_has 'init tailscale disable' || fail 'stock service must be disabled'
log_not_has 'init tailscale stop' || fail 'stock service must never be stopped'
log_not_has 'network reload' || fail 'network reload must never appear'
assert_contains "$(run_ow --login-server "$LOGIN" discover --json)" '"core_fingerprint":"verified"'
[ -f "$ROOT/etc/tailscale-bootstrap/state.json" ] || fail 'state.json missing'
assert_file_contains "$ROOT/etc/tailscale-bootstrap/state.json" '"service_mode": "core"'
# uci changes stay clean after install.
[ -z "$(FAKE_OPENWRT_ROOT=$ROOT "$OPENWRT_BIN/uci" changes network)" ] || fail 'pending network UCI after install'
[ -z "$(FAKE_OPENWRT_ROOT=$ROOT "$OPENWRT_BIN/uci" changes firewall)" ] || fail 'pending firewall UCI after install'

# install is idempotent at the convergence level: rerun succeeds, no duplicate ops.
log_reset
OUT=$(run_ow --login-server "$LOGIN" install)
assert_contains "$OUT" 'Install complete'
log_not_has 'opkg install tailscale' || fail 'package must not be reinstalled'

################################################################
# B. apply: first-stage fw4 zone transaction, then idempotent
################################################################

log_reset
OUT=$(run_ow --login-server "$LOGIN" apply)
assert_contains "$OUT" 'Apply complete'
FW=$ROOT/etc/config/firewall
assert_file_contains "$FW" "config zone 'tailscale'"
assert_file_contains "$FW" "option name 'tailscale'"
assert_file_contains "$FW" "list device 'tailscale0'"
assert_file_contains "$FW" "option input 'ACCEPT'"
assert_file_contains "$FW" "option output 'ACCEPT'"
assert_file_contains "$FW" "option forward 'REJECT'"
# The tailscale zone itself must not masquerade (PLAN 25: Tailscale SNATs).
TS_ZONE=$(awk '/^config zone .tailscale.$/{flag=1;next} /^config /{flag=0} flag' "$FW")
assert_not_contains "$TS_ZONE" 'masq'
line_check=$(log_line_of 'fw4 check')
line_commit=$(log_line_of 'uci commit firewall')
line_reload=$(log_line_of 'init firewall reload')
[ -n "$line_check" ] || fail 'fw4 check not logged'
[ -n "$line_commit" ] || fail 'uci commit firewall not logged'
[ -n "$line_reload" ] || fail 'firewall reload not logged'
[ "$line_check" -lt "$line_commit" ] || fail 'fw4 check must precede uci commit'
[ "$line_commit" -lt "$line_reload" ] || fail 'commit must precede firewall reload'

log_reset
OUT=$(run_ow --login-server "$LOGIN" apply)
assert_contains "$OUT" 'Apply complete'
log_not_has 'uci commit firewall' || fail 'converged apply must not commit again'
log_not_has 'init firewall reload' || fail 'converged apply must not reload again'

# B2. fw4 check failure: revert pending UCI, nothing committed or reloaded.
make_fresh_root ow-b2
run_ow --login-server "$LOGIN" install >/dev/null
log_reset
set +e
OUT=$(env FAKE_OPENWRT_ROOT="$ROOT" FAKE_FAIL_FW4_CHECK=1 FAKE_LOG="$LOG" PATH="$OPENWRT_BIN:$PATH" \
    "$OPENWRT_SCRIPT" --root "$ROOT" --login-server "$LOGIN" apply 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'apply must fail when fw4 check fails'
assert_file_not_contains "$ROOT/etc/config/firewall" "config zone 'tailscale'"
log_not_has 'uci commit firewall' || fail 'must not commit after failed fw4 check'
log_not_has 'init firewall reload' || fail 'must not reload after failed fw4 check'
[ -z "$(FAKE_OPENWRT_ROOT=$ROOT "$OPENWRT_BIN/uci" changes firewall)" ] || fail 'pending firewall UCI must be reverted'

################################################################
# C. join: file: auth key, no --reset, key removed on success
################################################################

make_fresh_root ow-c
run_ow --login-server "$LOGIN" install >/dev/null
run_ow --login-server "$LOGIN" apply >/dev/null
KEYFILE=$TMP_DIR/hs-auth-key
printf 'hskey-auth-FIXTURE-join\n' > "$KEYFILE"
chmod 600 "$KEYFILE"
log_reset
OUT=$(run_ow --login-server "$LOGIN" --auth-key-file "$KEYFILE" join)
assert_contains "$OUT" 'Join complete'
UP_LINE=$(grep -F 'tailscale up' "$LOG" | head -n 1)
[ -n "$UP_LINE" ] || fail 'tailscale up not called'
assert_contains "$UP_LINE" "--login-server=$LOGIN"
assert_contains "$UP_LINE" '--auth-key=file:'
assert_contains "$UP_LINE" '--accept-dns=false'
assert_contains "$UP_LINE" '--accept-routes=false'
assert_not_contains "$UP_LINE" '--reset'
[ ! -f "$KEYFILE" ] || fail 'auth key file must be removed after a successful join'
PREFS=$ROOT/.ts-state/prefs
assert_file_contains "$PREFS" "\"ControlURL\":\"$LOGIN\""

# C2. Re-join when already registered: no second login, key untouched.
printf 'hskey-auth-FIXTURE-second\n' > "$KEYFILE"
chmod 600 "$KEYFILE"
log_reset
OUT=$(run_ow --login-server "$LOGIN" --auth-key-file "$KEYFILE" join)
assert_contains "$OUT" 'already registered'
log_not_has 'tailscale up' || fail 'registered node must not run tailscale up again'
[ -f "$KEYFILE" ] || fail 'unused key file must be kept'
rm -f "$KEYFILE"

# C3. Auth failure: join fails, key file kept for inspection.
make_fresh_root ow-c3
run_ow --login-server "$LOGIN" install >/dev/null
printf 'hskey-auth-FIXTURE-bad\n' > "$KEYFILE"
chmod 600 "$KEYFILE"
set +e
OUT=$(env FAKE_OPENWRT_ROOT="$ROOT" FAKE_FAIL_AUTH=1 FAKE_LOG="$LOG" PATH="$OPENWRT_BIN:$PATH" \
    "$OPENWRT_SCRIPT" --root "$ROOT" --login-server "$LOGIN" --auth-key-file "$KEYFILE" join 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'join must fail on auth failure'
[ -f "$KEYFILE" ] || fail 'key file must be kept when join fails'
rm -f "$KEYFILE"

# C4. Different existing ControlURL: hard stop, no silent switch (PLAN 33.2).
make_fresh_root ow-c4
run_ow --login-server "$LOGIN" install >/dev/null
printf 'hskey-auth-FIXTURE-guard\n' > "$KEYFILE"
chmod 600 "$KEYFILE"
run_ow --login-server "$LOGIN" --auth-key-file "$KEYFILE" join >/dev/null
rm -f "$KEYFILE"
printf 'hskey-auth-FIXTURE-other\n' > "$KEYFILE"
chmod 600 "$KEYFILE"
log_reset
set +e
OUT=$(env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$OPENWRT_BIN:$PATH" \
    "$OPENWRT_SCRIPT" --root "$ROOT" --login-server https://other.example.test --auth-key-file "$KEYFILE" join 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "different ControlURL must exit 2, got $CODE"
assert_contains "$OUT" 'different control server'
log_not_has 'tailscale up' || fail 'must not call tailscale up on ControlURL mismatch'

printf 'OpenWrt core/install/apply/join tests passed.\n'
