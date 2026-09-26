#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE=""
INSTALL_SYSTEM=0

usage() {
  cat <<'USAGE'
Usage: provision.sh --env FILE [--install-system]

Idempotently provisions the PPSV runtime account, persistent directories,
pool ACL, TLS material, Apache/Shiny configuration, and systemd timers.
TLS_KEY_FILE and PPSV_BACKUP_DIR are mandatory; neither is guessed.
USAGE
}

while (($#)); do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env needs a file"
      ENV_FILE="$2"
      shift 2
      ;;
    --install-system) INSTALL_SYSTEM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
[[ -n "${ENV_FILE}" ]] || die "--env is required. Start from scripts/ppsv-app.env.example."
load_runtime_env "${ENV_FILE}"
validate_runtime_paths

[[ "${APP_RUN_USER}" == ppsvf-shiny-user ]] || die "Production APP_RUN_USER must be ppsvf-shiny-user."
[[ "${APP_RUN_GROUP}" == ppsvf-shiny ]] || die "Production APP_RUN_GROUP must be the private group ppsvf-shiny."
[[ "${PPSV_POOL_GROUP}" == b_profa ]] || die "Production PPSV_POOL_GROUP must be b_profa."
[[ "${AUTH_MODE:-}" == ldap ]] || die "Production AUTH_MODE must be ldap."
[[ "${PPSV_PUBLIC_URL}" == https://ppcf-vm.biochem.mpg.de/ppsv-app/ ]] || die "Unexpected PPSV_PUBLIC_URL: ${PPSV_PUBLIC_URL}"

check_args=(--repo "${PPSV_REPO_ROOT_DEFAULT}" --env "${ENV_FILE}")
((INSTALL_SYSTEM == 0)) || check_args+=(--install-system)
"${SCRIPT_DIR}/check_requirements.sh" "${check_args[@]}"

for name in TLS_CERT_FILE TLS_BUNDLE_FILE TLS_KEY_FILE PPSV_BACKUP_DIR; do
  require_value "${name}"
done
require_absolute_path TLS_CERT_FILE "${TLS_CERT_FILE}"
require_absolute_path TLS_BUNDLE_FILE "${TLS_BUNDLE_FILE}"
require_absolute_path TLS_KEY_FILE "${TLS_KEY_FILE}"
require_absolute_path PPSV_BACKUP_DIR "${PPSV_BACKUP_DIR}"

for tls_file in "${TLS_CERT_FILE}" "${TLS_BUNDLE_FILE}" "${TLS_KEY_FILE}"; do
  [[ -f "${tls_file}" && -r "${tls_file}" ]] || die "TLS source is not a readable regular file: ${tls_file}"
done
[[ "${TLS_KEY_FILE}" != *request* && "${TLS_KEY_FILE}" != *.csr ]] || die "TLS_KEY_FILE looks like a certificate request, not a private key."

tls_work="$(mktemp -d)"
config_started=0
config_committed=0
config_targets=()
site80_was_enabled=0
site443_was_enabled=0
default_http_was_enabled=0
default_ssl_was_enabled=0
cleanup() {
  local status=$?
  trap - EXIT
  if [[ ${config_started:-0} -eq 1 && ${config_committed:-0} -eq 0 ]]; then
    warn "Provisioning did not activate; restoring the previous TLS and service configuration."
    local index target
    for index in "${!config_targets[@]}"; do
      target="${config_targets[$index]}"
      if [[ -f "${tls_work}/previous/${index}" ]]; then
        cp -a -- "${tls_work}/previous/${index}" "${target}"
      else
        rm -f -- "${target}"
      fi
    done
    ((site80_was_enabled == 0)) || a2ensite ppsv-vm-shiny-80.conf >/dev/null 2>&1 || true
    ((site80_was_enabled == 1)) || a2dissite ppsv-vm-shiny-80.conf >/dev/null 2>&1 || true
    ((site443_was_enabled == 0)) || a2ensite ppsv-vm-shiny-443.conf >/dev/null 2>&1 || true
    ((site443_was_enabled == 1)) || a2dissite ppsv-vm-shiny-443.conf >/dev/null 2>&1 || true
    ((default_http_was_enabled == 0)) || a2ensite 000-default.conf >/dev/null 2>&1 || true
    ((default_http_was_enabled == 1)) || a2dissite 000-default.conf >/dev/null 2>&1 || true
    ((default_ssl_was_enabled == 0)) || a2ensite default-ssl.conf >/dev/null 2>&1 || true
    ((default_ssl_was_enabled == 1)) || a2dissite default-ssl.conf >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    if apache2ctl configtest >/dev/null 2>&1 && systemctl is-active --quiet apache2; then
      systemctl reload apache2 || true
    fi
  fi
  rm -rf -- "${tls_work}"
  exit "${status}"
}
trap cleanup EXIT

openssl x509 -in "${TLS_CERT_FILE}" -noout >/dev/null || die "TLS_CERT_FILE is not a PEM certificate."
san_text="$(openssl x509 -in "${TLS_CERT_FILE}" -noout -ext subjectAltName 2>/dev/null || true)"
grep -Eq 'DNS:ppcf-vm\.biochem\.mpg\.de([,[:space:]]|$)' <<<"${san_text}" || die "Leaf certificate SAN must explicitly contain ppcf-vm.biochem.mpg.de."
openssl x509 -in "${TLS_CERT_FILE}" -noout -checkhost ppcf-vm.biochem.mpg.de >/dev/null || die "Leaf certificate SAN does not cover ppcf-vm.biochem.mpg.de."
openssl x509 -in "${TLS_CERT_FILE}" -noout -checkend 2592000 >/dev/null || die "Leaf certificate expires within 30 days."
openssl pkey -in "${TLS_KEY_FILE}" -passin pass: -check -noout >/dev/null 2>&1 || die "TLS_KEY_FILE is invalid or encrypted; Apache requires an unattended readable key."

cert_count="$(grep -c -- '-----BEGIN CERTIFICATE-----' "${TLS_BUNDLE_FILE}" || true)"
((cert_count >= 2)) || die "TLS_BUNDLE_FILE must contain the leaf certificate followed by at least one chain certificate."
awk '
  /-----BEGIN CERTIFICATE-----/ { in_cert = 1; count++ }
  in_cert && count == 1 { print }
  /-----END CERTIFICATE-----/ && count == 1 { exit }
' "${TLS_BUNDLE_FILE}" >"${tls_work}/bundle-leaf.pem"
awk '
  /-----BEGIN CERTIFICATE-----/ { in_cert = 1; count++ }
  in_cert && count >= 2 { print }
  /-----END CERTIFICATE-----/ && count >= 2 { in_cert = 0 }
' "${TLS_BUNDLE_FILE}" >"${tls_work}/bundle-chain.pem"
openssl x509 -in "${tls_work}/bundle-leaf.pem" -noout >/dev/null || die "The first bundle entry is not a valid certificate."
[[ -s "${tls_work}/bundle-chain.pem" ]] || die "TLS bundle does not contain an intermediate certificate chain."
openssl crl2pkcs7 -nocrl -certfile "${TLS_BUNDLE_FILE}" 2>/dev/null | openssl pkcs7 -print_certs -noout >/dev/null || die "TLS_BUNDLE_FILE contains malformed certificate data."

leaf_fingerprint="$(openssl x509 -in "${TLS_CERT_FILE}" -noout -fingerprint -sha256)"
bundle_fingerprint="$(openssl x509 -in "${tls_work}/bundle-leaf.pem" -noout -fingerprint -sha256)"
[[ "${leaf_fingerprint}" == "${bundle_fingerprint}" ]] || die "TLS bundle must begin with the same leaf certificate as TLS_CERT_FILE."

cert_key_hash="$(openssl x509 -in "${TLS_CERT_FILE}" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
private_key_hash="$(openssl pkey -in "${TLS_KEY_FILE}" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
[[ "${cert_key_hash}" == "${private_key_hash}" ]] || die "TLS certificate and private key do not match."
[[ -r /etc/ssl/certs/ca-certificates.crt ]] || die "System CA trust store is unavailable."
openssl verify -purpose sslserver \
  -CAfile /etc/ssl/certs/ca-certificates.crt \
  -untrusted "${tls_work}/bundle-chain.pem" \
  "${TLS_CERT_FILE}" >/dev/null || die "TLS leaf/intermediate chain does not terminate at a system-trusted CA."
log "TLS key, SAN, expiry, leaf order, and chain validated."

# Prove both external storage dependencies before changing accounts,
# permissions, environment files, or service configuration.
validate_pool_destination
validate_backup_destination

# Snapshot every managed configuration file before the first replacement so a
# later Apache/systemd failure cannot leave a mixed old/new installation.
config_targets=(
  /etc/ppsv-app/ppsv-app.env
  /etc/ssl/certs/ppsv-app-fullchain.pem
  /etc/ssl/private/ppsv-app.key
  /etc/shiny-server/shiny-server.conf
  /etc/apache2/sites-available/ppsv-vm-shiny-80.conf
  /etc/apache2/sites-available/ppsv-vm-shiny-443.conf
  /usr/local/libexec/ppsv-app/lib.sh
  /usr/local/libexec/ppsv-app/backup.sh
  /usr/local/libexec/ppsv-app/backup_database.R
  /usr/local/libexec/ppsv-app/check_requirements.sh
  /usr/local/libexec/ppsv-app/deploy.sh
  /usr/local/libexec/ppsv-app/process_mail_outbox.sh
  /usr/local/libexec/ppsv-app/reconcile_pool.sh
  /usr/local/libexec/ppsv-app/restore_backup.sh
  /usr/local/libexec/ppsv-app/rollback.sh
  /usr/local/libexec/ppsv-app/verify_deployment.sh
  /etc/systemd/system/shiny-server.service.d/ppsv-app.conf
  /etc/systemd/system/ppsv-mail-outbox.service
  /etc/systemd/system/ppsv-mail-outbox.timer
  /etc/systemd/system/ppsv-backup.service
  /etc/systemd/system/ppsv-backup.timer
  /etc/systemd/system/ppsv-pool-reconcile.service
)
install -d -o root -g root -m 0700 "${tls_work}/previous"
for index in "${!config_targets[@]}"; do
  target="${config_targets[$index]}"
  [[ ! -L "${target}" ]] || die "Refusing to replace a symbolic-link configuration target: ${target}"
  if [[ -e "${target}" ]]; then
    [[ -f "${target}" ]] || die "Configuration target is not a regular file: ${target}"
    cp -a -- "${target}" "${tls_work}/previous/${index}"
  fi
done
[[ -L /etc/apache2/sites-enabled/ppsv-vm-shiny-80.conf ]] && site80_was_enabled=1
[[ -L /etc/apache2/sites-enabled/ppsv-vm-shiny-443.conf ]] && site443_was_enabled=1
[[ -L /etc/apache2/sites-enabled/000-default.conf ]] && default_http_was_enabled=1
[[ -L /etc/apache2/sites-enabled/default-ssl.conf ]] && default_ssl_was_enabled=1

if ! getent group "${APP_RUN_GROUP}" >/dev/null; then
  groupadd --system "${APP_RUN_GROUP}"
fi
if ! getent passwd "${APP_RUN_USER}" >/dev/null; then
  useradd --system --gid "${APP_RUN_GROUP}" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "${APP_RUN_USER}"
fi
actual_primary_group="$(id -gn "${APP_RUN_USER}")"
[[ "${actual_primary_group}" == "${APP_RUN_GROUP}" ]] || die "${APP_RUN_USER} primary group is ${actual_primary_group}; expected private group ${APP_RUN_GROUP}."
getent group "${PPSV_POOL_GROUP}" >/dev/null || die "Required pool group does not exist: ${PPSV_POOL_GROUP}"

config_started=1
install -d -o root -g "${APP_RUN_GROUP}" -m 0750 /etc/ppsv-app
if [[ "$(readlink -f "${ENV_FILE}")" != /etc/ppsv-app/ppsv-app.env ]]; then
  install -o root -g "${APP_RUN_GROUP}" -m 0640 "${ENV_FILE}" /etc/ppsv-app/ppsv-app.env
else
  chown root:"${APP_RUN_GROUP}" /etc/ppsv-app/ppsv-app.env
  chmod 0640 /etc/ppsv-app/ppsv-app.env
fi

install -d -o root -g "${APP_RUN_GROUP}" -m 0750 "${PPSV_RELEASES_ROOT}"
install -d -o root -g "${APP_RUN_GROUP}" -m 1770 "${PPSV_DATA_ROOT}"
install -d -o "${APP_RUN_USER}" -g "${APP_RUN_GROUP}" -m 2770 \
  "${PPSV_FALLBACK_ROOT}" "${PPSV_DATA_ROOT}/renv-cache"
install -d -o root -g "${APP_RUN_GROUP}" -m 0750 \
  "${PPSV_DATA_ROOT}/locks" "${PPSV_DATA_ROOT}/deployments" "${PPSV_DATA_ROOT}/pre_restore"
for lock_file in "${PPSV_DATA_ROOT}/locks/maintenance.lock" "${PPSV_DATA_ROOT}/locks/mail-outbox.lock"; do
  if [[ ! -e "${lock_file}" ]]; then
    install -o root -g "${APP_RUN_GROUP}" -m 0660 /dev/null "${lock_file}"
  else
    [[ -f "${lock_file}" && ! -L "${lock_file}" ]] || die "Unsafe pre-existing lock path: ${lock_file}"
    chown root:"${APP_RUN_GROUP}" "${lock_file}"
    chmod 0660 "${lock_file}"
  fi
done
install -d -o root -g "${APP_RUN_GROUP}" -m 0750 /srv/shiny-server

[[ -d "${PPSV_POOL_ROOT}" ]] || die "Project pool is not mounted at ${PPSV_POOL_ROOT}."
chgrp "${PPSV_POOL_GROUP}" "${PPSV_POOL_ROOT}"
chmod 2770 "${PPSV_POOL_ROOT}"
setfacl -m "u:${APP_RUN_USER}:rwx,g:${PPSV_POOL_GROUP}:rwx,m:rwx" "${PPSV_POOL_ROOT}"
setfacl -d -m "u:${APP_RUN_USER}:rwx,g:${PPSV_POOL_GROUP}:rwx,m:rwx" "${PPSV_POOL_ROOT}"

install -d -o "${APP_RUN_USER}" -g "${APP_RUN_GROUP}" -m 0750 \
  "${PPSV_BACKUP_DIR}" "${PPSV_BACKUP_DIR}/database" "${PPSV_BACKUP_DIR}/fallback"
runuser -u "${APP_RUN_USER}" -- test -w "${PPSV_BACKUP_DIR}" || die "Runtime user cannot write PPSV_BACKUP_DIR."

install -o root -g root -m 0644 "${TLS_BUNDLE_FILE}" /etc/ssl/certs/ppsv-app-fullchain.pem
install -o root -g root -m 0600 "${TLS_KEY_FILE}" /etc/ssl/private/ppsv-app.key

install -o root -g root -m 0644 "${SCRIPT_DIR}/shiny-server.conf" /etc/shiny-server/shiny-server.conf
install -o root -g root -m 0644 "${SCRIPT_DIR}/ppsv-vm-shiny-80.conf" /etc/apache2/sites-available/ppsv-vm-shiny-80.conf
install -o root -g root -m 0644 "${SCRIPT_DIR}/ppsv-vm-shiny-443.conf" /etc/apache2/sites-available/ppsv-vm-shiny-443.conf

a2enmod authnz_ldap headers ldap proxy proxy_http proxy_wstunnel rewrite ssl
a2dissite 000-default.conf default-ssl.conf 2>/dev/null || true
a2ensite ppsv-vm-shiny-80.conf ppsv-vm-shiny-443.conf
apache2ctl configtest

install -d -o root -g root -m 0755 /usr/local/libexec/ppsv-app
for helper in lib.sh backup.sh backup_database.R check_requirements.sh deploy.sh process_mail_outbox.sh reconcile_pool.sh restore_backup.sh rollback.sh verify_deployment.sh; do
  install -o root -g root -m 0755 "${SCRIPT_DIR}/${helper}" "/usr/local/libexec/ppsv-app/${helper}"
done

install -d -o root -g root -m 0755 /etc/systemd/system/shiny-server.service.d
install -o root -g root -m 0644 "${SCRIPT_DIR}/systemd/shiny-server-ppsv.conf" /etc/systemd/system/shiny-server.service.d/ppsv-app.conf
for unit in ppsv-mail-outbox.service ppsv-mail-outbox.timer ppsv-backup.service ppsv-backup.timer ppsv-pool-reconcile.service; do
  install -o root -g root -m 0644 "${SCRIPT_DIR}/systemd/${unit}" "/etc/systemd/system/${unit}"
done

systemctl daemon-reload
systemctl enable ppsv-mail-outbox.timer ppsv-backup.timer
systemctl reload apache2

config_committed=1
trap - EXIT
rm -rf -- "${tls_work}"
log "Provisioning complete. Deploy an application release before starting the PPSV timers."
