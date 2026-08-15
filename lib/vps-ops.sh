#!/bin/sh

# VPS mutating operations.  Every write follows
# the transaction model:
#   discover -> validate -> backup -> prepare temp -> syntax check -> apply
#   -> reload only the necessary service -> verify -> commit state
# Any failure restores the backup and exits nonzero.

VPS_DEFAULT_VERSION=0.29.3
VPS_DEB_URL_PREFIX=https://github.com/juanfont/headscale/releases/download

vps_require_root_real() {
    if [ "$BOOTSTRAP_ROOT" = / ] && [ "$(id -u 2>/dev/null || printf 1)" != 0 ]; then
        die "$VPS_COMMAND on the real VPS requires root"
    fi
}

vps_refresh() {
    vps_collect_facts
    vps_safe_config_state
    vps_effective_proxy
}

vps_conflict_or_die() {
    # Shared hard guards.  Mirrors vps_compute_conflicts (kept in sync with
    # plan) plus mutate-specific requirements.
    vps_refresh
    if [ "$VPS_ENABLE_DERP" = true ]; then
        die 'embedded DERP enablement is not supported in this build; refusing to proceed'
    fi
    vps_compute_conflicts mutate
    if [ "$vps_plan_blocked" -eq 1 ]; then
        log_error "blocked preconditions: ${vps_block_reasons# }"
        exit 2
    fi
}

vps_os_supported() {
    case "$VPS_OS_ID" in
        debian) [ "${VPS_OS_VERSION_ID%%.*}" -ge 12 ] 2>/dev/null && return 0 ;;
        ubuntu) [ "${VPS_OS_VERSION_ID%%.*}" -ge 22 ] 2>/dev/null && return 0 ;;
    esac
    return 1
}

vps_semver_parts() {
    printf '%s\n' "$1" | awk -F. '{ print $1 + 0, $2 + 0, $3 + 0 }'
}

vps_version_cmp() {
    version_cmp "$1" "$2"
}

vps_current_version() {
    if [ "$VPS_HEADSCALE_VERSION" != absent ] && [ "$VPS_HEADSCALE_VERSION" != present-version-unknown ]; then
        version_extract_semver "$VPS_HEADSCALE_VERSION"
    fi
}

vps_download_deb() {
    # vps_download_deb VERSION -> prints local file path
    vps_dl_version=$1
    vps_dl_dir=${TMPDIR:-/tmp}/headscale-bootstrap-download.$$
    mkdir -p "$vps_dl_dir" || return 1
    vps_dl_file="$vps_dl_dir/headscale_${vps_dl_version}_linux_${VPS_ARCH}.deb"
    log_info "downloading headscale $vps_dl_version for $VPS_ARCH"
    curl --fail --location --silent --show-error \
        -o "$vps_dl_file" \
        "$VPS_DEB_URL_PREFIX/v$vps_dl_version/headscale_${vps_dl_version}_linux_${VPS_ARCH}.deb" || {
        rm -rf "$vps_dl_dir"
        return 1
    }
    printf '%s\n' "$vps_dl_file"
}

vps_deb_metadata_ok() {
    # vps_deb_metadata_ok FILE EXPECTED_VERSION
    vps_deb_file=$1
    vps_deb_expected=$2
    vps_deb_fields=$(dpkg-deb --field "$vps_deb_file" Package Version 2>/dev/null) || {
        log_error 'dpkg-deb metadata validation failed'
        return 1
    }
    vps_deb_package=$(printf '%s\n' "$vps_deb_fields" | sed -n '1p')
    vps_deb_version=$(printf '%s\n' "$vps_deb_fields" | sed -n '2p')
    if [ "$vps_deb_package" != headscale ] || [ "$vps_deb_version" != "$vps_deb_expected" ]; then
        log_error "package metadata mismatch: got package=$vps_deb_package version=$vps_deb_version, expected headscale $vps_deb_expected"
        return 1
    fi
    return 0
}

vps_install_deb() {
    # vps_install_deb FILE
    apt-get install -y "$1" >/dev/null || {
        log_error "apt-get install failed for $1"
        return 1
    }
    return 0
}

vps_render_config() {
    # vps_render_config SRC DST — rewrite only the managed keys.
    # Everything else passes through byte for byte.  trusted_proxies is
    # normalized to the loopback block list; an existing block list is
    # consumed so no orphaned items remain.
    render_src=$1
    render_dst=$2
    render_manage_tls=true
    [ "$VPS_EFFECTIVE_PROXY" = none ] && render_manage_tls=false
    awk \
        -v server_url="https://$VPS_EFFECTIVE_DOMAIN" \
        -v listen_addr="$VPS_LISTEN" \
        -v metrics_addr="$VPS_METRICS_LISTEN" \
        -v grpc_addr="$VPS_GRPC_LISTEN" \
        -v derp_enabled="$VPS_ENABLE_DERP" \
        -v manage_tls="$render_manage_tls" '
        function indent_of(s, n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
        {
            line = $0
            ind = indent_of(line)
            if (consume_tp && line ~ /^[[:space:]]*-/) next
            consume_tp = 0
            if (in_derp_server && ind <= server_indent && line !~ /^[[:space:]]*$/) in_derp_server = 0
            if (in_derp && ind <= derp_indent && line !~ /^[[:space:]]*$/) { in_derp = 0; in_derp_server = 0 }
            if (line ~ /^server_url[[:space:]]*:/) { print "server_url: " server_url; saw["server_url"] = 1; next }
            if (line ~ /^listen_addr[[:space:]]*:/) { print "listen_addr: " listen_addr; saw["listen_addr"] = 1; next }
            if (line ~ /^metrics_listen_addr[[:space:]]*:/) { print "metrics_listen_addr: " metrics_addr; saw["metrics_listen_addr"] = 1; next }
            if (line ~ /^grpc_listen_addr[[:space:]]*:/) { print "grpc_listen_addr: " grpc_addr; saw["grpc_listen_addr"] = 1; next }
            if (line ~ /^grpc_allow_insecure[[:space:]]*:/) { print "grpc_allow_insecure: false"; saw["grpc_allow_insecure"] = 1; next }
            if (manage_tls == "true") {
                if (line ~ /^tls_cert_path[[:space:]]*:/) { print "tls_cert_path: \"\""; saw["tls_cert_path"] = 1; next }
                if (line ~ /^tls_key_path[[:space:]]*:/) { print "tls_key_path: \"\""; saw["tls_key_path"] = 1; next }
            }
            if (line ~ /^trusted_proxies[[:space:]]*:/) {
                print "trusted_proxies:"
                print "  - 127.0.0.1/32"
                print "  - ::1/128"
                saw["trusted_proxies"] = 1
                consume_tp = 1
                next
            }
            if (line ~ /^[[:space:]]*derp[[:space:]]*:/) { derp_indent = ind; in_derp = 1; print; next }
            if (in_derp && line ~ /^[[:space:]]*server[[:space:]]*:/) { server_indent = ind; in_derp_server = 1; print; next }
            if (in_derp_server && line ~ /^[[:space:]]*enabled[[:space:]]*:/) {
                printf "%*senabled: %s\n", server_indent + 2, "", derp_enabled
                saw["derp_enabled"] = 1
                next
            }
            print
        }
        END {
            if (!saw["server_url"]) print "server_url: " server_url
            if (!saw["listen_addr"]) print "listen_addr: " listen_addr
            if (!saw["metrics_listen_addr"]) print "metrics_listen_addr: " metrics_addr
            if (!saw["grpc_listen_addr"]) print "grpc_listen_addr: " grpc_addr
            if (!saw["grpc_allow_insecure"]) print "grpc_allow_insecure: false"
            if (manage_tls == "true" && !saw["tls_cert_path"]) print "tls_cert_path: \"\""
            if (manage_tls == "true" && !saw["tls_key_path"]) print "tls_key_path: \"\""
            if (!saw["trusted_proxies"]) {
                print "trusted_proxies:"
                print "  - 127.0.0.1/32"
                print "  - ::1/128"
            }
        }
    ' "$render_src" > "$render_dst"
}

vps_configtest_file() {
    headscale -c "$1" configtest >/dev/null 2>&1
}

vps_config_write_transaction() {
    # vps_config_write_transaction RENDERED_TMP
    # backup -> configtest(tmp) -> atomic replace; caller restarts.
    vps_cwt_tmp=$1
    vps_configtest_file "$vps_cwt_tmp" || {
        log_error 'headscale configtest rejected the rendered config; nothing was changed'
        return 1
    }
    VPS_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
    VPS_BACKUP_ROOT=$(backup_allocate_directory "$(bootstrap_root_path "$VPS_BACKUP_DIR")" "$VPS_BACKUP_TIMESTAMP") || {
        log_error 'cannot allocate backup directory'
        return 1
    }
    chmod 700 "$VPS_BACKUP_ROOT" 2>/dev/null || true
    backup_mark_incomplete "$VPS_BACKUP_ROOT"
    if [ -f "$VPS_CONFIG_PATH" ]; then
        backup_copy_path "$VPS_CONFIG_PATH" "$VPS_BACKUP_ROOT/source/etc/headscale/config.yaml" || {
            backup_mark_incomplete "$VPS_BACKUP_ROOT"
            return 1
        }
    fi
    backup_finish "$VPS_BACKUP_ROOT" "$VPS_PROGRAM" "$BOOTSTRAP_ROOT" "$VPS_BACKUP_TIMESTAMP" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        return 1
    }
    log_change "backed up config to $VPS_BACKUP_ROOT"
    mv "$vps_cwt_tmp" "$VPS_CONFIG_PATH" || return 1
    vps_configtest_file "$VPS_CONFIG_PATH" || {
        log_error 'configtest failed on the installed config; restoring backup'
        if [ -f "$VPS_BACKUP_ROOT/source/etc/headscale/config.yaml" ]; then
            cp "$VPS_BACKUP_ROOT/source/etc/headscale/config.yaml" "$VPS_CONFIG_PATH"
        fi
        return 1
    }
    return 0
}

vps_restore_config_backup() {
    [ -f "$VPS_BACKUP_ROOT/source/etc/headscale/config.yaml" ] || return 0
    cp "$VPS_BACKUP_ROOT/source/etc/headscale/config.yaml" "$VPS_CONFIG_PATH" && \
        vps_configtest_file "$VPS_CONFIG_PATH"
}

vps_local_health_ok() {
    [ "$(vps_health_code "http://$VPS_LISTEN/health")" = 200 ]
}

vps_public_health_ok() {
    [ -n "$VPS_EFFECTIVE_DOMAIN" ] || return 1
    [ "$(vps_health_code "https://$VPS_EFFECTIVE_DOMAIN/health")" = 200 ]
}

vps_restart_and_verify() {
    systemctl restart headscale || { log_error 'systemctl restart headscale failed'; return 1; }
    if ! vps_local_health_ok; then
        log_error 'local /health failed after restart; rolling back config'
        vps_restore_config_backup || log_error 'config rollback failed configtest; keeping new config'
        systemctl restart headscale || true
        return 1
    fi
    return 0
}

vps_write_state() {
    state_write "$(state_path_vps)" \
        domain "$VPS_EFFECTIVE_DOMAIN" \
        proxy_mode "$VPS_EFFECTIVE_PROXY" \
        headscale_version "$(vps_current_version)" \
        listen "$VPS_LISTEN" \
        metrics_listen "$VPS_METRICS_LISTEN" \
        grpc_listen "$VPS_GRPC_LISTEN" || die 'failed to write state.json'
    log_change "state.json updated: $(state_path_vps)"
}

vps_install() {
    vps_require_root_real
    vps_conflict_or_die

    vps_os_supported || die "unsupported OS for the .deb path: $VPS_OS_ID $VPS_OS_VERSION_ID (need Debian 12+ or Ubuntu 22.04+)"
    [ "$VPS_ARCH" = amd64 ] || [ "$VPS_ARCH" = arm64 ] || die "unsupported architecture for the .deb path: $VPS_ARCH_RAW"

    if [ "$VPS_HEADSCALE_VERSION" != absent ]; then
        die "headscale already installed ($VPS_HEADSCALE_VERSION); use apply or update"
    fi
    if [ "$VPS_CONFIG_PRESENT" = yes ]; then
        die "existing $VPS_CONFIG_PATH without a usable headscale binary; refusing a fresh install over it (use apply/update)"
    fi

    [ "$VPS_PORT_8080" = free ] || die "listen port 8080 is not free (state: $VPS_PORT_8080)"
    [ "$VPS_PORT_9090" = free ] || die "metrics port 9090 is not free (state: $VPS_PORT_9090)"
    [ "$VPS_PORT_50443" = free ] || die "grpc port 50443 is not free (state: $VPS_PORT_50443)"

    vps_install_version=${VPS_VERSION:-$VPS_DEFAULT_VERSION}
    version_extract_semver "$vps_install_version" | grep -q '.' || die "invalid --version: $vps_install_version"

    vps_install_deb_file=$(vps_download_deb "$vps_install_version") || die 'download failed'
    vps_deb_metadata_ok "$vps_install_deb_file" "$vps_install_version" || {
        rm -f "$vps_install_deb_file"
        die 'package metadata validation failed; nothing was installed'
    }
    vps_install_deb "$vps_install_deb_file" || {
        rm -f "$vps_install_deb_file"
        die 'package installation failed'
    }
    rm -f "$vps_install_deb_file"

    vps_refresh
    if [ "$VPS_HEADSCALE_VERSION" = absent ]; then
        die 'headscale binary not usable after install'
    fi

    if [ ! -f "$VPS_CONFIG_PATH" ]; then
        vps_example=$(bootstrap_root_path /etc/headscale/config.example.yaml)
        if [ -f "$vps_example" ]; then
            cp "$vps_example" "$VPS_CONFIG_PATH" || die 'failed to seed config.yaml from the packaged example'
            log_change 'seeded /etc/headscale/config.yaml from packaged example'
        else
            die 'installed package provides no config baseline (no config.yaml and no config.example.yaml)'
        fi
    fi

    vps_tmp_config=${TMPDIR:-/tmp}/headscale-config.$$.yaml
    vps_render_config "$VPS_CONFIG_PATH" "$vps_tmp_config" || {
        rm -f "$vps_tmp_config"
        die 'config rendering failed'
    }
    vps_config_write_transaction "$vps_tmp_config" || {
        rm -f "$vps_tmp_config"
        die 'config transaction failed; no service restart was attempted'
    }
    log_change 'rendered managed config keys (server_url, listen_addrs, trusted_proxies, embedded DERP off, TLS paths empty)'

    systemctl enable headscale || log_warn 'systemctl enable headscale failed'
    vps_restart_and_verify || die 'post-install verification failed'

    printf 'Installed headscale %s listening on %s (metrics %s, grpc %s)\n' \
        "$(vps_current_version)" "$VPS_LISTEN" "$VPS_METRICS_LISTEN" "$VPS_GRPC_LISTEN"
    case "$VPS_EFFECTIVE_PROXY" in
        1panel)
            printf 'Next: create the %s reverse-proxy site in the 1Panel UI (upstream http://%s, TLS certificate), then run: %s apply --domain %s\n' \
                "$VPS_EFFECTIVE_DOMAIN" "$VPS_LISTEN" "$VPS_PROGRAM" "$VPS_EFFECTIVE_DOMAIN"
            ;;
        caddy|nginx)
            printf 'Next: run: %s apply --domain %s --proxy %s\n' "$VPS_PROGRAM" "$VPS_EFFECTIVE_DOMAIN" "$VPS_EFFECTIVE_PROXY"
            ;;
        none)
            printf 'No reverse proxy is managed; ensure https://%s is served before clients register.\n' "$VPS_EFFECTIVE_DOMAIN"
            ;;
    esac
    vps_write_state
}

vps_apply() {
    vps_require_root_real
    vps_conflict_or_die

    [ "$VPS_HEADSCALE_VERSION" != absent ] || die 'headscale is not installed; run install first'
    [ "$VPS_CONFIG_PRESENT" = yes ] || die "$VPS_CONFIG_PATH missing; run install first"

    vps_tmp_config=${TMPDIR:-/tmp}/headscale-config.$$.yaml
    vps_render_config "$VPS_CONFIG_PATH" "$vps_tmp_config" || {
        rm -f "$vps_tmp_config"
        die 'config rendering failed'
    }
    if cmp -s "$vps_tmp_config" "$VPS_CONFIG_PATH"; then
        rm -f "$vps_tmp_config"
        log_info 'config already matches the desired managed keys; no restart'
    else
        vps_config_write_transaction "$vps_tmp_config" || {
            rm -f "$vps_tmp_config"
            die 'config transaction failed'
        }
        rm -f "$vps_tmp_config"
        vps_restart_and_verify || die 'restart/health verification failed'
    fi

    case "$VPS_EFFECTIVE_PROXY" in
        1panel) vps_apply_1panel ;;
        caddy) vps_apply_caddy ;;
        nginx) vps_apply_nginx ;;
        none) log_info 'proxy mode none: no reverse proxy is managed by this script' ;;
        *) die 'effective proxy could not be determined' ;;
    esac

    if [ "$VPS_EFFECTIVE_PROXY" != none ] && ! vps_public_health_ok; then
        die "public https://$VPS_EFFECTIVE_DOMAIN/health did not return 200 after proxy apply"
    fi
    printf 'Apply complete: config verified, proxy=%s, health OK.\n' "$VPS_EFFECTIVE_PROXY"
    vps_write_state
}

vps_proxy_backup_files() {
    # Back up the given proxy files into the shared backup layout.
    VPS_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
    VPS_BACKUP_ROOT=$(backup_allocate_directory "$(bootstrap_root_path "$VPS_BACKUP_DIR")" "$VPS_BACKUP_TIMESTAMP") || return 1
    chmod 700 "$VPS_BACKUP_ROOT" 2>/dev/null || true
    backup_mark_incomplete "$VPS_BACKUP_ROOT"
    for vps_pb_source in "$@"; do
        [ -n "$vps_pb_source" ] || continue
        backup_copy_path "$vps_pb_source" "$VPS_BACKUP_ROOT/proxy/$(basename "$vps_pb_source")" || {
            backup_mark_incomplete "$VPS_BACKUP_ROOT"
            return 1
        }
    done
    backup_finish "$VPS_BACKUP_ROOT" "$VPS_PROGRAM" "$BOOTSTRAP_ROOT" "$VPS_BACKUP_TIMESTAMP" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        return 1
    }
    log_change "proxy files backed up to $VPS_BACKUP_ROOT"
    return 0
}

vps_panel_required_directives() {
    # Print the directives that must be active inside the 1Panel proxy block.
    printf '%s\n' \
        "proxy_pass http://$VPS_LISTEN;" \
        'proxy_http_version 1.1;' \
        'proxy_set_header Upgrade $http_upgrade;' \
        'proxy_set_header Connection $http_connection;' \
        'proxy_set_header Host $host;' \
        'proxy_set_header X-Real-IP $remote_addr;' \
        'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
        'proxy_set_header X-Forwarded-Proto $scheme;' \
        'proxy_buffering off;'
}

vps_panel_prefix_present() {
    # A directive counts as present when any active line starts with the
    # directive name (never rewrite a verified $http_connection form).
    vps_pp_prefix=$1
    vps_pp_text=$2
    printf '%s\n' "$vps_pp_text" | grep -qF "$vps_pp_prefix"
}

vps_apply_1panel() {
    [ "$VPS_PANEL_ROOT_PRESENT" = yes ] || {
        cat >&2 <<EOF
1Panel mode requires an existing site.  Create it in the 1Panel UI first:
  - domain: $VPS_EFFECTIVE_DOMAIN
  - reverse proxy upstream: http://$VPS_LISTEN
  - TLS certificate for the domain (DNS Only, no Cloudflare proxy)
This script does not create 1Panel sites or certificates.
EOF
        exit 2
    }

    vps_panel_active=$(bootstrap_active_config_lines "$VPS_PANEL_ROOT_CONF")
    if printf '%s\n' "$vps_panel_active" | grep -q '^[[:space:]]*proxy_pass'; then
        vps_panel_upstream=$(printf '%s\n' "$vps_panel_active" | sed -n 's/^[[:space:]]*proxy_pass[[:space:]]\+\([^;]*\);.*/\1/p' | sed -n '1p')
        if [ "$vps_panel_upstream" != "http://$VPS_LISTEN" ]; then
            die "1Panel site proxies to '$vps_panel_upstream' instead of http://$VPS_LISTEN; refusing to rewrite it"
        fi
    else
        die '1Panel proxy root has no proxy_pass directive; create the site in the 1Panel UI first'
    fi

    vps_panel_missing=$(vps_panel_required_directives | {
        while IFS= read -r vps_panel_directive; do
            [ -n "$vps_panel_directive" ] || continue
            case "$vps_panel_directive" in
                proxy_pass*|proxy_http_version*|proxy_buffering*)
                    printf '%s\n' "$vps_panel_active" | grep -qF "$vps_panel_directive" && continue
                    ;;
                *)
                    vps_panel_prefix=$(printf '%s\n' "$vps_panel_directive" | awk '{ print $1 " " $2 }')
                    vps_panel_prefix_present "$vps_panel_prefix" "$vps_panel_active" && continue
                    ;;
            esac
            printf '%s\n' "$vps_panel_directive"
        done
    })
    if [ -z "$vps_panel_missing" ]; then
        log_info '1Panel proxy root already has every required directive; no proxy change'
        return 0
    fi

    vps_proxy_backup_files "$VPS_PANEL_ROOT_CONF" "$VPS_PANEL_VHOST_PATH" || die 'failed to back up 1Panel proxy files'

    vps_panel_tmp=${TMPDIR:-/tmp}/1panel-root.$$.conf
    vps_panel_close=$(awk '
        /location/ && !started { started = 1; depth = 0 }
        started {
            n = gsub(/{/, "{"); m = gsub(/}/, "}")
            depth += n - m
            if (started && depth == 0 && m > 0) { print NR; exit }
        }
    ' "$VPS_PANEL_ROOT_CONF")
    [ -n "$vps_panel_close" ] || {
        rm -f "$vps_panel_tmp"
        die 'could not locate the closing brace of the 1Panel location block'
    }
    vps_panel_insert=$(printf '%s\n' "$vps_panel_missing" | sed '/^[[:space:]]*$/d' | sed 's/^/    /')
    {
        sed -n "1,$((vps_panel_close - 1))p" "$VPS_PANEL_ROOT_CONF"
        printf '%s\n' "$vps_panel_insert"
        sed -n "${vps_panel_close},\$p" "$VPS_PANEL_ROOT_CONF"
    } > "$vps_panel_tmp"

    cp "$vps_panel_tmp" "$VPS_PANEL_ROOT_CONF" || {
        rm -f "$vps_panel_tmp"
        die 'failed to stage patched 1Panel proxy root'
    }
    rm -f "$vps_panel_tmp"

    if ! docker exec "$VPS_DOCKER_CONTAINER" /usr/local/openresty/bin/openresty -t >/dev/null 2>&1; then
        log_error 'openresty -t rejected the patched config; restoring backup without reloading'
        cp "$VPS_BACKUP_ROOT/proxy/$(basename "$VPS_PANEL_ROOT_CONF")" "$VPS_PANEL_ROOT_CONF"
        exit 1
    fi
    docker exec "$VPS_DOCKER_CONTAINER" /usr/local/openresty/bin/openresty -s reload || {
        log_error 'openresty reload failed; restoring backup'
        cp "$VPS_BACKUP_ROOT/proxy/$(basename "$VPS_PANEL_ROOT_CONF")" "$VPS_PANEL_ROOT_CONF"
        exit 1
    }
    log_change "1Panel proxy root patched:$vps_panel_missing"
    return 0
}

vps_managed_block_render() {
    # vps_managed_block_render TEMPLATE -> stdout
    sed -e "s/__DOMAIN__/$VPS_EFFECTIVE_DOMAIN/g" -e "s|__UPSTREAM__|http://$VPS_LISTEN|g" "$1"
}

vps_replace_managed_block() {
    # vps_replace_managed_block FILE TEMPLATE: create/replace/append the
    # managed marker block, leaving foreign content untouched.
    vps_rmb_file=$1
    vps_rmb_template=$2
    vps_rmb_block=$(vps_managed_block_render "$vps_rmb_template")
    if [ ! -f "$vps_rmb_file" ]; then
        printf '%s\n' "$vps_rmb_block" > "$vps_rmb_file"
        log_change "created managed block in $vps_rmb_file"
        return 0
    fi
    if grep -qF '# BEGIN headscale-bootstrap managed' "$vps_rmb_file" 2>/dev/null; then
        awk -v block="$vps_rmb_block" '
            /^# BEGIN headscale-bootstrap managed$/ { print block; skipping = 1; next }
            /^# END headscale-bootstrap managed$/ { skipping = 0; replaced = 1; next }
            !skipping { print }
            END { if (!replaced) { print ""; print block } }
        ' "$vps_rmb_file" > "$vps_rmb_file.tmp" && mv "$vps_rmb_file.tmp" "$vps_rmb_file"
        log_change "replaced managed block in $vps_rmb_file"
        return 0
    fi
    {
        cat "$vps_rmb_file"
        printf '\n'
        printf '%s\n' "$vps_rmb_block"
    } > "$vps_rmb_file.tmp" && mv "$vps_rmb_file.tmp" "$vps_rmb_file"
    log_change "appended managed block to $vps_rmb_file"
    return 0
}

vps_apply_caddy() {
    if ! bootstrap_command_exists caddy; then
        [ "$VPS_PORT_80" = free ] && [ "$VPS_PORT_443" = free ] || {
            die 'caddy is absent and 80/443 are not free; refusing to proceed'
        }
        apt-get install -y caddy >/dev/null || die 'failed to install caddy'
        log_change 'installed caddy package'
    fi
    vps_caddy_file=$(bootstrap_root_path /etc/caddy/Caddyfile)
    vps_caddy_changed=0
    mkdir -p "$(dirname "$vps_caddy_file")" || die "cannot create $(dirname "$vps_caddy_file")"
    if [ -f "$vps_caddy_file" ]; then
        vps_proxy_backup_files "$vps_caddy_file" || die 'failed to back up Caddyfile'
    fi
    vps_rmb_before=$(cat "$vps_caddy_file" 2>/dev/null)
    vps_replace_managed_block "$vps_caddy_file" "$VPS_SCRIPT_DIR/templates/caddy-headscale.conf"
    if [ "$vps_rmb_before" = "$(cat "$vps_caddy_file" 2>/dev/null)" ]; then
        log_info 'caddy managed block already current; no reload'
        return 0
    fi
    if ! caddy validate --config "$vps_caddy_file" >/dev/null 2>&1; then
        log_error 'caddy validate failed; restoring backup without reloading'
        [ -f "$VPS_BACKUP_ROOT/proxy/Caddyfile" ] && cp "$VPS_BACKUP_ROOT/proxy/Caddyfile" "$vps_caddy_file"
        exit 1
    fi
    if [ "$(systemctl is-active caddy 2>/dev/null || printf inactive)" = active ]; then
        systemctl reload caddy || die 'caddy reload failed'
    else
        systemctl enable caddy >/dev/null 2>&1 || true
        systemctl start caddy || die 'caddy start failed'
    fi
    log_change 'caddy reloaded with the managed Headscale site'
}

vps_apply_nginx() {
    vps_nginx_file=$(bootstrap_root_path /etc/nginx/conf.d/headscale-bootstrap.conf)
    if [ -f "$vps_nginx_file" ]; then
        vps_proxy_backup_files "$vps_nginx_file" || die 'failed to back up the managed nginx file'
    fi
    vps_rmb_before=$(cat "$vps_nginx_file" 2>/dev/null)
    mkdir -p "$(dirname "$vps_nginx_file")" || die "cannot create $(dirname "$vps_nginx_file")"
    vps_replace_managed_block "$vps_nginx_file" "$VPS_SCRIPT_DIR/templates/nginx-headscale.conf"
    if [ "$vps_rmb_before" = "$(cat "$vps_nginx_file" 2>/dev/null)" ]; then
        log_info 'nginx managed block already current; no reload'
        return 0
    fi
    if ! nginx -t >/dev/null 2>&1; then
        log_error 'nginx -t failed (TLS certificates must be provided outside this script); restoring backup without reloading'
        [ -f "$VPS_BACKUP_ROOT/proxy/headscale-bootstrap.conf" ] && cp "$VPS_BACKUP_ROOT/proxy/headscale-bootstrap.conf" "$vps_nginx_file"
        exit 1
    fi
    if [ "$(systemctl is-active nginx 2>/dev/null || printf inactive)" = active ]; then
        systemctl reload nginx || die 'nginx reload failed'
    else
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl start nginx || die 'nginx start failed'
    fi
    log_change 'nginx reloaded with the managed Headscale server blocks'
}

vps_user_id_for() {
    # vps_user_id_for USERS_LIST NAME -> prints the id, exits nonzero if absent.
    # Fallback lookup: `headscale users list` renders a pipe-separated table;
    # fields carry padding.  Since Headscale 0.26 the "Name" column holds the
    # display name (empty for plain `users create`) and the username lives in
    # "Username"; older releases kept the username in "Name".  Locate the
    # column from the header so both layouts match.  Keep to plain POSIX awk
    # constructs only.  The primary lookup is vps_resolve_user_id.
    printf '%s\n' "$1" | awk -F'|' -v wanted="$2" '
        function field(n, s) { s = $n; gsub(/[ \t]/, "", s); return s }
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                col = field(i)
                if (col == "Username") name_col = i
                else if (col == "Name" && name_col == 0) name_col = i
            }
            if (name_col == 0) name_col = 2
            next
        }
        field(name_col) == wanted { print field(1); found = 1; exit }
        END { exit(found ? 0 : 1) }
    '
}

vps_strip_ansi() {
    # Headscale renders CLI output through pterm, which colors it with ANSI
    # SGR/CSI sequences even when stdout is captured (observed on 0.29:
    # the users-table ID cell arrives as ESC[96m ESC[0m ESC[0m 1 ESC[90m
    # ESC[90m).  Strip every CSI sequence before parsing captured output.
    sed "s/$(printf '\033')\[[0-9;]*[A-Za-z]//g"
}

vps_resolve_user_id() {
    # vps_resolve_user_id NAME -> prints the user id, exits nonzero if absent.
    # Primary lookup: server-side `users list --name NAME` (Headscale >= 0.26)
    # so existence means "the filtered table has a data row" and column 1 is
    # the id; no table-column parsing is involved.  Only sed/cut/tr touch the
    # output, after vps_strip_ansi removes pterm coloring.  Releases without
    # the flag (older Headscale) fall back to parsing the unfiltered table
    # via vps_user_id_for.
    vps_rui_raw=$(NO_COLOR=1 headscale users list --name "$1" 2>/dev/null) || {
        vps_rui_all=$(NO_COLOR=1 headscale users list 2>/dev/null) || return 1
        vps_user_id_for "$(printf '%s\n' "$vps_rui_all" | vps_strip_ansi)" "$1" && return 0
        return 1
    }
    vps_rui_filtered=$(printf '%s\n' "$vps_rui_raw" | vps_strip_ansi)
    vps_rui_row=$(printf '%s\n' "$vps_rui_filtered" | sed -n '2p')
    [ -n "$vps_rui_row" ] || return 1
    vps_rui_id=$(printf '%s\n' "$vps_rui_row" | cut -d'|' -f1 | tr -d ' \t')
    [ -n "$vps_rui_id" ] || return 1
    printf '%s\n' "$vps_rui_id"
}

vps_ensure_user() {
    [ -n "$VPS_USER_NAME" ] || die 'ensure-user requires --user NAME'
    vps_refresh
    [ "$VPS_HEADSCALE_VERSION" != absent ] || die 'headscale is not installed'
    if vps_user_id=$(vps_resolve_user_id "$VPS_USER_NAME"); then
        printf 'User %s already exists (id %s).\n' "$VPS_USER_NAME" "$vps_user_id"
        return 0
    fi
    headscale users create "$VPS_USER_NAME" || die "failed to create user $VPS_USER_NAME (the name may already exist while 'headscale users list' cannot be parsed on this system; run it manually and report the exact output)"
    vps_user_id=$(vps_resolve_user_id "$VPS_USER_NAME") || die 'created user not found after create'
    log_change "created Headscale user $VPS_USER_NAME (id $vps_user_id)"
    printf 'User %s created (id %s).\n' "$VPS_USER_NAME" "$vps_user_id"
}

vps_issue_key() {
    [ -n "$VPS_USER_NAME" ] || die 'issue-key requires --user NAME'
    vps_refresh
    [ "$VPS_HEADSCALE_VERSION" != absent ] || die 'headscale is not installed'
    if ! vps_user_id=$(vps_resolve_user_id "$VPS_USER_NAME"); then
        headscale users create "$VPS_USER_NAME" || die "failed to create user $VPS_USER_NAME (the name may already exist while 'headscale users list' cannot be parsed on this system; run it manually and report the exact output)"
        vps_user_id=$(vps_resolve_user_id "$VPS_USER_NAME") || die 'cannot resolve user id after create'
        log_change "created Headscale user $VPS_USER_NAME (id $vps_user_id)"
    fi
    vps_key_raw=$(NO_COLOR=1 headscale preauthkeys create --user "$vps_user_id" --expiration "${VPS_KEY_EXPIRATION:-2h}") || {
        die 'preauthkeys create failed (check headscale version flag support with: headscale preauthkeys create --help)'
    }
    vps_key=$(printf '%s\n' "$vps_key_raw" | vps_strip_ansi)
    log_change "issued pre-auth key $(printf '%s\n' "$vps_key" | sed -n 's/^\(hskey-..............\).*/\1/p')-***"
    if [ -n "$VPS_KEY_OUTPUT" ]; then
        umask 077
        printf '%s\n' "$vps_key" > "$VPS_KEY_OUTPUT" || die "failed to write $VPS_KEY_OUTPUT"
        chmod 600 "$VPS_KEY_OUTPUT" 2>/dev/null || true
        printf 'Pre-auth key written to %s (mode 0600).  It is not stored anywhere else.\n' "$VPS_KEY_OUTPUT"
    else
        printf '%s\n' "$vps_key"
    fi
}

vps_approve_route() {
    [ -n "$VPS_NODE_ID" ] || die 'approve-route requires --node-id ID'
    [ -n "$VPS_ROUTE" ] || die 'approve-route requires --route CIDR'
    net_is_ipv4_cidr "$VPS_ROUTE" || die "--route must be an IPv4 CIDR: $VPS_ROUTE"
    vps_refresh
    [ "$VPS_HEADSCALE_VERSION" != absent ] || die 'headscale is not installed'
    headscale nodes list-routes || true
    headscale nodes approve-routes --identifier "$VPS_NODE_ID" --routes "$VPS_ROUTE" || {
        die 'approve-routes failed (check headscale version flag support with: headscale nodes approve-routes --help)'
    }
    log_change "approved route $VPS_ROUTE for node $VPS_NODE_ID"
    headscale nodes list-routes
}

vps_release_tags() {
    # Print stable vX.Y.Z tags from the GitHub releases API, one per line.
    vps_tags_file=${TMPDIR:-/tmp}/headscale-releases.$$.json
    curl --fail --location --silent --show-error -o "$vps_tags_file" \
        'https://api.github.com/repos/juanfont/headscale/releases?per_page=100' || {
        rm -f "$vps_tags_file"
        return 1
    }
    tr '{,' '\n\n' < "$vps_tags_file" | sed -n 's/.*"tag_name": *"\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p'
    rm -f "$vps_tags_file"
}

vps_latest_patch_for_minor() {
    # vps_latest_patch_for_minor TAGS MAJOR MINOR
    printf '%s\n' "$1" | awk -v maj="$2" -v min="$3" '
        {
            sub(/^v/, "", $1)
            split($1, p, ".")
            if (p[1] == maj && p[2] == min) {
                if (p[3] + 0 > best) best = p[3] + 0
            }
        }
        END { if (best > 0) printf "v%d.%d.%d\n", maj, min, best }
    '
}

vps_latest_stable_tag() {
    printf '%s\n' "$1" | awk '
        {
            sub(/^v/, "", $1)
            split($1, p, ".")
            if (p[1] > bmaj || (p[1] == bmaj && p[2] > bmin) || (p[1] == bmaj && p[2] == bmin && p[3] > bpat)) {
                bmaj = p[1]; bmin = p[2]; bpat = p[3]
            }
        }
        END { if (bmaj != "") printf "v%d.%d.%d\n", bmaj, bmin, bpat }
    '
}

vps_update_steps() {
    # Print the ordered upgrade chain (stable minors, latest patch each;
    # stable minors are never skipped).
    vps_steps_current=$1
    vps_steps_target=$2
    vps_steps_tags=$3

    vps_steps_cur_parts=$(vps_semver_parts "$vps_steps_current")
    vps_steps_tgt_parts=$(vps_semver_parts "$vps_steps_target")
    vps_steps_cur_maj=$(printf '%s\n' "$vps_steps_cur_parts" | awk '{print $1}')
    vps_steps_cur_min=$(printf '%s\n' "$vps_steps_cur_parts" | awk '{print $2}')
    vps_steps_tgt_maj=$(printf '%s\n' "$vps_steps_tgt_parts" | awk '{print $1}')
    vps_steps_tgt_min=$(printf '%s\n' "$vps_steps_tgt_parts" | awk '{print $2}')

    [ "$vps_steps_cur_maj" = "$vps_steps_tgt_maj" ] || {
        log_error "cross-major upgrade paths are not automated (current $vps_steps_current, target $vps_steps_target)"
        return 1
    }
    if [ "$vps_steps_tgt_min" -lt "$vps_steps_cur_min" ]; then
        log_error "target $vps_steps_target is older than current $vps_steps_current; use rollback instead"
        return 1
    fi

    # Intermediate minors each take their latest stable patch; the final step
    # is the exact requested version (a user-pinned older patch is honored).
    vps_steps_minor=$vps_steps_cur_min
    while [ "$vps_steps_minor" -lt "$((vps_steps_tgt_min - 1))" ]; do
        vps_steps_minor=$((vps_steps_minor + 1))
        vps_steps_tag=$(vps_latest_patch_for_minor "$vps_steps_tags" "$vps_steps_cur_maj" "$vps_steps_minor")
        [ -n "$vps_steps_tag" ] || {
            log_error "no stable release found for minor $vps_steps_cur_maj.$vps_steps_minor; refusing to guess"
            return 1
        }
        printf '%s\n' "${vps_steps_tag#v}"
    done
    printf '%s\n' "$vps_steps_target"
}

vps_backup_create() {
    vps_refresh
    bootstrap_sha256_available || die 'backup requires sha256sum, shasum, or openssl'
    VPS_BACKUP_TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%SZ)
    VPS_BACKUP_ROOT=$(backup_allocate_directory "$(bootstrap_root_path "$VPS_BACKUP_DIR")" "$VPS_BACKUP_TIMESTAMP") || return 1
    VPS_BACKUP_ID=${VPS_BACKUP_ROOT##*/}
    chmod 700 "$VPS_BACKUP_ROOT" 2>/dev/null || true
    backup_mark_incomplete "$VPS_BACKUP_ROOT"
    backup_copy_path "$VPS_CONFIG_DIR" "$VPS_BACKUP_ROOT/source/etc/headscale" || { backup_mark_incomplete "$VPS_BACKUP_ROOT"; return 1; }
    backup_copy_path "$VPS_DATA_PATH" "$VPS_BACKUP_ROOT/source/var/lib/headscale" || { backup_mark_incomplete "$VPS_BACKUP_ROOT"; return 1; }
    backup_copy_path "$VPS_UNIT_PATH" "$VPS_BACKUP_ROOT/source/usr/lib/systemd/system/headscale.service" || { backup_mark_incomplete "$VPS_BACKUP_ROOT"; return 1; }
    if [ -n "$VPS_PANEL_VHOST_PATH" ]; then
        backup_copy_path "$VPS_PANEL_VHOST_PATH" "$VPS_BACKUP_ROOT/proxy/vhost.conf" || { backup_mark_incomplete "$VPS_BACKUP_ROOT"; return 1; }
    fi
    if [ "$VPS_PANEL_ROOT_PRESENT" = yes ]; then
        backup_copy_path "$VPS_PANEL_ROOT_CONF" "$VPS_BACKUP_ROOT/proxy/root.conf" || { backup_mark_incomplete "$VPS_BACKUP_ROOT"; return 1; }
    fi
    if [ "$VPS_CADDYFILE_PRESENT" = yes ]; then
        backup_copy_path "$(bootstrap_root_path /etc/caddy/Caddyfile)" "$VPS_BACKUP_ROOT/proxy/Caddyfile" || { backup_mark_incomplete "$VPS_BACKUP_ROOT"; return 1; }
    fi
    printf 'vhost_source=%s\n' "${VPS_PANEL_VHOST_PATH:-absent}" > "$VPS_BACKUP_ROOT/proxy/paths.txt"
    printf 'proxy_root_source=%s\n' "${VPS_PANEL_ROOT_CONF:-absent}" >> "$VPS_BACKUP_ROOT/proxy/paths.txt"
    printf 'domain=%s\n' "${VPS_EFFECTIVE_DOMAIN:-unknown}" >> "$VPS_BACKUP_ROOT/proxy/paths.txt"
    printf '%s\n' "$(vps_current_version)" > "$VPS_BACKUP_ROOT/package-version.txt"
    vps_backup_service_state=no
    [ "$(systemctl is-active headscale 2>/dev/null || printf inactive)" = active ] && vps_backup_service_state=yes
    backup_finish "$VPS_BACKUP_ROOT" "$VPS_PROGRAM" "$BOOTSTRAP_ROOT" "$VPS_BACKUP_TIMESTAMP" "$vps_backup_service_state" || {
        backup_mark_incomplete "$VPS_BACKUP_ROOT"
        return 1
    }
    log_change "backup created: $VPS_BACKUP_ROOT (service_running=$vps_backup_service_state)"
    return 0
}

vps_update_step() {
    # One upgrade step: notes, stop, backup, download, verify, install, merge,
    # configtest, start, health, nodes list.
    vps_step_version=$1
    printf '\n=== Updating to %s ===\n' "$vps_step_version" >&2
    printf 'Release notes: https://github.com/juanfont/headscale/releases/tag/v%s\n' "$vps_step_version" >&2

    systemctl stop headscale || log_warn 'systemctl stop headscale failed (service may already be down)'
    vps_backup_create || {
        log_error 'pre-update backup failed; attempting to restart the current version'
        systemctl start headscale || true
        return 1
    }
    vps_step_deb=$(vps_download_deb "$vps_step_version") || {
        log_error 'download failed; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    vps_deb_metadata_ok "$vps_step_deb" "$vps_step_version" || {
        rm -f "$vps_step_deb"
        log_error 'metadata validation failed; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    vps_install_deb "$vps_step_deb" || {
        rm -f "$vps_step_deb"
        log_error 'package install failed; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    rm -f "$vps_step_deb"

    vps_refresh
    vps_tmp_config=${TMPDIR:-/tmp}/headscale-config.$$.yaml
    vps_render_config "$VPS_CONFIG_PATH" "$vps_tmp_config" || {
        rm -f "$vps_tmp_config"
        log_error 'config merge failed; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    vps_configtest_file "$vps_tmp_config" || {
        rm -f "$vps_tmp_config"
        log_error 'configtest rejected the merged config; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    mv "$vps_tmp_config" "$VPS_CONFIG_PATH"
    systemctl start headscale || {
        log_error 'service failed to start after update; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    vps_refresh
    vps_local_health_ok || {
        log_error 'local health failed after update; rolling back to the backup state'
        vps_rollback_to "$VPS_BACKUP_ROOT" || true
        return 1
    }
    if [ "$VPS_EFFECTIVE_PROXY" != none ] && ! vps_public_health_ok; then
        log_warn "public health not 200 after update (proxy may need attention)"
    fi
    headscale nodes list >/dev/null 2>&1 || log_warn 'headscale nodes list failed after update'
    log_change "updated headscale to $vps_step_version"
    return 0
}

vps_update() {
    vps_require_root_real
    vps_conflict_or_die
    [ "$VPS_HEADSCALE_VERSION" != absent ] || die 'headscale is not installed'
    [ "$VPS_CONFIG_PRESENT" = yes ] || die 'config missing; cannot update'

    vps_update_current=$(vps_current_version)
    [ -n "$vps_update_current" ] || die 'cannot determine the installed headscale version'

    vps_update_tags=$(vps_release_tags) || die 'cannot list headscale releases (GitHub API unreachable); refusing to guess versions'
    [ -n "$vps_update_tags" ] || die 'no stable headscale releases found'

    if [ "$VPS_VERSION" = latest ] || [ -z "$VPS_VERSION" ]; then
        vps_update_target_tag=$(vps_latest_stable_tag "$vps_update_tags")
        vps_update_target=${vps_update_target_tag#v}
    else
        vps_update_target=$(version_extract_semver "$VPS_VERSION")
        [ -n "$vps_update_target" ] || die "invalid --version: $VPS_VERSION"
    fi

    if [ "$(vps_version_cmp "$vps_update_current" "$vps_update_target")" = 0 ]; then
        printf 'Already at %s; nothing to update.\n' "$vps_update_current"
        return 0
    fi
    if [ "$(vps_version_cmp "$vps_update_current" "$vps_update_target")" = 1 ]; then
        die "target $vps_update_target is older than installed $vps_update_current; use rollback for downgrades"
    fi

    vps_update_plan=$(vps_update_steps "$vps_update_current" "$vps_update_target" "$vps_update_tags") || {
        die 'no compliant upgrade path (stable minors must not be skipped)'
    }
    vps_update_steps_count=$(printf '%s\n' "$vps_update_plan" | awk 'END { print NR }')
    if [ "$vps_update_steps_count" -gt 1 ] && [ "$BOOTSTRAP_YES" != 1 ]; then
        printf 'Planned multi-minor upgrade path: %s\n' "$(printf '%s\n' "$vps_update_plan" | tr '\n' ' ')" >&2
        die 'cross-minor updates step through every stable minor and require --yes'
    fi

    printf 'Upgrade path: %s -> %s\n' "$vps_update_current" "$(printf '%s\n' "$vps_update_plan" | tr '\n' ' ')" >&2
    for vps_update_step_version in $vps_update_plan; do
        vps_update_step "$vps_update_step_version" || exit 1
    done
    vps_write_state
    printf 'Update complete: now at %s.\n' "$(vps_current_version)"
}

vps_backup_list_latest() {
    vps_bl_base=$(bootstrap_root_path "$VPS_BACKUP_DIR")
    [ -d "$vps_bl_base" ] || return 1
    ls -1 "$vps_bl_base" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$' | sort | tail -n 1
}

vps_rollback_find() {
    if [ -n "$VPS_POSITIONAL" ]; then
        vps_rbf_dir=$(bootstrap_root_path "$VPS_BACKUP_DIR")/$VPS_POSITIONAL
    else
        vps_rbf_latest=$(vps_backup_list_latest) || return 1
        vps_rbf_dir=$(bootstrap_root_path "$VPS_BACKUP_DIR")/$vps_rbf_latest
    fi
    [ -d "$vps_rbf_dir" ] || {
        log_error "backup directory not found: $vps_rbf_dir"
        return 1
    }
    [ -f "$vps_rbf_dir/manifest.sha256" ] || {
        log_error "backup has no manifest: $vps_rbf_dir"
        return 1
    }
    [ ! -f "$vps_rbf_dir/.INCOMPLETE" ] || {
        log_error "backup is marked INCOMPLETE and must not be restored: $vps_rbf_dir"
        return 1
    }
    VPS_ROLLBACK_DIR=$vps_rbf_dir
    return 0
}

vps_rollback_to() {
    # vps_rollback_to BACKUP_DIR — package/config/database are one consistent
    # snapshot (package, config and data as one unit).
    vps_rb_dir=$1
    [ -d "$vps_rb_dir" ] || { log_error "rollback backup missing: $vps_rb_dir"; return 1; }
    [ ! -f "$vps_rb_dir/.INCOMPLETE" ] || { log_error "refusing to restore an INCOMPLETE backup: $vps_rb_dir"; return 1; }

    log_rollback "restoring from $vps_rb_dir"
    vps_rb_service=$(sed -n 's/^service_running=//p' "$vps_rb_dir/metadata.txt" 2>/dev/null)
    if [ "${vps_rb_service:-unknown}" = yes ]; then
        log_warn 'this snapshot was taken while headscale was running; the copied SQLite file may be internally inconsistent'
    fi
    systemctl stop headscale 2>/dev/null || true

    if [ -d "$vps_rb_dir/source/etc/headscale" ]; then
        rm -rf "$VPS_CONFIG_DIR"
        cp -a "$vps_rb_dir/source/etc/headscale" "$VPS_CONFIG_DIR" || return 1
    fi
    if [ -d "$vps_rb_dir/source/var/lib/headscale" ]; then
        rm -rf "$VPS_DATA_PATH"
        cp -a "$vps_rb_dir/source/var/lib/headscale" "$VPS_DATA_PATH" || return 1
    fi
    if [ -d "$vps_rb_dir/source/usr/lib/systemd/system" ] && [ -n "$VPS_UNIT_PATH" ] && [ "$VPS_UNIT_PATH" != "/" ]; then
        cp -a "$vps_rb_dir/source/usr/lib/systemd/system/headscale.service" "$VPS_UNIT_PATH" 2>/dev/null || true
    fi
    if [ -f "$vps_rb_dir/proxy/root.conf" ] && [ -n "$VPS_PANEL_ROOT_CONF" ]; then
        cp "$vps_rb_dir/proxy/root.conf" "$VPS_PANEL_ROOT_CONF" || return 1
        if [ -n "$VPS_DOCKER_CONTAINER" ]; then
            docker exec "$VPS_DOCKER_CONTAINER" /usr/local/openresty/bin/openresty -t >/dev/null 2>&1 && \
                docker exec "$VPS_DOCKER_CONTAINER" /usr/local/openresty/bin/openresty -s reload || \
                log_warn 'openresty reload after proxy restore failed'
        fi
    fi
    if [ -f "$vps_rb_dir/proxy/Caddyfile" ]; then
        cp "$vps_rb_dir/proxy/Caddyfile" "$(bootstrap_root_path /etc/caddy/Caddyfile)" || return 1
    fi

    vps_rb_version=$(cat "$vps_rb_dir/package-version.txt" 2>/dev/null)
    if [ -n "$vps_rb_version" ] && [ "$vps_rb_version" != "$(vps_current_version)" ]; then
        log_rollback "restoring package version $vps_rb_version"
        vps_rb_deb=$(vps_download_deb "$vps_rb_version") || return 1
        vps_deb_metadata_ok "$vps_rb_deb" "$vps_rb_version" || { rm -f "$vps_rb_deb"; return 1; }
        vps_install_deb "$vps_rb_deb" || { rm -f "$vps_rb_deb"; return 1; }
        rm -f "$vps_rb_deb"
    fi

    vps_refresh
    vps_configtest_file "$VPS_CONFIG_PATH" || {
        log_error 'configtest failed after restore'
        return 1
    }
    systemctl start headscale || return 1
    vps_refresh
    vps_local_health_ok || {
        log_error 'local health failed after rollback'
        return 1
    }
    log_rollback 'rollback restored and verified (config, data, package as one snapshot)'
    return 0
}

vps_rollback() {
    vps_require_root_real
    vps_refresh
    vps_rollback_find || exit 2
    vps_rollback_to "$VPS_ROLLBACK_DIR" || die 'rollback failed'
    vps_write_state
    printf 'Rollback complete from %s.\n' "$VPS_ROLLBACK_DIR"
}

vps_remove_managed_block_from() {
    vps_rmbf_file=$1
    [ -f "$vps_rmbf_file" ] || return 0
    grep -qF '# BEGIN headscale-bootstrap managed' "$vps_rmbf_file" 2>/dev/null || return 1
    awk '
        /^# BEGIN headscale-bootstrap managed$/ { skipping = 1; next }
        /^# END headscale-bootstrap managed$/ { skipping = 0; next }
        !skipping { print }
    ' "$vps_rmbf_file" > "$vps_rmbf_file.tmp" && mv "$vps_rmbf_file.tmp" "$vps_rmbf_file"
    return 0
}

vps_cleanup() {
    vps_require_root_real
    vps_refresh

    systemctl stop headscale 2>/dev/null || log_warn 'systemctl stop headscale failed'
    systemctl disable headscale 2>/dev/null || true
    log_change 'headscale stopped and disabled (config and data preserved)'

    vps_caddy_file=$(bootstrap_root_path /etc/caddy/Caddyfile)
    if [ -f "$vps_caddy_file" ] && grep -qF '# BEGIN headscale-bootstrap managed' "$vps_caddy_file" 2>/dev/null; then
        vps_proxy_backup_files "$vps_caddy_file" || die 'failed to back up Caddyfile before cleanup'
        if vps_remove_managed_block_from "$vps_caddy_file"; then
            if caddy validate --config "$vps_caddy_file" >/dev/null 2>&1; then
                systemctl reload caddy 2>/dev/null || true
                log_change 'removed the managed Caddy site block'
            else
                cp "$VPS_BACKUP_ROOT/proxy/Caddyfile" "$vps_caddy_file"
                log_warn 'caddy validate failed after removing the managed block; restored the previous Caddyfile'
            fi
        fi
    fi

    vps_nginx_managed=$(bootstrap_root_path /etc/nginx/conf.d/headscale-bootstrap.conf)
    if [ -f "$vps_nginx_managed" ] && grep -qF '# BEGIN headscale-bootstrap managed' "$vps_nginx_managed" 2>/dev/null; then
        rm -f "$vps_nginx_managed"
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || true
            log_change 'removed the managed nginx conf.d file'
        else
            log_warn 'nginx -t failed after removing the managed file; reload skipped'
        fi
    fi

    if [ "$VPS_PANEL_ROOT_PRESENT" = yes ] && [ "$VPS_PANEL_BUFFERING" = present ]; then
        printf '1Panel site files were left untouched; the proxy_buffering directive added by apply remains.\n'
    fi

    state_remove "$(state_path_vps)"
    printf 'Cleanup complete.  /etc/headscale and /var/lib/headscale were preserved; packages were not removed.\n'
}

vps_purge() {
    vps_require_root_real
    if [ "$BOOTSTRAP_UNDERSTAND" != 1 ]; then
        cat >&2 <<'EOF'
purge deletes /etc/headscale and /var/lib/headscale (all users, nodes, keys).
A final backup is taken first, but this is destructive.  Re-run with:
  --yes-i-understand
EOF
        exit 2
    fi
    vps_refresh
    vps_backup_create || die 'final backup failed; purge aborted'
    systemctl stop headscale 2>/dev/null || true
    systemctl disable headscale 2>/dev/null || true
    rm -rf "$VPS_CONFIG_DIR" "$VPS_DATA_PATH"
    state_remove "$(state_path_vps)"
    printf 'Purge complete.  Final backup: %s\n' "$VPS_BACKUP_ROOT"
    printf 'The headscale package itself was not removed (apt-get remove headscale if intended).\n'
}
