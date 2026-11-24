#!/usr/bin/env bash

# Shared package selections for the Calamares bootstrap. Keep the installer UI
# identifiers mapped to these arrays so the ISO closure and the packages
# selected at install time cannot diverge.
# ShellCheck analyzes this source file in isolation and cannot see its consumers.
# shellcheck disable=SC2034

declare -ag veldmuis_installer_base_packages=(
  veldmuis-desktop
  veldmuis-skemer
)

declare -ag veldmuis_installer_cpu_amd_packages=(
  amd-ucode
)

declare -ag veldmuis_installer_cpu_intel_packages=(
  intel-ucode
)

declare -ag veldmuis_installer_graphics_all_open_source_packages=(
  mesa
  libva-intel-driver
  intel-media-driver
  vulkan-radeon
  lib32-vulkan-radeon
  vulkan-intel
  lib32-vulkan-intel
  vulkan-nouveau
  lib32-vulkan-nouveau
)

declare -ag veldmuis_installer_graphics_amd_open_source_packages=(
  mesa
  vulkan-radeon
  lib32-vulkan-radeon
)

declare -ag veldmuis_installer_graphics_intel_open_source_packages=(
  mesa
  libva-intel-driver
  intel-media-driver
  vulkan-intel
  lib32-vulkan-intel
)

declare -ag veldmuis_installer_graphics_nvidia_open_source_packages=(
  mesa
  vulkan-nouveau
  lib32-vulkan-nouveau
)

declare -ag veldmuis_installer_graphics_nvidia_580xx_packages=(
  veldmuis-nvidia-legacy
)

declare -ag veldmuis_installer_gaming_packages=(
  veldmuis-gaming
)

# One array per selectable application. The Extras page installs these directly
# so each application can be removed independently; the grouped metapackage is
# only kept for the legacy "gaming" token.
declare -ag veldmuis_installer_steam_packages=(steam)
declare -ag veldmuis_installer_lutris_packages=(lutris)
declare -ag veldmuis_installer_discord_packages=(discord)

declare -ag veldmuis_installer_downloads_packages=(
  veldmuis-downloads
)

declare -ag veldmuis_installer_sync_packages=(
  veldmuis-sync
)

declare -ag veldmuis_installer_development_packages=(
  veldmuis-development
)

declare -ag veldmuis_installer_dotfiles_packages=(
  veldmuis-dotfiles
)

# AI coding agents. Both are Arch packages (extra); Claude Code is AUR-only and
# intentionally not offered until its redistribution terms are settled.
declare -ag veldmuis_installer_opencode_packages=(opencode)
declare -ag veldmuis_installer_codex_packages=(openai-codex)

# The installer always provides the Veldmuis terminal.
declare -ag veldmuis_installer_terminal_packages=(
  veldmuis-muis
)
