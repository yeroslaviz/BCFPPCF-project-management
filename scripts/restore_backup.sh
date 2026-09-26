#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${PPSV_ENV_FILE:-/etc/ppsv-app/ppsv-app.env}"
DATABASE_BACKUP=""
FALLBACK_BACKUP=""
APPLY=0
CONFIRMED=0

usage() {
  cat <<'USAGE'
Usage: restore_backup.sh --database FILE [--fallback ARCHIVE] [options]

Without --apply this performs a read-only restore verification. Every artifact
must have the one-record .sha256 sidecar created by backup.sh. To replace
production state, both --apply and --confirm-data-loss are mandatory; inputs
are staged and verified before services stop or live paths change.

Options:
  --database FILE          Verified SQLite backup to inspect/restore.
  --fallback ARCHIVE       Optional fallback-upload .tar.gz to inspect/restore.
  --env FILE               Runtime environment file.
  --apply                  Apply the verified restore.
  --confirm-data-loss      Acknowledge loss of data newer than the backup.
USAGE
}

while (($#)); do
  case "$1" in
    --database)
      [[ $# -ge 2 ]] || die "--database needs a file"
      DATABASE_BACKUP="$2"
      shift 2
      ;;
    --fallback)
      [[ $# -ge 2 ]] || die "--fallback needs a file"
      FALLBACK_BACKUP="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env needs a file"
      ENV_FILE="$2"
      shift 2
      ;;
    --apply) APPLY=1; shift ;;
    --confirm-data-loss) CONFIRMED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

load_runtime_env "${ENV_FILE}"
validate_runtime_paths
[[ -f "${DATABASE_BACKUP}" ]] || die "Database backup not found: ${DATABASE_BACKUP:-<unset>}"
require_command sha256sum
require_command sqlite3
verify_sha256_sidecar "${DATABASE_BACKUP}"
verify_sqlite_backup "${DATABASE_BACKUP}"
database_expected_hash="$(sha256sum "${DATABASE_BACKUP}" | awk '{ print $1 }')"

fallback_expected_hash=""
if [[ -n "${FALLBACK_BACKUP}" ]]; then
  [[ -f "${FALLBACK_BACKUP}" ]] || die "Fallback archive not found: ${FALLBACK_BACKUP}"
  verify_sha256_sidecar "${FALLBACK_BACKUP}"
  verify_fallback_archive "${FALLBACK_BACKUP}"
  fallback_expected_hash="$(sha256sum "${FALLBACK_BACKUP}" | awk '{ print $1 }')"
fi

log "Backup verification passed."
((APPLY == 1)) || exit 0
((CONFIRMED == 1)) || die "Applying a restore requires --confirm-data-loss."
require_root
[[ ! -L "${PPSV_DATA_ROOT}" && ! -L "${PPSV_DB_FILE}" && ! -L "${PPSV_FALLBACK_ROOT}" ]] || die "Refusing restore through a symbolic-link runtime path."
[[ ! -e "${PPSV_DB_FILE}" || -f "${PPSV_DB_FILE}" ]] || die "Live database path is not a regular file: ${PPSV_DB_FILE}"
[[ ! -e "${PPSV_FALLBACK_ROOT}" || -d "${PPSV_FALLBACK_ROOT}" ]] || die "Live fallback path is not a directory: ${PPSV_FALLBACK_ROOT}"
[[ "$(readlink -f "${DATABASE_BACKUP}")" != "$(readlink -f "${PPSV_DB_FILE}" 2>/dev/null || true)" ]] || die "The backup and live database resolve to the same file."
acquire_lock "${PPSV_DATA_ROOT}/locks/maintenance.lock"
app_dir="$(validate_active_app_dir)"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
recovery_parent="${PPSV_DATA_ROOT}/pre_restore"
db_parent="$(dirname "${PPSV_DB_FILE}")"
fallback_parent="$(dirname "${PPSV_FALLBACK_ROOT}")"
[[ -d "${recovery_parent}" && ! -L "${recovery_parent}" ]] || die "Protected pre-restore directory is missing: ${recovery_parent}"
[[ -d "${db_parent}" && ! -L "${db_parent}" ]] || die "Database parent directory is missing or unsafe: ${db_parent}"
[[ -d "${fallback_parent}" && ! -L "${fallback_parent}" ]] || die "Fallback parent directory is missing or unsafe: ${fallback_parent}"
[[ "$(stat -c '%U:%G' "${recovery_parent}")" == "root:${APP_RUN_GROUP}" && "$(stat -c '%a' "${recovery_parent}")" == 750 ]] || die "Pre-restore directory must be root:${APP_RUN_GROUP} mode 0750: ${recovery_parent}"
recovery_dir="$(mktemp -d "${recovery_parent}/${timestamp}.XXXXXX")"
chown root:root "${recovery_dir}"
chmod 0700 "${recovery_dir}"
db_stage=""
fallback_stage=""
fallback_archive_stage=""
cleanup_staging() {
  local status=$?
  trap - EXIT HUP INT TERM
  [[ ! -e "${db_stage}" ]] || rm -f -- "${db_stage}"
  [[ -z "${fallback_stage}" || ! -e "${fallback_stage}" ]] || rm -rf -- "${fallback_stage}"
  [[ -z "${fallback_archive_stage}" || ! -e "${fallback_archive_stage}" ]] || rm -f -- "${fallback_archive_stage}"
  rmdir -- "${recovery_dir}" 2>/dev/null || true
  exit "${status}"
}
trap cleanup_staging EXIT HUP INT TERM
[[ "$(stat -c '%d' "${recovery_dir}")" == "$(stat -c '%d' "${db_parent}")" ]] || die "Pre-restore and database paths must share a filesystem for atomic activation."
[[ "$(stat -c '%d' "${recovery_dir}")" == "$(stat -c '%d' "${fallback_parent}")" ]] || die "Pre-restore and fallback paths must share a filesystem for atomic activation."
db_stage="$(mktemp "${recovery_dir}/database.restore.XXXXXX")"
install -o root -g root -m 0600 "${DATABASE_BACKUP}" "${db_stage}"
[[ "$(sha256sum "${db_stage}" | awk '{ print $1 }')" == "${database_expected_hash}" ]] || die "Database backup changed while it was staged."
verify_sqlite_backup "${db_stage}"

if [[ -n "${FALLBACK_BACKUP}" ]]; then
  fallback_archive_stage="$(mktemp "${recovery_dir}/fallback-restore-archive.XXXXXX")"
  install -o root -g root -m 0600 "${FALLBACK_BACKUP}" "${fallback_archive_stage}"
  [[ "$(sha256sum "${fallback_archive_stage}" | awk '{ print $1 }')" == "${fallback_expected_hash}" ]] || die "Fallback backup changed while it was staged."
  verify_fallback_archive "${fallback_archive_stage}"
  fallback_stage="$(mktemp -d "${recovery_dir}/uploads.restore.XXXXXX")"
  chown root:root "${fallback_stage}"
  chmod 0700 "${fallback_stage}"
  tar --extract --gzip --file "${fallback_archive_stage}" --directory "${fallback_stage}" --no-same-owner --no-same-permissions
  if find "${fallback_stage}" \( -type l -o \( ! -type d ! -type f \) \) -print -quit | grep -q .; then
    die "Fallback archive produced a symbolic link or special file; restore aborted."
  fi
  rm -f -- "${fallback_archive_stage}"
  fallback_archive_stage=""
fi

shiny_was_active=0
mail_timer_was_active=0
backup_timer_was_active=0
systemctl is-active --quiet shiny-server.service && shiny_was_active=1
systemctl is-active --quiet ppsv-mail-outbox.timer && mail_timer_was_active=1
systemctl is-active --quiet ppsv-backup.timer && backup_timer_was_active=1

db_old_moved=0
db_activated=0
fallback_old_moved=0
fallback_activated=0
commit_complete=0
cleanup_restore() {
  local status=$?
  local rollback_failed=0
  trap - EXIT HUP INT TERM
  if [[ ${commit_complete:-0} -eq 0 ]]; then
    ((status != 0)) || status=1
    warn "Restore did not commit; restoring the pre-restore state."
    systemctl stop shiny-server.service ppsv-mail-outbox.service 2>/dev/null || true
    if [[ ${db_activated:-0} -eq 1 && -e "${PPSV_DB_FILE}" ]]; then
      mv -T "${PPSV_DB_FILE}" "${recovery_dir}/failed-restored-database.sqlite" || rollback_failed=1
    fi
    rm -f -- "${PPSV_DB_FILE}-wal" "${PPSV_DB_FILE}-shm"
    if [[ ${db_old_moved:-0} -eq 1 ]]; then
      [[ ! -e "${PPSV_DB_FILE}" ]] || rollback_failed=1
      ((rollback_failed == 1)) || mv -T "${recovery_dir}/database.raw.sqlite" "${PPSV_DB_FILE}" || rollback_failed=1
      [[ ! -e "${recovery_dir}/database.raw.sqlite-wal" ]] || mv -T "${recovery_dir}/database.raw.sqlite-wal" "${PPSV_DB_FILE}-wal" || rollback_failed=1
      [[ ! -e "${recovery_dir}/database.raw.sqlite-shm" ]] || mv -T "${recovery_dir}/database.raw.sqlite-shm" "${PPSV_DB_FILE}-shm" || rollback_failed=1
    fi
    if [[ ${fallback_activated:-0} -eq 1 && -e "${PPSV_FALLBACK_ROOT}" ]]; then
      mv -T "${PPSV_FALLBACK_ROOT}" "${recovery_dir}/failed-restored-uploads" || rollback_failed=1
    fi
    if [[ ${fallback_old_moved:-0} -eq 1 ]]; then
      [[ ! -e "${PPSV_FALLBACK_ROOT}" ]] || rollback_failed=1
      ((rollback_failed == 1)) || mv -T "${recovery_dir}/uploads_pending_pool" "${PPSV_FALLBACK_ROOT}" || rollback_failed=1
    fi
  fi
  [[ -z "${db_stage:-}" || ! -e "${db_stage}" ]] || rm -f -- "${db_stage}"
  [[ -z "${fallback_stage:-}" || ! -e "${fallback_stage}" ]] || rm -rf -- "${fallback_stage}"
  [[ -z "${fallback_archive_stage:-}" || ! -e "${fallback_archive_stage}" ]] || rm -f -- "${fallback_archive_stage}"
  if ((rollback_failed == 1)); then
    warn "Automatic rollback was incomplete. Services remain stopped; recover from ${recovery_dir} before restarting them."
    status=1
  else
    ((shiny_was_active == 0)) || systemctl start shiny-server.service || warn "Could not restart Shiny Server."
    ((mail_timer_was_active == 0)) || systemctl start ppsv-mail-outbox.timer || warn "Could not restart mail-outbox timer."
    ((backup_timer_was_active == 0)) || systemctl start ppsv-backup.timer || warn "Could not restart backup timer."
  fi
  exit "${status}"
}
trap cleanup_restore EXIT HUP INT TERM

systemctl stop ppsv-backup.timer ppsv-mail-outbox.timer ppsv-mail-outbox.service shiny-server.service 2>/dev/null || true

if [[ -f "${PPSV_DB_FILE}" ]]; then
  (
    cd "${app_dir}"
    Rscript "${SCRIPT_DIR}/backup_database.R" "${PPSV_DB_FILE}" "${recovery_dir}/database.sqlite"
  )
  chown root:root "${recovery_dir}/database.sqlite"
  chmod 0600 "${recovery_dir}/database.sqlite"
  verify_sqlite_backup "${recovery_dir}/database.sqlite"
  (
    cd "${recovery_dir}"
    sha256sum database.sqlite >database.sqlite.sha256
  )
  chown root:root "${recovery_dir}/database.sqlite.sha256"
  chmod 0600 "${recovery_dir}/database.sqlite.sha256"
  mv -T "${PPSV_DB_FILE}" "${recovery_dir}/database.raw.sqlite"
  db_old_moved=1
  [[ ! -e "${PPSV_DB_FILE}-wal" ]] || mv -T "${PPSV_DB_FILE}-wal" "${recovery_dir}/database.raw.sqlite-wal"
  [[ ! -e "${PPSV_DB_FILE}-shm" ]] || mv -T "${PPSV_DB_FILE}-shm" "${recovery_dir}/database.raw.sqlite-shm"
fi

chown "${APP_RUN_USER}:${APP_RUN_GROUP}" "${db_stage}"
chmod 0660 "${db_stage}"
mv -T "${db_stage}" "${PPSV_DB_FILE}"
db_stage=""
db_activated=1
verify_sqlite_backup "${PPSV_DB_FILE}"
(
  cd "${app_dir}"
  run_as_app env PPSV_DB_FILE="${PPSV_DB_FILE}" AUTH_MODE=ldap PPSV_RESET_DB=0 \
    RENV_PATHS_CACHE="${RENV_PATHS_CACHE}" Rscript setup_database.R
)
restored_schema_version="$(sqlite3 "${PPSV_DB_FILE}" 'SELECT COALESCE(MAX(version),0) FROM schema_migrations;')"
[[ "${restored_schema_version}" == 3 ]] || die "Restored database did not migrate to current schema version 3."

if [[ -n "${FALLBACK_BACKUP}" ]]; then
  chown -R "${APP_RUN_USER}:${APP_RUN_GROUP}" "${fallback_stage}"
  find "${fallback_stage}" -type d -exec chmod 2770 {} +
  find "${fallback_stage}" -type f -exec chmod 0660 {} +
  if [[ -e "${PPSV_FALLBACK_ROOT}" ]]; then
    mv -T "${PPSV_FALLBACK_ROOT}" "${recovery_dir}/uploads_pending_pool"
    fallback_old_moved=1
  fi
  mv -T "${fallback_stage}" "${PPSV_FALLBACK_ROOT}"
  fallback_stage=""
  fallback_activated=1
fi

commit_complete=1
((shiny_was_active == 0)) || systemctl start shiny-server.service
((mail_timer_was_active == 0)) || systemctl start ppsv-mail-outbox.timer
((backup_timer_was_active == 0)) || systemctl start ppsv-backup.timer
trap - EXIT HUP INT TERM
log "Restore applied. Pre-restore state is retained at ${recovery_dir}."
