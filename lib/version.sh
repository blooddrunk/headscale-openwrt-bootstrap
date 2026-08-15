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

version_cmp() {
    # version_cmp A B -> -1 | 0 | 1
    printf '%s\n' "$1 $2" | awk '
        {
            split($1, a, ".")
            split($2, b, ".")
            for (i = 1; i <= 3; i++) {
                if (a[i] + 0 < b[i] + 0) { print -1; exit }
                if (a[i] + 0 > b[i] + 0) { print 1; exit }
            }
            print 0
        }'
}

