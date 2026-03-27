#!/usr/bin/env bash
# cleanup_backups.sh - Retention-based backup cleanup for /home/vince/backups
#
# Retention policy (GFS rotation — remote copy on /mnt/backups/lamp-22 holds full set):
#   - Last 2 days:    keep the two most recent daily backups
#   - Last 1 week:    keep one backup per week (newest in previous ISO week)
#   - Beyond 1 week:  keep one backup per month (newest in each calendar month)
#
# Also cleans up:
#   - Log files for deleted bundle dates (same retention as bundles)
#   - Stale intermediate files (mongo, www, config) older than 1 day
#   - Legacy files in old/ directory
#
# Usage:
#   cleanup_backups.sh              # run for real
#   cleanup_backups.sh --dry-run    # preview what would be deleted

set -euo pipefail

BACKUP_DIR="/home/vince/backups"
LOG_TAG="backup-cleanup"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && DRY_RUN=true

log() { logger -t "$LOG_TAG" "$*" 2>/dev/null || true; echo "$(date '+%F %T') $*"; }

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

# --- Build set of dates to keep ---
declare -A keep_dates

# Tier 1: daily — keep the 2 most recent backups
sorted_dates=($(printf '%s\n' "${!all_dates[@]}" | sort -r))
for d in "${sorted_dates[@]:0:2}"; do
    keep_dates["$d"]="daily"
done

# Tier 2: weekly — newest from the previous ISO week only
this_week=$(date +%G-W%V)
prev_week=$(date -d "$today - 7 days" +%G-W%V)
declare -A week_newest
for d in "${!all_dates[@]}"; do
    week=$(date -d "$d" +%G-W%V)
    if [[ "$week" == "$prev_week" ]]; then
        if [[ -z "${week_newest[$prev_week]:-}" || "$d" > "${week_newest[$prev_week]}" ]]; then
            week_newest["$prev_week"]="$d"
        fi
    fi
done
for d in "${week_newest[@]}"; do
    [[ -z "${keep_dates[$d]:-}" ]] && keep_dates["$d"]="weekly"
done

# Tier 3: monthly — one per calendar month, excluding current month
this_month=$(date +%Y-%m)
declare -A month_newest
for d in "${!all_dates[@]}"; do
    month="${d:0:7}"
    [[ "$month" == "$this_month" ]] && continue
    if [[ -z "${month_newest[$month]:-}" || "$d" > "${month_newest[$month]}" ]]; then
        month_newest["$month"]="$d"
    fi
done
for d in "${month_newest[@]}"; do
    [[ -z "${keep_dates[$d]:-}" ]] && keep_dates["$d"]="monthly"
done

# --- Delete bundles not in keep set ---
deleted=0
freed=0

for f in "$BACKUP_DIR"/lamp22-archivist-bundle-*.tar.gz; do
    [[ -f "$f" ]] || continue
    d=$(basename "$f" | grep -oP '\d{4}-\d{2}-\d{2}') || continue
    if [[ -z "${keep_dates[$d]:-}" ]]; then
        size=$(stat -c '%s' "$f")
        if $DRY_RUN; then
            log "[DRY RUN] would delete: $(basename "$f") ($(numfmt --to=iec "$size"))"
        else
            log "deleting: $(basename "$f") ($(numfmt --to=iec "$size"))"
            rm -f "$f"
        fi
        (( freed += size )) || true
        (( deleted++ )) || true
    else
        log "keeping (${keep_dates[$d]}): $(basename "$f")"
    fi
done

# --- Delete logs whose bundle date is not in keep set ---
for f in "$BACKUP_DIR"/lamp22-archivist-bundle-*.log; do
    [[ -f "$f" ]] || continue
    d=$(basename "$f" | grep -oP '\d{4}-\d{2}-\d{2}') || continue
    if [[ -z "${keep_dates[$d]:-}" ]]; then
        if $DRY_RUN; then
            log "[DRY RUN] would delete log: $(basename "$f")"
        else
            log "deleting log: $(basename "$f")"
            rm -f "$f"
        fi
    fi
done

# --- Clean up stale intermediates older than 1 day ---
for pattern in \
    "lamp22-mongo-live-standalone-*.archive" \
    "lamp22-var-www-*.tgz" \
    "lamp22-etc-config-*.tgz"; do
    for f in "$BACKUP_DIR"/$pattern; do
        [[ -f "$f" ]] || continue
        if [[ -n $(find "$f" -mtime +1 -print 2>/dev/null) ]]; then
            size=$(stat -c '%s' "$f")
            if $DRY_RUN; then
                log "[DRY RUN] would delete stale intermediate: $(basename "$f") ($(numfmt --to=iec "$size"))"
            else
                log "deleting stale intermediate: $(basename "$f") ($(numfmt --to=iec "$size"))"
                rm -f "$f"
            fi
            (( freed += size )) || true
        fi
    done
done

# --- Clean up legacy old/ directory ---
if [[ -d "$BACKUP_DIR/old" ]]; then
    for f in "$BACKUP_DIR/old"/*; do
        [[ -f "$f" ]] || continue
        size=$(stat -c '%s' "$f")
        if $DRY_RUN; then
            log "[DRY RUN] would delete legacy: old/$(basename "$f") ($(numfmt --to=iec "$size"))"
        else
            log "deleting legacy: old/$(basename "$f") ($(numfmt --to=iec "$size"))"
            rm -f "$f"
        fi
        (( freed += size )) || true
    done
    if ! $DRY_RUN; then
        rmdir "$BACKUP_DIR/old" 2>/dev/null || true
    fi
fi

log "cleanup complete: $deleted bundles removed, $(numfmt --to=iec $freed) freed"
