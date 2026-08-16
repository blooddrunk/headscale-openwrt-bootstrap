#!/bin/sh

# TS_FAILOVER_WATCHDOG_v3
#
# Deployed by headscale-openwrt-bootstrap as /usr/sbin/tailscale-failover.
# The bootstrap script fingerprint-checks this file before every start;
# local edits make it "unverified" and it gets restored from the template.
#
# Reads the committed UCI file (default /etc/config/tailscale-bootstrap) and
# switches between already-registered tailscale profiles when the active
# network breaks:
#   - a profile becomes a failover candidate only after recovery_threshold
#     consecutive healthy probes;
#   - the active network is declared broken after failure_threshold
#     consecutive failed probes (HTTPS control-plane failure, or a reachable
#     control server with BackendState != Running, e.g. a revoked node);
#   - failback to a strictly higher-priority profile happens only when
#     failback=1;
#   - no two switches happen within `cooldown` seconds;
#   - an active network that drifted off the profile list is only abandoned
#     when it is actually broken - a healthy manual choice is never fought;
#   - it never logs in, never uses auth keys, never touches netifd, fw4 or
#     any config outside its runtime directory.
#
# Runtime state lives in $TS_FAILOVER_RUNTIME_DIR (default
# /var/run/tailscale-failover, tmpfs - counters reset on boot, which is fine
# for short thresholds).
#
# Diagnostic mode: `tailscale-failover --once` runs a single decision cycle.

CONFIG_FILE=${TS_FAILOVER_CONFIG_FILE:-/etc/config/tailscale-bootstrap}
RUNTIME_DIR=${TS_FAILOVER_RUNTIME_DIR:-/var/run/tailscale-failover}
SETTLE=${TS_FAILOVER_SETTLE:-10}
FAILOVER_INTERVAL=60

failover_log() {
    printf '[FAILOVER] %s\n' "$*" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t tailscale-failover "$*" 2>/dev/null || true
    fi
}

failover_die() {
    failover_log "FATAL: $*"
    exit 1
}

# --- config ----------------------------------------------------------------
# One "section|url|priority|ts_profile|ts_id" line per profile (sorted by
# priority, lower wins, then section name) plus "setting:key=value" lines.

failover_read_config() {
    [ -r "$CONFIG_FILE" ] || return 0
    awk '
        function unq(s) { gsub(/^[\047"]|[\047"]$/, "", s); return s }
        function flush() {
            if (type == "profile" && url != "" && prof != "") {
                printf "%s|%s|%d|%s|%s\n", name, url, prio + 0, prof, pid
            }
        }
        $1 == "config" {
            flush()
            type = unq($2); name = unq($3)
            url = ""; prio = ""; prof = ""; pid = ""
            next
        }
        type == "profile" && $1 == "option" {
            k = unq($2)
            if (k == "login_server") url = unq($3)
            else if (k == "priority") prio = unq($3)
            else if (k == "ts_profile") prof = unq($3)
            else if (k == "ts_id") pid = unq($3)
            next
        }
        type == "failover" && $1 == "option" {
            print "setting:" unq($2) "=" unq($3)
            next
        }
        type == "site_to_site" && $1 == "option" && unq($2) == "enabled" {
            print "setting:s2s=" unq($3)
            next
        }
        END { flush() }
    ' "$CONFIG_FILE" | sort -t'|' -k3,3n -k1,1
}

failover_setting() {
    printf '%s\n' "$FAILOVER_SETTINGS" | sed -n "s/^setting:$1=//p" | sed -n '1p'
}

failover_setting_int() {
    failover_si_value=$(failover_setting "$1")
    case "$failover_si_value" in
        ''|*[!0-9]*) printf '%s\n' "$2" ;;
        *) printf '%s\n' "$failover_si_value" ;;
    esac
}

# --- runtime counters ------------------------------------------------------

failover_counter() {
    failover_counter_file=$RUNTIME_DIR/$1.cnt
    [ -r "$failover_counter_file" ] || return 1
    cat "$failover_counter_file" 2>/dev/null
}

failover_set_counter() {
    printf '%s %s\n' "$2" "$3" > "$RUNTIME_DIR/$1.cnt" || return 1
}

failover_counter_state() {
    [ -r "$RUNTIME_DIR/$1.cnt" ] || return 1
    failover_counter "$1" | awk '{print $1}'
}

failover_counter_value() {
    # Always prints a number: a missing counter file means zero.
    [ -r "$RUNTIME_DIR/$1.cnt" ] || { printf '0\n'; return 0; }
    cat "$RUNTIME_DIR/$1.cnt" 2>/dev/null | awk '{print $2 + 0; exit}'
}

failover_badswitch() {
    # Always prints a number: a missing file means zero failed switches.
    [ -r "$RUNTIME_DIR/$1.badswitch" ] || { printf '0\n'; return 0; }
    cat "$RUNTIME_DIR/$1.badswitch" 2>/dev/null | awk '{print $1 + 0; exit}'
}

failover_set_badswitch() {
    printf '%s\n' "$2" > "$RUNTIME_DIR/$1.badswitch" || return 1
}

# --- probes -----------------------------------------------------------------

failover_probe() {
    failover_probe_url=$1
    failover_probe_timeout=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m "$failover_probe_timeout" "$failover_probe_url" >/dev/null 2>&1
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T "$failover_probe_timeout" -O /dev/null "$failover_probe_url" >/dev/null 2>&1
        return
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O /dev/null "$failover_probe_url" >/dev/null 2>&1
        return
    fi
    return 1
}

failover_control_url() {
    failover_cu=$(tailscale debug prefs 2>/dev/null | sed -n 's/.*"ControlURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
    case "$failover_cu" in
        */) failover_cu=${failover_cu%/} ;;
    esac
    printf '%s\n' "$failover_cu"
}

failover_backend_state() {
    tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p'
}

# --- switching --------------------------------------------------------------

failover_switch() {
    # failover_switch SECTION TS_PROFILE TS_ID URL
    failover_sw_section=$1
    failover_sw_profile=$2
    failover_sw_id=$3
    failover_sw_url=$4

    failover_sw_ok=0
    # The real CLI has no --id flag: the positional argument matches ID,
    # then tailnet, then account name, first match wins.  One account name
    # can be registered on several servers, and a name match may land on
    # the already-current profile (a successful no-op), so prefer the
    # unambiguous ID and keep the name only as a fallback.
    if [ -n "$failover_sw_id" ] && tailscale switch "$failover_sw_id" >/dev/null 2>&1; then
        failover_sw_ok=1
    elif [ -n "$failover_sw_profile" ] && tailscale switch "$failover_sw_profile" >/dev/null 2>&1; then
        failover_sw_ok=1
    fi
    if [ "$failover_sw_ok" != 1 ]; then
        failover_sw_bad=$(( $(failover_badswitch "$failover_sw_section") + 1 ))
        failover_set_badswitch "$failover_sw_section" "$failover_sw_bad"
        failover_log "switch to $failover_sw_url failed (profile '$failover_sw_profile' attempt $failover_sw_bad)"
        return 1
    fi

    [ "$SETTLE" -gt 0 ] && sleep "$SETTLE"

    failover_sw_now=$(failover_control_url)
    if [ "$failover_sw_now" != "$failover_sw_url" ]; then
        failover_sw_bad=$(( $(failover_badswitch "$failover_sw_section") + 1 ))
        failover_set_badswitch "$failover_sw_section" "$failover_sw_bad"
        failover_log "switch verification failed: ControlURL=$failover_sw_now expected=$failover_sw_url"
        return 1
    fi

    # Per-profile prefs: keep the bootstrap safety posture on every network.
    # site_to_site mode (enable-site-to-site) intentionally keeps
    # accept-routes on so remote subnets survive a failover switch too.
    if [ "$(failover_setting s2s)" = 1 ]; then
        tailscale set --accept-dns=false --accept-routes=true >/dev/null 2>&1 || \
            failover_log 'tailscale set accept-dns/accept-routes failed on the new profile'
    else
        tailscale set --accept-dns=false --accept-routes=false >/dev/null 2>&1 || \
            failover_log 'tailscale set accept-dns/accept-routes failed on the new profile'
    fi

    failover_set_badswitch "$failover_sw_section" 0
    printf '%s\n' "$(date +%s 2>/dev/null || printf 0)" > "$RUNTIME_DIR/last_switch"
    failover_log "switched to $failover_sw_url (profile '$failover_sw_profile')"
    return 0
}

# --- readiness --------------------------------------------------------------

failover_ready() {
    failover_r_section=$1
    [ "$(failover_counter_state "$failover_r_section")" = ok ] || return 1
    [ "$(failover_counter_value "$failover_r_section")" -ge "$FAILOVER_RECOVERY_THRESHOLD" ] || return 1
    [ "$(failover_badswitch "$failover_r_section")" -lt 3 ] || return 1
    return 0
}

failover_best_ready() {
    # prints "section|url|profile|id" of the best ready candidate, excluding $1
    failover_br_exclude=$1
    while IFS='|' read -r failover_section failover_url failover_prio failover_profile failover_id; do
        [ -n "$failover_section" ] || continue
        [ "$failover_section" = "$failover_br_exclude" ] && continue
        if failover_ready "$failover_section"; then
            printf '%s|%s|%s|%s\n' "$failover_section" "$failover_url" "$failover_profile" "$failover_id"
            return 0
        fi
    done <<EOF
$FAILOVER_PROFILES
EOF
    return 1
}

# --- one decision cycle -------------------------------------------------------

failover_cycle() {
    mkdir -p "$RUNTIME_DIR" || failover_die "cannot create $RUNTIME_DIR"

    FAILOVER_PROFILES=$(failover_read_config | grep -v '^setting:')
    FAILOVER_SETTINGS=$(failover_read_config | sed -n 's/^setting:/setting:/p')

    if [ "$(failover_setting enabled)" != 1 ]; then
        printf 'disabled\n' > "$RUNTIME_DIR/status"
        return 0
    fi

    FAILOVER_INTERVAL=$(failover_setting_int check_interval 60)
    [ "$FAILOVER_INTERVAL" -ge 10 ] || FAILOVER_INTERVAL=10
    FAILOVER_FAILURE_THRESHOLD=$(failover_setting_int failure_threshold 3)
    FAILOVER_RECOVERY_THRESHOLD=$(failover_setting_int recovery_threshold 3)
    FAILOVER_COOLDOWN=$(failover_setting_int cooldown 300)
    FAILOVER_PROBE_TIMEOUT=$(failover_setting_int probe_timeout 5)
    [ "$FAILOVER_PROBE_TIMEOUT" -ge 1 ] || FAILOVER_PROBE_TIMEOUT=5
    FAILOVER_FAILBACK=$(failover_setting failback)
    FAILOVER_HEALTH_PATH=$(failover_setting health_path)
    case "$FAILOVER_HEALTH_PATH" in
        /*) ;;
        *) FAILOVER_HEALTH_PATH=/health ;;
    esac

    command -v tailscale >/dev/null 2>&1 || { failover_log 'tailscale CLI missing; sleeping'; return 0; }

    [ -n "$FAILOVER_PROFILES" ] || { printf 'no profiles\n' > "$RUNTIME_DIR/status"; return 0; }

    FAILOVER_NOW=$(date +%s 2>/dev/null || printf 0)
    FAILOVER_CURRENT=$(failover_control_url)
    [ -n "$FAILOVER_CURRENT" ] || { failover_log 'cannot read current ControlURL; sleeping'; return 0; }
    FAILOVER_BACKEND=$(failover_backend_state)

    FAILOVER_CURRENT_SECTION=
    FAILOVER_CURRENT_PRIO=999999
    while IFS='|' read -r failover_section failover_url failover_prio failover_profile failover_id; do
        [ -n "$failover_section" ] || continue
        if [ "$failover_url" = "$FAILOVER_CURRENT" ]; then
            FAILOVER_CURRENT_SECTION=$failover_section
            FAILOVER_CURRENT_PRIO=$failover_prio
        fi
    done <<EOF
$FAILOVER_PROFILES
EOF

    # Probe every listed profile; counters are persisted to files so the
    # pipeline subshell stays side-effect-free apart from those files.
    while IFS='|' read -r failover_section failover_url failover_prio failover_profile failover_id; do
        [ -n "$failover_section" ] || continue
        if failover_probe "$failover_url$FAILOVER_HEALTH_PATH" "$FAILOVER_PROBE_TIMEOUT"; then
            failover_result=ok
        else
            failover_result=fail
        fi
        if [ "$failover_url" = "$FAILOVER_CURRENT" ] && [ "$failover_result" = ok ] && [ "$FAILOVER_BACKEND" != Running ]; then
            # Control plane reachable but the client is not usable on it
            # (expired/revoked node): treat the network as broken.
            failover_result=fail
        fi
        failover_counter_state=$(failover_counter_state "$failover_section")
        failover_counter_value=$(failover_counter_value "$failover_section")
        if [ "$failover_counter_state" = "$failover_result" ]; then
            failover_counter_value=$((failover_counter_value + 1))
            [ "$failover_counter_value" -gt 1000 ] && failover_counter_value=1000
        else
            failover_counter_value=1
        fi
        failover_set_counter "$failover_section" "$failover_result" "$failover_counter_value"
        printf '%s\n' "$FAILOVER_NOW" > "$RUNTIME_DIR/$failover_section.lastcheck" 2>/dev/null || true
    done <<EOF
$FAILOVER_PROFILES
EOF

    failover_decide
    return 0
}

failover_decide() {
    failover_target=$(failover_best_ready "$FAILOVER_CURRENT_SECTION")

    failover_broken=0
    if [ -n "$FAILOVER_CURRENT_SECTION" ]; then
        if [ "$(failover_counter_state "$FAILOVER_CURRENT_SECTION")" = fail ] && \
            [ "$(failover_counter_value "$FAILOVER_CURRENT_SECTION")" -ge "$FAILOVER_FAILURE_THRESHOLD" ]; then
            failover_broken=1
        fi
    else
        # Active network drifted off the profile list (manual switch or a
        # removed profile): only abandon it when it is actually broken.
        if ! failover_probe "$FAILOVER_CURRENT$FAILOVER_HEALTH_PATH" "$FAILOVER_PROBE_TIMEOUT"; then
            failover_broken=1
        elif [ "$FAILOVER_BACKEND" != Running ]; then
            failover_broken=1
        fi
    fi

    if [ "$failover_broken" = 1 ]; then
        :
    elif [ "$FAILOVER_FAILBACK" = 1 ] && [ -n "$failover_target" ]; then
        failover_target_prio=$(printf '%s\n' "$FAILOVER_PROFILES" | \
            awk -F'|' -v s="$(printf '%s\n' "$failover_target" | cut -d'|' -f1)" '$1 == s {print $3 + 0; exit}')
        # Only a strictly higher priority wins; otherwise stability first.
        if [ -z "$FAILOVER_CURRENT_SECTION" ] || [ "$failover_target_prio" -ge "$FAILOVER_CURRENT_PRIO" ]; then
            failover_target=
        fi
    else
        failover_target=
    fi

    if [ -z "$failover_target" ]; then
        printf 'no-switch current=%s\n' "$FAILOVER_CURRENT" > "$RUNTIME_DIR/status"
        return 0
    fi

    failover_last_switch=0
    [ -r "$RUNTIME_DIR/last_switch" ] && failover_last_switch=$(awk '{print $1 + 0}' "$RUNTIME_DIR/last_switch" 2>/dev/null)
    if [ $((FAILOVER_NOW - failover_last_switch)) -lt "$FAILOVER_COOLDOWN" ]; then
        failover_log "switch to $(printf '%s\n' "$failover_target" | cut -d'|' -f2) postponed: cooldown active"
        printf 'cooldown current=%s\n' "$FAILOVER_CURRENT" > "$RUNTIME_DIR/status"
        return 0
    fi

    failover_switch \
        "$(printf '%s\n' "$failover_target" | cut -d'|' -f1)" \
        "$(printf '%s\n' "$failover_target" | cut -d'|' -f3)" \
        "$(printf '%s\n' "$failover_target" | cut -d'|' -f4)" \
        "$(printf '%s\n' "$failover_target" | cut -d'|' -f2)" || true
    printf 'switched=%s\n' "$(printf '%s\n' "$failover_target" | cut -d'|' -f2)" > "$RUNTIME_DIR/status"
    return 0
}

# --- main ---------------------------------------------------------------------

case "${1:-}" in
    --once) failover_cycle; exit 0 ;;
    '') ;;
    *) printf 'usage: tailscale-failover [--once]\n' >&2; exit 2 ;;
esac

failover_log "watchdog starting (config=$CONFIG_FILE runtime=$RUNTIME_DIR)"
while :; do
    failover_cycle
    sleep "$FAILOVER_INTERVAL"
done
