#!/bin/sh

# Milestone 5 fixture tests: subnet router advertise + fw4 forwarding
# transaction, CIDR discovery math, overlap hard checks, disable path, and the
# reversible WAN UDP rule.

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
PROJECT_DIR=$(CDPATH= cd "$TEST_DIR/.." 2>/dev/null && pwd -P)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headscale-bootstrap-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

OPENWRT_SCRIPT=$PROJECT_DIR/tailscale-openwrt.sh
OPENWRT_BIN=$TEST_DIR/fixtures/bin-openwrt
LOGIN=https://hs.example.com

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s\n' "$1" | grep -qF -- "$2" || fail "missing: $2"
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

run_ow() {
    env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$OPENWRT_BIN:$PATH" \
        "$OPENWRT_SCRIPT" --root "$ROOT" "$@"
}

# Deployed + joined, no routes advertised yet.
make_joined_root() {
    ROOT=$TMP_DIR/$1
    LOG=$TMP_DIR/$1.log
    mkdir -p "$ROOT"
    cp -a "$TEST_DIR/fixtures/openwrt/." "$ROOT/"
    rm -rf "$ROOT/tmp" "$ROOT/root/tailscale-bootstrap-backups" "$ROOT/etc/tailscale-bootstrap"
    rm -f "$ROOT/etc/rc.d"/*
    ln -sf ../init.d/tailscale "$ROOT/etc/rc.d/S90tailscale"
    mkdir -p "$ROOT/dev/net"
    if [ -c /dev/net/tun ]; then
        ln -sf /dev/net/tun "$ROOT/dev/net/tun"
    elif [ "$(id -u)" = 0 ]; then
        mknod "$ROOT/dev/net/tun" c 10 200 2>/dev/null || true
    fi
    # No routes advertised yet.
    printf '{"ControlURL":"%s","CorpDNS":false,"RouteAll":false,"AdvertiseRoutes":[],"ExitNodeID":""}\n' "$LOGIN" \
        > "$ROOT/.ts-state/prefs"
    # Fresh firewall: no tailscale zone/forwarding yet (install/apply not run).
    awk '
        /^config zone .tailscale.$/ { skipping = 1; next }
        /^config forwarding .ts_to_lan.$/ { skipping = 1; next }
        skipping && /^config / { skipping = 0 }
        !skipping { print }
    ' "$ROOT/etc/config/firewall" > "$ROOT/etc/config/firewall.tmp"
    mv "$ROOT/etc/config/firewall.tmp" "$ROOT/etc/config/firewall"
    log_reset
}

[ -c /dev/net/tun ] || { printf 'SKIP: /dev/net/tun unavailable\n'; exit 0; }

################################################################
# A. enable-subnet with discovered LAN CIDR
################################################################

make_joined_root sw-a
OUT=$(run_ow --login-server "$LOGIN" enable-subnet)
assert_contains "$OUT" '192.168.10.0/24'
assert_contains "$OUT" 'awaiting approval'
assert_contains "$OUT" 'approve-routes'
PREFS=$ROOT/.ts-state/prefs
assert_file_contains "$PREFS" '"AdvertiseRoutes":["192.168.10.0/24"]'
FW=$ROOT/etc/config/firewall
assert_file_contains "$FW" "config forwarding 'ts_to_lan'"
TS_FWD=$(awk "/^config forwarding 'ts_to_lan'/{flag=1;next} /^config /{flag=0} flag" "$FW")
assert_contains "$TS_FWD" "option src 'tailscale'"
assert_contains "$TS_FWD" "option dest 'lan'"
assert_contains "$TS_FWD" "option family 'ipv4'"
line_set=$(log_line_of 'tailscale set --advertise-routes=192.168.10.0/24')
line_check=$(log_line_of 'fw4 check')
line_commit=$(log_line_of 'uci commit firewall')
line_reload=$(log_line_of 'init firewall reload')
[ -n "$line_set" ] || fail 'advertise not logged'
[ -n "$line_check" ] || fail 'fw4 check not logged'
[ "$line_set" -lt "$line_check" ] || fail 'advertise must precede fw4 check'
[ "$line_check" -lt "$line_commit" ] || fail 'fw4 check must precede commit'
[ "$line_commit" -lt "$line_reload" ] || fail 'commit must precede reload'

# A2. Idempotent re-run: no new advertise, no commit, no reload.
log_reset
OUT=$(run_ow --login-server "$LOGIN" enable-subnet)
assert_contains "$OUT" '192.168.10.0/24'
log_not_has 'tailscale set' || fail 'already-advertised subnet must not re-run set'
log_not_has 'uci commit firewall' || fail 'converged forwarding must not commit again'
log_not_has 'init firewall reload' || fail 'converged forwarding must not reload again'

# A3. Non-canonical request is normalized, still a no-op against the same net.
OUT=$(run_ow --login-server "$LOGIN" --subnet 192.168.10.77/24 enable-subnet)
assert_contains "$OUT" '192.168.10.0/24'

################################################################
# B. CIDR discovery math (PLAN 24.1: no naive .1 -> .0 rewrite)
################################################################

make_joined_root sw-b
OUT=$(env FAKE_LAN_IP=192.168.10.129 FAKE_LAN_MASK=25 FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" \
    PATH="$OPENWRT_BIN:$PATH" "$OPENWRT_SCRIPT" --root "$ROOT" --login-server "$LOGIN" enable-subnet)
assert_contains "$OUT" '192.168.10.128/25'
assert_file_contains "$ROOT/.ts-state/prefs" '"AdvertiseRoutes":["192.168.10.128/25"]'

################################################################
# C. Overlap hard checks (PLAN 41)
################################################################

make_joined_root sw-c
set +e
OUT=$(run_ow --login-server "$LOGIN" --subnet 100.64.1.0/24 enable-subnet 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'CGNAT-overlapping subnet must be refused'
assert_contains "$OUT" '100.64.0.0/10'

make_joined_root sw-c2
set +e
OUT=$(run_ow --login-server "$LOGIN" --subnet 100.0.0.0/8 enable-subnet 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'subnet containing the CGNAT range must be refused'
assert_contains "$OUT" 'contains the Tailscale CGNAT range'

make_joined_root sw-c3
set +e
OUT=$(run_ow --login-server "$LOGIN" --subnet 192.168.10.0/25 enable-subnet 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 0 ] || fail 'partial overlap with the LAN itself warns but proceeds'
assert_contains "$OUT" 'overlaps local route'

make_joined_root sw-c4
printf '{"ControlURL":"%s","CorpDNS":false,"RouteAll":false,"AdvertiseRoutes":["10.99.0.0/16"],"ExitNodeID":""}\n' "$LOGIN" \
    > "$ROOT/.ts-state/prefs"
set +e
OUT=$(run_ow --login-server "$LOGIN" --subnet 10.99.1.0/24 enable-subnet 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'overlap with another advertised route must be refused'
assert_contains "$OUT" 'overlaps the already advertised'

# Additional route is preserved when advertising a second, disjoint subnet.
make_joined_root sw-c5
printf '{"ControlURL":"%s","CorpDNS":false,"RouteAll":false,"AdvertiseRoutes":["10.99.0.0/16"],"ExitNodeID":""}\n' "$LOGIN" \
    > "$ROOT/.ts-state/prefs"
OUT=$(run_ow --login-server "$LOGIN" --subnet 192.168.10.0/24 enable-subnet)
assert_file_contains "$ROOT/.ts-state/prefs" '10.99.0.0/16'
assert_file_contains "$ROOT/.ts-state/prefs" '192.168.10.0/24'

################################################################
# D. disable-subnet
################################################################

make_joined_root sw-d
run_ow --login-server "$LOGIN" enable-subnet >/dev/null
log_reset
OUT=$(run_ow --login-server "$LOGIN" --subnet 192.168.10.0/24 disable-subnet)
assert_contains "$OUT" 'disabled'
assert_file_contains "$ROOT/.ts-state/prefs" '"AdvertiseRoutes":[]'
assert_file_not_contains "$ROOT/etc/config/firewall" "config forwarding 'ts_to_lan'"
log_has 'tailscale set --advertise-routes=' || fail 'withdraw must set empty routes'
line_check=$(log_line_of 'fw4 check')
line_commit=$(log_line_of 'uci commit firewall')
[ -n "$line_commit" ] || fail 'removal must commit'
[ "$line_check" -lt "$line_commit" ] || fail 'fw4 check must precede the removal commit'

################################################################
# E. allow-wan-udp on/off
################################################################

make_joined_root sw-e
OUT=$(run_ow --login-server "$LOGIN" allow-wan-udp)
assert_contains "$OUT" '41641'
FW=$ROOT/etc/config/firewall
assert_file_contains "$FW" "config rule 'ts_wan_udp'"
TS_RULE=$(awk "/^config rule 'ts_wan_udp'/{flag=1;next} /^config /{flag=0} flag" "$FW")
assert_contains "$TS_RULE" "option src 'wan'"
assert_contains "$TS_RULE" "option proto 'udp'"
assert_contains "$TS_RULE" "option dest_port '41641'"
assert_contains "$TS_RULE" "option target 'ACCEPT'"
assert_contains "$TS_RULE" "option family 'ipv4'"
line_check=$(log_line_of 'fw4 check')
line_commit=$(log_line_of 'uci commit firewall')
[ "$line_check" -lt "$line_commit" ] || fail 'fw4 check must precede the wan-udp commit'

log_reset
OUT=$(run_ow --login-server "$LOGIN" --allow-wan-udp=false allow-wan-udp)
assert_contains "$OUT" 'removed'
assert_file_not_contains "$ROOT/etc/config/firewall" "config rule 'ts_wan_udp'"

log_reset
OUT=$(run_ow --login-server "$LOGIN" --allow-wan-udp=false allow-wan-udp)
assert_contains "$OUT" 'nothing to do'

printf 'OpenWrt subnet/WAN-UDP tests passed.\n'
