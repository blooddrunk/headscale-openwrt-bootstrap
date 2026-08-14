#!/bin/sh

# Backup primitives.  Backups are private by default and are never printed.
# The caller supplies source paths and a destination root in its namespace.

backup_copy_path() {
    backup_source=$1
    backup_destination=$2

    bootstrap_path_exists "$backup_source" || return 0
    mkdir -p "$(dirname "$backup_destination")" || return 1

    if [ -d "$backup_source" ] && [ ! -L "$backup_source" ]; then
        mkdir -p "$backup_destination" || return 1
        cp -a "$backup_source"/. "$backup_destination"/ || return 1
    else
        cp -a "$backup_source" "$backup_destination" || return 1
    fi
}

backup_mark_incomplete() {
    backup_incomplete_root=$1
    : > "$backup_incomplete_root/.INCOMPLETE"
    chmod 600 "$backup_incomplete_root/.INCOMPLETE" 2>/dev/null || true
}

backup_allocate_directory() {
    backup_base=$1
    backup_timestamp=$2
    mkdir -p "$backup_base" || return 1

    backup_candidate="$backup_base/$backup_timestamp"
    if mkdir "$backup_candidate" 2>/dev/null; then
        printf '%s\n' "$backup_candidate"
        return 0
    fi

    backup_suffix=1
    while [ "$backup_suffix" -le 99 ]; do
        backup_candidate="$backup_base/$backup_timestamp-$backup_suffix"
        if mkdir "$backup_candidate" 2>/dev/null; then
            printf '%s\n' "$backup_candidate"
            return 0
        fi
        backup_suffix=$((backup_suffix + 1))
    done
    return 1
}

backup_write_metadata() {
    backup_metadata_file=$1
    backup_metadata_script=$2
    backup_metadata_root=$3
    backup_metadata_timestamp=$4

    umask 077
    {
        printf 'schema=1\n'
        printf 'managed_by=headscale-openwrt-bootstrap\n'
        printf 'script=%s\n' "$backup_metadata_script"
        printf 'source_root=%s\n' "$backup_metadata_root"
        printf 'created_at_utc=%s\n' "$backup_metadata_timestamp"
        printf 'secret_contents=not_logged\n'
    } > "$backup_metadata_file"
    chmod 600 "$backup_metadata_file" 2>/dev/null || true
}

backup_write_manifest() {
    backup_root=$1
    backup_manifest="$backup_root/manifest.sha256"
    backup_manifest_tmp="$backup_root/.manifest.sha256.tmp"
    backup_file_list="$backup_root/.files.list"
    backup_sorted_file_list="$backup_root/.files.list.sorted"

    bootstrap_sha256_available || return 1

    find "$backup_root" -type f ! -name 'manifest.sha256' ! -name '.manifest.sha256.tmp' ! -name '.INCOMPLETE' ! -name '.files.list' ! -name '.files.list.sorted' -print > "$backup_file_list" || return 1
    sort "$backup_file_list" > "$backup_sorted_file_list" || return 1
    (
        CDPATH= cd "$backup_root" || exit 1
        while IFS= read -r backup_absolute_file; do
            [ -n "$backup_absolute_file" ] || continue
            backup_relative_file=./${backup_absolute_file#"$backup_root"/}
            backup_digest=$(bootstrap_sha256_only "$backup_relative_file") || exit 1
            [ -n "$backup_digest" ] || exit 1
            printf '%s  %s\n' "$backup_digest" "$backup_relative_file"
        done < "$backup_sorted_file_list"
    ) > "$backup_manifest_tmp" || return 1

    mv "$backup_manifest_tmp" "$backup_manifest" || return 1
    chmod 600 "$backup_manifest" 2>/dev/null || true
}

backup_finish() {
    backup_root=$1
    backup_script=$2
    backup_source_root=$3
    backup_timestamp=$4

    backup_write_metadata "$backup_root/metadata.txt" "$backup_script" "$backup_source_root" "$backup_timestamp" || return 1
    backup_write_manifest "$backup_root" || return 1
    rm -f "$backup_root/.INCOMPLETE" "$backup_root/.manifest.sha256.tmp" "$backup_root/.files.list" "$backup_root/.files.list.sorted"
    chmod -R go-rwx "$backup_root" 2>/dev/null || true
}
