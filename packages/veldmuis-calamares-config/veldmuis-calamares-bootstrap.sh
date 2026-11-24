#!/usr/bin/env bash

# Installing the target system in phases lets Calamares advance its progress bar
# during the long package download instead of sitting on a single opaque job.
# Each phase is a separate shellprocess job (see settings.conf) that calls this
# script with its phase name; "all" runs every phase in one go and is kept for
# manual runs.

set -euo pipefail

phase="${1:-all}"
target_root="${2:-}"
graphics_choice="${3:-all-open-source}"
extras_choice="${4:-}"
live_repo_root="/opt/veldmuis/repo"
installer_package_sets="/usr/lib/veldmuis/installer-package-sets.sh"
state_dir="/tmp/veldmuis-calamares"
pacman_conf="${state_dir}/pacman.conf"
arch_mirrorlist="${state_dir}/mirrorlist"
log_file="/tmp/veldmuis-calamares-bootstrap.log"

log() {
  printf '[veldmuis-calamares-bootstrap] %s\n' "$*"
}

die() {
  printf '[veldmuis-calamares-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

cleanup() {
  rm -rf "${state_dir}"
}

write_live_arch_mirrorlist() {
  install -d -m700 "${state_dir}"
  arch_mirrorlist="${state_dir}/mirrorlist"

  [[ -f /etc/pacman.d/mirrorlist ]] || \
    die "Live Arch mirrorlist is missing at /etc/pacman.d/mirrorlist."

  awk '
    /^[[:space:]]*Server[[:space:]]*=/ {
      sub(/^[[:space:]]*/, "")
      print
      found = 1
    }
    END { exit found ? 0 : 1 }
  ' /etc/pacman.d/mirrorlist >"${arch_mirrorlist}" || \
    die "Live Arch mirrorlist has no active Server entries. The ISO mirror hook likely did not run."

  chmod 644 "${arch_mirrorlist}"
  log "Using active Arch mirrors from the live mirrorlist"
}

write_ranked_arch_mirrorlist() {
  local ranked_mirrorlist=""

  if ! command -v veldmuis-refresh-arch-mirrors >/dev/null 2>&1; then
    log "Veldmuis mirror refresh helper is unavailable; using live Arch mirrorlist"
    write_live_arch_mirrorlist
    return
  fi

  install -d -m700 "${state_dir}"
  ranked_mirrorlist="$(mktemp -t veldmuis-calamares-ranked-mirrorlist.XXXXXX)"
  if veldmuis-refresh-arch-mirrors --output "${ranked_mirrorlist}" --no-backup; then
    arch_mirrorlist="${state_dir}/mirrorlist"
    mv -f "${ranked_mirrorlist}" "${arch_mirrorlist}"
    chmod 644 "${arch_mirrorlist}"
    log "Using ranked Arch mirrors from reflector"
    return
  fi

  log "Reflector mirror ranking failed; using live Arch mirrorlist"
  rm -f "${ranked_mirrorlist}"
  write_live_arch_mirrorlist
}

write_arch_mirrorlist() {
  write_ranked_arch_mirrorlist
}

normalize_graphics_choice() {
  case "${graphics_choice}" in
    all-open-source|amd-open-source|intel-open-source|nvidia-open-source|nvidia-580xx-dkms)
      ;;
    "")
      graphics_choice="all-open-source"
      ;;
    *)
      log "Unknown graphics choice '${graphics_choice}', defaulting to all-open-source"
      graphics_choice="all-open-source"
      ;;
  esac
}

# Extras tokens accepted by the installer UI. Every token maps to exactly one
# selectable row; "gaming" is the legacy grouped token and still installs the
# veldmuis-gaming metapackage so older answers keep working.
normalize_extras_choice() {
  local extra
  local -a extras=()
  local -a validated=()

  [[ -n "${extras_choice}" ]] || return 0

  IFS=',' read -r -a extras <<<"${extras_choice}"
  for extra in "${extras[@]}"; do
    case "${extra}" in
      gaming|steam|lutris|discord|qbittorrent|syncthing|code|dotfiles|opencode|codex)
        validated+=("${extra}")
        ;;
      ""|None)
        ;;
      *)
        log "Unknown extras choice '${extra}', ignoring it"
        ;;
    esac
  done

  extras_choice="$(printf '%s\n' "${validated[@]}" | awk 'NF && !seen[$0]++' | paste -sd, -)"
}

extras_has() {
  [[ ",${extras_choice}," == *",$1,"* ]]
}

has_non_loopback_nameserver() {
  local resolver_path="$1"

  awk '
    $1 == "nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ { found=1 }
    END { exit found ? 0 : 1 }
  ' "${resolver_path}"
}

pick_resolver_source() {
  local candidate

  for candidate in \
    /run/systemd/resolve/resolv.conf \
    /run/NetworkManager/no-stub-resolv.conf \
    /run/NetworkManager/resolv.conf \
    /etc/resolv.conf
  do
    [[ -f "${candidate}" ]] || continue
    if has_non_loopback_nameserver "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

write_pacman_conf() {
  install -d -m700 "${state_dir}"
  pacman_conf="${state_dir}/pacman.conf"

  write_arch_mirrorlist
  cat >"${pacman_conf}" <<EOF
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 1
DisableDownloadTimeout

[core]
Include = ${arch_mirrorlist}

[extra]
Include = ${arch_mirrorlist}

[multilib]
Include = ${arch_mirrorlist}

[veldmuis-core]
SigLevel = Required DatabaseRequired
Server = file://${live_repo_root}/veldmuis-core/os/\$arch

[veldmuis-extra]
SigLevel = Required DatabaseRequired
Server = file://${live_repo_root}/veldmuis-extra/os/\$arch
EOF
}

# Later phases reuse the pacman configuration and ranked mirrorlist that the
# prepare phase produced, so reflector and the keyring work happen only once.
ensure_pacman_conf() {
  if [[ -s "${pacman_conf}" && -s "${arch_mirrorlist}" ]]; then
    log "Reusing the prepared pacman configuration"
    return 0
  fi

  write_pacman_conf
}

has_secret_key() {
  local gpgdir="$1"

  gpg --homedir "${gpgdir}" --batch --with-colons -K 2>/dev/null | grep -q '^sec:'
}

target_has_secret_key() {
  arch-chroot "${target_root}" /usr/bin/bash -lc \
    "gpg --homedir /etc/pacman.d/gnupg --batch --with-colons -K 2>/dev/null | grep -q '^sec:'"
}

release_key_id_from_dir() {
  local keyring_dir="$1"
  local trusted_file="${keyring_dir}/veldmuis-trusted"

  [[ -f "${trusted_file}" ]] || return 0

  awk -F: '
    NF && $1 !~ /^#/ {
      print $1
      exit
    }
  ' "${trusted_file}"
}

ensure_keyring_populated() {
  local gpgdir="$1"
  local keyring_dir="$2"
  local label="$3"
  local release_key_id=""

  install -d -m700 "${gpgdir}"

  if ! has_secret_key "${gpgdir}"; then
    log "Initializing ${label} pacman keyring"
    pacman-key --gpgdir "${gpgdir}" --init
  fi

  log "Populating ${label} pacman keyring with Arch and Veldmuis signing keys"
  pacman-key --gpgdir "${gpgdir}" --populate-from "${keyring_dir}" --populate archlinux veldmuis
  log "Updating ${label} pacman trust database"
  pacman-key --gpgdir "${gpgdir}" --updatedb

  release_key_id="$(release_key_id_from_dir "${keyring_dir}")"
  if [[ -n "${release_key_id}" ]]; then
    log "Locally signing the Veldmuis release key in the ${label} keyring"
    pacman-key --gpgdir "${gpgdir}" --lsign-key "${release_key_id}"
  fi
}

ensure_target_keyring_populated() {
  local release_key_id="$1"

  if ! target_has_secret_key; then
    log "Initializing target pacman keyring"
    arch-chroot "${target_root}" pacman-key --init
  fi

  log "Populating target pacman keyring with Arch and Veldmuis signing keys"
  arch-chroot "${target_root}" pacman-key --populate archlinux veldmuis
  log "Updating target pacman trust database"
  arch-chroot "${target_root}" pacman-key --updatedb

  if [[ -n "${release_key_id}" ]]; then
    log "Locally signing the Veldmuis release key in the target keyring"
    arch-chroot "${target_root}" pacman-key --lsign-key "${release_key_id}"
  fi
}

prepare_target_root() {
  local resolver_source=""

  install -d -m755 "${target_root}/etc"
  install -Dm644 /dev/null "${target_root}/etc/vconsole.conf"

  if resolver_source="$(pick_resolver_source)"; then
    log "Copying resolver config from ${resolver_source} into ${target_root}"
    install -Dm644 "${resolver_source}" "${target_root}/etc/resolv.conf"
  else
    die "Could not find a non-loopback resolver config in the live environment."
  fi
}

install_target_arch_mirrorlist() {
  [[ -n "${arch_mirrorlist}" ]] || write_live_arch_mirrorlist
  log "Installing Arch mirrorlist into target system"
  install -Dm644 "${arch_mirrorlist}" "${target_root}/etc/pacman.d/mirrorlist"
}

normalize_keyring_permissions() {
  local gpgdir="$1"

  [[ -d "${gpgdir}" ]] || return 0

  chmod 755 "${gpgdir}"

  for dir_name in crls.d openpgp-revocs.d private-keys-v1.d; do
    [[ -d "${gpgdir}/${dir_name}" ]] || continue
    chmod 700 "${gpgdir}/${dir_name}"
  done

  for file_name in pubring.gpg trustdb.gpg gpg.conf gpg-agent.conf tofu.db; do
    [[ -f "${gpgdir}/${file_name}" ]] || continue
    chmod 644 "${gpgdir}/${file_name}"
  done

  [[ -f "${gpgdir}/secring.gpg" ]] && chmod 600 "${gpgdir}/secring.gpg"
}

install_target_packages() {
  (($# > 0)) || return 0

  log "Installing target packages: $*"
  arch-chroot "${target_root}" pacman -S --noconfirm --needed "$@"
}

cpu_microcode_packages() {
  local vendor_id=""

  vendor_id="$(awk -F ': ' '/^vendor_id[[:space:]]*: / { print $2; exit }' /proc/cpuinfo)"

  case "${vendor_id}" in
    AuthenticAMD)
      printf '%s\n' "${veldmuis_installer_cpu_amd_packages[@]}"
      ;;
    GenuineIntel)
      printf '%s\n' "${veldmuis_installer_cpu_intel_packages[@]}"
      ;;
    *)
      ;;
  esac
}

selected_graphics_packages() {
  case "${graphics_choice}" in
    all-open-source)
      printf '%s\n' "${veldmuis_installer_graphics_all_open_source_packages[@]}"
      ;;
    amd-open-source)
      printf '%s\n' "${veldmuis_installer_graphics_amd_open_source_packages[@]}"
      ;;
    intel-open-source)
      printf '%s\n' "${veldmuis_installer_graphics_intel_open_source_packages[@]}"
      ;;
    nvidia-open-source)
      printf '%s\n' "${veldmuis_installer_graphics_nvidia_open_source_packages[@]}"
      ;;
    nvidia-580xx-dkms)
      printf '%s\n' "${veldmuis_installer_graphics_nvidia_580xx_packages[@]}"
      ;;
  esac
}

selected_extras_packages() {
  if extras_has gaming; then
    printf '%s\n' "${veldmuis_installer_gaming_packages[@]}"
  fi
  if extras_has steam; then
    printf '%s\n' "${veldmuis_installer_steam_packages[@]}"
  fi
  if extras_has lutris; then
    printf '%s\n' "${veldmuis_installer_lutris_packages[@]}"
  fi
  if extras_has discord; then
    printf '%s\n' "${veldmuis_installer_discord_packages[@]}"
  fi
  if extras_has qbittorrent; then
    printf '%s\n' "${veldmuis_installer_downloads_packages[@]}"
  fi
  if extras_has syncthing; then
    printf '%s\n' "${veldmuis_installer_sync_packages[@]}"
  fi
  if extras_has code; then
    printf '%s\n' "${veldmuis_installer_development_packages[@]}"
  fi
  if extras_has dotfiles; then
    printf '%s\n' "${veldmuis_installer_dotfiles_packages[@]}"
  fi
  if extras_has opencode; then
    printf '%s\n' "${veldmuis_installer_opencode_packages[@]}"
  fi
  if extras_has codex; then
    printf '%s\n' "${veldmuis_installer_codex_packages[@]}"
  fi
}

selected_terminal_packages() {
  printf '%s\n' "${veldmuis_installer_terminal_packages[@]}"
}

append_packages_from() {
  local package

  while IFS= read -r package; do
    [[ -n "${package}" ]] || continue
    PACKAGE_BATCH+=("${package}")
  done < <("$@")
}

# Packages that turn a bare chroot into a bootable Veldmuis base system.
base_phase_packages() {
  PACKAGE_BATCH=("${veldmuis_installer_base_packages[@]}")
  append_packages_from cpu_microcode_packages
  append_packages_from selected_terminal_packages
  printf '%s\n' "${PACKAGE_BATCH[@]}"
}

graphics_phase_packages() {
  PACKAGE_BATCH=()
  append_packages_from selected_graphics_packages
  ((${#PACKAGE_BATCH[@]} == 0)) && return 0
  printf '%s\n' "${PACKAGE_BATCH[@]}"
}

extras_phase_packages() {
  PACKAGE_BATCH=()
  append_packages_from selected_extras_packages
  ((${#PACKAGE_BATCH[@]} == 0)) && return 0
  printf '%s\n' "${PACKAGE_BATCH[@]}"
}

initial_target_packages() {
  PACKAGE_BATCH=()
  append_packages_from base_phase_packages
  append_packages_from graphics_phase_packages
  append_packages_from extras_phase_packages
  printf '%s\n' "${PACKAGE_BATCH[@]}"
}

validate_environment() {
  [[ -n "${target_root}" ]] || die "Missing target root argument."
  [[ -d "${target_root}" ]] || die "Target root does not exist: ${target_root}"
  [[ -s "${live_repo_root}/veldmuis-core/os/x86_64/veldmuis-core.db.tar.gz" && \
    -s "${live_repo_root}/veldmuis-extra/os/x86_64/veldmuis-extra.db.tar.gz" ]] || \
    die "Embedded Veldmuis repositories are incomplete at ${live_repo_root}"
  [[ -f /usr/share/pacman/keyrings/veldmuis.gpg ]] || \
    die "Veldmuis keyring is missing from the live environment."
  [[ -r "${installer_package_sets}" ]] || \
    die "Installer package-set definition is missing: ${installer_package_sets}"

  # shellcheck source=packages/veldmuis-calamares-config/installer-package-sets.sh
  . "${installer_package_sets}"
}

log_selection() {
  log "Selected graphics choice: ${graphics_choice}"
  log "Selected extras choices: ${extras_choice:-none}"
}

# Mirrors, pacman configuration, target root skeleton and the live keyring. This
# is the only phase that ranks mirrors, so later phases start quickly.
phase_prepare() {
  normalize_graphics_choice
  normalize_extras_choice
  write_pacman_conf
  prepare_target_root
  ensure_keyring_populated /etc/pacman.d/gnupg /usr/share/pacman/keyrings live
  log_selection
}

install_phase_packages() {
  local label="$1"
  local package_function="$2"
  local -a packages=()

  mapfile -t packages < <("${package_function}")

  if ((${#packages[@]} == 0)); then
    log "No packages selected for the ${label} phase"
    return 0
  fi

  log "Installing ${label} packages into ${target_root}: ${packages[*]}"
  pacstrap -C "${pacman_conf}" "${target_root}" "${packages[@]}"
}

# The base phase installs the desktop closure, which dominates the download.
phase_base() {
  normalize_graphics_choice
  normalize_extras_choice
  ensure_pacman_conf
  install_phase_packages "base system" base_phase_packages
}

phase_graphics() {
  normalize_graphics_choice
  normalize_extras_choice
  ensure_pacman_conf
  install_phase_packages "graphics" graphics_phase_packages
}

phase_extras() {
  normalize_graphics_choice
  normalize_extras_choice
  ensure_pacman_conf
  install_phase_packages "optional extras" extras_phase_packages
}

# Target mirrorlist, target keyring and the Veldmuis repository include.
phase_finalize() {
  local release_key_id=""

  normalize_graphics_choice
  normalize_extras_choice
  ensure_pacman_conf

  release_key_id="$(release_key_id_from_dir /usr/share/pacman/keyrings)"
  install_target_arch_mirrorlist
  ensure_target_keyring_populated "${release_key_id}"
  normalize_keyring_permissions "${target_root}/etc/pacman.d/gnupg"

  if ! grep -qxF 'Include = /etc/pacman.conf.d/veldmuis.conf' "${target_root}/etc/pacman.conf"; then
    printf '\nInclude = /etc/pacman.conf.d/veldmuis.conf\n' >> "${target_root}/etc/pacman.conf"
  fi

  log_selection
  cleanup
}

# Single-shot mode for manual runs: every phase in one job.
phase_all() {
  local release_key_id=""
  local -a packages=()

  normalize_graphics_choice
  normalize_extras_choice
  write_pacman_conf
  prepare_target_root
  ensure_keyring_populated /etc/pacman.d/gnupg /usr/share/pacman/keyrings live
  release_key_id="$(release_key_id_from_dir /usr/share/pacman/keyrings)"

  mapfile -t packages < <(initial_target_packages)
  log "Installing Veldmuis package stack into ${target_root}: ${packages[*]}"
  pacstrap -C "${pacman_conf}" "${target_root}" "${packages[@]}"

  install_target_arch_mirrorlist
  ensure_target_keyring_populated "${release_key_id}"
  normalize_keyring_permissions "${target_root}/etc/pacman.d/gnupg"

  if ! grep -qxF 'Include = /etc/pacman.conf.d/veldmuis.conf' "${target_root}/etc/pacman.conf"; then
    printf '\nInclude = /etc/pacman.conf.d/veldmuis.conf\n' >> "${target_root}/etc/pacman.conf"
  fi

  log_selection
  cleanup
}

main() {
  require_cmd pacstrap
  require_cmd pacman-key
  require_cmd gpg
  require_cmd arch-chroot

  exec > >(tee "${log_file}") 2>&1

  validate_environment
  log "Bootstrap phase '${phase}' starting"

  case "${phase}" in
    prepare|base|graphics|extras|finalize)
      "phase_${phase}"
      ;;
    all)
      phase_all
      ;;
    *)
      die "Unknown bootstrap phase '${phase}'"
      ;;
  esac

  log "Bootstrap phase '${phase}' complete"
}

main "$@"
