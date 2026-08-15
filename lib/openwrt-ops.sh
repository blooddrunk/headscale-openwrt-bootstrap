#!/bin/sh

# OpenWrt mutating operations (PLAN Milestones 4, 5 and 6).  Ownership rules
# that keep netifd, fw4, tailscaled and the LuCI helper from fighting:
#   - netifd never manages tailscale0 (no network.tailscale, no network reload);
#   - the dangerous stock /etc/init.d/tailscale is only ever disabled, never
#     stopped/reloaded/restarted (PLAN 2.2.12, 18.2);
#   - firewall writes go: pending UCI -> fw4 check -> commit -> firewall reload;
#   - the daemon runs through tailscale-core only; identity lives in
#     /etc/tailscale/tailscaled.state and is never printed.

openwrt_require_root_real() {
    if [ "$BOOTSTRAP_ROOT" = / ] && [ "$(id -u 2>/dev/null || printf 1)" != 0 ]; then
        die "$OPENWRT_COMMAND on the real router requires root"
    fi
}

openwrt_refresh() {
    openwrt_collect_facts
    openwrt_effective_values
}

openwrt_conflict_or_die() {
    openwrt_refresh
    openwrt_client_version_gate
    openwrt_compute_conflicts mutate
    if [ "$openwrt_plan_blocked" -eq 1 ]; then
        log_error "blocked preconditions: ${openwrt_block_reasons# }"
        exit 2
    fi
}

openwrt_client_version_gate() {
    # PLAN 17: stop when the client is older than the server's minimum.  The
    # threshold is passed in (--min-client-version) so it tracks the actual
    # Headscale release instead of being hardcoded.
    [ -n "$OPENWRT_MIN_CLIENT_VERSION" ] || return 0
    openwrt_cv_current=$(version_extract_semver "$OPENWRT_TAILSCALE_VERSION")
    [ -n "$openwrt_cv_current" ] || die "cannot determine the tailscale client version for the --min-client-version check"
    openwrt_cv_min=$(version_extract_semver "$OPENWRT_MIN_CLIENT_VERSION")
    [ -n "$openwrt_cv_min" ] || die "invalid --min-client-version: $OPENWRT_MIN_CLIENT_VERSION"
    if [ "$(version_cmp "$openwrt_cv_current" "$openwrt_cv_min")" = -1 ]; then
        die "tailscale client $openwrt_cv_current is older than the required minimum $openwrt_cv_min (from the Headscale server); upgrade the package first"
    fi
    log_check "client version gate passed: $openwrt_cv_current >= $openwrt_cv_min"
    return 0
}

openwrt_init_action() {
    # openwrt_init_action SERVICE ACTION...
    # Real root executes /etc/init.d/SERVICE ACTION.  Fixture roots never
    # execute target scripts; the intent is recorded and enable/disable are
    # emulated through rc.d links so enable-state checks stay meaningful.
    openwrt_init_service=$1
    shift
    openwrt_init_script=$(openwrt_target_path "/etc/init.d/$openwrt_init_service")
    if [ "$BOOTSTRAP_ROOT" = / ]; then
        [ -x "$openwrt_init_script" ] || {
            log_error "init script missing or not executable: $openwrt_init_script"
            return 1
        }
        "$openwrt_init_script" "$@"
        return
    fi
    case "$1" in
        enable)
            mkdir -p "$(openwrt_target_path /etc/rc.d)"
            ln -snf "../init.d/$openwrt_init_service" "$(openwrt_target_path "/etc/rc.d/S90$openwrt_init_service")"
            ;;
        disable)
            rm -f "$(openwrt_target_path "/etc/rc.d/S90$openwrt_init_service")"
            ;;
    esac
    if [ -n "${FAKE_LOG:-}" ]; then
        printf 'init %s %s\n' "$openwrt_init_service" "$*" >> "$FAKE_LOG"
    fi
    log_change "init $openwrt_init_service $* (recorded in fixture namespace)"
    return 0
}

# --- UCI transaction helpers (PLAN 2.2.8/9, 23, 25) ----------------------

openwrt_uci_ensure_section() {
    # openwrt_uci_ensure_section PATH TYPE; returns 0 when staged, 1 no-op.
    if openwrt_current=$(uci -q get "$1" 2>/dev/null); then
        [ "$openwrt_current" = "$2" ] && return 1
        die "UCI section $1 exists as type '$openwrt_current' (expected '$2'); refusing to overwrite"
    fi
    uci set "$1=$2" || die "uci set $1 failed"
    return 0
}

openwrt_uci_ensure_option() {
    # openwrt_uci_ensure_option PATH VALUE; returns 0 when staged, 1 no-op.
    openwrt_current=$(uci -q get "$1" 2>/dev/null)
    [ "$openwrt_current" = "$2" ] && return 1
    uci set "$1=$2" || die "uci set $1 failed"
    return 0
}

openwrt_uci_ensure_list_item() {
    # openwrt_uci_ensure_list_item PATH ITEM; returns 0 when staged, 1 no-op.
    openwrt_current=$(uci -q get "$1" 2>/dev/null)
    case " ${openwrt_current:-} " in
        *" $2 "*) return 1 ;;
    esac
    uci add_list "$1=$2" || die "uci add_list $1 failed"
    return 0
}

openwrt_uci_delete_if_exists() {
    # returns 0 when staged, 1 no-op.
    uci -q get "$1" >/dev/null 2>&1 || return 1
    uci delete "$1" || die "uci delete $1 failed"
    return 0
}

openwrt_firewall_commit_or_revert() {
    # fw4 check BEFORE commit; reload firewall only; network is never reloaded.
    if [ -z "$(uci changes firewall 2>/dev/null)" ]; then
        log_info 'no pending firewall changes; nothing to commit'
        return 0
    fi
    if ! fw4 check >/dev/null 2>&1; then
        uci revert firewall
        die 'fw4 check failed; uncommitted firewall changes were reverted (nothing was committed or reloaded)'
    fi
    uci commit firewall || die 'uci commit firewall failed'
    openwrt_init_action firewall reload || die '/etc/init.d/firewall reload failed'
    log_change 'fw4 check passed; firewall committed and firewall reloaded'
    return 0
}

openwrt_firewall_ensure_zone() {
    # First-stage zone bound directly to the tailscale0 device (PLAN 23).
    openwrt_fwz_changed=0
    openwrt_uci_ensure_section firewall.tailscale zone && openwrt_fwz_changed=1
    openwrt_uci_ensure_option firewall.tailscale.name tailscale && openwrt_fwz_changed=1
    openwrt_uci_ensure_list_item firewall.tailscale.device tailscale0 && openwrt_fwz_changed=1
    openwrt_uci_ensure_option firewall.tailscale.input ACCEPT && openwrt_fwz_changed=1
    openwrt_uci_ensure_option firewall.tailscale.output ACCEPT && openwrt_fwz_changed=1
    openwrt_uci_ensure_option firewall.tailscale.forward REJECT && openwrt_fwz_changed=1
    return 0
}

openwrt_firewall_ensure_forwarding() {
    openwrt_fwf_changed=0
    openwrt_uci_ensure_section firewall.ts_to_lan forwarding && openwrt_fwf_changed=1
    openwrt_uci_ensure_option firewall.ts_to_lan.src tailscale && openwrt_fwf_changed=1
    openwrt_uci_ensure_option firewall.ts_to_lan.dest lan && openwrt_fwf_changed=1
    openwrt_uci_ensure_option firewall.ts_to_lan.family ipv4 && openwrt_fwf_changed=1
    return 0
}

openwrt_firewall_ensure_wan_udp_rule() {
    # Narrow, reversible WAN input rule (PLAN 27): UDP only, the port
    # tailscaled actually listens on, no port forwarding.
    openwrt_wur_changed=0
    openwrt_uci_ensure_section firewall.ts_wan_udp rule && openwrt_wur_changed=1
    openwrt_uci_ensure_option firewall.ts_wan_udp.name ts-wan-udp && openwrt_wur_changed=1
    openwrt_uci_ensure_option firewall.ts_wan_udp.src wan && openwrt_wur_changed=1
    openwrt_uci_ensure_option firewall.ts_wan_udp.proto udp && openwrt_wur_changed=1
    openwrt_uci_ensure_option firewall.ts_wan_udp.dest_port "$OPENWRT_TS_PORT" && openwrt_wur_changed=1
    openwrt_uci_ensure_option firewall.ts_wan_udp.family ipv4 && openwrt_wur_changed=1
    openwrt_uci_ensure_option firewall.ts_wan_udp.target ACCEPT && openwrt_wur_changed=1
    return 0
}

# --- core service / daemon ------------------------------------------------

openwrt_ensure_core() {
    if [ "$OPENWRT_TAILSCALE_PACKAGE" != installed ]; then
        [ "$OPENWRT_PACKAGE_MANAGER" != none ] || die 'no supported package manager (opkg/apk) found'
        case "$OPENWRT_PACKAGE_MANAGER" in
            opkg) opkg update || die 'opkg update failed'; opkg install tailscale || die 'opkg install tailscale failed' ;;
            apk) apk add tailscale || die 'apk add tailscale failed' ;;
        esac
        openwrt_refresh
        [ "$OPENWRT_TAILSCALE_PACKAGE" = installed ] || die 'tailscale package still not installed'
        log_change 'installed the tailscale package'
    fi

    if [ ! -f "$OPENWRT_INIT_CORE" ] || [ "$(openwrt_core_fingerprint "$OPENWRT_INIT_CORE")" != verified ]; then
        if [ -f "$OPENWRT_INIT_CORE" ]; then
            OPENWRT_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
            OPENWRT_BACKUP_ROOT=$(backup_allocate_directory "$(bootstrap_root_path "$OPENWRT_BACKUP_DIR")" "$OPENWRT_BACKUP_TIMESTAMP") || die 'cannot allocate backup directory'
            chmod 700 "$OPENWRT_BACKUP_ROOT" 2>/dev/null || true
            backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"
            backup_copy_path "$OPENWRT_INIT_CORE" "$OPENWRT_BACKUP_ROOT/source/etc/init.d/tailscale-core" || die 'failed to back up existing tailscale-core'
            backup_finish "$OPENWRT_BACKUP_ROOT" "$OPENWRT_PROGRAM" "$BOOTSTRAP_ROOT" "$OPENWRT_BACKUP_TIMESTAMP" || die 'failed to finalize backup'
            log_change "backed up existing tailscale-core to $OPENWRT_BACKUP_ROOT"
        fi
        mkdir -p "$(dirname "$OPENWRT_INIT_CORE")"
        cat "$OPENWRT_SCRIPT_DIR/templates/tailscale-core.init" > "$OPENWRT_INIT_CORE" || die 'failed to write tailscale-core'
        chmod 755 "$OPENWRT_INIT_CORE"
        log_change 'installed tailscale-core from the verified template'
    else
        log_info 'tailscale-core present and fingerprint verified'
    fi

    [ "$(openwrt_core_fingerprint "$OPENWRT_INIT_CORE")" = verified ] || {
        die 'tailscale-core fingerprint mismatch after write; refusing to manage this daemon'
    }

    if [ "$OPENWRT_CORE_SERVICE_ENABLED" != yes ]; then
        openwrt_init_action tailscale-core enable || die 'failed to enable tailscale-core'
        log_change 'enabled tailscale-core at boot'
    fi

    # Stock service handling: disable only, and never stop it (PLAN 18.2).
    if [ "$OPENWRT_UNSAFE_LUCI_HELPER" = yes ]; then
        if [ "$OPENWRT_STOCK_SERVICE_ENABLED" = yes ]; then
            openwrt_init_action tailscale disable || die 'failed to disable the unsafe stock tailscale service'
            log_change 'disabled unsafe stock /etc/init.d/tailscale (disable only; stop was NOT called)'
        fi
        log_warn 'luci-app-tailscale UI start/stop/restart buttons must not be used; this deployment is managed by tailscale-core'
    elif [ "$OPENWRT_EFFECTIVE_SERVICE_MODE" = core ] && [ "$OPENWRT_STOCK_INIT_PRESENT" = yes ] && [ "$OPENWRT_STOCK_SERVICE_ENABLED" = yes ]; then
        openwrt_init_action tailscale disable || die 'failed to disable the stock tailscale service'
        log_change 'disabled stock /etc/init.d/tailscale to avoid a second daemon at boot (disable only)'
    fi
    return 0
}

openwrt_ensure_daemon_running() {
    if [ "$BOOTSTRAP_ROOT" = / ]; then
        if pgrep tailscaled >/dev/null 2>&1; then
            openwrt_state_file=$(state_path_openwrt)
            if [ -r "$openwrt_state_file" ] && [ "$(state_read_field "$openwrt_state_file" service_mode)" = core ]; then
                log_info 'tailscaled already running under tailscale-core management'
                return 0
            fi
            die 'tailscaled is already running but not recorded as managed by tailscale-core; stop it manually or reboot (this script never calls the third-party init)'
        fi
        openwrt_init_action tailscale-core start || die 'failed to start tailscale-core'
        log_change 'started tailscale-core'
    else
        openwrt_init_action tailscale-core start
    fi
    return 0
}

openwrt_write_state() {
    state_write "$(state_path_openwrt)" \
        service_mode "$OPENWRT_EFFECTIVE_SERVICE_MODE" \
        login_server "$OPENWRT_EFFECTIVE_LOGIN_SERVER" \
        subnets "${OPENWRT_CURRENT_ADVERTISE_ROUTES:-none}" \
        firewall_zone tailscale || die 'failed to write state.json'
    log_change "state.json updated: $(state_path_openwrt)"
}

# --- install / apply / join ----------------------------------------------

openwrt_install() {
    openwrt_require_root_real
    openwrt_conflict_or_die
    openwrt_ensure_core
    openwrt_ensure_daemon_running

    # Daemon start must not leave network/firewall UCI dirty (PLAN 20).
    if [ "$(uci changes network 2>/dev/null | wc -l)" != 0 ] || [ "$(uci changes firewall 2>/dev/null | wc -l)" != 0 ]; then
        die 'pending network/firewall UCI changes after daemon start; investigate before continuing'
    fi
    log_check 'daemon start left network/firewall UCI clean'
    openwrt_write_state
    printf 'Install complete: tailscale package + tailscale-core enabled and started (logged out).\n'
    printf 'Next: %s join --login-server %s --auth-key-file /tmp/hs-auth-key\n' "$OPENWRT_PROGRAM" "$OPENWRT_EFFECTIVE_LOGIN_SERVER"
}

openwrt_converge_prefs() {
    # Idempotent prefs via `tailscale set` only (PLAN 22); never advertise here.
    [ "$OPENWRT_PREFS_READABLE" = yes ] || return 0
    openwrt_cp_changed=0
    if [ "$OPENWRT_CURRENT_ACCEPT_DNS" != "$OPENWRT_ACCEPT_DNS" ]; then
        tailscale set --accept-dns="$OPENWRT_ACCEPT_DNS" || die 'tailscale set --accept-dns failed'
        openwrt_cp_changed=1
        log_change "accept-dns converged to $OPENWRT_ACCEPT_DNS"
    fi
    if [ "$OPENWRT_CURRENT_ACCEPT_ROUTES" != "$OPENWRT_ACCEPT_ROUTES" ]; then
        tailscale set --accept-routes="$OPENWRT_ACCEPT_ROUTES" || die 'tailscale set --accept-routes failed'
        openwrt_cp_changed=1
        log_change "accept-routes converged to $OPENWRT_ACCEPT_ROUTES"
    fi
    return 0
}

openwrt_apply() {
    openwrt_require_root_real
    openwrt_conflict_or_die
    openwrt_ensure_core
    openwrt_ensure_daemon_running

    openwrt_firewall_ensure_zone
    openwrt_firewall_commit_or_revert

    openwrt_refresh
    if [ "$OPENWRT_PREFS_READABLE" = yes ]; then
        openwrt_converge_prefs
    else
        log_info 'node is not registered yet; run join with a fresh auth key'
    fi

    if [ "$OPENWRT_TS0_PRESENT" = yes ] && [ "$(fw4 device tailscale0 2>/dev/null | sed -n '1p')" != tailscale ]; then
        die 'fw4 device tailscale0 is not bound to the tailscale zone after apply'
    fi
    log_check 'fw4 zone binding verified'
    openwrt_write_state
    printf 'Apply complete (service=%s, zone=tailscale, UCI clean).\n' "$OPENWRT_EFFECTIVE_SERVICE_MODE"
}

openwrt_join() {
    openwrt_require_root_real
    openwrt_refresh
    openwrt_client_version_gate
    bootstrap_is_https_url "$OPENWRT_EFFECTIVE_LOGIN_SERVER" || die 'join requires --login-server https://...'
    [ -n "$OPENWRT_AUTH_KEY_FILE" ] || die 'join requires --auth-key-file FILE (mode 0400/0600)'

    # Multi-Headscale guard (PLAN 33.2): never silently switch ControlURL.
    if [ "$OPENWRT_CURRENT_CONTROL_URL" != unknown ] && [ -n "$OPENWRT_CURRENT_CONTROL_URL" ] && \
        [ "$OPENWRT_CURRENT_CONTROL_URL" != "$OPENWRT_EFFECTIVE_LOGIN_SERVER" ]; then
        cat >&2 <<EOF
This node is registered with a different control server:
  current:  $OPENWRT_CURRENT_CONTROL_URL
  requested: $OPENWRT_EFFECTIVE_LOGIN_SERVER
Refusing to switch silently.  Choose one explicitly:
  1. keep-current        re-run with --login-server $OPENWRT_CURRENT_CONTROL_URL
  2. switch profile      use 'tailscale switch' workflows manually if supported
  3. purge and re-register  run: $OPENWRT_PROGRAM purge-identity --yes-i-understand
EOF
        exit 2
    fi

    openwrt_compute_conflicts mutate
    if [ "$openwrt_plan_blocked" -eq 1 ]; then
        log_error "blocked preconditions: ${openwrt_block_reasons# }"
        exit 2
    fi

    openwrt_ensure_core
    openwrt_ensure_daemon_running
    openwrt_firewall_ensure_zone
    openwrt_firewall_commit_or_revert

    openwrt_refresh
    if [ "$OPENWRT_CURRENT_CONTROL_URL" = "$OPENWRT_EFFECTIVE_LOGIN_SERVER" ] && [ "$OPENWRT_TAILSCALE_STATE" = Running ]; then
        log_info 'node already registered with the requested control server; converging prefs without a new login'
        openwrt_converge_prefs
        openwrt_join_verify
        openwrt_write_state
        printf 'Join verified (already registered; no new auth key was used).\n'
        return 0
    fi

    # Fresh login.  --reset is deliberately absent (PLAN 2.2.4, 21).
    tailscale up \
        --login-server="$OPENWRT_EFFECTIVE_LOGIN_SERVER" \
        --auth-key="file:$OPENWRT_AUTH_KEY_FILE" \
        --accept-dns="$OPENWRT_ACCEPT_DNS" \
        --accept-routes="$OPENWRT_ACCEPT_ROUTES" || {
        log_error 'tailscale up failed'
        log_warn "the auth key file was NOT deleted (it may still be usable): $OPENWRT_AUTH_KEY_FILE"
        exit 1
    }
    rm -f "$OPENWRT_AUTH_KEY_FILE"
    log_change 'auth key file removed after successful login'

    openwrt_refresh
    openwrt_converge_prefs
    openwrt_join_verify
    openwrt_write_state
    printf 'Join complete: %s\n' "$OPENWRT_EFFECTIVE_LOGIN_SERVER"
}

openwrt_join_verify() {
    openwrt_refresh
    [ "$OPENWRT_CURRENT_CONTROL_URL" = "$OPENWRT_EFFECTIVE_LOGIN_SERVER" ] || die "ControlURL mismatch after join: $OPENWRT_CURRENT_CONTROL_URL"
    [ "$OPENWRT_TAILSCALE_IP4" != unknown ] && [ -n "$OPENWRT_TAILSCALE_IP4" ] || die 'no Tailscale IPv4 after join'
    [ -z "$(uci changes network 2>/dev/null)" ] || die 'pending network UCI changes after join'
    [ -z "$(uci changes firewall 2>/dev/null)" ] || die 'pending firewall UCI changes after join'
    if [ "$OPENWRT_TS0_PRESENT" = yes ] && [ "$(fw4 device tailscale0 2>/dev/null | sed -n '1p')" != tailscale ]; then
        die 'fw4 device tailscale0 is not bound to the tailscale zone'
    fi
    log_check "join verified: ControlURL=$OPENWRT_CURRENT_CONTROL_URL IP=$OPENWRT_TAILSCALE_IP4 UCI clean"
}

# --- subnet router (PLAN 24/25/41) ---------------------------------------

openwrt_discover_lan_cidr() {
    bootstrap_command_exists ubus || return 1
    openwrt_lan_json=$(ubus call network.interface.lan status 2>/dev/null) || return 1
    # Parse inside the ipv4-address object only; a route object later in the
    # same JSON also carries a "mask" field that must not win a greedy match.
    openwrt_lan_obj=$(printf '%s\n' "$openwrt_lan_json" | sed -n 's/.*"ipv4-address"[[:space:]]*:[[:space:]]*\[{[[:space:]]*\([^]}]*\).*/\1/p' | sed -n '1p')
    [ -n "$openwrt_lan_obj" ] || return 1
    openwrt_lan_ip=$(printf '%s\n' "$openwrt_lan_obj" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
    openwrt_lan_mask=$(printf '%s\n' "$openwrt_lan_obj" | sed -n 's/.*"mask"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
    [ -n "$openwrt_lan_ip" ] && [ -n "$openwrt_lan_mask" ] || return 1
    net_is_ipv4 "$openwrt_lan_ip" || return 1
    # Proper CIDR math, never a naive .1 -> .0 rewrite (PLAN 24.1).
    printf '%s/%s\n' "$(net_network_of "$openwrt_lan_ip" "$openwrt_lan_mask")" "$openwrt_lan_mask"
}

openwrt_subnet_hard_checks() {
    # PLAN 41: the CGNAT and ULA ranges must never be advertised as a LAN.
    net_cidr_contains 100.64.0.0/10 "$1" && die "$1 is inside the Tailscale CGNAT range 100.64.0.0/10"
    net_cidr_contains "$1" 100.64.0.0/10 && die "$1 contains the Tailscale CGNAT range 100.64.0.0/10"
    case "$1" in
        *:*) die 'IPv6 subnet routing is not supported in this build' ;;
    esac
    for openwrt_existing_route in $OPENWRT_CURRENT_ADVERTISE_ROUTES; do
        [ "$openwrt_existing_route" = "$1" ] && continue
        if net_cidr_overlaps "$openwrt_existing_route" "$1"; then
            die "$1 overlaps the already advertised $openwrt_existing_route"
        fi
    done
    if [ -n "$OPENWRT_LAN_ROUTE" ] && [ "$OPENWRT_LAN_ROUTE" != unknown ] && [ "$OPENWRT_LAN_ROUTE" != "$1" ]; then
        if net_cidr_overlaps "$OPENWRT_LAN_ROUTE" "$1"; then
            log_warn "$1 overlaps local route $OPENWRT_LAN_ROUTE (site-to-site style); proceeding"
        fi
    fi
}

openwrt_enable_subnet() {
    openwrt_require_root_real
    openwrt_conflict_or_die
    [ "$OPENWRT_PREFS_READABLE" = yes ] || die 'node is not registered; run join first'
    [ "$OPENWRT_CURRENT_CONTROL_URL" = "$OPENWRT_EFFECTIVE_LOGIN_SERVER" ] || die 'current ControlURL differs from --login-server; refusing to advertise'

    if [ -n "$OPENWRT_SUBNET" ]; then
        OPENWRT_SUBNET=$(net_normalize_cidr "$OPENWRT_SUBNET")
        net_is_ipv4_cidr "$OPENWRT_SUBNET" || die "--subnet must be an IPv4 CIDR: $OPENWRT_SUBNET"
    else
        OPENWRT_SUBNET=$(openwrt_discover_lan_cidr) || die 'could not derive the LAN CIDR from ubus; pass --subnet explicitly'
        log_info "discovered LAN CIDR: $OPENWRT_SUBNET"
    fi
    openwrt_subnet_hard_checks "$OPENWRT_SUBNET"

    openwrt_es_new_routes=$OPENWRT_SUBNET
    for openwrt_es_route in $OPENWRT_CURRENT_ADVERTISE_ROUTES; do
        [ "$openwrt_es_route" = "$OPENWRT_SUBNET" ] && continue
        openwrt_es_new_routes="$openwrt_es_route,$openwrt_es_new_routes"
    done
    case " $OPENWRT_CURRENT_ADVERTISE_ROUTES " in
        *" $OPENWRT_SUBNET "*)
            log_info "$OPENWRT_SUBNET is already advertised; converging firewall only"
            ;;
        *)
            tailscale set --advertise-routes="$openwrt_es_new_routes" || die 'tailscale set --advertise-routes failed'
            log_change "advertised routes now: $openwrt_es_new_routes"
            ;;
    esac

    openwrt_firewall_ensure_forwarding
    openwrt_firewall_commit_or_revert

    openwrt_refresh
    case " $OPENWRT_CURRENT_ADVERTISE_ROUTES " in
        *" $OPENWRT_SUBNET "*) : ;;
        *) die "advertise verification failed; prefs routes: ${OPENWRT_CURRENT_ADVERTISE_ROUTES:-none}" ;;
    esac
    uci -q get firewall.ts_to_lan >/dev/null 2>&1 || die 'firewall.ts_to_lan missing after commit'

    openwrt_write_state
    cat <<EOF
Subnet router advertised: $OPENWRT_SUBNET
Status: advertised, awaiting approval on the Headscale server.
Approve it there (PLAN 24.3), e.g.:
  headscale nodes list-routes
  headscale nodes approve-routes --identifier <NODE_ID> --routes $OPENWRT_SUBNET
or from the VPS: headscale-vps.sh approve-route --node-id <NODE_ID> --route $OPENWRT_SUBNET
EOF
}

openwrt_disable_subnet() {
    openwrt_require_root_real
    openwrt_conflict_or_die
    [ "$OPENWRT_PREFS_READABLE" = yes ] || die 'node is not registered; nothing to disable'

    if [ -n "$OPENWRT_SUBNET" ]; then
        OPENWRT_SUBNET=$(net_normalize_cidr "$OPENWRT_SUBNET")
        net_is_ipv4_cidr "$OPENWRT_SUBNET" || die "--subnet must be an IPv4 CIDR: $OPENWRT_SUBNET"
    else
        [ -n "$OPENWRT_CURRENT_ADVERTISE_ROUTES" ] || die 'no advertised routes and no --subnet given'
        [ "$(printf '%s\n' "$OPENWRT_CURRENT_ADVERTISE_ROUTES" | awk '{print NF}')" = 1 ] || \
            die 'multiple routes advertised; pass -- subnet explicitly'
        OPENWRT_SUBNET=$OPENWRT_CURRENT_ADVERTISE_ROUTES
    fi

    openwrt_ds_remaining=
    for openwrt_ds_route in $OPENWRT_CURRENT_ADVERTISE_ROUTES; do
        [ "$openwrt_ds_route" = "$OPENWRT_SUBNET" ] && continue
        if [ -n "$openwrt_ds_remaining" ]; then
            openwrt_ds_remaining="$openwrt_ds_remaining,$openwrt_ds_route"
        else
            openwrt_ds_remaining=$openwrt_ds_route
        fi
    done
    tailscale set --advertise-routes="$openwrt_ds_remaining" || die 'tailscale set --advertise-routes failed'
    log_change "advertised routes now: ${openwrt_ds_remaining:-none}"

    openwrt_uci_delete_if_exists firewall.ts_to_lan
    openwrt_firewall_commit_or_revert

    openwrt_refresh
    case " $OPENWRT_CURRENT_ADVERTISE_ROUTES " in
        *" $OPENWRT_SUBNET "*) die "route $OPENWRT_SUBNET still advertised after disable" ;;
    esac
    openwrt_write_state
    printf 'Subnet routing disabled for %s.\n' "$OPENWRT_SUBNET"
}

openwrt_allow_wan_udp() {
    openwrt_require_root_real
    openwrt_conflict_or_die

    if [ "$OPENWRT_ALLOW_WAN_UDP" = true ]; then
        openwrt_firewall_ensure_wan_udp_rule
        openwrt_firewall_commit_or_revert
        uci -q get firewall.ts_wan_udp >/dev/null 2>&1 || die 'firewall.ts_wan_udp missing after commit'
        printf 'WAN UDP %s input allowed (narrow rule firewall.ts_wan_udp; reversible via allow-wan-udp false or cleanup).\n' "$OPENWRT_TS_PORT"
        return 0
    fi

    if openwrt_uci_delete_if_exists firewall.ts_wan_udp; then
        openwrt_firewall_commit_or_revert
        printf 'WAN UDP rule removed.\n'
    else
        openwrt_firewall_commit_or_revert
        printf 'No WAN UDP rule present; nothing to do.\n'
    fi
}

# --- update / rollback / cleanup / purge (PLAN 28-30) --------------------

openwrt_backup_create() {
    openwrt_refresh
    bootstrap_sha256_available || die 'backup requires sha256sum, shasum, or openssl'
    OPENWRT_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
    OPENWRT_BACKUP_ROOT=$(backup_allocate_directory "$(bootstrap_root_path "$OPENWRT_BACKUP_DIR")" "$OPENWRT_BACKUP_TIMESTAMP") || return 1
    OPENWRT_BACKUP_ID=${OPENWRT_BACKUP_ROOT##*/}
    chmod 700 "$OPENWRT_BACKUP_ROOT" 2>/dev/null || true
    backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"
    backup_copy_path "$OPENWRT_ETC_TAILSCALE" "$OPENWRT_BACKUP_ROOT/source/etc/tailscale" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_INIT_CORE" "$OPENWRT_BACKUP_ROOT/source/etc/init.d/tailscale-core" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_INIT_TAILSCALE" "$OPENWRT_BACKUP_ROOT/source/etc/init.d/tailscale" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_HELPER" "$OPENWRT_BACKUP_ROOT/source/usr/sbin/tailscale_helper" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_CONFIG_TAILSCALE" "$OPENWRT_BACKUP_ROOT/source/etc/config/tailscale" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_CONFIG_FIREWALL" "$OPENWRT_BACKUP_ROOT/source/etc/config/firewall" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_CONFIG_NETWORK" "$OPENWRT_BACKUP_ROOT/source/etc/config/network" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    mkdir -p "$OPENWRT_BACKUP_ROOT/diagnostics" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    openwrt_backup_prefs "$OPENWRT_BACKUP_ROOT/diagnostics/prefs.txt"
    openwrt_backup_packages "$OPENWRT_BACKUP_ROOT/diagnostics/packages.txt"
    {
        printf 'control_url=%s\n' "$OPENWRT_CURRENT_CONTROL_URL"
        printf 'tailscale_ip4=%s\n' "$OPENWRT_TAILSCALE_IP4"
        printf 'advertise_routes=%s\n' "${OPENWRT_CURRENT_ADVERTISE_ROUTES:-none}"
    } > "$OPENWRT_BACKUP_ROOT/diagnostics/summary.txt"
    chmod 600 "$OPENWRT_BACKUP_ROOT/diagnostics/summary.txt" 2>/dev/null || true
    openwrt_backup_service_state=no
    if [ "$BOOTSTRAP_ROOT" = / ] && pgrep tailscaled >/dev/null 2>&1; then
        openwrt_backup_service_state=yes
    fi
    backup_finish "$OPENWRT_BACKUP_ROOT" "$OPENWRT_PROGRAM" "$BOOTSTRAP_ROOT" "$OPENWRT_BACKUP_TIMESTAMP" "$openwrt_backup_service_state" || {
        backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"
        return 1
    }
    log_change "backup created: $OPENWRT_BACKUP_ROOT (service_running=$openwrt_backup_service_state)"
    return 0
}

openwrt_update() {
    openwrt_require_root_real
    openwrt_conflict_or_die
    [ "$OPENWRT_TAILSCALE_PACKAGE" = installed ] || die 'tailscale package is not installed'

    openwrt_update_control=$OPENWRT_CURRENT_CONTROL_URL
    openwrt_update_ip=$OPENWRT_TAILSCALE_IP4
    openwrt_update_routes=${OPENWRT_CURRENT_ADVERTISE_ROUTES:-}

    openwrt_backup_create || die 'pre-update backup failed; aborting'

    case "$OPENWRT_PACKAGE_MANAGER" in
        opkg) opkg upgrade tailscale || die 'opkg upgrade tailscale failed' ;;
        apk) apk upgrade tailscale || die 'apk upgrade tailscale failed' ;;
        *) die 'no supported package manager' ;;
    esac

    # Re-run the helper fingerprint after the package touched the filesystem
    # and make sure the stock service stays disabled when unsafe (PLAN 28).
    openwrt_refresh
    openwrt_ensure_core
    openwrt_init_action tailscale-core restart || die 'failed to restart tailscale-core (only tailscale-core is restarted)'

    openwrt_refresh
    [ "$OPENWRT_CURRENT_CONTROL_URL" = "$openwrt_update_control" ] || \
        die "ControlURL changed after update: $openwrt_update_control -> $OPENWRT_CURRENT_CONTROL_URL"
    [ "$OPENWRT_TAILSCALE_IP4" = "$openwrt_update_ip" ] || \
        die "Tailscale IP changed after update: $openwrt_update_ip -> $OPENWRT_TAILSCALE_IP4 (identity problem)"
    [ "${OPENWRT_CURRENT_ADVERTISE_ROUTES:-}" = "$openwrt_update_routes" ] || \
        die "advertised routes changed after update"
    uci -q get firewall.tailscale >/dev/null 2>&1 || die 'firewall zone missing after update'
    [ -z "$(uci changes network 2>/dev/null)" ] || die 'pending network UCI changes after update'
    [ -z "$(uci changes firewall 2>/dev/null)" ] || die 'pending firewall UCI changes after update'

    log_check 'update verified: same ControlURL/IP/routes, zone present, UCI clean'
    openwrt_write_state
    printf 'Update complete: tailscale %s.\n' "$OPENWRT_TAILSCALE_VERSION"
}

openwrt_backup_list_latest() {
    openwrt_bl_base=$(bootstrap_root_path "$OPENWRT_BACKUP_DIR")
    [ -d "$openwrt_bl_base" ] || return 1
    ls -1 "$openwrt_bl_base" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$' | sort | tail -n 1
}

openwrt_rollback_find() {
    if [ -n "$OPENWRT_POSITIONAL" ]; then
        openwrt_rbf_dir=$(bootstrap_root_path "$OPENWRT_BACKUP_DIR")/$OPENWRT_POSITIONAL
    else
        openwrt_rbf_latest=$(openwrt_backup_list_latest) || return 1
        openwrt_rbf_dir=$(bootstrap_root_path "$OPENWRT_BACKUP_DIR")/$openwrt_rbf_latest
    fi
    [ -d "$openwrt_rbf_dir" ] || { log_error "backup directory not found: $openwrt_rbf_dir"; return 1; }
    [ -f "$openwrt_rbf_dir/manifest.sha256" ] || { log_error "backup has no manifest: $openwrt_rbf_dir"; return 1; }
    [ ! -f "$openwrt_rbf_dir/.INCOMPLETE" ] || { log_error "backup is INCOMPLETE: $openwrt_rbf_dir"; return 1; }
    OPENWRT_ROLLBACK_DIR=$openwrt_rbf_dir
    return 0
}

openwrt_rollback() {
    openwrt_require_root_real
    openwrt_refresh
    openwrt_rollback_find || exit 2
    openwrt_rb_dir=$OPENWRT_ROLLBACK_DIR

    log_rollback "restoring from $openwrt_rb_dir"
    # Stop only our own service; the third-party init is never invoked.
    openwrt_init_action tailscale-core stop
    openwrt_init_action tailscale-core disable

    for openwrt_rb_pair in \
        "source/etc/config/firewall:/etc/config/firewall" \
        "source/etc/config/network:/etc/config/network" \
        "source/etc/config/tailscale:/etc/config/tailscale" \
        "source/etc/init.d/tailscale-core:/etc/init.d/tailscale-core" \
        "source/etc/init.d/tailscale:/etc/init.d/tailscale" \
        "source/usr/sbin/tailscale_helper:/usr/sbin/tailscale_helper" \
        "source/etc/tailscale:/etc/tailscale"
    do
        openwrt_rb_src=$openwrt_rb_dir/${openwrt_rb_pair%%:*}
        openwrt_rb_dst=$(openwrt_target_path "${openwrt_rb_pair#*:}")
        [ -e "$openwrt_rb_src" ] || continue
        rm -rf "$openwrt_rb_dst"
        cp -a "$openwrt_rb_src" "$openwrt_rb_dst" || die "failed to restore $openwrt_rb_dst"
    done

    uci revert firewall 2>/dev/null || true
    uci revert network 2>/dev/null || true
    openwrt_init_action firewall reload || log_warn 'firewall reload after restore failed'
    openwrt_init_action tailscale-core enable || die 'failed to re-enable tailscale-core'
    openwrt_init_action tailscale-core start

    openwrt_refresh
    [ -z "$(uci changes network 2>/dev/null)" ] || die 'pending network UCI changes after rollback'
    [ -z "$(uci changes firewall 2>/dev/null)" ] || die 'pending firewall UCI changes after rollback'
    log_check 'rollback restored (config, identity, init scripts; firewall reloaded)'
    openwrt_write_state
    printf 'Rollback complete from %s.\n' "$openwrt_rb_dir"
}

openwrt_cleanup() {
    openwrt_require_root_real
    openwrt_refresh

    openwrt_backup_create || die 'cleanup backup failed; aborting'

    # Stop/disable/remove our service only; never touch the stock service.
    openwrt_init_action tailscale-core stop
    openwrt_init_action tailscale-core disable
    rm -f "$OPENWRT_INIT_CORE" "$(openwrt_target_path /etc/rc.d/S90tailscale-core)"

    openwrt_c_changed=0
    openwrt_uci_delete_if_exists firewall.ts_to_lan && openwrt_c_changed=1
    openwrt_uci_delete_if_exists firewall.tailscale && openwrt_c_changed=1
    openwrt_uci_delete_if_exists firewall.ts_wan_udp && openwrt_c_changed=1
    openwrt_firewall_commit_or_revert

    state_remove "$(state_path_openwrt)"
    printf 'Cleanup complete: tailscale-core and firewall sections removed; firewall reloaded.\n'
    printf 'Preserved: /etc/tailscale/tailscaled.state (identity), tailscale and luci-app-tailscale packages.\n'
    printf 'The stock /etc/init.d/tailscale was left untouched (never stopped by this script).\n'
}

openwrt_purge_identity() {
    openwrt_require_root_real
    if [ "$BOOTSTRAP_UNDERSTAND" != 1 ]; then
        cat >&2 <<'EOF'
purge-identity deletes this node's identity (/etc/tailscale/tailscaled.state).
The next join becomes a NEW Headscale node registration.
A private backup is taken first.  Re-run with:
  --yes-i-understand
EOF
        exit 2
    fi
    openwrt_refresh
    [ -f "$OPENWRT_TS_STATE" ] || { printf 'No identity file present; nothing to purge.\n'; exit 0; }
    openwrt_backup_create || die 'identity backup failed; aborting'
    if bootstrap_command_exists tailscale && [ "$OPENWRT_PREFS_READABLE" = yes ]; then
        tailscale logout || log_warn 'tailscale logout failed; the server may keep the node listed'
    fi
    rm -f "$OPENWRT_TS_STATE"
    state_remove "$(state_path_openwrt)"
    printf 'Identity purged (private backup: %s).\n' "$OPENWRT_BACKUP_ROOT"
    printf 'This makes the next join a new Headscale node registration.\n'
}
