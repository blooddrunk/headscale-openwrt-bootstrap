#!/bin/sh

# IPv4/CIDR arithmetic without non-POSIX awk extensions (no compl()/bit ops).
# Values stay below 2^32, which double-precision awk handles exactly.
#
# Every number that can reach or exceed 2^31 must be printed with %.0f,
# never %d: busybox awk on 32-bit ARM (armv7 Kwrt builds) casts %d through a
# C int, and the ARM float-to-int conversion SATURATES at 2^31-1.  Observed
# on a real router: any address >= 128.0.0.0 collapsed to 127.255.255.255
# (INT_MAX), making the discovered LAN CIDR useless and bogus overlap
# warnings fire.  %.0f keeps everything in double precision up to 2^53.

net_is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        {
            if (NF != 4) exit 1
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i + 0 > 255 || ($i ~ /^0./ && $i + 0 != 0 && length($i) > 1 && $i !~ /^0$/)) exit 1
                if (length($i) > 1 && $i ~ /^0/) exit 1
            }
            exit 0
        }
    ' 2>/dev/null
}

net_is_ipv4_cidr() {
    case "$1" in
        */*) ;;
        *) return 1 ;;
    esac
    net_cidr_ip=${1%%/*}
    net_cidr_prefix=${1##*/}
    net_is_ipv4 "$net_cidr_ip" || return 1
    case "$net_cidr_prefix" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$net_cidr_prefix" -le 32 ] || return 1
    return 0
}

net_ipv4_to_int() {
    printf '%s\n' "$1" | awk -F. '{ printf "%.0f", ((($1 * 256 + $2) * 256 + $3) * 256 + $4) }'
}

net_int_to_ipv4() {
    printf '%s\n' "$1" | awk '{
        b = $1 + 0
        printf "%d.%d.%d.%d", int(b / 16777216) % 256, int(b / 65536) % 256, int(b / 256) % 256, b % 256
    }'
}

# net_cidr_info CIDR -> "base_int block_size"
net_cidr_info() {
    printf '%s %s\n' "${1%%/*}" "${1##*/}" | awk '
        {
            ip = $1; p = $2 + 0
            split(ip, o, ".")
            val = (((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4])
            block = 1
            for (i = 0; i < 32 - p; i++) block *= 2
            printf "%.0f %.0f\n", int(val / block) * block, block
        }
    '
}

# Print the normalized network address of IP/PREFIX (never rewrite
# ".1" to ".0" by hand).
net_network_of() {
    net_network_ip=$1
    net_network_prefix=$2
    net_network_info=$(net_cidr_info "$net_network_ip/$net_network_prefix")
    net_int_to_ipv4 "${net_network_info%% *}"
}

net_normalize_cidr() {
    net_norm_prefix=${1##*/}
    net_norm_base=$(net_network_of "${1%%/*}" "$net_norm_prefix")
    printf '%s/%s\n' "$net_norm_base" "$net_norm_prefix"
}

# net_cidr_contains A B: exit 0 when B is inside A.
net_cidr_contains() {
    net_contains_a=$(net_cidr_info "$1")
    net_contains_b=$(net_cidr_info "$2")
    printf '%s %s %s %s\n' $net_contains_a $net_contains_b | awk '
        {
            a1 = $1; as = $2; b1 = $3; bs = $4
            if (b1 >= a1 && b1 + bs - 1 <= a1 + as - 1) exit 0
            exit 1
        }
    '
}

# net_cidr_overlaps A B: exit 0 when the ranges intersect at all.
net_cidr_overlaps() {
    net_overlaps_a=$(net_cidr_info "$1")
    net_overlaps_b=$(net_cidr_info "$2")
    printf '%s %s %s %s\n' $net_overlaps_a $net_overlaps_b | awk '
        {
            a1 = $1; as = $2; b1 = $3; bs = $4
            if (a1 <= b1 + bs - 1 && b1 <= a1 + as - 1) exit 0
            exit 1
        }
    '
}
