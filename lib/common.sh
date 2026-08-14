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
