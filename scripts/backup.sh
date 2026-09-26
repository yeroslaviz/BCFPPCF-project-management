#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_runtime_env "${PPSV_ENV_FILE:-/etc/ppsv-app/ppsv-app.env}"
validate_runtime_paths

if [[ "$(id -un)" != "${APP_RUN_USER}" ]]; then
  reexec_as_app "${BASH_SOURCE[0]}"
fi

umask 0027
require_command sha256sum
require_command tar
require_command sqlite3
validate_backup_destination
acquire_lock "${PPSV_DATA_ROOT}/locks/maintenance.lock"

if [[ "${PPSV_POOL_SNAPSHOT_POLICY_ACK}" == 1 ]]; then
  log "External facility-pool snapshot policy is recorded as acknowledged."
else
  warn "Primary project-pool files are outside this backup; the external pool snapshot policy is not yet acknowledged."
fi

[[ "${PPSV_BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] || die "PPSV_BACKUP_RETENTION_DAYS must be a non-negative integer."

DB_BACKUP_DIR="${PPSV_BACKUP_DIR%/}/database"
FALLBACK_BACKUP_DIR="${PPSV_BACKUP_DIR%/}/fallback"
install -d -m 0750 "${DB_BACKUP_DIR}" "${FALLBACK_BACKUP_DIR}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
app_dir="$(validate_active_app_dir)"
db_final=""
fallback_final=""
db_partial=""
fallback_partial=""
db_sidecar_partial=""
fallback_sidecar_partial=""
restore_probe=""
cleanup_backup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -f -- "${db_partial:-}" "${fallback_partial:-}" \
    "${db_sidecar_partial:-}" "${fallback_sidecar_partial:-}" "${restore_probe:-}"
  exit "${status}"
}
trap cleanup_backup EXIT HUP INT TERM

if [[ -f "${PPSV_DB_FILE}" ]]; then
  db_final="${DB_BACKUP_DIR}/ppsv_projects_${timestamp}.sqlite"
  [[ ! -e "${db_final}" && ! -e "${db_final}.sha256" ]] || die "Backup timestamp collision: ${db_final}"
  db_partial="${db_final}.partial.$$"
  (
    cd "${app_dir}"
    Rscript "${SCRIPT_DIR}/backup_database.R" "${PPSV_DB_FILE}" "${db_partial}"
  )
  verify_sqlite_backup "${db_partial}"
  mv "${db_partial}" "${db_final}"
  db_partial=""
  db_sidecar_partial="${db_final}.sha256.partial.$$"
  (
    cd "${DB_BACKUP_DIR}"
    sha256sum "$(basename "${db_final}")" >"$(basename "${db_sidecar_partial}")"
  )
  mv "${db_sidecar_partial}" "${db_final}.sha256"
  db_sidecar_partial=""
  verify_sha256_sidecar "${db_final}"

  # Exercise the restore path into a disposable file, then open and validate
  # the result. A readable archive alone is not sufficient evidence that it
  # can be restored.
  restore_probe="$(mktemp "${DB_BACKUP_DIR}/.restore-drill.sqlite.XXXXXX")"
  install -m 0600 "${db_final}" "${restore_probe}"
  verify_sqlite_backup "${restore_probe}"
  rm -f -- "${restore_probe}"
  restore_probe=""
  log "Database backup and restore drill verified: ${db_final}"
else
  warn "Database does not exist yet; database backup skipped: ${PPSV_DB_FILE}"
fi

if [[ -L "${PPSV_FALLBACK_ROOT}" ]]; then
  die "Fallback storage root must not be a symbolic link: ${PPSV_FALLBACK_ROOT}"
elif [[ -d "${PPSV_FALLBACK_ROOT}" ]]; then
  if find "${PPSV_FALLBACK_ROOT}" \( -type l -o \( ! -type d ! -type f \) \) -print -quit | grep -q .; then
    die "Fallback storage contains a symbolic link or special file; refusing to archive it."
  fi
  fallback_final="${FALLBACK_BACKUP_DIR}/uploads_pending_pool_${timestamp}.tar.gz"
  [[ ! -e "${fallback_final}" && ! -e "${fallback_final}.sha256" ]] || die "Backup timestamp collision: ${fallback_final}"
  fallback_partial="${fallback_final}.partial.$$"
  tar --create --gzip --file "${fallback_partial}" --directory "${PPSV_FALLBACK_ROOT}" .
  verify_fallback_archive "${fallback_partial}"
  tar --compare --gzip --file "${fallback_partial}" --directory "${PPSV_FALLBACK_ROOT}" .
  mv "${fallback_partial}" "${fallback_final}"
  fallback_partial=""
  fallback_sidecar_partial="${fallback_final}.sha256.partial.$$"
  (
    cd "${FALLBACK_BACKUP_DIR}"
    sha256sum "$(basename "${fallback_final}")" >"$(basename "${fallback_sidecar_partial}")"
  )
  mv "${fallback_sidecar_partial}" "${fallback_final}.sha256"
  fallback_sidecar_partial=""
  verify_sha256_sidecar "${fallback_final}"
  log "Fallback-upload backup verified: ${fallback_final}"
fi

if [[ -n "${db_final}" ]]; then
  restore_check_args=(--database "${db_final}")
  [[ -z "${fallback_final}" ]] || restore_check_args+=(--fallback "${fallback_final}")
  "${SCRIPT_DIR}/restore_backup.sh" "${restore_check_args[@]}"
  log "The operator restore verifier accepted the new backup set."
fi

find "${DB_BACKUP_DIR}" -type f -mtime "+${PPSV_BACKUP_RETENTION_DAYS}" \( -name 'ppsv_projects_*.sqlite' -o -name 'ppsv_projects_*.sqlite.sha256' \) -delete
find "${FALLBACK_BACKUP_DIR}" -type f -mtime "+${PPSV_BACKUP_RETENTION_DAYS}" \( -name 'uploads_pending_pool_*.tar.gz' -o -name 'uploads_pending_pool_*.tar.gz.sha256' \) -delete
trap - EXIT HUP INT TERM
log "Backup completed; retention is ${PPSV_BACKUP_RETENTION_DAYS} days."
