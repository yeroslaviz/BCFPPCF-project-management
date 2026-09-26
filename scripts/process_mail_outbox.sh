#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
load_runtime_env "${PPSV_ENV_FILE:-/etc/ppsvf-app/ppsvf-app.env}"
validate_runtime_paths

if [[ "$(id -un)" != "${APP_RUN_USER}" ]]; then
  reexec_as_app "${BASH_SOURCE[0]}"
fi

umask 0007
acquire_lock "${PPSV_DATA_ROOT}/locks/mail-outbox.lock"

APP_DIR="$(validate_active_app_dir)"
[[ -n "${APP_DIR}" && -f "${APP_DIR}/process_mail_outbox.R" ]] || die "Mail worker is missing from the active release."

cd "${APP_DIR}"
log "Processing due mail-outbox records."
run_as_app Rscript process_mail_outbox.R
