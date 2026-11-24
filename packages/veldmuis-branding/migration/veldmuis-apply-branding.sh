#!/bin/bash
#
# SPDX-FileCopyrightText: Veldmuis Linux
# SPDX-License-Identifier: MIT
#
# One-shot migration for installs that predate the Veldmuis colour scheme.
#
# Runs from /etc/xdg/autostart on graphical login, applies the Veldmuis look to
# the current user, then writes a marker so it never touches that user again.
# It deliberately does not use plasma-apply-lookandfeel, which would also
# replace the user's panel layout and wallpaper.
#
# Removal: delete the autostart entry and this script from the package. Users
# that already ran it keep their marker; users that have not logged in yet stop
# being migrated. Nothing needs to be cleaned up afterwards.

set -u

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
marker="${config_home}/veldmuis/branding.applied"

if [ -n "${VELDMUIS_SKIP_BRANDING:-}" ]; then
    exit 0
fi

# Already migrated for this user.
if [ -e "${marker}" ]; then
    exit 0
fi

# Only meaningful inside a Plasma session with the branding package installed.
command -v plasma-apply-colorscheme >/dev/null 2>&1 || exit 0
if ! plasma-apply-colorscheme -l 2>/dev/null | grep -q 'Veldmuis'; then
    exit 0
fi

# Colour scheme first: this is the part that matters and is applied live.
if ! plasma-apply-colorscheme Veldmuis; then
    exit 0
fi

# Desktop theme (panel/dialog colours). Not fatal if the session refuses it.
plasma-apply-desktoptheme Veldmuis >/dev/null 2>&1 || true

kwriteconfig6 --file kdeglobals --group General --key ColorScheme Veldmuis || true
kwriteconfig6 --file kdeglobals --group General --key AccentColor 229,156,63 || true
kwriteconfig6 --file kdeglobals --group General --key LastUsedCustomAccentColor 229,156,63 || true
kwriteconfig6 --file kdeglobals --group KSplash --key Theme org.veldmuis.desktop || true
kwriteconfig6 --file kdeglobals --group Icons --key Theme breeze-dark || true
kwriteconfig6 --file plasmarc --group Theme --key name Veldmuis || true

# GTK only when the user already has a GTK configuration; KDE's own GTK module
# regenerates colours from the active scheme anyway.
for version in 3.0 4.0; do
    gtk_dir="${config_home}/gtk-${version}"
    [ -d "${gtk_dir}" ] || continue
    kwriteconfig6 --file "gtk-${version}/settings.ini" --group Settings \
        --key gtk-theme-name Veldmuis || true
    kwriteconfig6 --file "gtk-${version}/settings.ini" --group Settings \
        --key gtk-application-prefer-dark-theme true || true
done

mkdir -p "$(dirname "${marker}")" && date -Iseconds > "${marker}"
