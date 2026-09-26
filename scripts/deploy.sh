#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

SOURCE_ROOT="${PPSV_REPO_ROOT_DEFAULT}"
ENV_FILE="${PPSV_ENV_FILE:-/etc/ppsvf-app/ppsvf-app.env}"
RELEASE_ID=""

usage() {
  cat <<'USAGE'
Usage: deploy.sh [--source REPOSITORY] [--env FILE] [--release ID]

Builds an immutable staged release, restores ppsvf-app/renv.lock, creates a
verified pre-deployment backup, runs database migrations with Shiny stopped,
then atomically changes /srv/shiny-server/ppsvf-app. A failed health check
automatically returns the code symlink to the previous release.
USAGE
}

while (($#)); do
  case "$1" in
    --source)
      [[ $# -ge 2 ]] || die "--source needs a repository path"
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env needs a file"
      ENV_FILE="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || die "--release needs an identifier"
      RELEASE_ID="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
load_runtime_env "${ENV_FILE}"
validate_runtime_paths
acquire_lock "/run/lock/ppsv-deploy.lock" 8

SOURCE_ROOT="$(cd "${SOURCE_ROOT}" && pwd)"
SOURCE_APP="${SOURCE_ROOT}/ppsvf-app"
[[ -f "${SOURCE_APP}/app.R" ]] || die "Application entrypoint missing: ${SOURCE_APP}/app.R"
[[ -f "${SOURCE_APP}/renv.lock" ]] || die "Pinned dependency lock missing: ${SOURCE_APP}/renv.lock"
[[ -f "${SOURCE_APP}/renv.lock.sha256" ]] || die "Reviewed lock checksum missing: ${SOURCE_APP}/renv.lock.sha256"
[[ -f "${SOURCE_APP}/setup_database.R" ]] || die "Database initializer missing: ${SOURCE_APP}/setup_database.R"
[[ -f "${SOURCE_APP}/process_mail_outbox.R" ]] || die "Mail worker missing: ${SOURCE_APP}/process_mail_outbox.R"
[[ "${PPSV_RESET_DB:-0}" != 1 ]] || die "PPSV_RESET_DB=1 is forbidden during deployment."

(
  cd "${SOURCE_APP}"
  sha256sum --check --strict renv.lock.sha256
) || die "renv.lock does not match its reviewed SHA-256 sidecar."

getent passwd "${APP_RUN_USER}" >/dev/null || die "Runtime account does not exist: ${APP_RUN_USER}"
[[ "$(id -gn "${APP_RUN_USER}")" == "${APP_RUN_GROUP}" ]] || die "Runtime account does not use private primary group ${APP_RUN_GROUP}."
validate_pool_destination
runuser -u "${APP_RUN_USER}" -- test -w "${PPSV_POOL_ROOT}" || die "Runtime account cannot write the project pool."
runuser -u "${APP_RUN_USER}" -- test -w "${PPSV_FALLBACK_ROOT}" || die "Runtime account cannot write fallback storage."

if git -C "${SOURCE_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_revision="$(git -C "${SOURCE_ROOT}" rev-parse --short=12 HEAD)"
  if [[ -n "$(git -C "${SOURCE_ROOT}" status --porcelain --untracked-files=normal)" && "${PPSV_ALLOW_DIRTY_RELEASE:-0}" != 1 ]]; then
    die "Source repository has tracked or untracked changes. Commit the release, or explicitly set PPSV_ALLOW_DIRTY_RELEASE=1 for a non-production test."
  fi
else
  git_revision="unversioned"
  [[ "${PPSV_ALLOW_DIRTY_RELEASE:-0}" == 1 ]] || die "Source is not a Git worktree; production releases must be traceable."
fi

if [[ -z "${RELEASE_ID}" ]]; then
  RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-${git_revision}"
fi
[[ "${RELEASE_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Release ID contains unsafe characters: ${RELEASE_ID}"

RELEASE_ROOT="${PPSV_RELEASES_ROOT}/${RELEASE_ID}"
STAGING_ROOT="${PPSV_RELEASES_ROOT}/.${RELEASE_ID}.staging.$$"
[[ ! -e "${RELEASE_ROOT}" && ! -e "${STAGING_ROOT}" ]] || die "Release already exists: ${RELEASE_ID}"

previous_target="$(readlink -f "${PPSV_CURRENT_LINK}" 2>/dev/null || true)"
services_quiesced=0
shiny_was_active=0
mail_timer_was_active=0
release_activated=0
record_tmp=""
cleanup_deploy() {
  local status=$?
  trap - EXIT
  if [[ ${status} -ne 0 && ${release_activated:-0} -eq 1 ]]; then
    warn "Deployment stopped after activation; restoring the previous code link."
    systemctl stop shiny-server.service 2>/dev/null || true
    if [[ -n "${previous_target}" && -d "${previous_target}" ]]; then
      atomic_symlink "${previous_target}" "${PPSV_CURRENT_LINK}" || warn "Could not restore the previous application link."
    else
      rm -f -- "${PPSV_CURRENT_LINK}" || warn "Could not remove the failed application link."
    fi
    release_activated=0
  fi
  if [[ -d "${STAGING_ROOT}" ]]; then
    rm -rf -- "${STAGING_ROOT}"
  fi
  if [[ -n "${record_tmp:-}" && -f "${record_tmp}" ]]; then
    rm -f -- "${record_tmp}"
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
trap cleanup_deploy EXIT

install -d -o "${APP_RUN_USER}" -g "${APP_RUN_GROUP}" -m 0750 "${STAGING_ROOT}/ppsvf-app"
rsync -a --delete \
  --exclude '.Renviron' \
  --exclude '.Rproj.user/' \
  --exclude 'renv/library/' \
  --exclude '*.db' \
  --exclude '*.sqlite*' \
  --exclude 'uploads_pending_pool/' \
  "${SOURCE_APP}/" "${STAGING_ROOT}/ppsvf-app/"

(
  cd "${STAGING_ROOT}/ppsvf-app"
  sha256sum --check --strict renv.lock.sha256
) || die "Staged renv.lock checksum differs from the reviewed source."

if find "${STAGING_ROOT}" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '.Renviron' \) -print -quit | grep -q .; then
  die "Staged release contains mutable database or environment files."
fi

chown -R "${APP_RUN_USER}:${APP_RUN_GROUP}" "${STAGING_ROOT}"
find "${STAGING_ROOT}" -type d -exec chmod 0750 {} +
find "${STAGING_ROOT}" -type f -exec chmod 0640 {} +

log "Restoring locked R dependencies into staged release ${RELEASE_ID}."
(
  cd "${STAGING_ROOT}/ppsvf-app"
  runuser -u "${APP_RUN_USER}" -- env \
    RENV_PROJECT="${STAGING_ROOT}/ppsvf-app" \
    RENV_PATHS_CACHE="${RENV_PATHS_CACHE}" \
    RENV_CONFIG_CACHE_SYMLINKS=false \
    Rscript -e '
      stopifnot(requireNamespace("renv", quietly = TRUE))
      renv::restore(project = getwd(), prompt = FALSE)
      required <- c("DBI", "digest", "DT", "mailR", "png", "rJava", "RSQLite", "shiny")
      missing <- required[!vapply(required, requireNamespace, logical(1L), quietly = TRUE)]
      if (length(missing)) stop("Restored library is missing: ", paste(missing, collapse = ", "))
      rJava::.jinit()
    '
)

"${SCRIPT_DIR}/check_requirements.sh" \
  --repo "${STAGING_ROOT}" \
  --runtime-project "${STAGING_ROOT}/ppsvf-app" \
  --env "${ENV_FILE}"

if [[ -f "${PPSV_DB_FILE}" ]]; then
  log "Creating verified pre-deployment database and fallback backup."
  PPSV_ENV_FILE="${ENV_FILE}" /usr/local/libexec/ppsvf-app/backup.sh
fi

# Prevent a reconciliation, restore, or scheduled backup from crossing the
# service stop and migration/activation boundary. Descriptor 8 continues to
# serialize deploy/rollback while descriptor 9 owns the maintenance lock.
acquire_lock "${PPSV_DATA_ROOT}/locks/maintenance.lock" 9

systemctl is-active --quiet shiny-server.service && shiny_was_active=1
systemctl is-active --quiet ppsv-mail-outbox.timer && mail_timer_was_active=1
services_quiesced=1
systemctl stop ppsv-mail-outbox.timer ppsv-mail-outbox.service 2>/dev/null || true
systemctl stop shiny-server.service

log "Applying transactional database migrations."
(
  cd "${STAGING_ROOT}/ppsvf-app"
  runuser -u "${APP_RUN_USER}" -- env PPSV_RESET_DB=0 RENV_PATHS_CACHE="${RENV_PATHS_CACHE}" Rscript setup_database.R
)
[[ -f "${PPSV_DB_FILE}" ]] || die "Database initializer did not create ${PPSV_DB_FILE}."
chown "${APP_RUN_USER}:${APP_RUN_GROUP}" "${PPSV_DB_FILE}"
chmod 0660 "${PPSV_DB_FILE}"

printf '%s\n' "${git_revision}" >"${STAGING_ROOT}/REVISION"
(
  cd "${STAGING_ROOT}"
  find ppsvf-app -type f -print0 | sort -z | xargs -0 sha256sum >MANIFEST.sha256
)
chown -R root:"${APP_RUN_GROUP}" "${STAGING_ROOT}"
find "${STAGING_ROOT}" -type d -exec chmod 0750 {} +
find "${STAGING_ROOT}" -type f -exec chmod 0640 {} +
mv "${STAGING_ROOT}" "${RELEASE_ROOT}"
atomic_symlink "${RELEASE_ROOT}/ppsvf-app" "${PPSV_CURRENT_LINK}"
release_activated=1

systemctl start shiny-server.service

healthy=0
for _ in {1..30}; do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 http://127.0.0.1:3838/ppsvf-app/ || true)"
  if [[ "${status}" =~ ^(2|3)[0-9][0-9]$ ]]; then
    healthy=1
    break
  fi
  sleep 1
done

if ((healthy == 0)); then
  die "Release ${RELEASE_ID} was not activated. Database migrations are retained; use restore_backup.sh only after assessing post-migration writes."
fi

record_dir="${PPSV_DATA_ROOT}/deployments"
[[ -d "${record_dir}" && ! -L "${record_dir}" ]] || die "Protected deployment-record directory is missing: ${record_dir}"
[[ "$(stat -c '%U:%G' "${record_dir}")" == "root:${APP_RUN_GROUP}" && "$(stat -c '%a' "${record_dir}")" == 750 ]] || die "Deployment-record directory must be root:${APP_RUN_GROUP} mode 0750."
record="${record_dir}/${RELEASE_ID}.env"
[[ ! -e "${record}" ]] || die "Deployment record already exists: ${record}"
record_tmp="$(mktemp "${record_dir}/.${RELEASE_ID}.XXXXXX")"
{
  printf 'RELEASE_ID=%q\n' "${RELEASE_ID}"
  printf 'GIT_REVISION=%q\n' "${git_revision}"
  printf 'DEPLOYED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'PREVIOUS_TARGET=%q\n' "${previous_target}"
} >"${record_tmp}"
chown root:"${APP_RUN_GROUP}" "${record_tmp}"
chmod 0640 "${record_tmp}"
mv -T "${record_tmp}" "${record}"
record_tmp=""

systemctl start ppsv-mail-outbox.timer ppsv-backup.timer
PPSV_ENV_FILE="${ENV_FILE}" "${SCRIPT_DIR}/verify_deployment.sh" --skip-public

services_quiesced=0
trap - EXIT
log "Release ${RELEASE_ID} is active at ${PPSV_CURRENT_LINK}."
