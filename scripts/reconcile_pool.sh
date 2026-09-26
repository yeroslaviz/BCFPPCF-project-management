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

umask 0007
acquire_lock "${PPSV_DATA_ROOT}/locks/maintenance.lock"
validate_pool_destination

[[ -d "${PPSV_POOL_ROOT}" && ! -L "${PPSV_POOL_ROOT}" && -w "${PPSV_POOL_ROOT}" ]] || die "Primary pool is unavailable, unsafe, or not writable: ${PPSV_POOL_ROOT}"
[[ -d "${PPSV_FALLBACK_ROOT}" && ! -L "${PPSV_FALLBACK_ROOT}" && -r "${PPSV_FALLBACK_ROOT}" ]] || die "Fallback directory is unavailable, unsafe, or not readable: ${PPSV_FALLBACK_ROOT}"

APP_DIR="$(validate_active_app_dir)"
[[ -n "${APP_DIR}" && -f "${APP_DIR}/R/load_backend.R" ]] || die "Backend loader is missing from the active release."

cd "${APP_DIR}"
log "Reconciling fallback uploads. Files are checksum-verified before database paths change."
run_as_app Rscript -e 'source("R/load_backend.R"); ppsv_initialize(); print(ppsv_reconcile_storage())'
