#!/bin/sh

# Headscale + OpenWrt bootstrap, VPS side.
#
# Milestone 1 intentionally has no mutating install/apply/update/rollback or
# cleanup implementation.  discover, plan and status inspect only; backup
# creates a private, hashed snapshot and does not stop/reload any service.

set -f
umask 077

VPS_SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
. "$VPS_SCRIPT_DIR/lib/log.sh" || exit 1
. "$VPS_SCRIPT_DIR/lib/common.sh" || exit 1
. "$VPS_SCRIPT_DIR/lib/backup.sh" || exit 1
. "$VPS_SCRIPT_DIR/lib/version.sh" || exit 1

VPS_PROGRAM=headscale-vps.sh
VPS_COMMAND=
VPS_DOMAIN=
VPS_VERSION=
VPS_PROXY_MODE=auto
VPS_USER_NAME=
VPS_LISTEN=127.0.0.1:8080
VPS_METRICS_LISTEN=127.0.0.1:9090
VPS_GRPC_LISTEN=127.0.0.1:50443
VPS_ENABLE_DERP=false
VPS_EXPECTED_PUBLIC_IP=
VPS_BACKUP_DIR=/var/backups/headscale-bootstrap
BOOTSTRAP_ROOT=/
BOOTSTRAP_DRY_RUN=0
BOOTSTRAP_YES=0
BOOTSTRAP_JSON=0
BOOTSTRAP_QUIET=0
BOOTSTRAP_VERBOSE=0

vps_usage() {
    cat <<'EOF'
Usage:
  headscale-vps.sh [global options] <command>

Milestone 1 commands (discover/status/plan are read-only):
  discover                 Inspect the VPS without changing it.
  plan                     Show a guarded future plan; never changes the VPS.
  status                   Check current Headscale/proxy safety and health.
  verify                   Read-only verification alias for status in Milestone 1.
  backup                   Create a private timestamped snapshot; no service reload.

Reserved fail-closed commands:
  install apply update rollback cleanup purge ensure-user issue-key approve-route

Options:
  --domain DOMAIN
  --version VERSION
  --proxy auto|1panel|caddy|nginx|none
  --user USER
  --listen ADDRESS:PORT
  --metrics-listen ADDRESS:PORT
  --grpc-listen ADDRESS:PORT
  --enable-embedded-derp true|false
  --expected-public-ip IP   Optional DNS-to-VPS comparison input.
  --root DIR                Test/fixture root; default is /.
  --backup-dir DIR          Backup directory in the selected root namespace.
  --dry-run                 Accepted for CLI compatibility; all Milestone 1 commands are non-mutating.
  --yes                     Accepted for future explicit operations; not sufficient for reserved commands.
  --json --quiet --verbose
  -h, --help

Hard boundaries in this milestone:
  - no service start/stop/restart/reload;
  - no package installation;
  - no config rewrite or reverse-proxy reload;
  - no public bind is proposed for Headscale 8080/9090/50443;
  - no OpenWrt/network/firewall operation is performed by this script.
EOF
}

vps_parse_bool() {
    case "$1" in
        true|yes|1|on) printf 'true\n' ;;
        false|no|0|off) printf 'false\n' ;;
        *) die "invalid boolean: $1 (expected true or false)" ;;
    esac
}

vps_validate_proxy() {
    case "$VPS_PROXY_MODE" in
        auto|1panel|caddy|nginx|none) ;;
        *) die "unsupported --proxy value: $VPS_PROXY_MODE" ;;
    esac
}

vps_validate_backup_dir() {
    case "$VPS_BACKUP_DIR" in
        /*) ;;
        *) die '--backup-dir must be an absolute path in the selected root namespace' ;;
    esac
    case "$VPS_BACKUP_DIR" in
        /|*/../*|*/..|..|.) die 'refusing unsafe --backup-dir' ;;
    esac
}

vps_need_value() {
    [ "$#" -ge 2 ] || die "option $1 needs a value"
}

vps_parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            discover|plan|status|verify|backup|install|apply|update|rollback|cleanup|purge|ensure-user|issue-key|approve-route)
                [ -z "$VPS_COMMAND" ] || die "multiple commands supplied: $VPS_COMMAND and $1"
                VPS_COMMAND=$1
                shift
                ;;
            --domain)
                vps_need_value "$@"
                VPS_DOMAIN=$2
                shift 2
                ;;
            --domain=*) VPS_DOMAIN=${1#*=}; shift ;;
            --version)
                vps_need_value "$@"
                VPS_VERSION=$2
                shift 2
                ;;
            --version=*) VPS_VERSION=${1#*=}; shift ;;
            --proxy)
                vps_need_value "$@"
                VPS_PROXY_MODE=$2
                shift 2
                ;;
            --proxy=*) VPS_PROXY_MODE=${1#*=}; shift ;;
            --user)
                vps_need_value "$@"
                VPS_USER_NAME=$2
                shift 2
                ;;
            --user=*) VPS_USER_NAME=${1#*=}; shift ;;
            --listen)
                vps_need_value "$@"
                VPS_LISTEN=$2
                shift 2
                ;;
            --listen=*) VPS_LISTEN=${1#*=}; shift ;;
            --metrics-listen)
                vps_need_value "$@"
                VPS_METRICS_LISTEN=$2
                shift 2
                ;;
            --metrics-listen=*) VPS_METRICS_LISTEN=${1#*=}; shift ;;
            --grpc-listen)
                vps_need_value "$@"
                VPS_GRPC_LISTEN=$2
                shift 2
                ;;
            --grpc-listen=*) VPS_GRPC_LISTEN=${1#*=}; shift ;;
            --enable-embedded-derp)
                vps_need_value "$@"
                VPS_ENABLE_DERP=$(vps_parse_bool "$2")
                shift 2
                ;;
            --enable-embedded-derp=*) VPS_ENABLE_DERP=$(vps_parse_bool "${1#*=}"); shift ;;
            --expected-public-ip)
                vps_need_value "$@"
                VPS_EXPECTED_PUBLIC_IP=$2
                shift 2
                ;;
            --expected-public-ip=*) VPS_EXPECTED_PUBLIC_IP=${1#*=}; shift ;;
            --root)
                vps_need_value "$@"
                BOOTSTRAP_ROOT=$2
                shift 2
                ;;
            --root=*) BOOTSTRAP_ROOT=${1#*=}; shift ;;
            --backup-dir)
                vps_need_value "$@"
                VPS_BACKUP_DIR=$2
                shift 2
                ;;
            --backup-dir=*) VPS_BACKUP_DIR=${1#*=}; shift ;;
            --dry-run) BOOTSTRAP_DRY_RUN=1; shift ;;
            --yes|--yes-i-understand) BOOTSTRAP_YES=1; shift ;;
            --json) BOOTSTRAP_JSON=1; shift ;;
            --quiet) BOOTSTRAP_QUIET=1; shift ;;
            --verbose) BOOTSTRAP_VERBOSE=1; shift ;;
            -h|--help) vps_usage; exit 0 ;;
            --) shift; while [ "$#" -gt 0 ]; do die "unexpected argument after --: $1"; done ;;
            *) die "unknown option or command: $1" ;;
        esac
    done

    [ -n "$VPS_COMMAND" ] || { vps_usage >&2; exit 2; }
    vps_validate_proxy
    vps_validate_backup_dir
    BOOTSTRAP_ROOT=$(bootstrap_normalize_root "$BOOTSTRAP_ROOT") || die "--root is not an accessible directory"
}

vps_extract_domain_from_url() {
    vps_url=$1
    case "$vps_url" in
        https://*)
            vps_host=${vps_url#https://}
            vps_host=${vps_host%%/*}
            vps_host=${vps_host%%:*}
            printf '%s\n' "$vps_host"
            ;;
    esac
}

vps_socket_state() {
    vps_socket_port=$1
    vps_socket_data=$2
    [ -n "$vps_socket_data" ] || { printf 'unknown\n'; return 0; }

    printf '%s\n' "$vps_socket_data" | awk -v wanted_port="$vps_socket_port" '
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

vps_socket_owner_summary() {
    vps_owner_port=$1
    vps_owner_data=$2
    [ -n "$vps_owner_data" ] || return 0
    printf '%s\n' "$vps_owner_data" | awk -v wanted_port="$vps_owner_port" '
        NR == 1 && $1 ~ /Netid|State/ { next }
        {
            address=$4
            if ($1 ~ /^(tcp|udp|tcp6|udp6)$/ && $2 ~ /^(LISTEN|UNCONN|ESTAB|TIME-WAIT)$/) address=$5
            if (address !~ (":" wanted_port "$")) next
            process="unknown"
            pid="unknown"
            if (index($0, "users:((") > 0) {
                process=$0
                sub(/^.*users:\(\("/, "", process)
                sub(/".*$/, "", process)
                pid=$0
                sub(/^.*pid=/, "", pid)
                sub(/[^0-9].*$/, "", pid)
                if (pid == "") pid="unknown"
            }
            gsub(/[^A-Za-z0-9_.-]/, "", process)
            printf "%s %s process=%s pid=%s\n", $1, address, process, pid
        }
    '
}

vps_find_panel_vhost() {
    vps_panel_conf_dir=$(bootstrap_root_path /opt/1panel/www/conf.d)
    [ -d "$vps_panel_conf_dir" ] || return 0
    [ -n "$VPS_EFFECTIVE_DOMAIN" ] || return 0

    find "$vps_panel_conf_dir" -type f -name '*.conf' -print 2>/dev/null |
    while IFS= read -r vps_candidate; do
        if grep -qF "server_name $VPS_EFFECTIVE_DOMAIN" "$vps_candidate" 2>/dev/null; then
            printf '%s\n' "$vps_candidate"
            break
        fi
    done | sed -n '1p'
}

vps_collect_dns() {
    VPS_DNS_IPS=
    VPS_DNS_STATUS=unknown
    VPS_DNS_MATCH=unknown
    VPS_DNS_POSSIBLE_PROXY=no

    [ -n "$VPS_EFFECTIVE_DOMAIN" ] || {
        VPS_DNS_STATUS=missing-domain
        return 0
    }

    if bootstrap_command_exists getent; then
        VPS_DNS_IPS=$(getent ahosts "$VPS_EFFECTIVE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    elif bootstrap_command_exists nslookup; then
        VPS_DNS_IPS=$(nslookup "$VPS_EFFECTIVE_DOMAIN" 2>/dev/null | awk '/^Address: / {print $2}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    elif bootstrap_command_exists host; then
        VPS_DNS_IPS=$(host "$VPS_EFFECTIVE_DOMAIN" 2>/dev/null | awk '/has address|has IPv6 address/ {print $NF}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    else
        VPS_DNS_STATUS=no-resolver
        return 0
    fi

    [ -n "$VPS_DNS_IPS" ] || {
        VPS_DNS_STATUS=unresolved
        return 0
    }
    VPS_DNS_STATUS=resolved

    if [ -n "$VPS_EXPECTED_PUBLIC_IP" ]; then
        VPS_DNS_ALL_MATCH=yes
        VPS_DNS_ANY_MATCH=no
        for vps_dns_ip in $VPS_DNS_IPS; do
            if [ "$vps_dns_ip" = "$VPS_EXPECTED_PUBLIC_IP" ]; then
                VPS_DNS_ANY_MATCH=yes
            else
                VPS_DNS_ALL_MATCH=no
            fi
        done
        if [ "$VPS_DNS_ANY_MATCH" = yes ] && [ "$VPS_DNS_ALL_MATCH" = yes ]; then
            VPS_DNS_MATCH=match
        else
            VPS_DNS_MATCH=mismatch
            VPS_DNS_POSSIBLE_PROXY=yes
        fi
        return 0
    fi

    VPS_LOCAL_GLOBAL_IPS=
    if bootstrap_command_exists ip; then
        VPS_LOCAL_GLOBAL_IPS=$(ip -o addr show scope global 2>/dev/null | awk '$3 == "inet" || $3 == "inet6" {split($4, a, "/"); print a[1]}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    fi
    if [ -n "$VPS_LOCAL_GLOBAL_IPS" ]; then
        VPS_DNS_ALL_MATCH=yes
        VPS_DNS_ANY_MATCH=no
        for vps_dns_ip in $VPS_DNS_IPS; do
            VPS_DNS_IP_MATCH=no
            for vps_local_ip in $VPS_LOCAL_GLOBAL_IPS; do
                [ "$vps_dns_ip" = "$vps_local_ip" ] && VPS_DNS_IP_MATCH=yes
            done
            [ "$VPS_DNS_IP_MATCH" = yes ] && VPS_DNS_ANY_MATCH=yes || VPS_DNS_ALL_MATCH=no
        done
        if [ "$VPS_DNS_ANY_MATCH" = yes ] && [ "$VPS_DNS_ALL_MATCH" = yes ]; then
            VPS_DNS_MATCH=match
        else
            VPS_DNS_MATCH=not-local
            VPS_DNS_POSSIBLE_PROXY=yes
        fi
    fi
}

vps_collect_facts() {
    VPS_CONFIG_DIR=$(bootstrap_root_path /etc/headscale)
    VPS_CONFIG_PATH=$(bootstrap_root_path /etc/headscale/config.yaml)
    VPS_DATA_PATH=$(bootstrap_root_path /var/lib/headscale)
    VPS_UNIT_PATH=$(bootstrap_root_path /usr/lib/systemd/system/headscale.service)
    [ -f "$VPS_UNIT_PATH" ] || VPS_UNIT_PATH=$(bootstrap_root_path /etc/systemd/system/headscale.service)

    VPS_CONFIG_PRESENT=no
    VPS_DATA_PRESENT=no
    [ -f "$VPS_CONFIG_PATH" ] && VPS_CONFIG_PRESENT=yes
    [ -d "$VPS_DATA_PATH" ] && VPS_DATA_PRESENT=yes

    VPS_OS_ID=unknown
    VPS_OS_VERSION_ID=unknown
    VPS_OS_RELEASE=$(bootstrap_root_path /etc/os-release)
    if [ -r "$VPS_OS_RELEASE" ]; then
        VPS_OS_ID=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print $2; exit}' "$VPS_OS_RELEASE" 2>/dev/null)
        VPS_OS_VERSION_ID=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2; exit}' "$VPS_OS_RELEASE" 2>/dev/null)
        [ -n "$VPS_OS_ID" ] || VPS_OS_ID=unknown
        [ -n "$VPS_OS_VERSION_ID" ] || VPS_OS_VERSION_ID=unknown
    fi

    VPS_ARCH_RAW=unknown
    bootstrap_command_exists uname && VPS_ARCH_RAW=$(bootstrap_capture_first_line uname -m)
    case "$VPS_ARCH_RAW" in
        x86_64|amd64) VPS_ARCH=amd64 ;;
        aarch64|arm64) VPS_ARCH=arm64 ;;
        *) VPS_ARCH=unsupported-or-unknown ;;
    esac

    VPS_HEADSCALE_VERSION=absent
    if bootstrap_command_exists headscale; then
        VPS_HEADSCALE_VERSION=$(bootstrap_capture_first_line headscale version)
        [ -n "$VPS_HEADSCALE_VERSION" ] || VPS_HEADSCALE_VERSION=present-version-unknown
    fi

    VPS_SERVICE_ACTIVE=unknown
    VPS_SERVICE_ENABLED=unknown
    if bootstrap_command_exists systemctl; then
        VPS_SERVICE_ACTIVE=$(bootstrap_capture_first_line systemctl is-active headscale)
        VPS_SERVICE_ENABLED=$(bootstrap_capture_first_line systemctl is-enabled headscale)
        [ -n "$VPS_SERVICE_ACTIVE" ] || VPS_SERVICE_ACTIVE=unknown
        [ -n "$VPS_SERVICE_ENABLED" ] || VPS_SERVICE_ENABLED=unknown
    fi

    VPS_SOCKETS=
    if bootstrap_command_exists ss; then
        VPS_SOCKETS=$(ss -lntup 2>/dev/null)
    fi
    VPS_PORT_80=$(vps_socket_state 80 "$VPS_SOCKETS")
    VPS_PORT_443=$(vps_socket_state 443 "$VPS_SOCKETS")
    VPS_PORT_8080=$(vps_socket_state 8080 "$VPS_SOCKETS")
    VPS_PORT_9090=$(vps_socket_state 9090 "$VPS_SOCKETS")
    VPS_PORT_50443=$(vps_socket_state 50443 "$VPS_SOCKETS")
    VPS_OWNER_80=$(vps_socket_owner_summary 80 "$VPS_SOCKETS" | sed -n '1p')
    VPS_OWNER_443=$(vps_socket_owner_summary 443 "$VPS_SOCKETS" | sed -n '1p')
    VPS_OWNER_8080=$(vps_socket_owner_summary 8080 "$VPS_SOCKETS" | sed -n '1p')
    VPS_OWNER_9090=$(vps_socket_owner_summary 9090 "$VPS_SOCKETS" | sed -n '1p')
    VPS_OWNER_50443=$(vps_socket_owner_summary 50443 "$VPS_SOCKETS" | sed -n '1p')

    VPS_UDP_SOCKETS=
    if bootstrap_command_exists ss; then
        VPS_UDP_SOCKETS=$(ss -lun 2>/dev/null)
    fi
    VPS_PORT_3478_UDP=$(vps_socket_state 3478 "$VPS_UDP_SOCKETS")

    VPS_CURRENT_SERVER_URL=
    VPS_CURRENT_LISTEN=
    VPS_CURRENT_METRICS_LISTEN=
    VPS_CURRENT_GRPC_LISTEN=
    VPS_CURRENT_TLS_CERT=
    VPS_CURRENT_TLS_KEY=
    VPS_CURRENT_TRUSTED_PROXIES=
    VPS_CURRENT_DERP_ENABLED=
    if [ "$VPS_CONFIG_PRESENT" = yes ]; then
        VPS_CURRENT_SERVER_URL=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" server_url)
        VPS_CURRENT_LISTEN=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" listen_addr)
        VPS_CURRENT_METRICS_LISTEN=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" metrics_listen_addr)
        VPS_CURRENT_GRPC_LISTEN=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" grpc_listen_addr)
        VPS_CURRENT_TLS_CERT=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" tls_cert_path)
        VPS_CURRENT_TLS_KEY=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" tls_key_path)
        VPS_CURRENT_TRUSTED_PROXIES=$(bootstrap_yaml_scalar "$VPS_CONFIG_PATH" trusted_proxies)
        VPS_CURRENT_DERP_ENABLED=$(bootstrap_yaml_triple_scalar "$VPS_CONFIG_PATH" derp server enabled)
    fi
    [ -n "$VPS_CURRENT_SERVER_URL" ] || VPS_CURRENT_SERVER_URL=unknown
    [ -n "$VPS_CURRENT_LISTEN" ] || VPS_CURRENT_LISTEN=unknown
    [ -n "$VPS_CURRENT_METRICS_LISTEN" ] || VPS_CURRENT_METRICS_LISTEN=unknown
    [ -n "$VPS_CURRENT_GRPC_LISTEN" ] || VPS_CURRENT_GRPC_LISTEN=unknown
    [ -n "$VPS_CURRENT_TLS_CERT" ] || VPS_CURRENT_TLS_CERT=unknown-or-empty
    [ -n "$VPS_CURRENT_TLS_KEY" ] || VPS_CURRENT_TLS_KEY=unknown-or-empty
    [ -n "$VPS_CURRENT_TRUSTED_PROXIES" ] || VPS_CURRENT_TRUSTED_PROXIES=unknown
    [ -n "$VPS_CURRENT_DERP_ENABLED" ] || VPS_CURRENT_DERP_ENABLED=unknown

    VPS_DETECTED_DOMAIN=
    [ "$VPS_CURRENT_SERVER_URL" != unknown ] && VPS_DETECTED_DOMAIN=$(vps_extract_domain_from_url "$VPS_CURRENT_SERVER_URL")
    VPS_EFFECTIVE_DOMAIN=${VPS_DOMAIN:-$VPS_DETECTED_DOMAIN}
    vps_collect_dns

    VPS_DOCKER_OPENRESTY=no
    VPS_DOCKER_CONTAINER=
    VPS_DOCKER_NETWORK_MODE=unknown
    VPS_PANEL_MOUNT_WWW=unknown
    VPS_PANEL_MOUNT_CONFD=unknown
    if bootstrap_command_exists docker; then
        VPS_DOCKER_NAMES=$(docker ps --format '{{.Names}}' 2>/dev/null)
        for vps_docker_name in $VPS_DOCKER_NAMES; do
            VPS_DOCKER_DETAILS=$(docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.HostConfig.NetworkMode}}' "$vps_docker_name" 2>/dev/null)
            case "$VPS_DOCKER_DETAILS" in
                *openresty*|*OpenResty*|*1panel*openresty*|*1Panel*OpenResty*)
                    VPS_DOCKER_OPENRESTY=yes
                    VPS_DOCKER_CONTAINER=$vps_docker_name
                    VPS_DOCKER_NETWORK_MODE=$(printf '%s\n' "$VPS_DOCKER_DETAILS" | awk -F'|' '{print $3}')
                    VPS_DOCKER_MOUNTS=$(docker inspect --format '{{range .Mounts}}{{.Source}}=>{{.Destination}};{{end}}' "$vps_docker_name" 2>/dev/null)
                    VPS_PANEL_MOUNT_WWW=no
                    VPS_PANEL_MOUNT_CONFD=no
                    case "$VPS_DOCKER_MOUNTS" in *'/opt/1panel/www=>/www;'*) VPS_PANEL_MOUNT_WWW=yes ;; esac
                    case "$VPS_DOCKER_MOUNTS" in *'/opt/1panel/www/conf.d=>/usr/local/openresty/nginx/conf/conf.d;'*) VPS_PANEL_MOUNT_CONFD=yes ;; esac
                    break
                    ;;
            esac
        done
    fi

    VPS_PANEL_VHOST_PATH=$(vps_find_panel_vhost)
    VPS_PANEL_ROOT_CONF=
    if [ -n "$VPS_EFFECTIVE_DOMAIN" ]; then
        VPS_PANEL_ROOT_CONF=$(bootstrap_root_path "/opt/1panel/www/sites/$VPS_EFFECTIVE_DOMAIN/proxy/root.conf")
    fi
    VPS_PANEL_ROOT_PRESENT=no
    VPS_PANEL_BUFFERING=unknown
    [ -f "$VPS_PANEL_ROOT_CONF" ] && VPS_PANEL_ROOT_PRESENT=yes
    if [ "$VPS_PANEL_ROOT_PRESENT" = yes ]; then
        if grep -qF 'proxy_buffering off;' "$VPS_PANEL_ROOT_CONF" 2>/dev/null; then
            VPS_PANEL_BUFFERING=present
        else
            VPS_PANEL_BUFFERING=missing
        fi
    fi
    VPS_PANEL_PRESENT=no
    [ -d "$(bootstrap_root_path /opt/1panel)" ] && VPS_PANEL_PRESENT=yes

    VPS_CADDY_PRESENT=no
    VPS_CADDYFILE_PRESENT=no
    bootstrap_command_exists caddy && VPS_CADDY_PRESENT=yes
    [ -f "$(bootstrap_root_path /etc/caddy/Caddyfile)" ] && VPS_CADDYFILE_PRESENT=yes
    VPS_NGINX_PRESENT=no
    bootstrap_command_exists nginx && VPS_NGINX_PRESENT=yes

    VPS_HEADSCALE_ACCOUNT_USER=unknown
    VPS_CONFIGTEST_CAPABILITY=unavailable
    if bootstrap_command_exists headscale; then
        VPS_CONFIGTEST_CAPABILITY=available
    fi
}

vps_safe_config_state() {
    VPS_SAFE_CONFIG=yes
    VPS_CONFIG_SAFETY_REASON=ok
    [ "$VPS_CONFIG_PRESENT" = yes ] || {
        VPS_SAFE_CONFIG=unknown
        VPS_CONFIG_SAFETY_REASON=config-absent
        return 0
    }

    case "$VPS_CURRENT_LISTEN" in
        127.*:*|localhost:*|\[::1\]:*|::1:*) ;;
        *) VPS_SAFE_CONFIG=no; VPS_CONFIG_SAFETY_REASON=listen-not-loopback ;;
    esac
    case "$VPS_CURRENT_METRICS_LISTEN" in
        127.*:*|localhost:*|\[::1\]:*|::1:*) ;;
        *) VPS_SAFE_CONFIG=no; VPS_CONFIG_SAFETY_REASON=metrics-not-loopback ;;
    esac
    case "$VPS_CURRENT_GRPC_LISTEN" in
        127.*:*|localhost:*|\[::1\]:*|::1:*) ;;
        *) VPS_SAFE_CONFIG=no; VPS_CONFIG_SAFETY_REASON=grpc-not-loopback ;;
    esac
    case "$VPS_CURRENT_SERVER_URL" in
        https://?*) ;;
        *) VPS_SAFE_CONFIG=no; VPS_CONFIG_SAFETY_REASON=server-url-not-https ;;
    esac
    if [ "$VPS_PROXY_MODE" != none ] && [ "$VPS_CURRENT_TLS_CERT" != unknown-or-empty ] && [ -n "$VPS_CURRENT_TLS_CERT" ]; then
        VPS_SAFE_CONFIG=no
        VPS_CONFIG_SAFETY_REASON=headscale-tls-cert-set-in-proxy-mode
    fi
    if [ "$VPS_PROXY_MODE" != none ] && [ "$VPS_CURRENT_TLS_KEY" != unknown-or-empty ] && [ -n "$VPS_CURRENT_TLS_KEY" ]; then
        VPS_SAFE_CONFIG=no
        VPS_CONFIG_SAFETY_REASON=headscale-tls-key-set-in-proxy-mode
    fi
}

vps_effective_proxy() {
    VPS_EFFECTIVE_PROXY=$VPS_PROXY_MODE
    if [ "$VPS_PROXY_MODE" = auto ]; then
        if [ "$VPS_DOCKER_OPENRESTY" = yes ] && [ "$VPS_DOCKER_NETWORK_MODE" = host ]; then
            VPS_EFFECTIVE_PROXY=1panel
        elif [ "$VPS_CADDY_PRESENT" = yes ] && [ "$VPS_PORT_80" = free ] && [ "$VPS_PORT_443" = free ]; then
            VPS_EFFECTIVE_PROXY=caddy
        elif [ "$VPS_NGINX_PRESENT" = yes ] && vps_proxy_listener_ownership_ok nginx; then
            VPS_EFFECTIVE_PROXY=nginx
        elif [ "$VPS_PORT_80" = free ] && [ "$VPS_PORT_443" = free ]; then
            VPS_EFFECTIVE_PROXY=caddy
        else
            VPS_EFFECTIVE_PROXY=unknown
        fi
    fi
}

vps_proxy_listener_ownership_ok() {
    vps_proxy_name=$1
    case "$vps_proxy_name" in
        caddy)
            vps_listener_owner_matches "$VPS_PORT_80" "$VPS_OWNER_80" caddy || return 1
            vps_listener_owner_matches "$VPS_PORT_443" "$VPS_OWNER_443" caddy || return 1
            ;;
        nginx)
            vps_listener_owner_matches "$VPS_PORT_80" "$VPS_OWNER_80" nginx || return 1
            vps_listener_owner_matches "$VPS_PORT_443" "$VPS_OWNER_443" nginx || return 1
            ;;
        1panel) return 0 ;;
        none) return 0 ;;
        *) return 1 ;;
    esac
}

vps_listener_owner_matches() {
    vps_listener_state=$1
    vps_listener_owner=$2
    vps_listener_expected=$3
    [ "$vps_listener_state" = free ] && return 0
    case "$vps_listener_expected" in
        caddy)
            case "$vps_listener_owner" in *caddy*) return 0 ;; esac
            ;;
        nginx)
            case "$vps_listener_owner" in *nginx*|*openresty*|*OpenResty*) return 0 ;; esac
            ;;
    esac
    return 1
}

vps_print_text_discover() {
    printf 'Headscale VPS discovery (read-only)\n'
    printf '  root: %s\n' "$BOOTSTRAP_ROOT"
    printf '  OS: %s %s\n' "$VPS_OS_ID" "$VPS_OS_VERSION_ID"
    printf '  architecture: %s (raw=%s)\n' "$VPS_ARCH" "$VPS_ARCH_RAW"
    printf '  headscale binary: %s\n' "$VPS_HEADSCALE_VERSION"
    printf '  headscale config: %s\n' "$VPS_CONFIG_PRESENT"
    printf '  headscale data: %s\n' "$VPS_DATA_PRESENT"
    printf '  systemd active/enabled: %s/%s\n' "$VPS_SERVICE_ACTIVE" "$VPS_SERVICE_ENABLED"
    printf '  configured server_url: %s\n' "$VPS_CURRENT_SERVER_URL"
    printf '  configured listen/metrics/grpc: %s / %s / %s\n' "$VPS_CURRENT_LISTEN" "$VPS_CURRENT_METRICS_LISTEN" "$VPS_CURRENT_GRPC_LISTEN"
    printf '  configured Headscale TLS paths: cert=%s key=%s\n' "$VPS_CURRENT_TLS_CERT" "$VPS_CURRENT_TLS_KEY"
    printf '  trusted_proxies baseline: %s\n' "$VPS_CURRENT_TRUSTED_PROXIES"
    printf '  embedded DERP enabled: %s\n' "$VPS_CURRENT_DERP_ENABLED"
    printf '  effective domain: %s\n' "${VPS_EFFECTIVE_DOMAIN:-unknown}"
    printf '  DNS: %s; match=%s; addresses=%s\n' "$VPS_DNS_STATUS" "$VPS_DNS_MATCH" "${VPS_DNS_IPS:-none}"
    printf '  listeners 80/443: %s/%s\n' "$VPS_PORT_80" "$VPS_PORT_443"
    printf '  listeners 8080/9090/50443: %s/%s/%s\n' "$VPS_PORT_8080" "$VPS_PORT_9090" "$VPS_PORT_50443"
    printf '  listener owners 80/443: %s / %s\n' "${VPS_OWNER_80:-unknown}" "${VPS_OWNER_443:-unknown}"
    printf '  listener owners 8080/9090/50443: %s / %s / %s\n' "${VPS_OWNER_8080:-unknown}" "${VPS_OWNER_9090:-unknown}" "${VPS_OWNER_50443:-unknown}"
    printf '  UDP 3478: %s\n' "$VPS_PORT_3478_UDP"
    printf '  1Panel/OpenResty: container=%s network=%s mounts(www/conf.d)=%s/%s vhost=%s proxy_root=%s buffering=%s\n' \
        "$VPS_DOCKER_CONTAINER" "$VPS_DOCKER_NETWORK_MODE" \
        "$VPS_PANEL_MOUNT_WWW" "$VPS_PANEL_MOUNT_CONFD" \
        "${VPS_PANEL_VHOST_PATH:-none}" "${VPS_PANEL_ROOT_PRESENT}" "$VPS_PANEL_BUFFERING"
    printf '  Caddy binary/Caddyfile: %s/%s\n' "$VPS_CADDY_PRESENT" "$VPS_CADDYFILE_PRESENT"
    printf '  Nginx binary: %s\n' "$VPS_NGINX_PRESENT"
    printf '  configured safety: %s (%s)\n' "$VPS_SAFE_CONFIG" "$VPS_CONFIG_SAFETY_REASON"
}

vps_print_json_discover() {
    bootstrap_json_start
    bootstrap_json_field script "$VPS_PROGRAM"
    bootstrap_json_field command discover
    bootstrap_json_field root "$BOOTSTRAP_ROOT"
    bootstrap_json_field os_id "$VPS_OS_ID"
    bootstrap_json_field os_version "$VPS_OS_VERSION_ID"
    bootstrap_json_field architecture "$VPS_ARCH"
    bootstrap_json_field headscale_version "$VPS_HEADSCALE_VERSION"
    bootstrap_json_field config_present "$VPS_CONFIG_PRESENT"
    bootstrap_json_field data_present "$VPS_DATA_PRESENT"
    bootstrap_json_field service_active "$VPS_SERVICE_ACTIVE"
    bootstrap_json_field service_enabled "$VPS_SERVICE_ENABLED"
    bootstrap_json_field server_url "$VPS_CURRENT_SERVER_URL"
    bootstrap_json_field listen_addr "$VPS_CURRENT_LISTEN"
    bootstrap_json_field metrics_listen_addr "$VPS_CURRENT_METRICS_LISTEN"
    bootstrap_json_field grpc_listen_addr "$VPS_CURRENT_GRPC_LISTEN"
    bootstrap_json_field tls_cert_path "$VPS_CURRENT_TLS_CERT"
    bootstrap_json_field tls_key_path "$VPS_CURRENT_TLS_KEY"
    bootstrap_json_field trusted_proxies "$VPS_CURRENT_TRUSTED_PROXIES"
    bootstrap_json_field embedded_derp_enabled "$VPS_CURRENT_DERP_ENABLED"
    bootstrap_json_field domain "${VPS_EFFECTIVE_DOMAIN:-unknown}"
    bootstrap_json_field dns_status "$VPS_DNS_STATUS"
    bootstrap_json_field dns_match "$VPS_DNS_MATCH"
    bootstrap_json_field dns_addresses "${VPS_DNS_IPS:-none}"
    bootstrap_json_field port_80 "$VPS_PORT_80"
    bootstrap_json_field port_443 "$VPS_PORT_443"
    bootstrap_json_field port_8080 "$VPS_PORT_8080"
    bootstrap_json_field port_9090 "$VPS_PORT_9090"
    bootstrap_json_field port_50443 "$VPS_PORT_50443"
    bootstrap_json_field owner_80 "${VPS_OWNER_80:-unknown}"
    bootstrap_json_field owner_443 "${VPS_OWNER_443:-unknown}"
    bootstrap_json_field owner_8080 "${VPS_OWNER_8080:-unknown}"
    bootstrap_json_field owner_9090 "${VPS_OWNER_9090:-unknown}"
    bootstrap_json_field owner_50443 "${VPS_OWNER_50443:-unknown}"
    bootstrap_json_field udp_3478 "$VPS_PORT_3478_UDP"
    bootstrap_json_field docker_openresty "$VPS_DOCKER_OPENRESTY"
    bootstrap_json_field docker_network_mode "$VPS_DOCKER_NETWORK_MODE"
    bootstrap_json_field panel_mount_www "$VPS_PANEL_MOUNT_WWW"
    bootstrap_json_field panel_mount_confd "$VPS_PANEL_MOUNT_CONFD"
    bootstrap_json_field panel_vhost_present "$([ -n "$VPS_PANEL_VHOST_PATH" ] && printf yes || printf no)"
    bootstrap_json_field panel_proxy_root_present "$VPS_PANEL_ROOT_PRESENT"
    bootstrap_json_field panel_proxy_buffering "$VPS_PANEL_BUFFERING"
    bootstrap_json_field caddy_present "$VPS_CADDY_PRESENT"
    bootstrap_json_field nginx_present "$VPS_NGINX_PRESENT"
    bootstrap_json_field safety "$VPS_SAFE_CONFIG"
    bootstrap_json_field safety_reason "$VPS_CONFIG_SAFETY_REASON"
    bootstrap_json_end
}

vps_print_discover() {
    vps_collect_facts
    vps_safe_config_state
    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        vps_print_json_discover
    else
        vps_print_text_discover
    fi
}

vps_plan() {
    vps_collect_facts
    vps_safe_config_state
    vps_effective_proxy
    vps_plan_blocked=0
    vps_block_reasons=

    if [ "$VPS_CONFIG_PRESENT" = yes ] && [ -n "$VPS_DOMAIN" ] && [ -n "$VPS_DETECTED_DOMAIN" ] && [ "$VPS_DOMAIN" != "$VPS_DETECTED_DOMAIN" ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons existing-server-url-domain-differs"
    fi
    if [ "$VPS_DATA_PRESENT" = yes ] && [ "$VPS_CONFIG_PRESENT" != yes ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons data-present-without-config"
    fi
    if [ -n "$VPS_VERSION" ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons version-transaction-not-implemented-in-milestone-1"
    fi
    if [ "$VPS_ENABLE_DERP" = true ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons embedded-derp-transaction-not-implemented-in-milestone-1"
    fi
    [ -n "$VPS_EFFECTIVE_DOMAIN" ] || {
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons missing-domain"
    }
    case "$VPS_EFFECTIVE_DOMAIN" in
        *[!A-Za-z0-9.-]*|.*|*.)
            if [ -n "$VPS_EFFECTIVE_DOMAIN" ]; then
                vps_plan_blocked=1
                vps_block_reasons="$vps_block_reasons invalid-domain"
            fi
            ;;
    esac
    if [ "$VPS_DNS_STATUS" != resolved ] || [ "$VPS_DNS_MATCH" != match ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons dns-not-confirmed-or-proxied"
    fi
    if [ "$VPS_EFFECTIVE_PROXY" = unknown ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons proxy-ambiguous-or-port-owner-unknown"
    fi
    if [ "$VPS_PROXY_MODE" = 1panel ] && { [ "$VPS_DOCKER_OPENRESTY" != yes ] || [ "$VPS_DOCKER_NETWORK_MODE" != host ] || [ "$VPS_PANEL_MOUNT_WWW" != yes ] || [ "$VPS_PANEL_MOUNT_CONFD" != yes ]; }; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons 1panel-openresty-host-network-or-mount-not-confirmed"
    fi
    if [ "$VPS_PORT_8080" = public ] || [ "$VPS_PORT_9090" = public ] || [ "$VPS_PORT_50443" = public ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons headscale-admin-port-public"
    fi
    if [ "$VPS_CURRENT_DERP_ENABLED" = false ] && [ "$VPS_PORT_3478_UDP" != free ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons derp-disabled-but-3478-listening"
    fi
    if [ "$VPS_SAFE_CONFIG" = no ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons existing-config-unsafe"
    fi
    if [ "$VPS_EFFECTIVE_PROXY" = 1panel ] && [ "$VPS_PANEL_ROOT_PRESENT" != yes ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons 1panel-site-or-proxy-root-not-found"
    fi
    if [ "$VPS_EFFECTIVE_PROXY" = caddy ] && ! vps_proxy_listener_ownership_ok caddy; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons caddy-does-not-own-80-and-443"
    fi
    if [ "$VPS_EFFECTIVE_PROXY" = nginx ] && ! vps_proxy_listener_ownership_ok nginx; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons nginx-does-not-own-80-and-443"
    fi
    if [ "$VPS_EFFECTIVE_PROXY" != none ] && [ "$VPS_PORT_80" = present ] && [ "$VPS_EFFECTIVE_PROXY" != 1panel ] && [ "$VPS_EFFECTIVE_PROXY" != nginx ] && [ "$VPS_EFFECTIVE_PROXY" != caddy ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons unknown-service-on-80"
    fi
    if [ "$VPS_EFFECTIVE_PROXY" != none ] && [ "$VPS_PORT_443" = present ] && [ "$VPS_EFFECTIVE_PROXY" != 1panel ] && [ "$VPS_EFFECTIVE_PROXY" != nginx ] && [ "$VPS_EFFECTIVE_PROXY" != caddy ]; then
        vps_plan_blocked=1
        vps_block_reasons="$vps_block_reasons unknown-service-on-443"
    fi

    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$VPS_PROGRAM"
        bootstrap_json_field command plan
        bootstrap_json_field effective_proxy "$VPS_EFFECTIVE_PROXY"
        bootstrap_json_field domain "${VPS_EFFECTIVE_DOMAIN:-unknown}"
        bootstrap_json_field requested_version "${VPS_VERSION:-none}"
        bootstrap_json_field requested_embedded_derp "$VPS_ENABLE_DERP"
        bootstrap_json_field dns_status "$VPS_DNS_STATUS"
        bootstrap_json_field dns_match "$VPS_DNS_MATCH"
        bootstrap_json_field blocked_reasons "${vps_block_reasons# }"
        if [ "$vps_plan_blocked" -eq 1 ]; then bootstrap_json_bool_field blocked true; else bootstrap_json_bool_field blocked false; fi
        bootstrap_json_field mutates_system no
        bootstrap_json_end
    else
        printf 'Headscale VPS plan (read-only; no changes made)\n'
        printf 'Detected:\n'
        printf '  domain: %s\n' "${VPS_EFFECTIVE_DOMAIN:-unknown}"
        printf '  proxy requested/effective: %s/%s\n' "$VPS_PROXY_MODE" "$VPS_EFFECTIVE_PROXY"
        printf '  requested version/embedded DERP: %s/%s\n' "${VPS_VERSION:-none}" "$VPS_ENABLE_DERP"
        printf '  Headscale config/data: %s/%s\n' "$VPS_CONFIG_PRESENT" "$VPS_DATA_PRESENT"
        printf '  public listeners 80/443: %s/%s\n' "$VPS_PORT_80" "$VPS_PORT_443"
        printf '  admin listeners 8080/9090/50443: %s/%s/%s\n' "$VPS_PORT_8080" "$VPS_PORT_9090" "$VPS_PORT_50443"
        printf '  DNS: %s; match=%s%s\n' "$VPS_DNS_STATUS" "$VPS_DNS_MATCH" \
            "$( [ "$VPS_DNS_POSSIBLE_PROXY" = yes ] && printf ' (possible proxy/non-VPS answer)' )"
        printf '  current config safety: %s (%s)\n' "$VPS_SAFE_CONFIG" "$VPS_CONFIG_SAFETY_REASON"
        printf '\nWould change in a later Milestone (not now):\n'
        if [ "$VPS_CONFIG_PRESENT" = no ]; then
            printf '  - install and validate the requested Headscale package/config baseline\n'
        else
            printf '  - back up and patch only managed Headscale keys after configtest succeeds\n'
        fi
        if [ "$VPS_CURRENT_TRUSTED_PROXIES" != '[127.0.0.1/32,::1/128]' ]; then
            printf '  - add only loopback trusted_proxies for the reverse proxy, preserving unrelated config\n'
        fi
        case "$VPS_EFFECTIVE_PROXY" in
            1panel) printf '  - back up and inspect the existing 1Panel proxy root; test then reload OpenResty only\n' ;;
            caddy) printf '  - manage a dedicated Caddy fragment; validate then reload Caddy only\n' ;;
            nginx) printf '  - inspect a dedicated Nginx/OpenResty block; test then reload the existing proxy only\n' ;;
            none) printf '  - keep TLS ownership explicit; no public plaintext Headscale listener\n' ;;
            *) printf '  - no proxy change can be planned until ownership is unambiguous\n' ;;
        esac
        printf '\nWill NOT change in this milestone:\n'
        printf '  - no package install, service restart/reload, config write, database write, DNS/Cloudflare change, or process kill\n'
        printf '  - no public bind for 8080/9090/50443; no unconditional 3478/udp opening\n'
        if [ "$vps_plan_blocked" -eq 1 ]; then
            printf '\nBLOCKED: %s\n' "${vps_block_reasons# }"
        else
            printf '\nREADY FOR FUTURE MILESTONE: discovery did not find a hard conflict.\n'
        fi
    fi

    if [ "$vps_plan_blocked" -eq 0 ]; then
        return 0
    fi
    return 2
}

vps_run_configtest() {
    VPS_CONFIGTEST=not-run
    [ "$VPS_CONFIG_PRESENT" = yes ] || return 0
    bootstrap_command_exists headscale || return 0
    if headscale -c "$VPS_CONFIG_PATH" configtest >/dev/null 2>&1; then
        VPS_CONFIGTEST=pass
    else
        VPS_CONFIGTEST=fail
    fi
}

vps_health_code() {
    vps_health_url=$1
    if ! bootstrap_command_exists curl; then
        printf 'unavailable\n'
        return 0
    fi
    vps_health_result=$(curl --silent --show-error --max-time 5 --output /dev/null --write-out '%{http_code}' "$vps_health_url" 2>/dev/null)
    case "$vps_health_result" in
        2??) printf '%s\n' "$vps_health_result" ;;
        '') printf 'failed\n' ;;
        *) printf '%s\n' "$vps_health_result" ;;
    esac
}

vps_status() {
    vps_collect_facts
    vps_safe_config_state
    vps_run_configtest
    VPS_LOCAL_HEALTH=not-tested
    VPS_PUBLIC_HEALTH=not-tested
    if [ "$VPS_CONFIG_PRESENT" = yes ] && [ "$VPS_CURRENT_LISTEN" != unknown ]; then
        VPS_LOCAL_HEALTH=$(vps_health_code "http://$VPS_CURRENT_LISTEN/health")
    fi
    if [ -n "$VPS_EFFECTIVE_DOMAIN" ]; then
        VPS_PUBLIC_HEALTH=$(vps_health_code "https://$VPS_EFFECTIVE_DOMAIN/health")
    fi

    VPS_STATUS_CODE=0
    VPS_STATUS_REASONS=
    if [ "$VPS_CONFIG_PRESENT" != yes ]; then
        VPS_STATUS_CODE=2
        VPS_STATUS_REASONS="$VPS_STATUS_REASONS headscale-config-missing"
    else
        [ "$VPS_SAFE_CONFIG" = yes ] || { VPS_STATUS_CODE=2; VPS_STATUS_REASONS="$VPS_STATUS_REASONS unsafe-config"; }
        [ "$VPS_CONFIGTEST" = pass ] || { VPS_STATUS_CODE=2; VPS_STATUS_REASONS="$VPS_STATUS_REASONS configtest-$VPS_CONFIGTEST"; }
        [ "$VPS_SERVICE_ACTIVE" = active ] || { VPS_STATUS_CODE=2; VPS_STATUS_REASONS="$VPS_STATUS_REASONS service-not-active"; }
        [ "$VPS_LOCAL_HEALTH" = 200 ] || { VPS_STATUS_CODE=2; VPS_STATUS_REASONS="$VPS_STATUS_REASONS local-health-$VPS_LOCAL_HEALTH"; }
        [ "$VPS_PUBLIC_HEALTH" = 200 ] || { VPS_STATUS_CODE=2; VPS_STATUS_REASONS="$VPS_STATUS_REASONS public-health-$VPS_PUBLIC_HEALTH"; }
        if [ "$VPS_DNS_STATUS" != resolved ] || [ "$VPS_DNS_MATCH" != match ]; then
            VPS_STATUS_CODE=2
            VPS_STATUS_REASONS="$VPS_STATUS_REASONS dns-not-confirmed-or-proxied"
        fi
    fi
    if [ "$VPS_PORT_8080" = public ] || [ "$VPS_PORT_9090" = public ] || [ "$VPS_PORT_50443" = public ]; then
        VPS_STATUS_CODE=2
        VPS_STATUS_REASONS="$VPS_STATUS_REASONS admin-port-public"
    fi
    if [ "$VPS_CURRENT_DERP_ENABLED" = false ] && [ "$VPS_PORT_3478_UDP" != free ]; then
        VPS_STATUS_CODE=2
        VPS_STATUS_REASONS="$VPS_STATUS_REASONS derp-disabled-but-3478-listening"
    fi

    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$VPS_PROGRAM"
        bootstrap_json_field command status
        bootstrap_json_field configtest "$VPS_CONFIGTEST"
        bootstrap_json_field local_health "$VPS_LOCAL_HEALTH"
        bootstrap_json_field public_health "$VPS_PUBLIC_HEALTH"
        bootstrap_json_field service_active "$VPS_SERVICE_ACTIVE"
        bootstrap_json_field service_enabled "$VPS_SERVICE_ENABLED"
        bootstrap_json_field safety "$VPS_SAFE_CONFIG"
        bootstrap_json_field safety_reasons "${VPS_STATUS_REASONS# }"
        if [ "$VPS_STATUS_CODE" -eq 0 ]; then bootstrap_json_bool_field ok true; else bootstrap_json_bool_field ok false; fi
        bootstrap_json_end
    else
        printf 'Headscale VPS status (read-only)\n'
        printf '  version: %s\n' "$VPS_HEADSCALE_VERSION"
        printf '  service active/enabled: %s/%s\n' "$VPS_SERVICE_ACTIVE" "$VPS_SERVICE_ENABLED"
        printf '  configtest: %s\n' "$VPS_CONFIGTEST"
        printf '  local /health: %s\n' "$VPS_LOCAL_HEALTH"
        printf '  public /health: %s\n' "$VPS_PUBLIC_HEALTH"
        printf '  listeners admin 8080/9090/50443: %s/%s/%s\n' "$VPS_PORT_8080" "$VPS_PORT_9090" "$VPS_PORT_50443"
        printf '  UDP 3478: %s (embedded DERP=%s)\n' "$VPS_PORT_3478_UDP" "$VPS_CURRENT_DERP_ENABLED"
        printf '  safety: %s (%s)\n' "$VPS_SAFE_CONFIG" "$VPS_CONFIG_SAFETY_REASON"
        if [ "$VPS_STATUS_CODE" -eq 0 ]; then
            printf 'OK\n'
        else
            printf 'FAIL: %s\n' "${VPS_STATUS_REASONS# }"
        fi
    fi

    return "$VPS_STATUS_CODE"
}

vps_backup() {
    vps_collect_facts
    bootstrap_sha256_available || die 'backup requires sha256sum, shasum, or openssl'
    if [ "$BOOTSTRAP_ROOT" = / ] && [ "$(id -u 2>/dev/null || printf 1)" != 0 ]; then
        die 'backup of the real VPS requires root; use --root DIR only for an explicit fixture'
    fi

    VPS_BACKUP_BASE=$(bootstrap_root_path "$VPS_BACKUP_DIR")
    VPS_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
    VPS_BACKUP_ROOT=$(backup_allocate_directory "$VPS_BACKUP_BASE" "$VPS_BACKUP_TIMESTAMP") || die "cannot allocate backup directory below: $VPS_BACKUP_BASE"
    VPS_BACKUP_ID=${VPS_BACKUP_ROOT##*/}
    chmod 700 "$VPS_BACKUP_ROOT" 2>/dev/null || true
    backup_mark_incomplete "$VPS_BACKUP_ROOT"

    backup_copy_path "$VPS_CONFIG_DIR" "$VPS_BACKUP_ROOT/source/etc/headscale" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        die 'failed to copy /etc/headscale; incomplete backup retained'
    }
    backup_copy_path "$VPS_DATA_PATH" "$VPS_BACKUP_ROOT/source/var/lib/headscale" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        die 'failed to copy /var/lib/headscale; incomplete backup retained'
    }
    backup_copy_path "$VPS_UNIT_PATH" "$VPS_BACKUP_ROOT/source/usr/lib/systemd/system/headscale.service" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        die 'failed to copy headscale.service; incomplete backup retained'
    }

    if [ -n "$VPS_PANEL_VHOST_PATH" ]; then
        backup_copy_path "$VPS_PANEL_VHOST_PATH" "$VPS_BACKUP_ROOT/proxy/vhost.conf" || {
            backup_mark_incomplete "$VPS_BACKUP_ROOT"
            die 'failed to copy detected 1Panel vhost; incomplete backup retained'
        }
    fi
    if [ "$VPS_PANEL_ROOT_PRESENT" = yes ]; then
        backup_copy_path "$VPS_PANEL_ROOT_CONF" "$VPS_BACKUP_ROOT/proxy/root.conf" || {
            backup_mark_incomplete "$VPS_BACKUP_ROOT"
            die 'failed to copy detected 1Panel proxy root; incomplete backup retained'
        }
    fi
    if [ "$VPS_CADDYFILE_PRESENT" = yes ] && { [ "$VPS_PROXY_MODE" = caddy ] || [ "$VPS_PROXY_MODE" = auto ]; }; then
        backup_copy_path "$(bootstrap_root_path /etc/caddy/Caddyfile)" "$VPS_BACKUP_ROOT/proxy/Caddyfile" || {
            backup_mark_incomplete "$VPS_BACKUP_ROOT"
            die 'failed to copy detected Caddyfile; incomplete backup retained'
        }
    fi

    {
        printf 'vhost_source=%s\n' "${VPS_PANEL_VHOST_PATH:-absent}"
        printf 'proxy_root_source=%s\n' "${VPS_PANEL_ROOT_CONF:-absent}"
        printf 'domain=%s\n' "${VPS_EFFECTIVE_DOMAIN:-unknown}"
        printf 'headscale_version=%s\n' "$VPS_HEADSCALE_VERSION"
    } > "$VPS_BACKUP_ROOT/proxy/paths.txt"
    chmod 600 "$VPS_BACKUP_ROOT/proxy/paths.txt" 2>/dev/null || true
    printf '%s\n' "$VPS_HEADSCALE_VERSION" > "$VPS_BACKUP_ROOT/package-version.txt"
    chmod 600 "$VPS_BACKUP_ROOT/package-version.txt" 2>/dev/null || true

    backup_finish "$VPS_BACKUP_ROOT" "$VPS_PROGRAM" "$BOOTSTRAP_ROOT" "$VPS_BACKUP_TIMESTAMP" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        die 'failed to finalize backup manifest; incomplete backup retained'
    }

    if [ "$BOOTSTRAP_JSON" = 1 ]; then
        bootstrap_json_start
        bootstrap_json_field script "$VPS_PROGRAM"
        bootstrap_json_field command backup
        bootstrap_json_field backup_id "$VPS_BACKUP_ID"
        bootstrap_json_field backup_path "$VPS_BACKUP_ROOT"
        bootstrap_json_field manifest manifest.sha256
        bootstrap_json_field secret_contents not-logged
        bootstrap_json_end
    else
        printf 'Backup created: %s\n' "$VPS_BACKUP_ROOT"
        printf 'Manifest: %s\n' "$VPS_BACKUP_ROOT/manifest.sha256"
        printf 'Secret contents were not printed; backup permissions are private.\n'
    fi
}

vps_reserved_command() {
    log_error "$VPS_COMMAND is reserved for a later Milestone and is fail-closed in this build"
    log_error 'No package, service, config, database, DNS, proxy, UCI, netifd, or firewall change was attempted'
    exit 2
}

vps_main() {
    vps_parse_args "$@"
    case "$VPS_COMMAND" in
        discover) vps_print_discover ;;
        plan) vps_plan ;;
        status|verify) vps_status ;;
        backup) vps_backup ;;
        *) vps_reserved_command ;;
    esac
}

vps_main "$@"
