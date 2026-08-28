#!/bin/sh

# Milestone 2 (VPS fresh install + apply) and Milestone 3 (1Panel patch)
# fixture tests.

set -eu

TEST_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P)
PROJECT_DIR=$(CDPATH= cd "$TEST_DIR/.." 2>/dev/null && pwd -P)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headscale-bootstrap-test.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

VPS_SCRIPT=$PROJECT_DIR/headscale-vps.sh
VPS_BIN=$TEST_DIR/fixtures/bin-vps

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s\n' "$1" | grep -qF "$2" || fail "missing: $2"
}

assert_not_contains() {
    if printf '%s\n' "$1" | grep -qF "$2"; then fail "unexpected: $2"; fi
}

assert_file_contains() {
    [ -f "$1" ] || fail "file missing: $1"
    grep -qF "$2" "$1" || fail "file $1 missing: $2"
}

assert_file_not_contains() {
    [ -f "$1" ] || fail "file missing: $1"
    if grep -qF "$2" "$1"; then fail "file $1 unexpectedly contains: $2"; fi
}

run_vps() {
    env FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
        "$VPS_SCRIPT" --root "$ROOT" "$@"
}

log_has() { grep -qF "$1" "$LOG"; }
log_line_of() { grep -nF "$1" "$LOG" | head -n 1 | cut -d: -f1; }
log_reset() { : > "$LOG"; }

make_fresh_root() {
    ROOT=$TMP_DIR/$1
    LOG=$TMP_DIR/$1.log
    mkdir -p "$ROOT"
    cp -a "$TEST_DIR/fixtures/vps/." "$ROOT/"
    rm -rf "$ROOT/etc/headscale" "$ROOT/var/lib/headscale" \
    rm -rf "$ROOT/.headscale-installed" \
        "$ROOT/var/backups" "$ROOT/.systemd" "$ROOT/.headscale-state"
    log_reset
}

################################################################
# A. Fresh install on the 1Panel baseline (M2)
################################################################

make_fresh_root vps-a
SS_ENV="FAKE_SS_EMPTY=1"

OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install)
assert_contains "$OUT" 'Installed headscale 0.29.3 listening on 127.0.0.1:8080'

CFG=$ROOT/etc/headscale/config.yaml
assert_file_contains "$CFG" 'server_url: https://hs.example.com'
assert_file_contains "$CFG" 'listen_addr: 127.0.0.1:8080'
assert_file_contains "$CFG" 'metrics_listen_addr: 127.0.0.1:9090'
assert_file_contains "$CFG" 'grpc_listen_addr: 127.0.0.1:50443'
assert_file_contains "$CFG" 'grpc_allow_insecure: false'
assert_file_contains "$CFG" 'tls_cert_path: ""'
assert_file_contains "$CFG" 'tls_key_path: ""'
assert_file_contains "$CFG" '  - 127.0.0.1/32'
assert_file_contains "$CFG" '  - ::1/128'
assert_file_contains "$CFG" 'enabled: false'
# Unrelated keys survive rendering untouched.
assert_file_contains "$CFG" 'path: /var/lib/headscale/db.sqlite'
assert_file_contains "$CFG" 'private_key_path: /var/lib/headscale/noise_private.key'
assert_file_contains "$CFG" 'v6: fd7a:115c:a1e0::/48'
[ "$(grep -c '^listen_addr:' "$CFG")" = 1 ] || fail 'listen_addr rendered more than once'
[ -f "$ROOT/.systemd/headscale.enabled" ] || fail 'headscale not enabled'
[ -f "$ROOT/.systemd/headscale.active" ] || fail 'headscale not started'
[ -f "$ROOT/var/lib/headscale-bootstrap/state.json" ] || fail 'state.json missing'
assert_file_contains "$ROOT/var/lib/headscale-bootstrap/state.json" '"proxy_mode": "1panel"'
assert_file_contains "$ROOT/var/lib/headscale-bootstrap/state.json" '"domain": "hs.example.com"'

# Transaction order: download -> apt install -> configtest -> restart.
line_dl=$(log_line_of 'curl --fail --location --silent --show-error')
line_apt=$(log_line_of 'apt-get install -y')
line_ct=$(log_line_of 'configtest')
line_rs=$(log_line_of 'systemctl restart headscale')
[ -n "$line_dl" ] || fail 'download not logged'
[ -n "$line_apt" ] || fail 'apt-get not logged'
[ -n "$line_ct" ] || fail 'configtest not logged'
[ -n "$line_rs" ] || fail 'restart not logged'
[ "$line_dl" -lt "$line_apt" ] || fail 'download must precede apt-get'
[ "$line_apt" -lt "$line_ct" ] || fail 'apt-get must precede configtest'
[ "$line_ct" -lt "$line_rs" ] || fail 'configtest must precede restart'

# A2. Re-running install on an installed host fails closed.
set +e
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'second install must fail'
assert_contains "$OUT" 'already installed'

################################################################
# B. apply is a no-op on an already-converged host (idempotency)
################################################################

log_reset
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'Apply complete'
if log_has 'systemctl restart headscale'; then fail 'converged apply must not restart headscale'; fi
if log_has 'openresty -s reload'; then fail 'unchanged 1panel proxy must not be reloaded'; fi

log_reset
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'Apply complete'
if log_has 'systemctl restart headscale'; then fail 'second converged apply must not restart headscale'; fi

################################################################
# C. 1Panel patch paths (M3)
################################################################

make_fresh_root vps-c1
env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
# Strip the verified buffering directive: apply must add it back.
ROOTCONF=$ROOT/opt/1panel/www/sites/hs.example.com/proxy/root.conf
sed -i '/proxy_buffering off;/d' "$ROOTCONF"
log_reset
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'Apply complete'
assert_file_contains "$ROOTCONF" 'proxy_buffering off;'
log_has 'openresty -t' || fail 'openresty -t must run after patching'
log_has 'openresty -s reload' || fail 'openresty reload must run after -t passes'
line_t=$(log_line_of 'openresty -t')
line_r=$(log_line_of 'openresty -s reload')
[ "$line_t" -lt "$line_r" ] || fail 'openresty -t must precede reload'

# C2. openresty -t failure: restore and never reload.
make_fresh_root vps-c2
env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
ROOTCONF=$ROOT/opt/1panel/www/sites/hs.example.com/proxy/root.conf
sed -i '/proxy_buffering off;/d' "$ROOTCONF"
log_reset
set +e
OUT=$(env FAKE_SS_EMPTY=1 FAKE_FAIL_OPENRESTY_T=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'apply must fail when openresty -t fails'
assert_file_not_contains "$ROOTCONF" 'proxy_buffering off;'
if log_has 'openresty -s reload'; then fail 'must not reload after failed -t'; fi

# C3. Foreign upstream: refuse and keep the file byte-identical.
make_fresh_root vps-c3
env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
ROOTCONF=$ROOT/opt/1panel/www/sites/hs.example.com/proxy/root.conf
sed -i 's|proxy_pass http://127.0.0.1:8080;|proxy_pass http://127.0.0.1:9999;|' "$ROOTCONF"
BEFORE=$(cat "$ROOTCONF")
set +e
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'apply must refuse a foreign upstream'
assert_contains "$OUT" 'refusing to rewrite'
[ "$BEFORE" = "$(cat "$ROOTCONF")" ] || fail 'root.conf must stay unchanged on refusal'

################################################################
# D. Caddy mode (no 1Panel): managed block + validate + start
################################################################

# A PATH without the caddy binary so the script installs it via apt-get.
NO_CADDY_BIN=$TMP_DIR/bin-no-caddy
mkdir -p "$NO_CADDY_BIN"
for fake in "$VPS_BIN"/*; do
    case "$(basename "$fake")" in
        caddy|nginx) continue ;;
    esac
    ln -sf "$fake" "$NO_CADDY_BIN/$(basename "$fake")"
done

make_fresh_root vps-d
D_ENV="FAKE_SS_EMPTY=1 FAKE_NO_DOCKER=1"
env $D_ENV FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$NO_CADDY_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
log_reset
D_PATH="$NO_CADDY_BIN:$ROOT/usr/bin:$PATH"
OUT=$(env $D_ENV FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$D_PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'proxy=caddy'
CADDYFILE=$ROOT/etc/caddy/Caddyfile
assert_file_contains "$CADDYFILE" '# BEGIN headscale-bootstrap managed'
assert_file_contains "$CADDYFILE" 'hs.example.com {'
assert_file_contains "$CADDYFILE" 'reverse_proxy http://127.0.0.1:8080 {'
assert_file_contains "$CADDYFILE" '# END headscale-bootstrap managed'
log_has 'apt-get install -y caddy' || fail 'caddy package install expected'
log_has 'caddy validate --config' || fail 'caddy validate expected'
log_has 'systemctl start caddy' || fail 'caddy start expected'

log_reset
OUT=$(env $D_ENV FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$D_PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'proxy=caddy'
if log_has 'systemctl start caddy'; then fail 'converged caddy apply must not start again'; fi
if log_has 'systemctl reload caddy'; then fail 'unchanged caddy block must not reload'; fi

# D2. caddy validate failure: restore the previous Caddyfile, no start.
make_fresh_root vps-d2
printf '# foreign operator config\nimport /etc/caddy/sites/*\n' > "$ROOT/etc/caddy/Caddyfile" 2>/dev/null || {
    mkdir -p "$ROOT/etc/caddy"
    printf '# foreign operator config\nimport /etc/caddy/sites/*\n' > "$ROOT/etc/caddy/Caddyfile"
}
env $D_ENV FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
log_reset
set +e
OUT=$(env $D_ENV FAKE_FAIL_CADDY_VALIDATE=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || fail 'apply must fail when caddy validate fails'
assert_file_contains "$ROOT/etc/caddy/Caddyfile" 'foreign operator config'
assert_file_not_contains "$ROOT/etc/caddy/Caddyfile" 'reverse_proxy http://127.0.0.1:8080'
if log_has 'systemctl start caddy'; then fail 'must not start caddy after validate failure'; fi

################################################################
# E. Recovery paths: service-readable permissions, unsafe heal, seeding
################################################################

# E1. The script's global umask 077 must not leave the config 0600 root:root
#     (regression: the headscale service user got "permission denied" and
#     crash-looped on every install).
make_fresh_root vps-e1
env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
[ "$(stat -c %a "$ROOT/etc/headscale/config.yaml")" = 640 ] || fail 'config must be 0640 so the service user can read it'

# E2. A rollback that restored the packaged baseline (server_url
#     http://127.0.0.1) must not deadlock apply: the managed keys are
#     rewritten and the config converges back to https.
make_fresh_root vps-e2
env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
sed -i 's|^server_url: https://hs.example.com|server_url: http://127.0.0.1:8080|' "$ROOT/etc/headscale/config.yaml"
log_reset
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'Apply complete'
assert_file_contains "$ROOT/etc/headscale/config.yaml" 'server_url: https://hs.example.com'
[ "$(stat -c %a "$ROOT/etc/headscale/config.yaml")" = 640 ] || fail 'healed config must stay 0640'

# E3. apply re-seeds a missing config from the packaged baseline.
rm -f "$ROOT/etc/headscale/config.yaml"
cp "$TEST_DIR/fixtures/deb-payload/config.example.yaml" "$ROOT/etc/headscale/config.example.yaml"
log_reset
OUT=$(env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
    "$VPS_SCRIPT" --root "$ROOT" --domain hs.example.com --expected-public-ip 203.0.113.10 apply)
assert_contains "$OUT" 'Apply complete'
assert_file_contains "$ROOT/etc/headscale/config.yaml" 'server_url: https://hs.example.com'

################################################################
# F. Embedded DERP: enable/disable, managed region keys, and
#    preservation across apply (regression: the renderer used to
#    hard-code derp enabled to false, silently disabling a relay
#    configured manually or via enable-derp).
################################################################

make_fresh_root vps-f1
CFG=$ROOT/etc/headscale/config.yaml
f_run() {
    env FAKE_SS_EMPTY=1 FAKE_VPS_ROOT="$ROOT" FAKE_LOG="$LOG" PATH="$VPS_BIN:$PATH" \
        "$VPS_SCRIPT" --root "$ROOT" "$@"
}
f_run --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
log_reset

# F1. enable-derp with derived identity: first domain label minus "hs-",
#     public IPv4 from --expected-public-ip, doc IPv6 neutralized, and the
#     restart verified against the fixture STUN listener + /derp/probe.
OUT=$(f_run --domain hs.example.com --expected-public-ip 203.0.113.10 enable-derp)
assert_contains "$OUT" 'Embedded DERP enabled: region=hs'
assert_contains "$OUT" 'udp/3478'
assert_file_contains "$CFG" 'enabled: true'
assert_file_contains "$CFG" 'region_code: "hs"'
assert_file_contains "$CFG" 'region_name: "Hs VPS"'
assert_file_contains "$CFG" 'ipv4: 203.0.113.10'
assert_file_contains "$CFG" '# ipv6: 2001:db8::1'
log_has 'systemctl restart headscale' || fail 'enable-derp must restart after a config change'

# F2. explicit region naming converges and is then idempotent.
f_run --derp-region-code custom --derp-region-name 'Custom Region' enable-derp >/dev/null
assert_file_contains "$CFG" 'region_code: "custom"'
assert_file_contains "$CFG" 'region_name: "Custom Region"'
log_reset
f_run --derp-region-code custom --derp-region-name 'Custom Region' enable-derp >/dev/null
if log_has 'systemctl restart headscale'; then fail 'enable-derp restarted with nothing to change'; fi

# F3. apply without DERP flags preserves the enabled state and the chosen
#     region identity (no silent reset, no gratuitous restart).
log_reset
f_run --domain hs.example.com --expected-public-ip 203.0.113.10 apply >/dev/null
assert_file_contains "$CFG" 'enabled: true'
assert_file_contains "$CFG" 'region_code: "custom"'
if log_has 'systemctl restart headscale'; then fail 'apply must not restart when the config already matches'; fi
OUT=$(f_run plan)
assert_contains "$OUT" 'requested version/embedded DERP: none/true (effective)'
OUT=$(f_run status)
assert_contains "$OUT" 'embedded DERP=true, region=custom'
OUT=$(f_run --json status)
assert_contains "$OUT" '"embedded_derp_region":"custom"'

# F4. --enable-embedded-derp true drives the same convergence via apply.
make_fresh_root vps-f2
CFG=$ROOT/etc/headscale/config.yaml
f_run --domain hs.example.com --expected-public-ip 203.0.113.10 install >/dev/null
f_run --domain hs.example.com --expected-public-ip 203.0.113.10 --enable-embedded-derp true apply >/dev/null
assert_file_contains "$CFG" 'enabled: true'
assert_file_contains "$CFG" 'ipv4: 203.0.113.10'

# F5. disable-derp flips the switch and keeps the region keys for a cheap
#     re-enable; the STUN listener goes away with the config.
f_run disable-derp >/dev/null
assert_file_contains "$CFG" 'enabled: false'
assert_file_contains "$CFG" 'region_code: "hs"'
[ ! -f "$ROOT/.headscale-state/derp-enabled" ] || fail 'fixture STUN listener must be gone after disable-derp'
OUT=$(f_run status)
assert_contains "$OUT" 'embedded DERP=false'

printf 'VPS install/apply/1panel tests passed.\n'
