#!/usr/bin/env bash

# Resolve the newest signed Skemer release and optionally pin it into the
# veldmuis-skemer PKGBUILD.
#
# The Skemer project signs its release artifacts with its own key. This script
# verifies those signatures against the vendored public key before trusting a
# release, so the Veldmuis package repository only ever repackages an
# authenticated upstream build. The Veldmuis signing key is not involved.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
pkgbuild="${VELDMUIS_SKEMER_PKGBUILD:-${repo_root}/packages/veldmuis-skemer/PKGBUILD}"
keyring="${SKEMER_RELEASE_KEYRING:-${repo_root}/development/skemer-keyring/skemer-release.gpg}"
trusted_file="${SKEMER_RELEASE_TRUSTED:-${repo_root}/development/skemer-keyring/skemer-trusted}"
source_repo="${SKEMER_RELEASE_REPO:-bornmanr/skemer}"
work_dir=""

log() {
  printf '[resolve-skemer-release] %s\n' "$*"
}

die() {
  printf '[resolve-skemer-release] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

cleanup() {
  if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
    rm -rf -- "${work_dir}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage:
  resolve-skemer-release.sh --print-version
  resolve-skemer-release.sh --update-package

Behavior:
  - --print-version prints the newest Skemer release tag that carries the
    signature assets, or nothing when no signed release exists
  - --update-package verifies that release against the vendored Skemer public
    key and rewrites packages/veldmuis-skemer/PKGBUILD to pin its version and
    checksum

Environment overrides:
  SKEMER_RELEASE_REPO     Default: bornmanr/skemer
  SKEMER_RELEASE_KEYRING  Default: development/skemer-keyring/skemer-release.gpg
  SKEMER_RELEASE_TRUSTED  Default: development/skemer-keyring/skemer-trusted
  VELDMUIS_SKEMER_PKGBUILD
EOF
}

tag_to_version() {
  printf '%s\n' "${1#v}"
}

latest_signed_version() {
  local tag version names name
  local -a required=()

  command -v gh >/dev/null 2>&1 || return 1

  tag="$(gh api "repos/${source_repo}/releases/latest" --jq '.tag_name' 2>/dev/null)" || return 1
  [[ -n "${tag}" && "${tag}" != "null" ]] || return 1

  version="$(tag_to_version "${tag}")"
  names="$(gh api "repos/${source_repo}/releases/latest" --jq '.assets[].name' 2>/dev/null)" || return 1

  required=(
    "skemer-${version}-x86_64-linux.tar.gz"
    "skemer-${version}-x86_64-linux.tar.gz.asc"
    "SHA256SUMS"
    "SHA256SUMS.asc"
  )
  for name in "${required[@]}"; do
    grep -qxF -- "${name}" <<<"${names}" || return 1
  done

  printf '%s\n' "${version}"
}

verify_vendored_key() {
  local trusted actual

  [[ -r "${keyring}" ]] || die "Vendored Skemer keyring not found: ${keyring}"
  [[ -r "${trusted_file}" ]] || die "Vendored Skemer trusted fingerprint not found: ${trusted_file}"

  trusted="$(tr -d '[:space:]' < "${trusted_file}" | tr '[:lower:]' '[:upper:]')"
  actual="$(gpg --batch --show-keys --with-colons "${keyring}" 2>/dev/null \
    | awk -F: '$1 == "fpr" { print $10; exit }' | tr '[:lower:]' '[:upper:]')"

  [[ "${actual}" =~ ^[0-9A-F]{40}$ ]] || die "Could not read a fingerprint from ${keyring}."
  [[ "${actual}" == "${trusted}" ]] || \
    die "Vendored Skemer keyring does not match the pinned fingerprint (${trusted})."
}

print_version() {
  local version
  if version="$(latest_signed_version)"; then
    printf '%s\n' "${version}"
  fi
}

update_package() {
  local version tarball computed expected

  if ! version="$(latest_signed_version)"; then
    log "No signed Skemer release is available; leaving the pinned version in place."
    return 0
  fi

  [[ -r "${pkgbuild}" ]] || die "PKGBUILD not found: ${pkgbuild}"
  [[ -r "${keyring}" ]] || die "Vendored Skemer keyring not found: ${keyring}"
  [[ -r "${trusted_file}" ]] || die "Vendored Skemer trusted fingerprint not found: ${trusted_file}"

  require_cmd gh
  require_cmd gpg
  require_cmd gpgv
  require_cmd sha256sum
  require_cmd awk
  require_cmd sed

  verify_vendored_key

  work_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/veldmuis-skemer-release.XXXXXX")"
  tarball="skemer-${version}-x86_64-linux.tar.gz"

  log "Downloading Skemer ${version} release artifacts"
  gh release download "v${version}" --repo "${source_repo}" \
    --pattern "${tarball}" \
    --pattern "${tarball}.asc" \
    --pattern "SHA256SUMS" \
    --pattern "SHA256SUMS.asc" \
    --dir "${work_dir}" --clobber

  log "Verifying Skemer ${version} signatures"
  gpgv --keyring "${keyring}" "${work_dir}/SHA256SUMS.asc" "${work_dir}/SHA256SUMS" \
    || die "SHA256SUMS signature verification failed for Skemer ${version}."
  gpgv --keyring "${keyring}" "${work_dir}/${tarball}.asc" "${work_dir}/${tarball}" \
    || die "Artifact signature verification failed for Skemer ${version}."

  computed="$(sha256sum "${work_dir}/${tarball}" | awk '{print $1}')"
  expected="$(awk -v name="./${tarball}" '$2 == name { print $1; exit }' "${work_dir}/SHA256SUMS")"
  if [[ -z "${expected}" ]]; then
    expected="$(awk -v name="${tarball}" '$2 == name { print $1; exit }' "${work_dir}/SHA256SUMS")"
  fi
  [[ "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA256SUMS does not list ${tarball}."
  [[ "${computed,,}" == "${expected,,}" ]] || \
    die "Tarball checksum mismatch for Skemer ${version}."

  sed -i "s|^pkgver=.*|pkgver=${version}|" "${pkgbuild}"
  sed -i "s|^sha256sums=.*|sha256sums=(\"${computed}\")|" "${pkgbuild}"

  log "Pinned veldmuis-skemer to Skemer ${version} (${computed})"
}

main() {
  case "${1:-}" in
    --print-version)
      require_cmd gh
      print_version
      ;;
    --update-package)
      update_package
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      die "Unknown or missing argument: ${1:-}"
      ;;
  esac
}

main "$@"
