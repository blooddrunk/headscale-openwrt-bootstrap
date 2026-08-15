#!/bin/sh

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
PROJECT_DIR=$(CDPATH= cd "$TEST_DIR/.." 2>/dev/null && pwd -P)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headscale-bootstrap-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

VPS_SCRIPT=$PROJECT_DIR/headscale-vps.sh
OPENWRT_SCRIPT=$PROJECT_DIR/tailscale-openwrt.sh
VPS_BIN=$TEST_DIR/fixtures/bin-vps
OPENWRT_BIN=$TEST_DIR/fixtures/bin-openwrt

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    assert_text=$1
    assert_needle=$2
    printf '%s\n' "$assert_text" | grep -qF "$assert_needle" || fail "missing: $assert_needle"
}

assert_json_value() {
    assert_json=$1
    assert_filter=$2
    printf '%s\n' "$assert_json" | jq -e "$assert_filter" >/dev/null || fail "JSON assertion failed: $assert_filter"
}

assert_code() {
    assert_expected=$1
    shift
    set +e
    assert_output=$("$@" 2>&1)
    assert_actual=$?
    set -e
    [ "$assert_actual" -eq "$assert_expected" ] || {
        printf '%s\n' "$assert_output" >&2
        fail "expected exit $assert_expected, got $assert_actual"
    }
    printf '%s\n' "$assert_output"
}

chmod +x "$TEST_DIR"/fixtures/bin-vps/* "$TEST_DIR"/fixtures/bin-openwrt/*

VPS_ROOT=$TMP_DIR/vps
OPENWRT_ROOT=$TMP_DIR/openwrt
mkdir -p "$VPS_ROOT" "$OPENWRT_ROOT"
cp -a "$TEST_DIR/fixtures/vps/." "$VPS_ROOT/"
cp -a "$TEST_DIR/fixtures/openwrt/." "$OPENWRT_ROOT/"
printf 'PRIVATE-STATE-MARKER\n' > "$OPENWRT_ROOT/etc/tailscale/tailscaled.state"
printf 'PRIVATE-DB-MARKER\n' > "$VPS_ROOT/var/lib/headscale/db.sqlite"
chmod 600 "$OPENWRT_ROOT/etc/tailscale/tailscaled.state" "$VPS_ROOT/var/lib/headscale/db.sqlite"

# The TUN check uses [ -c ], so fixture roots need a character device.  Try
# mknod when running as root, else link the host tun device when present.
OPENWRT_TUN_OK=no
mkdir -p "$OPENWRT_ROOT/dev/net"
if [ "$(id -u)" = 0 ]; then
    mknod "$OPENWRT_ROOT/dev/net/tun" c 10 200 2>/dev/null || true
elif [ -c /dev/net/tun ]; then
    ln -sf /dev/net/tun "$OPENWRT_ROOT/dev/net/tun" 2>/dev/null || true
fi
[ -c "$OPENWRT_ROOT/dev/net/tun" ] && OPENWRT_TUN_OK=yes

openwrt_env() {
    env FAKE_OPENWRT_ROOT="$OPENWRT_ROOT" PATH="$OPENWRT_BIN:$PATH" "$@"
}

VPS_DISCOVER=$(env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" --expected-public-ip 203.0.113.10 discover --json)
assert_json_value "$VPS_DISCOVER" '.headscale_version == "0.29.3" and .docker_network_mode == "host" and .panel_mount_www == "yes" and .panel_mount_confd == "yes" and .dns_match == "match" and .udp_3478 == "free"'

VPS_PLAN=$(env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 plan --json)
assert_json_value "$VPS_PLAN" '.blocked == false and .effective_proxy == "1panel" and .mutates_system == "no"'

VPS_STATUS=$(env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" status --json)
assert_json_value "$VPS_STATUS" '.ok == true and .configtest == "pass" and .local_health == "200" and .public_health == "200"'

VPS_UNSAFE_ROOT=$TMP_DIR/vps-unsafe
mkdir -p "$VPS_UNSAFE_ROOT"
cp -a "$VPS_ROOT/." "$VPS_UNSAFE_ROOT/"
sed -i 's/listen_addr: 127.0.0.1:8080/listen_addr: 0.0.0.0:8080/' "$VPS_UNSAFE_ROOT/etc/headscale/config.yaml"
VPS_UNSAFE_PLAN=$(assert_code 2 env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_UNSAFE_ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 plan --json)
assert_contains "$VPS_UNSAFE_PLAN" 'existing-config-unsafe'

OPENWRT_DISCOVER=$(openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" discover --json)
assert_json_value "$OPENWRT_DISCOVER" '.unsafe_luci_helper == "yes" and .control_url == "https://hs.example.com" and .advertise_routes == "192.168.10.0/24" and .network_tailscale == "no"'
# Regression: the commented-out `#option advertise_exit_node '1'` default in the
# luci-app-tailscale UCI config must NOT raise exit-node risk.
assert_json_value "$OPENWRT_DISCOVER" '.exit_node_risk == "no"'
assert_json_value "$OPENWRT_DISCOVER" '.network_changes == "clean" and .firewall_changes == "clean"'

set +e
OPENWRT_PLAN=$(openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" --login-server https://other.example.test plan --json)
OPENWRT_PLAN_CODE=$?
set -e
[ "$OPENWRT_PLAN_CODE" -eq 2 ] || fail "expected openwrt plan exit 2, got $OPENWRT_PLAN_CODE"
assert_contains "$OPENWRT_PLAN" 'different-existing-controlurl'

OPENWRT_NETWORK_CONFLICT_ROOT=$TMP_DIR/openwrt-network-conflict
mkdir -p "$OPENWRT_NETWORK_CONFLICT_ROOT"
cp -a "$OPENWRT_ROOT/." "$OPENWRT_NETWORK_CONFLICT_ROOT/"
rm -rf "$OPENWRT_NETWORK_CONFLICT_ROOT/dev"
printf "\nconfig interface 'tailscale'\n\toption proto 'none'\n" >> "$OPENWRT_NETWORK_CONFLICT_ROOT/etc/config/network"
set +e
OPENWRT_NETWORK_CONFLICT=$(env FAKE_OPENWRT_ROOT="$OPENWRT_NETWORK_CONFLICT_ROOT" PATH="$OPENWRT_BIN:$PATH" "$OPENWRT_SCRIPT" --root "$OPENWRT_NETWORK_CONFLICT_ROOT" --login-server https://hs.example.com plan --json)
OPENWRT_NETWORK_CONFLICT_CODE=$?
set -e
[ "$OPENWRT_NETWORK_CONFLICT_CODE" -eq 2 ] || fail "expected conflict plan exit 2, got $OPENWRT_NETWORK_CONFLICT_CODE"
assert_contains "$OPENWRT_NETWORK_CONFLICT" 'existing-network-tailscale-section'

# Positive path: a fully deployed, clean baseline must produce READY/OK exit 0.
# Skipped only when no TUN character device could be provisioned for the fixture.
if [ "$OPENWRT_TUN_OK" = yes ]; then
    set +e
    OPENWRT_PLAN_READY=$(openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" --login-server https://hs.example.com plan --json)
    OPENWRT_PLAN_READY_CODE=$?
    OPENWRT_STATUS_OK=$(openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" status --json)
    OPENWRT_STATUS_OK_CODE=$?
    set -e
    [ "$OPENWRT_PLAN_READY_CODE" -eq 0 ] || { printf '%s\n' "$OPENWRT_PLAN_READY" >&2; fail "clean baseline plan should be READY, exit $OPENWRT_PLAN_READY_CODE"; }
    [ "$OPENWRT_STATUS_OK_CODE" -eq 0 ] || { printf '%s\n' "$OPENWRT_STATUS_OK" >&2; fail "clean baseline status should be OK, exit $OPENWRT_STATUS_OK_CODE"; }
    assert_json_value "$OPENWRT_PLAN_READY" '.blocked == false'
    assert_json_value "$OPENWRT_STATUS_OK" '.ok == true and .fw4_device == "tailscale"'
else
    printf 'SKIP: no TUN character device available for the fixture root; READY/OK path not asserted\n' >&2
fi

# Destructive commands stay fail-closed without their explicit confirmation.
OPENWRT_PURGE_GUARD=$(assert_code 2 openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" purge-identity)
assert_contains "$OPENWRT_PURGE_GUARD" 'yes-i-understand'
VPS_PURGE_GUARD=$(assert_code 2 env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" purge)
assert_contains "$VPS_PURGE_GUARD" 'yes-i-understand'

VPS_BACKUP=$(env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" backup)
VPS_BACKUP_PATH=$(printf '%s\n' "$VPS_BACKUP" | sed -n 's/^Backup created: //p')
[ -n "$VPS_BACKUP_PATH" ] || fail 'VPS backup path missing'
[ -f "$VPS_BACKUP_PATH/manifest.sha256" ] || fail 'VPS manifest missing'
[ -f "$VPS_BACKUP_PATH/source/etc/headscale/config.yaml" ] || fail 'VPS config not backed up'
[ -f "$VPS_BACKUP_PATH/source/var/lib/headscale/db.sqlite" ] || fail 'VPS database not backed up'
[ "$(stat -c '%a' "$VPS_BACKUP_PATH")" = 700 ] || fail 'VPS backup directory is not private'
(cd "$VPS_BACKUP_PATH" && sha256sum -c manifest.sha256 >/dev/null) || fail 'VPS manifest verification failed'
! printf '%s\n' "$VPS_BACKUP" | grep -qF 'PRIVATE-DB-MARKER' || fail 'VPS secret leaked to backup output'
VPS_BACKUP_AGAIN=$(env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" backup)
VPS_BACKUP_AGAIN_PATH=$(printf '%s\n' "$VPS_BACKUP_AGAIN" | sed -n 's/^Backup created: //p')
[ "$VPS_BACKUP_AGAIN_PATH" != "$VPS_BACKUP_PATH" ] || fail 'repeated VPS backup reused a directory'
VPS_BACKUP_JSON=$(env FAKE_VPS_ROOT="$VPS_ROOT" PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VPS_ROOT" backup --json)
assert_json_value "$VPS_BACKUP_JSON" '.command == "backup" and .secret_contents == "not-logged"'

OPENWRT_BACKUP=$(openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" backup)
OPENWRT_BACKUP_PATH=$(printf '%s\n' "$OPENWRT_BACKUP" | sed -n 's/^Backup created: //p')
[ -n "$OPENWRT_BACKUP_PATH" ] || fail 'OpenWrt backup path missing'
[ -f "$OPENWRT_BACKUP_PATH/manifest.sha256" ] || fail 'OpenWrt manifest missing'
[ -f "$OPENWRT_BACKUP_PATH/source/etc/tailscale/tailscaled.state" ] || fail 'OpenWrt state not backed up'
[ "$(stat -c '%a' "$OPENWRT_BACKUP_PATH")" = 700 ] || fail 'OpenWrt backup directory is not private'
(cd "$OPENWRT_BACKUP_PATH" && sha256sum -c manifest.sha256 >/dev/null) || fail 'OpenWrt manifest verification failed'
! printf '%s\n' "$OPENWRT_BACKUP" | grep -qF 'PRIVATE-STATE-MARKER' || fail 'OpenWrt state leaked to backup output'
OPENWRT_BACKUP_JSON=$(openwrt_env "$OPENWRT_SCRIPT" --root "$OPENWRT_ROOT" backup --json)
assert_json_value "$OPENWRT_BACKUP_JSON" '.command == "backup" and .secret_contents == "not-logged"'

printf 'Milestone 1 checks passed.\n'
