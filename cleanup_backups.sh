#!/usr/bin/env bash
# cleanup_backups.sh - Retention-based backup cleanup for /home/vince/backups
#
# Retention policy (GFS rotation):
#   - Last 3 days:   keep all daily backups
#   - Last 4 weeks:  keep one backup per week (newest in each ISO week)
#   - Beyond 4 weeks: keep one backup per month (newest in each calendar month)
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

# Tier 1: daily — keep all backups from the last 3 days
for d in "${!all_dates[@]}"; do
    d_sec=$(date -d "$d" +%s)
    age=$(( (today_sec - d_sec) / 86400 ))
    (( age < 3 )) && keep_dates["$d"]="daily"
done

# Tier 2: weekly — one per ISO week, for backups aged 3–27 days
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
    [[ -z "${keep_dates[$d]:-}" ]] && keep_dates["$d"]="weekly"
done

# Tier 3: monthly — one per calendar month, for backups aged 28+ days
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
