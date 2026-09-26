#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

DEB_FILE=""
EXPECTED_SHA256=""
EXPECTED_VERSION=""
ENV_FILE=""

usage() {
  cat <<'USAGE'
Usage: install_shiny_server.sh --deb FILE [--env FILE] [--sha256 HEX]
                               [--version VERSION]

Installs a local Shiny Server Open Source package only after validating the
reviewed SHA-256, Debian architecture, host platform, and exact package
version. Values may come from the protected runtime environment; explicit
arguments override them. This script never downloads an installer.
USAGE
}

while (($#)); do
  case "$1" in
    --deb)
      [[ $# -ge 2 ]] || die "--deb needs a file"
      DEB_FILE="$2"
      shift 2
      ;;
    --sha256)
      [[ $# -ge 2 ]] || die "--sha256 needs a value"
      EXPECTED_SHA256="${2,,}"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env needs a file"
      ENV_FILE="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version needs a value"
      EXPECTED_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
if [[ -n "${ENV_FILE}" ]]; then
  load_runtime_env "${ENV_FILE}"
fi
EXPECTED_VERSION="${EXPECTED_VERSION:-${SHINY_SERVER_VERSION:-1.5.23.1030}}"
EXPECTED_SHA256="${EXPECTED_SHA256:-${SHINY_SERVER_DEB_SHA256:-}}"
require_command dpkg-deb
require_command sha256sum
[[ -f "${DEB_FILE}" ]] || die "Installer not found: ${DEB_FILE:-<unset>}"
[[ "${EXPECTED_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "--sha256 must be a reviewed 64-character SHA-256 value."

[[ -r /etc/os-release ]] || die "/etc/os-release is unavailable."
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 26.04 ]]; then
  die "Unsupported Shiny Server installer platform: ${ID:-unknown} ${VERSION_ID:-unknown}; expected Ubuntu 26.04 LTS."
fi

actual_sha256="$(sha256sum "${DEB_FILE}" | awk '{print $1}')"
[[ "${actual_sha256}" == "${EXPECTED_SHA256}" ]] || die "Installer checksum mismatch. Expected ${EXPECTED_SHA256}; got ${actual_sha256}."

package_name="$(dpkg-deb -f "${DEB_FILE}" Package)"
package_version="$(dpkg-deb -f "${DEB_FILE}" Version)"
package_arch="$(dpkg-deb -f "${DEB_FILE}" Architecture)"
[[ "${package_name}" == shiny-server ]] || die "Unexpected Debian package: ${package_name}"
[[ "${package_version}" == "${EXPECTED_VERSION}" ]] || die "Expected Shiny Server ${EXPECTED_VERSION}; package contains ${package_version}."
[[ "${package_arch}" == amd64 ]] || die "Expected amd64 package; found ${package_arch}."
[[ "$(dpkg --print-architecture)" == amd64 ]] || die "Host architecture is not amd64."

log "Installing verified ${package_name} ${package_version} (${actual_sha256})."
apt-get install -y "$(readlink -f "${DEB_FILE}")"

installed_version="$(dpkg-query -W -f='${Version}' shiny-server 2>/dev/null || true)"
[[ "${installed_version}" == "${EXPECTED_VERSION}" ]] || die "Installed Debian package version is ${installed_version:-unknown}; expected exactly ${EXPECTED_VERSION}."
log "Shiny Server ${EXPECTED_VERSION} installed successfully."
