#!/bin/sh

# Logging helpers shared by the two Milestone 1 scripts.
# Logs always go to stderr so --json output on stdout remains machine-readable.

bootstrap_log() {
    bootstrap_log_level=$1
    shift

    if [ "${BOOTSTRAP_QUIET:-0}" = "1" ] && [ "$bootstrap_log_level" = "INFO" ]; then
        return 0
    fi

    printf '[%s] %s\n' "$bootstrap_log_level" "$*" >&2
}

log_info() { bootstrap_log INFO "$@"; }
log_warn() { bootstrap_log WARN "$@"; }
log_error() { bootstrap_log ERROR "$@"; }
log_change() { bootstrap_log CHANGE "$@"; }
log_check() { bootstrap_log CHECK "$@"; }
log_rollback() { bootstrap_log ROLLBACK "$@"; }

die() {
    log_error "$*"
    exit 1
}

