#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${PPSV_ENV_FILE:-/etc/ppsv-app/ppsv-app.env}"
RELEASE_ID=""

usage() {
  cat <<'USAGE'
Usage: rollback.sh --release ID [--env FILE]

Atomically rolls application code back to an existing immutable release.
This does not reverse database migrations or remove later requests. Use
restore_backup.sh separately only when intentional data loss is acceptable.
USAGE
}

while (($#)); do
  case "$1" in
    --release)
      [[ $# -ge 2 ]] || die "--release needs an identifier"
      RELEASE_ID="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env needs a file"
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
[[ "${RELEASE_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "A safe --release ID is required."
load_runtime_env "${ENV_FILE}"
validate_runtime_paths
acquire_lock "/run/lock/ppsv-deploy.lock" 8
acquire_lock "${PPSV_DATA_ROOT}/locks/maintenance.lock" 9

target="${PPSV_RELEASES_ROOT}/${RELEASE_ID}/ppsv-app"
[[ -f "${target}/app.R" && -f "${target}/renv.lock" ]] || die "Release is incomplete or absent: ${target}"
release_root="$(dirname "${target}")"
[[ -f "${release_root}/MANIFEST.sha256" ]] || die "Release manifest is missing: ${release_root}/MANIFEST.sha256"
(
  cd "${release_root}"
  sha256sum --check --strict MANIFEST.sha256
) || die "Release ${RELEASE_ID} failed its immutable-file checksum verification."
(
  cd "${target}"
  sha256sum --check --strict renv.lock.sha256
) || die "Release ${RELEASE_ID} has an unreviewed or modified dependency lock."
current="$(readlink -f "${PPSV_CURRENT_LINK}" 2>/dev/null || true)"
[[ "${current}" != "$(readlink -f "${target}")" ]] || die "Release ${RELEASE_ID} is already active."

shiny_was_active=0
mail_timer_was_active=0
services_quiesced=0
rollback_activated=0
cleanup_rollback() {
  local status=$?
  trap - EXIT
  if [[ ${status} -ne 0 && ${rollback_activated:-0} -eq 1 ]]; then
    systemctl stop shiny-server.service 2>/dev/null || true
    if [[ -n "${current}" && -d "${current}" ]]; then
      atomic_symlink "${current}" "${PPSV_CURRENT_LINK}" || true
    else
      rm -f -- "${PPSV_CURRENT_LINK}"
    fi
  fi
  if [[ ${status} -ne 0 && ${services_quiesced:-0} -eq 1 ]]; then
    if [[ ${shiny_was_active:-0} -eq 1 && -e "${PPSV_CURRENT_LINK}" ]]; then
      systemctl start shiny-server.service 2>/dev/null || true
    else
      systemctl stop shiny-server.service 2>/dev/null || true
    fi
    if [[ ${mail_timer_was_active:-0} -eq 1 ]]; then
      systemctl start ppsv-mail-outbox.timer 2>/dev/null || true
    else
      systemctl stop ppsv-mail-outbox.timer 2>/dev/null || true
    fi
  fi
  exit "${status}"
}
trap cleanup_rollback EXIT

systemctl is-active --quiet shiny-server.service && shiny_was_active=1
systemctl is-active --quiet ppsv-mail-outbox.timer && mail_timer_was_active=1
services_quiesced=1
systemctl stop ppsv-mail-outbox.timer ppsv-mail-outbox.service 2>/dev/null || true
systemctl stop shiny-server.service
atomic_symlink "${target}" "${PPSV_CURRENT_LINK}"
rollback_activated=1
systemctl start shiny-server.service

healthy=0
for _ in {1..30}; do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 http://127.0.0.1:3838/ppsv-app/ || true)"
  if [[ "${status}" =~ ^(2|3)[0-9][0-9]$ ]]; then healthy=1; break; fi
  sleep 1
done

if ((healthy == 0)); then
  die "Rollback target failed health check; previous code link was restored."
fi

systemctl start ppsv-mail-outbox.timer
services_quiesced=0
trap - EXIT
log "Code rolled back to ${RELEASE_ID}. Database state was not changed."
