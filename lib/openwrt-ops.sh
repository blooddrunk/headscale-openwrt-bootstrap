#!/bin/sh

# OpenWrt mutating operations.  Ownership rules
# that keep netifd, fw4, tailscaled and the LuCI helper from fighting:
#   - netifd never manages tailscale0 (no network.tailscale, no network reload);
#   - the dangerous stock /etc/init.d/tailscale is only ever disabled, never
#     stopped/reloaded/restarted -- the one exception is
#     openwrt_takeover_stock_daemon: when procd proves the running tailscaled
#     belongs to the stock service that the package postinst autostarted, the
#     procd service is deleted through ubus (a stop without ever executing the
#     third-party script);
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
    # Stop when the client is older than the server's minimum.  The
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
    if [ "$openwrt_init_service" = firewall ] && [ "$1" = reload ] && [ "${FAKE_FAIL_FIREWALL_RELOAD:-0}" = 1 ]; then
        printf 'init firewall reload failed (injected)\n' >&2
        return 1
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

# --- UCI transaction helpers ----------------------------------------------

openwrt_ensure_bootstrap_config() {
    # The real UCI CLI requires a package file to exist before `uci set`
    # stages a section.  Profile management owns this file, so create only
    # the missing empty file and never replace an administrator's config.
    [ -n "${OPENWRT_CONFIG_BOOTSTRAP:-}" ] || die 'bootstrap UCI config path is not initialized'
    if [ -e "$OPENWRT_CONFIG_BOOTSTRAP" ]; then
        [ -f "$OPENWRT_CONFIG_BOOTSTRAP" ] || \
            die "bootstrap UCI config is not a regular file: $OPENWRT_CONFIG_BOOTSTRAP"
        return 0
    fi

    openwrt_bootstrap_config_dir=$(dirname "$OPENWRT_CONFIG_BOOTSTRAP")
    [ -d "$openwrt_bootstrap_config_dir" ] || \
        mkdir -p "$openwrt_bootstrap_config_dir" || \
        die "cannot create UCI config directory: $openwrt_bootstrap_config_dir"
    : > "$OPENWRT_CONFIG_BOOTSTRAP" || \
        die "cannot create bootstrap UCI config: $OPENWRT_CONFIG_BOOTSTRAP"
    log_change "created project-owned UCI config: $OPENWRT_CONFIG_BOOTSTRAP"
}

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

openwrt_firewall_reload() {
    # Reload fw4 and surface the real cause when it fails.  Some OpenWrt
    # forks return nonzero from /etc/init.d/firewall reload for reasons
    # outside this script's managed sections (patched init scripts, `config
    # include` reload_commands from third-party packages).  Capture the
    # wrapper output so the cause is visible, then retry once with plain
    # `fw4 reload`, which bypasses the init wrapper.  Returns 0 only when a
    # reload path actually succeeded.
    openwrt_fwr_tmp=${TMPDIR:-/tmp}/fw-reload.$$
    if openwrt_init_action firewall reload >"$openwrt_fwr_tmp" 2>&1; then
        cat "$openwrt_fwr_tmp" >&2
        rm -f "$openwrt_fwr_tmp"
        return 0
    fi
    log_warn '/etc/init.d/firewall reload returned nonzero; its output was:'
    sed 's/^/  /' "$openwrt_fwr_tmp" >&2
    rm -f "$openwrt_fwr_tmp"
    log_info 'retrying the reload with fw4 directly'
    if fw4 reload; then
        log_change 'firewall reloaded via fw4 reload (the init-script wrapper had failed)'
        return 0
    fi
    return 1
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
    if ! openwrt_firewall_reload; then
        # The managed sections passed fw4 check and are committed; the reload
        # failure comes from this router's own reload machinery.  Aborting
        # would leave a valid committed config and a half-finished join for a
        # cause outside this script, so verify the config still checks out
        # and continue with a warning; the join-time verification still runs.
        if fw4 check >/dev/null 2>&1; then
            log_warn 'firewall reload failed on this router (see output above); the committed config is valid and applies on the next successful firewall restart'
            return 0
        fi
        die 'firewall reload failed and the committed config fails fw4 check; inspect with: fw4 check'
    fi
    log_change 'fw4 check passed; firewall committed and firewall reloaded'
    return 0
}

openwrt_firewall_ensure_zone() {
    # Zone bound directly to the tailscale0 device (no netifd interface).
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
    # Narrow, reversible WAN input rule: UDP only, the port
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
    OPENWRT_PACKAGE_JUST_INSTALLED=no
    if [ "$OPENWRT_TAILSCALE_PACKAGE" != installed ]; then
        [ "$OPENWRT_PACKAGE_MANAGER" != none ] || die 'no supported package manager (opkg/apk) found'
        case "$OPENWRT_PACKAGE_MANAGER" in
            opkg) opkg update || die 'opkg update failed'; opkg install tailscale || die 'opkg install tailscale failed' ;;
            apk) apk add tailscale || die 'apk add tailscale failed' ;;
        esac
        openwrt_refresh
        [ "$OPENWRT_TAILSCALE_PACKAGE" = installed ] || die 'tailscale package still not installed'
        # OpenWrt's default_postinst enables and starts every shipped init
        # script, so the package install autostarts a stock-supervised
        # tailscaled; openwrt_takeover_stock_daemon keys off this flag.
        OPENWRT_PACKAGE_JUST_INSTALLED=yes
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

    # Stock service handling: disable only, and never stop it.
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

openwrt_ubus_reply_pid() {
    # openwrt_ubus_reply_pid JSON [jsonfilter-expression]; prints the pid or
    # nothing.  Real ubus pretty-prints across lines, so the fallback compacts
    # first; a reply filtered by service name covers that service only.
    openwrt_pid_json=$1
    openwrt_pid_out=
    if [ -n "$2" ] && bootstrap_command_exists jsonfilter; then
        openwrt_pid_out=$(printf '%s\n' "$openwrt_pid_json" | jsonfilter -e "$2" 2>/dev/null | sed -n '1p')
    fi
    if [ -z "$openwrt_pid_out" ]; then
        openwrt_pid_out=$(printf '%s\n' "$openwrt_pid_json" | tr -d '\n\t\r ' | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
    fi
    printf '%s\n' "$openwrt_pid_out"
}

openwrt_daemon_supervised_by_core() {
    # procd is the authority on which init script supervises the running
    # tailscaled.  The fingerprinted tailscale-core template spawns exactly
    # one /usr/sbin/tailscaled instance, so a live pid for that instance
    # means the daemon belongs to this project's service.
    bootstrap_command_exists ubus || return 1
    openwrt_svc_json=$(ubus call service list '{"name":"tailscale-core","verbose":true}' 2>/dev/null) || return 1
    [ -n "$openwrt_svc_json" ] || return 1
    openwrt_svc_pid=$(openwrt_ubus_reply_pid "$openwrt_svc_json" '@.tailscale-core.instances.main.pid')
    [ -n "$openwrt_svc_pid" ]
}

openwrt_stock_daemon_pid() {
    # pid procd attributes to the stock "tailscale" service, if any; the
    # stock init leaves its instance unnamed, so parse the first pid without
    # a jsonfilter path.
    bootstrap_command_exists ubus || return 1
    openwrt_stock_json=$(ubus call service list '{"name":"tailscale","verbose":true}' 2>/dev/null) || return 1
    [ -n "$openwrt_stock_json" ] || return 1
    openwrt_stock_pid=$(openwrt_ubus_reply_pid "$openwrt_stock_json")
    [ -n "$openwrt_stock_pid" ] || return 1
    printf '%s\n' "$openwrt_stock_pid"
}

openwrt_takeover_stock_daemon() {
    # opkg's default_postinst starts every shipped init script, so installing
    # the tailscale package leaves a stock-supervised, respawning tailscaled
    # that would fight tailscale-core for port 41641 and the state file.
    # When procd proves the running daemon belongs to the stock service,
    # remove that service through procd itself (never by executing the
    # third-party script).  Gate: this run installed the package, or no
    # install ever completed (no state.json) -- i.e. the daemon is autostart
    # residue, not an administrator's deliberately started service.
    openwrt_stock_pid=$(openwrt_stock_daemon_pid) || return 1
    if [ "$OPENWRT_PACKAGE_JUST_INSTALLED" != yes ] && [ -r "$(state_path_openwrt)" ]; then
        return 1
    fi
    log_warn "tailscaled (pid $openwrt_stock_pid) runs under the stock 'tailscale' service (package postinst autostart); removing the stock procd service so tailscale-core can own the daemon"
    ubus call service delete '{"name":"tailscale"}' >/dev/null 2>&1 || {
        log_error 'failed to remove the stock tailscale service from procd'
        return 1
    }
    openwrt_stop_wait=0
    while pgrep tailscaled >/dev/null 2>&1 && [ "$openwrt_stop_wait" -lt 10 ]; do
        sleep 1
        openwrt_stop_wait=$((openwrt_stop_wait + 1))
    done
    pgrep tailscaled >/dev/null 2>&1 && {
        log_error 'the stock tailscaled did not exit after the procd service removal; stop it manually and re-run'
        return 1
    }
    log_change 'stock tailscaled stopped via procd service delete; tailscale-core takes over'
    return 0
}

openwrt_ensure_daemon_running() {
    # Fixture tests resolve pgrep to the fixture binary, which answers from
    # FAKE_TAILSCALED_RUNNING so the already-running paths stay testable.
    if pgrep tailscaled >/dev/null 2>&1; then
        openwrt_state_file=$(state_path_openwrt)
        if [ -r "$openwrt_state_file" ] && [ "$(state_read_field "$openwrt_state_file" service_mode)" = core ]; then
            log_info 'tailscaled already running under tailscale-core management'
            return 0
        fi
        if openwrt_daemon_supervised_by_core; then
            # A previous run started tailscale-core but aborted before
            # state.json was written.  Reboot would not clear this (the
            # enabled service starts the daemon again), so adopt the
            # daemon; the state write at the end of install records it.
            log_warn 'tailscaled runs under tailscale-core but state.json does not record it (previous run aborted early); adopting it'
            return 0
        fi
        openwrt_takeover_stock_daemon || \
            die 'tailscaled is already running outside tailscale-core management; stop it manually or reboot (this script never calls the third-party init)'
        # stock daemon stopped above; fall through and start tailscale-core
    fi
    if [ "$BOOTSTRAP_ROOT" = / ]; then
        openwrt_init_action tailscale-core start || die 'failed to start tailscale-core'
        log_change 'started tailscale-core'
    else
        openwrt_init_action tailscale-core start
    fi
    return 0
}

openwrt_write_state() {
    openwrt_load_profiles
    state_write "$(state_path_openwrt)" \
        service_mode "$OPENWRT_EFFECTIVE_SERVICE_MODE" \
        login_server "$OPENWRT_EFFECTIVE_LOGIN_SERVER" \
        subnets "${OPENWRT_CURRENT_ADVERTISE_ROUTES:-none}" \
        firewall_zone tailscale \
        profiles "${OPENWRT_PROFILE_URLS:-none}" \
        failover_enabled "$OPENWRT_FAILOVER_ENABLED" || die 'failed to write state.json'
    log_change "state.json updated: $(state_path_openwrt)"
}

# --- auth key input ---------------------------------------------------------

openwrt_auth_key_require_source() {
    # The caller must be a command that will actually perform a new login.
    # stdin is intentionally accepted as an alternative to a pre-created file;
    # the key is still handed to tailscale through its file: mechanism.
    openwrt_auth_key_command=$1
    if [ -z "$OPENWRT_AUTH_KEY_FILE" ] && [ "$OPENWRT_AUTH_KEY_STDIN" != 1 ]; then
        die "$openwrt_auth_key_command requires --auth-key-file FILE or --auth-key-stdin"
    fi
}

openwrt_auth_key_cleanup() {
    if [ -n "${OPENWRT_AUTH_KEY_TEMP:-}" ]; then
        rm -f "$OPENWRT_AUTH_KEY_TEMP" 2>/dev/null || true
        if [ "${OPENWRT_AUTH_KEY_FILE:-}" = "$OPENWRT_AUTH_KEY_TEMP" ]; then
            OPENWRT_AUTH_KEY_FILE=
        fi
        OPENWRT_AUTH_KEY_TEMP=
    fi
}

openwrt_auth_key_prepare_stdin() {
    [ "$OPENWRT_AUTH_KEY_STDIN" = 1 ] || return 0

    OPENWRT_AUTH_KEY_TEMP=$(mktemp "${TMPDIR:-/tmp}/headscale-bootstrap-auth.XXXXXX") || \
        die 'cannot create a temporary auth key file'
    OPENWRT_AUTH_KEY_FILE=$OPENWRT_AUTH_KEY_TEMP
    chmod 600 "$OPENWRT_AUTH_KEY_FILE" || {
        openwrt_auth_key_cleanup
        die 'cannot secure the temporary auth key file'
    }

    OPENWRT_AUTH_KEY_VALUE=
    IFS= read -r OPENWRT_AUTH_KEY_VALUE
    openwrt_auth_key_read_status=$?
    if [ "$openwrt_auth_key_read_status" -ne 0 ] && [ -z "$OPENWRT_AUTH_KEY_VALUE" ]; then
        openwrt_auth_key_cleanup
        die 'no auth key was received on stdin'
    fi
    [ -n "$OPENWRT_AUTH_KEY_VALUE" ] || {
        openwrt_auth_key_cleanup
        die 'auth key received on stdin is empty'
    }
    printf '%s\n' "$OPENWRT_AUTH_KEY_VALUE" > "$OPENWRT_AUTH_KEY_FILE" || {
        openwrt_auth_key_cleanup
        die 'failed to write the temporary auth key file'
    }
    unset OPENWRT_AUTH_KEY_VALUE
}

openwrt_auth_key_remove_after_success() {
    if [ "$OPENWRT_AUTH_KEY_STDIN" = 1 ]; then
        openwrt_auth_key_cleanup
        log_change 'temporary stdin auth key file removed after successful login'
    else
        rm -f "$OPENWRT_AUTH_KEY_FILE"
        log_change 'auth key file removed after successful login'
    fi
}

openwrt_auth_key_login_failed() {
    if [ "$OPENWRT_AUTH_KEY_STDIN" = 1 ]; then
        openwrt_auth_key_cleanup
        log_warn 'the auth key read from stdin was not retained; retry with --auth-key-stdin'
    else
        log_warn "the auth key file was NOT deleted (it may still be usable): $OPENWRT_AUTH_KEY_FILE"
    fi
}

# --- install / apply / join ----------------------------------------------

openwrt_install() {
    openwrt_require_root_real
    openwrt_conflict_or_die
    openwrt_ensure_core
    openwrt_ensure_daemon_running

    # Daemon start must not leave network/firewall UCI dirty.
    if [ "$(uci changes network 2>/dev/null | wc -l)" != 0 ] || [ "$(uci changes firewall 2>/dev/null | wc -l)" != 0 ]; then
        die 'pending network/firewall UCI changes after daemon start; investigate before continuing'
    fi
    log_check 'daemon start left network/firewall UCI clean'
    openwrt_write_state
    printf 'Install complete: tailscale package + tailscale-core enabled and started (logged out).\n'
    printf 'Next: %s join --login-server %s --auth-key-file /tmp/hs-auth-key\n' "$OPENWRT_PROGRAM" "$OPENWRT_EFFECTIVE_LOGIN_SERVER"
}

openwrt_converge_prefs() {
    # Idempotent prefs via `tailscale set` only; never advertise routes here.
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
    openwrt_auth_key_require_source join

    # Multi-Headscale guard: never silently switch ControlURL.
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

    # Fresh login.  --reset is deliberately absent.  If stdin was selected,
    # read it only now so an already-registered node never blocks for a key it
    # will not use.
    openwrt_auth_key_prepare_stdin
    tailscale up \
        --login-server="$OPENWRT_EFFECTIVE_LOGIN_SERVER" \
        --auth-key="file:$OPENWRT_AUTH_KEY_FILE" \
        --accept-dns="$OPENWRT_ACCEPT_DNS" \
        --accept-routes="$OPENWRT_ACCEPT_ROUTES" || {
        log_error 'tailscale up failed'
        openwrt_auth_key_login_failed
        exit 1
    }
    openwrt_auth_key_remove_after_success

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

# --- subnet router ---------------------------------------------------------

openwrt_discover_lan_cidr() {
    bootstrap_command_exists ubus || return 1
    openwrt_lan_json=$(ubus call network.interface.lan status 2>/dev/null) || return 1
    [ -n "$openwrt_lan_json" ] || return 1
    openwrt_lan_ip=
    openwrt_lan_mask=
    # Real ubus pretty-prints JSON across multiple lines (the ipv4-address
    # "[{" spans lines, which per-line sed can never match), so prefer
    # jsonfilter from the OpenWrt base install.
    if bootstrap_command_exists jsonfilter; then
        openwrt_lan_ip=$(printf '%s\n' "$openwrt_lan_json" | jsonfilter -e '@.ipv4-address[0].address' 2>/dev/null | sed -n '1p')
        openwrt_lan_mask=$(printf '%s\n' "$openwrt_lan_json" | jsonfilter -e '@.ipv4-address[0].mask' 2>/dev/null | sed -n '1p')
    fi
    if [ -z "$openwrt_lan_ip" ] || [ -z "$openwrt_lan_mask" ]; then
        # Fallback without jsonfilter: compact to one line first, then parse
        # inside the ipv4-address object only; a route object later in the
        # same JSON also carries a "mask" field that must not win a greedy
        # match.  The mask is a bare number in real ubus output.
        openwrt_lan_flat=$(printf '%s\n' "$openwrt_lan_json" | tr -d '\n\t\r')
        openwrt_lan_obj=$(printf '%s\n' "$openwrt_lan_flat" | sed -n 's/.*"ipv4-address"[[:space:]]*:[[:space:]]*\[{[[:space:]]*\([^]}]*\).*/\1/p' | sed -n '1p')
        [ -n "$openwrt_lan_obj" ] || return 1
        openwrt_lan_ip=$(printf '%s\n' "$openwrt_lan_obj" | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
        openwrt_lan_mask=$(printf '%s\n' "$openwrt_lan_obj" | sed -n 's/.*"mask"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' | sed -n '1p')
    fi
    [ -n "$openwrt_lan_ip" ] && [ -n "$openwrt_lan_mask" ] || return 1
    net_is_ipv4 "$openwrt_lan_ip" || return 1
    # Proper CIDR math, never a naive .1 -> .0 rewrite.
    printf '%s/%s\n' "$(net_network_of "$openwrt_lan_ip" "$openwrt_lan_mask")" "$openwrt_lan_mask"
}

openwrt_subnet_hard_checks() {
    # The CGNAT and ULA ranges must never be advertised as a LAN.
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
Approve it there, e.g.:
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

# --- profiles & failover -----------------------------------------------------

# Profile list + failover settings live in a dedicated, project-owned UCI file
# (/etc/config/tailscale-bootstrap).  The stock /etc/config/tailscale belongs
# to luci-app-tailscale and is never written by this script.
OPENWRT_UCI_TSBOOT=tailscale-bootstrap

openwrt_load_profiles() {
    # Sets OPENWRT_PROFILES (one "section|url|priority|ts_profile|ts_id" line
    # each, sorted by priority then section), OPENWRT_PROFILE_COUNT,
    # OPENWRT_PROFILE_URLS, and OPENWRT_FAILOVER_* settings read from the
    # committed file.  Only committed state is read; writers always commit.
    OPENWRT_PROFILES=
    OPENWRT_PROFILE_COUNT=0
    OPENWRT_PROFILE_URLS=
    OPENWRT_FAILOVER_ENABLED=no
    OPENWRT_FAILOVER_INTERVAL=
    OPENWRT_FAILOVER_FAILURE_THRESHOLD=
    OPENWRT_FAILOVER_RECOVERY_THRESHOLD=
    OPENWRT_FAILOVER_FAILBACK=
    OPENWRT_FAILOVER_COOLDOWN=
    OPENWRT_FAILOVER_PROBE_TIMEOUT=
    OPENWRT_FAILOVER_HEALTH_PATH=
    [ -r "$OPENWRT_CONFIG_BOOTSTRAP" ] || return 0

    openwrt_lp_settings=
    while IFS= read -r openwrt_lp_line; do
        case "$openwrt_lp_line" in
            setting:*)
                openwrt_lp_key=${openwrt_lp_line#setting:}
                openwrt_lp_key=${openwrt_lp_key%%=*}
                openwrt_lp_value=${openwrt_lp_line#*=}
                case "$openwrt_lp_key" in
                    enabled) [ "$openwrt_lp_value" = 1 ] && OPENWRT_FAILOVER_ENABLED=yes ;;
                    check_interval) OPENWRT_FAILOVER_INTERVAL=$openwrt_lp_value ;;
                    failure_threshold) OPENWRT_FAILOVER_FAILURE_THRESHOLD=$openwrt_lp_value ;;
                    recovery_threshold) OPENWRT_FAILOVER_RECOVERY_THRESHOLD=$openwrt_lp_value ;;
                    failback) OPENWRT_FAILOVER_FAILBACK=$openwrt_lp_value ;;
                    cooldown) OPENWRT_FAILOVER_COOLDOWN=$openwrt_lp_value ;;
                    probe_timeout) OPENWRT_FAILOVER_PROBE_TIMEOUT=$openwrt_lp_value ;;
                    health_path) OPENWRT_FAILOVER_HEALTH_PATH=$openwrt_lp_value ;;
                esac
                ;;
            *)
                OPENWRT_PROFILES="$OPENWRT_PROFILES$openwrt_lp_line
"
                openwrt_lp_url=$(printf '%s\n' "$openwrt_lp_line" | cut -d'|' -f2)
                OPENWRT_PROFILE_URLS="$OPENWRT_PROFILE_URLS $openwrt_lp_url"
                OPENWRT_PROFILE_COUNT=$((OPENWRT_PROFILE_COUNT + 1))
                ;;
        esac
    done <<EOF
$(awk '
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
    END { flush() }
' "$OPENWRT_CONFIG_BOOTSTRAP" | sort -t'|' -k3,3n -k1,1)
EOF
    OPENWRT_PROFILE_URLS=$(printf '%s\n' "$OPENWRT_PROFILE_URLS" | awk '{$1=$1; print}')
    return 0
}

openwrt_profiles_find() {
    # openwrt_profiles_find URL -> section name, or nothing
    printf '%s\n' "$OPENWRT_PROFILES" | awk -F'|' -v u="$1" '$2 == u { print $1; exit }'
}

openwrt_profiles_get_field() {
    # openwrt_profiles_get_field URL FIELD(2=prio,4=ts_profile,5=ts_id) -> value
    printf '%s\n' "$OPENWRT_PROFILES" | awk -F'|' -v u="$1" -v f="$2" '$2 == u { print $f; exit }'
}

openwrt_profile_max_priority() {
    printf '%s\n' "$OPENWRT_PROFILES" | awk -F'|' 'NR == 1 { max = $3 + 0 } $3 + 0 > max { max = $3 + 0 } END { print max + 0 }'
}

openwrt_profile_section_name() {
    # Deterministic section name from the URL host.
    openwrt_psn_host=${1#*://}
    openwrt_psn_host=${openwrt_psn_host%%/*}
    printf '%s\n' "$openwrt_psn_host" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/^_\+//; s/_\+$//' | cut -c1-60
}

# tailscale switch --list entry helpers.  Lines look like
# "ID Tailnet Account" (newer clients) or "account@example.com", with the
# current entry marked by a trailing asterisk.

openwrt_ts_current_entry() {
    printf '%s\n' "$1" | awk '$0 ~ /\*[[:space:]]*$/ { print; exit }'
}

openwrt_ts_entry_fields() {
    # openwrt_ts_entry_fields LINE -> "name|id" (id may be empty)
    printf '%s\n' "$1" | awk '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]*\*[[:space:]]*$/, "", line)
            n = split(line, f, /[[:space:]]+/)
            if (n == 0 || line == "") exit
            # "ID ... Account" is the table header, never a profile.
            if (f[1] == "ID" && f[n] == "Account") exit
            print f[n] "|" ((n >= 3) ? f[1] : "")
        }'
}

openwrt_ts_new_entry() {
    # openwrt_ts_new_entry BEFORE AFTER -> the first line only in AFTER.
    # Lines are normalized first: the only difference between "current" and
    # "not current" is a trailing asterisk, which must not look like a new
    # profile.  The table's column padding also changes whenever a wider
    # profile joins, so runs of blanks are squeezed before comparing, and
    # the header row is skipped: an exact-text diff would otherwise mistake
    # the re-padded "ID Tailnet Account" header for the new entry.
    openwrt_tne_before=$(printf '%s\n' "$1" \
        | sed -e 's/[[:space:]]*\*[[:space:]]*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]\{1,\}/ /g' \
        | awk 'NF')
    while IFS= read -r openwrt_tne_line; do
        [ -n "$openwrt_tne_line" ] || continue
        openwrt_tne_line=$(printf '%s\n' "$openwrt_tne_line" \
            | sed -e 's/[[:space:]]*\*[[:space:]]*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]\{1,\}/ /g')
        [ -n "$openwrt_tne_line" ] || continue
        [ "$openwrt_tne_line" = 'ID Tailnet Account' ] && continue
        if ! printf '%s\n' "$openwrt_tne_before" | grep -qxF -- "$openwrt_tne_line"; then
            printf '%s\n' "$openwrt_tne_line"
            return 0
        fi
    done <<EOF
$2
EOF
    return 1
}

openwrt_ts_entry_for_url() {
    # openwrt_ts_entry_for_url LIST URL -> entry whose Tailnet column is the
    # URL host; falls back to the only entry when the list has exactly one.
    openwrt_tef_host=${2#*://}
    openwrt_tef_host=${openwrt_tef_host%%/*}
    printf '%s\n' "$1" | awk -v host="$openwrt_tef_host" '
        {
            line = $0
            sub(/[[:space:]]*\*[[:space:]]*$/, "", line)
            if (split(line, f, /[[:space:]]+/) >= 3 && f[2] == host) { print line; found = 1; exit }
            lines[++cnt] = line
        }
        END { if (!found && cnt == 1) print lines[1] }'
}

openwrt_ts_entries_strict_for_url() {
    # openwrt_ts_entries_strict_for_url LIST URL -> every entry whose Tailnet
    # column is the URL host (no single-entry fallback).
    openwrt_tes_host=${2#*://}
    openwrt_tes_host=${openwrt_tes_host%%/*}
    printf '%s\n' "$1" | awk -v host="$openwrt_tes_host" '
        {
            line = $0
            sub(/[[:space:]]*\*[[:space:]]*$/, "", line)
            if (split(line, f, /[[:space:]]+/) >= 3 && f[2] == host) print line
        }'
}

openwrt_ts_switch() {
    # openwrt_ts_switch NAME ID; settles so the new ControlURL is observable.
    # The real CLI has no --id flag: the positional argument is matched
    # against ID, then tailnet, then account name, first match wins.  One
    # account name can be registered on several servers, and a name match
    # may land on the profile that is already current (a successful no-op),
    # so switch by the unambiguous ID whenever one is recorded and keep the
    # name only as a fallback.
    openwrt_tsw_name=$1
    openwrt_tsw_id=$2
    openwrt_tsw_ok=
    if [ -n "$openwrt_tsw_id" ]; then
        tailscale switch "$openwrt_tsw_id" >/dev/null 2>&1 && openwrt_tsw_ok=1
    fi
    if [ -z "$openwrt_tsw_ok" ] && [ -n "$openwrt_tsw_name" ]; then
        tailscale switch "$openwrt_tsw_name" >/dev/null 2>&1 && openwrt_tsw_ok=1
    fi
    [ -n "$openwrt_tsw_ok" ] || return 1
    openwrt_tsw_settle=${OPENWRT_SWITCH_SETTLE:-5}
    [ "$openwrt_tsw_settle" -gt 0 ] 2>/dev/null && sleep "$openwrt_tsw_settle"
    return 0
}

openwrt_failover_probe_tool() {
    if bootstrap_command_exists curl; then printf 'curl\n'; return 0; fi
    if bootstrap_command_exists wget; then printf 'wget\n'; return 0; fi
    if bootstrap_command_exists uclient-fetch; then printf 'uclient-fetch\n'; return 0; fi
    return 1
}

openwrt_failover_probe() {
    # openwrt_failover_probe URL TIMEOUT (same order as the watchdog)
    openwrt_fp_url=$1
    openwrt_fp_timeout=$2
    if bootstrap_command_exists curl; then
        curl -fsS -m "$openwrt_fp_timeout" "$openwrt_fp_url" >/dev/null 2>&1
        return
    fi
    if bootstrap_command_exists wget; then
        wget -q -T "$openwrt_fp_timeout" -O /dev/null "$openwrt_fp_url" >/dev/null 2>&1
        return
    fi
    if bootstrap_command_exists uclient-fetch; then
        uclient-fetch -q -O /dev/null "$openwrt_fp_url" >/dev/null 2>&1
        return
    fi
    return 1
}

openwrt_profile_guard() {
    # Standard hard guards, tolerating an intentionally different target
    # server (profile-add/switch-to switch networks on purpose).  With
    # "skip-failover", failover service defects do not block enable-failover
    # (which is the command that repairs them).
    openwrt_refresh
    openwrt_client_version_gate
    openwrt_pg_target=$OPENWRT_LOGIN_SERVER
    openwrt_conflicts_skip_failover=0
    [ "${1:-}" = skip-failover ] && openwrt_conflicts_skip_failover=1
    if [ -n "$OPENWRT_CURRENT_CONTROL_URL" ] && [ "$OPENWRT_CURRENT_CONTROL_URL" != unknown ] && \
        [ -n "$openwrt_pg_target" ] && [ "$OPENWRT_CURRENT_CONTROL_URL" != "$openwrt_pg_target" ]; then
        OPENWRT_LOGIN_SERVER=
        openwrt_effective_values
    fi
    openwrt_compute_conflicts mutate
    openwrt_conflicts_skip_failover=0
    OPENWRT_LOGIN_SERVER=$openwrt_pg_target
    openwrt_effective_values
    if [ "$openwrt_plan_blocked" -eq 1 ]; then
        log_error "blocked preconditions: ${openwrt_block_reasons# }"
        exit 2
    fi
}

openwrt_deploy_template() {
    # openwrt_deploy_template SRC DST MODE FINGERPRINT_FN
    openwrt_dt_src=$1
    openwrt_dt_dst=$2
    openwrt_dt_mode=$3
    openwrt_dt_fingerprint=$4
    if [ ! -f "$openwrt_dt_dst" ] || [ "$("$openwrt_dt_fingerprint" "$openwrt_dt_dst")" != verified ]; then
        if [ -f "$openwrt_dt_dst" ]; then
            OPENWRT_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
            OPENWRT_BACKUP_ROOT=$(backup_allocate_directory "$(bootstrap_root_path "$OPENWRT_BACKUP_DIR")" "$OPENWRT_BACKUP_TIMESTAMP") || die 'cannot allocate backup directory'
            chmod 700 "$OPENWRT_BACKUP_ROOT" 2>/dev/null || true
            backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"
            backup_copy_path "$openwrt_dt_dst" "$OPENWRT_BACKUP_ROOT/source${openwrt_dt_dst#"$BOOTSTRAP_ROOT"}" || die "failed to back up existing $openwrt_dt_dst"
            backup_finish "$OPENWRT_BACKUP_ROOT" "$OPENWRT_PROGRAM" "$BOOTSTRAP_ROOT" "$OPENWRT_BACKUP_TIMESTAMP" || die 'failed to finalize backup'
            log_change "backed up existing $openwrt_dt_dst to $OPENWRT_BACKUP_ROOT"
        fi
        mkdir -p "$(dirname "$openwrt_dt_dst")"
        cat "$OPENWRT_SCRIPT_DIR/$openwrt_dt_src" > "$openwrt_dt_dst" || die "failed to write $openwrt_dt_dst"
        chmod "$openwrt_dt_mode" "$openwrt_dt_dst"
        log_change "installed ${openwrt_dt_dst##*/} from the verified template"
    else
        log_info "${openwrt_dt_dst##*/} present and fingerprint verified"
    fi
    [ "$("$openwrt_dt_fingerprint" "$openwrt_dt_dst")" = verified ] || \
        die "fingerprint mismatch after write: $openwrt_dt_dst"
    return 0
}

openwrt_failover_ensure_service() {
    openwrt_deploy_template \
        templates/tailscale-failover.init \
        "$OPENWRT_INIT_FAILOVER" \
        755 \
        openwrt_failover_fingerprint
    openwrt_deploy_template \
        templates/tailscale-failover.watchdog.sh \
        "$OPENWRT_WATCHDOG_FAILOVER" \
        700 \
        openwrt_watchdog_fingerprint
    return 0
}

openwrt_failover_disable_service() {
    if [ "$OPENWRT_INIT_FAILOVER_PRESENT" = yes ]; then
        openwrt_init_action tailscale-failover stop
        openwrt_init_action tailscale-failover disable
    fi
    if openwrt_uci_ensure_option "$OPENWRT_UCI_TSBOOT.watchdog.enabled" 0; then
        uci commit "$OPENWRT_UCI_TSBOOT" || die "uci commit $OPENWRT_UCI_TSBOOT failed"
    fi
    return 0
}

openwrt_profile_list() {
    openwrt_refresh
    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$OPENWRT_PROGRAM"
        bootstrap_json_field command profile-list
        bootstrap_json_field config "${OPENWRT_CONFIG_BOOTSTRAP}"
        bootstrap_json_field profile_count "$OPENWRT_PROFILE_COUNT"
        bootstrap_json_field profiles "${OPENWRT_PROFILE_URLS:-none}"
        bootstrap_json_field current_control_url "$OPENWRT_CURRENT_CONTROL_URL"
        bootstrap_json_field failover_enabled "$OPENWRT_FAILOVER_ENABLED"
        bootstrap_json_field failover_service "$OPENWRT_INIT_FAILOVER_PRESENT"
        bootstrap_json_end
        return 0
    fi
    printf 'Bootstrap profile list (read-only)\n'
    printf '  config: %s\n' "$OPENWRT_CONFIG_BOOTSTRAP"
    printf '  profiles: %s\n' "${OPENWRT_PROFILE_COUNT:-0}"
    printf '%s\n' "$OPENWRT_PROFILES" | while IFS='|' read -r openwrt_pl_section openwrt_pl_url openwrt_pl_prio openwrt_pl_name openwrt_pl_id; do
        [ -n "$openwrt_pl_section" ] || continue
        openwrt_pl_marker=
        [ "$openwrt_pl_url" = "$OPENWRT_CURRENT_CONTROL_URL" ] && openwrt_pl_marker=' [active]'
        printf '  prio %-4s %s%s\n' "$openwrt_pl_prio" "$openwrt_pl_url" "$openwrt_pl_marker"
        printf '         section %s, ts_profile %s%s\n' "$openwrt_pl_section" "$openwrt_pl_name" \
            "$([ -n "$openwrt_pl_id" ] && printf ", ts_id %s" "$openwrt_pl_id")"
    done
    printf '  current ControlURL: %s\n' "$OPENWRT_CURRENT_CONTROL_URL"
    printf '  failover: %s (service %s, interval %ss, failure %s, recovery %s, failback %s, cooldown %ss)\n' \
        "$OPENWRT_FAILOVER_ENABLED" "$OPENWRT_INIT_FAILOVER_PRESENT" \
        "${OPENWRT_FAILOVER_INTERVAL:-60}" "${OPENWRT_FAILOVER_FAILURE_THRESHOLD:-3}" \
        "${OPENWRT_FAILOVER_RECOVERY_THRESHOLD:-3}" \
        "$([ "$OPENWRT_FAILOVER_FAILBACK" = 1 ] && printf true || printf false)" \
        "${OPENWRT_FAILOVER_COOLDOWN:-300}"
    return 0
}

openwrt_profile_add() {
    openwrt_require_root_real
    bootstrap_is_https_url "$OPENWRT_LOGIN_SERVER" || die 'profile-add requires --login-server https://...'
    openwrt_auth_key_require_source profile-add
    openwrt_refresh
    openwrt_client_version_gate

    openwrt_pa_target=$OPENWRT_LOGIN_SERVER
    openwrt_pa_prev_url=$OPENWRT_CURRENT_CONTROL_URL

    # Duplicate check before any network action.
    if [ -n "$(openwrt_profiles_find "$openwrt_pa_target")" ]; then
        die "$openwrt_pa_target is already in the profile list (use switch-to or profile-remove)"
    fi

    # A different target server is the normal case here, not a conflict.
    openwrt_profile_guard

    tailscale switch --list >/dev/null 2>&1 || die 'tailscale switch --list failed; this client cannot manage profiles'

    openwrt_pa_before=$(tailscale switch --list 2>/dev/null || :)
    openwrt_pa_prev_entry=$(openwrt_ts_current_entry "$openwrt_pa_before")
    openwrt_pa_prev_name=
    openwrt_pa_prev_id=
    if [ -n "$openwrt_pa_prev_entry" ]; then
        openwrt_pa_prev_fields=$(openwrt_ts_entry_fields "$openwrt_pa_prev_entry")
        openwrt_pa_prev_name=${openwrt_pa_prev_fields%%|*}
        openwrt_pa_prev_id=${openwrt_pa_prev_fields#*|}
    fi

    if [ "$openwrt_pa_prev_url" = "$openwrt_pa_target" ]; then
        # Adopt the current registration instead of logging in again.
        openwrt_pa_entry=$(openwrt_ts_entry_for_url "$openwrt_pa_before" "$openwrt_pa_target")
        if [ -z "$openwrt_pa_entry" ]; then
            die 'cannot map the current registration to a tailscale profile; register this server via profile-add from another network, or purge-identity first'
        fi
        log_info "adopting the current registration on $openwrt_pa_target"
        openwrt_converge_prefs
    else
        # tailscale login creates a NEW profile; it never reconfigures the
        # current one, so the active network is preserved until we switch back.
        openwrt_auth_key_prepare_stdin
        tailscale login \
            --login-server="$openwrt_pa_target" \
            --auth-key="file:$OPENWRT_AUTH_KEY_FILE" || {
            log_error 'tailscale login failed'
            openwrt_auth_key_login_failed
            exit 1
        }
        openwrt_auth_key_remove_after_success

        openwrt_refresh
        [ "$OPENWRT_CURRENT_CONTROL_URL" = "$openwrt_pa_target" ] || \
            die "ControlURL mismatch after login: $OPENWRT_CURRENT_CONTROL_URL"
        [ "$OPENWRT_TAILSCALE_IP4" != unknown ] && [ -n "$OPENWRT_TAILSCALE_IP4" ] || \
            die 'no Tailscale IPv4 after login'

        # Converge the safe prefs while the new profile is current.
        openwrt_converge_prefs

        openwrt_pa_after=$(tailscale switch --list 2>/dev/null || :)
        openwrt_pa_entry=$(openwrt_ts_new_entry "$openwrt_pa_before" "$openwrt_pa_after")
        if [ -z "$openwrt_pa_entry" ]; then
            log_error 'could not identify the new tailscale profile (list unchanged)'
            log_warn 'the node is now registered on the new network; fix the profile list manually or purge-identity'
            exit 1
        fi
    fi

    openwrt_pa_fields=$(openwrt_ts_entry_fields "$openwrt_pa_entry")
    openwrt_pa_name=${openwrt_pa_fields%%|*}
    openwrt_pa_id=${openwrt_pa_fields#*|}
    [ -n "$openwrt_pa_name" ] || {
        log_error "could not parse the tailscale profile entry: $openwrt_pa_entry"
        log_warn 'if this followed a login, the node is now registered on the new network; fix the profile list manually or purge-identity'
        exit 1
    }

    openwrt_pa_section=$(openwrt_profile_section_name "$openwrt_pa_target")
    if [ -n "$OPENWRT_PRIORITY" ]; then
        openwrt_pa_priority=$OPENWRT_PRIORITY
    else
        openwrt_pa_priority=$(( $(openwrt_profile_max_priority) + 10 ))
        [ "$openwrt_pa_priority" -ge 10 ] || openwrt_pa_priority=10
    fi

    openwrt_ensure_bootstrap_config
    openwrt_uci_ensure_section "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section" profile || true
    uci set "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section.login_server=$openwrt_pa_target" || die 'uci set login_server failed'
    uci set "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section.priority=$openwrt_pa_priority" || die 'uci set priority failed'
    uci set "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section.ts_profile=$openwrt_pa_name" || die 'uci set ts_profile failed'
    if [ -n "$openwrt_pa_id" ]; then
        uci set "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section.ts_id=$openwrt_pa_id" || die 'uci set ts_id failed'
    else
        openwrt_uci_delete_if_exists "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section.ts_id" || true
    fi
    uci commit "$OPENWRT_UCI_TSBOOT" || die "uci commit $OPENWRT_UCI_TSBOOT failed"
    uci -q get "$OPENWRT_UCI_TSBOOT.$openwrt_pa_section.login_server" >/dev/null 2>&1 || \
        die 'profile section missing after commit'
    log_change "profile recorded: $openwrt_pa_target (section $openwrt_pa_section, priority $openwrt_pa_priority, ts_profile $openwrt_pa_name)"

    # Switch back so adding a backup never yanks the active network away.
    if [ -n "$openwrt_pa_prev_url" ] && [ "$openwrt_pa_prev_url" != unknown ] && \
        [ "$openwrt_pa_prev_url" != "$openwrt_pa_target" ] && [ -n "$openwrt_pa_prev_name" ]; then
        if openwrt_ts_switch "$openwrt_pa_prev_name" "$openwrt_pa_prev_id"; then
            openwrt_refresh
            if [ "$OPENWRT_CURRENT_CONTROL_URL" = "$openwrt_pa_prev_url" ]; then
                log_change "switched back to $openwrt_pa_prev_url"
            else
                log_warn "switch-back verification mismatch: $OPENWRT_CURRENT_CONTROL_URL"
            fi
        else
            log_warn 'switch back to the previous network failed; the node is now on the NEW network'
        fi
    fi

    openwrt_refresh
    openwrt_write_state
    printf 'Profile added: %s (priority %s, ts_profile %s).\n' "$openwrt_pa_target" "$openwrt_pa_priority" "$openwrt_pa_name"
    printf 'Active network after profile-add: %s\n' "$OPENWRT_CURRENT_CONTROL_URL"
}

openwrt_switch_to() {
    openwrt_require_root_real
    bootstrap_is_https_url "$OPENWRT_LOGIN_SERVER" || die 'switch-to requires --login-server https://...'
    openwrt_refresh
    openwrt_client_version_gate
    [ "$OPENWRT_PREFS_READABLE" = yes ] || die 'not registered yet; run profile-add first'

    openwrt_st_target=$OPENWRT_LOGIN_SERVER
    openwrt_st_section=$(openwrt_profiles_find "$openwrt_st_target")
    [ -n "$openwrt_st_section" ] || die "$openwrt_st_target is not in the profile list; add it with profile-add first"

    openwrt_profile_guard

    if [ "$OPENWRT_CURRENT_CONTROL_URL" = "$openwrt_st_target" ]; then
        openwrt_converge_prefs
        openwrt_write_state
        printf 'Already active: %s\n' "$openwrt_st_target"
        return 0
    fi

    openwrt_st_name=$(openwrt_profiles_get_field "$openwrt_st_target" 4)
    openwrt_st_id=$(openwrt_profiles_get_field "$openwrt_st_target" 5)
    [ -n "$openwrt_st_name" ] || [ -n "$openwrt_st_id" ] || \
        die "profile entry for $openwrt_st_target lacks ts_profile/ts_id; re-add it via profile-add"

    openwrt_ensure_daemon_running
    openwrt_ts_switch "$openwrt_st_name" "$openwrt_st_id" || die "tailscale switch to $openwrt_st_name failed"

    openwrt_refresh
    [ "$OPENWRT_CURRENT_CONTROL_URL" = "$openwrt_st_target" ] || \
        die "switch verification failed: ControlURL=$OPENWRT_CURRENT_CONTROL_URL expected=$openwrt_st_target"
    openwrt_converge_prefs
    openwrt_write_state
    printf 'Switched to: %s (profile %s).\n' "$openwrt_st_target" "$openwrt_st_name"
}

openwrt_profile_remove() {
    openwrt_require_root_real
    openwrt_refresh
    bootstrap_is_https_url "$OPENWRT_LOGIN_SERVER" || die 'profile-remove requires --login-server https://...'
    openwrt_pr_target=$OPENWRT_LOGIN_SERVER
    openwrt_pr_section=$(openwrt_profiles_find "$openwrt_pr_target")
    if [ -z "$openwrt_pr_section" ]; then
        log_error "$openwrt_pr_target is not in the profile list; known profiles:${OPENWRT_PROFILE_URLS:- none}"
        exit 2
    fi

    openwrt_pr_remaining=$((OPENWRT_PROFILE_COUNT - 1))

    if [ "$OPENWRT_DELETE_IDENTITY" = 1 ]; then
        [ "$OPENWRT_PREFS_READABLE" = yes ] || die 'not registered; nothing to delete'
        [ "$openwrt_pr_remaining" -ge 1 ] || die 'refusing --delete-identity: no other profile remains to land on'
        openwrt_pr_prev_url=$OPENWRT_CURRENT_CONTROL_URL
        # One URL may own several tailscale profiles (repeated logins);
        # logout only removes the current one, so loop until none remain.
        openwrt_pr_attempts=0
        while :; do
            openwrt_pr_list=$(tailscale switch --list 2>/dev/null || :)
            openwrt_pr_entry=$(openwrt_ts_entries_strict_for_url "$openwrt_pr_list" "$openwrt_pr_target" | sed -n '1p')
            [ -n "$openwrt_pr_entry" ] || break
            openwrt_pr_attempts=$((openwrt_pr_attempts + 1))
            [ "$openwrt_pr_attempts" -le 5 ] || \
                die "could not fully log out $openwrt_pr_target after 5 attempts; finish manually with tailscale switch/logout"
            openwrt_refresh
            if [ "$OPENWRT_CURRENT_CONTROL_URL" != "$openwrt_pr_target" ]; then
                openwrt_pr_fields=$(openwrt_ts_entry_fields "$openwrt_pr_entry")
                openwrt_pr_name=${openwrt_pr_fields%%|*}
                openwrt_pr_id=${openwrt_pr_fields#*|}
                openwrt_ts_switch "$openwrt_pr_name" "$openwrt_pr_id" || \
                    die "cannot switch to a $openwrt_pr_target profile to log it out"
            fi
            tailscale logout || die 'tailscale logout failed'
        done
        log_change "identity for $openwrt_pr_target deleted (logged out)"

        openwrt_refresh
        # Land deterministically on the previous network when it still exists.
        if [ "$openwrt_pr_prev_url" != "$openwrt_pr_target" ] && \
            [ -n "$(openwrt_profiles_find "$openwrt_pr_prev_url")" ] && \
            { [ "$OPENWRT_PREFS_READABLE" != yes ] || [ "$OPENWRT_CURRENT_CONTROL_URL" != "$openwrt_pr_prev_url" ]; }; then
            openwrt_pr_back_name=$(openwrt_profiles_get_field "$openwrt_pr_prev_url" 4)
            openwrt_pr_back_id=$(openwrt_profiles_get_field "$openwrt_pr_prev_url" 5)
            openwrt_ts_switch "$openwrt_pr_back_name" "$openwrt_pr_back_id" || \
                log_warn "cannot switch back to $openwrt_pr_prev_url after logout"
            openwrt_refresh
        fi
    elif [ "$OPENWRT_CURRENT_CONTROL_URL" = "$openwrt_pr_target" ]; then
        log_warn "removing the ACTIVE network; the node stays registered on it until you switch-to another profile"
    fi

    uci delete "$OPENWRT_UCI_TSBOOT.$openwrt_pr_section" || die "uci delete $openwrt_pr_section failed"
    uci commit "$OPENWRT_UCI_TSBOOT" || die "uci commit $OPENWRT_UCI_TSBOOT failed"
    uci -q get "$OPENWRT_UCI_TSBOOT.$openwrt_pr_section.login_server" >/dev/null 2>&1 && \
        die 'profile section still present after commit'
    log_change "profile removed from the list: $openwrt_pr_target"

    # A watchdog with fewer than two profiles cannot fail over; disable it.
    openwrt_refresh
    if [ "$OPENWRT_FAILOVER_ENABLED" = yes ] && [ "$OPENWRT_PROFILE_COUNT" -lt 2 ]; then
        openwrt_failover_disable_service
        log_change 'failover disabled automatically: fewer than two profiles remain'
        openwrt_refresh
    fi

    openwrt_write_state
    printf 'Profile removed: %s (remaining: %s).\n' "$openwrt_pr_target" "$OPENWRT_PROFILE_COUNT"
    printf 'Active network: %s\n' "$OPENWRT_CURRENT_CONTROL_URL"
}

openwrt_enable_failover() {
    openwrt_require_root_real
    openwrt_refresh
    openwrt_client_version_gate
    openwrt_profile_guard skip-failover

    [ "$OPENWRT_PROFILE_COUNT" -ge 2 ] || die "failover needs at least two profiles; got $OPENWRT_PROFILE_COUNT (profile-add more first)"
    openwrt_failover_probe_tool >/dev/null || die 'no HTTPS probe tool found (need curl, wget, or uclient-fetch with TLS)'

    openwrt_ef_health=${OPENWRT_HEALTH_PATH:-/health}
    openwrt_ef_timeout=${OPENWRT_PROBE_TIMEOUT:-5}
    openwrt_ef_ok=0
    openwrt_ef_down=
    while IFS='|' read -r openwrt_ef_section openwrt_ef_url openwrt_ef_prio openwrt_ef_name openwrt_ef_id; do
        [ -n "$openwrt_ef_section" ] || continue
        if openwrt_failover_probe "$openwrt_ef_url$openwrt_ef_health" "$openwrt_ef_timeout"; then
            openwrt_ef_ok=$((openwrt_ef_ok + 1))
        else
            openwrt_ef_down="$openwrt_ef_down $openwrt_ef_url"
        fi
    done <<EOF
$OPENWRT_PROFILES
EOF
    [ "$openwrt_ef_ok" -ge 1 ] || die 'no profile is reachable right now; refusing to enable a blind watchdog'
    [ -z "$openwrt_ef_down" ] || log_warn "currently unreachable (excluded until they recover):$openwrt_ef_down"

    # Converge the watchdog settings: explicit flags win, then existing UCI
    # values, then defaults.
    openwrt_uci_ensure_section "$OPENWRT_UCI_TSBOOT.watchdog" failover || true
    openwrt_uci_ensure_option "$OPENWRT_UCI_TSBOOT.watchdog.enabled" 1 || true
    openwrt_failover_ensure_watchdog_option check_interval "$OPENWRT_CHECK_INTERVAL" 60
    openwrt_failover_ensure_watchdog_option failure_threshold "$OPENWRT_FAILURE_THRESHOLD" 3
    openwrt_failover_ensure_watchdog_option recovery_threshold "$OPENWRT_RECOVERY_THRESHOLD" 3
    openwrt_failover_ensure_watchdog_option cooldown "$OPENWRT_COOLDOWN" 300
    openwrt_failover_ensure_watchdog_option probe_timeout "$OPENWRT_PROBE_TIMEOUT" 5
    openwrt_failover_ensure_watchdog_option health_path "$OPENWRT_HEALTH_PATH" /health
    if [ -n "$OPENWRT_FAILBACK" ]; then
        case "$OPENWRT_FAILBACK" in
            true) uci set "$OPENWRT_UCI_TSBOOT.watchdog.failback=1" ;;
            false) uci set "$OPENWRT_UCI_TSBOOT.watchdog.failback=0" ;;
        esac
    fi
    uci commit "$OPENWRT_UCI_TSBOOT" || die "uci commit $OPENWRT_UCI_TSBOOT failed"

    openwrt_failover_ensure_service

    openwrt_init_action tailscale-failover enable || die 'failed to enable tailscale-failover'
    openwrt_init_action tailscale-failover start || die 'failed to start tailscale-failover'

    openwrt_refresh
    [ "$OPENWRT_INIT_FAILOVER_PRESENT" = yes ] || die 'tailscale-failover init missing after enable'
    [ "$OPENWRT_FAILOVER_FINGERPRINT" = verified ] || die 'tailscale-failover fingerprint unverified after enable'
    [ "$OPENWRT_WATCHDOG_FINGERPRINT" = verified ] || die 'watchdog fingerprint unverified after enable'

    openwrt_write_state
    printf 'Failover enabled: %s profiles, watchdog installed and started.\n' "$OPENWRT_PROFILE_COUNT"
    [ -z "$openwrt_ef_down" ] || printf 'Currently unreachable (excluded until they recover):%s\n' "$openwrt_ef_down"
    printf 'Logs: logread | grep tailscale-failover; single-cycle check: /usr/sbin/tailscale-failover --once\n'
}

openwrt_failover_ensure_watchdog_option() {
    # openwrt_failover_ensure_watchdog_option KEY FLAG_VALUE DEFAULT
    openwrt_few_key=$1
    openwrt_few_value=$2
    openwrt_few_default=$3
    openwrt_few_path="$OPENWRT_UCI_TSBOOT.watchdog.$openwrt_few_key"
    if [ -n "$openwrt_few_value" ]; then
        uci set "$openwrt_few_path=$openwrt_few_value" || die "uci set $openwrt_few_path failed"
    else
        uci -q get "$openwrt_few_path" >/dev/null 2>&1 || \
            uci set "$openwrt_few_path=$openwrt_few_default" || die "uci set $openwrt_few_path failed"
    fi
    return 0
}

openwrt_disable_failover() {
    openwrt_require_root_real
    openwrt_refresh
    openwrt_failover_disable_service
    openwrt_refresh
    openwrt_write_state
    printf 'Failover disabled (service stopped and disabled; profiles kept).\n'
    return 0
}


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
    backup_copy_path "$OPENWRT_CONFIG_BOOTSTRAP" "$OPENWRT_BACKUP_ROOT/source/etc/config/tailscale-bootstrap" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_INIT_FAILOVER" "$OPENWRT_BACKUP_ROOT/source/etc/init.d/tailscale-failover" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
    backup_copy_path "$OPENWRT_WATCHDOG_FAILOVER" "$OPENWRT_BACKUP_ROOT/source/usr/sbin/tailscale-failover" || { backup_mark_incomplete "$OPENWRT_BACKUP_ROOT"; return 1; }
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
    # and make sure the stock service stays disabled when unsafe.
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
        "source/etc/config/tailscale-bootstrap:/etc/config/tailscale-bootstrap" \
        "source/etc/init.d/tailscale-core:/etc/init.d/tailscale-core" \
        "source/etc/init.d/tailscale-failover:/etc/init.d/tailscale-failover" \
        "source/etc/init.d/tailscale:/etc/init.d/tailscale" \
        "source/usr/sbin/tailscale-failover:/usr/sbin/tailscale-failover" \
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
    uci revert "$OPENWRT_UCI_TSBOOT" 2>/dev/null || true
    openwrt_firewall_reload || log_warn 'firewall reload after restore failed'
    openwrt_init_action tailscale-core enable || die 'failed to re-enable tailscale-core'
    openwrt_init_action tailscale-core start

    # Failover comes back exactly as the snapshot recorded it.
    openwrt_refresh
    if [ "$OPENWRT_INIT_FAILOVER_PRESENT" = yes ]; then
        if [ "$OPENWRT_FAILOVER_ENABLED" = yes ] && [ "$OPENWRT_PROFILE_COUNT" -ge 2 ]; then
            openwrt_init_action tailscale-failover enable || log_warn 'failed to re-enable tailscale-failover'
            openwrt_init_action tailscale-failover start || log_warn 'failed to start tailscale-failover'
        else
            openwrt_init_action tailscale-failover disable || true
        fi
    else
        rm -f "$(openwrt_target_path /etc/rc.d/S95tailscale-failover)" "$(openwrt_target_path /etc/rc.d/S90tailscale-failover)"
    fi

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

    # The failover watchdog and the project-owned profile list go away too;
    # tailscale-side identities inside tailscaled.state are preserved.
    openwrt_init_action tailscale-failover stop
    openwrt_init_action tailscale-failover disable
    rm -f "$OPENWRT_INIT_FAILOVER" "$OPENWRT_WATCHDOG_FAILOVER" \
        "$(openwrt_target_path /etc/rc.d/S95tailscale-failover)" \
        "$(openwrt_target_path /etc/rc.d/S90tailscale-failover)" \
        "$OPENWRT_CONFIG_BOOTSTRAP"

    openwrt_c_changed=0
    openwrt_uci_delete_if_exists firewall.ts_to_lan && openwrt_c_changed=1
    openwrt_uci_delete_if_exists firewall.tailscale && openwrt_c_changed=1
    openwrt_uci_delete_if_exists firewall.ts_wan_udp && openwrt_c_changed=1
    openwrt_firewall_commit_or_revert

    state_remove "$(state_path_openwrt)"
    printf 'Cleanup complete: tailscale-core, failover watchdog and firewall sections removed; firewall reloaded.\n'
    printf 'Preserved: /etc/tailscale/tailscaled.state (identities, incl. all profiles), tailscale and luci-app-tailscale packages.\n'
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
