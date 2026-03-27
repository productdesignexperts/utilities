#!/usr/bin/env bash
# move_backup.sh - Copy backups to /mnt/backups/lamp-22 organized by retention tier
#
# Copies bundles + logs into daily/, weekly/, monthly/ subdirectories based on
# the same GFS rotation logic used by cleanup_backups.sh:
#   - Last 3 days:    daily/
#   - 3–27 days:      weekly/   (newest per ISO week)
#   - 28+ days:       monthly/  (newest per calendar month)
#
# Safety:
#   - Skips files already at destination with matching size
#   - Verifies file size after copy; aborts that file on mismatch
#   - Does NOT delete local files — run cleanup_backups.sh afterward
#
# Usage:
#   move_backup.sh              # run for real
#   move_backup.sh --dry-run    # preview what would be copied

set -euo pipefail

BACKUP_DIR="/home/vince/backups"
DEST_BASE="/mnt/backups/lamp-22"
LOG_TAG="backup-move"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && DRY_RUN=true

log() { logger -t "$LOG_TAG" "$*" 2>/dev/null || true; echo "$(date '+%F %T') $*"; }

# --- Verify destination is accessible ---
if [[ ! -d "$DEST_BASE" ]]; then
    log "ERROR: destination $DEST_BASE does not exist or is not mounted"
    exit 1
fi

today=$(date +%F)
today_sec=$(date -d "$today" +%s)

# --- Collect all unique bundle dates ---
declare -A all_dates
for f in "$BACKUP_DIR"/lamp22-archivist-bundle-*.tar.gz; do
    [[ -f "$f" ]] || continue
    d=$(basename "$f" | grep -oP '\d{4}-\d{2}-\d{2}') || continue
    all_dates["$d"]=1
done

if (( ${#all_dates[@]} == 0 )); then
    log "no bundles found, nothing to do"
    exit 0
fi

# --- Classify each date into a retention tier ---
declare -A date_tier

# Tier 1: daily — last 3 days
for d in "${!all_dates[@]}"; do
    d_sec=$(date -d "$d" +%s)
    age=$(( (today_sec - d_sec) / 86400 ))
    (( age < 3 )) && date_tier["$d"]="daily"
done

# Tier 2: weekly — one per ISO week, aged 3–27 days
declare -A week_newest
for d in "${!all_dates[@]}"; do
    d_sec=$(date -d "$d" +%s)
    age=$(( (today_sec - d_sec) / 86400 ))
    if (( age >= 3 && age < 28 )); then
        week=$(date -d "$d" +%G-W%V)
        if [[ -z "${week_newest[$week]:-}" || "$d" > "${week_newest[$week]}" ]]; then
            week_newest["$week"]="$d"
        fi
    fi
done
for d in "${week_newest[@]}"; do
    [[ -z "${date_tier[$d]:-}" ]] && date_tier["$d"]="weekly"
done

# Tier 3: monthly — one per calendar month, aged 28+ days
declare -A month_newest
for d in "${!all_dates[@]}"; do
    d_sec=$(date -d "$d" +%s)
    age=$(( (today_sec - d_sec) / 86400 ))
    if (( age >= 28 )); then
        month="${d:0:7}"
        if [[ -z "${month_newest[$month]:-}" || "$d" > "${month_newest[$month]}" ]]; then
            month_newest["$month"]="$d"
        fi
    fi
done
for d in "${month_newest[@]}"; do
    [[ -z "${date_tier[$d]:-}" ]] && date_tier["$d"]="monthly"
done

# --- Copy files to their tier directory ---
copied=0
skipped=0
failed=0
bytes_copied=0

copy_file() {
    local src="$1" dest_dir="$2"
    local fname
    fname=$(basename "$src")
    local dest="$dest_dir/$fname"
    local src_size
    src_size=$(stat -c '%s' "$src")

    # Skip if destination already has matching file
    if [[ -f "$dest" ]]; then
        local dest_size
        dest_size=$(stat -c '%s' "$dest")
        if (( src_size == dest_size )); then
            log "skip (already exists, size matches): $fname -> $(basename "$dest_dir")/"
            (( skipped++ )) || true
            return 0
        else
            log "WARNING: size mismatch for existing $fname (src=${src_size}, dest=${dest_size}), re-copying"
        fi
    fi

    if $DRY_RUN; then
        log "[DRY RUN] would copy: $fname -> $(basename "$dest_dir")/ ($(numfmt --to=iec "$src_size"))"
        return 0
    fi

    log "copying: $fname -> $(basename "$dest_dir")/ ($(numfmt --to=iec "$src_size"))"
    cp -- "$src" "$dest"

    # Verify size after copy
    local copied_size
    copied_size=$(stat -c '%s' "$dest")
    if (( src_size != copied_size )); then
        log "ERROR: size verification failed for $fname (src=${src_size}, dest=${copied_size}), removing bad copy"
        rm -f "$dest"
        (( failed++ )) || true
        return 1
    fi

    (( copied++ )) || true
    (( bytes_copied += src_size )) || true
}

# Create tier directories
for tier in daily weekly monthly; do
    if ! $DRY_RUN; then
        mkdir -p "$DEST_BASE/$tier"
    fi
done

# Process each bundle that has a tier assignment
for f in "$BACKUP_DIR"/lamp22-archivist-bundle-*.tar.gz; do
    [[ -f "$f" ]] || continue
    d=$(basename "$f" | grep -oP '\d{4}-\d{2}-\d{2}') || continue

    tier="${date_tier[$d]:-}"
    if [[ -z "$tier" ]]; then
        log "skip (not in retention set): $(basename "$f")"
        continue
    fi

    dest_dir="$DEST_BASE/$tier"

    # Copy the bundle
    copy_file "$f" "$dest_dir"

    # Copy the matching log if it exists
    local_log="${f%.tar.gz}.log"
    if [[ -f "$local_log" ]]; then
        copy_file "$local_log" "$dest_dir"
    fi
done

if $DRY_RUN; then
    log "dry run complete"
else
    log "move complete: $copied files copied ($(numfmt --to=iec $bytes_copied)), $skipped skipped, $failed failed"
fi
