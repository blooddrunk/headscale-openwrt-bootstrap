#!/bin/sh

# Fixture tests for the multi-profile list and the tailscale-failover
# watchdog: profile-add/remove/switch-to, enable/disable-failover, watchdog
# decision cycles (failover, cooldown, failback, both-down, drifted current),
# tamper repair, the unchanged join guard, and rollback of failover state.

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
log_reset() { : > "$LOG"; }

A=https://hs.example.com
B=https://hs-b.example.com

make_fresh_root() {
    ROOT=$TMP_DIR/$1
    LOG=$TMP_DIR/$1.log
    mkdir -p "$ROOT"
    cp -a "$TEST_DIR/fixtures/openwrt/." "$ROOT/"
    rm -rf "$ROOT/etc/tailscale" "$ROOT/.ts-state" "$ROOT/.opkg-installed" \
        "$ROOT/.opkg-versions" "$ROOT/root/tailscale-bootstrap-backups" \
        "$ROOT/etc/tailscale-bootstrap" "$ROOT/tmp"
    rm -f "$ROOT/etc/init.d/tailscale-core" "$ROOT/etc/rc.d"/*
    mkdir -p "$ROOT/.opkg-installed" "$ROOT/.opkg-versions"
    : > "$ROOT/.opkg-installed/luci-app-tailscale"
    printf '1.2.6-r1\n' > "$ROOT/.opkg-versions/luci-app-tailscale"
    awk '
        /^config zone .tailscale.$/ { skipping = 1; next }
        /^config forwarding .ts_to_lan.$/ { skipping = 1; next }
        skipping && /^config / { skipping = 0 }
        !skipping { print }
    ' "$ROOT/etc/config/firewall" > "$ROOT/etc/config/firewall.tmp"
    mv "$ROOT/etc/config/firewall.tmp" "$ROOT/etc/config/firewall"
    ln -sf ../init.d/tailscale "$ROOT/etc/rc.d/S90tailscale"
    mkdir -p "$ROOT/dev/net"
    if [ "$(id -u)" = 0 ]; then
        mknod "$ROOT/dev/net/tun" c 10 200 2>/dev/null || true
    elif [ -c /dev/net/tun ]; then
        ln -sf /dev/net/tun "$ROOT/dev/net/tun"
    fi
    log_reset
}

run_ow() {
    env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" TMPDIR="$TMP_DIR" OPENWRT_SWITCH_SETTLE=0 \
        PATH="$OPENWRT_BIN:$PATH" \
        "$OPENWRT_SCRIPT" --root "$ROOT" "$@"
}

run_watchdog() {
    env FAKE_OPENWRT_ROOT="$ROOT" FAKE_LOG="$LOG" \
        TS_FAILOVER_CONFIG_FILE="$ROOT/etc/config/tailscale-bootstrap" \
        TS_FAILOVER_RUNTIME_DIR="$ROOT/var/run/tailscale-failover" \
        TS_FAILOVER_SETTLE=0 \
        PATH="$OPENWRT_BIN:$PATH" \
        sh "$ROOT/usr/sbin/tailscale-failover" --once
}

uci_admin() {
    env FAKE_OPENWRT_ROOT="$ROOT" "$OPENWRT_BIN/uci" "$@"
}

cur_url() {
    sed -n 's/.*"ControlURL":"\([^"]*\)".*/\1/p' "$ROOT/.ts-state/prefs" | sed -n '1p'
}

watchdog_cycles() {
    openwrt_wc_n=$1
    openwrt_wc_i=0
    while [ "$openwrt_wc_i" -lt "$openwrt_wc_n" ]; do
        run_watchdog >/dev/null 2>&1
        openwrt_wc_i=$((openwrt_wc_i + 1))
    done
}

[ -c /dev/net/tun ] || { printf 'SKIP: /dev/net/tun unavailable\n'; exit 0; }

new_key() {
    KEYFILE=$TMP_DIR/hs-auth-key
    printf 'hskey-auth-FIXTURE-%s\n' "$1" > "$KEYFILE"
    chmod 600 "$KEYFILE"
}

BOOTCFG=

reset_bootcfg() {
    BOOTCFG=$ROOT/etc/config/tailscale-bootstrap
}

################################################################
# A. profile-add: first network from logged-out, then a second one
################################################################

make_fresh_root owf-a
reset_bootcfg
run_ow --login-server "$A" install >/dev/null

new_key first
OUT=$(run_ow --login-server "$A" --priority 10 --auth-key-file "$KEYFILE" profile-add)
assert_contains "$OUT" 'Profile added'
[ ! -f "$KEYFILE" ] || fail 'auth key file must be removed after login'
assert_file_contains "$BOOTCFG" "config profile 'hs_example_com'"
assert_file_contains "$BOOTCFG" "option login_server '$A'"
assert_file_contains "$BOOTCFG" "option priority '10'"
assert_file_contains "$BOOTCFG" "option ts_profile 'user1'"
[ "$(cur_url)" = "$A" ] || fail "expected current $A, got $(cur_url)"
# Safe prefs converged on the new profile.
assert_file_contains "$ROOT/.ts-state/prefs" '"CorpDNS":false'

OUT=$(run_ow profile-list)
assert_contains "$OUT" 'profiles: 1'
assert_contains "$OUT" "$A [active]"

# Second network: login creates a profile, then the script must switch back.
OUT=$(printf 'hskey-auth-FIXTURE-second-stdin\n' | \
    run_ow --login-server "$B" --auth-key-stdin profile-add)
assert_contains "$OUT" 'Profile added'
assert_file_contains "$BOOTCFG" "option login_server '$B'"
assert_file_contains "$BOOTCFG" "option priority '20'"
assert_file_contains "$BOOTCFG" "option ts_profile 'user2'"
assert_contains "$OUT" "Active network after profile-add: $A"
[ "$(cur_url)" = "$A" ] || fail "adding a backup must not yank the active network: $(cur_url)"

OUT=$(run_ow profile-list)
assert_contains "$OUT" 'profiles: 2'

# Duplicate add is refused before any network action.
new_key dup
set +e
OUT=$(run_ow --login-server "$B" --auth-key-file "$KEYFILE" profile-add 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'duplicate profile-add must fail'
assert_contains "$OUT" 'already in the profile list'
[ -f "$KEYFILE" ] || fail 'unused key must be kept on refusal'
rm -f "$KEYFILE"

################################################################
# B. switch-to between listed profiles
################################################################

OUT=$(run_ow --login-server "$B" switch-to)
assert_contains "$OUT" "Switched to: $B"
[ "$(cur_url)" = "$B" ] || fail "switch-to B failed: $(cur_url)"
assert_file_contains "$ROOT/etc/tailscale-bootstrap/state.json" "\"login_server\": \"$B\""

OUT=$(run_ow --login-server "$B" switch-to)
assert_contains "$OUT" 'Already active'

set +e
OUT=$(run_ow --login-server https://not-listed.example.test switch-to 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'switch-to unlisted server must fail'
assert_contains "$OUT" 'not in the profile list'

run_ow --login-server "$A" switch-to >/dev/null
[ "$(cur_url)" = "$A" ] || fail 'switch back to A failed'

################################################################
# C. join guard unchanged: no silent switch even with profiles present
################################################################

new_key guard
set +e
OUT=$(run_ow --login-server "$B" --auth-key-file "$KEYFILE" join 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail "join must still exit 2 on ControlURL mismatch, got $CODE"
assert_contains "$OUT" 'different control server'
rm -f "$KEYFILE"

################################################################
# C2. duplicate account names: profiles must be keyed by ID
################################################################

# The real CLI prints a padded "ID Tailnet Account" table that reflows
# when a wider profile joins, and one account name can be registered on
# several servers.  profile-add must still record the real entry (not the
# re-padded header), and switch-to must land on the requested server even
# though both profiles share the account name.
make_fresh_root owf-dupname
reset_bootcfg
run_ow --login-server "$A" install >/dev/null

new_key dup-a
export FAKE_TS_LOGIN_NAME=home
run_ow --login-server "$A" --auth-key-file "$KEYFILE" profile-add >/dev/null
assert_file_contains "$BOOTCFG" "option ts_profile 'home'"
assert_file_contains "$BOOTCFG" "option ts_id '0101'"

new_key dup-b
run_ow --login-server "$B" --auth-key-file "$KEYFILE" profile-add >/dev/null
unset FAKE_TS_LOGIN_NAME
assert_file_contains "$BOOTCFG" "option login_server '$B'"
assert_file_contains "$BOOTCFG" "option ts_profile 'home'"
assert_file_contains "$BOOTCFG" "option ts_id '0102'"
assert_file_not_contains "$BOOTCFG" "ts_profile 'Account'"
assert_file_not_contains "$BOOTCFG" "ts_id 'ID'"
[ "$(cur_url)" = "$A" ] || fail "adding a same-name backup must not yank the active network: $(cur_url)"

OUT=$(run_ow --login-server "$B" switch-to)
assert_contains "$OUT" "Switched to: $B"
[ "$(cur_url)" = "$B" ] || fail "switch-to must key on the profile ID, not the shared name: $(cur_url)"

run_ow --login-server "$A" switch-to >/dev/null
[ "$(cur_url)" = "$A" ] || fail "switch back to A failed: $(cur_url)"

ROOT=$TMP_DIR/owf-a
reset_bootcfg

################################################################
# D. enable-failover: gating, deployment, idempotency
################################################################

make_fresh_root owf-enable-guard
run_ow --login-server "$A" install >/dev/null
new_key only
run_ow --login-server "$A" --auth-key-file "$KEYFILE" profile-add >/dev/null
set +e
OUT=$(run_ow enable-failover 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'enable-failover with one profile must fail'
assert_contains "$OUT" 'at least two profiles'

ROOT=$TMP_DIR/owf-a
reset_bootcfg
OUT=$(run_ow --failure-threshold 2 --recovery-threshold 2 --cooldown 1 enable-failover)
assert_contains "$OUT" 'Failover enabled'
[ -x "$ROOT/etc/init.d/tailscale-failover" ] || fail 'failover init missing'
[ -x "$ROOT/usr/sbin/tailscale-failover" ] || fail 'watchdog missing'
[ "$(stat -c '%a' "$ROOT/usr/sbin/tailscale-failover")" = 700 ] || fail 'watchdog must be mode 700'
[ -L "$ROOT/etc/rc.d/S90tailscale-failover" ] || fail 'failover service not enabled at boot'
assert_file_contains "$BOOTCFG" "option enabled '1'"
assert_file_contains "$BOOTCFG" "option failure_threshold '2'"
log_has 'init tailscale-failover enable' || fail 'service must be enabled'
log_has 'init tailscale-failover start' || fail 'service must be started'

OUT=$(run_ow status)
assert_contains "$OUT" 'failover: yes'
assert_contains "$OUT" 'OK'

# Idempotent re-enable: a verified watchdog is not redeployed.
log_reset
WD_SUM=$(cksum "$ROOT/usr/sbin/tailscale-failover")
run_ow enable-failover >/dev/null
[ "$WD_SUM" = "$(cksum "$ROOT/usr/sbin/tailscale-failover")" ] || fail 'must not redeploy a verified watchdog'

################################################################
# E. watchdog decision cycles (deployed script, --once)
################################################################

RT=$ROOT/var/run/tailscale-failover

# E1: active A down, B up -> after failure_threshold(2) cycles switch to B.
rm -rf "$RT"
log_reset
FAKE_PROBE_DOWN=hs.example.com watchdog_cycles 1
[ "$(cur_url)" = "$A" ] || fail 'must not switch before the failure threshold'
FAKE_PROBE_DOWN=hs.example.com watchdog_cycles 1
[ "$(cur_url)" = "$B" ] || fail "expected failover to B, got $(cur_url)"
assert_file_contains "$RT/status" "switched=$B"
log_has "switched to $B" || fail 'switch must be logged'
assert_file_contains "$ROOT/.ts-state/prefs" '"CorpDNS":false'

# E2: failback=0 -> with both networks healthy, the higher-priority A is
# NOT re-selected (stability first).
FAKE_PROBE_DOWN= watchdog_cycles 3
[ "$(cur_url)" = "$B" ] || fail 'failback must stay off by default'

# E3: failback=1 -> switch back to A once it has recovery_threshold oks.
uci_admin set tailscale-bootstrap.watchdog.failback=1
uci_admin commit tailscale-bootstrap
sleep 2  # deterministic: let the E1 switch clear the 1s cooldown
FAKE_PROBE_DOWN= watchdog_cycles 3
[ "$(cur_url)" = "$A" ] || fail "failback must return to A, got $(cur_url)"
uci_admin set tailscale-bootstrap.watchdog.failback=0
uci_admin commit tailscale-bootstrap

# E4: everything down -> stay put, never switch into the void.
FAKE_PROBE_DOWN="hs.example.com hs-b.example.com" watchdog_cycles 3
[ "$(cur_url)" = "$A" ] || fail 'must stay when no candidate is healthy'
assert_file_contains "$RT/status" 'no-switch'

# E5: cooldown postpones a re-switch even when thresholds are met.
rm -rf "$RT"
FAKE_PROBE_DOWN= watchdog_cycles 1   # counters: A ok1 B ok1
FAKE_PROBE_DOWN=hs.example.com watchdog_cycles 1  # A fail1; B ok2 -> not broken yet? A had ok1 -> fail1: not broken
[ "$(cur_url)" = "$A" ] || fail 'premature switch in cooldown setup'
FAKE_PROBE_DOWN=hs.example.com watchdog_cycles 1  # A fail2 -> broken; B ok -> switch to B
[ "$(cur_url)" = "$B" ] || fail 'expected switch to B in cooldown setup'
uci_admin set tailscale-bootstrap.watchdog.cooldown=300
uci_admin commit tailscale-bootstrap
FAKE_PROBE_DOWN="hs-b.example.com" watchdog_cycles 2  # B fail2 broken; A ok2 ready
[ "$(cur_url)" = "$B" ] || fail 'cooldown must postpone the switch back'
assert_file_contains "$RT/status" 'cooldown'
uci_admin set tailscale-bootstrap.watchdog.cooldown=1
uci_admin commit tailscale-bootstrap

# E6: a healthy network that drifted off the list is left alone; a broken
# one is failed over to the best listed candidate.
rm -rf "$RT"
printf '{"ControlURL":"https://manual.example.net","CorpDNS":false,"RouteAll":false,"AdvertiseRoutes":[],"ExitNodeID":""}\n' \
    > "$ROOT/.ts-state/prefs"
FAKE_PROBE_DOWN= watchdog_cycles 2
[ "$(cur_url)" = https://manual.example.net ] || fail 'healthy drifted network must be respected'
FAKE_PROBE_DOWN=manual.example.net watchdog_cycles 2
[ "$(cur_url)" = "$A" ] || fail "broken drifted network must fail over to A, got $(cur_url)"

################################################################
# F. tamper repair + plan/status blocks
################################################################

printf '# tampered by hand\n' > "$ROOT/usr/sbin/tailscale-failover"
set +e
OUT=$(run_ow --login-server "$A" plan 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail 'plan must block on a tampered watchdog'
assert_contains "$OUT" 'failover-watchdog-missing-or-unverified'

set +e
OUT=$(run_ow status 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail 'status must fail on a tampered watchdog'
assert_contains "$OUT" 'failover-watchdog-missing-or-unverified'

log_reset
run_ow --login-server "$A" enable-failover >/dev/null
assert_file_contains "$ROOT/usr/sbin/tailscale-failover" 'TS_FAILOVER_WATCHDOG_v2'
TAMPERED_BACKUP=$(grep -rl '# tampered by hand' "$ROOT"/root/tailscale-bootstrap-backups/*/source/usr/sbin/tailscale-failover 2>/dev/null | sed -n '1p')
[ -n "$TAMPERED_BACKUP" ] || fail 'tampered watchdog must be backed up before repair'
run_ow --login-server "$A" status >/dev/null

################################################################
# G. profile-remove: list-only, auto-disable, delete-identity
################################################################

# Remove the non-active network while failover is enabled: dropping below
# two profiles must auto-disable the watchdog.
OUT=$(run_ow --login-server "$B" profile-remove)
assert_contains "$OUT" 'Profile removed'
assert_file_not_contains "$BOOTCFG" "option login_server '$B'"
assert_file_contains "$BOOTCFG" "option enabled '0'"
log_has 'init tailscale-failover stop' || fail 'watchdog must be stopped when it cannot fail over'
run_ow --login-server "$A" status >/dev/null

# Remove an unknown server.
set +e
OUT=$(run_ow --login-server "$B" profile-remove 2>&1)
CODE=$?
set -e
[ "$CODE" -eq 2 ] || fail 'removing an unknown profile must exit 2'
assert_contains "$OUT" 'not in the profile list'

# delete-identity: bring B back, then remove the active A for real.
new_key third
run_ow --login-server "$B" --auth-key-file "$KEYFILE" profile-add >/dev/null
OUT=$(run_ow --login-server "$A" --delete-identity profile-remove)
assert_contains "$OUT" 'Profile removed'
assert_file_not_contains "$BOOTCFG" "option login_server '$A'"
assert_file_not_contains "$ROOT/.ts-state/profiles" "|$A"
[ "$(cur_url)" = "$B" ] || fail "after deleting A the node must land on B, got $(cur_url)"

# Removing the last remaining profile with --delete-identity is refused.
set +e
OUT=$(run_ow --login-server "$B" --delete-identity profile-remove 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'delete-identity on the last profile must fail'
assert_contains "$OUT" 'no other profile remains'

# List-only removal of the ACTIVE network warns and keeps the registration.
OUT=$(run_ow --login-server "$B" profile-remove)
assert_contains "$OUT" 'Profile removed'
[ -f "$ROOT/.ts-state/prefs" ] || fail 'list-only removal must keep the identity'

################################################################
# H. disable-failover + rollback restores the enabled snapshot
################################################################

new_key fourth
run_ow --login-server "$A" --auth-key-file "$KEYFILE" profile-add >/dev/null
# B is still the active network and not listed: profile-add adopts it
# without a new login (the key stays unused on disk).
new_key fifth
run_ow --login-server "$B" --auth-key-file "$KEYFILE" profile-add >/dev/null
[ -f "$KEYFILE" ] || fail 'adopt must not consume the auth key'
rm -f "$KEYFILE"
run_ow enable-failover >/dev/null
run_ow backup >/dev/null
run_ow disable-failover >/dev/null
assert_file_contains "$BOOTCFG" "option enabled '0'"
log_reset
run_ow rollback >/dev/null
assert_file_contains "$BOOTCFG" "option enabled '1'"
log_has 'init tailscale-failover enable' || fail 'rollback must re-enable failover'
log_has 'init tailscale-failover start' || fail 'rollback must start failover'

# Cleanup removes the whole managed surface, identities stay (the fake
# keeps them in .ts-state, mirroring /etc/tailscale/tailscaled.state).
run_ow cleanup >/dev/null
[ ! -e "$ROOT/etc/init.d/tailscale-failover" ] || fail 'cleanup must remove the failover init'
[ ! -e "$ROOT/usr/sbin/tailscale-failover" ] || fail 'cleanup must remove the watchdog'
[ ! -e "$ROOT/etc/config/tailscale-bootstrap" ] || fail 'cleanup must remove the profile list'
[ -f "$ROOT/.ts-state/prefs" ] || fail 'cleanup must keep identities'

printf 'OpenWrt profile/failover tests passed.\n'
