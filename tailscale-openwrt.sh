#!/bin/sh

# Headscale + OpenWrt bootstrap, router side.
#
# discover/plan/status/verify stay read-only.  install/apply/join and the
# subnet/WAN-UDP/update/rollback/cleanup commands follow the transaction model:
# transaction model and the ownership boundaries: netifd never manages
# tailscale0, the dangerous stock init is only ever disabled (never stopped),
# firewall writes go pending-UCI -> fw4 check -> commit -> firewall reload,
# and the identity file is never printed.

set -f
umask 077

OPENWRT_SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/log.sh" || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/common.sh" || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/backup.sh" || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/version.sh" || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/state.sh" || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/net.sh" || exit 1
. "$OPENWRT_SCRIPT_DIR/lib/openwrt-ops.sh" || exit 1

OPENWRT_PROGRAM=tailscale-openwrt.sh
OPENWRT_COMMAND=
OPENWRT_POSITIONAL=
OPENWRT_LOGIN_SERVER=
OPENWRT_AUTH_KEY_FILE=
OPENWRT_AUTH_KEY_STDIN=0
OPENWRT_AUTH_KEY_TEMP=
OPENWRT_HOSTNAME=
OPENWRT_SERVICE_MODE=auto
OPENWRT_ACCEPT_DNS=false
OPENWRT_ACCEPT_ROUTES=false
OPENWRT_SUBNET=
OPENWRT_SUBNET_EXPLICIT=0
OPENWRT_ENABLE_SUBNET=false
OPENWRT_ALLOW_WAN_UDP=false
OPENWRT_ALLOW_WAN_UDP_EXPLICIT=0
OPENWRT_MIN_CLIENT_VERSION=
OPENWRT_PRIORITY=
OPENWRT_CHECK_INTERVAL=
OPENWRT_FAILURE_THRESHOLD=
OPENWRT_RECOVERY_THRESHOLD=
OPENWRT_FAILBACK=
OPENWRT_COOLDOWN=
OPENWRT_PROBE_TIMEOUT=
OPENWRT_HEALTH_PATH=
OPENWRT_DELETE_IDENTITY=0
OPENWRT_BACKUP_DIR=/root/tailscale-bootstrap-backups
BOOTSTRAP_ROOT=/
BOOTSTRAP_DRY_RUN=0
BOOTSTRAP_YES=0
BOOTSTRAP_UNDERSTAND=0
BOOTSTRAP_JSON=0
BOOTSTRAP_QUIET=0
BOOTSTRAP_VERBOSE=0

# A stdin-supplied auth key is materialized only for the duration of the
# login operation.  The cleanup trap also covers die/exit paths after the
# temporary file has been created.
trap 'openwrt_auth_key_cleanup' 0
trap 'openwrt_auth_key_cleanup; exit 130' INT
trap 'openwrt_auth_key_cleanup; exit 143' HUP TERM

openwrt_usage() {
    cat <<'EOF'
Usage:
  tailscale-openwrt.sh [global options] <command> [BACKUP_ID]

Read-only commands:
  discover                 Inspect packages, helpers, prefs, UCI and fw4 safely.
  plan                     Show a guarded plan; hard conflicts exit 2.
  status                   Check current daemon/control/firewall/UCI state.
  verify                   Read-only alias for status.
  backup                   Create a private timestamped snapshot; no service stop.

Mutating commands (backup -> validate -> apply -> verify, restore on failure):
  install                  Install the tailscale package, tailscale-core and
                           start the daemon (logged out); disables an unsafe
                           stock service without stopping it.
  apply                    Idempotent convergence: core service, fw4 zone
                           bound to device tailscale0, prefs via tailscale set.
  join                     Register with --login-server using --auth-key-file
                           or --auth-key-stdin (file: key, no --reset);
                           refuses a ControlURL switch.
  profile-list             Read-only: the managed profile list and failover
                           state from /etc/config/tailscale-bootstrap.
  profile-add              Register --login-server as an ADDITIONAL tailscale
                           profile (tailscale login; the active network is
                           switched back afterwards), using --auth-key-file or
                           --auth-key-stdin, and record it with --priority
                           (lower wins; default appends +10).
  profile-remove           Drop --login-server from the profile list; add
                           --delete-identity to also log that profile out.
  switch-to                Manually switch to --login-server (must already be
                           in the profile list); verified via ControlURL.
  enable-failover          Install + start the tailscale-failover watchdog:
                           probes every profile, switches when the active
                           network breaks (failure_threshold probes), optional
                           --failback true to prefer higher priority again.
  disable-failover         Stop + disable the watchdog; profiles are kept.
  enable-subnet            Advertise --subnet (or the discovered LAN CIDR) and
                           add IPv4 tailscale->lan forwarding after fw4 check.
  disable-subnet           Withdraw --subnet and remove the forwarding.
  allow-wan-udp [false]    Add/remove the narrow WAN UDP input rule.
  update                   Upgrade the tailscale package; restarts
                           tailscale-core only and verifies identity kept.
  rollback [BACKUP_ID]     Restore configs, identity and init scripts.
  cleanup                  Remove tailscale-core + failover watchdog + managed
                           firewall sections; keep identities and packages;
                           never stops stock service.
  purge-identity           Destructive: needs --yes-i-understand; backs up first.

Options:
  --login-server URL
  --auth-key-file FILE     Path is checked, never read to stdout or logs.
  --auth-key-stdin         Read one auth key line from stdin into a private
                           temporary file; mutually exclusive with --auth-key-file.
  --hostname NAME
  --service-mode auto|core|native
  --accept-dns true|false
  --accept-routes true|false
  --subnet CIDR
  --min-client-version X.Y.Z  Refuse to proceed when the installed client is
                              older than this (value comes from the Headscale
                              server release notes; never hardcoded).
  --enable-subnet[=true|false]
  --allow-wan-udp[=true|false]
  --priority N             profile-add: priority, lower wins (default +10).
  --delete-identity        profile-remove: also log the profile out.
  --check-interval SEC     enable-failover tuning (default 60, min 10).
  --failure-threshold N    failed probes before switching (default 3).
  --recovery-threshold N   ok probes before a profile is a candidate
                           (default 3).
  --failback true|false    switch back to higher priority once it recovers
                           (default false: stability first).
  --cooldown SEC           minimum seconds between two switches (default 300).
  --probe-timeout SEC      HTTPS probe timeout (default 5).
  --health-path PATH       control-server health path (default /health).
  --root DIR                Test/fixture root; default is /.
  --backup-dir DIR          Backup directory in the selected root namespace.
  --dry-run                 Accepted for CLI compatibility.
  --yes                     Accepted for future explicit operations.
  --yes-i-understand        Required confirmation for purge-identity.
  --json --quiet --verbose
  -h, --help

Hard boundaries:
  - no netifd interface for tailscale0 and no network reload, ever;
  - the stock /etc/init.d/tailscale is only disabled, never stopped/reloaded;
  - no tailscale up --reset; registered nodes converge via tailscale set;
  - firewall changes: pending UCI -> fw4 check -> commit -> firewall reload;
  - no exit node, no IPv6 subnet routing;
  - one active tailnet at a time: failover switches registered profiles
    serially and never runs two networks concurrently.
EOF
}

openwrt_parse_bool() {
    case "$1" in
        true|yes|1|on) printf 'true\n' ;;
        false|no|0|off) printf 'false\n' ;;
        *) die "invalid boolean: $1 (expected true or false)" ;;
    esac
}

openwrt_need_value() {
    [ "$#" -ge 2 ] || die "option $1 needs a value"
}

openwrt_validate_positive_int() {
    openwrt_vpi_name=$1
    openwrt_vpi_value=$2
    case "$openwrt_vpi_value" in
        ''|*[!0-9]*) die "$openwrt_vpi_name must be a positive integer: $openwrt_vpi_value" ;;
    esac
    [ "$openwrt_vpi_value" -ge 1 ] || die "$openwrt_vpi_name must be >= 1: $openwrt_vpi_value"
}

openwrt_validate_options() {
    case "$OPENWRT_SERVICE_MODE" in
        auto|core|native) ;;
        *) die "unsupported --service-mode: $OPENWRT_SERVICE_MODE" ;;
    esac
    case "$OPENWRT_LOGIN_SERVER" in
        '') ;;
        https://?*) OPENWRT_LOGIN_SERVER=$(bootstrap_normalize_url "$OPENWRT_LOGIN_SERVER") ;;
        *) die '--login-server must be an HTTPS URL' ;;
    esac
    if [ "$OPENWRT_AUTH_KEY_STDIN" = 1 ] && [ -n "$OPENWRT_AUTH_KEY_FILE" ]; then
        die '--auth-key-file and --auth-key-stdin are mutually exclusive'
    fi
    if [ -n "$OPENWRT_AUTH_KEY_FILE" ] && [ ! -f "$OPENWRT_AUTH_KEY_FILE" ]; then
        die "--auth-key-file is not a regular file: $OPENWRT_AUTH_KEY_FILE"
    fi
    if [ -n "$OPENWRT_AUTH_KEY_FILE" ]; then
        OPENWRT_AUTH_KEY_MODE=$(bootstrap_file_mode "$OPENWRT_AUTH_KEY_FILE")
        case "$OPENWRT_AUTH_KEY_MODE" in
            400|600) ;;
            *) die '--auth-key-file must be mode 0400 or 0600; key contents are never printed' ;;
        esac
    fi
    if [ -n "$OPENWRT_SUBNET" ]; then
        case "$OPENWRT_SUBNET" in
            *[!0-9./]*) die "unsupported subnet syntax: $OPENWRT_SUBNET" ;;
            */[0-9]|*/[1-2][0-9]|*/3[0-2]) ;;
            *) die "subnet must be an IPv4 CIDR such as 192.168.10.0/24: $OPENWRT_SUBNET" ;;
        esac
    fi
    [ -n "$OPENWRT_PRIORITY" ] && openwrt_validate_positive_int --priority "$OPENWRT_PRIORITY"
    [ -n "$OPENWRT_CHECK_INTERVAL" ] && openwrt_validate_positive_int --check-interval "$OPENWRT_CHECK_INTERVAL"
    [ -n "$OPENWRT_FAILURE_THRESHOLD" ] && openwrt_validate_positive_int --failure-threshold "$OPENWRT_FAILURE_THRESHOLD"
    [ -n "$OPENWRT_RECOVERY_THRESHOLD" ] && openwrt_validate_positive_int --recovery-threshold "$OPENWRT_RECOVERY_THRESHOLD"
    [ -n "$OPENWRT_COOLDOWN" ] && openwrt_validate_positive_int --cooldown "$OPENWRT_COOLDOWN"
    [ -n "$OPENWRT_PROBE_TIMEOUT" ] && openwrt_validate_positive_int --probe-timeout "$OPENWRT_PROBE_TIMEOUT"
    case "$OPENWRT_HEALTH_PATH" in
        '') ;;
        /*) ;;
        *) die "--health-path must start with / (got: $OPENWRT_HEALTH_PATH)" ;;
    esac
    case "$OPENWRT_FAILBACK" in
        ''|true|false) ;;
        *) die "--failback must be true or false (got: $OPENWRT_FAILBACK)" ;;
    esac
    case "$OPENWRT_BACKUP_DIR" in
        /*) ;;
        *) die '--backup-dir must be an absolute path in the selected root namespace' ;;
    esac
    case "$OPENWRT_BACKUP_DIR" in
        /|*/../*|*/..|..|.) die 'refusing unsafe --backup-dir' ;;
    esac
}

openwrt_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            discover|plan|status|verify|backup|install|apply|join|profile-list|profile-add|profile-remove|switch-to|enable-failover|disable-failover|update|enable-subnet|disable-subnet|allow-wan-udp|rollback|cleanup|purge-identity)
                [ -z "$OPENWRT_COMMAND" ] || die "multiple commands supplied: $OPENWRT_COMMAND and $1"
                OPENWRT_COMMAND=$1
                shift
                ;;
            --login-server)
                openwrt_need_value "$@"
                OPENWRT_LOGIN_SERVER=$2
                shift 2
                ;;
            --login-server=*) OPENWRT_LOGIN_SERVER=${1#*=}; shift ;;
            --auth-key-file)
                openwrt_need_value "$@"
                OPENWRT_AUTH_KEY_FILE=$2
                shift 2
                ;;
            --auth-key-file=*) OPENWRT_AUTH_KEY_FILE=${1#*=}; shift ;;
            --auth-key-stdin) OPENWRT_AUTH_KEY_STDIN=1; shift ;;
            --hostname)
                openwrt_need_value "$@"
                OPENWRT_HOSTNAME=$2
                shift 2
                ;;
            --hostname=*) OPENWRT_HOSTNAME=${1#*=}; shift ;;
            --service-mode)
                openwrt_need_value "$@"
                OPENWRT_SERVICE_MODE=$2
                shift 2
                ;;
            --service-mode=*) OPENWRT_SERVICE_MODE=${1#*=}; shift ;;
            --accept-dns)
                openwrt_need_value "$@"
                OPENWRT_ACCEPT_DNS=$(openwrt_parse_bool "$2")
                shift 2
                ;;
            --accept-dns=*) OPENWRT_ACCEPT_DNS=$(openwrt_parse_bool "${1#*=}"); shift ;;
            --accept-routes)
                openwrt_need_value "$@"
                OPENWRT_ACCEPT_ROUTES=$(openwrt_parse_bool "$2")
                shift 2
                ;;
            --accept-routes=*) OPENWRT_ACCEPT_ROUTES=$(openwrt_parse_bool "${1#*=}"); shift ;;
            --subnet)
                openwrt_need_value "$@"
                OPENWRT_SUBNET=$2
                OPENWRT_SUBNET_EXPLICIT=1
                shift 2
                ;;
            --subnet=*) OPENWRT_SUBNET=${1#*=}; OPENWRT_SUBNET_EXPLICIT=1; shift ;;
            --min-client-version)
                openwrt_need_value "$@"
                OPENWRT_MIN_CLIENT_VERSION=$2
                shift 2
                ;;
            --min-client-version=*) OPENWRT_MIN_CLIENT_VERSION=${1#*=}; shift ;;
            --enable-subnet)
                if [ "$#" -ge 2 ]; then
                    case "$2" in
                        true|yes|1|on|false|no|0|off)
                            OPENWRT_ENABLE_SUBNET=$(openwrt_parse_bool "$2")
                            shift 2
                            ;;
                        *) OPENWRT_ENABLE_SUBNET=true; shift ;;
                    esac
                else
                    OPENWRT_ENABLE_SUBNET=true
                    shift
                fi
                ;;
            --enable-subnet=*) OPENWRT_ENABLE_SUBNET=$(openwrt_parse_bool "${1#*=}"); shift ;;
            --allow-wan-udp)
                OPENWRT_ALLOW_WAN_UDP_EXPLICIT=1
                if [ "$#" -ge 2 ]; then
                    case "$2" in
                        true|yes|1|on|false|no|0|off)
                            OPENWRT_ALLOW_WAN_UDP=$(openwrt_parse_bool "$2")
                            shift 2
                            ;;
                        *) OPENWRT_ALLOW_WAN_UDP=true; shift ;;
                    esac
                else
                    OPENWRT_ALLOW_WAN_UDP=true
                    shift
                fi
                ;;
            --allow-wan-udp=*) OPENWRT_ALLOW_WAN_UDP_EXPLICIT=1; OPENWRT_ALLOW_WAN_UDP=$(openwrt_parse_bool "${1#*=}"); shift ;;
            --priority)
                openwrt_need_value "$@"
                OPENWRT_PRIORITY=$2
                shift 2
                ;;
            --priority=*) OPENWRT_PRIORITY=${1#*=}; shift ;;
            --delete-identity) OPENWRT_DELETE_IDENTITY=1; shift ;;
            --check-interval)
                openwrt_need_value "$@"
                OPENWRT_CHECK_INTERVAL=$2
                shift 2
                ;;
            --check-interval=*) OPENWRT_CHECK_INTERVAL=${1#*=}; shift ;;
            --failure-threshold)
                openwrt_need_value "$@"
                OPENWRT_FAILURE_THRESHOLD=$2
                shift 2
                ;;
            --failure-threshold=*) OPENWRT_FAILURE_THRESHOLD=${1#*=}; shift ;;
            --recovery-threshold)
                openwrt_need_value "$@"
                OPENWRT_RECOVERY_THRESHOLD=$2
                shift 2
                ;;
            --recovery-threshold=*) OPENWRT_RECOVERY_THRESHOLD=${1#*=}; shift ;;
            --failback)
                if [ "$#" -ge 2 ]; then
                    case "$2" in
                        true|yes|1|on|false|no|0|off) OPENWRT_FAILBACK=$(openwrt_parse_bool "$2"); shift 2 ;;
                        *) OPENWRT_FAILBACK=true; shift ;;
                    esac
                else
                    OPENWRT_FAILBACK=true
                    shift
                fi
                ;;
            --failback=*) OPENWRT_FAILBACK=$(openwrt_parse_bool "${1#*=}"); shift ;;
            --cooldown)
                openwrt_need_value "$@"
                OPENWRT_COOLDOWN=$2
                shift 2
                ;;
            --cooldown=*) OPENWRT_COOLDOWN=${1#*=}; shift ;;
            --probe-timeout)
                openwrt_need_value "$@"
                OPENWRT_PROBE_TIMEOUT=$2
                shift 2
                ;;
            --probe-timeout=*) OPENWRT_PROBE_TIMEOUT=${1#*=}; shift ;;
            --health-path)
                openwrt_need_value "$@"
                OPENWRT_HEALTH_PATH=$2
                shift 2
                ;;
            --health-path=*) OPENWRT_HEALTH_PATH=${1#*=}; shift ;;
            --root)
                openwrt_need_value "$@"
                BOOTSTRAP_ROOT=$2
                shift 2
                ;;
            --root=*) BOOTSTRAP_ROOT=${1#*=}; shift ;;
            --backup-dir)
                openwrt_need_value "$@"
                OPENWRT_BACKUP_DIR=$2
                shift 2
                ;;
            --backup-dir=*) OPENWRT_BACKUP_DIR=${1#*=}; shift ;;
            --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
            --yes) BOOTSTRAP_YES=1; shift ;;
            --yes-i-understand) BOOTSTRAP_UNDERSTAND=1; shift ;;
            --json) BOOTSTRAP_JSON=1; shift ;;
            --quiet) BOOTSTRAP_QUIET=1; shift ;;
            --verbose) BOOTSTRAP_VERBOSE=1; shift ;;
            -h|--help) openwrt_usage; exit 0 ;;
            --) shift; while [ "$#" -gt 0 ]; do die "unexpected argument after --: $1"; done ;;
            -*) die "unknown option: $1" ;;
            *)
                if [ -n "$OPENWRT_COMMAND" ]; then
                    [ -z "$OPENWRT_POSITIONAL" ] || die "multiple positional arguments: $OPENWRT_POSITIONAL and $1"
                    OPENWRT_POSITIONAL=$1
                    shift
                else
                    die "unknown command: $1"
                fi
                ;;
        esac
    done

    [ -n "$OPENWRT_COMMAND" ] || { openwrt_usage >&2; exit 2; }
    openwrt_validate_options
    BOOTSTRAP_ROOT=$(bootstrap_normalize_root "$BOOTSTRAP_ROOT") || die '--root is not an accessible directory'
}

openwrt_target_path() {
    bootstrap_root_path "$1"
}

openwrt_uci_option_from_file() {
    openwrt_uci_file=$1
    openwrt_uci_option=$2
    [ -r "$openwrt_uci_file" ] || return 1
    awk -v wanted="$openwrt_uci_option" '
        $1 == "option" && $2 == wanted {
            value=$0
            sub("^[[:space:]]*option[[:space:]]+" wanted "[[:space:]]+", "", value)
            gsub(/^['\''"]|['\''"]$/, "", value)
            print value
            exit
        }
    ' "$openwrt_uci_file" 2>/dev/null
}

openwrt_section_in_file() {
    openwrt_section_file=$1
    openwrt_section_type=$2
    openwrt_section_name=$3
    [ -r "$openwrt_section_file" ] || return 1
    awk -v wanted_type="$openwrt_section_type" -v wanted_name="$openwrt_section_name" '
        $1 == "config" && $2 == wanted_type {
            name=$3
            gsub(/^['\''"]|['\''"]$/, "", name)
            if (name == wanted_name) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$openwrt_section_file" 2>/dev/null
}

openwrt_scan_unsafe_file() {
    openwrt_scan_file=$1
    [ -r "$openwrt_scan_file" ] || return 0

    if grep -qF 'tailscale up --reset' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match tailscale-up-reset; fi
    if grep -qF '/etc/init.d/network reload' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match network-reload; fi
    if grep -qF 'uci set network.tailscale' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match uci-network-tailscale; fi
    if grep -qF 'uci commit network' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match uci-commit-network; fi
    if grep -qF 'tailscale_helper' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match helper-call; fi
    if grep -qF 'stop_instance' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match stop-instance; fi
    if grep -qF '/etc/init.d/tailscale stop' "$openwrt_scan_file" 2>/dev/null; then openwrt_record_unsafe_match stock-stop; fi
}

openwrt_record_unsafe_match() {
    openwrt_match_name=$1
    case " $OPENWRT_UNSAFE_MATCHES " in
        *" $openwrt_match_name "*) ;;
        *) OPENWRT_UNSAFE_MATCHES="$OPENWRT_UNSAFE_MATCHES $openwrt_match_name" ;;
    esac
}

openwrt_core_fingerprint() {
    openwrt_core_file=$1
    if [ ! -f "$openwrt_core_file" ]; then
        printf 'absent\n'
        return 0
    fi
    if grep -qF 'procd_open_instance main' "$openwrt_core_file" 2>/dev/null \
        && grep -qF '/usr/sbin/tailscaled' "$openwrt_core_file" 2>/dev/null \
        && grep -qF -e '--state /etc/tailscale/tailscaled.state' "$openwrt_core_file" 2>/dev/null \
        && grep -qF -e '--port 41641' "$openwrt_core_file" 2>/dev/null \
        && grep -qF 'TS_DEBUG_FIREWALL_MODE=nftables' "$openwrt_core_file" 2>/dev/null \
        && ! grep -qF '/etc/init.d/network reload' "$openwrt_core_file" 2>/dev/null \
        && ! grep -qF 'uci commit network' "$openwrt_core_file" 2>/dev/null; then
        printf 'verified\n'
    else
        printf 'unverified\n'
    fi
}

openwrt_failover_fingerprint() {
    openwrt_fo_file=$1
    if [ ! -f "$openwrt_fo_file" ]; then
        printf 'absent\n'
        return 0
    fi
    if grep -qF 'TS_FAILOVER_INIT_v1' "$openwrt_fo_file" 2>/dev/null \
        && grep -qF 'procd_open_instance failover' "$openwrt_fo_file" 2>/dev/null \
        && grep -qF '/usr/sbin/tailscale-failover' "$openwrt_fo_file" 2>/dev/null \
        && ! grep -qF '/etc/init.d/network reload' "$openwrt_fo_file" 2>/dev/null \
        && ! grep -qF 'uci commit network' "$openwrt_fo_file" 2>/dev/null; then
        printf 'verified\n'
    else
        printf 'unverified\n'
    fi
}

openwrt_watchdog_fingerprint() {
    openwrt_wd_file=$1
    if [ ! -f "$openwrt_wd_file" ]; then
        printf 'absent\n'
        return 0
    fi
    if grep -qF 'TS_FAILOVER_WATCHDOG_v1' "$openwrt_wd_file" 2>/dev/null \
        && grep -qF 'failover_probe' "$openwrt_wd_file" 2>/dev/null \
        && grep -qF 'tailscale switch' "$openwrt_wd_file" 2>/dev/null \
        && ! grep -qF 'tailscale up' "$openwrt_wd_file" 2>/dev/null \
        && ! grep -qF 'auth-key' "$openwrt_wd_file" 2>/dev/null \
        && ! grep -qF '/etc/init.d/network reload' "$openwrt_wd_file" 2>/dev/null \
        && ! grep -qF 'uci commit network' "$openwrt_wd_file" 2>/dev/null; then
        printf 'verified\n'
    else
        printf 'unverified\n'
    fi
}

openwrt_parse_prefs() {
    OPENWRT_PREFS_READABLE=no
    OPENWRT_CURRENT_CONTROL_URL=
    OPENWRT_CURRENT_ACCEPT_DNS=unknown
    OPENWRT_CURRENT_ACCEPT_ROUTES=unknown
    OPENWRT_CURRENT_ADVERTISE_ROUTES=
    OPENWRT_EXIT_NODE_RISK=no
    OPENWRT_TAILSCALE_STATE=unknown
    OPENWRT_TAILSCALE_IP4=unknown
    OPENWRT_PROFILE_STATE=unknown

    if ! bootstrap_command_exists tailscale; then
        return 0
    fi

    # `tailscale debug prefs` pretty-prints JSON across lines (arrays spread
    # their elements), so flatten before the single-line seds and bound the
    # AdvertiseRoutes capture to the first closing bracket.
    OPENWRT_PREFS_TEXT=$(tailscale debug prefs 2>/dev/null | tr '\n\t' '  ')
    [ -n "$OPENWRT_PREFS_TEXT" ] && OPENWRT_PREFS_READABLE=yes
    OPENWRT_CURRENT_CONTROL_URL=$(printf '%s\n' "$OPENWRT_PREFS_TEXT" | sed -n 's/.*"ControlURL"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
    [ -n "$OPENWRT_CURRENT_CONTROL_URL" ] || OPENWRT_CURRENT_CONTROL_URL=$(printf '%s\n' "$OPENWRT_PREFS_TEXT" | sed -n 's/.*ControlURL[[:space:]]*[:=][[:space:]]*\([^",[:space:]]*\).*/\1/p' | sed -n '1p')
    OPENWRT_CURRENT_CONTROL_URL=$(bootstrap_normalize_url "$OPENWRT_CURRENT_CONTROL_URL")

    OPENWRT_CURRENT_ACCEPT_DNS=$(printf '%s\n' "$OPENWRT_PREFS_TEXT" | sed -n 's/.*"CorpDNS"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | sed -n '1p')
    [ -n "$OPENWRT_CURRENT_ACCEPT_DNS" ] || OPENWRT_CURRENT_ACCEPT_DNS=unknown
    OPENWRT_CURRENT_ACCEPT_ROUTES=$(printf '%s\n' "$OPENWRT_PREFS_TEXT" | sed -n 's/.*"RouteAll"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | sed -n '1p')
    [ -n "$OPENWRT_CURRENT_ACCEPT_ROUTES" ] || OPENWRT_CURRENT_ACCEPT_ROUTES=unknown
    OPENWRT_CURRENT_ADVERTISE_ROUTES=$(printf '%s\n' "$OPENWRT_PREFS_TEXT" | sed -n 's/.*"AdvertiseRoutes"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | sed -n '1p' | tr -d '"' | tr ',' ' ' | awk '{$1=$1; print}')
    case "$OPENWRT_CURRENT_ADVERTISE_ROUTES" in
        *0.0.0.0/0*|*::/0*) OPENWRT_EXIT_NODE_RISK=yes ;;
    esac
    if printf '%s\n' "$OPENWRT_PREFS_TEXT" | grep -qF '0.0.0.0/0' 2>/dev/null || printf '%s\n' "$OPENWRT_PREFS_TEXT" | grep -qF '::/0' 2>/dev/null; then
        OPENWRT_EXIT_NODE_RISK=yes
    fi
    OPENWRT_EXIT_NODE_ID=$(printf '%s\n' "$OPENWRT_PREFS_TEXT" | sed -n 's/.*"ExitNodeID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
    [ -n "$OPENWRT_EXIT_NODE_ID" ] && OPENWRT_EXIT_NODE_RISK=yes
    if bootstrap_active_config_lines "$OPENWRT_CONFIG_TAILSCALE" | grep -qF "option advertise_exit_node '1'" 2>/dev/null || \
        bootstrap_active_config_lines "$OPENWRT_CONFIG_TAILSCALE" | grep -qF -- '--advertise-exit-node' 2>/dev/null; then
        OPENWRT_EXIT_NODE_RISK=yes
    fi

    OPENWRT_STATUS_JSON=$(tailscale status --json 2>/dev/null)
    OPENWRT_TAILSCALE_STATE=$(printf '%s\n' "$OPENWRT_STATUS_JSON" | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
    [ -n "$OPENWRT_TAILSCALE_STATE" ] || OPENWRT_TAILSCALE_STATE=unknown
    OPENWRT_TAILSCALE_IP4=$(tailscale ip -4 2>/dev/null | sed -n '1p')
    [ -n "$OPENWRT_TAILSCALE_IP4" ] || OPENWRT_TAILSCALE_IP4=unknown

    OPENWRT_SWITCH_LIST=$(tailscale switch --list 2>/dev/null)
    if [ -n "$OPENWRT_SWITCH_LIST" ]; then
        OPENWRT_PROFILE_STATE=present
    else
        OPENWRT_PROFILE_STATE=none-or-unavailable
    fi
}

openwrt_socket_state() {
    openwrt_socket_port=$1
    openwrt_socket_data=$2
    [ -n "$openwrt_socket_data" ] || { printf 'unknown\n'; return 0; }
    printf '%s\n' "$openwrt_socket_data" | awk -v wanted_port="$openwrt_socket_port" '
        NR == 1 && $1 ~ /Netid|State/ { next }
        {
            address=$4
            if ($1 ~ /^(tcp|udp|tcp6|udp6)$/ && $2 ~ /^(LISTEN|UNCONN|ESTAB|TIME-WAIT)$/) address=$5
            if (address !~ (":" wanted_port "$")) next
            found=1
            if (address ~ /^0\.0\.0\.0:/ || address ~ /^\*:/ || address ~ /^\[::\]:/ || address ~ /^:::/) public=1
        }
        END {
            if (public) print "public"
            else if (found) print "present"
            else print "free"
        }
    '
}

openwrt_collect_facts() {
    OPENWRT_ETC_TAILSCALE=$(openwrt_target_path /etc/tailscale)
    OPENWRT_TS_STATE=$(openwrt_target_path /etc/tailscale/tailscaled.state)
    OPENWRT_INIT_TAILSCALE=$(openwrt_target_path /etc/init.d/tailscale)
    OPENWRT_INIT_CORE=$(openwrt_target_path /etc/init.d/tailscale-core)
    OPENWRT_INIT_FAILOVER=$(openwrt_target_path /etc/init.d/tailscale-failover)
    OPENWRT_WATCHDOG_FAILOVER=$(openwrt_target_path /usr/sbin/tailscale-failover)
    OPENWRT_CONFIG_TAILSCALE=$(openwrt_target_path /etc/config/tailscale)
    OPENWRT_CONFIG_BOOTSTRAP=$(openwrt_target_path /etc/config/tailscale-bootstrap)
    OPENWRT_CONFIG_FIREWALL=$(openwrt_target_path /etc/config/firewall)
    OPENWRT_CONFIG_NETWORK=$(openwrt_target_path /etc/config/network)
    OPENWRT_HELPER=$(openwrt_target_path /usr/sbin/tailscale_helper)
    OPENWRT_RC_DIR=$(openwrt_target_path /etc/rc.d)
    OPENWRT_TUN=$(openwrt_target_path /dev/net/tun)
    OPENWRT_PROC_IPV4_FORWARD=$(openwrt_target_path /proc/sys/net/ipv4/ip_forward)
    OPENWRT_PROC_IPV6_FORWARD=$(openwrt_target_path /proc/sys/net/ipv6/conf/all/forwarding)

    OPENWRT_TAILSCALE_DIR_PRESENT=no
    OPENWRT_STATE_PRESENT=no
    [ -d "$OPENWRT_ETC_TAILSCALE" ] && OPENWRT_TAILSCALE_DIR_PRESENT=yes
    [ -f "$OPENWRT_TS_STATE" ] && OPENWRT_STATE_PRESENT=yes
    OPENWRT_INIT_CORE_PRESENT=no
    [ -f "$OPENWRT_INIT_CORE" ] && OPENWRT_INIT_CORE_PRESENT=yes
    OPENWRT_CORE_FINGERPRINT=$(openwrt_core_fingerprint "$OPENWRT_INIT_CORE")
    OPENWRT_INIT_FAILOVER_PRESENT=no
    [ -f "$OPENWRT_INIT_FAILOVER" ] && OPENWRT_INIT_FAILOVER_PRESENT=yes
    OPENWRT_FAILOVER_FINGERPRINT=$(openwrt_failover_fingerprint "$OPENWRT_INIT_FAILOVER")
    OPENWRT_WATCHDOG_FAILOVER_PRESENT=no
    [ -f "$OPENWRT_WATCHDOG_FAILOVER" ] && OPENWRT_WATCHDOG_FAILOVER_PRESENT=yes
    OPENWRT_WATCHDOG_FINGERPRINT=$(openwrt_watchdog_fingerprint "$OPENWRT_WATCHDOG_FAILOVER")
    OPENWRT_STOCK_INIT_PRESENT=no
    [ -f "$OPENWRT_INIT_TAILSCALE" ] && OPENWRT_STOCK_INIT_PRESENT=yes
    OPENWRT_HELPER_PRESENT=no
    [ -f "$OPENWRT_HELPER" ] && OPENWRT_HELPER_PRESENT=yes
    OPENWRT_TAILSCALE_CONFIG_PRESENT=no
    [ -f "$OPENWRT_CONFIG_TAILSCALE" ] && OPENWRT_TAILSCALE_CONFIG_PRESENT=yes

    OPENWRT_PACKAGE_MANAGER=none
    if bootstrap_command_exists opkg; then OPENWRT_PACKAGE_MANAGER=opkg; elif bootstrap_command_exists apk; then OPENWRT_PACKAGE_MANAGER=apk; fi
    OPENWRT_UCI_PRESENT=no
    bootstrap_command_exists uci && OPENWRT_UCI_PRESENT=yes
    OPENWRT_TAILSCALE_PACKAGE=unknown
    OPENWRT_LUCI_PACKAGE=unknown
    if [ "$OPENWRT_PACKAGE_MANAGER" = opkg ]; then
        if opkg status tailscale 2>/dev/null | grep -qF 'Status: install ok installed'; then OPENWRT_TAILSCALE_PACKAGE=installed; else OPENWRT_TAILSCALE_PACKAGE=absent; fi
        if opkg status luci-app-tailscale 2>/dev/null | grep -qF 'Status: install ok installed'; then OPENWRT_LUCI_PACKAGE=installed; else OPENWRT_LUCI_PACKAGE=absent; fi
    elif [ "$OPENWRT_PACKAGE_MANAGER" = apk ]; then
        if apk info -e tailscale >/dev/null 2>&1; then OPENWRT_TAILSCALE_PACKAGE=installed; else OPENWRT_TAILSCALE_PACKAGE=absent; fi
        if apk info -e luci-app-tailscale >/dev/null 2>&1; then OPENWRT_LUCI_PACKAGE=installed; else OPENWRT_LUCI_PACKAGE=absent; fi
    fi

    OPENWRT_TAILSCALE_VERSION=absent
    if bootstrap_command_exists tailscale; then
        OPENWRT_TAILSCALE_VERSION=$(bootstrap_capture_first_line tailscale version)
        [ -n "$OPENWRT_TAILSCALE_VERSION" ] || OPENWRT_TAILSCALE_VERSION=present-version-unknown
    fi
    OPENWRT_TAILSCALED_VERSION=absent
    if bootstrap_command_exists tailscaled; then
        OPENWRT_TAILSCALED_VERSION=$(bootstrap_capture_first_line tailscaled --version)
        [ -n "$OPENWRT_TAILSCALED_VERSION" ] || OPENWRT_TAILSCALED_VERSION=present-version-unknown
    fi

    OPENWRT_BOARD_MODEL=unknown
    OPENWRT_BOARD_RELEASE=unknown
    if bootstrap_command_exists ubus; then
        OPENWRT_BOARD_JSON=$(ubus call system board 2>/dev/null)
        OPENWRT_BOARD_MODEL=$(printf '%s\n' "$OPENWRT_BOARD_JSON" | sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')
        OPENWRT_BOARD_RELEASE=$(printf '%s\n' "$OPENWRT_BOARD_JSON" | sed -n 's/.*"release"[[:space:]]*:[[:space:]]*{.*/release-object/p' | sed -n '1p')
    fi
    [ -n "$OPENWRT_BOARD_MODEL" ] || OPENWRT_BOARD_MODEL=unknown
    [ -n "$OPENWRT_BOARD_RELEASE" ] || OPENWRT_BOARD_RELEASE=unknown

    OPENWRT_TUN_PRESENT=no
    [ -c "$OPENWRT_TUN" ] && OPENWRT_TUN_PRESENT=yes
    OPENWRT_FW4_PRESENT=no
    OPENWRT_NFT_PRESENT=no
    bootstrap_command_exists fw4 && OPENWRT_FW4_PRESENT=yes
    bootstrap_command_exists nft && OPENWRT_NFT_PRESENT=yes

    OPENWRT_IPV4_FORWARD=unknown
    OPENWRT_IPV6_FORWARD=unknown
    if [ -r "$OPENWRT_PROC_IPV4_FORWARD" ]; then OPENWRT_IPV4_FORWARD=$(bootstrap_read_first_line "$OPENWRT_PROC_IPV4_FORWARD"); fi
    if [ -r "$OPENWRT_PROC_IPV6_FORWARD" ]; then OPENWRT_IPV6_FORWARD=$(bootstrap_read_first_line "$OPENWRT_PROC_IPV6_FORWARD"); fi
    if bootstrap_command_exists sysctl && [ "$BOOTSTRAP_ROOT" = / ]; then
        OPENWRT_IPV4_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null | sed -n '1p')
        OPENWRT_IPV6_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null | sed -n '1p')
    fi
    [ -n "$OPENWRT_IPV4_FORWARD" ] || OPENWRT_IPV4_FORWARD=unknown
    [ -n "$OPENWRT_IPV6_FORWARD" ] || OPENWRT_IPV6_FORWARD=unknown

    OPENWRT_UNSAFE_MATCHES=
    openwrt_scan_unsafe_file "$OPENWRT_INIT_TAILSCALE"
    openwrt_scan_unsafe_file "$OPENWRT_HELPER"
    openwrt_scan_unsafe_file "$OPENWRT_CONFIG_TAILSCALE"
    if [ -n "$OPENWRT_UNSAFE_MATCHES" ]; then OPENWRT_UNSAFE_LUCI_HELPER=yes; else OPENWRT_UNSAFE_LUCI_HELPER=no; fi

    OPENWRT_STOCK_SERVICE_ENABLED=unknown
    OPENWRT_CORE_SERVICE_ENABLED=unknown
    if [ -d "$OPENWRT_RC_DIR" ]; then
        if find "$OPENWRT_RC_DIR" \( -type l -o -type f \) -print 2>/dev/null | grep -q '/S[0-9][0-9]tailscale$'; then
            OPENWRT_STOCK_SERVICE_ENABLED=yes
        else
            OPENWRT_STOCK_SERVICE_ENABLED=no
        fi
        if find "$OPENWRT_RC_DIR" \( -type l -o -type f \) -print 2>/dev/null | grep -q '/S[0-9][0-9]tailscale-core$'; then
            OPENWRT_CORE_SERVICE_ENABLED=yes
        else
            OPENWRT_CORE_SERVICE_ENABLED=no
        fi
        if find "$OPENWRT_RC_DIR" \( -type l -o -type f \) -print 2>/dev/null | grep -q '/S[0-9][0-9]tailscale-failover$'; then
            OPENWRT_FAILOVER_SERVICE_ENABLED=yes
        else
            OPENWRT_FAILOVER_SERVICE_ENABLED=no
        fi
    fi

    openwrt_load_profiles

    OPENWRT_CONFIG_LOGIN_SERVER=
    if [ "$OPENWRT_TAILSCALE_CONFIG_PRESENT" = yes ]; then
        OPENWRT_CONFIG_LOGIN_SERVER=$(openwrt_uci_option_from_file "$OPENWRT_CONFIG_TAILSCALE" login_server)
    fi
    [ -n "$OPENWRT_LOGIN_SERVER" ] || OPENWRT_LOGIN_SERVER=$OPENWRT_CONFIG_LOGIN_SERVER

    openwrt_parse_prefs
    [ -n "$OPENWRT_CURRENT_CONTROL_URL" ] || OPENWRT_CURRENT_CONTROL_URL=unknown

    OPENWRT_CURRENT_NETWORK_CHANGES=unknown
    OPENWRT_CURRENT_FIREWALL_CHANGES=unknown
    if bootstrap_command_exists uci; then
        OPENWRT_CURRENT_NETWORK_CHANGES=$(uci changes network 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        OPENWRT_CURRENT_FIREWALL_CHANGES=$(uci changes firewall 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        [ -n "$OPENWRT_CURRENT_NETWORK_CHANGES" ] || OPENWRT_CURRENT_NETWORK_CHANGES=clean
        [ -n "$OPENWRT_CURRENT_FIREWALL_CHANGES" ] || OPENWRT_CURRENT_FIREWALL_CHANGES=clean
    fi

    OPENWRT_NETWORK_TS_PRESENT=no
    OPENWRT_FIREWALL_TS_PRESENT=no
    OPENWRT_FIREWALL_TS_TO_LAN_PRESENT=no
    OPENWRT_FIREWALL_TS_WAN_UDP_PRESENT=no
    if bootstrap_command_exists uci; then
        uci -q get network.tailscale >/dev/null 2>&1 && OPENWRT_NETWORK_TS_PRESENT=yes
        uci -q get firewall.tailscale >/dev/null 2>&1 && OPENWRT_FIREWALL_TS_PRESENT=yes
        uci -q get firewall.ts_to_lan >/dev/null 2>&1 && OPENWRT_FIREWALL_TS_TO_LAN_PRESENT=yes
        uci -q get firewall.ts_wan_udp >/dev/null 2>&1 && OPENWRT_FIREWALL_TS_WAN_UDP_PRESENT=yes
    else
        openwrt_section_in_file "$OPENWRT_CONFIG_NETWORK" interface tailscale && OPENWRT_NETWORK_TS_PRESENT=yes
        openwrt_section_in_file "$OPENWRT_CONFIG_FIREWALL" zone tailscale && OPENWRT_FIREWALL_TS_PRESENT=yes
        openwrt_section_in_file "$OPENWRT_CONFIG_FIREWALL" forwarding ts_to_lan && OPENWRT_FIREWALL_TS_TO_LAN_PRESENT=yes
        openwrt_section_in_file "$OPENWRT_CONFIG_FIREWALL" rule ts_wan_udp && OPENWRT_FIREWALL_TS_WAN_UDP_PRESENT=yes
    fi

    OPENWRT_TS0_PRESENT=no
    OPENWRT_TS0_IP4=unknown
    if bootstrap_command_exists ip; then
        ip link show tailscale0 >/dev/null 2>&1 && OPENWRT_TS0_PRESENT=yes
        OPENWRT_TS0_IP4=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | sed -n '1p')
    fi
    [ -e "$(openwrt_target_path /sys/class/net/tailscale0)" ] && OPENWRT_TS0_PRESENT=yes
    [ -n "$OPENWRT_TS0_IP4" ] || OPENWRT_TS0_IP4=unknown

    OPENWRT_FIREWALL_DEVICE=unknown
    if [ "$OPENWRT_FW4_PRESENT" = yes ]; then
        OPENWRT_FIREWALL_DEVICE=$(fw4 device tailscale0 2>/dev/null | sed -n '1p')
        [ -n "$OPENWRT_FIREWALL_DEVICE" ] || OPENWRT_FIREWALL_DEVICE=none
    fi

    OPENWRT_LAN_ROUTE=unknown
    if bootstrap_command_exists ip; then
        OPENWRT_LAN_ROUTE=$(ip -4 route show scope link 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1; exit}')
    fi
    [ -n "$OPENWRT_LAN_ROUTE" ] || OPENWRT_LAN_ROUTE=unknown

    OPENWRT_TS_PORT=41641
    if [ "$OPENWRT_TAILSCALE_CONFIG_PRESENT" = yes ]; then
        OPENWRT_CONFIG_PORT=$(openwrt_uci_option_from_file "$OPENWRT_CONFIG_TAILSCALE" port)
        [ -n "$OPENWRT_CONFIG_PORT" ] && OPENWRT_TS_PORT=$OPENWRT_CONFIG_PORT
    fi
    OPENWRT_SOCKETS=
    if bootstrap_command_exists ss; then OPENWRT_SOCKETS=$(ss -lun 2>/dev/null); fi
    OPENWRT_UDP_TS_PORT=$(openwrt_socket_state "$OPENWRT_TS_PORT" "$OPENWRT_SOCKETS")
}

openwrt_effective_values() {
    OPENWRT_EFFECTIVE_LOGIN_SERVER=${OPENWRT_LOGIN_SERVER:-$OPENWRT_CURRENT_CONTROL_URL}
    OPENWRT_EFFECTIVE_LOGIN_SERVER=$(bootstrap_normalize_url "$OPENWRT_EFFECTIVE_LOGIN_SERVER")
    if [ "$OPENWRT_SERVICE_MODE" = auto ]; then
        OPENWRT_EFFECTIVE_SERVICE_MODE=core
    else
        OPENWRT_EFFECTIVE_SERVICE_MODE=$OPENWRT_SERVICE_MODE
    fi
}

openwrt_print_text_discover() {
    printf 'OpenWrt Tailscale discovery (read-only)\n'
    printf '  root: %s\n' "$BOOTSTRAP_ROOT"
    printf '  board/model: %s\n' "$OPENWRT_BOARD_MODEL"
    printf '  package manager/UCI: %s/%s\n' "$OPENWRT_PACKAGE_MANAGER" "$OPENWRT_UCI_PRESENT"
    printf '  tailscale package/client/daemon: %s/%s/%s\n' "$OPENWRT_TAILSCALE_PACKAGE" "$OPENWRT_TAILSCALE_VERSION" "$OPENWRT_TAILSCALED_VERSION"
    printf '  luci-app-tailscale: %s\n' "$OPENWRT_LUCI_PACKAGE"
    printf '  TUN/fw4/nft: %s/%s/%s\n' "$OPENWRT_TUN_PRESENT" "$OPENWRT_FW4_PRESENT" "$OPENWRT_NFT_PRESENT"
    printf '  IPv4/IPv6 forwarding: %s/%s\n' "$OPENWRT_IPV4_FORWARD" "$OPENWRT_IPV6_FORWARD"
    printf '  state dir/state file: %s/%s\n' "$OPENWRT_TAILSCALE_DIR_PRESENT" "$OPENWRT_STATE_PRESENT"
    printf '  tailscale-core present/enabled/fingerprint: %s/%s/%s; stock init present/enabled: %s/%s\n' "$OPENWRT_INIT_CORE_PRESENT" "$OPENWRT_CORE_SERVICE_ENABLED" "$OPENWRT_CORE_FINGERPRINT" "$OPENWRT_STOCK_INIT_PRESENT" "$OPENWRT_STOCK_SERVICE_ENABLED"
    printf '  dangerous LuCI/helper fingerprint: %s (%s)\n' "$OPENWRT_UNSAFE_LUCI_HELPER" "${OPENWRT_UNSAFE_MATCHES# }"
    printf '  current ControlURL: %s\n' "$OPENWRT_CURRENT_CONTROL_URL"
    printf '  backend state/IP4: %s/%s\n' "$OPENWRT_TAILSCALE_STATE" "$OPENWRT_TAILSCALE_IP4"
    printf '  prefs readable/profiles: %s/%s\n' "$OPENWRT_PREFS_READABLE" "$OPENWRT_PROFILE_STATE"
    printf '  advertise routes: %s\n' "${OPENWRT_CURRENT_ADVERTISE_ROUTES:-none}"
    printf '  exit-node risk: %s\n' "$OPENWRT_EXIT_NODE_RISK"
    printf '  tailscale0 present/IP4: %s/%s\n' "$OPENWRT_TS0_PRESENT" "$OPENWRT_TS0_IP4"
    printf '  fw4 device tailscale0: %s\n' "$OPENWRT_FIREWALL_DEVICE"
    printf '  LAN route observed: %s\n' "$OPENWRT_LAN_ROUTE"
    printf '  UCI network/firewall pending: %s/%s\n' "$OPENWRT_CURRENT_NETWORK_CHANGES" "$OPENWRT_CURRENT_FIREWALL_CHANGES"
    printf '  UCI sections network.tailscale/firewall.tailscale/ts_to_lan/ts_wan_udp: %s/%s/%s/%s\n' \
        "$OPENWRT_NETWORK_TS_PRESENT" "$OPENWRT_FIREWALL_TS_PRESENT" "$OPENWRT_FIREWALL_TS_TO_LAN_PRESENT" "$OPENWRT_FIREWALL_TS_WAN_UDP_PRESENT"
    printf '  UDP %s: %s\n' "$OPENWRT_TS_PORT" "$OPENWRT_UDP_TS_PORT"
    printf '  bootstrap profiles: %s (%s)\n' "$OPENWRT_PROFILE_COUNT" "${OPENWRT_PROFILE_URLS:-none}"
    printf '  failover enabled/service/fingerprint: %s/%s/%s\n' \
        "$OPENWRT_FAILOVER_ENABLED" "$OPENWRT_INIT_FAILOVER_PRESENT" "$OPENWRT_FAILOVER_FINGERPRINT"
}

openwrt_print_json_discover() {
    bootstrap_json_start
    bootstrap_json_field script "$OPENWRT_PROGRAM"
    bootstrap_json_field command discover
    bootstrap_json_field root "$BOOTSTRAP_ROOT"
    bootstrap_json_field board "$OPENWRT_BOARD_MODEL"
    bootstrap_json_field package_manager "$OPENWRT_PACKAGE_MANAGER"
    bootstrap_json_field uci "$OPENWRT_UCI_PRESENT"
    bootstrap_json_field tailscale_package "$OPENWRT_TAILSCALE_PACKAGE"
    bootstrap_json_field tailscale_version "$OPENWRT_TAILSCALE_VERSION"
    bootstrap_json_field tailscaled_version "$OPENWRT_TAILSCALED_VERSION"
    bootstrap_json_field luci_app_tailscale "$OPENWRT_LUCI_PACKAGE"
    bootstrap_json_field tun "$OPENWRT_TUN_PRESENT"
    bootstrap_json_field fw4 "$OPENWRT_FW4_PRESENT"
    bootstrap_json_field nft "$OPENWRT_NFT_PRESENT"
    bootstrap_json_field ipv4_forward "$OPENWRT_IPV4_FORWARD"
    bootstrap_json_field ipv6_forward "$OPENWRT_IPV6_FORWARD"
    bootstrap_json_field state_dir "$OPENWRT_TAILSCALE_DIR_PRESENT"
    bootstrap_json_field state_file "$OPENWRT_STATE_PRESENT"
    bootstrap_json_field core_service "$OPENWRT_INIT_CORE_PRESENT"
    bootstrap_json_field core_service_enabled "$OPENWRT_CORE_SERVICE_ENABLED"
    bootstrap_json_field core_fingerprint "$OPENWRT_CORE_FINGERPRINT"
    bootstrap_json_field stock_service_enabled "$OPENWRT_STOCK_SERVICE_ENABLED"
    bootstrap_json_field unsafe_luci_helper "$OPENWRT_UNSAFE_LUCI_HELPER"
    bootstrap_json_field unsafe_matches "${OPENWRT_UNSAFE_MATCHES# }"
    bootstrap_json_field control_url "$OPENWRT_CURRENT_CONTROL_URL"
    bootstrap_json_field backend_state "$OPENWRT_TAILSCALE_STATE"
    bootstrap_json_field tailscale_ip4 "$OPENWRT_TAILSCALE_IP4"
    bootstrap_json_field prefs_readable "$OPENWRT_PREFS_READABLE"
    bootstrap_json_field profiles "$OPENWRT_PROFILE_STATE"
    bootstrap_json_field advertise_routes "${OPENWRT_CURRENT_ADVERTISE_ROUTES:-none}"
    bootstrap_json_field exit_node_risk "$OPENWRT_EXIT_NODE_RISK"
    bootstrap_json_field tailscale0 "$OPENWRT_TS0_PRESENT"
    bootstrap_json_field tailscale0_ip4 "$OPENWRT_TS0_IP4"
    bootstrap_json_field fw4_device "$OPENWRT_FIREWALL_DEVICE"
    bootstrap_json_field lan_route "$OPENWRT_LAN_ROUTE"
    bootstrap_json_field network_changes "$OPENWRT_CURRENT_NETWORK_CHANGES"
    bootstrap_json_field firewall_changes "$OPENWRT_CURRENT_FIREWALL_CHANGES"
    bootstrap_json_field network_tailscale "$OPENWRT_NETWORK_TS_PRESENT"
    bootstrap_json_field firewall_tailscale "$OPENWRT_FIREWALL_TS_PRESENT"
    bootstrap_json_field firewall_ts_to_lan "$OPENWRT_FIREWALL_TS_TO_LAN_PRESENT"
    bootstrap_json_field firewall_ts_wan_udp "$OPENWRT_FIREWALL_TS_WAN_UDP_PRESENT"
    bootstrap_json_field udp_port_state "$OPENWRT_UDP_TS_PORT"
    bootstrap_json_field profile_count "$OPENWRT_PROFILE_COUNT"
    bootstrap_json_field profiles "${OPENWRT_PROFILE_URLS:-none}"
    bootstrap_json_field failover_enabled "$OPENWRT_FAILOVER_ENABLED"
    bootstrap_json_field failover_service "$OPENWRT_INIT_FAILOVER_PRESENT"
    bootstrap_json_field failover_fingerprint "$OPENWRT_FAILOVER_FINGERPRINT"
    bootstrap_json_end
}

openwrt_print_discover() {
    openwrt_collect_facts
    if [ "$BOOTSTRAP_JSON" = 1 ]; then openwrt_print_json_discover; else openwrt_print_text_discover; fi
}

openwrt_compute_conflicts() {
    # Shared hard guards for plan and every mutating command (safety rules, single network).
    openwrt_conflicts_mode=${1:-plan}
    openwrt_plan_blocked=0
    openwrt_block_reasons=

    if [ -z "$OPENWRT_EFFECTIVE_LOGIN_SERVER" ] || [ "$OPENWRT_EFFECTIVE_LOGIN_SERVER" = unknown ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons missing-login-server"
    elif ! bootstrap_is_https_url "$OPENWRT_EFFECTIVE_LOGIN_SERVER"; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons login-server-not-https"
    fi
    if [ "$OPENWRT_CURRENT_CONTROL_URL" != unknown ] && [ -n "$OPENWRT_CURRENT_CONTROL_URL" ] && [ -n "$OPENWRT_LOGIN_SERVER" ] && [ "$OPENWRT_CURRENT_CONTROL_URL" != "$OPENWRT_LOGIN_SERVER" ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons different-existing-controlurl"
    fi
    if [ "$OPENWRT_TUN_PRESENT" != yes ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons tun-missing"
    fi
    if [ "$OPENWRT_EFFECTIVE_SERVICE_MODE" = core ] && { [ "$OPENWRT_FW4_PRESENT" != yes ] || [ "$OPENWRT_NFT_PRESENT" != yes ]; }; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons fw4-nftables-baseline-not-confirmed"
    fi
    if [ "$OPENWRT_SERVICE_MODE" = native ] && [ "$OPENWRT_UNSAFE_LUCI_HELPER" = yes ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons unsafe-native-luci-helper"
    fi
    if [ "$OPENWRT_SERVICE_MODE" = native ] && [ "$OPENWRT_STOCK_INIT_PRESENT" != yes ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons native-init-not-found"
    fi
    if [ "$OPENWRT_UCI_PRESENT" != yes ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons uci-not-found"
    fi
    if [ "$OPENWRT_EFFECTIVE_SERVICE_MODE" = core ] && [ "$OPENWRT_CORE_FINGERPRINT" = unverified ]; then
        # plan reports it; mutating commands repair it from the verified
        # template instead of blocking, backing up the file first.
        if [ "$openwrt_conflicts_mode" = plan ]; then
            openwrt_plan_blocked=1
            openwrt_block_reasons="$openwrt_block_reasons unverified-tailscale-core"
        else
            log_warn 'tailscale-core fingerprint mismatch; it will be restored from the verified template (with a backup)'
        fi
    fi
    if [ "$OPENWRT_NETWORK_TS_PRESENT" = yes ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons existing-network-tailscale-section"
    fi
    if [ "$OPENWRT_CURRENT_NETWORK_CHANGES" != clean ] && [ "$OPENWRT_CURRENT_NETWORK_CHANGES" != unknown ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons pending-network-uci-changes"
    fi
    if [ "$OPENWRT_CURRENT_FIREWALL_CHANGES" != clean ] && [ "$OPENWRT_CURRENT_FIREWALL_CHANGES" != unknown ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons pending-firewall-uci-changes"
    fi
    if [ "$OPENWRT_EXIT_NODE_RISK" = yes ]; then
        openwrt_plan_blocked=1
        openwrt_block_reasons="$openwrt_block_reasons exit-node-or-default-route-risk"
    fi
    # Failover invariants: a half-installed or tampered watchdog must block
    # (and be repaired via enable-failover), never run half-configured.
    if [ "${openwrt_conflicts_skip_failover:-0}" != 1 ] && [ "$OPENWRT_FAILOVER_ENABLED" = yes ]; then
        if [ "$OPENWRT_INIT_FAILOVER_PRESENT" != yes ]; then
            openwrt_plan_blocked=1
            openwrt_block_reasons="$openwrt_block_reasons failover-service-missing"
        elif [ "$OPENWRT_FAILOVER_FINGERPRINT" != verified ]; then
            openwrt_plan_blocked=1
            openwrt_block_reasons="$openwrt_block_reasons failover-unverified-fingerprint"
        elif [ "$OPENWRT_WATCHDOG_FAILOVER_PRESENT" != yes ] || [ "$OPENWRT_WATCHDOG_FINGERPRINT" != verified ]; then
            openwrt_plan_blocked=1
            openwrt_block_reasons="$openwrt_block_reasons failover-watchdog-missing-or-unverified"
        elif [ "$OPENWRT_PROFILE_COUNT" -lt 2 ]; then
            openwrt_plan_blocked=1
            openwrt_block_reasons="$openwrt_block_reasons failover-under-two-profiles"
        fi
    fi
}

openwrt_plan() {
    openwrt_collect_facts
    openwrt_effective_values
    openwrt_compute_conflicts plan

    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$OPENWRT_PROGRAM"
        bootstrap_json_field command plan
        bootstrap_json_field effective_service_mode "$OPENWRT_EFFECTIVE_SERVICE_MODE"
        bootstrap_json_field login_server "${OPENWRT_EFFECTIVE_LOGIN_SERVER:-unknown}"
        bootstrap_json_field current_control_url "$OPENWRT_CURRENT_CONTROL_URL"
        bootstrap_json_field profile_count "$OPENWRT_PROFILE_COUNT"
        bootstrap_json_field failover_enabled "$OPENWRT_FAILOVER_ENABLED"
        bootstrap_json_field blocked_reasons "${openwrt_block_reasons# }"
        if [ "$openwrt_plan_blocked" -eq 1 ]; then bootstrap_json_bool_field blocked true; else bootstrap_json_bool_field blocked false; fi
        bootstrap_json_field mutates_system no
        bootstrap_json_field network_reload no
        bootstrap_json_field exit_node false
        bootstrap_json_end
    else
        printf 'OpenWrt Tailscale plan (read-only; no changes made)\n'
        printf 'Detected:\n'
        printf '  service requested/effective: %s/%s\n' "$OPENWRT_SERVICE_MODE" "$OPENWRT_EFFECTIVE_SERVICE_MODE"
        printf '  requested/current ControlURL: %s/%s\n' "${OPENWRT_EFFECTIVE_LOGIN_SERVER:-unknown}" "$OPENWRT_CURRENT_CONTROL_URL"
        printf '  bootstrap profiles: %s (%s); failover enabled: %s\n' \
            "$OPENWRT_PROFILE_COUNT" "${OPENWRT_PROFILE_URLS:-none}" "$OPENWRT_FAILOVER_ENABLED"
        printf '  package/tun/fw4/nft: %s/%s/%s/%s\n' "$OPENWRT_TAILSCALE_PACKAGE" "$OPENWRT_TUN_PRESENT" "$OPENWRT_FW4_PRESENT" "$OPENWRT_NFT_PRESENT"
        printf '  dangerous helper: %s (%s)\n' "$OPENWRT_UNSAFE_LUCI_HELPER" "${OPENWRT_UNSAFE_MATCHES# }"
        printf '  existing network.tailscale: %s\n' "$OPENWRT_NETWORK_TS_PRESENT"
        printf '  pending network/firewall UCI: %s/%s\n' "$OPENWRT_CURRENT_NETWORK_CHANGES" "$OPENWRT_CURRENT_FIREWALL_CHANGES"
        printf '  exit-node risk: %s; subnet requested: %s/%s; WAN UDP requested: %s\n' \
            "$OPENWRT_EXIT_NODE_RISK" "$OPENWRT_ENABLE_SUBNET" "${OPENWRT_SUBNET:-none}" "$OPENWRT_ALLOW_WAN_UDP"
        printf '\nplan itself changes nothing; install/apply/join would:\n'
        if [ "$OPENWRT_TAILSCALE_PACKAGE" = absent ]; then
            printf '  - install only the Tailscale package required by the selected package manager\n'
        fi
        if [ "$OPENWRT_EFFECTIVE_SERVICE_MODE" = core ]; then
            printf '  - fingerprint the stock helper, disable it without stop if unsafe, and install tailscale-core\n'
        else
            printf '  - use native service only after the helper fingerprint is proven safe\n'
        fi
        printf '  - join with file: auth key, accept-dns=false, accept-routes=false, and no --reset\n'
        printf '  - bind fw4 directly to device tailscale0 only after fw4 check; never create netifd tailscale interface\n'
        if [ "$OPENWRT_ENABLE_SUBNET" = true ]; then
            printf '  - advertise %s and add only IPv4 tailscale -> lan forwarding; approval remains a Headscale-side action\n' "$OPENWRT_SUBNET"
        else
            printf '  - leave subnet routing disabled until explicitly requested\n'
        fi
        if [ "$OPENWRT_ALLOW_WAN_UDP" = true ]; then
            printf '  - add a narrow UDP %s WAN rule only after explicit request; provide a reversible remove path\n' "$OPENWRT_TS_PORT"
        else
            printf '  - leave WAN UDP %s closed by default and rely on DERP fallback\n' "$OPENWRT_TS_PORT"
        fi
        printf '\nNever changed by this script:\n'
        printf '  - no tailscale up --reset, no stock init stop/reload/restart, no network reload\n'
        printf '  - no exit node, no IPv6 subnet routing, no DNS changes, no silent ControlURL switch\n'
        printf '  - failover only switches profiles registered via profile-add; it never logs in\n'
        if [ "$openwrt_plan_blocked" -eq 1 ]; then
            printf '\nBLOCKED: %s\n' "${openwrt_block_reasons# }"
        else
            printf '\nREADY: no hard conflict found; install/apply/join may proceed.\n'
        fi
    fi

    if [ "$openwrt_plan_blocked" -eq 0 ]; then
        return 0
    fi
    return 2
}

openwrt_status() {
    openwrt_collect_facts
    openwrt_effective_values
    OPENWRT_STATUS_CODE=0
    OPENWRT_STATUS_REASONS=
    if [ "$OPENWRT_TAILSCALE_PACKAGE" != installed ] && [ "$OPENWRT_TAILSCALE_VERSION" = absent ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS tailscale-package-missing"
    fi
    if [ "$OPENWRT_CURRENT_CONTROL_URL" = unknown ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS controlurl-unknown"
    fi
    if [ "$OPENWRT_TAILSCALE_STATE" = unknown ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS backend-state-unknown"
    fi
    if [ "$OPENWRT_TAILSCALE_STATE" != Running ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS backend-not-running"
    fi
    if [ "$OPENWRT_INIT_CORE_PRESENT" = yes ] && [ "$OPENWRT_CORE_FINGERPRINT" != verified ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS unverified-tailscale-core"
    fi
    if [ "$OPENWRT_CURRENT_NETWORK_CHANGES" != clean ] || [ "$OPENWRT_CURRENT_NETWORK_CHANGES" = unknown ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS network-uci-not-clean-or-unknown"
    fi
    if [ "$OPENWRT_CURRENT_FIREWALL_CHANGES" != clean ] || [ "$OPENWRT_CURRENT_FIREWALL_CHANGES" = unknown ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS firewall-uci-not-clean-or-unknown"
    fi
    if [ "$OPENWRT_TAILSCALE_STATE" = Running ] && [ "$OPENWRT_TS0_PRESENT" != yes ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS backend-running-without-tailscale0"
    fi
    if [ "$OPENWRT_TS0_PRESENT" = yes ] && [ "$OPENWRT_FIREWALL_DEVICE" != tailscale ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS tailscale0-not-bound-to-fw4-zone"
    fi
    if [ "$OPENWRT_CURRENT_ACCEPT_DNS" = true ] || [ "$OPENWRT_CURRENT_ACCEPT_ROUTES" = true ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS unsafe-dns-or-route-acceptance"
    fi
    if [ "$OPENWRT_UNSAFE_LUCI_HELPER" = yes ] && [ "$OPENWRT_STOCK_SERVICE_ENABLED" = yes ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS unsafe-stock-service-enabled"
    fi
    if [ "$OPENWRT_NETWORK_TS_PRESENT" = yes ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS network-tailscale-section-present"
    fi
    if [ "$OPENWRT_EXIT_NODE_RISK" = yes ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS exit-node-risk"
    fi
    if [ "$OPENWRT_CURRENT_CONTROL_URL" != unknown ] && [ -n "$OPENWRT_LOGIN_SERVER" ] && [ "$OPENWRT_CURRENT_CONTROL_URL" != "$OPENWRT_LOGIN_SERVER" ]; then
        OPENWRT_STATUS_CODE=2
        OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS requested-controlurl-differs"
    fi
    if [ "$OPENWRT_FAILOVER_ENABLED" = yes ]; then
        if [ "$OPENWRT_INIT_FAILOVER_PRESENT" != yes ]; then
            OPENWRT_STATUS_CODE=2
            OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS failover-service-missing"
        elif [ "$OPENWRT_FAILOVER_FINGERPRINT" != verified ]; then
            OPENWRT_STATUS_CODE=2
            OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS failover-unverified-fingerprint"
        elif [ "$OPENWRT_WATCHDOG_FAILOVER_PRESENT" != yes ] || [ "$OPENWRT_WATCHDOG_FINGERPRINT" != verified ]; then
            OPENWRT_STATUS_CODE=2
            OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS failover-watchdog-missing-or-unverified"
        elif [ "$OPENWRT_PROFILE_COUNT" -lt 2 ]; then
            OPENWRT_STATUS_CODE=2
            OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS failover-under-two-profiles"
        elif [ "$OPENWRT_FAILOVER_SERVICE_ENABLED" != yes ]; then
            OPENWRT_STATUS_CODE=2
            OPENWRT_STATUS_REASONS="$OPENWRT_STATUS_REASONS failover-service-not-enabled-at-boot"
        fi
    fi

    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$OPENWRT_PROGRAM"
        bootstrap_json_field command status
        bootstrap_json_field backend_state "$OPENWRT_TAILSCALE_STATE"
        bootstrap_json_field control_url "$OPENWRT_CURRENT_CONTROL_URL"
        bootstrap_json_field tailscale_ip4 "$OPENWRT_TAILSCALE_IP4"
        bootstrap_json_field tailscale0 "$OPENWRT_TS0_PRESENT"
        bootstrap_json_field fw4_device "$OPENWRT_FIREWALL_DEVICE"
        bootstrap_json_field core_service "$OPENWRT_INIT_CORE_PRESENT"
        bootstrap_json_field network_changes "$OPENWRT_CURRENT_NETWORK_CHANGES"
        bootstrap_json_field firewall_changes "$OPENWRT_CURRENT_FIREWALL_CHANGES"
        bootstrap_json_field profile_count "$OPENWRT_PROFILE_COUNT"
        bootstrap_json_field profiles "${OPENWRT_PROFILE_URLS:-none}"
        bootstrap_json_field failover_enabled "$OPENWRT_FAILOVER_ENABLED"
        bootstrap_json_field failover_service "$OPENWRT_INIT_FAILOVER_PRESENT"
        bootstrap_json_field reasons "${OPENWRT_STATUS_REASONS# }"
        if [ "$OPENWRT_STATUS_CODE" -eq 0 ]; then bootstrap_json_bool_field ok true; else bootstrap_json_bool_field ok false; fi
        bootstrap_json_end
    else
        printf 'OpenWrt Tailscale status (read-only)\n'
        printf '  backend state: %s\n' "$OPENWRT_TAILSCALE_STATE"
        printf '  ControlURL: %s\n' "$OPENWRT_CURRENT_CONTROL_URL"
        printf '  Tailscale IPv4/tailscale0: %s/%s\n' "$OPENWRT_TAILSCALE_IP4" "$OPENWRT_TS0_PRESENT"
        printf '  fw4 device tailscale0: %s\n' "$OPENWRT_FIREWALL_DEVICE"
        printf '  tailscale-core present: %s\n' "$OPENWRT_INIT_CORE_PRESENT"
        printf '  stock init enabled: %s; unsafe helper: %s\n' "$OPENWRT_STOCK_SERVICE_ENABLED" "$OPENWRT_UNSAFE_LUCI_HELPER"
        printf '  network/firewall UCI pending: %s/%s\n' "$OPENWRT_CURRENT_NETWORK_CHANGES" "$OPENWRT_CURRENT_FIREWALL_CHANGES"
        printf '  exit-node risk: %s\n' "$OPENWRT_EXIT_NODE_RISK"
        printf '  bootstrap profiles: %s (%s); failover: %s (service %s)\n' \
            "$OPENWRT_PROFILE_COUNT" "${OPENWRT_PROFILE_URLS:-none}" "$OPENWRT_FAILOVER_ENABLED" "$OPENWRT_INIT_FAILOVER_PRESENT"
        if [ "$OPENWRT_STATUS_CODE" -eq 0 ]; then printf 'OK\n'; else printf 'FAIL: %s\n' "${OPENWRT_STATUS_REASONS# }"; fi
    fi

    return "$OPENWRT_STATUS_CODE"
}

openwrt_backup_packages() {
    openwrt_backup_package_file=$1
    if [ "$OPENWRT_PACKAGE_MANAGER" = opkg ]; then
        opkg list-installed 2>/dev/null | awk '$1 ~ /^(tailscale|luci-app-tailscale)$/ {print}' > "$openwrt_backup_package_file"
    elif [ "$OPENWRT_PACKAGE_MANAGER" = apk ]; then
        apk info 2>/dev/null | grep -E '^(tailscale|luci-app-tailscale)' > "$openwrt_backup_package_file"
    else
        printf 'package-manager=unavailable\n' > "$openwrt_backup_package_file"
    fi
    chmod 600 "$openwrt_backup_package_file" 2>/dev/null || true
}

openwrt_backup_prefs() {
    openwrt_backup_prefs_file=$1
    if bootstrap_command_exists tailscale; then
        tailscale debug prefs > "$openwrt_backup_prefs_file" 2>/dev/null || printf 'prefs=unavailable\n' > "$openwrt_backup_prefs_file"
    else
        printf 'tailscale=unavailable\n' > "$openwrt_backup_prefs_file"
    fi
    chmod 600 "$openwrt_backup_prefs_file" 2>/dev/null || true
}

openwrt_backup() {
    if [ "$BOOTSTRAP_ROOT" = / ] && [ "$(id -u 2>/dev/null || printf 1)" != 0 ]; then
        die 'backup of the real OpenWrt device requires root; use --root DIR only for an explicit fixture'
    fi
    openwrt_backup_create || die 'backup failed'

    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$OPENWRT_PROGRAM"
        bootstrap_json_field command backup
        bootstrap_json_field backup_id "$OPENWRT_BACKUP_ID"
        bootstrap_json_field backup_path "$OPENWRT_BACKUP_ROOT"
        bootstrap_json_field manifest manifest.sha256
        bootstrap_json_field secret_contents not-logged
        bootstrap_json_end
    else
        printf 'Backup created: %s\n' "$OPENWRT_BACKUP_ROOT"
        printf 'Manifest: %s\n' "$OPENWRT_BACKUP_ROOT/manifest.sha256"
        printf 'tailscaled.state was handled as private backup data and was not printed.\n'
    fi
}

openwrt_main() {
    openwrt_parse_args "$@"
    # The allow-wan-udp command enables the rule by default; the option only
    # exists to express the explicit false form.
    if [ "$OPENWRT_COMMAND" = allow-wan-udp ] && [ "$OPENWRT_ALLOW_WAN_UDP_EXPLICIT" != 1 ]; then
        OPENWRT_ALLOW_WAN_UDP=true
    fi
    case "$OPENWRT_COMMAND" in
        discover) openwrt_print_discover ;;
        plan) openwrt_plan ;;
        status|verify) openwrt_status ;;
        backup) openwrt_backup ;;
        install) openwrt_install ;;
        apply) openwrt_apply ;;
        join) openwrt_join ;;
        profile-list) openwrt_profile_list ;;
        profile-add) openwrt_profile_add ;;
        profile-remove) openwrt_profile_remove ;;
        switch-to) openwrt_switch_to ;;
        enable-failover) openwrt_enable_failover ;;
        disable-failover) openwrt_disable_failover ;;
        enable-subnet) openwrt_enable_subnet ;;
        disable-subnet) openwrt_disable_subnet ;;
        allow-wan-udp) openwrt_allow_wan_udp ;;
        update) openwrt_update ;;
        rollback) openwrt_rollback ;;
        cleanup) openwrt_cleanup ;;
        purge-identity) openwrt_purge_identity ;;
        *) die "unhandled command: $OPENWRT_COMMAND" ;;
    esac
}

openwrt_main "$@"
