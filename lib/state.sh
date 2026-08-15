#!/bin/sh

# Non-secret state.json management.  The state file only
# records management facts.  It must never contain auth keys, API tokens,
# Cloudflare tokens, tailscaled.state content, private keys, or database
# credentials.

state_path_vps() {
    bootstrap_root_path /var/lib/headscale-bootstrap/state.json
}

state_path_openwrt() {
    bootstrap_root_path /etc/tailscale-bootstrap/state.json
}

state_read_field() {
    state_file=$1
    state_key=$2
    [ -r "$state_file" ] || return 1
    sed -n "s/.*\"$state_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$state_file" 2>/dev/null | sed -n '1p'
}

state_write() {
    # state_write FILE key value [key value ...]
    state_file=$1
    shift
    [ "$#" -ge 2 ] || { log_error 'state_write needs key/value pairs'; return 1; }
    mkdir -p "$(dirname "$state_file")" || return 1
    umask 077
    printf '{\n  "schema": "1",\n  "managed_by": "headscale-openwrt-bootstrap"' > "$state_file.tmp"
    while [ "$#" -ge 2 ]; do
        printf ',\n  "%s": "%s"' \
            "$(bootstrap_json_escape "$1")" \
            "$(bootstrap_json_escape "$2")" >> "$state_file.tmp"
        shift 2
    done
    printf '\n}\n' >> "$state_file.tmp"
    mv "$state_file.tmp" "$state_file" || return 1
    chmod 600 "$state_file" 2>/dev/null || true
    return 0
}

state_remove() {
    rm -f "$1" 2>/dev/null || true
}
