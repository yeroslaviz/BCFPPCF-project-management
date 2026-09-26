#!/usr/bin/env bash

# Shared constants and validation helpers for PPSV operator scripts.
# This file is sourced; callers are responsible for `set -euo pipefail`.

PPSV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PPSV_REPO_ROOT_DEFAULT="$(cd "${PPSV_SCRIPT_DIR}/.." && pwd)"

log() {
  printf '[PPSV] %s\n' "$*"
}

warn() {
  printf '[PPSV] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[PPSV] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run this command as root (for example, with sudo)."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

require_absolute_path() {
  local name="$1"
  local value="$2"
  [[ -n "${value}" && "${value}" = /* ]] || die "${name} must be an absolute path."
}

require_value() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "${value}" ]] || die "Required setting ${name} is empty or unset."
}

load_runtime_env() {
  local requested_file="${1:-${PPSV_ENV_FILE:-/etc/ppsv-app/ppsv-app.env}}"

  [[ -f "${requested_file}" && ! -L "${requested_file}" ]] || die "Runtime environment file must be a regular, non-symlink file: ${requested_file}"
  local env_owner env_mode env_mode_value
  env_owner="$(stat -c '%u' "${requested_file}")"
  env_mode="$(stat -c '%a' "${requested_file}")"
  [[ "${env_owner}" == 0 ]] || die "Runtime environment file must be owned by root: ${requested_file}"
  env_mode_value=$((8#${env_mode}))
  (( (env_mode_value & 8#0037) == 0 )) || die "Runtime environment file must be mode 0640 or stricter (no group write/execute or other access): ${requested_file}"

  if [[ -r "${requested_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${requested_file}"
    set +a
  elif [[ ${EUID} -ne 0 && "${PPSV_ENV_PRELOADED:-0}" == 1 ]]; then
    # systemd reads EnvironmentFile as root. This marker permits mode 0600
    # while still requiring the on-disk file to pass the ownership/mode checks.
    :
  else
    die "Runtime environment file is not readable and no trusted preloaded environment is present: ${requested_file}"
  fi

  export PPSV_ENV_FILE="${requested_file}"
  export APP_RUN_USER="${APP_RUN_USER:-ppsvf-shiny-user}"
  export APP_RUN_GROUP="${APP_RUN_GROUP:-ppsvf-shiny}"
  export PPSV_POOL_GROUP="${PPSV_POOL_GROUP:-b_profa}"
  export PPSV_RELEASES_ROOT="${PPSV_RELEASES_ROOT:-/srv/ppsv-app/releases}"
  export PPSV_DATA_ROOT="${PPSV_DATA_ROOT:-/srv/ppsv-app-data}"
  export PPSV_CURRENT_LINK="${PPSV_CURRENT_LINK:-/srv/shiny-server/ppsv-app}"
  export PPSV_DB_FILE="${PPSV_DB_FILE:-${PPSV_DATA_ROOT}/ppsv_projects.db}"
  export PPSV_POOL_ROOT="${PPSV_POOL_ROOT:-/fs/pool/pool-ppsvf-projects}"
  export PPSV_FALLBACK_ROOT="${PPSV_FALLBACK_ROOT:-${PPSV_DATA_ROOT}/uploads_pending_pool}"
  export PPSV_PUBLIC_URL="${PPSV_PUBLIC_URL:-https://ppcf-vm.biochem.mpg.de/ppsv-app/}"
  export PPSV_BACKUP_RETENTION_DAYS="${PPSV_BACKUP_RETENTION_DAYS:-30}"
  export PPSV_ALLOW_LOCAL_BACKUP="${PPSV_ALLOW_LOCAL_BACKUP:-0}"
  export PPSV_BACKUP_EXPECTED_SOURCE="${PPSV_BACKUP_EXPECTED_SOURCE:-}"
  export PPSV_ALLOW_LOCAL_POOL="${PPSV_ALLOW_LOCAL_POOL:-0}"
  export PPSV_POOL_EXPECTED_SOURCE="${PPSV_POOL_EXPECTED_SOURCE:-}"
  export PPSV_POOL_SNAPSHOT_POLICY_ACK="${PPSV_POOL_SNAPSHOT_POLICY_ACK:-0}"
  export PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK="${PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK:-0}"
  export PPSV_TICKET_E2E_TEST_ACK="${PPSV_TICKET_E2E_TEST_ACK:-0}"
  export RENV_PATHS_CACHE="${RENV_PATHS_CACHE:-${PPSV_DATA_ROOT}/renv-cache}"
}

reexec_as_app() {
  local script="$1"
  shift
  [[ "$(id -un)" != "${APP_RUN_USER}" ]] || return 0
  require_root
  unset BASH_ENV ENV CDPATH GLOBIGNORE R_ENVIRON R_ENVIRON_USER R_PROFILE R_PROFILE_USER
  unset R_LIBS R_LIBS_USER LD_PRELOAD PYTHONPATH PERL5OPT
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/nonexistent TMPDIR=/tmp
  export PPSV_ENV_PRELOADED=1
  exec runuser -u "${APP_RUN_USER}" --preserve-environment -- "${script}" "$@"
}

validate_runtime_paths() {
  require_absolute_path PPSV_RELEASES_ROOT "${PPSV_RELEASES_ROOT}"
  require_absolute_path PPSV_DATA_ROOT "${PPSV_DATA_ROOT}"
  require_absolute_path PPSV_CURRENT_LINK "${PPSV_CURRENT_LINK}"
  require_absolute_path PPSV_DB_FILE "${PPSV_DB_FILE}"
  require_absolute_path PPSV_POOL_ROOT "${PPSV_POOL_ROOT}"
  require_absolute_path PPSV_FALLBACK_ROOT "${PPSV_FALLBACK_ROOT}"

  local path_value
  for path_value in \
    "${PPSV_RELEASES_ROOT}" \
    "${PPSV_DATA_ROOT}" \
    "${PPSV_CURRENT_LINK}" \
    "${PPSV_DB_FILE}" \
    "${PPSV_POOL_ROOT}" \
    "${PPSV_FALLBACK_ROOT}"; do
    [[ "${path_value}" != / && "${path_value}" != *'/../'* && "${path_value}" != */.. ]] || die "Unsafe runtime path: ${path_value}"
  done

  case "${PPSV_DB_FILE}" in
    "${PPSV_DATA_ROOT}"/*) ;;
    *) die "PPSV_DB_FILE must be below PPSV_DATA_ROOT." ;;
  esac
  case "${PPSV_FALLBACK_ROOT}" in
    "${PPSV_DATA_ROOT}"/*) ;;
    *) die "PPSV_FALLBACK_ROOT must be below PPSV_DATA_ROOT." ;;
  esac

  case "${AUTH_MODE:-ldap}" in
    ldap|test) ;;
    *) die "AUTH_MODE must be ldap or test." ;;
  esac
  case "${PPSV_TICKET_MODE:-disabled}" in
    disabled|service_reply_to|ldap_from) ;;
    *) die "PPSV_TICKET_MODE must be disabled, service_reply_to, or ldap_from." ;;
  esac
  case "${PPSV_SMTP_SECURITY:-starttls}" in
    none|ssl|starttls) ;;
    *) die "PPSV_SMTP_SECURITY must be none, ssl, or starttls." ;;
  esac
  local upload_limit smtp_port direct_ack_value
  upload_limit="${PPSV_MAX_UPLOAD_MB:-75}"
  smtp_port="${PPSV_SMTP_PORT:-587}"
  [[ "${upload_limit}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "PPSV_MAX_UPLOAD_MB must be a positive number."
  awk -v value="${upload_limit}" 'BEGIN { exit !(value > 0) }' || die "PPSV_MAX_UPLOAD_MB must be greater than zero."
  [[ "${smtp_port}" =~ ^[0-9]+$ ]] || die "PPSV_SMTP_PORT must be an integer."
  (( 10#${smtp_port} >= 1 && 10#${smtp_port} <= 65535 )) || die "PPSV_SMTP_PORT must be between 1 and 65535."
  direct_ack_value="$(printf '%s' "${PPSV_DIRECT_ACK:-false}" | tr '[:upper:]' '[:lower:]')"
  case "${direct_ack_value}" in
    0|1|false|true|no|yes|off|on) ;;
    *) die "PPSV_DIRECT_ACK must be a boolean value." ;;
  esac
  if [[ "${PPSV_TICKET_MODE:-disabled}" != disabled ]]; then
    require_value PPSV_TICKET_TO
    require_value PPSV_MAIL_FROM
    require_value PPSV_SMTP_HOST
  fi
  case "${PPSV_POOL_SNAPSHOT_POLICY_ACK}" in
    0|1) ;;
    *) die "PPSV_POOL_SNAPSHOT_POLICY_ACK must be 0 or 1." ;;
  esac
  case "${PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK}" in
    0|1) ;;
    *) die "PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK must be 0 or 1." ;;
  esac
  case "${PPSV_TICKET_E2E_TEST_ACK}" in
    0|1) ;;
    *) die "PPSV_TICKET_E2E_TEST_ACK must be 0 or 1." ;;
  esac
  case "${PPSV_ALLOW_LOCAL_POOL}" in
    0|1) ;;
    *) die "PPSV_ALLOW_LOCAL_POOL must be 0 or 1." ;;
  esac
}

validate_active_app_dir() {
  local active_app
  active_app="$(readlink -f "${PPSV_CURRENT_LINK}" 2>/dev/null || true)"
  [[ -n "${active_app}" && -d "${active_app}" ]] || die "Active PPSV application release is unavailable."
  case "${active_app}" in
    "${PPSV_RELEASES_ROOT}"/*/ppsv-app) ;;
    *) die "Active PPSV application is outside the immutable release root: ${active_app}" ;;
  esac
  printf '%s\n' "${active_app}"
}

validate_backup_destination() {
  require_value PPSV_BACKUP_DIR
  require_absolute_path PPSV_BACKUP_DIR "${PPSV_BACKUP_DIR}"
  [[ "${PPSV_BACKUP_DIR}" != *REQUIRED* ]] || die "PPSV_BACKUP_DIR still contains an unresolved placeholder."
  [[ -d "${PPSV_BACKUP_DIR}" && ! -L "${PPSV_BACKUP_DIR}" ]] || die "Backup destination must be an existing, non-symlink directory: ${PPSV_BACKUP_DIR}"
  [[ -w "${PPSV_BACKUP_DIR}" ]] || die "Backup destination is not writable: ${PPSV_BACKUP_DIR}"

  case "${PPSV_ALLOW_LOCAL_BACKUP}" in
    0|1) ;;
    *) die "PPSV_ALLOW_LOCAL_BACKUP must be 0 or 1." ;;
  esac
  if [[ "${PPSV_ALLOW_LOCAL_BACKUP}" == 1 ]]; then
    warn "Local backup storage is explicitly enabled. This is suitable only for a test VM."
    return 0
  fi

  require_command findmnt
  local mount_source mount_target mount_type mount_options mount_device root_device
  mount_source="$(findmnt -n -o SOURCE -T "${PPSV_BACKUP_DIR}" 2>/dev/null || true)"
  mount_target="$(findmnt -n -o TARGET -T "${PPSV_BACKUP_DIR}" 2>/dev/null || true)"
  mount_type="$(findmnt -n -o FSTYPE -T "${PPSV_BACKUP_DIR}" 2>/dev/null || true)"
  mount_options="$(findmnt -n -o OPTIONS -T "${PPSV_BACKUP_DIR}" 2>/dev/null || true)"
  mount_device="$(findmnt -n -o MAJ:MIN -T "${PPSV_BACKUP_DIR}" 2>/dev/null || true)"
  root_device="$(findmnt -n -o MAJ:MIN -T / 2>/dev/null || true)"
  [[ -n "${mount_source}" && -n "${mount_target}" ]] || die "PPSV_BACKUP_DIR is not on a discoverable mounted filesystem."
  [[ "${mount_target}" != / ]] || die "PPSV_BACKUP_DIR resolves to the root filesystem; external mounted storage is required."
  [[ -z "${mount_device}" || -z "${root_device}" || "${mount_device}" != "${root_device}" ]] || die "Backup destination uses the same backing device as /; external storage is required."
  case "${mount_type}" in
    tmpfs|ramfs|overlay) die "Unsupported backup filesystem ${mount_type}; durable external storage is required." ;;
  esac
  case ",${mount_options}," in
    *,ro,*) die "Backup filesystem is mounted read-only: ${mount_target}" ;;
  esac
  [[ -n "${PPSV_BACKUP_EXPECTED_SOURCE}" ]] || die "Set PPSV_BACKUP_EXPECTED_SOURCE to the reviewed findmnt SOURCE for the external backup mount."
  [[ "${PPSV_BACKUP_EXPECTED_SOURCE}" != *REQUIRED* ]] || die "PPSV_BACKUP_EXPECTED_SOURCE still contains an unresolved placeholder."
  [[ "${mount_source}" == "${PPSV_BACKUP_EXPECTED_SOURCE}" ]] || die "Backup mount source changed: expected ${PPSV_BACKUP_EXPECTED_SOURCE}, found ${mount_source}."
  log "Backup target is mounted from ${mount_source} at ${mount_target} (${mount_type})."
}

validate_pool_destination() {
  [[ -d "${PPSV_POOL_ROOT}" && ! -L "${PPSV_POOL_ROOT}" ]] || die "Project pool must be an existing, non-symlink directory: ${PPSV_POOL_ROOT}"
  if [[ "${PPSV_ALLOW_LOCAL_POOL}" == 1 ]]; then
    warn "Local project-pool storage is explicitly enabled. This is suitable only for a test VM."
    return 0
  fi

  require_command findmnt
  local mount_source mount_target mount_type mount_options root_device pool_device
  mount_source="$(findmnt -n -o SOURCE -T "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
  mount_target="$(findmnt -n -o TARGET -T "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
  mount_type="$(findmnt -n -o FSTYPE -T "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
  mount_options="$(findmnt -n -o OPTIONS -T "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
  pool_device="$(findmnt -n -o MAJ:MIN -T "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
  root_device="$(findmnt -n -o MAJ:MIN -T / 2>/dev/null || true)"
  [[ -n "${mount_source}" && -n "${mount_target}" ]] || die "PPSV_POOL_ROOT is not on a discoverable mounted filesystem."
  [[ "${mount_target}" != / ]] || die "PPSV_POOL_ROOT resolves to the root filesystem; the facility pool mount is required."
  [[ -z "${pool_device}" || -z "${root_device}" || "${pool_device}" != "${root_device}" ]] || die "PPSV_POOL_ROOT uses the root backing device; the facility pool mount is required."
  case "${mount_type}" in
    tmpfs|ramfs|overlay) die "Unsupported project-pool filesystem ${mount_type}." ;;
  esac
  case ",${mount_options}," in
    *,ro,*) die "Project pool is mounted read-only: ${mount_target}" ;;
  esac
  [[ -n "${PPSV_POOL_EXPECTED_SOURCE}" && "${PPSV_POOL_EXPECTED_SOURCE}" != *REQUIRED* ]] || die "Set PPSV_POOL_EXPECTED_SOURCE to the reviewed findmnt SOURCE for the facility pool mount."
  [[ "${mount_source}" == "${PPSV_POOL_EXPECTED_SOURCE}" ]] || die "Project-pool mount source changed: expected ${PPSV_POOL_EXPECTED_SOURCE}, found ${mount_source}."
  log "Project pool is mounted from ${mount_source} at ${mount_target} (${mount_type})."
}

verify_sha256_sidecar() {
  local artifact="$1"
  local sidecar="${artifact}.sha256"
  [[ -f "${artifact}" && ! -L "${artifact}" ]] || die "Backup artifact must be a regular, non-symlink file: ${artifact}"
  [[ -f "${sidecar}" && ! -L "${sidecar}" ]] || die "Required SHA-256 sidecar is missing or unsafe: ${sidecar}"
  local line_count expected actual
  line_count="$(awk 'END { print NR + 0 }' "${sidecar}")"
  [[ "${line_count}" == 1 ]] || die "SHA-256 sidecar must contain exactly one record: ${sidecar}"
  expected="$(awk 'NR == 1 { print $1 }' "${sidecar}")"
  [[ "${expected}" =~ ^[[:xdigit:]]{64}$ ]] || die "Malformed SHA-256 value in ${sidecar}"
  expected="$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')"
  actual="$(sha256sum "${artifact}" | awk '{ print $1 }')"
  [[ "${actual}" == "${expected}" ]] || die "SHA-256 mismatch for ${artifact}"
}

verify_sqlite_backup() {
  local database="$1"
  require_command sqlite3
  case "${database}" in
    *'?'*|*'#'*|*'%'*) die "SQLite verification path contains URI-reserved characters: ${database}" ;;
  esac
  local database_uri="file:${database}?immutable=1"
  local integrity foreign_keys schema_version table_count
  integrity="$(sqlite3 -readonly "${database_uri}" 'PRAGMA integrity_check;' 2>/dev/null || true)"
  [[ "${integrity}" == ok ]] || die "SQLite integrity check failed for ${database}: ${integrity:-no result}"
  foreign_keys="$(sqlite3 -readonly "${database_uri}" 'PRAGMA foreign_key_check;' 2>/dev/null || true)"
  [[ -z "${foreign_keys}" ]] || die "SQLite foreign-key check failed for ${database}: ${foreign_keys}"
  schema_version="$(sqlite3 -readonly "${database_uri}" 'SELECT COALESCE(MAX(version),0) FROM schema_migrations;' 2>/dev/null || true)"
  case "${schema_version}" in
    1|2|3) ;;
    *) die "Expected a supported PPSV schema version (1, 2, or 3) in ${database}; found ${schema_version:-none}." ;;
  esac
  table_count="$(sqlite3 -readonly "${database_uri}" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('users','service_modules','requests','protein_submissions','inquiries','request_files','status_history','mail_outbox','mail_attempts');" 2>/dev/null || true)"
  [[ "${table_count}" == 9 ]] || die "Required PPSV tables are missing from ${database}."
}

verify_fallback_archive() {
  local archive="$1"
  require_command tar
  [[ -f "${archive}" && ! -L "${archive}" ]] || die "Fallback backup must be a regular, non-symlink file: ${archive}"
  local listing entry
  listing="$(tar --list --gzip --file "${archive}")" || die "Fallback archive cannot be listed: ${archive}"
  while IFS= read -r entry; do
    case "${entry}" in
      /*|../*|./../*|*/../*|*/..) die "Unsafe path in fallback archive: ${entry}" ;;
    esac
  done <<<"${listing}"
  if ! tar --list --verbose --gzip --file "${archive}" | awk 'substr($1, 1, 1) != "d" && substr($1, 1, 1) != "-" { exit 1 }'; then
    die "Fallback archive contains a symbolic link, hard link, or special file: ${archive}"
  fi
}

run_as_app() {
  if [[ $(id -un) == "${APP_RUN_USER}" ]]; then
    "$@"
  elif [[ ${EUID} -eq 0 ]]; then
    runuser -u "${APP_RUN_USER}" -- "$@"
  else
    die "This command must run as ${APP_RUN_USER} or root."
  fi
}

acquire_lock() {
  local lock_file="$1"
  local lock_fd="${2:-9}"
  require_command flock
  local lock_dir lock_dir_owner lock_dir_mode lock_dir_mode_value lock_owner
  lock_dir="$(dirname "${lock_file}")"
  [[ -d "${lock_dir}" && ! -L "${lock_dir}" ]] || die "Lock directory is missing or unsafe: ${lock_dir}"
  lock_dir_owner="$(stat -c '%u' "${lock_dir}")"
  lock_dir_mode="$(stat -c '%a' "${lock_dir}")"
  lock_dir_mode_value=$((8#${lock_dir_mode}))

  if [[ ${EUID} -eq 0 ]]; then
    [[ "${lock_dir_owner}" == 0 ]] || die "Root refuses a lock directory not owned by root: ${lock_dir}"
    if (( (lock_dir_mode_value & 8#0022) != 0 && (lock_dir_mode_value & 8#1000) == 0 )); then
      die "Root refuses a group/other-writable non-sticky lock directory: ${lock_dir}"
    fi
  elif [[ "${lock_dir_owner}" == 0 ]] && (( (lock_dir_mode_value & 8#0022) != 0 && (lock_dir_mode_value & 8#1000) == 0 )); then
    die "Refusing a replaceable lock in a group/other-writable root directory: ${lock_dir}"
  fi

  if [[ ! -e "${lock_file}" ]]; then
    # noclobber requests an atomic create and refuses an attacker-provided
    # existing path or symlink. Production app-user locks are precreated by
    # provisioning in a root-owned, non-writable directory.
    (set -o noclobber; : >"${lock_file}") 2>/dev/null || die "Lock file must be safely precreated: ${lock_file}"
  fi
  [[ -f "${lock_file}" && ! -L "${lock_file}" ]] || die "Lock file is not a regular, non-symlink file: ${lock_file}"
  lock_owner="$(stat -c '%u' "${lock_file}")"
  if [[ "${lock_dir_owner}" == 0 ]]; then
    [[ "${lock_owner}" == 0 ]] || die "Lock file in a root-owned directory must be owned by root: ${lock_file}"
  fi
  [[ -w "${lock_file}" ]] || die "Lock file is not writable by $(id -un): ${lock_file}"
  case "${lock_fd}" in
    8) exec 8>>"${lock_file}" ;;
    9) exec 9>>"${lock_file}" ;;
    *) die "Internal error: unsupported lock descriptor ${lock_fd}." ;;
  esac
  flock -n "${lock_fd}" || die "Another PPSV operation holds ${lock_file}."
}

atomic_symlink() {
  local target="$1"
  local link="$2"
  local temporary="${link}.new.$$"
  ln -s "${target}" "${temporary}"
  mv -Tf "${temporary}" "${link}"
}
