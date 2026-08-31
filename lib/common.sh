#!/bin/sh

# POSIX shell helpers.  These functions deliberately avoid sourcing any target
# configuration file: target files may contain secrets or shell syntax owned by
# another administrator.

bootstrap_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

bootstrap_root_path() {
    bootstrap_root_arg=$1
    if [ "${BOOTSTRAP_ROOT:-/}" = "/" ]; then
        printf '%s\n' "$bootstrap_root_arg"
        return 0
    fi

    case "$bootstrap_root_arg" in
        /*) printf '%s%s\n' "$BOOTSTRAP_ROOT" "$bootstrap_root_arg" ;;
        *) printf '%s/%s\n' "$BOOTSTRAP_ROOT" "$bootstrap_root_arg" ;;
    esac
}

bootstrap_normalize_root() {
    bootstrap_root_input=$1
    [ -d "$bootstrap_root_input" ] || return 1
    (CDPATH= cd "$bootstrap_root_input" 2>/dev/null && pwd -P)
}

bootstrap_path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

bootstrap_read_first_line() {
    bootstrap_read_file=$1
    [ -r "$bootstrap_read_file" ] || return 1
    sed -n '1p' "$bootstrap_read_file" 2>/dev/null
}

bootstrap_active_config_lines() {
    # Drop full-line comments only.  Trailing comments stay, so an active
    # directive with an inline note is still matched.  This keeps grep-based
    # directive checks from firing on the commented-out defaults that ship in
    # luci-app-tailscale and generated nginx configs.
    bootstrap_active_file=$1
    [ -r "$bootstrap_active_file" ] || return 0
    sed -e '/^[[:space:]]*#/d' "$bootstrap_active_file" 2>/dev/null
}

bootstrap_trim() {
    # awk collapses leading/trailing whitespace without evaluating the value.
    printf '%s\n' "$1" | awk '{$1=$1; print}'
}

bootstrap_strip_yaml_scalar() {
    if [ "$#" -gt 0 ]; then
        bootstrap_yaml_value=$1
    else
        bootstrap_yaml_value=
        IFS= read -r bootstrap_yaml_value || true
    fi
    bootstrap_yaml_value=$(bootstrap_trim "$bootstrap_yaml_value")
    case "$bootstrap_yaml_value" in
        \"*\")
            bootstrap_yaml_value=${bootstrap_yaml_value#\"}
            bootstrap_yaml_value=${bootstrap_yaml_value%\"}
            ;;
        \'*\')
            bootstrap_yaml_value=${bootstrap_yaml_value#\'}
            bootstrap_yaml_value=${bootstrap_yaml_value%\'}
            ;;
    esac
    printf '%s\n' "$bootstrap_yaml_value"
}

bootstrap_yaml_scalar() {
    bootstrap_yaml_file=$1
    bootstrap_yaml_key=$2
    [ -r "$bootstrap_yaml_file" ] || return 1

    awk -v wanted="$bootstrap_yaml_key" '
        $0 ~ "^[[:space:]]*" wanted "[[:space:]]*:" {
            value=$0
            sub("^[[:space:]]*" wanted "[[:space:]]*:[[:space:]]*", "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            print value
            exit
        }
    ' "$bootstrap_yaml_file" 2>/dev/null | bootstrap_strip_yaml_scalar
}

bootstrap_yaml_nested_scalar() {
    bootstrap_yaml_file=$1
    bootstrap_yaml_parent=$2
    bootstrap_yaml_child=$3
    [ -r "$bootstrap_yaml_file" ] || return 1

    awk -v parent="$bootstrap_yaml_parent" -v child="$bootstrap_yaml_child" '
        function indent(line, n) {
            n=0
            while (substr(line, n + 1, 1) == " ") n++
            return n
        }
        {
            line_indent=indent($0)
            if ($0 ~ "^[[:space:]]*" parent "[[:space:]]*:") {
                parent_indent=line_indent
                in_parent=1
                in_child=0
                next
            }
            if (in_parent && line_indent <= parent_indent && $0 !~ /^[[:space:]]*$/) {
                in_parent=0
                in_child=0
            }
            if (in_parent && $0 ~ "^[[:space:]]*" child "[[:space:]]*:") {
                value=$0
                sub("^[[:space:]]*" child "[[:space:]]*:[[:space:]]*", "", value)
                sub(/[[:space:]]+#.*$/, "", value)
                print value
                exit
            }
        }
    ' "$bootstrap_yaml_file" 2>/dev/null | bootstrap_strip_yaml_scalar
}

bootstrap_yaml_triple_scalar() {
    bootstrap_yaml_file=$1
    bootstrap_yaml_top=$2
    bootstrap_yaml_middle=$3
    bootstrap_yaml_child=$4
    [ -r "$bootstrap_yaml_file" ] || return 1

    awk -v top="$bootstrap_yaml_top" -v middle="$bootstrap_yaml_middle" -v child="$bootstrap_yaml_child" '
        function indent(line, n) {
            n=0
            while (substr(line, n + 1, 1) == " ") n++
            return n
        }
        {
            line_indent=indent($0)
            if ($0 ~ "^[[:space:]]*" top "[[:space:]]*:") {
                top_indent=line_indent
                in_top=1
                in_middle=0
                next
            }
            if (in_top && line_indent <= top_indent && $0 !~ /^[[:space:]]*$/) {
                in_top=0
                in_middle=0
            }
            if (in_top && $0 ~ "^[[:space:]]*" middle "[[:space:]]*:") {
                middle_indent=line_indent
                in_middle=1
                next
            }
            if (in_middle && line_indent <= middle_indent && $0 !~ /^[[:space:]]*$/) {
                in_middle=0
            }
            if (in_middle && $0 ~ "^[[:space:]]*" child "[[:space:]]*:") {
                value=$0
                sub("^[[:space:]]*" child "[[:space:]]*:[[:space:]]*", "", value)
                sub(/[[:space:]]+#.*$/, "", value)
                print value
                exit
            }
        }
    ' "$bootstrap_yaml_file" 2>/dev/null | bootstrap_strip_yaml_scalar
}

bootstrap_yaml_triple_list() {
    # bootstrap_yaml_triple_list FILE TOP MIDDLE CHILD — print the "- item"
    # entries of the list under TOP -> MIDDLE -> CHILD, one per line.
    bootstrap_yaml_file=$1
    bootstrap_yaml_top=$2
    bootstrap_yaml_middle=$3
    bootstrap_yaml_child=$4
    [ -r "$bootstrap_yaml_file" ] || return 1

    awk -v top="$bootstrap_yaml_top" -v middle="$bootstrap_yaml_middle" -v child="$bootstrap_yaml_child" '
        function indent(line, n) {
            n=0
            while (substr(line, n + 1, 1) == " ") n++
            return n
        }
        {
            line_indent=indent($0)
            if ($0 ~ "^[[:space:]]*" top "[[:space:]]*:") {
                top_indent=line_indent
                in_top=1
                in_middle=0
                in_child=0
                next
            }
            if (in_top && line_indent <= top_indent && $0 !~ /^[[:space:]]*$/) {
                in_top=0
                in_middle=0
                in_child=0
            }
            if (in_top && $0 ~ "^[[:space:]]*" middle "[[:space:]]*:") {
                middle_indent=line_indent
                in_middle=1
                in_child=0
                next
            }
            if (in_middle && line_indent <= middle_indent && $0 !~ /^[[:space:]]*$/) {
                in_middle=0
                in_child=0
            }
            if (in_middle && $0 ~ "^[[:space:]]*" child "[[:space:]]*:") {
                child_indent=line_indent
                in_child=1
                next
            }
            if (in_child) {
                if (line_indent <= child_indent && $0 !~ /^[[:space:]]*$/) { exit }
                if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                    item=$0
                    sub(/^[[:space:]]*-[[:space:]]*/, "", item)
                    sub(/[[:space:]]+#.*$/, "", item)
                    print item
                }
            }
        }
    ' "$bootstrap_yaml_file" 2>/dev/null
}

bootstrap_json_escape() {
    # Values are summaries, never raw secret files.  Still escape all JSON
    # control characters so an unexpected newline cannot corrupt --json.
    printf '%s' "$1" | awk '
        BEGIN { ORS="" }
        {
            if (NR > 1) printf "\\n"
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            printf "%s", $0
        }
    '
}

bootstrap_json_start() {
    BOOTSTRAP_JSON_FIRST=1
    printf '{'
}

bootstrap_json_field() {
    bootstrap_json_key=$1
    bootstrap_json_value=$2
    if [ "${BOOTSTRAP_JSON_FIRST:-1}" != "1" ]; then
        printf ','
    fi
    printf '"%s":"%s"' \
        "$(bootstrap_json_escape "$bootstrap_json_key")" \
        "$(bootstrap_json_escape "$bootstrap_json_value")"
    BOOTSTRAP_JSON_FIRST=0
}

bootstrap_json_bool_field() {
    bootstrap_json_key=$1
    bootstrap_json_value=$2
    if [ "${BOOTSTRAP_JSON_FIRST:-1}" != "1" ]; then
        printf ','
    fi
    case "$bootstrap_json_value" in
        true|false|null) ;;
        *) bootstrap_json_value=false ;;
    esac
    printf '"%s":%s' \
        "$(bootstrap_json_escape "$bootstrap_json_key")" \
        "$bootstrap_json_value"
    BOOTSTRAP_JSON_FIRST=0
}

bootstrap_json_end() {
    printf '}\n'
}

bootstrap_sha256_only() {
    bootstrap_hash_file=$1
    if bootstrap_command_exists sha256sum; then
        bootstrap_hash_output=$(sha256sum "$bootstrap_hash_file" 2>/dev/null) || return 1
        printf '%s\n' "$bootstrap_hash_output" | awk '{print $1}'
        return 0
    fi
    if bootstrap_command_exists shasum; then
        bootstrap_hash_output=$(shasum -a 256 "$bootstrap_hash_file" 2>/dev/null) || return 1
        printf '%s\n' "$bootstrap_hash_output" | awk '{print $1}'
        return 0
    fi
    if bootstrap_command_exists openssl; then
        bootstrap_hash_output=$(openssl dgst -sha256 "$bootstrap_hash_file" 2>/dev/null) || return 1
        printf '%s\n' "$bootstrap_hash_output" | sed 's/^.*= //'
        return 0
    fi
    return 127
}

bootstrap_sha256_available() {
    bootstrap_command_exists sha256sum || \
        bootstrap_command_exists shasum || \
        bootstrap_command_exists openssl
}

bootstrap_file_mode() {
    bootstrap_mode_file=$1
    if bootstrap_command_exists stat; then
        stat -c '%a' "$bootstrap_mode_file" 2>/dev/null || \
            stat -f '%Lp' "$bootstrap_mode_file" 2>/dev/null
    fi
}

bootstrap_is_loopback_addr() {
    case "$1" in
        127.*|localhost:*|\[::1\]:*|::1:*) return 0 ;;
        *) return 1 ;;
    esac
}

bootstrap_is_https_url() {
    case "$1" in
        https://?*) return 0 ;;
        *) return 1 ;;
    esac
}

bootstrap_normalize_url() {
    bootstrap_url=$1
    case "$bootstrap_url" in
        */) bootstrap_url=${bootstrap_url%/} ;;
    esac
    printf '%s\n' "$bootstrap_url"
}

bootstrap_capture_first_line() {
    # The caller controls the command.  Only the first line is returned so a
    # verbose service/status command cannot accidentally become a log stream.
    "$@" 2>/dev/null | sed -n '1p'
}

bootstrap_reason_hint() {
    # Maps one block/status reason tag to a one-line cause + suggested fix.
    # Unknown tags print nothing so new tags never break output; the tag list
    # printed by the caller stays the authoritative summary.
    case "$1" in
        # --- shared OpenWrt plan/mutate/status tags ------------------------
        missing-login-server)
            printf 'no control server is known. Fix: pass --login-server https://hs.example.com, or run install first so state.json records one.' ;;
        login-server-not-https)
            printf 'the control server URL is not https://. Fix: put Headscale behind TLS (Caddy/Nginx/1Panel) and pass the https:// URL.' ;;
        different-existing-controlurl|requested-controlurl-differs)
            printf 'the node is registered with a different control server; this script never switches networks silently. Fix: re-run with the current URL, use switch-to/profile-add, or purge-identity --yes-i-understand.' ;;
        tun-missing)
            printf '/dev/net/tun is absent so tailscaled cannot create tailscale0. Fix: opkg install kmod-tun and reboot; LXC/Docker hosts must also expose /dev/net/tun to the guest.' ;;
        fw4-nftables-baseline-not-confirmed)
            printf 'core mode requires fw4 + nftables (OpenWrt 22.03+). Fix: opkg install fw4 nftables, or use an image that ships fw4.' ;;
        unsafe-native-luci-helper)
            printf 'native mode was requested but the installed luci-app-tailscale helper is not proven safe. Fix: use --service-mode core (default) or remove luci-app-tailscale.' ;;
        native-init-not-found)
            printf 'native mode needs the stock /etc/init.d/tailscale. Fix: install the tailscale package first, or use --service-mode core.' ;;
        uci-not-found)
            printf 'the uci CLI is missing. Fix: this is not a standard OpenWrt image; use the official image or install the uci package.' ;;
        unverified-tailscale-core)
            printf '/etc/init.d/tailscale-core does not match the verified template. Fix: run install or apply, which backs it up and restores the template (plan stays strict until then).' ;;
        existing-network-tailscale-section|network-tailscale-section-present)
            printf 'a netifd section network.tailscale exists and would fight tailscale0. Fix: uci delete network.tailscale && uci commit network (only if you know who created it).' ;;
        pending-network-uci-changes|network-uci-not-clean-or-unknown)
            printf 'uncommitted (or unreadable) UCI network changes. Fix: run "uci changes network"; revert with uci revert network or commit deliberately, then re-run.' ;;
        pending-firewall-uci-changes|firewall-uci-not-clean-or-unknown)
            printf 'uncommitted (or unreadable) UCI firewall changes. Fix: run "uci changes firewall"; revert with uci revert firewall or commit deliberately, then re-run.' ;;
        exit-node-or-default-route-risk|exit-node-risk)
            printf '0.0.0.0/0 or ::/0 is advertised (an exit node would hijack this router). Fix: tailscale set --advertise-routes= without the default route.' ;;
        failover-service-missing)
            printf 'failover is enabled but /etc/init.d/tailscale-failover is absent. Fix: re-run enable-failover, which deploys the service.' ;;
        failover-unverified-fingerprint)
            printf '/etc/init.d/tailscale-failover differs from the verified template. Fix: re-run enable-failover to redeploy it (existing file is backed up).' ;;
        failover-watchdog-missing-or-unverified)
            printf 'the failover watchdog script is missing or modified. Fix: re-run enable-failover to redeploy it.' ;;
        failover-under-two-profiles)
            printf 'failover needs at least two profiles to switch between. Fix: profile-add the backup server before enabling failover.' ;;
        failover-service-not-enabled-at-boot)
            printf 'the failover service is not enabled at boot. Fix: re-run enable-failover, or /etc/init.d/tailscale-failover enable.' ;;
        # --- OpenWrt status-only tags --------------------------------------
        tailscale-package-missing)
            printf 'the tailscale package is not installed. Fix: run install, or opkg/apk install tailscale.' ;;
        controlurl-unknown)
            printf 'tailscaled has no registration yet (no ControlURL). Fix: run join with a fresh auth key.' ;;
        backend-state-unknown)
            printf 'tailscale status cannot be read. Fix: check that tailscaled runs: logread | grep tailscaled.' ;;
        backend-not-running)
            printf 'tailscaled is not in Running state. Fix: logread | grep tailscaled for the error, then /etc/init.d/tailscale-core start.' ;;
        backend-running-without-tailscale0)
            printf 'tailscaled runs but tailscale0 was never created. Fix: logread usually shows a tun error; check kmod-tun and /dev/net/tun.' ;;
        tailscale0-not-bound-to-fw4-zone)
            printf 'tailscale0 is not in the fw4 tailscale zone. Fix: run apply to repair the zone binding.' ;;
        unsafe-accept-dns)
            printf 'accept-dns=true can hijack the router resolver. Fix: tailscale set --accept-dns=false, or run apply to converge it.' ;;
        accept-routes-without-site-to-site)
            printf 'accept-routes=true while site-to-site is off. Fix: run enable-site-to-site to match the marker, or apply to converge it back to false.' ;;
        ts_to_lan-references-missing-zone)
            printf 'forwarding ts_to_lan exists but the tailscale zone is gone (fw4 would reject it). Fix: run apply or enable-subnet to repair the zone.' ;;
        lan_to_ts-references-missing-zone)
            printf 'forwarding lan_to_ts exists but the tailscale zone is gone (fw4 would reject it). Fix: run apply or enable-site-to-site to repair the zone.' ;;
        ts_to_lan-without-advertised-routes)
            printf 'ts_to_lan forwarding exists but no route is advertised. Fix: run enable-subnet, or disable-subnet to clean it up.' ;;
        site-to-site-accept-routes-off)
            printf 'the site-to-site marker is on but accept-routes is false. Fix: run apply or enable-site-to-site to converge it.' ;;
        site-to-site-ts-to-lan-missing)
            printf 'site-to-site needs the ts_to_lan forwarding. Fix: run apply or enable-site-to-site to repair it.' ;;
        site-to-site-lan-to-ts-missing)
            printf 'site-to-site needs the lan_to_ts forwarding. Fix: run apply or enable-site-to-site to repair it.' ;;
        unsafe-stock-service-enabled)
            printf 'the stock /etc/init.d/tailscale is enabled and would start a second daemon at boot. Fix: run apply (disables it), or /etc/init.d/tailscale disable.' ;;
        # --- shared VPS plan/status tags -----------------------------------
        existing-server-url-domain-differs)
            printf 'the existing config uses a different server_url domain. Fix: re-run with --domain matching it, or clean up and reinstall.' ;;
        data-present-without-config)
            printf '/var/lib/headscale has data but /etc/headscale/config.yaml is missing. Fix: restore the config, or remove the data deliberately.' ;;
        embedded-derp-not-supported-in-this-build)
            printf -- '--enable-derp is not supported by this script. Fix: drop the flag and use an external DERP server.' ;;
        missing-domain)
            printf 'no domain is known. Fix: pass --domain hs.example.com.' ;;
        invalid-domain)
            printf 'the domain contains invalid characters. Fix: use a plain FQDN (letters, digits, dots, hyphens only).' ;;
        dns-not-confirmed-or-proxied)
            printf 'the domain does not resolve to this VPS (or is proxied). Fix: create/fix the A record; on Cloudflare set the record to DNS-only or pass --expected-public-ip.' ;;
        proxy-ambiguous-or-port-owner-unknown)
            printf 'cannot tell who owns ports 80/443. Fix: pass --proxy caddy|nginx|1panel|none explicitly.' ;;
        1panel-openresty-host-network-or-mount-not-confirmed)
            printf "1Panel's OpenResty must run in host network mode with the /www and conf mounts. Fix: adjust the container, or choose another --proxy." ;;
        headscale-admin-port-public|admin-port-public)
            printf 'an admin port (8080/9090/50443) listens publicly. Fix: bind those services to 127.0.0.1 or firewall them off.' ;;
        derp-disabled-but-3478-listening)
            printf 'UDP 3478 is occupied while embedded DERP is off. Fix: stop the service holding 3478 (check ss -ulnp), or enable DERP on it.' ;;
        existing-config-unsafe)
            printf 'the existing config has keys outside the managed baseline. Fix: apply rewrites the managed keys with a backup; review /etc/headscale/config.yaml.' ;;
        1panel-site-or-proxy-root-not-found)
            printf 'the 1Panel site/proxy root was not found. Fix: create the website in 1Panel first, then re-run.' ;;
        caddy-does-not-own-80-and-443)
            printf 'caddy was selected but does not own 80/443. Fix: free the ports (ss -tlnp) or select the owning --proxy.' ;;
        nginx-does-not-own-80-and-443)
            printf 'nginx was selected but does not own 80/443. Fix: free the ports (ss -tlnp) or select the owning --proxy.' ;;
        unknown-service-on-80|unknown-service-on-443)
            printf 'an unrecognized service holds the port. Fix: identify it (ss -tlnp), stop it, or run with --proxy none.' ;;
        # --- VPS status-only tags ------------------------------------------
        headscale-config-missing)
            printf '/etc/headscale/config.yaml is missing. Fix: run install to create the managed baseline.' ;;
        unsafe-config)
            printf 'the config fails the safety audit. Fix: run apply to rewrite the managed keys; see the safety reason above.' ;;
        configtest-fail)
            printf 'headscale configtest rejected the config. Fix: headscale -c /etc/headscale/config.yaml configtest prints the exact error.' ;;
        configtest-not-run)
            printf 'configtest did not run. Fix: check that the headscale binary is installed and on PATH.' ;;
        service-not-active)
            printf 'headscale.service is not active. Fix: systemctl status headscale, then journalctl -u headscale for the error.' ;;
        local-health-*)
            printf 'the local /health endpoint did not answer 200. Fix: journalctl -u headscale; check listen_addr in the config.' ;;
        public-health-*)
            printf 'the public https://DOMAIN/health endpoint did not answer 200. Fix: check DNS, the reverse proxy, and TLS certificates.' ;;
        dns-global-resolvers-pushed)
            printf 'dns.nameservers.global is not empty, so every accept-dns=true client gets ALL its DNS rerouted to those resolvers (breaks LAN devices behind daed/dae). Fix: run enable-magic-dns (or disable-magic-dns), or empty dns.nameservers.global in /etc/headscale/config.yaml.' ;;
    esac
}

bootstrap_explain_reasons() {
    # bootstrap_explain_reasons "tag1 tag2 ..." -> one "- tag: hint" line per
    # known tag to stdout.  Callers decide the stream: log paths redirect to
    # stderr (>&2) so --json stdout stays machine-readable.
    for bootstrap_er_tag in $1; do
        bootstrap_er_hint=$(bootstrap_reason_hint "$bootstrap_er_tag")
        [ -n "$bootstrap_er_hint" ] || continue
        printf '  - %s: %s\n' "$bootstrap_er_tag" "$bootstrap_er_hint"
    done
}
