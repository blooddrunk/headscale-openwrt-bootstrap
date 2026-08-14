#!/bin/sh

# Version helpers are intentionally conservative.  They only report versions
# in Milestone 1; upgrade ordering and package mutation belong to Milestone 6.

version_first_line() {
    version_command=$1
    shift
    bootstrap_capture_first_line "$version_command" "$@"
}

version_extract_semver() {
    printf '%s\n' "$1" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | sed -n '1p'
}

