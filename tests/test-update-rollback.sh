#!/bin/sh

# Milestone 6 fixture tests: VPS users/keys/route approval, Headscale update
# ordering (stable minors never skipped), rollback as one consistent
# snapshot, cleanup/purge on both sides, and OpenWrt update/rollback/cleanup
# identity preservation.

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

vlog_has() { grep -qF -- "$1" "$VLOG"; }
vlog_line_of() { grep -nF -- "$1" "$VLOG" | head -n 1 | cut -d: -f1; }

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

olog_has() { grep -qF -- "$1" "$OLOG"; }
olog_not_has() { if grep -qF -- "$1" "$OLOG"; then return 1; fi; return 0; }
olog_line_of() { grep -nF -- "$1" "$OLOG" | head -n 1 | cut -d: -f1; }

OW_SKIP=0
[ -c /dev/net/tun ] || OW_SKIP=1

################################################################
# VPS A. ensure-user / issue-key / approve-route
################################################################

make_vps_root vps-a
vps install >/dev/null
OUT=$(vps ensure-user --user home)
assert_contains "$OUT" 'User home created'
USERS=$VROOT/.headscale-state/users
assert_file_contains "$USERS" '1||home'
OUT=$(vps ensure-user --user home)
assert_contains "$OUT" 'already exists'
[ "$(wc -l < "$USERS")" = 1 ] || fail 'ensure-user must not create duplicates'

# Regression (Headscale >= 0.26 table): users that already exist outside this
# script must be matched via the Username column (display name may differ or be
# empty), never re-created (UNIQUE constraint on users.name).
printf '2|Family Room|cabin|\n3||attic|\n' >> "$USERS"
OUT=$(vps ensure-user --user cabin)
assert_contains "$OUT" 'already exists'
OUT=$(vps ensure-user --user attic)
assert_contains "$OUT" 'already exists'
[ "$(wc -l < "$USERS")" = 3 ] || fail 'ensure-user must not duplicate pre-existing users'
OUT=$(vps issue-key --user attic)
printf '%s\n' "$OUT" | grep -qF 'hskey-auth-FIXTURE3' || fail 'issue-key must resolve a pre-existing user by username'

# Primary lookup goes through the filtered list: a genuinely absent user is
# still created (empty display name, username in the Username column).
OUT=$(vps ensure-user --user garage)
assert_contains "$OUT" 'User garage created'
assert_file_contains "$USERS" '4||garage'
[ "$(wc -l < "$USERS")" = 4 ] || fail 'ensure-user must create a genuinely absent user'

# Fallback lookup: Headscale without `users list --name` must still resolve an
# existing user from the unfiltered table (header-aware parse, no duplicates).
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" FAKE_NO_NAME_FILTER=1 \
    PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com \
    --expected-public-ip 203.0.113.10 ensure-user --user garage)
assert_contains "$OUT" 'already exists'
[ "$(wc -l < "$USERS")" = 4 ] || fail 'fallback lookup must not duplicate users'

OUT=$(vps issue-key --user home)
KEY=$(printf '%s\n' "$OUT" | grep -F 'hskey-auth' | sed -n '1p')
[ -n "$KEY" ] || fail 'issue-key did not emit a key'
[ "$(printf '%s\n' "$OUT" | grep -cF "$KEY")" = 1 ] || fail 'key must appear exactly once (stdout only)'
if printf '%s' "$KEY" | LC_ALL=C grep -q "$(printf '\033')"; then
    fail 'issued key must not contain ANSI escape sequences'
fi
KEYFILE=$TMP_DIR/key.out
OUT=$(vps issue-key --user home --expiration 4h --output "$KEYFILE")
assert_file_contains "$KEYFILE" 'hskey-auth-'
if LC_ALL=C grep -q "$(printf '\033')" "$KEYFILE"; then
    fail 'key file must not contain ANSI escape sequences'
fi
[ "$(stat -c '%a' "$KEYFILE")" = 600 ] || fail 'key file must be 0600'
assert_not_contains "$OUT" 'hskey-auth-' || true

OUT=$(vps approve-route --node-id 1 --route 192.168.10.0/24)
assert_contains "$OUT" 'Route updated'
assert_file_contains "$VROOT/.headscale-state/approved-routes" '192.168.10.0/24'

set +e
OUT=$(vps approve-route --node-id 1 --route 192.168.10/24 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'approve-route must validate the CIDR'

################################################################
# VPS B. update: same version no-op, patch step, ordering protections
################################################################

make_vps_root vps-b
vps install >/dev/null
: > "$VLOG"
OUT=$(vps update --version 0.29.3)
assert_contains "$OUT" 'Already at 0.29.3'

set +e
OUT=$(vps update --version 0.28.0 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'downgrade must be refused'
assert_contains "$OUT" 'use rollback'

# Patch bump within the same minor.
TAGS="v0.29.4 v0.29.3 v0.28.4 v0.28.0 v0.27.4 v0.27.0 v0.26.1"
OUT=$(env FAKE_SS_EMPTY=1 FAKE_RELEASE_TAGS="$TAGS" FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" \
    PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com \
    --expected-public-ip 203.0.113.10 update --version 0.29.4)
assert_contains "$OUT" 'now at 0.29.4'
[ "$(cat "$VROOT/.headscale-state/version")" = 0.29.4 ] || fail 'version marker not bumped'
assert_file_contains "$VROOT/etc/headscale/config.yaml" 'server_url: https://hs.example.com'
line_stop=$(vlog_line_of 'systemctl stop headscale')
line_apt=$(vlog_line_of 'apt-get install -y')
line_start=$(vlog_line_of 'systemctl start headscale')
[ -n "$line_stop" ] || fail 'update must stop headscale first'
[ "$line_stop" -lt "$line_apt" ] || fail 'stop must precede package install'
[ "$line_apt" -lt "$line_start" ] || fail 'install must precede start'

# Cross-minor: needs --yes, then walks every stable minor (0.27 -> 0.28 -> 0.29).
make_vps_root vps-b2
vps install >/dev/null
printf '0.27.4\n' > "$VROOT/.headscale-state/version"
set +e
OUT=$(env FAKE_SS_EMPTY=1 FAKE_RELEASE_TAGS="$TAGS" FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" \
    PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com \
    --expected-public-ip 203.0.113.10 update --version 0.29.3 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'cross-minor update without --yes must fail'
assert_contains "$OUT" '--yes'

: > "$VLOG"
OUT=$(env FAKE_SS_EMPTY=1 FAKE_RELEASE_TAGS="$TAGS" FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" \
    PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com \
    --expected-public-ip 203.0.113.10 update --version 0.29.3 --yes)
assert_contains "$OUT" 'now at 0.29.3'
[ "$(cat "$VROOT/.headscale-state/version")" = 0.29.3 ] || fail 'final version wrong'
[ "$(grep -c 'apt-get install -y' "$VLOG")" = 2 ] || fail 'expected exactly two install steps (0.28.4 then 0.29.3)'
vlog_has 'headscale_0.28.4_linux_amd64.deb' || fail 'first step must be the latest 0.28.x patch'
vlog_has 'headscale_0.29.3_linux_amd64.deb' || fail 'second step must be 0.29.3'

# Missing intermediate minor: fail closed, do not guess.
make_vps_root vps-b3
vps install >/dev/null
printf '0.26.1\n' > "$VROOT/.headscale-state/version"
set +e
OUT=$(env FAKE_SS_EMPTY=1 FAKE_RELEASE_TAGS="v0.29.3 v0.27.4 v0.26.1" FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" \
    PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com \
    --expected-public-ip 203.0.113.10 update --version 0.29.3 --yes 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'skipping a missing minor must be refused'
assert_contains "$OUT" 'no stable release found for minor 0.28'

################################################################
# VPS C. rollback restores one consistent snapshot
################################################################

make_vps_root vps-c
vps install >/dev/null
PRE_BACKUPS=$(ls -1 "$VROOT/var/backups/headscale-bootstrap" 2>/dev/null | wc -l)
env FAKE_SS_EMPTY=1 FAKE_RELEASE_TAGS="$TAGS" FAKE_VPS_ROOT="$VROOT" FAKE_LOG="$VLOG" \
    PATH="$VPS_BIN:$PATH" "$VPS_SCRIPT" --root "$VROOT" --domain hs.example.com \
    --expected-public-ip 203.0.113.10 update --version 0.29.4 >/dev/null
[ "$(cat "$VROOT/.headscale-state/version")" = 0.29.4 ] || fail 'update to 0.29.4 failed'
sed -i 's|^server_url:.*|server_url: https://tampered.example|' "$VROOT/etc/headscale/config.yaml"

OUT=$(vps rollback)
assert_contains "$OUT" 'Rollback'
[ "$(cat "$VROOT/.headscale-state/version")" = 0.29.3 ] || fail 'rollback must restore the 0.29.3 package'
assert_file_contains "$VROOT/etc/headscale/config.yaml" 'server_url: https://hs.example.com'
[ -f "$VROOT/.systemd/headscale.active" ] || fail 'service must be active after rollback'
[ -f "$VROOT/.systemd/headscale.enabled" ] || fail 'service must stay enabled after rollback'
[ "$(ls -1 "$VROOT/var/backups/headscale-bootstrap" | wc -l)" -gt "$PRE_BACKUPS" ] || fail 'update must have created backups'

# Explicit BACKUP_ID form.
LATEST=$(ls -1 "$VROOT/var/backups/headscale-bootstrap" | sort | tail -n 1)
OUT=$(vps rollback "$LATEST")
assert_contains "$OUT" 'Rollback'

set +e
OUT=$(vps rollback 19700101T000000Z 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'unknown backup id must fail'

# Refuse INCOMPLETE backups.
BROKEN=$VROOT/var/backups/headscale-bootstrap/20260101T000000Z
mkdir -p "$BROKEN"
: > "$BROKEN/.INCOMPLETE"
set +e
OUT=$(vps rollback 20260101T000000Z 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'INCOMPLETE backup must not be restored'

################################################################
# VPS D. cleanup preserves data; purge needs the explicit flag
################################################################

make_vps_root vps-d
vps install >/dev/null
OUT=$(vps cleanup)
assert_contains "$OUT" 'preserved'
[ -f "$VROOT/etc/headscale/config.yaml" ] || fail 'cleanup must keep /etc/headscale'
[ -d "$VROOT/var/lib/headscale" ] || fail 'cleanup must keep /var/lib/headscale'
[ ! -f "$VROOT/.systemd/headscale.active" ] || fail 'cleanup must stop headscale'
[ ! -f "$VROOT/.systemd/headscale.enabled" ] || fail 'cleanup must disable headscale'
[ ! -f "$VROOT/var/lib/headscale-bootstrap/state.json" ] || fail 'cleanup must drop state.json'

set +e
OUT=$(vps purge 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail 'purge without confirmation must exit 2'
[ -f "$VROOT/etc/headscale/config.yaml" ] || fail 'refused purge must not delete data'

OUT=$(vps purge --yes-i-understand)
assert_contains "$OUT" 'Purge complete'
[ ! -d "$VROOT/etc/headscale" ] || fail 'purge must delete /etc/headscale'
[ ! -d "$VROOT/var/lib/headscale" ] || fail 'purge must delete /var/lib/headscale'

################################################################
# OpenWrt E. update preserves identity, rewrites a broken core
################################################################

if [ "$OW_SKIP" = 0 ]; then
    make_ow_root ow-e
    ow install >/dev/null
    printf 'hskey\n' > "$TMP_DIR/k"; chmod 600 "$TMP_DIR/k"
    env FAKE_OPENWRT_ROOT="$OROOT" FAKE_LOG="$OLOG" PATH="$OW_BIN:$PATH" \
        "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" --auth-key-file "$TMP_DIR/k" join >/dev/null
    # Corrupt the core init (as a package upgrade might) and record identity.
    printf '#!/bin/sh\ncorrupted\n' > "$OROOT/etc/init.d/tailscale-core"
    PREFS_BEFORE=$(cat "$OROOT/.ts-state/prefs")
    STATE_BEFORE=$(cat "$OROOT/etc/tailscale/tailscaled.state")
    STOCK_BEFORE=$(cat "$OROOT/etc/init.d/tailscale")
    : > "$OLOG"

    OUT=$(env FAKE_OPENWRT_ROOT="$OROOT" FAKE_OPKG_UPGRADE_VERSION=1.99.0-r1 FAKE_LOG="$OLOG" \
        PATH="$OW_BIN:$PATH" "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" update)
    assert_contains "$OUT" 'Update complete'
    olog_has 'opkg upgrade tailscale' || fail 'opkg upgrade not called'
    olog_has 'init tailscale-core restart' || fail 'tailscale-core must be restarted'
    olog_not_has 'network reload' || fail 'update must never reload network'
    olog_not_has 'init tailscale stop' || fail 'update must never stop the stock service'
    assert_contains "$(env FAKE_OPENWRT_ROOT="$OROOT" PATH="$OW_BIN:$PATH" \
        "$OW_SCRIPT" --root "$OROOT" --login-server "$LOGIN" discover --json)" '"core_fingerprint":"verified"'
    [ "$(cat "$OROOT/.ts-state/prefs")" = "$PREFS_BEFORE" ] || fail 'prefs must survive update'
    [ "$(cat "$OROOT/etc/tailscale/tailscaled.state")" = "$STATE_BEFORE" ] || fail 'identity must survive update'
    [ "$(cat "$OROOT/etc/init.d/tailscale")" = "$STOCK_BEFORE" ] || fail 'stock init must be untouched'

    ################################################################
    # OpenWrt F. rollback restores configs and identity
    ################################################################

    make_ow_root ow-f
    ow backup >/dev/null
    printf "\nconfig zone 'bogus'\n\toption name 'bogus'\n" >> "$OROOT/etc/config/firewall"
    rm -f "$OROOT/etc/init.d/tailscale-core"
    OUT=$(ow rollback)
    assert_contains "$OUT" 'Rollback complete'
    assert_file_not_contains "$OROOT/etc/config/firewall" "config zone 'bogus'"
    assert_file_contains "$OROOT/etc/config/firewall" "config zone 'tailscale'"
    [ -f "$OROOT/etc/init.d/tailscale-core" ] || fail 'rollback must restore tailscale-core'
    [ -f "$OROOT/etc/tailscale/tailscaled.state" ] || fail 'rollback must restore the identity file'
    olog_not_has 'init tailscale stop' || fail 'rollback must never stop the stock service'

    ################################################################
    # OpenWrt G. cleanup removes only what this script owns
    ################################################################

    make_ow_root ow-g
    ow install >/dev/null
    OUT=$(ow cleanup)
    assert_contains "$OUT" 'Cleanup complete'
    [ ! -f "$OROOT/etc/init.d/tailscale-core" ] || fail 'cleanup must remove tailscale-core'
    [ ! -e "$OROOT/etc/rc.d/S90tailscale-core" ] || fail 'cleanup must remove the boot link'
    assert_file_not_contains "$OROOT/etc/config/firewall" "config zone 'tailscale'"
    assert_file_not_contains "$OROOT/etc/config/firewall" "config forwarding 'ts_to_lan'"
    [ -f "$OROOT/etc/tailscale/tailscaled.state" ] || fail 'cleanup must keep the identity file'
    [ -f "$OROOT/etc/init.d/tailscale" ] || fail 'cleanup must keep the stock init file'
    [ -f "$OROOT/.opkg-installed/tailscale" ] || fail 'cleanup must keep packages'
    [ ! -f "$OROOT/etc/tailscale-bootstrap/state.json" ] || fail 'cleanup must drop state.json'
    olog_not_has 'init tailscale stop' || fail 'cleanup must never stop the stock service'
    olog_line=$(grep -nF 'fw4 check' "$OLOG" | head -n 1 | cut -d: -f1)
    olog_commit=$(grep -nF 'uci commit firewall' "$OLOG" | head -n 1 | cut -d: -f1)
    [ "$olog_line" -lt "$olog_commit" ] || fail 'cleanup firewall removal must pass fw4 check first'
    # Second cleanup is a safe no-op.
    OUT=$(ow cleanup)
    assert_contains "$OUT" 'Cleanup complete'

    ################################################################
    # OpenWrt H. purge-identity
    ################################################################

    make_ow_root ow-h
    set +e
    OUT=$(ow purge-identity 2>&1)
    CODE=$?
    set -e
    [ "$CODE" -eq 2 ] || fail 'purge-identity without confirmation must exit 2'
    [ -f "$OROOT/etc/tailscale/tailscaled.state" ] || fail 'refused purge must keep identity'

    OUT=$(ow purge-identity --yes-i-understand)
    assert_contains "$OUT" 'new Headscale node registration'
    [ ! -f "$OROOT/etc/tailscale/tailscaled.state" ] || fail 'identity must be deleted after purge'
    olog_has 'tailscale logout' || fail 'logout must be attempted'
fi

printf 'Update/rollback/cleanup/purge tests passed.\n'
