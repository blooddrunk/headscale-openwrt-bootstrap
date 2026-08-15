#!/bin/sh

# Milestone 7 fixture tests: failure injection, idempotency and the reboot
# steady state (PLAN sections 39, 40 and 31's automated subset).

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
PROJECT_DIR=$(CDPATH= cd "$TEST_DIR/.." 2>/dev/null && pwd -P)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headscale-bootstrap-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

VPS_SCRIPT=$PROJECT_DIR/headscale-vps.sh
OW_SCRIPT=$PROJECT_DIR/tailscale-openwrt.sh
VPS_BIN=$TEST_DIR/fixtures/bin-vps
OW_BIN=$TEST_DIR/fixtures/bin-openwrt
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

make_vps_root() {
    VROOT=$TMP_DIR/$1
    VLOG=$TMP_DIR/$1.vps.log
    mkdir -p "$VROOT"
    cp -a "$TEST_DIR/fixtures/vps/." "$VROOT/"
    rm -rf "$VROOT/etc/headscale" "$VROOT/var/lib/headscale" "$VROOT/var/backups" \
        "$VROOT/.systemd" "$VROOT/.headscale-state" "$VROOT/.headscale-installed" \
        "$VROOT/var/lib/headscale-bootstrap"
    : > "$VLOG"
}

vps() {
    env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" \
        "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 "$@"
}

make_ow_root() {
    OROOT=$TMP_DIR/$1
    OLOG=$TMP_DIR/$1.ow.log
    mkdir -p "$OROOT"
    cp -a "$TEST_DIR/fixtures/openwrt/." "$OROOT/"
    rm -rf "$OROOT/tmp" "$OROOT/root/tailscale-bootstrap-backups" "$OROOT/etc/tailscale-bootstrap"
    rm -f "$OROOT/etc/rc.d"/*
    mkdir -p "$OROOT/dev/net"
    if [ -c /dev/net/tun ]; then
        ln -sf /dev/net/tun "$OROOT/dev/net/tun"
    elif [ "$(id -u)" = 0 ]; then
        mknod "$OROOT/dev/net/tun" c 10 200 2>/dev/null || true
    fi
    : > "$OLOG"
}

ow() {
    env FAKE_OPENWRT_ROOT="$OROOT" FAKE_LOG="$OLOG" PATH="$OW_BIN:$PATH" \
        "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" "$@"
}

expect_fail() {
    expect_fail_code=$1
    shift
    set +e
    expect_fail_out=$( "$@" 2>&1 )
    expect_fail_actual=$?
    set -e
    [ "$expect_fail_actual" -eq "$expect_fail_code" ] || {
        printf '%s\n' "$expect_fail_out" >&2
        fail "expected exit $expect_fail_code, got $expect_fail_actual"
    }
    printf '%s\n' "$expect_fail_out"
}

OW_SKIP=0
[ -c /dev/net/tun ] || OW_SKIP=1

################################################################
# VPS failure injection
################################################################

# 1. DNS pointing elsewhere (e.g. Cloudflare proxied) blocks install.
make_vps_root vps-fi1
OUT=$(expect_fail 2 env FAKE_SS_EMPTY=1 FAKE_GETENT_IP=198.51.100.99 FAKE_VPS_ROOT="$VROOT" \
    FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" \
    --domain hs.example.com --expected-public-ip 203.0.113.10 install)
assert_contains "$OUT" 'dns-not-confirmed-or-proxied'

# 2. Unknown process on 443 -> fail closed, no takeover.
make_vps_root vps-fi2
OUT=$(expect_fail 2 env FAKE_NO_DOCKER=1 FAKE_SS_UNKNOWN_443=1 FAKE_VPS_ROOT="$VROOT" \
    FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" \
    --domain hs.example.com --expected-public-ip 203.0.113.10 plan)
assert_contains "$OUT" 'unknown-service-on-443'

# 3. Deb metadata mismatch -> abort before apt installs anything.
make_vps_root vps-fi3
OUT=$(expect_fail 1 env FAKE_SS_EMPTY=1 FAKE_MISMATCH_DEB=1 FAKE_VPS_ROOT="$VROOT" \
    FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" \
    --domain hs.example.com --expected-public-ip 203.0.113.10 install)
assert_contains "$OUT" 'metadata mismatch'
if grep -qF 'apt-get install' "$VLOG"; then fail 'apt-get must not run after metadata mismatch'; fi

# 3b. Slow headscale startup: the first /health probes miss while the
#     service initializes (Type=simple returns before the port binds);
#     the retry window must converge and install must still succeed.
make_vps_root vps-fi3b
OUT=$(env FAKE_SS_EMPTY=1 FAKE_HEALTH_DELAY=2 FAKE_VPS_ROOT="$VROOT" \
    FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" \
    --domain hs.example.com --expected-public-ip 203.0.113.10 install)
assert_contains "$OUT" 'Installed headscale'

# 4. configtest failure during apply -> no restart, config untouched.
#    (Drift is introduced on an unmanaged key so the domain-switch guard is
#    not the thing under test here.)
make_vps_root vps-fi4
vps install >/dev/null
: > "$VLOG"
sed -i 's|^metrics_listen_addr:.*|metrics_listen_addr: 127.0.0.1:9091|' "$VROOT/etc/headscale/config.yaml"
OUT=$(expect_fail 1 env FAKE_SS_EMPTY=1 FAKE_FAIL_CONFIGTEST=1 FAKE_VPS_ROOT="$VROOT" \
    FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" \
    --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
if grep -qF 'systemctl restart headscale' "$VLOG"; then fail 'no restart may happen when configtest fails'; fi
assert_file_contains "$VROOT/etc/headscale/config.yaml" 'metrics_listen_addr: 127.0.0.1:9091'

# 5. Failed health after update -> automatic rollback to the pre-update snapshot.
make_vps_root vps-fi5
vps install >/dev/null
TAGS="v0.29.4 v0.29.3"
OUT=$(expect_fail 1 env FAKE_SS_EMPTY=1 FAKE_RELEASE_TAGS="$TAGS" FAKE_LOCAL_HEALTH=503 \
    FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" \
    --domain hs.example.com --expected-public-ip 203.0.113.10 update --version 0.29.4)
[ "$(cat "$VROOT/.headscale-state/version")" = 0.29.3 ] || fail 'failed update must roll the package back'
assert_file_contains "$VROOT/etc/headscale/config.yaml" 'server_url: https://hs.example.com'

# 6. Idempotency (PLAN 39): apply x3 stays a no-op after convergence.
make_vps_root vps-idem
vps install >/dev/null
vps apply >/dev/null
: > "$VLOG"
vps apply >/dev/null
vps apply >/dev/null
vps apply >/dev/null
if grep -qF 'systemctl restart headscale' "$VLOG"; then fail 'apply x3 must not restart headscale'; fi
if grep -qF 'users create' "$VLOG"; then fail 'apply must not create users'; fi

if [ "$OW_SKIP" = 0 ]; then
    ################################################################
    # OpenWrt failure injection
    ################################################################

    # 7. Missing TUN device blocks install.
    make_ow_root ow-fi7
    rm -f "$OROOT/dev/net/tun"
    OUT=$(expect_fail 2 ow install)
    assert_contains "$OUT" 'tun-missing'

    # 8. Client too old for the server's minimum -> stop (PLAN 17).
    make_ow_root ow-fi8
    OUT=$(expect_fail 1 ow --min-client-version 1.99.0 install)
    assert_contains "$OUT" 'older than the required minimum'
    OUT=$(ow --min-client-version 1.98.0 install)
    assert_contains "$OUT" 'Install complete'

    # 9. tailscale up transport failure -> key kept, no partial state.
    make_ow_root ow-fi9
    rm -f "$OROOT/.ts-state/prefs"
    ow install >/dev/null
    ow apply >/dev/null
    KFILE=$TMP_DIR/k7
    printf 'hskey-auth-FI9\n' > "$KFILE"; chmod 600 "$KFILE"
    OUT=$(expect_fail 1 env FAKE_OPENWRT_ROOT="$OROOT" FAKE_FAIL_TS_UP=1 FAKE_LOG="$OLOG" \
        PATH="$OW_BIN:$PATH" "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" --auth-key-file "$KFILE" join)
    [ -f "$KFILE" ] || fail 'key must be kept when up fails'
    rm -f "$KFILE"

    # 10. opkg failure during install aborts cleanly.
    make_ow_root ow-fi10
    rm -rf "$OROOT/.opkg-installed" "$OROOT/.opkg-versions"
    OUT=$(expect_fail 1 env FAKE_OPENWRT_ROOT="$OROOT" FAKE_FAIL_OPKG=1 FAKE_LOG="$OLOG" \
        PATH="$OW_BIN:$PATH" "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" install)
    assert_contains "$OUT" 'opkg'

    # 11. Idempotency: apply x3 keeps exactly one zone/forwarding and no resets.
    make_ow_root ow-idem
    ow install >/dev/null
    ow apply >/dev/null
    : > "$OLOG"
    ow apply >/dev/null
    ow apply >/dev/null
    ow apply >/dev/null
    [ "$(grep -c "config zone 'tailscale'" "$OROOT/etc/config/firewall")" = 1 ] || fail 'zone duplicated'
    if grep -qF 'tailscale up' "$OLOG"; then fail 'apply must never call tailscale up'; fi
    if grep -qF -- '--reset' "$OLOG"; then fail '--reset must never appear'; fi
    if grep -qF 'network reload' "$OLOG"; then fail 'network reload must never appear'; fi
    if grep -qF 'uci commit firewall' "$OLOG"; then fail 'converged apply x3 must not commit'; fi

    # 12. Reboot steady state (PLAN 31, automated subset): boot links present
    #     and a cold status check passes on the deployed system.
    make_ow_root ow-reboot
    ow install >/dev/null
    ow apply >/dev/null
    KFILE=$TMP_DIR/k12
    printf 'hskey-auth-REBOOT\n' > "$KFILE"; chmod 600 "$KFILE"
    ow --auth-key-file "$KFILE" join >/dev/null
    ow enable-subnet >/dev/null
    [ -L "$OROOT/etc/rc.d/S90tailscale-core" ] || fail 'boot link missing (reboot would not start the daemon)'
    [ ! -e "$OROOT/etc/rc.d/S90tailscale" ] || fail 'unsafe stock service would start at boot'
    set +e
    ow status --json > "$TMP_DIR/reboot-status.json"
    STATUS_CODE=$?
    set -e
    [ "$STATUS_CODE" -eq 0 ] || { cat "$TMP_DIR/reboot-status.json" >&2; fail 'post-deploy status must be OK'; }
    grep -qF '"fw4_device":"tailscale"' "$TMP_DIR/reboot-status.json" || fail 'zone binding lost'
    grep -qF '"control_url":"'"$LOGIN"'"' "$TMP_DIR/reboot-status.json" || fail 'ControlURL lost'
    assert_file_contains "$OROOT/.ts-state/prefs" '192.168.10.0/24'

    # 13. /etc/init.d/firewall reload fails -> the fw4 reload fallback applies
    #     the ruleset and join still completes (Kwrt-style patched init).
    #     The fixture node is pre-registered, so join converges without a new
    #     login; its zone sections are removed first to force a pending
    #     firewall transaction.
    make_ow_root ow-fi13
    ow install >/dev/null
    env FAKE_OPENWRT_ROOT="$OROOT" PATH="$OW_BIN:$PATH" sh -c \
        'uci -q delete firewall.tailscale; uci -q delete firewall.ts_to_lan; uci -q delete firewall.ts_wan_udp; uci commit firewall'
    KFILE=$TMP_DIR/k13
    printf 'hskey-auth-FI13\n' > "$KFILE"; chmod 600 "$KFILE"
    : > "$OLOG"
    OUT=$(env FAKE_OPENWRT_ROOT="$OROOT" FAKE_LOG="$OLOG" FAKE_FAIL_FIREWALL_RELOAD=1 \
        PATH="$OW_BIN:$PATH" "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" \
        --auth-key-file "$KFILE" join 2>&1)
    assert_contains "$OUT" 'Join verified'
    assert_contains "$OUT" 'retrying the reload with fw4 directly'
    assert_file_contains "$OLOG" 'fw4 reload'
    [ "$(grep -c "config zone 'tailscale'" "$OROOT/etc/config/firewall")" = 1 ] || fail 'zone missing after fallback reload'
    rm -f "$KFILE"

    # 14. Both reload paths fail while the committed config still passes
    #     fw4 check: join warns and continues instead of aborting the
    #     transaction with a committed-but-never-verified config.
    make_ow_root ow-fi14
    ow install >/dev/null
    env FAKE_OPENWRT_ROOT="$OROOT" PATH="$OW_BIN:$PATH" sh -c \
        'uci -q delete firewall.tailscale; uci -q delete firewall.ts_to_lan; uci -q delete firewall.ts_wan_udp; uci commit firewall'
    KFILE=$TMP_DIR/k14
    printf 'hskey-auth-FI14\n' > "$KFILE"; chmod 600 "$KFILE"
    : > "$OLOG"
    OUT=$(env FAKE_OPENWRT_ROOT="$OROOT" FAKE_LOG="$OLOG" FAKE_FAIL_FIREWALL_RELOAD=1 \
        FAKE_FAIL_FW4_RELOAD=1 PATH="$OW_BIN:$PATH" "$OW_SCRIPT" --root "$OROOT" \
        --login-server "$LOGIN" --auth-key-file "$KFILE" join 2>&1)
    assert_contains "$OUT" 'Join verified'
    assert_contains "$OUT" 'firewall reload failed on this router'
    [ "$(grep -c "config zone 'tailscale'" "$OROOT/etc/config/firewall")" = 1 ] || fail 'zone missing after warn-continue'
    [ -z "$(FAKE_OPENWRT_ROOT="$OROOT" PATH="$OW_BIN:$PATH" uci -q changes firewall 2>/dev/null)" ] || fail 'firewall UCI must be clean after warn-continue'
    rm -f "$KFILE"
fi

printf 'Failure injection and idempotency tests passed.\n'
