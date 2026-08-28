#!/bin/sh

# Fixture tests for the two subnet modes and the field breakages they fix:
#   remote-access (enable-subnet): accept-routes=false, ts_to_lan only;
#   site-to-site (enable-site-to-site): accept-routes=true + lan_to_ts;
#   ts_to_lan referencing a missing zone is reported BROKEN and repaired;
#   accept-routes is never silently reset by apply convergence;
#   the failover watchdog keeps RouteAll on in site-to-site mode.

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
PROJECT_DIR=$(CDPATH= cd "$TEST_DIR/.." 2>/dev/null && pwd -P)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headscale-bootstrap-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

OPENWRT_SCRIPT=$PROJECT_DIR/tailscale-openwrt.sh
OPENWRT_BIN=$TEST_DIR/fixtures/bin-openwrt
A=https://hs.example.com
B=https://hs-b.example.com

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
log_reset() { : > "$LOG"; }

run_ow() {
    env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" TMPDIR="$TMP_DIR" OPENWRT_SWITCH_SETTLE=0 \
        PATH="$OPENWRT_BIN:$PATH" \
        "$OPENWRT_SCRIPT" --root "$ROOT" "$@"
}

uci_admin() {
    env FAKE_OPENWRT_ROOT="$ROOT" "$OPENWRT_BIN/uci" "$@"
}

cur_url() {
    sed -n 's/.*"ControlURL":"\([^"]*\)".*/\1/p' "$ROOT/.ts-state/prefs" | sed -n '1p'
}

routeall() {
    sed -n 's/.*"RouteAll":\([^,]*\).*/\1/p' "$ROOT/.ts-state/prefs" | sed -n '1p'
}

run_watchdog() {
    env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" \
        TS_FAILOVER_CONFIG_FILE="$ROOT/etc/config/tailscale-bootstrap" \
        TS_FAILOVER_RUNTIME_DIR="$ROOT/var/run/tailscale-failover" \
        TS_FAILOVER_SETTLE=0 \
        PATH="$OPENWRT_BIN:$PATH" \
        sh "$ROOT/usr/sbin/tailscale-failover" --once
}

watchdog_cycles() {
    s2s_wc_n=$1
    s2s_wc_i=0
    while [ "$s2s_wc_i" -lt "$s2s_wc_n" ]; do
        run_watchdog >/dev/null 2>&1
        s2s_wc_i=$((s2s_wc_i + 1))
    done
}

new_key() {
    KEYFILE=$TMP_DIR/hs-auth-key
    printf 'hskey-auth-FIXTURE-%s\n' "$1" > "$KEYFILE"
    chmod 600 "$KEYFILE"
}

# Joined node baseline: package installed, registered to $A, no routes
# advertised yet, and a firewall stripped of every managed section (the
# zone is created by the command under test).
make_joined_root() {
    ROOT=$TMP_DIR/$1
    LOG=$TMP_DIR/$1.log
    mkdir -p "$ROOT"
    cp -a "$TEST_DIR/fixtures/openwrt/." "$ROOT/"
    rm -rf "$ROOT/tmp" "$ROOT/root/tailscale-bootstrap-backups" "$ROOT/etc/tailscale-bootstrap"
    rm -f "$ROOT/etc/rc.d"/*
    mkdir -p "$ROOT/dev/net"
    if [ -c /dev/net/tun ]; then
        ln -sf /dev/net/tun "$ROOT/dev/net/tun"
    elif [ "$(id -u)" = 0 ]; then
        mknod "$ROOT/dev/net/tun" c 10 200 2>/dev/null || true
    fi
    printf '{"ControlURL":"%s","CorpDNS":false,"RouteAll":false,"AdvertiseRoutes":[],"ExitNodeID":""}\n' "$A" \
        > "$ROOT/.ts-state/prefs"
    awk '
        /^config zone .tailscale.$/ { skipping = 1; next }
        /^config forwarding .ts_to_lan.$/ { skipping = 1; next }
        skipping && /^config / { skipping = 0 }
        !skipping { print }
    ' "$ROOT/etc/config/firewall" > "$ROOT/etc/config/firewall.tmp"
    mv "$ROOT/etc/config/firewall.tmp" "$ROOT/etc/config/firewall"
    log_reset
}

count_fw_section() {
    grep -c "^config $2 '$1'$" "$ROOT/etc/config/firewall" || true
}

[ -c /dev/net/tun ] || { printf 'SKIP: /dev/net/tun unavailable\n'; exit 0; }

################################################################
# A. remote-access mode (Test 2): enable-subnet creates the zone it
#    references, keeps accept-routes=false and never adds lan_to_ts.
################################################################

make_joined_root s2s-a
OUT=$(run_ow --login-server "$A" enable-subnet)
assert_contains "$OUT" '192.168.10.0/24'
FW=$ROOT/etc/config/firewall
assert_file_contains "$FW" "config zone 'tailscale'"
assert_file_contains "$FW" "list device 'tailscale0'"
assert_file_contains "$FW" "config forwarding 'ts_to_lan'"
assert_file_not_contains "$FW" "config forwarding 'lan_to_ts'"
[ "$(routeall)" = false ] || fail 'remote-access mode must keep RouteAll=false'
run_ow --login-server "$A" status >/dev/null

# B. site-to-site mode (Test 3): explicit command, both forwardings,
#    accept-routes=true, no masquerade, marker recorded.
make_joined_root s2s-b
OUT=$(run_ow --login-server "$A" enable-site-to-site)
assert_contains "$OUT" 'Site-to-site enabled'
assert_contains "$OUT" 'accept-routes=true'
assert_contains "$OUT" 'does not imply peers accepted'
[ "$(routeall)" = true ] || fail 'site-to-site must set RouteAll=true'
assert_file_contains "$ROOT/.ts-state/prefs" '"AdvertiseRoutes":["192.168.10.0/24"]'
FW=$ROOT/etc/config/firewall
assert_file_contains "$FW" "config forwarding 'ts_to_lan'"
assert_file_contains "$FW" "config forwarding 'lan_to_ts'"
LAN_FWD=$(awk "/^config forwarding 'lan_to_ts'/{flag=1;next} /^config /{flag=0} flag" "$FW")
assert_contains "$LAN_FWD" "option src 'lan'"
assert_contains "$LAN_FWD" "option dest 'tailscale'"
assert_contains "$LAN_FWD" "option family 'ipv4'"
TS_ZONE=$(awk "/^config zone 'tailscale'/{flag=1;next} /^config /{flag=0} flag" "$FW")
assert_not_contains "$TS_ZONE" 'masq'
BOOTCFG=$ROOT/etc/config/tailscale-bootstrap
assert_file_contains "$BOOTCFG" "config site_to_site 'site_to_site'"
assert_file_contains "$BOOTCFG" "option enabled '1'"
run_ow --login-server "$A" status >/dev/null

# B2. Idempotent re-run: no prefs write, no firewall commit/reload.
log_reset
OUT=$(run_ow --login-server "$A" enable-site-to-site)
assert_contains "$OUT" 'Site-to-site enabled'
log_not_has 'tailscale set' || fail 'converged site-to-site must not re-run tailscale set'
log_not_has 'uci commit firewall' || fail 'converged site-to-site must not commit again'
log_not_has 'init firewall reload' || fail 'converged site-to-site must not reload again'
[ "$(routeall)" = true ] || fail 'RouteAll must stay true after a no-op rerun'

# C. apply must keep RouteAll=true in site-to-site mode (regression:
#    converge_prefs used to reset it to the CLI default false).
log_reset
OUT=$(run_ow --login-server "$A" apply)
assert_contains "$OUT" 'Apply complete'
[ "$(routeall)" = true ] || fail 'apply must not reset accept-routes in site-to-site mode'
log_not_has 'accept-routes=false' || fail 'apply must not converge accept-routes back to false'
run_ow --login-server "$A" status >/dev/null

# C2. Rerun triple-apply (Test 5): UCI clean, no duplicated sections,
#     identity and prefs unchanged.
URL_BEFORE=$(cur_url)
PREFS_BEFORE=$(cat "$ROOT/.ts-state/prefs")
run_ow --login-server "$A" apply >/dev/null
run_ow --login-server "$A" apply >/dev/null
run_ow --login-server "$A" apply >/dev/null
[ -z "$(uci_admin changes network)" ] || fail 'pending network UCI after repeated apply'
[ -z "$(uci_admin changes firewall)" ] || fail 'pending firewall UCI after repeated apply'
[ "$(count_fw_section tailscale zone)" = 1 ] || fail 'tailscale zone duplicated'
[ "$(count_fw_section ts_to_lan forwarding)" = 1 ] || fail 'ts_to_lan duplicated'
[ "$(count_fw_section lan_to_ts forwarding)" = 1 ] || fail 'lan_to_ts duplicated'
[ "$(cur_url)" = "$URL_BEFORE" ] || fail 'ControlURL changed across reruns'
[ "$(cat "$ROOT/.ts-state/prefs")" = "$PREFS_BEFORE" ] || fail 'prefs changed across converged reruns'

# D. disable-site-to-site: back to remote-access semantics.
log_reset
OUT=$(run_ow --login-server "$A" disable-site-to-site)
assert_contains "$OUT" 'Site-to-site disabled'
[ "$(routeall)" = false ] || fail 'disable must set RouteAll=false'
assert_file_not_contains "$ROOT/etc/config/firewall" "config forwarding 'lan_to_ts'"
assert_file_contains "$ROOT/etc/config/firewall" "config forwarding 'ts_to_lan'"
assert_file_contains "$ROOT/etc/config/tailscale-bootstrap" "option enabled '0'"
run_ow --login-server "$A" status >/dev/null

# E. broken zone detection (Test 4): ts_to_lan without firewall.tailscale
#    must fail verify with the exact cause, and enable-subnet repairs it.
make_joined_root s2s-e
run_ow --login-server "$A" enable-subnet >/dev/null
awk '
    /^config zone .tailscale.$/ { skipping = 1; next }
    skipping && /^config / { skipping = 0 }
    !skipping { print }
' "$ROOT/etc/config/firewall" > "$ROOT/etc/config/firewall.tmp"
mv "$ROOT/etc/config/firewall.tmp" "$ROOT/etc/config/firewall"
set +e
OUT=$(run_ow --login-server "$A" status 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'status must fail when ts_to_lan references a missing zone'
assert_contains "$OUT" 'ts_to_lan-references-missing-zone'
log_reset
OUT=$(run_ow --login-server "$A" enable-subnet)
assert_contains "$OUT" '192.168.10.0/24'
assert_file_contains "$ROOT/etc/config/firewall" "config zone 'tailscale'"
run_ow --login-server "$A" status >/dev/null

# F. accept-routes=true without the site-to-site marker is still flagged.
make_joined_root s2s-f
printf '{"ControlURL":"%s","CorpDNS":false,"RouteAll":true,"AdvertiseRoutes":["192.168.10.0/24"],"ExitNodeID":""}\n' "$A" \
    > "$ROOT/.ts-state/prefs"
set +e
OUT=$(run_ow --login-server "$A" status 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'RouteAll=true without site-to-site must fail status'
assert_contains "$OUT" 'accept-routes-without-site-to-site'

# G. site-to-site inconsistency: marker on but lan_to_ts removed by hand.
make_joined_root s2s-g
run_ow --login-server "$A" enable-site-to-site >/dev/null
awk '
    /^config forwarding .lan_to_ts.$/ { skipping = 1; next }
    skipping && /^config / { skipping = 0 }
    !skipping { print }
' "$ROOT/etc/config/firewall" > "$ROOT/etc/config/firewall.tmp"
mv "$ROOT/etc/config/firewall.tmp" "$ROOT/etc/config/firewall"
set +e
OUT=$(run_ow --login-server "$A" status 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'site-to-site without lan_to_ts must fail status'
assert_contains "$OUT" 'site-to-site-lan-to-ts-missing'
log_reset
OUT=$(run_ow --login-server "$A" apply)
assert_contains "$OUT" 'Apply complete'
assert_file_contains "$ROOT/etc/config/firewall" "config forwarding 'lan_to_ts'"
run_ow --login-server "$A" status >/dev/null

################################################################
# H. the failover watchdog keeps accept-routes on in site-to-site
#    mode (regression: it used to force --accept-routes=false after
#    every switch) and off in remote-access mode.
################################################################

make_joined_root s2s-h
# Logged-out start: profile-add then registers A through a real fixture
# login (the adoption path needs an existing tailscale profile entry).
rm -f "$ROOT/.ts-state/prefs" "$ROOT/.ts-state/profiles"
run_ow --login-server "$A" install >/dev/null
new_key ha
run_ow --login-server "$A" --auth-key-file "$KEYFILE" profile-add >/dev/null
new_key hb
run_ow --login-server "$B" --auth-key-file "$KEYFILE" profile-add >/dev/null
run_ow --failure-threshold 2 --recovery-threshold 2 --cooldown 1 enable-failover >/dev/null
run_ow --login-server "$A" enable-site-to-site >/dev/null
[ "$(routeall)" = true ] || fail 'site-to-site setup failed before the watchdog test'

FAKE_PROBE_DOWN=hs.example.com watchdog_cycles 1
[ "$(cur_url)" = "$A" ] || fail 'must not switch before the failure threshold'
FAKE_PROBE_DOWN=hs.example.com watchdog_cycles 1
[ "$(cur_url)" = "$B" ] || fail "expected failover to B, got $(cur_url)"
[ "$(routeall)" = true ] || fail 'the watchdog must keep accept-routes=true in site-to-site mode'
# Bare status: after the switch the active network is B, so an explicit
# --login-server A would (correctly) trip requested-controlurl-differs.
run_ow status >/dev/null

# Back to remote-access: after a switch the watchdog converges false again.
run_ow disable-site-to-site >/dev/null
sleep 2  # let the 1s cooldown clear deterministically
FAKE_PROBE_DOWN=hs-b.example.com watchdog_cycles 2
[ "$(cur_url)" = "$A" ] || fail "expected failover back to A, got $(cur_url)"
[ "$(routeall)" = false ] || fail 'the watchdog must converge accept-routes=false in remote-access mode'

printf 'OpenWrt site-to-site tests passed.\n'
