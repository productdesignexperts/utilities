#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/vince/backups"
SUBMIT="/var/www/submit.archivist.site/php_cli/archivist-submit.php"

cd "$WORKDIR"

ts="$(date +%F-%H%M)"  # single timestamp for all artifacts in this run
host="$(hostname -s)"  # short hostname for file naming

# Files (exact naming pattern)
live_archive="${host}-live-standalone-${ts}.archive"              # created by mongodump --gzip
mongo_archive="${host}-mongo-live-standalone-${ts}.archive"       # renamed from live_archive
www_tgz="${host}-var-www-${ts}.tgz"                               # created by tar zcf
config_tgz="${host}-etc-config-${ts}.tgz"                         # system config files + cron scripts
bundle="${host}-archivist-bundle-${ts}.tar.gz"                    # composite containing mongo_archive + www_tgz + config_tgz
run_log="${host}-archivist-bundle-${ts}.log"                      # hashes + sizes + stdout/stderr

# Temp file for root crontab dump
root_crontab_tmp="${WORKDIR}/.root-crontab-${ts}.txt"

log_file_info () {
  local f="$1"
  local bytes sha
  bytes="$(stat -c '%s' "$f")"
  sha="$(sha256sum "$f" | awk '{print $1}')"
  echo "FILE: $f"
  echo "  SIZE_BYTES: $bytes"
  echo "  SHA256: $sha"
}

{
  echo "===== $(date -Is) start ====="
  echo "PWD: $(pwd)"
  echo

  # 1) Create Mongo archive (gzip happens inside the archive stream)
  echo "Running mongodump..."
  echo "  OUT: ${WORKDIR}/${live_archive}"
  mongodump --archive="${WORKDIR}/${live_archive}" --gzip

  if [[ ! -f "${WORKDIR}/${live_archive}" ]]; then
    echo "ERROR: mongodump did not create ${WORKDIR}/${live_archive}"
    exit 1
  fi

  # 2) Rename to mongo-live-standalone-...
  echo
  echo "Renaming mongo archive:"
  echo "  FROM: ${live_archive}"
  echo "  TO:   ${mongo_archive}"
  mv -f -- "${WORKDIR}/${live_archive}" "${WORKDIR}/${mongo_archive}"

  # 3) Create /var/www tarball into WORKDIR
  echo
  echo "Creating /var/www tarball..."
  echo "  OUT: ${WORKDIR}/${www_tgz}"
  tar zcf "${WORKDIR}/${www_tgz}" /var/www/

  if [[ ! -f "${WORKDIR}/${www_tgz}" ]]; then
    echo "ERROR: tar did not create ${WORKDIR}/${www_tgz}"
    exit 1
  fi

  # 4) Create system config tarball
  echo
  echo "Creating system config tarball..."
  echo "  OUT: ${WORKDIR}/${config_tgz}"

  # Dump root crontab to temp file
  crontab -l > "${root_crontab_tmp}" 2>/dev/null || echo "# no root crontab" > "${root_crontab_tmp}"
  echo "  Dumped root crontab to: ${root_crontab_tmp}"

  # Extract .php and .sh script paths from all crontabs
  # Note: grep returns exit 1 when no matches; use { || :; } to avoid pipefail exit
  cron_scripts=$(cat "${root_crontab_tmp}" /etc/crontab /etc/cron.d/* 2>/dev/null \
    | { grep -oE '/[^ ]+\.(php|sh)' || :; } | sort -u | while read -r f; do [[ -f "$f" ]] && echo "$f"; done)

  echo "  Cron scripts found:"
  if [[ -n "$cron_scripts" ]]; then
    echo "$cron_scripts" | sed 's/^/    /'
  else
    echo "    (none)"
  fi

  # Build list of static config paths (only include if they exist)
  config_paths=()
  for p in \
    /etc/apache2 \
    /etc/ssl \
    /etc/letsencrypt \
    /etc/mongod.conf \
    /etc/passwd \
    /etc/group \
    /etc/shadow \
    /etc/hosts \
    /etc/hostname \
    /etc/crontab \
    /etc/cron.d \
    /etc/cron.daily \
    /etc/cron.hourly \
    /etc/cron.weekly \
    /etc/cron.monthly
  do
    [[ -e "$p" ]] && config_paths+=("$p")
  done

  # Add the root crontab dump
  config_paths+=("${root_crontab_tmp}")

  # Add discovered cron scripts
  if [[ -n "$cron_scripts" ]]; then
    while IFS= read -r script; do
      config_paths+=("$script")
    done <<< "$cron_scripts"
  fi

  echo "  Config paths to archive:"
  printf '    %s\n' "${config_paths[@]}"

  # Create the config tarball
  tar zcf "${WORKDIR}/${config_tgz}" "${config_paths[@]}" 2>/dev/null

  if [[ ! -f "${WORKDIR}/${config_tgz}" ]]; then
    echo "ERROR: tar did not create ${WORKDIR}/${config_tgz}"
    exit 1
  fi

  # Cleanup temp crontab file
  rm -f "${root_crontab_tmp}"

  # 5) Hashes + sizes for individual files
  echo
  echo "Hash + size for individual files:"
  log_file_info "${WORKDIR}/${mongo_archive}"
  log_file_info "${WORKDIR}/${www_tgz}"
  log_file_info "${WORKDIR}/${config_tgz}"

  # 6) Create composite bundle containing all files (store relative names inside)
  echo
  echo "Building composite bundle:"
  echo "  OUT: ${WORKDIR}/${bundle}"
  tar zcf "${WORKDIR}/${bundle}" -C "${WORKDIR}" "${mongo_archive}" "${www_tgz}" "${config_tgz}"

  if [[ ! -f "${WORKDIR}/${bundle}" ]]; then
    echo "ERROR: composite tar did not create ${WORKDIR}/${bundle}"
    exit 1
  fi

  echo
  echo "Hash + size for composite bundle:"
  log_file_info "${WORKDIR}/${bundle}"

  # 7) Submit composite bundle (called externally but invoked from WORKDIR)
  echo
  echo "Submitting composite bundle: ${bundle}"
  "${SUBMIT}" "${bundle}"

  # 8) Cleanup intermediates
  echo
  echo "Cleaning up intermediates:"
  rm -f -- "${WORKDIR}/${mongo_archive}" "${WORKDIR}/${www_tgz}" "${WORKDIR}/${config_tgz}"
  echo "Removed: ${mongo_archive}, ${www_tgz}, ${config_tgz}"

  echo "===== $(date -Is) done ====="
} >> "${WORKDIR}/${run_log}" 2>&1

# Submit log file after the logging block closes
"${SUBMIT}" "${run_log}"

