#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${PPSV_ENV_FILE:-/etc/ppsvf-app/ppsvf-app.env}"
SKIP_PUBLIC=0
NETRC_FILE=""
ROLE_USER=""
ROLE_TECHNICIAN="grzejszc"
ROLE_ADMIN="yeroslaviz"

usage() {
  cat <<'USAGE'
Usage: verify_deployment.sh [--env FILE] [--skip-public] [--netrc FILE]
                            [--role-user USER] [--role-technician USER]
                            [--role-admin USER]

Runs local service, ownership, database, ACL, configuration, and timer checks.
Public checks use normal CA verification (never curl -k). If --netrc points to
a mode-0600 curl netrc containing an LDAP test account, the authenticated
route, forged-header replacement, and WebSocket upgrade are checked as well.

Role checks always verify the configured technician and administrator. Supply
an ordinary LDAP username with --role-user to complete the three-role proof.
USAGE
}

while (($#)); do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env needs a file"
      ENV_FILE="$2"
      shift 2
      ;;
    --skip-public) SKIP_PUBLIC=1; shift ;;
    --netrc)
      [[ $# -ge 2 ]] || die "--netrc needs a file"
      NETRC_FILE="$2"
      shift 2
      ;;
    --role-user)
      [[ $# -ge 2 ]] || die "--role-user needs a username"
      ROLE_USER="$2"
      shift 2
      ;;
    --role-technician)
      [[ $# -ge 2 ]] || die "--role-technician needs a username"
      ROLE_TECHNICIAN="$2"
      shift 2
      ;;
    --role-admin)
      [[ $# -ge 2 ]] || die "--role-admin needs a username"
      ROLE_ADMIN="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
load_runtime_env "${ENV_FILE}"
validate_runtime_paths
require_command curl
require_command ss
require_command sqlite3
require_command getfacl
require_command sha256sum

failures=0
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; failures=$((failures + 1)); }

[[ "${AUTH_MODE:-}" == ldap ]] && pass "AUTH_MODE is ldap" || fail "AUTH_MODE must be ldap"
runtime_primary_group="$(id -gn "${APP_RUN_USER}" 2>/dev/null || true)"
[[ "${runtime_primary_group}" == "${APP_RUN_GROUP}" && "${APP_RUN_GROUP}" == "${PPSV_POOL_GROUP}" ]] && pass "runtime account uses shared group ${APP_RUN_GROUP}" || fail "runtime primary group is ${runtime_primary_group:-missing}, expected ${APP_RUN_GROUP}; APP_RUN_GROUP/PPSV_POOL_GROUP are ${APP_RUN_GROUP}/${PPSV_POOL_GROUP}"
[[ "${PPSV_TICKET_MODE:-disabled}" != disabled ]] && pass "ticket delivery is enabled in ${PPSV_TICKET_MODE} mode" || fail "ticket delivery is disabled"
[[ "${PPSV_MAIL_FROM:-}" == ppsv-service@biochem.mpg.de ]] && pass "SMTP service identity is ppsv-service@biochem.mpg.de" || fail "PPSV_MAIL_FROM is not the approved service identity"
[[ "${PPSV_TICKET_TO:-}" == ppsv-request@biochem.mpg.de ]] && pass "ticket recipient is ppsv-request@biochem.mpg.de" || fail "PPSV_TICKET_TO is not the PPSV request address"
[[ "${PPSV_SERVICE_IDENTITY_AUTHORIZED_ACK}" == 1 ]] && pass "service mail identity authorization is acknowledged" || fail "service mail identity authorization is not acknowledged"
[[ "${PPSV_TICKET_E2E_TEST_ACK}" == 1 ]] && pass "ticket requester/auto-reply end-to-end test is acknowledged" || fail "ticket requester/auto-reply end-to-end test is not acknowledged"

env_mode="$(stat -c '%a' "${ENV_FILE}")"
env_owner="$(stat -c '%U:%G' "${ENV_FILE}")"
env_mode_value=$((8#${env_mode}))
if [[ "${env_owner}" == "root:root" ]] && (( (env_mode_value & 8#0077) == 0 )); then
  pass "runtime environment is root:root mode ${env_mode} (0600 or stricter)"
else
  fail "runtime environment is ${env_owner} mode ${env_mode}, expected root:root and mode 0600 or stricter"
fi

check_protected_dir() {
  local path="$1"
  local expected_mode="$2"
  local label="$3"
  local actual_mode actual_owner
  actual_mode="$(stat -c '%a' "${path}" 2>/dev/null || true)"
  actual_owner="$(stat -c '%U:%G' "${path}" 2>/dev/null || true)"
  if [[ -d "${path}" && ! -L "${path}" && "${actual_mode}" == "${expected_mode}" && "${actual_owner}" == "root:${APP_RUN_GROUP}" ]]; then
    pass "${label} is protected as root:${APP_RUN_GROUP} mode ${expected_mode}"
  else
    fail "${label} is ${actual_owner:-missing} mode ${actual_mode:-missing} (or symbolic), expected root:${APP_RUN_GROUP} ${expected_mode}"
  fi
}

check_protected_dir "${PPSV_DATA_ROOT}" 1770 "persistent data root"
check_protected_dir "${PPSV_DATA_ROOT}/deployments" 750 "deployment-record directory"
check_protected_dir "${PPSV_RELEASES_ROOT}" 750 "immutable releases root"
check_protected_dir "$(dirname "${PPSV_CURRENT_LINK}")" 750 "active-link parent"

lock_dir_mode="$(stat -c '%a' "${PPSV_DATA_ROOT}/locks" 2>/dev/null || true)"
lock_dir_owner="$(stat -c '%U:%G' "${PPSV_DATA_ROOT}/locks" 2>/dev/null || true)"
[[ "${lock_dir_mode}" == 750 && "${lock_dir_owner}" == "root:${APP_RUN_GROUP}" ]] && pass "maintenance lock directory is protected from runtime-user replacement" || fail "lock directory is ${lock_dir_owner:-missing} mode ${lock_dir_mode:-missing}, expected root:${APP_RUN_GROUP} 750"
for lock_name in maintenance.lock mail-outbox.lock; do
  lock_path="${PPSV_DATA_ROOT}/locks/${lock_name}"
  lock_mode="$(stat -c '%a' "${lock_path}" 2>/dev/null || true)"
  lock_owner="$(stat -c '%U:%G' "${lock_path}" 2>/dev/null || true)"
  [[ "${lock_mode}" == 660 && "${lock_owner}" == "root:${APP_RUN_GROUP}" && ! -L "${lock_path}" ]] && pass "${lock_name} is root-owned and app-group writable" || fail "${lock_name} is ${lock_owner:-missing} mode ${lock_mode:-missing}, expected root:${APP_RUN_GROUP} 660"
done
recovery_parent_mode="$(stat -c '%a' "${PPSV_DATA_ROOT}/pre_restore" 2>/dev/null || true)"
recovery_parent_owner="$(stat -c '%U:%G' "${PPSV_DATA_ROOT}/pre_restore" 2>/dev/null || true)"
[[ "${recovery_parent_mode}" == 750 && "${recovery_parent_owner}" == "root:${APP_RUN_GROUP}" && ! -L "${PPSV_DATA_ROOT}/pre_restore" ]] && pass "pre-restore recovery directory is protected" || fail "pre-restore directory is ${recovery_parent_owner:-missing} mode ${recovery_parent_mode:-missing}, expected root:${APP_RUN_GROUP} 750"

active_app="$(readlink -f "${PPSV_CURRENT_LINK}" 2>/dev/null || true)"
case "${active_app}" in
  "${PPSV_RELEASES_ROOT}"/*/ppsvf-app) pass "active application points into immutable releases" ;;
  *) fail "active application link is missing or outside ${PPSV_RELEASES_ROOT}: ${active_app:-<none>}" ;;
esac

if [[ -n "${active_app}" && -f "${active_app}/app.R" && -f "${active_app}/renv.lock" ]]; then
  pass "active release contains app.R and renv.lock"
else
  fail "active release is incomplete"
fi

if [[ -n "${active_app}" ]] && find "${active_app}" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '.Renviron' \) -print -quit | grep -q .; then
  fail "active release contains mutable database/environment state"
else
  pass "active release contains no database or .Renviron"
fi
if [[ -n "${active_app}" ]] && find "${active_app}" ! -user root -print -quit | grep -q .; then
  fail "active release contains content not owned by root"
else
  pass "active release content is root-owned"
fi
if [[ -n "${active_app}" ]] && find "${active_app}" -perm /0022 -print -quit | grep -q .; then
  fail "active release contains group/other-writable content"
else
  pass "active release is not group/other-writable"
fi
release_root="$(dirname "${active_app}")"
check_protected_dir "${release_root}" 750 "active release root"
if [[ -f "${release_root}/MANIFEST.sha256" ]] && (cd "${release_root}" && sha256sum --check --quiet MANIFEST.sha256); then
  pass "active release matches its SHA-256 manifest"
else
  fail "active release manifest is missing or does not verify"
fi
if [[ -f "${active_app}/renv.lock.sha256" ]] && (cd "${active_app}" && sha256sum --check --strict renv.lock.sha256 >/dev/null); then
  pass "active dependency lock matches its reviewed SHA-256"
else
  fail "active dependency lock checksum is missing or invalid"
fi

systemctl is-active --quiet shiny-server.service && pass "Shiny Server is active" || fail "Shiny Server is not active"
if ss -ltnH | awk '$4 ~ /^(127\.0\.0\.1|\[::1\]):3838$/ {found=1} END {exit !found}'; then
  pass "Shiny Server listens on loopback port 3838"
else
  fail "no loopback listener found on port 3838"
fi
if ss -ltnH | awk '$4 ~ /^(0\.0\.0\.0|\[::\]|\*):3838$/ {found=1} END {exit !found}'; then
  fail "port 3838 is exposed on a wildcard address"
else
  pass "port 3838 is not exposed on a wildcard address"
fi

local_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 http://127.0.0.1:3838/ppsvf-app/ || true)"
[[ "${local_status}" =~ ^(2|3)[0-9][0-9]$ ]] && pass "loopback application returned ${local_status}" || fail "loopback application returned ${local_status:-no response}"

if ps -eo user=,args= | awk -v user="${APP_RUN_USER}" '$1 == user && /[Rr].*ppsvf-app/ {found=1} END {exit !found}'; then
  pass "application R worker runs as ${APP_RUN_USER}"
else
  fail "no PPSV R worker owned by ${APP_RUN_USER} was observed"
fi
grep -Eq "^[[:space:]]*run_as[[:space:]]+${APP_RUN_USER};" /etc/shiny-server/shiny-server.conf && pass "Shiny Server run_as is ${APP_RUN_USER}" || fail "Shiny Server run_as is not ${APP_RUN_USER}"
grep -Eq '^[[:space:]]*listen[[:space:]]+3838[[:space:]]+127\.0\.0\.1;' /etc/shiny-server/shiny-server.conf && pass "Shiny Server configuration binds 3838 to IPv4 loopback" || fail "Shiny Server configuration is not loopback-only"

if [[ -f "${PPSV_DB_FILE}" ]]; then
  db_integrity="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" 'PRAGMA integrity_check;' 2>/dev/null || true)"
  [[ "${db_integrity}" == ok ]] && pass "SQLite integrity check returned ok" || fail "SQLite integrity check failed: ${db_integrity:-no result}"
  db_foreign_keys="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" 'PRAGMA foreign_key_check;' 2>/dev/null || true)"
  [[ -z "${db_foreign_keys}" ]] && pass "SQLite foreign-key check returned no violations" || fail "SQLite foreign-key violations found: ${db_foreign_keys}"
  schema_version="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" 'SELECT COALESCE(MAX(version),0) FROM schema_migrations;' 2>/dev/null || true)"
  [[ "${schema_version}" == 3 ]] && pass "database schema version is 3" || fail "database schema version is ${schema_version:-unavailable}, expected 3"
  module_count="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" 'SELECT count(*) FROM service_modules WHERE active=1;' 2>/dev/null || true)"
  module_order_count="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" 'SELECT count(DISTINCT display_order) FROM service_modules WHERE active=1 AND display_order BETWEEN 1 AND 8;' 2>/dev/null || true)"
  [[ "${module_count}" == 8 && "${module_order_count}" == 8 ]] && pass "eight active service modules have unique display order 1-8" || fail "service-module seed/order is invalid (${module_count:-?}/${module_order_count:-?})"
  db_mode="$(stat -c '%a' "${PPSV_DB_FILE}")"
  db_owner="$(stat -c '%U:%G' "${PPSV_DB_FILE}")"
  [[ "${db_mode}" == 660 && "${db_owner}" == "${APP_RUN_USER}:${APP_RUN_GROUP}" ]] && pass "database ownership/mode are ${db_owner} ${db_mode}" || fail "database ownership/mode are ${db_owner} ${db_mode}, expected ${APP_RUN_USER}:${APP_RUN_GROUP} 660"
  for sqlite_sidecar in "${PPSV_DB_FILE}-wal" "${PPSV_DB_FILE}-shm"; do
    if [[ -e "${sqlite_sidecar}" ]]; then
      sidecar_mode="$(stat -c '%a' "${sqlite_sidecar}")"
      sidecar_owner="$(stat -c '%U:%G' "${sqlite_sidecar}")"
      [[ "${sidecar_mode}" == 660 && "${sidecar_owner}" == "${APP_RUN_USER}:${APP_RUN_GROUP}" ]] && pass "$(basename "${sqlite_sidecar}") ownership/mode are correct" || fail "$(basename "${sqlite_sidecar}") is ${sidecar_owner} mode ${sidecar_mode}, expected ${APP_RUN_USER}:${APP_RUN_GROUP} 660"
    fi
  done
else
  fail "database file is missing: ${PPSV_DB_FILE}"
fi

expected_statuses='Submitted|Under review|Accepted|In progress|Awaiting requester input|Completed|Closed'
actual_statuses="$(
  cd "${active_app}" 2>/dev/null &&
    runuser -u "${APP_RUN_USER}" -- Rscript -e 'source("R/load_backend.R"); cat(paste(PPSV_STATUS_OPTIONS, collapse="|"))' 2>/dev/null
  )" || actual_statuses=""
[[ "${actual_statuses}" == "${expected_statuses}" ]] && pass "application exposes exactly the seven approved statuses" || fail "application status set/order is unexpected: ${actual_statuses:-unavailable}"

check_role() {
  local username="$1"
  local expected="$2"
  local actual active_count
  [[ "${username}" =~ ^[A-Za-z0-9._-]+$ ]] || { fail "unsafe or empty username supplied for ${expected} role check"; return; }
  actual="$(
    cd "${active_app}" 2>/dev/null &&
      runuser -u "${APP_RUN_USER}" -- Rscript -e 'source("R/load_backend.R"); cat(ppsv_role_for_username(commandArgs(trailingOnly=TRUE)[[1L]]))' "${username}" 2>/dev/null
    )" || actual=""
  active_count="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" "SELECT count(*) FROM users WHERE lower(username)=lower('${username}') AND active=1;" 2>/dev/null || true)"
  if [[ "${actual}" == "${expected}" && "${active_count}" == 1 ]]; then
    pass "${username} derives the ${expected} role and has an active synchronized profile"
  else
    fail "${username} role/profile check failed (derived=${actual:-unavailable}, active rows=${active_count:-unavailable})"
  fi
}

check_role "${ROLE_ADMIN}" admin
check_role "${ROLE_TECHNICIAN}" technician

check_storage_acl() {
  local root="$1"
  local label="$2"
  local expected_group="$3"
  local probe="${root}/.ppsv-verify-$$"
  if runuser -u "${APP_RUN_USER}" -- bash -c 'umask 0007; mkdir "$1"; touch "$1/probe"' bash "${probe}"; then
    local directory_mode file_mode directory_group file_group
    directory_mode="$(stat -c '%a' "${probe}")"
    file_mode="$(stat -c '%a' "${probe}/probe")"
    directory_group="$(stat -c '%G' "${probe}")"
    file_group="$(stat -c '%G' "${probe}/probe")"
    rm -f -- "${probe}/probe"
    rmdir -- "${probe}"
    [[ "${directory_mode}" == 2770 && "${file_mode}" == 660 ]] && pass "${label} creates 2770 directories and 0660 files" || fail "${label} created modes ${directory_mode}/${file_mode}, expected 2770/660"
    [[ "${directory_group}" == "${expected_group}" && "${file_group}" == "${expected_group}" ]] && pass "${label} children inherit group ${expected_group}" || fail "${label} child groups are ${directory_group}/${file_group}, expected ${expected_group}"
  else
    fail "runtime account cannot create files in ${label}: ${root}"
    rm -rf -- "${probe}" 2>/dev/null || true
  fi
}

if validate_pool_destination; then
  if [[ "${PPSV_ALLOW_LOCAL_POOL}" == 0 ]]; then
    pass "project pool and expected facility mount source are valid"
  else
    fail "PPSV_ALLOW_LOCAL_POOL=1 is a test-only override, not a production pool"
  fi
fi

check_storage_acl "${PPSV_POOL_ROOT}" "project pool" "${PPSV_POOL_GROUP}"
check_storage_acl "${PPSV_FALLBACK_ROOT}" "fallback storage" "${APP_RUN_GROUP}"

pool_root_mode="$(stat -c '%a' "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
pool_root_group="$(stat -c '%G' "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
[[ "${pool_root_mode}" == 2770 && "${pool_root_group}" == "${PPSV_POOL_GROUP}" ]] && pass "project pool root is mode 2770 group ${PPSV_POOL_GROUP}" || fail "project pool root is mode ${pool_root_mode:-missing} group ${pool_root_group:-missing}"
fallback_root_mode="$(stat -c '%a' "${PPSV_FALLBACK_ROOT}" 2>/dev/null || true)"
fallback_root_owner="$(stat -c '%U:%G' "${PPSV_FALLBACK_ROOT}" 2>/dev/null || true)"
[[ "${fallback_root_mode}" == 2770 && "${fallback_root_owner}" == "${APP_RUN_USER}:${APP_RUN_GROUP}" ]] && pass "fallback root is runtime-owned mode 2770" || fail "fallback root is ${fallback_root_owner:-missing} mode ${fallback_root_mode:-missing}"

pool_acl="$(getfacl -cp "${PPSV_POOL_ROOT}" 2>/dev/null || true)"
grep -Fqx "user:${APP_RUN_USER}:rwx" <<<"${pool_acl}" && pass "project pool grants the runtime user rwx ACL" || fail "project pool runtime-user ACL is missing"
grep -Fqx "group:${PPSV_POOL_GROUP}:rwx" <<<"${pool_acl}" && pass "project pool grants ${PPSV_POOL_GROUP} rwx ACL" || fail "project pool ${PPSV_POOL_GROUP} ACL is missing"
grep -Fqx "default:user:${APP_RUN_USER}:rwx" <<<"${pool_acl}" && pass "project pool has a default runtime-user ACL" || fail "project pool default runtime-user ACL is missing"
grep -Fqx "default:group:${PPSV_POOL_GROUP}:rwx" <<<"${pool_acl}" && pass "project pool has a default ${PPSV_POOL_GROUP} ACL" || fail "project pool default ${PPSV_POOL_GROUP} ACL is missing"

if validate_backup_destination; then
  if [[ "${PPSV_ALLOW_LOCAL_BACKUP}" == 0 ]]; then
    pass "backup destination and expected external mount source are valid"
  else
    fail "PPSV_ALLOW_LOCAL_BACKUP=1 is a test-only override, not a production backup"
  fi
fi
runuser -u "${APP_RUN_USER}" -- test -w "${PPSV_BACKUP_DIR}" && pass "runtime account can write the backup destination" || fail "runtime account cannot write the backup destination"
[[ "${PPSV_POOL_SNAPSHOT_POLICY_ACK}" == 1 ]] && pass "external project-pool snapshot policy is acknowledged" || fail "external project-pool snapshot policy is not acknowledged (PPSV_POOL_SNAPSHOT_POLICY_ACK=0)"

latest_db_backup="$(find "${PPSV_BACKUP_DIR%/}/database" -maxdepth 1 -type f -name 'ppsv_projects_*.sqlite' -print 2>/dev/null | sort | tail -n 1)"
if [[ -n "${latest_db_backup}" ]]; then
  backup_stamp="$(basename "${latest_db_backup}")"
  backup_stamp="${backup_stamp#ppsv_projects_}"
  backup_stamp="${backup_stamp%.sqlite}"
  latest_fallback_backup="${PPSV_BACKUP_DIR%/}/fallback/uploads_pending_pool_${backup_stamp}.tar.gz"
  [[ -f "${latest_fallback_backup}" ]] || latest_fallback_backup=""
  backup_age_seconds=$(( $(date +%s) - $(stat -c '%Y' "${latest_db_backup}") ))
  ((backup_age_seconds >= -300 && backup_age_seconds <= 129600)) && pass "latest database backup is no more than 36 hours old" || fail "latest database backup timestamp is stale or implausibly in the future"
  restore_verify_args=(--database "${latest_db_backup}")
  if [[ -n "${latest_fallback_backup}" ]]; then
    restore_verify_args+=(--fallback "${latest_fallback_backup}")
  else
    fail "latest database backup has no same-timestamp fallback archive"
  fi
  if PPSV_ENV_FILE="${ENV_FILE}" "${SCRIPT_DIR}/restore_backup.sh" "${restore_verify_args[@]}" >/dev/null; then
    pass "latest backup set passes the operator restore verifier"
  else
    fail "latest backup set failed the operator restore verifier"
  fi
elif ((SKIP_PUBLIC == 0)); then
  fail "no verified database backup exists at the external destination"
else
  warn "No database backup exists yet; run the backup job before production acceptance."
fi

apache2ctl configtest >/dev/null 2>&1 && pass "Apache configuration syntax is valid" || fail "Apache configuration syntax is invalid"
for module in authnz_ldap headers proxy proxy_http proxy_wstunnel rewrite ssl; do
  apache2ctl -M 2>/dev/null | grep -q "${module}_module" && pass "Apache module ${module} is loaded" || fail "Apache module ${module} is missing"
done

grep -Fq 'RequestHeader unset X-Remote-User early' /etc/apache2/sites-enabled/ppsv-vm-shiny-443.conf && pass "client identity header is stripped before proxying" || fail "active vhost does not strip X-Remote-User"
grep -Fq 'RequestHeader set X-Remote-User "expr=%{REMOTE_USER}"' /etc/apache2/sites-enabled/ppsv-vm-shiny-443.conf && pass "proxied username comes from Apache REMOTE_USER" || fail "active vhost does not inject username from REMOTE_USER"
for profile_header in X-Remote-Name X-Remote-Email X-Remote-Group X-Remote-Phone; do
  grep -Fq "RequestHeader unset ${profile_header} early" /etc/apache2/sites-enabled/ppsv-vm-shiny-443.conf || fail "active vhost does not strip ${profile_header}"
done
grep -Fq '127.0.0.1:3838' /etc/apache2/sites-enabled/ppsv-vm-shiny-443.conf && pass "Apache proxies only to loopback" || fail "active vhost proxy target is unexpected"

systemctl is-enabled --quiet ppsv-mail-outbox.timer && pass "mail-outbox timer is enabled" || fail "mail-outbox timer is not enabled"
systemctl is-enabled --quiet ppsv-backup.timer && pass "backup timer is enabled" || fail "backup timer is not enabled"
systemctl is-active --quiet ppsv-mail-outbox.timer && pass "mail-outbox timer is active" || fail "mail-outbox timer is not active"
systemctl is-active --quiet ppsv-backup.timer && pass "backup timer is active" || fail "backup timer is not active"

if ((SKIP_PUBLIC == 0)); then
  [[ "${PPSV_PUBLIC_URL}" == 'https://ppcf-vm.biochem.mpg.de/ppsvf-app/' ]] && pass "public URL is the canonical PPSV endpoint" || fail "PPSV_PUBLIC_URL is not the canonical endpoint: ${PPSV_PUBLIC_URL}"
  http_headers="$(curl --silent --show-error --head --max-time 15 http://ppcf-vm.biochem.mpg.de/ || true)"
  if grep -Eq '^HTTP/[^ ]+ (301|308)' <<<"${http_headers}" && grep -Eiq '^location: https://ppcf-vm\.biochem\.mpg\.de/' <<<"${http_headers}"; then
    pass "HTTP redirects to the canonical HTTPS host"
  else
    fail "canonical HTTP-to-HTTPS redirect was not observed"
  fi

  https_root_headers="$(curl --silent --show-error --head --max-time 15 https://ppcf-vm.biochem.mpg.de/ || true)"
  if grep -Eq '^HTTP/[^ ]+ 30[1278]' <<<"${https_root_headers}" && grep -Eiq '^location: (/ppsvf-app/|https://ppcf-vm\.biochem\.mpg\.de/ppsvf-app/)' <<<"${https_root_headers}"; then
    pass "HTTPS root redirects to /ppsvf-app/ with trusted CA and hostname validation"
  else
    fail "HTTPS root did not produce the canonical /ppsvf-app/ redirect"
  fi

  unauth_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 15 -H 'X-Remote-User: forged-admin' https://ppcf-vm.biochem.mpg.de/ppsvf-app/ || true)"
  [[ "${unauth_status}" == 401 ]] && pass "forged identity header without LDAP credentials is rejected" || fail "forged unauthenticated request returned ${unauth_status:-no response}, expected 401"

  unauth_websocket_status="$(curl --http1.1 --silent --output /dev/null --write-out '%{http_code}' --max-time 8 \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: cHBzdi11bmF1dGgtdGVzdA==' \
    -H 'Sec-WebSocket-Protocol: shiny' \
    -H 'Origin: https://ppcf-vm.biochem.mpg.de' \
    -H 'X-Remote-User: forged-admin' \
    https://ppcf-vm.biochem.mpg.de/ppsvf-app/websocket/ || true)"
  [[ "${unauth_websocket_status}" == 401 ]] && pass "unauthenticated WebSocket upgrade is rejected by LDAP" || fail "unauthenticated WebSocket upgrade returned ${unauth_websocket_status:-no response}, expected 401"

  if [[ -n "${NETRC_FILE}" ]]; then
    [[ -f "${NETRC_FILE}" && ! -L "${NETRC_FILE}" ]] || die "Netrc file must be a regular, non-symlink file: ${NETRC_FILE}"
    [[ "$(stat -c '%a' "${NETRC_FILE}")" == 600 ]] || die "LDAP test netrc must have mode 0600."
    auth_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 30 --netrc-file "${NETRC_FILE}" https://ppcf-vm.biochem.mpg.de/ppsvf-app/ || true)"
    [[ "${auth_status}" =~ ^(2|3)[0-9][0-9]$ ]] && pass "LDAP-authenticated application route returned ${auth_status}" || fail "LDAP-authenticated route returned ${auth_status:-no response}"
    spoof_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 30 --netrc-file "${NETRC_FILE}" -H 'X-Remote-User: forged-admin' https://ppcf-vm.biochem.mpg.de/ppsvf-app/ || true)"
    [[ "${spoof_status}" =~ ^(2|3)[0-9][0-9]$ ]] && pass "authenticated request survives replacement of a forged identity header" || fail "authenticated spoof test returned ${spoof_status:-no response}"
    websocket_status="$(curl --http1.1 --silent --output /dev/null --write-out '%{http_code}' --max-time 8 --netrc-file "${NETRC_FILE}" \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: cHBzdi12ZXJpZnktdGVzdA==' \
      -H 'Sec-WebSocket-Protocol: shiny' \
      -H 'Origin: https://ppcf-vm.biochem.mpg.de' \
      -H 'X-Remote-User: forged-admin' \
      https://ppcf-vm.biochem.mpg.de/ppsvf-app/websocket/ || true)"
    [[ "${websocket_status}" == 101 ]] && pass "authenticated WebSocket upgrade succeeds after forged identity replacement" || fail "authenticated WebSocket upgrade returned ${websocket_status:-no response}, expected 101"
    forged_rows="$(runuser -u "${APP_RUN_USER}" -- sqlite3 "${PPSV_DB_FILE}" "SELECT count(*) FROM users WHERE lower(username)='forged-admin';" 2>/dev/null || true)"
    [[ "${forged_rows}" == 0 ]] && pass "forged identity was not synchronized into the user directory" || fail "forged-admin unexpectedly exists in the user directory"
  else
    fail "No --netrc supplied; LDAP login, authenticated spoof replacement, and WebSocket checks were not proved."
  fi
fi

if [[ -n "${ROLE_USER}" ]]; then
  check_role "${ROLE_USER}" user
elif ((SKIP_PUBLIC == 0)); then
  fail "No --role-user supplied; the ordinary-user role was not proved."
else
  warn "Public checks skipped; the ordinary-user role proof remains an operator acceptance item."
fi

if ((failures > 0)); then
  die "Deployment verification found ${failures} failure(s)."
fi
log "Deployment verification passed."
