#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

INSTALL_SYSTEM=0
REPO_ROOT="${PPSV_REPO_ROOT_DEFAULT}"
RUNTIME_PROJECT=""
ENV_FILE=""

usage() {
  cat <<'USAGE'
Usage: check_requirements.sh [options]

Read-only by default. Options:
  --install-system          Install missing Ubuntu packages with apt.
  --repo PATH               Repository containing ppsv-app/renv.lock.
  --runtime-project PATH    Also load rJava and mailR from this restored project.
  --env PATH                Read SHINY_SERVER_VERSION and path overrides.
  -h, --help                Show this help.
USAGE
}

while (($#)); do
  case "$1" in
    --install-system)
      INSTALL_SYSTEM=1
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo needs a path"
      REPO_ROOT="$2"
      shift 2
      ;;
    --runtime-project)
      [[ $# -ge 2 ]] || die "--runtime-project needs a path"
      RUNTIME_PROJECT="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env needs a path"
      ENV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

if [[ -n "${ENV_FILE}" ]]; then
  load_runtime_env "${ENV_FILE}"
fi

EXPECTED_SHINY_VERSION="${SHINY_SERVER_VERSION:-1.5.23.1030}"
if [[ -n "${ENV_FILE}" ]]; then
  [[ "${SHINY_SERVER_DEB_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die "SHINY_SERVER_DEB_SHA256 must contain the reviewed 64-character checksum."
fi

[[ -r /etc/os-release ]] || die "/etc/os-release is unavailable. This target must be Ubuntu 26.04."
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 26.04 ]]; then
  if [[ "${PPSV_ALLOW_OS_OVERRIDE:-0}" != 1 ]]; then
    die "Unsupported OS ${ID:-unknown} ${VERSION_ID:-unknown}; expected Ubuntu 26.04. Set PPSV_ALLOW_OS_OVERRIDE=1 only for a documented test host."
  fi
  warn "OS override accepted for ${ID:-unknown} ${VERSION_ID:-unknown}."
fi

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) die "The pinned Shiny Server installer is amd64-only; found $(uname -m)." ;;
esac

APT_PACKAGES=(
  acl
  apache2
  build-essential
  ca-certificates
  curl
  default-jdk
  git
  libcurl4-openssl-dev
  libfontconfig1-dev
  libfreetype6-dev
  libfribidi-dev
  libharfbuzz-dev
  libjpeg-dev
  libldap2-dev
  libpng-dev
  libsasl2-dev
  libssl-dev
  libtiff-dev
  libxml2-dev
  make
  pandoc
  r-base
  r-base-dev
  rsync
  sqlite3
  unzip
)

missing_packages=()
for package in "${APT_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q 'install ok installed' || missing_packages+=("${package}")
done

if ((${#missing_packages[@]} > 0 && INSTALL_SYSTEM == 1)); then
  require_root
  log "Installing missing Ubuntu packages: ${missing_packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
  missing_packages=()
fi

((${#missing_packages[@]} == 0)) || die "Missing Ubuntu packages: ${missing_packages[*]}. Re-run with --install-system after review."

for command_name in apache2ctl curl flock git java javac openssl R Rscript rsync setfacl sha256sum sqlite3; do
  require_command "${command_name}"
done

[[ -x /opt/shiny-server/bin/shiny-server ]] || die "Shiny Server is not installed. Use install_shiny_server.sh with a reviewed .deb checksum."
installed_shiny_version="$(dpkg-query -W -f='${Version}' shiny-server 2>/dev/null || true)"
[[ "${installed_shiny_version}" == "${EXPECTED_SHINY_VERSION}" ]] || die "Expected exact Shiny Server Debian package ${EXPECTED_SHINY_VERSION}; got: ${installed_shiny_version:-unknown}"

LOCK_FILE="${REPO_ROOT%/}/ppsv-app/renv.lock"
[[ -f "${LOCK_FILE}" ]] || die "Pinned dependency lock is missing: ${LOCK_FILE}"
LOCK_SIDECAR="${REPO_ROOT%/}/ppsv-app/renv.lock.sha256"
[[ -f "${LOCK_SIDECAR}" ]] || die "Reviewed dependency-lock checksum is missing: ${LOCK_SIDECAR}"
(
  cd "$(dirname "${LOCK_FILE}")"
  sha256sum --check --strict "$(basename "${LOCK_SIDECAR}")"
) || die "renv.lock does not match its reviewed SHA-256 sidecar."
Rscript --vanilla -e '
  path <- commandArgs(trailingOnly = TRUE)[[1L]]
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  quote <- intToUtf8(34L)
  required <- c("DBI", "digest", "DT", "mailR", "png", "rJava", "RSQLite", "shiny")
  missing <- required[!vapply(
    required,
    function(package) any(grepl(paste0(quote, package, quote), lines, fixed = TRUE)),
    logical(1L)
  )]
  if (length(missing)) stop("renv.lock is missing runtime packages: ", paste(missing, collapse = ", "))
  r_index <- grep(paste0(quote, "R", quote, ":"), lines, fixed = TRUE)[1L]
  package_index <- grep(paste0(quote, "Packages", quote, ":"), lines, fixed = TRUE)[1L]
  version_lines <- lines[seq.int(r_index, package_index - 1L)]
  version_line <- version_lines[grep(paste0(quote, "Version", quote, ":"), version_lines, fixed = TRUE)[1L]]
  locked_r <- strsplit(version_line, quote, fixed = TRUE)[[1L]][[4L]]
  version_series <- function(value) {
    parts <- strsplit(as.character(value), ".", fixed = TRUE)[[1L]]
    paste(parts[seq_len(min(2L, length(parts)))], collapse = ".")
  }
  current_series <- version_series(getRversion())
  locked_series <- version_series(locked_r)
  if (!identical(current_series, locked_series)) {
    stop("R major/minor ", current_series, " does not match lockfile series ", locked_series)
  }
' "${LOCK_FILE}"

java_home="$(R CMD config JAVA_HOME 2>/dev/null || true)"
[[ -n "${java_home}" && -d "${java_home}" ]] || die "R is not configured with a valid JAVA_HOME. Run sudo R CMD javareconf, then retry."

if [[ -n "${RUNTIME_PROJECT}" ]]; then
  [[ -d "${RUNTIME_PROJECT}" ]] || die "Runtime project does not exist: ${RUNTIME_PROJECT}"
  (
    cd "${RUNTIME_PROJECT}"
    Rscript -e '
      stopifnot(requireNamespace("renv", quietly = TRUE))
      stopifnot(requireNamespace("rJava", quietly = TRUE))
      stopifnot(requireNamespace("mailR", quietly = TRUE))
      rJava::.jinit()
      cat("rJava/mailR runtime gate passed\n")
    '
  )
fi

log "Requirement check passed (Ubuntu ${VERSION_ID:-unknown}, $(uname -m), Shiny Server ${EXPECTED_SHINY_VERSION})."
